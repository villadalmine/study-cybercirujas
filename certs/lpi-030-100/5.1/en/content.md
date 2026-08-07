# LPI 030-100 Study Guide — Topic 5.1: Node.js Basics

**Exam Certification:** Linux Professional Institute Web Development Essentials (Exam 030-100, Version 1.0)  
**Topic Objective:** Topic 5.1 Node.js Basics  
**Topic Weight:** 2.5  
**Target Audience:** SREs, DevOps Engineers, Platform Architects  

---

## 1. Architectural Motivation & Production Problem Statement

### 1.1 The C10K Problem and Thread-per-Request Bottlenecks
Traditional web server architectures (e.g., Apache HTTP Server with `mod_php` or traditional Java Servlet containers) rely on a **thread-per-request** or **process-per-request** concurrency model. In this model, every incoming TCP connection is bound to a dedicated operating system (OS) thread.

```
Thread-per-Request Concurrency Bottleneck:
[ HTTP Client 1 ] ---> [ OS Thread 1 (Stack ~1MB) ] ---> [ Blocking DB Read ] (Thread Idle)
[ HTTP Client 2 ] ---> [ OS Thread 2 (Stack ~1MB) ] ---> [ Blocking File I/O ] (Thread Idle)
...
[ HTTP Client N ] ---> Context Switching Overhead + RAM Exhaustion (10,000 Threads = ~10GB Overhead)
```

**Production Architectural Failure Modes:**
1. **Memory Overhead:** Each OS thread allocates a default stack memory size (typically 512KB to 2MB). Managing 10,000 concurrent idle connections consumes ~10GB of RAM purely for thread stacks.
2. **Context Switching Thrashing:** As connection count ($N$) grows, the OS kernel spends more CPU cycles performing thread context switches (saving/restoring registers, CPU cache invalidation) than executing application code.
3. **I/O Blocking Waste:** In typical web applications, over 90% of request latency is spent waiting on external I/O (Database queries, file system access, network API calls). Under thread-per-request, the OS thread remains blocked and idle during these periods.

### 1.2 The Node.js Non-Blocking Event-Driven Architecture
Node.js solves the C10K problem by using a **single-threaded event loop** paired with non-blocking I/O multiplexing backed by `libuv` and the Google V8 JavaScript engine.

```
Node.js Architecture High-Level Component Stack:

+-----------------------------------------------------------------------+
|                        Node.js Core API (JS)                          |
|             (http, fs, net, crypto, stream, events, process)          |
+-----------------------------------------------------------------------+
|                    Node.js C++ Binding Layer                          |
+-----------------------------------+-----------------------------------+
|     V8 JavaScript Engine          |             libuv                 |
| (JIT Compilation, Garbage Coll.)  |  (Event Loop, Async I/O, Pool)    |
+-----------------------------------+-----------------------------------+
                                    | OS I/O Demux (epoll/kqueue/IOCP)  |
                                    +-----------------------------------+
                                    | libuv Thread Pool (4 Workers)     |
                                    +-----------------------------------+
```

#### Key Architecture Components:
* **Google V8 Engine:** Compiles JavaScript directly into native machine code (JIT), manages the execution stack, and handles memory allocation/garbage collection (Scavenge/Mark-Sweep).
* **libuv:** A multi-platform C library that abstraction layer over low-level asynchronous I/O primitives:
  * **Linux:** `epoll`
  * **macOS/BSD:** `kqueue`
  * **Windows:** `IOCP` (Input/Output Completion Ports)
* **Main Thread:** Executes JavaScript code, evaluates synchronous operations, and executes event callbacks sequentially.

---

### 1.3 Deep Dive: The libuv Event Loop & Thread Pool Mechanics

The event loop operates on a single thread, but offloads asynchronous operations. Not all asynchronous operations use OS non-blocking handles; some operations are fundamentally blocking at the kernel level (e.g., synchronous file operations, DNS resolution via `/etc/hosts`).

