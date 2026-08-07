#!/usr/bin/env bash
# ==============================================================================
# LPI Web Development Essentials (030-100) - Topic 5.2: Node.js Express Basics
# LAB TYPE: Break & Fix - Production Troubleshooting & SRE Engineering
# Target Certification Exam: 030-100 (v1.0) | Weight: 10
# Official Reference: https://www.lpi.org/our-certifications/web-development-essentials-overview/
# ==============================================================================
# 
# SCENARIO DESCRIPTION:
# An engineer deployed an Express.js microservice (`user-service`) to process JSON
# payloads for user registration and query status endpoints. Shortly after deployment,
# automated health checks and HTTP POST requests started failing with 500 Internal
# Server Error responses, unhandled promise rejections, and premature process exits.
#
# YOUR OBJECTIVE:
# 1. Investigate the failure using Linux CLI tools (curl, lsof/netstat, tail/cat logs).
# 2. Identify the architectural and code-level defects in the Express application.
# 3. Modify `server.js` to fix the middleware pipeline sequence, error handling,
#    and HTTP status propagation.
# 4. Verify that POST requests successfully parse JSON bodies and return HTTP 201.
# 5. Ensure unhandled errors are safely intercepted by a centralized error-handling middleware.
# ==============================================================================

set -euo pipefail

LAB_DIR="/tmp/express_break_fix_lab"
LOG_FILE="${LAB_DIR}/server.log"
PID_FILE="${LAB_DIR}/server.pid"
PORT=3000

echo "=========================================================================="
echo " [!] INITIALIZING LPI 030-100 TOPIC 5.2 BREAK & FIX LAB ENVIRONMENT"
echo "=========================================================================="

# Step 1: Pre-flight check for Node.js and NPM
if ! command -v node &> /dev/null; then
    echo "[-] Error: Node.js is not installed on this host."
    echo "    Please install Node.js (v16+) to run this lab."
    exit 1
fi

if ! command -v npm &> /dev/null; then
    echo "[-] Error: NPM is not installed on this host."
    exit 1
fi

# Step 2: Cleanup previous lab artifacts
if [ -f "$PID_FILE" ]; then
    OLD_PID=$(cat "$PID_FILE" 2>/dev/null || true)
    if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
        echo "[*] Terminating existing lab process (PID: $OLD_PID)..."
        kill -9 "$OLD_PID" || true
    fi
    rm -f "$PID_FILE"
fi

rm -rf "$LAB_DIR"
mkdir -p "$LAB_DIR"
cd "$LAB_DIR"

echo "[*] Setting up workspace directory at ${LAB_DIR}..."

# Step 3: Initialize Node.js project and install Express
cat <<'EOF' > package.json
{
  "name": "express-break-fix-lab",
  "version": "1.0.0",
  "description": "LPI 030-100 Topic 5.2 Troubleshooting Lab",
  "main": "server.js",
  "scripts": {
    "start": "node server.js"
  },
  "dependencies": {
    "express": "^4.18.2"
  }
}
EOF

echo "[*] Installing required NPM dependencies (express)..."
npm install --silent > /dev/null 2>&1

# Step 4: Inject BROKEN Express application code
cat <<'EOF' > server.js
/**
 * Production Microservice - User Management API
 * Express.js Architecture Setup
 */
const express = require('express');
const app = express();
const PORT = process.env.PORT || 3000;

// In-memory data storage
const users = [];

// Health Check Endpoint
app.get('/healthz', (req, res) => {
    res.status(200).json({ status: 'UP', timestamp: new Date().toISOString() });
});

// BUG #1: Route handler declared BEFORE middleware body-parsing registration!
// In Express, request processing follows linear middleware execution order.
// Declaring routes before app.use(express.json()) leaves req.body as undefined.
app.post('/api/users', async (req, res, next) => {
    // Attempting to destructure properties from undefined req.body throws TypeError
    const { username, email, role } = req.body;

    // Simulated async database call
    if (!username || !email) {
        // BUG #2: Async error thrown directly without wrapping in try/catch 
        // or passing to next(err). In Express 4, unhandled async errors cause
        // UnhandledPromiseRejection and crash Node.js or hang the connection.
        throw new Error('ValidationFailed: username and email are required fields.');
    }

    const newUser = { id: users.length + 1, username, email, role: role || 'user' };
    users.push(newUser);

    res.status(200).send(newUser);
});

