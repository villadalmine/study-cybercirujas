# 352.3 Docker — Guided Exercises

> **Exam context** — LPIC-3 305-300, Topic 352.3 (weight 15, the single heaviest objective of the certification). These exercises drive the official knowledge areas: Docker architecture, the CLI, image and container management, Dockerfiles, `docker compose`, networking, storage, and security, plus awareness of Podman/Buildah/skopeo.
> **Reference:** LPI Exam 305 Objectives — https://www.lpi.org/our-certifications/exam-305-objectives/ · Docker docs — https://docs.docker.com/
>
> **Lab prerequisites**
> - A Linux host (Debian/Ubuntu or Fedora/RHEL family) with Docker Engine ≥ 24.x and the Compose v2 plugin installed.
> - Root or a user in the `docker` group. Where a command needs privilege it is shown with `sudo`.
> - Outbound access to Docker Hub (`registry-1.docker.io`) for image pulls.
> - Confirm your baseline before starting:
> ```bash
> docker version --format '{{.Server.Version}}'
> docker compose version
> ```

---

## Exercise 1 — Map the Docker architecture end to end

**Goal:** see the client/daemon split and the `dockerd → containerd → runc` runtime stack that actually runs a container.

1. Query both halves of the client–server pair and note that the API is a REST API over a Unix socket:
   ```bash
   docker version
   ls -l /var/run/docker.sock
   ```
2. Inspect the process tree of the daemon and its runtime components. Start a long-lived container first so there is something to see:
   ```bash
   docker run -d --name arch-demo nginx:1.27-alpine
   ps -ef | grep -E 'dockerd|containerd|runc|shim' | grep -v grep
   ```
3. Look at the shim that owns your container. `containerd-shim-runc-v2` is the parent of the container's PID 1 and is what keeps the container alive if `dockerd` restarts:
   ```bash
   ps -ef | grep containerd-shim | grep -v grep
   pgrep -a nginx
   ```
4. Confirm the daemon is a systemd service and that it can be stopped independently of running containers:
   ```bash
   systemctl status docker.service --no-pager | head -n 5
   systemctl status docker.socket --no-pager | head -n 5
   ```
5. Ask the daemon about itself. `docker info` reports the storage driver, cgroup version, default runtime, and root directory:
   ```bash
   docker info --format 'Storage: {{.Driver}} | Runtime: {{.DefaultRuntime}} | Cgroup: {{.CgroupVersion}} | Root: {{.DockerRootDir}}'
   ```

Expected output of step 5 resembles:
```
Storage: overlay2 | Runtime: runc | Cgroup: v2 | Root: /var/lib/docker
```

> **Q1.1** — When you type `docker run`, which process actually creates the namespaces and cgroups for the container: `docker`, `dockerd`, `containerd`, or `runc`?
> **Q1.2** — You run `systemctl restart docker`. Your `arch-demo` container keeps running throughout. Which component makes that possible, and why is it deliberately *not* a child of `dockerd`?
> **Q1.3** — What is `docker.socket` for, and how does socket activation change when the daemon first starts?

---

## Exercise 2 — Configure the daemon through `/etc/docker/daemon.json`

**Goal:** change daemon-wide behaviour declaratively (the exam-relevant configuration file) and prove the change took effect.

1. Inspect the current logging driver and default address pool *before* changing anything:
   ```bash
   docker info --format 'Log driver: {{.LoggingDriver}}'
   ```
2. Create or edit the daemon configuration. If the file does not exist, create it:
   ```bash
   sudo install -d -m 0755 /etc/docker
   sudo tee /etc/docker/daemon.json >/dev/null <<'EOF'
   {
     "log-driver": "json-file",
     "log-opts": {
       "max-size": "10m",
       "max-file": "3"
     },
     "default-address-pools": [
       { "base": "172.30.0.0/16", "size": 24 }
     ],
     "live-restore": true
   }
   EOF
   ```
3. Validate the JSON is well-formed *before* reloading (a syntax error will refuse to start the daemon):
   ```bash
   sudo dockerd --validate --config-file /etc/docker/daemon.json
   ```
4. Apply it. `log-driver` and `default-address-pools` require a full restart; many options (like `live-restore`) can be picked up with a SIGHUP reload:
   ```bash
   sudo systemctl restart docker
   docker info --format 'Log driver: {{.LoggingDriver}}'
   ```
5. Prove the new address pool is used by a freshly created network:
   ```bash
   docker network create pooltest
   docker network inspect pooltest --format '{{(index .IPAM.Config 0).Subnet}}'
   ```

Expected: the subnet falls inside `172.30.0.0/16` with a `/24` mask, e.g. `172.30.1.0/24`.