```
libuv Event Loop Lifecycle Phases:

      +-----------------------------------------+
----> |                 Timers                  | ---> [ setTimeout(), setInterval() ]
      +-----------------------------------------+
                           |
      +-----------------------------------------+
      |            Pending Callbacks            | ---> [ Executed deferred I/O callbacks ]
      +-----------------------------------------+
                           |
      +-----------------------------------------+
      |           Idle, Prepare                 | ---> [ Internal libuv usage ]
      +-----------------------------------------+
                           |
      +-----------------------------------------+
      |                 Poll                    | ---> [ Retrieve new I/O events; block if idle ]
      +-----------------------------------------+
                           |
      +-----------------------------------------+
      |                 Check                   | ---> [ setImmediate() callbacks ]
      +-----------------------------------------+
                           |
      +-----------------------------------------+
      |            Close Callbacks              | ---> [ e.g. socket.on('close') ]
      +-----------------------------------------+
                           |
                           v
           [ Microtask Queue Check: process.nextTick() -> Promises ]
```

#### libuv Thread Pool Operations
When an operation cannot be performed via OS non-blocking I/O multiplexing, `libuv` delegates the work to an internal thread pool managed via the `UV_THREADPOOL_SIZE` environment variable (default: `4`, max: `1024`).

**Operations delegated to the Thread Pool:**
1. **File System (`fs` module):** Asynchronous file calls (`fs.readFile`, `fs.writeFile`) use thread pool tasks because major OS kernels lack unified non-blocking file I/O interfaces.
2. **Crypto (`crypto` module):** CPU-intensive operations like `crypto.pbkdf2()`, `crypto.scrypt()`, and `crypto.randomBytes()`.
3. **Zlib (`zlib` module):** Compression/decompression operations.
4. **DNS (`dns` module):** `dns.lookup()` uses `getaddrinfo(3)`, which blocks synchronously. Note: `dns.resolve()` uses c-ares and performs direct non-blocking network socket calls without thread pool intervention.

---

## 2. Technical Comparisons & Trade-Off Matrix

### 2.1 Concurrency Model Trade-Offs

| Dimensional Feature | Node.js (Event-Driven / Single-Threaded Main Loop) | Thread-per-Request (Java Tomcat / Apache Prefork) | Go (Goroutines / M:N Scheduler) |
| :--- | :--- | :--- | :--- |
| **Primary Execution Unit** | Single V8 Execution Thread + Event Loop | 1 OS Thread per HTTP Connection | User-space Goroutines multiplexed on $M$ OS Threads |
| **I/O Handling Strategy** | Asynchronous Non-blocking via OS `epoll`/`kqueue` | Synchronous Blocking I/O per thread | Non-blocking via `netpoller` hidden behind sync syntax |
| **Memory Footprint / Connection** | Extremely low (~2KB - 4KB per socket handle) | High (~512KB - 2MB per thread stack) | Very Low (~2KB per goroutine stack) |
| **CPU-Bound Task Impact** | **Severe:** Blocks main thread, halts entire server loop | **Isolated:** Affects only the single worker thread | **Distributed:** Work-stealing scheduler migrates tasks |
| **Context Switching Overhead** | Zero for main event loop execution | High kernel-level context switching cost | Extremely low user-space context switching |
| **Best Production Use-Case** | I/O-Intensive APIs, WebSockets, Proxy/Gateway | Enterprise legacy applications, Heavy synchronous processing | High-concurrency microservices, Network tooling |

---

### 2.2 Node.js Module Systems: CommonJS (CJS) vs. ECMAScript Modules (ESM)

