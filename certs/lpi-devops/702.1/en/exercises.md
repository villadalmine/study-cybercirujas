# 702.1 Application Container Management — Guided Exercises

**Certification:** LPI DevOps Tools Engineer (Exam 701-100, v2.0.0)
**Objective weight:** 8.33
**Format:** every block is a sequence of commands you actually run, followed by verification questions. All answers are in the collapsible section at the end.

---

## Lab prerequisites

A Linux host with either Docker Engine ≥ 24 or Podman ≥ 4.x, `curl`, and about 3 GB of free disk. Every exercise is self-contained and ends with its own cleanup. Where Podman differs, the difference is called out — the exam treats the OCI toolchain, not one vendor.

```bash
mkdir -p ~/lab-702.1 && cd ~/lab-702.1
docker version --format '{{.Server.Version}}'   # or: podman version --format '{{.Version}}'
```

---

## Exercise 1 — The runtime stack underneath the CLI

A container is not a first-class kernel object. It is a process with namespaces, cgroups, a rootfs from a layered filesystem, and an LSM profile. Before managing containers you must know which implementation of each your host provides, because every limit you set later lands in one of them.

1. Print the daemon's structural facts:

```bash
docker info --format '{{.ServerVersion}} storage={{.Driver}} cgroup=v{{.CgroupVersion}} driver={{.CgroupDriver}} runtime={{.DefaultRuntime}}'
```

```
27.3.1 storage=overlay2 cgroup=v2 driver=systemd runtime=runc
```

2. Look at the process tree the daemon builds for a running container:

```bash
docker run -d --name probe alpine:3.20 sleep 600
ps -ef --forest | grep -A2 -E 'containerd-shim|dockerd' | head -20
```

```
root  1180     1  0 09:11 ?  00:00:04 /usr/bin/dockerd -H fd://
root  2044     1  0 09:12 ?  00:00:00 /usr/bin/containerd-shim-runc-v2 -namespace moby -id 9f3c... -address /run/containerd/containerd.sock
root  2066  2044  0 09:12 ?  00:00:00  \_ sleep 600
```

3. Confirm the namespaces are real and per-container:

```bash
pid=$(docker inspect -f '{{.State.Pid}}' probe)
sudo ls -l /proc/$pid/ns/
sudo readlink /proc/$pid/ns/net /proc/self/ns/net
```

```
lrwxrwxrwx 1 root root 0 mnt -> 'mnt:[4026532584]'
lrwxrwxrwx 1 root root 0 net -> 'net:[4026532647]'
lrwxrwxrwx 1 root root 0 pid -> 'pid:[4026532586]'
lrwxrwxrwx 1 root root 0 uts -> 'uts:[4026532583]'
...
net:[4026532647]
net:[4026531840]
```

4. Find the container's cgroup and read a live limit from it:

```bash
cat /proc/$pid/cgroup
cat /sys/fs/cgroup/system.slice/docker-$(docker inspect -f '{{.Id}}' probe).scope/pids.current
```

```
0::/system.slice/docker-9f3c1b8e....scope
1
```

5. Clean up:

```bash
docker rm -f probe
```

> **Q1.1** `runc` does not appear in the `ps` output while the container runs. Why, and what does `containerd-shim-runc-v2` exist for?
> **Q1.2** The container's `net` namespace inode differs from the host's, but you did not create a network. What network did the container join, and what would `--network host` change in step 3?
> **Q1.3** Your host reports `cgroup=v1`. Which of the limits used later in this lab (`--cpus`, `--memory`, `--pids-limit`, `--memory-swap`) change behaviour, and where would you read them instead of `/sys/fs/cgroup/<scope>/`?

---

## Exercise 2 — Image anatomy: manifest, config, layers, digest

An "image" is three separate artifacts in the registry: a manifest, a config blob, and N layer blobs. Confusing the *image ID* (a hash of the local config) with the *repository digest* (a hash of the manifest as stored in the registry) is the single most common cause of "but I deployed the same tag" incidents.

1. Pull a small multi-layer image and list what you got:

```bash
docker pull nginx:1.27-alpine
docker image inspect nginx:1.27-alpine \
  --format 'ID={{.Id}}{{"\n"}}Digest={{index .RepoDigests 0}}{{"\n"}}Layers={{len .RootFS.Layers}}'
```

```
ID=sha256:1ae4bcd8b0a0f8f4a3a4dbd6ff3b3c1a70c0e2c4a1f1d0a5b3e9e2c1d4f6a7b8
Digest=nginx@sha256:41523187cf7d7a2f2677a80609d9caa14388bf5c1d2eaf7ab3eb0e5f8e0ef1b1
Layers=8
```

2. Show how each layer was produced, and which ones cost bytes:

```bash
docker history nginx:1.27-alpine --format 'table {{.Size}}\t{{.CreatedBy}}' | head -12
```

```
SIZE      CREATED BY
0B        CMD ["nginx" "-g" "daemon off;"]
0B        STOPSIGNAL SIGQUIT
0B        EXPOSE map[80/tcp:{}]
0B        ENTRYPOINT ["/docker-entrypoint.sh"]
1.62kB    COPY 30-tune-worker-processes.sh /docker-entrypoint.d/ # buildkit
...
44.7MB    RUN /bin/sh -c set -x  && apkArch="$(cat /etc/apk/arch)" ...
8.83MB    ADD alpine-minirootfs-3.20.3-x86_64.tar.gz / # buildkit
```

3. Read the raw manifest as the registry serves it (no daemon involved):

```bash
skopeo inspect --raw docker://docker.io/library/nginx:1.27-alpine | head -20
```

```json
{
  "schemaVersion": 2,
  "mediaType": "application/vnd.oci.image.index.v1+json",
  "manifests": [
    { "mediaType": "application/vnd.oci.image.manifest.v1+json",
      "digest": "sha256:0f2e0a4...", "size": 1741,
      "platform": { "architecture": "amd64", "os": "linux" } },
    { "mediaType": "application/vnd.oci.image.manifest.v1+json",
      "digest": "sha256:9c1b7d3...", "size": 1741,
      "platform": { "architecture": "arm64", "os": "linux", "variant": "v8" } }
  ]
}
```

4. Pin by digest and prove the pin is immutable:

```bash
docker pull nginx@sha256:41523187cf7d7a2f2677a80609d9caa14388bf5c1d2eaf7ab3eb0e5f8e0ef1b1
docker image ls --digests nginx
```

```
REPOSITORY  TAG          DIGEST                     IMAGE ID       SIZE
nginx       1.27-alpine  sha256:41523187cf7d...     1ae4bcd8b0a0   52.5MB
nginx       <none>       sha256:41523187cf7d...     1ae4bcd8b0a0   52.5MB
```

5. Inspect the deduplicated on-disk layers:

```bash
docker system df -v | head -6
```

> **Q2.1** Step 1 printed two different `sha256:` values. Which one identifies bytes that exist in the registry, and which one exists only on this host? Which would you write into a production manifest?
> **Q2.2** Step 3 returned an *index*, not a manifest. What does that object contain, and what would `docker pull` do with it on an arm64 host?
> **Q2.3** Several `docker history` rows show `0B`. Are they still layers? Explain in terms of manifest layers vs. config history entries.
> **Q2.4** You rebuild an image from the identical Dockerfile on two machines and get two different image IDs. Give two reasons this happens even with no source change.

---

## Exercise 3 — Building: cache order, multi-stage, and build-arg leakage

1. Create a deliberately badly ordered build:

