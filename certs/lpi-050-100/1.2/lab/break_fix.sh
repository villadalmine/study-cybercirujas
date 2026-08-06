#!/usr/bin/env bash
# ==============================================================================
# LPI 050-100: Open Source Essentials
# Topic 1.2: Software Architecture (Weight: 5)
# SRE Break & Fix Practical Lab Script
#
# Reference: https://www.lpi.org/our-certifications/open-source-essentials-overview/
# ==============================================================================
# OVERVIEW:
# This script simulates a 3-Tier Software Architecture environment on a disposable
# Linux VM:
#   1. Presentation Tier (Web Proxy / Frontend Gateway listening on port 8080)
#   2. Application Tier (REST API Application Server listening on port 5000)
#   3. Data Tier (Database Service listening on port 9090)
#
# The script intentionally breaks architectural linkage between components.
# ==============================================================================

set -euo pipefail

LAB_DIR="/tmp/lpi_lab_software_arch"
LOG_DIR="${LAB_DIR}/logs"
CONF_DIR="${LAB_DIR}/config"

# Colors for UI output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

cleanup_existing_lab() {
    echo -e "${YELLOW}[+] Cleaning up any pre-existing lab environment...${NC}"
    pkill -f "lpi_lab_arch" 2>/dev/null || true
    rm -rf "${LAB_DIR}"
}

setup_architecture() {
    echo -e "${BLUE}[+] Building 3-Tier Software Architecture infrastructure...${NC}"
    mkdir -p "${LAB_DIR}" "${LOG_DIR}" "${CONF_DIR}"

    # --------------------------------------------------------------------------
    # Tier 3: Data Tier (Mock Database Server)
    # --------------------------------------------------------------------------
    cat << 'EOF' > "${LAB_DIR}/db_service.py"
import http.server
import socketserver
import json

PORT = 9090

class DBHandler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/query':
            self.send_response(200)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            response = {"status": "SUCCESS", "db_tier": "DataStore_v1.4", "records": 42}
            self.wfile.write(json.dumps(response).encode('utf-8'))
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, format, *args):
        with open("/tmp/lpi_lab_software_arch/logs/db.log", "a") as f:
            f.write(f"DB_TIER: {format % args}\n")

with socketserver.TCPServer(("127.0.0.1", PORT), DBHandler) as httpd:
    httpd.serve_forever()
EOF

    # --------------------------------------------------------------------------
    # Tier 2: Application Tier (Backend Business Logic API)
    # --------------------------------------------------------------------------
    cat << 'EOF' > "${LAB_DIR}/app_service.py"
import http.server
import socketserver
import json
import urllib.request
import os

PORT = 5000

class AppHandler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        db_host = os.environ.get("DB_HOST", "127.0.0.1")
        db_port = os.environ.get("DB_PORT", "5432") # Default misconfiguration target

        if self.path == '/api/v1/data':
            try:
                url = f"http://{db_host}:{db_port}/query"
                req = urllib.request.Request(url)
                with urllib.request.urlopen(req, timeout=2) as resp:
                    if resp.status == 200:
                        db_data = json.loads(resp.read().decode('utf-8'))
                        self.send_response(200)
                        self.send_header('Content-type', 'application/json')
                        self.end_headers()
                        payload = {
                            "architecture": "3-Tier Microservices",
                            "app_tier_status": "ONLINE",
                            "data_tier_response": db_data
                        }
                        self.wfile.write(json.dumps(payload).encode('utf-8'))
                    else:
                        raise Exception("Data tier non-200 response")
            except Exception as e:
                self.send_response(500)
                self.send_header('Content-type', 'application/json')
                self.end_headers()
                err_payload = {
                    "error": "500 Internal Server Error",
                    "reason": "Application Tier failed to reach Data Tier",
                    "details": str(e)
                }
                self.wfile.write(json.dumps(err_payload).encode('utf-8'))
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, format, *args):
        with open("/tmp/lpi_lab_software_arch/logs/app.log", "a") as f:
            f.write(f"APP_TIER: {format % args}\n")

