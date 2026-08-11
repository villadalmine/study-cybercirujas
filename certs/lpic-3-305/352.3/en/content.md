# Docker — Production Architecture, Operations, and Security Engineering
### LPIC-3 305-300 · Topic 352.3 (exam version 3.0, weight 15)

---

## 1. Motivation: the production architectural problem

Before containers, the unit of deployment in most shops was either a bare package (`.deb`/`.rpm` plus a pile of configuration-management glue) or a full virtual machine. Both leak the host's state into the application:

- **The package model** shares the host userland. Two applications that need incompatible versions of `glibc`, `openssl`, or a Python interpreter cannot coexist cleanly. Dependency resolution becomes a global constraint-satisfaction problem across every service on the box ("dependency hell"), and the artifact that passed CI is *not* the artifact that runs in production — only a recipe for reconstructing it is.
- **The full-VM model** solves isolation but pays for it: a hypervisor virtualizes hardware, each guest carries its own kernel, and boot time is measured in tens of seconds. Density on a 128 GB host tops out in the low hundreds of guests, and the image is gigabytes.

Docker's architectural bet is that the **kernel is shared and stable enough to be a contract**, and that the *only* thing an application legitimately needs to carry is its own userland — libraries, binaries, and a root filesystem — packaged as an **immutable, content-addressable image**. Isolation is provided not by a hypervisor but by kernel primitives (namespaces, cgroups, capabilities, seccomp, LSMs) that were already in Linux. The result:

| Property | Full VM (KVM/Xen) | Docker container |
|---|---|---|
| Kernel | One per guest | Shared with host |
| Boot / start time | 10–60 s | 20–200 ms |
| Image size | GBs | tens of MB (with multi-stage) |
| Density per host | 10²–10³ | 10³–10⁴ |
| Isolation boundary | Hardware-virtualized, strong | Kernel-enforced, weaker (shared attack surface) |
| Live migration | Mature | Not a first-class concept |
| Immutability / reproducibility | Weak (mutable disk) | Strong (layered, digest-pinned) |

The production consequences that this topic is really about:

1. **The daemon is a shared, root-owned, single point of failure.** `dockerd` runs as root, listens on a socket, and every container's lifecycle hangs off it. A daemon restart historically killed every container; `/var/run/docker.sock` bind-mounted into a container is equivalent to giving that container root on the host. This drove the industry toward **rootless mode**, **`live-restore`**, and the **containerd/runc split**.
2. **Supply chain and provenance.** An image is code you did not write, running as root by default, pulled by a mutable tag. CVE scanning, digest pinning, and signing (Notation/cosine, Docker Content Trust) exist because `docker pull nginx:latest` is an unauthenticated download of an executable.
3. **Resource isolation is opt-in, not default.** A container with no `--memory`/`--cpus` limit can starve its neighbours. Production Docker is mostly about the flags you *add* to `docker run`.

> **Official framing:** Docker's own overview, "Docker overview / architecture," docs.docker.com/get-started/docker-overview/ — the client–daemon–registry model described below.

---

## 2. Docker architecture and internals

### 2.1 The process tree: client → dockerd → containerd → shim → runc

Modern Docker is **not** a monolith. The CLI you type is a thin client; the real work is delegated down a chain of daemons, each matching an OCI specification.

```
docker (CLI)  ──REST/gRPC──►  dockerd (Docker Engine API)
                                   │  (image build, networking, volumes, API)
                                   ▼
                              containerd            (OCI image + container lifecycle)
                                   │
                                   ▼
                          containerd-shim-runc-v2   (one per container; reparents to init)
                                   │  exec
                                   ▼
                                 runc                (creates namespaces/cgroups, execs entrypoint, exits)
                                   │
                                   ▼
                          your process (PID 1 in the container's PID namespace)
```

- **`runc`** is a *fork-and-exec* runtime: it sets up namespaces/cgroups, applies the OCI runtime spec (`config.json`), `exec`s the container's entrypoint, and **exits**. It does not stay resident.
- **`containerd-shim-runc-v2`** is the resident parent. Because `runc` exits, the shim keeps the container's `stdio` open, reaps it, reports exit status, and — crucially — **survives a `dockerd` restart**. This is what makes `live-restore` possible: containers keep running while the engine is upgraded.
- **`containerd`** owns the image store, snapshots, and container metadata. `dockerd` on top adds the higher-level UX: `docker build`, networking (libnetwork), volumes, Swarm, the Compose-facing API.