// JSON Body Parser Middleware incorrectly placed AFTER routes
app.use(express.json());

// Global 404 Route Catch-all
app.use((req, res) => {
    res.status(404).send('Resource Not Found');
});

// BUG #3: Missing signature for Centralized Error Handling Middleware!
// Express requires (err, req, res, next) with 4 arguments to classify a callback
// as an error handler. Standard middleware (req, res, next) ignores thrown errors.
app.use((err, req, res) => {
    console.error('Unhandled Application Error:', err.message);
    res.status(500).json({ error: 'Internal Server Error', message: err.message });
});

app.listen(PORT, () => {
    console.log(`[SERVER] Express application running on port ${PORT}`);
});
EOF

# Step 5: Launch the broken service in background
echo "[*] Launching Express application in background..."
node server.js > "$LOG_FILE" 2>&1 &
SERVER_PID=$!
echo "$SERVER_PID" > "$PID_FILE"

# Wait for server startup
sleep 2

if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    echo "[-] Server failed to start! Check logs at $LOG_FILE"
    cat "$LOG_FILE"
    exit 1
fi

echo "=========================================================================="
echo " [!] LAB SETUP COMPLETE - ENVIRONMENT IS NOW IN A BROKEN STATE"
echo "=========================================================================="
echo ""
echo "LAB DETAILS:"
echo "  - Directory: ${LAB_DIR}"
echo "  - Main File: ${LAB_DIR}/server.js"
echo "  - Log File:  ${LOG_FILE}"
echo "  - Process PID: ${SERVER_PID}"
echo "  - Listening Port: ${PORT}"
echo ""
echo "SYMPTOMS OBSERVED IN PRODUCTION:"
echo "  1. Health check works: curl -i http://localhost:${PORT}/healthz"
echo "  2. POST request to /api/users fails with 500 Internal Server Error or crashes:"
echo "     curl -i -X POST http://localhost:${PORT}/api/users \\"
echo "       -H 'Content-Type: application/json' \\"
echo "       -d '{\"username\": \"alice\", \"email\": \"alice@example.com\"}'"
echo ""
echo "YOUR TASK:"
echo "  - Inspect ${LAB_DIR}/server.js and fix all structural bugs in Express routing,"
echo "    middleware execution chain, and error handling."
echo "  - Restart the application (`node server.js`) and ensure POST /api/users returns HTTP 201."
echo "  - Ensure malformed payloads return structured HTTP 400 errors via centralized middleware."
echo ""
echo "=========================================================================="