> **Q2.1** — You add `"hosts": ["tcp://0.0.0.0:2375"]` to `daemon.json` and the daemon fails to start under systemd. Why, and what is the correct way to expose the daemon over TCP?
> **Q2.2** — What does `live-restore` change about the relationship between `dockerd` and running containers, and what is its main limitation?
> **Q2.3** — Which is authoritative when the same flag appears both in `daemon.json` and on the `dockerd` command line, and why do they refuse to coexist for the same key?

---

## Exercise 3 — Manage images: layers, history, tags, digests

**Goal:** understand images as stacks of read-only layers and manage them precisely.

1. Pull an image and read its layer/digest metadata:
   ```bash
   docker pull nginx:1.27-alpine
   docker images --digests nginx
   ```
2. Read the build history — each line is a layer, `<missing>` lines are layers imported from a base image without their own build metadata:
   ```bash
   docker history nginx:1.27-alpine
   ```
3. Inspect the layered filesystem and the config. Note `RootFS.Layers` (content-addressable diff IDs) vs the config's `Env`/`Cmd`:
   ```bash
   docker image inspect nginx:1.27-alpine --format '{{len .RootFS.Layers}} layers'
   docker image inspect nginx:1.27-alpine --format '{{json .Config.Cmd}}'
   ```
4. Retag the image into a local name and observe that no data is copied — both names point at the same image ID:
   ```bash
   docker tag nginx:1.27-alpine myteam/web:v1
   docker images --format '{{.Repository}}:{{.Tag}} => {{.ID}}' | grep -E 'nginx|myteam'
   ```
5. Pin by immutable digest instead of a mutable tag, then reclaim space with a filtered prune:
   ```bash
   docker inspect --format '{{index .RepoDigests 0}}' nginx:1.27-alpine
   docker image prune -a --filter "until=24h" --dry-run 2>/dev/null || docker image prune -a --filter "until=24h"
   ```

> **Q3.1** — Why can `docker tag` create ten names for one image instantly, while `docker pull` of a new tag may still download nothing? What underlying property of layers explains both?
> **Q3.2** — In `docker history` output, what does a `<missing>` value in the `IMAGE` column actually mean — is the layer gone?
> **Q3.3** — A colleague deploys `nginx:1.27-alpine` today and you deploy the "same" tag next month, yet you run different bits. How do you make the deployment reproducible, and what command gives you the value to pin?

---

## Exercise 4 — Build images with a Dockerfile (multi-stage + cache)

**Goal:** author a syntactically complete Dockerfile, exploit build-cache invalidation, and shrink the result with a multi-stage build.

1. Create a project directory and a small Go program to build:
   ```bash
   mkdir -p ~/lab/docker-build && cd ~/lab/docker-build
   cat > main.go <<'EOF'
   package main

   import (
       "fmt"
       "net/http"
   )

   func main() {
       http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
           fmt.Fprintln(w, "hello from a multi-stage build")
       })
       http.ListenAndServe(":8080", nil)
   }
   EOF
   ```
2. Write a **multi-stage** Dockerfile: a `builder` stage compiles a static binary, the final stage copies only that binary onto a minimal base:
   ```dockerfile
   # syntax=docker/dockerfile:1
   FROM golang:1.22-alpine AS builder
   WORKDIR /src
   COPY go.* ./
   RUN go mod download 2>/dev/null || true
   COPY . .
   RUN CGO_ENABLED=0 GOOS=linux go build -o /out/app ./...

   FROM gcr.io/distroless/static-debian12:nonroot
   COPY --from=builder /out/app /app
   EXPOSE 8080
   USER nonroot:nonroot
   ENTRYPOINT ["/app"]
   ```
3. Initialise the module and build, tagging the result:
   ```bash
   printf 'module example.com/app\n\ngo 1.22\n' > go.mod
   docker build -t multistage-demo:1 .
   ```
4. Compare final size against a naive single-stage build (the builder toolchain never ships):
   ```bash
   docker images multistage-demo:1 --format 'final image: {{.Size}}'
   docker images golang:1.22-alpine --format 'builder base: {{.Size}}'
   ```
5. Demonstrate cache invalidation. Touch the source, rebuild, and watch which steps say `CACHED`:
   ```bash
   docker build -t multistage-demo:2 . 2>&1 | grep -E 'CACHED|RUN go build'
   sed -i 's/hello from/HELLO from/' main.go
   docker build -t multistage-demo:3 . 2>&1 | grep -E 'CACHED|RUN go build'
   ```
6. Confirm the final image runs as a non-root user (the `USER nonroot` line matters for security):
   ```bash
   docker run --rm --entrypoint /bin/sh multistage-demo:3 -c 'id' 2>/dev/null || echo "distroless has no shell — that is the point"
   ```

