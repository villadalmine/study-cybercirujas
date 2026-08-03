# Guided Exercises — 3.3 Containerization (KCNA)

> Prerequisites: a Linux machine (or VM) with **Docker Engine** or **containerd + nerdctl** installed, `sudo` access, and internet connection to pull images from Docker Hub. Some exercises use `ctr` and `crictl`, low-level tools that come with containerd — if you don't have them, you can install them following the [containerd documentation](https://github.com/containerd/containerd).

---

## Exercise 1 — From OCI image to running container

1. Pull an image from a public registry:
   ```bash
   docker pull nginx:1.27
   ```
2. List local images and note the `IMAGE ID`:
   ```bash
   docker images
   ```
3. Inspect the image metadata, particularly the `RootFS` section:
   ```bash
   docker inspect nginx:1.27 --format '{{json .RootFS}}' | jq .
   ```
4. Create and start a container from that image:
   ```bash
   docker run -d --name ej1 -p 8080:80 nginx:1.27
   ```
5. Verify it responds:
   ```bash
   curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8080
   ```

**Questions:**
- What is the difference between an *image* and a *container* in terms of the OCI Image Spec and the OCI Runtime Spec?
- The array you saw in `RootFS.Layers`, what does it represent and why might an image have multiple entries there?

---

## Exercise 2 — Namespaces: process isolation

1. Start a container in the background:
   ```bash
   docker run -d --name ns-demo nginx:1.27
   ```
2. List processes **inside** the container:
   ```bash
   docker exec ns-demo ps aux
   ```
3. Get the PID of the main process as seen **from the host**:
   ```bash
   PID=$(docker inspect --format '{{.State.Pid}}' ns-demo)
   echo $PID
   ```
4. Compare that PID with the PID the process sees inside the container (step 2). Then list the namespaces assigned to that process:
   ```bash
   sudo ls -la /proc/$PID/ns
   ```
5. Compare against the namespaces of the host shell itself:
   ```bash
   ls -la /proc/$$/ns
   ```

**Questions:**
- Why does the `nginx` process have a different PID when viewed from inside the container (e.g., `1`) versus from the host (e.g., `48213`)?
- Name at least three types of Linux namespaces that a container runtime uses to isolate a container and what each one isolates.

---

## Exercise 3 — cgroups: resource limits

1. Start a container with explicit memory and CPU limits:
   ```bash
   docker run -d --name cg-demo --memory=100m --cpus=0.5 nginx:1.27
   ```
2. Confirm the configured limit at the runtime level:
   ```bash
   docker inspect cg-demo --format 'Memory={{.HostConfig.Memory}} NanoCPUs={{.HostConfig.NanoCpus}}'
   ```
3. Locate the full container `ID` and check the actual limit applied by the kernel (cgroup v2; on v1 the path changes to `/sys/fs/cgroup/memory/...`):
   ```bash
   CID=$(docker inspect --format '{{.Id}}' cg-demo)
   cat /sys/fs/cgroup/system.slice/docker-$CID.scope/memory.max
   ```
4. Try to force the container to exceed the memory limit and observe what happens:
   ```bash
   docker exec cg-demo sh -c "cat /dev/zero | head -c 300m | tail"
   docker inspect cg-demo --format '{{.State.OOMKilled}}'
   ```

**Questions:**
- What Linux kernel mechanism enforces the memory and CPU limits you passed to `docker run`?
- If `OOMKilled` is `true`, what does that mean and what system component made the decision to kill the process?

---

## Exercise 4 — Build an image with Dockerfile (multi-stage build)

1. Create a working directory and a single-stage `Dockerfile`:
   ```bash
   mkdir -p ~/kcna-build && cd ~/kcna-build
   cat > Dockerfile.single <<'EOF'
   FROM golang:1.22
   WORKDIR /app
   COPY main.go .
   RUN go build -o server main.go
   CMD ["./server"]
   EOF
   ```
2. Create a minimal `main.go`:
   ```bash
   cat > main.go <<'EOF'
   package main
   func main() { println("hola KCNA") }
   EOF
   ```
3. Build the single-stage image and note its size:
   ```bash
   docker build -f Dockerfile.single -t demo:single .
   docker images demo:single
   ```
4. Now create a **multi-stage** version:
   ```bash
   cat > Dockerfile.multi <<'EOF'
   FROM golang:1.22 AS build
   WORKDIR /app
   COPY main.go .
   RUN go build -o server main.go

   FROM gcr.io/distroless/base-debian12
   COPY --from=build /app/server /server
   CMD ["/server"]
   EOF
   ```
5. Build it and compare the size with the previous version:
   ```bash
   docker build -f Dockerfile.multi -t demo:multi .
   docker images | grep demo
   ```

**Questions:**
- Why is the `demo:multi` image significantly smaller than `demo:single`?
- What gets discarded from the build stage (`AS build`) when the final image only copies the binary with `COPY --from=build`?

---

## Exercise 5 — Layers and union filesystem (OverlayFS)

1. Review the layer history of an image:
   ```bash
   docker history nginx:1.27
   ```
2. Start a container and modify a file inside it:
   ```bash
   docker run -d --name ov-demo nginx:1.27
   docker exec ov-demo sh -c "echo 'hola' > /usr/share/nginx/html/test.txt"
   ```
3. Verify what changed compared to the original image:
   ```bash
   docker diff ov-demo
   ```
4. Stop and remove the container, and confirm the original image was not modified:
   ```bash
   docker rm -f ov-demo
   docker run --rm nginx:1.27 ls /usr/share/nginx/html/
   ```

**Questions:**
- In which layer (according to `docker diff`) was the `test.txt` file recorded, and why did it disappear when the container was deleted?
- Explain in your own words what a union filesystem (like OverlayFS) does to allow many containers to share the same read-only layers without interfering with each other.

