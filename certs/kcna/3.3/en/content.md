# 3.3 Containerization

## What is a container?

A **container** is a software unit that packages code and all its dependencies (libraries, binaries, configuration files) so that an application runs quickly and reliably across different computing environments. Unlike a virtual machine (VM), a container does not include a complete operating system: it shares the host kernel and isolates the process using kernel primitives of the Linux kernel itself.

This difference is key for the exam: VMs virtualize hardware (via a hypervisor) and each runs its own kernel; containers virtualize the operating system (via the host kernel) and are therefore much lighter, start in milliseconds/seconds, and consume fewer resources.

```
VM                              Container
┌─────────────┐                 ┌─────────────┐
│   App A     │                 │   App A     │
├─────────────┤                 ├─────────────┤
│  Bins/Libs  │                 │  Bins/Libs  │
├─────────────┤                 ├─────────────┤
│ Guest OS    │                 │  (runtime)  │
├─────────────┤                 ├─────────────┤
│ Hypervisor  │                 │  Host OS    │
├─────────────┤                 ├─────────────┤
│ Infra       │                 │  Infra      │
└─────────────┘                 └─────────────┘
```

## The Linux kernel primitives

Containers are not "magic": they are normal Linux processes to which the runtime applies two kernel mechanisms.

- **Namespaces**: isolate what a process *can see*. Each namespace gives the process its own view of a system resource.
  - `pid` — own process tree (process 1 inside the container is not the host's process 1).
  - `net` — own network interfaces, routing tables, and ports.
  - `mnt` — own filesystem mount point.
  - `uts` — own hostname and domainname.
  - `ipc` — isolated inter-process communication mechanisms (message queues, semaphores).
  - `user` — UID/GID mapping, basis for *rootless containers*.
- **Control groups (cgroups)**: limit and account what a process *can use* (CPU, memory, disk I/O, network bandwidth). They are the reason a container can have `--memory=512m` or `--cpus=0.5`.

In short: **namespaces = isolation (visibility), cgroups = limits (consumption)**.

## Container images and the OCI standard

A **container image** is an immutable, read-only artifact composed of layers stacked via a union filesystem (typically `overlay2`). Each instruction in a Dockerfile that modifies the filesystem creates a new layer, and layers are cached and reused between builds.

The **Open Container Initiative (OCI)**, part of CNCF/Linux Foundation, defines open specifications so that any tool is interoperable:

- **OCI Image Spec**: format of images (layers, manifest, configuration).
- **OCI Runtime Spec**: how a container is executed from a *bundle* (filesystem + config JSON).
- **OCI Distribution Spec**: how to push/pull images to/from a registry.

Example of a Dockerfile with **multi-stage build** (a frequently asked pattern that reduces the final image size):

```dockerfile
# Stage 1: build
FROM golang:1.22 AS builder
WORKDIR /src
COPY . .
RUN go build -o app .

# Stage 2: runtime, only the final binary
FROM alpine:3.19
COPY --from=builder /src/app /usr/local/bin/app
ENTRYPOINT ["/usr/local/bin/app"]
```

```
$ docker build -t myapp:1.0 .
$ docker images
REPOSITORY   TAG    IMAGE ID       SIZE
myapp        1.0    a1b2c3d4e5f6   12.4MB
golang       1.22   f6e5d4c3b2a1   814MB
```

## Container runtimes and CRI

Kubernetes does not run containers directly: it delegates that task to a **runtime**, through the **Container Runtime Interface (CRI)**, a gRPC API that decouples the kubelet from a specific implementation.

Two levels are distinguished:

- **High-level runtime**: manages the full lifecycle (image pulling, storage management, API for the kubelet). Examples: **containerd** and **CRI-O**. Docker Engine also acted as a high-level runtime, but **dockershim** was removed from Kubernetes in v1.24; today Docker Desktop uses containerd under the hood.
- **Low-level runtime**: creates and runs the container itself, applying namespaces/cgroups according to the OCI Runtime Spec. The de facto standard is **runc**. Alternatives oriented towards greater isolation/security exist, such as **gVisor** (sandboxing via syscall interception) and **Kata Containers** (each container runs inside a lightweight micro-VM).

```
kubelet ──(CRI/gRPC)──> containerd/CRI-O ──(OCI)──> runc ──> container process
```

```
$ crictl ps
CONTAINER    IMAGE               STATE      NAME
9f8e7d6c5b   nginx:1.27          Running    web
$ ctr images ls
REF                      TYPE       DIGEST
docker.io/library/nginx  manifest   sha256:1a2b3c...
```

## Registries

A **container registry** stores and distributes images following the OCI Distribution Spec. Examples: Docker Hub, Harbor (CNCF graduated open source registry), GitHub Container Registry, ECR/GCR/ACR from cloud providers.

```
$ docker tag myapp:1.0 registry.example.com/team/myapp:1.0
$ docker push registry.example.com/team/myapp:1.0
$ docker pull registry.example.com/team/myapp:1.0
```

Related best practices (relevant for the exam): use immutable tags (avoid depending only on `latest`), sign images (Sigstore/Cosign), and scan for vulnerabilities (Trivy, Grype) before publishing.

## Container security

Points that KCNA often touches at an introductory level:

- **Rootless containers**: run the runtime and processes without root privileges on the host, using `user` namespaces.
- **Capabilities**: instead of a binary root/no-root, Linux exposes granular capabilities (`NET_BIND_SERVICE`, `SYS_ADMIN`, etc.) that can be granted or removed (`--cap-drop`, `--cap-add`).
- **Seccomp**: filters which syscalls a process inside the container can invoke, reducing the attack surface.
- **Minimal image**: using bases like `alpine` or `distroless` reduces size and the number of exposed CVEs.

## References

- CNCF, *KCNA Curriculum*: https://github.com/cncf/curriculum/raw/master/KCNA_Curriculum.pdf
- Open Container Initiative — specifications: https://opencontainers.org/
- containerd: https://containerd.io/docs/
- CRI-O: https://cri-o.io/
- Kubernetes, *Container Runtimes*: https://kubernetes.io/docs/setup/production-environment/container-runtimes/
- Kubernetes, *Container Runtime Interface (CRI)*: https://kubernetes.io/docs/concepts/architecture/cri/
- runc: https://github.com/opencontainers/runc
- gVisor: https://gvisor.dev/docs/
- Kata Containers: https://katacontainers.io/
- Docker, *Overview of Docker*: https://docs.docker.com/get-started/overview/
- Harbor: https://goharbor.io/docs/