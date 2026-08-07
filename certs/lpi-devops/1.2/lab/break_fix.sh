#!/usr/bin/env bash
# ==============================================================================
# LPI DevOps Tools Engineer (Exam 701-100, v1.0)
# Topic 1.2: Standard Components and Platforms for Software (Weight: 3.33)
# Official Reference: https://www.lpi.org/our-certifications/devops-tools-engineer-overview/
#
# Production Break & Fix Lab Script
# Target Platform: Linux VM (Ubuntu 22.04/24.04 LTS or RHEL 9+)
#
# ARCHITECTURE OVERVIEW:
# Three-Tier Web Platform Stack:
# 1. Reverse Proxy / Web Server: Nginx (Port 80)
# 2. Application Server: Python WSGI / Gunicorn App (`app-service`) (Port 5000)
# 3. In-Memory Cache / Database: Redis Key-Value Store (Port 6379)
#
# INTERNAL MECHANICS & COMPONENT INTERACTIONS:
# Nginx acts as the Layer 7 reverse proxy terminating incoming HTTP requests on 
# TCP port 80 and forwarding them via HTTP upstream to Gunicorn running on 
# 127.0.0.1:5000. Gunicorn serves a Flask microservice that queries Redis at 
# 127.0.0.1:6379 to retrieve and increment session hit counters.
#
# LAB BREAKAGE SUMMARY:
# - Breakage 1 (Web Proxy Layer): Nginx upstream block points to port 5001 instead of 5000.
# - Breakage 2 (Application Layer): `app-service.service` systemd unit has `PrivateNetwork=yes`
#   enabled, isolating loopback network namespaces and blocking connection to Redis.
# - Breakage 3 (Data / Cache Layer): Redis configuration is restricted to IPv6 `::1`,
#   rejecting IPv4 connections from `127.0.0.1`.
# ==============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

LAB_DIR="/opt/devops-lab-1.2"
APP_USER="www-data"

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}[ERROR] This script must be run as root to configure systemd, nginx, and redis services.${NC}" >&2
        exit 1
    fi
}

install_dependencies() {
    echo -e "${BLUE}[+] Installing required components (Nginx, Redis, Python3, Gunicorn)...${NC}"
    if command -v apt-get &>/dev/null; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y -qq nginx redis-server python3 python3-flask python3-redis gunicorn curl net-tools &>/dev/null
    elif command -v dnf &>/dev/null; then
        dnf install -y -q nginx redis python3 python3-flask python3-redis gunicorn curl net-tools &>/dev/null
    else
        echo -e "${RED}[ERROR] Unsupported package manager. Debian/Ubuntu or RHEL/Rocky Linux required.${NC}" >&2
        exit 1
    fi
}

