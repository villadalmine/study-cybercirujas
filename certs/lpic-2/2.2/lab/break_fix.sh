#!/bin/bash
# ==============================================================================
# LPIC-2 (Exams 201-450 & 202-450 v4.5) - Topic 2.2 / 208: Web Services
# Production Break & Fix Lab Script: High-Availability HTTPS & FastCGI Gateway
#
# Official References:
# - LPIC-2 Exam Objectives: https://www.lpi.org/our-certifications/lpic-2-overview/
# - NGINX Architecture & HTTP Core: https://nginx.org/en/docs/
# - Apache HTTP Server Documentation v2.4: https://httpd.apache.org/docs/2.4/
# - OpenSSL TLS/SSL CLI Diagnostics: https://www.openssl.org/docs/manmaster/man1/openssl-s_client.html
# - PHP-FPM FastCGI Protocol Integration: https://www.php.net/manual/en/install.fpm.php
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# 1. Environment & Privilege Verification
# ------------------------------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
    echo "[ERROR] This Break & Fix lab script must be executed as root (or via sudo)." >&2
    exit 1
fi

WEB_USER="www-data"
if ! id "$WEB_USER" &>/dev/null; then
    WEB_USER="nginx"
    if ! id "$WEB_USER" &>/dev/null; then
        useradd --system --no-create-home --shell /bin/false www-data || true
        WEB_USER="www-data"
    fi
fi

LAB_DIR="/var/www/production-app"
CONF_DIR="/etc/nginx/conf.d"
SSL_DIR="/etc/ssl/lab-certs"
SOCKET_DIR="/run/php-fpm"

# ------------------------------------------------------------------------------
# 2. Lab Setup & Controlled Failure Injection
# ------------------------------------------------------------------------------
echo "[LAB SETUP] Initializing LPIC-2 Web Services production lab environment..."

# Package check / provisioning simulation
mkdir -p "$LAB_DIR/public" "$CONF_DIR" "$SSL_DIR" "$SOCKET_DIR"

# Generate Self-Signed Certificate Chain for SNI / TLS testing
if [ ! -f "$SSL_DIR/app.crt" ]; then
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout "$SSL_DIR/app.key" \
        -out "$SSL_DIR/app.crt" \
        -subj "/C=US/ST=State/L=City/O=Production/OU=SRE/CN=app.production.local" \
        &>/dev/null
fi

# Create target index file
cat << 'EOF' > "$LAB_DIR/public/index.php"
<?php
header('Content-Type: application/json');
echo json_encode([
    'status' => 'HEALTHY',
    'timestamp' => time(),
    'server' => $_SERVER['SERVER_SOFTWARE'] ?? 'NGINX/PHP-FPM',
    'protocol' => $_SERVER['HTTPS'] ?? 'off'
]);
EOF

# Inject Fault 1: Strict/Unreadable File Permissions on SSL Private Key
chmod 0000 "$SSL_DIR/app.key"
chown root:root "$SSL_DIR/app.key"

# Inject Fault 2: DocumentRoot ownership isolation causing HTTP 403 Forbidden
chmod 0700 "$LAB_DIR/public"
chown root:root "$LAB_DIR/public"
chmod 0600 "$LAB_DIR/public/index.php"

# Inject Fault 3: Broken PHP-FPM Unix Socket permissions
touch "$SOCKET_DIR/php-fpm.sock"
chmod 0600 "$SOCKET_DIR/php-fpm.sock"
chown root:root "$SOCKET_DIR/php-fpm.sock"

# Inject Fault 4: Syntactically Invalid and Misconfigured NGINX Virtual Host Manifest
cat << 'EOF' > "$CONF_DIR/app.production.local.conf"
# Production Virtual Host Configuration for LPIC-2 Topic 208 Validation
server {
    listen 80;
    listen [::]:80;
    server_name app.production.local;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl http2
    server_name app.production.local;

    root /var/www/production-app/public;
    index index.php index.html;

    # SSL TLS Engine Configuration
    ssl_certificate /etc/ssl/lab-certs/app.crt;
    ssl_certificate_key /etc/ssl/lab-certs/app.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    location / {
        try_files $uri $uri/ /index.php?$args;
    }

    location ~ \.php$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        # Unix domain socket FastCGI proxy setup
        fastcgi_pass unix:/run/php-fpm/php-fpm.sock;
        fastcgi_index index.php;
        
        # BROKEN PARAMETER: Missing lead slash and improper scope definition
        fastcgi_param SCRIPT_FILENAME document_root$fastcgi_script_name;
        include fastcgi_params;
    }
}
EOF

