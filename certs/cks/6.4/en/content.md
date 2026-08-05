# 6.4 — Ensure immutability of containers at runtime

**Certification:** CKS (Certified Kubernetes Security Specialist), curriculum v1.34
**Domain:** Monitoring, Logging and Runtime Security · **Weight:** 4

---

## 1. The production problem

A container image is a content-addressable, signed, scanned artifact. The moment the kubelet hands it to the CRI runtime, that guarantee evaporates: the OCI runtime stacks a writable `upperdir` on top of the image layers, and from that instant the running container is a *mutable* filesystem that no longer corresponds to anything you scanned, signed, or attested.

Everything that makes container security tractable depends on closing that gap:

| Guarantee you *think* you have | What breaks it |
|---|---|
| "This pod runs the code we scanned in CI" | Attacker writes `/usr/bin/curl` or overwrites the app binary in the writable layer |
| "Two replicas of this Deployment are identical" | One replica got `kubectl exec`'d and patched by hand at 03:00 during an incident |
| "We can forensically reason about the blast radius" | Post-mortem shows a container whose filesystem diverged from its image weeks ago; nobody knows when |
| "Rebuilding from the image removes the compromise" | It does — but only if you can *detect* that you need to, which requires drift signals |
| "The SBOM is accurate" | A dropped static binary appears in no SBOM |

The attack chain this control targets is short and extremely common:

1. **Initial access** — RCE via a deserialization bug, SSRF, or a vulnerable dependency in the app itself.
2. **Ingress tool transfer** (MITRE ATT&CK **T1105**) — the attacker needs tooling. `curl`/`wget` a static `nc`, `kubectl`, or a crypto-miner into a writable path.
3. **Execution** — `chmod +x` and run it.
4. **Persistence** (**T1543**, **T1546**) — overwrite an entrypoint script, drop a cron entry, patch a shared library so it survives a process restart *inside the same container*.
5. **Escalation / lateral movement** (**T1611**) — use the dropped tooling against the API server, the node, or peer pods.

Runtime immutability breaks the chain at step 2–3, which is the cheapest possible place to break it. Note the crucial asymmetry: an attacker with RCE has *arbitrary code execution inside your process*, which you cannot prevent post-hoc. What you *can* prevent is that execution turning into **durable, tool-assisted, hard-to-detect** presence.

### Immutability is three separate properties

CKS phrases this as one objective, but in production it decomposes into three controls with three different enforcement layers, and conflating them is the single most common design error:

| Property | Meaning | Enforcement layer |
|---|---|---|
| **Image immutability** | The bytes that run are exactly the bytes that were signed. Tags cannot be re-pointed underneath you. | Registry + digest pinning + `AlwaysPullImages` + signature verification |
| **Filesystem immutability** | The running container cannot modify its own root filesystem. | OCI runtime (`root.readonly`), LSMs (AppArmor/SELinux) |
| **Configuration immutability** | Pod spec, ConfigMaps and Secrets are replaced by rollout, never patched in place. | API server (`immutable: true`), RBAC, GitOps, admission policy |

A read-only root filesystem on a container built `FROM ubuntu:latest` with a mutable tag and a writable `/var/lib` PVC gives you almost nothing. All three properties must hold together.

---

## 2. Mechanics: what `readOnlyRootFilesystem` actually does

This is the field CKS tests, and understanding its exact semantics tells you precisely what it does *not* cover.

### 2.1 The path from PodSpec to kernel

```
PodSpec.spec.containers[].securityContext.readOnlyRootFilesystem: true
        │
        ▼
kubelet → CRI  ContainerConfig.linux.security_context.readonly_rootfs = true
        │
        ▼
containerd → OCI runtime spec (config.json)   "root": { "path": "rootfs", "readonly": true }
        │
        ▼
runc:  mount(NULL, rootfs, NULL, MS_BIND|MS_REMOUNT|MS_RDONLY|..., NULL)
```

The last step is the important one. runc does **not** create a read-only overlay. It builds the normal read-write overlay, then **bind-remounts the mount point read-only**. Two consequences you can observe directly:

```console
$ kubectl exec -n payments deploy/edge -c nginx -- cat /proc/self/mountinfo | head -3
1877 1876 0:143 / / ro,relatime master:412 - overlay overlay rw,lowerdir=/var/lib/containerd/io.containerd.snapshotter.v1.overlayfs/snapshots/2401/fs:/var/lib/containerd/io.containerd.snapshotter.v1.overlayfs/snapshots/2400/fs,upperdir=/var/lib/containerd/io.containerd.snapshotter.v1.overlayfs/snapshots/2417/fs,workdir=/var/lib/containerd/io.containerd.snapshotter.v1.overlayfs/snapshots/2417/work
1878 1877 0:146 / /proc rw,nosuid,nodev,noexec,relatime - proc proc rw
1879 1877 0:147 / /dev rw,nosuid,noexec,relatime - tmpfs tmpfs rw,size=65536k,mode=755
```

Read field 6 (`ro,relatime`) versus the superblock options after the `-` separator (`overlay rw,...`). **The mount is read-only; the filesystem underneath is read-write.** That distinction is why:

- `readOnlyRootFilesystem` is enforced by the kernel's mount flags, not by the storage driver — it is cheap, immediate, and returns `EROFS` (errno 30) on every write attempt.
- It applies to **that mount point only**. Every other mount in the container's mount namespace carries its own flags.

### 2.2 Verify at the runtime level

```console
$ CID=$(sudo crictl ps -q --name nginx --state Running | head -1)
$ sudo crictl inspect --output json "$CID" | jq '.info.runtimeSpec.root'
{
  "path": "rootfs",
  "readonly": true
}
```

And the paths the CRI hardens by default, independent of your PodSpec:

```console
$ sudo crictl inspect --output json "$CID" | jq '.info.runtimeSpec.linux | {maskedPaths, readonlyPaths}'
{
  "maskedPaths": [
    "/proc/acpi",
    "/proc/asound",
    "/proc/kcore",
    "/proc/keys",
    "/proc/latency_stats",
    "/proc/timer_list",
    "/proc/timer_stats",
    "/proc/sched_debug",
    "/proc/scsi",
    "/sys/firmware",
    "/sys/devices/virtual/powercap"
  ],
  "readonlyPaths": [
    "/proc/bus",
    "/proc/fs",
    "/proc/irq",
    "/proc/sys",
    "/proc/sysrq-trigger"
  ]
}
```

These defaults are why a container cannot write `/proc/sys/kernel/core_pattern` (a classic container-escape primitive) even without `readOnlyRootFilesystem`. They are undone by `securityContext.procMount: Unmasked`, which requires the `ProcMountType` feature gate and is forbidden by the `baseline` and `restricted` Pod Security Standards — treat any request for it as a red flag.

### 2.3 What `readOnlyRootFilesystem: true` does **not** cover

This is the part that fails audits.

```console
$ kubectl exec -n payments deploy/edge -c nginx -- sh -c 'awk "{print \$5, \$6}" /proc/self/mountinfo'
/ ro,relatime
/proc rw,nosuid,nodev,noexec,relatime
/dev rw,nosuid,noexec,relatime
/dev/shm rw,nosuid,nodev,noexec,relatime
/dev/termination-log rw,nosuid,nodev,relatime
/etc/hosts rw,nosuid,nodev,relatime
/etc/hostname rw,nosuid,nodev,relatime
/etc/resolv.conf rw,nosuid,nodev,relatime
/etc/nginx/nginx.conf ro,relatime
/tmp rw,relatime
/var/run/secrets/kubernetes.io/serviceaccount ro,relatime
```

Everything except `/` and the two `ro` entries is writable. Concretely, with `readOnlyRootFilesystem: true` an attacker can still:

| Writable surface | Origin | Exec allowed? | Mitigation |
|---|---|---|---|
| `/dev/shm` (64 MiB tmpfs) | CRI default | No — `noexec` | Keep `noexec`; monitor for staging |
| `/etc/hosts`, `/etc/hostname`, `/etc/resolv.conf` | kubelet bind mounts from the pod dir | No (file, not dir) | Detect edits (DNS hijack primitive) |
| `/dev/termination-log` | kubelet, `terminationMessagePath` | No | Set `terminationMessagePolicy: FallbackToLogsOnError`; cannot be removed |
| Any `emptyDir` you mounted | your PodSpec | **Yes, by default** | See §4 — this is where discipline is required |
| Any PVC | your PodSpec | **Yes** | Genuine state only; never mount over `/usr`, `/bin`, `/opt/app` |
| `hostPath` | your PodSpec | **Yes, and it escapes the container** | Forbidden by PSS `baseline`/`restricted` |
| Anonymous memory via `memfd_create(2)` + `fexecve(2)` | kernel | **Yes — fileless** | Undetectable by any path-based control; needs eBPF/Falco |

