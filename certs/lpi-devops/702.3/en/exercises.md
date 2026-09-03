# 702.3 — Container Image Building
## Guided Exercises

**Certification:** LPI DevOps Tools Engineer — Exam 701-100, version 2.0.0
**Objective:** 702.3 Container Image Building — **exam weight 8.33**
**Format:** numbered steps you execute, followed by comprehension checkpoints. All answers are in the collapsible section at the end.

---

### Environment and conventions

Every digest, image ID and byte size printed in this document is **representative**. Yours will differ — base images are rebuilt upstream and layer content is host- and date-dependent. What must match is the *shape* of the output and the *relationships* between values (same digest ⇒ same bytes, different digest ⇒ different bytes).

Requirements: Docker Engine ≥ 23 (BuildKit is the default builder from that release on), or Podman ≥ 4 where indicated. Network access to Docker Hub. Roughly 3 GB of free disk.

```bash
docker version --format 'client={{.Client.Version}} server={{.Server.Version}}'
docker buildx version
docker info --format 'storage-driver={{.Driver}} rootless={{.SecurityOptions}}'
```

```
client=27.3.1 server=27.3.1
github.com/docker/buildx v0.17.1
storage-driver=overlay2 rootless=[name=seccomp,profile=builtin name=cgroupns]
```

Create a scratch workspace used by every exercise:

```bash
mkdir -p ~/lab-702.3 && cd ~/lab-702.3
```

---

## Exercise 1 — Anatomy of an image: layers, config, manifest

Before writing a `Dockerfile`, you need a precise mental model of what a build *produces*. An OCI image is not a filesystem — it is a **JSON config blob** plus an **ordered list of tar layers**, tied together by a **manifest**. The registry stores all three as content-addressed blobs.

### Steps

1. Pull a small base image and look at what the daemon recorded.

```bash
docker pull alpine:3.20
docker image ls alpine:3.20
```

```
REPOSITORY   TAG    IMAGE ID       CREATED       SIZE
alpine       3.20   91ef0af61f39   3 weeks ago   8.83MB
```

2. Print the **rootfs layer list**. These are `diffID`s — SHA-256 digests of the *uncompressed* tar of each layer.

```bash
docker image inspect alpine:3.20 --format '{{range .RootFS.Layers}}{{println .}}{{end}}'
```

```
sha256:63ca1fbb43ae5034640e5e6cb3e083e05c290072c5366fcaa9d62435a4cced85
```

3. Now ask the *registry* for the manifest. These digests are of the **compressed** blobs — deliberately different values for the same content.

```bash
docker buildx imagetools inspect --raw alpine:3.20 | head -40
```

```json
{
  "mediaType": "application/vnd.oci.image.index.v1+json",
  "schemaVersion": 2,
  "manifests": [
    {
      "mediaType": "application/vnd.oci.image.manifest.v1+json",
      "digest": "sha256:beefdbd8a1da6d2915566fde36db9db0b524eb737fc57cd1367effd16dc0d06d",
      "size": 581,
      "platform": { "architecture": "amd64", "os": "linux" }
    },
    ...
  ]
}
```

4. Inspect the **image config** — the part that holds `Env`, `Cmd`, `Entrypoint`, `User`, `WorkingDir` and the build history.

```bash
docker image inspect alpine:3.20 \
  --format '{{json .Config}}' | python3 -m json.tool
```

```json
{
    "Hostname": "",
    "Env": [ "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" ],
    "Cmd": [ "/bin/sh" ],
    "WorkingDir": "",
    "Entrypoint": null,
    "Labels": null
}
```

5. Read the build history, including the steps that produced **no** filesystem change.

```bash
docker image history alpine:3.20
```

```
IMAGE          CREATED       CREATED BY                                      SIZE      COMMENT
91ef0af61f39   3 weeks ago   CMD ["/bin/sh"]                                 0B        buildkit.dockerfile.v0
<missing>      3 weeks ago   ADD alpine-minirootfs-3.20.3-x86_64.tar.gz /…   8.83MB    buildkit.dockerfile.v0
```

### Checkpoint 1

- **Q1.** The digest in `.RootFS.Layers` and the layer digest in the registry manifest describe the same layer, yet they differ. Why, and which one does `docker pull` use to decide whether it can skip a download?
- **Q2.** `docker image ls` reports `8.83MB` for `alpine:3.20`. If you pull ten images that all derive `FROM alpine:3.20`, will `docker system df` report ~88 MB of image data? Justify.
- **Q3.** In `docker image history`, why is one row's IMAGE column `<missing>`, and what does that tell you about whether you can `docker run` an intermediate layer of an image you pulled?
- **Q4.** The `CMD ["/bin/sh"]` row has `SIZE 0B`. Where is that instruction's effect actually stored?

---

## Exercise 2 — Your first Dockerfile, and the cache mechanics that decide your build time

### Steps

1. Create a minimal application:

```bash
mkdir -p ~/lab-702.3/app && cd ~/lab-702.3/app
cat > requirements.txt <<'EOF'
flask==3.0.3
EOF
cat > server.py <<'EOF'
from flask import Flask

app = Flask(__name__)


@app.get("/healthz")
def healthz():
    return {"status": "ok"}, 200


@app.get("/")
def index():
    return {"service": "lab-702.3"}, 200


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
EOF
```

2. Write a **deliberately badly ordered** Dockerfile:

```bash
cat > Dockerfile.slow <<'EOF'
# syntax=docker/dockerfile:1.7
FROM python:3.12-slim

WORKDIR /srv
COPY . /srv
RUN pip install --no-cache-dir -r requirements.txt
CMD ["python", "server.py"]
EOF
```

3. Build it and time it:

```bash
time docker build -f Dockerfile.slow -t lab:slow .
```

```
[+] Building 14.2s (9/9) FINISHED
 => [internal] load build definition from Dockerfile.slow            0.0s
 => [internal] load metadata for docker.io/library/python:3.12-slim  0.9s
 => [internal] load .dockerignore                                    0.0s
 => [internal] load build context                                    0.0s
 => => transferring context: 1.13kB                                  0.0s
 => CACHED [1/4] FROM docker.io/library/python:3.12-slim@sha256:2a3…  0.0s
 => [2/4] WORKDIR /srv                                               0.1s
 => [3/4] COPY . /srv                                                0.0s
 => [4/4] RUN pip install --no-cache-dir -r requirements.txt        11.8s
 => exporting to image                                               1.2s

real    0m14.4s
```

4. Change **one line of application code** — not a dependency — and rebuild:

```bash
sed -i 's/"lab-702.3"/"lab-702.3-v2"/' server.py
time docker build -f Dockerfile.slow -t lab:slow .
```

```
 => [3/4] COPY . /srv                                                0.0s
 => [4/4] RUN pip install --no-cache-dir -r requirements.txt        11.6s

real    0m13.9s
```

5. Now write the correctly ordered version:

```bash
cat > Dockerfile <<'EOF'
# syntax=docker/dockerfile:1.7
FROM python:3.12-slim

WORKDIR /srv

# Dependency manifest first: this layer's cache key changes only when
# requirements.txt changes, not when application code changes.
COPY requirements.txt /srv/requirements.txt
RUN pip install --no-cache-dir -r /srv/requirements.txt

COPY server.py /srv/server.py

EXPOSE 8080
CMD ["python", "server.py"]
EOF

docker build -t lab:fast .
sed -i 's/-v2/-v3/' server.py
time docker build -t lab:fast .
```

```
 => CACHED [2/5] WORKDIR /srv                                        0.0s
 => CACHED [3/5] COPY requirements.txt /srv/requirements.txt         0.0s
 => CACHED [4/5] RUN pip install --no-cache-dir -r /srv/requireme…   0.0s
 => [5/5] COPY server.py /srv/server.py                              0.0s

real    0m0.9s
```

6. Prove *why* the cache hit or missed. BuildKit computes a cache key per step; for `COPY`/`ADD` the key includes a checksum of the copied files, for `RUN` it includes the literal command string and the parent step's key.

```bash
docker build --progress=plain --no-cache -t lab:fast . 2>&1 | grep -E '^#[0-9]+ '
```

7. Break the cache without touching any file, using only the command string:

```bash
sed -i 's/pip install --no-cache-dir/pip install  --no-cache-dir/' Dockerfile
docker build -t lab:fast .
```

Observe that step 4 rebuilds, from a single extra space.

### Checkpoint 2

- **Q5.** In step 4, `requirements.txt` was byte-identical, yet `pip install` re-ran. Which instruction invalidated the cache, and what exactly was in its cache key?
- **Q6.** Explain precisely why adding one space to the `RUN` line in step 7 forced a rebuild. Does BuildKit ever inspect the *effect* of a `RUN` to decide cache validity?
- **Q7.** A colleague pins nothing and writes `RUN apt-get update && apt-get install -y curl`. Six weeks later the layer is still `CACHED` and ships a curl with a known CVE. Explain the failure mode and give two mitigations that do not involve `--no-cache` on every build.
- **Q8.** Why is `--no-cache-dir` passed to `pip` here, when the `RUN` already runs in an ephemeral build container? What would be left behind without it?
- **Q9.** What is the practical difference between `docker build --no-cache` and `docker builder prune`?