Verify the chain on a running host:

```console
$ docker run -d --name web nginx:1.27-alpine
9f1c0a3b...
$ ps -eo pid,ppid,comm | grep -E 'dockerd|containerd|runc|nginx'
    901     1 dockerd
    950     1 containerd
   1442   950 containerd-shim
   1465  1442 nginx
$ sudo ctr --namespace moby containers ls        # containerd sees the same container
CONTAINER       IMAGE    RUNTIME
9f1c0a3b...     -        io.containerd.runc.v2
```

Note the shim's PPID is `containerd` (950), and `nginx` reparents to the shim (1442), **not** to `dockerd`. Kill `dockerd` and `nginx` keeps serving.

### 2.2 The OCI specifications

Docker interoperates because three specs decouple the pieces:

| Spec | Governs | Artifact |
|---|---|---|
| **OCI Image Spec** | On-disk/registry layout: layers, manifest, config | `sha256:` layers + manifest.json |
| **OCI Runtime Spec** | How a "filesystem bundle" becomes a running process | `config.json` + `rootfs/` |
| **OCI Distribution Spec** | Registry HTTP API (push/pull/discovery) | `/v2/...` endpoints |

This is why `skopeo copy`, `buildah`, `podman`, and `containerd` can all consume Docker images: they speak the same OCI wire format.

### 2.3 The kernel primitives that *are* the container

A "container" is not a kernel object. It is a **process** wrapped in:

| Primitive | Isolates | Docker exposure |
|---|---|---|
| **PID namespace** | Process tree (container PID 1) | default; `--pid=host` to disable |
| **Network namespace** | Interfaces, routes, iptables, ports | `--network` driver |
| **Mount namespace** | Filesystem view (rootfs, overlayfs) | always |
| **UTS namespace** | Hostname/domainname | `--hostname`, `--uts=host` |
| **IPC namespace** | SysV IPC, POSIX message queues | `--ipc` |
| **User namespace** | UID/GID mapping (root-in-container ≠ root-on-host) | `userns-remap`, rootless |
| **cgroup namespace** | The container's view of its own cgroup | default (cgroup v2) |
| **cgroups v2** | CPU, memory, IO, PIDs *limits* | `--cpus`, `--memory`, `--pids-limit` |
| **Capabilities** | Fine-grained root powers | `--cap-drop`/`--cap-add` |
| **seccomp-BPF** | Allowed syscalls | default profile; `--security-opt seccomp=` |
| **LSM (AppArmor/SELinux)** | MAC policy | `--security-opt apparmor=`/`label=` |

Prove the namespaces are distinct:

```console
$ docker run -d --name ns-demo alpine sleep 1000
$ pid=$(docker inspect -f '{{.State.Pid}}' ns-demo)
$ sudo ls -l /proc/$pid/ns/
lrwxrwxrwx 1 root root 0 net -> 'net:[4026532567]'
lrwxrwxrwx 1 root root 0 pid -> 'pid:[4026532571]'
lrwxrwxrwx 1 root root 0 mnt -> 'mnt:[4026532565]'
...
$ sudo ls -l /proc/1/ns/net        # host's net namespace inode differs
lrwxrwxrwx 1 root root 0 net -> 'net:[4026531840]'
```

### 2.4 Storage driver: `overlay2` and copy-on-write

An image is a stack of **read-only layers**; the container adds one thin **read-write layer** on top. `overlay2` is the production default, implemented with the kernel's OverlayFS:

```
container rw layer  (upperdir)   ← writes land here (copy-up on modify)
─────────────────
image layer N       (lowerdir)   ← read-only
image layer N-1     (lowerdir)
...                              ← merged view = mountpoint
```

- **Copy-on-write:** modifying a file from a lower layer copies it up to the writable layer first — the "copy-up" penalty, which is why write-heavy workloads should use **volumes**, not the container filesystem.
- Layers are **content-addressed** (`sha256`), so identical layers are shared across images on disk — the reason pulling a second `-alpine`-based image is nearly free.

```console
$ docker info --format '{{.Driver}}'
overlay2
$ docker system df
TYPE            TOTAL   ACTIVE  SIZE      RECLAIMABLE
Images          14      6       2.1GB     1.3GB (61%)
Containers      9       4       115MB     46MB (40%)
Local Volumes   5       3       820MB     210MB (25%)
Build Cache     102     0       640MB     640MB
```

