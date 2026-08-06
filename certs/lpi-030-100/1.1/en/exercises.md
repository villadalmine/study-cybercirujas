# LPI 030-100: Web Development Essentials — Topic 1.1: Software Development Basics
**Exam Target**: LPI-030-100 (v1.0)  
**Topic Weight**: 2.5  
**Audience**: Site Reliability Engineers, Platform Architects, and Systems Developers  

---

## Official Reference Documentation
* [LPI Web Development Essentials Overview & Objectives](https://www.lpi.org/our-certifications/web-development-essentials-overview/)
* [MDN Web Docs: HTTP Overview & Protocols](https://developer.mozilla.org/en-US/docs/Web/HTTP/Overview)
* [Git Documentation: Internals & Architecture](https://git-scm.com/book/en/v2/Git-Internals-Plumbing-and-Porcelain)
* [Node.js Documentation: V8 Execution & Event Loop](https://nodejs.org/en/learn/getting-started/the-v8-javascript-engine)
* [The Twelve-Factor App Methodology](https://12factor.net/)

---

## Architecture Overview & Mechanical Foundations

```
+---------------------------------------------------------------------------------------------------+
|                                 SOFTWARE DEVELOPMENT PIPELINE                                     |
+---------------------------------------------------------------------------------------------------+
|  1. CODE CREATION        2. VERSION CONTROL        3. COMPILATION / BUILD      4. RUNTIME EXECUTION |
|  +----------------+      +---------------+         +-------------------+       +-----------------+ |
|  | Developer Work | ---> | Git Repository| ------> | CI/CD Pipeline    | ----> | Environment     | |
|  | (IDE / Local)  |      | (DAG/Objects) |         | (Artifact / Image)|       | (Dev/Stg/Prod)  | |
|  +----------------+      +---------------+         +-------------------+       +-----------------+ |
+---------------------------------------------------------------------------------------------------+
                                                                                          |          
   +--------------------------------------------------------------------------------------+          
   |                                                                                                 
   v                                                                                                 
+---------------------------------------------------------------------------------------------------+
|                                RUNTIME EXECUTION MECHANICS                                        |
+---------------------------------------------------------------------------------------------------+
|  A. COMPILED (C/Go)             B. INTERPRETED (Python)            C. JIT / HYBRID (JS / Node.js) |
|  +-----------------------+      +-------------------------+        +----------------------------+ |
|  | Source -> Machine Code|      | Source -> Bytecode      |        | Source -> AST -> Bytecode  | |
|  | Direct OS Kernel Exec |      | Executed via Virtual    |        | Ignited -> Profiler        | |
|  | (Native ELF Binary)   |      | Machine (PVM Loop)      |        | -> TurboFan Machine Code   | |
|  +-----------------------+      +-------------------------+        +----------------------------+ |
+---------------------------------------------------------------------------------------------------+
```

Software Development Basics covers the fundamental paradigms, architectural patterns, runtime models, source code management techniques, and environment lifecycle models required to deploy web systems.

---

## Exercise 1: Runtime Execution Paradigms — Compiled vs. Interpreted vs. JIT Engines

### Objective
Examine how source code transforms into executable instructions across Compiled (C/Native ELF), Interpreted (Python Bytecode), and Just-In-Time compiled (JavaScript V8 Engine) execution models. Analyze CPU/Memory trade-offs and runtime diagnostics.

### Hands-On Execution Steps

#### Step 1.1: Build and analyze a statically compiled binary
Create a low-level application in C to observe native compilation into an Executable and Linkable Format (ELF) binary.

```bash
mkdir -p ~/lpi_lab/ex1 && cd ~/lpi_lab/ex1

cat << 'EOF' > app.c
#include <stdio.h>

int main() {
    unsigned long long sum = 0;
    for (unsigned long long i = 0; i < 100000000ULL; i++) {
        sum += i;
    }
    printf("Result: %llu\n", sum);
    return 0;
}
EOF

gcc -O2 app.c -o app_compiled
file app_compiled
```

**Expected Output:**
```text
app_compiled: ELF 64-bit LSB executable, x86-64, version 1 (SYSV), dynamically linked, interpreter /lib64/ld-linux-x86-64.so.2, for GNU/Linux 3.2.0, BuildID[sha1]=..., stripped
```

Measure execution time using `time`:
```bash
time ./app_compiled
```

**Expected Output:**
```text
Result: 4999999950000000

real    0m0.003s
user    0m0.003s
sys     0m0.000s
```

#### Step 1.2: Inspect interpreted runtime mechanics via Python Bytecode
Create an equivalent Python script and inspect the intermediate opcode generated for the Python Virtual Machine (PVM).

```bash
cat << 'EOF' > app.py
import dis

def calculate():
    total = 0
    for i in range(100000000):
        total += i
    return total

if __name__ == "__main__":
    print(f"Result: {calculate()}")
EOF

python3 -m dis app.py | head -n 25
```

**Expected Output:**
```text
  3           0 LOAD_CONST               1 (0)
              2 STORE_FAST               0 (total)

  4           4 LOAD_GLOBAL              0 (range)
              6 LOAD_CONST               2 (100000000)
              8 CALL_FUNCTION            1
             10 GET_ITER
        >>   12 FOR_ITER                 6 (to 26)
             14 STORE_FAST               1 (i)

  5          16 LOAD_FAST                0 (total)
             18 LOAD_FAST                1 (i)
             20 INPLACE_ADD
             22 STORE_FAST               0 (total)
             24 JUMP_ABSOLUTE           12
        >>   26 LOAD_FAST                0 (total)
             28 RETURN_VALUE
```

Measure execution time of the interpreted runtime:
```bash
time python3 app.py
```

**Expected Output:**
```text
Result: 4999999950000000

real    0m3.842s
user    0m3.835s
sys     0m0.004s
```

#### Step 1.3: Inspect JIT compilation and optimization in Node.js (V8 Engine)
Create a JavaScript equivalent and observe V8's transition from Ignition interpreter bytecode to TurboFan optimized machine code.

```bash
cat << 'EOF' > app.js
function calculate() {
    let total = 0;
    for (let i = 0; i < 100000000; i++) {
        total += i;
    }
    return total;
}

console.time("JS_Execution");
const result = calculate();
console.timeEnd("JS_Execution");
console.log("Result:", result);
EOF

node --trace-opt app.js
```

**Expected Output:**
```text
[marking 0x... <JSFunction calculate ...> for optimization to TURBOFAN, reason: small function]
[compiling method 0x... <JSFunction calculate ...> (target TURBOFAN) using TurboFan]
[completed compiling 0x... <JSFunction calculate ...> (target TURBOFAN) - OSR]
JS_Execution: ~42.15ms
Result: 4999999950000000
```

---

### Verification Questions (Exercise 1)

1. **Why does the compiled binary (`app_compiled`) execute orders of magnitude faster than the Python interpreted script (`app.py`) for the exact same loop counter logic?**
2. **What occurs inside the V8 engine when `--trace-opt` reports `marking for optimization to TURBOFAN`?**
3. **If a web backend system requires minimal startup latency (cold start < 10ms) and low, deterministic memory consumption, which execution paradigm is most suitable and why?**

---

## Exercise 2: Web Architecture & HTTP Mechanics — Client vs. Server-Side Execution

### Objective
Build a production-grade lightweight Node.js HTTP web service using standard core libraries. Inspect the client/server HTTP protocol flow, custom headers, TCP socket state, and status codes using lower-level CLI tools (`curl`, `ss`/`netstat`).

### Hands-On Execution Steps

#### Step 2.1: Implement a syntactically valid HTTP web server
Create a native Node.js HTTP server supporting REST API paradigms, structured routing, dynamic JSON responses, and HTTP response headers.

```bash
mkdir -p ~/lpi_lab/ex2 && cd ~/lpi_lab/ex2

cat << 'EOF' > server.js
const http = require('http');
const url = require('url');

const PORT = 8080;

const server = http.createServer((req, res) => {
    const parsedUrl = url.parse(req.url, true);
    const method = req.method;

    // Security & Infrastructure Headers
    res.setHeader('Content-Type', 'application/json');
    res.setHeader('X-Content-Type-Options', 'nosniff');
    res.setHeader('Server', 'SRE-Production-Core/1.0');

    if (parsedUrl.pathname === '/api/v1/health' && method === 'GET') {
        res.statusCode = 200;
        res.end(JSON.stringify({
            status: 'UP',
            timestamp: new Date().toISOString(),
            uptime: process.uptime()
        }));
    } else if (parsedUrl.pathname === '/api/v1/data' && method === 'POST') {
        let body = '';
        req.on('data', chunk => { body += chunk.toString(); });
        req.on('end', () => {
            try {
                const parsed = JSON.parse(body);
                res.statusCode = 201;
                res.end(JSON.stringify({ message: 'Resource created', data: parsed }));
            } catch (err) {
                res.statusCode = 400;
                res.end(JSON.stringify({ error: 'Invalid JSON payload' }));
            }
        });
    } else {
        res.statusCode = 404;
        res.end(JSON.stringify({ error: 'Route not found' }));
    }
});

server.listen(PORT, '127.0.0.1', () => {
    console.log(`Server running on http://127.0.0.1:${PORT}`);
});
EOF

node server.js &
SERVER_PID=$!
sleep 1
```

**Expected Output:**
```text
Server running on http://127.0.0.1:8080
```

#### Step 2.2: Inspect HTTP request/response frame details with verbose `curl`
Execute HTTP requests to analyze status codes, request headers, and response metadata.

```bash
curl -i -X GET http://127.0.0.1:8080/api/v1/health
```

**Expected Output:**
```http
HTTP/1.1 200 OK
Content-Type: application/json
X-Content-Type-Options: nosniff
Server: SRE-Production-Core/1.0
Date: Thu, 06 Aug 2026 18:50:00 GMT
Connection: keep-alive
Keep-Alive: timeout=5
Content-Length: 78

{"status":"UP","timestamp":"2026-08-06T18:50:00.000Z","uptime":1.0421}
```

Test error handling (400 Bad Request):
```bash
curl -i -X POST http://127.0.0.1:8080/api/v1/data \
  -H "Content-Type: application/json" \
  -d "{ invalid_json: "
```

**Expected Output:**
```http
HTTP/1.1 400 Bad Request
Content-Type: application/json
X-Content-Type-Options: nosniff
Server: SRE-Production-Core/1.0
Date: Thu, 06 Aug 2026 18:50:05 GMT
Connection: keep-alive
Content-Length: 30

{"error":"Invalid JSON payload"}
```

#### Step 2.3: Analyze underlying TCP socket bindings
Inspect the listening socket in Linux system metrics via `ss`.

```bash
ss -tulpn | grep 8080
```

**Expected Output:**
```text
tcp   LISTEN 0      512        127.0.0.1:8080      0.0.0.0:*    users:(("node",pid=...,fd=18))
```

Clean up background job:
```bash
kill $SERVER_PID
```

---

### Verification Questions (Exercise 2)

1. **In Client-Side Rendering (CSR) vs. Server-Side Rendering (SSR), where does JavaScript execution take place, and how does this affect First Contentful Paint (FCP) and server CPU load?**
2. **What is the architectural significance of returning `X-Content-Type-Options: nosniff` in HTTP server headers?**
3. **During an outage diagnosis, `curl` returns `curl: (7) Failed to connect to 127.0.0.1 port 8080: Connection refused`. Does this indicate an HTTP application code error (e.g., 500 Internal Server Error) or a lower-level transport layer issue? Explain using the TCP lifecycle.**

---

## Exercise 3: Version Control Systems — Git DAG & Internals Mechanics

### Objective
Gain deep low-level understanding of Git internal architecture: the Directed Acyclic Graph (DAG), object types (`blob`, `tree`, `commit`, `annotated tag`), plumbing commands, pointers (`HEAD`, branches), and conflict resolution techniques.

```
+-----------------------------------------------------------------------------------+
|                                 GIT DAG INTERNALS                                 |
+-----------------------------------------------------------------------------------+
|  BRANCH REF: refs/heads/main -----> COMMIT OBJECT (hash: 7a8f...)                 |
|                                     |-- tree: 3b1c...                             |
|                                     |-- parent: 1e4a...                           |
|                                     |-- author / committer                        |
|                                     `-- message: "feat: initial API"              |
|                                              |                                    |
|                                              v                                    |
|                                     TREE OBJECT (hash: 3b1c...)                   |
|                                     |-- 100644 blob 9d2e...    app.js           |
|                                     `-- 040000 tree 8e4f...    src/             |
|                                                    |                              |
|                                                    v                              |
|                                           BLOB OBJECT (hash: 9d2e...)             |
|                                           (Raw File Contents Only)                |
+-----------------------------------------------------------------------------------+
```

### Hands-On Execution Steps

#### Step 3.1: Initialize repository and inspect `.git` structure
Create a sandbox repository and analyze the underlying object storage engine.

```bash
mkdir -p ~/lpi_lab/ex3 && cd ~/lpi_lab/ex3
git init
ls -la .git
```

**Expected Output:**
```text
total 24
drwxr-xr-x 7 user user 4096 Aug  6 18:50 .
drwxr-xr-x 5 user user 4096 Aug  6 18:50 ..
-rw-r--r-- 1 user user   23 Aug  6 18:50 HEAD
-rw-r--r-- 1 user user  130 Aug  6 18:50 config
-rw-r--r-- 1 user user   73 Aug  6 18:50 description
drwxr-xr-x 2 user user 4096 Aug  6 18:50 hooks
drwxr-xr-x 2 user user 4096 Aug  6 18:50 info
drwxr-xr-x 4 user user 4096 Aug  6 18:50 objects
drwxr-xr-x 2 user user 4096 Aug  6 18:50 refs
```

#### Step 3.2: Create objects manually using Git plumbing commands
Generate a raw blob directly into `.git/objects` without `git add`.

```bash
BLOB_HASH=$(echo "Production Platform Config" | git hash-object -w --stdin)
echo "Blob Hash: ${BLOB_HASH}"
```

**Expected Output:**
```text
Blob Hash: b4fa528a4794e6378c25dbfbf21a7114ff35aa94
```

Inspect object type and contents using `git cat-file`:
```bash
git cat-file -t ${BLOB_HASH}
git cat-file -p ${BLOB_HASH}
```

**Expected Output:**
```text
blob
Production Platform Config
```

#### Step 3.3: Simulate a branching conflict and perform manual resolution
Create a commit history with divergent branches on the same file lines.

```bash
echo "log_level = info" > config.ini
git add config.ini
git commit -m "Initial config"

# Create feature branch
git checkout -b feature/verbose-logging
echo "log_level = debug" > config.ini
git commit -am "Set debug log level"

# Switch back to main branch and create conflicting change
git checkout main
echo "log_level = warn" > config.ini
git commit -am "Set warn log level"

# Trigger merge conflict
git merge feature/verbose-logging
```

**Expected Output:**
```text
Auto-merging config.ini
CONFLICT (content): Merge conflict in config.ini
Automatic merge failed; fix conflicts and then commit the result.
```

Inspect status and conflict markers:
```bash
cat config.ini
```

**Expected Output:**
```text
<<<<<<< HEAD
log_level = warn
=======
log_level = debug
>>>>>>> feature/verbose-logging
```

Resolve conflict, stage file, and finalize merge:
```bash
cat << 'EOF' > config.ini
log_level = info
EOF

git add config.ini
git commit -m "Fix merge conflict in config.ini: retain info log level"
git log --graph --oneline --all
```

**Expected Output:**
```text
*   e5a9b2c (HEAD -> main) Fix merge conflict in config.ini: retain info log level
|\  
| * 7d1f8a2 (feature/verbose-logging) Set debug log level
* | 3c4e1f9 Set warn log level
|/  
* 9a8b7c6 Initial config
```

---

### Verification Questions (Exercise 3)

1. **What data is stored inside a Git `blob` object, and why are file names, permissions, and directory structures omitted from it?**
2. **Where are file paths and directory hierarchies recorded in Git's object model?**
3. **If a platform engineer runs `git reset --hard HEAD~1`, are the detached commit objects immediately purged from disk? Explain how Git garbage collection (`git gc`) works.**

---

## Exercise 4: Environment Isolation, Configuration Management & CI/CD Pipelines

### Objective
Implement the Twelve-Factor App methodology for configuration management. Construct environment isolation workflows (Development, Staging, Production), validate environment variable injection, and write a complete, syntactically valid CI/CD pipeline manifest.

### Hands-On Execution Steps

#### Step 4.1: Implement Twelve-Factor compliant configuration reading
Create a Node.js application that enforces configuration via environment variables rather than hardcoded credentials or environment-specific config files.

```bash
mkdir -p ~/lpi_lab/ex4 && cd ~/lpi_lab/ex4

cat << 'EOF' > app_config.js
function getRequiredEnv(key, defaultValue = null) {
    const value = process.env[key] || defaultValue;
    if (value === null) {
        console.error(`[CRITICAL CONFIG ERROR] Missing required env var: ${key}`);
        process.exit(1);
    }
    return value;
}

const config = {
    env: getRequiredEnv('NODE_ENV', 'development'),
    dbHost: getRequiredEnv('DB_HOST', '127.0.0.1'),
    dbPort: parseInt(getRequiredEnv('DB_PORT', '5432'), 10),
    maxConnections: parseInt(getRequiredEnv('MAX_CONN', '10'), 10),
};

console.log('Successfully loaded platform configuration:');
console.log(JSON.stringify(config, null, 2));
EOF
```

Execute under **Development** environment mode:
```bash
NODE_ENV=development DB_HOST=localhost DB_PORT=5432 app_config_run() {
    NODE_ENV=development DB_HOST=dev-db.local node app_config.js
}
app_config_run
```

**Expected Output:**
```json
Successfully loaded platform configuration:
{
  "env": "development",
  "dbHost": "dev-db.local",
  "dbPort": 5432,
  "maxConnections": 10
}
```

Execute under **Production** environment mode:
```bash
NODE_ENV=production DB_HOST=prod-db-cluster.internal DB_PORT=5432 MAX_CONN=500 node app_config.js
```

**Expected Output:**
```json
Successfully loaded platform configuration:
{
  "env": "production",
  "dbHost": "prod-db-cluster.internal",
  "dbPort": 5432,
  "maxConnections": 500
}
```

#### Step 4.2: Build a production-grade GitHub Actions CI/CD workflow manifest
Create a fully valid YAML specification for an automated CI/CD pipeline featuring build, test, lint, containerization, and staging/production deployment stages.

```bash
mkdir -p .github/workflows

cat << 'EOF' > .github/workflows/deploy.yml
name: Production SDLC CI/CD Pipeline

on:
  push:
    branches: [ main, staging ]
  pull_request:
    branches: [ main ]

permissions:
  contents: read
  packages: write

jobs:
  lint-and-test:
    name: Lint & Unit Test
    runs-on: ubuntu-latest
    steps:
      - name: Checkout Source Code
        uses: actions/checkout@v4

      - name: Setup Node.js Runtime
        uses: actions/setup-node@v4
        with:
          node-version: '20'
          cache: 'npm'

      - name: Install Dependencies
        run: npm ci --prefer-offline

      - name: Execute Linter
        run: npm run lint --if-present

      - name: Run Test Suite
        run: npm test --if-present
        env:
          NODE_ENV: test

  build-and-push:
    name: Build & Push OCI Image
    needs: lint-and-test
    runs-on: ubuntu-latest
    steps:
      - name: Checkout Repository
        uses: actions/checkout@v4

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Log in to Container Registry
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
            type=ref,event=branch
            type=sha,format=short

      - name: Build and Push Container Image
        uses: docker/build-push-action@v5
        with:
          context: .
          push: true
          tags: ${{ steps.meta.outputs.tags }}
          labels: ${{ steps.meta.outputs.labels }}

  deploy-staging:
    name: Deploy to Staging
    needs: build-and-push
    if: github.ref == 'refs/heads/staging'
    runs-on: ubuntu-latest
    environment: staging
    steps:
      - name: Deploy to Kubernetes Staging Namespace
        run: |
          echo "Deploying image tag ${{ github.sha }} to Staging Environment..."
          # kubectl set image deployment/web-app web=${{ steps.meta.outputs.tags }} -n staging

  deploy-production:
    name: Deploy to Production
    needs: build-and-push
    if: github.ref == 'refs/heads/main'
    runs-on: ubuntu-latest
    environment: production
    steps:
      - name: Deploy to Kubernetes Production Cluster
        run: |
          echo "Deploying image tag ${{ github.sha }} to Production Environment..."
          # kubectl set image deployment/web-app web=${{ steps.meta.outputs.tags }} -n production
EOF

python3 -c "import yaml; yaml.safe_load(open('.github/workflows/deploy.yml'))" && echo "YAML Syntax Valid"
```

**Expected Output:**
```text
YAML Syntax Valid
```

---

### Verification Questions (Exercise 4)

1. **Why does the Twelve-Factor App methodology strictly advocate storing configuration in environment variables rather than hardcoding environment-specific `.json` or `.yaml` files inside the codebase?**
2. **What is the structural difference between Staging and Production environments in modern cloud-native architectures?**
3. **In the CI/CD pipeline manifest (`deploy.yml`), why is `needs: lint-and-test` declared before the `build-and-push` job? What SRE principle does this enforce?**

---

## Verification Answer Key & Deep-Dive Technical Explanations

<details>
<summary><strong>Click to expand Master Answer Key & Architectural Explanations</strong></summary>

### Exercise 1 Solutions: Runtime Execution Paradigms

1. **Compiled vs. Interpreted Execution Mechanics:**
   * **`app_compiled` (C/Native ELF)**: The compiler (`gcc -O2`) translates C source directly into native machine code targeting the host CPU architecture (x86-64 instruction set). CPU registers handle arithmetic (`ADD`, `INC`), and the OS kernel executes the pre-compiled binary without runtime translation overhead.
   * **`app.py` (Python/PVM)**: Python compiles source code into intermediate *bytecode*. The Python Virtual Machine (PVM) executes a loop reading opcodes (`FOR_ITER`, `INPLACE_ADD`). Each iteration requires bytecode fetch-decode-execute dispatching, dynamic type evaluation, integer object memory allocations, and reference counting, resulting in significant execution overhead.

2. **V8 JIT Optimization & TurboFan:**
   * Node.js starts executing JavaScript code via the **Ignition** bytecode interpreter for instant startup.
   * As code executes, the V8 profiler monitors execution frequency ("hot spot detection").
   * When `calculate()` loops millions of times, V8 marks the function as hot (`marking for optimization to TURBOFAN`).
   * **TurboFan** re-compiles that specific bytecode block directly into optimized native machine code in the background, bypassing the interpreter entirely. If dynamic assumptions change (e.g., passing a string instead of an integer), V8 performs *de-optimization* back to Ignition bytecode.

3. **Runtime Selection for Low Cold Starts & Low Memory:**
   * **Compiled Languages (Go, Rust, C)** are optimal.
   * They compile directly to static native ELF binaries with no Virtual Machine or JIT compiler overhead. They launch instantly (<2ms), consume minimal RSS memory (<10MB), and eliminate JIT compilation CPU spikes during initial request traffic.

---

### Exercise 2 Solutions: Web Architecture & HTTP Mechanics

1. **Client-Side Rendering (CSR) vs. Server-Side Rendering (SSR):**
   * **CSR (Client-Side Rendering)**: The server returns a bare shell HTML file along with JavaScript bundles. The user's web browser downloads, parses, and executes the JS to render the DOM.
     * *Trade-off*: Low server CPU overhead; delayed First Contentful Paint (FCP) because client devices must download and compute the entire application UI.
   * **SSR (Server-Side Rendering)**: Node.js/Server engines execute JavaScript or templates on the server, producing fully populated HTML strings returned directly in the HTTP response body.
     * *Trade-off*: Fast initial FCP and high SEO optimization; higher server CPU/memory load since rendering compute shifts entirely to backend infrastructure.

2. **Security Significance of `X-Content-Type-Options: nosniff`:**
   * This response header instructs browsers to strictly honor the declared `Content-Type` header (e.g., `application/json` or `text/html`) without attempting MIME-type sniffing.
   * This mitigates **MIME-confused attacks** (e.g., an attacker uploading a malicious JavaScript file disguised as a `.png` or `.txt`, forcing the browser to execute untrusted code).

3. **Diagnostics for `Connection refused` (Errno 111):**
   * `Connection refused` occurs at the **TCP Transport Layer (Layer 4)**. The client sent a `TCP SYN` packet to port 8080, but the kernel network stack responded with a `TCP RST` (Reset) packet because no process was actively bound to `LISTEN` on `127.0.0.1:8080`.
   * This indicates an infrastructure/process lifecycle failure (process crashed, service down, incorrect IP/port binding), **not** an HTTP 500 application layer code crash.

---

### Exercise 3 Solutions: Git DAG & Internals

1. **Git Blob Storage Model:**
   * A Git `blob` (binary large object) stores **only raw file content**.
   * It stores no metadata: no file path, no timestamps, no directory location, and no permissions.
   * *Reason*: Storage efficiency and deduplication. If ten identical files exist across different directories or branches, Git stores a single SHA-1/SHA-256 blob object representing that unique content.

2. **Directory Structure Storage in Git:**
   * Directory hierarchies, file paths, and file modes (`100644` standard, `100755` executable) are stored in **Tree Objects**.
   * A Tree object maps blob hashes to their respective file names and modes, or points to nested child Tree objects representing subdirectories.

3. **Git Reset vs. Garbage Collection Mechanics:**
   * `git reset --hard HEAD~1` updates the current branch pointer to the parent commit, detaching the unreferenced commit.
   * The commit object remains on disk inside `.git/objects/`. It is retained in the **Reflog** (`.git/logs/`) for safety (typically 90 days default).
   * Objects are only permanently removed when `git gc` (Garbage Collection) runs, pruning unreferenced objects older than `gc.pruneExpire` (default 2 weeks) and consolidating loose objects into packed packfiles (`.git/objects/pack/`).

---

### Exercise 4 Solutions: Environment Isolation & CI/CD Pipelines

1. **Twelve-Factor App Configuration Rationale:**
   * Hardcoding environment files (`config.production.json`) into repositories introduces significant security risks (accidental leakage of production database credentials) and violates strict codebase-environment separation.
   * Environment variables allow the exact same immutable code build or container image tag to deploy across Development, Staging, and Production without code modifications, changing only runtime environment variables injected at deployment.

2. **Staging vs. Production Environment Separation:**
   * **Staging**: An exact architectural replica of production (same database versions, topology, network policies, and OS runtimes) isolated using distinct namespaces, VPCs, or clusters. It uses synthetic or sanitized data to validate deployment artifacts before reaching end users.
   * **Production**: The live environment serving real user traffic, strict SLA/SLO metrics, production databases, KMS secret stores, and high-availability auto-scaling controls.

3. **SRE Guardrails in CI/CD Pipelines (`needs: lint-and-test`):**
   * Declaring dependencies between jobs prevents **flawed artifacts from propagating downstream**.
   * If unit tests fail, the pipeline immediately fails and cancels container compilation (`build-and-push`) and deployment (`deploy-staging`/`deploy-production`). This conserves registry storage, prevents broken container releases, and maintains deployment safety.

</details>

---

## Summary Checklist for LPI 030-100 Exam Preparation

| Topic Concept | Key Command / Term | Critical Verification Point |
| :--- | :--- | :--- |
| **Compiled Languages** | `gcc -O2`, ELF format | Machine code direct kernel execution; high performance, zero runtime VM overhead. |
| **Interpreted Languages** | Python, `dis` module | Source to bytecode to PVM execution loop; dynamic typing overhead. |
| **JIT Engines** | Node.js V8 (`Ignition`/`TurboFan`) | Starts as bytecode, dynamically optimizes hot loops into native machine code at runtime. |
| **HTTP Mechanics** | `curl -i`, `ss -tulpn` | Status codes (200, 400, 404, 500), headers, TCP socket state analysis. |
| **Git Architecture** | `git hash-object`, `cat-file` | Blobs (data), Trees (paths/permissions), Commits (metadata/parents), Refs (pointers). |
| **SDLC & 12-Factor** | `process.env`, GitHub Actions YAML | Strict environment separation, configuration via env vars, CI/CD pipeline safety. |