---

## Exercise 3 — Build context and `.dockerignore`

The build context is *uploaded* to the builder before the first instruction runs. On a repository with a `.git` directory, a `node_modules`, or a `target/`, this alone can dominate build time — and silently widen your attack surface via `COPY . .`.

### Steps

1. Manufacture a realistic dirty tree:

```bash
cd ~/lab-702.3/app
mkdir -p .git/objects node_modules
head -c 40M /dev/urandom > .git/objects/pack.bin
head -c 25M /dev/urandom > node_modules/blob.bin
echo "AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY" > .env
```

2. Build and read the context transfer line:

```bash
docker build --no-cache --progress=plain -t lab:ctx . 2>&1 | grep -i 'transferring context'
```

```
#2 [internal] load build context
#2 transferring context: 68.15MB 2.4s done
```

3. Add a `.dockerignore` and rebuild:

```bash
cat > .dockerignore <<'EOF'
# Everything git-related
.git
.gitignore

# Build artefacts and dependency trees rebuilt inside the image
node_modules
__pycache__/
**/*.pyc

# Local configuration and credentials — never in an image
.env
*.pem
*.key
secrets/

# Docker's own files
Dockerfile*
.dockerignore

# Re-include a file that a broad rule above would have excluded
!Dockerfile.keep
EOF

docker build --no-cache --progress=plain -t lab:ctx . 2>&1 | grep -i 'transferring context'
```

```
#2 transferring context: 3.42kB done
```

4. Verify the sensitive file really is absent from the image, and from every layer:

```bash
docker run --rm lab:ctx ls -la /srv
docker save lab:ctx | tar -tv 2>/dev/null | head
```

5. Confirm the negation rule works:

```bash
touch Dockerfile.keep
docker build --no-cache --progress=plain -t lab:ctx . 2>&1 | grep 'transferring context'
```

### Checkpoint 3

- **Q10.** `Dockerfile` is listed in `.dockerignore`, yet the build still succeeds. Why is that not a contradiction?
- **Q11.** A teammate argues `.dockerignore` is unnecessary because their Dockerfile only does `COPY server.py /srv/`. Give two concrete costs they still pay.
- **Q12.** You add `.env` to `.dockerignore` *after* having already built and pushed `myco/api:1.4.0`. Is the credential now safe? What is the correct remediation sequence?

---

## Exercise 4 — `ARG` vs `ENV`, and the classic secret leak

### Steps

1. Write a Dockerfile that uses build arguments in every legal position:

```bash
cd ~/lab-702.3/app
cat > Dockerfile.args <<'EOF'
# syntax=docker/dockerfile:1.7

# An ARG declared *before* the first FROM is "global": it is usable in FROM
# lines only, and is NOT inherited by build stages automatically.
ARG PYTHON_VERSION=3.12
ARG BASE=python:${PYTHON_VERSION}-slim

FROM ${BASE} AS runtime

# Re-declaration is mandatory to use a pre-FROM ARG inside a stage.
ARG PYTHON_VERSION
ARG BUILD_REV=unknown
ARG API_TOKEN=none

ENV APP_HOME=/srv \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

LABEL org.opencontainers.image.title="lab-702.3" \
      org.opencontainers.image.revision="${BUILD_REV}" \
      org.opencontainers.image.base.name="${BASE}"

WORKDIR ${APP_HOME}
RUN echo "built on python ${PYTHON_VERSION}, rev ${BUILD_REV}" > /srv/BUILDINFO
RUN echo "token seen at build time: ${API_TOKEN}" >> /srv/BUILDINFO

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY server.py .

CMD ["python", "server.py"]
EOF
```

2. Build with arguments supplied:

```bash
docker build -f Dockerfile.args \
  --build-arg BUILD_REV="$(git rev-parse --short HEAD 2>/dev/null || echo local)" \
  --build-arg API_TOKEN='s3cr3t-do-not-ship' \
  -t lab:args .
```

3. Investigate what survived into the image:

```bash
docker run --rm lab:args cat /srv/BUILDINFO
docker image inspect lab:args --format '{{json .Config.Env}}'
docker image inspect lab:args --format '{{json .Config.Labels}}'
```

```
built on python 3.12, rev a91c4f2
token seen at build time: s3cr3t-do-not-ship

["PATH=/usr/local/bin:...","LANG=C.UTF-8","APP_HOME=/srv","PYTHONDONTWRITEBYTECODE=1","PYTHONUNBUFFERED=1"]
{"org.opencontainers.image.base.name":"python:3.12-slim","org.opencontainers.image.revision":"a91c4f2","org.opencontainers.image.title":"lab-702.3"}
```

4. Now find the leak in the metadata, without running the container:

```bash
docker image history --no-trunc lab:args | grep -i token
```

```
<missing>  2 minutes ago  RUN |3 PYTHON_VERSION=3.12 BUILD_REV=a91c4f2 API_TOKEN=s3cr3t-do-not-ship /bin/sh -c echo "token seen at build time: ${API_TOKEN}" >> /srv/BUILDINFO # buildkit    58B
```

5. Prove that deleting the file in a later layer does **not** remove it:

```bash
cat >> Dockerfile.args <<'EOF'
RUN rm -f /srv/BUILDINFO
EOF
docker build -f Dockerfile.args --build-arg API_TOKEN='s3cr3t-do-not-ship' -t lab:args-rm .
docker run --rm lab:args-rm ls /srv/BUILDINFO || echo "gone from the union mount"
docker image history --no-trunc lab:args-rm | grep -c 's3cr3t' 
```

6. Contrast `ARG` and `ENV` at runtime:

```bash
docker run --rm lab:args sh -c 'echo "ARG=[${BUILD_REV}] ENV=[${APP_HOME}]"'
```

```
ARG=[] ENV=[/srv]
```

### Checkpoint 4

- **Q13.** Why is `BUILD_REV` empty at runtime while `APP_HOME` is populated? State the rule in one sentence.
- **Q14.** In step 5, `ls /srv/BUILDINFO` fails but the secret is still recoverable. Explain the storage mechanism that makes this true, and name the file marker involved.
- **Q15.** `ARG PYTHON_VERSION=3.12` is declared before `FROM` and re-declared after it. What breaks if you omit the re-declaration, and what does the `${PYTHON_VERSION}` expansion inside the stage evaluate to then?
- **Q16.** Someone proposes `--build-arg API_TOKEN=...` combined with `RUN unset API_TOKEN` as a fix. Why does this not work?
- **Q17.** Which two OCI annotation keys used above let a scanner determine the upstream base image and the source commit? Why does that matter for CVE triage?

---

## Exercise 5 — `ENTRYPOINT`, `CMD`, PID 1 and signal handling

This is where correct-looking images fail in production: rolling updates take the full termination grace period, in-flight requests are severed, and the pod's exit code is `137`.

### Steps

1. Write an application that logs its own signal handling:

```bash
cd ~/lab-702.3
mkdir -p sig && cd sig
cat > app.sh <<'EOF'
#!/bin/sh
term() {
  echo "$(date -Is) SIGTERM received — draining"
  exit 0
}
trap term TERM

echo "$(date -Is) started with pid $$ argv: $*"
while :; do
  sleep 1 &
  wait $!
done
EOF
chmod +x app.sh
```

2. Build two images that differ **only** in the form of `ENTRYPOINT`:

```bash
cat > Dockerfile.exec <<'EOF'
FROM alpine:3.20
COPY app.sh /app.sh
STOPSIGNAL SIGTERM
ENTRYPOINT ["/app.sh"]
CMD ["--default-flag"]
EOF

cat > Dockerfile.shell <<'EOF'
FROM alpine:3.20
COPY app.sh /app.sh
ENTRYPOINT /app.sh && echo "never reached"
CMD ["--default-flag"]
EOF

docker build -f Dockerfile.exec  -t sig:exec  .
docker build -f Dockerfile.shell -t sig:shell .
```

3. Inspect what PID 1 actually is in each:

```bash
docker run -d --name c-exec  sig:exec
docker run -d --name c-shell sig:shell
docker exec c-exec  ps -o pid,args
docker exec c-shell ps -o pid,args
```

```
# c-exec
PID   COMMAND
    1 {app.sh} /bin/sh /app.sh --default-flag
   ...

# c-shell
PID   COMMAND
    1 /bin/sh -c /app.sh && echo "never reached"
    7 {app.sh} /bin/sh /app.sh
   ...
```

4. Compare the stop behaviour and the exit code:

```bash
time docker stop c-exec  ; docker inspect -f '{{.State.ExitCode}}' c-exec
time docker stop c-shell ; docker inspect -f '{{.State.ExitCode}}' c-shell
docker logs c-exec ; echo '---' ; docker logs c-shell
```

```
c-exec
real    0m0.35s
0
---
c-shell
real    0m10.29s
137
```

```
2026-09-03T10:14:02+00:00 started with pid 1 argv: --default-flag
2026-09-03T10:14:19+00:00 SIGTERM received — draining
---
2026-09-03T10:14:05+00:00 started with pid 1 argv:
```

