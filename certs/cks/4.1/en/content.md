# CKS 4.1 — Minimize Base Image Footprint

**Domain:** Supply Chain Security · **Exam weight:** 5% · **Exam version:** CKS 1.34 (Kubernetes v1.34)

---

## 1. The production problem

### 1.1 "Footprint" is not "megabytes"

Most teams reduce this topic to image size. Size is a *proxy metric*, and a lossy one. What actually determines the security posture of a container image is the set of **executable capabilities reachable by a process that has achieved code execution inside the container**.

Decompose the footprint into five independent axes:

| Axis | What it is | Why it matters after compromise |
|---|---|---|
| **Package surface** | Every `.deb`/`.rpm`/`.apk` and its transitive dependencies | Each package is a CVE feed you have subscribed to permanently. You now own patch SLAs for code your app never calls. |
| **Executable surface** | Shells, coreutils, `curl`, `wget`, `nc`, `python`, `perl`, `tar`, `find` | These are the attacker's toolchain. A container with no `sh` forces the attacker to bring their own binary *and* find a writable, executable filesystem location. |
| **Package-manager surface** | `apt`, `apk`, `dnf/microdnf`, `pip`, `npm` | Converts a code-execution primitive into arbitrary tool installation, and gives egress-based persistence. |
| **Privilege surface** | setuid/setgid binaries, file capabilities (`getcap`), `/etc/sudoers` | Local privilege escalation inside the container namespace — the first half of most escape chains. |
| **Credential surface** | Build-time secrets left in layers, `~/.npmrc`, `~/.docker/config.json`, cloud SDK caches | Lateral movement. Layers are content-addressed and immutable: `rm` in a later layer does **not** delete the blob. |

A "small" image can still be terrible (Alpine ships a full BusyBox shell + `apk` + `wget` in 7 MB). A "large" image can be defensible (a 200 MB JVM image with no shell, no package manager, and no setuid binaries). **Optimize the axes, and size falls out as a side effect.**

### 1.2 The arithmetic of inherited CVEs

The vulnerability count of your image is:

```
CVE(image) = CVE(base OS packages)
           + CVE(language runtime)
           + CVE(application dependencies)
           + CVE(your code)
```

The first term is the only one that is *pure liability* — you inherit the maintenance burden without gaining functionality. In a typical Go microservice built `FROM ubuntu:24.04`, term 1 is 90–98% of the reported findings, and 100% of it is unnecessary: the compiled binary links nothing from the base.

This has direct operational consequences that show up in an SRE's error budget, not just in a scanner dashboard:

- **Patch amplification.** A `glibc`/`openssl`/`zlib` advisory forces a rebuild-and-redeploy of *every* service that shares the base, regardless of whether the service uses the library. With 300 services on a shared Ubuntu base, one CVE is 300 deployments.
- **Policy gates block releases.** A CI gate of `trivy --exit-code 1 --severity CRITICAL` on a fat base blocks releases for CVEs in `passwd`, `apt`, or `perl-base` that the workload never invokes. Teams then do the worst possible thing: they add blanket `.trivyignore` entries and stop reading the scanner.
- **Audit noise destroys signal.** 480 findings where 470 are unreachable means the 10 real ones are not triaged.

### 1.3 Post-exploitation: what the attacker actually finds

Consider an SSRF-to-RCE in a web app. The difference between base images decides whether the incident is *contained* or *pivoting*:

```
┌───────────────────────────────────────────────────────────────────────────────┐
│  Attacker obtains code execution as the container's UID                       │
└───────────────────────────────────────────────────────────────────────────────┘
        │                                                    │
        │  FROM ubuntu:24.04                                 │  FROM distroless/static:nonroot
        ▼                                                    ▼
  /bin/bash            → interactive shell               (absent)  → no interpreter
  apt-get install      → arbitrary tooling               (absent)  → must smuggle a static ELF
  curl / wget          → C2 egress + payload staging     (absent)  → must write raw sockets in-process
  /usr/bin/mount (suid)→ local privesc primitive         (absent)  → no setuid binaries at all
  python3 / perl       → reverse shell one-liner         (absent)  → nothing to interpret
  ps / find / netstat  → in-cluster reconnaissance       (absent)  → blind
  /var/run/secrets/... → ServiceAccount token            present   → still present (K8s-level control)
```

The minimal image does **not** stop the initial RCE. It raises the cost of *every subsequent step*, and — critically for detection — it forces the attacker to write a file to disk or exec an unexpected binary, which is exactly the event a runtime sensor (Falco, Tetragon) reliably catches. Combined with `readOnlyRootFilesystem: true`, the attacker has code execution in a process with no shell, no writable executable path, and no package manager. That is the point.

> **Threat-model honesty:** a minimal image is *not* a sandbox. It does nothing against kernel exploits, does nothing against a mounted ServiceAccount token with excessive RBAC, and does nothing against `hostPath` mounts. It is one control in a chain that must also include Pod Security Standards, seccomp, RBAC minimization, and NetworkPolicy.

### 1.4 Node-level economics

Footprint is also a reliability property of the node:

- **Pull latency on the critical path.** A node failure triggers reschedule → image pull → readiness. A 900 MB image on a 200 Mbit/s node link costs ~40 s of pull *per node* before the container even starts, and it is serialized behind the runtime's decompression. Scale-out under load (HPA) is gated by the same number.
- **Disk pressure and image GC.** The kubelet garbage-collects images between `imageGCLowThresholdPercent` and `imageGCHighThresholdPercent`. Fat images make `DiskPressure` eviction more likely, which evicts *other* tenants' pods — a cross-tenant reliability coupling created purely by image bloat.
- **Registry cost and cache hit rate.** Layer dedup only helps when bases are *shared*; a fleet with 12 different fat bases gets the worst of both worlds.

---

## 2. Taxonomy of base images

### 2.1 The comparison table

Sizes are **uncompressed**, as reported by `docker image ls` (the registry stores compressed blobs, typically ~35–45% of this). Measured 2026-08-04 on `linux/amd64`; reproduce with the script in §5.1. Treat the numbers as orders of magnitude, not constants.

| Base image | Size | libc | Shell | Pkg mgr | CA certs | `/etc/passwd` | tzdata | Typical use |
|---|---:|---|---|---|---|---|---|---|
| `scratch` | 0 B | none | ✗ | ✗ | ✗ | ✗ | ✗ | Fully static binary, no TLS-to-external, no temp files |
| `gcr.io/distroless/static-debian12` | ~2.4 MB | none | ✗ | ✗ | ✓ | ✓ (`nonroot`=65532) | ✓ | **Default for Go/Rust static** |
| `cgr.dev/chainguard/static` | ~3 MB | none | ✗ | ✗ | ✓ | ✓ (65532) | ✓ | Same role, Wolfi-maintained, SBOM+signature attached |
| `gcr.io/distroless/base-debian12` | ~20 MB | glibc | ✗ | ✗ | ✓ | ✓ | ✓ | CGO-enabled Go, dynamically linked C |
| `gcr.io/distroless/cc-debian12` | ~22 MB | glibc + libstdc++ | ✗ | ✗ | ✓ | ✓ | ✓ | C++ apps, Rust with `gnu` target |
| `alpine:3.20` | ~7.8 MB | musl | ✓ BusyBox `ash` | ✓ `apk` | ✓ (via pkg) | ✓ | ✗ (via pkg) | Ops/debug images; app images only with reservations (§2.2) |
| `cgr.dev/chainguard/wolfi-base` | ~14 MB | glibc | ✓ | ✓ `apk` | ✓ | ✓ | ✓ | glibc-compatible build/debug stage with apk convenience |
| `registry.access.redhat.com/ubi9/ubi-micro` | ~26 MB | glibc | ✗ | ✗ (install from outside) | ✓ | ✓ | ✓ | RHEL-supported, no shell |
| `registry.access.redhat.com/ubi9/ubi-minimal` | ~100 MB | glibc | ✓ | ✓ `microdnf` | ✓ | ✓ | ✓ | RHEL support contract required |
| `debian:12-slim` | ~74 MB | glibc | ✓ | ✓ `apt` | ✗ (via pkg) | ✓ | ✓ | Legacy apps needing `apt` at build time |
| `ubuntu:24.04` | ~78 MB | glibc | ✓ | ✓ `apt` | ✗ (via pkg) | ✓ | ✓ | Avoid as a *runtime* base |
| `gcr.io/distroless/java21-debian12` | ~190 MB | glibc | ✗ | ✗ | ✓ | ✓ | ✓ | JVM apps without custom jlink runtime |
| `gcr.io/distroless/nodejs22-debian12` | ~150 MB | glibc | ✗ | ✗ | ✓ | ✓ | ✓ | Node apps; ENTRYPOINT is `node` |