> **Q4.1** — Why is `COPY go.* ./` placed on its own line *before* `COPY . .`? What does this ordering buy you across rebuilds?
> **Q4.2** — After you edit `main.go`, the `go build` layer re-runs but the `go mod download` layer stays `CACHED`. Explain the cache rule that produces this.
> **Q4.3** — Contrast `ENTRYPOINT ["/app"]` (exec form) with `ENTRYPOINT /app` (shell form). Which one lets the process receive `SIGTERM` as PID 1, and why does that matter for `docker stop`?
> **Q4.4** — The final stage is `distroless` with no shell. Name two operational trade-offs — one benefit, one cost.

---

## Exercise 5 — Container lifecycle, exec, logs, resource limits

**Goal:** drive a container through its full lifecycle and constrain it with cgroup limits.

1. Run a detached container with an explicit restart policy and resource caps:
   ```bash
   docker run -d --name lc-demo \
     --restart=on-failure:3 \
     --memory=128m --memory-swap=128m \
     --cpus=0.5 \
     --pids-limit=100 \
     nginx:1.27-alpine
   ```
2. Observe the lifecycle states and the enforced limits:
   ```bash
   docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.RunningFor}}'
   docker inspect lc-demo --format 'Mem: {{.HostConfig.Memory}} | CPUs: {{.HostConfig.NanoCpus}} | PIDs: {{.HostConfig.PidsLimit}}'
   ```
3. Enter the running container and read its cgroup view (cgroup v2 path shown):
   ```bash
   docker exec lc-demo cat /sys/fs/cgroup/memory.max
   docker exec lc-demo cat /sys/fs/cgroup/pids.max
   ```
4. Stream logs and confirm the daemon-side logging driver you set in Exercise 2 is in effect:
   ```bash
   docker logs --tail 5 --timestamps lc-demo
   docker inspect lc-demo --format '{{.HostConfig.LogConfig.Type}}'
   ```
5. Walk the pause/stop/start transitions and read the exit code:
   ```bash
   docker pause lc-demo && docker ps --filter name=lc-demo --format '{{.Status}}'
   docker unpause lc-demo
   docker stop lc-demo
   docker inspect lc-demo --format 'Exited: {{.State.ExitCode}} | OOMKilled: {{.State.OOMKilled}}'
   docker start lc-demo
   ```
6. Trigger the memory limit to see an OOM kill (allocate more than 128 MB):
   ```bash
   docker run --rm --memory=64m --memory-swap=64m python:3.12-alpine \
     python -c "x = bytearray(200*1024*1024)" ; echo "exit=$?"
   ```

Expected: the container is killed and the shell prints a non-zero exit (`137`, i.e. `128 + SIGKILL(9)`).

> **Q5.1** — Why must you set `--memory-swap` equal to `--memory` to truly cap memory? What happens if you omit `--memory-swap`?
> **Q5.2** — An exit code of `137` and `139` mean different things. Decode both.
> **Q5.3** — With `--restart=on-failure:3`, a container exits `0`. Does Docker restart it? What about exit `1`? State the rule.
> **Q5.4** — What is the difference between `docker stop` and `docker kill` in terms of the signal sent and the grace period?

---

## Exercise 6 — Networking: bridge, user-defined networks, DNS, publishing

**Goal:** understand the default bridge vs a user-defined bridge, embedded DNS, and port publishing.

1. List the default networks the daemon creates and inspect the default bridge:
   ```bash
   docker network ls
   docker network inspect bridge --format 'Subnet: {{(index .IPAM.Config 0).Subnet}} | Gateway: {{(index .IPAM.Config 0).Gateway}}'
   ip -brief addr show docker0
   ```
2. Create a **user-defined bridge** — this enables automatic container-name DNS, which the default bridge does *not* provide:
   ```bash
   docker network create --driver bridge appnet
   docker run -d --name db  --network appnet redis:7-alpine
   docker run -d --name api --network appnet nginx:1.27-alpine
   ```
3. Prove name-based service discovery works on the user-defined network:
   ```bash
   docker exec api getent hosts db
   docker exec api ping -c1 db
   ```
4. Show that the *default* bridge cannot resolve names (only legacy `--link` or IPs work there):
   ```bash
   docker run -d --name legacy1 nginx:1.27-alpine
   docker run -d --name legacy2 nginx:1.27-alpine
   docker exec legacy1 getent hosts legacy2 || echo "no DNS on default bridge — expected"
   ```