> The exact 10-second wait depends on the shell implementation: BusyBox `ash` and `dash` block in `wait()` and never deliver the signal onward, so the daemon's grace period elapses and `SIGKILL` ends it. Some shells `exec` a single simple command and would behave like the exec form. The *deterministic* evidence is the `ps` output in step 3 — read that, not the timing, to identify the failure.

5. Verify argument composition rules:

```bash
docker run --rm sig:exec --custom-flag & sleep 1; docker logs "$(docker ps -lq)"
docker run --rm sig:shell --custom-flag & sleep 1; docker logs "$(docker ps -lq)"
```

6. Add a proper init for zombie reaping and observe the difference:

```bash
docker run -d --init --name c-init sig:exec
docker exec c-init ps -o pid,args | head -3
```

```
PID   COMMAND
    1 /sbin/docker-init -- /app.sh --default-flag
    7 {app.sh} /bin/sh /app.sh --default-flag
```

### Checkpoint 5

- **Q18.** State the rule that determines when `CMD` is used as *arguments to* `ENTRYPOINT` versus as the *command itself*, and explain why `sig:shell` printed an empty `argv`.
- **Q19.** `c-shell` exited `137`. Decompose that number and name the signal.
- **Q20.** Your Kubernetes Deployment sets `terminationGracePeriodSeconds: 60` and your image uses shell-form `ENTRYPOINT`. Describe exactly what a rolling update looks like to end users, and how long each pod takes to disappear.
- **Q21.** What does `STOPSIGNAL SIGTERM` change here, and which runtime honours it — Docker, Kubernetes, or both?
- **Q22.** When is `--init` (or `tini`) genuinely required, given that your app already traps `SIGTERM` correctly?

---

## Exercise 6 — Multi-stage builds: from 800 MB to 6 MB

### Steps

1. Create a small Go service:

```bash
mkdir -p ~/lab-702.3/go-svc && cd ~/lab-702.3/go-svc
cat > go.mod <<'EOF'
module example.com/svc

go 1.23
EOF
cat > main.go <<'EOF'
package main

import (
	"encoding/json"
	"log"
	"net/http"
	"os"
)

func main() {
	http.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]string{"status": "ok"})
	})

	addr := ":8080"
	log.Printf("listening on %s as uid %d", addr, os.Getuid())
	log.Fatal(http.ListenAndServe(addr, nil))
}
EOF
```

2. Build the naive single-stage image first, so you have a baseline:

```bash
cat > Dockerfile.single <<'EOF'
FROM golang:1.23-alpine3.20
WORKDIR /src
COPY . .
RUN go build -o /src/svc ./main.go
EXPOSE 8080
CMD ["/src/svc"]
EOF
docker build -f Dockerfile.single -t svc:single .
```

3. Now the multi-stage version, targeting a distroless runtime:

```bash
cat > Dockerfile <<'EOF'
# syntax=docker/dockerfile:1.7

##############################################################################
# Stage 1 — build. Contains the toolchain, the module cache and the sources.
# None of this reaches the final image.
##############################################################################
FROM golang:1.23-alpine3.20 AS build

WORKDIR /src

# Module graph first, so `go mod download` is cached independently of sources.
COPY go.mod ./
RUN --mount=type=cache,target=/go/pkg/mod \
    go mod download

COPY . .

ARG TARGETOS=linux
ARG TARGETARCH=amd64

# CGO_ENABLED=0 produces a statically linked binary with no libc dependency,
# which is what makes a scratch/distroless base viable.
# -trimpath removes local filesystem paths; -ldflags "-s -w" drops the symbol
# table and DWARF data (smaller binary, no debugger symbols).
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} \
    go build -trimpath -ldflags="-s -w" -o /out/svc ./main.go

##############################################################################
# Stage 2 — optional test stage. Built only when explicitly targeted.
##############################################################################
FROM build AS test
RUN go vet ./...

##############################################################################
# Stage 3 — runtime. No shell, no package manager, no libc, non-root by tag.
##############################################################################
FROM gcr.io/distroless/static-debian12:nonroot AS runtime

COPY --from=build --chown=65532:65532 /out/svc /usr/local/bin/svc

USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/svc"]
EOF

docker build -t svc:multi .
docker image ls svc
```

```
REPOSITORY   TAG     IMAGE ID       CREATED          SIZE
svc          multi   4b7f1c9e2a30   5 seconds ago    8.42MB
svc          single  1ad3e8c05b71   40 seconds ago   358MB
```

4. Build only the test stage — note that the runtime stage is never executed:

```bash
docker build --target test -t svc:test .
```

5. Confirm the toolchain is really gone and the process is not root:

```bash
docker run --rm --entrypoint /bin/sh svc:multi -c 'echo hi' || echo "no shell in image"
docker run -d --name svc -p 8080:8080 svc:multi
docker exec svc id 2>&1 || echo "no exec possible: distroless has no shell"
docker inspect -f '{{.Config.User}}' svc:multi
curl -s localhost:8080/healthz ; echo
docker logs svc
```

```
no shell in image
65532:65532
{"status":"ok"}
2026/09/03 10:31:44 listening on :8080 as uid 65532
```

6. Debug a distroless container anyway, using a sidecar-style ephemeral approach:

```bash
docker run --rm -it --pid=container:svc --network=container:svc \
  --cap-add SYS_PTRACE alpine:3.20 sh -c 'apk add -q procps && ps -o pid,user,args'
```

### Checkpoint 6

- **Q23.** `svc:single` is 358 MB and `svc:multi` is 8.4 MB, from identical source. Enumerate what is *not* present in the second image.
- **Q24.** Why is `CGO_ENABLED=0` a prerequisite for `gcr.io/distroless/static-debian12`? What happens at runtime if you forget it?
- **Q25.** Stage `test` sits between `build` and `runtime` in the file. When you run `docker build -t svc:multi .` with no `--target`, is `go vet` executed? Explain BuildKit's evaluation model.
- **Q26.** `USER 65532:65532` uses a numeric UID rather than a name. Give the production reason this matters to Kubernetes, specifically to `runAsNonRoot`.
- **Q27.** The runtime image has no shell, so `docker exec` and `kubectl exec` are useless. Name the trade-off you have accepted and the two mechanisms that give you debuggability back.

---

## Exercise 7 — BuildKit: cache mounts, build secrets, heredocs

### Steps

1. Demonstrate a cache mount surviving across builds. Cache mounts are **not layers** — they persist in the builder, never in the image.

```bash
cd ~/lab-702.3/app
cat > Dockerfile.cache <<'EOF'
# syntax=docker/dockerfile:1.7
FROM python:3.12-slim

# sharing=locked serialises concurrent builds that use the same cache id,
# which is what you want for package managers that are not concurrency-safe.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends curl ca-certificates

WORKDIR /srv
COPY requirements.txt .
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install -r requirements.txt
COPY server.py .
CMD ["python", "server.py"]
EOF

docker build -f Dockerfile.cache -t lab:cache .
docker build --no-cache -f Dockerfile.cache -t lab:cache .   # note: still fast
```

2. Note there is **no** `rm -rf /var/lib/apt/lists/*` and yet:

```bash
docker run --rm lab:cache sh -c 'du -sh /var/lib/apt/lists /var/cache/apt'
```

```
4.0K	/var/lib/apt/lists
8.0K	/var/cache/apt
```

3. Do secrets properly. Create a credential and consume it without persisting it:

```bash
echo 'ghp_EXAMPLE_do_not_ship' > token.txt
cat > Dockerfile.secret <<'EOF'
# syntax=docker/dockerfile:1.7
FROM alpine:3.20

# The secret is bind-mounted into the RUN's mount namespace only, at
# /run/secrets/<id> by default. It is not part of the layer diff, not part
# of the cache key content, and not visible in image history.
RUN --mount=type=secret,id=gh_token \
    sh -c 'test -s /run/secrets/gh_token && \
           echo "token length: $(wc -c < /run/secrets/gh_token)" > /build.log'

CMD ["cat", "/build.log"]
EOF

docker build -f Dockerfile.secret --secret id=gh_token,src=./token.txt -t lab:secret .
docker run --rm lab:secret
```

```
token length: 41
```

4. Forensically confirm the secret is absent from every artefact:

```bash
docker image history --no-trunc lab:secret | grep -c 'ghp_' || echo "0 hits in history"
docker save lab:secret -o /tmp/lab-secret.tar
tar -xOf /tmp/lab-secret.tar | strings | grep -c 'ghp_EXAMPLE_do' || echo "0 hits in layers"
docker run --rm lab:secret ls /run/secrets 2>&1 || echo "mount does not exist at runtime"
```

5. Use heredocs to keep multi-line `RUN` blocks readable without backslash soup:

```bash
cat > Dockerfile.heredoc <<'OUTER'
# syntax=docker/dockerfile:1.7
FROM debian:12-slim

RUN <<EOF
set -eux
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl
apt-get clean
rm -rf /var/lib/apt/lists/*
EOF

COPY <<'EOF' /etc/app/config.yaml
server:
  listen: "0.0.0.0:8080"
  timeout: 30s
logging:
  level: info
EOF

CMD ["cat", "/etc/app/config.yaml"]
OUTER

docker build -f Dockerfile.heredoc -t lab:heredoc .
docker run --rm lab:heredoc
```

