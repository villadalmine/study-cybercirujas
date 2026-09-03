# 702.1 — Application Container Management

**Exam:** LPI DevOps Tools Engineer, 701-100 (objectives v2.0.0)
**Topic weight:** 8.33 — one of the heaviest single objectives in the exam. Expect questions that go past `docker run` into image construction, identity, isolation primitives and failure triage.

**Scope covered here (paraphrased from the official objective set):** building, distributing and running application containers; Dockerfile/Containerfile authoring; image registries and image identity; container lifecycle, storage, networking and resource constraints; multi-container application definitions; container security posture; and the tooling ecosystem around Docker, Podman, Buildah and Skopeo. Orchestration (Kubernetes, scheduling, controllers) is **702.2/702.3** and is only referenced here where it changes a design decision at the container level.

---

## 1. The production problem

### 1.1 What containers actually solve — and what they do not

The naive story ("containers solve *works on my machine*") is true but useless for a platform architect. The precise statement is:

> A container image is a **content-addressable, layered, immutable filesystem bundle plus an execution contract**, and a container is a **process tree started from that bundle with a restricted view of the kernel**.

Two consequences drive every production decision in this objective:

1. **The kernel is shared.** There is no hypervisor boundary. A container is a normal Linux process whose visibility is trimmed by namespaces, whose resource consumption is capped by cgroups, and whose privilege is trimmed by capabilities, seccomp and LSMs (SELinux/AppArmor). Every isolation property you rely on is one misconfigured flag away from being absent.
2. **The artifact is immutable and addressable.** The unit of promotion between environments stops being "a deployment script that installs packages" and becomes "a digest". `sha256:1a2b…` in staging and `sha256:1a2b…` in production are *bit-identical*. This is the single largest reliability win, and it is silently discarded the moment someone deploys `:latest`.

### 1.2 The architectural failure modes containers introduce

Containers remove classes of failure and add new ones. An SRE must know the new ones cold:

| Failure class | Root cause | Symptom in production |
|---|---|---|
| **PID 1 semantics** | The container's first process is PID 1 in its PID namespace. PID 1 does not get default signal handlers and must reap orphans. | `docker stop` takes exactly 10 s then SIGKILLs; zombie processes accumulate; graceful drain never runs; in-flight requests are cut. |
| **Signal loss via shell form** | `ENTRYPOINT cmd` runs `/bin/sh -c "cmd"`; `sh` becomes PID 1 and does not forward SIGTERM. | Same as above, plus exit code 137 instead of a clean 0/143. |
| **cgroup-unaware runtimes** | JVM/Node/Go read `/proc/cpuinfo` and `/proc/meminfo` (host values) unless cgroup-aware. | Heap sized for 256 GB host inside a 512 MiB limit → OOMKill; `GOMAXPROCS` = 96 on a 0.5 CPU quota → scheduler thrash and latency tail. |
| **Mutable tags** | `:latest` / `:v1` re-pointed in the registry. | Two replicas of "the same version" run different code; rollback restores a tag that no longer means what it meant. |
| **Layer inheritance of CVEs** | Base image frozen at build time; nothing re-pulls it. | A patched base exists upstream; your fleet ships the vulnerable one for months. |
| **Write amplification on the union filesystem** | overlay2 copies a whole file to the upper layer on first write (copy-up). | A container appending to a 4 GiB log file inherited from the image consumes 4 GiB of the host's graph storage instantly. |
| **UID collision on bind mounts** | Container UID 1000 ≠ host UID 1000 semantics under rootless user namespaces. | `Permission denied` on a volume that is `0777` on the host. |
| **Ephemeral logs** | Logs written inside the container's writable layer. | Logs vanish with the container; disk fills because `json-file` has no default rotation on plain Docker. |

### 1.3 The design contract this objective enforces

Everything below follows from four rules:

1. **Build once, promote a digest.** Tags are human-facing labels; digests are the deployment identity.
2. **The runtime image contains the application and nothing else.** No compilers, no package manager, no shell if avoidable. Every binary in the image is attack surface *and* CVE-scanner noise.
3. **Run as a non-root user, with a read-only root filesystem, with all capabilities dropped, with `no-new-privileges`.** These are four flags; there is no excuse for omitting them.
4. **Every container declares its resource envelope and its liveness contract.** A container without `memory.max` is a host-wide outage waiting for a memory leak.

---

## 2. Mechanics: what the kernel is actually doing

### 2.1 Namespaces

A container is defined by which namespaces it *does not* share with the host.

| Namespace | `clone()` flag | Isolates | Practical effect |
|---|---|---|---|
| `mnt` | `CLONE_NEWNS` | Mount table | The container sees the image rootfs, not `/`. |
| `pid` | `CLONE_NEWPID` | Process IDs | The entrypoint is PID 1; the host's processes are invisible. Requires a fresh `/proc` mount. |
| `net` | `CLONE_NEWNET` | Interfaces, routes, netfilter, sockets, `/proc/net` | Own `lo`, own `eth0` (veth peer), own iptables/nftables tables. |
| `ipc` | `CLONE_NEWIPC` | SysV IPC, POSIX message queues, shared memory | Isolates `/dev/shm` (default 64 MiB — a classic Chrome/Postgres failure). |
| `uts` | `CLONE_NEWUTS` | Hostname, NIS domain | `--hostname` works without touching the host. |
| `user` | `CLONE_NEWUSER` | UID/GID maps, capability sets | **The foundation of rootless.** Root inside maps to an unprivileged host UID. |
| `cgroup` | `CLONE_NEWCGROUP` | cgroup root | Container sees `/sys/fs/cgroup` as its own root, not the host hierarchy. |
| `time` | `CLONE_NEWTIME` | `CLOCK_MONOTONIC`/`BOOTTIME` offsets | Used by CRIU checkpoint/restore; rarely set by container engines. |

Observe them directly:

```console
$ podman run -d --rm --name ns-demo docker.io/library/alpine:3.20 sleep 600
9f2c4b1e7a3d5c8f0e6b2a4d7c9e1f3b5a7c9e1f3b5d7f9a1c3e5b7d9f1a3c5e

$ pid=$(podman inspect -f '{{.State.Pid}}' ns-demo); echo "$pid"
48213

$ ls -l /proc/$pid/ns
total 0
lrwxrwxrwx. 1 dev dev 0 Sep  3 10:21 cgroup -> 'cgroup:[4026533112]'
lrwxrwxrwx. 1 dev dev 0 Sep  3 10:21 ipc    -> 'ipc:[4026533049]'
lrwxrwxrwx. 1 dev dev 0 Sep  3 10:21 mnt    -> 'mnt:[4026533047]'
lrwxrwxrwx. 1 dev dev 0 Sep  3 10:21 net    -> 'net:[4026533051]'
lrwxrwxrwx. 1 dev dev 0 Sep  3 10:21 pid    -> 'pid:[4026533050]'
lrwxrwxrwx. 1 dev dev 0 Sep  3 10:21 user   -> 'user:[4026531837]'
lrwxrwxrwx. 1 dev dev 0 Sep  3 10:21 uts    -> 'uts:[4026533048]'

$ readlink /proc/self/ns/net
net:[4026531840]
```