```bash
mkdir -p build-lab && cd build-lab
cat > requirements.txt <<'EOF'
flask==3.0.3
EOF
cat > app.py <<'EOF'
from flask import Flask
app = Flask(__name__)

@app.get("/healthz")
def healthz():
    return {"status": "ok"}, 200

@app.get("/")
def index():
    return {"service": "demo", "version": "1"}, 200
EOF
cat > Dockerfile <<'EOF'
FROM python:3.12-slim
WORKDIR /app
COPY . /app
RUN pip install --no-cache-dir -r requirements.txt
CMD ["python", "-m", "flask", "run", "--host=0.0.0.0"]
EOF

docker build -t demo:bad .
```

2. Change only the application source and rebuild, timing it:

```bash
sed -i 's/"version": "1"/"version": "2"/' app.py
time docker build -t demo:bad .
```

```
 => [3/4] COPY . /app                                          0.1s
 => [4/4] RUN pip install --no-cache-dir -r requirements.txt   9.4s
real    0m11.7s
```

3. Reorder so dependencies are cached independently of source, and add a `.dockerignore`:

```bash
cat > Dockerfile <<'EOF'
FROM python:3.12-slim AS base
WORKDIR /app
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py ./
ENV FLASK_APP=app.py
EXPOSE 5000
CMD ["python", "-m", "flask", "run", "--host=0.0.0.0"]
EOF
printf '.git\n__pycache__\n*.pyc\n.env\n' > .dockerignore

docker build -t demo:good .
sed -i 's/"version": "2"/"version": "3"/' app.py
time docker build -t demo:good .
```

```
 => CACHED [base 3/4] RUN pip install --no-cache-dir -r requirements.txt   0.0s
 => [base 4/4] COPY app.py ./                                             0.1s
real    0m1.3s
```

4. Now leak a secret the way real pipelines do, and find it:

```bash
cat > Dockerfile.leak <<'EOF'
FROM alpine:3.20
ARG API_TOKEN
RUN echo "fetching with $API_TOKEN" > /tmp/build.log
EOF
docker build -f Dockerfile.leak --build-arg API_TOKEN=s3cr3t-prod-token -t demo:leak .
docker history --no-trunc demo:leak | grep -o 's3cr3t[^ "]*'
```

```
s3cr3t-prod-token
```

5. Do it correctly with a BuildKit secret mount, and verify the leak is gone:

```bash
echo -n 's3cr3t-prod-token' > token.txt
cat > Dockerfile.safe <<'EOF'
# syntax=docker/dockerfile:1
FROM alpine:3.20
RUN --mount=type=secret,id=api_token \
    wc -c < /run/secrets/api_token > /tmp/token.len
EOF
DOCKER_BUILDKIT=1 docker build -f Dockerfile.safe --secret id=api_token,src=token.txt -t demo:safe .
docker history --no-trunc demo:safe | grep -c 's3cr3t' ; docker run --rm demo:safe cat /tmp/token.len
```

```
0
17
```

6. Build a multi-stage image and compare sizes:

```bash
cat > Dockerfile.multi <<'EOF'
FROM golang:1.23-alpine AS build
WORKDIR /src
RUN cat > main.go <<'GO'
package main
import ("fmt"; "net/http")
func main() {
  http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) { fmt.Fprintln(w, "ok") })
  http.ListenAndServe(":8080", nil)
}
GO
RUN go mod init demo && CGO_ENABLED=0 go build -o /out/server main.go

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/server /server
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/server"]
EOF
docker build -f Dockerfile.multi -t demo:multi .
docker image ls --format 'table {{.Repository}}:{{.Tag}}\t{{.Size}}' | grep -E 'demo|golang'
```

```
demo:multi        6.31MB
golang:1.23-alpine 249MB
```

> **Q3.1** In step 2, `COPY . /app` invalidated the cache. Precisely *what* does BuildKit hash to decide that a `COPY` instruction is a cache hit?
> **Q3.2** Why did adding `.dockerignore` matter for cache correctness and not only for build context size? Name a file that would otherwise cause a cache miss on every developer's machine.
> **Q3.3** The secret in step 4 was never `COPY`ed into the image and the file lives in `/tmp`. Explain the two independent ways it is still recoverable by anyone who pulls `demo:leak`.
> **Q3.4** `demo:multi` has no shell and no package manager. State one concrete operational cost of that and the diagnostic technique from Exercise 10 that removes it.
> **Q3.5** `docker build --target build -t demo:builder .` — what would that produce, and give a legitimate CI use for it.

---

## Exercise 4 — PID 1, signals, and clean shutdown

Containers stop by signal. If PID 1 in your container does not handle `SIGTERM`, every deployment becomes a 10-second hard kill and every in-flight request is dropped.

1. Write a service that handles termination properly:

```bash
cd ~/lab-702.1 && mkdir -p signals && cd signals
cat > app.sh <<'EOF'
#!/bin/sh
term() { echo "SIGTERM received: draining"; sleep 1; echo "drained"; exit 0; }
trap term TERM
echo "started as pid $$"
while :; do sleep 1 & wait $!; done
EOF
chmod +x app.sh
```

2. Build the **shell form** variant:

```bash
cat > Dockerfile.shell <<'EOF'
FROM alpine:3.20
COPY app.sh /app.sh
ENTRYPOINT /app.sh
EOF
docker build -f Dockerfile.shell -t sig:shell .
docker run -d --name s-shell sig:shell
docker exec s-shell ps -o pid,args
```

```
PID   COMMAND
    1 /bin/sh -c /app.sh
    7 /bin/sh /app.sh
   14 sleep 1
```

3. Time the stop and read the exit code:

```bash
time docker stop s-shell ; docker inspect -f '{{.State.ExitCode}}' s-shell ; docker logs s-shell
```

```
real    0m10.4s
137
started as pid 7
```

4. Build the **exec form** variant and repeat:

```bash
cat > Dockerfile.exec <<'EOF'
FROM alpine:3.20
COPY app.sh /app.sh
STOPSIGNAL SIGTERM
ENTRYPOINT ["/app.sh"]
EOF
docker build -f Dockerfile.exec -t sig:exec .
docker run -d --name s-exec sig:exec
docker exec s-exec ps -o pid,args | head -3
time docker stop s-exec ; docker inspect -f '{{.State.ExitCode}}' s-exec ; docker logs s-exec
```

```
PID   COMMAND
    1 /bin/sh /app.sh
    7 sleep 1

real    0m1.3s
0
started as pid 1
SIGTERM received: draining
drained
```

5. Show zombie reaping, the other PID 1 duty:

```bash
docker run --rm alpine:3.20 sh -c 'sleep 0.1 & sleep 0.5; ps -o pid,stat,args'
docker run --rm --init alpine:3.20 sh -c 'sleep 0.1 & sleep 0.5; ps -o pid,stat,args'
```

```
PID   STAT COMMAND
    1 S    sh -c sleep 0.1 & sleep 0.5; ps ...
    7 Z    [sleep]
...
PID   STAT COMMAND
    1 S    /sbin/docker-init -- sh -c ...
    7 S    sh -c ...
```

6. Extend the grace period the way a slow-draining service needs:

```bash
docker run -d --name s-slow --stop-timeout 30 sig:exec
docker stop s-slow ; docker rm -f s-shell s-exec s-slow
```

> **Q4.1** In step 2, PID 1 was `/bin/sh -c /app.sh` and the script ran as PID 7. Two independent mechanisms then prevented a clean shutdown — name both.
> **Q4.2** Exit code 137 and exit code 143 both mean "killed". Decompose each number and say which one indicates that your handler worked.
> **Q4.3** `nginx` ships `STOPSIGNAL SIGQUIT`. Why would a `SIGTERM` be the wrong default for it, and where is `STOPSIGNAL` recorded so the runtime can read it?
> **Q4.4** A container with a shell-form `ENTRYPOINT` that spawns background workers leaks zombies. `--init` fixes the reaping, but not the signal forwarding to those workers. Why not, and what is the correct fix inside the image?

---

