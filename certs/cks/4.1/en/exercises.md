# CKS 4.1 — Minimize Base Image Footprint
## Guided Exercises (exam v1.34 · Supply Chain Security · weight 5)

> **What you are practising.** Every byte in a container image is either code you run or attack surface you inherit. This lab walks the full reduction path — *fat builder image → slim distro → distroless → scratch* — and forces you to **measure** the result at each step (size, package count, CVE count, presence of a shell), instead of trusting the marketing on a base image's README. You will also break things on purpose: minimal images fail in very specific, very recognisable ways (missing CA bundle, missing `/etc/passwd`, missing `/tmp`, `kubectl exec` returning `exec: "sh": executable file not found`), and recognising those failures instantly is what separates a hardened build from a rolled-back deployment.

### Lab prerequisites

| Tool | Minimum | Check |
|---|---|---|
| Docker Engine (BuildKit on by default) | 24.x | `docker version --format '{{.Server.Version}}'` |
| kubectl | 1.34 | `kubectl version --client` |
| A cluster (kind / minikube / k3s) | 1.32+ | `kubectl get nodes` |
| Trivy | 0.58+ | `trivy --version` |
| Syft | 1.18+ | `syft version` |
| dive (optional, layer explorer) | 0.12+ | `dive --version` |
| crane (`go-containerregistry`) | 0.20+ | `crane version` |

```bash
mkdir -p ~/cks/4.1 && cd ~/cks/4.1
export DOCKER_BUILDKIT=1
```

> Podman users: every `docker` command below works with `podman`, except `docker history --no-trunc` (use `podman history --no-trunc`) and `dive` (use `dive podman://<image>`).

---

## Exercise 1 — Build the baseline you are going to shrink

You cannot claim a reduction without a "before". Build the naive image first: the one almost every team ships on day one, where the **build toolchain is also the runtime**.

1. Create the application. It exposes a health endpoint, reports its own UID/GID, and makes an outbound TLS call (that last handler matters in Exercise 6).

```bash
cat > main.go <<'EOF'
package main

import (
	"fmt"
	"log"
	"net/http"
	"os"
)

func main() {
	http.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintln(w, "ok")
	})

	http.HandleFunc("/whoami", func(w http.ResponseWriter, r *http.Request) {
		host, _ := os.Hostname()
		fmt.Fprintf(w, "host=%s uid=%d gid=%d\n", host, os.Getuid(), os.Getgid())
	})

	// Exercises the system trust store: fails on `scratch` without a CA bundle.
	http.HandleFunc("/fetch", func(w http.ResponseWriter, r *http.Request) {
		resp, err := http.Get("https://kubernetes.io/")
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadGateway)
			return
		}
		defer resp.Body.Close()
		fmt.Fprintf(w, "upstream status: %s\n", resp.Status)
	})

	log.Println("listening on :8080")
	log.Fatal(http.ListenAndServe(":8080", nil))
}
EOF

cat > go.mod <<'EOF'
module example.com/minimal

go 1.24
EOF
```

2. Write the naive Dockerfile — build and run in the same `golang` image.

```bash
cat > Dockerfile.fat <<'EOF'
FROM golang:1.24
WORKDIR /src
COPY go.mod ./
COPY main.go ./
RUN go build -o /usr/local/bin/app ./...
EXPOSE 8080
CMD ["app"]
EOF

docker build -f Dockerfile.fat -t cks41/app:fat .
```

3. Measure it. Size, layer count, and what is actually installed inside.

```bash
docker images cks41/app:fat --format 'table {{.Repository}}:{{.Tag}}\t{{.Size}}'
docker image inspect cks41/app:fat --format '{{len .RootFS.Layers}} layers'
docker run --rm cks41/app:fat dpkg-query -f '${binary:Package}\n' -W | wc -l
```

Expected shape of the output (your exact figures will differ by base-image build date):

```
REPOSITORY:TAG      SIZE
cks41/app:fat       1.03GB
9 layers
430
```

4. Enumerate the *interactive* attack surface: shells, package managers, and setuid binaries.

```bash
docker run --rm cks41/app:fat sh -c 'ls /bin/sh /bin/bash /usr/bin/apt /usr/bin/curl /usr/bin/wget 2>&1'
docker run --rm cks41/app:fat find / -xdev -perm -4000 -type f 2>/dev/null
```

```
/bin/bash
/bin/sh
/usr/bin/apt
/usr/bin/curl
/usr/bin/wget
/usr/bin/chsh
/usr/bin/gpasswd
/usr/bin/mount
/usr/bin/newgrp
/usr/bin/passwd
/usr/bin/su
/usr/bin/umount
/usr/bin/chfn
/usr/bin/sudo
```

5. Scan it. Record the totals in a scratchpad file — you will diff against them repeatedly.

```bash
trivy image --scanners vuln --severity HIGH,CRITICAL cks41/app:fat | tail -20
trivy image --scanners vuln --format json cks41/app:fat \
  | jq '[.Results[].Vulnerabilities // [] | length] | add'
```

```
Total: 1187 (HIGH: 78, CRITICAL: 4)
```

**Questions — block 1**

- **Q1.1** The compiled binary is roughly 7 MB. Where did the other ~1 GB come from, and why is *none* of it required at runtime for this particular program?
- **Q1.2** `docker run --rm cks41/app:fat` executes `CMD ["app"]` and it works, yet the exec form does **not** invoke a shell. How is `app` resolved without one?
- **Q1.3** Ranking by realistic exam/production risk, which is worse in this image: the 4 CRITICAL CVEs, or the presence of `/bin/sh`, `apt` and `curl`? Justify in terms of an attacker's kill chain.
- **Q1.4** You run the scan again in three weeks against the *identical* image digest and the CVE total goes up. Did the image change? What did?
- **Q1.5** Why does `find / -xdev -perm -4000` use `-xdev`, and what would you miss if you dropped it when scanning a *running* container instead of an image?

---

## Exercise 2 — Layer hygiene: the reduction that costs you nothing

Before changing base images, fix the mechanical mistakes. These apply to *any* Dockerfile, including the ones you will be asked to critique in an exam scenario.

1. Build a deliberately wasteful image with the three classic anti-patterns: one `RUN` per command, `apt-get` without `--no-install-recommends`, and a cleanup step in a *later* layer.

```bash
cat > Dockerfile.wasteful <<'EOF'
FROM debian:12
RUN apt-get update
RUN apt-get install -y ca-certificates curl jq
RUN rm -rf /var/lib/apt/lists/*
COPY --from=cks41/app:fat /usr/local/bin/app /usr/local/bin/app
CMD ["app"]
EOF

docker build -f Dockerfile.wasteful -t cks41/app:wasteful .
```

2. Build the corrected version: a single `RUN`, recommends disabled, cache purged **inside the same layer**.

```bash
cat > Dockerfile.tidy <<'EOF'
FROM debian:12-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates \
 && rm -rf /var/lib/apt/lists/*
COPY --from=cks41/app:fat /usr/local/bin/app /usr/local/bin/app
CMD ["app"]
EOF

docker build -f Dockerfile.tidy -t cks41/app:tidy .
```

3. Compare, then inspect where the bytes went.

```bash
docker images 'cks41/app' --format 'table {{.Tag}}\t{{.Size}}'
docker history cks41/app:wasteful --format 'table {{.Size}}\t{{.CreatedBy}}' | head -8
```

```
TAG         SIZE
fat         1.03GB
wasteful    218MB
tidy        105MB
```

```
SIZE      CREATED BY
7.31MB    COPY /usr/local/bin/app /usr/local/bin/app # buildkit
0B        RUN /bin/sh -c rm -rf /var/lib/apt/lists/* # buildkit
71.4MB    RUN /bin/sh -c apt-get install -y ca-certificates curl jq # buildkit
23.6MB    RUN /bin/sh -c apt-get update # buildkit
117MB     <missing>
```

4. Confirm the `rm -rf` layer is a lie by reading the *union* of layers versus a single layer.

```bash
docker run --rm cks41/app:wasteful ls /var/lib/apt/lists/     # empty at runtime
dive cks41/app:wasteful                                       # press Tab, inspect layer 3
```

5. Add a `.dockerignore`. Create a plausible build-context leak first, then prove the fix.

```bash
mkdir -p .git && echo 'https://ci-bot:ghp_REDACTEDTOKEN@github.com' > .git/credentials
echo 'AWS_SECRET_ACCESS_KEY=wJalrXUtn' > .env

cat > Dockerfile.ctx <<'EOF'
FROM debian:12-slim
COPY . /build
CMD ["sleep", "infinity"]
EOF

docker build -f Dockerfile.ctx -t cks41/ctx:leaky .
docker run --rm cks41/ctx:leaky cat /build/.git/credentials /build/.env
```