**Trade-off summary:**

| Choice | Gains | Costs / risks |
|---|---|---|
| `scratch` | Absolute minimum; zero inherited CVEs | No CA bundle (TLS to the internet fails), no `/etc/passwd` (`user.Current()` fails), no `/tmp`, no tzdata, no `nsswitch.conf`. You must supply each explicitly. |
| Distroless `static` | Same guarantees as scratch **plus** the four things above already correct | Debian-based CVE feed for `ca-certificates`/`tzdata` (tiny). No shell → mandatory ephemeral-container debugging workflow. |
| Distroless `base`/`cc` | Supports CGO / dynamic linking | glibc + OpenSSL now in your CVE surface. |
| Alpine | Small, `apk` available, huge package index | **musl ≠ glibc**: subtle runtime differences (§2.2). Ships shell + package manager + BusyBox applets — the exact post-exploitation surface you were trying to remove. |
| Wolfi / Chainguard | glibc, near-zero CVE, signed + SBOM by default, daily rebuilds | Free tier pins to `:latest` (no historical version tags without a subscription) — conflicts with digest-pinning discipline unless you mirror. |
| UBI | Red Hat CVE support lifecycle, FIPS-validated crypto path | Largest of the "minimal" family; `ubi-minimal` still ships a shell. |

### 2.2 glibc vs musl — the trade-off nobody documents at the interview

Alpine's small size comes from BusyBox + **musl libc**, not from being "cleaner". musl is a different libc, and the divergences are production-relevant:

| Concern | glibc | musl | Kubernetes-specific impact |
|---|---|---|---|
| DNS resolver | Sequential nameservers, TCP fallback on truncation, `nsswitch.conf` | Queries all `nameserver` entries in parallel; **TCP fallback only since musl 1.2.4** (Alpine 3.18+) | With `ndots: 5` and 4 search domains, a single lookup fans out to ~20 queries. Pre-1.2.4 musl silently fails on >512-byte responses (large headless-Service endpoint lists). |
| Default thread stack | 8 MB | 128 KB (raised to 128 KB in 1.2.x; historically 80 KB) | JVM/Rust/deep-recursion code segfaults with no useful message. |
| malloc | ptmalloc2, arena-per-thread | mallocng — smaller, **measurably slower under high thread contention** | 20–40% throughput regressions have been reported for allocation-heavy workloads. |
| Binary compatibility | The de-facto ABI | Not glibc-ABI-compatible | Any prebuilt `manylinux` wheel, `.so` vendored by a vendor SDK, or Go binary built with `CGO_ENABLED=1` on Debian will fail on Alpine. |
| Python wheels | `manylinux` wheels install | Needs `musllinux` wheels, else compiles from source | `pip install` in an Alpine build stage silently takes 15 minutes and pulls in `gcc`. |

**Rule of thumb:** if you control the compiler and can produce a fully static binary, use `distroless/static` — you get Alpine's size *without* musl and *without* a shell. Use Alpine when you want a small **debug/ops** image, or when the ecosystem is already musl-native.

### 2.3 The distroless contract

`gcr.io/distroless/*` images (Google, `GoogleContainerTools/distroless`) contain the application's runtime dependencies and nothing else. Concretely, `static-debian12` contains:

```
/etc/passwd, /etc/group        → root(0) and nonroot(65532) entries
/etc/nsswitch.conf             → "hosts: files dns"  (needed by Go's cgo resolver path)
/etc/ssl/certs/ca-certificates.crt
/usr/share/zoneinfo/           → tzdata
/tmp                           → mode 1777
/var/lib/dpkg/status.d/        → package metadata so scanners can enumerate contents
```

Tag variants that matter for the exam and for production:

| Tag | Effect |
|---|---|
| `:latest` | Runs as **root (UID 0)** |
| `:nonroot` | Runs as **UID/GID 65532**, `$HOME=/home/nonroot` |
| `:debug` | Adds a BusyBox shell at `/busybox/sh` — **never ship this to production**, use it only to reproduce a bug |
| `:debug-nonroot` | Both of the above |

The `/var/lib/dpkg/status.d/` detail is important: it is what lets Trivy/Grype enumerate the base packages. `scratch`-based images are *unscannable* at the OS layer — the scanner reports "0 vulnerabilities" because it found no package database, which is not the same as "secure". Prefer distroless over scratch partly for this observability reason.

### 2.4 Decision procedure

```
Can the app be compiled to a fully static binary (Go CGO_ENABLED=0, Rust musl target)?
├── yes → gcr.io/distroless/static-debian12:nonroot        (2.4 MB, no shell, no libc)
└── no
    ├── Needs glibc only (CGO, C libs)?      → gcr.io/distroless/base-debian12:nonroot
    ├── Needs libstdc++ (C++, Rust gnu)?     → gcr.io/distroless/cc-debian12:nonroot
    ├── JVM?
    │     ├── can run jlink/jdeps  → jlink custom runtime → distroless/base or chainguard/jre
    │     └── cannot                → gcr.io/distroless/java21-debian12:nonroot
    ├── Node.js?                             → gcr.io/distroless/nodejs22-debian12:nonroot
    ├── Python / Ruby / PHP?                 → cgr.dev/chainguard/python (or wolfi-base + apk, then strip)
    └── Vendor blob demanding RHEL/FIPS?     → ubi9/ubi-micro (install RPMs from a ubi9 builder stage)
```

---

## 3. Build techniques — complete, working Dockerfiles

The reference application for §3 and §5 is a small Go HTTP service.

```go
// main.go
package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"
	_ "time/tzdata" // embed the IANA database in the binary; survives a scratch base
)

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))

	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		fmt.Fprintln(w, "ok")
	})
	mux.HandleFunc("GET /", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintf(w, "served at %s\n", time.Now().UTC().Format(time.RFC3339))
	})

	srv := &http.Server{
		Addr:              ":8080",
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}

	go func() {
		logger.Info("listening", "addr", srv.Addr, "uid", os.Getuid())
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			logger.Error("server failed", "err", err)
			os.Exit(1)
		}
	}()

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	<-stop

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	_ = srv.Shutdown(ctx)
	logger.Info("stopped")
}
```

### 3.1 The anti-pattern (what an exam task hands you to fix)

```dockerfile
# Dockerfile.bad — DO NOT SHIP. Reference for the "before" measurement.
FROM ubuntu:24.04

RUN apt-get update && apt-get install -y golang-go ca-certificates curl vim net-tools

WORKDIR /src
COPY . .
RUN go build -o /usr/local/bin/webapp .

EXPOSE 8080
CMD ["/usr/local/bin/webapp"]
```

Defects, in the order a CKS grader looks for them:

1. **Single stage** — the compiler, its sources, the module cache and `/src` all ship to production.
2. **Runs as root** — no `USER` instruction.
3. **`curl`, `vim`, `net-tools`** — attacker toolchain installed deliberately.
4. **`apt` present at runtime** — arbitrary tool installation post-compromise.
5. **Unpinned base tag** — `ubuntu:24.04` is a moving target; builds are not reproducible.
6. **No `apt-get clean` / list removal** — package indices persist in the layer.
7. **`apt-get update` and `install` are cacheable and unpinned** — classic cache-poisoning/staleness bug.

### 3.2 The target: multi-stage → distroless static, non-root