The `net` inode differs (`4026533051` vs the host's `4026531840`) → the container has its own network namespace. The `user` inode is *identical* to the host's here, because this was a rootful Podman run; under rootless it would differ. That single comparison is the fastest way to prove whether user-namespace isolation is actually in effect.

```console
$ lsns -t pid -p $pid
        NS TYPE NPROCS   PID USER COMMAND
4026533050 pid       1 48213 root sleep 600

$ sudo nsenter -t $pid -a ps -ef
PID   USER     TIME  COMMAND
    1 root      0:00 sleep 600
    7 root      0:00 ps -ef
```

### 2.2 cgroups v2 — the resource contract

On a modern host (`cgroup2fs` unified hierarchy), the container's limits are plain files.

```console
$ stat -fc %T /sys/fs/cgroup
cgroup2fs

$ id=$(docker inspect -f '{{.Id}}' api)
$ cg=/sys/fs/cgroup/system.slice/docker-$id.scope

$ cat $cg/memory.max $cg/memory.high $cg/pids.max $cg/cpu.max
536870912
max
512
50000 100000
```

Reading: hard memory ceiling 512 MiB; no soft throttle; max 512 PIDs; CPU quota 50 000 µs per 100 000 µs period = **0.5 CPU**.

```console
$ cat $cg/memory.events
low 0
high 0
max 1174
oom 2
oom_kill 2

$ cat $cg/cpu.stat
usage_usec 91827364
user_usec 71029844
system_usec 20797520
nr_periods 18342
nr_throttled 4471
throttled_usec 2310945000
```

`nr_throttled / nr_periods = 24 %` — one in four scheduling periods the workload was stopped at its quota. That is a latency bug, not a capacity bug, and it is invisible to `docker stats`. `oom_kill 2` proves the kernel killed processes twice; `max 1174` counts times the allocation hit the ceiling.

Rootless Podman places containers elsewhere:

```console
$ cat /sys/fs/cgroup/user.slice/user-1000.slice/user@1000.service/user.slice/\
libpod-$(podman inspect -f '{{.Id}}' api).scope/memory.max
268435456
```

> **cgroup v1 caveat:** rootless resource limits require cgroups v2 + systemd. On a v1 host, `podman run --memory` from a non-root user is silently ignored or errors. `podman info --format '{{.Host.CgroupsVersion}}'` is the check.

### 2.3 Capabilities

Root inside a container is not host root — it is a *capability set*. Docker/Podman grant a reduced default set and drop the rest.

```console
$ docker run --rm alpine:3.20 sh -c 'apk add -q libcap; capsh --print | head -3'
Current: cap_chown,cap_dac_override,cap_fowner,cap_fsetid,cap_kill,cap_setgid,
cap_setuid,cap_setpcap,cap_net_bind_service,cap_net_raw,cap_sys_chroot,
cap_mknod,cap_audit_write,cap_setfcap=ep
Bounding set: cap_chown,cap_dac_override,cap_fowner,cap_fsetid,cap_kill,...
```

The production posture drops everything and re-adds only what is provably needed:

```console
$ docker run --rm --cap-drop=ALL --security-opt=no-new-privileges \
    alpine:3.20 sh -c 'apk add -q libcap; capsh --print | head -1'
Current: =
```

| Capability | Why an app might need it | Safer alternative |
|---|---|---|
| `NET_BIND_SERVICE` | Listen on port < 1024 | Listen on 8080, publish `-p 443:8080`; or sysctl `net.ipv4.ip_unprivileged_port_start=80` |
| `CHOWN`, `DAC_OVERRIDE`, `FOWNER` | Entrypoint fixing volume permissions | Fix ownership at build time / use `:U` (Podman) or an init container |
| `NET_RAW` | `ping`, raw sockets | Drop it — it enables ARP spoofing inside the network namespace |
| `SYS_ADMIN` | "Docker-in-Docker", mounts, some profilers | Rootless Podman, sysbox, or a sidecar with a narrow seccomp profile |
| `SYS_PTRACE` | Debuggers, `py-spy`, `perf` | Attach only in a temporary debug container |

### 2.4 The image on disk: overlayfs

```console
$ docker image inspect nginx:1.27-alpine \
    --format '{{json .GraphDriver}}' | jq .
{
  "Data": {
    "LowerDir": "/var/lib/docker/overlay2/8a1f.../diff:/var/lib/docker/overlay2/3b7c.../diff",
    "MergedDir": "/var/lib/docker/overlay2/f04e.../merged",
    "UpperDir": "/var/lib/docker/overlay2/f04e.../diff",
    "WorkDir": "/var/lib/docker/overlay2/f04e.../work"
  },
  "Name": "overlay2"
}
```

* `LowerDir` — the read-only image layers, stacked right-to-left (rightmost is the base).
* `UpperDir` — the container's writable layer. **Everything written at runtime that is not a volume lands here.**
* `MergedDir` — the unified view the process sees as `/`.
* Deleting a file from a lower layer creates a *whiteout* (a `0:0` char device) in `UpperDir` — the bytes remain in the image. This is why `RUN rm -rf /secret` in a later Dockerfile layer **does not remove the secret from the image**.

```console
$ docker diff api | head
C /etc
C /etc/nginx/conf.d
A /etc/nginx/conf.d/upstream.conf
C /var/cache/nginx
A /var/cache/nginx/client_temp
C /tmp
A /tmp/heapdump-20260903.hprof
```

`A` = added, `C` = changed, `D` = deleted. A container that should be immutable showing dozens of `A` lines outside `/tmp` is a design defect.

### 2.5 The runtime stack

```
docker CLI ──REST/unix socket──► dockerd ──gRPC──► containerd ──► containerd-shim-runc-v2 ──► runc ──► your process
                                                                        (shim survives daemon restart)

podman CLI ──(no daemon; fork/exec)──────────────────────────────────► conmon ──► crun|runc ──► your process

kubelet ────CRI (gRPC)────► containerd | CRI-O ──► shim ──► runc|crun ──► your process
```

* **`runc`** — the OCI runtime reference implementation (Go). Applies namespaces/cgroups/capabilities/seccomp, then `execve()`s.
* **`crun`** — C implementation, faster start, lower memory, native cgroup v2 support; Podman's default on Fedora/RHEL.
* **`conmon`** — Podman's per-container monitor: holds the PTY, writes the log, reports the exit code. It is the daemonless equivalent of the containerd shim.
* **Daemonless matters operationally:** restarting `dockerd` is a fleet-wide event; Podman has no such single point of failure, and its containers are ordinary systemd services when managed via Quadlet (§8).

```console
$ podman info --format '{{.Host.OCIRuntime.Name}} {{.Host.OCIRuntime.Version}}'
crun 1.15

$ docker info --format '{{.DefaultRuntime}} / {{.CgroupDriver}} / {{.CgroupVersion}}'
runc / systemd / 2
```

---

## 3. Engine and tooling comparison

### 3.1 Container engines

| | **Docker Engine** | **Podman** | **containerd + nerdctl** | **CRI-O** |
|---|---|---|---|---|
| Architecture | Client → daemon (`dockerd`) → containerd | Daemonless, fork/exec, `conmon` per container | Daemon (`containerd`), CLI is thin | Daemon, Kubernetes-only |
| Runs as non-root | Rootless mode (extra setup, `dockerd-rootless.sh`) | **Rootless is first-class and default** | Rootless supported | No (kubelet-driven) |
| Socket privilege model | Membership of `docker` group ≈ root on the host | No socket needed; optional API service | `containerd.sock` ≈ root | CRI socket, kubelet only |
| systemd integration | Containers are children of the daemon | **Quadlet** — containers *are* systemd units | Manual | kubelet-managed |
| Pods (shared netns) | No | **Yes** (`podman pod`) | No | Yes (CRI) |
| Build engine | BuildKit (integrated) | Buildah (integrated as `podman build`) | BuildKit (separate) | None — pull only |
| Compose | `docker compose` (v2 plugin, first-class) | `podman compose` shim / `podman kube play` | `nerdctl compose` | N/A |
| Docker API compatibility | Native | `podman system service` exposes a compatible API | Partial | No |
| Best fit | Developer laptops, Swarm, ecosystems assuming `/var/run/docker.sock` | RHEL/Fedora hosts, rootless CI, single-node production services, air-gapped | Kubernetes nodes, minimal footprint | Kubernetes nodes, minimal attack surface |

**The security argument, stated precisely:** adding a user to the `docker` group grants the ability to run `docker run -v /:/host --privileged`, i.e. full root on the host, without `sudo` and without an audit trail attributable to a privileged action. Rootless Podman has no equivalent escalation path because the container's "root" is a mapped unprivileged UID.

### 3.2 Build tools

| | **`docker build` (BuildKit)** | **Buildah** | **Kaniko** | **`podman build`** |
|---|---|---|---|---|
| Requires a daemon | Yes (or `buildx` with a builder container) | No | No | No (uses Buildah) |
| Requires privilege | Daemon runs as root (or rootless mode) | Rootless capable | Runs in-cluster, unprivileged-ish | Rootless capable |
| Dockerfile support | Full, canonical | Full (`buildah bud`) | Most | Full |
| Scriptable without a Dockerfile | No | **Yes** (`buildah from` / `run` / `commit`) | No | No |
| Parallel stage execution / DAG | **Yes** | Sequential | Sequential | Sequential |
| Cache mounts, secret mounts, SSH mounts | **Yes** | Partial | Partial | Partial (BuildKit-style `--mount` supported for cache/secret) |
| Multi-arch in one command | **Yes** (`buildx --platform`) | Via `buildah manifest` | Per-arch jobs | Via `podman manifest` |
| Typical use | Everything, CI included | Air-gapped, scripted image assembly, base-image factories | Kubernetes-native CI where no daemon is allowed | Podman-based CI |

**Buildah's differentiator** — building an image with no Dockerfile at all, useful when the "build" is really a composition step:

```console
$ ctr=$(buildah from registry.access.redhat.com/ubi9/ubi-micro:9.4)
$ mnt=$(buildah mount $ctr)
$ install -D -m 0755 ./dist/api "$mnt/usr/local/bin/api"
$ buildah umount $ctr
$ buildah config --entrypoint '["/usr/local/bin/api"]' \
    --port 8080 \
    --user 65532:65532 \
    --label org.opencontainers.image.revision="$(git rev-parse HEAD)" $ctr
$ buildah commit --format oci --squash $ctr registry.example.com/platform/api:1.8.3
Getting image source signatures
Copying blob 4f2a1c0e9b31 done
Copying config 8c1d3e5a72 done
Writing manifest to image destination
8c1d3e5a72f9b4d0e6a8c2f4b6d8e0a2c4f6b8d0e2a4c6f8b0d2e4a6c8f0b2d4
```

### 3.3 Base image selection

| Base | Size (amd64, typical) | Shell | libc | Package manager | CVE surface | Debuggability | Use when |
|---|---|---|---|---|---|---|---|
| `scratch` | 0 B | no | none (static only) | none | minimal | none | Fully static Go/Rust binary, maximum hardening |
| `gcr.io/distroless/static-debian12` | ~2 MiB | no (`:debug` variant has busybox) | none | none | very low | poor without `:debug` | Static binaries with CA certs, tzdata, `/etc/passwd` |
| `gcr.io/distroless/base-debian12` | ~20 MiB | no | glibc | none | low | poor | CGO-enabled binaries |
| `alpine:3.20` | ~7 MiB | ash | **musl** | apk | low | good | Small images where musl is verified safe |
| `debian:12-slim` | ~75 MiB | bash | glibc | apt | medium | good | glibc-dependent apps, broad compatibility |
| `ubi9/ubi-micro` | ~25 MiB | no | glibc | none (build with `microdnf` from `ubi`) | low | poor | Red Hat support/entitlement requirements |
| `ubi9/ubi-minimal` | ~100 MiB | bash | glibc | microdnf | medium | good | RHEL ecosystem, needs a package manager |

**The musl trap.** Alpine uses musl libc. Known production consequences: glibc-only binaries fail with `Error loading shared library ld-linux-x86-64.so.2`; DNS resolution historically differed (no `search`-domain retry on `SERVFAIL`, no TCP fallback in old versions); the default thread stack size is 128 KiB vs glibc's 8 MiB, which crashes deep-recursion workloads; Python wheels need `musllinux` builds or compile from source. Alpine is an excellent choice *once verified*, and a latent incident when adopted for size alone.

---

## 4. Building production images

### 4.1 `.dockerignore` — correctness, not just speed

BuildKit sends the build context to the builder. Without an ignore file you ship `.git` (full history, including rotated secrets), `node_modules`, local `.env` files and CI caches — all of which also invalidate the cache on every commit.

```gitignore
# .dockerignore
*
!cmd/
!internal/
!pkg/
!go.mod
!go.sum
!requirements.txt
!worker/
```

Deny-all-then-allow is the only pattern that fails safe: a new secret file added to the repo tomorrow is excluded by default.

### 4.2 Multi-stage Containerfile — Go service on distroless

```dockerfile
# syntax=docker/dockerfile:1.7
# Containerfile — API service. Cross-compiled, static, distroless, non-root.

ARG GO_VERSION=1.22.5
ARG RUNTIME_IMAGE=gcr.io/distroless/static-debian12:nonroot

# ---------------------------------------------------------------- build stage
# --platform=$BUILDPLATFORM pins the toolchain to the builder's native arch and
# cross-compiles via GOOS/GOARCH. Emulating the toolchain under QEMU instead is
# roughly 10x slower for a multi-arch build.
FROM --platform=$BUILDPLATFORM golang:${GO_VERSION}-bookworm AS build

ARG TARGETOS
ARG TARGETARCH
ARG VERSION=dev
ARG REVISION=unknown

WORKDIR /src

# Dependency layer: invalidated only when go.mod/go.sum change.
COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod,sharing=locked \
    go mod download -x

# Source layer.
COPY cmd/ ./cmd/
COPY internal/ ./internal/
COPY pkg/ ./pkg/

# CGO_ENABLED=0        -> static binary, runnable on scratch/distroless-static
# -trimpath            -> reproducible builds: no absolute build paths embedded
# -ldflags "-s -w"     -> strip symbol table and DWARF (~30% smaller)
# -X main.version=...  -> stamp version metadata into the binary
RUN --mount=type=cache,target=/go/pkg/mod,sharing=locked \
    --mount=type=cache,target=/root/.cache/go-build,sharing=locked \
    CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} \
    go build \
      -trimpath \
      -ldflags="-s -w -X main.version=${VERSION} -X main.revision=${REVISION}" \
      -o /out/api ./cmd/api

# ----------------------------------------------------------------- test stage
# Not in the runtime path; built explicitly with --target=test in CI.
FROM build AS test
RUN --mount=type=cache,target=/go/pkg/mod,sharing=locked \
    --mount=type=cache,target=/root/.cache/go-build,sharing=locked \
    go vet ./... && go test -race -covermode=atomic -coverprofile=/out/cover.out ./...

# -------------------------------------------------------------- runtime stage
FROM ${RUNTIME_IMAGE} AS runtime

ARG VERSION=dev
ARG REVISION=unknown
ARG CREATED=1970-01-01T00:00:00Z

# OCI standard annotations: consumed by registries, scanners and policy engines.
LABEL org.opencontainers.image.title="platform-api" \
      org.opencontainers.image.description="Public HTTP API for the ordering platform" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${REVISION}" \
      org.opencontainers.image.created="${CREATED}" \
      org.opencontainers.image.source="https://git.example.com/platform/api" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.base.name="${RUNTIME_IMAGE}"

# distroless:nonroot ships uid/gid 65532 in /etc/passwd and /etc/group.
COPY --from=build --chown=65532:65532 --chmod=0555 /out/api /usr/local/bin/api

USER 65532:65532
WORKDIR /
EXPOSE 8080 9090

ENV GOMAXPROCS=0 \
    OTEL_SERVICE_NAME=platform-api \
    API_LISTEN_ADDR=":8080" \
    API_METRICS_ADDR=":9090"

# The image has no shell and no curl, so the health probe is a subcommand of the
# application binary itself. This is the correct pattern for distroless.
HEALTHCHECK --interval=10s --timeout=2s --start-period=15s --retries=3 \
  CMD ["/usr/local/bin/api", "healthcheck", "--addr", "127.0.0.1:8080"]

# Exec form only: the binary is PID 1 and receives SIGTERM directly.
ENTRYPOINT ["/usr/local/bin/api"]
CMD ["serve"]
```

### 4.3 Multi-stage Containerfile — Python worker

```dockerfile
# syntax=docker/dockerfile:1.7
# Containerfile.worker — Python worker. Wheel-only install, venv copy, non-root.

ARG PYTHON_VERSION=3.12.5

# ---------------------------------------------------------------- build stage
FROM docker.io/library/python:${PYTHON_VERSION}-slim-bookworm AS build

ENV PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_COMPILE=0 \
    PYTHONDONTWRITEBYTECODE=0

# Toolchain needed only to compile C extensions; never reaches the runtime image.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    rm -f /etc/apt/apt.conf.d/docker-clean && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        build-essential=12.9 \
        libpq-dev=15.* \
        git

WORKDIR /src
RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

COPY requirements.txt requirements.lock ./
# --require-hashes turns the lock file into a supply-chain control: a tampered
# artifact on PyPI or a compromised mirror fails the build instead of shipping.
RUN --mount=type=cache,target=/root/.cache/pip,sharing=locked \
    pip install --require-hashes --no-deps -r requirements.lock

COPY worker/ ./worker/
RUN pip install --no-deps . && python -m compileall -q /opt/venv

# -------------------------------------------------------------- runtime stage
FROM docker.io/library/python:${PYTHON_VERSION}-slim-bookworm AS runtime

ARG VERSION=dev
ARG REVISION=unknown

LABEL org.opencontainers.image.title="platform-worker" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${REVISION}" \
      org.opencontainers.image.source="https://git.example.com/platform/worker"

# Runtime shared libraries only — no compilers, no headers, no git.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    rm -f /etc/apt/apt.conf.d/docker-clean && \
    apt-get update && \
    apt-get install -y --no-install-recommends libpq5 tini && \
    rm -rf /var/lib/apt/lists/*

RUN groupadd --gid 10001 worker && \
    useradd --uid 10001 --gid 10001 --no-create-home --shell /usr/sbin/nologin worker

COPY --from=build --chown=root:root /opt/venv /opt/venv

ENV PATH="/opt/venv/bin:$PATH" \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONFAULTHANDLER=1 \
    HOME=/tmp

USER 10001:10001
WORKDIR /opt/venv

HEALTHCHECK --interval=15s --timeout=3s --start-period=20s --retries=3 \
  CMD ["python", "-m", "worker.healthcheck"]

# tini as PID 1: reaps zombies (Python multiprocessing/subprocess leave them)
# and forwards SIGTERM to the process group.
ENTRYPOINT ["/usr/bin/tini", "--", "python", "-m", "worker"]
CMD ["--queue", "default", "--concurrency", "4"]
```

### 4.4 `ENTRYPOINT` vs `CMD`, exec vs shell form

| Dockerfile | Process actually executed | PID 1 | Receives SIGTERM | `docker run img X` overrides |
|---|---|---|---|---|
| `CMD ["nginx","-g","daemon off;"]` | `nginx` | `nginx` | yes | the whole command |
| `CMD nginx -g "daemon off;"` | `/bin/sh -c 'nginx -g "daemon off;"'` | `sh` | **no** | the whole command |
| `ENTRYPOINT ["nginx"]` + `CMD ["-g","daemon off;"]` | `nginx -g daemon off;` | `nginx` | yes | only the args |
| `ENTRYPOINT nginx` (shell form) | `/bin/sh -c nginx` | `sh` | **no** | nothing (`CMD` is ignored) |
| `ENTRYPOINT ["/entrypoint.sh"]` with `exec "$@"` at the end | final binary | the binary | yes | args |

Proof of the shell-form defect:

```console
$ printf 'FROM alpine:3.20\nENTRYPOINT sleep 300\n' | docker build -q -t bad -
sha256:6c9a8e2f1b4d7a3c5e9f0b2d4a6c8e0f2b4d6a8c0e2f4b6d8a0c2e4f6b8d0a2c

$ docker run -d --name bad bad && time docker stop bad
bad
real    0m10.412s          # <-- the full grace period; SIGTERM went nowhere

$ docker inspect -f '{{.State.ExitCode}} {{.State.OOMKilled}}' bad
137 false                  # 128+9 = SIGKILL

$ printf 'FROM alpine:3.20\nENTRYPOINT ["sleep","300"]\n' | docker build -q -t good -
sha256:2f8b0d4a6c8e0f2b4d6a8c0e2f4b6d8a0c2e4f6b8d0a2c4e6f8b0d2a4c6e8f0b

$ docker run -d --name good good && time docker stop good
good
real    0m0.238s

$ docker inspect -f '{{.State.ExitCode}}' good
143                        # 128+15 = SIGTERM, handled
```

A correct wrapper entrypoint, when one is unavoidable:

```bash
#!/bin/sh
# /entrypoint.sh — must exec, so the app becomes PID 1 and inherits signals.
set -eu

: "${DATABASE_URL:?DATABASE_URL is required}"

if [ -n "${DATABASE_PASSWORD_FILE:-}" ]; then
    DATABASE_PASSWORD="$(cat "$DATABASE_PASSWORD_FILE")"
    export DATABASE_PASSWORD
fi

# exec replaces the shell: no extra process, signals reach the application.
exec "$@"
```

### 4.5 Layer cache mechanics

BuildKit keys each instruction on a cache key derived from the parent layer's digest plus the instruction. For `COPY`/`ADD`, the key includes the **content checksum** of the copied files; for `RUN`, it includes only the **command string** — not the state of the network or the upstream repository. Two consequences:

* Copy dependency manifests before source code, so a source edit does not invalidate dependency installation.
* `RUN apt-get update` alone in its own layer is a bug: the cached layer pins a package index from months ago, and the later `apt-get install` resolves against it. Always `update && install` in a single `RUN`.

```console
$ docker buildx build --target=runtime --platform=linux/amd64 \
    --build-arg VERSION=1.8.3 \
    --build-arg REVISION="$(git rev-parse HEAD)" \
    --build-arg CREATED="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    -t registry.example.com/platform/api:1.8.3 -f Containerfile .
[+] Building 41.7s (19/19) FINISHED                              docker:default
 => [internal] load build definition from Containerfile                    0.0s
 => resolve image config for docker.io/docker/dockerfile:1.7               0.6s
 => [internal] load metadata for gcr.io/distroless/static-debian12:nonroot 0.5s
 => [internal] load metadata for docker.io/library/golang:1.22.5-bookworm  0.4s
 => [internal] load .dockerignore                                          0.0s
 => [build 1/7] FROM docker.io/library/golang:1.22.5-bookworm@sha256:3f2a… 0.0s
 => CACHED [build 2/7] WORKDIR /src                                        0.0s
 => CACHED [build 3/7] COPY go.mod go.sum ./                               0.0s
 => CACHED [build 4/7] RUN --mount=type=cache,target=/go/pkg/mod go mod …  0.0s
 => [build 5/7] COPY cmd/ ./cmd/                                           0.1s
 => [build 6/7] COPY internal/ ./internal/                                 0.1s
 => [build 7/7] RUN --mount=type=cache,target=/go/pkg/mod --mount=type=c… 37.9s
 => [runtime 1/1] COPY --from=build --chown=65532:65532 --chmod=0555 /ou…  0.2s
 => exporting to image                                                     0.3s
 => => exporting layers                                                    0.2s
 => => writing image sha256:c41d8f2a90b7e3c5d6a8f0b2c4e6a8d0f2b4c6e8a0d2f…  0.0s
 => => naming to registry.example.com/platform/api:1.8.3                   0.0s
```

Rows 2–4 are `CACHED`; only the source copies and the compile re-ran, because `go.mod`/`go.sum` were unchanged. That is the ordering paying off.

```console
$ docker image ls registry.example.com/platform/api
REPOSITORY                            TAG    IMAGE ID       CREATED          SIZE
registry.example.com/platform/api     1.8.3  c41d8f2a90b7   12 seconds ago   14.2MB

$ docker history registry.example.com/platform/api:1.8.3
IMAGE          CREATED          CREATED BY                                      SIZE
c41d8f2a90b7   12 seconds ago   ENTRYPOINT ["/usr/local/bin/api"]                0B
<missing>      12 seconds ago   CMD ["serve"]                                    0B
<missing>      12 seconds ago   HEALTHCHECK &{["CMD" "/usr/local/bin/api" "he…   0B
<missing>      12 seconds ago   ENV GOMAXPROCS=0 OTEL_SERVICE_NAME=platform-a…   0B
<missing>      12 seconds ago   EXPOSE map[8080/tcp:{} 9090/tcp:{}]              0B
<missing>      12 seconds ago   USER 65532:65532                                 0B
<missing>      12 seconds ago   COPY /out/api /usr/local/bin/api # buildkit    12.1MB
<missing>      3 weeks ago      LABEL org.opencontainers.image.base.name=gcr.…   0B
<missing>      3 weeks ago      COPY /etc/passwd /etc/passwd # buildkit          1.3kB
<missing>      3 weeks ago      COPY /etc/ssl/certs /etc/ssl/certs # buildkit  2.05MB
```

14.2 MB total, one application layer, no shell, no package manager. Compare against the same binary on `debian:12-slim` (~87 MB) or built single-stage on `golang` (~1.1 GB, shipping the entire Go toolchain and the source tree to production).

### 4.6 Build secrets — the wrong way and the right way

`ARG` values and any file written in an intermediate layer are recoverable from the image or the build history. The only safe mechanism is a BuildKit secret mount, which is present during the `RUN` and absent from the layer.

```dockerfile
# syntax=docker/dockerfile:1.7
RUN --mount=type=secret,id=npmrc,target=/root/.npmrc,mode=0400 \
    npm ci --omit=dev

RUN --mount=type=ssh \
    git clone git@git.example.com:platform/private-lib.git /src/lib
```

```console
$ docker buildx build --secret id=npmrc,src=$HOME/.npmrc --ssh default -t app:1.0 .
```

Verification that nothing leaked:

```console
$ docker history --no-trunc app:1.0 | grep -ci npmrc
0
$ docker save app:1.0 | tar -xO --wildcards '*/layer.tar' 2>/dev/null \
    | tar -tv 2>/dev/null | grep -c '\.npmrc'
0
```

---

## 5. Image identity, registries and distribution

### 5.1 Tags are labels; digests are identity

| Reference form | Example | Mutable | Reproducible | Use for |
|---|---|---|---|---|
| Bare name | `nginx` | yes | no | never |
| Floating tag | `nginx:latest`, `api:main` | yes | no | local development only |
| Semver tag | `api:1.8.3` | yes (can be re-pushed) | no | human-facing release naming |
| Immutable tag policy | `api:1.8.3` on a registry with tag immutability enabled | no | yes | good compromise |
| **Digest** | `api@sha256:c41d8f…` | **no** | **yes** | deployment manifests, base images in Containerfiles, policy |
| Tag + digest | `api:1.8.3@sha256:c41d8f…` | no | yes | best: readable *and* pinned |

```console
$ docker buildx imagetools inspect registry.example.com/platform/api:1.8.3
Name:      registry.example.com/platform/api:1.8.3
MediaType: application/vnd.oci.image.index.v1+json
Digest:    sha256:9d4e2b8a1c6f3e5079b2d4a6c8e0f2b4d6a8c0e2f4b6d8a0c2e4f6b8d0a2c4e6

Manifests:
  Name:        registry.example.com/platform/api:1.8.3@sha256:c41d8f2a90b7e3c5…
  MediaType:   application/vnd.oci.image.manifest.v1+json
  Platform:    linux/amd64

  Name:        registry.example.com/platform/api:1.8.3@sha256:7b3e1a9c5d0f2b4e…
  MediaType:   application/vnd.oci.image.manifest.v1+json
  Platform:    linux/arm64

  Name:        registry.example.com/platform/api:1.8.3@sha256:e2f4b6d8a0c2e4f6…
  MediaType:   application/vnd.in-toto+json
  Platform:    unknown/unknown
  Annotations:
    vnd.docker.reference.digest: sha256:c41d8f2a90b7e3c5d6a8f0b2c4e6a8d0f2b4c6e8a…
    vnd.docker.reference.type:   attestation-manifest
```

The top-level digest is an **image index** (manifest list). Pulling `…:1.8.3` on arm64 resolves to `sha256:7b3e1a9c…` automatically. Pinning the *index* digest keeps multi-arch behaviour and immutability simultaneously — this is the correct pin for a heterogeneous fleet.

### 5.2 Multi-architecture builds

```console
$ docker buildx create --name multi --driver docker-container --bootstrap --use
[+] Building 8.4s (1/1) FINISHED
 => [internal] booting buildkit                                            8.4s
 => => pulling image moby/buildkit:buildx-stable-1                         6.9s
 => => creating container buildx_buildkit_multi0                           1.5s
multi

$ docker buildx build \
    --platform linux/amd64,linux/arm64 \
    --build-arg VERSION=1.8.3 \
    --provenance=mode=max --sbom=true \
    -t registry.example.com/platform/api:1.8.3 \
    --push -f Containerfile .
[+] Building 96.3s (34/34) FINISHED                              docker-container:multi
 => [linux/amd64 build 7/7] RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go…  38.2s
 => [linux/arm64 build 7/7] RUN CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go…  41.7s
 => exporting to image                                                      6.1s
 => => exporting manifest list sha256:9d4e2b8a1c6f3e5079b2d4a6c8e0f2b4d6a…  0.0s
 => => pushing layers                                                       5.2s
 => => pushing manifest for registry.example.com/platform/api:1.8.3@sha25…  0.7s
```

Podman/Buildah equivalent using an explicit manifest list:

```console
$ podman manifest create registry.example.com/platform/api:1.8.3
$ podman build --platform linux/amd64,linux/arm64 \
    --manifest registry.example.com/platform/api:1.8.3 -f Containerfile .
$ podman manifest push --all \
    registry.example.com/platform/api:1.8.3 \
    docker://registry.example.com/platform/api:1.8.3
```

### 5.3 Skopeo — registry operations without a daemon or a local pull

Skopeo is the right tool for promotion, mirroring and inspection because it copies blobs registry-to-registry without unpacking them locally.

```console
$ skopeo inspect docker://registry.example.com/platform/api:1.8.3 | jq '{Digest,Architecture,Labels,Layers}'
{
  "Digest": "sha256:c41d8f2a90b7e3c5d6a8f0b2c4e6a8d0f2b4c6e8a0d2f4b6c8e0a2d4f6b8c0e2",
  "Architecture": "amd64",
  "Labels": {
    "org.opencontainers.image.revision": "4c9e1f7b2a8d3e5c0f6b1a4d7c9e2f5b8a0c3e6d",
    "org.opencontainers.image.source": "https://git.example.com/platform/api",
    "org.opencontainers.image.version": "1.8.3"
  },
  "Layers": [
    "sha256:1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6f7a8b9c0d1e2f",
    "sha256:2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6f7a8b9c0d1e2f3a"
  ]
}

# Promotion staging -> production, digest-preserving, no local storage:
$ skopeo copy --all \
    docker://registry.example.com/staging/api:1.8.3 \
    docker://registry.example.com/prod/api:1.8.3
Getting image list signatures
Copying 2 images generated from 2 images in list
Copying image sha256:c41d8f2a90b7… (1/2)
Copying blob 1e2f3a4b5c6d skipped: already exists
Copying blob 2f3a4b5c6d7e done   |  12.1MiB / 12.1MiB
Writing manifest to image destination
Copying image sha256:7b3e1a9c5d0f… (2/2)
Writing manifest list to image destination
Storing list signatures

# Air-gap export/import through a directory or an OCI layout:
$ skopeo copy docker://registry.example.com/prod/api:1.8.3 \
    oci-archive:/transfer/api-1.8.3.oci.tar:api:1.8.3
$ skopeo copy oci-archive:/transfer/api-1.8.3.oci.tar:api:1.8.3 \
    docker://airgap-registry.internal:5000/platform/api:1.8.3
```

### 5.4 Registry authentication

| Engine | Credential file | Notes |
|---|---|---|
| Docker | `~/.docker/config.json` | `auths.<registry>.auth` is **base64, not encryption**. Use `credsStore`/`credHelpers`. |
| Podman/Buildah/Skopeo | `${XDG_RUNTIME_DIR}/containers/auth.json` | Session-scoped by default; `--authfile` overrides. `podman login --compat-auth-file` writes Docker's format. |

```console
$ podman login registry.example.com
Username: ci-bot
Password:
Login Succeeded!

$ cat $XDG_RUNTIME_DIR/containers/auth.json
{
	"auths": {
		"registry.example.com": {
			"auth": "Y2ktYm90OnMzY3IzdC10b2tlbg=="
		}
	}
}

$ echo Y2ktYm90OnMzY3IzdC10b2tlbg== | base64 -d
ci-bot:s3cr3t-token
```

That last command is the whole argument for credential helpers and short-lived tokens.

### 5.5 Supply chain: scan, SBOM, sign, verify

```console
$ trivy image --severity HIGH,CRITICAL --ignore-unfixed \
    registry.example.com/platform/api:1.8.3
2026-09-03T10:44:11Z  INFO  Vulnerability scanning is enabled
2026-09-03T10:44:13Z  INFO  Detected OS: debian  (distroless)
2026-09-03T10:44:13Z  INFO  Number of language-specific files: 1

registry.example.com/platform/api:1.8.3 (debian 12.6)
====================================================
Total: 0 (HIGH: 0, CRITICAL: 0)

usr/local/bin/api (gobinary)
============================
Total: 1 (HIGH: 1, CRITICAL: 0)

┌──────────────────┬────────────────┬──────────┬────────┬───────────────────┬───────────────┐
│     Library      │ Vulnerability  │ Severity │ Status │ Installed Version │ Fixed Version │
├──────────────────┼────────────────┼──────────┼────────┼───────────────────┼───────────────┤
│ golang.org/x/net │ CVE-2024-45338 │ HIGH     │ fixed  │ v0.29.0           │ 0.33.0        │
└──────────────────┴────────────────┴──────────┴────────┴───────────────────┴───────────────┘

$ syft registry.example.com/platform/api:1.8.3 -o spdx-json > api-1.8.3.sbom.spdx.json

$ cosign sign --yes registry.example.com/platform/api@sha256:9d4e2b8a1c6f3e50…
$ cosign attest --yes --predicate api-1.8.3.sbom.spdx.json --type spdxjson \
    registry.example.com/platform/api@sha256:9d4e2b8a1c6f3e50…

$ cosign verify \
    --certificate-identity-regexp '^https://git\.example\.com/platform/.+$' \
    --certificate-oidc-issuer https://token.actions.githubusercontent.com \
    registry.example.com/platform/api@sha256:9d4e2b8a1c6f3e50… | jq -r '.[0].critical.image'
{
  "docker-manifest-digest": "sha256:9d4e2b8a1c6f3e5079b2d4a6c8e0f2b4d6a8c0e2f4b6d8a0c2e4f6b8d0a2c4e6"
}
```

Podman can enforce signature policy at pull time via `/etc/containers/policy.json`:

```json
{
    "default": [{ "type": "reject" }],
    "transports": {
        "docker": {
            "registry.example.com/platform": [
                {
                    "type": "sigstoreSigned",
                    "keyPath": "/etc/pki/containers/platform-release.pub",
                    "signedIdentity": { "type": "matchRepository" }
                }
            ],
            "docker.io/library": [{ "type": "insecureAcceptAnything" }]
        }
    }
}
```

```console
$ podman pull registry.example.com/platform/api:1.8.3
Trying to pull registry.example.com/platform/api:1.8.3...
Error: Source image rejected: A signature was required, but no signature exists
```

---

## 6. Runtime configuration

### 6.1 Storage: the three mount types

| Type | Flag | Lifecycle | Host path | Performance | Correct use |
|---|---|---|---|---|---|
| **Named volume** | `-v appdata:/var/lib/app` | Independent of the container | Engine-managed (`/var/lib/docker/volumes/…`) | Native FS | Databases, any state that must survive `rm` |
| **Bind mount** | `-v /srv/conf:/etc/app:ro` | Host-owned | Explicit | Native FS | Config injection, dev source mounts, host log dirs |
| **tmpfs** | `--tmpfs /tmp:rw,noexec,nosuid,size=64m` | Dies with the container, never on disk | RAM | RAM | Scratch space, decrypted secrets, PID files under a read-only rootfs |
| Writable layer (default) | — | Dies with the container | overlay2 upper | **copy-up penalty** | Nothing that is written frequently |

```console
$ docker volume create --driver local \
    --opt type=none --opt device=/srv/pgdata --opt o=bind pgdata
pgdata

$ docker volume inspect pgdata
[
    {
        "CreatedAt": "2026-09-03T10:51:07Z",
        "Driver": "local",
        "Labels": null,
        "Mountpoint": "/var/lib/docker/volumes/pgdata/_data",
        "Name": "pgdata",
        "Options": { "device": "/srv/pgdata", "o": "bind", "type": "none" },
        "Scope": "local"
    }
]
```

**SELinux (RHEL/Fedora):** a bind mount without a label produces `Permission denied` even as root, and `ls -Z` shows why.

```console
$ podman run --rm -v /srv/conf:/etc/app:ro registry.example.com/platform/api:1.8.3
Error: open /etc/app/api.yaml: permission denied

$ ls -Z /srv/conf/api.yaml
unconfined_u:object_r:var_t:s0 /srv/conf/api.yaml

$ podman run --rm -v /srv/conf:/etc/app:ro,Z registry.example.com/platform/api:1.8.3 healthcheck
ok

$ ls -Z /srv/conf/api.yaml
system_u:object_r:container_file_t:s0:c142,c799 /srv/conf/api.yaml
```

`:z` = shared label (multiple containers may read); `:Z` = private label (exclusive, with MCS categories). **Never apply `:Z` to `/home`, `/usr` or `/etc`** — it relabels the host tree recursively and breaks the system.

Podman-only mount suffixes worth knowing: `:U` chowns the volume to the container's mapped UID (solves rootless volume permissions); `:idmap` applies an idmapped mount instead of copying ownership.

### 6.2 Networking

| Driver | Scope | IP address | Container-to-container DNS | Use when |
|---|---|---|---|---|
| `bridge` (default) | Single host | Private NAT subnet | **Only on user-defined networks**, not on `bridge` | Standard multi-container apps |
| `host` | Single host | Host's stack, no netns | N/A | Extreme packet rates; loses port isolation |
| `none` | Single host | `lo` only | N/A | Batch jobs with no network need |
| `macvlan` | Single host | Directly on the LAN, own MAC | External DNS | Legacy apps requiring an L2 presence; needs promiscuous mode |
| `ipvlan` (L2/L3) | Single host | LAN IP, shares host MAC | External DNS | Same as macvlan where the switch blocks extra MACs |
| `overlay` | Multi-host (Swarm) | VXLAN mesh | Yes | Swarm services |

The default `bridge` network deliberately has **no embedded DNS server**. Container name resolution requires a user-defined network:

```console
$ docker run -d --name db --network bridge postgres:16-alpine
$ docker run --rm --network bridge alpine:3.20 getent hosts db
$ echo $?
2                                        # <-- no resolution on the default bridge

$ docker network create --driver bridge \
    --subnet 10.89.7.0/24 --gateway 10.89.7.1 \
    --opt com.docker.network.bridge.name=br-platform platform-backend
6f2a9c1e4b8d0f3a5c7e9b1d3f5a7c9e1b3d5f7a9c1e3b5d7f9a1c3e5b7d9f1a

$ docker network connect platform-backend db
$ docker run --rm --network platform-backend alpine:3.20 getent hosts db
10.89.7.2         db

$ docker network inspect platform-backend --format '{{json .Containers}}' | jq
{
  "a1b2c3d4e5f6…": {
    "Name": "db",
    "EndpointID": "9f8e7d6c5b4a…",
    "MacAddress": "02:42:0a:59:07:02",
    "IPv4Address": "10.89.7.2/24",
    "IPv6Address": ""
  }
}
```

Podman uses **netavark** (firewall/network driver) plus **aardvark-dns** (name resolution) since 4.0:

```console
$ podman info --format '{{.Host.NetworkBackend}}'
netavark

$ podman network create --subnet 10.90.1.0/24 platform-backend
platform-backend

$ podman network inspect platform-backend | jq '.[0] | {name,driver,subnets,dns_enabled}'
{
  "name": "platform-backend",
  "driver": "bridge",
  "subnets": [{ "subnet": "10.90.1.0/24", "gateway": "10.90.1.1" }],
  "dns_enabled": true
}
```

**Publishing ports** — `-p [host_ip:]host_port:container_port[/proto]`. Binding to `0.0.0.0` (the default) exposes the service on every host interface and, on Docker, **bypasses `firewalld`/`ufw`** because Docker inserts its rules into the `DOCKER` chain ahead of the filter rules users normally edit. Bind explicitly:

```console
$ docker run -d -p 127.0.0.1:9090:9090 --name metrics registry.example.com/platform/api:1.8.3
$ ss -lntp | grep 9090
LISTEN 0  4096   127.0.0.1:9090   0.0.0.0:*   users:(("docker-proxy",pid=51204,fd=4))
```

Rootless port binding below 1024:

```console
$ podman run -d -p 443:8443 registry.example.com/platform/api:1.8.3
Error: rootlessport cannot expose privileged port 443, you can add
'net.ipv4.ip_unprivileged_port_start=443' to /etc/sysctl.conf ...

$ sudo sysctl -w net.ipv4.ip_unprivileged_port_start=443
net.ipv4.ip_unprivileged_port_start = 443
```

### 6.3 Resource limits

| Flag | cgroup v2 file | Meaning | Failure mode if unset |
|---|---|---|---|
| `--memory 512m` | `memory.max` | Hard ceiling; exceeding it triggers OOM kill inside the container | One leaking container OOMs the host |
| `--memory-reservation 384m` | `memory.high` | Soft limit; kernel throttles reclaim above it | No back-pressure before the hard kill |
| `--memory-swap 512m` | `memory.swap.max` | Total memory+swap. Equal to `--memory` ⇒ swap disabled | Latency cliff from swapping |
| `--cpus 1.5` | `cpu.max` = `150000 100000` | CFS quota per 100 ms period | Noisy neighbour saturates cores |
| `--cpu-shares 512` | `cpu.weight` | Relative weight **only under contention** | — |
| `--cpuset-cpus 4-7` | `cpuset.cpus` | Pin to specific cores | NUMA-crossing latency for pinned workloads |
| `--pids-limit 256` | `pids.max` | Max processes/threads | Fork bomb exhausts the host PID space |
| `--ulimit nofile=65535:65535` | (rlimit, not cgroup) | Open file descriptors | `too many open files` at moderate concurrency |
| `--blkio-weight 500` | `io.weight` | Relative block I/O weight | I/O starvation |
| `--shm-size 256m` | (tmpfs size) | `/dev/shm` size, default **64 MiB** | `Bus error` in Postgres/Chromium/PyTorch |

```console
$ docker run -d --name api \
    --memory 512m --memory-swap 512m --memory-reservation 384m \
    --cpus 1.5 --pids-limit 256 --shm-size 128m \
    --ulimit nofile=65535:65535 \
    registry.example.com/platform/api:1.8.3

$ docker stats --no-stream api
CONTAINER ID   NAME   CPU %    MEM USAGE / LIMIT     MEM %    NET I/O          BLOCK I/O    PIDS
d7f3a91c4e28   api    43.17%   211.4MiB / 512MiB     41.29%   38.4MB / 12.1MB  0B / 4.1kB   14
```

**Making the runtime cgroup-aware** is a separate step from setting the limit:

| Runtime | Symptom | Fix |
|---|---|---|
| Go | `GOMAXPROCS` = host core count → CFS throttling | `GOMAXPROCS` from the quota (`automaxprocs`), or set it explicitly |
| JVM (11+) | Heap = ¼ host RAM, ignoring the limit only on old JVMs | `-XX:MaxRAMPercentage=70` (container support is on by default in 11+) |
| Node.js | Old-space default from host RAM | `--max-old-space-size=<0.75 × limit MiB>` |
| Python | Thread pools sized from `os.cpu_count()` (host value) | `len(os.sched_getaffinity(0))` or an explicit env var |

### 6.4 Restart policies and logging

| Policy | Restarts on non-zero exit | Restarts on `docker stop` | Restarts on daemon/host boot | Use |
|---|---|---|---|---|
| `no` (default) | no | no | no | Batch jobs, CI steps |
| `on-failure[:5]` | yes, up to N, exponential backoff | no | yes, if it was running | Jobs that may transiently fail |
| `always` | yes | no (but restarts on daemon restart) | **yes, even if you stopped it** | Rarely correct |
| `unless-stopped` | yes | no | yes, unless stopped manually | **Default choice for services** |

| Log driver | Where it goes | Rotation | `docker logs` works | Notes |
|---|---|---|---|---|
| `json-file` | `/var/lib/docker/containers/<id>/<id>-json.log` | **only if configured** | yes | Default; unrotated it fills the disk |
| `local` | Binary, compressed | yes, by default | yes | Better default than `json-file` |
| `journald` | systemd journal | journald's rules | yes | Podman-friendly, host-integrated |
| `syslog` / `fluentd` / `gelf` | Remote collector | remote | **no** | Blocking mode can stall the container |
| `none` | discarded | — | no | Only when the app ships its own logs |

Set rotation globally — this single omission is a recurring cause of full disks:

```json
// /etc/docker/daemon.json
{
  "log-driver": "local",
  "log-opts": { "max-size": "50m", "max-file": "5", "compress": "true" },
  "default-ulimits": {
    "nofile": { "Name": "nofile", "Hard": 65535, "Soft": 65535 }
  },
  "live-restore": true,
  "userland-proxy": false,
  "no-new-privileges": true,
  "icc": false
}
```

```console
$ sudo systemctl reload docker
$ docker info --format '{{.LoggingDriver}} / live-restore={{.LiveRestoreEnabled}}'
local / live-restore=true
```

`live-restore: true` keeps containers running across a `dockerd` restart — mandatory on any host running production workloads under Docker.

### 6.5 Reference: a fully hardened `run`

```console
$ docker run -d \
    --name api \
    --restart unless-stopped \
    --user 65532:65532 \
    --read-only \
    --tmpfs /tmp:rw,noexec,nosuid,nodev,size=64m \
    --cap-drop ALL \
    --security-opt no-new-privileges:true \
    --security-opt seccomp=/etc/docker/seccomp/api.json \
    --memory 512m --memory-swap 512m --cpus 1.5 --pids-limit 256 \
    --network platform-backend \
    --publish 127.0.0.1:8080:8080 \
    --health-cmd '/usr/local/bin/api healthcheck --addr 127.0.0.1:8080' \
    --health-interval 10s --health-timeout 2s --health-retries 3 \
    --env-file /etc/platform/api.env \
    --mount type=bind,source=/etc/platform/api.yaml,target=/etc/api/api.yaml,readonly \
    --label com.example.team=platform \
    registry.example.com/platform/api@sha256:9d4e2b8a1c6f3e5079b2d4a6c8e0f2b4d6a8c0e2f4b6d8a0c2e4f6b8d0a2c4e6
d7f3a91c4e28b5f7a9c1e3b5d7f9a1c3e5b7d9f1a3c5e7b9d1f3a5c7e9b1d3f5a
```

---

## 7. Multi-container applications

### 7.1 Compose specification — complete production file

```yaml
# compose.yaml — four-service application, hardened, with explicit dependency
# ordering, resource envelopes, split networks and file-based secrets.
# Compose Specification (https://compose-spec.io); run with `docker compose`.

name: platform

x-logging: &default-logging
  driver: local
  options:
    max-size: "50m"
    max-file: "5"

x-hardening: &hardening
  security_opt:
    - no-new-privileges:true
  cap_drop:
    - ALL
  restart: unless-stopped
  logging: *default-logging

services:

  api:
    <<: *hardening
    image: registry.example.com/platform/api:1.8.3@sha256:9d4e2b8a1c6f3e5079b2d4a6c8e0f2b4d6a8c0e2f4b6d8a0c2e4f6b8d0a2c4e6
    container_name: platform-api
    user: "65532:65532"
    read_only: true
    tmpfs:
      - /tmp:rw,noexec,nosuid,nodev,size=64m
    cap_add:
      - NET_BIND_SERVICE          # only because it also serves :80 internally
    environment:
      API_LISTEN_ADDR: ":8080"
      API_METRICS_ADDR: ":9090"
      DATABASE_HOST: db
      DATABASE_PORT: "5432"
      DATABASE_NAME: platform
      DATABASE_USER: platform
      DATABASE_PASSWORD_FILE: /run/secrets/db_password
      DATABASE_SSLMODE: require
      REDIS_URL: redis://cache:6379/0
      LOG_LEVEL: ${LOG_LEVEL:-info}
      OTEL_EXPORTER_OTLP_ENDPOINT: http://otel-collector:4317
    secrets:
      - db_password
    configs:
      - source: api_config
        target: /etc/api/api.yaml
        mode: 0444
    ports:
      - target: 8080
        published: "127.0.0.1:8080"
        protocol: tcp
        mode: host
    networks:
      - frontend
      - backend
    depends_on:
      db:
        condition: service_healthy
        restart: true
      cache:
        condition: service_started
    healthcheck:
      test: ["CMD", "/usr/local/bin/api", "healthcheck", "--addr", "127.0.0.1:8080"]
      interval: 10s
      timeout: 2s
      retries: 3
      start_period: 15s
      start_interval: 2s
    stop_grace_period: 30s
    stop_signal: SIGTERM
    deploy:
      replicas: 1
      resources:
        limits:
          cpus: "1.5"
          memory: 512M
          pids: 256
        reservations:
          cpus: "0.25"
          memory: 256M
    ulimits:
      nofile:
        soft: 65535
        hard: 65535

  worker:
    <<: *hardening
    image: registry.example.com/platform/worker:1.8.3@sha256:5a7c9e1b3d5f7a9c1e3b5d7f9a1c3e5b7d9f1a3c5e7b9d1f3a5c7e9b1d3f5a7c
    container_name: platform-worker
    user: "10001:10001"
    read_only: true
    tmpfs:
      - /tmp:rw,noexec,nosuid,nodev,size=256m
    command: ["--queue", "default", "--concurrency", "8"]
    environment:
      DATABASE_HOST: db
      DATABASE_NAME: platform
      DATABASE_USER: platform
      DATABASE_PASSWORD_FILE: /run/secrets/db_password
      REDIS_URL: redis://cache:6379/0
      PYTHONFAULTHANDLER: "1"
    secrets:
      - db_password
    networks:
      - backend
    depends_on:
      db:
        condition: service_healthy
      cache:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "python", "-m", "worker.healthcheck"]
      interval: 15s
      timeout: 3s
      retries: 3
      start_period: 20s
    stop_grace_period: 60s          # drain in-flight jobs before SIGKILL
    deploy:
      replicas: 2
      resources:
        limits:
          cpus: "2.0"
          memory: 1G
        reservations:
          memory: 512M

  db:
    <<: *hardening
    image: docker.io/library/postgres:16.4-alpine@sha256:0b1c3e5a7d9f1b3d5f7a9c1e3b5d7f9a1c3e5b7d9f1a3c5e7b9d1f3a5c7e9b1d
    container_name: platform-db
    user: "70:70"                   # postgres uid/gid in the alpine image
    cap_add:
      - CHOWN
      - DAC_READ_SEARCH
      - FOWNER
      - SETGID
      - SETUID
    environment:
      POSTGRES_DB: platform
      POSTGRES_USER: platform
      POSTGRES_PASSWORD_FILE: /run/secrets/db_password
      POSTGRES_INITDB_ARGS: "--data-checksums"
      PGDATA: /var/lib/postgresql/data/pgdata
    secrets:
      - db_password
    volumes:
      - type: volume
        source: pgdata
        target: /var/lib/postgresql/data
      - type: bind
        source: ./ops/postgres/postgresql.conf
        target: /etc/postgresql/postgresql.conf
        read_only: true
    command:
      - postgres
      - -c
      - config_file=/etc/postgresql/postgresql.conf
    networks:
      - backend
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U platform -d platform -h 127.0.0.1"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 30s
    shm_size: 256mb                 # Postgres parallel query needs > 64MiB
    stop_grace_period: 120s         # allow a clean shutdown checkpoint
    deploy:
      resources:
        limits:
          cpus: "2.0"
          memory: 2G
        reservations:
          memory: 1G

  cache:
    <<: *hardening
    image: docker.io/library/redis:7.4-alpine@sha256:3e5b7d9f1a3c5e7b9d1f3a5c7e9b1d3f5a7c9e1b3d5f7a9c1e3b5d7f9a1c3e5b
    container_name: platform-cache
    user: "999:1000"
    read_only: true
    command:
      - redis-server
      - --save
      - ""
      - --appendonly
      - "no"
      - --maxmemory
      - 192mb
      - --maxmemory-policy
      - allkeys-lru
    networks:
      - backend
    healthcheck:
      test: ["CMD", "redis-cli", "-h", "127.0.0.1", "ping"]
      interval: 10s
      timeout: 2s
      retries: 3
      start_period: 5s
    deploy:
      resources:
        limits:
          cpus: "0.5"
          memory: 256M

networks:
  frontend:
    driver: bridge
    ipam:
      config:
        - subnet: 10.89.10.0/24
  backend:
    driver: bridge
    internal: true               # no route to the outside world
    ipam:
      config:
        - subnet: 10.89.11.0/24

volumes:
  pgdata:
    driver: local

secrets:
  db_password:
    file: ./secrets/db_password.txt   # mounted read-only at /run/secrets/db_password

configs:
  api_config:
    file: ./ops/api/api.yaml
```

Design points that matter and are frequently wrong:

* **`backend` is `internal: true`.** The database and the worker have no default route off-host. Only `api` sits on both networks. This is network segmentation expressed in ten characters.
* **`depends_on: condition: service_healthy`** waits for the health check to pass, not merely for the container to start. Plain `depends_on: [db]` only orders *creation* and is the reason so many stacks need retry loops.
* **Secrets are files, not environment variables.** `docker inspect` prints environment variables; `/proc/<pid>/environ` leaks them to anything that can read it; they land in crash dumps and log lines. `/run/secrets/<name>` is a tmpfs file, mode 0444, readable only inside the container.
* **`stop_grace_period` differs per service.** 30 s for the API (connection drain), 60 s for the worker (job completion), 120 s for Postgres (final checkpoint). The 10 s default truncates all three.
* **Images are pinned by digest.** The tag stays for readability.

Operating it:

```console
$ docker compose config --quiet && echo "valid"
valid

$ docker compose up -d --wait --wait-timeout 180
[+] Running 8/8
 ✔ Network platform_backend        Created                                  0.1s
 ✔ Network platform_frontend       Created                                  0.1s
 ✔ Volume  platform_pgdata         Created                                  0.0s
 ✔ Container platform-cache        Healthy                                  6.3s
 ✔ Container platform-db           Healthy                                 31.8s
 ✔ Container platform-api          Healthy                                 48.4s
 ✔ Container platform-worker-1     Healthy                                 69.2s
 ✔ Container platform-worker-2     Healthy                                 69.4s

$ docker compose ps --format table
NAME                IMAGE                                    STATUS                   PORTS
platform-api        registry.example.com/platform/api:1.8.3  Up 2 minutes (healthy)   127.0.0.1:8080->8080/tcp
platform-cache      redis:7.4-alpine                         Up 2 minutes (healthy)
platform-db         postgres:16.4-alpine                     Up 2 minutes (healthy)   5432/tcp
platform-worker-1   registry.example.com/platform/worker:…   Up 1 minute (healthy)
platform-worker-2   registry.example.com/platform/worker:…   Up 1 minute (healthy)

$ docker compose logs --since 2m --tail 5 api
platform-api  | {"ts":"2026-09-03T11:02:41Z","level":"info","msg":"listening","addr":":8080"}
platform-api  | {"ts":"2026-09-03T11:02:41Z","level":"info","msg":"db pool ready","conns":10}
platform-api  | {"ts":"2026-09-03T11:02:41Z","level":"info","msg":"redis ready","addr":"cache:6379"}

$ docker compose down --volumes --remove-orphans      # destroys pgdata — deliberate
```

### 7.2 Podman equivalents

Podman offers two paths beyond the compose shim. The pod model shares a network namespace, exactly like a Kubernetes Pod:

```console
$ podman pod create --name platform \
    --network platform-backend \
    --publish 127.0.0.1:8080:8080 \
    --share net,ipc,uts
c9e1f3b5d7f9a1c3e5b7d9f1a3c5e7b9d1f3a5c7e9b1d3f5a7c9e1b3d5f7a9c1

$ podman run -d --pod platform --name db \
    -e POSTGRES_DB=platform -e POSTGRES_USER=platform \
    --secret db_password,type=mount,target=/run/secrets/db_password \
    -e POSTGRES_PASSWORD_FILE=/run/secrets/db_password \
    -v pgdata:/var/lib/postgresql/data \
    docker.io/library/postgres:16.4-alpine

$ podman run -d --pod platform --name api \
    registry.example.com/platform/api:1.8.3

$ podman pod ps
POD ID        NAME      STATUS   CREATED         INFRA ID      # OF CONTAINERS
c9e1f3b5d7f9  platform  Running  2 minutes ago   4a6c8e0f2b4d  3

# Inside the pod, services reach each other on localhost — shared netns.
$ podman exec api /usr/local/bin/api healthcheck --addr 127.0.0.1:8080
ok
```

And the Kubernetes-YAML path, which makes the single-host definition and the cluster definition the same artifact:

```console
$ podman kube generate platform > platform-pod.yaml
$ podman kube play platform-pod.yaml
Pod:
c9e1f3b5d7f9a1c3e5b7d9f1a3c5e7b9d1f3a5c7e9b1d3f5a7c9e1b3d5f7a9c1
Containers:
  1a3c5e7b9d1f3a5c7e9b1d3f5a7c9e1b3d5f7a9c1e3b5d7f9a1c3e5b7d9f1a3c
  7e9b1d3f5a7c9e1b3d5f7a9c1e3b5d7f9a1c3e5b7d9f1a3c5e7b9d1f3a5c7e9b
```

```yaml
# platform-pod.yaml — trimmed to the parts you must be able to read/write.
# Note: `podman kube play` supports a subset of the Kubernetes Pod schema;
# the same file applies with `kubectl apply -f` in a cluster.
apiVersion: v1
kind: Pod
metadata:
  name: platform
  labels:
    app: platform
spec:
  restartPolicy: OnFailure
  securityContext:
    runAsNonRoot: true
    seccompProfile:
      type: RuntimeDefault
  volumes:
    - name: pgdata
      persistentVolumeClaim:
        claimName: pgdata
    - name: tmp
      emptyDir:
        medium: Memory
        sizeLimit: 64Mi
  containers:
    - name: api
      image: registry.example.com/platform/api:1.8.3
      imagePullPolicy: IfNotPresent
      args: ["serve"]
      ports:
        - containerPort: 8080
          hostPort: 8080
          protocol: TCP
      env:
        - name: DATABASE_HOST
          value: 127.0.0.1
        - name: DATABASE_PASSWORD_FILE
          value: /run/secrets/db_password
      volumeMounts:
        - name: tmp
          mountPath: /tmp
      securityContext:
        runAsUser: 65532
        runAsGroup: 65532
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
      resources:
        limits:
          cpu: "1500m"
          memory: 512Mi
        requests:
          cpu: "250m"
          memory: 256Mi
      livenessProbe:
        exec:
          command: ["/usr/local/bin/api", "healthcheck", "--addr", "127.0.0.1:8080"]
        initialDelaySeconds: 15
        periodSeconds: 10
        timeoutSeconds: 2
        failureThreshold: 3
    - name: db
      image: docker.io/library/postgres:16.4-alpine
      env:
        - name: POSTGRES_DB
          value: platform
        - name: POSTGRES_USER
          value: platform
        - name: PGDATA
          value: /var/lib/postgresql/data/pgdata
      volumeMounts:
        - name: pgdata
          mountPath: /var/lib/postgresql/data
      securityContext:
        runAsUser: 70
        runAsGroup: 70
        allowPrivilegeEscalation: false
      resources:
        limits:
          cpu: "2"
          memory: 2Gi
      readinessProbe:
        exec:
          command: ["pg_isready", "-U", "platform", "-h", "127.0.0.1"]
        initialDelaySeconds: 10
        periodSeconds: 10
```

---

## 8. Rootless containers, security posture and systemd integration

### 8.1 How rootless actually works

```console
$ grep "^$USER:" /etc/subuid /etc/subgid
/etc/subuid:dev:100000:65536
/etc/subgid:dev:100000:65536

$ podman unshare cat /proc/self/uid_map
         0       1000          1
         1     100000      65536
```

Reading the map: UID 0 inside the container ⇒ UID 1000 on the host (your user). UIDs 1–65536 inside ⇒ 100000–165535 on the host. A process that is "root" in the container has, on the host, the privileges of an unprivileged user with **zero** capabilities against host resources.

```console
$ podman run --rm -v $PWD/data:/data:Z alpine:3.20 sh -c 'id; touch /data/probe; ls -ln /data'
uid=0(root) gid=0(root) groups=0(root),1(bin),...
total 0
-rw-r--r--    1 0        0                0 Sep  3 11:14 probe

$ ls -ln data/
total 0
-rw-r--r--. 1 1000 1000 0 Sep  3 11:14 probe      # <-- host sees your UID, not 0
```

The classic rootless volume failure and its fix:

```console
$ podman run --rm --user 10001:10001 -v $PWD/data:/data:Z alpine:3.20 touch /data/x
touch: /data/x: Permission denied

# UID 10001 inside maps to host UID 100000+10000 = 110000, which does not own ./data.
$ podman unshare chown 10001:10001 data
$ ls -ln data/
total 0
drwxr-xr-x. 2 110000 110000 60 Sep  3 11:16 data

$ podman run --rm --user 10001:10001 -v $PWD/data:/data:Z alpine:3.20 touch /data/x
$ echo $?
0

# Or let Podman do it, at the cost of a recursive chown on every start:
$ podman run --rm --user 10001:10001 -v $PWD/data:/data:Z,U alpine:3.20 touch /data/x
```

| Aspect | Rootful (root or `docker` group) | Rootless (Podman/Docker rootless) |
|---|---|---|
| Host blast radius of a container escape | Full root | The invoking user's UID only |
| Binding ports < 1024 | Allowed | Needs the sysctl, or a reverse proxy |
| `--network host` | Full host stack | User-mode network (pasta/slirp4netns), not the host stack |
| Networking performance | Kernel bridge | pasta ≈ near-native; slirp4netns noticeably slower |
| cgroup limits | Always | cgroup v2 + systemd required |
| NFS / CIFS / fuse volumes | Works | Often restricted |
| Boot persistence | Daemon or systemd unit | `loginctl enable-linger <user>` + systemd user unit |
| Overlay storage | Kernel overlayfs | `fuse-overlayfs` on older kernels (slower); native overlay on 5.11+ with a supported kernel |

### 8.2 Quadlet — containers as first-class systemd units

Quadlet (Podman ≥ 4.4) replaces the deprecated `podman generate systemd`. You write a declarative `.container` file; `podman-system-generator` renders a real `.service` at boot.

```ini
# /etc/containers/systemd/platform-db.container
[Unit]
Description=Platform PostgreSQL 16
Wants=network-online.target
After=network-online.target

[Container]
Image=docker.io/library/postgres:16.4-alpine
ContainerName=platform-db
AutoUpdate=registry
Network=platform-backend.network
User=70:70
Environment=POSTGRES_DB=platform
Environment=POSTGRES_USER=platform
Environment=POSTGRES_PASSWORD_FILE=/run/secrets/db_password
Environment=PGDATA=/var/lib/postgresql/data/pgdata
Secret=db_password,type=mount,target=/run/secrets/db_password
Volume=platform-pgdata.volume:/var/lib/postgresql/data:Z
Volume=/etc/platform/postgresql.conf:/etc/postgresql/postgresql.conf:ro,Z
Exec=postgres -c config_file=/etc/postgresql/postgresql.conf
PodmanArgs=--shm-size=256m
HealthCmd=pg_isready -U platform -h 127.0.0.1
HealthInterval=10s
HealthTimeout=5s
HealthRetries=5
HealthStartPeriod=30s
NoNewPrivileges=true
DropCapability=ALL
AddCapability=CHOWN
AddCapability=DAC_READ_SEARCH
AddCapability=FOWNER
AddCapability=SETGID
AddCapability=SETUID
Memory=2G
PidsLimit=512

[Service]
Restart=always
RestartSec=10
TimeoutStopSec=120

[Install]
WantedBy=multi-user.target
```

```ini
# /etc/containers/systemd/platform-api.container
[Unit]
Description=Platform API
Requires=platform-db.service
After=platform-db.service

[Container]
Image=registry.example.com/platform/api:1.8.3
ContainerName=platform-api
AutoUpdate=registry
Network=platform-backend.network
PublishPort=127.0.0.1:8080:8080
User=65532:65532
ReadOnly=true
Tmpfs=/tmp:rw,noexec,nosuid,nodev,size=64m
NoNewPrivileges=true
DropCapability=ALL
SecurityLabelType=container_t
Environment=DATABASE_HOST=platform-db
Environment=DATABASE_PASSWORD_FILE=/run/secrets/db_password
Secret=db_password,type=mount,target=/run/secrets/db_password
HealthCmd=/usr/local/bin/api healthcheck --addr 127.0.0.1:8080
HealthInterval=10s
HealthStartPeriod=15s
HealthOnFailure=kill
Memory=512M
PidsLimit=256

[Service]
Restart=unless-stopped
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
```

```ini
# /etc/containers/systemd/platform-backend.network
[Network]
NetworkName=platform-backend
Subnet=10.90.1.0/24
Gateway=10.90.1.1
Internal=true
```

```ini
# /etc/containers/systemd/platform-pgdata.volume
[Volume]
VolumeName=platform-pgdata
```

```console
$ sudo podman secret create db_password /root/secrets/db_password.txt
1f3a5c7e9b1d3f5a7c9e1b3d

$ sudo systemctl daemon-reload
$ sudo systemctl start platform-api.service

$ systemctl status platform-api.service --no-pager
● platform-api.service - Platform API
     Loaded: loaded (/etc/containers/systemd/platform-api.container; generated)
     Active: active (running) since Thu 2026-09-03 11:31:04 -03; 42s ago
   Main PID: 62148 (conmon)
      Tasks: 12 (limit: 4915)
     Memory: 47.2M (max: 512.0M available: 464.7M)
        CPU: 1.284s
     CGroup: /system.slice/platform-api.service
             ├─62148 /usr/bin/conmon --api-version 1 -c d7f3a91c4e28 …
             └─container
                 └─62161 /usr/local/bin/api serve

Sep 03 11:31:04 node01 podman[62130]: Starting platform-api
Sep 03 11:31:05 node01 platform-api[62161]: {"level":"info","msg":"listening","addr":":8080"}

$ sudo journalctl -u platform-api.service -f --output=cat
{"ts":"2026-09-03T11:31:05Z","level":"info","msg":"db pool ready","conns":10}
```

Because these are ordinary units, you get `Requires=`/`After=` ordering, `systemd-analyze` dependency graphs, journald log aggregation, `Restart=` semantics and `systemctl` as the single operational interface — none of which Docker's `--restart` flag provides. `AutoUpdate=registry` plus `podman-auto-update.timer` pulls a newer digest for the same tag and rolls back automatically if the health check fails:

```console
$ sudo systemctl enable --now podman-auto-update.timer
$ sudo podman auto-update --dry-run
            UNIT                    CONTAINER              IMAGE                                     POLICY      UPDATED
            platform-api.service    d7f3a91c4e28 (api)     registry.example.com/platform/api:1.8.3   registry    pending
            platform-db.service     a1b2c3d4e5f6 (db)      docker.io/library/postgres:16.4-alpine    registry    false
```

---

## 9. Verification and failure diagnosis

### 9.1 Exit codes — read these first, always

| Exit code | Meaning | First command to run |
|---|---|---|
| `0` | Clean exit. A service exiting 0 usually means "config told it to do nothing". | `docker logs <c>` |
| `1` / `2` | Application error / usage error | `docker logs <c>` |
| `125` | **The engine itself failed** — bad flag, bad image ref, no such network | Re-read the `docker run` line |
| `126` | Command found but not executable — wrong permissions or wrong architecture | `docker run --rm --entrypoint ls img -l /path` |
| `127` | Command not found — typo, or a dynamically-linked binary on a base without its libs | `ldd`, or check the base image |
| `137` | 128+9 SIGKILL — **OOM kill or a stop that timed out** | `docker inspect -f '{{.State.OOMKilled}}'` |
| `139` | 128+11 SIGSEGV | core dump, `dmesg` |
| `143` | 128+15 SIGTERM — normal, handled shutdown | nothing; this is healthy |

```console
$ docker inspect api --format '{{.State.Status}} exit={{.State.ExitCode}} oom={{.State.OOMKilled}} err="{{.State.Error}}" restarts={{.RestartCount}}'
exited exit=137 oom=true err="" restarts=6
```

### 9.2 The core verification toolbox

| Question | Command |
|---|---|
| Full runtime state, resolved | `docker inspect <c>` / `podman inspect <c>` |
| What the engine did and when | `docker events --since 30m --filter container=<c>` |
| Live resource usage vs limits | `docker stats <c>` |
| Processes inside, with host PIDs | `docker top <c> -eo pid,ppid,user,pcpu,rss,args` |
| What changed on the writable layer | `docker diff <c>` |
| Health-check history with output | `docker inspect -f '{{json .State.Health}}' <c> \| jq` |
| Where disk went | `docker system df -v` |
| Which layers cost what | `docker history --no-trunc <img>` |
| Effective config of a compose stack | `docker compose config` |
| Cross-check ports actually listening | `ss -lntp` on the host, `ss -lntp` via `nsenter` inside |

### 9.3 Runbook — container exits immediately

```console
$ docker compose up -d api
$ docker compose ps -a api
NAME           IMAGE                    STATUS                       PORTS
platform-api   platform/api:1.8.3       Exited (1) 3 seconds ago

$ docker logs --timestamps platform-api
2026-09-03T11:44:02.118Z {"level":"fatal","msg":"config: DATABASE_URL is required"}

# Confirm what the container actually received, not what you think you set:
$ docker inspect platform-api --format '{{range .Config.Env}}{{println .}}{{end}}' | grep -i database
DATABASE_HOST=db
DATABASE_PORT=5432
# DATABASE_URL is absent -> the app wants a URL, compose supplies parts.

# Reproduce interactively, overriding the entrypoint to get a shell:
$ docker run --rm -it --entrypoint /bin/sh --network platform_backend \
    --env-file ./api.env platform/api:1.8.3
/ # env | grep -c DATABASE_URL
0
```

### 9.4 Runbook — OOMKilled

```console
$ docker inspect api --format '{{.State.OOMKilled}} {{.State.ExitCode}} {{.RestartCount}}'
true 137 6

$ dmesg -T | grep -i -A3 'killed process' | tail -8
[Thu Sep  3 11:47:31 2026] Memory cgroup out of memory: Killed process 62161 (api)
  total-vm:1284736kB, anon-rss:518912kB, file-rss:12288kB, shmem-rss:0kB,
  UID:65532 pgtables:1284kB oom_score_adj:0
[Thu Sep  3 11:47:31 2026] oom_reaper: reaped process 62161 (api), now anon-rss:0kB

$ cg=/sys/fs/cgroup/system.slice/docker-$(docker inspect -f '{{.Id}}' api).scope
$ cat $cg/memory.max $cg/memory.peak $cg/memory.events
536870912
536870912
low 0
high 0
max 1174
oom 2
oom_kill 2

$ cat $cg/memory.stat | egrep '^(anon|file|slab|sock|kernel_stack) '
anon 511705088
file 8check388608
slab 3506176
sock 1245184
kernel_stack 393216
```

`anon` ≈ 488 MiB of the 512 MiB limit is application heap, not page cache. Decide between raising the limit and fixing the leak — but first confirm the runtime is even aware of the limit:

```console
$ docker exec api /usr/local/bin/api debug runtime
GOMAXPROCS=16   # <-- host cores, under a 1.5 CPU quota
GOMEMLIMIT=off  # <-- Go GC has no idea a 512MiB ceiling exists
```

Fix: set `GOMEMLIMIT` to ~90 % of the cgroup limit and `GOMAXPROCS` to `ceil(cpu quota)`. Same class of bug for the JVM (`-XX:MaxRAMPercentage`) and Node (`--max-old-space-size`).

### 9.5 Runbook — "the healthcheck never passes"

```console
$ docker inspect api --format '{{json .State.Health}}' | jq
{
  "Status": "unhealthy",
  "FailingStreak": 9,
  "Log": [
    {
      "Start": "2026-09-03T11:52:11.402Z",
      "End": "2026-09-03T11:52:11.418Z",
      "ExitCode": 127,
      "Output": "OCI runtime exec failed: exec failed: unable to start container process: exec: \"curl\": executable file not found in $PATH"
    }
  ]
}
```

The image is distroless; `curl` does not exist. Either use a binary the image contains (the `api healthcheck` subcommand) or drop to the `:debug` variant of the base for troubleshooting only.

A second, subtler failure — health check passing on `0.0.0.0` but the app bound to a different interface:

```console
$ docker exec api /usr/local/bin/api healthcheck --addr 127.0.0.1:8080
dial tcp 127.0.0.1:8080: connect: connection refused

$ pid=$(docker inspect -f '{{.State.Pid}}' api)
$ sudo nsenter -t $pid -n ss -lntp
State  Recv-Q Send-Q  Local Address:Port  Peer Address:Port  Process
LISTEN 0      4096    10.89.11.4:8080     0.0.0.0:*          users:(("api",pid=1,fd=7))
```

The app bound to the container's own IP, not to all interfaces, so a loopback probe fails. Bind to `0.0.0.0:8080` or probe the container IP.

### 9.6 Runbook — DNS resolution fails inside the container

```console
$ docker exec api getent hosts db
$ echo $?
2

$ docker exec api cat /etc/resolv.conf
nameserver 127.0.0.11
options ndots:0

$ docker inspect api --format '{{range $k,$v := .NetworkSettings.Networks}}{{println $k}}{{end}}'
bridge

$ docker inspect db --format '{{range $k,$v := .NetworkSettings.Networks}}{{println $k}}{{end}}'
platform_backend
```

Root cause: the containers are on different networks; also, `127.0.0.11` (Docker's embedded resolver) only serves names for **user-defined** networks. Fix:

```console
$ docker network connect platform_backend api
$ docker exec api getent hosts db
10.89.11.2        db
```

Podman equivalent — verify `aardvark-dns` is running and the network has DNS enabled:

```console
$ podman network inspect platform-backend --format '{{.DNSEnabled}}'
true
$ pgrep -a aardvark-dns
71204 /usr/libexec/podman/aardvark-dns --config /run/containers/networks/aardvark-dns -p 53 run
```

### 9.7 Runbook — `no space left on device`

```console
$ docker system df -v | head -20
TYPE            TOTAL   ACTIVE  SIZE      RECLAIMABLE
Images          148     9       92.4GB    81.7GB (88%)
Containers      37      6       14.2GB    13.9GB (97%)
Local Volumes   22      4       61.8GB    47.1GB (76%)
Build Cache     412     0       38.9GB    38.9GB

$ df -h /var/lib/docker
Filesystem              Size  Used Avail Use% Mounted on
/dev/mapper/vg0-docker  200G  199G  418M 100% /var/lib/docker

$ du -sh /var/lib/docker/containers/*/*-json.log 2>/dev/null | sort -h | tail -3
2.1G  /var/lib/docker/containers/8c1d.../8c1d...-json.log
6.7G  /var/lib/docker/containers/a1b2.../a1b2...-json.log
11G   /var/lib/docker/containers/d7f3.../d7f3...-json.log
```

Unrotated `json-file` logs, exactly as predicted in §6.4. Immediate relief, then the permanent fix:

```console
$ docker builder prune --all --force
Total reclaimed space: 38.9GB

$ docker image prune --all --filter "until=168h" --force
Total reclaimed space: 74.2GB

$ docker container prune --filter "until=72h" --force
Total reclaimed space: 13.9GB

# Never run `docker volume prune` reflexively — it deletes unreferenced data volumes.
$ docker volume ls --filter dangling=true
DRIVER    VOLUME NAME
local     0f3a5c7e9b1d3f5a7c9e1b3d5f7a9c1e3b5d7f9a1c3e5b7d9f1a3c5e7b9d1f3a
```

Then set `log-opts` in `/etc/docker/daemon.json` and schedule pruning as a systemd timer rather than as a human reflex.

### 9.8 Runbook — `exec format error` / wrong architecture

```console
$ docker run --rm registry.example.com/platform/api:1.8.3
exec /usr/local/bin/api: exec format error

$ docker image inspect registry.example.com/platform/api:1.8.3 \
    --format '{{.Os}}/{{.Architecture}} {{.Variant}}'
linux/amd64

$ uname -m
aarch64
```

The image index lacks an arm64 manifest, or the pull was forced to amd64. Confirm what the registry offers:

```console
$ docker buildx imagetools inspect registry.example.com/platform/api:1.8.3 \
    --format '{{range .Manifest.Manifests}}{{.Platform.OS}}/{{.Platform.Architecture}}{{println}}{{end}}'
linux/amd64
unknown/unknown
```

Only amd64 was published. Rebuild with `--platform linux/amd64,linux/arm64` (§5.2). Emulated execution as a stopgap requires binfmt handlers:

```console
$ docker run --rm --privileged tonistiigi/binfmt --install arm64
installing: arm64 OK
{"supported":["linux/amd64","linux/arm64","linux/riscv64","linux/ppc64le","linux/s390x"]}
```

### 9.9 Runbook — build cache never hits

```console
$ docker buildx build --progress=plain -t api:dev . 2>&1 | grep -E '^#[0-9]+ (CACHED|\[)'
#8 [build 3/7] COPY . .
#9 [build 4/7] RUN go mod download
```

`COPY . .` before `RUN go mod download` means *any* file change — including a README edit — invalidates dependency download. Also check that the context is not enormous:

```console
$ docker buildx build --progress=plain . 2>&1 | grep 'transferring context'
#2 transferring context: 1.84GB 21.4s
```

1.84 GB of context means `.dockerignore` is missing or ineffective. Verify what is actually being sent:

```console
$ tar --exclude-from=<(sed 's/^!//' .dockerignore) -cf - . | wc -c
```

### 9.10 Runbook — zombie processes accumulate

```console
$ docker exec worker ps -eo pid,ppid,stat,comm | awk '$3 ~ /Z/'
   47     1 Z    ffmpeg
   52     1 Z    ffmpeg
   61     1 Z    ffmpeg

$ docker inspect worker --format '{{json .Config.Entrypoint}}'
["python","-m","worker"]
```

Python is PID 1 and does not reap orphaned children. Fix with an init: `--init` (Docker injects `tini`), `init: true` in compose, or `ENTRYPOINT ["/usr/bin/tini","--", …]` as in §4.3.

```console
$ docker run -d --init --name worker platform/worker:1.8.3
$ docker exec worker ps -eo pid,ppid,stat,comm | head -3
  PID  PPID STAT COMMAND
    1     0 Ss   docker-init
    7     1 Ssl  python
```

### 9.11 Debugging a container that has no shell

```console
$ docker exec -it api /bin/sh
OCI runtime exec failed: exec failed: unable to start container process:
exec: "/bin/sh": stat /bin/sh: no such file or directory
```

Three correct approaches, in order of preference:

```console
# 1. Attach a debug container sharing the target's namespaces (Docker 25+):
$ docker debug api
# or the portable equivalent:
$ docker run --rm -it \
    --pid=container:api --network=container:api \
    --cap-add SYS_PTRACE --security-opt seccomp=unconfined \
    nicolaka/netshoot
netshoot> ss -lntp
netshoot> tcpdump -i any -nn port 5432 -c 20
netshoot> dig +short db

# 2. Enter the namespaces from the host:
$ pid=$(docker inspect -f '{{.State.Pid}}' api)
$ sudo nsenter -t $pid -n -p -m ss -lntp

# 3. Read the container's filesystem from the host via the merged dir:
$ sudo ls -l "$(docker inspect -f '{{.GraphDriver.Data.MergedDir}}' api)/etc"
```

Podman's rootless equivalent for filesystem inspection:

```console
$ podman unshare ls -l "$(podman mount api)/etc"
$ podman unmount api
```

### 9.12 Post-build acceptance gate

Every image should pass this before it is allowed near production:

```bash
#!/usr/bin/env bash
# ops/verify-image.sh — fail the pipeline on any violated invariant.
set -euo pipefail
IMAGE="$1"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# 1. Must not run as root.
user="$(docker image inspect "$IMAGE" --format '{{.Config.User}}')"
[ -n "$user" ] && [ "$user" != "root" ] && [ "${user%%:*}" != "0" ] \
    || fail "image runs as root (Config.User='${user}')"

# 2. Must declare an exec-form entrypoint.
docker image inspect "$IMAGE" --format '{{json .Config.Entrypoint}}' \
    | grep -qv '"/bin/sh","-c"' || fail "shell-form ENTRYPOINT: signals will be lost"

# 3. Must carry provenance labels.
for label in revision source version; do
    v="$(docker image inspect "$IMAGE" \
         --format "{{index .Config.Labels \"org.opencontainers.image.${label}\"}}")"
    [ -n "$v" ] || fail "missing label org.opencontainers.image.${label}"
done

# 4. Must declare a health check.
docker image inspect "$IMAGE" --format '{{json .Config.Healthcheck}}' \
    | grep -q 'Test' || fail "no HEALTHCHECK declared"

# 5. Must have no fixable HIGH/CRITICAL vulnerabilities.
trivy image --quiet --exit-code 1 --severity HIGH,CRITICAL --ignore-unfixed "$IMAGE" \
    || fail "fixable HIGH/CRITICAL vulnerabilities present"

# 6. Must not ship a package manager or a compiler in the runtime layer.
if docker run --rm --entrypoint /bin/sh "$IMAGE" -c \
     'command -v apt-get apk dnf yum gcc 2>/dev/null' 2>/dev/null | grep -q .; then
    fail "package manager or compiler present in the runtime image"
fi

# 7. Must actually start and become healthy.
cid="$(docker run -d --rm "$IMAGE")"
trap 'docker rm -f "$cid" >/dev/null 2>&1 || true' EXIT
for _ in $(seq 1 30); do
    st="$(docker inspect -f '{{.State.Health.Status}}' "$cid" 2>/dev/null || echo starting)"
    [ "$st" = "healthy" ] && { printf 'OK: %s\n' "$IMAGE"; exit 0; }
    sleep 2
done
docker logs "$cid" >&2
fail "container never became healthy within 60s"
```

```console
$ ops/verify-image.sh registry.example.com/platform/api:1.8.3
OK: registry.example.com/platform/api:1.8.3

$ ops/verify-image.sh registry.example.com/legacy/billing:3.2.0
FAIL: image runs as root (Config.User='')
```

### 9.13 Command reference

| Task | Docker | Podman |
|---|---|---|
| Build | `docker buildx build -t X .` | `podman build -t X .` |
| Run detached | `docker run -d --name c X` | `podman run -d --name c X` |
| Shell into | `docker exec -it c sh` | `podman exec -it c sh` |
| Logs, follow | `docker logs -f --since 10m c` | `podman logs -f --since 10m c` |
| Full state | `docker inspect c` | `podman inspect c` |
| Live metrics | `docker stats c` | `podman stats c` |
| Processes | `docker top c` | `podman top c` |
| FS changes | `docker diff c` | `podman diff c` |
| Copy files | `docker cp c:/p ./p` | `podman cp c:/p ./p` |
| Engine events | `docker events --since 1h` | `podman events --since 1h` |
| Push / pull | `docker push X` | `podman push X` |
| Registry inspect (no pull) | `docker buildx imagetools inspect X` | `skopeo inspect docker://X` |
| Save / load | `docker save X -o x.tar` | `podman save --format oci-archive X -o x.tar` |
| Multi-container | `docker compose up -d` | `podman kube play f.yaml` / `podman-compose` |
| Disk usage | `docker system df -v` | `podman system df -v` |
| Reclaim | `docker system prune -a` | `podman system prune -a` |
| Autostart on boot | `--restart unless-stopped` | Quadlet `.container` unit |
| Generate K8s YAML | — | `podman kube generate c` |

---

## References

Official specifications and standards:

- OCI Image Format Specification — https://github.com/opencontainers/image-spec/blob/main/spec.md
- OCI Runtime Specification — https://github.com/opencontainers/runtime-spec/blob/main/spec.md
- OCI Distribution Specification — https://github.com/opencontainers/distribution-spec/blob/main/spec.md
- OCI pre-defined annotation keys — https://github.com/opencontainers/image-spec/blob/main/annotations.md
- The Compose Specification — https://github.com/compose-spec/compose-spec/blob/main/spec.md

Certification objectives:

- LPI DevOps Tools Engineer, Exam 701 objectives — https://www.lpi.org/our-certifications/exam-701-objectives/

Docker:

- Dockerfile reference — https://docs.docker.com/reference/dockerfile/
- Multi-stage builds — https://docs.docker.com/build/building/multi-stage/
- BuildKit build mounts (`cache`, `secret`, `ssh`) — https://docs.docker.com/reference/dockerfile/#run---mount
- Building multi-platform images — https://docs.docker.com/build/building/multi-platform/
- Runtime resource constraints — https://docs.docker.com/engine/containers/resource_constraints/
- Networking overview and drivers — https://docs.docker.com/engine/network/
- Manage data: volumes, bind mounts, tmpfs — https://docs.docker.com/engine/storage/
- Configure logging drivers — https://docs.docker.com/engine/logging/configure/
- Container security options (`--security-opt`, seccomp, capabilities) — https://docs.docker.com/engine/security/
- Rootless mode — https://docs.docker.com/engine/security/rootless/
- Daemon configuration file — https://docs.docker.com/reference/cli/dockerd/#daemon-configuration-file
- `docker compose` CLI reference — https://docs.docker.com/reference/cli/docker/compose/

Podman, Buildah, Skopeo:

- Podman documentation index — https://docs.podman.io/en/latest/
- `podman run` manual — https://docs.podman.io/en/latest/markdown/podman-run.1.html
- Quadlet — `podman-systemd.unit(5)` — https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html
- `podman kube play` — https://docs.podman.io/en/latest/markdown/podman-kube-play.1.html
- `podman auto-update` — https://docs.podman.io/en/latest/markdown/podman-auto-update.1.html
- Rootless containers tutorial — https://github.com/containers/podman/blob/main/docs/tutorials/rootless_tutorial.md
- Buildah — https://buildah.io/
- Skopeo — https://github.com/containers/skopeo/blob/main/docs/skopeo.1.md
- `containers-policy.json(5)` (signature enforcement) — https://github.com/containers/image/blob/main/docs/containers-policy.json.5.md
- Netavark and Aardvark-dns — https://github.com/containers/netavark

Kernel and runtime primitives:

- `namespaces(7)` — https://man7.org/linux/man-pages/man7/namespaces.7.html
- `user_namespaces(7)` — https://man7.org/linux/man-pages/man7/user_namespaces.7.html
- `capabilities(7)` — https://man7.org/linux/man-pages/man7/capabilities.7.html
- `cgroups(7)` — https://man7.org/linux/man-pages/man7/cgroups.7.html
- Linux cgroup v2 kernel documentation — https://docs.kernel.org/admin-guide/cgroup-v2.html
- OverlayFS kernel documentation — https://docs.kernel.org/filesystems/overlayfs.html
- `seccomp(2)` — https://man7.org/linux/man-pages/man2/seccomp.2.html
- runc — https://github.com/opencontainers/runc
- crun — https://github.com/containers/crun
- containerd — https://containerd.io/docs/

Supply chain and images:

- Distroless container images — https://github.com/GoogleContainerTools/distroless
- Red Hat Universal Base Image — https://catalog.redhat.com/software/base-images
- Trivy — https://trivy.dev/latest/docs/
- Syft (SBOM) — https://github.com/anchore/syft
- Sigstore Cosign — https://docs.sigstore.dev/cosign/signing/overview/
- SLSA provenance levels — https://slsa.dev/spec/v1.0/levels