The last row is the one that ends the "read-only root filesystem = solved" argument. Fileless execution (`memfd_create` → write ELF → `execveat(fd, "", ..., AT_EMPTY_PATH)`, MITRE **T1620**) touches no path on any filesystem. `readOnlyRootFilesystem`, AppArmor path rules, and SELinux file contexts are all blind to it. Only syscall-level runtime detection sees it. **Prevention and detection are not substitutes for each other.**

---

## 3. Comparative analysis of the control set

### 3.1 Controls, coverage, and cost

| Control | Enforcement layer | Blocks | Blind to | Operational cost |
|---|---|---|---|---|
| `readOnlyRootFilesystem: true` | OCI runtime, `MS_RDONLY` bind remount | All writes to `/` | Volumes, `/dev/shm`, kubelet-injected files, memfd | App refactor to relocate writable state; **medium**, one-time |
| Distroless / `scratch` base image | Image build | `sh`, `curl`, `apt`, `python` — the entire living-off-the-land toolbox | Statically linked binary dropped into a writable mount | `kubectl exec`/`kubectl cp` stop working; debug via ephemeral containers; **medium** |
| Digest pinning (`image: repo@sha256:…`) | Image resolution | Mutable-tag re-point; "it worked yesterday" drift | Compromised registry serving a signed-but-malicious digest | Requires renovate/automation; **medium, recurring** |
| `AlwaysPullImages` admission plugin | API server | Reuse of a cached image by a pod whose SA lacks pull rights | Nothing about content | Registry load, pull latency, availability coupling; **low–medium** |
| Cosign / Sigstore verification (Kyverno `verifyImages`, `ImagePolicyWebhook`) | Admission | Unsigned or wrongly-attested images | Signed-but-vulnerable images | Key/Fulcio management; **medium** |
| PSS `restricted` (Pod Security Admission) | API server, built-in | `privileged`, privilege escalation, all capabilities, `hostPath`, host namespaces, non-root enforcement, seccomp | **Does NOT require `readOnlyRootFilesystem`** | Free (label the namespace); **very low** |
| ValidatingAdmissionPolicy (CEL, in-process) | API server | Any spec-level rule you can express, incl. read-only rootfs and digest pinning | Post-admission behaviour | No extra pods, no webhook latency/availability risk; **low** |
| Kyverno / OPA Gatekeeper | Validating+mutating webhook | Same, plus *mutation* (auto-inject) and image verification | Post-admission behaviour | Extra control-plane dependency; webhook outage = cluster impact; **medium** |
| AppArmor `deny /** w` profile | LSM, path-based | Writes **anywhere**, including volumes and PVCs | memfd; requires profile present on every node | Per-workload profile authoring + node distribution; **high** |
| SELinux (`seLinuxOptions`, MCS) | LSM, label-based | Cross-container and host writes; type-enforced in-container writes | memfd | RHEL/OpenShift-centric expertise; **high** |
| seccomp `RuntimeDefault` | LSM, syscall-number filter | ~44 dangerous syscalls (`mount`, `pivot_root`, `kexec_load`, `bpf`…) | **Cannot filter `write(2)` by path** — seccomp sees only register values, never dereferences pointers | Free; **very low** — always enable it |
| Falco / Tetragon / eBPF sensors | Runtime detection | Nothing (detect-only, unless enforcing mode) | — | Node agent, rule tuning, alert fatigue; **medium–high** |
| `immutable: true` ConfigMaps/Secrets | API server | In-place config mutation; also removes the kubelet watch (large scaling win) | Nothing about the container fs | Requires content-hashed names for rollout; **low** |
| RBAC removal of `pods/exec`, `pods/attach`, `pods/ephemeralcontainers`, `pods/portforward` | API server | Human-driven drift, the #1 real-world cause | Attacker already inside the container | Culture change; **medium** |

**Key insight for design reviews:** `seccomp` and `readOnlyRootFilesystem` are complementary, not redundant. seccomp filters *which syscall*, never *which path* — it physically cannot, because dereferencing a userspace pointer inside a BPF filter would be a TOCTOU vulnerability. Path-scoped write control is exclusively an LSM (AppArmor/SELinux) or mount-flag (`readOnlyRootFilesystem`) concern.

### 3.2 Strategies for the writable state you genuinely need

Almost no real workload writes zero bytes. Choosing the backing store correctly is the whole design exercise.

| Strategy | Backing store | Survives container restart | Survives pod reschedule | Accounted against | `noexec`? | Verdict |
|---|---|---|---|---|---|---|
| `emptyDir: {}` | Node disk under `/var/lib/kubelet/pods/<uid>/volumes/` | Yes | No | Pod `ephemeral-storage` limit; kubelet evicts the pod on `sizeLimit` breach | No | **Default choice** for scratch/cache |
| `emptyDir: {medium: Memory, sizeLimit: 64Mi}` | tmpfs | Yes | No | **Container memory limit** — tmpfs pages are charged to the pod cgroup | No | Best for secrets material, PID files, small temp; never touches disk |
| `configMap` / `secret` / `downwardAPI` / `projected` volume | tmpfs, mounted **read-only always** | Yes | Yes | negligible | n/a | Config injection; already immutable |
| PVC (CSI) | External volume | Yes | Yes | StorageClass quota | No | Genuine durable state only |
| `hostPath` | Node filesystem | Yes | No (node-pinned) | Nothing | No | **Forbidden** — breaks the container boundary entirely |

Two behaviours that surprise people in production:

- **Memory-backed `emptyDir` size.** Since the `SizeMemoryBackedVolumes` feature (enabled by default since v1.22), the tmpfs is created with `size=` set from `sizeLimit`. Overrunning it gives the process an immediate `ENOSPC`. Without that gate, the tmpfs defaults to 50% of *node* RAM and the pod gets OOM-killed instead — a far worse failure mode. Always set `sizeLimit`, and always add it to the container's `resources.limits.memory`.
- **Disk-backed `emptyDir` size.** `sizeLimit` is *not* a filesystem quota. The kubelet's eviction manager measures usage during periodic housekeeping (~10 s) and **evicts the whole pod**. You get `Evicted`, not `ENOSPC`, and you get it seconds late.

---

## 4. Complete production manifests

### 4.1 Reference workload: nginx, non-root, read-only, digest-pinned

This is the canonical "make a filesystem-hungry workload immutable" exercise. Stock nginx writes to `/var/cache/nginx/*`, `/var/run/nginx.pid` and `/etc/nginx/conf.d` — all of which must be relocated onto tmpfs.

First, resolve the digest. Never hand-copy this from a browser:

```console
$ crane digest docker.io/nginxinc/nginx-unprivileged:1.27.4-alpine
sha256:9f7cd4d4a53ea6b0a4bd52a7ef6ee65cd58c68c76ecb5f47d9f7d3fbb2d1f5c3

$ skopeo inspect docker://docker.io/nginxinc/nginx-unprivileged:1.27.4-alpine | jq -r '.Digest'
sha256:9f7cd4d4a53ea6b0a4bd52a7ef6ee65cd58c68c76ecb5f47d9f7d3fbb2d1f5c3
```

> The digest above is an example. Re-resolve it in your own pipeline and let a bot (Renovate, `digestabot`) keep it current — a stale pinned digest is a *vulnerability management* failure, which is why pinning must be automated rather than manual.

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: payments
  labels:
    # Baseline platform posture. Note: `restricted` does NOT imply
    # readOnlyRootFilesystem — that is added by the VAP in section 5.
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: v1.34
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/audit-version: v1.34
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/warn-version: v1.34
    security.example.com/immutability: enforce
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: edge
  namespace: payments
automountServiceAccountToken: false
---
apiVersion: v1
kind: ConfigMap
metadata:
  # Content-hashed name. `immutable: true` means this object can never be
  # edited; a config change produces a NEW ConfigMap and a NEW Deployment
  # revision. Generate the suffix with kustomize configMapGenerator or a
  # sha256 of the data block in CI.
  name: edge-nginx-conf-7f4c2b9d61
  namespace: payments
immutable: true
data:
  nginx.conf: |
    worker_processes auto;
    # PID file relocated onto the tmpfs emptyDir; the default /var/run/nginx.pid
    # lives on the read-only root filesystem.
    pid /tmp/nginx/nginx.pid;
    error_log /dev/stderr warn;

    events {
      worker_connections 1024;
    }

    http {
      include       /etc/nginx/mime.types;
      default_type  application/octet-stream;
      access_log    /dev/stdout combined;

      # Every temp path nginx may write to, relocated under /tmp.
      client_body_temp_path /tmp/nginx/client_body;
      proxy_temp_path       /tmp/nginx/proxy;
      fastcgi_temp_path     /tmp/nginx/fastcgi;
      uwsgi_temp_path       /tmp/nginx/uwsgi;
      scgi_temp_path        /tmp/nginx/scgi;

      sendfile        on;
      keepalive_timeout 65;
      server_tokens   off;

      server {
        listen 8080;
        server_name _;
        root /usr/share/nginx/html;

        location = /healthz {
          access_log off;
          add_header Content-Type text/plain;
          return 200 "ok\n";
        }

        location / {
          try_files $uri $uri/ =404;
        }
      }
    }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: edge
  namespace: payments
  labels:
    app.kubernetes.io/name: edge