5. Publish a port and trace the NAT rule Docker installs:
   ```bash
   docker run -d --name pub -p 8081:80 nginx:1.27-alpine
   curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8081
   sudo iptables -t nat -L DOCKER -n | grep 8081 || sudo nft list chain ip nat DOCKER 2>/dev/null | grep 8081
   ```
6. Compare `--network host` (shares the host netns, no NAT, no isolation) and `--network none` (no connectivity):
   ```bash
   docker run --rm --network host nginx:1.27-alpine sh -c 'ip addr show | grep -c inet'
   docker run --rm --network none  alpine ip addr show
   ```

> **Q6.1** — Two containers on the *default* bridge; one needs to reach the other by name. Why does `ping db` fail, and what is the single cleanest fix?
> **Q6.2** — `-p 8081:80` — which number is the host port and which is the container port? What does `-p 127.0.0.1:8081:80` additionally restrict?
> **Q6.3** — With `--network host`, what does `-p 8081:80` do? Why is publishing meaningless in host networking mode?
> **Q6.4** — Which iptables table and chain does Docker use to implement published-port DNAT, and what is the risk of Docker's rules bypassing a host `ufw`/`firewalld` policy?

---

## Exercise 7 — Storage: named volumes vs bind mounts vs tmpfs

**Goal:** persist and share data correctly, and know when the daemon manages the lifecycle vs when you do.

1. Create a named volume and inspect where the daemon stores it:
   ```bash
   docker volume create pgdata
   docker volume inspect pgdata --format 'Driver: {{.Driver}} | Mountpoint: {{.Mountpoint}}'
   ```
2. Attach it and write data; then destroy the container and prove the data survives:
   ```bash
   docker run -d --name pg -e POSTGRES_PASSWORD=secret -v pgdata:/var/lib/postgresql/data postgres:16-alpine
   sleep 5
   docker exec pg psql -U postgres -c 'CREATE TABLE t(id int); INSERT INTO t VALUES (42);'
   docker rm -f pg
   docker run -d --name pg2 -e POSTGRES_PASSWORD=secret -v pgdata:/var/lib/postgresql/data postgres:16-alpine
   sleep 5
   docker exec pg2 psql -U postgres -c 'SELECT * FROM t;'
   ```
3. Compare with a **bind mount** — the host path is the source of truth and Docker never manages its lifecycle:
   ```bash
   mkdir -p ~/lab/site && echo '<h1>bind-mounted</h1>' > ~/lab/site/index.html
   docker run -d --name bindweb -p 8082:80 \
     --mount type=bind,source="$HOME/lab/site",target=/usr/share/nginx/html,readonly \
     nginx:1.27-alpine
   curl -s http://localhost:8082
   echo '<h1>changed on host</h1>' > ~/lab/site/index.html
   curl -s http://localhost:8082
   ```
4. Use `tmpfs` for sensitive or ephemeral data that must never touch disk:
   ```bash
   docker run --rm --tmpfs /scratch:rw,size=16m,noexec alpine \
     sh -c 'mount | grep scratch; dd if=/dev/zero of=/scratch/f bs=1M count=8 && echo written'
   ```
5. Clean up dangling volumes safely:
   ```bash
   docker rm -f pg2 bindweb
   docker volume ls --filter dangling=true
   docker volume prune -f
   ```

> **Q7.1** — Both survive a `docker rm`. What is the essential difference in *who owns the lifecycle* of a named volume vs a bind mount?
> **Q7.2** — Why is the `--mount type=bind,...` syntax generally preferred over `-v /host:/container` for bind mounts? Give one failure mode `-v` hides.
> **Q7.3** — You bind-mount an empty host directory over `/var/lib/mysql`, which the image pre-populated. What happens to the image's pre-seeded data, and why does this differ from a fresh *named volume*?
> **Q7.4** — When would you deliberately choose `tmpfs` over a volume?

---

## Exercise 8 — Docker Compose (multi-service stack)

**Goal:** declare a multi-container application, manage its lifecycle as a unit, and use dependency ordering with health checks.

1. Author a `compose.yaml` describing a web app, a Redis cache, and a network/volume:
   ```bash
   mkdir -p ~/lab/compose && cd ~/lab/compose
   cat > compose.yaml <<'EOF'
   name: labstack
   services:
     cache:
       image: redis:7-alpine
       healthcheck:
         test: ["CMD", "redis-cli", "ping"]
         interval: 2s
         timeout: 3s
         retries: 5
       networks: [backend]

     web:
       image: nginx:1.27-alpine
       ports:
         - "8083:80"
       depends_on:
         cache:
           condition: service_healthy
       volumes:
         - webcontent:/usr/share/nginx/html:ro
       networks: [backend]
       deploy:
         resources:
           limits:
             memory: 128M

   networks:
     backend:
       driver: bridge

   volumes:
     webcontent:
   EOF
   ```
