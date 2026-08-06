#!/bin/bash
# ==============================================================================
# CNCF / LPI CERTIFICATION PREPARATION: OPEN SOURCE ESSENTIALS (050-100)
# Topic 6.3: Communication and Collaboration Tools (Exam Weight: 5)
# Reference: https://www.lpi.org/our-certifications/open-source-essentials-overview/
#
# ROLE: Principal Platform Architect & Senior SRE Instructor
# EXAM: LPI-050-100 | Topic 6.3: Communication and Collaboration Tools
# LAB MODULE: Break & Fix - Production Collaboration Gateway & Mail Hook Failure
# ==============================================================================
# ARCHITECTURAL OVERVIEW & PRODUCTION MECHANICS:
# Modern open-source collaboration platforms (e.g., Nextcloud, Mattermost, Matrix,
# Discourse, Git/GitLab notification engines) rely heavily on background asynchronous
# messaging protocols, local Mail Transfer Agents (MTAs like Postfix), and HTTP webhooks.
#
# Trade-offs in Self-Hosted Collaboration Stack Architecture:
# 1. Asynchronous SMTP/Mail Queues vs. Direct Webhooks:
#    - SMTP provides durable, retry-capable delivery for critical alerts but introduces
#      MTA dependency, SPF/DKIM complexity, and local spool management overhead.
#    - Direct HTTP/REST webhooks provide low latency real-time communication (e.g., Matrix/Mattermost),
#      but fail hard during endpoint downtime without external buffer queues (Redis/RabbitMQ).
# 2. Local Socket vs. Loopback TCP Binding for MTA Integration:
#    - Unix Domain Sockets (`/var/run/mail.sock`) eliminate TCP overhead and restrict access via
#      POSIX permissions, but require same-host co-location.
#    - Loopback TCP (`127.0.0.1:25`) allows containerized isolation but requires precise network
#      namespace binding and local firewall validation.
# ==============================================================================

set -euo pipefail

# Color Palette for CLI Diagnostics
RED='\031[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

LOG_DIR="/var/log/collab-lab"
CONF_DIR="/etc/collab-gateway"
SERVICE_NAME="collab-notifier"

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}[ERROR] This script must be executed with root privileges (sudo).${NC}" >&2
        exit 1
    fi
}

setup_lab_environment() {
    echo -e "${CYAN}[SETUP] Provisioning Collaboration & Communication Stack...${NC}"
    
    # Install dependencies silently
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq && apt-get install -y -qq postfix mailutils curl python3 systemd net-tools >/dev/null 2>&1 || true

    mkdir -p "${LOG_DIR}" "${CONF_DIR}"

    # Create mock collaboration backend API server (simulating Mattermost/Nextcloud notification receiver)
    cat <<'EOF' > "${CONF_DIR}/mock_api.py"
import http.server
import socketserver
import json
import sys

PORT = 8085

class CollabAPIHandler(http.server.SimpleHTTPRequestHandler):
    def do_POST(self):
        content_length = int(self.headers.get('Content-Length', 0))
        post_data = self.rfile.read(content_length)
        
        if self.path == "/api/v1/notify":
            try:
                payload = json.loads(post_data.decode('utf-8'))
                print(f"[API RECEIVER] Received notification: {payload}", flush=True)
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(b'{"status":"ACCEPTED","message":"Notification routed successfully"}')
            except Exception as e:
                self.send_response(400)
                self.end_headers()
                self.wfile.write(f'{{"error":"Malformed JSON: {str(e)}"}}'.encode('utf-8'))
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, format, *args):
        return

if __name__ == "__main__":
    with socketserver.TCPServer(("127.0.0.1", PORT), CollabAPIHandler) as httpd:
        httpd.serve_forever()
EOF

    # Create Mock API systemd service
    cat <<EOF > /etc/systemd/system/collab-api.service
[Unit]
Description=Mock Collaboration API Receiver (Mattermost/Nextcloud Gateway)
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 ${CONF_DIR}/mock_api.py
Restart=always
User=nobody
Group=nogroup

[Install]
WantedBy=multi-user.target
EOF

    # Create Notification Relay Daemon (Bridge between local MTA/Git events and API)
    cat <<'EOF' > "${CONF_DIR}/notifier.sh"
#!/bin/bash
CONFIG_FILE="/etc/collab-gateway/gateway.env"

if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
else
    echo "[CRITICAL] Configuration file missing!" >&2
    exit 1
fi

echo "[NOTIFIER] Attempting to deliver event '${EVENT_TYPE:-GENERIC}' to ${API_ENDPOINT}..."

