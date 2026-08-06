# LPI 030-100: Software Development Basics (Topic 1.1 / 031.1) - Advanced Production Study Guide

---

## 1. Motivation and Production Architectural Problem

At the enterprise level, the distinction between writing code and operating software at scale is defined by how foundational software development principles interact with underlying Linux kernels, execution runtimes, and container orchestrators. SRE and Platform Engineers must evaluate programming languages, execution models, software paradigms, and tooling not merely by developer ergonomics, but through the lens of **predictable tail latency (p99/p99.9)**, **resource utilization density**, **container cold-start behavior**, and **failure domain isolation**.

```
+-----------------------------------------------------------------------------------+
|                                 APPLICATION LAYER                                 |
|   Procedural / OOP / Functional Paradigms | Dependencies & Dynamic Libraries     |
+-----------------------------------------------------------------------------------+
                                         |
                                         v
+-----------------------------------------------------------------------------------+
|                             EXECUTION RUNTIME LAYER                               |
|   Native AOT Binary   |   Bytecode VM + JIT (JVM/.NET)   |   Interpreted Engine     |
|   (Direct System)     |   (Garbage Collection/JIT)       |   (Node.js/Python V8/GIL)|
+-----------------------------------------------------------------------------------+
                                         |
                                         v
+-----------------------------------------------------------------------------------+
|                        LINUX KERNEL & CONTAINER SUBSYSTEM                         |
|   cgroups v2 (Memory/CPU limits) | POSIX Signals (SIGTERM) | Virtual Memory (mmap)|
+-----------------------------------------------------------------------------------+
```

### Key Architectural Production Friction Points:

1. **Compilation vs. Interpretation vs. JIT in Cloud-Native Lifecycles**:
   - **Ahead-of-Time (AOT) Compiled Languages (C, C++, Go, Rust)** compile directly to Machine Code/ELF binaries. They present minimal memory footprints, zero runtime bootstrap overhead, and sub-millisecond container startup times, making them ideal for high-throughput microservices and Serverless/FaaS architectures.
   - **Bytecode VM / JIT Languages (Java, C#)** execute via intermediate bytecode compiled at runtime by a Just-In-Time compiler. While offering high runtime optimizations after warm-up, they introduce heavy initial memory overhead, slow startup phases (PGO/tiered compilation delays), and non-deterministic CPU spikes during compilation phases.
   - **Interpreted / Dynamic Scripting Languages (Python, PHP, JavaScript/Node.js)** execute instructions line-by-line or via single-threaded event-loop engines. They afford rapid development cycles but suffer from higher CPU execution overhead per instruction, memory bloat from dynamic typing, and single-core execution bottlenecks driven by runtime locks like Python's Global Interpreter Lock (GIL).

2. **Memory Management and Garbage Collection (GC) in Containerized Environments**:
   - Automated memory management using Garbage Collection (JVM, V8, Go runtime) abstracts heap allocation. However, under Linux kernel `cgroups v2` memory limits, if the runtime GC is not cgroup-aware, the Linux kernel Out-Of-Memory (OOM) Killer will send `SIGKILL` (Exit Code 137) to the container process before the runtime triggers its internal GC cycle.
   - Manual memory management (C/C++) eliminates GC latency jitter but requires absolute discipline to avoid memory leaks, use-after-free bugs, and heap fragmentation that leads to kernel OOM states.

3. **Software Paradigms & State Management**:
   - **Procedural**: Imperative sequential execution. Can lead to monolithic procedural sprawl and shared global state mutations that ruin concurrency scaling.
   - **Object-Oriented Programming (OOP)**: Encapsulates state and behavior within classes. Excessive class hierarchies and mutable shared objects complicate multi-threaded safety and thread-pool execution.
   - **Functional Programming (FP)**: Enforces immutability and pure, side-effect-free functions. In distributed microservices, immutable data flows eliminate race conditions without requiring coarse-grained mutex locking, enabling linear horizontal scaling across multi-core systems.

---

## 2. Technical Comparisons & Trade-offs Tables

### Table 1: Software Paradigms Comparison

| Metric / Dimension | Procedural Programming | Object-Oriented Programming (OOP) | Functional Programming (FP) |
| :--- | :--- | :--- | :--- |
| **State Mutation** | Direct, explicit local/global variable mutation. | Encapsulated mutable state within class instances. | Strict immutability; persistent data structures. |
| **Concurrency Safety** | Low; high risk of data races on global state. | Moderate; requires manual synchronization (mutexes/locks). | Inherently safe; immutable state avoids lock contention. |
| **Memory Footprint** | Minimal; low stack/heap overhead. | Higher; object metadata, vtables, pointer overhead. | Moderate-High; object allocation for immutability cycles. |
| **Testability & Mocking**| Difficult for global state; easy for linear procedures. | Moderate; relies on interfaces, dependency injection, mocks. | Superior; pure functions allow deterministic unit testing. |
| **Cloud-Native Fit** | Legacy utilities, procedural shell/C tooling. | Enterprise microservices (Java Spring, C# .NET). | High-concurrency event streaming, pipeline processing. |

### Table 2: Execution Runtimes & Compilation Models

| Dimension | Native AOT (C, Go, Rust) | Bytecode VM + JIT (Java, C#) | Interpreted / Scripting (Python, PHP, Node.js) |
| :--- | :--- | :--- | :--- |
| **Execution Binary** | Native Machine Code (ELF binary). | Intermediate Bytecode (.class, .dll). | Plaintext Source Code / AST. |
| **Startup / Cold-Start** | Instantaneous (<10ms). | Slow (1s – 10s+) due to JVM/CLR init & JIT warm-up. | Fast to Moderate (100ms – 1s). |
| **Runtime CPU Overhead**| Lowest (Direct CPU execution). | Low to Medium (Post JIT warm-up). | Highest (Interpreter loop overhead). |
| **Base Container Size** | Minimal (<15MB, `scratch` or `distroless`). | Large (150MB - 500MB with JRE). | Medium (50MB - 200MB with interpreter runtime). |
| **cgroup v2 Awareness** | Native OS interactions. | Requires modern JRE (Java 11+) to parse cgroup paths. | Node/Python rely on libuv/OS system calls. |

### Table 3: Memory Management Models in Production

| Model | Languages | Tail Latency Impact (p99) | OOM Risk Factor in K8s | SRE Operational Complexity |
| :--- | :--- | :--- | :--- | :--- |
| **Manual (malloc/free)** | C, C++ | Zero GC pauses; predictable. | High (Memory leaks degrade cgroup limit). | High (Requires Valgrind, ASan profiling). |
| **Compile-time Ownership**| Rust | Zero GC pauses; deterministic drop.| Low (Enforced at compile-time). | Moderate (High learning curve). |
| **Concurrent GC** | Go | Low GC pauses (<1ms stop-the-world).| Moderate (GOGC tuning required). | Low-Moderate (Simple runtime flags). |
| **Generational GC** | Java (G1GC/ZGC)| Periodic latency spikes (Stop-The-World).| High if JVM `-Xmx` exceeds container memory limit.| High (Requires tuning `-Xms`, `-Xmx`, GC algorithms). |
| **Reference Counting + GC**| Python, PHP | Latency jitter during cyclic collection. | Moderate (Unreleased memory under load). | Moderate (Requires memory leak profilers). |

---

## 3. Complete Production Infrastructure Manifests

### Manifest 1: Multi-Stage Production `Dockerfile`
A production-grade, hardened, multi-stage Dockerfile compiling a Go service into an AOT binary placed inside a minimal `scratch` container image.

```dockerfile
# ==========================================
# STAGE 1: Build & Compilation Environment
# ==========================================
FROM golang:1.22-alpine AS builder

# Install security updates and build tools
RUN apk update && apk add --no-cache git ca-certificates tzdata && update-ca-certificates

# Create non-privileged build user
RUN adduser -D -g "" -u 10001 appuser

WORKDIR /src

# Leverage layer caching for dependencies
COPY go.mod go.sum ./
RUN go mod download && go mod verify

# Copy source code
COPY . .

# Compile static AOT executable (CGO disabled for pure static ELF)
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build \
    -ldflags="-w -s -extldflags '-static'" \
    -o /bin/server ./cmd/api

# ==========================================
# STAGE 2: Minimal Production Runtime
# ==========================================
FROM scratch

# Copy system metadata from builder
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY --from=builder /usr/share/zoneinfo /usr/share/zoneinfo
COPY --from=builder /etc/passwd /etc/passwd
COPY --from=builder /etc/group /etc/group

# Copy compiled AOT binary
COPY --from=builder --chown=10001:10001 /bin/server /server

# Enforce non-root execution
USER 10001:10001

# Expose service port
EXPOSE 8080

# Configure execution entrypoint
ENTRYPOINT ["/server"]
```

### Manifest 2: Production Kubernetes Deployment (`deployment.yaml`)
Syntactically complete Kubernetes Deployment enforcing resource quotas, security contexts, probe configs, and graceful POSIX `SIGTERM` shutdown configuration.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payment-processor-api
  namespace: production
  labels:
    app.kubernetes.io/name: payment-processor-api
    app.kubernetes.io/part-of: finance-platform
    app.kubernetes.io/component: backend
spec:
  replicas: 3
  revisionHistoryLimit: 5
  selector:
    matchLabels:
      app.kubernetes.io/name: payment-processor-api
  template:
    metadata:
      labels:
        app.kubernetes.io/name: payment-processor-api
    spec:
      terminationGracePeriodSeconds: 30
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        fsGroup: 10001
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: api-runtime
          image: registry.enterprise.internal/finance/payment-api:v1.4.2
          imagePullPolicy: IfNotPresent
          command: ["/server"]
          env:
            - name: PORT
              value: "8080"
            - name: ENVIRONMENT
              value: "production"
            - name: GOMAXPROCS
              valueFrom:
                resourceFieldRef:
                  resource: limits.cpu
          ports:
            - containerPort: 8080
              name: http-api
              protocol: TCP
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop:
                - ALL
          resources:
            requests:
              cpu: 250m
              memory: 128Mi
            limits:
              cpu: 1000m
              memory: 512Mi
          startupProbe:
            httpGet:
              path: /healthz/startup
              port: 8080
            initialDelaySeconds: 2
            periodSeconds: 3
            failureThreshold: 10
          livenessProbe:
            httpGet:
              path: /healthz/liveness
              port: 8080
            periodSeconds: 10
            timeoutSeconds: 2
            failureThreshold: 3
          readinessProbe:
            httpGet:
              path: /healthz/readiness
              port: 8080
            periodSeconds: 5
            timeoutSeconds: 2
            successThreshold: 1
            failureThreshold: 2
```

### Manifest 3: Full Enterprise CI/CD Pipeline (`ci-cd-pipeline.yaml`)
Declarative GitHub Actions workflow integrating code linting, unit testing, static application security testing (SAST), binary build, container image creation, and registry pushing.

```yaml
name: Production CI/CD Pipeline

on:
  push:
    branches:
      - main
  pull_request:
    branches:
      - main

permissions:
  contents: read
  security-events: write
  packages: write

jobs:
  code-quality-and-test:
    name: Code Quality, Lint & Test
    runs-on: ubuntu-latest
    steps:
      - name: Checkout Source Code
        uses: actions/checkout@v4

      - name: Setup Go Development Environment
        uses: actions/setup-go@v5
        with:
          go-version: '1.22'
          cache: true

      - name: Run Static Code Analysis (golangci-lint)
        uses: golangci/golangci-lint-action@v4
        with:
          version: v1.56.2

      - name: Execute Unit Tests with Coverage & Race Detection
        run: |
          go test -race -v -coverprofile=coverage.out ./...

      - name: Run SAST Security Scan (Trivy Code)
        uses: aquasecurity/trivy-action@0.18.0
        with:
          scan-type: 'fs'
          ignore-unfixed: true
          format: 'sarif'
          output: 'trivy-results.sarif'
          severity: 'CRITICAL,HIGH'

  build-and-publish:
    name: Build AOT & Publish Container Image
    needs: code-quality-and-test
    runs-on: ubuntu-latest
    if: github.ref == 'refs/heads/main' && github.event_name == 'push'
    steps:
      - name: Checkout Source Code
        uses: actions/checkout@v4

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Authenticate to Container Registry
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Extract Metadata (Tags, Labels)
        id: meta
        uses: docker/metadata-action@v5
        with:
          images: ghcr.io/${{ github.repository }}
          tags: |
            type=sha,prefix=,format=long
            type=ref,event=branch
            latest

      - name: Build and Push OCI Container Image
        uses: docker/build-push-action@v5
        with:
          context: .
          file: ./Dockerfile
          push: true
          tags: ${{ steps.meta.outputs.tags }}
          labels: ${{ steps.meta.outputs.labels }}
          cache-from: type=gha
          cache-to: type=gha,mode=max
```

---

## 4. Real CLI Commands and Terminal Outputs ($)

### 1. Binary Header Inspection & Library Linking Verification
Analyzing execution targets to differentiate native AOT compiled ELF binaries, dynamic dependencies, and interpreted execution engines.

```bash
$ file /bin/ls /bin/server /usr/bin/python3
/bin/ls:          ELF 64-bit LSB pie executable, x86-64, version 1 (SYSV), dynamically linked, interpreter /lib64/ld-linux-x86-64.so.2, for GNU/Linux 3.2.0, BuildID[sha1]=1b2c3d4e5f, stripped
/bin/server:      ELF 64-bit LSB executable, x86-64, version 1 (SYSV), statically linked, Go BuildID=a1b2c3d4e5f6, stripped
/usr/bin/python3: ELF 64-bit LSB pie executable, x86-64, version 1 (SYSV), dynamically linked, interpreter /lib64/ld-linux-x86-64.so.2, for GNU/Linux 3.2.0, BuildID[sha1]=9f8e7d6c5b, stripped

$ ldd /bin/server
	statically linked

$ ldd /usr/bin/python3
	linux-vdso.so.1 (0x00007ffc12345000)
	libm.so.6 => /lib/x86_64-linux-gnu/libm.so.6 (0x00007f89ab000000)
	libc.so.6 => /lib/x86_64-linux-gnu/libc.so.6 (0x00007f89aa800000)
	/lib64/ld-linux-x86-64.so.2 (0x00007f89ab400000)
```

### 2. Runtime Memory and Thread Profiling via `pidstat`
Inspecting memory page allocations (`VSZ`, `RSS`), page faults, and multi-threading behavior across target process IDs.

```bash
$ pidstat -p $(pgrep -f "server") -r -u -t 1 3
Linux 6.6.13-amd64 (node-prod-01) 	08/06/2026 	_x86_64_	(8 CPU)

06:47:01 PM   UID      TGID       TID    %usr %system  %guest   %wait    %CPU   CPU  Command
06:47:02 PM 10001     41022         -    4.00    1.00    0.00    0.00    5.00     2  server
06:47:02 PM 10001         -     41022    1.00    0.00    0.00    0.00    1.00     2  |--server
06:47:02 PM 10001         -     41023    2.00    0.00    0.00    0.00    2.00     5  |--server
06:47:02 PM 10001         -     41024    1.00    1.00    0.00    0.00    2.00     7  |--server

06:47:01 PM   UID       PID  minflt/s  majflt/s     VSZ     RSS   %MEM  Command
06:47:02 PM 10001     41022    120.00      0.00   32456   18432   0.11  server
06:47:03 PM 10001     41022     45.00      0.00   32456   18496   0.11  server
06:47:04 PM 10001     41022      0.00      0.00   32456   18496   0.11  server
Average:    10001     41022     55.00      0.00   32456   18474   0.11  server
```

### 3. Git Source Control Diagnostics & Commit Tracking
Performing automated git fault localization using `git bisect` to locate regressions within source history.

```bash
$ git bisect start
$ git bisect bad HEAD
$ git bisect good v1.4.0
Bisecting: 12 revisions left to test after this (roughly 4 steps)
[a1b2c3d4e5f67890123456789abcdef012345678] feat(api): update JSON serialization library

$ git bisect run go test -run TestPaymentProcessing ./...
running  go test -run TestPaymentProcessing ./...
--- FAIL: TestPaymentProcessing (0.04s)
    payment_test.go:42: Unexpected nil pointer reference during payload parse
FAIL
exit status 1
Bisecting: 5 revisions left to test after this (roughly 3 steps)
[89abcdef0123456789abcdef0123456789a1b2c3] fix(db): optimize connection pooling parameters
running  go test -run TestPaymentProcessing ./...
PASS
ok  	github.com/enterprise/finance/pkg/payment	0.038s
[a1b2c3d4e5f67890123456789abcdef012345678] is the first bad commit
commit a1b2c3d4e5f67890123456789abcdef012345678
Author: Developer <dev@enterprise.internal>
Date:   Wed Aug 5 14:22:10 2026 -0400

    feat(api): update JSON serialization library

:100644 100644 c1d2e3... f4a5b6... M	pkg/payment/serializer.go
```

---

## 5. Troubleshooting & Failure Diagnostic Guide

```
                            +------------------------------------+
                            | KUBERNETES POD TERMINATED (FAIL)   |
                            +------------------------------------+
                                              |
                                              v
                            +------------------------------------+
                            | Inspect Exit Code & Status         |
                            | kubectl describe pod <pod-name>    |
                            +------------------------------------+
                                    /                    \
                                   /                      \
                         Exit Code 137                  Exit Code 143 / 1
                                 /                          \
                                v                            v
            +-----------------------+              +-----------------------+
            | OOMKilled by Kernel   |              | Graceful Termination  |
            | (cgroup Limit)        |              | Timeout / SIGKILL     |
            +-----------------------+              +-----------------------+
                        |                                      |
                        v                                      v
            +-----------------------+              +-----------------------+
            | Check Heap vs Limit   |              | Check SIGTERM Listener|
            | Tune Heap/GC Settings |              | Inspect Connection    |
            | (-Xmx, GOMAXPROCS)    |              | Draining Metrics      |
            +-----------------------+              +-----------------------+
```

### Problem A: Kubernetes OOMKilled (Exit Code 137) in Managed Runtimes

#### Root Cause Mechanics:
Languages running on top of Virtual Machines (JVM, Node.js V8) allocate memory for code cache, thread stacks, off-heap native memory (`mmap`), and the heap. If the VM runtime is oblivious to cgroup limits, or if `-Xmx` (Max Heap) is set equal to or greater than the container's Kubernetes memory limit, the total process footprint (Heap + Non-Heap) will breach the OS cgroup boundary. The Linux Kernel `oom-killer` immediately sends signal `9` (`SIGKILL`), resulting in Exit Code `137` (`128 + 9`).

#### Step-by-Step Diagnostic & Remediation Workflow:

1. **Verify Pod Status & Termination Reason**:
   ```bash
   $ kubectl get pod payment-processor-api-7b89c-x4z9d -n production -o jsonpath='{.status.containerStatuses[0].lastState.terminated}'
   {"containerID":"containerd://a1b2c3d4...","exitCode":137,"finishedAt":"2026-08-06T18:30:12Z","reason":"OOMKilled","startedAt":"2026-08-06T18:00:00Z"}
   ```

2. **Inspect Kernel cgroup OOM Events via Node Diagnostics**:
   ```bash
   $ dmesg -T | grep -E -i "oom|killed process"
   [Thu Aug 6 18:30:12 2026] Memory cgroup out of memory: Kill process 41022 (java) score 995 or sacrifice child
   [Thu Aug 6 18:30:12 2026] Killed process 41022 (java) total-vm:4231200kB, anon-rss:523800kB, file-rss:12400kB, shmem-rss:0kB oom_reap_status 0
   ```

3. **Remediation Strategy**:
   - For Java JVM: Enforce cgroup ergonomics via `-XX:+UseContainerSupport` and set dynamic heap proportions instead of fixed values: `-XX:MaxRAMPercentage=75.0`.
   - For Node.js: Explicitly restrict the V8 garbage collector heap limit inside the pod spec environment:
     ```yaml
     env:
       - name: NODE_OPTIONS
         value: "--max-old-space-size=384" # Fits within 512Mi limit, leaving room for off-heap buffers
     ```

---

### Problem B: Event Loop Starvation & CPU Throttling in Single-Threaded Runtimes

#### Root Cause Mechanics:
Single-threaded event loop engines (JavaScript/Node.js, Python asyncio) handle non-blocking I/O via worker thread pools (`libuv`) while executing application logic on a single main thread. If a developer introduces synchronous, CPU-intensive algorithms (e.g., synchronous cryptographic hashing, recursive JSON parsing, intensive mathematical loops), the main thread blocks. The event loop cannot process incoming socket read/write callbacks or Kubernetes readiness probes, causing cascading HTTP 504 timeouts and probe failures.

#### Step-by-Step Diagnostic & Remediation Workflow:

1. **Identify CPU Throttling via cgroup Metrics**:
   ```bash
   $ kubectl exec -it payment-processor-api-7b89c-x4z9d -n production -- cat /sys/fs/cgroup/cpu.stat
   nr_periods 45120
   nr_throttled 12430
   throttled_usec 894320112
   ```
   *Interpretation*: High `nr_throttled` relative to `nr_periods` confirms the runtime is constrained by kernel CPU quota limits (`cpu.cfs_quota_us`).

2. **Profile Main Thread Event Loop Latency**:
   Execute Node.js event-loop sampling via `clinic.js` or inspect active handles using `process._getActiveHandles()` to find unreleased sync blocks.

3. **Remediation Strategy**:
   - Offload CPU-heavy computation from the procedural main thread to background Worker Threads (`worker_threads` module in Node.js, `concurrent.futures` ProcessPoolExecutor in Python).
   - Increase Kubernetes CPU limits or remove strict CPU limits if using burstable QoS classes to prevent cgroup CFS throttle pauses.

---

### Problem C: Broken Database Connections Due to Ungraceful `SIGTERM` Signal Handling

#### Root Cause Mechanics:
When Kubernetes terminates a Pod (during deployments or autoscaling), it sends a POSIX `SIGTERM` signal to Process ID 1 (`PID 1`) inside the container. If the application binary is wrapped inside a shell script (`ENTRYPOINT /sh/start.sh`) without `exec`, the shell intercepts and drops `SIGTERM`. As a result, the application process never receives notification, continues accepting requests, fails to drain open TCP sockets, and is abruptly killed 30 seconds later by `SIGKILL` (Exit Code 143 / 137). This causes active client requests to fail with `ECONNRESET`.

#### Step-by-Step Diagnostic & Remediation Workflow:

1. **Check Process Hierarchy Inside Container**:
   ```bash
   $ kubectl exec -it payment-processor-api-7b89c-x4z9d -n production -- ps -ef
   UID        PID  PPID  C STIME TTY          TIME CMD
   10001        1     0  0 18:00 ?        00:00:00 /bin/sh /start.sh
   10001        7     1  2 18:00 ?        00:00:15 node /app/index.js
   ```
   *Interpretation*: PID 1 is `/bin/sh`, NOT `node`. `/bin/sh` will not forward POSIX signals to PID 7.

2. **Remediation Strategy**:
   - Update the Dockerfile `ENTRYPOINT` using the JSON array syntax to replace PID 1 directly with the application binary via shell execution:
     ```dockerfile
     # WRONG: ENTRYPOINT /start.sh
     # CORRECT (Direct execution as PID 1):
     ENTRYPOINT ["/server"]
     ```
   - Implement explicit OS signal listener registration inside the application code (Procedural/OOP handler):
     ```go
     // Graceful Shutdown Signal Handler in Go
     sigChan := make(chan os.Signal, 1)
     signal.Notify(sigChan, syscall.SIGTERM, syscall.SIGINT)

     <-sigChan // Block until signal received
     log.Println("SIGTERM received. Initiating graceful drain...")

     ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
     defer cancel()
     if err := httpServer.Shutdown(ctx); err != nil {
         log.Fatalf("Server forced to shutdown: %v", err)
     }
     ```

---

## 6. References

- **Linux Professional Institute (LPI) Web Development Essentials Overview**:  
  https://www.lpi.org/our-certifications/web-development-essentials-overview/
- **LPI Wiki - Web Development Essentials Objectives V1.0 (Topic 031.1)**:  
  https://wiki.lpi.org/wiki/Web_Development_Essentials_Objectives_V1.0
- **Kubernetes Documentation - Pod Lifecycle & Container Hooks**:  
  https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/
- **Kubernetes Documentation - Resource Management for Pods and Containers**:  
  https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/
- **Docker Documentation - Multi-stage Builds Best Practices**:  
  https://docs.docker.com/build/building/multi-stage/
- **The Linux Kernel Documentation - Control Group v2 (cgroups v2)**:  
  https://www.kernel.org/doc/html/latest/admin-guide/cgroup-v2.html