| Characteristic | CommonJS (CJS) | ECMAScript Modules (ESM) |
| :--- | :--- | :--- |
| **Specification** | De-facto Node.js standard (`require` / `module.exports`) | Official ECMAScript Standard (`import` / `export`) |
| **Module Resolution Timing** | **Dynamic at Runtime:** Loaded synchronously when `require()` is invoked | **Static at Parsing:** Loaded and linked asynchronously before code execution |
| **Top-Level `await`** | Not supported (requires wrapping in `async` IIFE) | Supported natively at top-level |
| **Tree-Shaking Support** | Poor / Impossible due to dynamic `require` semantics | Excellent: Static dependency graph enables dead-code elimination |
| **Built-in Scope Identifiers** | Provides `__dirname` and `__filename` | Excludes `__dirname`/`__filename` (Requires `import.meta.url` + `fileURLToPath`) |
| **Interoperability** | Cannot `require()` pure ESM packages directly | Can `import` CJS modules, but only default imports |

---

### 2.3 Microtask vs. Macrotask Queue Execution Priority

Order of execution within a single event loop turn:

```
[ Current Synchronous Stack ] 
            |
            v
[ Microtask: process.nextTick() Queue ]
            |
            v
[ Microtask: Promise Jobs (Microtask Queue) ]
            |
            v
[ Macrotask Phase Callback (e.g., Timers / Poll / Check) ]
```

```javascript
// Demonstration of Queue Execution Priority
console.log('1: Synchronous');

setTimeout(() => console.log('2: Macrotask (setTimeout)'), 0);
setImmediate(() => console.log('3: Macrotask (setImmediate)'));

Promise.resolve().then(() => console.log('4: Microtask (Promise.then)'));

process.nextTick(() => console.log('5: Microtask (process.nextTick)'));

console.log('6: Synchronous End');

// Execution Output Order:
// 1: Synchronous
// 6: Synchronous End
// 5: Microtask (process.nextTick)
// 4: Microtask (Promise.then)
// 2: Macrotask (setTimeout)  <-- Or 3 depending on timer resolution phase
// 3: Macrotask (setImmediate)
```

---

## 3. Production Infrastructure & Code Manifests

### 3.1 `package.json`

```json
{
  "name": "production-node-service",
  "version": "1.0.0",
  "description": "Production-grade enterprise Node.js HTTP Service",
  "main": "server.js",
  "type": "module",
  "engines": {
    "node": ">=20.10.0",
    "npm": ">=10.2.0"
  },
  "scripts": {
    "start": "node server.js",
    "dev": "node --watch server.js",
    "test": "node --test"
  },
  "dependencies": {
    "express": "^4.19.2"
  },
  "devDependencies": {
    "autocannon": "^7.15.0"
  },
  "private": true
}
```

---

### 3.2 `server.js` (Production Server with Graceful Shutdown & Health Probes)