## Exercise 5 — Networking: bridges, embedded DNS, and published ports

1. Prove that the default bridge has no service discovery:

```bash
docker run -d --name db  alpine:3.20 sleep 600
docker run -d --name web alpine:3.20 sleep 600
docker exec web getent hosts db ; echo "exit=$?"
```

```
exit=2
```

2. Create a user-defined network and repeat:

```bash
docker network create --driver bridge --subnet 172.28.0.0/24 appnet
docker rm -f db web
docker run -d --name db  --network appnet alpine:3.20 sleep 600
docker run -d --name web --network appnet --network-alias frontend alpine:3.20 sleep 600
docker exec web getent hosts db
docker exec web cat /etc/resolv.conf
```

```
172.28.0.2        db
nameserver 127.0.0.11
options ndots:0
```

3. Inspect the address plan from the daemon's side:

```bash
docker network inspect appnet -f '{{range $k,$v := .Containers}}{{$v.Name}} {{$v.IPv4Address}}{{"\n"}}{{end}}'
```

```
db 172.28.0.2/24
web 172.28.0.3/24
```

4. Publish a port and see what the kernel actually did:

```bash
docker run -d --name site -p 127.0.0.1:8080:80 nginx:1.27-alpine
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080/
sudo iptables -t nat -S DOCKER | grep 8080
ss -lntp | grep 8080
```

```
200
-A DOCKER ! -i docker0 -p tcp -m tcp --dport 8080 -j DNAT --to-destination 172.17.0.3:80
LISTEN 0 4096 127.0.0.1:8080 0.0.0.0:* users:(("docker-proxy",pid=5120,fd=4))
```

5. Contrast with host networking:

```bash
docker run -d --name hostnet --network host nginx:1.27-alpine
docker exec hostnet ip -o addr show | wc -l   # host interfaces, not 2
docker run -d --name hostnet2 --network host nginx:1.27-alpine ; docker logs hostnet2 | tail -2
```

```
bind() to 0.0.0.0:80 failed (98: Address in use)
```

6. Clean up:

```bash
docker rm -f db web site hostnet hostnet2 ; docker network rm appnet
```

> **Q5.1** Step 1 failed and step 2 succeeded with no image change. What component appears at `127.0.0.11` on a user-defined network, and why is it a link-local address inside the container's netns instead of a real server?
> **Q5.2** You publish `-p 8080:80` on a host with a `ufw`/`firewalld` rule denying 8080 from outside, and the port is reachable anyway. Explain the chain-ordering reason and name the iptables chain intended for your rules.
> **Q5.3** `--network host` removed the network namespace. Which of these still isolate the container: mount ns, PID ns, cgroup limits, port bindings? Answer each.
> **Q5.4** A container needs to reach a service on the host itself. Give the portable approach on Docker Desktop/Podman and the Linux-native alternative.
> **Q5.5** What is the difference between `--network-alias frontend` and `--name frontend` for resolution, and when do you need the alias?

---

## Exercise 6 — Storage: bind mounts, named volumes, copy-up, tmpfs

1. Watch a named volume perform *copy-up* from the image:

```bash
docker volume create sitedata
docker run -d --name v1 -v sitedata:/usr/share/nginx/html -p 8081:80 nginx:1.27-alpine
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8081/
docker run --rm -v sitedata:/data alpine:3.20 ls /data
```

```
200
50x.html
index.html
```

2. Do the same with a bind mount and observe the opposite behaviour:

```bash
mkdir -p ~/lab-702.1/html-empty
docker run -d --name v2 -v ~/lab-702.1/html-empty:/usr/share/nginx/html -p 8082:80 nginx:1.27-alpine
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8082/
```

```
403
```

3. Locate a named volume on the host and confirm it survives the container:

```bash
docker volume inspect sitedata -f '{{.Mountpoint}}'
docker rm -f v1
sudo ls $(docker volume inspect sitedata -f '{{.Mountpoint}}')
```

```
/var/lib/docker/volumes/sitedata/_data
50x.html  index.html
```

4. Run with an immutable root filesystem — the production default:

```bash
docker run -d --name ro \
  --read-only \
  --tmpfs /tmp:rw,noexec,nosuid,size=64m \
  --tmpfs /var/cache/nginx --tmpfs /var/run \
  -v sitedata:/usr/share/nginx/html:ro \
  -p 8083:80 nginx:1.27-alpine
docker exec ro sh -c 'touch /etc/canary' ; echo "exit=$?"
docker exec ro sh -c 'touch /tmp/canary && mount | grep " /tmp "'
```

```
touch: /etc/canary: Read-only file system
exit=1
tmpfs on /tmp type tmpfs (rw,nosuid,nodev,noexec,relatime,size=65536k,...)
```

5. On an SELinux host (Fedora/RHEL), see the relabel requirement:

```bash
mkdir -p ~/lab-702.1/selinux-demo && echo hello > ~/lab-702.1/selinux-demo/f.txt
docker run --rm -v ~/lab-702.1/selinux-demo:/d alpine:3.20 cat /d/f.txt   # may fail: Permission denied
ls -Z ~/lab-702.1/selinux-demo/f.txt
docker run --rm -v ~/lab-702.1/selinux-demo:/d:Z alpine:3.20 cat /d/f.txt
ls -Z ~/lab-702.1/selinux-demo/f.txt
```

```
unconfined_u:object_r:user_home_t:s0    f.txt
hello
system_u:object_r:container_file_t:s0:c214,c806    f.txt
```

6. Clean up:

```bash
docker rm -f v2 ro ; docker volume rm sitedata
```

> **Q6.1** State the rule that explains both step 1 (content appeared) and step 2 (content vanished), including the exact precondition for copy-up.
> **Q6.2** Step 3 shows the volume outliving the container. Which `docker rm` flag deletes anonymous volumes, and why does it not delete `sitedata`?
> **Q6.3** In step 4 you had to add three `--tmpfs` mounts. What is the systematic way to discover which paths an unfamiliar image writes to before you set `--read-only`?
> **Q6.4** Explain the difference between `:z` and `:Z` and describe the concrete failure caused by using `:Z` on `/home/user/src` shared with a second container.
> **Q6.5** A bind-mounted directory shows files owned by `nobody` inside the container. Give the cause under rootless Podman and the flag that fixes it.

---

## Exercise 7 — Resource limits and OOM behaviour

1. Verify the limits land in cgroup v2 files:

```bash
docker run --rm -m 64m --cpus 0.5 --pids-limit 16 alpine:3.20 sh -c \
  'cat /sys/fs/cgroup/memory.max /sys/fs/cgroup/cpu.max /sys/fs/cgroup/pids.max'
```

```
67108864
50000 100000
16
```

2. Trigger a real OOM kill and read the forensic evidence:

```bash
docker run --name oom -m 64m --memory-swap 64m --shm-size 128m alpine:3.20 \
  sh -c 'dd if=/dev/zero of=/dev/shm/balloon bs=1M count=128'
echo "exit=$?"
docker inspect oom -f 'OOMKilled={{.State.OOMKilled}} ExitCode={{.State.ExitCode}} Status={{.State.Status}}'
sudo dmesg | tail -3
```

```
Killed
exit=137
OOMKilled=true ExitCode=137 Status=exited
[ 8123.4] Memory cgroup out of memory: Killed process 20441 (dd) total-vm:...,anon-rss:...
```

3. Hit the PID limit:

```bash
docker run --rm --pids-limit 16 alpine:3.20 sh -c \
  'i=0; while [ $i -lt 50 ]; do sleep 30 & i=$((i+1)); done; echo spawned=$i'
```

```
sh: can't fork: Resource temporarily unavailable
```

4. Measure the CPU quota rather than trusting it:

```bash
docker run --rm --cpus 0.5 alpine:3.20 sh -c \
  'time (i=0; while [ $i -lt 300000 ]; do i=$((i+1)); done)'
docker run --rm --cpus 2 alpine:3.20 sh -c \
  'time (i=0; while [ $i -lt 300000 ]; do i=$((i+1)); done)'
```

5. Observe live consumption and per-container processes:

```bash
docker run -d --name busy --cpus 0.25 alpine:3.20 sh -c 'while :; do :; done'
docker stats --no-stream busy
docker top busy
docker rm -f busy oom
```

```
CONTAINER  CPU %   MEM USAGE / LIMIT   MEM %   PIDS
busy       24.93%  512KiB / 15.35GiB   0.00%   1
```

> **Q7.1** `--cpus 0.5` produced `50000 100000` in `cpu.max`. Read those two numbers aloud in kernel terms, and say what happens to a thread that exhausts the quota mid-period.
> **Q7.2** Why did the exercise pass `--memory-swap 64m` explicitly? What is the default when only `-m` is given, and how would omitting it make the OOM test non-deterministic?
> **Q7.3** `--cpus` and `--cpu-shares` are both CPU controls. Which is a hard ceiling, which is a weight, and which one has *no effect* on an idle host?
> **Q7.4** `docker stats` reported `MEM USAGE 512KiB / 15.35GiB` for a container with `--cpus 0.25` and no memory limit. Why is the limit column the host total, and what risk does that create on a shared node?
> **Q7.5** Your application is a JVM in a `-m 512m` container and it is OOM-killed despite `-Xmx256m`. Give two plausible causes rooted in what the memory cgroup actually counts.

---

## Exercise 8 — Security posture: user, capabilities, privileges

1. See what a default container is granted:

```bash
docker run --rm alpine:3.20 sh -c 'id; grep CapEff /proc/self/status'
docker run --rm alpine:3.20 sh -c 'apk add -q libcap-ng 2>/dev/null; capsh --decode=$(grep CapEff /proc/self/status | cut -f2)' 2>/dev/null \
  || docker run --rm alpine:3.20 sh -c 'grep Cap /proc/self/status'
```

```
uid=0(root) gid=0(root) groups=0(root),1(bin),...
CapEff:	00000000a80425fb
```

2. Drop everything and add back only what is needed:

```bash
docker run --rm --cap-drop ALL alpine:3.20 sh -c 'ping -c1 -W1 127.0.0.1 >/dev/null 2>&1; echo ping=$?'
docker run --rm --cap-drop ALL --cap-add NET_RAW alpine:3.20 sh -c 'ping -c1 -W1 127.0.0.1 >/dev/null 2>&1; echo ping=$?'
```

```
ping=1
ping=0
```

3. Run as a non-root UID that does not exist in `/etc/passwd`:

```bash
docker run --rm -u 10001:10001 alpine:3.20 sh -c 'id; touch /root/x 2>&1 | head -1'
```

```
uid=10001 gid=10001
touch: /root/x: Permission denied
```

4. Bake the non-root user into the image — the only version that survives someone forgetting the flag:

```bash
cd ~/lab-702.1 && mkdir -p sec && cd sec
cat > Dockerfile <<'EOF'
FROM alpine:3.20
RUN addgroup -g 10001 app && adduser -D -u 10001 -G app app \
 && mkdir -p /var/lib/app && chown app:app /var/lib/app
USER 10001:10001
WORKDIR /var/lib/app
ENTRYPOINT ["/bin/sh","-c","id; sleep 300"]
EOF
docker build -t sec:nonroot .
docker run -d --name s1 --cap-drop ALL --security-opt no-new-privileges \
  --read-only --tmpfs /tmp sec:nonroot
docker logs s1
```

```
uid=10001(app) gid=10001(app) groups=10001(app)
```

5. Demonstrate `no-new-privileges` against a setuid binary:

```bash
docker run --rm -u 10001 alpine:3.20 sh -c 'ls -l /bin/busybox; su -c id 2>&1 | head -1'
docker run --rm -u 10001 --security-opt no-new-privileges alpine:3.20 sh -c 'su -c id 2>&1 | head -1'
```

6. Show what `--privileged` actually removes (run once, then never in production):

```bash
docker run --rm alpine:3.20 sh -c 'ls /dev | wc -l; mount -t tmpfs none /mnt 2>&1 | head -1'
docker run --rm --privileged alpine:3.20 sh -c 'ls /dev | wc -l; mount -t tmpfs none /mnt && echo MOUNTED; head -1 /dev/sda 2>&1 | head -c 40'
```

```
16
mount: permission denied (are you root?)
...
408
MOUNTED
```

7. Compare rootless Podman's identity mapping:

```bash
podman unshare cat /proc/self/uid_map
grep "^$(id -un):" /etc/subuid
podman run --rm alpine:3.20 id
podman run --rm --userns=keep-id alpine:3.20 id
```

```
         0       1000          1
         1     100000      65536
dalmine:100000:65536
uid=0(root) gid=0(root)
uid=1000 gid=1000
```

8. Clean up: `docker rm -f s1`

> **Q8.1** Step 1 showed `uid=0` inside the container. Is that the host's root? Answer separately for rootful Docker and rootless Podman, referencing the uid_map from step 7.
> **Q8.2** `--cap-drop ALL` broke `ping` but the process was still uid 0. Explain the relationship between capabilities and the root uid on a modern kernel.
> **Q8.3** Your app must bind port 80. Give three ways to make that work without granting full root, and rank them by blast radius.
> **Q8.4** What exactly does `--security-opt no-new-privileges` set, and why is it the cheapest single hardening flag when combined with a non-root `USER`?
> **Q8.5** `-u 10001` at runtime and `USER 10001` in the Dockerfile both produce uid 10001. Give two reasons the Dockerfile version is stronger, and one thing it still does not guarantee.
> **Q8.6** A vendor's docs say "run with `--privileged`". Enumerate what that flag turns off and describe how you would replace it with a minimal set of flags.

---

## Exercise 9 — Health checks, restart policies, logging, and Compose

1. Build an image with a health check and observe the state machine:

```bash
cd ~/lab-702.1 && mkdir -p compose && cd compose
cat > Dockerfile.web <<'EOF'
FROM nginx:1.27-alpine
HEALTHCHECK --interval=5s --timeout=3s --start-period=5s --retries=3 \
  CMD wget -q -O /dev/null http://127.0.0.1/ || exit 1
EOF
docker build -f Dockerfile.web -t hc:web .
docker run -d --name hc hc:web
for i in 1 2 3 4; do docker inspect -f '{{.State.Health.Status}}' hc; sleep 4; done
```

```
starting
starting
healthy
healthy
```

2. Break it and read the recorded probe output:

```bash
docker exec hc nginx -s stop ; sleep 20
docker inspect -f '{{.State.Health.Status}} failing={{.State.Health.FailingStreak}}' hc
docker inspect -f '{{(index .State.Health.Log 0).Output}}' hc
docker ps -a --filter name=hc --format '{{.Status}}'
```

```
unhealthy failing=4
Exited (1)
```

3. Test restart policies:

```bash
docker run -d --name flap --restart on-failure:3 alpine:3.20 sh -c 'sleep 2; exit 1'
sleep 25
docker inspect -f 'restarts={{.RestartCount}} status={{.State.Status}} exit={{.State.ExitCode}}' flap
```

```
restarts=3 status=exited exit=1
```

4. Bound the logs before they fill the disk:

```bash
docker run -d --name loud \
  --log-driver json-file --log-opt max-size=1m --log-opt max-file=3 \
  alpine:3.20 sh -c 'i=0; while :; do echo "line $i $(head -c 200 /dev/zero | tr "\0" "x")"; i=$((i+1)); done'
sleep 10
sudo ls -lh /var/lib/docker/containers/$(docker inspect -f '{{.Id}}' loud)/ | grep json.log
docker logs --tail 2 --timestamps loud
docker rm -f loud flap hc
```