```dockerfile
# syntax=docker/dockerfile:1.9
# ---------------------------------------------------------------------------
# Stage 1 — build. Never ships.
# ---------------------------------------------------------------------------
FROM golang:1.23.4-bookworm@sha256:7ea4c9dcb2b97ff8ee80a67db3d44f98c8ffa0d191399197007d8459c1453041 AS build

WORKDIR /src

# Dependency layer, cached independently of source changes.
COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod \
    go mod download && go mod verify

COPY . .

# CGO_ENABLED=0  -> pure-Go, statically linked; no ELF interpreter needed.
# -trimpath      -> strips absolute build paths (reproducibility + info leak).
# -buildvcs=false-> avoid embedding VCS state that changes every commit.
# -ldflags "-s -w" -> drop symbol table and DWARF; smaller, harder to reverse.
# -tags timetzdata -> belt-and-braces with the `_ "time/tzdata"` import.
ARG TARGETOS=linux
ARG TARGETARCH=amd64
ARG VERSION=dev
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} \
    go build \
      -trimpath \
      -buildvcs=false \
      -tags timetzdata \
      -ldflags="-s -w -X main.version=${VERSION}" \
      -o /out/webapp .

# Fail the build here, not in production, if the binary is not static.
RUN set -eux; \
    file /out/webapp | grep -q 'statically linked'; \
    ! ldd /out/webapp 2>/dev/null | grep -q '=>' || (echo "BUILD FAILED: dynamic deps present" && exit 1)

# ---------------------------------------------------------------------------
# Stage 2 — runtime. 2.4 MB base, no shell, no libc, no package manager.
# ---------------------------------------------------------------------------
FROM gcr.io/distroless/static-debian12:nonroot@sha256:3f2b64ef97bd285e36132c684e6b2ae8f2fb1fa8bda9c0e5b3f0bd1f1b12e26f

COPY --from=build --chown=65532:65532 /out/webapp /usr/local/bin/webapp

# Numeric UID:GID — mandatory for securityContext.runAsNonRoot (see §5.4, F-05).
USER 65532:65532

EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/webapp"]
```

Build and measure:

```console
$ DOCKER_BUILDKIT=1 docker build -f Dockerfile.bad -t webapp:fat .
$ DOCKER_BUILDKIT=1 docker build -f Dockerfile     -t webapp:min --build-arg VERSION=1.4.2 .

$ docker image ls --format 'table {{.Repository}}:{{.Tag}}\t{{.Size}}' | grep webapp
REPOSITORY:TAG    SIZE
webapp:fat        847MB
webapp:min        9.51MB
```

```console
$ trivy image --scanners vuln --severity HIGH,CRITICAL --quiet webapp:fat
webapp:fat (ubuntu 24.04)
=========================
Total: 34 (HIGH: 31, CRITICAL: 3)

┌──────────────────┬────────────────┬──────────┬──────────────┬───────────────┐
│     Library      │ Vulnerability  │ Severity │   Status     │ Installed Ver │
├──────────────────┼────────────────┼──────────┼──────────────┼───────────────┤
│ libssl3t64       │ CVE-2024-XXXXX │ HIGH     │ fixed        │ 3.0.13-0ub…   │
│ perl-base        │ CVE-2024-XXXXX │ HIGH     │ will_not_fix │ 5.38.2-3.2    │
│ ...              │                │          │              │               │
└──────────────────┴────────────────┴──────────┴──────────────┴───────────────┘

$ trivy image --scanners vuln --severity HIGH,CRITICAL --quiet webapp:min
webapp:min (debian 12.8)
========================
Total: 0 (HIGH: 0, CRITICAL: 0)

/usr/local/bin/webapp (gobinary)
================================
Total: 0 (HIGH: 0, CRITICAL: 0)
```

Prove the attacker surface is gone:

```console
$ docker run --rm -it webapp:min sh
docker: Error response from daemon: failed to create task for container:
failed to create shim task: OCI runtime create failed: runc create failed:
unable to start container process: exec: "sh": executable file not found in $PATH: unknown.

$ docker run --rm --entrypoint /bin/ls webapp:min /
docker: Error response from daemon: ... exec: "/bin/ls": stat /bin/ls: no such file or directory

$ docker run --rm webapp:min &
$ docker exec -it <id> id
OCI runtime exec failed: exec failed: unable to start container process:
exec: "id": executable file not found in $PATH: unknown
```

### 3.3 When CGO is unavoidable — distroless `base`

```dockerfile
# syntax=docker/dockerfile:1.9
FROM golang:1.23.4-bookworm AS build
WORKDIR /src
RUN apt-get update && apt-get install -y --no-install-recommends \
        libsqlite3-dev pkg-config \
    && rm -rf /var/lib/apt/lists/*
COPY . .
RUN CGO_ENABLED=1 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/app .

# Enumerate the exact shared objects the binary needs, and nothing else.
RUN mkdir -p /out/libs && \
    ldd /out/app | awk '/=> \//{print $3}' | xargs -I{} cp -v --parents {} /out/libs && \
    cp -v --parents /lib64/ld-linux-x86-64.so.2 /out/libs

FROM gcr.io/distroless/base-debian12:nonroot
COPY --from=build /out/libs/ /
COPY --from=build /out/app /usr/local/bin/app
USER 65532:65532
ENTRYPOINT ["/usr/local/bin/app"]
```

### 3.4 JVM — `jdeps` + `jlink` custom runtime

The generic `distroless/java21` image ships a full JDK-derived runtime (~190 MB). A `jlink` runtime containing only the modules your app resolves is typically 45–70 MB and removes entire attack surfaces (`jdk.attach`, `java.rmi`, `jdk.jshell`, the `jcmd`/`jstack` tooling).

```dockerfile
# syntax=docker/dockerfile:1.9
# ---------------------------------------------------------------------------
FROM eclipse-temurin:21.0.5_11-jdk-jammy AS build
WORKDIR /src
COPY . .
RUN ./mvnw -B -q -DskipTests package

# ---------------------------------------------------------------------------
FROM eclipse-temurin:21.0.5_11-jdk-jammy AS jre-build
WORKDIR /build
COPY --from=build /src/target/app.jar app.jar

# jdeps resolves the module graph actually reachable from the fat jar.
RUN jdeps \
      --ignore-missing-deps \
      --print-module-deps \
      --multi-release 21 \
      --recursive \
      app.jar > /build/deps.txt \
    && cat /build/deps.txt

RUN jlink \
      --add-modules "$(cat /build/deps.txt),jdk.crypto.ec" \
      --strip-debug \
      --no-man-pages \
      --no-header-files \
      --compress=zip-6 \
      --output /javaruntime \
    && /javaruntime/bin/java --version

# ---------------------------------------------------------------------------
FROM gcr.io/distroless/base-debian12:nonroot
ENV JAVA_HOME=/opt/java
ENV PATH="${JAVA_HOME}/bin:${PATH}"
COPY --from=jre-build /javaruntime ${JAVA_HOME}
COPY --from=jre-build /build/app.jar /app/app.jar
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/opt/java/bin/java", \
            "-XX:MaxRAMPercentage=75.0", \
            "-XX:+ExitOnOutOfMemoryError", \
            "-Djava.security.egd=file:/dev/urandom", \
            "-jar", "/app/app.jar"]
```

```console
$ docker build -t svc:jvm .
...
#14 [jre-build 4/4] RUN jdeps ... > /build/deps.txt
#14 1.882 java.base,java.logging,java.management,java.naming,java.sql,java.xml
#14 DONE 2.1s

$ docker image ls svc:jvm --format '{{.Size}}'
118MB          # vs 341MB for eclipse-temurin:21-jre-jammy + jar
```

> `--add-modules "$(cat deps.txt),jdk.crypto.ec"` — `jdeps` performs *static* analysis and systematically misses reflection- and ServiceLoader-loaded modules. `jdk.crypto.ec` (needed for ECDHE TLS), `jdk.localedata`, and JDBC drivers are the usual omissions. Always add them explicitly and validate with an integration test, not just a startup check.

### 3.5 Node.js — distroless `nodejs`