```bash
cat > .dockerignore <<'EOF'
.git
.env
*.pem
*.key
node_modules
Dockerfile*
EOF

docker build -f Dockerfile.ctx -t cks41/ctx:clean .
docker run --rm cks41/ctx:clean ls -a /build
```

**Questions — block 2**

- **Q2.1** `docker history` reports the `rm -rf /var/lib/apt/lists/*` layer as `0B`, yet the image is 113 MB larger than `tidy`. Explain precisely what a whiteout file is and why the deleted data still ships to every node that pulls the image.
- **Q2.2** `--no-install-recommends` removed roughly how much, and — more importantly — what *class* of packages does it exclude? Name a security consequence of shipping recommended packages.
- **Q2.3** Merging every command into one `RUN` shrinks the image but hurts something else. What, and when is that trade-off wrong?
- **Q2.4** `.dockerignore` stopped the `.git` directory from entering the image. Did it stop the credential from being *readable by the build*? What is the correct mechanism when a build genuinely needs a secret?
- **Q2.5** A teammate proposes `docker build --squash` as a universal fix for leaked layers. Give two reasons that is the wrong answer for a CKS-grade pipeline.

---

## Exercise 3 — Multi-stage builds: separate the toolchain from the runtime

1. Write the canonical two-stage build. Note every flag — each one is deliberate.

```bash
cat > Dockerfile.multi <<'EOF'
# ---- build stage -------------------------------------------------------
FROM golang:1.24-bookworm AS builder
WORKDIR /src
COPY go.mod ./
COPY main.go ./
# CGO_ENABLED=0 -> statically linked, no libc dependency at runtime.
# -trimpath     -> strips absolute build paths (reproducibility, no path leak).
# -ldflags="-s -w" -> drops the symbol table and DWARF debug info.
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build -trimpath -ldflags="-s -w" -o /out/app ./...

# ---- runtime stage -----------------------------------------------------
FROM debian:12-slim AS runtime
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates \
 && rm -rf /var/lib/apt/lists/*
COPY --from=builder /out/app /usr/local/bin/app
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/app"]
EOF

docker build -f Dockerfile.multi -t cks41/app:multi .
```

2. Verify the toolchain did not survive into the final image.

```bash
docker run --rm cks41/app:multi sh -c 'command -v go gcc git make; echo exit=$?'
docker run --rm cks41/app:multi id
```

```
exit=1
uid=65532 gid=65532 groups=65532
```

3. Prove the binary is static (this is the precondition for the next two exercises).

```bash
docker run --rm cks41/app:multi sh -c 'ldd /usr/local/bin/app' 2>&1 | head -2
```

```
	not a dynamic executable
```

4. Build a *dynamically* linked variant so you can see the failure mode later.

```bash
docker build -f Dockerfile.multi -t cks41/app:cgo \
  --build-arg X=1 --target builder .
docker run --rm -v "$PWD":/src -w /src golang:1.24-bookworm \
  sh -c 'CGO_ENABLED=1 go build -o /tmp/app-cgo ./... && ldd /tmp/app-cgo'
```

```
	linux-vdso.so.1 (0x00007ffd8b5f8000)
	libc.so.6 => /lib/x86_64-linux-gnu/libc.so.6 (0x00007f2c4a000000)
	/lib64/ld-linux-x86-64.so.2 (0x00007f2c4a2b0000)
```

5. Diff the vulnerability count against the baseline.

```bash
for t in fat tidy multi; do
  printf '%-8s ' "$t"
  trivy image --scanners vuln --quiet --format json "cks41/app:$t" \
    | jq -r '[.Results[]?.Vulnerabilities // [] | length] | add // 0'
done
```

**Questions — block 3**

- **Q3.1** Multi-stage removed the compiler, but the runtime is still `debian:12-slim` with ~90 packages. Which category of CVE did multi-stage eliminate entirely, and which category did it not touch at all?
- **Q3.2** What exactly does `CGO_ENABLED=0` change about the produced binary, and why is it a *prerequisite* for `FROM scratch` rather than merely an optimisation?
- **Q3.3** `-ldflags="-s -w"` shrinks the binary. Name one operational capability you lose, and one security benefit you gain.
- **Q3.4** `USER 65532:65532` appears in the runtime stage. Why the numeric form instead of `USER nonroot`, given that Kubernetes will later evaluate `runAsNonRoot: true`?
- **Q3.5** The build stage `COPY go.mod ./` before `COPY main.go ./`. What is the reason for splitting those into two instructions, and what breaks if you write `COPY . .` instead?

---

## Exercise 4 — Distroless: remove the shell, the package manager, and the distro

Distroless images ship the language runtime and its dependencies — nothing else. No shell, no `apt`, no `busybox`, no setuid binaries.

1. Rebuild on `gcr.io/distroless/static-debian12`.

```bash
cat > Dockerfile.distroless <<'EOF'
FROM golang:1.24-bookworm AS builder
WORKDIR /src
COPY go.mod ./
COPY main.go ./
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/app ./...

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=builder /out/app /app
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/app"]
EOF

docker build -f Dockerfile.distroless -t cks41/app:distroless .
docker images cks41/app --format 'table {{.Tag}}\t{{.Size}}'
```

```
TAG          SIZE
fat          1.03GB
wasteful     218MB
tidy         105MB
multi        104MB
distroless   9.63MB
```

2. Attempt to get a shell. This is the defining property of the image.

```bash
docker run --rm -it cks41/app:distroless sh
```

```
docker: Error response from daemon: failed to create task for container:
failed to create shim task: OCI runtime create failed: runc create failed:
unable to start container process: exec: "sh": executable file not found in $PATH
```

3. Enumerate what *is* inside, using a tool that does not need a shell in the image.

```bash
docker export "$(docker create cks41/app:distroless)" | tar -tv | head -30
```

```
drwxr-xr-x 0/0               0 2026-08-04 00:00 ./
-rwxr-xr-x 0/0         7315456 2026-08-04 00:00 app
drwxr-xr-x 0/0               0 1970-01-01 00:00 etc/
-rw-r--r-- 0/0             127 1970-01-01 00:00 etc/passwd
-rw-r--r-- 0/0              82 1970-01-01 00:00 etc/group
-rw-r--r-- 0/0            1748 1970-01-01 00:00 etc/nsswitch.conf
drwxr-xr-x 0/0               0 1970-01-01 00:00 etc/ssl/certs/
-rw-r--r-- 0/0          213234 1970-01-01 00:00 etc/ssl/certs/ca-certificates.crt
drwxrwxrwx 0/0               0 1970-01-01 00:00 tmp/
drwxr-xr-x 0/0               0 1970-01-01 00:00 var/run/
```

4. Compare package inventories with an SBOM instead of `dpkg`.

```bash
for t in fat tidy distroless; do
  printf '%-11s ' "$t"
  syft -q -o json "cks41/app:$t" | jq '.artifacts | length'
done
```

```
fat         431
tidy        94
distroless  3
```

5. Scan, and note what the numbers now look like.

```bash
trivy image --scanners vuln --severity LOW,MEDIUM,HIGH,CRITICAL cks41/app:distroless
```

```
cks41/app:distroless (debian 12.11)
Total: 0 (LOW: 0, MEDIUM: 0, HIGH: 0, CRITICAL: 0)

app (gobinary)
Total: 0 (LOW: 0, MEDIUM: 0, HIGH: 0, CRITICAL: 0)
```

6. Look at the debug variant, and understand why it exists.

```bash
crane manifest gcr.io/distroless/static-debian12:debug-nonroot | jq '.config.digest'
docker run --rm -it gcr.io/distroless/static-debian12:debug-nonroot sh -c 'busybox | head -1; ls /busybox'
```

**Questions — block 4**

- **Q4.1** Trivy reports `Total: 0`. Give two distinct reasons why "zero findings" is *not* the same as "no vulnerabilities", and how you would detect a flaw that this scan structurally cannot see.
- **Q4.2** Removing `/bin/sh` blocks a specific, very common exploitation step. Name it, and name a class of RCE that removing the shell does **not** block.
- **Q4.3** `gcr.io/distroless/static-debian12` still carries `/etc/ssl/certs/ca-certificates.crt` and `/etc/passwd`. Why are those two files deliberately kept, when the whole point is minimalism?
- **Q4.4** What is the operational difference between the `:nonroot` tag and the plain tag, and what happens if you use the plain tag together with a Pod that sets `runAsNonRoot: true` but no `runAsUser`?
- **Q4.5** `debug-nonroot` ships a BusyBox shell. Explain why shipping that tag to production defeats the exercise, and what the supported alternative is in Kubernetes 1.34.

---

## Exercise 5 — `scratch`: the absolute floor, and its four failure modes

