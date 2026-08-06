#!/usr/bin/env bash
# ==============================================================================
# LPI 050-100: Open Source Essentials
# Topic 4.2: Service Provider Business Models (SaaS, PaaS, IaaS, Open-Core)
# SRE Production Lab: Break & Fix Scenario - SaaS Multi-Tenant Gateway Outage
# ==============================================================================
# Objective: Break a production-style SaaS/Open-Core service infrastructure on a 
#            disposable Linux VM, present symptoms to the student, and require 
#            full diagnosis and recovery using standard SRE & Linux CLI tools.
# Target OS: Debian/Ubuntu/RHEL/CentOS/Fedora Linux distributions with systemd & nginx
# ==============================================================================

set -euo pipefail

# Color formatting for lab interface
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Ensure root privileges
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}[ERROR] This lab script must be executed as root (e.g., via sudo).${NC}"
   exit 1
fi

echo -e "${CYAN}======================================================================${NC}"
echo -e "${CYAN}   LPI 050-100 Topic 4.2: Service Provider Business Models - SRE Lab  ${NC}"
echo -e "${CYAN}======================================================================${NC}"
echo -e "${YELLOW}[+] Provisioning baseline SaaS / Open-Core infrastructure...${NC}"

# Step 1: Install prerequisite packages if missing
if command -v apt-get &>/dev/null; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq &>/dev/null
    apt-get install -y -qq nginx python3 &>/dev/null
elif command -v dnf &>/dev/null; then
    dnf install -y -q nginx python3 &>/dev/null
elif command -v yum &>/dev/null; then
    yum install -y -q nginx python3 &>/dev/null
else
    echo -e "${RED}[ERROR] Package manager not recognized. Please use Ubuntu/Debian/RHEL family OS.${NC}"
    exit 1
fi

# Step 2: Create service account and directory structures
SAAS_USER="saas-svc"
SAAS_DIR="/opt/saas-provider"
SAAS_CONF_DIR="/etc/saas-provider"

if ! id "$SAAS_USER" &>/dev/null; then
    useradd --system --no-create-home --shell /bin/false "$SAAS_USER"
fi

mkdir -p "$SAAS_DIR" "$SAAS_CONF_DIR"

# Step 3: Deploy backend SaaS Telemetry & Feature Gateway Application (Python 3)
cat << 'EOF' > "${SAAS_DIR}/saas_backend.py"
import http.server
import socketserver
import os
import sys

port_str = os.environ.get("SAAS_PORT", "9090")
try:
    PORT = int(port_str)
except ValueError:
    PORT = 9090

LICENSE_TIER = os.environ.get("SAAS_TIER", "open-core-enterprise")
PROVIDER_MODEL = os.environ.get("SERVICE_MODEL", "SaaS-Managed-Service")

class SaaSHandler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/api/v1/telemetry" or self.path == "/health":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            payload = (
                f'{{"status":"HEALTHY","model":"{PROVIDER_MODEL}",'
                f'"tier":"{LICENSE_TIER}","upstream_port":{PORT}}}\n'
            )
            self.wfile.write(payload.encode("utf-8"))
        else:
            self.send_response(404)
            self.end_headers()
            self.wfile.write(b'{"error":"Endpoint not found"}\n')

    def log_message(self, format, *args):
        sys.stdout.write(f"[SaaS Backend] {self.address_string()} - {format%args}\n")
        sys.stdout.flush()

if __name__ == "__main__":
    print(f"Starting SaaS Gateway Backend on 127.0.0.1:{PORT} (Tier: {LICENSE_TIER})...")
    sys.stdout.flush()
    with socketserver.TCPServer(("127.0.0.1", PORT), SaaSHandler) as httpd:
        httpd.serve_forever()
EOF

chmod 755 "${SAAS_DIR}/saas_backend.py"
chown -R "$SAAS_USER:$SAAS_USER" "$SAAS_DIR"

# Step 4: Create environment configuration file
cat << EOF > "${SAAS_CONF_DIR}/config.env"
SAAS_PORT=9090
SAAS_TIER=open-core-enterprise
SERVICE_MODEL=SaaS-Managed-Service
EOF