```
-rw-r----- 1 root root 1.0M ... 9f3c...-json.log
-rw-r----- 1 root root 1.0M ... 9f3c...-json.log.1
-rw-r----- 1 root root 1.0M ... 9f3c...-json.log.2
2026-09-03T09:41:22.118Z line 84213 xxxxxxxx...
```

5. Compose the whole thing, with ordering that depends on health rather than on start:

```bash
cat > compose.yaml <<'EOF'
name: lab702
services:
  cache:
    image: redis:7-alpine
    command: ["redis-server","--save","","--appendonly","no"]
    healthcheck:
      test: ["CMD","redis-cli","ping"]
      interval: 5s
      timeout: 3s
      retries: 5
    networks: [back]
    read_only: true
    tmpfs: [/tmp]

  web:
    build:
      context: .
      dockerfile: Dockerfile.web
    depends_on:
      cache:
        condition: service_healthy
    ports: ["127.0.0.1:8090:80"]
    networks: [back]
    deploy:
      resources:
        limits:
          cpus: "0.50"
          memory: 128M
    logging:
      driver: json-file
      options: { max-size: "1m", max-file: "3" }
    restart: unless-stopped
networks:
  back: {}
EOF

docker compose config --quiet && echo "schema OK"
docker compose up -d --wait
docker compose ps
```

```
schema OK
NAME             SERVICE  STATUS                   PORTS
lab702-cache-1   cache    Up 22 seconds (healthy)
lab702-web-1     web      Up 12 seconds (healthy)  127.0.0.1:8090->80/tcp
```

6. Verify the limits Compose applied and the name-based discovery:

```bash
docker inspect lab702-web-1 -f 'mem={{.HostConfig.Memory}} cpuquota={{.HostConfig.NanoCpus}}'
docker compose exec web getent hosts cache
docker compose logs --tail 3 cache
docker compose down -v
```

```
mem=134217728 cpuquota=500000000
172.29.0.2        cache lab702-cache-1
```

> **Q9.1** In step 2 the container was `unhealthy` but `docker ps` still showed it `Up`. What does Docker Engine do about an unhealthy container by itself, and which two systems *do* act on that status?
> **Q9.2** `restart: unless-stopped` vs `restart: always` — describe the one scenario, involving a daemon restart, where they behave differently.
> **Q9.3** `--restart on-failure:3` stopped after 3 attempts. What is the interval between attempts, and why is that policy dangerous with a `HEALTHCHECK` that has no `--start-period`?
> **Q9.4** You switch to `--log-driver journald`. What breaks about the step-4 verification, and which log drivers keep `docker logs` working?
> **Q9.5** Explain why `depends_on: condition: service_healthy` is still insufficient as an application-level guarantee, and what the application must implement regardless.
> **Q9.6** The Compose file used `deploy.resources.limits`. Under `docker compose up` (not Swarm), is that honoured? Justify from the `docker inspect` output in step 6.

---

## Exercise 10 — Diagnosing a container you cannot shell into

The distroless image from Exercise 3 has no shell. This is the technique that makes that acceptable.

1. Start the shell-less service and confirm the obvious approach fails:

```bash
cd ~/lab-702.1/build-lab
docker run -d --name svc -p 8091:8080 demo:multi
curl -s http://127.0.0.1:8091/ ; docker exec -it svc sh
```

```
ok
OCI runtime exec failed: exec failed: unable to start container process: exec: "sh": executable file not found in $PATH
```

2. Attach a fully equipped container to the *same namespaces*:

```bash
docker run -it --rm \
  --network container:svc \
  --pid container:svc \
  --cap-add SYS_PTRACE \
  nicolaka/netshoot \
  sh -c 'ps -ef; ss -lntp; wget -qO- http://127.0.0.1:8080/'
```

```
PID   USER     COMMAND
    1 65532    /server
   16 root     sh -c ps -ef; ss -lntp; ...
State  Recv-Q Send-Q Local Address:Port  Process
LISTEN 0      4096        *:8080         users:(("server",pid=1,fd=3))
ok
```

3. Reach the target's filesystem from the host, without a shell in the image:

```bash
pid=$(docker inspect -f '{{.State.Pid}}' svc)
sudo ls /proc/$pid/root/
sudo cat /proc/$pid/environ | tr '\0' '\n' | head -3
sudo nsenter -t $pid -n ss -lntp
```

```
etc  server  var
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
HOSTNAME=4b8c2d1e9a77
```

4. Diff the running rootfs against the image — the audit question "what changed in production?":

```bash
docker diff svc | head
docker inspect svc -f '{{json .State}}' | python3 -m json.tool | head -12
```

5. Watch the daemon's event stream while something fails:

```bash
docker events --since 5m --filter container=svc --format '{{.Time}} {{.Action}}' &
docker kill --signal SIGKILL svc ; sleep 1 ; kill %1
docker inspect svc -f 'exit={{.State.ExitCode}} oom={{.State.OOMKilled}} err={{.State.Error}}'
```

```
1756890123 kill
1756890123 die
exit=137 oom=false err=
```

6. Export the exact bytes for offline forensics:

```bash
docker commit svc svc:postmortem
docker export svc -o svc-rootfs.tar ; tar -tf svc-rootfs.tar | head -5
docker rm -f svc ; docker rmi svc:postmortem ; rm -f svc-rootfs.tar
```

> **Q10.1** Step 2 shared `--network` and `--pid` but not the mount namespace. Which diagnostics does that enable, and which does it *not*?
> **Q10.2** `/proc/$pid/root/` showed the container's filesystem from the host. What kernel feature makes that path resolve into another mount namespace, and what is the one prerequisite for it to work?
> **Q10.3** `docker export` and `docker save` both produce a tar. State the difference in content and which one preserves layers and image metadata.
> **Q10.4** `docker inspect` reported `exit=137 oom=false`. Two different causes produce 137 — distinguish them using exactly these fields.
> **Q10.5** In Kubernetes the equivalent of step 2 is a single command. Name it and say what it shares with the target container by default.

---

## Cleanup

```bash
docker rm -f $(docker ps -aq --filter label=lab=702.1) 2>/dev/null
docker compose -f ~/lab-702.1/compose/compose.yaml down -v 2>/dev/null
docker image rm demo:bad demo:good demo:leak demo:safe demo:multi sig:shell sig:exec sec:nonroot hc:web 2>/dev/null
docker system prune -f
docker system df
```

---

<details>
<summary><strong>Answers</strong></summary>

### Exercise 1

**A1.1** `runc` is not a daemon; it is a one-shot binary. It sets up namespaces, cgroups, seccomp/LSM labels and the rootfs, `exec()`s the container's entrypoint, then exits. Nothing of `runc` remains in the process tree. The shim (`containerd-shim-runc-v2`) is what stays: it becomes the parent of PID 1, holds the container's stdio/TTY, reports the exit status, and — critically — allows `containerd` and `dockerd` to be restarted or upgraded without killing running containers, because the containers' parents are shims, not the daemon.

**A1.2** The container joined the default bridge network (`docker0` / `bridge`), which is why it got its own `net` namespace with a veth pair into that bridge. With `--network host` the container's `net` namespace symlink would be *identical* to the host's — same inode number — because no new network namespace is created.

**A1.3** All four still work, but they are written into a different hierarchy. Under cgroup v1 the controllers are separate mounts: memory at `/sys/fs/cgroup/memory/docker/<id>/memory.limit_in_bytes` and `memory.memsw.limit_in_bytes`, CPU at `/sys/fs/cgroup/cpu/docker/<id>/cpu.cfs_quota_us` + `cpu.cfs_period_us`, pids at `/sys/fs/cgroup/pids/docker/<id>/pids.max`. Behavioural differences: v1 `memsw` counts memory+swap together (so `--memory-swap` semantics differ), and v1 has no unified `memory.high` pressure mechanism, no proper per-cgroup PSI, and rootless containers cannot get resource limits at all without cgroup v2 + systemd delegation.