`scratch` is not an image — it is the empty base. Everything the process needs must be copied in explicitly. Build it, then break it four different ways so you recognise each error on sight.

1. Build the deliberately naive `scratch` image.

```bash
cat > Dockerfile.scratch-naive <<'EOF'
FROM golang:1.24-bookworm AS builder
WORKDIR /src
COPY go.mod ./
COPY main.go ./
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/app ./...

FROM scratch
COPY --from=builder /out/app /app
ENTRYPOINT ["/app"]
EOF

docker build -f Dockerfile.scratch-naive -t cks41/app:scratch-naive .
docker images cks41/app:scratch-naive --format '{{.Size}}'
```

```
7.32MB
```

2. **Failure mode 1 — no TLS trust store.** Start it and call the outbound handler.

```bash
docker run -d --name s1 -p 8081:8080 cks41/app:scratch-naive
curl -s localhost:8081/whoami
curl -s localhost:8081/fetch
```

```
host=3f2c1b4d9a77 uid=0 gid=0
Get "https://kubernetes.io/": tls: failed to verify certificate: x509: certificate signed by unknown authority
```

3. **Failure mode 2 — the shell form of `ENTRYPOINT`.** Rebuild with `ENTRYPOINT /app` (no JSON array) and observe.

```bash
sed 's|ENTRYPOINT \["/app"\]|ENTRYPOINT /app|' Dockerfile.scratch-naive > Dockerfile.scratch-shellform
docker build -f Dockerfile.scratch-shellform -t cks41/app:scratch-shellform .
docker run --rm cks41/app:scratch-shellform
```

```
exec: "/bin/sh": stat /bin/sh: no such file or directory: unknown
```

4. **Failure mode 3 — no `/etc/passwd`, no `/tmp`.** Confirm the container is running as UID 0 with no user database, and that any code calling `os.TempDir()` or writing to `/tmp` will fail.

```bash
docker run --rm cks41/app:scratch-naive 2>/dev/null || true
docker export "$(docker create cks41/app:scratch-naive)" | tar -tv
```

```
-rwxr-xr-x 0/0         7315456 2026-08-04 00:00 app
```

5. Now build the **correct** `scratch` image: CA bundle, a non-root user database entry, a writable temp directory, and timezone data.

```bash
cat > Dockerfile.scratch <<'EOF'
FROM golang:1.24-bookworm AS builder
WORKDIR /src
COPY go.mod ./
COPY main.go ./
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/app ./...

# Manufacture a minimal user database instead of copying the builder's.
RUN printf 'app:x:65532:65532:app:/nonexistent:/sbin/nologin\n' > /out/passwd \
 && printf 'app:x:65532:\n'                                    > /out/group \
 && mkdir -p /out/tmp && chmod 1777 /out/tmp

FROM scratch
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=builder /usr/share/zoneinfo /usr/share/zoneinfo
COPY --from=builder /out/passwd /etc/passwd
COPY --from=builder /out/group  /etc/group
COPY --from=builder --chown=65532:65532 /out/tmp /tmp
COPY --from=builder /out/app /app
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/app"]
EOF

docker build -f Dockerfile.scratch -t cks41/app:scratch .
docker rm -f s1 >/dev/null 2>&1
docker run -d --name s2 -p 8082:8080 cks41/app:scratch
curl -s localhost:8082/whoami
curl -s localhost:8082/fetch
docker images cks41/app:scratch --format '{{.Size}}'
```

```
host=91ac5e0f77b2 uid=65532 gid=65532
upstream status: 200 OK
7.55MB
```

6. **Failure mode 4 — dynamic linking.** Copy the CGO binary from Exercise 3 into `scratch` and run it.

```bash
cat > Dockerfile.scratch-cgo <<'EOF'
FROM golang:1.24-bookworm AS builder
WORKDIR /src
COPY go.mod ./
COPY main.go ./
RUN CGO_ENABLED=1 GOOS=linux go build -o /out/app ./...

FROM scratch
COPY --from=builder /out/app /app
ENTRYPOINT ["/app"]
EOF

docker build -f Dockerfile.scratch-cgo -t cks41/app:scratch-cgo .
docker run --rm cks41/app:scratch-cgo
```

```
exec /app: no such file or directory
```

**Questions — block 5**

- **Q5.1** In step 6 the binary `/app` demonstrably exists inside the image, yet the kernel reports `no such file or directory`. Explain the actual missing file.
- **Q5.2** The `scratch` image resolved `kubernetes.io` correctly with no `/etc/nsswitch.conf` and no `/etc/resolv.conf` copied in. Why did DNS work, and under exactly what build flag would it stop working?
- **Q5.3** You copy `/etc/passwd` from the builder stage wholesale instead of manufacturing one. Name two concrete problems with that shortcut.
- **Q5.4** `scratch` is 7.55 MB versus distroless at 9.63 MB — a 2 MB saving. Argue the case for choosing distroless anyway in a regulated production environment.
- **Q5.5** Trivy on the `scratch` image reports no OS packages at all. What does that mean for a compliance requirement that says "all deployed images must have an OS package SBOM", and how do you satisfy it?

---

## Exercise 6 — Alpine and the musl trade-off

Alpine is the popular middle ground: ~8 MB, a real package manager, a real shell. Understand precisely what you buy and what you pay.

1. Build on Alpine.

```bash
cat > Dockerfile.alpine <<'EOF'
FROM golang:1.24-alpine AS builder
WORKDIR /src
COPY go.mod ./
COPY main.go ./
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/app ./...

FROM alpine:3.22
RUN apk add --no-cache ca-certificates \
 && addgroup -g 65532 -S app \
 && adduser  -u 65532 -S app -G app
COPY --from=builder /out/app /app
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/app"]
EOF

docker build -f Dockerfile.alpine -t cks41/app:alpine .
docker images cks41/app --format 'table {{.Tag}}\t{{.Size}}' | sort -k2 -h
```

2. Confirm what Alpine gives an attacker that distroless does not.

```bash
docker run --rm cks41/app:alpine sh -c 'command -v sh wget apk busybox; apk list --installed | wc -l'
```

```
/bin/sh
/usr/bin/wget
/sbin/apk
/bin/busybox
19
```

3. Observe the `--no-cache` idiom versus the `apt` equivalent.

```bash
docker run --rm cks41/app:alpine ls /var/cache/apk/
docker history cks41/app:alpine --format 'table {{.Size}}\t{{.CreatedBy}}' | head -5
```

4. Demonstrate the libc difference. Build a CGO binary against glibc and try to run it on Alpine.

```bash
docker run --rm -v "$PWD":/src -w /src golang:1.24-bookworm \
  sh -c 'CGO_ENABLED=1 go build -o /src/app-glibc ./...'
docker run --rm -v "$PWD":/src alpine:3.22 /src/app-glibc
```

```
/src/app-glibc: /lib/x86_64-linux-gnu/libc.so.6: not found
```

5. Compare scan results across the whole family.

```bash
for t in fat tidy multi alpine distroless scratch; do
  printf '%-11s %-9s ' "$t" "$(docker images -q --format '{{.Size}}' cks41/app:$t)"
  trivy image --scanners vuln --quiet --format json "cks41/app:$t" \
    | jq -r '[.Results[]?.Vulnerabilities // [] | length] | add // 0'
done
```

**Questions — block 6**

- **Q6.1** `apk add --no-cache` is a single flag; the Debian equivalent needs `rm -rf /var/lib/apt/lists/*` chained into the same `RUN`. Explain the underlying difference in behaviour.
- **Q6.2** Alpine's package count (19) is far below Debian slim's (94) but far above distroless's (3). Which specific components account for that middle ground, and what capability do they give a post-exploitation toolkit?
- **Q6.3** The glibc binary fails on Alpine with `libc.so.6: not found`. Beyond portability, name one *runtime behaviour* difference between musl and glibc that has bitten production Kubernetes workloads.
- **Q6.4** A team says "Alpine is safer than Debian because it has fewer CVEs." Give two reasons that comparison is not sound as stated.
- **Q6.5** For a Python service that requires `psycopg2` compiled against native libraries, would you choose `alpine`, `python:3.13-slim`, or `gcr.io/distroless/python3-debian12`? Defend the choice on both footprint and build-reliability grounds.

---

## Exercise 7 — Prove that build-time secrets survive layer deletion

This is the single highest-value demonstration in this topic. Minimising an image is worthless if a deleted layer still ships a credential.

1. Build an image that copies a secret, uses it, then deletes it.

