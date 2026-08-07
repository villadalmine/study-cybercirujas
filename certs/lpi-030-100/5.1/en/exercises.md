# CNCF / LPI-030-100 Study Material: Topic 5.1 – Node.js Basics

**Exam Target:** LPI Web Development Essentials (Exam 030-100, Version 1.0)  
**Topic 5.1:** Node.js Basics  
**Weight:** 2.5  
**Official References:**
* [LPI Web Development Essentials Overview](https://www.lpi.org/our-certifications/web-development-essentials-overview/)
* [Node.js Official Documentation: Event Loop, Timers, and process.nextTick()](https://nodejs.org/en/learn/asynchronous-work/event-loop-timers-and-nexttick)
* [Node.js Official Documentation: Modules System](https://nodejs.org/api/modules.html)

---

## Architectural Deep Dive: Node.js Runtime & Internals

Node.js is an open-source, cross-platform, single-threaded JavaScript runtime environment built on Google Chrome's **V8 JavaScript Engine** and the **libuv** C library.

```
+-------------------------------------------------------+
|                    Application Code                   |
+-------------------------------------------------------+
|        Node.js Standard Library (fs, http, path)      |
+---------------------------+---------------------------+
|      V8 Engine (JS)       |   Node.js C++ Bindings    |
+---------------------------+---------------------------+
|                          libuv                        |
|  (Event Loop, Asynchronous I/O Pool, Thread Pool)     |
+-------------------------------------------------------+
|                   Operating System                    |
+-------------------------------------------------------+
```

### Core Architecture Components

1. **V8 Engine**: Compiles JavaScript source code directly into native machine code (JIT compilation) and handles memory allocation, call stack execution, and garbage collection (Mark-and-Sweep).
2. **libuv**: Implements a cross-platform abstraction layer for event-driven asynchronous I/O. It handles the **Event Loop** and manages a background thread pool (default size: 4 threads, configurable via `UV_THREADPOOL_SIZE`) for blocking I/O operations such as disk access (`fs`) and DNS lookups.
3. **Event Loop Execution Phases**:
   * **Timers Phase**: Executes callbacks scheduled by `setTimeout()` and `setInterval()`.
   * **Pending Callbacks Phase**: Executes I/O callbacks deferred to the next loop iteration (e.g., TCP error handling).
   * **Idle / Prepare Phase**: Used internally by Node.js.
   * **Poll Phase**: Retrieves new I/O events; executes I/O-related callbacks. Node.js will block here when appropriate.
   * **Check Phase**: Executes callbacks invoked by `setImmediate()`.
   * **Close Callbacks Phase**: Executes close handlers (e.g., `socket.on('close', ...)`).

> **Microtask Queue Execution Priority:**  
> Microtasks run immediately following the current phase, before transitioning to the next Event Loop phase. The `process.nextTick()` queue has absolute priority over the `Promise` microtask queue.

---

## Exercise 1: Event Loop Mechanics, Microtasks, and Execution Order

### Objective
Diagnose low-level event scheduling order by observing how `process.nextTick()`, `Promise.then()`, `setTimeout()`, `setImmediate()`, and synchronous execution interleave across V8 and `libuv`.

### Step-by-Step Instructions

1. Create a workspace directory and initialize a new test script named `event-loop-test.js`:

```bash
mkdir -p node-sre-lab && cd node-sre-lab
cat << 'EOF' > event-loop-test.js
const fs = require('node:fs');

console.log('[1] Synchronous: Call Stack start');

setTimeout(() => {
  console.log('[2] Timers Phase: setTimeout (0ms)');
}, 0);

setImmediate(() => {
  console.log('[3] Check Phase: setImmediate');
});

process.nextTick(() => {
  console.log('[4] Microtask: process.nextTick');
});

Promise.resolve().then(() => {
  console.log('[5] Microtask: Promise.then');
});

fs.readFile(__filename, () => {
  console.log('[6] Poll Phase: I/O Callback completed');

  setTimeout(() => {
    console.log('[7] Nested Timers Phase: setTimeout inside I/O');
  }, 0);

  setImmediate(() => {
    console.log('[8] Nested Check Phase: setImmediate inside I/O');
  });
});

console.log('[9] Synchronous: Call Stack end');
EOF
```

2. Run the script using the Node.js runtime:

```bash
node event-loop-test.js
```

**Expected CLI Output:**
```text
[1] Synchronous: Call Stack start
[9] Synchronous: Call Stack end
[4] Microtask: process.nextTick
[5] Microtask: Promise.then
[2] Timers Phase: setTimeout (0ms)
[3] Check Phase: setImmediate
[6] Poll Phase: I/O Callback completed
[8] Nested Check Phase: setImmediate inside I/O
[7] Nested Timers Phase: setTimeout inside I/O
```

---

### Comprehension Questions - Exercise 1

1. Why does `[8] Nested Check Phase: setImmediate inside I/O` consistently execute **before** `[7] Nested Timers Phase: setTimeout inside I/O` when scheduled inside an I/O callback?
2. What would happen to the Event Loop if a recursive function invoked `process.nextTick()` indefinitely without returning?

---

## Exercise 2: Module Systems (CommonJS vs. ESM) and Package Lifecycle

### Objective
Compare the structural differences, module loading semantics, and dependency isolation mechanisms between **CommonJS (CJS)** and **ECMAScript Modules (ESM)**, and configure a strict `package.json` manifest.

### Step-by-Step Instructions

1. Initialize a modern Node.js project manifest:

```bash
cat << 'EOF' > package.json
{
  "name": "sre-node-app",
  "version": "1.0.0",
  "description": "Production Node.js Architecture Lab",
  "main": "index.js",
  "type": "module",
  "scripts": {
    "start": "node index.js",
    "test": "node --test"
  },
  "dependencies": {
    "uuid": "^9.0.1"
  },
  "engines": {
    "node": ">=18.0.0"
  }
}
EOF
```

2. Create a CJS helper module named `legacy-config.cjs`:

```bash
cat << 'EOF' > legacy-config.cjs
module.exports = {
  environment: process.env.NODE_ENV || 'development',
  maxConnections: 100
};
EOF
```

3. Create an ESM service module named `metrics.js`:

```bash
cat << 'EOF' > metrics.js
import { performance } from 'node:perf_hooks';

export class SystemMetrics {
  #startTime = performance.now();

  getUptime() {
    return (performance.now() - this.#startTime).toFixed(2);
  }
}

export const formatBytes = (bytes) => `${(bytes / 1024 / 1024).toFixed(2)} MB`;
EOF
```

4. Create the application entry point `index.js` importing both ESM and CJS modules:

```bash
cat << 'EOF' > index.js
import { SystemMetrics, formatBytes } from './metrics.js';
import legacyConfig from './legacy-config.cjs';
import os from 'node:os';

const metrics = new SystemMetrics();

console.log('--- System Diagnostic initialized ---');
console.log(`Environment: ${legacyConfig.environment}`);
console.log(`Max Connections: ${legacyConfig.maxConnections}`);
console.log(`Total Memory: ${formatBytes(os.totalmem())}`);
console.log(`Free Memory: ${formatBytes(os.freemem())}`);
console.log(`Initial Uptime: ${metrics.getUptime()} ms`);
EOF
```

5. Execute the application:

```bash
node index.js
```

**Expected CLI Output:**
```text
--- System Diagnostic initialized ---
Environment: development
Max Connections: 100
Total Memory: 16384.00 MB
Free Memory: 8192.00 MB
Initial Uptime: 2.15 ms
```

---

### Comprehension Questions - Exercise 2

1. How does the module resolution and instantiation process differ between CommonJS (`require()`) and ECMAScript Modules (`import`)?
2. If `package.json` sets `"type": "module"`, how can a developer force a specific file to be interpreted as a CommonJS module without modifying `package.json`?

---

## Exercise 3: Zero-Dependency Asynchronous HTTP Web Server & Streams

### Objective
Implement a production-grade HTTP web server using native `node:http` and `node:stream` modules, handling request routing, query resolution, header manipulation, graceful errors, and memory-efficient streaming I/O.

### Step-by-Step Instructions

1. Create a file named `server.js`:

```bash
cat << 'EOF' > server.js
import http from 'node:http';
import { URL } from 'node:url';
import fs from 'node:fs';
import path from 'node:path';
import { pipeline } from 'node:stream/promises';

const PORT = process.env.PORT || 8080;
const LOG_FILE = path.join(process.cwd(), 'access.log');

const logStream = fs.createWriteStream(LOG_FILE, { flags: 'a' });

const server = http.createServer(async (req, res) => {
  const parsedUrl = new URL(req.url, `http://${req.headers.host}`);
  const timestamp = new Date().toISOString();

  logStream.write(`[${timestamp}] ${req.method} ${parsedUrl.pathname}\n`);

  // Route: GET /api/health
  if (req.method === 'GET' && parsedUrl.pathname === '/api/health') {
    const payload = JSON.stringify({ status: 'UP', uptime: process.uptime() });
    res.writeHead(200, {
      'Content-Type': 'application/json',
      'Content-Length': Buffer.byteLength(payload)
    });
    return res.end(payload);
  }

  // Route: GET /api/log
  if (req.method === 'GET' && parsedUrl.pathname === '/api/log') {
    if (!fs.existsSync(LOG_FILE)) {
      res.writeHead(404, { 'Content-Type': 'application/json' });
      return res.end(JSON.stringify({ error: 'Log file not found' }));
    }

    res.writeHead(200, { 'Content-Type': 'text/plain; charset=utf-8' });
    try {
      const readStream = fs.createReadStream(LOG_FILE);
      await pipeline(readStream, res);
    } catch (err) {
      console.error('Stream failure:', err);
    }
    return;
  }

  // 404 Fallback
  res.writeHead(404, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ error: 'Route not found' }));
});