with socketserver.TCPServer(("127.0.0.1", PORT), AppHandler) as httpd:
    httpd.serve_forever()
EOF

    # --------------------------------------------------------------------------
    # Tier 1: Presentation Tier (Reverse Proxy / API Gateway Gateway)
    # --------------------------------------------------------------------------
    cat << 'EOF' > "${LAB_DIR}/web_proxy.py"
import http.server
import socketserver
import urllib.request
import os

PORT = 8080

class ProxyHandler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        conf_file = "/tmp/lpi_lab_software_arch/config/gateway.env"
        app_target = "127.0.0.1:5001" # Default misconfigured upstream port

        if os.path.exists(conf_file):
            with open(conf_file, "r") as f:
                for line in f:
                    if line.startswith("UPSTREAM_APP="):
                        app_target = line.strip().split("=")[1]

        target_url = f"http://{app_target}{self.path}"
        try:
            req = urllib.request.Request(target_url)
            with urllib.request.urlopen(req, timeout=2) as resp:
                self.send_response(resp.status)
                self.send_header('Content-type', resp.headers.get('Content-type', 'application/json'))
                self.end_headers()
                self.wfile.write(resp.read())
        except Exception as e:
            self.send_response(502)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            proxy_err = {
                "error": "502 Bad Gateway",
                "tier": "Presentation Tier (API Gateway)",
                "details": f"Failed connecting to App Tier upstream at {app_target}: {str(e)}"
            }
            import json
            self.wfile.write(json.dumps(proxy_err).encode('utf-8'))

    def log_message(self, format, *args):
        with open("/tmp/lpi_lab_software_arch/logs/web.log", "a") as f:
            f.write(f"WEB_TIER: {format % args}\n")

with socketserver.TCPServer(("127.0.0.1", PORT), ProxyHandler) as httpd:
    httpd.serve_forever()
EOF

    # Config file for Web Tier
    cat << 'EOF' > "${CONF_DIR}/gateway.env"
# Presentation Tier Configuration
UPSTREAM_APP=127.0.0.1:5001
EOF
}

inject_architectural_defects() {
    echo -e "${RED}[!] Injecting architectural breakage...${NC}"

    # Start Data Tier background process (Listening on 9090)
    python3 "${LAB_DIR}/db_service.py" > /dev/null 2>&1 &

    # Start App Tier process with BROKEN DB_PORT environment variable (5432 instead of 9090)
    DB_HOST="127.0.0.1" DB_PORT="5432" python3 "${LAB_DIR}/app_service.py" > /dev/null 2>&1 &

    # Start Web Tier process (Upstream gateway configured to point to 5001 instead of 5000)
    python3 "${LAB_DIR}/web_proxy.py" > /dev/null 2>&1 &

    sleep 1
}

print_student_instructions() {
    echo -e "\n========================================================================"
    echo -e "${GREEN}LAB ENVIRONMENT BROKEN SUCCESSFULLY!${NC}"
    echo -e "========================================================================"
    echo -e "${YELLOW}Topic:${NC} 1.2 Software Architecture (LPI 050-100)"
    echo -e "${YELLOW}Scenario:${NC} 3-Tier Multi-layer Web Application Communication Failure"
    echo -e "------------------------------------------------------------------------"
    echo -e "${BLUE}SYMPTOMS REPORTED BY MONITORING:${NC}"
    echo -e "  - End-user requests to the Presentation Tier (`curl -i http://127.0.0.1:8080/api/v1/data`) respond with:"
    echo -e "    ${RED}HTTP/1.0 502 Bad Gateway${NC}"
    echo -e "  - The architecture is supposed to follow standard 3-Tier decoupling:"
    echo -e "      [Client] ---> Tier 1: Web Gateway (8080)"
    echo -e "                      ---> Tier 2: App API Server (5000)"
    echo -e "                             ---> Tier 3: Database Engine (9090)"
    echo -e ""
    echo -e "${BLUE}YOUR OBJECTIVE:${NC}"
    echo -e "  1. Use SRE diagnostic tools (`ss`, `lsof`, `curl`, `ps`, environment variables, and config inspection) to trace socket bindings and upstream configurations across all 3 tiers."
    echo -e "  2. Fix the misconfiguration in Tier 1 (API Gateway configuration file)."
    echo -e "  3. Fix the misconfiguration between Tier 2 and Tier 3 (Application Tier process environment variables)."
    echo -e "  4. Verify complete end-to-end multi-tier data flow where `curl http://127.0.0.1:8080/api/v1/data` returns HTTP 200 with JSON payload."
    echo -e "------------------------------------------------------------------------"
    echo -e "${YELLOW}Artifact Locations:${NC}"
    echo -e "  - Base Directory: ${LAB_DIR}"
    echo -e "  - Config Files:   ${CONF_DIR}/gateway.env"
    echo -e "  - Log Files:      ${LOG_DIR}/(web.log|app.log|db.log)"
    echo -e "========================================================================\n"
}