```bash
echo 'REGISTRY_TOKEN=dckr_pat_9f3b1c2e7a5d4088' > secrets.env

cat > Dockerfile.leaky <<'EOF'
FROM debian:12-slim
COPY secrets.env /tmp/secrets.env
RUN . /tmp/secrets.env && echo "using token ${REGISTRY_TOKEN:0:9}..." \
 && rm -f /tmp/secrets.env
COPY --from=cks41/app:fat /usr/local/bin/app /app
ENTRYPOINT ["/app"]
EOF

sed -i '/^.dockerignore$/d' .dockerignore 2>/dev/null || true
docker build -f Dockerfile.leaky -t cks41/app:leaky .
```

2. Confirm the file is genuinely gone from the running filesystem.

```bash
docker run --rm cks41/app:leaky ls -l /tmp/secrets.env; echo "exit=$?"
```

```
ls: cannot access '/tmp/secrets.env': No such file or directory
exit=2
```

3. Now read the layers directly. This works regardless of whether Docker wrote a legacy or OCI-layout archive.

```bash
rm -rf /tmp/leaky && mkdir -p /tmp/leaky
docker save cks41/app:leaky | tar -x -C /tmp/leaky

find /tmp/leaky -type f | while read -r f; do
  if tar -tf "$f" >/dev/null 2>&1; then
    if tar -tf "$f" 2>/dev/null | grep -q 'tmp/secrets.env'; then
      echo "SECRET PRESENT IN LAYER: $f"
      tar -xOf "$f" tmp/secrets.env
    fi
  fi
done
```

```
SECRET PRESENT IN LAYER: /tmp/leaky/blobs/sha256/4c1d0ea9b3f7...
REGISTRY_TOKEN=dckr_pat_9f3b1c2e7a5d4088
```

4. Cross-check with metadata alone — often enough to spot the problem in a code review.

```bash
docker history --no-trunc cks41/app:leaky | grep -i secrets
trivy image --scanners secret cks41/app:leaky
```

5. Fix it properly with a BuildKit secret mount, which never materialises in any layer.

```bash
cat > Dockerfile.sealed <<'EOF'
# syntax=docker/dockerfile:1.7
FROM debian:12-slim
RUN --mount=type=secret,id=regtoken,target=/run/secrets/regtoken \
    . /run/secrets/regtoken && echo "using token ${REGISTRY_TOKEN:0:9}..."
COPY --from=cks41/app:fat /usr/local/bin/app /app
ENTRYPOINT ["/app"]
EOF

docker build -f Dockerfile.sealed --secret id=regtoken,src=secrets.env -t cks41/app:sealed .

rm -rf /tmp/sealed && mkdir -p /tmp/sealed
docker save cks41/app:sealed | tar -x -C /tmp/sealed
find /tmp/sealed -type f -exec sh -c 'tar -tf "$1" 2>/dev/null | grep -H "secrets" ' _ {} \; ; echo "scan complete"
trivy image --scanners secret cks41/app:sealed
```

6. Clean up the local secret material.

```bash
rm -f secrets.env
```

**Questions — block 7**

- **Q7.1** Step 2 shows the file is absent at runtime; step 3 recovers the plaintext token. Reconcile those two facts in terms of how a container's root filesystem is assembled.
- **Q7.2** Would `ARG REGISTRY_TOKEN` + `--build-arg` have been safer than `COPY`? Show the command that would disprove it.
- **Q7.3** `--mount=type=secret` places the file at `/run/secrets/regtoken` during that `RUN` only. Where does the data physically live during the build, and why does it not become a layer?
- **Q7.4** The `# syntax=docker/dockerfile:1.7` line is mandatory for some builders. What does that directive actually do, and what is the failure message if it is missing on an older frontend?
- **Q7.5** The token was leaked, then the image was pushed to a registry and later deleted. Is rotating the token optional? Justify with reference to how registries and CI caches retain blobs.

---

## Exercise 8 — Consequences in the cluster: running, debugging and pinning minimal images

A minimal image changes how you operate the workload. Practise the whole cycle on a live cluster.

1. Load the images into your cluster (kind shown; for k3s use `k3s ctr images import`).

```bash
kind load docker-image cks41/app:distroless cks41/app:fat --name kind 2>/dev/null \
  || echo "adjust for your cluster runtime"
```

2. Deploy the distroless image with a hardened Pod spec.

```bash
cat > pod-distroless.yaml <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: app-distroless
  labels:
    app: minimal
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 65532
    runAsGroup: 65532
    fsGroup: 65532
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: app
      image: cks41/app:distroless
      imagePullPolicy: IfNotPresent
      ports:
        - name: http
          containerPort: 8080
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        privileged: false
        capabilities:
          drop: ["ALL"]
      resources:
        requests:
          cpu: 25m
          memory: 32Mi
        limits:
          cpu: 200m
          memory: 128Mi
      livenessProbe:
        httpGet:
          path: /healthz
          port: http
        initialDelaySeconds: 2
        periodSeconds: 10
      volumeMounts:
        - name: tmp
          mountPath: /tmp
  volumes:
    - name: tmp
      emptyDir:
        medium: Memory
        sizeLimit: 16Mi
EOF

kubectl apply -f pod-distroless.yaml
kubectl wait --for=condition=Ready pod/app-distroless --timeout=60s
```

3. Try to exec into it — and see the exact error the exam expects you to recognise.

```bash
kubectl exec -it app-distroless -- sh
```

```
error: Internal error occurred: error executing command in container:
failed to exec in container: failed to start exec "…":
OCI runtime exec failed: exec failed: unable to start container process:
exec: "sh": executable file not found in $PATH: unknown
```

4. Debug it the supported way: an **ephemeral container** sharing the target's process namespace.

```bash
kubectl debug -it app-distroless \
  --image=busybox:1.37 \
  --target=app \
  --profile=general \
  -- sh
```

Inside the ephemeral container:

```sh
ps -ef
ls -l /proc/1/root/app
cat /proc/1/root/etc/passwd
wget -qO- http://localhost:8080/whoami
exit
```

```
PID   USER     TIME  COMMAND
    1 65532     0:00 /app
   22 root      0:00 sh
host=app-distroless uid=65532 gid=65532
```

5. Verify the hardening actually took effect.

```bash
kubectl get pod app-distroless -o jsonpath='{.spec.containers[0].securityContext}' | jq
kubectl debug -q -it app-distroless --image=busybox:1.37 --target=app -- \
  sh -c 'touch /proc/1/root/newfile 2>&1'
```

6. Demonstrate what happens when a **non-`:nonroot`** minimal image meets `runAsNonRoot: true` without `runAsUser`.

```bash
cat > pod-badroot.yaml <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: app-badroot
spec:
  securityContext:
    runAsNonRoot: true
  containers:
    - name: app
      image: cks41/app:scratch-naive
      imagePullPolicy: IfNotPresent
EOF

kubectl apply -f pod-badroot.yaml
kubectl get pod app-badroot
kubectl describe pod app-badroot | grep -A3 -i 'reason\|message'
```

```
NAME          READY   STATUS                       RESTARTS   AGE
app-badroot   0/1     CreateContainerConfigError   0          6s

  Reason:  CreateContainerConfigError
  Message: container has runAsNonRoot and image will run as root
```

7. Pin by digest instead of by tag, so the footprint you audited is the footprint you run.

```bash
crane digest gcr.io/distroless/static-debian12:nonroot
```

```
sha256:6ec5aa99dc335666e79dc64e4a6c8b89c33a543a1967f20d360922a80dd21f02
```

```bash
cat > Dockerfile.pinned <<'EOF'
FROM golang:1.24-bookworm@sha256:1c04c2a9b3f0ee2b5c8f6f2c6a5b9c9d7e1f4a3b8c2d5e9f0a1b2c3d4e5f6a7b AS builder
WORKDIR /src
COPY go.mod ./
COPY main.go ./
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/app ./...

FROM gcr.io/distroless/static-debian12@sha256:6ec5aa99dc335666e79dc64e4a6c8b89c33a543a1967f20d360922a80dd21f02
COPY --from=builder /out/app /app
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/app"]
EOF
```

8. Clean up.

```bash
kubectl delete pod app-distroless app-badroot --ignore-not-found
```

**Questions — block 8**

- **Q8.1** `kubectl exec -- sh` failed, but `kubectl debug --target=app` gave you a shell that could read `/proc/1/root/app`. Explain the mechanism, and state which namespace sharing makes `/proc/1/root` reachable.
- **Q8.2** The Pod sets `readOnlyRootFilesystem: true` and mounts an `emptyDir` at `/tmp`. Why is that mount necessary *even for a distroless image*, and what does `medium: Memory` change about the security posture?
- **Q8.3** In step 6 the kubelet rejected the Pod with `container has runAsNonRoot and image will run as root`. At what point in the Pod lifecycle is that check performed, and why can it not be done by the API server?
- **Q8.4** `imagePullPolicy: IfNotPresent` combined with a mutable tag creates a specific supply-chain hazard. Describe the attack, and explain how digest pinning closes it.
- **Q8.5** Ephemeral containers give an operator a full BusyBox toolkit inside your Pod's namespaces. What is the RBAC verb that gates this, and why does granting it broadly undo much of the benefit of a shell-less image?