```dockerfile
# syntax=docker/dockerfile:1.9
FROM node:22.11.0-bookworm AS deps
WORKDIR /app
COPY package.json package-lock.json ./
RUN --mount=type=cache,target=/root/.npm \
    npm ci --omit=dev --ignore-scripts

FROM node:22.11.0-bookworm AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN --mount=type=cache,target=/root/.npm npm ci --ignore-scripts
COPY . .
RUN npm run build && npm prune --omit=dev

# ENTRYPOINT of this base is already ["/nodejs/bin/node"] — CMD supplies args only.
FROM gcr.io/distroless/nodejs22-debian12:nonroot
WORKDIR /app
COPY --from=deps  --chown=65532:65532 /app/node_modules ./node_modules
COPY --from=build --chown=65532:65532 /app/dist          ./dist
COPY --from=build --chown=65532:65532 /app/package.json  ./
USER 65532:65532
ENV NODE_ENV=production
EXPOSE 3000
CMD ["dist/server.js"]
```

`--ignore-scripts` on `npm ci` is a supply-chain control, not a footprint one: it blocks `postinstall` hooks, the single most exploited npm attack vector. Where a package genuinely needs its build script, run it in the *build* stage only.

### 3.6 Python — the hard case

Python cannot be statically linked, and the interpreter + stdlib is irreducibly ~40 MB. The realistic target is: no compiler, no `pip`, no shell in the final image.

```dockerfile
# syntax=docker/dockerfile:1.9
FROM python:3.12.7-slim-bookworm AS build

ENV PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PYTHONDONTWRITEBYTECODE=1

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential libpq-dev \
    && rm -rf /var/lib/apt/lists/*

# Self-contained venv: everything the runtime needs lives under one prefix.
RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:${PATH}"

COPY requirements.txt .
# --require-hashes turns requirements.txt into an integrity manifest.
RUN pip install --require-hashes -r requirements.txt

COPY src/ /app/

# ---------------------------------------------------------------------------
FROM gcr.io/distroless/python3-debian12:nonroot

COPY --from=build --chown=65532:65532 /opt/venv /opt/venv
COPY --from=build --chown=65532:65532 /app      /app

ENV PYTHONPATH="/opt/venv/lib/python3.12/site-packages" \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

WORKDIR /app
USER 65532:65532
EXPOSE 8000
# ENTRYPOINT of this base is /usr/bin/python3.
CMD ["-m", "gunicorn", "--bind", "0.0.0.0:8000", "--workers", "2", "app:application"]
```

> **Caveats you must know.** `gcr.io/distroless/python3-*` is marked *experimental* upstream and its Python minor version tracks Debian's, so the venv's `site-packages` path must match the base's interpreter version or imports fail silently at runtime. A production-grade alternative is `cgr.dev/chainguard/python:latest` (glibc, Wolfi, versioned interpreter, signed + SBOM), or `ubi9/ubi-micro` with the Python RPMs installed from a `ubi9` builder stage via `dnf --installroot`.

### 3.7 If you must keep a package manager at build time

```dockerfile
# Debian/Ubuntu
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates=20230311 \
      curl=7.88.1-10+deb12u8 \
 && apt-get purge -y --auto-remove \
 && rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*

# Alpine
RUN apk add --no-cache ca-certificates=20240705-r0 tzdata=2024b-r0

# UBI — install into an empty root, then COPY that root into ubi-micro
FROM registry.access.redhat.com/ubi9/ubi:9.5 AS installer
RUN mkdir -p /mnt/rootfs \
 && dnf install -y --installroot /mnt/rootfs --releasever 9 \
      --setopt install_weak_deps=false --nodocs \
      python3.12 \
 && dnf --installroot /mnt/rootfs clean all \
 && rm -rf /mnt/rootfs/var/cache/* /mnt/rootfs/var/log/dnf* /mnt/rootfs/var/log/yum.*

FROM registry.access.redhat.com/ubi9/ubi-micro:9.5
COPY --from=installer /mnt/rootfs /
```

`--no-install-recommends` alone typically removes 30–60% of a Debian install's transitive packages. Version-pinning every package is what makes the build reproducible; without it, `apt-get install curl` returns a different binary next Tuesday and your digest-based attestations become meaningless.

### 3.8 Hardening the final layer

Apply these in the **last stage** when the base is not already distroless:

```dockerfile
# 1. Remove every setuid/setgid bit — kills local privesc primitives.
RUN find / -xdev \( -perm -4000 -o -perm -2000 \) -type f -exec chmod ug-s {} + 2>/dev/null || true

# 2. Remove file capabilities (ping, etc.) — invisible to `find -perm`.
RUN command -v setcap >/dev/null && \
    getcap -r / 2>/dev/null | cut -d' ' -f1 | xargs -r setcap -r || true

# 3. Remove shells and package managers if the base insisted on shipping them.
RUN rm -rf /usr/bin/apt* /usr/bin/dpkg* /sbin/apk /usr/bin/wget /usr/bin/curl \
           /bin/sh /bin/bash /usr/bin/nc /usr/bin/netcat

# 4. Create a numeric non-root identity if the base has none.
RUN echo 'app:x:10001:10001::/nonexistent:/sbin/nologin' >> /etc/passwd && \
    echo 'app:x:10001:' >> /etc/group

USER 10001:10001
```

Verify:

```console
$ docker run --rm --entrypoint /bin/sh webapp:hardened -c 'find / -xdev -perm /6000 -type f 2>/dev/null'
# (no output — but note: you needed a shell to run this. Do it in the build stage,
#  or from outside with `docker export | tar tv`, see §5.1)

$ docker export $(docker create webapp:min) | tar -tvf - | awk '$1 ~ /^[-l]/ && $1 ~ /s/'
# empty → no setuid/setgid files in the image at all
```

### 3.9 Reproducibility: pin by digest, not by tag

A tag is a mutable pointer. `FROM alpine:3.20` today and tomorrow can be different images with different CVE sets, which breaks incident forensics ("which image was actually running?") and defeats any attestation.

```console
$ crane digest gcr.io/distroless/static-debian12:nonroot
sha256:3f2b64ef97bd285e36132c684e6b2ae8f2fb1fa8bda9c0e5b3f0bd1f1b12e26f

$ docker buildx imagetools inspect gcr.io/distroless/static-debian12:nonroot
Name:      gcr.io/distroless/static-debian12:nonroot
MediaType: application/vnd.oci.image.index.v1+json
Digest:    sha256:3f2b64ef97bd285e36132c684e6b2ae8f2fb1fa8bda9c0e5b3f0bd1f1b12e26f

Manifests:
  Name:      gcr.io/distroless/static-debian12:nonroot@sha256:1c2b...
  Platform:  linux/amd64
  Name:      gcr.io/distroless/static-debian12:nonroot@sha256:9d4e...
  Platform:  linux/arm64
```

Pin **the index digest** (multi-arch safe) in the Dockerfile, and automate bumps with Renovate/Dependabot so pinning does not become "frozen and unpatched" — the failure mode that makes teams abandon pinning.

For byte-identical rebuilds, also normalize timestamps:

```console
$ SOURCE_DATE_EPOCH=$(git log -1 --pretty=%ct) \
  docker buildx build --build-arg SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH \
    --output type=image,name=webapp:min,rewrite-timestamp=true .
```

### 3.10 Layer hygiene — secrets are forever

```dockerfile
# WRONG — the token is in layer 3 forever, regardless of the rm in layer 4.
COPY .npmrc /root/.npmrc
RUN npm ci
RUN rm /root/.npmrc

# RIGHT — BuildKit secret mount: never materialized in any layer.
RUN --mount=type=secret,id=npmrc,target=/root/.npmrc,uid=0 \
    npm ci --omit=dev
```

```console
$ docker buildx build --secret id=npmrc,src=$HOME/.npmrc -t app:build .
```

Detect leaks in an existing image:

```console
$ docker history --no-trunc --format '{{.Size}}\t{{.CreatedBy}}' webapp:fat | head -5
121MB   /bin/sh -c apt-get update && apt-get install -y golang-go ca-certificates curl vim net-tools
0B      /bin/sh -c #(nop) COPY dir:8a3f... in /src
6.15MB  /bin/sh -c go build -o /usr/local/bin/webapp .

$ docker save webapp:fat -o /tmp/fat.tar && trivy image --scanners secret --input /tmp/fat.tar
```

---

## 4. The Kubernetes side — making the minimal image pay off