### 2.5 Docker vs the field

| | Docker Engine | Podman | containerd (raw) | LXC |
|---|---|---|---|---|
| Daemon | Long-running root `dockerd` | **Daemonless** (fork/exec) | `containerd` daemon | `lxc` monitor per container |
| Rootless | Yes (extra setup) | **Native/first-class** | Via nerdctl | Yes |
| Systemd integration | Weak (PID 1 gap) | `podman generate systemd`/Quadlet | — | Strong |
| Build | BuildKit built-in | Buildah | Needs BuildKit/img | Templates |
| OCI images | Yes | Yes | Yes | Not natively (system containers) |
| Orchestration | Swarm / feeds K8s | Pods (K8s-like) | K8s CRI target | Not its focus |
| Typical use | Dev + single-host prod | Rootless/RHEL, drop-in `alias docker=podman` | Kubernetes node runtime | Full-system/OS containers |

**Podman, Buildah, Skopeo** (LPI expects *awareness*): `podman` is a daemonless, mostly CLI-compatible drop-in (`alias docker=podman` works for most flows); `buildah` builds OCI images without a daemon and with finer step control; `skopeo` copies/inspects/signs images **between registries and stores without pulling to a local runtime** (`skopeo copy docker://... docker://...`).

---

## 3. Image management and Dockerfiles

### 3.1 Anatomy of an image reference

```
registry.example.com:5000 / team / api : 1.4.2 @ sha256:9b2a...   
└──── registry host ────┘  └repo path┘  └tag┘  └── immutable digest ──┘
```

- A **tag** is mutable (`:latest` can point anywhere tomorrow). A **digest** (`@sha256:...`) is content-addressed and immutable. **Pin digests in production** for reproducibility and supply-chain safety.

### 3.2 A production-grade multi-stage Dockerfile (complete)

Multi-stage builds compile in a fat "builder" stage and copy *only the artifact* into a minimal runtime stage — the single biggest lever on image size and attack surface.

```dockerfile
# syntax=docker/dockerfile:1.7
# ---- Stage 1: build ----
FROM golang:1.22-bookworm AS build
WORKDIR /src

# Cache module downloads separately from source for better layer caching.
COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod \
    go mod download

COPY . .
# Static build: no libc dependency, so it runs on scratch/distroless.
RUN --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS=linux GOFLAGS=-trimpath \
    go build -ldflags="-s -w" -o /out/api ./cmd/api

# ---- Stage 2: runtime ----
FROM gcr.io/distroless/static-debian12:nonroot AS runtime
# distroless: no shell, no package manager -> minimal CVE surface.

# Copy only the compiled binary from the build stage.
COPY --from=build /out/api /usr/local/bin/api

# Run as an unprivileged, numeric UID (works even without /etc/passwd).
USER 65532:65532

EXPOSE 8080
# Exec form -> PID 1 is the app, receives SIGTERM directly (clean shutdown).
ENTRYPOINT ["/usr/local/bin/api"]
```

Supporting `.dockerignore` (keeps build context small and secrets out of layers):

```gitignore
.git
.gitignore
*.md
**/*_test.go
.env
.env.*
secrets/
Dockerfile
docker-compose*.yml
```

Build and inspect:

```console
$ DOCKER_BUILDKIT=1 docker build -t registry.example.com/team/api:1.4.2 .
[+] Building 22.7s (16/16) FINISHED
 => [build 4/6] RUN go mod download                              6.1s
 => [build 6/6] RUN CGO_ENABLED=0 ... go build -o /out/api       9.8s
 => [runtime 2/2] COPY --from=build /out/api /usr/local/bin/api  0.1s
 => exporting to image                                           0.3s
 => => writing image sha256:3c1f...                              0.0s
 => => naming to registry.example.com/team/api:1.4.2

$ docker image ls registry.example.com/team/api
REPOSITORY                        TAG     IMAGE ID       SIZE
registry.example.com/team/api     1.4.2   3c1f2a9d8e4b   11.9MB
```

### 3.3 Instruction semantics that trip people up