main() {
    cleanup_existing_lab
    setup_architecture
    inject_architectural_defects
    print_student_instructions
}

main "$@"

# ==============================================================================
# SOLUTION & DIAGNOSTIC STEPS (FOR INSTRUCTOR / STUDENT REFERENCE)
# ==============================================================================
#
# STEP 1: Reproduce the entrypoint issue (Presentation Tier)
# $ curl -i http://127.0.0.1:8080/api/v1/data
# Output: HTTP/1.0 502 Bad Gateway
# Details: Failed connecting to App Tier upstream at 127.0.0.1:5001
#
# STEP 2: Inspect listening network ports across the system to locate active tiers
# $ ss -tulpn | grep -E '8080|5000|5001|9090|5432'
# OR
# $ lsof -i :8080 -i :5000 -i :5001 -i :9090 -i :5432
#
# Observation:
# - Presentation Tier is listening on port 8080.
# - Application Tier is actually listening on port 5000 (NOT 5001).
# - Data Tier is listening on port 9090 (NOT 5432).
#
# STEP 3: Fix Tier 1 -> Tier 2 Configuration
# Inspect Tier 1 configuration:
# $ cat /tmp/lpi_lab_software_arch/config/gateway.env
# Change UPSTREAM_APP=127.0.0.1:5001 to UPSTREAM_APP=127.0.0.1:5000
# $ sed -i 's/5001/5000/' /tmp/lpi_lab_software_arch/config/gateway.env
#
# Test Tier 1 -> Tier 2 communication:
# $ curl -i http://127.0.0.1:8080/api/v1/data
# Output: HTTP/1.0 500 Internal Server Error
# Reason: Application Tier failed to reach Data Tier (Connection Refused to 127.0.0.1:5432)
#
# STEP 4: Diagnose Tier 2 -> Tier 3 Linkage
# Inspect running processes and environment variables for the App Tier service:
# $ ps aux | grep app_service.py
# $ PID=$(pgrep -f "app_service.py")
# $ cat /proc/${PID}/environ | tr '\0' '\n' | grep DB_
# Output:
# DB_HOST=127.0.0.1
# DB_PORT=5432
#
# Notice that Data Tier service is listening on port 9090 (verified via `ss -tulpn`).
#
# STEP 5: Restart Tier 2 (App Service) with corrected Environment Variables
# $ kill ${PID}
# $ DB_HOST="127.0.0.1" DB_PORT="9090" python3 /tmp/lpi_lab_software_arch/app_service.py > /dev/null 2>&1 &
#
# STEP 6: Final Verification (End-to-End Architectural Test)
# $ curl -i http://127.0.0.1:8080/api/v1/data
#
# Expected Output:
# HTTP/1.0 200 OK
# Content-type: application/json
#
# {
#   "architecture": "3-Tier Microservices",
#   "app_tier_status": "ONLINE",
#   "data_tier_response": {
#     "status": "SUCCESS",
#     "db_tier": "DataStore_v1.4",
#     "records": 42
#   }
# }
# ==============================================================================