spec:
  replicas: 3
  revisionHistoryLimit: 5
  selector:
    matchLabels:
      app.kubernetes.io/name: edge
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  template:
    metadata:
      labels:
        app.kubernetes.io/name: edge
      annotations:
        # Forces a rollout whenever the (immutable) ConfigMap name changes.
        checksum/config: "7f4c2b9d61"
    spec:
      serviceAccountName: edge
      automountServiceAccountToken: false
      enableServiceLinks: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 101
        runAsGroup: 101
        fsGroup: 101
        fsGroupChangePolicy: OnRootMismatch
        seccompProfile:
          type: RuntimeDefault
        # AppArmor as a first-class field (GA in v1.31). Replaces the
        # deprecated container.apparmor.security.beta.kubernetes.io/<name>
        # annotation. The profile must already be loaded on the node.
        appArmorProfile:
          type: Localhost
          localhostProfile: k8s-immutable-nginx

      initContainers:
        # The classic pattern: an init container populates the writable
        # emptyDir so the main container never has to mkdir at startup.
        - name: prepare-tmp
          image: docker.io/nginxinc/nginx-unprivileged:1.27.4-alpine@sha256:9f7cd4d4a53ea6b0a4bd52a7ef6ee65cd58c68c76ecb5f47d9f7d3fbb2d1f5c3
          imagePullPolicy: IfNotPresent
          command:
            - /bin/sh
            - -c
            - |
              set -eu
              mkdir -p /tmp/nginx/client_body \
                       /tmp/nginx/proxy \
                       /tmp/nginx/fastcgi \
                       /tmp/nginx/uwsgi \
                       /tmp/nginx/scgi
              chmod 0700 /tmp/nginx
              ls -la /tmp/nginx
          securityContext:
            readOnlyRootFilesystem: true
            allowPrivilegeEscalation: false
            privileged: false
            runAsNonRoot: true
            runAsUser: 101
            capabilities:
              drop: ["ALL"]
            seccompProfile:
              type: RuntimeDefault
          resources:
            requests: { cpu: 10m, memory: 16Mi }
            limits:   { cpu: 100m, memory: 32Mi }
          volumeMounts:
            - name: tmp
              mountPath: /tmp

      containers:
        - name: nginx
          image: docker.io/nginxinc/nginx-unprivileged:1.27.4-alpine@sha256:9f7cd4d4a53ea6b0a4bd52a7ef6ee65cd58c68c76ecb5f47d9f7d3fbb2d1f5c3
          imagePullPolicy: IfNotPresent
          args: ["nginx", "-g", "daemon off;", "-c", "/etc/nginx/nginx.conf"]
          ports:
            - name: http
              containerPort: 8080
              protocol: TCP
          securityContext:
            # ── The objective of this section ──────────────────────────────
            readOnlyRootFilesystem: true
            # ───────────────────────────────────────────────────────────────
            allowPrivilegeEscalation: false
            privileged: false
            runAsNonRoot: true
            runAsUser: 101
            runAsGroup: 101
            capabilities:
              drop: ["ALL"]
              # NET_BIND_SERVICE is NOT needed: we listen on 8080, not 80.
              # Adding it here would be the single most common gratuitous
              # capability grant in the wild.
            seccompProfile:
              type: RuntimeDefault
          resources:
            requests:
              cpu: 100m
              # tmpfs pages are charged to this cgroup: 64Mi (tmp) is included.
              memory: 128Mi
              ephemeral-storage: 64Mi
            limits:
              cpu: 500m
              memory: 256Mi
              ephemeral-storage: 128Mi
          startupProbe:
            httpGet: { path: /healthz, port: http }
            periodSeconds: 2
            failureThreshold: 30
          readinessProbe:
            httpGet: { path: /healthz, port: http }
            periodSeconds: 5
          livenessProbe:
            httpGet: { path: /healthz, port: http }
            periodSeconds: 10
          terminationMessagePolicy: FallbackToLogsOnError
          volumeMounts:
            - name: tmp
              mountPath: /tmp
            - name: nginx-conf
              mountPath: /etc/nginx/nginx.conf
              subPath: nginx.conf
              readOnly: true
            - name: nginx-cache
              mountPath: /var/cache/nginx
            - name: nginx-run
              mountPath: /var/run

      volumes:
        # Memory-backed: never touches node disk, wiped on container restart.
        # sizeLimit is enforced as the tmpfs `size=` mount option.
        - name: tmp
          emptyDir:
            medium: Memory
            sizeLimit: 64Mi
        - name: nginx-cache
          emptyDir:
            medium: Memory
            sizeLimit: 32Mi
        - name: nginx-run
          emptyDir:
            medium: Memory
            sizeLimit: 8Mi
        - name: nginx-conf
          configMap:
            name: edge-nginx-conf-7f4c2b9d61
            defaultMode: 0444
---
apiVersion: v1
kind: Service
metadata:
  name: edge
  namespace: payments
spec:
  selector:
    app.kubernetes.io/name: edge
  ports:
    - name: http
      port: 80
      targetPort: http
```

### 4.2 The ideal case: a static binary on `scratch`

For anything you compile yourself, the strongest posture is a single static binary with no filesystem to speak of. There is nothing to overwrite and nothing to execute.

```dockerfile
# syntax=docker/dockerfile:1.7
FROM golang:1.24-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
# CGO_ENABLED=0 → pure-static; -trimpath + -buildid= → reproducible builds,
# so the digest is verifiable by a third party.
RUN CGO_ENABLED=0 GOOS=linux go build \
      -trimpath \
      -ldflags="-s -w -buildid=" \
      -o /out/app ./cmd/app

FROM scratch
# CA bundle and passwd are the only two things a static Go binary usually
# needs from the base image.
COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY --from=build --chown=65532:65532 /out/app /app
USER 65532:65532
ENTRYPOINT ["/app"]
```

```yaml
containers:
  - name: app
    image: ghcr.io/example/app@sha256:3c1f0e2b8a7d64f5c9e0b1a2d3f4e5a6b7c8d9e0f1a2b3c4d5e6f7a8b9c0d1e2
    securityContext:
      readOnlyRootFilesystem: true
      allowPrivilegeEscalation: false
      runAsNonRoot: true
      runAsUser: 65532
      runAsGroup: 65532
      capabilities: { drop: ["ALL"] }
      seccompProfile: { type: RuntimeDefault }
    volumeMounts:
      - name: tmp
        mountPath: /tmp          # Go's os.CreateTemp, TLS session cache, pprof
volumes:
  - name: tmp
    emptyDir: { medium: Memory, sizeLimit: 16Mi }
```

Trade-off, stated honestly: `kubectl exec` and `kubectl cp` are now impossible (no shell, no `tar`). That is the *point* — but it means your incident-response runbook must be rewritten around ephemeral debug containers (§7.3) before you ship this, not after.

### 4.3 AppArmor profile: deny-writes-everywhere, including volumes

`readOnlyRootFilesystem` cannot protect the `emptyDir` you just mounted at `/tmp`. If you need `/tmp` writable for data but not for *code*, an LSM is the only tool that can express that.

`/etc/apparmor.d/k8s-immutable-nginx` on every node:

```
#include <tunables/global>