| Concern | Do | Don't |
|---|---|---|
| Signal handling | `ENTRYPOINT ["/app"]` (exec form) | `ENTRYPOINT /app` (shell form → PID 1 is `sh`, swallows SIGTERM) |
| Layer cache | Copy `go.mod`/`package.json` before source | `COPY . .` first (invalidates cache on any change) |
| Secrets | `RUN --mount=type=secret` | `ARG TOKEN` / `COPY .env` (baked into a layer forever) |
| Image size | Multi-stage, `--no-install-recommends`, clean apt lists in same `RUN` | separate `RUN apt clean` (previous layer still holds the cache) |
| `ADD` vs `COPY` | `COPY` for files; `ADD` only for remote URL/auto-extract tar | `ADD` for everything |

### 3.4 Registry, digests, and pull-by-digest

```console
$ docker push registry.example.com/team/api:1.4.2
The push refers to repository [registry.example.com/team/api]
5f70bf18a086: Pushed
1.4.2: digest: sha256:9b2a4c... size: 949

# Pin the digest downstream so the tag can never be swapped under you:
$ docker pull registry.example.com/team/api@sha256:9b2a4c...
$ docker inspect --format '{{index .RepoDigests 0}}' registry.example.com/team/api:1.4.2
registry.example.com/team/api@sha256:9b2a4c...
```

### 3.5 CVE scanning (the honest supply-chain gap)

```console
$ docker scout cves registry.example.com/team/api:1.4.2
    ✓ Image stored for indexing
    ✓ Indexed 1 package
  No vulnerabilities found.

# Or vendor-neutral, in CI:
$ trivy image --severity HIGH,CRITICAL --exit-code 1 registry.example.com/team/api:1.4.2
registry.example.com/team/api:1.4.2 (debian 12)
Total: 0 (HIGH: 0, CRITICAL: 0)
```

`--exit-code 1` makes the scan **fail the pipeline** on a CRITICAL — the point of scanning is a gate, not a report.

---

## 4. Container lifecycle and runtime controls

### 4.1 A hardened, resource-bounded `docker run` (production shape)

Every flag here is a production default you should reach for, not exotica:

```console
$ docker run -d \
    --name api \
    --restart=on-failure:5 \
    --memory=512m --memory-swap=512m \      # hard cap; swap=mem disables swap
    --cpus=1.5 \                            # 1.5 cores of CPU time
    --pids-limit=200 \                      # fork-bomb guard
    --read-only \                           # immutable rootfs
    --tmpfs /tmp:rw,noexec,nosuid,size=64m \ # writable scratch, non-exec
    --cap-drop=ALL --cap-add=NET_BIND_SERVICE \
    --security-opt no-new-privileges:true \  # block setuid escalation
    --user 65532:65532 \
    --health-cmd='wget -qO- http://localhost:8080/healthz || exit 1' \
    --health-interval=10s --health-timeout=2s --health-retries=3 \
    -p 127.0.0.1:8080:8080 \                 # bind to loopback, not 0.0.0.0
    registry.example.com/team/api:1.4.2
```

### 4.2 Restart policies

| Policy | Behaviour | Use for |
|---|---|---|
| `no` (default) | Never restart | one-shot jobs |
| `on-failure[:N]` | Restart on non-zero exit, up to N | batch/idempotent workloads |
| `always` | Restart always, incl. daemon start | long-running services |
| `unless-stopped` | Like `always` but honours a manual `docker stop` across daemon restarts | services you sometimes stop by hand |

### 4.3 Healthchecks and lifecycle states

```console
$ docker ps --format 'table {{.Names}}\t{{.Status}}'
NAMES   STATUS
api     Up 2 minutes (healthy)

$ docker inspect --format '{{json .State.Health}}' api | jq
{
  "Status": "healthy",
  "FailingStreak": 0,
  "Log": [ { "ExitCode": 0, "Output": "OK" } ]
}
```

### 4.4 Logging drivers (unbounded logs are a top on-call outage)

The default `json-file` driver **grows without limit** and has filled `/var/lib/docker` on countless hosts. Bound it per-container or globally (see §7):

```console
$ docker run -d --log-driver=json-file \
    --log-opt max-size=10m --log-opt max-file=3 nginx
```

| Driver | Destination | Notes |
|---|---|---|
| `json-file` | local disk | default; **set `max-size`/`max-file`** |
| `local` | local disk (binary) | more efficient than json-file |
| `journald` | systemd journal | central rotation, `journalctl CONTAINER_NAME=` |
| `syslog`/`fluentd`/`gelf`/`awslogs` | remote | ship to aggregator |

