#!/usr/bin/env bash
# ==============================================================================
# LPI Web Development Essentials (Exam 030-100, Version 1.0)
# Topic 5.1: Node.js Basics (Weight: 2.5)
# Lab Exercise: Production Node.js Break & Fix Diagnostic Scenario
#
# Official References:
# - LPI Web Development Essentials: https://www.lpi.org/our-certifications/web-development-essentials-overview/
# - Node.js Modules Architecture: https://nodejs.org/api/modules.html
# - Node.js Process & Environment: https://nodejs.org/api/process.html
# - npm package.json Structure: https://docs.npmjs.com/cli/v10/configuring-npm/package-json
# ==============================================================================

set -euo pipefail

LAB_DIR="/tmp/node-basics-lab"
TARGET_PORT=8080

echo "======================================================================"
echo "[+] Initializing LPI 030-100 Topic 5.1 (Node.js Basics) Lab Environment"
echo "======================================================================"

# Verify Node.js runtime availability
if ! command -v node &> /dev/null || ! command -v npm &> /dev/null; then
    echo "[!] Error: Node.js and npm are required to run this lab."
    exit 1
fi

# Reset lab environment directory
rm -rf "${LAB_DIR}"
mkdir -p "${LAB_DIR}/src"

# 1. Create package.json missing "type": "module" property despite using ES import syntax
cat << 'EOF' > "${LAB_DIR}/package.json"
{
  "name": "lpi-node-service",
  "version": "1.0.0",
  "description": "LPI 030-100 Node.js Production Service",
  "main": "src/server.js",
  "scripts": {
    "start": "node src/server.js"
  },
  "dependencies": {
    "dotenv": "^16.4.5"
  }
}
EOF

# 2. Create environment configuration (.env) file
cat << 'EOF' > "${LAB_DIR}/.env"
PORT=8080
NODE_ENV=production
SERVICE_NAME=lpi-node-service
EOF

# 3. Create module dependency file src/logger.js using ES module exports
cat << 'EOF' > "${LAB_DIR}/src/logger.js"
import fs from 'fs';

export function logMessage(msg) {
    const timestamp = new Date().toISOString();
    const formatted = `[${timestamp}] ${msg}\n`;
    fs.appendFileSync('app.log', formatted);
    console.log(formatted.trim());
}
EOF

# 4. Create primary entry point src/server.js relying on environment variables and ESM imports
cat << 'EOF' > "${LAB_DIR}/src/server.js"
import http from 'http';
import { logMessage } from './logger.js';

const port = process.env.PORT || 3000;

if (!process.env.NODE_ENV) {
    console.error("FATAL: NODE_ENV environment variable is missing!");
    process.exit(1);
}

const server = http.createServer((req, res) => {
    logMessage(`Received ${req.method} request for ${req.url}`);
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({
        status: "ok",
        service: process.env.SERVICE_NAME,
        environment: process.env.NODE_ENV
    }));
});

server.on('error', (err) => {
    console.error(`Server Startup Error: ${err.message}`);
    process.exit(1);
});

server.listen(port, () => {
    logMessage(`Server listening on port ${port} in ${process.env.NODE_ENV} mode`);
});
EOF

# 5. Inject Port Collision Failure (EADDRINUSE) using background netcat listener
nc -l -k -p ${TARGET_PORT} &> /dev/null &
CONFLICT_PID=$!
echo "${CONFLICT_PID}" > "${LAB_DIR}/.conflict_pid"
disown ${CONFLICT_PID} 2>/dev/null || true

echo ""
echo "======================================================================"
echo "                   LAB SCENARIO BREAK COMPLETE                        "
echo "======================================================================"
echo "Target Workspace: ${LAB_DIR}"
echo ""
echo "SYMPTOMS & INCIDENT REPORT:"
echo "1. Running 'npm start' inside '${LAB_DIR}' crashes immediately."
echo "2. Runtime error thrown: 'SyntaxError: Cannot use import statement outside a module'."
echo "3. If module syntax is bypassed, process exits with missing NODE_ENV environment variable."
echo "4. If environment variables are supplied, server fails with 'EADDRINUSE: address already in use'."
echo ""
echo "STUDENT GOALS & ACCEPTANCE CRITERIA:"
echo "1. Change directory to '${LAB_DIR}'."
echo "2. Fix ES Module (ESM) declaration resolution in 'package.json'."
echo "3. Ensure Node loads '.env' file variables into 'process.env' without crashing."
echo "4. Identify and release port ${TARGET_PORT} occupied by a rogue background process."
echo "5. Run 'npm start' and confirm HTTP 200 via: curl http://localhost:${TARGET_PORT}"
echo "======================================================================"
echo ""

# ==============================================================================
# STEP-BY-STEP SOLUTION & TECHNICAL EXPLANATION
# ==============================================================================
#
# ROOT CAUSE ANALYSIS:
# --------------------
# 1. Module System Mismatch (CommonJS vs ES Modules):
#    Node.js treats .js files as CommonJS by default unless specified otherwise.
#    Because src/server.js uses ECMAScript module imports ('import http from "http"'),
#    Node.js raises: `SyntaxError: Cannot use import statement outside a module`.
#    Fix: Define `"type": "module"` in package.json, or use .mjs file extensions.
#    Ref: https://nodejs.org/api/packages.html#type
#
# 2. Environment Variable Resolution (.env handling):
#    Node.js process.env only contains system OS environment variables by default.
#    Files named '.env' are not loaded automatically unless using Node v20.6.0+ flag
#    `node --env-file=.env` or importing `dotenv/config`.
#    Ref: https://nodejs.org/api/process.html#processenv
#
# 3. Port Conflict (EADDRINUSE / Socket Binding):
#    Port 8080 is locked by PID $(cat /tmp/node-basics-lab/.conflict_pid).
#    Node.js emits an asynchronous server 'error' event with code 'EADDRINUSE'.
#    Fix: Use `lsof` or `ss` to identify socket ownership and terminate the process.
#
# STEP-BY-STEP RECOVERY COMMANDS:
# -------------------------------
# Step 1: Navigate to project workspace
# $ cd /tmp/node-basics-lab
#
# Step 2: Configure package.json to support ES Modules
# Edit package.json and add `"type": "module"` at the root object level:
# $ node -e '
#   const fs = require("fs");
#   const pkg = JSON.parse(fs.readFileSync("package.json", "utf8"));
#   pkg.type = "module";
#   pkg.scripts.start = "node --env-file=.env src/server.js";
#   fs.writeFileSync("package.json", JSON.stringify(pkg, null, 2));
# '
#
# Step 3: Or alternatively, add import 'dotenv/config' at top of src/server.js:
# $ sed -i '1s/^/import "dotenv\/config";\n/' src/server.js
#
# Step 4: Locate and kill process listening on port 8080
# $ lsof -i :8080
# COMMAND   PID USER   FD   TYPE DEVICE SIZE/OFF NODE NAME
# nc      12345 root    3u  IPv4  89012      0t0  TCP *:http-alt (LISTEN)
# $ kill -9 $(lsof -t -i :8080)
#
# Step 5: Start the Node.js application service
# $ npm start &
#
# Step 6: Verify HTTP Endpoint and inspect output
# $ curl -i http://localhost:8080
# Output expected:
# HTTP/1.1 200 OK
# Content-Type: application/json
# {"status":"ok","service":"lpi-node-service","environment":"production"}
# ==============================================================================