A minimal image without a matching `securityContext` leaves most of the benefit on the table. This is the manifest a CKS grader expects.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: webapp
  namespace: prod
  labels:
    app.kubernetes.io/name: webapp
spec:
  replicas: 3
  revisionHistoryLimit: 3
  selector:
    matchLabels:
      app.kubernetes.io/name: webapp
  template:
    metadata:
      labels:
        app.kubernetes.io/name: webapp
    spec:
      automountServiceAccountToken: false      # the app never calls the API server
      serviceAccountName: webapp
      # Pod-level context: applies to every container unless overridden.
      securityContext:
        runAsNonRoot: true
        runAsUser: 65532
        runAsGroup: 65532
        fsGroup: 65532
        seccompProfile:
          type: RuntimeDefault                 # blocks ~44 dangerous syscalls
      containers:
        - name: webapp
          # Digest-pinned: the tag is documentation, the digest is the contract.
          image: registry.example.com/team/webapp:1.4.2@sha256:5b7e2c9d1a4f8e6b0c3d2a1f9e8d7c6b5a4f3e2d1c0b9a8f7e6d5c4b3a2f1e0d
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 8080
              protocol: TCP
          securityContext:
            allowPrivilegeEscalation: false    # no_new_privs; neutralizes any setuid bit
            privileged: false
            readOnlyRootFilesystem: true       # no writable path => no dropped payloads
            capabilities:
              drop: ["ALL"]                    # not even NET_BIND_SERVICE (we bind 8080)
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 500m
              memory: 128Mi
              ephemeral-storage: 256Mi
          # The image has no shell — probes MUST be httpGet/tcpSocket, never exec.
          startupProbe:
            httpGet: { path: /healthz, port: http }
            failureThreshold: 30
            periodSeconds: 2
          livenessProbe:
            httpGet: { path: /healthz, port: http }
            periodSeconds: 10
            timeoutSeconds: 2
          readinessProbe:
            httpGet: { path: /healthz, port: http }
            periodSeconds: 5
            timeoutSeconds: 2
          volumeMounts:
            - name: tmp
              mountPath: /tmp
            - name: cache
              mountPath: /var/cache/app
      volumes:
        # readOnlyRootFilesystem makes these the ONLY writable paths, and they are
        # mounted noexec/nosuid/nodev-equivalent from the workload's point of view
        # because the kernel still honours the emptyDir's mount options on the node.
        - name: tmp
          emptyDir:
            medium: Memory
            sizeLimit: 32Mi
        - name: cache
          emptyDir:
            sizeLimit: 128Mi
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: webapp
  namespace: prod
automountServiceAccountToken: false
---
apiVersion: v1
kind: Service
metadata:
  name: webapp
  namespace: prod
spec:
  selector:
    app.kubernetes.io/name: webapp
  ports:
    - name: http
      port: 80
      targetPort: http
```

Namespace-level baseline via Pod Security Admission:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: prod
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: v1.34
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/audit-version: v1.34
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/warn-version: v1.34
```

### 4.1 Enforcing image provenance with ValidatingAdmissionPolicy (no external controller)

`ValidatingAdmissionPolicy` reached GA in v1.30 and is the in-tree, CEL-based way to enforce image rules on a 1.34 cluster. This is exam-relevant because it needs no Helm chart and no webhook TLS.

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: minimal-image-policy
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - apiGroups:   [""]
        apiVersions: ["v1"]
        operations:  ["CREATE", "UPDATE"]
        resources:   ["pods"]
  variables:
    - name: allContainers
      expression: >-
        object.spec.containers +
        (has(object.spec.initContainers) ? object.spec.initContainers : []) +
        (has(object.spec.ephemeralContainers) ? object.spec.ephemeralContainers : [])
    - name: allowedRegistries
      expression: "['registry.example.com/', 'gcr.io/distroless/', 'cgr.dev/chainguard/']"
  validations:
    # 1. Registry allow-list.
    - expression: >-
        variables.allContainers.all(c,
          variables.allowedRegistries.exists(r, c.image.startsWith(r)))
      message: "image must come from an approved registry (registry.example.com, gcr.io/distroless, cgr.dev/chainguard)"
      reason: Forbidden

    # 2. Digest pinning — rejects :latest and every mutable tag.
    - expression: "variables.allContainers.all(c, c.image.contains('@sha256:'))"
      message: "image must be pinned by digest (name:tag@sha256:...)"
      reason: Forbidden

    # 3. Refuse the distroless :debug variants in this cluster.
    - expression: "variables.allContainers.all(c, !c.image.contains(':debug'))"
      message: "distroless :debug images ship a shell and are not allowed here"
      reason: Forbidden

    # 4. Enforce the securityContext that makes a minimal image worth having.
    - expression: >-
        variables.allContainers.all(c,
          has(c.securityContext) &&
          has(c.securityContext.readOnlyRootFilesystem) &&
          c.securityContext.readOnlyRootFilesystem == true)
      message: "readOnlyRootFilesystem: true is required"
      reason: Forbidden
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: minimal-image-policy-binding
spec:
  policyName: minimal-image-policy
  validationActions: ["Deny", "Audit"]
  matchResources:
    namespaceSelector:
      matchExpressions:
        - key: kubernetes.io/metadata.name
          operator: NotIn
          values: ["kube-system", "kube-node-lease"]
```

```console
$ kubectl apply -f vap-minimal-image.yaml
validatingadmissionpolicy.admissionregistration.k8s.io/minimal-image-policy created
validatingadmissionpolicybinding.admissionregistration.k8s.io/minimal-image-policy-binding created

$ kubectl -n prod run bad --image=nginx:latest
Error from server (Forbidden): admission webhook denied the request:
ValidatingAdmissionPolicy 'minimal-image-policy' with binding 'minimal-image-policy-binding'
denied request: image must come from an approved registry
(registry.example.com, gcr.io/distroless, cgr.dev/chainguard)

$ kubectl -n prod run dbg --image=gcr.io/distroless/static-debian12:debug-nonroot
Error from server (Forbidden): ... denied request: image must be pinned by digest (name:tag@sha256:...)
```

Equivalent Kyverno policy, for clusters that already run it:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: restrict-image-footprint
spec:
  validationFailureAction: Enforce
  background: true
  rules:
    - name: allowed-registries
      match:
        any:
          - resources:
              kinds: ["Pod"]
      exclude:
        any:
          - resources:
              namespaces: ["kube-system"]
      validate:
        message: "Images must originate from an approved minimal-base registry."
        pattern:
          spec:
            =(ephemeralContainers):
              - image: "registry.example.com/* | gcr.io/distroless/* | cgr.dev/chainguard/*"
            =(initContainers):
              - image: "registry.example.com/* | gcr.io/distroless/* | cgr.dev/chainguard/*"
            containers:
              - image: "registry.example.com/* | gcr.io/distroless/* | cgr.dev/chainguard/*"
    - name: require-digest
      match:
        any:
          - resources:
              kinds: ["Pod"]
      validate:
        message: "Images must be referenced by digest."
        foreach:
          - list: "request.object.spec.containers"
            deny:
              conditions:
                all:
                  - key: "{{ contains(element.image, '@sha256:') }}"
                    operator: Equals
                    value: false
```

### 4.2 Node-level: kubelet image garbage collection

```yaml
# /var/lib/kubelet/config.yaml  (KubeletConfiguration)
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
imageGCHighThresholdPercent: 80    # start GC when imagefs usage exceeds this
imageGCLowThresholdPercent: 65     # GC until usage drops below this
imageMinimumGCAge: 5m              # never delete images younger than this
imageMaximumGCAge: 168h            # delete unused images older than 7 days (v1.30+)
serializeImagePulls: false
maxParallelImagePulls: 5
evictionHard:
  imagefs.available: "10%"
  nodefs.available: "10%"
```

```console
$ sudo systemctl restart kubelet
$ kubectl get --raw "/api/v1/nodes/node-1/proxy/configz" | jq '.kubeletconfig | {imageGCHighThresholdPercent, imageMaximumGCAge}'
{
  "imageGCHighThresholdPercent": 80,
  "imageMaximumGCAge": "168h0m0s"
}
```

---

