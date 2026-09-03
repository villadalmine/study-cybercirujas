# 702.3 — Container Image Building

**Certification:** LPI DevOps Tools Engineer · **Exam:** 701-100 · **Syllabus version:** 2.0.0
**Objective weight:** 8.33 — one of the heaviest single objectives in the exam. Expect questions on `Dockerfile`/`Containerfile` semantics, multi-stage builds, build-time caching, daemonless/rootless builders, registry interaction and image metadata.

**Coverage map (original summary of the objective, attributed to the published exam objectives — see *References*):**

| Area | What you must be able to do |
|---|---|
| Build files | Author and reason about `Dockerfile` / `Containerfile` instructions and their exact runtime semantics |
| Build execution | Build images with `docker build` / BuildKit, `podman build`, `buildah`, and understand daemonless alternatives |
| Layers & cache | Explain layer creation, content addressing, cache key derivation, cache invalidation and `.dockerignore` |
| Multi-stage | Split build-time from run-time dependencies; select and target stages |
| Registries | Tag, push, pull, authenticate; understand tags vs digests and manifest lists |
| Image model | Understand the OCI image specification: index, manifest, config, layers, annotations |
| Alternative builders | Awareness of Cloud Native Buildpacks, Kaniko, `ko`, Jib and their trade-offs |
| Hardening | Minimal base images, non-root users, build secrets, SBOM/provenance, reproducibility |

---

## 1. The production problem: the image is an ABI, not an archive

A container image is not "a zip of my app". It is the **binary interface** between the software-engineering organisation and the runtime platform. Everything downstream — Kubernetes admission, the scheduler's image locality decisions, the CVE scanner, the audit trail, the rollback procedure — takes the image digest as its primary key. Four production failure modes follow directly from getting the build wrong.

### 1.1 Non-reproducibility destroys incident response

At 03:00, `api:2.7.0` is crash-looping. You rebuild from tag `v2.7.0` on the build node and the bug is gone. The image that is running was built six weeks ago from a `FROM python:3.12` that resolved to a different base digest, pulled `requests` from an unpinned range, and baked in a `pip` index snapshot that no longer exists. You cannot reproduce the artifact you are debugging, so you cannot bisect it. **Reproducibility is not an aesthetic concern; it is the precondition for differential diagnosis.**

### 1.2 Size is a fleet-wide latency and cost multiplier

Image size is paid on every cold pull: node scale-out, node replacement, DaemonSet rollout, spot reclamation, cluster autoscaler churn.

| Image | Compressed size | Pull @ 300 Mb/s | 200-node scale-out (serialised at registry) | Monthly registry egress @ 40k pulls |
|---|---:|---:|---:|---:|
| `ubuntu:24.04` + Python + build toolchain | 1.18 GB | ~31 s | ~236 GB | ~47 TB |
| `python:3.12-slim` runtime only | 148 MB | ~4 s | ~29 GB | ~5.9 TB |
| `gcr.io/distroless/python3-debian12` | 52 MB | ~1.4 s | ~10 GB | ~2.1 TB |
| Go static on `scratch` | 8.4 MB | ~0.2 s | ~1.7 GB | ~336 GB |

The 31 s pull is not merely slow — it is added to your p99 recovery time on every node failure, and it is the difference between an HPA that absorbs a traffic spike and one that does not.

### 1.3 Every build-time package is a permanent runtime attack surface

`gcc`, `curl`, `git`, `make`, `apt`, a shell, a package manager, and the SSH key you used to fetch a private module are all *still in the image* unless you deliberately excluded them — and a `RUN rm -rf` in a later layer does **not** remove them, it only whites them out. The blob is still in the registry, still pullable, still greppable.

### 1.4 The build node is the softest target in the whole pipeline

The classical CI pattern — mount `/var/run/docker.sock` into the build container — grants the build **root on the node**, because the daemon runs as root and the build job can now start a privileged container with `hostPID` and `/` mounted. Any untrusted `Dockerfile`, any compromised dependency executed during `RUN`, and the attacker owns the CI fleet and every registry credential on it. This is why the objective covers daemonless builders (Buildah, Kaniko, rootless BuildKit) and why "how do I build images inside Kubernetes without `privileged: true`" is a real architectural question, treated in §8.

---

## 2. What you are actually producing: the OCI image model

Before the syntax, the artifact. An OCI image is a **content-addressed Merkle DAG** stored in a registry.

```
index (manifest list)            ← optional; one per multi-arch image
 ├── manifest (linux/amd64)
 │    ├── config  (JSON: env, entrypoint, user, labels, rootfs.diff_ids, history)
 │    └── layers  [blob, blob, blob]   ← gzipped tar archives, ordered
 ├── manifest (linux/arm64)
 └── manifest (unknown/unknown)  ← attestations (SBOM, provenance) when built with buildx
```

Two hashes are constantly confused and the exam likes the distinction:

| Term | Hash of | Where it appears |
|---|---|---|
| **`digest`** | the **compressed** blob as stored in the registry | manifest `layers[].digest`, `image@sha256:...` |
| **`diff_id`** | the **uncompressed** tar of the same layer | image config `rootfs.diff_ids[]` |
| **`chain_id`** | cumulative hash of diff_ids up to layer *n* | the runtime's local snapshot key |

Inspect a real image without pulling it:

```
$ skopeo inspect --raw docker://registry.example.com/platform/api:2.7.0 | jq .
{
  "schemaVersion": 2,
  "mediaType": "application/vnd.oci.image.index.v1+json",
  "manifests": [
    {
      "mediaType": "application/vnd.oci.image.manifest.v1+json",
      "digest": "sha256:2b7e5a1c9f0a4d6b8e3c1f7a2d94b6e0c5a8f31d47b2e9c60a1f3d8b7c4e2059",
      "size": 1214,
      "platform": { "architecture": "amd64", "os": "linux" }
    },
    {
      "mediaType": "application/vnd.oci.image.manifest.v1+json",
      "digest": "sha256:c4a1f83b2d7e05c9a6b41f2e8d30c75a9e1b4d6f8027c3a5e9d1b7f04c68a23e",
      "size": 1214,
      "platform": { "architecture": "arm64", "os": "linux" }
    },
    {
      "mediaType": "application/vnd.oci.image.manifest.v1+json",
      "digest": "sha256:7d90b1e4c8a2f36d05b9e7c1a4f82d6039b5e8c7a1d4f60b2e9c3a8d5f741062",
      "size": 840,
      "annotations": {
        "vnd.docker.reference.digest": "sha256:2b7e5a1c9f0a4d6b8e3c1f7a2d94b6e0c5a8f31d47b2e9c60a1f3d8b7c4e2059",
        "vnd.docker.reference.type": "attestation-manifest"
      },
      "platform": { "architecture": "unknown", "os": "unknown" }
    }
  ]
}
```

And the config — this is what `ENV`, `USER`, `ENTRYPOINT`, `LABEL`, `WORKDIR`, `EXPOSE` and `HEALTHCHECK` compile down to:

```
$ crane config registry.example.com/platform/api:2.7.0 | jq '{config, rootfs, history: (.history|length)}'
{
  "config": {
    "User": "10001:10001",
    "Env": [
      "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
      "PYTHONDONTWRITEBYTECODE=1",
      "PYTHONUNBUFFERED=1",
      "APP_HOME=/app"
    ],
    "Entrypoint": ["/app/.venv/bin/python", "-m", "uvicorn"],
    "Cmd": ["api.main:app", "--host", "0.0.0.0", "--port", "8080"],
    "WorkingDir": "/app",
    "ExposedPorts": { "8080/tcp": {} },
    "Labels": {
      "org.opencontainers.image.revision": "9f3ac21b7d0e4c58a6b1f2e39d47c80512ab6e3f",
      "org.opencontainers.image.source": "https://github.com/example/api",
      "org.opencontainers.image.version": "2.7.0"
    },
    "StopSignal": "SIGTERM"
  },
  "rootfs": {
    "type": "layers",
    "diff_ids": [
      "sha256:8a1f2c0d9b74e35a6c8f01d3b29e7a45c6d80f1b3e2a49c7d5b0f836a1e94c72",
      "sha256:d40c7b1e93a852f6c0b4d17e2a693f8c15d0b7e4a92c36f8d1b05e7a4c39ف..."
    ]
  },
  "history": 11
}
```

**Key consequence:** an image is immutable and identified by digest. A *tag* is a mutable pointer. Everything in §13 follows from that.

---

## 3. The instruction set, with production semantics

Use the syntax directive on line 1 so the build uses a pinned, feature-complete frontend regardless of the local Docker version:

```dockerfile
# syntax=docker/dockerfile:1.7
```

### 3.1 Which instructions create layers