---

## Exercise 9 — Consolidation: audit an unknown Dockerfile against the checklist

1. You receive this Dockerfile in a pull request. Save it and identify every footprint and hardening defect before reading the answers.

```dockerfile
FROM python:3.13
WORKDIR /app
ADD https://internal.example.com/app.tar.gz /app/
COPY . /app
COPY id_rsa /root/.ssh/id_rsa
RUN pip install --upgrade pip
RUN pip install -r requirements.txt
RUN apt-get update && apt-get install -y curl vim netcat-openbsd
RUN rm /root/.ssh/id_rsa
ENV DB_PASSWORD=supersecret123
EXPOSE 8000
CMD python /app/server.py
```

2. Write your corrected version, then compare against the reference in the answers.

3. Verify your rewrite mechanically:

```bash
docker build -f Dockerfile.fixed -t cks41/py:fixed .
docker images cks41/py:fixed --format '{{.Size}}'
trivy image --scanners vuln,secret,misconfig cks41/py:fixed
trivy config Dockerfile.fixed
syft -q -o json cks41/py:fixed | jq '.artifacts | length'
docker run --rm cks41/py:fixed sh -c 'id' 2>&1 | head -1
```

**Questions — block 9**

- **Q9.1** List every defect in the original Dockerfile, classified as *footprint*, *secret exposure*, or *runtime hardening*.
- **Q9.2** `ADD https://...` versus `RUN curl -fsSL ... | tar xz` versus `COPY`. Which is correct here and why does `ADD` from a URL fail a security review?
- **Q9.3** `ENV DB_PASSWORD=supersecret123` — show the single command an attacker with only registry read access runs to extract it.
- **Q9.4** `CMD python /app/server.py` uses shell form. Name the two operational problems this causes in Kubernetes, independent of image size.
- **Q9.5** After your rewrite, `trivy image` still reports HIGH CVEs in Python wheels. Which of the four CKS supply-chain competencies does that push you toward, and what is the concrete next action?

---

<details>
<summary><strong>Answers — click to expand</strong></summary>

### Block 1 — Baseline

**A1.1** The `golang:1.24` image is a full Debian bookworm userland plus the entire Go toolchain: `gc`, the assembler and linker, the standard-library sources, `gofmt`, `go vet`, the module cache, plus GCC/binutils pulled in by the `buildpack-deps` lineage that `golang` is built on. A Go program compiled with `CGO_ENABLED=0` is statically linked — at runtime it needs the Linux kernel's syscall interface and literally nothing else from userland. So ~99% of the image is build-time-only material that will nonetheless be pulled to every node, stored on every node's disk, scanned by every scanner, and made available to anyone who achieves code execution in the container.

**A1.2** The exec form `CMD ["app"]` does not spawn a shell, but the container runtime (`runc`) still performs `$PATH` resolution via `execvp(3)`-style lookup when the command is not an absolute path. `app` was written to `/usr/local/bin`, which is on the default `PATH` inherited from the image config. This is a portability trap: it works here by accident of the base image's `PATH`, and it breaks the moment you move to `scratch` where `PATH` may be empty. Always use an absolute path in the exec form.

**A1.3** The shell and package manager are worse. The 4 CRITICAL CVEs may be in packages the process never loads (`perl`, `git`, `apt` itself) and therefore may be unreachable. `/bin/sh`, `apt`, `curl` and `wget`, by contrast, are *unconditionally* useful to an attacker who has achieved even a constrained code-execution primitive: they turn a limited primitive into interactive access, allow staging of a second-stage payload from the network, allow installing tooling (`nmap`, `kubectl`), and allow scripting of lateral movement against the Kubernetes API using the mounted ServiceAccount token. CVE counts are a proxy metric; removed binaries are a hard control.

**A1.4** The image did not change — an image digest is immutable by construction (it is the SHA-256 of the manifest, which commits to the config and every layer digest). What changed is the vulnerability database: new CVEs were published against packages that were already present. This is why "scanned clean at build time" is not a durable claim, why you re-scan deployed digests on a schedule, and why fewer packages means fewer future CVEs, not just fewer current ones.

**A1.5** `-xdev` stops `find` from descending into other filesystems. On an image inspected via `docker run` you already have `/proc`, `/sys` and `/dev` mounted by the runtime; without `-xdev` you walk them, producing noise and errors. If you scanned a *running* container without `-xdev` you would additionally traverse every mounted `emptyDir`, `configMap`, `secret` and `projected` volume — and while that is noisy, it is also where you would find a setuid binary that arrived via a mounted `hostPath`, which `-xdev` would hide. So: use `-xdev` for image inventory, and deliberately drop it (with `-mount`/`-fstype` filters) when hunting for injected binaries at runtime.

### Block 2 — Layer hygiene

**A2.1** Container images are stacks of read-only layers unioned by an overlay filesystem (`overlayfs` on modern runtimes). Deleting a file in layer *N* cannot modify layer *N-1*, which is already sealed and content-addressed. Instead the build records a **whiteout entry** — in the OCI tar format, a zero-byte file named `.wh.<filename>` (or `.wh..wh..opq` for an opaque directory) — in layer *N*. The overlay driver reads that marker and hides the underlying file from the merged view. The original bytes remain in layer *N-1*'s blob, which is pushed to the registry, pulled to every node, and extractable by anyone with `docker save`, `crane export`, or read access to the registry. `docker history` shows `0B` because the *delta* of that layer is only the whiteout markers.

**A2.2** Roughly 70–90 MB in this example. `--no-install-recommends` excludes packages listed in the `Recommends:` field of the Debian control file — packages that are "strongly desirable but not required", which in practice means documentation, locale data, editors, `dbus`, and frequently entire secondary toolchains. Security consequence: recommended packages install binaries you never audited, never intended to ship, and cannot enumerate from your dependency manifest. Installing `curl` on Debian without the flag can pull in `libssh`, `libldap`, `libpsl` and their transitive CVEs; installing anything that recommends `perl-modules` adds thousands of scripts. Every one of them is an unreviewed dependency in your SBOM and a candidate for the next CVE.

**A2.3** You lose build-cache granularity. With one monolithic `RUN`, changing any part of it invalidates the whole layer, so a one-line package addition re-downloads and rebuilds everything. The trade-off is wrong when the layer is expensive and rarely changes — e.g. a 4-minute `pip install` of scientific wheels. The correct resolution is not "split into many layers" but **order instructions from least- to most-frequently-changing**, and use BuildKit cache mounts (`RUN --mount=type=cache,target=/root/.cache/pip`) which give you cache reuse *without* the bytes entering the image.

**A2.4** No. `.dockerignore` controls what is uploaded into the **build context** (what `COPY .` can see); it does nothing about material read by other means. The credential was still on the developer's disk and would still be present if the Dockerfile ran `RUN git clone` with a token, or if a `RUN --network` step fetched it. For a build that genuinely needs a secret, the correct mechanism is BuildKit's `RUN --mount=type=secret,id=…` (Exercise 7), or `--mount=type=ssh` for SSH agent forwarding — both expose the material to exactly one `RUN` step via a tmpfs, and neither produces a layer.

**A2.5** First, `--squash` is a legacy classic-builder feature, deprecated and unavailable in the default BuildKit builder; relying on it makes the pipeline non-portable. Second and more fundamentally, squashing is a *post-hoc cleanup of a build that already handled the secret wrongly* — it collapses layers but the secret was still written to the build cache, may still exist in intermediate images retained by the builder, and the credential is now known to have existed in a build environment you do not control end-to-end. The correct answers are multi-stage builds (the secret never reaches the final stage) and secret mounts (the secret never reaches any layer). Squashing also destroys layer sharing across images, increasing total registry and node storage.

### Block 3 — Multi-stage

**A3.1** Eliminated entirely: vulnerabilities in **build-time-only** components — the Go toolchain, GCC, `git`, `make`, `binutils`, module dependencies of the build, and the `buildpack-deps` lineage. Not touched at all: vulnerabilities in the **runtime distro's remaining packages** (glibc, zlib, OpenSSL, `coreutils`, `bash`, `libssl`) and in the **application's own compiled-in dependencies**, which Trivy detects by parsing the Go build metadata embedded in the binary (`gobinary` result type). Multi-stage is orthogonal to base-image choice; you need both.

**A3.2** With `CGO_ENABLED=0`, the Go compiler does not link against the system C library and substitutes pure-Go implementations for the packages that would otherwise call into libc — principally `net` (DNS resolution) and `os/user`. The result is a fully static ELF with no `PT_INTERP` program header and no `DT_NEEDED` entries, meaning the kernel loads and executes it directly without invoking a dynamic loader. That is the prerequisite for `scratch`: `scratch` contains no `/lib64/ld-linux-x86-64.so.2` and no `libc.so.6`, so a dynamically linked binary cannot start at all (see A5.1).

