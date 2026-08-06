#!/bin/bash
# ==============================================================================
# LPI 030-100: Web Development Essentials (Version 1.0)
# Topic 1.2: Web Application Architecture (Exam Weight: 5)
# Real-World SRE "Break & Fix" Production Lab Script
#
# Reference: https://www.lpi.org/our-certifications/web-development-essentials-overview/
# Target OS: Ubuntu / Debian Linux Disposable Lab VM
# ==============================================================================

set -euo pipefail

# Ensure script is executed with root privileges
if [[ $EUID -ne 0 ]]; then
   echo "[ERROR] This lab provisioning script must be executed as root (or via sudo)." >&2
   exit 1
fi

echo "------------------------------------------------------------------------"
echo "  Provisioning SRE Lab Environment: Web Application Architecture (1.2) "
echo "------------------------------------------------------------------------"

# 1. Install prerequisites quietly
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq && apt-get install -y -qq nginx python3 > /dev/null

# 2. Setup Application Layer (Backend Python WSGI / HTTP Server)
mkdir -p /opt/webapp
cat << 'EOF' > /opt/webapp/app.py
#!/usr/bin/env python3
import http.server
import socketserver
import os
import sys

PORT = 8080

class ArchitectureHandler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        # Validate Proxy Host Header propagation
        host_header = self.headers.get('Host', '')
        forwarded_for = self.headers.get('X-Forwarded-For', '')
        
        if not host_header or host_header == 'localhost:8080':
            self.send_response(400)
            self.send_header('Content-Type', 'text/plain')
            self.end_headers()
            self.wfile.write(b"400 Bad Request: Direct access bypasses Reverse Proxy or Host header missing.\n")
            return

        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        response = (
            f'{{"status":"healthy","tier":"application_backend","received_host":"{host_header}",'
            f'"client_ip_chain":"{forwarded_for}"}}\n'
        )
        self.wfile.write(response.encode('utf-8'))

if __name__ == "__main__":
    # Check required environment file
    if not os.path.exists("/etc/default/webapp-backend"):
        print("CRITICAL: Environment configuration file /etc/default/webapp-backend missing!", file=sys.stderr)
        sys.exit(1)

    with socketserver.TCPServer(("127.0.0.1", PORT), ArchitectureHandler) as httpd:
        print(f"Backend WSGI/HTTP service listening on 127.0.0.1:{PORT}")
        httpd.serve_forever()
EOF

chmod 755 /opt/webapp/app.py

# Create systemd unit file for Application Backend
cat << 'EOF' > /etc/systemd/system/webapp-backend.service
[Unit]
Description=LPI 030-100 Web Application Backend Service
After=network.target

[Service]
Type=simple
User=www-data
Group=www-data
WorkingDirectory=/opt/webapp
ExecStart=/usr/bin/python3 /opt/webapp/app.py
Restart=on-failure
EnvironmentFile=/etc/default/webapp-backend

[Install]
WantedBy=multi-user.target
EOF

# 3. Setup Presentation / Reverse Proxy Layer (Nginx)
rm -f /etc/nginx/sites-enabled/default

cat << 'EOF' > /etc/nginx/sites-available/webapp.conf
server {
    listen 80 default_server;
    server_name _;

    # Static Asset Routing (Edge Layer)
    location /static/ {
        alias /var/www/html/static/;
        expires 1d;
    }

    # Dynamic Application Backend Proxying
    location / {
        # INTENTIONAL BUG 1: Misconfigured upstream TCP port (8081 instead of 8080)
        proxy_pass http://127.0.0.1:8081;

        # INTENTIONAL BUG 2: Missing essential HTTP reverse proxy headers
        # SRE must restore Host, X-Real-IP, and X-Forwarded-For headers
    }
}
EOF

ln -sf /etc/nginx/sites-available/webapp.conf /etc/nginx/sites-enabled/webapp.conf

# 4. Inject Controlled Architectural Breakages
# Breakage A: Systemd service fails because /etc/default/webapp-backend has invalid permissions (000)
touch /etc/default/webapp-backend
echo "APP_ENV=production" > /etc/default/webapp-backend
chmod 000 /etc/default/webapp-backend

# Reload systemd and try starting backend (will fail silently or enter restart loop)
systemctl daemon-reload
systemctl enable webapp-backend.service > /dev/null 2>&1 || true
systemctl start webapp-backend.service > /dev/null 2>&1 || true

# Test & reload Nginx with broken configuration
nginx -t > /dev/null 2>&1 && systemctl reload nginx