profile k8s-immutable-nginx flags=(attach_disconnected,mediate_deleted) {
  #include <abstractions/base>
  #include <abstractions/nameservice>

  # ── Capabilities ────────────────────────────────────────────────────────
  # We listen on 8080, so we need none at all.
  deny capability,

  # ── Network ─────────────────────────────────────────────────────────────
  network inet  stream,
  network inet6 stream,
  network unix  stream,
  deny network raw,
  deny network packet,

  # ── Read everywhere, execute only the known binary ──────────────────────
  /** r,
  /usr/sbin/nginx ix,
  /usr/lib/nginx/modules/*.so mr,

  # ── The only writable islands: must mirror the emptyDir mounts ──────────
  /tmp/**             rwk,
  /var/cache/nginx/** rwk,
  /var/run/**         rwk,
  /dev/std{out,err}   w,

  # ── Explicit, audited denials ───────────────────────────────────────────
  audit deny /usr/**  w,
  audit deny /bin/**  w,
  audit deny /sbin/** w,
  audit deny /lib/**  w,
  audit deny /etc/**  w,
  audit deny /**/     w,

  # No new executables anywhere, even inside the writable islands.
  audit deny /tmp/**             x,
  audit deny /var/cache/nginx/** x,
  audit deny /var/run/**         x,
  audit deny /dev/shm/**         x,

  # ── Escape primitives ───────────────────────────────────────────────────
  deny mount,
  deny umount,
  deny pivot_root,
  deny ptrace (trace, tracedby, read),
  audit deny /proc/*/mem      w,
  audit deny /proc/sys/**     w,
  audit deny @{PROC}/kcore    rwklx,
}
```

Distribute and load it with a DaemonSet (the node-level prerequisite people forget):

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: apparmor-loader
  namespace: kube-system
spec:
  selector:
    matchLabels: { name: apparmor-loader }
  template:
    metadata:
      labels: { name: apparmor-loader }
    spec:
      hostPID: false
      # Loading an AppArmor profile REQUIRES writing to the node's
      # securityfs. This is a deliberately privileged, deliberately
      # tiny, deliberately audited exception to everything above.
      containers:
        - name: loader
          image: registry.k8s.io/apparmor-loader:v0.4.1
          args: ["-poll", "10s", "/profiles"]
          securityContext:
            privileged: true
          volumeMounts:
            - name: profiles
              mountPath: /profiles
              readOnly: true
            - name: sys
              mountPath: /sys
              readOnly: false
      volumes:
        - name: profiles
          configMap:
            name: apparmor-profiles
        - name: sys
          hostPath:
            path: /sys
            type: Directory
      tolerations:
        - operator: Exists
```

Verify the profile is actually applied — not merely requested:

```console
$ kubectl exec -n payments deploy/edge -c nginx -- cat /proc/self/attr/current
k8s-immutable-nginx (enforce)

$ sudo aa-status | grep -A2 'profiles are in enforce'
27 profiles are in enforce mode.
   /usr/bin/man
   k8s-immutable-nginx
```

---

## 5. Enforcement at admission

### 5.1 The Pod Security Admission gap

Read this carefully, because it is the most frequently mis-stated fact in this domain:

**The `restricted` Pod Security Standard does not require `readOnlyRootFilesystem`.**

`restricted` requires `allowPrivilegeEscalation: false`, `runAsNonRoot: true`, `capabilities.drop: ["ALL"]`, a `RuntimeDefault`/`Localhost` seccomp profile, a restricted volume-type list, no host namespaces, and no privileged containers. Read-only root filesystem is deliberately excluded because too many legitimate images cannot satisfy it without modification.

Proof, in one command:

```console
$ kubectl label ns demo pod-security.kubernetes.io/enforce=restricted --overwrite
namespace/demo labeled

$ kubectl run probe -n demo --image=busybox:1.36 --restart=Never \
    --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":1000,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"probe","image":"busybox:1.36","command":["sleep","3600"],"securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}'
pod/probe created

$ kubectl get pod probe -n demo -o jsonpath='{.spec.containers[0].securityContext.readOnlyRootFilesystem}{"\n"}'

$ kubectl exec -n demo probe -- sh -c 'echo pwned > /usr/bin/backdoor && ls -l /usr/bin/backdoor'
-rw-r--r--    1 1000     root             6 Aug  5 14:31 /usr/bin/backdoor
```

A pod that fully satisfies `restricted` just wrote into `/usr/bin`. Closing that gap is what the next section is for.

### 5.2 ValidatingAdmissionPolicy (CEL) — the built-in answer

`admissionregistration.k8s.io/v1` is GA since v1.30. Prefer this over a webhook: it runs in-process in the API server, adds no availability dependency, and cannot fail-open due to a crashed policy pod.

```yaml
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: require-container-immutability.security.example.com
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - apiGroups:   [""]
        apiVersions: ["v1"]
        operations:  ["CREATE", "UPDATE"]
        resources:   ["pods"]
  matchConditions:
    # Ephemeral containers arrive via the pods/ephemeralcontainers
    # subresource, which this rule does not match — deliberately.
    # Debug containers MUST stay writable; gate them with RBAC instead.
    - name: skip-system-namespaces
      expression: >-
        !(request.namespace in ['kube-system', 'kube-node-lease', 'kube-public'])
  variables:
    - name: workloadContainers
      expression: >-
        object.spec.containers +
        (has(object.spec.initContainers) ? object.spec.initContainers : [])
    - name: offendersRootFS
      expression: >-
        variables.workloadContainers.filter(c,
          !has(c.securityContext) ||
          !has(c.securityContext.readOnlyRootFilesystem) ||
          c.securityContext.readOnlyRootFilesystem != true
        ).map(c, c.name)
    - name: offendersDigest
      expression: >-
        variables.workloadContainers.filter(c,
          !c.image.contains('@sha256:')
        ).map(c, c.name)
    - name: offendersVolumes
      expression: >-
        (has(object.spec.volumes) ? object.spec.volumes : []).filter(v,
          has(v.hostPath)
        ).map(v, v.name)
  validations:
    - expression: "size(variables.offendersRootFS) == 0"
      messageExpression: >-
        'containers must set securityContext.readOnlyRootFilesystem: true — offending containers: '
        + variables.offendersRootFS.join(', ')
      reason: Forbidden
    - expression: "size(variables.offendersDigest) == 0"
      messageExpression: >-
        'container images must be pinned by digest (repo@sha256:...) — offending containers: '
        + variables.offendersDigest.join(', ')
      reason: Forbidden
    - expression: "size(variables.offendersVolumes) == 0"
      messageExpression: >-
        'hostPath volumes defeat container immutability — offending volumes: '
        + variables.offendersVolumes.join(', ')
      reason: Forbidden
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: require-container-immutability-binding
spec:
  policyName: require-container-immutability.security.example.com
  # Audit first, then add Deny. Rolling this out Deny-first will page you.
  validationActions: ["Deny", "Audit"]
  matchResources:
    namespaceSelector:
      matchExpressions:
        - key: security.example.com/immutability
          operator: In
          values: ["enforce"]
```

Staged rollout — the only responsible way to ship this:

```console
# Phase 1: observe only. Nothing is blocked; violations land in the audit log.
$ kubectl patch validatingadmissionpolicybinding require-container-immutability-binding \
    --type=json -p='[{"op":"replace","path":"/spec/validationActions","value":["Audit","Warn"]}]'
validatingadmissionpolicybinding.admissionregistration.k8s.io/require-container-immutability-binding patched

# Phase 2: count violations from the API server audit log.
$ sudo jq -r 'select(.annotations["validation.policy.admission.k8s.io/validation_failure"] != null)
    | .objectRef.namespace' /var/log/kubernetes/audit.log | sort | uniq -c | sort -rn
     43 legacy-batch
     11 observability
      2 payments

# Phase 3: flip to Deny only for namespaces that are already at zero.
```

Verify it bites:

```console
$ kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: mutable
  namespace: payments
spec:
  containers:
    - name: app
      image: busybox:1.36
      command: ["sleep", "3600"]
EOF
Error from server (Forbidden): error when creating "STDIN": pods "mutable" is forbidden: ValidatingAdmissionPolicy 'require-container-immutability.security.example.com' with binding 'require-container-immutability-binding' denied request: containers must set securityContext.readOnlyRootFilesystem: true — offending containers: app
```

### 5.3 Kyverno — when you also want *mutation* and image verification

CEL policies can only validate. Kyverno can inject the field for you (enormous for brownfield migrations) and can verify signatures, which VAP cannot.

```yaml
---
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: container-immutability
  annotations:
    policies.kyverno.io/title: Enforce container runtime immutability
    policies.kyverno.io/severity: high
spec:
  validationFailureAction: Enforce
  background: true
  rules:
    # ── 1. Mutate: default the field in, so teams opt OUT rather than IN ──
    - name: default-read-only-root-filesystem
      match:
        any:
          - resources:
              kinds: ["Pod"]
      exclude:
        any:
          - resources:
              namespaces: ["kube-system", "kube-node-lease", "kube-public"]
          - resources:
              annotations:
                security.example.com/immutability-exception: "approved"
      mutate:
        foreach:
          - list: "request.object.spec.containers"
            patchStrategicMerge:
              spec:
                containers:
                  - name: "{{ element.name }}"
                    securityContext:
                      readOnlyRootFilesystem: true
          - list: "request.object.spec.[initContainers][]"
            patchStrategicMerge:
              spec:
                initContainers:
                  - name: "{{ element.name }}"
                    securityContext:
                      readOnlyRootFilesystem: true

    # ── 2. Validate: no hostPath, ever ───────────────────────────────────
    - name: block-hostpath
      match:
        any:
          - resources:
              kinds: ["Pod"]
      validate:
        message: "hostPath volumes are forbidden; they bypass container immutability entirely."
        foreach:
          - list: "request.object.spec.[volumes][]"
            deny:
              conditions:
                any:
                  - key: "{{ element.keys(@).contains('hostPath') }}"
                    operator: Equals
                    value: true

    # ── 3. Validate: image immutability by digest ─────────────────────────
    - name: require-digest-pinning
      match:
        any:
          - resources:
              kinds: ["Pod"]
      validate:
        message: "Images must be referenced by digest: {{ element.image }}"
        foreach:
          - list: "request.object.spec.containers"
            deny:
              conditions:
                all:
                  - key: "{{ regex_match('^.+@sha256:[a-f0-9]{64}$', '{{ element.image }}') }}"
                    operator: Equals
                    value: false

    # ── 4. Verify: only signed images run (VAP cannot do this) ────────────
    - name: verify-cosign-signature
      match:
        any:
          - resources:
              kinds: ["Pod"]
              namespaces: ["payments"]
      verifyImages:
        - imageReferences:
            - "ghcr.io/example/*"
          # Rewrite the tag to the verified digest — belt and braces.
          mutateDigest: true
          verifyDigest: true
          required: true
          attestors:
            - count: 1
              entries:
                - keyless:
                    subject: "https://github.com/example/*/.github/workflows/release.yaml@refs/heads/main"
                    issuer: "https://token.actions.githubusercontent.com"
                    rekor:
                      url: https://rekor.sigstore.dev
```

**Design warning.** A mutating webhook that *silently* adds `readOnlyRootFilesystem: true` will break workloads at runtime rather than at `kubectl apply` time — the pod is admitted, then `CrashLoopBackOff`s. Run rule 1 in `Audit` for a full release cycle and publish the diff to owning teams before enforcing.

### 5.4 OPA Gatekeeper equivalent

```yaml
---
apiVersion: templates.gatekeeper.sh/v1
kind: ConstraintTemplate
metadata:
  name: k8srequirereadonlyrootfilesystem
spec:
  crd:
    spec:
      names:
        kind: K8sRequireReadOnlyRootFilesystem
      validation:
        openAPIV3Schema:
          type: object
          properties:
            exemptImages:
              type: array
              items: { type: string }
  targets:
    - target: admission.k8s.gatekeeper.sh
      rego: |
        package k8srequirereadonlyrootfilesystem

        violation[{"msg": msg}] {
          c := input_containers[_]
          not exempt(c.image)
          not c.securityContext.readOnlyRootFilesystem == true
          msg := sprintf(
            "container <%v> must set securityContext.readOnlyRootFilesystem: true",
            [c.name])
        }

        input_containers[c] { c := input.review.object.spec.containers[_] }
        input_containers[c] { c := input.review.object.spec.initContainers[_] }

        exempt(image) {
          prefix := input.parameters.exemptImages[_]
          startswith(image, trim_suffix(prefix, "*"))
        }
---
apiVersion: constraints.gatekeeper.sh/v1beta1
kind: K8sRequireReadOnlyRootFilesystem
metadata:
  name: require-read-only-root-filesystem
spec:
  enforcementAction: deny
  match:
    kinds:
      - apiGroups: [""]
        kinds: ["Pod"]
    excludedNamespaces: ["kube-system", "gatekeeper-system"]
  parameters:
    exemptImages:
      - "registry.k8s.io/apparmor-loader*"
```

### 5.5 Image immutability at the API-server level

Enable `AlwaysPullImages` in the kube-apiserver static pod manifest (`/etc/kubernetes/manifests/kube-apiserver.yaml`):

```yaml
spec:
  containers:
    - name: kube-apiserver
      command:
        - kube-apiserver
        - --enable-admission-plugins=NodeRestriction,AlwaysPullImages,ValidatingAdmissionPolicy
        - --audit-policy-file=/etc/kubernetes/audit/policy.yaml
        - --audit-log-path=/var/log/kubernetes/audit.log
        # ... remaining flags unchanged
```

`AlwaysPullImages` overwrites every container's `imagePullPolicy` to `Always`. Its security value is not freshness — it is that a pod in namespace A can no longer *use* an image cached on the node by a pod in namespace B whose pull secret it does not possess. Without it, node-local image cache is a cross-tenant confidentiality leak.

Confirm it took effect:

```console
$ kubectl -n kube-system get pod kube-apiserver-cp-1 \
    -o jsonpath='{.spec.containers[0].command}' | tr ',' '\n' | grep enable-admission
"--enable-admission-plugins=NodeRestriction,AlwaysPullImages,ValidatingAdmissionPolicy"

$ kubectl run t --image=busybox:1.36 --restart=Never --command -- sleep 60
pod/t created
$ kubectl get pod t -o jsonpath='{.spec.containers[0].imagePullPolicy}{"\n"}'
Always
```

Trade-off, explicitly: `AlwaysPullImages` couples pod startup to registry availability. A registry outage now blocks *every* pod restart cluster-wide, including during a node failure when you most need capacity. Mitigate with a pull-through cache registry inside the cluster, and understand that this is a real availability cost paid for a real confidentiality gain.

### 5.6 The default `imagePullPolicy` rule, which surprises everyone

| Image reference | `imagePullPolicy` omitted → |
|---|---|
| `nginx:1.27.4` | `IfNotPresent` |
| `nginx:latest` | `Always` |
| `nginx` (no tag) | `Always` |
| `nginx@sha256:…` | `IfNotPresent` |

Digest-pinned images default to `IfNotPresent` — correctly, since the content is immutable by definition. `AlwaysPullImages` overrides all of the above.

### 5.7 Removing human-driven drift with RBAC

The overwhelmingly most common cause of container drift in real clusters is not an attacker. It is an SRE fixing something at 03:00.

```yaml
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: workload-viewer
rules:
  - apiGroups: [""]
    resources: ["pods", "pods/log", "pods/status", "services", "configmaps", "events"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["apps"]
    resources: ["deployments", "replicasets", "statefulsets", "daemonsets"]
    verbs: ["get", "list", "watch"]
  # NOTE the deliberate absences:
  #   pods/exec               – interactive shell into a running container
  #   pods/attach             – attach to PID 1
  #   pods/ephemeralcontainers – kubectl debug
  #   pods/portforward        – tunnel to a pod-local service
  # These are the four verbs that turn a read-only operator into one who
  # can mutate a running container. Grant them via a separate, audited,
  # time-boxed break-glass binding.
```

Audit who currently holds them:

```console
$ kubectl get clusterrolebindings,rolebindings -A -o json | jq -r '
  .items[] | . as $b |
  $b.subjects[]? |
  "\($b.kind)/\($b.metadata.name)\t\(.kind)/\(.name)"' | sort -u > /tmp/bindings

$ kubectl get clusterroles,roles -A -o json | jq -r '
  .items[] | select(.rules[]?.resources[]? | test("pods/(exec|attach|ephemeralcontainers)")) |
  "\(.kind)/\(.metadata.name)"'
ClusterRole/cluster-admin
ClusterRole/admin
ClusterRole/edit
ClusterRole/debug-breakglass
```

Then confirm the audit policy records every use:

```yaml
# /etc/kubernetes/audit/policy.yaml
apiVersion: audit.k8s.io/v1
kind: Policy
omitStages: ["RequestReceived"]
rules:
  # Any mutation of a running container is a Metadata-level event at minimum.
  - level: RequestResponse
    resources:
      - group: ""
        resources: ["pods/exec", "pods/attach", "pods/portforward", "pods/ephemeralcontainers"]
  - level: Metadata
    resources:
      - group: ""
        resources: ["secrets", "configmaps"]
  - level: Metadata
    omitStages: ["RequestReceived"]
```

---

## 6. Runtime detection: what admission cannot see

Admission control is a one-shot gate at `t=0`. Everything after that is the runtime sensor's job.

### 6.1 Falco drift rules

Falco's upstream ruleset ships the relevant detections; in recent releases the drift rules live in the `falco-incubating` ruleset and must be explicitly loaded:

```yaml
# /etc/falco/falco.yaml (excerpt)
rules_files:
  - /etc/falco/falco_rules.yaml
  - /etc/falco/falco-incubating_rules.yaml   # contains the drift rules
  - /etc/falco/rules.d                       # our overrides, loaded last

# Prefer the modern eBPF (CO-RE) driver over the kernel module.
engine:
  kind: modern_ebpf
  modern_ebpf:
    cpus_for_each_buffer: 2
```

Custom rules that encode *your* immutability contract:

```yaml
# /etc/falco/rules.d/immutability.yaml
---
- list: immutable_namespaces
  items: [payments, checkout, ledger]

- macro: in_immutable_workload
  condition: (k8s.ns.name in (immutable_namespaces))

- macro: declared_writable_path
  condition: >
    (fd.name startswith /tmp/ or
     fd.name startswith /var/cache/nginx/ or
     fd.name startswith /var/run/ or
     fd.name startswith /dev/stdout or
     fd.name startswith /dev/stderr or
     fd.name startswith /dev/termination-log or
     fd.name startswith /proc/self/)

- rule: Write outside declared writable paths in immutable workload
  desc: >
    A container in an immutability-enforced namespace opened a file for
    writing outside the emptyDir mounts declared in its PodSpec. With
    readOnlyRootFilesystem this should be impossible for the root fs, so a
    hit means either a misdeclared volume or an unexpected writable mount.
  condition: >
    open_write
    and container
    and in_immutable_workload
    and not declared_writable_path
  output: >
    Unexpected write in immutable workload
    (file=%fd.name evt=%evt.type proc=%proc.name cmdline=%proc.cmdline
     user=%user.name uid=%user.uid parent=%proc.pname
     container_id=%container.id image=%container.image.repository
     k8s_ns=%k8s.ns.name k8s_pod=%k8s.pod.name)
  priority: WARNING
  tags: [container, filesystem, immutability, mitre_persistence, T1543]

- rule: New executable created inside container
  desc: >
    A file was created and made executable inside a container. This is the
    canonical "drop a tool and chmod +x" step (MITRE T1105 -> T1059).
  condition: >
    chmod
    and container
    and (evt.arg.mode contains "S_IXUSR" or
         evt.arg.mode contains "S_IXGRP" or
         evt.arg.mode contains "S_IXOTH")
    and not proc.name in (dpkg, rpm, apk, pip, npm)
  output: >
    File made executable inside container
    (file=%evt.arg.filename mode=%evt.arg.mode proc=%proc.name
     cmdline=%proc.cmdline container_id=%container.id
     image=%container.image.repository k8s_ns=%k8s.ns.name k8s_pod=%k8s.pod.name)
  priority: CRITICAL
  tags: [container, filesystem, mitre_execution, T1105]

- rule: Fileless execution via memfd
  desc: >
    Execution from an anonymous memory file descriptor. Defeats
    readOnlyRootFilesystem, AppArmor path rules and SELinux file contexts,
    because no path is ever touched (MITRE T1620).
  condition: >
    spawned_process
    and container
    and proc.exepath startswith "memfd:"
  output: >
    Fileless execution detected
    (exepath=%proc.exepath proc=%proc.name cmdline=%proc.cmdline
     parent=%proc.pname user=%user.name container_id=%container.id
     image=%container.image.repository k8s_ns=%k8s.ns.name k8s_pod=%k8s.pod.name)
  priority: CRITICAL
  tags: [container, process, mitre_defense_evasion, T1620]
```

Live output during a simulated compromise:

```console
$ kubectl exec -n payments deploy/legacy-batch -- sh -c 'cp /bin/busybox /tmp/nc && chmod +x /tmp/nc'

$ kubectl logs -n falco -l app.kubernetes.io/name=falco -c falco --tail=20 | grep -i immutab
16:04:22.951231455: Warning Unexpected write in immutable workload (file=/tmp/nc evt=openat proc=cp cmdline=cp /bin/busybox /tmp/nc user=root uid=0 parent=sh container_id=3f2b0c9a1d77 image=docker.io/library/debian k8s_ns=payments k8s_pod=legacy-batch-6c9f7d5b84-q2xzt)
16:04:22.958604112: Critical File made executable inside container (file=/tmp/nc mode=S_IXUSR|S_IXGRP|S_IXOTH|S_IRUSR|S_IRGRP|S_IROTH|S_IWUSR proc=chmod cmdline=chmod +x /tmp/nc container_id=3f2b0c9a1d77 image=docker.io/library/debian k8s_ns=payments k8s_pod=legacy-batch-6c9f7d5b84-q2xzt)
```

Note that this fired on a `/tmp` write — the exact surface `readOnlyRootFilesystem` cannot cover. That is the division of labour between the two controls, demonstrated.

Upstream rules worth enabling by name, rather than rewriting:

| Falco rule | Detects |
|---|---|
| `Drop and execute new binary in container` | A binary not present in the image being executed |
| `Container Drift Detected (open+create)` | `O_CREAT` on a path that did not exist in the image |
| `Container Drift Detected (chmod)` | `chmod +x` on a container file |
| `Write below binary dir` | Writes under `/bin`, `/sbin`, `/usr/bin`, `/usr/sbin` |
| `Write below etc` | Configuration tampering |
| `Fileless execution via memfd_create` | `memfd`-based execution |
| `Launch Package Management Process in Container` | `apt`/`yum`/`apk` at runtime |

### 6.2 Offline drift detection: diff the overlay upper directory

Falco is a stream. Sometimes you need a point-in-time answer to "has this container diverged from its image?" — the `docker diff` equivalent, which `crictl` does not provide. Read containerd's snapshotter directly on the node:

```console
$ CID=$(sudo crictl ps -q --name legacy-batch --state Running | head -1)
$ echo "$CID"
3f2b0c9a1d7742a9f0b3e8c1d6a5b4c3928170e6f5d4c3b2a1908f7e6d5c4b3a

$ SNAP=$(sudo ctr -n k8s.io containers info "$CID" | jq -r '.SnapshotKey')
$ echo "$SNAP"
3f2b0c9a1d7742a9f0b3e8c1d6a5b4c3928170e6f5d4c3b2a1908f7e6d5c4b3a

$ UPPER=$(sudo ctr -n k8s.io snapshots mounts /tmp/inspect "$SNAP" \
          | tr ',' '\n' | sed -n 's/^upperdir=//p')
$ echo "$UPPER"
/var/lib/containerd/io.containerd.snapshotter.v1.overlayfs/snapshots/2417/fs

# Everything below is a divergence from the image layers.
$ sudo find "$UPPER" -mindepth 1 \( -type f -o -type l \) -printf '%M %10s %TY-%Tm-%Td %TH:%TM %P\n'
-rw-r--r--      12288 2026-08-05 16:01 var/lib/dpkg/lock-frontend
-rwxr-xr-x    1183448 2026-08-05 16:04 usr/bin/nc
-rw-r--r--        842 2026-08-05 16:05 etc/cron.d/sync
-rw-r--r--       4096 2026-08-05 15:58 var/log/app.log

# Whiteout entries (character device, 0/0) mark files DELETED from the image.
$ sudo find "$UPPER" -type c -printf '%P\n'
usr/bin/apt
etc/ssl/certs/ca-certificates.crt
```

`usr/bin/nc`, `etc/cron.d/sync`, and a deleted CA bundle: this container is compromised. Two files (`var/lib/dpkg/lock-frontend`, `var/log/app.log`) are benign but would have been prevented outright by `readOnlyRootFilesystem` plus an `emptyDir` at `/var/log`.

Fleet-wide sweep, as a node DaemonSet or an SSH loop:

```console
$ for cid in $(sudo crictl ps -q); do
    name=$(sudo crictl inspect "$cid" | jq -r '.status.metadata.name')
    ns=$(sudo crictl inspect "$cid" | jq -r '.status.labels["io.kubernetes.pod.namespace"]')
    ro=$(sudo crictl inspect "$cid" | jq -r '.info.runtimeSpec.root.readonly')
    snap=$(sudo ctr -n k8s.io containers info "$cid" 2>/dev/null | jq -r '.SnapshotKey')
    upper=$(sudo ctr -n k8s.io snapshots mounts /tmp/x "$snap" 2>/dev/null | tr ',' '\n' | sed -n 's/^upperdir=//p')
    n=$( [ -n "$upper" ] && sudo find "$upper" -mindepth 1 -type f 2>/dev/null | wc -l || echo "?" )
    printf '%-16s %-28s ro=%-5s drifted_files=%s\n' "$ns" "$name" "$ro" "$n"
  done
kube-system      kube-proxy                   ro=false drifted_files=3
payments         nginx                        ro=true  drifted_files=0
payments         legacy-batch                 ro=false drifted_files=417
observability    otel-collector               ro=true  drifted_files=0
```

`drifted_files=417` on `legacy-batch` is your remediation backlog, ranked.

---

## 7. Verification and failure diagnosis

### 7.1 Fleet-wide compliance audit

```console
$ kubectl get pods -A -o json | jq -r '
  .items[] as $p |
  ($p.spec.containers + ($p.spec.initContainers // []))[] |
  select((.securityContext.readOnlyRootFilesystem // false) != true) |
  [$p.metadata.namespace, $p.metadata.name, .name, .image] | @tsv' \
  | column -t -s $'\t' | head -20
observability  loki-0                        loki       grafana/loki:3.4.1
observability  promtail-mn4kd                promtail   grafana/promtail:3.4.1
payments       legacy-batch-6c9f7d5b84-q2xzt app        docker.io/library/debian:12
kube-system    coredns-6f9d84b7c9-w2hnp      coredns    registry.k8s.io/coredns/coredns:v1.12.0
```

Aggregate by owning workload rather than by pod, so the report maps to teams:

```console
$ kubectl get pods -A -o json | jq -r '
  .items[] as $p |
  ($p.metadata.ownerReferences[0].name // $p.metadata.name) as $owner |
  ($p.spec.containers + ($p.spec.initContainers // []))[] |
  select((.securityContext.readOnlyRootFilesystem // false) != true) |
  "\($p.metadata.namespace)/\($owner)"' | sort | uniq -c | sort -rn
     12 observability/promtail
      6 payments/legacy-batch-6c9f7d5b84
      2 kube-system/coredns-6f9d84b7c9
```

Compact per-container view:

```console
$ kubectl get pods -n payments -o custom-columns=\
'POD:.metadata.name,CONTAINER:.spec.containers[*].name,RO_ROOTFS:.spec.containers[*].securityContext.readOnlyRootFilesystem,PRIVESC:.spec.containers[*].securityContext.allowPrivilegeEscalation,IMAGE:.spec.containers[*].image'
POD                             CONTAINER   RO_ROOTFS   PRIVESC   IMAGE
edge-5b8f7c9d64-4nfgm           nginx       true        false     docker.io/nginxinc/nginx-unprivileged@sha256:9f7cd4d4...
edge-5b8f7c9d64-7xk2p           nginx       true        false     docker.io/nginxinc/nginx-unprivileged@sha256:9f7cd4d4...
legacy-batch-6c9f7d5b84-q2xzt   app         <none>      <none>    docker.io/library/debian:12
```

### 7.2 Positive verification — prove enforcement, don't infer it

Never accept a green field in the spec as proof. Test the behaviour:

```console
# 1. The API server thinks it is set.
$ kubectl get pod -n payments -l app.kubernetes.io/name=edge \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].securityContext.readOnlyRootFilesystem}{"\n"}{end}'
edge-5b8f7c9d64-4nfgm	true
edge-5b8f7c9d64-7xk2p	true
edge-5b8f7c9d64-9pmr8	true

# 2. The kernel agrees.
$ kubectl exec -n payments deploy/edge -c nginx -- grep -m1 ' / ' /proc/self/mountinfo
1877 1876 0:143 / / ro,relatime master:412 - overlay overlay rw,lowerdir=...

# 3. A write actually fails.
$ kubectl exec -n payments deploy/edge -c nginx -- sh -c 'touch /usr/bin/backdoor'
touch: /usr/bin/backdoor: Read-only file system
command terminated with exit code 1

# 4. The declared writable island actually works.
$ kubectl exec -n payments deploy/edge -c nginx -- sh -c 'touch /tmp/probe && ls -l /tmp/probe'
-rw-r--r--    1 nginx    nginx            0 Aug  5 16:11 /tmp/probe

# 5. tmpfs sizeLimit is really applied as the mount option.
$ kubectl exec -n payments deploy/edge -c nginx -- sh -c 'grep " /tmp " /proc/self/mountinfo'
1901 1877 0:152 / /tmp rw,relatime - tmpfs tmpfs rw,size=65536k,inode64

# 6. Capabilities and no-new-privs.
$ kubectl exec -n payments deploy/edge -c nginx -- grep -E 'CapEff|NoNewPrivs' /proc/self/status
NoNewPrivs:	1
CapEff:	0000000000000000

# 7. seccomp mode 2 (filtered).
$ kubectl exec -n payments deploy/edge -c nginx -- grep Seccomp /proc/self/status
Seccomp:	2
Seccomp_filters:	1
```

`CapEff: 0000000000000000` and `Seccomp: 2` are the two lines to look for. Anything else and the securityContext did not take effect the way you think.

### 7.3 Debugging a distroless, read-only container

You cannot `kubectl exec` — there is no shell. Ephemeral containers share the target's namespaces without modifying it:

```console
$ kubectl debug -n payments -it edge-5b8f7c9d64-4nfgm \
    --image=nicolaka/netshoot:v0.13 \
    --target=nginx \
    --profile=general \
    -- bash
Targeting container "nginx". If you don't see processes from this container it may be because the container runtime doesn't support this feature.
Defaulting debug container name to debugger-x7k2m.
If you don't see a command prompt, try pressing enter.

debugger:~# ps aux
PID   USER     TIME  COMMAND
    1 101       0:00 nginx: master process nginx -g daemon off; -c /etc/nginx/nginx.conf
   29 101       0:00 nginx: worker process
   47 root      0:00 bash
   58 root      0:00 ps aux

# The target's root filesystem, reachable through /proc
debugger:~# ls -la /proc/1/root/usr/share/nginx/html
total 16
drwxr-xr-x    2 root  root  4096 Jan 14 00:00 .
drwxr-xr-x    3 root  root  4096 Jan 14 00:00 ..
-rw-r--r--    1 root  root   497 Jan 14 00:00 50x.html
-rw-r--r--    1 root  root   615 Jan 14 00:00 index.html

# The target's mount flags, from outside the target
debugger:~# grep -E ' / | /tmp ' /proc/1/mountinfo
1877 1876 0:143 / / ro,relatime master:412 - overlay overlay rw,lowerdir=...
1901 1877 0:152 / /tmp rw,relatime - tmpfs tmpfs rw,size=65536k,inode64

# Confirm the debug container itself is a separate, writable filesystem —
# this is why the VAP in 5.2 deliberately excludes ephemeral containers.
debugger:~# touch /root/scratch && echo ok
ok
```

Two prerequisites people miss:

- `--target` requires the CRI to support process-namespace targeting. containerd ≥ 1.4 and CRI-O support it; if the flag is silently ignored, you will only see the debug container's own PID 1.
- `--profile=general` (or `restricted`, `netadmin`, `sysadmin`) controls the debug container's securityContext. Under a `restricted` PSA namespace, the default profile may be rejected — use `--profile=restricted`.

### 7.4 Finding every path a workload writes to, before enforcing

The migration question is always "which directories does this thing actually write?" Three techniques, in order of preference:

**(a) Local reproduction — fastest, no cluster involved.**

```console
$ docker run --rm --read-only \
    --tmpfs /tmp:rw,noexec,nosuid,size=64m \
    -p 8080:8080 \
    docker.io/nginxinc/nginx-unprivileged:1.27.4-alpine
2026/08/05 16:20:41 [emerg] 1#1: mkdir() "/var/cache/nginx/client_temp" failed (30: Read-only file system)
nginx: [emerg] mkdir() "/var/cache/nginx/client_temp" failed (30: Read-only file system)

$ docker run --rm --read-only \
    --tmpfs /tmp:rw,noexec,nosuid,size=64m \
    --tmpfs /var/cache/nginx:rw,size=32m \
    docker.io/nginxinc/nginx-unprivileged:1.27.4-alpine
2026/08/05 16:21:12 [emerg] 1#1: open() "/tmp/nginx.pid" failed (2: No such file or directory)
```

Iterate until it boots. Each `EROFS` names exactly one directory to add.

**(b) Overlay upperdir diff after a representative run** — §6.2. This catches paths that a synthetic smoke test never exercises, such as a once-a-day log rotation.

**(c) Syscall tracing, when (a) and (b) disagree.**

```console
$ kubectl debug -n payments -it legacy-batch-6c9f7d5b84-q2xzt \
    --image=nicolaka/netshoot:v0.13 --target=app \
    --profile=sysadmin -- bash

debugger:~# strace -f -qq -e trace=creat,open,openat,mkdir,unlink,rename -p 1 2>&1 \
              | grep -vE 'O_RDONLY|ENOENT' | awk -F'"' '{print $2}' | sort -u
/var/log/app/audit.log
/var/lib/app/session.db
/run/app.pid
```

`--profile=sysadmin` grants `SYS_PTRACE`, which `strace` requires. Use it in a staging namespace; do not leave a binding that permits it in production.

### 7.5 Failure signature reference

| Symptom | errno / event | Root cause | Remediation |
|---|---|---|---|
| `Read-only file system` in logs, `CrashLoopBackOff` | `EROFS` (30) | Write to the read-only rootfs | Mount an `emptyDir` at that path, or relocate the write via config |
| `Permission denied` on a mounted `emptyDir` | `EACCES` (13) | `runAsNonRoot` + volume owned by root | Set `securityContext.fsGroup`; add `fsGroupChangePolicy: OnRootMismatch` to avoid a full recursive chown on every start |
| `No space left on device` on a tmpfs mount | `ENOSPC` (28) | Memory-backed `emptyDir` `sizeLimit` too small | Raise `sizeLimit` **and** `resources.limits.memory` together |
| Pod status `Evicted`, message `… exceeds the local ephemeral storage limit` | eviction | Disk-backed `emptyDir` over `sizeLimit`, detected at ~10 s housekeeping | Raise `sizeLimit`; move genuine state to a PVC |
| Pod `OOMKilled` shortly after heavy temp I/O | cgroup OOM | tmpfs pages charged to the container memory limit | Include the tmpfs `sizeLimit` in `limits.memory` |
| `CreateContainerError`, `apparmor profile is not loaded` | kubelet | Profile referenced but absent on that node | Deploy the loader DaemonSet; add a `nodeAffinity` or wait for the loader to be Ready |
| `container has runAsNonRoot and image will run as root` | kubelet | Image `USER` is root or numeric UID unresolvable | Set a numeric `runAsUser`; fix the Dockerfile `USER` |
| Pod never created; `kubectl apply` of a **Deployment** succeeds | admission | VAP/webhook denies the **Pod**, not the Deployment | `kubectl describe rs` — see below |
| Falco silent after node kernel upgrade | driver | Kernel module / eBPF probe mismatch | Switch `engine.kind: modern_ebpf` (CO-RE, no per-kernel driver) |

The Deployment/Pod indirection is worth its own worked example, because it is the single most confusing operational consequence of pod-level admission policy:

```console
$ kubectl apply -f deploy-noncompliant.yaml
deployment.apps/legacy-batch created           # <-- succeeds!

$ kubectl get deploy legacy-batch -n payments
NAME           READY   UP-TO-DATE   AVAILABLE   AGE
legacy-batch   0/3     0            0           24s

$ kubectl describe rs -n payments -l app=legacy-batch | tail -8
Events:
  Type     Reason        Age                From                   Message
  ----     ------        ----               ----                   -------
  Warning  FailedCreate  22s (x4 over 24s)  replicaset-controller  Error creating: pods "legacy-batch-6c9f7d5b84-" is forbidden: ValidatingAdmissionPolicy 'require-container-immutability.security.example.com' with binding 'require-container-immutability-binding' denied request: containers must set securityContext.readOnlyRootFilesystem: true — offending containers: app
  Warning  FailedCreate  12s (x3 over 20s)  replicaset-controller  (combined from similar events): Error creating: pods "legacy-batch-6c9f7d5b84-" is forbidden: ...
```

Mitigate the UX cost by adding `Warn` to `validationActions` — the API server then returns a warning header on the *Deployment* apply, which `kubectl` prints immediately:

```console
$ kubectl apply -f deploy-noncompliant.yaml
Warning: ValidatingAdmissionPolicy 'require-container-immutability.security.example.com' ... containers must set securityContext.readOnlyRootFilesystem: true — offending containers: app
deployment.apps/legacy-batch created
```

### 7.6 A migration playbook that has survived contact with real teams

1. **Measure.** Run the §7.1 audit; publish counts per owning team, not per pod.
2. **Observe.** Bind the VAP with `validationActions: ["Audit","Warn"]`. Nothing breaks. Collect two weeks of data.
3. **Discover write paths** per workload with §7.4(a) and (b). Produce a PR per workload that adds the `emptyDir` mounts *and* `readOnlyRootFilesystem: true` in the same commit — never separately, or you ship a broken intermediate state.
4. **Canary.** One replica, `maxUnavailable: 0`, real traffic, 24 h. Watch for `EROFS` in logs and pod restart counts, not just readiness.
5. **Enforce per namespace.** Flip the binding to `Deny` only for namespaces already at zero violations. The `namespaceSelector` in §5.2 makes this a single label change.
6. **Detect the remainder.** Workloads with a signed exception annotation get compensating Falco coverage from §6.1 and a review date.
7. **Ratchet.** A quarterly job that fails CI if the exception list grew.

---

## 8. Exam-day quick reference

```console
# Add readOnlyRootFilesystem to an existing deployment, imperatively.
$ kubectl patch deploy edge -n payments --type=json -p='[
    {"op":"add","path":"/spec/template/spec/containers/0/securityContext/readOnlyRootFilesystem","value":true}
  ]'
deployment.apps/edge patched

# If securityContext does not exist yet, create the whole object first.
$ kubectl patch deploy edge -n payments --type=json -p='[
    {"op":"add","path":"/spec/template/spec/containers/0/securityContext",
     "value":{"readOnlyRootFilesystem":true,"allowPrivilegeEscalation":false,
              "capabilities":{"drop":["ALL"]}}}
  ]'

# Add the writable emptyDir in one shot.
$ kubectl patch deploy edge -n payments --type=json -p='[
    {"op":"add","path":"/spec/template/spec/volumes","value":[{"name":"tmp","emptyDir":{"medium":"Memory","sizeLimit":"64Mi"}}]},
    {"op":"add","path":"/spec/template/spec/containers/0/volumeMounts","value":[{"name":"tmp","mountPath":"/tmp"}]}
  ]'

# Field reference, straight from the API server — no internet needed.
$ kubectl explain pod.spec.containers.securityContext.readOnlyRootFilesystem
KIND:       Pod
VERSION:    v1

FIELD: readOnlyRootFilesystem <boolean>

DESCRIPTION:
    Whether this container has a read-only root filesystem. Default is false.
    Note that this field cannot be set when spec.os.name is windows.

$ kubectl explain pod.spec.volumes.emptyDir
```

Six facts that decide the question:

1. `readOnlyRootFilesystem` lives on the **container** `securityContext`, never the pod-level one. There is no pod-wide equivalent.
2. It must be set on **initContainers** too. Auditors and policies check them; people forget them.
3. It affects the **root filesystem only**. Mounted volumes remain writable unless you also set `readOnly: true` on the `volumeMount`.
4. `configMap`, `secret`, `downwardAPI` and `projected` volumes are **always** mounted read-only.
5. PSS `restricted` does **not** require it.
6. It cannot be set when `spec.os.name: windows`.

---

## 9. References

**Official Kubernetes documentation**

- Configure a Security Context for a Pod or Container — https://kubernetes.io/docs/tasks/configure-pod-container/security-context/
- Security Context API reference (`SecurityContext` v1) — https://kubernetes.io/docs/reference/kubernetes-api/workload-resources/pod-v1/#security-context
- Pod Security Standards — https://kubernetes.io/docs/concepts/security/pod-security-standards/
- Pod Security Admission — https://kubernetes.io/docs/concepts/security/pod-security-admission/
- Volumes: `emptyDir` — https://kubernetes.io/docs/concepts/storage/volumes/#emptydir
- Local ephemeral storage and `sizeLimit` — https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/#local-ephemeral-storage
- Images and `imagePullPolicy` defaults — https://kubernetes.io/docs/concepts/containers/images/
- Admission controllers reference (`AlwaysPullImages`, `ImagePolicyWebhook`) — https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/
- Validating Admission Policy — https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/
- Common Expression Language in Kubernetes — https://kubernetes.io/docs/reference/using-api/cel/
- Restrict a Container's Access to Resources with AppArmor — https://kubernetes.io/docs/tutorials/security/apparmor/
- Restrict a Container's Syscalls with seccomp — https://kubernetes.io/docs/tutorials/security/seccomp/
- Assign SELinux labels to a container — https://kubernetes.io/docs/tasks/configure-pod-container/security-context/#assign-selinux-labels-to-a-container
- Immutable ConfigMaps and Secrets — https://kubernetes.io/docs/concepts/configuration/configmap/#configmap-immutable
- Ephemeral Containers — https://kubernetes.io/docs/concepts/workloads/pods/ephemeral-containers/
- Debug Running Pods (`kubectl debug`) — https://kubernetes.io/docs/tasks/debug/debug-application/debug-running-pod/
- Auditing — https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/
- RBAC Authorization — https://kubernetes.io/docs/reference/access-authn-authz/rbac/
- Security Checklist — https://kubernetes.io/docs/concepts/security/security-checklist/

**CNCF / certification**

- CKS Curriculum v1.34 (PDF) — https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
- CNCF curriculum repository — https://github.com/cncf/curriculum
- CKS Exam Program — https://training.linuxfoundation.org/certification/certified-kubernetes-security-specialist/

**Runtime, OCI and Linux internals**

- OCI Runtime Specification — `config.json` `root.readonly` — https://github.com/opencontainers/runtime-spec/blob/main/config.md#root
- OCI Runtime Spec, Linux `maskedPaths` / `readonlyPaths` — https://github.com/opencontainers/runtime-spec/blob/main/config-linux.md#masked-paths
- runc — https://github.com/opencontainers/runc
- containerd documentation — https://containerd.io/docs/
- `crictl` user guide — https://github.com/kubernetes-sigs/cri-tools/blob/master/docs/crictl.md
- Linux `overlayfs` documentation — https://www.kernel.org/doc/html/latest/filesystems/overlayfs.html
- `seccomp(2)` manual page — https://man7.org/linux/man-pages/man2/seccomp.2.html
- `memfd_create(2)` manual page — https://man7.org/linux/man-pages/man2/memfd_create.2.html
- AppArmor documentation — https://gitlab.com/apparmor/apparmor/-/wikis/Documentation

**Policy engines and runtime security**

- Falco documentation — https://falco.org/docs/
- Falco default and incubating rules — https://github.com/falcosecurity/rules
- Kyverno policy documentation — https://kyverno.io/docs/
- Kyverno policy library — https://kyverno.io/policies/
- OPA Gatekeeper — https://open-policy-agent.github.io/gatekeeper/website/docs/
- Cilium Tetragon — https://tetragon.io/docs/
- Sigstore / cosign — https://docs.sigstore.dev/

**Hardening guidance and threat models**

- NSA/CISA Kubernetes Hardening Guide — https://media.defense.gov/2022/Aug/29/2003066362/-1/-1/0/CTR_KUBERNETES_HARDENING_GUIDANCE_1.2_20220829.PDF
- CIS Kubernetes Benchmark — https://www.cisecurity.org/benchmark/kubernetes
- MITRE ATT&CK for Containers — https://attack.mitre.org/matrices/enterprise/containers/
- MITRE ATT&CK T1610 / T1611 / T1105 / T1620 — https://attack.mitre.org/techniques/T1611/
- Distroless container images — https://github.com/GoogleContainerTools/distroless
- `crane` (go-containerregistry) — https://github.com/google/go-containerregistry/blob/main/cmd/crane/README.md
- `skopeo` — https://github.com/containers/skopeo