```javascript
import http from 'node:http';
import process from 'node:process';
import { fileURLToPath } from 'node:url';
import express from 'express';

const app = express();
const PORT = process.env.PORT || 3000;

// State flags for Kubernetes Readiness Probe
let isShuttingDown = false;

// Middleware for parsing JSON requests
app.use(express.json());

// Liveness Probe Endpoint (Checks if process is alive)
app.get('/healthz', (req, res) => {
  res.status(200).json({ status: 'UP', timestamp: new Date().toISOString() });
});

// Readiness Probe Endpoint (Checks if application can accept traffic)
app.get('/readyz', (req, res) => {
  if (isShuttingDown) {
    return res.status(503).json({ status: 'DRAINING', message: 'Service is shutting down' });
  }
  // Check database or external dependencies connection state here
  res.status(200).json({ status: 'READY' });
});

// Business Logic Endpoint
app.get('/api/v1/resource', (req, res) => {
  res.status(200).json({
    id: 'res-9842',
    data: 'Production Operational Data',
    pid: process.pid,
  });
});

// HTTP Server Initialization
const server = http.createServer(app);

server.listen(PORT, () => {
  console.log(JSON.stringify({
    level: 'INFO',
    message: `Server initialized and listening on port ${PORT}`,
    pid: process.pid,
    nodeVersion: process.version,
  }));
});

// Graceful Shutdown Handler
function gracefulShutdown(signal) {
  console.log(JSON.stringify({
    level: 'WARN',
    message: `Received ${signal}. Starting graceful shutdown sequence...`,
    pid: process.pid,
  }));

  // Step 1: Mark app as shutting down to fail Readiness probes immediately
  isShuttingDown = true;

  // Step 2: Stop accepting new TCP connections
  server.close((err) => {
    if (err) {
      console.error(JSON.stringify({
        level: 'ERROR',
        message: 'Error encountered during HTTP server closure',
        error: err.message,
      }));
      process.exit(1);
    }

    console.log(JSON.stringify({
      level: 'INFO',
      message: 'All active HTTP connections closed cleanly. Exiting process.',
    }));
    process.exit(0);
  });

  // Step 3: Hard shutdown timeout force-kill if connections do not drain
  const FORCE_SHUTDOWN_TIMEOUT = 10000; // 10 Seconds
  const timer = setTimeout(() => {
    console.error(JSON.stringify({
      level: 'FATAL',
      message: 'Forced shutdown executed: Active connections failed to drain within timeout window.',
    }));
    process.exit(1);
  }, FORCE_SHUTDOWN_TIMEOUT);

  // Allow process to exit naturally if server closes before timer completes
  timer.unref();
}

// Signal Listeners
process.on('SIGTERM', () => gracefulShutdown('SIGTERM'));
process.on('SIGINT', () => gracefulShutdown('SIGINT'));

// Process Failure Protection Handlers
process.on('uncaughtException', (err) => {
  console.error(JSON.stringify({
    level: 'FATAL',
    message: 'Uncaught Exception detected in execution stack',
    error: err.message,
    stack: err.stack,
  }));
  // Uncaught exceptions leave the process in an undefined state; force termination
  process.exit(1);
});

process.on('unhandledRejection', (reason, promise) => {
  console.error(JSON.stringify({
    level: 'ERROR',
    message: 'Unhandled Promise Rejection detected',
    reason: reason instanceof Error ? reason.message : reason,
  }));
});
```

---

### 3.3 Production Dockerfile (Multi-Stage Distroless Security Build)

```dockerfile
# Stage 1: Build & Dependency Resolution
FROM node:20.15.0-alpine AS builder

WORKDIR /usr/src/app

# Copy dependency manifests
COPY package*.json ./

# Install production dependencies only via clean install
RUN npm ci --only=production && npm cache clean --force

# Copy application source code
COPY . .

# Stage 2: Final Minimal Runtime Image
FROM gcr.io/distroless/nodejs20-debian12:nonroot

WORKDIR /usr/src/app

# Copy built application and node_modules from builder
COPY --from=builder /usr/src/app /usr/src/app

# Set Production Environment Variables
ENV NODE_ENV=production \
    PORT=3000 \
    UV_THREADPOOL_SIZE=8

# Expose HTTP Port
EXPOSE 3000

# Execute as default non-root user (UID 65532 in distroless)
USER nonroot

# Run Node.js App
CMD ["server.js"]
```

---

### 3.4 Kubernetes Infrastructure Manifest (`k8s-deployment.yaml`)

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: node-service-deployment
  namespace: production
  labels:
    app.kubernetes.io/name: node-service
    app.kubernetes.io/tier: api
spec:
  replicas: 3
  selector:
    matchLabels:
      app: node-service
  template:
    metadata:
      labels:
        app: node-service
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 65532
        fsGroup: 65532
      containers:
        - name: node-service
          image: registry.internal.net/apps/node-service:1.0.0
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 3000
              name: http
          env:
            - name: NODE_ENV
              value: "production"
            - name: PORT
              value: "3000"
            - name: UV_THREADPOOL_SIZE
              value: "8"
          resources:
            requests:
              cpu: "250m"
              memory: "256Mi"
            limits:
              cpu: "1000m"
              memory: "512Mi"
          startupProbe:
            httpGet:
              path: /healthz
              port: 3000
            initialDelaySeconds: 2
            periodSeconds: 3
            failureThreshold: 5
          livenessProbe:
            httpGet:
              path: /healthz
              port: 3000
            initialDelaySeconds: 5
            periodSeconds: 10
            timeoutSeconds: 2
            failureThreshold: 3
          readinessProbe:
            httpGet:
              path: /readyz
              port: 3000
            initialDelaySeconds: 5
            periodSeconds: 5
            timeoutSeconds: 2
            failureThreshold: 2
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop:
                - ALL