# Test DNS / host connectivity
if ! ping -c 1 -W 1 "${API_HOST}" >/dev/null 2>&1; then
    echo "[ERROR] DNS resolution or network reachability failed for host: ${API_HOST}" >&2
    exit 2
fi

# Send webhook payload
HTTP_RESPONSE=$(curl -s -o /tmp/api_out.log -w "%{http_code}" -X POST \
    -H "Content-Type: application/json" \
    -d "{\"event\":\"${EVENT_TYPE}\",\"channel\":\"#devex-alerts\",\"message\":\"Pipeline completed successfully\"}" \
    "http://${API_HOST}:${API_PORT}/api/v1/notify")

if [[ "$HTTP_RESPONSE" -eq 200 ]]; then
    echo "[SUCCESS] Event notification dispatched to team chat gateway."
    exit 0
else
    echo "[ERROR] Webhook delivery failed with HTTP status code: ${HTTP_RESPONSE}" >&2
    exit 3
fi
EOF
    chmod +x "${CONF_DIR}/notifier.sh"

    # Create Gateway Environment Config
    cat <<EOF > "${CONF_DIR}/gateway.env"
API_HOST="collab.internal"
API_PORT="8085"
API_ENDPOINT="http://collab.internal:8085/api/v1/notify"
EVENT_TYPE="CI_BUILD_SUCCESS"
EOF

    # Create Notifier systemd unit
    cat <<EOF > /etc/systemd/system/${SERVICE_NAME}.service
[Unit]
Description=Enterprise Communication & Collaboration Event Notifier
After=network.target collab-api.service

[Service]
Type=oneshot
ExecStart=${CONF_DIR}/notifier.sh
StandardOutput=append:${LOG_DIR}/notifier.log
StandardError=append:${LOG_DIR}/notifier.log
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=${LOG_DIR} /tmp

[Install]
WantedBy=multi-user.target
EOF

    # Configure hosts entry for collab.internal
    if ! grep -q "collab.internal" /etc/hosts; then
        echo "127.0.0.1 collab.internal" >> /etc/hosts
    fi

    # Configure basic Postfix MTA setting
    if [[ -f /etc/postfix/main.cf ]]; then
        postconf -e "inet_interfaces = loopback-only" 2>/dev/null || true
        postconf -e "mydomain = internal.lab" 2>/dev/null || true
    fi

    systemctl daemon-reload
    systemctl enable --now collab-api.service >/dev/null 2>&1
    systemctl restart postfix >/dev/null 2>&1 || true

    echo -e "${GREEN}[SETUP COMPLETE] Base collaboration infrastructure online.${NC}"
}

inject_faults() {
    echo -e "${YELLOW}[INJECTING FAULTS] Breaking production communication pathways...${NC}"

    # Fault 1: Sabotage /etc/hosts mapping for the collaboration gateway hostname
    sed -i 's/127.0.0.1 collab.internal/192.0.2.253 collab.internal/' /etc/hosts

    # Fault 2: Introduce permission and security sandbox restriction in systemd unit
    # (Restricting /tmp and removing configuration file read access path)
    sed -i 's|ReadWritePaths=.*|ReadWritePaths=/var/log/collab-lab|' /etc/systemd/system/${SERVICE_NAME}.service
    cat <<EOF >> /etc/systemd/system/${SERVICE_NAME}.service
ProtectControlGroups=true
ReadOnlyPaths=${CONF_DIR}
InaccessiblePaths=${CONF_DIR}/gateway.env
EOF

    # Fault 3: Break Postfix local mail queue binding for fallback email notifications
    if [[ -f /etc/postfix/main.cf ]]; then
        postconf -e "inet_interfaces = 192.0.2.1" 2>/dev/null || true
    fi

    chmod 000 "${CONF_DIR}/gateway.env"

    systemctl daemon-reload
    systemctl restart postfix >/dev/null 2>&1 || true

    # Trigger failed run to populate logs
    systemctl start ${SERVICE_NAME}.service >/dev/null 2>&1 || true
}