---

## 5. Networking

### 5.1 Drivers and their trade-offs

| Driver | Model | L2/L3 | Cross-host | Perf | Use case |
|---|---|---|---|---|---|
| **bridge** (default) | NAT via `docker0`/veth | L3 (NAT) | No | Good | Single-host multi-container |
| **user-defined bridge** | Same + **embedded DNS** | L3 (NAT) | No | Good | **Default choice**: name-based service discovery |
| **host** | Shares host netns | — | No | **Native** | Latency-critical, no port mapping |
| **none** | Loopback only | — | No | — | Fully isolated / custom netns |
| **macvlan** | Container gets a MAC on the physical LAN | L2 | Yes (physical) | Native | Container as a first-class LAN host |
| **ipvlan** | Shares host MAC, own IP | L2/L3 | Yes | Native | macvlan without MAC proliferation |
| **overlay** | VXLAN across a Swarm | L2 over L3 | **Yes** | Moderate | Multi-host clusters (Swarm) |

### 5.2 Why user-defined bridges, not the default bridge

Containers on the **default** `bridge` can only reach each other by IP. Containers on a **user-defined** bridge get Docker's **embedded DNS at 127.0.0.11**, so they resolve each other by container/service name — the foundation of service discovery in Compose.

```console
$ docker network create --driver bridge \
    --subnet 172.28.0.0/16 --gateway 172.28.0.1 appnet
$ docker run -d --name db  --network appnet postgres:16
$ docker run -d --name api --network appnet registry.example.com/team/api:1.4.2

$ docker exec api getent hosts db
172.28.0.2       db                       # resolved by name via embedded DNS
$ docker exec api cat /etc/resolv.conf
nameserver 127.0.0.11
```

### 5.3 What port publishing actually does (iptables/NAT)

`-p 8080:80` inserts a **DNAT** rule so host traffic is rewritten to the container's namespace IP:

```console
$ docker run -d -p 8080:80 --name web nginx
$ sudo iptables -t nat -L DOCKER -n
Chain DOCKER (2 references)
target  prot opt source     destination
DNAT    tcp  --  0.0.0.0/0  0.0.0.0/0   tcp dpt:8080 to:172.17.0.2:80

$ docker port web
80/tcp -> 0.0.0.0:8080
```

Publishing to `0.0.0.0` exposes the port on **every** host interface — bind to `127.0.0.1:8080:80` when only the host should reach it.

### 5.4 Inspecting connectivity

```console
$ docker network inspect appnet --format '{{json .Containers}}' | jq
{
  "api...": { "Name": "api", "IPv4Address": "172.28.0.3/16" },
  "db...":  { "Name": "db",  "IPv4Address": "172.28.0.2/16" }
}
$ docker exec api wget -qO- http://db:5432 2>&1 | head -1   # name reachability test
```

---

## 6. Storage: volumes vs bind mounts vs tmpfs

| Mount type | Managed by Docker | Location | Survives `rm` | Best for |
|---|---|---|---|---|
| **Named volume** | Yes (`/var/lib/docker/volumes`) | Docker-managed | Yes (until `volume rm`) | **Persistent data (DBs)**, portability, volume drivers |
| **Bind mount** | No | Arbitrary host path | Yes (host owns it) | Dev source mounts, host config/socket |
| **tmpfs** | Yes | RAM only | No | Secrets/scratch that must never hit disk |

Rules of thumb: **never write hot data to the container's writable layer** (copy-up cost, lost on `rm`); use **volumes** for state; use **bind mounts** sparingly and read-only in prod.

```console
$ docker volume create pgdata
$ docker run -d --name db \
    -v pgdata:/var/lib/postgresql/data \        # named volume (persistent)
    --mount type=bind,src=/etc/pg/pg.conf,dst=/etc/postgresql/postgresql.conf,ro \
    --tmpfs /run/postgresql:rw,size=32m \
    -e POSTGRES_PASSWORD_FILE=/run/secrets/pw \
    postgres:16

$ docker volume inspect pgdata --format '{{.Mountpoint}}'
/var/lib/docker/volumes/pgdata/_data
```

The explicit `--mount` syntax (`type=`,`src=`,`dst=`,`ro`) is preferred over `-v` in production because it is unambiguous and fails loudly on typos rather than silently creating an empty volume.