---
apiVersion: v1
kind: Service
metadata:
  name: node-service-svc
  namespace: production
spec:
  type: ClusterIP
  ports:
    - port: 80
      targetPort: http
      protocol: TCP
      name: http
  selector:
    app: node-service
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: node-service-hpa
  namespace: production
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: node-service-deployment
  minReplicas: 3
  maxReplicas: 10
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
```

---

### 3.5 Systemd Service Unit Manifest (`/etc/systemd/system/node-app.service`)

```ini
[Unit]
Description=Production Node.js Application Service
After=network.target syslog.target

[Service]
Type=simple
User=node
Group=node
WorkingDirectory=/var/www/node-app
ExecStart=/usr/bin/node --max-old-space-size=4096 server.js
Restart=always
RestartSec=5s

# Environment Configuration
Environment=NODE_ENV=production
Environment=PORT=3000
Environment=UV_THREADPOOL_SIZE=8

# Security Isolation & Hardening
NoNewPrivileges=true
ProtectSystem=full
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
CapabilityBoundingSet=

# Resource Limits
LimitNOFILE=65536
LimitNPROC=4096
MemoryMax=4.5G

# Logging Redirect
StandardOutput=journal
StandardError=journal
SyslogIdentifier=node-app

[Install]
WantedBy=multi-user.target
```

---

## 4. Real CLI Commands & Terminal Output Sequences

### 4.1 Dependency Management & Audit Execution

```bash
$ npm init -y
Wrote to /var/www/node-app/package.json:

{
  "name": "node-app",
  "version": "1.0.0",
  "description": "",
  "main": "index.js",
  "scripts": {
    "test": "echo \"Error: no test specified\" && exit 1"
  },
  "keywords": [],
  "author": "",
  "license": "ISC"
}

$ npm install express --save
added 64 packages, and audited 65 packages in 1s

3 packages are looking for funding
  run `npm fund` for details

found 0 vulnerabilities

$ npm audit --production
found 0 vulnerabilities in 65 scanned packages
```

---

### 4.2 Inspecting V8 Engine Memory & Heap Statistics

```bash
$ node -e "console.log(v8.getHeapStatistics())"
{
  total_heap_size: 4743168,
  total_heap_size_executable: 524288,
  total_physical_size: 4743168,
  total_available_size: 4341738776,
  used_heap_size: 2712536,
  heap_size_limit: 4345298944,
  malloced_memory: 254128,
  peak_malloced_memory: 585720,
  does_zap_garbage: 0,
  number_of_native_contexts: 2,
  number_of_detached_contexts: 0,
  total_global_handles_size: 8192,
  used_global_handles_size: 2304
}
```

---

### 4.3 Node.js Inspector Remote Debugging Activation

```bash
$ node --inspect=0.0.0.0:9229 server.js
Debugger listening on ws://0.0.0.0:9229/c8a90fd1-512b-47e1-b1e9-4e781df5a021
For help, see: https://nodejs.org/en/docs/inspector
{"level":"INFO","message":"Server initialized and listening on port 3000","pid":40892,"nodeVersion":"v20.15.0"}
```

---

### 4.4 CPU Profiling & Profile Analysis

```bash
$ node --prof server.js
# [Execute load test in separate terminal: autocannon -c 100 -d 10 http://localhost:3000/api/v1/resource]
^C

$ ls isolate-*.log
isolate-0x55d8f99e3000-41005-v8.log