2. Bring the stack up detached and read its status. Notice `web` waits for `cache` to be *healthy*, not merely started:
   ```bash
   docker compose up -d
   docker compose ps
   ```
3. Show the project-scoped naming and the auto-created network/volume (prefixed with the project `name:`):
   ```bash
   docker network ls | grep labstack
   docker volume ls | grep labstack
   docker compose config --services
   ```
4. Scale a stateless service horizontally and view aggregated logs:
   ```bash
   docker compose up -d --scale cache=1 web=2 2>&1 | tail -n 3 || echo "note: 'web' publishes a fixed host port, so it cannot scale >1 as written"
   docker compose logs --tail 3 cache
   ```
5. Tear the whole stack down, including named volumes:
   ```bash
   docker compose down --volumes --remove-orphans
   docker compose ls
   ```

> **Q8.1** — What does `depends_on: { cache: { condition: service_healthy } }` guarantee that a plain `depends_on: [cache]` does *not*?
> **Q8.2** — Why can the `web` service in this file not be scaled beyond one replica as written, and what change would make it scalable?
> **Q8.3** — How does Compose derive the names of the network `labstack_backend` and container `labstack-web-1`? What controls the prefix?
> **Q8.4** — What is the practical difference between `docker compose down`, `docker compose down --volumes`, and `docker compose stop`?

---

## Exercise 9 — Container security hardening

**Goal:** apply the defence-in-depth controls the objective calls out — capabilities, non-root user, read-only rootfs, no-new-privileges, seccomp — and verify each.

1. Show the default Linux capabilities a container gets, then drop them all and add back only what is needed:
   ```bash
   docker run --rm alpine sh -c 'apk add -q libcap; capsh --print' 2>/dev/null | grep Current || \
   docker run --rm alpine grep CapEff /proc/1/status
   docker run --rm --cap-drop=ALL --cap-add=NET_BIND_SERVICE alpine grep CapEff /proc/1/status
   ```
2. Run a hardened container: non-root user, read-only root filesystem, no privilege escalation, with a writable `tmpfs` for the one path that needs it:
   ```bash
   docker run -d --name hardened \
     --user 10001:10001 \
     --read-only \
     --tmpfs /tmp:rw,size=8m \
     --security-opt no-new-privileges=true \
     --cap-drop=ALL \
     nginx:1.27-alpine 2>&1 | tail -n1 || true
   ```
   (Stock `nginx` writes to several paths; expect it to fail — that is the lesson. Use an image designed for read-only rootfs, or add the needed `--tmpfs` paths.)
3. Verify the running security posture of a correctly hardened workload:
   ```bash
   docker run -d --name safe --user 10001:10001 --security-opt no-new-privileges=true --cap-drop=ALL alpine sleep 600
   docker exec safe id
   docker exec safe grep NoNewPrivs /proc/1/status
   docker inspect safe --format 'ReadOnly: {{.HostConfig.ReadonlyRootfs}} | Caps dropped: {{json .HostConfig.CapDrop}}'
   ```
4. Confirm the default seccomp profile is active and demonstrate it blocks a dangerous syscall. Compare against `--security-opt seccomp=unconfined`:
   ```bash
   docker run --rm alpine sh -c 'unshare --map-root-user --user echo ok' 2>&1 | head -n1 || echo "blocked by default seccomp/userns"
   docker run --rm --security-opt seccomp=unconfined alpine sh -c 'echo unconfined runs'
   ```
5. Contrast an unsafe container. **Never do this in production** — `--privileged` disables nearly every control at once:
   ```bash
   docker run --rm --privileged alpine grep CapEff /proc/1/status
   # Compare the CapEff bitmask against the --cap-drop=ALL run from step 1.
   ```

> **Q9.1** — `--privileged` vs `--cap-add=SYS_ADMIN` — why is the former far more dangerous than adding even a powerful single capability?
> **Q9.2** — What exactly does `--security-opt no-new-privileges=true` prevent, and which classic attack vector (a specific file permission bit) does it neutralise?
> **Q9.3** — A read-only root filesystem broke `nginx`. Explain the correct remediation without simply removing `--read-only`.
> **Q9.4** — What is *rootless* Docker, and which class of vulnerability (daemon compromise → host root) does it fundamentally mitigate that a hardened rootful container does not?

---

## Exercise 10 — Awareness: Podman, Buildah, skopeo

**Goal:** the objective lists these as awareness items. Contrast the daemonless model against Docker without necessarily having them installed.