### Exercise 2

**A2.1** `Digest` (the `RepoDigests` entry) is the content address of the *manifest* as served by the registry — the same bytes everywhere, and the only value that survives a tag being moved. `Id` is the local digest of the *image config blob*, computed by this daemon; it is not what you pull by. Production manifests pin `image@sha256:<manifest-digest>`.

**A2.2** It is an image index (manifest list): a list of per-platform manifests plus their `platform` fields. `docker pull` on arm64 reads the index, selects the entry with `architecture: arm64`, and pulls only that manifest and its layers. The tag therefore resolves to different bytes on different hosts — one more reason a tag is not an identity.

**A2.3** No. Those rows are *history entries* in the image config, recording metadata-only instructions (`CMD`, `ENV`, `EXPOSE`, `LABEL`, `ENTRYPOINT`, `WORKDIR`) that change the config JSON and produce no filesystem diff. `len .RootFS.Layers` (8) counts real layers; `docker history` printed more rows than that. Only instructions that write to the filesystem (`RUN`, `COPY`, `ADD`) create layers.

**A2.4** (1) Timestamps: without `SOURCE_DATE_EPOCH` / reproducible-build flags, `created` fields and file mtimes differ, changing the config hash. (2) Non-pinned inputs: `FROM python:3.12-slim` or `apt-get install`/`pip install` without lockfiles resolves to different upstream bytes at different times. Also file ordering/permissions from the build context, and different BuildKit versions emitting different metadata.

### Exercise 3

**A3.1** For `COPY`/`ADD`, BuildKit hashes the *content* of the matched files in the build context — a checksum over each file's contents plus its path, mode, uid/gid — not the mtime. The cache key is that checksum combined with the parent stage's cache key and the literal instruction string. A `COPY . /app` therefore takes any change anywhere in the context as a miss.

**A3.2** Because the checksum covers everything in the context, unignored volatile paths cause spurious misses and can silently ship secrets. `.git/` is the classic: it changes on every commit, fetch, or even `git status` (index mtime/refs), so every developer and every CI run gets a cache miss on `COPY . .`. `__pycache__/`, `node_modules/`, `.venv/`, and `.env` are the others — and `.env` is also a secret leak.

**A3.3** (1) The value is embedded in the image *config history* as the literal command string of the `RUN` layer — `docker history --no-trunc` or `docker inspect` prints it, and anyone who pulls the image can read it without running it. (2) The `RUN` created a layer containing `/tmp/build.log` with the token inside; even if a later `RUN rm` deleted it, the earlier layer blob still exists in the image and can be extracted with `docker save`/`skopeo copy` + `tar`. Deleting a file in a later layer only adds a whiteout entry; it does not remove the bytes.

**A3.4** Cost: no `sh`, `ps`, `curl`, `nslookup`, or package manager, so `docker exec` for triage is impossible — you cannot inspect the process table or test connectivity from inside. The fix from Exercise 10 is to attach a debug container to the target's namespaces (`--network container:<name> --pid container:<name>`, or `kubectl debug --target`), which brings its own toolchain while observing the target's network and process view.

**A3.5** It builds only up to the `build` stage and tags that intermediate image — the full Go toolchain with sources and compiled artifacts. Legitimate uses: running unit tests and linters in CI against the exact build environment, extracting coverage or SBOM artifacts, and warming a shared build cache (`--cache-from`) so subsequent pipeline stages skip recompilation.

### Exercise 4

**A4.1** (1) `/bin/sh -c` did not `exec` the script — it forked it as a child — so the shell was PID 1, and `docker stop` delivers `SIGTERM` **only to PID 1**, never to the tree. The script never saw the signal. (2) Even reaching PID 1, that shell had no `TERM` trap, and the kernel *ignores* signals with default dispositions for PID 1 inside a PID namespace (the "init protection" rule): a process that has not installed a handler cannot be killed by `SIGTERM` as PID 1. After the 10-second grace period Docker sent `SIGKILL`, which is not maskable.

**A4.2** Both are `128 + signal`. `137 = 128 + 9` (`SIGKILL`) — the grace period expired and the runtime hard-killed it; nothing drained. `143 = 128 + 15` (`SIGTERM`) — the process died from TERM, which means it at least received it. In the working case the handler called `exit 0`, so the clean-shutdown signature is exit code **0**, not 143. Seeing 137 on every deploy is the fingerprint of a broken PID 1.

**A4.3** For nginx, `SIGTERM` means *fast shutdown*: workers abandon in-flight connections immediately. `SIGQUIT` is nginx's *graceful* shutdown: stop accepting new connections, finish the ones in progress, then exit. `STOPSIGNAL` is stored in the image config (`Config.StopSignal`), so `docker stop` reads it from the image and sends the right signal without anyone remembering `--signal`. Verify with `docker inspect -f '{{.Config.StopSignal}}'`.

**A4.4** `--init` inserts `tini`/`docker-init` as PID 1, which reaps orphans and forwards signals **to its direct child**. It does not forward to grandchildren, and it cannot know your application's process tree. A shell that spawns workers and does not itself propagate `TERM` still leaves them running. The correct fix inside the image is `ENTRYPOINT ["/app"]` in exec form so the real process is PID 1, or — if a wrapper script is genuinely required — end it with `exec "$@"` so the shell is replaced rather than kept, and use `trap` + `kill -TERM 0`/`kill -- -$$` only when a supervisor is unavoidable.

### Exercise 5

**A5.1** Docker's embedded DNS server. Every container on a user-defined network gets `nameserver 127.0.0.11` in `/etc/resolv.conf`; the daemon installs DNAT rules inside that container's network namespace redirecting 127.0.0.11:53 to a listener in the daemon, which answers for container names, network aliases and service names, and forwards everything else to the host's resolvers. It is link-local and per-namespace precisely so the same address means "my network's resolver" in every container without collisions. The legacy default bridge has no such resolver — only the deprecated `--link` mechanism, which writes `/etc/hosts` entries.

**A5.2** Docker inserts its NAT rules in the `nat` table's `PREROUTING`/`DOCKER` chains and its filter rules in `FORWARD` → `DOCKER`, which are evaluated *before* the `ufw`/`firewalld` user chains for forwarded traffic. Since published-port traffic is DNAT'ed and forwarded rather than delivered to the host's `INPUT` chain, host firewall rules written for `INPUT` never see it. The chain Docker leaves for you is **`DOCKER-USER`**, which is traversed before `DOCKER`; put your deny rules there. Alternatively publish to a loopback or specific host IP (`-p 127.0.0.1:8080:80`), as this lab does.

**A5.3** Mount ns: **still isolated** — the container keeps its own rootfs. PID ns: **still isolated** — `--network host` only shares the network namespace; use `--pid host` to share that. cgroup limits: **still applied** — resource control is orthogonal to namespaces. Port bindings: **not isolated** — the container binds directly on host interfaces, `-p` is meaningless and rejected/ignored, and two such containers collide on the same port, which is the error in step 5.

**A5.4** Portable: the special DNS name `host.docker.internal` (Docker Desktop; on Linux add `--add-host=host.docker.internal:host-gateway`) or, for Podman, `host.containers.internal`. Linux-native alternative: use the bridge gateway address (`172.17.0.1`, or the gateway from `docker network inspect`), or run with `--network host` so "the host" is just localhost.