**A3.3** `-s` strips the symbol table, `-w` omits DWARF debug information. Lost capability: meaningful stack traces from a core dump and the ability to attach `delve`/`gdb` with symbol resolution — post-mortem debugging becomes materially harder, so keep unstripped artefacts in your build archive. Gained: the binary shrinks 25–35%, and you stop shipping function names, source-file paths and struct layouts that make an attacker's reverse-engineering and gadget-finding significantly cheaper. `-trimpath` complements this by removing absolute build paths (which otherwise leak CI directory structure and usernames) and improving build reproducibility.

**A3.4** The kubelet enforces `runAsNonRoot: true` by inspecting the image config's `User` field. It has **no way to resolve a username to a UID**, because doing so would require reading `/etc/passwd` from inside the image before the container exists. If the image declares `USER nonroot` (a name), the kubelet cannot determine whether that is UID 0 and — depending on version and runtime — will either reject the Pod or be unable to verify the constraint. Declaring `USER 65532:65532` numerically makes the check unambiguous and lets `runAsNonRoot: true` pass without also having to specify `runAsUser` in every Pod spec.

**A3.5** Layer-cache optimisation: dependency manifests change far less often than source code. By copying `go.mod` (and in a real project `go.sum`, followed by `RUN go mod download`) first, the expensive dependency-resolution layer is cached and reused across every source-only change. `COPY . .` collapses that into one layer keyed on the hash of the entire context, so editing a single line of code invalidates dependency download on every build. `COPY . .` additionally drags the whole build context — including anything `.dockerignore` failed to exclude — into the build stage.

### Block 4 — Distroless

**A4.1** (i) **Coverage gap:** Trivy matches package metadata against advisory databases. Distroless carries almost no package metadata, and the Go binary's dependencies are only detectable because Go embeds module information — a C, Rust or stripped binary may produce zero detections simply because there is nothing to parse. Absence of evidence is not evidence of absence. (ii) **Scope gap:** an OS-package scanner cannot see logic flaws, misconfiguration, hardcoded credentials, insecure defaults, or a zero-day in your own code — the entire class that actually causes most breaches. Detect the rest with `trivy image --scanners vuln,secret,misconfig`, static analysis of the workload manifests (`kubesec`, `kube-linter` — CKS competency 4.4), an SBOM you generate at build time and re-evaluate continuously, and runtime detection (Falco — domain 6).

**A4.2** Blocked: **command injection into a shell and interactive post-exploitation** — `os.system()`-style injections, `sh -c` reverse shells, `kubectl exec` for a live attacker, and any payload that assumes it can invoke `curl | sh`. Not blocked: **in-process code execution** — a memory-corruption exploit, an unsafe deserialisation gadget chain, an SSRF, or a Go/Java/Python-level RCE that runs entirely inside the application runtime. Such an attacker can still open sockets, read the ServiceAccount token at `/var/run/secrets/kubernetes.io/serviceaccount/token`, and talk to the API server — all without a shell. Distroless raises cost; it does not eliminate the class.

**A4.3** Both are needed by ordinary, correct programs. `ca-certificates.crt` is the system trust store: without it any outbound TLS connection — to the Kubernetes API, to a database, to an OIDC issuer — fails with `x509: certificate signed by unknown authority`. `/etc/passwd` (and `/etc/group`) provide the UID→name mapping that `os/user`, many logging libraries, and some runtimes call at startup; more importantly it is what makes the `nonroot` user a real, resolvable identity so `id`-style lookups and `fsGroup` semantics behave predictably. Distroless is minimal *for a running application*, not empty for its own sake — that is precisely the distinction from `scratch`.

**A4.4** The plain tag (`:latest`, `:debug`) declares no `USER`, so the container defaults to UID 0. The `:nonroot` tag sets `USER 65532:65532` in the image config and pre-populates `/etc/passwd` with that entry. If you use the plain tag in a Pod with `runAsNonRoot: true` and no `runAsUser`, the kubelet sees an image that will run as root, refuses to start the container, and the Pod enters `CreateContainerConfigError` with `container has runAsNonRoot and image will run as root` — exactly the failure reproduced in Exercise 8 step 6. Fixes: use the `:nonroot` tag, or set `runAsUser: 65532` explicitly in the Pod spec.

**A4.5** The `debug` variants add a BusyBox shell at `/busybox/sh` plus a symlinked coreutils set. Shipping that tag reinstates precisely the capability you removed: an attacker with in-process RCE regains `sh`, `wget`, `nc` and a full text-processing toolkit. The supported alternative is **ephemeral containers** (`kubectl debug -it <pod> --image=busybox --target=<container>`, GA since Kubernetes 1.25): the debugging tools live in a *separate* container image, are attached on demand by an operator with explicit `pods/ephemeralcontainers` RBAC, are audit-logged, and disappear when the Pod is replaced — none of them are ever part of the workload image sitting in your registry.

### Block 5 — scratch

**A5.1** The missing file is the **dynamic loader**, `/lib64/ld-linux-x86-64.so.2`. A dynamically linked ELF carries a `PT_INTERP` header naming its interpreter; `execve(2)` loads that interpreter, not the binary. The kernel returns `ENOENT` when the *interpreter* path does not exist, and the runtime surfaces it verbatim as `no such file or directory` pointing at `/app` — one of the most misleading errors in container work. Confirm with `readelf -l /out/app | grep interpreter` in the builder stage, or `file /out/app` which will say `dynamically linked, interpreter /lib64/ld-linux-x86-64.so.2`.

**A5.2** Because `CGO_ENABLED=0` forces Go's **pure-Go resolver**, which does not consult `/etc/nsswitch.conf` or call `getaddrinfo(3)`; it reads `/etc/resolv.conf` — and in a Kubernetes Pod (and under Docker) the runtime *bind-mounts* `/etc/resolv.conf` into the container at start, so it exists even on `scratch`. DNS stops working if you build with `CGO_ENABLED=1`, which makes Go prefer the cgo resolver: that path calls into glibc's NSS machinery, which `dlopen()`s `libnss_dns.so.2` at runtime — a shared object that is absent from `scratch`, producing intermittent, host-dependent resolution failures. (You can also force the pure resolver with `GODEBUG=netdns=go`, but building static is the durable fix.)

**A5.3** (i) You import the builder image's entire user database — dozens of system accounts (`daemon`, `bin`, `sys`, `nobody`, and whatever the toolchain added) — reintroducing identities and shell paths you never intended to declare, and expanding what a `setuid`-style escalation could target. (ii) The UIDs will not match your Pod spec: the builder has no `65532` entry, so `runAsUser: 65532` runs an unmapped UID and `os/user` lookups fail, while any UID that *does* match (e.g. `nobody` at 65534) is one you did not choose. Manufacturing a two-line `passwd`/`group` pair makes the identity explicit, auditable, and stable across base-image updates.

**A5.4** Because the 2 MB is irrelevant and the missing 2 MB is doing real work. Distroless gives you: a maintained trust store that is **updated with the base image** (on `scratch` you froze a CA bundle at build time and must remember to rebuild when a root is distrusted), a real `/etc/passwd` with a documented nonroot identity, timezone data, `/tmp` with correct permissions, published provenance and signatures for the base image, and — critically for compliance — recognisable OS-package metadata so scanners and SBOM tooling produce meaningful output. `scratch` shifts all of that maintenance onto your Dockerfile, where it silently rots. Choose `scratch` only for a single static binary with no TLS, no temp files, and no identity requirements.

**A5.5** It means the scan is structurally silent, not clean: with no package database there is nothing for the OS-package analyser to enumerate, so `trivy image` reports no OS results and the requirement is unmet by construction. Satisfy it by generating the SBOM **at build time in the builder stage**, where full metadata still exists — `syft` the builder stage or use `docker buildx build --sbom=true --provenance=true` to attach an SPDX/CycloneDX attestation to the image — then scan the SBOM directly (`trivy sbom app.spdx.json`) and store it as a signed attestation alongside the image. This is the bridge from CKS 4.1 into 4.2, "understand your supply chain".

### Block 6 — Alpine

**A6.1** `apt-get update` downloads package index files to `/var/lib/apt/lists/` and `apt-get install` caches `.deb` archives in `/var/cache/apt/archives/`; both persist as files, so they become part of whichever layer the `RUN` produced and must be removed *within that same `RUN`*. `apk add --no-cache` instructs apk to fetch the index directly to memory for the transaction and never write `/var/cache/apk/` at all — there is nothing to clean up, so no layer is polluted regardless of how the `RUN` instructions are arranged. (The older idiom `apk add --update … && rm -rf /var/cache/apk/*` is the Debian-style equivalent and is now obsolete.)