# ------------------------------------------------------------------------------
# 3. Student Briefing & Diagnostic Guide
# ------------------------------------------------------------------------------
cat << EOF

================================================================================
                    LPIC-2 Web Services: Break & Fix Lab
================================================================================
ARCHITECTURE OVERVIEW:
You are troubleshooting an enterprise web gateway operating NGINX as an event-
driven reverse proxy terminating TLS 1.2/1.3 and offloading dynamic execution
to PHP-FPM via a FastCGI Unix Domain Socket (/run/php-fpm/php-fpm.sock).

DEEP TECHNICAL MECHANICS & TRADE-OFFS:
1. Event Loop vs. Process Model:
   - NGINX uses an asynchronous, non-blocking event-loop (epoll on Linux) where
     a master process delegates worker connections without process-per-request overhead.
   - Apache HTTPD offers Multi-Processing Modules (MPMs):
     * prefork: One thread per process (no thread safety issues, high memory footprint).
     * worker: Multi-process with multi-threading (lower RAM usage, requires thread-safe modules).
     * event: Worker architecture optimized for Keep-Alive handling via dedicated listening threads.

2. FastCGI vs HTTP Reverse Proxying:
   - FastCGI maintains persistent binary protocol connections between web server and app workers.
   - Unix Domain Sockets eliminate TCP stack overhead (loopback framing, handshake, port exhaustion)
     offloading routing to OS IPC primitives, but mandate precise POSIX ACL match between worker users.

3. SSL/TLS SNI Mechanics:
   - Server Name Indication (SNI) passes requested hostname inside TLS Client Hello before cipher setup,
     allowing multi-tenant VirtualHosts to bind to a single IP:Port listener.

CURRENT INCIDENT SYMPTOMS:
- `nginx -t` fails to validate configurations.
- Web server fails to boot or reload state via systemd.
- HTTP client queries return 502 Bad Gateway, 403 Forbidden, or SSL Handshake failures.
- FastCGI binary bridge fails to execute target scripts.

OBJECTIVES TO COMPLETE:
1. Fix all NGINX configuration syntax errors in `$CONF_DIR/app.production.local.conf`.
2. Resolve POSIX file permissions and DAC contexts for SSL Private Keys.
3. Fix Unix Domain Socket ownership and file permissions between NGINX and FastCGI daemon.
4. Correct FastCGI directive variables for proper SCRIPT_FILENAME path expansion.
5. Fix DocumentRoot directory and file read/execute permissions for web daemon user ($WEB_USER).
6. Verify end-to-end execution returning HTTP 200 JSON status payload over HTTPS.

REAL CLI DIAGNOSTIC WORKFLOW TO EXECUTE:
  1. Syntax Check:
     # nginx -t -c /etc/nginx/nginx.conf
  2. Socket & Process Verification:
     # ss -x -l | grep php-fpm
     # ls -la /run/php-fpm/php-fpm.sock
  3. Certificate & Key Permission Audit:
     # namei -om /etc/ssl/lab-certs/app.key
     # openssl x509 -in /etc/ssl/lab-certs/app.crt -text -noout
  4. Dynamic Trace Diagnostics:
     # curl -Iv -k --resolve app.production.local:443:127.0.0.1 https://app.production.local/index.php
     # journalctl -u nginx -n 50 --no-pager

================================================================================
Lab environment broken successfully! Begin troubleshooting now.
================================================================================
EOF

exit 0