**A5.5** `--name` gives one resolvable name tied to the container's identity, unique per daemon. `--network-alias` adds additional names *scoped to one network*, and several containers may share the same alias — the embedded DNS then returns all their addresses, giving round-robin client-side load balancing. You need aliases when multiple replicas must answer to one logical service name, or when the same container must be reachable under different names on different networks.

### Exercise 6

**A6.1** Copy-up applies to **named (and anonymous) volumes only**, and only when the volume is **empty** and the image's target directory is **non-empty**: the runtime seeds the volume with the image content, including ownership and permissions, at first use. Bind mounts never copy up — a bind mount is a plain mount that shadows whatever is under it, so an empty host directory shows as empty, and nginx returned 403 (autoindex off, no `index.html`).

**A6.2** `docker rm -v` (or `docker rm --volumes`) removes *anonymous* volumes attached to the container. `sitedata` was created explicitly with `docker volume create` and referenced by name, so it is a managed named volume with an independent lifecycle; only `docker volume rm sitedata` (or `docker compose down -v` for Compose-created ones) deletes it. This asymmetry is deliberate: named volumes are data you meant to keep.

**A6.3** Run it read-only and let it tell you: start with `--read-only` and read the failure messages/`docker logs`; or observe writes empirically — run the container normally, exercise it, then `docker diff <container>`, whose `A`/`C` lines list every added or changed path relative to the image. Those paths become your `tmpfs` or volume mounts. `strace -f -e trace=file` via a debug container attached with `--cap-add SYS_PTRACE` gives the same answer for stubborn cases.

**A6.4** `:z` relabels the host content with a **shared** SELinux category label (`container_file_t` with no unique MCS categories), so multiple containers may access it. `:Z` applies a **private** label with a unique MCS category pair bound to that one container. Using `:Z` on a shared source directory relabels those files to a category only the first container can read, so the second container gets `Permission denied` — and if the path is something like `/home/user/src` or, catastrophically, a system directory, the relabel also breaks host processes' access to it. Never use `:Z` on shared or system paths.

**A6.5** Under rootless Podman the container runs inside a user namespace: the host UID that owns the files (your 1000) is not mapped into the container's range, so it appears as the overflow UID `nobody` (65534). `--userns=keep-id` maps your host UID to the same UID inside the container, making ownership line up; `--userns=keep-id:uid=1000,gid=1000` pins it explicitly. `podman unshare chown` is the alternative when you want the files owned by a container-internal UID instead.

### Exercise 7

