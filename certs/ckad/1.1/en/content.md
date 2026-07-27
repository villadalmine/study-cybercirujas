# 1.1 Define, Build and Modify Container Images

## Overview

A container image is an immutable, layered filesystem bundled with metadata (entrypoint, environment variables, exposed ports, user) that a container runtime uses to start a container. For CKAD, you need to be comfortable writing a `Dockerfile`, building an image from it, understanding how layers and caching work, modifying an existing image, and producing lean, secure images that Kubernetes will later pull and run as Pods.

Container images follow the **OCI (Open Container Initiative) Image Format Specification**, which is why images built with different tools (Docker, Podman, Buildah, `nerdctl`) are interoperable and can all be pushed to the same registries.

---

## 1. Anatomy of a Dockerfile

A `Dockerfile` is a text file of instructions, each producing a new **layer** on top of the previous one.

```dockerfile
# Dockerfile
FROM python:3.12-slim AS base

# Metadata
LABEL maintainer="team@example.com"

# Build-time only variable
ARG APP_VERSION=1.0.0

# Runtime environment variable
ENV APP_HOME=/app \
    APP_VERSION=${APP_VERSION}

WORKDIR ${APP_HOME}

# Copy dependency manifest first for better layer caching
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application source
COPY . .

# Document the port the app listens on (does not publish it)
EXPOSE 8080

# Drop root privileges
RUN useradd -u 1000 appuser
USER 1000

ENTRYPOINT ["python", "app.py"]
CMD ["--port", "8080"]
```

### Key instructions

| Instruction | Purpose |
|---|---|
| `FROM` | Base image; every Dockerfile must start with one (or `scratch`) |
| `RUN` | Executes a command and commits the result as a new layer (build time) |
| `COPY` | Copies files from build context into the image |
| `ADD` | Like `COPY`, but also auto-extracts local tar archives and can fetch remote URLs — prefer `COPY` unless you need those features |
| `WORKDIR` | Sets the working directory for subsequent instructions |
| `ENV` | Sets a persistent environment variable available at runtime |
| `ARG` | Build-time-only variable, passed via `--build-arg`, not present in the final container's environment |
| `EXPOSE` | Documentation only — informs which port the app uses; does **not** publish the port |
| `USER` | Sets the UID/user that subsequent `RUN`/`CMD`/`ENTRYPOINT` run as |
| `LABEL` | Key/value metadata attached to the image |
| `CMD` | Default arguments/command; overridden entirely by `docker run <image> <args>` or a Pod's `args`/`command` |
| `ENTRYPOINT` | Fixed executable for the container; `CMD` supplies default arguments to it |

### `CMD` vs `ENTRYPOINT`

- `ENTRYPOINT ["python", "app.py"]` + `CMD ["--port", "8080"]` → container runs `python app.py --port 8080`.
- Kubernetes maps `command:` to `ENTRYPOINT` and `args:` to `CMD`. If you only set `args:` in a Pod spec, it replaces `CMD` but keeps `ENTRYPOINT`.

---

## 2. Building an Image

```bash
docker build -t registry.example.com/myapp:1.0.0 .
```

```
[+] Building 8.2s (11/11) FINISHED
 => [internal] load build definition from Dockerfile           0.0s
 => [internal] load .dockerignore                               0.0s
 => [1/6] FROM docker.io/library/python:3.12-slim               1.1s
 => [2/6] WORKDIR /app                                          0.1s
 => [3/6] COPY requirements.txt .                                0.0s
 => [4/6] RUN pip install --no-cache-dir -r requirements.txt    5.4s
 => [5/6] COPY . .                                               0.1s
 => [6/6] RUN useradd -u 1000 appuser                            0.3s
 => exporting to image                                          0.4s
 => => naming to registry.example.com/myapp:1.0.0
```

- `-t` tags the image `name:tag`. Untagged images default to `latest`.
- `.` is the **build context** — everything under that path is sent to the build daemon, so keep it small with a `.dockerignore`.
- Each instruction that changes the filesystem or metadata is cached as a **layer**; if an instruction and everything before it is unchanged, Docker reuses the cached layer (`CACHED` in build output), which is why `COPY requirements.txt` is placed before `COPY . .` — dependency installation is only re-run when dependencies actually change.

### `.dockerignore`

```
.git
__pycache__/
*.pyc
node_modules/
.env
```

Excludes files from the build context (smaller context = faster builds, and avoids leaking secrets or dev files into the image).

---

## 3. Multi-stage Builds

Multi-stage builds keep build-time tooling (compilers, SDKs) out of the final runtime image, producing smaller and more secure images.