1. Note the architectural claim to verify conceptually: Docker uses a long-running root daemon (`dockerd`); Podman is daemonless and forks `conmon` per container, running rootless by default.
2. If Podman is available, show the drop-in CLI compatibility and the daemonless process model:
   ```bash
   command -v podman && podman run --rm alpine echo "podman: no daemon required" || echo "podman not installed — awareness only"
   command -v podman && podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null
   ```
3. If Buildah is available, build without a daemon or a Dockerfile (imperative builds):
   ```bash
   command -v buildah && buildah --version || echo "buildah not installed — awareness only"
   ```
4. If skopeo is available, inspect and copy images between registries **without pulling them into a local runtime**:
   ```bash
   command -v skopeo && skopeo inspect docker://docker.io/library/nginx:1.27-alpine | head -n 12 || echo "skopeo not installed — awareness only"
   ```
5. Regardless of what is installed, know the division of labour: **Podman** runs containers, **Buildah** builds images, **skopeo** moves/inspects images.

> **Q10.1** — What single architectural difference between Podman and Docker most changes the security story, and how does it change who owns a container's processes?
> **Q10.2** — Match each tool to its job: run containers / build images / copy & inspect images across registries.
> **Q10.3** — Why can skopeo copy an image from Docker Hub to a private registry on a host that has no container runtime running at all?
> **Q10.4** — A team wants `docker`-compatible commands but no root daemon. Which tool, and what does `alias docker=podman` get them (and not get them)?

---

<details>
<summary><strong>Answers</strong></summary>

### Exercise 1
- **Q1.1** — `runc`. The chain is `docker` (CLI, talks REST to the daemon) → `dockerd` (accepts the API call, prepares config) → `containerd` (manages container lifecycle, image/snapshot) → `containerd-shim` (per-container supervisor) → **`runc`**, the OCI runtime that actually calls `clone()`/`unshare()` to create namespaces and writes the cgroup limits, then `execve()`s the entrypoint and exits. After exec, `runc` is gone; the shim remains.
- **Q1.2** — The **`containerd-shim-runc-v2`** process. Each running container has its own shim, and the shim — not `dockerd` — is the parent of the container's PID 1. Because the shim is reparented to `init`/systemd and is independent of the daemon, restarting or crashing `dockerd`/`containerd` does not kill running containers (this is what `live-restore` and the shim architecture provide). If the shim were a child of `dockerd`, killing the daemon would signal-cascade to every container.
- **Q1.3** — `docker.socket` is a systemd socket unit that owns `/var/run/docker.sock` and provides **socket activation**: systemd creates and listens on the socket, and starts `docker.service` on the first client connection. This means the socket exists (and clients can connect) even before/while the daemon is starting; the daemon inherits the already-open socket fd rather than creating it itself.

### Exercise 2
- **Q2.1** — Under systemd, the unit's `ExecStart` typically already passes `-H fd://` (socket activation). Specifying `hosts` in `daemon.json` *and* on the command line for the same key is a conflict and the daemon aborts with "unable to configure the Docker daemon with file … the following directives are specified both as a flag and in the configuration file: hosts". The correct fix is a **systemd drop-in** that overrides `ExecStart` (clearing the `-H fd://` and adding `-H fd:// -H tcp://…`), or remove `-H` from the unit and set `hosts` only in `daemon.json`. And exposing `2375` unencrypted is unauthenticated root — use TLS (`2376`) or an SSH context instead.
- **Q2.2** — `live-restore: true` lets containers keep running while the daemon is **down** (stopped or upgraded), by relying on the shim/containerd. Its main limitation: it only supports **daemon restarts**, not configuration changes that require reconfiguring running containers, and it is incompatible with swarm mode; also the *daemon* being down means no new API operations, health monitoring, or log collection until it returns.
- **Q2.3** — Neither is "authoritative" — Docker deliberately **refuses to start** if the same key is set both in `daemon.json` and as a command-line flag, because silent precedence would hide misconfiguration. You must choose exactly one place for each option.

### Exercise 3
- **Q3.1** — Images are **content-addressable stacks of read-only layers**, and a tag is just a named pointer to an image config (itself a digest). `docker tag` only writes a new pointer — no bytes move. `docker pull` of a new tag downloads only the layers whose digests you don't already have locally; if the new tag shares all layers with an image you already hold, nothing is transferred.
- **Q3.2** — The layer is **not** gone. `<missing>` means that layer was pulled as part of a base image and Docker doesn't have local build-history metadata (the intermediate image config) for it — only the parent image had that. The layer data is present and in use; just its historical build command/image-ID is unknown locally.
- **Q3.3** — Pin by **digest**, not tag: `nginx@sha256:…`. Tags are mutable pointers that can be re-pushed; a digest is the immutable content hash of the manifest. Get it with `docker inspect --format '{{index .RepoDigests 0}}' nginx:1.27-alpine` (or `docker images --digests`).