| Instruction | Creates a filesystem layer | Notes that bite in production |
|---|---|---|
| `FROM` | inherits layers | `FROM x AS name` names a stage; `ARG` before the first `FROM` is global |
| `RUN` | **yes** | The single largest source of bloat and cache invalidation |
| `COPY` / `ADD` | **yes** | `ADD` auto-extracts local tars and can fetch URLs/git refs; prefer `COPY` |
| `WORKDIR` | yes (creates dir) | Metadata + `mkdir -p`; always use absolute paths |
| `ENV` | no (metadata) | Persists into the **running container**; leaks into `docker inspect` |
| `ARG` | no (metadata) | Build-time only, **but visible in `docker history`** for `RUN` lines |
| `LABEL`, `EXPOSE`, `USER`, `VOLUME`, `ENTRYPOINT`, `CMD`, `HEALTHCHECK`, `STOPSIGNAL`, `SHELL`, `ONBUILD` | no | Pure config-object mutations |

With BuildKit, metadata-only instructions are effectively free and are *not* separate blobs; the layer count you see in `docker history` includes zero-byte metadata entries.

### 3.2 `ENTRYPOINT` / `CMD`: the matrix that decides whether SIGTERM works

```dockerfile
ENTRYPOINT ["/app/server"]        # exec form  → PID 1 is /app/server
ENTRYPOINT /app/server            # shell form → PID 1 is /bin/sh -c, signals are swallowed
```

| `ENTRYPOINT` | `CMD` | Executed |
|---|---|---|
| absent | `["nginx","-g","daemon off;"]` | `nginx -g daemon off;` |
| `["/app/server"]` | `["--config","/etc/app.yaml"]` | `/app/server --config /etc/app.yaml` |
| `["/app/server"]` | absent | `/app/server` |
| shell form `/app/server` | anything | `/bin/sh -c "/app/server"` — **`CMD` is ignored** |

**Why it matters:** in shell form, `/bin/sh` is PID 1. `sh` does not forward `SIGTERM` to its child and does not reap zombies. Kubernetes sends `SIGTERM`, nothing happens, and 30 s later `terminationGracePeriodSeconds` expires and the pod is `SIGKILL`ed mid-request. Symptom: 502s on every rollout. Rule: **`ENTRYPOINT` in exec form, always**; add `tini` (`ENTRYPOINT ["/sbin/tini","--","/app/server"]`) only when your process genuinely forks children it will not reap.

### 3.3 `ARG` vs `ENV` scoping — a top-three exam trap

```dockerfile
# syntax=docker/dockerfile:1.7
ARG PY_VERSION=3.12                  # global scope: usable in FROM lines only

FROM python:${PY_VERSION}-slim AS base
ARG PY_VERSION                       # MUST be re-declared to be visible inside the stage
RUN echo "building on ${PY_VERSION}" # without the redeclaration this prints "building on "

ARG BUILD_MODE=release               # stage-scoped, not present at runtime
ENV APP_MODE=${BUILD_MODE}           # promoted to runtime config
```

Predefined build args, available in every stage without declaration when using BuildKit/buildx:

`TARGETPLATFORM` `TARGETOS` `TARGETARCH` `TARGETVARIANT` `BUILDPLATFORM` `BUILDOS` `BUILDARCH` `BUILDVARIANT`, plus proxy args (`HTTP_PROXY`, `NO_PROXY`, …) which are **excluded from the cache key and from `docker history`**.

### 3.4 `COPY` flags worth knowing

```dockerfile
COPY --chown=10001:10001 --chmod=0550 ./bin/server /app/server
COPY --from=builder /src/dist /app/dist        # from another stage
COPY --from=ghcr.io/aquasecurity/trivy:0.55.0 /usr/local/bin/trivy /usr/local/bin/
COPY --link ./static /app/static               # layer is built independently of its parent
```

`--link` is the highest-leverage and least-known flag: the layer is created with no dependency on the previous filesystem state, so changing an earlier layer **does not invalidate it** and the layer can be reused across images. Cost: the destination path's parent directories are created with default ownership, so combine with `--chown`.

---

## 4. Layer cache mechanics and the ordering theorem

BuildKit computes a **cache key** per build step:

- `RUN`: hash of (parent step's cache key + the literal command string + values of referenced `ARG`s + mount definitions).
- `COPY`/`ADD`: hash of (parent key + the **content checksum** of every file copied + destination + flags).

Therefore: **the first instruction whose inputs change invalidates that step and every step after it.** The ordering theorem follows — order instructions from least to most frequently changing.

The canonical mistake and its fix:

```dockerfile
# ✗ every source edit re-runs the 90-second dependency install
COPY . /app
RUN pip install -r /app/requirements.txt

# ✓ dependency layer is keyed only on the lockfile
COPY requirements.txt /app/
RUN pip install -r /app/requirements.txt
COPY . /app
```

### 4.1 `.dockerignore` — correctness, not just speed

```gitignore
# .dockerignore
.git
.github
**/__pycache__
**/*.pyc
.venv
node_modules
.env
*.pem
*.key
secrets/
dist/
.pytest_cache
.mypy_cache
Dockerfile*
docker-compose*.yml
README.md
```

Three separate effects: (1) the context transfer shrinks — a 900 MB `.git` no longer streams to the builder on every build; (2) `COPY . .` stops embedding credentials; (3) the `COPY . .` cache key stops changing every time a `.pyc` is regenerated. **Caveat:** if your build derives a version from `git describe`, excluding `.git` breaks it — pass the value as `--build-arg` instead of re-including the repository.

### 4.2 Cache backends — choosing one for CI

| Backend | Export syntax | Survives ephemeral runners | Shareable across runners | Caveats |
|---|---|---|---|---|
| `inline` | `--cache-to type=inline` | yes (rides in the image) | yes | Metadata only; no multi-stage intermediate layers |
| `registry` | `--cache-to type=registry,ref=repo/cache,mode=max` | yes | yes | `mode=max` stores all stages; needs registry quota + GC |
| `gha` | `--cache-to type=gha,mode=max` | yes | within a repo | 10 GB cap per repo, LRU-evicted |
| `s3` / `azblob` | `--cache-to type=s3,region=…,bucket=…` | yes | yes | Best for self-hosted fleets; needs lifecycle rules |
| `local` | `--cache-to type=local,dest=/cache` | only with a persistent volume | no | Grows unbounded without `mode` + pruning |

```
$ docker buildx build \
    --cache-from type=registry,ref=registry.example.com/platform/api/cache \
    --cache-to   type=registry,ref=registry.example.com/platform/api/cache,mode=max \
    --tag registry.example.com/platform/api:2.7.0 --push .
```

### 4.3 Cache mounts: the cache that never enters the image

```dockerfile
RUN --mount=type=cache,target=/root/.cache/pip,sharing=locked \
    pip install --require-hashes -r requirements.txt
```

`sharing=locked` serialises concurrent builds on the same mount (correct for package managers that are not concurrency-safe); `shared` (default) allows parallel access; `private` gives each build its own copy. The mount exists **only during that `RUN`** and is never committed to a layer.

---

## 5. Multi-stage builds

### 5.1 Go service → `scratch`, static, 8 MB, non-root

```dockerfile
# syntax=docker/dockerfile:1.7
ARG GO_VERSION=1.23
ARG ALPINE_VERSION=3.20

FROM --platform=$BUILDPLATFORM golang:${GO_VERSION}-alpine${ALPINE_VERSION} AS builder
WORKDIR /src

RUN apk add --no-cache ca-certificates tzdata git

COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod \
    go mod download -x

COPY . .

ARG TARGETOS
ARG TARGETARCH
ARG VERSION=dev
ARG REVISION=unknown
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} \
    go build \
      -trimpath \
      -buildvcs=false \
      -ldflags="-s -w -X main.version=${VERSION} -X main.revision=${REVISION}" \
      -o /out/server ./cmd/server

FROM builder AS test
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    go vet ./... && go test -race -count=1 ./...

FROM scratch AS runtime
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY --from=builder /usr/share/zoneinfo /usr/share/zoneinfo
COPY --from=builder --chown=10001:10001 --chmod=0555 /out/server /server

USER 10001:10001
ENV TZ=UTC
EXPOSE 8080
STOPSIGNAL SIGTERM
ENTRYPOINT ["/server"]
CMD ["--listen=:8080"]

LABEL org.opencontainers.image.title="platform-api" \
      org.opencontainers.image.source="https://github.com/example/api" \
      org.opencontainers.image.licenses="Apache-2.0"
```

Three details that separate this from a tutorial `Dockerfile`:

- `--platform=$BUILDPLATFORM` on the builder stage pins the *compiler* to the native architecture and cross-compiles via `GOARCH`. Without it, an `arm64` build on an `amd64` runner runs the whole Go toolchain under QEMU emulation — typically **5–20× slower**.
- `CGO_ENABLED=0` is mandatory for `scratch`: with cgo, the binary dynamically links `libc` and the Go resolver, and you get `exec /server: no such file or directory` at runtime (see §16).
- On `scratch` there is no `/etc/passwd`, so `USER 10001:10001` must be numeric. A name would fail to resolve.

Build only the test stage in CI without producing an image:

```
$ docker buildx build --target test --progress=plain .
#12 [test 2/2] RUN go vet ./... && go test -race -count=1 ./...
#12 0.412 ok      github.com/example/api/internal/handler 0.183s
#12 1.904 ok      github.com/example/api/internal/store   1.402s
#12 DONE 2.1s
```

### 5.2 Python service → `python:3.12-slim`, virtualenv carried across stages

```dockerfile
# syntax=docker/dockerfile:1.7
ARG PY_VERSION=3.12
ARG BASE_DIGEST=sha256:2f8c1e94b0d7a35f6c1b804e2d9a37fb50c6e8143d7b09a2e6c5f1d38b70a49e

FROM python:${PY_VERSION}-slim@${BASE_DIGEST} AS base
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=0 \
    VIRTUAL_ENV=/app/.venv \
    PATH="/app/.venv/bin:$PATH"

FROM base AS builder
RUN apt-get update \
 && apt-get install --no-install-recommends -y build-essential libpq-dev \
 && rm -rf /var/lib/apt/lists/*

RUN python -m venv "$VIRTUAL_ENV"
WORKDIR /app

COPY requirements.txt requirements.lock ./
RUN --mount=type=cache,target=/root/.cache/pip,sharing=locked \
    --mount=type=secret,id=pip_extra_index,env=PIP_EXTRA_INDEX_URL \
    pip install --require-hashes -r requirements.lock

COPY . /app
RUN python -m compileall -q /app/api

FROM base AS runtime
RUN apt-get update \
 && apt-get install --no-install-recommends -y libpq5 \
 && rm -rf /var/lib/apt/lists/* \
 && groupadd --gid 10001 app \
 && useradd --uid 10001 --gid 10001 --home-dir /app --no-create-home --shell /usr/sbin/nologin app

WORKDIR /app
COPY --from=builder --chown=10001:10001 /app/.venv /app/.venv
COPY --from=builder --chown=10001:10001 /app/api  /app/api

USER 10001:10001
EXPOSE 8080
STOPSIGNAL SIGTERM
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD ["/app/.venv/bin/python", "-c", "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8080/healthz', timeout=2).status==200 else 1)"]
ENTRYPOINT ["/app/.venv/bin/python", "-m", "uvicorn"]
CMD ["api.main:app", "--host", "0.0.0.0", "--port", "8080", "--no-access-log"]
```

`build-essential` and `libpq-dev` (≈ 420 MB) exist only in `builder`; `runtime` keeps `libpq5` (≈ 1 MB). Note the `HEALTHCHECK` in exec form — Kubernetes ignores image `HEALTHCHECK`s (it uses probes), but Docker, Compose and Nomad honour them, and `docker inspect --format '{{.State.Health.Status}}'` is a legitimate exam answer.

### 5.3 The build graph is parallel

BuildKit resolves stages as a DAG and executes independent branches concurrently:

```
$ docker buildx build --progress=plain -t app:ci .
#7  [frontend 3/4] RUN npm ci --omit=dev        ...  DONE 22.4s
#9  [backend  3/4] RUN go build -o /out/server  ...  DONE 19.8s   ← ran in parallel with #7
#12 [runtime  4/6] COPY --from=frontend /ui/dist /app/static  DONE 0.3s
```

Wall-clock is the longest path, not the sum of the stages. This is a real reason to prefer BuildKit over the legacy builder for monorepos.

---

## 6. Base image selection

| Base | Typical size | libc | Shell / pkg mgr | Non-root default | Best for | Main risk |
|---|---:|---|---|---|---|---|
| `scratch` | 0 B | none | none | you set it | Static Go/Rust | No CA certs, no `/etc/passwd`, no TZ data, no `nsswitch` |
| `gcr.io/distroless/static-debian12:nonroot` | ~2 MB | none | none | **yes (65532)** | Static binaries with certs+TZ included | Cannot `exec` in for debugging (use `:debug` tag) |
| `gcr.io/distroless/cc-debian12` | ~22 MB | glibc | none | optional tag | cgo, Rust with `libgcc` | No shell for probes |
| `cgr.dev/chainguard/static` (Wolfi) | ~2 MB | none | none | yes | Low-CVE posture, daily rebuilds | Fast-moving tags; pin digests |
| `alpine:3.20` | ~7.8 MB | **musl** | `ash` + `apk` | no | Small ops images | musl ≠ glibc — see below |
| `debian:12-slim` | ~29 MB | glibc | `bash` + `apt` | no | Anything glibc | Needs manual slimming |
| `python:3.12-slim` | ~48 MB base | glibc | yes | no | Python services | Ships pip/setuptools into runtime |
| `registry.access.redhat.com/ubi9/ubi-micro` | ~12 MB | glibc | none (install from host `dnf --installroot`) | no | RHEL-supported estates | Requires UBI subscription mechanics for full repos |

**The musl trap, concretely.** Alpine uses musl, not glibc. Consequences you will meet in production:

- Python wheels are built `manylinux` (glibc); on Alpine `pip` falls back to compiling from source, so a 20-second install becomes a 12-minute one — and it needs `gcc`, which then has to be purged.
- Any vendor binary linked against glibc fails with `Error loading shared library libc.musl-x86_64.so.1` or `not found` from `ldd`.
- musl's resolver historically differs from glibc's on search-domain handling and TCP fallback for >512-byte responses — the classic "DNS is flaky only in the Alpine pods" incident.

Alpine is an excellent base for a static binary or an ops toolbox. It is a poor default for a Python or Node service with native extensions.

---

## 7. Builder comparison

| Builder | Daemon | Root required | Rootless | `Dockerfile` compatible | Native multi-arch | Cache | Where it fits |
|---|---|---|---|---|---|---|---|
| `docker build` (BuildKit) | dockerd | daemon runs as root | with rootless Docker | yes | via buildx | best-in-class | Developer workstations |
| `docker buildx` (`docker-container` driver) | buildkitd container | no (rootless image) | yes | yes | **yes** (QEMU or node pool) | registry/gha/s3/local | CI, multi-arch release builds |
| `buildctl` + remote buildkitd | shared buildkitd | no | yes | yes | yes | shared across all CI jobs | Central build service in K8s |
| `podman build` / `buildah bud` | **none** | no | **yes** (user namespaces) | yes | via `--platform` + qemu-user-static | layer cache with `--layers` | Fedora/RHEL hosts, rootless CI |
| `buildah` script mode | none | no | yes | n/a (shell script) | yes | manual | Builds that don't fit the `Dockerfile` model |
| **Kaniko** | none | root **inside** the container | no (needs root in-container) | yes | one arch per run | `--cache-repo` | Kubernetes Jobs, no privileged |
| **Cloud Native Buildpacks** (`pack`) | Docker or `--trust-builder` | depends on driver | with a rootless driver | **no Dockerfile at all** | builder-dependent | lifecycle `restore`/`analyze` | Platform teams standardising 200 apps |
| **`ko`** (Go only) | none | no | yes | no | **yes, built in** | Go build cache | Go microservices, GitOps |
| **Jib** (Java) | none | no | yes | no | yes | Maven/Gradle-aware | JVM shops |
| **Bazel `rules_oci`** | none | no | yes | no | yes | hermetic, content-based | Monorepos demanding hermeticity |

**Selection heuristics.** One language and a strong convention → `ko`/Jib/Buildpacks (no `Dockerfile` to maintain, base image patched by `rebase` without a rebuild). Heterogeneous estate → BuildKit as a shared service. Kubernetes-native CI where you cannot grant `privileged` and cannot run a shared service → Kaniko or Buildah with `vfs`. Rootless Linux hosts and no daemon allowed → Podman/Buildah.

**Kaniko caveat worth stating plainly:** it runs as *root inside the container* and unpacks each base layer into the container's own root filesystem. It removes the need for `privileged` and the docker socket, but it is not a sandbox — never run untrusted `Dockerfile`s with it on a shared node without gVisor/Kata or a dedicated node pool.

---

## 8. Building images inside Kubernetes without `privileged`

### 8.1 Rootless BuildKit as a shared build service

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: build
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: buildkitd
  namespace: build
---
apiVersion: v1
kind: Service
metadata:
  name: buildkitd
  namespace: build
spec:
  clusterIP: None
  selector:
    app: buildkitd
  ports:
    - name: grpc
      port: 1234
      targetPort: 1234
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: buildkitd
  namespace: build
spec:
  serviceName: buildkitd
  replicas: 3
  podManagementPolicy: Parallel
  selector:
    matchLabels:
      app: buildkitd
  template:
    metadata:
      labels:
        app: buildkitd
      annotations:
        container.apparmor.security.beta.kubernetes.io/buildkitd: unconfined
    spec:
      serviceAccountName: buildkitd
      automountServiceAccountToken: false
      securityContext:
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
        runAsNonRoot: true
        seccompProfile:
          type: Unconfined          # rootlesskit needs unrestricted clone()/unshare()
      containers:
        - name: buildkitd
          image: moby/buildkit:v0.16.0-rootless
          args:
            - --addr
            - unix:///home/user/.local/share/buildkit/buildkitd.sock
            - --addr
            - tcp://0.0.0.0:1234
            - --tlscacert=/certs/ca.pem
            - --tlscert=/certs/cert.pem
            - --tlskey=/certs/key.pem
            - --oci-worker-no-process-sandbox
            - --config=/etc/buildkit/buildkitd.toml
          ports:
            - name: grpc
              containerPort: 1234
          readinessProbe:
            exec:
              command: ["buildctl", "debug", "workers"]
            initialDelaySeconds: 5
            periodSeconds: 30
          livenessProbe:
            exec:
              command: ["buildctl", "debug", "workers"]
            initialDelaySeconds: 15
            periodSeconds: 60
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: false
            capabilities:
              drop: ["ALL"]
          resources:
            requests:
              cpu: "2"
              memory: 4Gi
              ephemeral-storage: 20Gi
            limits:
              cpu: "8"
              memory: 16Gi
              ephemeral-storage: 80Gi
          volumeMounts:
            - name: buildkitd-state
              mountPath: /home/user/.local/share/buildkit
            - name: certs
              mountPath: /certs
              readOnly: true
            - name: config
              mountPath: /etc/buildkit
              readOnly: true
      volumes:
        - name: certs
          secret:
            secretName: buildkit-daemon-certs
        - name: config
          configMap:
            name: buildkitd-config
  volumeClaimTemplates:
    - metadata:
        name: buildkitd-state
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: fast-ssd
        resources:
          requests:
            storage: 200Gi
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: buildkitd-config
  namespace: build
data:
  buildkitd.toml: |
    debug = false
    insecure-entitlements = []

    [worker.oci]
      enabled = true
      snapshotter = "overlayfs"
      gc = true
      gckeepstorage = "120GB"
      max-parallelism = 4

      [[worker.oci.gcpolicy]]
        keepBytes = "20GB"
        keepDuration = "48h"
        filters = ["type==source.local", "type==exec.cachemount"]
      [[worker.oci.gcpolicy]]
        all = true
        keepBytes = "120GB"

    [registry."registry.example.com"]
      mirrors = ["registry-mirror.build.svc.cluster.local:5000"]
    [registry."docker.io"]
      mirrors = ["registry-mirror.build.svc.cluster.local:5000"]
```

Three points the exam and reality both care about:

- **`--oci-worker-no-process-sandbox`** disables the nested process sandbox, which is what allows buildkitd to run without `CAP_SYS_ADMIN`. Trade-off: builds share the pod's namespace isolation, so one tenant per builder pool.
- **`seccompProfile: Unconfined` + AppArmor `unconfined`** are required because `rootlesskit` calls `unshare(CLONE_NEWUSER|CLONE_NEWNS)`; the default profiles block it. This is *less* privilege than `privileged: true`, not more, but it must be a conscious decision recorded in your policy exceptions.
- The **`StatefulSet` + PVC** is deliberate: a build cache is stateful, and losing it turns a 40-second build into an 8-minute one.

Client side:

```
$ buildctl --addr tcp://buildkitd.build.svc.cluster.local:1234 \
    --tlscacert /certs/ca.pem --tlscert /certs/client.pem --tlskey /certs/client-key.pem \
    build \
    --frontend dockerfile.v0 \
    --local context=. \
    --local dockerfile=./build \
    --opt filename=Dockerfile \
    --opt build-arg:VERSION=2.7.0 \
    --opt platform=linux/amd64,linux/arm64 \
    --secret id=pip_extra_index,src=/tmp/pip_index \
    --output type=image,\"name=registry.example.com/platform/api:2.7.0\",push=true \
    --export-cache type=registry,ref=registry.example.com/platform/api/cache,mode=max \
    --import-cache type=registry,ref=registry.example.com/platform/api/cache
```

### 8.2 Kaniko Job — one build, no daemon, no privileged

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: build-api-2-7-0
  namespace: build
spec:
  backoffLimit: 1
  ttlSecondsAfterFinished: 3600
  template:
    metadata:
      labels:
        app.kubernetes.io/name: kaniko
    spec:
      restartPolicy: Never
      automountServiceAccountToken: false
      nodeSelector:
        workload: build
      tolerations:
        - key: dedicated
          operator: Equal
          value: build
          effect: NoSchedule
      containers:
        - name: kaniko
          image: gcr.io/kaniko-project/executor:v1.23.2
          args:
            - --context=git://github.com/example/api.git#refs/tags/v2.7.0
            - --dockerfile=build/Dockerfile
            - --destination=registry.example.com/platform/api:2.7.0
            - --destination=registry.example.com/platform/api:latest
            - --digest-file=/dev/termination-log
            - --cache=true
            - --cache-repo=registry.example.com/platform/api/cache
            - --cache-ttl=168h
            - --snapshot-mode=redo
            - --use-new-run
            - --push-retry=3
            - --image-fs-extract-retry=2
            - --build-arg=VERSION=2.7.0
            - --label=org.opencontainers.image.revision=9f3ac21b7d0e4c58a6b1f2e39d47c80512ab6e3f
            - --reproducible
          env:
            - name: GIT_TOKEN
              valueFrom:
                secretKeyRef:
                  name: git-credentials
                  key: token
          resources:
            requests:
              cpu: "2"
              memory: 4Gi
              ephemeral-storage: 30Gi
            limits:
              cpu: "4"
              memory: 8Gi
              ephemeral-storage: 60Gi
          volumeMounts:
            - name: docker-config
              mountPath: /kaniko/.docker
              readOnly: true
      volumes:
        - name: docker-config
          secret:
            secretName: registry-credentials
            items:
              - key: .dockerconfigjson
                path: config.json
```

`--snapshot-mode=redo` hashes file metadata instead of full contents (much faster on large trees); `--reproducible` strips timestamps so identical inputs give an identical digest — at the cost of discarding layer `created` history.

### 8.3 Buildah Job — rootless, `fuse-overlayfs`

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: buildah-api
  namespace: build
spec:
  backoffLimit: 1
  template:
    metadata:
      annotations:
        container.apparmor.security.beta.kubernetes.io/buildah: unconfined
    spec:
      restartPolicy: Never
      securityContext:
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
        seccompProfile:
          type: Unconfined
      containers:
        - name: buildah
          image: quay.io/buildah/stable:v1.37
          command: ["/bin/bash", "-c"]
          args:
            - |
              set -euo pipefail
              buildah --storage-driver vfs bud \
                --isolation chroot \
                --format oci \
                --layers \
                --build-arg VERSION="${VERSION}" \
                --label org.opencontainers.image.revision="${GIT_SHA}" \
                -f build/Dockerfile \
                -t "${IMAGE}" .
              buildah --storage-driver vfs push \
                --authfile /auth/config.json \
                "${IMAGE}" "docker://${IMAGE}"
          env:
            - name: IMAGE
              value: registry.example.com/platform/api:2.7.0
            - name: VERSION
              value: "2.7.0"
            - name: GIT_SHA
              value: 9f3ac21b7d0e4c58a6b1f2e39d47c80512ab6e3f
            - name: STORAGE_DRIVER
              value: vfs
            - name: BUILDAH_ISOLATION
              value: chroot
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - name: workspace
              mountPath: /workspace
            - name: containers-storage
              mountPath: /home/build/.local/share/containers
            - name: auth
              mountPath: /auth
              readOnly: true
          resources:
            requests: { cpu: "2", memory: 4Gi, ephemeral-storage: 40Gi }
            limits:   { cpu: "4", memory: 8Gi, ephemeral-storage: 80Gi }
      volumes:
        - name: workspace
          emptyDir: {}
        - name: containers-storage
          emptyDir:
            sizeLimit: 40Gi
        - name: auth
          secret:
            secretName: registry-credentials
            items:
              - key: .dockerconfigjson
                path: config.json
```

`vfs` is the compatibility escape hatch: it copies the whole filesystem for every layer instead of using overlay, so it needs **no `/dev/fuse`, no user-namespace mapping and no extra capability** — but disk usage and build time scale with layer count. If your nodes expose `/dev/fuse` (device plugin or `hostPath`), switch to `--storage-driver overlay` with `fuse-overlayfs` and builds get 3–10× faster.

### 8.4 Buildah in script mode — when the `Dockerfile` model doesn't fit

```bash
#!/usr/bin/env bash
set -euo pipefail

ctr=$(buildah from registry.access.redhat.com/ubi9/ubi-micro:9.4)
mnt=$(buildah mount "$ctr")

# Install into the mounted rootfs using the HOST's package manager.
dnf install --installroot "$mnt" --releasever 9 --setopt=install_weak_deps=false \
    -y python3.12 && dnf clean all --installroot "$mnt"

install -m 0755 ./dist/server "$mnt/usr/local/bin/server"

buildah config \
  --entrypoint '["/usr/local/bin/server"]' \
  --cmd '["--listen=:8080"]' \
  --port 8080 \
  --user 10001:10001 \
  --env APP_MODE=production \
  --label org.opencontainers.image.version=2.7.0 \
  --annotation org.opencontainers.image.created="$(date -u -d @"${SOURCE_DATE_EPOCH}" +%Y-%m-%dT%H:%M:%SZ)" \
  "$ctr"

buildah umount "$ctr"
buildah commit --format oci --squash "$ctr" registry.example.com/platform/api:2.7.0
buildah rm "$ctr"
```

This is the answer to "install RPMs into a base image that has no package manager" — impossible with a `Dockerfile`, trivial with `buildah mount`.

---

## 9. Multi-architecture builds

```
$ docker buildx create --name multi --driver docker-container \
    --driver-opt image=moby/buildkit:v0.16.0,network=host --use
multi

$ docker buildx inspect --bootstrap
Name:          multi
Driver:        docker-container
Nodes:
Name:          multi0
Endpoint:      unix:///var/run/docker.sock
Status:        running
BuildKit:      v0.16.0
Platforms:     linux/amd64, linux/amd64/v2, linux/amd64/v3, linux/386,
               linux/arm64, linux/riscv64, linux/ppc64le, linux/s390x, linux/arm/v7, linux/arm/v6
```

Non-native platforms are executed through QEMU registered in `binfmt_misc`. Register it once per host:

```
$ docker run --privileged --rm tonistiigi/binfmt --install arm64,arm
installing: arm64 OK
installing: arm OK
{ "supported": ["linux/amd64","linux/arm64","linux/arm/v7","linux/arm/v6"], "emulators": ["qemu-aarch64","qemu-arm"] }
```

| Strategy | Speed | Fidelity | Setup cost |
|---|---|---|---|
| Cross-compile (`--platform=$BUILDPLATFORM` + `GOARCH`/`--target`) | Fastest | Native binaries, no emulation bugs | Only works for cross-capable toolchains |
| QEMU emulation | 5–20× slower; occasional `Illegal instruction` in JITs | Runs anything | One `binfmt` install |
| Remote native nodes (`buildx create --append`) | Native speed on both arches | Highest | Needs an arm64 build fleet |

Native multi-node builder:

```
$ docker buildx create --name fleet --node amd64 --platform linux/amd64 ssh://build@runner-amd64
$ docker buildx create --name fleet --append --node arm64 --platform linux/arm64 ssh://build@runner-arm64
$ docker buildx build --builder fleet --platform linux/amd64,linux/arm64 -t registry.example.com/platform/api:2.7.0 --push .
```

### 9.1 `docker-bake.hcl` — the build graph as code

```hcl
variable "REGISTRY" { default = "registry.example.com/platform" }
variable "VERSION"  { default = "dev" }
variable "REVISION" { default = "unknown" }
variable "SOURCE_DATE_EPOCH" { default = "1735689600" }

group "default" {
  targets = ["api", "worker"]
}

target "_common" {
  context    = "."
  dockerfile = "build/Dockerfile"
  platforms  = ["linux/amd64", "linux/arm64"]
  args = {
    VERSION           = VERSION
    REVISION          = REVISION
    SOURCE_DATE_EPOCH = SOURCE_DATE_EPOCH
  }
  labels = {
    "org.opencontainers.image.version"  = VERSION
    "org.opencontainers.image.revision" = REVISION
    "org.opencontainers.image.source"   = "https://github.com/example/api"
    "org.opencontainers.image.licenses" = "Apache-2.0"
  }
  attest = [
    "type=provenance,mode=max",
    "type=sbom"
  ]
  output = ["type=image,push=true,rewrite-timestamp=true"]
}

target "api" {
  inherits = ["_common"]
  target   = "runtime"
  tags = [
    "${REGISTRY}/api:${VERSION}",
    "${REGISTRY}/api:latest"
  ]
  cache-from = ["type=registry,ref=${REGISTRY}/api/cache"]
  cache-to   = ["type=registry,ref=${REGISTRY}/api/cache,mode=max"]
}

target "worker" {
  inherits   = ["_common"]
  dockerfile = "build/Dockerfile.worker"
  target     = "runtime"
  tags       = ["${REGISTRY}/worker:${VERSION}"]
  cache-from = ["type=registry,ref=${REGISTRY}/worker/cache"]
  cache-to   = ["type=registry,ref=${REGISTRY}/worker/cache,mode=max"]
}

target "test" {
  inherits = ["_common"]
  target   = "test"
  output   = ["type=cacheonly"]
  platforms = ["linux/amd64"]
}
```

```
$ VERSION=2.7.0 REVISION=$(git rev-parse HEAD) docker buildx bake --print api
$ VERSION=2.7.0 REVISION=$(git rev-parse HEAD) docker buildx bake test api
```

---

## 10. Reproducible builds

Three sources of non-determinism, and the fix for each:

| Source | Effect | Fix |
|---|---|---|
| File mtimes in layers | Digest changes on every build | `SOURCE_DATE_EPOCH` + `rewrite-timestamp=true` |
| `created` in image config | Digest changes | Same; or Kaniko `--reproducible` |
| Unpinned base tag / package repos | Different content entirely | Pin `FROM …@sha256:`, use lockfiles with hashes, pin apt/apk snapshots |

```
$ export SOURCE_DATE_EPOCH=$(git log -1 --pretty=%ct)
$ docker buildx build \
    --build-arg SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" \
    --output type=image,name=registry.example.com/platform/api:2.7.0,push=true,rewrite-timestamp=true \
    --provenance=mode=max --sbom=true .
```

Verification — build twice, on two different hosts, and compare digests:

```
$ crane digest registry.example.com/platform/api:2.7.0
sha256:9f1c47ad0b3e6528c1a94f70d8b23e6a5c07f4d19b8e6203a7c5d1f84b09e376

$ crane digest registry.example.com/platform/api:2.7.0-rebuild
sha256:9f1c47ad0b3e6528c1a94f70d8b23e6a5c07f4d19b8e6203a7c5d1f84b09e376
# identical → the build is reproducible; the artifact is now falsifiable evidence
```

If they differ, diff the configs to find which knob moved:

```
$ diff <(crane config .../api:2.7.0 | jq -S .) <(crane config .../api:2.7.0-rebuild | jq -S .)
```

---

## 11. Secrets during the build

### 11.1 The four wrong ways

```dockerfile
ENV NPM_TOKEN=abc123                    # ✗ persists in the image config, visible to any puller
ARG NPM_TOKEN                           # ✗ appears verbatim in `docker history` on every RUN line
COPY .npmrc /root/.npmrc                # ✗ committed to a layer; `rm` later does NOT remove the blob
RUN echo "$KEY" > /k && use /k && rm /k # ✗ the blob still contains /k
```

### 11.2 The right way — BuildKit secret and SSH mounts

```dockerfile
# syntax=docker/dockerfile:1.7
RUN --mount=type=secret,id=npmrc,target=/root/.npmrc,mode=0400 \
    npm ci --omit=dev

RUN --mount=type=secret,id=aws,env=AWS_SECRET_ACCESS_KEY \
    aws s3 cp s3://artifacts/blob.tar.gz /tmp/

RUN --mount=type=ssh,id=default \
    git clone git@github.com:example/private-lib.git /src/lib
```

```
$ docker buildx build \
    --secret id=npmrc,src=$HOME/.npmrc \
    --secret id=aws,env=AWS_SECRET_ACCESS_KEY \
    --ssh default=$SSH_AUTH_SOCK \
    -t app:2.7.0 .
```

The secret is a tmpfs mount visible only for the duration of that `RUN`; it never becomes a layer, never enters the cache key content, and never reaches the registry.

### 11.3 Proving there is no leak

```
$ skopeo copy docker://registry.example.com/platform/api:2.7.0 oci:/tmp/api:2.7.0
Getting image source signatures
Copying blob 8a1f2c0d9b74 done
Copying blob d40c7b1e93a8 done
Copying config 5e2b09fa73 done
Writing manifest to image destination

$ for b in /tmp/api/blobs/sha256/*; do
>   if tar -tzf "$b" 2>/dev/null | grep -Eq '(^|/)(\.npmrc|\.git-credentials|id_rsa|\.env)$'; then
>     echo "LEAK in blob $b"; tar -tzf "$b" | grep -E '\.npmrc|id_rsa|\.env'
>   fi
> done
# (no output = clean)

$ docker history --no-trunc --format '{{.CreatedBy}}' api:2.7.0 | grep -iE 'token|passwd|secret|key='
# (no output = no build-arg leakage in the config history)
```

Contrast with a deliberately broken build — this is the failure signature you look for during a review:

```
$ docker history --no-trunc --format '{{.CreatedBy}}' api:leaky | head -3
|1 NPM_TOKEN=npm_9fA2kQ7xLm0pRt4vZc RUN /bin/sh -c npm ci --omit=dev # buildkit
```

---

## 12. Metadata, SBOM, provenance and signing

Standard annotations — use them; scanners, GitOps tooling and `Backstage`-style catalogues read them:

```dockerfile
LABEL org.opencontainers.image.title="platform-api" \
      org.opencontainers.image.description="Public order-intake API" \
      org.opencontainers.image.source="https://github.com/example/api" \
      org.opencontainers.image.documentation="https://docs.example.com/api" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.vendor="Example S.A." \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${REVISION}" \
      org.opencontainers.image.created="${BUILD_DATE}"
```

Generate attestations at build time and read them back:

```
$ docker buildx build --provenance=mode=max --sbom=true -t registry.example.com/platform/api:2.7.0 --push .

$ docker buildx imagetools inspect registry.example.com/platform/api:2.7.0 \
    --format '{{ json .SBOM.SPDX.packages }}' | jq -r '.[].name' | head -5
ca-certificates
libc6
libssl3
python3.12-minimal
tzdata

$ docker buildx imagetools inspect registry.example.com/platform/api:2.7.0 \
    --format '{{ json .Provenance.SLSA.invocation.configSource }}'
{
  "uri": "https://github.com/example/api@refs/tags/v2.7.0",
  "digest": {"sha1": "9f3ac21b7d0e4c58a6b1f2e39d47c80512ab6e3f"},
  "entryPoint": "build/Dockerfile"
}
```

Scan and sign, then enforce at admission:

```
$ trivy image --severity HIGH,CRITICAL --ignore-unfixed --exit-code 1 \
    registry.example.com/platform/api:2.7.0
registry.example.com/platform/api:2.7.0 (debian 12.6)
Total: 0 (HIGH: 0, CRITICAL: 0)

$ cosign sign --yes \
    registry.example.com/platform/api@sha256:9f1c47ad0b3e6528c1a94f70d8b23e6a5c07f4d19b8e6203a7c5d1f84b09e376
Generating ephemeral keys...
Retrieving signed certificate...
tlog entry created with index: 148392017

$ cosign verify \
    --certificate-identity-regexp='^https://github\.com/example/api/\.github/workflows/.+@refs/tags/v.+$' \
    --certificate-oidc-issuer=https://token.actions.githubusercontent.com \
    registry.example.com/platform/api@sha256:9f1c47ad... | jq '.[0].optional.Subject'
"https://github.com/example/api/.github/workflows/release.yaml@refs/tags/v2.7.0"
```

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-signed-platform-images
spec:
  validationFailureAction: Enforce
  background: false
  webhookTimeoutSeconds: 30
  rules:
    - name: verify-cosign-signature
      match:
        any:
          - resources:
              kinds: ["Pod"]
              namespaces: ["prod-*"]
      verifyImages:
        - imageReferences:
            - "registry.example.com/platform/*"
          mutateDigest: true          # rewrites the tag to the resolved digest
          verifyDigest: true
          required: true
          attestors:
            - count: 1
              entries:
                - keyless:
                    subject: "https://github.com/example/api/.github/workflows/release.yaml@refs/tags/*"
                    issuer: "https://token.actions.githubusercontent.com"
                    rekor:
                      url: https://rekor.sigstore.dev
```

`mutateDigest: true` is the operational payoff of everything above: the pod spec that reaches etcd names a digest, so the workload is pinned to the exact artifact you signed.

---

## 13. Registry mechanics

```
$ docker login registry.example.com -u ci-bot --password-stdin < /run/secrets/registry_token
Login Succeeded

$ docker push registry.example.com/platform/api:2.7.0
The push refers to repository [registry.example.com/platform/api]
d40c7b1e93a8: Pushed
8a1f2c0d9b74: Layer already exists
2.7.0: digest: sha256:9f1c47ad0b3e6528c1a94f70d8b23e6a5c07f4d19b8e6203a7c5d1f84b09e376 size: 1214
```

`Layer already exists` is content addressing at work: the registry answers a `HEAD /v2/<name>/blobs/<digest>` and the client skips the upload entirely. This is why base-layer sharing is a bandwidth and storage optimisation across your whole estate — and why changing base images per team is expensive.

| Reference form | Mutable | Use for |
|---|---|---|
| `api:latest` | yes | Never in production |
| `api:2.7.0` | yes (a tag can be re-pushed) | Human-facing release identity |
| `api@sha256:9f1c…` | **no** | Deployments, `FROM` lines, incident forensics |

Retagging without pulling the layers (the cheap, correct promotion path from staging to prod):

```
$ crane copy registry.example.com/staging/api:2.7.0 registry.example.com/platform/api:2.7.0
2026/09/03 11:42:07 Copying from registry.example.com/staging/api:2.7.0 to registry.example.com/platform/api:2.7.0
2026/09/03 11:42:08 existing blob: sha256:8a1f2c0d9b74…
2026/09/03 11:42:09 pushed blob: sha256:d40c7b1e93a8…
2026/09/03 11:42:09 registry.example.com/platform/api:2.7.0: digest: sha256:9f1c47ad… size: 1214
```

Enable immutable tags in the registry (Harbor, ECR, GAR, Quay all support it). Without it, "we rolled back to 2.6.0 and the bug was still there" is an outcome you will eventually experience.

---

## 14. Cloud Native Buildpacks — building without a `Dockerfile`

```
$ pack build registry.example.com/platform/api:2.7.0 \
    --builder paketobuildpacks/builder-jammy-base \
    --env BP_JVM_VERSION=21 \
    --env BP_OCI_SOURCE=https://github.com/example/api \
    --cache-image registry.example.com/platform/api/pack-cache \
    --publish
jammy-base: Pulling from paketobuildpacks/builder
===> ANALYZING
Restoring metadata for "paketo-buildpacks/ca-certificates:helper" from app image
===> DETECTING
5 of 12 buildpacks participating
paketo-buildpacks/ca-certificates 3.8.3
paketo-buildpacks/bellsoft-liberica 10.7.2
paketo-buildpacks/syft            1.44.0
paketo-buildpacks/gradle           7.6.1
paketo-buildpacks/executable-jar   6.9.1
===> RESTORING
===> BUILDING
===> EXPORTING
Adding layer 'paketo-buildpacks/ca-certificates:helper'
Adding layer 'launch.sbom'
Setting default process type 'web'
Saving registry.example.com/platform/api:2.7.0...
*** Images (sha256:41c9e0d7…):
      registry.example.com/platform/api:2.7.0
Successfully built image registry.example.com/platform/api:2.7.0
```

The lifecycle runs `detect → analyze → restore → build → export`. The killer feature is `rebase`: when the run image is patched for a CVE, you swap the base layers without recompiling the application.

```
$ pack rebase registry.example.com/platform/api:2.7.0 --run-image paketobuildpacks/run-jammy-base:latest --publish
Rebasing registry.example.com/platform/api:2.7.0 on run image paketobuildpacks/run-jammy-base:latest
Saving registry.example.com/platform/api:2.7.0...
*** Images (sha256:7bd214ac…):
      registry.example.com/platform/api:2.7.0
Rebased Image: sha256:7bd214ac…
```

| Dimension | `Dockerfile` | Buildpacks |
|---|---|---|
| Control | Total | Constrained to buildpack conventions |
| Consistency across 200 apps | Depends on discipline | Enforced by the builder image |
| CVE patch of base | Rebuild every image | `pack rebase` — seconds, no source needed |
| SBOM | You add it | Emitted by the lifecycle |
| Unusual runtime needs | Trivial | May require a custom buildpack |
| Learning curve for app teams | High | Near zero (`pack build`, no file) |

---

## 15. CI pipelines, complete

### 15.1 GitHub Actions — multi-arch, cached, attested, signed

```yaml
name: release
on:
  push:
    tags: ["v*"]

permissions:
  contents: read
  packages: write
  id-token: write        # required for cosign keyless (OIDC)

jobs:
  build:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Compute build metadata
        id: meta
        run: |
          echo "version=${GITHUB_REF_NAME#v}" >> "$GITHUB_OUTPUT"
          echo "revision=$(git rev-parse HEAD)" >> "$GITHUB_OUTPUT"
          echo "source_date_epoch=$(git log -1 --pretty=%ct)" >> "$GITHUB_OUTPUT"

      - uses: docker/setup-qemu-action@v3
        with:
          platforms: arm64

      - uses: docker/setup-buildx-action@v3
        with:
          driver-opts: image=moby/buildkit:v0.16.0

      - uses: docker/login-action@v3
        with:
          registry: registry.example.com
          username: ${{ secrets.REGISTRY_USER }}
          password: ${{ secrets.REGISTRY_TOKEN }}

      - name: Build and push
        id: build
        uses: docker/build-push-action@v6
        env:
          SOURCE_DATE_EPOCH: ${{ steps.meta.outputs.source_date_epoch }}
        with:
          context: .
          file: build/Dockerfile
          target: runtime
          platforms: linux/amd64,linux/arm64
          push: true
          provenance: mode=max
          sbom: true
          outputs: type=image,rewrite-timestamp=true
          tags: |
            registry.example.com/platform/api:${{ steps.meta.outputs.version }}
            registry.example.com/platform/api:latest
          build-args: |
            VERSION=${{ steps.meta.outputs.version }}
            REVISION=${{ steps.meta.outputs.revision }}
          labels: |
            org.opencontainers.image.version=${{ steps.meta.outputs.version }}
            org.opencontainers.image.revision=${{ steps.meta.outputs.revision }}
            org.opencontainers.image.source=${{ github.server_url }}/${{ github.repository }}
          secrets: |
            pip_extra_index=${{ secrets.PIP_EXTRA_INDEX_URL }}
          cache-from: type=gha,scope=api
          cache-to: type=gha,scope=api,mode=max

      - name: Scan
        uses: aquasecurity/trivy-action@0.24.0
        with:
          image-ref: registry.example.com/platform/api@${{ steps.build.outputs.digest }}
          severity: HIGH,CRITICAL
          ignore-unfixed: true
          exit-code: "1"

      - uses: sigstore/cosign-installer@v3
      - name: Sign
        run: |
          cosign sign --yes \
            "registry.example.com/platform/api@${{ steps.build.outputs.digest }}"
```

### 15.2 GitLab CI — Kaniko, no docker socket

```yaml
stages: [build, scan, sign]

variables:
  IMAGE: $CI_REGISTRY_IMAGE
  CACHE_REPO: $CI_REGISTRY_IMAGE/cache

build:image:
  stage: build
  image:
    name: gcr.io/kaniko-project/executor:v1.23.2-debug
    entrypoint: [""]
  script:
    - |
      cat > /kaniko/.docker/config.json <<EOF
      { "auths": { "${CI_REGISTRY}": { "auth": "$(printf '%s:%s' "${CI_REGISTRY_USER}" "${CI_REGISTRY_PASSWORD}" | base64 | tr -d '\n')" } } }
      EOF
    - export SOURCE_DATE_EPOCH="$(git log -1 --pretty=%ct)"
    - |
      /kaniko/executor \
        --context "dir://${CI_PROJECT_DIR}" \
        --dockerfile "${CI_PROJECT_DIR}/build/Dockerfile" \
        --target runtime \
        --destination "${IMAGE}:${CI_COMMIT_TAG:-$CI_COMMIT_SHORT_SHA}" \
        --cache=true \
        --cache-repo "${CACHE_REPO}" \
        --cache-ttl=168h \
        --snapshot-mode=redo \
        --use-new-run \
        --reproducible \
        --build-arg VERSION="${CI_COMMIT_TAG:-0.0.0-${CI_COMMIT_SHORT_SHA}}" \
        --label org.opencontainers.image.revision="${CI_COMMIT_SHA}" \
        --label org.opencontainers.image.source="${CI_PROJECT_URL}" \
        --digest-file "${CI_PROJECT_DIR}/image.digest"
  artifacts:
    paths: ["image.digest"]
    expire_in: 1 week

scan:image:
  stage: scan
  image: aquasec/trivy:0.55.0
  script:
    - trivy image --severity HIGH,CRITICAL --ignore-unfixed --exit-code 1 "${IMAGE}@$(cat image.digest)"
```

---

## 16. Verification and failure diagnosis

### 16.1 Symptom → cause → command

| Symptom | Most likely cause | First command |
|---|---|---|
| `failed to solve: process "/bin/sh -c …" did not complete successfully: exit code: 1` | Genuine command failure, hidden by the TUI | `docker buildx build --progress=plain --no-cache` |
| `COPY failed: file not found in build context` | Path excluded by `.dockerignore`, or wrong stage | `docker buildx build --target <stage> …` + review `.dockerignore` |
| `exec /server: no such file or directory` (binary exists!) | Dynamically linked binary on `scratch`/distroless — missing loader | `file dist/server` / `ldd dist/server` |
| `exec format error` | Architecture mismatch | `docker image inspect --format '{{.Architecture}}'` |
| Cache never hits in CI | No `--cache-from/--cache-to`; ephemeral runner | Add `type=registry,mode=max` |
| Cache misses after a trivial source edit | `COPY . .` before dependency install | Reorder; see §4 |
| `max depth exceeded` | > 127 layers | Squash or collapse `RUN`s |
| `no space left on device` on the builder | Build cache growth | `docker buildx du` → `docker builder prune` |
| Image 10× bigger than expected | Build tools in the final stage, or `rm` after the fact | `dive` / `docker history` |
| `Error loading shared library libc.musl…` | glibc binary on Alpine | Change base or build against musl |
| `unauthorized: authentication required` on push | Missing/expired `config.json`; wrong registry host in the tag | `docker login` + check the tag prefix |
| `error checking push permissions` (Kaniko) | Secret not mounted at `/kaniko/.docker/config.json` | Check volume `items[].path` |
| `operation not permitted` in a rootless builder | seccomp/AppArmor blocking `unshare` | Set `seccompProfile: Unconfined` + AppArmor unconfined |
| Pod ignores `SIGTERM`, killed after grace period | `ENTRYPOINT` in shell form | `docker inspect --format '{{json .Config.Entrypoint}}'` |
| "It works locally, prod runs old code" | Mutable tag re-pushed / `imagePullPolicy: IfNotPresent` | Compare `crane digest` vs the pod's `imageID` |

### 16.2 Making a failing build talk

```
$ docker buildx build --progress=plain --no-cache -t api:debug . 2>&1 | tail -20
#14 [builder 5/6] RUN pip install --require-hashes -r requirements.lock
#14 3.117 Collecting psycopg2==2.9.9
#14 4.902   Running setup.py install for psycopg2: started
#14 6.740     Error: pg_config executable not found.
#14 6.741     ERROR: Command errored out with exit status 1
#14 ERROR: process "/bin/sh -c pip install --require-hashes -r requirements.lock" did not complete successfully: exit code: 1
------
 > [builder 5/6] RUN pip install --require-hashes -r requirements.lock:
6.740     Error: pg_config executable not found.
------
Dockerfile:22
--------------------
  21 |     COPY requirements.txt requirements.lock ./
  22 | >>> RUN --mount=type=cache,target=/root/.cache/pip \
  23 | >>>     pip install --require-hashes -r requirements.lock
--------------------
```

Then get a shell **in the last successful state** by targeting the stage before it:

```
$ docker buildx build --target builder --load -t api:builder-debug . || true
$ docker run --rm -it --entrypoint /bin/sh api:builder-debug
/ # which pg_config
/ # apt-get install -y libpq-dev && which pg_config
/usr/bin/pg_config
```

For a build that fails *inside* a stage you cannot reach, BuildKit's interactive debugger:

```
$ export BUILDX_EXPERIMENTAL=1
$ docker buildx debug --invoke /bin/sh build --target builder .
```

### 16.3 Auditing size and layer composition

```
$ docker history --format 'table {{.Size}}\t{{.CreatedBy}}' api:2.7.0
SIZE      CREATED BY
0B        CMD ["api.main:app" "--host" "0.0.0.0" "--port" "8080"]
0B        ENTRYPOINT ["/app/.venv/bin/python" "-m" "uvicorn"]
0B        USER 10001:10001
41.2MB    COPY /app/.venv /app/.venv # buildkit
2.14MB    COPY /app/api /app/api # buildkit
7.83MB    RUN /bin/sh -c apt-get update && apt-get install --no-install-recommends -y libpq5 …
0B        ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 …
48.1MB    /bin/sh -c #(nop) ADD file:… in /

$ dive registry.example.com/platform/api:2.7.0 --ci --lowestEfficiency=0.95
Analyzing image...
efficiency: 97.4 %
wastedBytes: 3.1 MB
userWastedPercent: 2.6 %
Run CI Validations...
  PASS: highestUserWastedPercent
  PASS: highestWastedBytes
  PASS: lowestEfficiency
Result:PASS
```

`dive`'s "wasted bytes" is the total of files written in one layer and overwritten or deleted in a later one — exactly the `rm`-after-the-fact anti-pattern.

### 16.4 Verifying the produced artifact before you ship it

```
# 1. Architecture and entrypoint are what you intended
$ docker buildx imagetools inspect registry.example.com/platform/api:2.7.0 \
    --format '{{range .Manifest.Manifests}}{{.Platform.OS}}/{{.Platform.Architecture}} {{end}}'
linux/amd64 linux/arm64 unknown/unknown

# 2. It does not run as root
$ crane config registry.example.com/platform/api:2.7.0 | jq -r '.config.User'
10001:10001

# 3. There is no shell or package manager in the runtime image
$ crane export registry.example.com/platform/api:2.7.0 - | tar -t 2>/dev/null \
    | grep -E '(bin/(ba)?sh|usr/bin/(apt|apk|dnf|yum))$'
usr/bin/dash          # ← still present: acceptable for slim, unacceptable for a hardened tier

# 4. The binary actually starts
$ docker run --rm --read-only --tmpfs /tmp --cap-drop=ALL --security-opt no-new-privileges \
    -p 8080:8080 registry.example.com/platform/api:2.7.0 &
$ curl -fsS localhost:8080/healthz && echo OK
{"status":"ok","version":"2.7.0"}
OK

# 5. Metadata is populated (GitOps and catalogues depend on it)
$ crane config registry.example.com/platform/api:2.7.0 | jq '.config.Labels'
{
  "org.opencontainers.image.revision": "9f3ac21b7d0e4c58a6b1f2e39d47c80512ab6e3f",
  "org.opencontainers.image.source": "https://github.com/example/api",
  "org.opencontainers.image.version": "2.7.0"
}
```

Step 4 is the one teams skip. Running the candidate with `--read-only --cap-drop=ALL` locally reproduces the restrictive `securityContext` production will apply, and catches "the app writes to `/app/logs` at startup" **before** the rollout does.

### 16.5 Builder housekeeping

```
$ docker buildx du --verbose | tail -12
ID:             xk3n9q1w7p2m4c6v8b0z5a3f
Created at:     2026-08-29 07:14:22 +0000 UTC
Mutable:        false
Reclaimable:    true
Shared:         false
Size:           4.19GB
Description:    [builder 5/6] RUN pip install --require-hashes -r requirements.lock
Usage count:    31
Last used:      2 days ago
Type:           regular

Reclaimable:    58.4GB
Total:          71.2GB

$ docker builder prune --filter until=168h --keep-storage 40GB -f
Total reclaimed space: 22.7GB
```

Run this from a `CronJob`/systemd timer on build nodes. "No space left on device" at 02:00 on release night is a scheduling failure, not a Docker failure.

---

## 17. Command reference

```
# Build
docker build -t app:1.0 .                             # legacy/BuildKit depending on DOCKER_BUILDKIT
DOCKER_BUILDKIT=1 docker build --secret id=x,src=f .  # BuildKit features
docker buildx build --platform linux/amd64,linux/arm64 --push -t repo/app:1.0 .
docker buildx build --target builder --load .          # single-arch load into the local daemon
docker buildx bake --print                             # resolve the HCL build graph
podman build -t app:1.0 -f Containerfile .
buildah bud --layers --format oci -t app:1.0 .
buildah from / run / copy / config / commit            # script-mode build
/kaniko/executor --context dir:// --destination repo/app:1.0

# Inspect
docker history --no-trunc app:1.0
docker image inspect app:1.0
docker buildx imagetools inspect repo/app:1.0
podman image tree app:1.0
skopeo inspect --raw docker://repo/app:1.0
crane config repo/app:1.0 ; crane digest repo/app:1.0 ; crane export repo/app:1.0 -
dive repo/app:1.0 --ci

# Registry
docker login registry.example.com
docker tag app:1.0 registry.example.com/team/app:1.0
docker push registry.example.com/team/app:1.0
skopeo copy docker://src:tag docker://dst:tag
crane copy src:tag dst:tag

# Housekeeping
docker buildx du ; docker builder prune --filter until=24h
docker system df ; docker image prune -a
podman system prune -a --volumes
```

---

## 18. Referencias

**Exam objectives**
- LPI DevOps Tools Engineer — Exam 701 objectives: https://www.lpi.org/our-certifications/exam-701-objectives/
- LPI DevOps Tools Engineer certification overview: https://www.lpi.org/our-certifications/devops-overview/

**Specifications**
- OCI Image Format Specification: https://github.com/opencontainers/image-spec/blob/main/spec.md
- OCI Image Manifest / Index / Config: https://github.com/opencontainers/image-spec/blob/main/manifest.md · https://github.com/opencontainers/image-spec/blob/main/image-index.md · https://github.com/opencontainers/image-spec/blob/main/config.md
- OCI Pre-defined Annotation Keys: https://github.com/opencontainers/image-spec/blob/main/annotations.md
- OCI Distribution Specification: https://github.com/opencontainers/distribution-spec/blob/main/spec.md

**Build files and builders**
- Dockerfile reference: https://docs.docker.com/reference/dockerfile/
- Dockerfile frontend syntax (BuildKit): https://docs.docker.com/build/dockerfile/frontend/
- Building best practices: https://docs.docker.com/build/building/best-practices/
- Multi-stage builds: https://docs.docker.com/build/building/multi-stage/
- BuildKit documentation: https://docs.docker.com/build/buildkit/
- Build cache and cache backends: https://docs.docker.com/build/cache/ · https://docs.docker.com/build/cache/backends/
- Build secrets: https://docs.docker.com/build/building/secrets/
- Multi-platform builds: https://docs.docker.com/build/building/multi-platform/
- Bake reference: https://docs.docker.com/build/bake/reference/
- Build attestations (SBOM, provenance): https://docs.docker.com/build/metadata/attestations/
- Reproducible builds: https://docs.docker.com/build/ci/github-actions/reproducible-builds/
- `.dockerignore` reference: https://docs.docker.com/reference/dockerfile/#dockerignore-file
- BuildKit project (rootless, Kubernetes examples): https://github.com/moby/buildkit · https://github.com/moby/buildkit/blob/master/docs/rootless.md · https://github.com/moby/buildkit/tree/master/examples/kubernetes
- Buildah: https://buildah.io/ · `buildah-bud(1)`: https://github.com/containers/buildah/blob/main/docs/buildah-build.1.md
- Podman `podman-build(1)`: https://docs.podman.io/en/latest/markdown/podman-build.1.html
- Podman rootless mode: https://github.com/containers/podman/blob/main/docs/tutorials/rootless_tutorial.md
- Kaniko: https://github.com/GoogleContainerTools/kaniko
- `ko`: https://ko.build/
- Jib: https://github.com/GoogleContainerTools/jib
- Cloud Native Buildpacks: https://buildpacks.io/docs/ · `pack` CLI: https://buildpacks.io/docs/for-platform-operators/how-to/integrate-ci/pack/
- Bazel `rules_oci`: https://github.com/bazel-contrib/rules_oci

**Base images**
- Distroless: https://github.com/GoogleContainerTools/distroless
- Alpine Linux: https://alpinelinux.org/ · musl vs glibc differences: https://wiki.musl-libc.org/functional-differences-from-glibc.html
- Red Hat UBI: https://developers.redhat.com/products/rhel/ubi
- Chainguard Images / Wolfi: https://edu.chainguard.dev/chainguard/chainguard-images/ · https://github.com/wolfi-dev

**Supply chain and inspection**
- Sigstore `cosign`: https://docs.sigstore.dev/cosign/signing/overview/
- SLSA framework: https://slsa.dev/spec/v1.0/
- Trivy: https://aquasecurity.github.io/trivy/
- Syft: https://github.com/anchore/syft
- `skopeo`: https://github.com/containers/skopeo
- `crane` (go-containerregistry): https://github.com/google/go-containerregistry/blob/main/cmd/crane/doc/crane.md
- `dive`: https://github.com/wagoodman/dive
- Kubernetes — Images and `imagePullPolicy`: https://kubernetes.io/docs/concepts/containers/images/
- Kubernetes — Pod Security Standards: https://kubernetes.io/docs/concepts/security/pod-security-standards/
- Kyverno image verification: https://kyverno.io/docs/writing-policies/verify-images/