```dockerfile
# --- Build stage ---
FROM golang:1.22 AS builder
WORKDIR /src
COPY . .
RUN CGO_ENABLED=0 go build -o /out/server .

# --- Final stage ---
FROM gcr.io/distroless/static-debian12
COPY --from=builder /out/server /server
USER 1000
ENTRYPOINT ["/server"]
```

Only the compiled binary is copied (`COPY --from=builder`) into the final `distroless` image — no Go toolchain, no shell, minimal attack surface. This pattern is a very common CKAD exam scenario and design-best-practice question.

---

## 4. Modifying an Existing Image

### a) Rebuild from an edited Dockerfile (preferred)

Change the Dockerfile, then rebuild — this is the reproducible, GitOps-friendly approach.

### b) Commit changes from a running container (ad hoc)

```bash
docker run -it --name temp-ctr busybox sh
# ... make changes inside the container ...
docker commit temp-ctr myimage:patched
```

This produces a working image but isn't reproducible or auditable — avoid it for anything beyond quick debugging.

### c) Tagging and re-tagging

```bash
docker tag myapp:1.0.0 registry.example.com/team/myapp:1.0.0
docker tag myapp:1.0.0 registry.example.com/team/myapp:latest
```

### d) Pushing/pulling to a registry

```bash
docker login registry.example.com
docker push registry.example.com/team/myapp:1.0.0
docker pull registry.example.com/team/myapp:1.0.0
```

Kubernetes Pods reference images by this same `repository:tag` (or `repository@sha256:digest` for immutability):

```yaml
spec:
  containers:
  - name: myapp
    image: registry.example.com/team/myapp:1.0.0
    imagePullPolicy: IfNotPresent
```

Pinning by digest (`image: myapp@sha256:...`) guarantees the exact same image is pulled everywhere, unlike a mutable tag like `latest`.

---

## 5. Inspecting Images

```bash
docker image ls
docker inspect registry.example.com/team/myapp:1.0.0
docker history registry.example.com/team/myapp:1.0.0
```

```
IMAGE          CREATED BY                                      SIZE
a1b2c3d4e5f6   USER 1000                                        0B
f6e5d4c3b2a1   RUN useradd -u 1000 appuser                      3.2MB
...
```

`docker history` shows each layer and the instruction that produced it — useful for spotting bloated layers (e.g., leftover cache files from `apt-get` when `--no-cache` / cleanup wasn't used).

---

## 6. Buildah / Podman (rootless alternative)

The exam environment may use Podman/Buildah instead of Docker; commands are largely drop-in compatible:

```bash
podman build -t myapp:1.0.0 .
podman push myapp:1.0.0 registry.example.com/team/myapp:1.0.0
buildah bud -t myapp:1.0.0 .
```

Buildah can also build images without a Dockerfile, scripting layers directly — good to be aware of, but Dockerfile-based builds are what CKAD focuses on.

---

## 7. Best Practices (frequently tested concepts)

- **Use minimal base images** (`-slim`, `-alpine`, `distroless`, or `scratch`) to reduce size and attack surface.
- **Order instructions from least to most frequently changing** to maximize layer cache reuse (dependencies before source code).
- **Combine `RUN` commands** with `&&` and clean up in the same layer to avoid leaving cache artifacts in intermediate layers:
  ```dockerfile
  RUN apt-get update && apt-get install -y curl && rm -rf /var/lib/apt/lists/*
  ```
- **Avoid running as root** — set `USER` explicitly; Kubernetes `securityContext.runAsNonRoot` can enforce this at deploy time.
- **Pin base image versions** (`python:3.12-slim`, not `python:latest`) for reproducible builds.
- **Use multi-stage builds** to strip build tools from the runtime image.
- **Don't bake secrets into images** — they persist in image layers even if removed in a later layer; use `ARG`/build secrets or inject at runtime via Kubernetes Secrets instead.

---

## Referencias

- CNCF CKAD Curriculum v1.35 — https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf
- Dockerfile reference — https://docs.docker.com/reference/dockerfile/
- Docker build command — https://docs.docker.com/reference/cli/docker/build/
- Multi-stage builds — https://docs.docker.com/build/building/multi-stage/
- Build cache — https://docs.docker.com/build/cache/
- OCI Image Format Specification — https://github.com/opencontainers/image-spec
- Podman documentation — https://docs.podman.io/en/latest/
- Buildah documentation — https://buildah.io/
- Kubernetes: Images — https://kubernetes.io/docs/concepts/containers/images/
- Kubernetes: Define a Command and Arguments for a Container — https://kubernetes.io/docs/tasks/inject-data-application/define-command-argument-container/