### Exercise 4
- **Q4.1** — To maximise **build-cache reuse**. Dependency manifests (`go.mod`/`go.sum`) change rarely; source changes often. Copying just the manifests and running `go mod download` on its own layer means that expensive dependency-fetch step stays cached across every rebuild where only source changed. Copying everything first would invalidate the download layer on any source edit.
- **Q4.2** — Cache invalidation is **sequential and content-based**: a layer is reused only if its instruction *and* the checksum of its inputs are unchanged *and* every preceding layer was also a cache hit. Editing `main.go` changes the input to the later `COPY . .`/`go build` steps, invalidating them, but the earlier `COPY go.* ./` + `go mod download` steps have unchanged inputs and unchanged predecessors, so they stay `CACHED`.
- **Q4.3** — **Exec form** `ENTRYPOINT ["/app"]` runs the binary directly as PID 1, so it receives `SIGTERM` from `docker stop`. **Shell form** `ENTRYPOINT /app` runs `/bin/sh -c "/app"`, making `sh` PID 1; the signal goes to `sh`, which typically does not forward it, so `docker stop` waits the full grace period and then `SIGKILL`s. Exec form is required for correct, prompt shutdown.
- **Q4.4** — Benefit: **minimal attack surface** — no shell, no package manager, tiny size, fewer CVEs. Cost: **no in-container debugging** — you can't `docker exec … sh`; you must debug via an ephemeral debug container / `docker debug` / copying tools in, and there's no libc-based tooling.

### Exercise 5
- **Q5.1** — `--memory` caps RAM, but by default `--memory-swap` is set to twice `--memory`, so the container can spill to swap and exceed the intended RAM budget. Setting `--memory-swap` **equal to** `--memory` disables swap for that container, making the RAM cap hard. Omitting it → up to 2× the limit becomes usable via swap.
- **Q5.2** — Exit `137` = `128 + 9` → the process was killed by **SIGKILL** (commonly an OOM kill or `docker kill`). Exit `139` = `128 + 11` → killed by **SIGSEGV** (segmentation fault). Check `.State.OOMKilled` to distinguish an OOM `137` from a manual kill.
- **Q5.3** — `on-failure` restarts only on a **non-zero** exit. Exit `0` → no restart. Exit `1` → restart, up to the `:3` maximum retry count, after which Docker gives up.
- **Q5.4** — `docker stop` sends **SIGTERM**, waits the grace period (default 10s, `-t` to change), then **SIGKILL** if still alive — a graceful stop. `docker kill` sends **SIGKILL** immediately (or the signal from `--signal`), with no grace period.

### Exercise 6
- **Q6.1** — The **default bridge** does not run Docker's embedded DNS server for container names (only for external resolution), so `db` doesn't resolve. Cleanest fix: put both containers on a **user-defined bridge network** (`docker network create` + `--network`), which enables automatic name-based DNS. (Legacy `--link` also works but is deprecated.)
- **Q6.2** — Format is `-p HOST:CONTAINER`, so `8081` is the host port and `80` the container port. `-p 127.0.0.1:8081:80` additionally **binds the published port only to the loopback interface**, so it's reachable from the host itself but not from other machines on the network.
- **Q6.3** — With `--network host` the container shares the host's network namespace directly, so its port 80 *is* the host's port 80. `-p` is **ignored** (Docker warns) because there is no separate namespace to NAT into — publishing only makes sense when the container has its own netns.
- **Q6.4** — Docker inserts DNAT rules in the **`nat` table, `DOCKER` chain** (jumped to from `PREROUTING`/`OUTPUT`), and FORWARD rules in the `filter` table. Because Docker manipulates iptables/nftables directly and its `DOCKER` chain is evaluated before typical `ufw` user rules, a published port can be reachable **even if the host firewall appears to block it** — a well-known footgun; mitigate with `-p 127.0.0.1:…`, the userland-proxy/`iptables:false` options, or Docker-aware firewall integration.