setup_baseline_environment() {
    echo -e "${BLUE}[+] Building baseline 3-tier architecture stack...${NC}"
    mkdir -p "${LAB_DIR}"

    # 1. Create Python Flask Application Code
    cat << 'EOF' > "${LAB_DIR}/app.py"
import os
import redis
from flask import Flask, jsonify

app = Flask(__name__)

REDIS_HOST = os.getenv('REDIS_HOST', '127.0.0.1')
REDIS_PORT = int(os.getenv('REDIS_PORT', 6379))

@app.route('/')
def index():
    try:
        r = redis.Redis(host=REDIS_HOST, port=REDIS_PORT, socket_timeout=2)
        hits = r.incr('page_hits')
        return jsonify({
            "status": "success",
            "message": "Standard Component Stack Fully Operational",
            "tier_web": "Nginx Reverse Proxy",
            "tier_app": "Python/Gunicorn WSGI",
            "tier_cache": "Redis In-Memory Data Store",
            "redis_hits": hits
        }), 200
    except redis.ConnectionError as e:
        return jsonify({
            "status": "error",
            "message": "Application failed to connect to Cache Tier (Redis)",
            "details": str(e)
        }), 500

if __name__ == '__main__':
    app.run(host='127.0.0.1', port=5000)
EOF

    chown -R ${APP_USER}:${APP_USER} "${LAB_DIR}"

    # 2. Systemd Service Unit for App Server
    cat << EOF > /etc/systemd/system/app-service.service
[Unit]
Description=LPI 701-100 Topic 1.2 Python Application Server
After=network.target redis.service

[Service]
Type=simple
User=${APP_USER}
WorkingDirectory=${LAB_DIR}
ExecStart=/usr/bin/gunicorn --workers 2 --bind 127.0.0.1:5000 app:app
Restart=always

[Install]
WantedBy=multi-user.target
EOF

    # 3. Nginx VirtualHost Reverse Proxy Configuration
    cat << 'EOF' > /etc/nginx/sites-available/devops-lab
server {
    listen 80 default_server;
    server_name _;

    location / {
        proxy_pass http://127.0.0.1:5000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
EOF

    if [[ -d /etc/nginx/sites-enabled ]]; then
        rm -f /etc/nginx/sites-enabled/default
        ln -sf /etc/nginx/sites-available/devops-lab /etc/nginx/sites-enabled/devops-lab
    else
        cp /etc/nginx/sites-available/devops-lab /etc/nginx/conf.d/devops-lab.conf
    fi

    systemctl daemon-reload
    systemctl restart redis
    systemctl restart app-service
    systemctl restart nginx
}

apply_breakages() {
    echo -e "${YELLOW}[!] Injecting controlled architectural breakages into the system...${NC}"

    # Breakage 1: Nginx Upstream Misconfiguration (Port 5001 instead of 5000)
    sed -i 's/127.0.0.1:5000/127.0.0.1:5001/g' /etc/nginx/sites-available/devops-lab 2>/dev/null || \
    sed -i 's/127.0.0.1:5000/127.0.0.1:5001/g' /etc/nginx/conf.d/devops-lab.conf

    # Breakage 2: Systemd Network Namespace Isolation on App Service
    cat << EOF > /etc/systemd/system/app-service.service
[Unit]
Description=LPI 701-100 Topic 1.2 Python Application Server
After=network.target redis.service

[Service]
Type=simple
User=${APP_USER}
WorkingDirectory=${LAB_DIR}
ExecStart=/usr/bin/gunicorn --workers 2 --bind 127.0.0.1:5000 app:app
PrivateNetwork=yes
Restart=always

[Install]
WantedBy=multi-user.target
EOF

    # Breakage 3: Redis Network Binding Restricted to IPv6
    REDIS_CONF="/etc/redis/redis.conf"
    if [[ ! -f "$REDIS_CONF" ]]; then
        REDIS_CONF="/etc/redis.conf"
    fi

    if grep -q "^bind " "$REDIS_CONF"; then
        sed -i 's/^bind .*/bind ::1/' "$REDIS_CONF"
    else
        echo "bind ::1" >> "$REDIS_CONF"
    fi

    # Restart services to apply breaks
    systemctl daemon-reload
    systemctl restart redis || true
    systemctl restart app-service || true
    systemctl reload nginx || systemctl restart nginx
}

display_instructions() {
    echo -e "\n${GREEN}==============================================================================${NC}"
    echo -e "${GREEN}        LPI 701-100 TOPIC 1.2: BREAK & FIX PRODUCTION LAB LOADED              ${NC}"
    echo -e "${GREEN}==============================================================================${NC}\n"
    
    echo -e "${BLUE}SCENARIO DESCRIPTION:${NC}"
    echo -e "You are maintaining a production 3-Tier Web Application deployed on this Linux host:"
    echo -e "  • Web / Reverse Proxy Tier: Nginx (Listening on 0.0.0.0:80)"
    echo -e "  • Application Server Tier: Python/Gunicorn WSGI app (`app-service.service` on 127.0.0.1:5000)"
    echo -e "  • Caching / State Tier: Redis key-value store (`redis.service` on 127.0.0.1:6379)\n"
    
    echo -e "${RED}CURRENT SYMPTOMS:${NC}"
    echo -e "1. Executing 'curl -v http://localhost' returns HTTP 502 Bad Gateway."
    echo -e "2. The platform monitor reports cascading service failures across components.\n"

    echo -e "${YELLOW}STUDENT OBJECTIVE:${NC}"
    echo -e "Diagnose the system using standard SRE/DevOps commands (`ss`, `curl`, `journalctl`, `systemctl`, `nginx -t`)."
    echo -e "Fix all configuration flaws until `curl -s http://localhost` returns HTTP status 200 with the payload:"
    echo -e '  {"status": "success", "redis_hits": <int>, "tier_app": "Python/Gunicorn WSGI", ...}\n'

    echo -e "${BLUE}DIAGNOSTIC WORKFLOW HINTS:${NC}"
    echo -e "  1. Test the entry point: `curl -v http://localhost`"
    echo -e "  2. Inspect Nginx access and error logs: `tail -n 20 /var/log/nginx/error.log`"
    echo -e "  3. Verify open sockets: `ss -tulpn | grep -E '80|5000|6379'`"
    echo -e "  4. Check application logs: `journalctl -u app-service -n 30 --no-pager`"
    echo -e "  5. Verify Redis connectivity: `redis-cli ping` or `nc -zvw3 127.0.0.1 6379`\n"
    echo -e "------------------------------------------------------------------------------"
    echo -e "The solution steps are commented at the bottom of this script file:"
    echo -e "View with: `tail -n 45 $0`"
    echo -e "------------------------------------------------------------------------------\n"
}

main() {
    check_root
    install_dependencies
    setup_baseline_environment
    apply_breakages
    display_instructions
}

main "$@"

# ==============================================================================
#                               STUDENT SOLUTION GUIDE
#                  (DO NOT READ UNTIL YOU HAVE ATTEMPTED TO FIX IT!)
# ==============================================================================
#
# STEP-BY-STEP DIAGNOSIS AND REMEDIATION:
#
# --- STEP 1: Fix Web Proxy Layer (Nginx Upstream Port) ---
# Command: curl -i http://localhost
# Output: HTTP/1.1 502 Bad Gateway
# Inspect Logs: tail -f /var/log/nginx/error.log
# Log evidence: connect() failed (111: Connection refused) while connecting to upstream, client: 127.0.0.1, server: _, request: "GET / HTTP/1.1", upstream: "http://127.0.0.1:5001/"
# Inspect Sockets: ss -tulpn | grep 500
# SRE Insight: Nginx is trying port 5001, but the app is listening on 5000.
# Fix:
#   1. Edit /etc/nginx/sites-available/devops-lab (or /etc/nginx/conf.d/devops-lab.conf).
#   2. Change `proxy_pass http://127.0.0.1:5001;` to `proxy_pass http://127.0.0.1:5000;`.
#   3. Validate syntax: nginx -t
#   4. Reload Nginx: systemctl reload nginx
#
# --- STEP 2: Fix Application Service Network Isolation (systemd) ---
# Command: curl -i http://localhost
# Output: HTTP/1.1 500 Internal Server Error
# Payload: {"details": "Error 111 connecting to 127.0.0.1:6379. Connection refused.", "status": "error"}
# Inspect App Logs: journalctl -u app-service -n 25 --no-pager
# Test Direct Connection from Host: redis-cli -h 127.0.0.1 ping
# SRE Insight: Redis host accepts connections, but app running under systemd gets Connection Refused on loopback.
# Inspect Service Unit: systemctl cat app-service
# Notice directive: `PrivateNetwork=yes`. This creates a isolated network namespace (`lo` only, no interface access to host loopback).
# Fix:
#   1. Edit /etc/systemd/system/app-service.service.
#   2. Remove line `PrivateNetwork=yes` (or set to `no`).
#   3. Reload systemd & restart app:
#      systemctl daemon-reload
#      systemctl restart app-service
#
# --- STEP 3: Fix Cache/Database Tier Binding (Redis IPv4/IPv6) ---
# Command: curl -i http://localhost
# If Redis ping still fails or binds strictly to IPv6 `::1`, inspect Redis listening address:
# Inspect Sockets: ss -tulpn | grep 6379
# Output shows: tcp LISTEN 0 512 [::1]:6379 (Bound ONLY to IPv6 loopback, rejecting IPv4 127.0.0.1).
# Fix:
#   1. Edit /etc/redis/redis.conf (or /etc/redis.conf).
#   2. Locate `bind` directive and change to: `bind 127.0.0.1 ::1`
#   3. Restart Redis: systemctl restart redis
#
# --- VERIFICATION ---
# Run: curl -s http://localhost | python3 -m json.tool
# Expected Result:
# {
#     "message": "Standard Component Stack Fully Operational",
#     "redis_hits": 1,
#     "status": "success",
#     "tier_app": "Python/Gunicorn WSGI",
#     "tier_cache": "Redis In-Memory Data Store",
#     "tier_web": "Nginx Reverse Proxy"
# }
# ==============================================================================