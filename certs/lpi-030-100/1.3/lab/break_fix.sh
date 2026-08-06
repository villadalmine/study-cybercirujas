#!/usr/bin/env bash
# ==============================================================================
# LPI 030-100 (v1.0) | Topic 1.3: HTTP Basics (Weight: 7.5)
# Official Reference: https://www.lpi.org/our-certifications/web-development-essentials-overview/
#
# LAB TITLE: Break & Fix - Production HTTP Protocol & Header Diagnostics
# ROLE: Senior SRE & Platform Architect Instructor
# ==============================================================================
# WARNING: Run this script ONLY in a disposable lab environment or VM.
# ==============================================================================

set -euo pipefail

LAB_DIR="/tmp/lpi_http_lab"
PORT=8080
LOG_FILE="${LAB_DIR}/server.log"
PID_FILE="${LAB_DIR}/server.pid"

# --- Step 0: Pre-flight & Cleanup ---
echo "[+] Initializing LPI 030-100 Topic 1.3 Break & Fix Lab..."

if command -v killall >/dev/null 2>&1; then
    killall python3 >/dev/null 2>&1 || true
fi

if [ -f "${PID_FILE}" ]; then
    kill "$(cat "${PID_FILE}")" >/dev/null 2>&1 || true
    rm -f "${PID_FILE}"
fi

rm -rf "${LAB_DIR}"
mkdir -p "${LAB_DIR}"

# --- Step 1: Injecting Controlled Faults into HTTP Service ---
# Creating a custom Python HTTP server with deliberately broken HTTP protocol mechanics
cat << 'EOF' > "${LAB_DIR}/broken_http_server.py"
import sys
import socket
from http.server import HTTPServer, BaseHTTPRequestHandler

class FaultyHTTPHandler(BaseHTTPRequestHandler):
    # Enforce strict HTTP/1.1 compliance testing
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        if self.path == "/api/v1/user":
            # FAULT 1: Malformed Content-Type (missing MIME type sub-category)
            # FAULT 2: Returns 200 OK status code despite missing authentication (Security & Semantics violation)
            body = b'{"error": "Unauthorized access to resource", "code": 401}'
            self.send_response(200)
            self.send_header("Content-Type", "application") # BROKEN: should be application/json
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Server", "SRE-Broken-Edge/1.0")
            self.end_headers()
            self.wfile.write(body)

        elif self.path == "/redirect-old":
            # FAULT 3: Status 301 Moved Permanently missing mandatory Location response header
            body = b'Redirecting to new API path...'
            self.send_response(301)
            # BROKEN: Missing self.send_header("Location", "/api/v1/user")
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        elif self.path == "/health":
            body = b'{"status": "UP"}'
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            body = b'Not Found'
            self.send_response(404)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    def do_POST(self):
        if self.path == "/api/v1/user":
            # FAULT 4: HTTP Method POST on /api/v1/user responds with 500 Internal Server Error
            # instead of proper 405 Method Not Allowed or valid handling
            body = b'Internal Server Error: Unsupported operation'
            self.send_response(500)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_error(404)

if __name__ == "__main__":
    server_address = ('127.0.0.1', 8080)
    httpd = HTTPServer(server_address, FaultyHTTPHandler)
    httpd.serve_forever()
EOF

# --- Step 2: Background Server Start ---
python3 "${LAB_DIR}/broken_http_server.py" > "${LOG_FILE}" 2>&1 &
echo $! > "${PID_FILE}"

sleep 2

# Verify server listener
if ! curl -s http://127.0.0.1:${PORT}/health >/dev/null; then
    echo "[!] Error: Failed to initialize target HTTP service on port ${PORT}."
    exit 1
fi

# --- Step 3: Student Lab Briefing ---
cat << EOF

================================================================================
  LPI 030-100 (v1.0) Topic 1.3: HTTP Basics - Break & Fix Practical Scenario
================================================================================
Official Topic Reference:
https://www.lpi.org/our-certifications/web-development-essentials-overview/

[SITUATION REPORT]
An upstream API microservice on localhost:${PORT} was recently updated, but automated
synthetics and API gateways (like Nginx / Kong) are throwing protocol alerts:
1. Client browsers and SDKs fail to parse JSON responses from /api/v1/user.
2. Unauthenticated calls receive HTTP status 200 OK while returning error payloads.
3. Redirect endpoint /redirect-old breaks HTTP/1.1 client redirection loops.
4. HTTP POST method calls to /api/v1/user return 500 Internal Server Error instead
   of semantic client-side error status codes.

[STUDENT SYMPTOMS & INCIDENT OBJECTIVES]
Use raw HTTP diagnostics tools (curl, nc, or python) to analyze response headers,
status codes, and HTTP request/response line formats.

Your Mission:
1. Diagnostic Task A:
   Run: curl -v http://127.0.0.1:${PORT}/api/v1/user
   Identify the malformed header key/value pair and fix the status code to 401 Unauthorized.

2. Diagnostic Task B:
   Run: curl -v -L http://127.0.0.1:${PORT}/redirect-old
   Identify why curl cannot follow the 301 Moved Permanently redirect.

3. Diagnostic Task C:
   Run: curl -v -X POST http://127.0.0.1:${PORT}/api/v1/user
   Identify why HTTP method handling violates RFC 9110 / HTTP specification.

