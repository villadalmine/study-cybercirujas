#!/usr/bin/env bash
# ==============================================================================
# LPI DevOps Tools Engineer (Exam 701-100) - Topic 1.1: Modern Software Development
# Break & Fix Lab: 12-Factor App Architecture & Environment Configuration Breakdown
# Official Reference: https://www.lpi.org/our-certifications/devops-tools-engineer-overview/
# ==============================================================================

set -euo pipefail

# Colors for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

LAB_DIR="/tmp/lpi-devops-lab-1.1"
SERVICE_NAME="order-processor"

echo -e "${BLUE}[+] Initializing LPI DevOps 701-100 Topic 1.1 (Modern Software Development) Lab Setup...${NC}"

# Clean previous lab state if exists
rm -rf "${LAB_DIR}"
mkdir -p "${LAB_DIR}/app" "${LAB_DIR}/config" "${LAB_DIR}/logs"

# ------------------------------------------------------------------------------
# 1. Base Application Setup (12-Factor Compliant Microservice)
# ------------------------------------------------------------------------------
cat << 'EOF' > "${LAB_DIR}/app/server.py"
#!/usr/bin/env python3
import os
import sys
import time
import http.server
import socketserver

PORT = int(os.getenv("PORT", "8080"))
DATABASE_URL = os.getenv("DATABASE_URL")
LOG_LEVEL = os.getenv("LOG_LEVEL", "INFO")

def log(msg, level="INFO"):
    # 12-Factor XI: Treat logs as event streams (stdout/stderr)
    print(f"[{level}] {time.strftime('%Y-%m-%d %H:%M:%S')} - {msg}", flush=True)

if not DATABASE_URL:
    log("CRITICAL: DATABASE_URL environment variable is not defined! (Violates 12-Factor Factor III: Config)", "ERROR")
    sys.exit(1)

if not DATABASE_URL.startswith("postgres://") and not DATABASE_URL.startswith("postgresql://"):
    log(f"CRITICAL: Invalid backing service binding scheme in DATABASE_URL: '{DATABASE_URL}' (Violates 12-Factor Factor IV: Backing services)", "ERROR")
    sys.exit(1)

class HealthCheckHandler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/healthz':
            self.send_response(200)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            self.wfile.write(b'{"status":"healthy","db_connected":true}\n')
            log("Health check passed 200 OK", "INFO")
        else:
            self.send_response(404)
            self.end_headers()

log(f"Starting microservice on port {PORT} with LOG_LEVEL={LOG_LEVEL}...", "INFO")
log(f"Connecting to backing database service at: {DATABASE_URL}...", "INFO")

try:
    with socketserver.TCPServer(("", PORT), HealthCheckHandler) as httpd:
        log(f"Service running and listening on port {PORT}", "INFO")
        httpd.serve_forever()
except Exception as e:
    log(f"Fatal error starting server: {e}", "ERROR")
    sys.exit(1)
EOF

chmod +x "${LAB_DIR}/app/server.py"

# ------------------------------------------------------------------------------
# 2. Injecting Controlled Breakage (Breaking 12-Factor Architecture)
# ------------------------------------------------------------------------------
# Breakage 1: Configuration drift - Hardcoding configuration inside a local file rather than environment injection
cat << 'EOF' > "${LAB_DIR}/config/env.conf"
# Legacy configuration file
DATABASE_URL=sqlite:///local_legacy_db.db
PORT=8080
LOG_LEVEL=DEBUG
EOF

# Breakage 2: Systemd-style process wrapper misconfiguration
# Hardcoding environment file paths with restrictive permissions and bad DB URI scheme
cat << 'EOF' > "${LAB_DIR}/run_service.sh"
#!/usr/bin/env bash
# Misconfigured launcher script breaking 12-Factor App principles

# Hardcoded bad config file override (Violating Factor III: Config in Environment)
source /tmp/lpi-devops-lab-1.1/config/env.conf

# Redirecting stdout to a root-restricted file (Violating Factor XI: Logs to stdout)
export DATABASE_URL="mysql://invalid_host:3306/prod_db"
export PORT=8080

exec /usr/bin/env python3 /tmp/lpi-devops-lab-1.1/app/server.py > /var/log/order-processor-app.log 2>&1
EOF

chmod +x "${LAB_DIR}/run_service.sh"

# Attempt initial execution to trigger failure state
echo -e "${YELLOW}[!] Executing application setup test...${NC}"
bash "${LAB_DIR}/run_service.sh" > /dev/null 2>&1 &
SERVICE_PID=$!
sleep 2

# Verify failure state
if kill -0 "${SERVICE_PID}" 2>/dev/null; then
    kill -9 "${SERVICE_PID}" 2>/dev/null || true
fi