---

## 7. Daemon configuration: `/etc/docker/daemon.json`

The daemon's behaviour is centralised here (a `dockerd` restart applies it; some keys reload on `SIGHUP`). A production baseline:

```json
{
  "data-root": "/var/lib/docker",
  "storage-driver": "overlay2",
  "live-restore": true,
  "userland-proxy": false,
  "no-new-privileges": true,
  "icc": false,
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "default-ulimits": {
    "nofile": { "Name": "nofile", "Soft": 65536, "Hard": 65536 }
  },
  "default-address-pools": [
    { "base": "172.30.0.0/16", "size": 24 }
  ],
  "insecure-registries": [],
  "registry-mirrors": ["https://mirror.internal.example.com"],
  "userns-remap": "default",
  "features": { "buildkit": true }
}
```

Key production knobs:

- **`live-restore: true`** — containers keep running across a `dockerd` upgrade/restart (works because the shim outlives the daemon; not compatible with Swarm-managed nodes).
- **`userns-remap: default`** — remaps container root to an unprivileged host UID range (`/etc/subuid`), so root-in-container ≠ root-on-host.
- **`icc: false`** — disable inter-container communication on the default bridge; force explicit user-defined networks.
- **`userland-proxy: false`** — use iptables hairpin instead of the `docker-proxy` userspace process for published ports (lower overhead).
- **`default-address-pools`** — stop Docker from colliding with your corporate `172.17.0.0/16` LAN.
- **`log-opts`** — the single most common fix for "disk full."

Apply and verify:

```console
$ sudo dockerd --validate --config-file /etc/docker/daemon.json
configuration OK
$ sudo systemctl restart docker
$ docker info --format '{{.LiveRestoreEnabled}} {{.SecurityOptions}}'
true [name=seccomp,profile=builtin name=userns name=rootless...]
```

### 7.1 Rootless mode

Rootless Docker runs `dockerd` and containers **entirely as an unprivileged user**, using user namespaces + `slirp4netns` for networking. It removes the "socket = host root" class of escapes.

```console
$ dockerd-rootless-setuptool.sh install
[INFO] Creating /home/deploy/.config/systemd/user/docker.service
[INFO] Installed docker.service successfully.
$ export DOCKER_HOST=unix:///run/user/$(id -u)/docker.sock
$ docker info --format '{{.SecurityOptions}}'
[name=seccomp,profile=builtin name=rootless name=cgroupns]
```
Trade-offs: no binding to ports < 1024 without `sysctl net.ipv4.ip_unprivileged_port_start`, some storage-driver/overlay caveats, and per-user isolation instead of a shared daemon.

---

## 8. Security model

Defence in depth — each layer is independent and additive:

| Control | Flag / config | Effect |
|---|---|---|
| Drop root | `--user`, `USER` in Dockerfile, `userns-remap` | process is not UID 0 (in-container and/or on-host) |
| Capabilities | `--cap-drop=ALL --cap-add=…` | shrink the ~14 default caps to what's needed |
| No privilege escalation | `--security-opt no-new-privileges` | setuid binaries can't raise privileges |
| Syscall filter | default **seccomp** profile (blocks ~44 syscalls) | shrinks kernel attack surface |
| MAC | AppArmor (`docker-default`) / SELinux (`--security-opt label=`) | mandatory access control |
| Immutable rootfs | `--read-only` + `--tmpfs` | no persistence of a compromise on the fs |
| Never do this | `--privileged`, `-v /var/run/docker.sock:...` | = root on the host |

Verify what a container actually holds:

```console
$ docker run --rm --cap-drop=ALL --cap-add=NET_BIND_SERVICE alpine \
    sh -c 'apk add -q libcap; capsh --print | grep Current'
Current: cap_net_bind_service=ep

$ docker inspect --format '{{.HostConfig.SecurityOpt}} priv={{.HostConfig.Privileged}}' api
[no-new-privileges:true label=type:container_t] priv=false
```

**Docker Content Trust** (image signing) and CVE scanning close the top of the supply chain:

```console
$ export DOCKER_CONTENT_TRUST=1
$ docker pull registry.example.com/team/api:1.4.2
Tagging registry.example.com/team/api@sha256:9b2a... as ...:1.4.2   # only if signed
```

---

## 9. Docker Compose