[VERIFICATION COMMANDS TO TEST YOUR WORK]
- Test A: curl -i http://127.0.0.1:${PORT}/api/v1/user | grep -i "HTTP/1.1 401"
- Test B: curl -i http://127.0.0.1:${PORT}/api/v1/user | grep -i "Content-Type: application/json"
- Test C: curl -i http://127.0.0.1:${PORT}/redirect-old | grep -i "Location:"
- Test D: curl -i -X POST http://127.0.0.1:${PORT}/api/v1/user | grep -i "HTTP/1.1 405"

Target server code located at: ${LAB_DIR}/broken_http_server.py
Log file location: ${LOG_FILE}
================================================================================
EOF

# ==============================================================================
# SOLUTION AND TROUBLESHOOTING GUIDE (DO NOT LOOK UNTIL YOU HAVE ATTEMPTED THE FIX)
# ==============================================================================
#
# STEP-BY-STEP DIAGNOSIS & FIX INSTRUCTIONS:
#
# Step 1: Root Cause Analysis using CLI
# ------------------------------------------------------------------------------
# A. Inspect /api/v1/user GET response:
#    $ curl -v http://127.0.0.1:8080/api/v1/user
#
#    Observed Header:
#      < HTTP/1.1 200 OK
#      < Content-Type: application
#    Problem:
#      - Status code is 200 OK despite payload containing {"error": "Unauthorized access"}.
#        HTTP Semantics rule: 401 Unauthorized MUST be returned when authentication credentials are missing.
#      - "Content-Type: application" is invalid MIME type syntax. Valid JSON format is "application/json".
#
# B. Inspect /redirect-old GET response:
#    $ curl -v -L http://127.0.0.1:8080/redirect-old
#
#    Observed Response:
#      < HTTP/1.1 301 Moved Permanently
#      * Issue: curl: (47) Maximum (%d) redirects followed / No Location header found
#    Problem:
#      - RFC 9110 Section 15.4.2 mandates that a 301 Moved Permanently response MUST
#        contain a valid 'Location' header specifying the target URI.
#
# C. Inspect /api/v1/user POST response:
#    $ curl -v -X POST http://127.0.0.1:8080/api/v1/user
#
#    Observed Response:
#      < HTTP/1.1 500 Internal Server Error
#    Problem:
#      - 500 Internal Server Error indicates an unhandled server failure. If an endpoint
#        does not allow a specific HTTP method (e.g. POST), it MUST return HTTP Status 405
#        (Method Not Allowed) along with an 'Allow' header indicating supported methods.
#
# ------------------------------------------------------------------------------
# Step 2: Applying the Code Fix
# ------------------------------------------------------------------------------
# Open /tmp/lpi_http_lab/broken_http_server.py in your editor or replace with fixed logic:
#
# Fixed Python Handler implementation:
#
# ```python
# class FaultyHTTPHandler(BaseHTTPRequestHandler):
#     protocol_version = "HTTP/1.1"
#
#     def do_GET(self):
#         if self.path == "/api/v1/user":
#             body = b'{"error": "Unauthorized access to resource", "code": 401}'
#             self.send_response(401)  # FIX 1: Correct Status Code 401
#             self.send_header("Content-Type", "application/json")  # FIX 2: Valid MIME type
#             self.send_header("WWW-Authenticate", 'Bearer realm="Access to staging API"')
#             self.send_header("Content-Length", str(len(body)))
#             self.end_headers()
#             self.wfile.write(body)
#
#         elif self.path == "/redirect-old":
#             body = b'Redirecting to new API path...'
#             self.send_response(301)
#             self.send_header("Location", "/api/v1/user")  # FIX 3: Mandatory Location header added
#             self.send_header("Content-Type", "text/plain; charset=utf-8")
#             self.send_header("Content-Length", str(len(body)))
#             self.end_headers()
#             self.wfile.write(body)
#
#     def do_POST(self):
#         if self.path == "/api/v1/user":
#             body = b'Method Not Allowed: Use GET'
#             self.send_response(405)  # FIX 4: Proper HTTP 405 Method Not Allowed
#             self.send_header("Allow", "GET, HEAD, OPTIONS")  # FIX 5: Standard Allow header
#             self.send_header("Content-Type", "text/plain")
#             self.send_header("Content-Length", str(len(body)))
#             self.end_headers()
#             self.wfile.write(body)
# ```
#
# ------------------------------------------------------------------------------
# Step 3: Restart Service and Verify Solutions
# ------------------------------------------------------------------------------
# 1. Kill running server:
#    $ kill $(cat /tmp/lpi_http_lab/server.pid)
#
# 2. Relaunch fixed server:
#    $ python3 /tmp/lpi_http_lab/broken_http_server.py > /tmp/lpi_http_lab/server.log 2>&1 &
#    $ echo $! > /tmp/lpi_http_lab/server.pid
#
# 3. Re-test with cURL:
#    $ curl -i http://127.0.0.1:8080/api/v1/user
#    Expected Output:
#      HTTP/1.1 401 Unauthorized
#      Content-Type: application/json
#      WWW-Authenticate: Bearer realm="..."
#
#    $ curl -i -L http://127.0.0.1:8080/redirect-old
#    Expected Output:
#      HTTP/1.1 301 Moved Permanently
#      Location: /api/v1/user
#      ...
#      HTTP/1.1 401 Unauthorized
#
#    $ curl -i -X POST http://127.0.0.1:8080/api/v1/user
#    Expected Output:
#      HTTP/1.1 405 Method Not Allowed
#      Allow: GET, HEAD, OPTIONS
# ==============================================================================