6. Compare `ADD` and `COPY` semantics explicitly:

```bash
cat > Dockerfile.addcopy <<'EOF'
# syntax=docker/dockerfile:1.7
FROM alpine:3.20

# ADD with a checksum is the only safe way to fetch a remote artefact:
# the build fails if the bytes do not match, making it reproducible.
ADD --checksum=sha256:9b2cabe89643d0d4b0a09b0f1c9f0e0c5b1e9c2a1f6f3f4b8b0c2d1e0f9a8b7c \
    https://example.com/tool.tar.gz /tmp/tool.tar.gz

# ADD auto-extracts a *local* tar; COPY never does.
ADD payload.tar.gz /opt/payload/
COPY payload.tar.gz /opt/raw/
EOF
```

### Checkpoint 7

- **Q28.** In step 1, `docker build --no-cache` was still fast. `--no-cache` is supposed to invalidate everything — what did it invalidate, and what did it deliberately leave intact?
- **Q29.** The image in step 2 has an empty `/var/lib/apt/lists` even though the Dockerfile never deletes it. Explain the mechanism, and state why the classic `&& rm -rf /var/lib/apt/lists/*` idiom exists at all.
- **Q30.** Contrast `--mount=type=secret` with `--build-arg` and with `COPY token.txt . && RUN ... && rm token.txt` on three axes: layer persistence, image history, and build cache.
- **Q31.** Give two behavioural differences between `ADD` and `COPY`, and state the rule of thumb for which to use by default. Why does `--checksum` change the security posture of a remote `ADD`?

---

## Exercise 8 — Tags, digests, registries and multi-architecture

### Steps

1. Run a local registry:

```bash
docker run -d --name registry -p 5000:5000 --restart=unless-stopped registry:2
curl -s http://localhost:5000/v2/_catalog ; echo
```

```
{"repositories":[]}
```

2. Tag deliberately. A tag is a **mutable pointer**; a digest is **immutable content**.

```bash
cd ~/lab-702.3/go-svc
docker tag svc:multi localhost:5000/lab/svc:1.0.0
docker tag svc:multi localhost:5000/lab/svc:1.0
docker tag svc:multi localhost:5000/lab/svc:latest

docker push localhost:5000/lab/svc:1.0.0
docker push localhost:5000/lab/svc:1.0
docker push localhost:5000/lab/svc:latest
```

```
The push refers to repository [localhost:5000/lab/svc]
6a1f0d3b8c2e: Pushed
1d2a5e0f7b91: Pushed
1.0.0: digest: sha256:c7d9e0a5b41f6a2d3c8e9f0b1a2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e size: 946
```

3. Capture the digest and pin by it:

```bash
DIG=$(docker image inspect localhost:5000/lab/svc:1.0.0 \
      --format '{{index .RepoDigests 0}}')
echo "$DIG"
docker pull "$DIG"
```

4. Prove that a tag can be repointed while the digest cannot:

```bash
docker tag alpine:3.20 localhost:5000/lab/svc:1.0.0
docker push localhost:5000/lab/svc:1.0.0
docker buildx imagetools inspect localhost:5000/lab/svc:1.0.0 --format '{{.Manifest.Digest}}'
docker buildx imagetools inspect "$DIG" --format '{{.Manifest.Digest}}'
```

5. Build a multi-architecture image. This needs a `docker-container` driver — the default `docker` driver cannot emit a manifest list.

```bash
docker buildx create --name multi --driver docker-container --use
docker buildx inspect --bootstrap | head -20

docker buildx build \
  --platform linux/amd64,linux/arm64 \
  -t localhost:5000/lab/svc:multiarch \
  --push .
```

6. Inspect the resulting **image index** (manifest list):

```bash
docker buildx imagetools inspect localhost:5000/lab/svc:multiarch
```

```
Name:      localhost:5000/lab/svc:multiarch
MediaType: application/vnd.oci.image.index.v1+json
Digest:    sha256:31ab7e5d0c9f...

Manifests:
  Name:      localhost:5000/lab/svc:multiarch@sha256:a0c1...
  MediaType: application/vnd.oci.image.manifest.v1+json
  Platform:  linux/amd64

  Name:      localhost:5000/lab/svc:multiarch@sha256:b4d7...
  MediaType: application/vnd.oci.image.manifest.v1+json
  Platform:  linux/arm64
```

7. Understand why the Dockerfile in Exercise 6 cross-compiles correctly. BuildKit injects `TARGETOS`/`TARGETARCH`/`TARGETPLATFORM` automatically; combined with `FROM --platform=$BUILDPLATFORM`, the toolchain runs natively and only the output is cross-targeted:

```bash
sed -i 's|^FROM golang:1.23-alpine3.20 AS build|FROM --platform=$BUILDPLATFORM golang:1.23-alpine3.20 AS build|' Dockerfile
time docker buildx build --platform linux/amd64,linux/arm64 \
  -t localhost:5000/lab/svc:xc --push .
```

8. Export the cache so CI runners share it:

```bash
docker buildx build \
  --cache-to   type=registry,ref=localhost:5000/lab/svc:buildcache,mode=max \
  --cache-from type=registry,ref=localhost:5000/lab/svc:buildcache \
  -t localhost:5000/lab/svc:1.0.1 --push .
```

### Checkpoint 8

- **Q32.** After step 4, a Deployment that references `localhost:5000/lab/svc:1.0.0` with `imagePullPolicy: IfNotPresent` is scaled up onto a new node. Which image runs there, and which runs on the old nodes? Name the class of bug this produces.
- **Q33.** Write the fully qualified reference for `nginx:1.27` as the registry client resolves it, and identify each of the four components.
- **Q34.** Why can the default `docker` buildx driver not produce a multi-architecture image, and what does the `docker-container` driver add?
- **Q35.** Without `--platform=$BUILDPLATFORM` on the build stage, how does BuildKit produce the `linux/arm64` variant on an amd64 host, and why is step 7 dramatically faster?
- **Q36.** What does `mode=max` change about the exported cache compared to the default, and what is the storage cost?

---

## Exercise 9 — Daemonless building: Podman, Buildah, and in-cluster builds

The Docker daemon runs as root and its socket is root-equivalent. Mounting `/var/run/docker.sock` into a CI job to build images hands that job full control of the host. Rootless, daemonless builders exist precisely to remove this.

### Steps

1. Build the identical Dockerfile with Podman, rootless:

```bash
cd ~/lab-702.3/go-svc
podman build -t svc:podman .
podman image ls svc
podman unshare cat /proc/self/uid_map
```

```
         0       1000          1
         1     100000      65536
```

2. Note the fully qualified name requirement — Podman does not silently assume Docker Hub:

```bash
podman image inspect svc:podman --format '{{.Config.User}}'
grep -A5 '^\[registries.search\]\|unqualified-search' /etc/containers/registries.conf
```

3. Use Buildah with a Dockerfile (`bud` = *build using Dockerfile*):

```bash
buildah bud -t svc:buildah -f Dockerfile .
buildah images
```

4. Now build **without any Dockerfile**, scripting the image directly. This is Buildah's distinguishing capability: the image definition becomes a shell program.

```bash
#!/usr/bin/env bash
set -euo pipefail

ctr=$(buildah from gcr.io/distroless/static-debian12:nonroot)
mnt=$(buildah mount "$ctr")

install -D -m 0555 -o 65532 -g 65532 \
    ./svc-binary "${mnt}/usr/local/bin/svc"

buildah config \
  --user 65532:65532 \
  --port 8080 \
  --entrypoint '["/usr/local/bin/svc"]' \
  --label org.opencontainers.image.title="svc" \
  --label org.opencontainers.image.source="https://example.com/svc" \
  "$ctr"

buildah unmount "$ctr"
buildah commit --format oci --rm "$ctr" localhost/svc:scripted
buildah push --tls-verify=false localhost/svc:scripted \
    docker://localhost:5000/lab/svc:scripted
```

5. Build inside Kubernetes with no privileged daemon, using BuildKit rootless:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: buildkit-build
spec:
  restartPolicy: Never
  containers:
    - name: buildkit
      image: moby/buildkit:v0.16.0-rootless
      command:
        - buildctl-daemonless.sh
        - build
        - --frontend=dockerfile.v0
        - --local=context=/workspace
        - --local=dockerfile=/workspace
        - --output=type=image,name=registry.example.com/lab/svc:ci,push=true
      env:
        - name: BUILDKITD_FLAGS
          value: --oci-worker-no-process-sandbox
      securityContext:
        seccompProfile:
          type: Unconfined
        appArmorProfile:
          type: Unconfined
        runAsUser: 1000
        runAsGroup: 1000
      volumeMounts:
        - name: workspace
          mountPath: /workspace
        - name: docker-config
          mountPath: /home/user/.docker
  volumes:
    - name: workspace
      emptyDir: {}
    - name: docker-config
      secret:
        secretName: registry-credentials
        items:
          - key: .dockerconfigjson
            path: config.json