## 5. Verification and failure diagnosis

### 5.1 Inspecting an image without running it

This is the skill that separates an operator from a user: you cannot `exec` into a distroless image, so all inspection must happen from outside.

```console
# Full config: entrypoint, user, env, architecture — no pull of the layers needed for the config alone
$ crane config gcr.io/distroless/static-debian12:nonroot | jq '{user: .config.User, entrypoint: .config.Entrypoint, arch: .architecture, os: .os}'
{
  "user": "65532:65532",
  "entrypoint": null,
  "arch": "amd64",
  "os": "linux"
}

# Enumerate every file in the image without executing anything
$ crane export webapp:min - | tar -tvf - | head -20
drwxr-xr-x  0/0               0 2026-08-04 00:00 etc/
-rw-r--r--  0/0             363 1970-01-01 00:00 etc/passwd
-rw-r--r--  0/0             225 1970-01-01 00:00 etc/group
-rw-r--r--  0/0              41 1970-01-01 00:00 etc/nsswitch.conf
drwxr-xr-x  0/0               0 1970-01-01 00:00 etc/ssl/certs/
-rw-r--r--  0/0          200330 1970-01-01 00:00 etc/ssl/certs/ca-certificates.crt
drwxrwxrwt  0/0               0 1970-01-01 00:00 tmp/
drwxr-xr-x  0/0               0 1970-01-01 00:00 usr/share/zoneinfo/
-rwxr-xr-x  65532/65532 7208960 1970-01-01 00:00 usr/local/bin/webapp

# Count executables — the real "footprint" metric
$ crane export webapp:min - | tar -tvf - | awk '$1 ~ /x/ && $1 ~ /^-/ {n++} END {print n" executable files"}'
1 executable files

$ crane export webapp:fat - | tar -tvf - | awk '$1 ~ /x/ && $1 ~ /^-/ {n++} END {print n" executable files"}'
1743 executable files

# Any setuid/setgid?
$ crane export webapp:fat - | tar -tvf - | awk '$1 ~ /s/ {print $1, $6}'
-rwsr-xr-x usr/bin/passwd
-rwsr-xr-x usr/bin/su
-rwsr-xr-x usr/bin/chsh
-rwsr-xr-x usr/bin/mount
-rwxr-sr-x usr/bin/wall

# Layer-by-layer waste analysis
$ dive webapp:fat --ci --lowestEfficiency=0.95
Analyzing image...
efficiency: 78.3141 %
wastedBytes: 141283042 bytes (141 MB)
userWastedPercent: 16.6721 %
Result:FAIL  [Total:3] [Passed:2] [Failed:1]

# Skopeo works without a Docker daemon — useful on exam nodes
$ skopeo inspect docker://gcr.io/distroless/static-debian12:nonroot | jq '{Digest, Layers: (.Layers|length)}'
{
  "Digest": "sha256:3f2b64ef97bd285e36132c684e6b2ae8f2fb1fa8bda9c0e5b3f0bd1f1b12e26f",
  "Layers": 2
}
```

Reproducible size table generator:

```bash
#!/usr/bin/env bash
# bases.sh — reproduce the §2.1 table on your own architecture
set -euo pipefail
BASES=(
  "gcr.io/distroless/static-debian12:nonroot"
  "gcr.io/distroless/base-debian12:nonroot"
  "gcr.io/distroless/cc-debian12:nonroot"
  "cgr.dev/chainguard/static:latest"
  "alpine:3.20"
  "debian:12-slim"
  "ubuntu:24.04"
  "registry.access.redhat.com/ubi9/ubi-micro:9.5"
  "registry.access.redhat.com/ubi9/ubi-minimal:9.5"
)
printf '%-55s %10s %8s %8s\n' IMAGE SIZE HIGH CRIT
for b in "${BASES[@]}"; do
  docker pull -q "$b" >/dev/null
  size=$(docker image inspect "$b" --format '{{.Size}}' | numfmt --to=iec)
  json=$(trivy image --quiet --format json --scanners vuln "$b")
  high=$(jq '[.Results[]?.Vulnerabilities[]? | select(.Severity=="HIGH")]  | length' <<<"$json")
  crit=$(jq '[.Results[]?.Vulnerabilities[]? | select(.Severity=="CRITICAL")] | length' <<<"$json")
  printf '%-55s %10s %8s %8s\n' "$b" "$size" "$high" "$crit"
done
```

### 5.2 Scanning and SBOM

```console
$ trivy image --scanners vuln,secret,misconfig --severity HIGH,CRITICAL \
      --exit-code 1 --ignore-unfixed registry.example.com/team/webapp:1.4.2
2026-08-04T11:02:14Z  INFO  Vulnerability scanning is enabled
2026-08-04T11:02:14Z  INFO  Secret scanning is enabled
registry.example.com/team/webapp:1.4.2 (debian 12.8)
Total: 0 (HIGH: 0, CRITICAL: 0)

/usr/local/bin/webapp (gobinary)
Total: 0 (HIGH: 0, CRITICAL: 0)

$ echo $?
0

# Generate and store an SBOM alongside the image
$ syft registry.example.com/team/webapp:1.4.2 -o spdx-json=sbom.spdx.json
 ✔ Parsed image        sha256:5b7e2c9d1a4f...
 ✔ Cataloged contents  sha256:5b7e2c9d1a4f...
   ├── ✔ Packages           [4 packages]
   └── ✔ Executables        [1 executables]

$ jq -r '.packages[].name' sbom.spdx.json
base-files
ca-certificates
netbase
tzdata

$ grype sbom:sbom.spdx.json --fail-on high
 ✔ Scanned for vulnerabilities     [0 vulnerability matches]
No vulnerabilities found
```

Four packages. That is the entire OS-level maintenance surface of the service.

### 5.3 Debugging a container that has no shell

**This is the operational cost of minimal images and the exam's favourite follow-up question.** You cannot `kubectl exec -it pod -- sh`. Three techniques, in order of preference:

**(a) Ephemeral container sharing the target's process namespace**

```console
$ kubectl -n prod debug -it webapp-6f8d9c7b54-x2n4p \
    --image=busybox:1.36 \
    --target=webapp \
    --profile=general \
    -- sh
Targeting container "webapp". If you don't see processes from this container it may be
because the container runtime doesn't support this feature.
Defaulting debug container name to debugger-mqz7k.
If you don't see a command prompt, try pressing enter.

/ # ps aux
PID   USER     COMMAND
    1 65532    /usr/local/bin/webapp
   14 root     sh
   21 root     ps aux

/ # ls /proc/1/root/usr/local/bin/
webapp

/ # cat /proc/1/environ | tr '\0' '\n'
PATH=/usr/local/bin:/usr/bin:/bin
HOSTNAME=webapp-6f8d9c7b54-x2n4p
HOME=/home/nonroot

/ # wget -qO- http://localhost:8080/healthz
ok

/ # cat /proc/1/net/tcp | head -3
  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid
   0: 00000000:1F90 00000000:0000 0A 00000000:00000000 00:00000000 00000000 65532
```

`--target=<container>` is what shares the PID namespace, giving you `/proc/1/root` — a full view of the target's filesystem from a container that *does* have tools. Without `--target`, you only share the network namespace.

**(b) Node-level debugging via `kubectl debug node/`**

```console
$ kubectl debug node/worker-2 -it --image=busybox:1.36
Creating debugging pod node-debugger-worker-2-hb4kq with container debugger on node worker-2.

/ # chroot /host
# crictl ps --name webapp
CONTAINER      IMAGE          CREATED         STATE     NAME      POD ID
7d9a1c4e2b8f3  5b7e2c9d1a4f   18 minutes ago  Running   webapp    2f8e1a9c7d3b5

# crictl inspect 7d9a1c4e2b8f3 | jq '.info.pid, .status.image.image'
14472
"registry.example.com/team/webapp@sha256:5b7e2c9d1a4f..."

# nsenter -t 14472 -m -n -p -- /usr/local/bin/webapp --version
webapp 1.4.2

# ls -l /proc/14472/root/
total 0
drwxr-xr-x 2 root root 60 Aug  4 11:02 etc
drwxrwxrwt 2 root root 40 Aug  4 11:02 tmp
drwxr-xr-x 3 root root 60 Aug  4 11:02 usr
```