---

## Exercise 6 — containerd and CRI: `ctr` and `crictl`

1. Pull an image directly with `ctr` (containerd low-level client, in the default namespace):
   ```bash
   sudo ctr images pull docker.io/library/nginx:1.27
   ```
2. List images managed by containerd:
   ```bash
   sudo ctr images ls
   ```
3. Run a container directly with `ctr` (without going through Docker):
   ```bash
   sudo ctr run -d docker.io/library/nginx:1.27 ctr-demo
   sudo ctr task ls
   ```
4. If you have `crictl` configured pointing to containerd's CRI socket, list pods/containers managed via CRI:
   ```bash
   sudo crictl images
   sudo crictl ps -a
   ```

**Questions:**
- What role does containerd play between the kubelet and the low-level runtime (e.g., `runc`) according to the Container Runtime Interface (CRI)?
- `docker`, `ctr`, and `crictl` all end up using the same containerd underneath. What is the difference in purpose between `ctr` and `crictl`?

---

## Exercise 7 — Local OCI image registry

1. Start a local OCI registry:
   ```bash
   docker run -d -p 5000:5000 --name registry registry:2
   ```
2. Tag an existing image to point to the local registry:
   ```bash
   docker tag nginx:1.27 localhost:5000/nginx:1.27
   ```
3. Push the image:
   ```bash
   docker push localhost:5000/nginx:1.27
   ```
4. Query the registry catalog via its HTTP API:
   ```bash
   curl -s http://localhost:5000/v2/_catalog
   curl -s http://localhost:5000/v2/nginx/tags/list
   ```
5. Delete the local image and pull it again from your registry:
   ```bash
   docker rmi nginx:1.27 localhost:5000/nginx:1.27
   docker pull localhost:5000/nginx:1.27
   ```

**Questions:**
- Which OCI specification defines the format in which a client like `docker push` uploads manifests and layers to a registry?
- Why did you have to run `docker tag` before you could `push` to `localhost:5000/...`?

---

<details>
<summary><strong>View answers</strong></summary>

**Exercise 1**
- An *image* is a static, immutable artifact (defined by the OCI Image Spec: manifest, config, and a set of filesystem layers). A *container* is the running instance of that image: a process (or group of processes) isolated with namespaces and cgroups, governed by the OCI Runtime Spec, with an additional writable layer on top of the image's filesystem.
- Each entry in `RootFS.Layers` is the digest of a filesystem layer (a compressed tar with the changes for that layer). An image has multiple layers because it is built incrementally instruction by instruction from the Dockerfile (or build), and these layers are shared and cached between images.

**Exercise 2**
- Because the container's PID namespace gives it its own process tree: inside that namespace the first created process always gets PID 1, even though from the host namespace that same process has a different PID (it is the same kernel process, seen with two different "numbers" depending on the namespace from which it is viewed).
- Examples: PID namespace (isolates the view of the process tree), Network namespace (isolates network interfaces, routes, ports), Mount namespace (isolates mount/filesystem tree), UTS namespace (isolates hostname), IPC namespace (isolates inter-process communication mechanisms like message queues/semaphores), User namespace (isolates UID/GID mapping).

**Exercise 3**
- **cgroups** (control groups) of Linux, which the container runtime configures when creating the container to limit and account for CPU, memory, I/O, etc. for that group of processes.
- `OOMKilled: true` means the Linux kernel (the OOM killer, activated when the cgroup exceeds its `memory.max`) killed the container's main process because it exceeded the configured memory limit.

**Exercise 4**
- Because the final image (`demo:multi`) starts from a minimal base (`distroless`) and only copies the compiled binary, without including the Go compiler, source code, or build tools from the `build` stage, all of which are present in the single-stage version.
- Everything from the `build` stage that was not explicitly copied is discarded: the Go SDK, module cache, `main.go` source code, and any intermediate files — that stage does not even remain as a layer in the final image.

**Exercise 5**
- It was recorded in the writable top layer of the `ov-demo` container, which is exclusive to that container. When you run `docker rm -f`, that layer is destroyed along with the container, so the file disappears; the original image was never touched.
- A union filesystem (union filesystem) like OverlayFS combines multiple read-only layers (`lowerdir`) with one writable layer per container (`upperdir`) to present a unified view (`merged`). Since the read-only layers are never modified, many containers can point to the same shared base layers on disk, and each only adds its own writable layer on top.

**Exercise 6**
- containerd implements the CRI (Container Runtime Interface) exposed to the kubelet: it receives gRPC calls from the kubelet (create pod, run container, pull image, etc.) and translates them into concrete operations, delegating the actual creation of the isolated process to a low-level runtime compatible with the OCI Runtime Spec, typically `runc` (via `containerd-shim`).
- `ctr` is a low-level debugging tool that talks directly to containerd's native API (does not go through CRI); `crictl` talks to containerd via the CRI socket, the same path the kubelet uses, so it is useful for inspecting the state as Kubernetes would see it (pods, sandboxes, etc.), not just individual containers.

**Exercise 7**
- The **OCI Distribution Spec**, which defines the HTTP API (`/v2/...`) that clients use to upload and download manifests, configs, and layers (blobs) to/from a registry.
- Because the local image name (`nginx:1.27`) does not include the target registry host. Docker uses the full reference name (`<registry>/<repo>:<tag>`) to decide which registry to push to; without the `localhost:5000/` prefix, `docker push nginx:1.27` would try to push to Docker Hub.

</details>

---

**Reference source:** [KCNA Curriculum — CNCF](https://github.com/cncf/curriculum/raw/master/KCNA_Curriculum.pdf)