```

6. The equivalent with Kaniko, which the 701 objectives list explicitly:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: kaniko-build
spec:
  restartPolicy: Never
  containers:
    - name: kaniko
      image: gcr.io/kaniko-project/executor:latest
      args:
        - --context=git://github.com/example/svc.git#refs/heads/main
        - --dockerfile=Dockerfile
        - --destination=registry.example.com/lab/svc:ci
        - --cache=true
        - --cache-repo=registry.example.com/lab/svc-cache
        - --snapshot-mode=redo
      volumeMounts:
        - name: docker-config
          mountPath: /kaniko/.docker
  volumes:
    - name: docker-config
      secret:
        secretName: registry-credentials
        items:
          - key: .dockerconfigjson
            path: config.json
```

> Kaniko executes the `RUN` instructions **in its own container's filesystem** and snapshots the diff after each one — that is why it needs no daemon and no privileges, and also why running it outside a container is explicitly unsupported. Check the project's current maintenance status before adopting it for new pipelines; several teams have moved to rootless BuildKit or Buildah for the same job.

### Checkpoint 9

- **Q37.** A CI job mounts `/var/run/docker.sock` to build images. Describe concretely how a malicious `Dockerfile` — or a compromised dependency in the build — escalates to root on the CI host.
- **Q38.** Explain what `podman unshare cat /proc/self/uid_map` printed and how it lets a non-root user create a container whose processes believe they are UID 0.
- **Q39.** Buildah can build with no `Dockerfile` at all. Give one production scenario where that is materially better than a `Dockerfile`, and one thing you lose.
- **Q40.** Both the BuildKit and the Kaniko Pod mount a `kubernetes.io/dockerconfigjson` Secret rather than passing credentials as args. Name two distinct reasons.

---

## Exercise 10 — Diagnostics: a broken build and a bloated image

### Steps

1. Save this Dockerfile. It contains **five** defects — some fail the build, some only fail in production.

```bash
mkdir -p ~/lab-702.3/broken && cd ~/lab-702.3/broken
cp ../app/server.py ../app/requirements.txt .

cat > Dockerfile <<'EOF'
FROM python:3.12

RUN useradd -m -u 10001 appuser
USER appuser

WORKDIR /opt/app
RUN pip install -r requirements.txt

COPY . .

VOLUME /opt/app/data
RUN mkdir -p /opt/app/data && echo "seed" > /opt/app/data/seed.txt

ENV FLASK_SECRET=hunter2
EXPOSE 8080
ENTRYPOINT python server.py
EOF
```

2. Build with full output and read the first failure:

```bash
docker build --progress=plain -t broken:1 . 2>&1 | tail -30
```

```
#7 [4/8] RUN pip install -r requirements.txt
#7 0.412 ERROR: Could not open requirements file:
#7 0.412 [Errno 2] No such file or directory: 'requirements.txt'
#7 ERROR: process "/bin/sh -c pip install -r requirements.txt" did not exit with code 0
```

3. Fix that one, rebuild, and read the next:

```bash
sed -i 's|^RUN pip install -r requirements.txt|COPY requirements.txt .\nRUN pip install --no-cache-dir -r requirements.txt|' Dockerfile
docker build --progress=plain -t broken:2 . 2>&1 | tail -20
```

```
#9 [6/9] COPY requirements.txt .
#9 ERROR: failed to calculate checksum ... permission denied
```

4. Use a debug target to get a shell at the exact point of failure — BuildKit does not leave runnable intermediate images the way the classic builder did:

```bash
cat >> Dockerfile <<'EOF'

FROM python:3.12 AS debug
RUN useradd -m -u 10001 appuser
WORKDIR /opt/app
RUN ls -ld /opt/app && id appuser
EOF
docker build --target debug --progress=plain -t broken:debug . 2>&1 | grep -A3 'ls -ld'
```

```
#12 0.298 drwxr-xr-x 2 root root 4096 Sep  3 10:52 /opt/app
#12 0.301 uid=10001(appuser) gid=10001(appuser) groups=10001(appuser)
```

5. Repair everything and measure:

```bash
cat > Dockerfile <<'EOF'
# syntax=docker/dockerfile:1.7
FROM python:3.12-slim AS runtime

RUN useradd --create-home --uid 10001 --shell /usr/sbin/nologin appuser \
 && install -d -o appuser -g appuser -m 0755 /opt/app /opt/app/data

WORKDIR /opt/app

# Dependencies installed as root into the system site-packages, then the
# process drops privileges. The app never needs write access to its own code.
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY --chown=appuser:appuser server.py .

# Secrets come from the orchestrator at runtime, never baked into the config.
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

USER 10001:10001
EXPOSE 8080
STOPSIGNAL SIGTERM

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8080/healthz').status==200 else 1)"

ENTRYPOINT ["python", "server.py"]
EOF

docker build -t fixed:1 .
docker image ls | grep -E '^(broken|fixed)'
docker run -d --name fixed -p 8080:8080 fixed:1
sleep 8
docker inspect -f '{{.State.Health.Status}} uid={{.Config.User}}' fixed
docker inspect -f '{{json .Mounts}}' fixed
```

```
healthy uid=10001:10001
[]
```

6. Find where the remaining bytes went:

```bash
docker image history fixed:1 --format 'table {{.Size}}\t{{.CreatedBy}}' | head
docker system df -v | head -20
```

### Checkpoint 10

- **Q41.** List the five defects in the original Dockerfile of step 1. For each, say whether it breaks the build or only manifests at runtime.
- **Q42.** In step 3, `COPY requirements.txt .` failed with `permission denied` even though `COPY` is executed by the builder, not by `appuser`. What actually determines the ownership and the target directory permissions here, and why does `COPY --chown` fix it?
- **Q43.** `VOLUME /opt/app/data` was followed by a `RUN` that seeds a file into that path. Explain what happens to `seed.txt`, and describe the second, subtler problem `VOLUME` creates every time the image is run.
- **Q44.** The fixed image declares `HEALTHCHECK` and it reports `healthy`. Your platform team says this is dead weight in the Kubernetes deployment. Are they right? What is the Kubernetes equivalent, and does the container runtime under Kubernetes evaluate `HEALTHCHECK` at all?

---

## Cleanup

```bash
docker rm -f fixed svc c-exec c-shell c-init registry 2>/dev/null
docker buildx rm multi 2>/dev/null
docker image rm -f $(docker image ls -q 'lab' 'svc' 'sig' 'broken' 'fixed') 2>/dev/null
docker builder prune -af
rm -rf ~/lab-702.3
```

---

## Sources

- LPI — Exam 701-100 Objectives (DevOps Tools Engineer, v2.0): https://www.lpi.org/our-certifications/exam-701-objectives/
- Dockerfile reference: https://docs.docker.com/reference/dockerfile/
- Docker build cache: https://docs.docker.com/build/cache/
- Multi-stage builds: https://docs.docker.com/build/building/multi-stage/
- Build secrets: https://docs.docker.com/build/building/secrets/
- Multi-platform builds: https://docs.docker.com/build/building/multi-platform/
- Buildx drivers: https://docs.docker.com/build/builders/drivers/
- BuildKit: https://github.com/moby/buildkit
- OCI Image Format Specification: https://github.com/opencontainers/image-spec/blob/main/spec.md
- OCI predefined annotation keys: https://github.com/opencontainers/image-spec/blob/main/annotations.md
- Podman build: https://docs.podman.io/en/latest/markdown/podman-build.1.html
- Buildah: https://buildah.io/ — https://github.com/containers/buildah/blob/main/docs/tutorials/
- Kaniko: https://github.com/GoogleContainerTools/kaniko
- Distroless base images: https://github.com/GoogleContainerTools/distroless
- Kubernetes probes: https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/
- Kubernetes Pod security context (`runAsNonRoot`): https://kubernetes.io/docs/tasks/configure-pod-container/security-context/

---

<details>
<summary><strong>Answers</strong></summary>

### Exercise 1

**A1.** They are digests of two different byte streams of the same logical layer. `.RootFS.Layers` holds **diffID**s — `sha256` of the *uncompressed* tar. The registry manifest holds the digest of the *compressed* blob (gzip or zstd) as it is actually transferred and stored. The diffID is what makes the image config deterministic regardless of compression settings; the blob digest is what content-addresses the transferred bytes. `docker pull` compares **blob digests** from the manifest against what it already has, so that is the one that decides a download skip. The config itself is also a blob, addressed by its own digest — and the digest of the *manifest* is what a pinned `image@sha256:...` reference names.

**A2.** No. Layers are shared and stored once, keyed by their content digest. Ten images sharing the `alpine:3.20` base store that 8.83 MB one time. `docker image ls` reports the *cumulative virtual size* of an image's full layer chain, which double-counts shared layers when you sum across rows. `docker system df -v` reports the deduplicated on-disk reality and shows a `SHARED SIZE` column. This is the single most common misreading of image size in capacity planning.

**A3.** `<missing>` means the local content store holds the layer but no *image config* naming it — intermediate configs are not distributed. A registry ships one config plus the layer blobs, not one config per historical step. Consequently you cannot `docker run` an intermediate layer of a pulled image: there is no image ID to reference. (With BuildKit this is also true for images you build yourself, unlike the legacy builder which created a real intermediate image per step. Use `--target` on a debug stage instead — Exercise 10 step 4.)