# ------------------------------------------------------------------------------
# 3. Display Lab Instructions for Student
# ------------------------------------------------------------------------------
clear
echo -e "${BLUE}==============================================================================${NC}"
echo -e "${GREEN}  LPI DevOps Tools Engineer (701-100) - Topic 1.1: Modern Software Development${NC}"
echo -e "${GREEN}  BREAK & FIX SCENARIO: 12-Factor App & Cloud-Native Architecture Compliance${NC}"
echo -e "${BLUE}==============================================================================${NC}"
echo -e ""
echo -e "${YELLOW}OFFICIAL REFERENCE:${NC}"
echo -e "  https://www.lpi.org/our-certifications/devops-tools-engineer-overview/"
echo -e ""
echo -e "${YELLOW}SITUATION REPORT / SYMPTOMS:${NC}"
echo -e "  You are tasked with deploying a cloud-native microservice ('${SERVICE_NAME}') into a containerized/12-factor compliant runtime environment."
echo -e "  Currently, running '${LAB_DIR}/run_service.sh' fails immediately or crashes silently."
echo -e "  The platform engineering team reported multiple 12-Factor architectural violations:"
echo -e "    1. Factor III (Config): Configuration parameters and credentials are hardcoded or bound to local files."
echo -e "    2. Factor IV (Backing Services): The database URL is pointing to an unsupported database scheme ('mysql://') instead of the microservice's expected PostgreSQL backend ('postgres://')."
echo -e "    3. Factor XI (Logs): Application streams are misdirected into file paths ('/var/log/...'), causing permission crashes and breaking log aggregation."
echo -e ""
echo -e "${YELLOW}YOUR OBJECTIVE:${NC}"
echo -e "  Refactor '${LAB_DIR}/run_service.sh' to strictly adhere to 12-Factor App principles:"
echo -e "    - Inject configuration dynamically via environment variables without relying on file sources."
echo -e "    - Provide a valid backing service URI (e.g., 'postgres://user:pass@db.internal:5432/orders')."
echo -e "    - Ensure logs stream directly to standard stdout/stderr (do NOT redirect to files)."
echo -e "    - Verify the microservice starts properly and responds with 200 OK on 'http://127.0.0.1:8080/healthz'."
echo -e ""
echo -e "${YELLOW}VERIFICATION COMMAND:${NC}"
echo -e "  Run your updated script in the background and execute:"
echo -e "  curl -i http://127.0.0.1:8080/healthz"
echo -e ""
echo -e "${BLUE}==============================================================================${NC}"
echo -e "Lab files location: ${LAB_DIR}"
echo -e "To inspect the application source: cat ${LAB_DIR}/app/server.py"
echo -e "${BLUE}==============================================================================${NC}"

exit 0

# ==============================================================================
# STEP-BY-STEP SOLUTION (UNCOMMENT AND EXECUTE ONLY TO VERIFY FIX)
# ==============================================================================
#
# STEP 1: Analyze the application source to understand required configuration variables
#   cat /tmp/lpi-devops-lab-1.1/app/server.py
#
#   Observations:
#   - Expects `PORT` (defaults to 8080).
#   - Expects `DATABASE_URL` starting with `postgres://` or `postgresql://`.
#   - Requires logs to go to stdout/stderr (Python `print(..., flush=True)`).
#
# STEP 2: Identify why run_service.sh failed
#   cat /tmp/lpi-devops-lab-1.1/run_service.sh
#
#   Faults identified:
#   1. `> /var/log/order-processor-app.log 2>&1` causes permission denied for unprivileged users and violates 12-Factor Factor XI.
#   2. `DATABASE_URL` uses `mysql://` which causes server.py validation to fail (Factor IV violation).
#   3. Configuration sourced from legacy file `/tmp/lpi-devops-lab-1.1/config/env.conf` (Factor III violation).
#
# STEP 3: Rewrite run_service.sh adhering to 12-Factor App principles
#
# cat << 'EOF' > /tmp/lpi-devops-lab-1.1/run_service.sh
# #!/usr/bin/env bash
# set -euo pipefail
#
# # 12-Factor III: Config injected via Environment Variables
# export PORT=8080
# export LOG_LEVEL="INFO"
#
# # 12-Factor IV: Backing service attached resource URL
# export DATABASE_URL="postgresql://orders_user:SecretPass123@127.0.0.1:5432/orders_db"
#
# # 12-Factor XI: Logs unhandled stream to stdout/stderr (no file redirection)
# exec /usr/bin/env python3 /tmp/lpi-devops-lab-1.1/app/server.py
# EOF
#
# chmod +x /tmp/lpi-devops-lab-1.1/run_service.sh
#
# STEP 4: Start the service and verify response
#   /tmp/lpi-devops-lab-1.1/run_service.sh &
#   sleep 2
#   curl -i http://127.0.0.1:8080/healthz
#
# Expected output:
#   HTTP/1.0 200 OK
#   Server: BaseHTTP/0.6 Python/3.x
#   Content-type: application/json
#
#   {"status":"healthy","db_connected":true}
# ==============================================================================