**(c) Rebuild once with the `:debug` tag — never ship it**

```console
$ docker build --build-arg BASE=gcr.io/distroless/static-debian12:debug-nonroot -t webapp:dbg .
$ kubectl -n staging set image deploy/webapp webapp=registry.example.com/team/webapp:dbg
$ kubectl -n staging exec -it deploy/webapp -- /busybox/sh
/ $ id
uid=65532(nonroot) gid=65532(nonroot)
```

> Ephemeral containers cannot be removed from a pod once added, and they bypass namespace-level PSA `restricted` only if your VAP/Kyverno policies explicitly allow `ephemeralContainers` — which is why the policy in §4.1 includes them in `variables.allContainers`. Grant `pods/ephemeralcontainers` RBAC deliberately; it is effectively "exec into anything with any image".

### 5.4 Failure catalogue — symptom → root cause → fix

| ID | Symptom (exact string) | Root cause | Fix |
|---|---|---|---|
| F-01 | `exec /usr/local/bin/app: no such file or directory` — *and the file demonstrably exists* | Binary is dynamically linked; the kernel cannot find the ELF interpreter `/lib64/ld-linux-x86-64.so.2`, which is absent from `scratch`/`static` | `CGO_ENABLED=0`, or switch to `distroless/base` and copy the `ldd` closure (§3.3) |
| F-02 | `sh: /app/bin/svc: not found` on Alpine | glibc-linked binary on musl — BusyBox reports the missing loader as "not found" | Build with the musl target (`GOOS=linux CGO_ENABLED=0`, or `--target x86_64-unknown-linux-musl` for Rust), or use a glibc base |
| F-03 | `x509: certificate signed by unknown authority` | No `/etc/ssl/certs/ca-certificates.crt` on `scratch` | Use `distroless/static` (bundle included), or `COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/` |
| F-04 | `open /tmp/upload-9182: no such file or directory` | `scratch` has no `/tmp`; or `readOnlyRootFilesystem: true` with no `emptyDir` at `/tmp` | Use distroless (`/tmp` mode 1777) **and** mount an `emptyDir` at `/tmp` |
| F-05 | Pod stuck `CreateContainerConfigError`: `container has runAsNonRoot and image has non-numeric user (nonroot), cannot verify user is non-root` | Kubelet cannot resolve a *named* `USER` at admission time — it has no access to `/etc/passwd` inside the image | Use a numeric `USER 65532:65532` in the Dockerfile **or** set `securityContext.runAsUser: 65532` |
| F-06 | `user: unknown userid 65532` (Go `user.Current()`, Java `System.getProperty("user.name")`) | `/etc/passwd` lacks an entry for the running UID | Use the `:nonroot` distroless tag, or append the entry (§3.8 step 4) |
| F-07 | `time: missing Location in call to Time.In` / all timestamps UTC | No `/usr/share/zoneinfo` | `import _ "time/tzdata"` (Go), or `COPY --from=build /usr/share/zoneinfo /usr/share/zoneinfo` |
| F-08 | Intermittent `lookup svc.ns.svc.cluster.local: no such host` on Alpine | musl < 1.2.4 has no DNS TCP fallback; responses > 512 B (large headless Services) are truncated and dropped | Alpine ≥ 3.18, or reduce `ndots`/search domains via `dnsConfig`, or move off musl |
| F-09 | `exec /app: exec format error` | Image architecture ≠ node architecture (amd64 image on arm64 node) | `crane config <img> \| jq .architecture`; rebuild with `docker buildx build --platform linux/amd64,linux/arm64` |
| F-10 | Container starts, then `read-only file system` on first write | `readOnlyRootFilesystem: true`, app writes outside a mounted volume | Identify the paths (`strace` via ephemeral container, or app docs) and add `emptyDir` mounts; do **not** disable the flag |
| F-11 | `Error: Cannot find module '/app/dist/server.js'` on distroless nodejs | The base's `ENTRYPOINT` is already `node`; a `CMD ["node", "dist/server.js"]` becomes `node node dist/server.js` | `CMD ["dist/server.js"]` only |
| F-12 | `java.lang.NoClassDefFoundError: javax.naming.*` after jlink | `jdeps` missed a reflectively-loaded module | Add explicitly: `--add-modules $(cat deps.txt),java.naming,jdk.crypto.ec,jdk.localedata` |
| F-13 | `Liveness probe failed: OCI runtime exec failed: exec: "sh": executable file not found` | `exec` probe against a shell-less image | Convert probes to `httpGet` or `tcpSocket` |
| F-14 | `ImportError: cannot import name ... from 'site-packages'` on distroless python | venv built against a different Python minor version than the base ships | Match interpreter versions exactly, or move to `cgr.dev/chainguard/python` |
| F-15 | Scanner reports `Total: 0` on a `scratch` image with obvious old libraries | No package database → nothing to enumerate; this is a *blind spot*, not a clean bill of health | Use distroless (ships `/var/lib/dpkg/status.d/`); scan the language layer explicitly (`trivy fs`, `syft` on the binary) |

Reproduction of F-01, the one worth doing by hand:

```console
$ CGO_ENABLED=1 go build -o webapp . && docker build -f - -t webapp:broken . <<'EOF'
FROM gcr.io/distroless/static-debian12:nonroot
COPY webapp /webapp
ENTRYPOINT ["/webapp"]
EOF

$ docker run --rm webapp:broken
exec /webapp: no such file or directory

$ file webapp
webapp: ELF 64-bit LSB pie executable, x86-64, dynamically linked,
        interpreter /lib64/ld-linux-x86-64.so.2, Go BuildID=..., not stripped

$ ldd webapp
	linux-vdso.so.1 (0x00007ffd4b3f2000)
	libresolv.so.2 => /lib/x86_64-linux-gnu/libresolv.so.2 (0x00007f2a8c1f4000)
	libc.so.6 => /lib/x86_64-linux-gnu/libc.so.6 (0x00007f2a8c000000)
	/lib64/ld-linux-x86-64.so.2 (0x00007f2a8c21e000)

$ CGO_ENABLED=0 go build -o webapp . && file webapp
webapp: ELF 64-bit LSB executable, x86-64, statically linked, Go BuildID=..., stripped
```

---

## 6. CI enforcement

```yaml
# .github/workflows/build.yaml
name: build-and-harden
on:
  push:
    branches: [main]

permissions:
  contents: read
  packages: write
  id-token: write        # for keyless cosign signing

jobs:
  image:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v4

      - name: Set up Buildx
        uses: docker/setup-buildx-action@v3

      - name: Build (load locally, do not push yet)
        uses: docker/build-push-action@v6
        with:
          context: .
          load: true
          tags: webapp:candidate
          provenance: mode=max
          sbom: true
          build-args: |
            VERSION=${{ github.sha }}
            SOURCE_DATE_EPOCH=0

      # Gate 1 — footprint budget. A regression here means someone added a base layer.
      - name: Enforce size budget
        run: |
          BYTES=$(docker image inspect webapp:candidate --format '{{.Size}}')
          MAX=$((30 * 1024 * 1024))
          echo "image size: $((BYTES/1024/1024)) MiB (budget $((MAX/1024/1024)) MiB)"
          [ "$BYTES" -le "$MAX" ] || { echo "::error::image exceeds size budget"; exit 1; }

      # Gate 2 — no shell, no package manager, no setuid.
      - name: Enforce executable surface
        run: |
          docker create --name c webapp:candidate
          docker export c | tar -tvf - > /tmp/files.txt
          docker rm c
          if grep -Eq '(bin/(ba|a|da|z|)sh|bin/busybox|bin/apt|bin/dpkg|sbin/apk|bin/dnf|bin/microdnf)$' /tmp/files.txt; then
            echo "::error::shell or package manager present in final image"; grep -E 'sh$|apt|apk|dnf' /tmp/files.txt; exit 1
          fi
          if awk '$1 ~ /^-.*s/' /tmp/files.txt | grep -q .; then
            echo "::error::setuid/setgid binaries present"; awk '$1 ~ /^-.*s/' /tmp/files.txt; exit 1
          fi

      # Gate 3 — non-root numeric user.
      - name: Enforce non-root numeric UID
        run: |
          USER=$(docker image inspect webapp:candidate --format '{{.Config.User}}')
          echo "image USER = '${USER}'"
          case "$USER" in
            ""|root|0|0:*) echo "::error::image runs as root"; exit 1 ;;
            [0-9]*)        echo "ok: numeric UID" ;;
            *)             echo "::error::USER must be numeric for runAsNonRoot"; exit 1 ;;
          esac

      # Gate 4 — vulnerabilities.
      - name: Trivy scan
        uses: aquasecurity/trivy-action@0.28.0
        with:
          image-ref: webapp:candidate
          format: sarif
          output: trivy.sarif
          severity: HIGH,CRITICAL
          ignore-unfixed: true
          exit-code: '1'

      - name: Upload SARIF
        if: always()
        uses: github/codeql-action/upload-sarif@v3
        with:
          sarif_file: trivy.sarif

      # Gate 5 — Dockerfile static analysis (CKS 4.4 overlap).
      - name: Hadolint
        uses: hadolint/hadolint-action@v3.1.0
        with:
          dockerfile: Dockerfile
          failure-threshold: warning

      - name: Push and sign
        run: |
          docker tag webapp:candidate ghcr.io/${{ github.repository }}:${{ github.sha }}
          docker push ghcr.io/${{ github.repository }}:${{ github.sha }}
          DIGEST=$(docker image inspect ghcr.io/${{ github.repository }}:${{ github.sha }} \
                     --format '{{index .RepoDigests 0}}')
          cosign sign --yes "$DIGEST"
          echo "DIGEST=$DIGEST" >> "$GITHUB_STEP_SUMMARY"
```