**A4.** In the **image config JSON**, under `.config.Cmd`. `CMD`, `ENV`, `ENTRYPOINT`, `USER`, `WORKDIR`, `EXPOSE`, `LABEL`, `VOLUME` and `STOPSIGNAL` are metadata-only instructions: they mutate the config blob and produce an empty layer diff, hence `0B`. The `history` array in the config records them with `empty_layer: true`.

### Exercise 2

**A5.** `COPY . /srv`. Its cache key is derived from a checksum over the *contents and metadata of every file in the build context that the pattern matches*. `server.py` changed, so the checksum changed, so that step missed. Cache invalidation is **transitive and ordered**: once a step misses, every subsequent step in that stage misses too, regardless of whether their own inputs changed. `pip install` is downstream of the `COPY`, so it re-ran.

**A6.** BuildKit's cache key for a `RUN` is a hash of `(parent step's cache key, the literal command string, the mount specifications, the relevant ARG/ENV values referenced)`. The command string is compared byte-for-byte, so an extra space produces a different key. BuildKit never inspects the *result* of a `RUN` to judge cache validity — it cannot, because it would have to execute the step to find out. This is the entire reason `RUN apt-get update` caching is dangerous.

**A7.** The failure mode is a **stale package index frozen in cache**. The `RUN` string never changes, its parent never changes, so BuildKit reuses the layer built six weeks ago — including the `apt` index and the package versions resolved then. Mitigations, either of:
1. Pin explicitly: `apt-get install -y curl=8.5.0-2ubuntu10.4`, so an upgrade is a Dockerfile change and thus a cache miss.
2. Rebuild on a schedule with `--pull --no-cache` (nightly base-image refresh in CI), publishing a new patch tag.
3. Break the cache intentionally with a periodic build arg: `ARG CACHEBUST=weekly-2026-w36` placed just before the `apt` block.
4. Scan the *published* image (Trivy/Grype) in CI and fail the pipeline on a threshold, so a stale layer cannot ship silently.

**A8.** `pip` writes a wheel cache to `~/.cache/pip`, and that write happens *inside the layer being built*. The build container is ephemeral but its filesystem diff is exactly what becomes the layer, so the cache would be committed permanently into the image — typically tens to hundreds of MB of wheels that are never used again. `--no-cache-dir` prevents the write. The superior alternative is Exercise 7's `--mount=type=cache,target=/root/.cache/pip`, which keeps the cache *out of the layer* while still reusing it across builds.

**A9.** `--no-cache` ignores existing cache entries **for this build only**; the entries remain on disk and later builds can still hit them. `docker builder prune` **deletes** the cache records and the associated blobs from the builder's storage, freeing disk. Use `--no-cache` to force fresh package resolution; use `builder prune` to reclaim space. Note that `--no-cache` does *not* clear `--mount=type=cache` volumes (see A28).

### Exercise 3

**A10.** `.dockerignore` filters the context that is **transferred to the builder for `COPY`/`ADD`**. The `Dockerfile` itself is read through a separate channel — BuildKit's `dockerfile` frontend receives it as a distinct input (`--local=dockerfile=...` / the `-f` path), not by fishing it out of the copied context. Ignoring it is standard practice so that editing the Dockerfile does not itself invalidate a `COPY . .` checksum.

**A11.** (1) **Transfer cost and cache churn**: the entire 68 MB context is checksummed and sent on every build, adding seconds to minutes per build and per CI runner. (2) **Blast radius on future edits**: the moment anyone changes that `COPY` to `COPY . .` — a routine refactor — every ignored file lands in the image, including `.env` and `.git` (which contains full history, deleted secrets included). `.dockerignore` is a standing guard, not a per-Dockerfile optimisation. (3) Secondarily, `.git` in the context is enough for a leaked build log or a `--progress=plain` dump to expose paths and branch names.

**A12.** **No, it is not safe.** The credential is in a published layer, in a registry, addressable by digest, and possibly pulled onto every node that ran it and mirrored by any pull-through cache. Remediation, in order:
1. **Rotate the credential immediately.** This is the only step that actually restores security; everything else is cleanup.
2. Delete the tag *and the underlying manifests* from the registry, then run garbage collection so the blobs are unreachable. Deleting a tag alone leaves the digest pullable.
3. Purge any pull-through caches, node image caches, and CI artefact stores.
4. Rebuild from a clean context with `.dockerignore` in place and republish under a new version.
5. Add a pre-push secret scan (`trivy image --scanners secret`, `gitleaks`) to CI so this fails the pipeline next time.

### Exercise 4

**A13.** `ENV` writes into the image config's `Env` array, which the runtime injects into the container's environment. `ARG` exists only in the builder's variable scope for the duration of the build and is never written to `.Config.Env`. **Rule: `ARG` is build-time-only and does not survive into the running container; `ENV` is baked into the image config and does.**

**A14.** Layers are stacked by a union filesystem (overlay2). A deletion in an upper layer is recorded as a **whiteout** — with overlayfs, a character device with major/minor `0/0` named after the deleted file (`.wh.BUILDINFO` in the OCI tar layer representation). The lower layer still contains the original bytes verbatim; the union mount merely hides them. Anyone with the image can extract the layer tarball (`docker save`, `crane export`, or just reading the blob from the registry) and recover the file. **Deleting a secret in a later instruction never removes it from an image.** The only fixes are: never write it (use `--mount=type=secret`), or write it in a stage that is discarded (multi-stage), or squash — and rotate the credential regardless.

**A15.** Without the re-declaration, `PYTHON_VERSION` is **not in scope inside the stage** and `${PYTHON_VERSION}` expands to the **empty string**. The build succeeds (no error is raised for an undefined variable), and `/srv/BUILDINFO` silently reads `built on python , rev ...`. This is a classic silent-corruption bug: the `FROM ${BASE}` line worked, so the developer assumes the variable is available everywhere. Pre-`FROM` ARGs are global to `FROM` lines only; `ARG NAME` with no default inside a stage re-imports the global value.

**A16.** Because the leak is not in the environment — it is in the **build history metadata**. BuildKit records the fully expanded `RUN` command in the image config's `history[].created_by` field, including the `|N ARG=value` prefix listing every build arg in scope. `docker image history --no-trunc` reads it straight out of the config; so does anyone who pulls the image. `unset` at runtime cannot retroactively edit a JSON blob that was written at build time. Additionally, if the `RUN` wrote the value to disk (as here), A14 applies too.

**A17.** `org.opencontainers.image.base.name` (which upstream image and tag this was built from) and `org.opencontainers.image.revision` (the source commit). Together they let a scanner answer the two questions CVE triage actually needs: *"is my base image affected, and has a fixed base been published?"* and *"which source tree produced this artefact, so I can patch and rebuild the right thing?"* Without them, a vulnerability report against a running container gives you a digest and no path back to source. `org.opencontainers.image.source` (repository URL) and `.version` complete the set; modern registries and tools like Grype and Syft read these annotations directly.

### Exercise 5

**A18.** **Rule:** `CMD` is passed as default arguments to `ENTRYPOINT` **only when `ENTRYPOINT` is in exec form** (JSON array). In shell form, BuildKit rewrites `ENTRYPOINT cmd` to `["/bin/sh", "-c", "cmd"]` — the argument vector is fully determined by that string, so `CMD` and any `docker run` arguments have nowhere to go and are **silently discarded**. That is why `sig:shell` logged an empty `argv`: `/app.sh` was invoked by the shell with no parameters. In step 5 the same applies to `--custom-flag`, which the exec-form image receives and the shell-form image ignores.

**A19.** `137 = 128 + 9`. Unix convention: a process terminated by signal *N* is reported by the shell/runtime as `128 + N`. Signal 9 is `SIGKILL`. So the container was force-killed, which is exactly what the daemon does when the grace period expires. `143 = 128 + 15 = SIGTERM` would indicate a clean signal-induced exit; `0` (as `c-exec` produced) indicates the trap handled it and exited deliberately.

**A20.** The kubelet sends `SIGTERM` to PID 1 — the shell — which never relays it. Meanwhile the endpoint is removed from the Service, so no *new* traffic arrives, but **every in-flight request is severed** when the kill lands. The pod sits in `Terminating` for the full **60 seconds**, then receives `SIGKILL`. With `maxUnavailable: 1` and 10 replicas, a rolling update that should take seconds takes **~10 minutes**, during which users see reset connections and 502s from the ingress on each cycle. The symptom that gives it away in the field: pods stuck in `Terminating` for exactly `terminationGracePeriodSeconds`, with `lastState.terminated.exitCode: 137`.

**A21.** `STOPSIGNAL SIGTERM` sets `.Config.StopSignal` in the image config — the signal the *Docker daemon* sends on `docker stop`. It is useful for applications that expect something else (nginx wants `SIGQUIT` for graceful shutdown, Apache `SIGWINCH`). **Kubernetes does not read it**: the CRI shutdown path sends `SIGTERM` unconditionally. So `STOPSIGNAL` is honoured by Docker/Podman and ignored under Kubernetes — if your app needs a different signal in a cluster, wrap it or use a `preStop` lifecycle hook.

**A22.** `--init` (or `tini` as PID 1) is required for **zombie reaping** and for **signal delivery to a process tree**. PID 1 in a PID namespace has two special properties: orphaned children are reparented to it and it must `wait()` on them, and the kernel does not apply default signal dispositions to it. A shell script or an application that spawns subprocesses (a supervisor, a language runtime that forks workers, anything calling out to a CLI) will accumulate zombies if it does not reap, eventually exhausting the PID table. Trapping `SIGTERM` correctly solves shutdown, not reaping. If your PID 1 is a single static binary that forks nothing, `--init` is unnecessary.

### Exercise 6

**A23.** Absent from `svc:multi`: the Go toolchain (`go`, `gofmt`, the standard library source tree, ~250 MB), the module cache, the application source code (`main.go`, `go.mod`), the Alpine base userland (`apk`, BusyBox, `/bin/sh`), the package database, `libc`, and any CA/shell/coreutils environment. What remains is the distroless base (CA certificates, `/etc/passwd` with the `nonroot` entry, timezone data, a few dozen files) plus the single static binary. The security consequence matters more than the size: with no shell and no package manager, the standard post-exploitation toolkit is unavailable in the container, and a CVE scanner reports essentially zero OS-package findings because there are no OS packages.

**A24.** `gcr.io/distroless/static-debian12` deliberately contains **no dynamic loader and no libc**. A Go binary built with `CGO_ENABLED=1` (the default when a C toolchain is present) links against `libc` for `net` and `os/user` resolution, producing a dynamically linked ELF. Running it on `static` fails immediately at exec with the runtime's least helpful error: `exec /usr/local/bin/svc: no such file or directory` — the missing file is the *interpreter* (`/lib/x86_64-linux-gnu/libc.so.6`), not the binary. Diagnose with `file svc` (look for "statically linked" vs "dynamically linked, interpreter …") or `ldd svc`. If you genuinely need cgo, use `gcr.io/distroless/base-debian12` instead, which ships glibc.

**A25.** **No, `go vet` is not executed.** BuildKit builds a DAG of stages and evaluates only the transitive dependencies of the requested target. Without `--target`, the target is the **last stage in the file** (`runtime`), whose only dependency is `build` (via `COPY --from=build`). Nothing references `test`, so that node is pruned and never runs. This is a real trap in CI: putting a test stage in the Dockerfile does not make it run — you need an explicit `docker build --target test .` step, or you need the runtime stage to depend on it (e.g. `COPY --from=test /dev/null /tmp/.test-passed`).

**A26.** Kubernetes' `securityContext.runAsNonRoot: true` is validated by the kubelet **before the container starts**, and the kubelet only sees the image config's `User` string — it does not have the container's `/etc/passwd`. If `User` is a *name* like `appuser`, the kubelet cannot resolve it to a UID and the pod fails admission with `CreateContainerConfigError: container has runAsNonRoot and image has non-numeric user (appuser), cannot verify user is non-root`. A numeric `USER 65532:65532` is resolvable without the image filesystem, so the check passes. It is also more robust generally: name-to-UID mapping depends on the base image's `/etc/passwd`, which a base-image bump can change underneath you.

**A27.** The trade-off: you traded **interactive debuggability** for a minimal attack surface and a near-empty CVE report. You get debuggability back through:
1. **Ephemeral debug containers** — `kubectl debug -it <pod> --image=busybox --target=<container>`, which attaches a container sharing the target's PID and network namespaces without modifying the pod. The Docker equivalent is step 6's `--pid=container: --network=container:`.
2. **Externalised observability** — structured logs to stdout, metrics, traces, and a `:debug` variant tag of the same image (`gcr.io/distroless/static-debian12:debug-nonroot` includes a BusyBox shell) that you can deploy temporarily when you must go in.

### Exercise 7

**A28.** `--no-cache` invalidates BuildKit's **layer/step cache** — every instruction re-executes. It deliberately does **not** clear `--mount=type=cache` volumes, which are persistent scratch directories owned by the builder, keyed by their `target` (or explicit `id=`), and shared across builds. So `apt-get update` and `pip install` re-executed, but found their downloaded `.deb`s and wheels already present and skipped the network. That is the point: `--no-cache` should force a fresh *evaluation*, not a slow one. To clear cache mounts, use `docker builder prune --filter type=exec.cachemount` (or `-af`).

**A29.** The `--mount=type=cache` directories exist only inside that `RUN`'s mount namespace. When the instruction finishes, the mount is detached and the layer diff is computed against the underlying (empty) directories — so the downloaded index and `.deb` files were **never part of the layer**. The traditional `&& rm -rf /var/lib/apt/lists/*` exists because without a cache mount those files *are* written into the layer, adding 30–50 MB permanently; and because of A14, deleting them in a *separate* `RUN` would not help — hence the single-`RUN` `&&` chain idiom. Cache mounts make that idiom unnecessary and are strictly better, since they also make rebuilds fast.

**A30.**

| | layer persistence | image history | build cache |
|---|---|---|---|
| `--mount=type=secret` | **never** — bind-mounted into the RUN's mount namespace at `/run/secrets/<id>`, detached before the diff | **not recorded**; the mount spec appears, the value does not | the secret **content** is excluded from the cache key by default (only its `id` participates), so rotating a token does not invalidate the build |
| `--build-arg` | not directly, but any file the RUN writes with the value is permanent | **fully recorded** in `created_by` as `\|N NAME=value` — trivially readable by anyone with the image | participates in the cache key, so the value is also stored in cache metadata |
| `COPY` then `rm` | **permanent** in the `COPY` layer, hidden by a whiteout in the `rm` layer | the `COPY` is recorded; the file contents are in the layer blob | the file's checksum is in the cache key |

Only the first is safe. The second two both require credential rotation if used.

**A31.** Differences:
1. `ADD` **auto-extracts local tar archives** (`.tar`, `.tar.gz`, `.tar.bz2`, `.tar.xz`) into the destination; `COPY` copies them as opaque files.
2. `ADD` can fetch **remote URLs** and (with Dockerfile 1.4+) **Git repositories**; `COPY` cannot — it only reads the build context or another stage via `--from`.

**Rule of thumb: use `COPY` by default; use `ADD` only when you specifically want tar auto-extraction or a checksummed remote fetch.** `ADD`'s implicit extraction is a footgun — a `.tar.gz` you meant to ship intact silently explodes into the image, and remote extraction historically enabled path-traversal via crafted archives.

`--checksum=sha256:...` changes the posture in two ways: the build **fails** if the remote bytes differ from the pin, so a compromised or repointed download URL cannot inject content; and the fetch becomes **reproducible and cacheable by content** rather than by URL, since BuildKit can use the checksum as the cache key without re-downloading. Without it, `ADD <url>` is an unauthenticated supply-chain入口 whose result can change between builds.

### Exercise 8

**A32.** The new node pulls `1.0.0` fresh and gets the **repointed manifest — `alpine:3.20`**, which has no application in it and will crash-loop. The old nodes already have a local image tagged `1.0.0`, and `IfNotPresent` means they never re-check the registry, so they keep running the **original Go service**. You now have a Deployment whose replicas run **different code under the same tag**. This class of bug is **mutable-tag drift** (or "tag reuse"): it produces heisenbugs that reproduce on some pods and not others, defeats rollback (rolling back to `1.0.0` gets you whatever `1.0.0` points at *today*), and breaks audit. The fix is to deploy by **digest** — `image: registry/lab/svc@sha256:c7d9e0...` — and to enable registry **tag immutability** so a push to an existing tag is rejected.

**A33.** `docker.io/library/nginx:1.27` — and, resolved fully, `index.docker.io/library/nginx:1.27@sha256:<digest>`.
- **Registry host**: `docker.io` (resolved to `index.docker.io`). Omitted, the Docker CLI defaults to Docker Hub; **Podman does not** and will either consult `unqualified-search-registries` in `/etc/containers/registries.conf` or refuse.
- **Namespace/organisation**: `library` — Docker Hub's implicit namespace for official images.
- **Repository**: `nginx`.
- **Tag**: `1.27` — a mutable pointer. Optionally replaced or accompanied by `@sha256:<digest>`, an immutable content reference. If both are given, the digest wins and the tag is documentation.

**A34.** The default `docker` driver builds **through the Docker Engine's embedded BuildKit and exports into the local image store**, which uses the legacy Docker image format — that store has no representation for a manifest list/image index, so it can hold exactly one platform per tag. It also has no way to emulate a foreign architecture. The `docker-container` driver runs BuildKit in a **dedicated container**, which gives you: manifest-list output (`--platform` with multiple values), QEMU-based emulation for foreign architectures via `binfmt_misc`, remote/registry cache export (`--cache-to type=registry`), and the full set of exporters (`type=oci`, `type=local`, attestations). Alternatives: the `kubernetes` driver (builders as pods, native nodes per architecture — faster than emulation) and the `remote` driver.

**A35.** Without `--platform=$BUILDPLATFORM`, `FROM golang:...` inherits the **target** platform, so BuildKit pulls the `linux/arm64` Go toolchain and runs it under **QEMU user-mode emulation** on your amd64 host. Every compiler instruction is translated — typically **5–20× slower**, and prone to obscure emulation bugs in JITs and threaded builds.

With `--platform=$BUILDPLATFORM`, the build stage pins to the **host's native** platform, so the amd64 Go toolchain runs at full speed and cross-compiles via `GOOS`/`GOARCH` (which BuildKit supplies automatically as `TARGETOS`/`TARGETARCH`). Only the tiny runtime stage is per-platform. This pattern works for any language with a real cross-compiler — Go, Rust, Zig — and is the single biggest lever on multi-arch build time.

**A36.** The default `mode=min` exports **only the layers of the final image** — enough to skip re-exporting on a rebuild, but useless for the intermediate steps of multi-stage builds, which is where the expensive work lives. `mode=max` exports **cache for every intermediate step in every stage**, including the discarded build stages. On a CI runner that starts from an empty cache each time, `mode=max` is what actually makes `go mod download` and `pip install` hit. The cost is registry storage and push/pull time: the cache image can easily be several times the size of the runtime image (it contains the whole toolchain layer set). Mitigate with a separate `-cache` repository, a shorter retention policy on it, and `--cache-to type=registry,...,compression=zstd`.

### Exercise 9

**A37.** The Docker socket is an **unauthenticated root-equivalent API**. Any process that can write to it can issue:

```bash
docker run -v /:/host --privileged --pid=host -it alpine chroot /host sh
```

which mounts the host root filesystem read-write inside a privileged container and gives an interactive root shell on the host. From there: read every other job's secrets and the CI runner's registry credentials, install a persistent backdoor, pivot into the cluster with the node's kubelet credentials. Note the attacker does not need a malicious `Dockerfile` — a compromised transitive dependency executing during `RUN`, or any code with access to the mounted socket in the job container, suffices. **"Access to the Docker socket" and "root on the host" are the same privilege.** This is precisely why rootless BuildKit, Buildah and Kaniko exist.

**A38.** It printed the **user-namespace UID mapping** for the rootless container environment:
```
         0       1000          1     ← in-namespace UID 0  → host UID 1000 (you), range 1
         1     100000      65536     ← in-namespace UIDs 1..65536 → host UIDs 100000..165535
```
The kernel's user namespaces let an unprivileged user create a namespace in which they hold `CAP_SYS_ADMIN` and other capabilities *scoped to that namespace only*. Your real UID (1000) is mapped to UID 0 inside it, so a process there sees itself as root and can `chown`, `mknod` in the namespace, and mount filesystems — but every operation against the host is still enforced against UID 1000 or against the subordinate range. The additional UIDs come from `/etc/subuid` and `/etc/subgid` (`shadow-utils`' `newuidmap`/`newgidmap` set the mapping). This is what makes `podman build` as a normal user produce images whose files are owned by "root" without any host privilege — and why an image escape from a rootless container lands you as an unprivileged host user rather than as root.

**A39.** **Better with Buildah:** building an image whose contents are produced by tooling that already exists outside the container — for example, assembling an image from RPMs resolved by the host's `dnf`, from a Nix or Bazel output directory, or from an artefact your existing build system already produced. There is no `Dockerfile` gymnastics to shoehorn a pre-built tree into layers; `buildah from scratch` + `buildah copy`/`buildah add` + `buildah config` + `buildah commit` composes it directly, with full shell control over ordering, retries, conditionals and per-layer decisions. It also composes naturally with `buildah mount`, letting you manipulate the rootfs with ordinary host tools.

**What you lose:** the `Dockerfile` as a **declarative, portable, universally readable contract**. A shell script is not analysable by `hadolint`, not buildable by any other tool, not renderable by a registry UI, and its behaviour depends on the host's shell and installed utilities. You also lose the frontend's automatic build cache — you have to invent your own idempotency. In practice most teams use `buildah bud` with a Dockerfile and reserve the scripted API for the cases above.

**A40.** (1) **Arguments are visible everywhere.** `args:` in a Pod spec is stored in etcd in plaintext, echoed by `kubectl describe pod`, `kubectl get pod -o yaml`, every audit log entry, and every CI log that prints the manifest — plus they appear in `/proc/<pid>/cmdline`, readable by any process in the container. A `Secret` mounted as a file is at least restricted by RBAC on the Secret object, is not printed by `describe`, and can be encrypted at rest via `EncryptionConfiguration`. (2) **It is the interface the tools expect**: both BuildKit and Kaniko read a standard `~/.docker/config.json`, so the same Secret works for `imagePullSecrets`, for `docker login`, and for credential helpers — no bespoke flag plumbing, and rotation is a Secret update rather than a manifest change across every pipeline. A third reason worth stating: a mounted Secret can be swapped for a short-lived, workload-identity-derived token (IRSA, Workload Identity Federation), which an inline argument cannot.

### Exercise 10

**A41.**

| # | Defect | When it bites |
|---|---|---|
| 1 | `RUN pip install -r requirements.txt` **before** any `COPY` brings the file in | **Build failure** — `No such file or directory` |
| 2 | `USER appuser` set before `WORKDIR`/`COPY`, so `WORKDIR /opt/app` is created **root-owned** and the unprivileged `COPY` cannot write into it | **Build failure** — `permission denied` |
| 3 | `ENV FLASK_SECRET=hunter2` bakes a credential into the image config, readable by `docker image inspect` from anyone who can pull | **Runtime / security** — the image is a published secret |
| 4 | `VOLUME /opt/app/data` followed by a `RUN` writing into it: the write is **discarded** (see A43) | **Runtime** — `seed.txt` is silently missing |
| 5 | `ENTRYPOINT python server.py` in **shell form**: PID 1 is `/bin/sh`, `SIGTERM` is not forwarded, `CMD` and run-args are ignored | **Runtime** — 10 s (or full grace period) shutdowns, exit 137 |

Bonus, not counted but production-relevant: `FROM python:3.12` is the ~1 GB full Debian image where `python:3.12-slim` (~120 MB) suffices; there is no `HEALTHCHECK`; `pip` runs without `--no-cache-dir`; nothing is version-pinned; `USER` is a name rather than a numeric UID (A26).

**A42.** `COPY` is executed by the **builder process**, but the file it writes lands in the layer with an ownership and into a directory whose permissions were established by earlier instructions. Two things combine here:
- `WORKDIR /opt/app` **creates the directory if it does not exist, always owned by `root:root` with mode `0755`** — the active `USER` does not change that.
- `COPY` defaults the *copied file's* ownership to `0:0` (root), but BuildKit performs the write in the context of the current `USER`. With `USER appuser` active and the destination `root:root 0755`, the write into a non-writable directory fails.

`COPY --chown=appuser:appuser` sets the resulting file's ownership, which addresses the *file*; the durable fix is to **create the directory with the right ownership before switching user** — `install -d -o appuser -g appuser /opt/app` — and to place `USER` as late as possible, immediately before `ENTRYPOINT`. That is what the repaired Dockerfile does: install dependencies as root, then drop privileges once, at the end. It also means the application cannot rewrite its own code at runtime, which is a security property worth having.

**A43.** `seed.txt` **does not exist in the image.** After a `VOLUME` declaration, any change made by a *subsequent* instruction to that path is made inside a temporary mount that is discarded when the instruction completes — the build system explicitly does not commit writes to declared volume paths. The build reports success, `docker image history` shows the `RUN`, and the file is simply absent at runtime. The fix is ordering: write the data first, declare `VOLUME` afterwards — or, better, do not declare it at all.

The subtler second problem: `VOLUME` in an image means **every `docker run` creates a new anonymous volume**. Those volumes are never garbage-collected with the container unless you pass `--rm` or `docker volume prune` them, so a service restarted a few thousand times accumulates thousands of orphaned volumes and eventually fills the disk. It also makes the container's data path non-obvious and breaks `--read-only` reasoning. Under Kubernetes, `VOLUME` in the image is at best ignored and at worst confusing — storage belongs in the Pod spec (`emptyDir`, `PersistentVolumeClaim`), declared by the operator, not baked into the artefact by the image author. **Do not use `VOLUME` in application images.**

**A44.** **They are right about Kubernetes, and it is still worth keeping.**

`HEALTHCHECK` is a **Docker/Moby extension**, not part of the OCI image specification. Under Kubernetes the CRI runtime (containerd, CRI-O) **does not evaluate it at all** — no probe is executed, `.State.Health` never exists, and nothing in the cluster reacts to it. Kubernetes uses `livenessProbe`, `readinessProbe` and `startupProbe` in the Pod spec, which are strictly more expressive (separate failure semantics: readiness removes the endpoint, liveness restarts the container, startup suppresses the other two during a slow boot) and are the operator's decision, not the image author's.

Keep it anyway because: it is the only health contract that works under plain `docker run`, `docker compose` (`depends_on: condition: service_healthy`), Podman, and Swarm — which is where developers run the image locally and where integration tests run in CI. And it **documents the health endpoint** for whoever writes the Pod spec. Cost is one line and a periodic in-container process, so the trade is easy. Just do not rely on it in the cluster: write real probes.

```yaml
readinessProbe:
  httpGet: { path: /healthz, port: 8080 }
  periodSeconds: 5
  failureThreshold: 3
livenessProbe:
  httpGet: { path: /healthz, port: 8080 }
  periodSeconds: 20
  failureThreshold: 3
startupProbe:
  httpGet: { path: /healthz, port: 8080 }
  periodSeconds: 5
  failureThreshold: 30
```

</details>