**A6.2** The middle ground is: **BusyBox** (providing `sh`, `wget`, `nc`, `vi`, `wget`, `ps`, `ash` and ~200 applets from a single multi-call binary), **musl libc**, **apk-tools**, and **ca-certificates** with its OpenSSL/libcrypto dependency. For a post-exploitation toolkit this is close to everything needed: BusyBox alone supplies a shell, an HTTP downloader for stage-two payloads, a raw-socket tool for reverse shells and port scanning, and a text-processing suite for parsing the ServiceAccount token and API responses. `apk` additionally lets an attacker install arbitrary further tooling if egress is permitted.

**A6.3** The best-known is **DNS resolution behaviour**: musl's resolver historically queried IPv4 and IPv6 in parallel and, in older versions, did not fall back from a truncated UDP response to TCP, and it ignores `options ndots` semantics differently from glibc — which interacts badly with Kubernetes' `ndots: 5` search-domain configuration and produced a long tail of "intermittent 5-second DNS timeouts on Alpine" incidents. Others worth knowing: musl's much smaller default thread stack size (~128 KB vs glibc's 8 MB) causing stack overflows in threaded C extensions, and musl's different `malloc` implementation producing materially different memory-fragmentation and performance profiles under allocation-heavy workloads.

**A6.4** (i) **Different counting basis.** Alpine's advisory coverage in the secdb is less complete than Debian's; a lower reported count can reflect fewer *tracked* advisories rather than fewer *flaws*. Debian's security team also tracks and reports issues that other distros silently carry. (ii) **Different denominators and reachability.** Alpine has fewer packages, so a raw total compares different software sets, not different security qualities of the same software; and neither number accounts for whether the vulnerable code is reachable from your process. The defensible comparison is: same application, same scanner, same database date, counting only `HIGH`/`CRITICAL` with `--ignore-unfixed`, and reasoning about which findings are actually loaded at runtime.

**A6.5** `python:3.13-slim` for the build, and ideally `gcr.io/distroless/python3-debian12` for the runtime in a multi-stage build. Reasoning: `psycopg2` (the non-binary variant) needs `libpq` and a C compiler. On Alpine, PyPI's manylinux wheels do not apply (they target glibc), so **every** wheel with native code compiles from source — slow, fragile, and it forces `gcc`, `musl-dev`, `postgresql-dev` and Python headers into the build, frequently ending up in the runtime too. The often-cited result is that an "Alpine Python" image ends up *larger* and slower to build than the slim Debian equivalent. The production shape is: build stage on `python:3.13-slim` with `pip install --no-cache-dir` into a venv or `--target` directory, runtime stage on distroless-python copying only the venv and the app — small footprint, no compiler, and standard manylinux wheels throughout.

### Block 7 — Build secrets

**A7.1** The container's root filesystem is an **overlay of immutable layers**. `COPY secrets.env /tmp/secrets.env` sealed the plaintext into layer *N*, content-addressed and pushed to the registry. The subsequent `rm -f` executed in layer *N+1* and could only write a whiteout marker (`.wh.secrets.env`) into that layer. The merged view the process sees — and therefore `ls` — honours the whiteout and reports the file absent. But `docker save`, `crane export --platform`, `skopeo copy`, or plain registry blob access all read the *individual* layers, where the plaintext is untouched. Runtime absence and layer absence are entirely different properties.

**A7.2** No — `--build-arg` is strictly worse, because build args are recorded in the image config's history and are trivially readable without extracting any layer:

```bash
docker history --no-trunc cks41/app:leaky
docker image inspect cks41/app:leaky --format '{{json .Config}}' | jq
crane config cks41/app:leaky | jq '.history[].created_by'
```

Any of these prints `ARG REGISTRY_TOKEN=dckr_pat_…` directly from metadata. The same applies to `ENV` (see A9.3), which is worse still because it also persists into the running container's environment where any process — or any `/proc/1/environ` read — can see it.

**A7.3** BuildKit stores the secret in the build session, held by the *client* (your `docker build` process), and exposes it to the `RUN` step as a **tmpfs mount** at the target path. Because it is a mount rather than a filesystem write, it exists only in the mount namespace of that single build step and produces no filesystem delta. Layer contents are computed as the diff of the step's filesystem changes, and a tmpfs mount point contributes nothing to that diff — so no blob, no history entry, nothing to extract. The secret also never traverses the BuildKit daemon's persistent cache.

**A7.4** `# syntax=docker/dockerfile:1.7` is a **parser directive** that tells BuildKit to pull that specific Dockerfile *frontend* image from the registry and use it to interpret the file, decoupling Dockerfile syntax features from the installed Docker version. Without it (or with an older default frontend, or with `DOCKER_BUILDKIT=0` forcing the classic builder) you get a parse error along the lines of `Dockerfile parse error line 3: Unknown flag: mount` — the classic builder does not implement `RUN --mount` at all. Pinning the frontend also makes builds reproducible across developer machines with different Docker versions.

**A7.5** Rotation is **mandatory, not optional**. Deleting a tag does not delete blobs: registries garbage-collect asynchronously and often only on an explicit maintenance run, replicas and pull-through caches keep their own copies, CI runners keep layer caches on disk, every node that ever pulled the image has the layer in its content store, and anyone who pulled it in the interim has a permanent copy. Treat any credential that entered a layer or an image config as fully disclosed from the moment of the first push: rotate it, then audit for use, then fix the build. The same reasoning applies to a secret committed to git and later force-pushed away.

### Block 8 — In-cluster consequences

**A8.1** `kubectl debug --target=app` creates an **ephemeral container** in the existing Pod, and `--target` sets `targetContainerName`, which makes the runtime place the new container in the **PID namespace** of the target container. Sharing the PID namespace means the ephemeral container sees the application as PID 1, and Linux exposes every process's mount-namespace root through `/proc/<pid>/root` — so `/proc/1/root/app` is a live view of the distroless container's filesystem, readable with BusyBox tools that were never shipped in the workload image. The ephemeral container also shares the Pod's network namespace by default, which is why `wget http://localhost:8080/whoami` reaches the app.

**A8.2** `readOnlyRootFilesystem: true` makes the container's merged overlay read-only, so *any* write fails — including the ones the Go runtime and standard library make without asking (`os.CreateTemp`, `httputil.ReverseProxy` spooling large bodies, TLS session material in some libraries, crash dumps). Being distroless does not change that: the image is small, but the program still expects a writable `/tmp`. Mounting an `emptyDir` there gives a writable path with a bounded lifetime tied to the Pod. `medium: Memory` backs it with tmpfs, so contents never touch node disk (nothing to recover forensically from a decommissioned node, and no persistence across a restart) and, combined with `sizeLimit: 16Mi`, it is bounded — otherwise a tmpfs `emptyDir` is charged against the Pod's memory and an unbounded one can drive node memory pressure.

**A8.3** The check is performed by the **kubelet**, immediately before container creation, in the `CreateContainer` path — which is why the failure surfaces as `CreateContainerConfigError` on an already-scheduled Pod rather than as a rejected `POST`. The API server cannot do it because determining the effective UID requires reading the **image config**, and only the node has (or can obtain) the image: it must pull from a registry that may require node-scoped credentials, may be a private mirror unreachable from the control plane, and the tag may resolve to a different digest at pull time. The API server validates the *spec*; only the kubelet can validate the *spec against the image*. If you want this rejected at admission time, that is a Pod Security Admission (`restricted` profile) or policy-engine (Kyverno/Gatekeeper) concern operating on the spec fields, not on the image.

**A8.4** With a mutable tag and `IfNotPresent`, the digest a node runs is whatever it happened to cache first. An attacker (or a compromised CI job) who can push to the registry overwrites `:v1.2` with a malicious image; nodes that already cached the tag keep running the old one while newly scheduled nodes pull the malicious one — so the fleet runs a mix, your scan results describe an image nobody is running, and rollback by tag does not restore a known state. `imagePullPolicy: Always` narrows but does not close it (the tag still points wherever the attacker aimed it). Referencing `image: repo/app@sha256:…` makes the reference **content-addressed**: the kubelet verifies the pulled manifest hashes to that digest, so the node either runs exactly the bytes you audited or fails to start. This is also the prerequisite for signature verification (CKS 4.3).