server.listen(PORT, () => {
  console.log(`Server listening on port ${PORT}`);
});
EOF
```

2. Start the HTTP server in the background:

```bash
node server.js &
SERVER_PID=$!
sleep 1
```

3. Query the health endpoint using `curl`:

```bash
curl -i http://localhost:8080/api/health
```

**Expected CLI Output:**
```http
HTTP/1.1 200 OK
Content-Type: application/json
Content-Length: 35
Date: Fri, 07 Aug 2026 03:30:44 GMT
Connection: keep-alive

{"status":"UP","uptime":0.123456}
```

4. Stream the log file back via HTTP:

```bash
curl -i http://localhost:8080/api/log
```

**Expected CLI Output:**
```http
HTTP/1.1 200 OK
Content-Type: text/plain; charset=utf-8
Date: Fri, 07 Aug 2026 03:30:45 GMT
Connection: keep-alive

[2026-08-07T03:30:44.100Z] GET /api/health
[2026-08-07T03:30:45.200Z] GET /api/log
```

5. Clean up the background process:

```bash
kill $SERVER_PID
```

---

### Comprehension Questions - Exercise 3

1. Why is `stream/promises` pipeline preferable to `fs.readFileSync()` or directly chaining `.pipe()` when handling file downloads over HTTP in Node.js?
2. What problem occurs when a slow network client consumes data slower than the server reads it from disk, and how do Node.js Streams resolve this issue?

---

## Exercise 4: Production Process Control, Signals, and Debugging

### Objective
Implement graceful shutdown signal handling (`SIGINT`/`SIGTERM`), capture unhandled exceptions, and enable runtime inspection flags for production monitoring.

### Step-by-Step Instructions

1. Create a script named `resilient-app.js`:

```bash
cat << 'EOF' > resilient-app.js
import http from 'node:http';

