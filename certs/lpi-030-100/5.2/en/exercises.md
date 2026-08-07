# LPI 030-100: Topic 5.2 – Node.js Express Basics
**Exam Target:** LPI Web Development Essentials (Exam 030-100, Version 1.0)  
**Topic Weight:** 10  
**Target Audience:** SREs, Platform Engineers, and Cloud Native Architects  
**Official Reference:** [LPI Web Development Essentials Overview](https://www.lpi.org/our-certifications/web-development-essentials-overview/) | [ExpressJS Official Documentation](https://expressjs.com/) | [Node.js Documentation](https://nodejs.org/docs/)

---

## Technical Overview & Architecture

Express is an unopinionated, minimal web framework built on top of Node.js's native `http.Server`. Understanding Express at a production level requires knowing how it extends native Node.js HTTP primitives (`http.IncomingMessage` and `http.ServerResponse`) and how its internal routing engine handles request dispatching via a layered middleware execution stack.

```
                              Node.js HTTP Server Pipeline
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                                    v8 Event Loop                                        │
│                                                                                         │
│  Incoming TCP Connection ──> http.Server ('request' event)                             │
│                                           │                                             │
│                                           ▼                                             │
│                                  express() app function                                 │
│                                           │                                             │
│                                           ▼                                             │
│                                  app.handle(req, res)                                   │
│                                           │                                             │
│  ┌────────────────────────────────────────┴──────────────────────────────────────────┐  │
│  │                              express.Router.stack                               │  │
│  │                                                                                 │  │
│  │   Layer 1: Built-in Body Parser (express.json) ──> next()                         │  │
│  │   Layer 2: Security Middleware (Helmet/Cors)  ──> next()                         │  │
│  │   Layer 3: Custom Logger Middleware           ──> next()                         │  │
│  │   Layer 4: Router Match (/api/v1/metrics)     ──> next()                         │  │
│  │   Layer 5: Terminal Route Handler             ──> res.json(...)                  │  │
│  │   Layer 6: Error Handler Middleware           ──> (err, req, res, next)          │  │
│  └─────────────────────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────────────────┘
```

### Core Architecture & Mechanical Internals

1. **Request & Response Delegation:**
   Express extends native `http.IncomingMessage` into `express.Request` (`req`) and `http.ServerResponse` into `express.Response` (`res`) via prototype inheritance. Methods like `res.json()`, `res.status()`, and `req.get()` wrap lower-level Node.js stream operations and header manipulations.

2. **The Middleware Pipeline (`app._router.stack`):**
   Express applications maintain an internal array of `Layer` instances. Each `app.use()`, `app.get()`, or `app.post()` call pushes a new `Layer` object onto `app._router.stack`. A `Layer` encapsulates:
   - A route path matching regular expression.
   - The middleware function reference.
   - The number of declared parameters (`fn.length`). Express relies on function signature arity to differentiate normal middleware (`(req, res, next)`) from error handling middleware (`(err, req, res, next)`).

3. **Asynchronous Execution & Event Loop Considerations:**
   Express 4.x does **not** automatically catch rejected Promises inside asynchronous middleware handlers (`async (req, res, next)`). If an unhandled promise rejection occurs within an `async` route handler, it skips Express error middleware and can trigger an `UnhandledPromiseRejection` or crash the Node.js process. Production configurations must either explicitly wrap async handlers, use a global wrapper, or upgrade to Express 5.x.

---

## Hands-On Guided Exercises

### Exercise 1: Middleware Architecture, Layer Stack Inspection & Request Lifecycle

#### Objective
Build a native Express 4 server, examine the internal router layer stack, inspect prototype inheritance on request/response objects, and write custom diagnostic middleware.

#### Step 1: Initialize the Project Environment
Create a clean directory and initialize a Node.js project using `npm`.

```bash
mkdir -p express-sre-lab && cd express-sre-lab
npm init -y
npm install express@4.19.2
```

Expected output:
```text
Wrote to /home/student/express-sre-lab/package.json:
...
+ express@4.19.2
added 64 packages in 1.2s
```

#### Step 2: Create `server-internals.js`
Create the application file `server-internals.js` with complete, syntactically valid code that exposes `app._router.stack` and demonstrates arity-based middleware execution.

```javascript
const express = require('express');
const app = express();
const PORT = process.env.PORT || 3000;

// Built-in middleware to parse JSON bodies
app.use(express.json());

// Custom Middleware 1: Request Timing & SRE Diagnostics Header
app.use((req, res, next) => {
  req.startTime = process.hrtime.bigint();
  res.setHeader('X-SRE-Engine', 'Express-V8-Runtime');
  
  // Intercept completion to log latency
  res.on('finish', () => {
    const durationNs = process.hrtime.bigint() - req.startTime;
    const durationMs = Number(durationNs) / 1e6;
    console.log(`[METRIC] ${req.method} ${req.originalUrl} - Status: ${res.statusCode} - Latency: ${durationMs.toFixed(3)}ms`);
  });

  next();
});

// Route Handler: GET /health
app.get('/health', (req, res) => {
  res.status(200).json({ status: 'UP', timestamp: new Date().toISOString() });
});

// Route Handler: Internal Diagnostics Route
app.get('/debug/stack', (req, res) => {
  // Inspect internal router stack
  const stackSummary = app._router.stack.map((layer, index) => {
    return {
      index,
      name: layer.name,
      keys: layer.keys,
      regexp: layer.regexp.toString(),
      handleArity: layer.handle.length,
      isRoute: !!layer.route
    };
  });

  res.json({
    prototypeChecks: {
      reqInheritsIncomingMessage: Object.getPrototypeOf(Object.getPrototypeOf(req)).constructor.name === 'IncomingMessage',
      resInheritsServerResponse: Object.getPrototypeOf(Object.getPrototypeOf(res)).constructor.name === 'ServerResponse'
    },
    routerStack: stackSummary
  });
});

// Terminal Error Handling Middleware (Arity = 4)
app.use((err, req, res, next) => {
  console.error('[ERROR] Caught by terminal handler:', err.message);
  res.status(500).json({ error: 'Internal Error', message: err.message });
});

app.listen(PORT, () => {
  console.log(`[INFO] Server listening on port ${PORT}`);
});
```

#### Step 3: Run the Server and Verify Diagnostics
Start the server in the background or terminal:

```bash
node server-internals.js
```

Expected output in server terminal:
```text
[INFO] Server listening on port 3000
```

Execute a request to `/debug/stack` using `curl`:

```bash
curl -s http://localhost:3000/debug/stack | node -e "console.log(JSON.stringify(JSON.parse(require('fs').readFileSync(0, 'utf-8')), null, 2))"
```

Expected HTTP output snippet:
```json
{
  "prototypeChecks": {
    "reqInheritsIncomingMessage": true,
    "resInheritsServerResponse": true
  },
  "routerStack": [
    {
      "index": 0,
      "name": "query",
      "handleArity": 3,
      "isRoute": false
    },
    {
      "index": 1,
      "name": "expressInit",
      "handleArity": 3,
      "isRoute": false
    },
    {
      "index": 2,
      "name": "jsonParser",
      "handleArity": 3,
      "isRoute": false
    },
    {
      "index": 3,
      "name": "<anonymous>",
      "handleArity": 3,
      "isRoute": false
    },
    {
      "index": 4,
      "name": "bound dispatch",
      "handleArity": 3,
      "isRoute": true
    },
    {
      "index": 5,
      "name": "bound dispatch",
      "handleArity": 3,
      "isRoute": true
    },
    {
      "index": 6,
      "name": "<anonymous>",
      "handleArity": 4,
      "isRoute": false
    }
  ]
}
```

Check server console output for metric tracking:
```text
[METRIC] GET /debug/stack - Status: 200 - Latency: 4.120ms
```

---

#### Comprehension Questions - Exercise 1

1. Why does Express inspect `layer.handle.length` to identify error-handling middleware, and what happens if an engineer defines an error handler as `(err, req, res) => {}` omitting `next`?
2. If `next()` is called multiple times inside a single middleware function, what is the exact runtime behavior in Node.js?

---

### Exercise 2: Modular Routing, Async Error Propagation & Request Parsing

#### Objective
Implement modular sub-routers (`express.Router()`), parse path parameters (`req.params`) and request bodies (`req.body`), and design a production-safe async error propagation wrapper for Express 4.x.

#### Step 1: Create `routes/api.js`
Create a directory named `routes` and create `api.js` implementing a modular REST resource with async handlers.

```bash
mkdir -p routes
```

Create `routes/api.js`:

```javascript
const express = require('express');
const router = express.Router();

// Simulated database resource
const metricsDB = new Map([
  ['node-1', { id: 'node-1', cpuUsage: 42.5, memoryFreeMB: 1024 }],
  ['node-2', { id: 'node-2', cpuUsage: 89.1, memoryFreeMB: 128 }]
]);

// Utility: Async Handler Wrapper for Express 4.x
const asyncHandler = (fn) => (req, res, next) => {
  Promise.resolve(fn(req, res, next)).catch(next);
};

// GET /api/v1/nodes/:id - Path Parameter Extraction
router.get('/nodes/:id', asyncHandler(async (req, res) => {
  const nodeId = req.params.id;
  
  if (!metricsDB.has(nodeId)) {
    const err = new Error(`Node identifier '${nodeId}' not found in cluster state.`);
    err.statusCode = 404;
    throw err; // Caught by asyncHandler and forwarded to next(err)
  }

  res.status(200).json({
    success: true,
    data: metricsDB.get(nodeId)
  });
}));

// POST /api/v1/nodes - JSON Body Parsing & Mutation
router.post('/nodes', asyncHandler(async (req, res) => {
  const { id, cpuUsage, memoryFreeMB } = req.body;

  if (!id || typeof cpuUsage !== 'number' || typeof memoryFreeMB !== 'number') {
    const err = new Error('Invalid payload parameters. Required: id (string), cpuUsage (number), memoryFreeMB (number)');
    err.statusCode = 400;
    throw err;
  }

  if (metricsDB.has(id)) {
    const err = new Error(`Node '${id}' already registered.`);
    err.statusCode = 409;
    throw err;
  }

  const newNode = { id, cpuUsage, memoryFreeMB };
  metricsDB.set(id, newNode);

  res.status(201).json({
    success: true,
    data: newNode
  });
}));

module.exports = router;
```

#### Step 2: Create `app-modular.js`
Create `app-modular.js` to mount the sub-router and handle standard HTTP status codes dynamically.

```javascript
const express = require('express');
const apiRouter = require('./routes/api');

const app = express();
const PORT = 3001;

// Body Parsers
app.use(express.json({ limit: '1mb' }));
app.use(express.urlencoded({ extended: false }));

// Mount Modular Sub-Router
app.use('/api/v1', apiRouter);

// 404 Catch-All Route Handler
app.use((req, res, next) => {
  const err = new Error(`Resource not found: ${req.method} ${req.originalUrl}`);
  err.statusCode = 404;
  next(err);
});

// Centralized Production Error Handling Middleware
app.use((err, req, res, next) => {
  const statusCode = err.statusCode || 500;
  
  console.error(`[ERROR] [${new Date().toISOString()}] ${req.method} ${req.originalUrl} - Status: ${statusCode} - ${err.message}`);
  
  res.status(statusCode).json({
    error: {
      status: statusCode,
      message: err.message,
      timestamp: new Date().toISOString()
    }
  });
});

app.listen(PORT, () => {
  console.log(`[INFO] Modular App listening on port ${PORT}`);
});
```

#### Step 3: Run and Test API Endpoints
Start the application:

```bash
node app-modular.js
```

In another terminal, test valid and invalid requests using `curl`.

1. **Test GET existing node:**
```bash
curl -i http://localhost:3001/api/v1/nodes/node-1
```
Expected output:
```http
HTTP/1.1 200 OK
Content-Type: application/json; charset=utf-8
Content-Length: 68

{"success":true,"data":{"id":"node-1","cpuUsage":42.5,"memoryFreeMB":1024}}
```

2. **Test GET non-existing node (Async Error Propagation):**
```bash
curl -i http://localhost:3001/api/v1/nodes/node-99
```
Expected output:
```http
HTTP/1.1 404 Not Found
Content-Type: application/json; charset=utf-8

{"error":{"status":404,"message":"Node identifier 'node-99' not found in cluster state.","timestamp":"2026-08-07T03:32:00.000Z"}}
```

3. **Test POST invalid payload:**
```bash
curl -i -X POST http://localhost:3001/api/v1/nodes \
  -H "Content-Type: application/json" \
  -d '{"id": "node-3", "cpuUsage": "invalid_number"}'
```
Expected output:
```http
HTTP/1.1 400 Bad Request
Content-Type: application/json; charset=utf-8

{"error":{"status":400,"message":"Invalid payload parameters. Required: id (string), cpuUsage (number), memoryFreeMB (number)","timestamp":"2026-08-07T03:32:00.000Z"}}
```

---

#### Comprehension Questions - Exercise 2

1. What occurs internally when `express.json()` receives a request with a header `Content-Type: application/json` where the body size exceeds the configured `limit: '1mb'`?
2. If `asyncHandler` is omitted in an Express 4 route handler that throws an error after an `await` point, what happens to the HTTP client connection?

---

### Exercise 3: Graceful Shutdown (POSIX Signals) & Stream Memory Management

#### Objective
Implement an SRE pattern for zero-downtime lifecycle management, intercepting POSIX signals (`SIGTERM`, `SIGINT`), refusing new connections, draining ongoing requests, and implementing stream responses to prevent V8 memory exhaustion.

#### Step 1: Create `server-sre-lifecycle.js`
Write a production server that demonstrates proper signal handling and response streaming using native Node.js streams via Express responses.

```javascript
const express = require('express');
const { Readable } = require('stream');
const app = express();
const PORT = 3002;

let isShuttingDown = false;

// Health Check with Liveness/Readiness Awareness
app.use((req, res, next) => {
  if (isShuttingDown && req.path !== '/health/liveness') {
    res.setHeader('Connection', 'close');
    return res.status(530).json({ error: 'Service Unavailable - Server Shutting Down' });
  }
  next();
});

app.get('/health/liveness', (req, res) => {
  res.status(200).json({ status: 'ALIVE' });
});

app.get('/health/readiness', (req, res) => {
  if (isShuttingDown) {
    return res.status(503).json({ status: 'NOT_READY', reason: 'SIGTERM received' });
  }
  res.status(200).json({ status: 'READY' });
});

// Route: Stream Large Log Payload (Zero V8 Memory Buffering)
app.get('/logs/stream', (req, res) => {
  res.setHeader('Content-Type', 'text/plain; charset=utf-8');
  res.setHeader('Transfer-Encoding', 'chunked');

  let lineCount = 0;
  const maxLines = 10000;

  // Create custom readable stream simulating log tailing
  const logStream = new Readable({
    read() {
      if (lineCount >= maxLines) {
        this.push(null); // End of stream
        return;
      }
      lineCount++;
      const chunk = `[LOG-LINE ${lineCount}] ${new Date().toISOString()} - SRE Event Monitoring Log Entry\n`;
      this.push(chunk);
    }
  });

  logStream.pipe(res);
});

const server = app.listen(PORT, () => {
  console.log(`[INFO] SRE Production Server running on PID ${process.pid} at port ${PORT}`);
});

// POSIX Signal Handling for Graceful Shutdown
const initiateGracefulShutdown = (signal) => {
  console.log(`[NOTICE] Received signal: ${signal}. Initiating graceful shutdown sequence...`);
  isShuttingDown = true;

  // Stop accepting new connections on the underlying HTTP server
  server.close((err) => {
    if (err) {
      console.error('[ERROR] Error closing HTTP server:', err);
      process.exit(1);
    }
    console.log('[INFO] HTTP server successfully closed. Cleaning up database connections & event loops.');
    process.exit(0);
  });

  // Forced termination timeout if connections fail to drain
  setTimeout(() => {
    console.error('[FATAL] Forced shutdown threshold (10s) reached. Terminating un-drained process.');
    process.exit(1);
  }, 10000).unref(); // Prevent timer from keeping event loop alive unnecessarily
};

process.on('SIGTERM', () => initiateGracefulShutdown('SIGTERM'));
process.on('SIGINT', () => initiateGracefulShutdown('SIGINT'));
```

#### Step 2: Verify Stream Latency & Signal Handling
Start the server in background execution:

```bash
node server-sre-lifecycle.js &
SERVER_PID=$!
sleep 1
```

Expected output:
```text
[INFO] SRE Production Server running on PID 12345 at port 3002
```

Stream logs using `curl` and inspect stream chunks:

```bash
curl -s http://localhost:3002/logs/stream | head -n 5
```

Expected output:
```text
[LOG-LINE 1] 2026-08-07T03:32:00.000Z - SRE Event Monitoring Log Entry
[LOG-LINE 2] 2026-08-07T03:32:00.000Z - SRE Event Monitoring Log Entry
[LOG-LINE 3] 2026-08-07T03:32:00.000Z - SRE Event Monitoring Log Entry
[LOG-LINE 4] 2026-08-07T03:32:00.000Z - SRE Event Monitoring Log Entry
[LOG-LINE 5] 2026-08-07T03:32:00.000Z - SRE Event Monitoring Log Entry
```

Issue `SIGTERM` to test graceful termination:

```bash
kill -s SIGTERM $SERVER_PID
```

Expected output in console:
```text
[NOTICE] Received signal: SIGTERM. Initiating graceful shutdown sequence...
[INFO] HTTP server successfully closed. Cleaning up database connections & event loops.
```

---

#### Comprehension Questions - Exercise 3

1. Why is `setTimeout(...).unref()` used when setting a safety cleanup timer during process termination?
2. What is the memory advantage of using `logStream.pipe(res)` compared to constructing a single large string in memory and executing `res.send(largeString)`?

---

### Exercise 4: Advanced Diagnostics: Event Loop Delay Tracking & Heap Dumps

#### Objective
Integrate Node.js `perf_hooks` and `v8` modules to build diagnostic endpoints inside Express for monitoring Event Loop delay spikes and triggering heap dumps under load.

#### Step 1: Create `server-diagnostics.js`
Write the diagnostic server demonstrating V8 heap management and event loop tracking.

```javascript
const express = require('express');
const { monitorEventLoopDelay } = require('perf_hooks');
const v8 = require('v8');
const path = require('path');
const fs = require('fs');

const app = express();
const PORT = 3003;

// Initialize Event Loop Delay Monitor (Resolution: 10ms)
const hgram = monitorEventLoopDelay({ resolution: 10 });
hgram.enable();

// Route: Real-Time Event Loop Metrics
app.get('/metrics/event-loop', (req, res) => {
  res.json({
    minNs: hgram.min,
    maxNs: hgram.max,
    meanNs: hgram.mean,
    stddevNs: hgram.stddev,
    p50Ns: hgram.percentile(50),
    p99Ns: hgram.percentile(99),
    memoryUsage: process.memoryUsage()
  });
});

// Route: Intentionally Block Event Loop (Simulating CPU Intensive Task)
app.get('/debug/block', (req, res) => {
  const durationMs = parseInt(req.query.ms, 10) || 500;
  const start = Date.now();
  
  // Synchronous CPU blocking loop
  while (Date.now() - start < durationMs) {
    Math.sqrt(Math.random() * 100000);
  }

  res.json({ message: `Event loop blocked synchronously for ${durationMs}ms` });
});

// Route: Generate Heap Snapshot for Memory Leak Diagnosis
app.get('/debug/heapdump', (req, res) => {
  const snapshotFileName = `heapdump-${Date.now()}.heapsnapshot`;
  const filePath = path.join(__dirname, snapshotFileName);

  const stream = v8.getHeapSnapshot();
  const writeStream = fs.createWriteStream(filePath);

  stream.pipe(writeStream);

  writeStream.on('finish', () => {
    const stats = fs.statSync(filePath);
    res.json({
      success: true,
      file: snapshotFileName,
      sizeBytes: stats.size
    });
  });
});

app.listen(PORT, () => {
  console.log(`[INFO] SRE Diagnostics Server listening on port ${PORT}`);
});
```

#### Step 2: Execute Diagnostics & Trigger Event Loop Degradation
Start the server:

```bash
node server-diagnostics.js &
DIAG_PID=$!
sleep 1
```

1. **Fetch baseline event loop statistics:**
```bash
curl -s http://localhost:3003/metrics/event-loop | node -e "console.log(JSON.stringify(JSON.parse(require('fs').readFileSync(0, 'utf-8')), null, 2))"
```

2. **Induce a 1000ms Event Loop Block:**
```bash
curl -s "http://localhost:3003/debug/block?ms=1000"
```
Expected output:
```json
{"message":"Event loop blocked synchronously for 1000ms"}
```

3. **Fetch updated metrics to verify P99 latency spike:**
```bash
curl -s http://localhost:3003/metrics/event-loop | node -e "const data=JSON.parse(require('fs').readFileSync(0, 'utf-8')); console.log('p99 (ms):', data.p99Ns / 1e6);"
```
Expected output showing the delay spike:
```text
p99 (ms): 1000.447
```

4. **Trigger a V8 Heap Dump:**
```bash
curl -s http://localhost:3003/debug/heapdump
```
Expected output:
```json
{"success":true,"file":"heapdump-1770435120000.heapsnapshot","sizeBytes":4820194}
```

Clean up process:
```bash
kill -s SIGTERM $DIAG_PID
```

---

#### Comprehension Questions - Exercise 4

1. Why does a synchronous CPU-bound loop inside a Node.js Express handler degrade latency across *all* concurrent client requests connected to that process?
2. In a production Kubernetes deployment, how do high event loop delays affect HTTP liveness and readiness probe checks?

---

## Solutions & Answer Keys

<details>
<summary>Click to view Comprehension Question Answers</summary>

### Answers for Exercise 1

1. **Function Arity and Error Handler Registration:**
   Express relies on JavaScript's Function object `.length` property to reflect the declared parameter count (arity). Normal middleware declares 3 parameters `(req, res, next)`, whereas error handling middleware strictly requires 4 parameters `(err, req, res, next)`. If an engineer defines an error handler as `(err, req, res) => {}`, `fn.length` evaluates to `3`. Express will treat it as a standard middleware function during stack iteration, passing `req` into the first parameter `err`, `res` into `req`, and `next` into `res`. This results in `TypeError: res.status is not a function` runtime failures and skips error processing entirely.

2. **Multiple `next()` Invocations:**
   The `next()` callback advances the index pointer inside `app._router.stack`. Calling `next()` multiple times inside a single middleware function causes Express to execute subsequent layers multiple times for the same request cycle. If downstream handlers perform response output (`res.send()` or `res.json()`), the second call throws an uncaught Node.js core exception: `ERR_HTTP_HEADERS_SENT: Cannot set headers after they are sent to the client`.

---

### Answers for Exercise 2

1. **Body-Parser Limit Enforcement:**
   When the payload size exceeds the specified threshold (e.g., `1mb`), the internal `body-parser` stream parser aborts stream consumption and creates a `PayloadTooLargeError` object (`err.type = 'entity.too.large'`, `err.statusCode = 413`). It invokes `next(err)`, bypassing downstream route handlers and passing control directly to configured error handling middleware.

2. **Unwrapped Async Errors in Express 4.x:**
   Express 4 route dispatchers run synchronously relative to the middleware call chain. If an `async` function rejects or throws an error after an `await` point and is **not** wrapped in a try/catch invoking `next(err)` (or using a wrapper like `asyncHandler`), the returned Promise rejection is unhandled by Express. The HTTP connection remains hanging until client timeout occurs, and Node.js logs an `UnhandledPromiseRejectionWarning` (or terminates the process depending on `--unhandled-rejections` mode).

---

### Answers for Exercise 3

1. **Purpose of `setTimeout(...).unref()`:**
   By default, active timers keep the Node.js Event Loop active. Calling `.unref()` on the `Timeout` object detaches it from the Event Loop's reference counter. If all ongoing HTTP requests and socket connections finish draining before the 10-second threshold expires, the Node.js process exits immediately without waiting for the timer to fire.

2. **Memory Overhead of `pipe(res)` vs `res.send()`:**
   Using `res.send(largeString)` requires allocating the full response buffer in the V8 Heap prior to serialization, which can exceed the maximum heap memory limit (`--max-old-space-size`) or trigger frequent Garbage Collection (GC) pauses. In contrast, `logStream.pipe(res)` streams data in small chunks (typically 16KB-64KB buffers), utilizing HTTP chunked transfer encoding (`Transfer-Encoding: chunked`). Memory usage remains flat regardless of total response size, and TCP backpressure automatically pauses stream reading if the client network socket is slow.

---

### Answers for Exercise 4

1. **Global Impact of Event Loop Blocking:**
   Node.js operates on a single-threaded Event Loop architecture for JavaScript execution and request dispatching. When a synchronous CPU loop runs, it blocks the main thread completely. The Event Loop cannot process I/O events, complete socket reads/writes, or schedule timer callbacks for *any* incoming or existing HTTP connection on that thread until the synchronous operation completes.

2. **Impact on Kubernetes Probes:**
   Kubernetes periodically sends HTTP GET requests to container liveness (`/health/liveness`) and readiness (`/health/readiness`) endpoints. If the Event Loop is blocked by a long-running CPU task, the Node.js process cannot respond to the probe requests within the configured `timeoutSeconds`. If failed attempts exceed `failureThreshold`, Kubernetes falsely flags the pod as un-ready (removing it from Endpoints) or restarts the container (liveness failure), creating cascading service outages.

</details>

---

## Command Reference Summary

| Task | Command |
| :--- | :--- |
| **Initialize Express Project** | `npm init -y && npm install express@4.19.2` |
| **Start Express Server** | `node server.js` |
| **Inspect Headers & Response** | `curl -i http://localhost:3000/health` |
| **Simulate JSON Payload** | `curl -X POST http://localhost:3001/api/v1/nodes -H "Content-Type: application/json" -d '{"id":"node-1","cpuUsage":50,"memoryFreeMB":512}'` |
| **Send POSIX Termination Signal** | `kill -s SIGTERM <PID>` |
| **Stream Log Tail Endpoint** | `curl -s http://localhost:3002/logs/stream \| head -n 20` |
| **Generate V8 Heap Snapshot** | `curl -s http://localhost:3003/debug/heapdump` |