$ node --prof-process isolate-0x55d8f99e3000-41005-v8.log > processed_profile.txt
$ head -n 25 processed_profile.txt
Statistical profiling result from isolate-0x55d8f99e3000-41005-v8.log, (15420 ticks, 12 unaccounted, 0 excluded).

 Shared libraries:
   ticks  total  nonlib   name
   11200   72.6%    0.0%  /usr/lib/x86_64-linux-gnu/libc.so
    2400   15.5%    0.0%  /usr/local/bin/node

 JavaScript:
   ticks  total  nonlib   name
     850    5.5%   46.7%  LazyCompile: *express /var/www/node-app/node_modules/express/lib/router/index.js:136:15
     320    2.1%   17.5%  LazyCompile: *http.createServer node:http:362:24

 C++:
   ticks  total  nonlib   name
     410    2.7%   22.5%  node::crypto::PBKDF2(v8::FunctionCallbackInfo<v8::Value> const&)
     150    1.0%    8.2%  uv__epoll_wait
```

---

### 4.5 Process Termination Signal Verification (Graceful Shutdown Trace)

```bash
# Terminal 1: Application Execution
$ node server.js
{"level":"INFO","message":"Server initialized and listening on port 3000","pid":42110,"nodeVersion":"v20.15.0"}

# Terminal 2: Send SIGTERM Signal
$ kill -SIGTERM 42110

# Terminal 1 Output Log:
{"level":"WARN","message":"Received SIGTERM. Starting graceful shutdown sequence...","pid":42110}
{"level":"INFO","message":"All active HTTP connections closed cleanly. Exiting process."}
$ echo $?
0
```

---

## 5. Verification & Diagnostic Troubleshooting Guide

### 5.1 Diagnostic Decision Tree Matrix

```
                          [ Issue Reported ]
                                  |
            +---------------------+---------------------+
            |                                           |
  [ High Latency / Lag ]                       [ OOM Crash / Leak ]
            |                                           |
            v                                           v
  Check Event Loop Lag                       Check V8 Heap Metrics
  (clinic doctor / perf)                     (node --trace-gc / heapdump)
            |                                           |
     +------+------+                             +------+------+
     |             |                             |             |
[Sync CPU]   [Thread Pool]                 [Global Vars] [Unclosed Sockets]
  Block        Exhaustion                    Reference      or Listeners
```

---

### 5.2 Symptom 1: Event Loop Starvation / Main Thread Blocking

#### Root Cause:
Execution of synchronous operations ($O(N^2)$ algorithm, large `JSON.parse()`, synchronous file I/O `fs.readFileSync`, or ReDoS regex evaluation) directly on the main thread.

#### Diagnostic Verification Command:
Use `clinic doctor` to detect Event Loop Blocking:

```bash
$ npx clinic doctor -- node server.js
$ autocannon -c 100 -d 10 http://localhost:3000/api/v1/compute
```

#### Diagnostic Log Trace (`node --trace-event-categories v8,node,node.async_hooks server.js`):

```json
{"pid":43102,"tid":1,"ts":17109201,"ph":"B","cat":"node.perf","name":"event_loop_delay","args":{"delay":4582.12}}
```

#### Mitigation Architecture:
Offload synchronous computations to **Worker Threads**:

```javascript
import { Worker, isMainThread, parentPort, workerData } from 'node:worker_threads';