const server = http.createServer((req, res) => {
  res.writeHead(200);
  res.end('Processing workload...\n');
});

server.listen(3000, () => {
  console.log('[App] Operational on PID:', process.pid);
});

// Unhandled Promise Rejection Handler
process.on('unhandledRejection', (reason, promise) => {
  console.error('[ALERT] Unhandled Rejection at:', promise, 'reason:', reason);
});

// Uncaught Exception Handler
process.on('uncaughtException', (err) => {
  console.error('[CRITICAL] Uncaught Exception:', err.message);
  // Graceful shutdown after critical failure
  shutdown('UNCAUGHT_EXCEPTION', 1);
});

// Signal Handling
const shutdown = (signal, exitCode = 0) => {
  console.log(`[Lifecycle] Received ${signal}. Initiating graceful shutdown...`);
  
  server.close(() => {
    console.log('[Lifecycle] HTTP server closed. Releasing resources.');
    process.exit(exitCode);
  });

  // Force shutdown if cleanup hangs
  setTimeout(() => {
    console.error('[Lifecycle] Forced shutdown due to timeout.');
    process.exit(1);
  }, 5000).unref();
};

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));
EOF
```

2. Start the resilient application in the background:

```bash
node resilient-app.js &
APP_PID=$!
sleep 1
```

3. Send a `SIGTERM` signal to trigger the graceful termination sequence:

```bash
kill -s SIGTERM $APP_PID
```

**Expected CLI Output:**
```text
[App] Operational on PID: 42109
[Lifecycle] Received SIGTERM. Initiating graceful shutdown...
[Lifecycle] HTTP server closed. Releasing resources.
```

---

### Comprehension Questions - Exercise 4

1. What is the operational danger of catching `uncaughtException` and choosing **not** to exit the process (`process.exit()`)?
2. What does `.unref()` do when invoked on the `setTimeout()` timer during the graceful shutdown sequence?

---

<details>
<summary><b>Solutions & Comprehension Check Answers</b></summary>

### Exercise 1 Solutions
1. **`setImmediate` vs `setTimeout` inside I/O:**  
   Inside an I/O callback (Poll phase), the event loop completes the Poll phase and transitions immediately to the **Check phase**. Because `setImmediate()` callbacks are executed in the Check phase, `setImmediate` is guaranteed to run *before* the next **Timers phase** (where `setTimeout` resides). When scheduled in the main stack, the ordering depends on system clock alignment; inside I/O callbacks, `setImmediate` is deterministic.
2. **Infinite `process.nextTick()` Recursion:**  
   Because `process.nextTick()` callbacks are executed in the microtask queue *immediately after the current operation finishes and before the Event Loop advances to the next phase*, recursively queuing `nextTick` starves the Event Loop. The loop will never reach the Poll or Timers phase, effectively freezing all I/O handling and timers (causing an Event Loop starvation crash).

---

### Exercise 2 Solutions
1. **Module System Differences:**  
   - **CommonJS (CJS):** Loads synchronously at runtime using dynamic function wrappers (`require()`). Module outputs are mutable copied values (`module.exports`).
   - **ECMAScript Modules (ESM):** Parsed and resolved asynchronously in three distinct static phases (Parsing/Loading, Instantiation, Evaluation) before execution. Exports are **live bindings** (read-only references to memory locations).
2. **Forcing CJS in ESM Projects:**  
   A developer can force Node.js to parse a file as CommonJS by giving it the `.cjs` file extension. Alternatively, setting `"type": "commonjs"` inside a nested `package.json` in a sub-folder overrides the parent project settings for files in that directory.

---

### Exercise 3 Solutions
1. **Why `stream/promises` `pipeline` is superior:**  
   `fs.readFileSync()` buffers the entire file into memory (RAM) at once, causing severe memory spikes for large files. Chaining `.pipe()` without error handling leaves streams open if an HTTP connection drops mid-transfer, leading to file descriptor and memory leaks. `pipeline()` streams data chunk-by-chunk and automatically handles cleanup, backpressure, and error destruction.
2. **Backpressure:**  
   Backpressure occurs when the source (e.g., fast disk read stream) produces data faster than the destination (e.g., slow network socket write stream) can consume it. Uncontrolled buffering leads to unbounded RAM growth. Node.js Streams solve this by using internal buffer limits (`highWaterMark`). When the write buffer fills, the destination signals `write() === false`, prompting the readable stream to `pause()` until a `drain` event is emitted.

---

### Exercise 4 Solutions
1. **Danger of ignoring `uncaughtException`:**  
   An uncaught exception means the V8 process is in an indeterminate state. Memory leaks, dangling database locks, corrupted global states, or half-written sockets may remain. Continuing execution after an uncaught exception risks serving corrupted data or entering deadlocks. The application should log the error and terminate so an orchestrator (such as Kubernetes or Systemd) can launch a clean instance.
2. **Role of `.unref()`:**  
   `.unref()` detaches the timer from the active Event Loop handle count. This guarantees that if all active network connections and I/O tasks close before the 5000ms threshold, Node.js will exit cleanly immediately without waiting for the 5-second timer to expire.

</details>