**A8.5** The verb is `create` on the `pods/ephemeralcontainers` subresource — for example `kubectl auth can-i create pods/ephemeralcontainers`. Granting it broadly hands any holder an arbitrary-image shell inside your Pod's PID, network and (with `--profile=sysadmin` or a permissive `securityContext`) IPC namespaces, with access to the target's mounted Secrets, ServiceAccount token and filesystem through `/proc/1/root`. That is a near-complete bypass of the shell-less image: you removed the shell from the artefact but left an API to attach one. Treat it as a break-glass permission — scope it to a namespace, bind it to an operations role rather than to developers or to service accounts, ensure the audit policy records it at `RequestResponse` level, and combine it with an admission policy restricting which debug images may be used.

### Block 9 — Consolidation audit

**A9.1**

*Footprint:*
1. `FROM python:3.13` — the full Debian-based image (~1.0 GB) instead of `-slim` (~130 MB) or a distroless runtime; ships the full C toolchain from `buildpack-deps`.
2. No multi-stage build — build dependencies and the app runtime are the same image.
3. `RUN apt-get install -y curl vim netcat-openbsd` — `vim` and `netcat` have no runtime purpose; `netcat` is a textbook post-exploitation tool. Also missing `--no-install-recommends` and missing `rm -rf /var/lib/apt/lists/*` in the same layer.
4. Four separate `RUN` instructions where two would do, each adding a layer.
5. `pip install` without `--no-cache-dir` leaves the wheel cache in `~/.cache/pip` inside the image.
6. `COPY . /app` with no `.dockerignore` — drags `.git`, `.env`, virtualenvs, test fixtures and CI config into the image.
7. `RUN pip install --upgrade pip` as its own layer duplicates pip.

*Secret exposure:*
8. `COPY id_rsa /root/.ssh/id_rsa` — private key sealed into a layer; the later `rm` only writes a whiteout (Exercise 7). The key must be rotated.
9. `ENV DB_PASSWORD=supersecret123` — plaintext in the image config, visible via `docker inspect`/`crane config` and in every container's environment.
10. `COPY . /app` may carry `.env`, `.git/credentials`, `*.pem`.
11. `ADD https://internal.example.com/app.tar.gz` — unpinned, unverified remote fetch (see A9.2).

*Runtime hardening:*
12. No `USER` — runs as root, incompatible with `runAsNonRoot: true`.
13. `CMD python /app/server.py` in shell form (see A9.4).
14. No pinned base-image digest; `python:3.13` is a mutable tag.
15. `requirements.txt` unpinned/unhashed (no `--require-hashes`), so builds are not reproducible and are vulnerable to dependency-confusion and typosquatting.
16. `WORKDIR /app` then `COPY . /app` with root ownership, while the process should run unprivileged and the root filesystem should be read-only.

**A9.2** `COPY` is correct for local build artefacts; for a remote tarball, fetch it in a **builder stage** with an explicit integrity check. `ADD <url>` fails review because: it performs an unauthenticated fetch at build time with no checksum or signature verification, so the content is whatever the server returned that day (no reproducibility, and a compromised or spoofed `internal.example.com` injects code directly into your image); before BuildKit's newer `--checksum` flag there was no way to pin it at all; it creates a layer containing the archive; and it silently auto-extracts local archives, which surprises reviewers. The defensible forms are `ADD --checksum=sha256:<digest> <url> /tmp/` in a builder stage, or `RUN curl -fsSL <url> -o /tmp/app.tar.gz && echo "<sha256>  /tmp/app.tar.gz" | sha256sum -c - && tar -xzf …` — with the extracted result `COPY --from=builder`-ed into a clean runtime stage.

**A9.3** A single command against the registry, with no need to pull layers:

```bash
crane config internal.example.com/app:latest | jq '.config.Env'
```

or equivalently `docker inspect --format '{{json .Config.Env}}' <image>` after a pull, or `skopeo inspect --config docker://<image>`. `ENV` values live in the image **config blob**, which is a small JSON document fetched before any layer — so the password is available to anyone with read access to the repository, and it is also present in `/proc/<pid>/environ` for every process in the container. Configuration that varies per environment belongs in a Kubernetes `Secret` mounted as a file (or injected by an external secrets operator), never baked into the image.

**A9.4** (i) **Signal handling.** The shell form runs `/bin/sh -c "python /app/server.py"`, making `sh` PID 1. Depending on the shell it may not forward `SIGTERM` to the Python process, so on Pod deletion the application never receives the termination signal, ignores `preStop`/graceful-shutdown logic, and is `SIGKILL`ed after `terminationGracePeriodSeconds` — producing dropped connections on every rolling update. (ii) **`args` override semantics.** With shell form, a Pod spec's `args:` cannot append arguments the way it does for exec form — Kubernetes `command`/`args` map onto `ENTRYPOINT`/`CMD`, and the shell-form wrapper makes the mapping non-obvious, so overrides silently do the wrong thing. A third: the extra `sh` process breaks PID-1 zombie reaping and confuses `ps`-based liveness logic. Use `ENTRYPOINT ["python", "/app/server.py"]` (exec form, absolute paths) — and on a shell-less base image the shell form fails outright (Exercise 5, step 3).

**A9.5** It pushes you into **4.2 "Understand your supply chain"** and **4.4 "Perform static analysis of user workloads and container images"** — footprint minimisation has reached its limit, because the remaining vulnerabilities are in code you deliberately depend on, not in incidental base-image packages. Concrete next actions: generate and store an SBOM per build (`syft` / `docker buildx --sbom=true`) so you can answer "where is this package deployed" without rebuilding; pin dependencies by hash (`pip-compile --generate-hashes`, then `pip install --require-hashes`) so the resolved set is reproducible and auditable; gate the pipeline on `trivy image --exit-code 1 --severity HIGH,CRITICAL --ignore-unfixed` so unfixable findings do not block while fixable ones do; run `trivy config` / `kube-linter` / `kubesec` against the Dockerfile and manifests; and feed the remaining accepted risk into runtime controls (seccomp `RuntimeDefault`, dropped capabilities, NetworkPolicy egress restrictions) so an exploited dependency still cannot reach anything useful.

</details>

---

## Exam-day checklist for this competency

| Signal you see | What it means | Action |
|---|---|---|
| `exec: "sh": executable file not found` | Distroless/scratch, no shell | Use `kubectl debug --target=<c>`, not `kubectl exec` |
| `exec /app: no such file or directory` (file exists) | Dynamically linked binary on `scratch` | Rebuild with `CGO_ENABLED=0`, or use distroless-base |
| `x509: certificate signed by unknown authority` | No CA bundle | `COPY --from=builder /etc/ssl/certs/ca-certificates.crt …` |
| `CreateContainerConfigError` + `image will run as root` | `runAsNonRoot: true` with no numeric `USER`/`runAsUser` | Use the `:nonroot` tag or set `runAsUser: 65532` |
| `exec: "/bin/sh": stat …: no such file` | Shell-form `CMD`/`ENTRYPOINT` on a shell-less base | Convert to JSON exec form with absolute paths |
| `read-only file system` on `/tmp` | `readOnlyRootFilesystem: true` | Mount `emptyDir` (`medium: Memory`, with `sizeLimit`) |
| Secret in `docker history` or `crane config` | `ARG`/`ENV`/`COPY` of credential | Rotate the credential, then move to `RUN --mount=type=secret` |

## Sources

- CNCF, *Certified Kubernetes Security Specialist (CKS) Curriculum v1.34* — https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
- Kubernetes, *Configure a Security Context for a Pod or Container* — https://kubernetes.io/docs/tasks/configure-pod-container/security-context/
- Kubernetes, *Debug Running Pods (Ephemeral Containers)* — https://kubernetes.io/docs/tasks/debug/debug-application/debug-running-pod/
- Kubernetes, *Images — image pull policy and digests* — https://kubernetes.io/docs/concepts/containers/images/
- Kubernetes, *Pod Security Standards* — https://kubernetes.io/docs/concepts/security/pod-security-standards/
- Docker, *Dockerfile reference* — https://docs.docker.com/reference/dockerfile/
- Docker, *Multi-stage builds* — https://docs.docker.com/build/building/multi-stage/
- Docker, *Build secrets* — https://docs.docker.com/build/building/secrets/
- Docker, *Build context and `.dockerignore`* — https://docs.docker.com/build/concepts/context/
- GoogleContainerTools, *distroless — language-focused Docker images, minus the operating system* — https://github.com/GoogleContainerTools/distroless
- Open Container Initiative, *Image Layer Filesystem Changeset (whiteouts)* — https://github.com/opencontainers/image-spec/blob/main/layer.md
- Aqua Security, *Trivy documentation* — https://trivy.dev/latest/docs/
- Anchore, *Syft — SBOM generation* — https://github.com/anchore/syft
- Alpine Linux, *Package management with apk* — https://wiki.alpinelinux.org/wiki/Alpine_Package_Keeper
- Go, *cgo and build modes* — https://pkg.go.dev/cmd/cgo and https://pkg.go.dev/net#hdr-Name_Resolution