# Step 5: Systemd Unit File Creation
cat << EOF > /etc/systemd/system/saas-telemetry.service
[Unit]
Description=SaaS Telemetry and Open-Core License Feature Gate Daemon
After=network.target

[Service]
Type=simple
User=${SAAS_USER}
Group=${SAAS_USER}
WorkingDirectory=${SAAS_DIR}
EnvironmentFile=${SAAS_CONF_DIR}/config.env
ExecStart=/usr/bin/python3 ${SAAS_DIR}/saas_backend.py
Restart=on-failure
RestartSec=2s

[Install]
WantedBy=multi-user.target
EOF

# Step 6: Configure Nginx Reverse Proxy (Frontend Gateway)
NGINX_CONF_PATH=""
if [[ -d "/etc/nginx/conf.d" ]]; then
    NGINX_CONF_PATH="/etc/nginx/conf.d/saas_gateway.conf"
    # Disable default site if present on Debian/Ubuntu
    if [[ -f "/etc/nginx/sites-enabled/default" ]]; then
        rm -f /etc/nginx/sites-enabled/default
    fi
fi

cat << 'EOF' > "$NGINX_CONF_PATH"
server {
    listen 8080 default_server;
    server_name _;

    location / {
        proxy_pass http://127.0.0.1:9099; # Target upstream backend
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_connect_timeout 3s;
        proxy_read_timeout 3s;
    }
}
EOF

# Ensure nginx configuration test passes before break injection
nginx -t &>/dev/null

# ==============================================================================
# INJECT BREAKAGE (Controlled Failure Simulation)
# ==============================================================================
echo -e "${YELLOW}[+] Injecting production outage scenario...${NC}"

# Fault 1: Restrict permissions on systemd EnvironmentFile so unprivileged user cannot read it
chmod 0600 "${SAAS_CONF_DIR}/config.env"
chown root:root "${SAAS_CONF_DIR}/config.env"

# Fault 2: Nginx proxy_pass is configured for port 9099, but backend listens on 9090

# Reload systemd and restart services to activate break condition
systemctl daemon-reload
systemctl enable saas-telemetry.service &>/dev/null || true
systemctl restart saas-telemetry.service &>/dev/null || true
systemctl restart nginx &>/dev/null || true

# Give systemd a moment to register failure state
sleep 2

echo -e "${GREEN}[✔] Outage scenario successfully injected into the lab VM!${NC}"
echo ""
echo -e "${CYAN}======================================================================${NC}"
echo -e "${YELLOW}               SRE PRODUCTION INCIDENT REPORT & INSTRUCTIONS           ${NC}"
echo -e "${CYAN}======================================================================${NC}"
echo -e "Scenario Context:"
echo -e "You are managing a hybrid Cloud Open-Source / SaaS infrastructure for a"
echo -e "Service Provider. The infrastructure relies on an Open-Core model where an"
echo -e "Nginx API Gateway (Port 8080) proxies traffic to a backend systemd daemon"
echo -e "('saas-telemetry.service') running under an unprivileged system user ('${SAAS_USER}')."
echo ""
echo -e "${RED}SYMPTOMS REPORTED BY MONITORING:${NC}"
echo -e "1. API Clients report 'HTTP 502 Bad Gateway' when querying the SaaS endpoint:"
echo -e "   Command: ${YELLOW}curl -i http://localhost:8080/api/v1/telemetry${NC}"
echo -e "2. The backend systemd service 'saas-telemetry.service' fails to enter 'running' state."
echo ""
echo -e "${BLUE}YOUR OBJECTIVE:${NC}"
echo -e "Investigate the root cause, repair all misconfigurations, ensure system security"
echo -e "best practices are preserved, and achieve a successful 200 OK response from:"
echo -e "   ${YELLOW}curl http://localhost:8080/api/v1/telemetry${NC}"
echo -e "Expected JSON response content:"
echo -e '   {"status":"HEALTHY","model":"SaaS-Managed-Service","tier":"open-core-enterprise","upstream_port":9090}'
echo -e "${CYAN}======================================================================${NC}"
echo -e "${YELLOW}Tip: Use systemctl, journalctl, nginx -t, ls -l, and netstat/ss to debug.${NC}"
echo ""