# ==============================================================================
# STEP-BY-STEP SOLUTION & TECHNICAL EXPLANATION (FOR INSTRUCTOR / VERIFICATION)
# ==============================================================================
# 
# DEEP TECHNICAL MECHANICS OF EXPRESS.JS:
#
# 1. Express Router & Middleware Pipeline Execution Order:
#    - Express executes middleware and route handlers strictly in the order they are
#      registered using `app.use()` or `app.METHOD()`.
#    - When an HTTP request enters Express, it traverses the layer stack sequentially.
#    - Placing `app.use(express.json())` AFTER `app.post('/api/users', ...)` causes the
#      request to hit the POST handler before body parsing occurs. As a result, `req.body`
#      remains `undefined`, leading to `TypeError: Cannot destructure property 'username' of 'req.body' as it is undefined.`
#
# 2. Async Route Handlers in Express 4 vs Express 5:
#    - In Express 4, asynchronous errors thrown inside `async (req, res, next) => {}`
#      are NOT automatically passed to the next error middleware.
#    - If an async function throws an uncaught Exception without a `try/catch` block calling `next(err)`,
#      Node.js emits an `UnhandledPromiseRejection`. Depending on Node version flags, this hangs
#      the connection or crashes the entire process.
#
# 3. Centralized Error-Handling Middleware Signature:
#    - Express identifies error-handling middleware specifically by checking the function's `length` property (number of parameters).
#    - An error handler MUST declare EXACTLY 4 parameters: `(err, req, res, next)`.
#    - Defining `(err, req, res)` with only 3 arguments causes Express to treat it as standard routing middleware,
#      skipping it completely during error propagation.
#
# ------------------------------------------------------------------------------
# COMPLETE STEP-BY-STEP TROUBLESHOOTING & FIX GUIDE:
# ------------------------------------------------------------------------------
#
# Step 1: Diagnose the Failure using CLI
#   $ curl -i http://localhost:3000/healthz
#   HTTP/1.1 200 OK
#   Content-Type: application/json; charset=utf-8
#   {"status":"UP","timestamp":"..."}
#
#   $ curl -i -X POST http://localhost:3000/api/users \
#     -H "Content-Type: application/json" \
#     -d '{"username":"alice","email":"alice@example.com"}'
#
#   Result: HTTP 500 or Connection Refused (due to node crash).
#   Inspect logs:
#   $ cat /tmp/express_break_fix_lab/server.log
#   Output: TypeError: Cannot read properties of undefined (reading 'username')
#
# Step 2: Stop the broken process
#   $ kill $(cat /tmp/express_break_fix_lab/server.pid)
#
# Step 3: Apply the syntactically valid production-grade solution to server.js
#
# Edit `/tmp/express_break_fix_lab/server.js` with the following content:
#
# ------------------------------------------------------------------------------
# BEGIN FULLY FIXED server.js
# ------------------------------------------------------------------------------
# const express = require('express');
# const app = express();
# const PORT = process.env.PORT || 3000;
# 
# const users = [];
# 
# // FIX 1: Register body parsing middleware BEFORE any route declarations
# app.use(express.json());
# 
# // Health Check Endpoint
# app.get('/healthz', (req, res) => {
#     res.status(200).json({ status: 'UP', timestamp: new Date().toISOString() });
# });
# 
# // FIX 2: Implement robust async route handling with try/catch and next(err)
# app.post('/api/users', async (req, res, next) => {
#     try {
#         if (!req.body || typeof req.body !== 'object') {
#             const err = new Error('Invalid JSON payload');
#             err.statusCode = 400;
#             return next(err);
#         }
# 
#         const { username, email, role } = req.body;
# 
#         if (!username || !email) {
#             const err = new Error('ValidationFailed: username and email are required fields.');
#             err.statusCode = 400;
#             return next(err);
#         }
# 
#         const newUser = { id: users.length + 1, username, email, role: role || 'user' };
#         users.push(newUser);
# 
#         // FIX 3: Return proper HTTP 201 Created status code for resource creation
#         res.status(201).json(newUser);
#     } catch (error) {
#         // Forward asynchronous error to Express error pipeline
#         next(error);
#     }
# });
# 
# // 404 Handler for undefined routes
# app.use((req, res) => {
#     res.status(404).json({ error: 'NotFound', message: `Route ${req.originalUrl} not found` });
# });
# 
# // FIX 4: Centralized Error-Handling Middleware with exact 4-parameter signature (err, req, res, next)
# app.use((err, req, res, next) => {
#     const statusCode = err.statusCode || 500;
#     console.error(`[ERROR] ${new Date().toISOString()} - ${err.stack || err.message}`);
#     res.status(statusCode).json({
#         error: statusCode === 400 ? 'BadRequest' : 'InternalServerError',
#         message: err.message || 'An unexpected error occurred'
#     });
# });
# 
# app.listen(PORT, () => {
#     console.log(`[SERVER] Production Express API running on port ${PORT}`);
# });
# ------------------------------------------------------------------------------
# END FULLY FIXED server.js
#
# Step 4: Verification Commands & Expected Output
#
# 1. Start the updated server:
#    $ cd /tmp/express_break_fix_lab
#    $ node server.js
#
# 2. Test successful creation (HTTP 201):
#    $ curl -i -X POST http://localhost:3000/api/users \
#      -H "Content-Type: application/json" \
#      -d '{"username":"devops_admin","email":"admin@lab.local","role":"administrator"}'
#
#    EXPECTED OUTPUT:
#    HTTP/1.1 201 Created
#    Content-Type: application/json; charset=utf-8
#    {"id":1,"username":"devops_admin","email":"admin@lab.local","role":"administrator"}
#
# 3. Test validation error propagation (HTTP 400):
#    $ curl -i -X POST http://localhost:3000/api/users \
#      -H "Content-Type: application/json" \
#      -d '{"username":"missing_email"}'
#
#    EXPECTED OUTPUT:
#    HTTP/1.1 400 Bad Request
#    Content-Type: application/json; charset=utf-8
#    {"error":"BadRequest","message":"ValidationFailed: username and email are required fields."}
# ==============================================================================