# Clear screen and display problem statement to the student
clear
cat << 'EOF'
================================================================================
 INCIDENT REPORT: WEB APPLICATION ARCHITECTURE TIERS FAILURE
 Certification: LPI 030-100 (Exam 030-100, Version 1.0) - Topic 1.2 (Weight 5)
 Source: https://www.lpi.org/our-certifications/web-development-essentials-overview/
================================================================================

[SYSTEM ALERT]
Production incident logged: The 3-tier web application architecture is failing.
Clients querying the frontend Edge Proxy receive "HTTP 502 Bad Gateway" or 
"HTTP 400 Bad Request" errors.

--------------------------------------------------------------------------------
OBSERVED SYMPTOMS:
--------------------------------------------------------------------------------
1. Running `curl -i http://localhost/` returns:
   "HTTP/1.1 502 Bad Gateway"

2. Direct request checks indicate proxy-to-backend communication issues.

--------------------------------------------------------------------------------
YOUR OBJECTIVE (SRE GOAL):
--------------------------------------------------------------------------------
1. Diagnose the multi-tier request pipeline:
   [Client] ---> [Nginx Reverse Proxy: Port 80] ---> [Python App Backend: Port 8080]

2. Fix the Application Tier:
   - Identify why `webapp-backend.service` fails to run under systemd.
   - Ensure the backend process is bound to loopback `127.0.0.1:8080`.

3. Fix the Reverse Proxy Tier:
   - Correct the upstream proxy destination port in Nginx configuration.
   - Configure proper HTTP header forwarding (`Host`, `X-Forwarded-For`, `X-Real-IP`).

4. Verification Criteria:
   Executing `curl -i http://localhost/` MUST return:
   - HTTP Status: `200 OK`
   - Body JSON: `{"status":"healthy","tier":"application_backend",...}`

================================================================================
Begin debugging using `systemctl`, `journalctl`, `ss`, `nginx -t`, and `curl`.
================================================================================
EOF

# ==============================================================================
# STEP-BY-STEP SOLUTION (STUDENT REFERENCE - COMMENTED OUT)
# ==============================================================================
#
# DIAGNOSIS & REPAIR WORKFLOW:
#
# 1. AGENT DIAGNOSTIC - STEP 1: Check Reverse Proxy Logs & Endpoint Response
#    $ curl -i http://localhost/
#    Output: HTTP/1.1 502 Bad Gateway
#    $ tail -n 20 /var/log/nginx/error.log
#    Output error: connect() failed (111: Connection refused) while connecting to upstream,
#    upstream: "http://127.0.0.1:8081/index.html"
#
# 2. AGENT DIAGNOSTIC - STEP 2: Inspect Application Tier & Socket Bindings
#    $ ss -tulpn | grep 808
#    (No process listening on 8080 or 8081)
#    $ systemctl status webapp-backend.service
#    Output: Active: failed (Result: exit-code)
#    $ journalctl -u webapp-backend.service -n 20 --no-pager
#    Output error: PermissionError: [Errno 13] Permission denied: '/etc/default/webapp-backend'
#
# 3. REPAIR STEP 1: Fix Application Tier Service Permission Bug
#    $ chmod 644 /etc/default/webapp-backend
#    $ systemctl restart webapp-backend.service
#    $ systemctl status webapp-backend.service
#    (Verify service is active (running))
#    $ ss -tulpn | grep 8080
#    (Verify python3 is listening on 127.0.0.1:8080)
#
# 4. REPAIR STEP 2: Fix Nginx Reverse Proxy Configuration & Upstream Port
#    Edit /etc/nginx/sites-available/webapp.conf:
#
#    replace:
#        location / {
#            proxy_pass http://127.0.0.1:8081;
#        }
#    with:
#        location / {
#            proxy_pass http://127.0.0.1:8080;
#            proxy_set_header Host $host;
#            proxy_set_header X-Real-IP $remote_addr;
#            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
#        }
#
# 5. REPAIR STEP 3: Test & Reload Nginx Architecture
#    $ nginx -t
#    $ systemctl reload nginx
#
# 6. FINAL VERIFICATION:
#    $ curl -i http://localhost/
#    Expected Output:
#    HTTP/1.1 200 OK
#    Server: nginx/...
#    Content-Type: application/json
#    
#    {"status":"healthy","tier":"application_backend","received_host":"localhost","client_ip_chain":"127.0.0.1"}
# ==============================================================================