---

## 7. Exam checklist

When a CKS task says *"minimize the footprint of this image"*, the graded actions are, in order:

1. **Convert to multi-stage.** Compiler, sources and caches must not appear in the final stage.
2. **Change the runtime base** to `gcr.io/distroless/static-debian12:nonroot` (static binaries) or the matching distroless/Alpine variant. Do not leave `ubuntu`/`debian` as the final stage.
3. **Add a numeric `USER`.** `USER 65532:65532`, never `USER nonroot` if the manifest sets `runAsNonRoot: true`.
4. **Remove the tooling** you did not need: `curl`, `wget`, `vim`, `net-tools`, build-essential.
5. **Clean the package-manager state** in the same `RUN` layer: `rm -rf /var/lib/apt/lists/*`, `apk add --no-cache`, `microdnf clean all`.
6. **Pin versions** — base by digest, packages by version.
7. **Match the Pod manifest**: `runAsNonRoot`, `readOnlyRootFilesystem`, `allowPrivilegeEscalation: false`, `capabilities.drop: ["ALL"]`, `seccompProfile: RuntimeDefault`, plus an `emptyDir` for every writable path.
8. **Convert `exec` probes** to `httpGet`/`tcpSocket` — the shell is gone.
9. **Verify** with `docker image ls`, `trivy image --severity HIGH,CRITICAL`, and `docker run --rm --entrypoint sh <img>` (must fail).

Time-savers under exam conditions:

```console
$ kubectl create deploy web --image=IMG --dry-run=client -o yaml > d.yaml
$ kubectl explain pod.spec.containers.securityContext --recursive | head -30
$ kubectl -n prod debug -it POD --image=busybox:1.36 --target=CONTAINER -- sh
$ trivy image --severity HIGH,CRITICAL --quiet IMG
```

---

## Referencias

**Exam and curriculum**
- CKS Curriculum v1.34 — https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
- CNCF Curriculum repository — https://github.com/cncf/curriculum
- Linux Foundation, Certified Kubernetes Security Specialist — https://training.linuxfoundation.org/certification/certified-kubernetes-security-specialist-cks/

**Kubernetes documentation**
- Images — https://kubernetes.io/docs/concepts/containers/images/
- Configure a Security Context for a Pod or Container — https://kubernetes.io/docs/tasks/configure-pod-container/security-context/
- Pod Security Standards — https://kubernetes.io/docs/concepts/security/pod-security-standards/
- Pod Security Admission — https://kubernetes.io/docs/concepts/security/pod-security-admission/
- Validating Admission Policy — https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/
- Ephemeral Containers — https://kubernetes.io/docs/concepts/workloads/pods/ephemeral-containers/
- Debug Running Pods — https://kubernetes.io/docs/tasks/debug/debug-application/debug-running-pod/
- Garbage Collection (image and container GC) — https://kubernetes.io/docs/concepts/architecture/garbage-collection/
- Kubelet Configuration (v1beta1) — https://kubernetes.io/docs/reference/config-api/kubelet-config.v1beta1/
- Seccomp for a Container — https://kubernetes.io/docs/tutorials/security/seccomp/
- Node-pressure Eviction — https://kubernetes.io/docs/concepts/scheduling-eviction/node-pressure-eviction/
- Cloud Native Security Overview (4C model) — https://kubernetes.io/docs/concepts/security/overview/

**Build tooling**
- Dockerfile reference — https://docs.docker.com/reference/dockerfile/
- Multi-stage builds — https://docs.docker.com/build/building/multi-stage/
- Build secrets — https://docs.docker.com/build/building/secrets/
- BuildKit cache mounts — https://docs.docker.com/build/cache/optimize/
- Reproducible builds with BuildKit — https://docs.docker.com/build/ci/github-actions/reproducible-builds/
- Multi-platform images — https://docs.docker.com/build/building/multi-platform/
- OCI Image Format Specification — https://github.com/opencontainers/image-spec

**Base images**
- Distroless (GoogleContainerTools) — https://github.com/GoogleContainerTools/distroless
- Distroless base images and tags — https://github.com/GoogleContainerTools/distroless/blob/main/base/README.md
- Chainguard Images — https://images.chainguard.dev/ and https://edu.chainguard.dev/chainguard/chainguard-images/
- Wolfi OS — https://github.com/wolfi-dev/os
- Red Hat Universal Base Image — https://catalog.redhat.com/software/base-images
- Building UBI micro images — https://developers.redhat.com/articles/2021/12/13/build-ubi-micro-container-images
- Alpine Linux — https://alpinelinux.org/ ; musl functional differences vs glibc — https://wiki.musl-libc.org/functional-differences-from-glibc.html

**Language-specific**
- Go: `cmd/go` build flags — https://pkg.go.dev/cmd/go#hdr-Compile_packages_and_dependencies
- Go: `time/tzdata` — https://pkg.go.dev/time/tzdata
- JDK: `jlink` — https://docs.oracle.com/en/java/javase/21/docs/specs/man/jlink.html
- JDK: `jdeps` — https://docs.oracle.com/en/java/javase/21/docs/specs/man/jdeps.html
- npm `ci` and `--ignore-scripts` — https://docs.npmjs.com/cli/v10/commands/npm-ci

**Scanning, inspection, policy**
- Trivy — https://trivy.dev/latest/docs/
- Grype — https://github.com/anchore/grype
- Syft (SBOM) — https://github.com/anchore/syft
- Dive — https://github.com/wagoodman/dive
- crane (go-containerregistry) — https://github.com/google/go-containerregistry/blob/main/cmd/crane/README.md
- Skopeo — https://github.com/containers/skopeo
- Hadolint — https://github.com/hadolint/hadolint
- Kyverno policies — https://kyverno.io/policies/
- Sigstore cosign — https://docs.sigstore.dev/cosign/signing/overview/

**Standards and guidance**
- NIST SP 800-190, Application Container Security Guide — https://csrc.nist.gov/publications/detail/sp/800-190/final
- CIS Docker Benchmark — https://www.cisecurity.org/benchmark/docker
- CIS Kubernetes Benchmark — https://www.cisecurity.org/benchmark/kubernetes
- OpenSSF Secure Supply Chain Consumption Framework — https://openssf.org/projects/s2c2f/
- SLSA — https://slsa.dev/spec/v1.0/
- Reproducible Builds, `SOURCE_DATE_EPOCH` — https://reproducible-builds.org/docs/source-date-epoch/