**A7.1** `cpu.max` is `<quota> <period>` in microseconds: 50,000 µs of CPU time per 100,000 µs period — half of one CPU, cumulative across all threads in the cgroup. A thread that exhausts the quota mid-period is **throttled**: the CFS bandwidth controller dequeues the whole cgroup until the next period boundary. This is a hard stall, not a slowdown, and it shows up as latency spikes (visible in `cpu.stat`'s `nr_throttled` / `throttled_usec`), which is why aggressive CPU limits on latency-sensitive services are a known production hazard.

**A7.2** Default: when only `-m 64m` is given, `--memory-swap` defaults to **twice** the memory limit (128m), i.e. 64 MB of swap is allowed. If the host has swap enabled, the shmem pages could be swapped out instead of triggering the OOM killer, so the test would sometimes pass and sometimes hang. Setting `--memory-swap` equal to `-m` disables swap for the cgroup and makes the OOM deterministic. (`--memory-swap=-1` means unlimited swap.)

**A7.3** `--cpus` (and `--cpu-quota`/`--cpu-period`) is a **hard ceiling** enforced by CFS bandwidth control — the cgroup is throttled even when the host is idle. `--cpu-shares` (cgroup v2: `cpu.weight`) is a **relative weight** used only when there is contention; on an idle host it has **no effect** and the container may use every core. Confusing the two is why "I set cpu-shares and it still ate the box" happens.

**A7.4** `docker stats` reports the *effective* limit, and with no `-m` the effective limit is the host's total RAM — the container's memory cgroup has `memory.max = max`. The risk: one unbounded container can consume all host memory, at which point the **global** OOM killer chooses a victim by badness score, and that victim may be an unrelated container, the container runtime, or `sshd`. A per-container limit converts a host-wide incident into a single-container restart.

**A7.5** (1) The JVM heap is not the JVM's whole footprint: metaspace, thread stacks (~1 MB each), code cache, GC structures, direct/mapped `ByteBuffer`s and JNI allocations are all anonymous memory counted by the cgroup and all outside `-Xmx`. (2) The memory cgroup also counts page cache and tmpfs/shmem attributed to the cgroup — a chatty log file or a `/dev/shm` allocation pushes the total over the limit even with a small heap. Secondary cause: an old JVM that read the *host's* RAM instead of the cgroup limit and sized its defaults accordingly (fixed by container-awareness / `-XX:MaxRAMPercentage`).

### Exercise 8

**A8.1** Rootful Docker: yes — uid 0 in the container **is** uid 0 on the host. The container is constrained by capabilities, seccomp, AppArmor/SELinux and namespaces, not by identity; a mount escape or a bind-mounted `/var/run/docker.sock` gives host root immediately. Rootless Podman: no — the uid_map shows container uid 0 mapped to your unprivileged host uid (1000), and uids 1..65536 mapped into the `/etc/subuid` range starting at 100000. Files it creates on a bind mount are owned by those host uids, and it has no privilege on the host beyond yours.

**A8.2** Since Linux 2.2, "root" is not a single privilege bit — it is the full capability set that the kernel grants to uid 0 by default. `ping` needs `CAP_NET_RAW` to open a raw/ICMP socket; dropping all capabilities leaves a uid-0 process with an empty effective set, so every privileged operation fails despite the uid. Practically: `--cap-drop ALL --cap-add <only what you need>` is far more meaningful than the uid, and the two controls compose (`USER` + `--cap-drop ALL` is the strong combination).

**A8.3** Ranked from smallest blast radius: (1) **Do not bind 80** — listen on 8080 and publish `-p 80:8080`; the NAT happens outside the container and the process never needs privilege. (2) **`sysctl net.ipv4.ip_unprivileged_port_start=0`** scoped to the container (`--sysctl`), letting an unprivileged uid bind low ports with no capability at all. (3) **`--cap-drop ALL --cap-add NET_BIND_SERVICE`** with a non-root `USER` — one narrow capability, but still a capability the process keeps for its whole life. Running as root to bind and dropping later is the worst option and is what the first three replace.

**A8.4** It sets the kernel's `PR_SET_NO_NEW_PRIVS` prctl on the container's processes, which makes `execve()` unable to grant additional privileges — setuid/setgid bits, file capabilities and privilege-raising LSM transitions are all ignored for that process and every descendant, permanently. It is cheap because it costs nothing at runtime and closes the standard escalation path out of a non-root container: finding a setuid binary in the image (`find / -perm -4000`) and using it to become uid 0.

**A8.5** Stronger because: (1) it is the image's default — no operator flag to forget, and it applies to every `docker run`, Compose service, and orchestrator that consumes the image; (2) the build can prepare the filesystem for that uid (`chown`, writable dirs, `/etc/passwd` entry), so the image actually *works* unprivileged, whereas `-u` on a root-designed image typically fails on permissions. What it does **not** guarantee: `USER` in the Dockerfile is overridable at runtime (`docker run -u 0`, or Kubernetes `securityContext.runAsUser`), so the enforcement must also exist at the platform layer (`runAsNonRoot: true`, Pod Security Admission, or a policy engine).

**A8.6** `--privileged` disables essentially the whole confinement layer: it grants **all** capabilities, mounts the full `/dev` (so host block devices are readable/writable), disables the seccomp filter, sets AppArmor/SELinux to unconfined, and makes `/sys` and `/proc` sysfs paths writable. It is host root with extra steps. To replace it, determine what the workload actually needs and grant only that: `--cap-add` the specific capabilities (`SYS_ADMIN`, `NET_ADMIN`, `SYS_TIME`…), `--device /dev/xxx` for specific devices, `--security-opt seccomp=custom.json` instead of `unconfined`, `--sysctl` for individual kernel knobs. Method: run privileged once under `strace`/audit or with `--security-opt seccomp=unconfined` and audit logging, collect the denials, and grant exactly those.

### Exercise 9

**A9.1** Docker Engine does **nothing** — it records the status and emits a `health_status: unhealthy` event, but it does not restart, stop, or stop routing to the container; a restart policy does not react to health either, only to process exit. The two systems that act on it: **Docker Swarm** (reschedules an unhealthy task) and **Kubernetes** (a failing `livenessProbe` restarts the container, a failing `readinessProbe` removes it from Service endpoints). On plain Docker you must wire the action yourself, e.g. a supervisor watching `docker events --filter event=health_status`.

**A9.2** They differ only after the **daemon (or host) restarts**. `always` starts the container again even if you had explicitly `docker stop`ped it before the restart. `unless-stopped` remembers that you stopped it deliberately and leaves it stopped. In every other respect — restarting on any non-zero *and* zero exit, unlimited attempts — they are the same. `unless-stopped` is the safer default because it respects operator intent across reboots.

**A9.3** Docker uses exponential backoff starting at 100 ms and doubling (100 ms, 200 ms, 400 ms…) capped at 1 minute, with the counter reset once the container stays up for 10 s. It is dangerous with a `HEALTHCHECK` lacking `--start-period` because the probe begins immediately: a slow-booting app is marked `unhealthy` during normal startup, and any supervisor acting on that status restarts it, producing a crash-loop where the app never gets enough time to become ready. `--start-period` makes failures during the boot window non-counting.

**A9.4** With `journald`, the per-container `*-json.log` files under `/var/lib/docker/containers/<id>/` no longer exist, so the `ls -lh` verification and the `max-size`/`max-file` rotation options are meaningless — rotation becomes journald's job (`SystemMaxUse=` in `journald.conf`). `docker logs` keeps working for the drivers that implement log reading: `json-file`, `local`, `journald`, and (with cluster config) `awslogs`/`gcplogs`. It fails outright for `syslog`, `fluentd`, `gelf`, and `splunk`, where you must query the destination instead.

**A9.5** `service_healthy` only guarantees the dependency was healthy at the moment `web` started. It says nothing about the dependency later restarting, failing over, becoming unreachable due to a network partition, or being slow. Applications must implement **connection retry with exponential backoff and jitter**, idempotent reconnect logic, timeouts on every outbound call, and ideally a circuit breaker — dependency ordering is a convenience for local startup, never a correctness mechanism. This is the same reason Kubernetes has no `depends_on`.

**A9.6** Yes, `deploy.resources.limits` is honoured by Compose v2 outside Swarm — the `docker inspect` output proves it: `mem=134217728` is exactly 128 MiB and `cpuquota=500000000` is 0.5 CPU expressed as NanoCpus. (The legacy Compose v1 behaviour of ignoring the whole `deploy:` key outside Swarm no longer applies to `limits`; other `deploy` keys such as `replicas` and `placement` are still Swarm-only.) The non-`deploy` equivalents `mem_limit` and `cpus` also work and are less ambiguous.

### Exercise 10

**A10.1** Sharing the **network** namespace gives you the target's exact interfaces, routes, `iptables`/`nftables` view, listening sockets (`ss -lntp`), DNS resolution path, and lets you `curl` its listeners over `127.0.0.1` — that is why the `wget` to `127.0.0.1:8080` succeeded from a different container. Sharing the **PID** namespace shows the target's processes with their real in-container PIDs, and with `SYS_PTRACE` allows `strace`, `gdb`, and reading `/proc/<pid>/`. What it does **not** give you is the target's **filesystem**: the debug container has its own rootfs, so you cannot read the app's config files or binaries directly — for that use `/proc/<pid>/root/` from the host (step 3) or, in Kubernetes, an ephemeral container with `--target` plus shared volumes.

**A10.2** `/proc/<pid>/root` is a kernel-maintained magic symlink that resolves relative to that process's **mount namespace and root directory**, so opening a path through it enters the container's filesystem view without any mount or `nsenter`. The prerequisite is privilege: you must have `CAP_SYS_PTRACE` on the host (in practice, be root or the same UID with ptrace permission), and on rootless Podman you must be the owning user or enter the user namespace with `podman unshare`. It also stops working the instant the process exits.

**A10.3** `docker export` writes a **flattened rootfs tarball of a container** — one filesystem tree, no layers, no image config, no `ENTRYPOINT`/`ENV`/history; re-importing it with `docker import` produces a single-layer image whose metadata you must re-specify. `docker save` writes an **image** (or images) with all its layer blobs, the config JSON, the manifest and the tag references — the layered, metadata-preserving form, and the correct choice for moving images between hosts or registries offline. For forensics you often want both: `save` for provenance, `export` for the exact runtime bytes including changes made after start.

**A10.4** `oom=false` with `exit=137` means the process received `SIGKILL` from **outside the cgroup memory subsystem** — a `docker kill`, a `docker stop` whose grace period expired (the Exercise 4 case), a host operator, or the global OOM killer acting on the host rather than the container's cgroup. `oom=true` with `exit=137` means the **container's own memory cgroup** hit its limit and the kernel's cgroup OOM killer chose a process inside it. So: read `State.OOMKilled` first; if it is false and you did not kill it, suspect a failed graceful shutdown and check `State.FinishedAt` against the stop time — a ~10 s gap is the signature. Cross-check with `dmesg` for the kernel's own record.

**A10.5** `kubectl debug -it <pod> --image=nicolaka/netshoot --target=<container>`. The ephemeral container shares the pod's **network namespace** (all containers in a pod always do) and, because of `--target`, the target container's **process namespace**, so `ps` and `/proc/<pid>` see the target's processes. It does **not** share the target's filesystem or its volumes unless the pod's volumes are also mounted — the same limitation as A10.1. `kubectl debug node/<node>` is the host-level variant, and `--copy-to` clones the pod when you need to change its command.

</details>

---

## Sources

- LPI — *DevOps Tools Engineer, Exam 701 Objectives*: https://www.lpi.org/our-certifications/exam-701-objectives/
- Docker — *Dockerfile reference*: https://docs.docker.com/reference/dockerfile/
- Docker — *Runtime options with Memory, CPUs, and GPUs*: https://docs.docker.com/engine/containers/resource_constraints/
- Docker — *Container networking*: https://docs.docker.com/engine/network/
- Docker — *Manage data in Docker (volumes, bind mounts, tmpfs)*: https://docs.docker.com/engine/storage/
- Docker — *Docker security / capabilities and privileged mode*: https://docs.docker.com/engine/security/
- Docker — *Configure logging drivers*: https://docs.docker.com/engine/logging/configure/
- Docker — *Build secrets*: https://docs.docker.com/build/building/secrets/
- Docker — *Compose file reference*: https://docs.docker.com/reference/compose-file/
- OCI — *Image Format Specification*: https://github.com/opencontainers/image-spec/blob/main/spec.md
- OCI — *Runtime Specification (Linux)*: https://github.com/opencontainers/runtime-spec/blob/main/config-linux.md
- Podman — *Rootless containers and user namespaces*: https://docs.podman.io/en/latest/markdown/podman-run.1.html
- Linux kernel — *Control Group v2*: https://docs.kernel.org/admin-guide/cgroup-v2.html
- Linux man-pages — *capabilities(7)*: https://man7.org/linux/man-pages/man7/capabilities.7.html
- Linux man-pages — *pid_namespaces(7)*: https://man7.org/linux/man-pages/man7/pid_namespaces.7.html