display_instructions() {
    echo -e "\n=========================================================================="
    echo -e "${BOLD}${RED}     SRE TROUBLESHOOTING SCENARIO: TOPIC 6.3 - COLLABORATION TOOLS${NC}"
    echo -e "=========================================================================="
    echo -e "${BOLD}SYSTEM INCIDENT BRIEFING:${NC}"
    echo -e "The automated DevOps pipeline notification system ('${SERVICE_NAME}') failed to"
    echo -e "deliver critical CI/CD build reports to the team chat platform (Mattermost/Matrix API)"
    echo -e "and local mail relay server (Postfix)."
    echo -e ""
    echo -e "${BOLD}OBSERVED SYMPTOMS:${NC}"
    echo -e " 1. Running 'systemctl start ${SERVICE_NAME}.service' exits with status code 1 or 2."
    echo -e " 2. Inspecting system logs via 'journalctl -u ${SERVICE_NAME}.service' or '${LOG_DIR}/notifier.log'"
    echo -e "    indicates configuration access failure and host unreachability."
    echo -e " 3. Local MTA email dispatch fails: 'mailq' shows deferred emails or Postfix fails to bind."
    echo -e ""
    echo -e "${BOLD}YOUR OBJECTIVE:${NC}"
    echo -e " 1. Diagnose and fix the systemd service security sandbox, file permissions, and environment"
    echo -e "    reading issues for '${CONF_DIR}/gateway.env'."
    echo -e " 2. Restore name resolution and connectivity for the collaboration endpoint '${BOLD}collab.internal${NC}'."
    echo -e " 3. Fix the local Postfix MTA interface binding ('inet_interfaces') so local mail alerting works."
    echo -e " 4. Verify full end-to-end functionality by successfully running:"
    echo -e "    ${CYAN}systemctl start ${SERVICE_NAME}.service${NC}"
    echo -e "    and verifying '[SUCCESS]' in ${LOG_DIR}/notifier.log."
    echo -e "==========================================================================\n"
}

main() {
    check_root
    setup_lab_environment
    inject_faults
    display_instructions
}

main "$@"

# ==============================================================================
# SOLUTION & DIAGNOSTIC STEPS (HIDDEN / COMMENTED OUT)
# ==============================================================================
#
# STEP 1: Inspect Systemd Service Failure & Logs
# Command:
#   systemctl status collab-notifier.service
#   cat /var/log/collab-lab/notifier.log
# Expected Output:
#   [CRITICAL] Configuration file missing!
#   OR Permission denied when reading /etc/collab-gateway/gateway.env
#
# STEP 2: Fix File Permissions & Systemd Security Sandbox
# Diagnosis:
#   Check permissions on gateway.env:
#     ls -la /etc/collab-gateway/gateway.env
#   Notice permissions are 000.
# Fix:
#   chmod 644 /etc/collab-gateway/gateway.env
#
# Diagnosis (Systemd Over-sandboxing):
#   Inspect systemd unit configuration:
#     cat /etc/systemd/system/collab-notifier.service
#   Notice:
#     InaccessiblePaths=/etc/collab-gateway/gateway.env
#     ReadWritePaths=/var/log/collab-lab (Missing /tmp for curl buffer output)
# Fix:
#   Edit /etc/systemd/system/collab-notifier.service:
#     Remove 'InaccessiblePaths=/etc/collab-gateway/gateway.env'
#     Update ReadWritePaths to: ReadWritePaths=/var/log/collab-lab /tmp
#   Reload systemd:
#     systemctl daemon-reload
#
# STEP 3: Diagnose Network & Host Resolution Failure
# Command:
#   ping -c 1 collab.internal
# Expected Output:
#   PING collab.internal (192.0.2.253) ... Destination Host Unreachable / Timeout.
# Fix:
#   Edit /etc/hosts:
#     Change: 192.0.2.253 collab.internal
#     To:     127.0.0.1 collab.internal
# Test connectivity:
#   curl -i http://collab.internal:8085/api/v1/notify
#
# STEP 4: Fix Local Postfix Mail Transfer Agent (MTA) Binding
# Command:
#   postfix status
#   netstat -tulpn | grep :25  (or ss -tulpn | grep :25)
#   cat /etc/postfix/main.cf | grep inet_interfaces
# Diagnosis:
#   inet_interfaces is bound to non-existent or unreachable IP 192.0.2.1.
# Fix:
#   postconf -e "inet_interfaces = loopback-only"
#   systemctl restart postfix
# Verify:
#   postfix status
#   mailq
#
# STEP 5: Verification & End-to-End Validation
# Command:
#   systemctl start collab-notifier.service
#   cat /var/log/collab-lab/notifier.log
# Expected Success Output:
#   [NOTIFIER] Attempting to deliver event 'CI_BUILD_SUCCESS' to http://collab.internal:8085/api/v1/notify...
#   [SUCCESS] Event notification dispatched to team chat gateway.
# ==============================================================================