### Exercise 7
- **Q7.1** — A **named volume's lifecycle is managed by the Docker daemon** (stored under `/var/lib/docker/volumes/…`, listed by `docker volume ls`, removable by `docker volume rm`). A **bind mount is just a host path**; Docker mounts it but never owns it — `docker volume` commands don't see it and removing the container never touches the host directory.
- **Q7.2** — `--mount` is explicit and **fails loudly** on error. With `-v /host:/container`, if the host path doesn't exist Docker silently **creates it as a root-owned directory** (and `-v name:/path` vs `-v /abs/path:/path` changes meaning based on whether the source looks like a path) — subtle bugs `--mount` prevents by requiring `type=` and named parameters.
- **Q7.3** — A **bind mount** overlays the host directory onto `/var/lib/mysql`, **hiding the image's pre-seeded files** (they're shadowed, and if the host dir is empty the DB sees an empty datadir). A fresh **named volume** is different: when a container first mounts an *empty* named volume onto a populated image path, Docker **copies the image's existing contents into the volume**. Bind mounts never do this copy-up.
- **Q7.4** — Choose `tmpfs` when data must be **fast and ephemeral and never persist to disk** — secrets/tokens, scratch space, caches — especially to avoid writing sensitive material to the host filesystem or to a read-only-rootfs container's writable path.

### Exercise 8
- **Q8.1** — Plain `depends_on: [cache]` only guarantees **start ordering** — `web` starts after `cache`'s container is created/started, but `cache` may not yet be ready to serve. `condition: service_healthy` makes `web` wait until `cache`'s **healthcheck reports healthy**, guaranteeing actual readiness.
- **Q8.2** — `web` publishes a **fixed host port** (`8083:80`). Scaling to N replicas would make N containers all try to bind host port 8083 — a collision. Make it scalable by publishing a **range or ephemeral host port** (e.g. `- "80"` or `"8083-8085:80"`) and/or putting a load balancer/reverse proxy in front.
- **Q8.3** — Compose derives names from the **project name** (here set explicitly by `name: labstack`; otherwise defaulting to the directory name). Network = `<project>_<network>` → `labstack_backend`; container = `<project>-<service>-<index>` → `labstack-web-1`. `-p/--project-name` or `COMPOSE_PROJECT_NAME` overrides the prefix.
- **Q8.4** — `docker compose stop` stops containers but keeps them, their networks, and volumes (fast resume). `docker compose down` stops **and removes** containers and the default network, but **keeps named volumes**. `docker compose down --volumes` additionally **removes the named volumes** declared in the file — permanent data loss.

### Exercise 9
- **Q9.1** — `--privileged` does far more than grant all capabilities: it also **disables seccomp, disables AppArmor/SELinux confinement, and exposes all host devices** (`/dev`) with full access — effectively removing the isolation boundary, so the container can reconfigure the host, load kernel modules, and access raw disks. `--cap-add=SYS_ADMIN` grants one (very powerful) capability but leaves seccomp, LSM, and device cgroup restrictions in place.
- **Q9.2** — It sets the kernel `no_new_privs` bit on the process, preventing the container's processes from **gaining more privileges than they start with** via `execve`. Concretely it neutralises **setuid/setgid binaries** — a `setuid-root` binary inside the container can no longer elevate to root, blocking a classic privilege-escalation path.
- **Q9.3** — Keep `--read-only` and **grant writable space only where the app genuinely needs it** using `--tmpfs` (or a mounted volume) for those specific paths (for `nginx`: `/var/cache/nginx`, `/var/run`, `/tmp`, PID file). The correct posture is read-only root plus explicit, minimal writable mounts — not disabling the protection.
- **Q9.4** — **Rootless Docker** runs `dockerd` and containers as an **unprivileged user** using user namespaces, so the container's "root" maps to a non-root host UID. It fundamentally mitigates **daemon/container-breakout → host root**: even if the daemon or a container is compromised, the attacker holds only an unprivileged host user, not UID 0. A hardened *rootful* container still has a root-owned daemon whose compromise means host root.

### Exercise 10
- **Q10.1** — **Daemonless + rootless-by-default.** Docker centralises everything in a root-owned `dockerd`; Podman has no daemon — each container is a child of a per-container `conmon` under the invoking (typically non-root) user. So there's no single root daemon as a target, and containers are owned by the user who ran them (fork/exec model), not by a shared privileged service.
- **Q10.2** — **Podman** → run containers (and pods). **Buildah** → build images (Dockerfile or imperative, daemonless). **skopeo** → copy and inspect images across registries/storage.
- **Q10.3** — skopeo works directly with **registry APIs and image manifests/blobs**; it copies layers registry-to-registry (or to/from local OCI/dir storage) without unpacking them into a runtime, so no `dockerd`/`containerd` and no local container execution are required.
- **Q10.4** — **Podman.** `alias docker=podman` gives near-complete CLI compatibility (`run`, `build`, `ps`, `images`, `compose` via `podman-compose`/`podman compose`) with no root daemon. What it does *not* transparently give: identical daemon-socket semantics for tools that talk to `/var/run/docker.sock` (needs the Podman socket/`podman system service`), Swarm, and some Docker-specific plugins/behaviours.

</details>