Compose is the declarative, single-host (or Swarm) multi-container spec. Modern Docker ships **Compose v2** as the `docker compose` **plugin** (Go), replacing the legacy Python `docker-compose` v1 binary. The `version:` top-level key is now obsolete and ignored.

A complete, production-shaped `compose.yaml`:

```yaml
name: web-stack

services:
  api:
    image: registry.example.com/team/api:1.4.2
    restart: unless-stopped
    depends_on:
      db:
        condition: service_healthy       # wait for db's healthcheck, not just start
    environment:
      DATABASE_URL: postgres://app@db:5432/app
    secrets:
      - db_password
    ports:
      - "127.0.0.1:8080:8080"
    networks: [frontend, backend]
    read_only: true
    tmpfs:
      - /tmp:size=64m
    cap_drop: [ALL]
    cap_add: [NET_BIND_SERVICE]
    security_opt:
      - no-new-privileges:true
    deploy:
      resources:
        limits:   { cpus: "1.5", memory: 512M }
        reservations: { memory: 256M }
    healthcheck:
      test: ["CMD", "wget", "-qO-", "http://localhost:8080/healthz"]
      interval: 10s
      timeout: 2s
      retries: 3
      start_period: 15s

  db:
    image: postgres:16-alpine
    restart: unless-stopped
    environment:
      POSTGRES_USER: app
      POSTGRES_DB: app
      POSTGRES_PASSWORD_FILE: /run/secrets/db_password
    secrets:
      - db_password
    volumes:
      - pgdata:/var/lib/postgresql/data
    networks: [backend]
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U app -d app"]
      interval: 5s
      timeout: 3s
      retries: 5

networks:
  frontend:
  backend:
    internal: true          # no egress; DB tier can't reach the outside world

volumes:
  pgdata:

secrets:
  db_password:
    file: ./secrets/db_password.txt
```

Operate it:

```console
$ docker compose config -q          # validate/interpolate without running
$ docker compose up -d
[+] Running 4/4
 ✔ Network web-stack_backend   Created
 ✔ Network web-stack_frontend  Created
 ✔ Container web-stack-db-1     Healthy
 ✔ Container web-stack-api-1    Started

$ docker compose ps
NAME               IMAGE                    STATUS                    PORTS
web-stack-api-1    .../team/api:1.4.2       Up (healthy)              127.0.0.1:8080->8080/tcp
web-stack-db-1     postgres:16-alpine       Up (healthy)

$ docker compose logs -f --tail=20 api
$ docker compose down -v            # -v also removes named volumes
```

`depends_on … condition: service_healthy` is the correct fix for the classic race where `api` starts before `db` is accepting connections — plain `depends_on` only orders *start*, not *readiness*.

---

## 10. Verification and failure diagnosis

### 10.1 First-pass triage commands

```console
$ docker info                       # daemon: driver, cgroup version, warnings
$ docker version                    # client/server API skew
$ docker system df -v               # where disk went (images/containers/volumes/cache)
$ docker events --since 10m         # lifecycle stream: OOM, die, health_status
$ docker stats --no-stream          # live CPU/mem/net/IO per container
$ journalctl -u docker --since '10 min ago'   # daemon-side errors
```

### 10.2 A container won't start / exits immediately

```console
$ docker ps -a --filter name=api
CONTAINER   STATUS
a1b2c3      Exited (1) 3 seconds ago
$ docker logs --tail=50 api          # the app's own error
$ docker inspect --format '{{.State.ExitCode}} {{.State.Error}} oom={{.State.OOMKilled}}' api
137  <no value> oom=true
```

**Exit 137 = 128 + 9 (SIGKILL)**, and `OOMKilled: true` confirms the kernel's OOM killer fired — raise `--memory` or fix the leak. **Exit 143 = 128 + 15 (SIGTERM)** is a clean stop.

### 10.3 Diagnosing OOM against the cgroup

```console
$ cid=$(docker inspect -f '{{.Id}}' api)
$ cat /sys/fs/cgroup/system.slice/docker-$cid.scope/memory.max
536870912
$ cat /sys/fs/cgroup/system.slice/docker-$cid.scope/memory.events
oom 0
oom_kill 3                          # the kernel killed the workload 3 times
$ dmesg | grep -i 'killed process'
Out of memory: Killed process 1465 (api) total-vm:... anon-rss:...
```