if (isMainThread) {
  // Main Thread Route Delegate
  app.get('/api/v1/compute', (req, res) => {
    const worker = new Worker(new URL(import.meta.url), { workerData: { target: 45 } });
    worker.on('message', (result) => res.json({ result }));
    worker.on('error', (err) => res.status(500).json({ error: err.message }));
  });
} else {
  // Worker Thread Execution Logic
  const fibonacci = (n) => (n <= 1 ? n : fibonacci(n - 1) + fibonacci(n - 2));
  const result = fibonacci(workerData.target);
  parentPort.postMessage(result);
}
```

---

### 5.3 Symptom 2: V8 Memory Leak / Out of Memory (OOM)

#### Root Cause:
Retaining references to objects in memory preventing Garbage Collection (e.g., growing global arrays, forgotten `EventEmitter` listeners, unclosed DB sockets).

#### Diagnostic Verification Command:

```bash
$ node --trace-gc --max-old-space-size=512 server.js
```

#### Real GC Log Output Sequence (Indicating Memory Pressure):

```
[44100:0x559e12000000]     1254 ms: Scavenge 240.5 (258.0) -> 235.1 (258.0) MB, 4.2 ms 
[44100:0x559e12000000]     2410 ms: Mark-sweep 480.2 (512.0) -> 460.5 (512.0) MB, 82.4 ms 
[44100:0x559e12000000]     3120 ms: Mark-sweep 505.8 (512.0) -> 501.2 (512.0) MB, 110.1 ms 

<--- Last few GCs --->
[44100:0x559e12000000]     3850 ms: Mark-sweep (reduce) 510.1 (512.0) -> 509.8 (512.0) MB, 145.2 ms

<--- JS stack trace --->
FATAL ERROR: Reached heap limit Allocation failed - JavaScript heap out of memory
 1: 0xb83a40 node::Abort() [/usr/local/bin/node]
 2: 0xa9c25e node::FatalError(char const*, char const*) [/usr/local/bin/node]
 3: 0xd3e512 v8::internal::V8::FatalProcessOutOfMemory(v8::internal::Isolate*, char const*, v8::OOMDetails const&) [/usr/local/bin/node]
```

#### Remediation & Heap Snapshot Capture:
Inject Heap Snapshot programmatic dump:

```javascript
import v8 from 'node:v8';
import fs from 'node:fs';

app.get('/admin/heapdump', (req, res) => {
  const fileName = `/tmp/heap-${Date.now()}.heapsnapshot`;
  const stream = v8.getHeapSnapshot();
  const writeStream = fs.createWriteStream(fileName);
  stream.pipe(writeStream);
  
  writeStream.on('finish', () => {
    res.json({ message: 'Snapshot generated', path: fileName });
  });
});
```

---

### 5.4 Symptom 3: libuv Thread Pool Exhaustion

#### Root Cause:
Concurrent execution of blocking asynchronous operations exceeding default `UV_THREADPOOL_SIZE` (4). For example, 10 concurrent requests invoking `crypto.pbkdf2()` will stall remaining file I/O operations until thread pool slots clear.

#### Verification & Resolution Test Command:

```bash
# Execute with default UV_THREADPOOL_SIZE=4
$ time node -e "
const crypto = require('crypto');
for(let i=0; i<8; i++) {
  crypto.pbkdf2('pass', 'salt', 100000, 512, 'sha512', () => console.log('Done', i));
}
"
Done 0
Done 1
Done 2
Done 3
# Pauses...
Done 4
Done 5
Done 6
Done 7
real    0m1.842s

# Execute with expanded UV_THREADPOOL_SIZE=8
$ UV_THREADPOOL_SIZE=8 time node -e "
const crypto = require('crypto');
for(let i=0; i<8; i++) {
  crypto.pbkdf2('pass', 'salt', 100000, 512, 'sha512', () => console.log('Done', i));
}
"
Done 0
Done 1
Done 2
Done 3
Done 4
Done 5
Done 6
Done 7
real    0m0.920s
```

---

## 6. References

* **LPI Web Development Essentials Overview:**  
  https://www.lpi.org/our-certifications/web-development-essentials-overview/
* **Node.js Official Documentation & API Reference:**  
  https://nodejs.org/en/docs/
* **Node.js Event Loop, Timers, and process.nextTick():**  
  https://nodejs.org/en/docs/guides/event-loop-timers-and-nexttick/
* **libuv Architectural Design Documentation:**  
  https://docs.libuv.org/en/v1.x/design.html
* **Google V8 JavaScript Engine Architecture:**  
  https://v8.dev/