# Exit cleanly leaving system broken for student interaction
exit 0


# ==============================================================================
#                        STEP-BY-STEP SOLUTION (STUDENT GUIDE)
# ==============================================================================
#
# STEP 1: VERIFY SYMPTOMS & INITIAL TRIAGE
# ------------------------------------------------------------------------------
# Test the public-facing endpoint:
#   $ curl -i http://localhost:8080/api/v1/telemetry
# Output: HTTP/1.1 502 Bad Gateway
#
# Check status of the backend service:
#   $ systemctl status saas-telemetry.service
# Output snippet:
#   Active: failed (Result: exit-code)
#   Process: ... ExecStart=... (code=exited, status=209/ENVIRONMENT)
#
#
# STEP 2: DIAGNOSE BACKEND SERVICE FAILURE
# ------------------------------------------------------------------------------
# Inspect systemd journal log for saas-telemetry.service:
#   $ journalctl -u saas-telemetry.service -n 20 --no-pager
# Output snippet:
#   Failed at step ENVIRONMENT spawning /usr/bin/python3: Permission denied
#
# Inspect the unit file to locate the EnvironmentFile:
#   $ systemctl cat saas-telemetry.service
# EnvironmentFile location identified: /etc/saas-provider/config.env
#
# Inspect file permissions and ownership:
#   $ ls -la /etc/saas-provider/config.env
# Output: -rw------- 1 root root 82 ... /etc/saas-provider/config.env
#
# Cause identified:
# The service runs as user 'saas-svc' (User=saas-svc in unit file), but config.env
# is owned by root with mode 0600. 'saas-svc' cannot read the environment file.
#
#
# STEP 3: FIX BACKEND SERVICE PERMISSIONS
# ------------------------------------------------------------------------------
# Grant read permissions to group/others or transfer ownership:
#   $ chown saas-svc:saas-svc /etc/saas-provider/config.env
#   $ chmod 0640 /etc/saas-provider/config.env
#
# Restart the backend service and verify:
#   $ systemctl restart saas-telemetry.service
#   $ systemctl status saas-telemetry.service
# Output: Active: active (running)
#
# Verify port listening on backend (9090):
#   $ ss -tulpn | grep 9090
# Output: tcp LISTEN ... 127.0.0.1:9090 ... python3
#
#
# STEP 4: DIAGNOSE GATEWAY / REVERSE PROXY FAILURE
# ------------------------------------------------------------------------------
# Retry public API call:
#   $ curl -i http://localhost:8080/api/v1/telemetry
# Output: HTTP/1.1 502 Bad Gateway
#
# Inspect Nginx error logs:
#   $ tail -n 10 /var/log/nginx/error.log
# Output snippet:
#   [error] ... connect() failed (111: Connection refused) while connecting to upstream, client: 127.0.0.1, server: _, request: "GET /api/v1/telemetry HTTP/1.1", upstream: "http://127.0.0.1:9099/api/v1/telemetry"
#
# Cause identified:
# Nginx is trying to proxy traffic to 127.0.0.1:9099, but backend listens on 127.0.0.1:9090.
#
#
# STEP 5: REPAIR NGINX REVERSE PROXY CONFIGURATION
# ------------------------------------------------------------------------------
# Edit Nginx configuration file (/etc/nginx/conf.d/saas_gateway.conf):
#   $ sed -i 's/9099/9090/' /etc/nginx/conf.d/saas_gateway.conf
#
# Test Nginx syntax:
#   $ nginx -t
# Output: syntax is ok, test is successful
#
# Reload Nginx service:
#   $ systemctl reload nginx
#
#
# STEP 6: VERIFY FINAL RESOLUTION
# ------------------------------------------------------------------------------
# Execute endpoint curl test:
#   $ curl -i http://localhost:8080/api/v1/telemetry
# Expected Output:
#   HTTP/1.1 200 OK
#   Content-Type: application/json
#   
#   {"status":"HEALTHY","model":"SaaS-Managed-Service","tier":"open-core-enterprise","upstream_port":9090}
# ==============================================================================