### 10.4 Networking failures

```console
# DNS resolution inside the container:
$ docker exec api getent hosts db || echo "name not resolvable"
# Is the port actually published?
$ docker port web
80/tcp -> 0.0.0.0:8080
# Enter the container's network namespace with host tools (no tools in the image):
$ pid=$(docker inspect -f '{{.State.Pid}}' api)
$ sudo nsenter -t $pid -n ss -tlnp
State   Local Address:Port   Process
LISTEN  0.0.0.0:8080         users:(("api",pid=1))
# Is the DNAT rule present?
$ sudo iptables -t nat -S DOCKER | grep 8080
```

`nsenter -t <pid> -n` is the key trick: it runs a **host** binary (`ss`, `tcpdump`, `ip`) inside the container's **network namespace**, so you can diagnose a distroless container that ships no tooling at all.

### 10.5 Storage / disk full

```console
$ docker system df
$ docker system prune -a --volumes    # reclaim: dangling images, stopped containers, unused volumes, build cache
Total reclaimed space: 3.8GB
$ df -h /var/lib/docker
```

### 10.6 Health and readiness

```console
$ docker inspect --format '{{.State.Health.Status}}' api
unhealthy
$ docker inspect --format '{{range .State.Health.Log}}{{.End}} exit={{.ExitCode}} {{.Output}}{{"\n"}}{{end}}' api
2026-08-11T... exit=1 wget: can't connect to localhost:8080
```

### 10.7 Interactive forensics on a stopped/minimal container

```console
# Copy a file out of a dead container's filesystem:
$ docker cp api:/var/log/app.log ./app.log
# Attach a debug sidecar sharing the target's namespaces (no shell in the image):
$ docker run -it --rm \
    --pid=container:api --net=container:api \
    --cap-add=SYS_PTRACE nicolaka/netshoot \
    sh -c 'ps aux; ss -tlnp'
```

`nicolaka/netshoot` sharing `--pid`/`--net` of the target is the standard way to debug a distroless/scratch container that has no shell, `ps`, or `ss` of its own.

---

## Referencias

- Docker overview & architecture — https://docs.docker.com/get-started/docker-overview/
- Docker Engine daemon configuration (`/etc/docker/daemon.json`) — https://docs.docker.com/engine/daemon/
- `dockerd` reference — https://docs.docker.com/reference/cli/dockerd/
- Dockerfile reference — https://docs.docker.com/reference/dockerfile/
- BuildKit & multi-stage builds — https://docs.docker.com/build/building/multi-stage/
- `.dockerignore` — https://docs.docker.com/reference/dockerfile/#dockerignore-file
- Storage drivers / `overlay2` — https://docs.docker.com/engine/storage/drivers/overlayfs-driver/
- Volumes and bind mounts — https://docs.docker.com/engine/storage/volumes/
- Networking overview & drivers — https://docs.docker.com/engine/network/
- Bridge / user-defined networks & embedded DNS — https://docs.docker.com/engine/network/drivers/bridge/
- Runtime resource constraints — https://docs.docker.com/engine/containers/resource_constraints/
- Container security & seccomp — https://docs.docker.com/engine/security/seccomp/
- AppArmor profile — https://docs.docker.com/engine/security/apparmor/
- Rootless mode — https://docs.docker.com/engine/security/rootless/
- User namespace remapping — https://docs.docker.com/engine/security/userns-remap/
- Docker Content Trust — https://docs.docker.com/engine/security/trust/
- Docker Scout (CVE scanning) — https://docs.docker.com/scout/
- Compose file reference (v2) — https://docs.docker.com/reference/compose-file/
- Compose `depends_on` / healthcheck conditions — https://docs.docker.com/reference/compose-file/services/#depends_on
- `docker system prune` — https://docs.docker.com/reference/cli/docker/system/prune/
- containerd — https://containerd.io/docs/
- runc (OCI runtime) — https://github.com/opencontainers/runc
- OCI Image / Runtime / Distribution specs — https://github.com/opencontainers/image-spec · https://github.com/opencontainers/runtime-spec · https://github.com/opencontainers/distribution-spec
- Podman — https://docs.podman.io/ · Buildah — https://buildah.io/ · Skopeo — https://github.com/containers/skopeo
- LPIC-3 305-300 exam objectives (352.3) — https://www.lpi.org/our-certifications/exam-305-objectives/