# ==============================================================================
#                      STEP-BY-STEP SOLUTION (COMMENTED)
# ==============================================================================
# The following bash commands represent the step-by-step resolution path
# to solve all injected faults and verify full production compliance.
#
# STEP 1: Identify Syntax Errors in NGINX VHost Manifest
# Execute syntax validation:
#   nginx -t
# Output error will highlight missing semicolon on line 9: `listen 443 ssl http2` -> `listen 443 ssl http2;`
# Edit file `/etc/nginx/conf.d/app.production.local.conf` and append missing semicolon `;`.
#
# STEP 2: Fix FastCGI SCRIPT_FILENAME Directive Mapping
# In `/etc/nginx/conf.d/app.production.local.conf`, find line:
#   fastcgi_param SCRIPT_FILENAME document_root$fastcgi_script_name;
# Change it to include the proper dollar sign prefix for NGINX variable evaluation:
#   fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
#
# Complete Syntactically Valid Manifest Example:
# ------------------------------------------------------------------------------
# server {
#     listen 80;
#     listen [::]:80;
#     server_name app.production.local;
#     return 301 https://$host$request_uri;
# }
#
# server {
#     listen 443 ssl;
#     listen [::]:443 ssl;
#     server_name app.production.local;
#
#     root /var/www/production-app/public;
#     index index.php index.html;
#
#     ssl_certificate /etc/ssl/lab-certs/app.crt;
#     ssl_certificate_key /etc/ssl/lab-certs/app.key;
#     ssl_protocols TLSv1.2 TLSv1.3;
#     ssl_ciphers HIGH:!aNULL:!MD5;
#
#     location / {
#         try_files $uri $uri/ /index.php?$args;
#     }
#
#     location ~ \.php$ {
#         fastcgi_split_path_info ^(.+\.php)(/.+)$;
#         fastcgi_pass unix:/run/php-fpm/php-fpm.sock;
#         fastcgi_index index.php;
#         fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
#         include fastcgi_params;
#     }
# }
# ------------------------------------------------------------------------------
#
# STEP 3: Fix POSIX File Permissions on Private Key
# Audit permissions:
#   ls -la /etc/ssl/lab-certs/app.key
# Output showing `---------- root root` prevents master worker read on boot.
# Fix read access for root / web group:
#   chmod 0640 /etc/ssl/lab-certs/app.key
#   chown root:www-data /etc/ssl/lab-certs/app.key   # (or root:nginx depending on distro)
#
# STEP 4: Fix Document Root Directory and File Permissions
# NGINX worker process running as `www-data` requires read + execute (r-x) on directories:
#   chmod 0755 /var/www/production-app/public
#   chmod 0644 /var/www/production-app/public/index.php
#   chown -R www-data:www-data /var/www/production-app/public
#
# STEP 5: Resolve FastCGI Unix Socket Access Rights
# FastCGI socket requires read/write (rw) access for web server worker:
#   chown www-data:www-data /run/php-fpm/php-fpm.sock
#   chmod 0660 /run/php-fpm/php-fpm.sock
#
# STEP 6: Reload Service & Run Verification Commands
# Test NGINX configuration syntax:
#   nginx -t
# Expected Output:
#   nginx: the configuration file /etc/nginx/nginx.conf syntax is ok
#   nginx: configuration file /etc/nginx/nginx.conf test is successful
#
# Reload system service:
#   systemctl reload nginx || nginx -s reload
#
# Test HTTP to HTTPS Redirection:
#   curl -Iv -H "Host: app.production.local" http://127.0.0.1/
# Expected Output:
#   HTTP/1.1 301 Moved Permanently
#   Location: https://app.production.local/
#
# Test End-to-End TLS & FastCGI Payload:
#   curl -Iv -k --resolve app.production.local:443:127.0.0.1 https://app.production.local/index.php
# Expected Output:
#   * Server certificate:
#   *  subject: C=US; ST=State; L=City; O=Production; OU=SRE; CN=app.production.local
#   < HTTP/1.1 200 OK
#   < Content-Type: application/json
#   {"status":"HEALTHY","timestamp":1770388206,"server":"NGINX\/PHP-FPM","protocol":"on"}
#
# Test OpenSSL Handshake & SNI Engine:
#   openssl s_client -connect 127.0.0.1:443 -servername app.production.local -brief
# Expected Output:
#   CONNECTION ESTABLISHED
#   Protocol version: TLSv1.3
#   Ciphersuite: TLS_AES_256_GCM_SHA384
# ==============================================================================