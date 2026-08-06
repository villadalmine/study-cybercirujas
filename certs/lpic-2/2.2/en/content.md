# LPIC-2 Exam 202-450: Topic 208 (Web Services) SRE Architecture & Engineering Guide

---

## 1. Production Architectural Motivation & Problem Statement

### 1.1 The Evolution of Web Service Architecture
Modern high-availability production environments require edge layer web architectures capable of handling tens of thousands of concurrent client connections while maintaining low latencies, strict security postures, and resource efficiency. Web services serve as the primary entry point (Ingress/Edge) for enterprise applications, mediating traffic between untrusted public networks and internal application runtimes.

Historically, web servers operated under a process-per-connection model. While simple and isolated, this architecture scales poorly as connection volume grows. Modern platform engineering relies on dynamic concurrency models, asynchronous I/O multiplexing, reverse-proxy caching, and hardware-accelerated TLS termination.

```
                         [ Untrusted Public Network ]
                                      │
                                      ▼
                        [ Layer 4/7 Load Balancer ]
                                      │
                   ┌──────────────────┴──────────────────┐
                   │ SNI / TLS 1.3 Edge Termination     │
                   ▼                                     ▼
      ┌─────────────────────────┐           ┌─────────────────────────┐
      │  NGINX Reverse Proxy    │           │  Apache HTTPD (Event)   │
      │  - Dynamic Buffering    │           │  - Auth / Legacy Logic  │
      │  - Keepalive Pools      │           │  - Static Asset Engine  │
      └────────────┬────────────┘           └────────────┬────────────┘
                   │                                     │
                   ├──────────────────┬──────────────────┤
                   ▼                  ▼                  ▼
          ┌────────────────┐ ┌────────────────┐ ┌────────────────┐
          │ App Node 01    │ │ App Node 02    │ │ App Node 03    │
          │ (PHP-FPM/Node) │ │ (PHP-FPM/Node) │ │ (PHP-FPM/Node) │
          └────────────────┘ └────────────────┘ └────────────────┘
```

### 1.2 Production Bottlenecks & Architectural Challenges

#### The C10K/C10M Challenge & Context Switching
Under legacy models (e.g., Apache `prefork`), each concurrent HTTP connection consumes an entire Operating System process. When connection counts scale to tens of thousands, the Linux Kernel spends a disproportionate amount of CPU cycles executing context switches (`schedule()`) and managing process memory structures (`task_struct`), leading to thrashing and high load averages even at low overall CPU utilization.

#### Resource Saturation under KeepAlive
HTTP KeepAlive maintains persistent TCP connections to eliminate the three-way handshake overhead for subsequent HTTP requests. However, under blocking I/O models, holding an idle TCP connection open holds an active server thread or process hostage, exhausting available worker pools and rejecting new inbound connections with `503 Service Unavailable`.

#### Edge TLS Offloading & Compute Overhead
Asymmetric cryptography (RSA/ECDSA handshakes) requires compute-intensive modular exponentiations and elliptic curve calculations. In enterprise architectures, TLS termination must occur at the edge layer using efficient session resumption techniques (TLS Session Tickets / Session IDs) and Server Name Indication (SNI) to host multiple virtual domains on shared IP infrastructure without leaking memory or CPU cycles.

---

## 2. Technical Comparisons & Trade-off Matrices

### 2.1 Apache HTTPD Multi-Processing Modules (MPMs)
Apache HTTPD delegates connection handling to modular engines called Multi-Processing Modules (MPMs). Choosing the correct MPM is critical for performance tuning and memory stability.

| Dimension | `prefork` | `worker` | `event` |
| :--- | :--- | :--- | :--- |
| **Concurrency Model** | Non-threaded, single-process per connection | Hybrid Multi-Process, Multi-Threaded | Hybrid Multi-Process, Multi-Threaded with Async Event Loop |
| **I/O Mechanism** | Blocking I/O (`select`/`poll`) | Blocking I/O per thread | Asynchronous non-blocking (`epoll` on Linux, `kqueue` on BSD) |
| **Memory Footprint** | Extremely High (~15MB–50MB per process) | Moderate (~2MB–5MB per thread pool) | Low (~1MB–3MB per thread pool) |
| **Thread Safety Requirements** | No (Safe for non-thread-safe modules like legacy `mod_php`) | Yes (All modules and libraries must be thread-safe) | Yes (All modules and libraries must be thread-safe) |
| **KeepAlive Handling** | Worker process locked for duration of KeepAlive timeout | Thread locked for duration of KeepAlive timeout | Dedicated Listener Thread handles KeepAlive; Worker Threads freed instantly |
| **Max Scale Potential** | Low (< 1,000 concurrent connections) | Medium (~10,000 concurrent connections) | High (100,000+ concurrent connections) |
| **Recommended Use Case** | Legacy PHP embedded runtimes (`mod_php`) | High-concurrency threaded workloads without KeepAlive overhead | Modern production standard for Apache HTTPD |

### 2.2 Architectural Comparison: Apache HTTPD vs. NGINX vs. Squid

| Feature / Architecture | Apache HTTPD (`mod_mpm_event`) | NGINX | Squid |
| :--- | :--- | :--- | :--- |
| **Primary Role** | Feature-rich Web Server, Dynamic Content Engine | High-Performance Event-Driven Web Server & Reverse Proxy | Dedicated Forward / Reverse Caching Proxy |
| **Worker Architecture** | Dynamic Thread Pools managed across worker processes | Single Master Process + Fixed Asynchronous Worker Processes | Single-threaded main event loop (`epoll`) with helper disk I/O threads |
| **Configuration Model** | Dynamic via `.htaccess` (optional per-directory runtime parsing) | Static compilation at reload; strictly central configuration files | Static central configuration; hierarchical ACL processing |
| **Static File Delivery** | Direct kernel `sendfile()` support | Optimized `sendfile()`, `tcp_nopush`, `tcp_nodelay` zero-copy architecture | Memory and Disk Object Store caching (`ufs`, `aufs`, `rock`) |
| **Proxy Capacities** | Forward/Reverse via `mod_proxy`, `mod_proxy_http`, `mod_proxy_fcgi` | High-throughput Layer 7 reverse proxy with upstream connection pooling | Complex L7 Forward Proxying, ICAP content inspection, Bandwidth throttling (Delay Pools) |
| **SSL/TLS Capabilities** | OpenSSL engine, SNI, OCSP Stapling, `mod_md` ACME client | OpenSSL/BoringSSL engine, SNI, OCSP Stapling, SSL Session Reuse | SSL Bump (TLS Man-in-the-Middle inspection), Ingress TLS Offloading |

### 2.3 Cryptographic Standards: TLS Protocol & Key Architectures

| Parameter | TLS 1.2 | TLS 1.3 |
| :--- | :--- | :--- |
| **Handshake Latency** | 2 RTT (Round Trip Times) | 1 RTT (0-RTT with Early Data Resumption) |
| **Key Exchange Mechanics** | Static RSA, DH, ECDH | Ephemeral Diffie-Hellman Only (ECDHE / DHE) — Mandatory Perfect Forward Secrecy |
| **Supported Cipher Suites** | ~30+ legacy suites (Includes CBC mode, RC4, 3DES) | 5 streamlined suites (AES-GCM, CHACHA20-POLY1305, AES-CCM) |
| **SNI Encryption** | Unencrypted (Client Hello SNI visible in plaintext) | Encrypted SNI / Encrypted Client Hello (ECH) standard |

---

## 3. Production Configuration Manifests

### 3.1 Apache HTTPD Enterprise Configuration

#### Main System Configuration: `/etc/httpd/conf/httpd.conf`
```apache
# Enterprise Production Apache HTTPD Configuration
# Target Environment: AlmaLinux 9 / RHEL 9 / CentOS Stream
# MPM Engine: Event

ServerRoot "/etc/httpd"
Listen 80
Listen 443 https

# Core Module Loading
LoadModule mpm_event_module modules/mod_mpm_event.so
LoadModule log_config_module modules/mod_log_config.so
LoadModule setenvif_module modules/mod_setenvif.so
LoadModule authz_core_module modules/mod_authz_core.so
LoadModule authz_host_module modules/mod_authz_host.so
LoadModule authn_core_module modules/mod_authn_core.so
LoadModule authn_file_module modules/mod_authn_file.so
LoadModule authz_user_module modules/mod_authz_user.so
LoadModule auth_basic_module modules/mod_auth_basic.so
LoadModule status_module modules/mod_status.so
LoadModule dir_module modules/mod_dir.so
LoadModule mime_module modules/mod_mime.so
LoadModule ssl_module modules/mod_ssl.so
LoadModule proxy_module modules/mod_proxy.so
LoadModule proxy_http_module modules/mod_proxy_http.so
LoadModule headers_module modules/mod_headers.so
LoadModule unixd_module modules/mod_unixd.so

User apache
Group apache
ServerAdmin admin@infrastructure.internal
ServerTokens Prod
ServerSignature Off
TraceEnable Off

# MPM Event Configuration Tuning
<IfModule mpm_event_module>
    StartServers             8
    MinSpareThreads         75
    MaxSpareThreads        250
    ThreadsPerChild         64
    MaxRequestWorkers     2048
    MaxConnectionsPerChild 10000
    AsyncRequestWorkerFactor 2
</IfModule>

# Restrict default filesystem access
<Directory />
    AllowOverride None
    Require all denied
</Directory>

DocumentRoot "/var/www/html"

<Directory "/var/www/html">
    Options -Indexes +FollowSymLinks
    AllowOverride None
    Require all granted
</Directory>

# Logging Configuration
LogFormat "%h %l %u %t \"%r\" %>s %b \"%{Referer}i\" \"%{User-Agent}i\"" combined
LogFormat "%h %l %u %t \"%r\" %>s %b" common
CustomLog "logs/access_log" combined
ErrorLog "logs/error_log"
LogLevel warn

# Global TLS Defaults (Mozilla Modern Configuration)
SSLPassPhraseDialog exec:/usr/libexec/httpd-ssl-pass-dialog
SSLSessionCache shmcb:/run/httpd/sslcache(512000)
SSLSessionCacheTimeout 300
SSLRandomSeed startup file:/dev/urandom 512
SSLRandomSeed connect builtin
SSLCryptoDevice builtin

# Global TLS Security Restrictions
SSLProtocol -all +TLSv1.2 +TLSv1.3
SSLCipherSuite ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384
SSLHonorCipherOrder off
SSLSessionTickets off

# Include Virtual Host Declarations
IncludeOptional conf.d/*.conf
```

#### Virtual Hosts Configuration: `/etc/httpd/conf.d/vhosts.conf`
```apache
# Virtual Host 1: Insecure HTTP Redirect & Admin Authentication Area
<VirtualHost *:80>
    ServerName app.infrastructure.internal
    ServerAlias www.infrastructure.internal
    
    # Redirect all non-secure HTTP traffic to HTTPS
    Redirect permanent / https://app.infrastructure.internal/
</VirtualHost>

<VirtualHost *:80>
    ServerName admin.infrastructure.internal
    DocumentRoot "/var/www/admin"

    <Directory "/var/www/admin">
        Options -Indexes
        AllowOverride None
        AuthType Basic
        AuthName "Restricted Administration Area"
        AuthUserFile "/etc/httpd/conf/.htpasswd"
        Require valid-user
    </Directory>

    ErrorLog "logs/admin_error.log"
    CustomLog "logs/admin_access.log" combined
</VirtualHost>

# Virtual Host 2: HTTPS Production Virtual Host with SNI & OCSP Stapling
<VirtualHost *:443>
    ServerName app.infrastructure.internal
    DocumentRoot "/var/www/app"

    SSLEngine on
    SSLCertificateFile "/etc/pki/tls/certs/app.infrastructure.internal.crt"
    SSLCertificateKeyFile "/etc/pki/tls/private/app.infrastructure.internal.key"
    SSLCertificateChainFile "/etc/pki/tls/certs/intermediate_ca.crt"

    # OCSP Stapling Configuration
    SSLUseStapling on
    SSLStaplingResponderTimeout 5
    SSLStaplingReturnResponderErrors off
    SSLStaplingCache "shmcb:/run/httpd/ocsp(128000)"

    # HTTP Strict Transport Security (HSTS)
    Header always set Strict-Transport-Security "max-age=63072000; includeSubDomains; preload"
    Header always set X-Frame-Options "DENY"
    Header always set X-Content-Type-Options "nosniff"

    <Directory "/var/www/app">
        Options -Indexes +FollowSymLinks
        AllowOverride None
        Require all granted
    </Directory>

    # Status Monitor Endpoint restricted to Internal Ops Subnet
    <Location "/server-status">
        SetHandler server-status
        Require ip 10.0.100.0/24 127.0.0.1
    </Location>

    ErrorLog "logs/app_ssl_error.log"
    CustomLog "logs/app_ssl_access.log" combined
</VirtualHost>
```

---

### 3.2 NGINX Enterprise Web Server & Reverse Proxy Configuration

#### Main System Configuration: `/etc/nginx/nginx.conf`
```nginx
# Enterprise NGINX Infrastructure Configuration
user nginx;
worker_processes auto;
worker_rlimit_nofile 65535;
pid /var/run/nginx.pid;
error_log /var/log/nginx/error.log warn;

events {
    worker_connections 10240;
    use epoll;
    multi_accept on;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    # Log Format Specification
    log_format production_json escape=json
      '{"time_local":"$time_local",'
      '"remote_addr":"$remote_addr",'
      '"request":"$request",'
      '"status": "$status",'
      '"body_bytes_sent":"$body_bytes_sent",'
      '"request_time":"$request_time",'
      '"http_referrer":"$http_referer",'
      '"http_user_agent":"$http_user_agent",'
      '"upstream_addr":"$upstream_addr",'
      '"upstream_status":"$upstream_status",'
      '"upstream_response_time":"$upstream_response_time"}';

    access_log /var/log/nginx/access.log production_json;

    # Performance Tuning Parameters
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    keepalive_requests 1000;
    types_hash_max_size 2048;
    server_tokens off;

    # Buffer Constraints
    client_body_buffer_size 128k;
    client_max_body_size 10M;
    client_header_buffer_size 1k;
    large_client_header_buffers 4 4k;

    # Gzip Compression Architecture
    gzip on;
    gzip_disable "msie6";
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types text/plain text/css application/json application/javascript text/xml application/xml application/xml+rss text/javascript;

    # Include modular configurations
    include /etc/nginx/conf.d/*.conf;
}
```

#### Upstream & Server Proxy Configuration: `/etc/nginx/conf.d/api_proxy.conf`
```nginx
# Upstream Application Cluster Definition
upstream backend_api_cluster {
    least_conn;
    server 10.0.1.11:8080 max_fails=3 fail_timeout=10s weight=5;
    server 10.0.1.12:8080 max_fails=3 fail_timeout=10s weight=5;
    server 10.0.1.13:8080 max_fails=3 fail_timeout=10s weight=2;
    
    # Keepalive connections pool to upstream backend servers
    keepalive 64;
}

server {
    listen 80;
    server_name api.infrastructure.internal;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl http2;
    server_name api.infrastructure.internal;

    # TLS Server Configuration
    ssl_certificate /etc/ssl/certs/api.infrastructure.internal.crt;
    ssl_certificate_key /etc/ssl/private/api.infrastructure.internal.key;
    ssl_trusted_certificate /etc/ssl/certs/ca_chain.crt;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:50m;
    ssl_session_tickets off;

    # OCSP Stapling
    ssl_stapling on;
    ssl_stapling_verify on;
    resolver 8.8.8.8 1.1.1.1 valid=300s;
    resolver_timeout 5s;

    # Root location serving static web content
    location /static/ {
        alias /var/www/api_static/;
        expires 30d;
        add_header Cache-Control "public, no-transform";
        access_log off;
    }

    # Proxy location routing to backend cluster
    location / {
        proxy_pass http://backend_api_cluster;
        proxy_http_version 1.1;

        # Header Transformations for Reverse Proxy Context
        proxy_set_header Connection "";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # Proxy Timeouts and Buffers
        proxy_connect_timeout 5s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;

        proxy_buffering on;
        proxy_buffer_size 8k;
        proxy_buffers 8 64k;
        proxy_busy_buffers_size 128k;

        # Error Handling Fallback
        proxy_next_upstream error timeout invalid_header http_502 http_503;
    }
}
```

---

### 3.3 Squid Enterprise Caching Proxy Configuration

#### Main System Configuration: `/etc/squid/squid.conf`
```squid
# Enterprise Squid Forward & Caching Proxy Configuration
# Listening Port Assignment
http_port 3128

# Network ACL Definitions
acl localnet src 10.0.0.0/8     # RFC 1918 Private Network
acl localnet src 172.16.0.0/12  # RFC 1918 Private Network
acl localnet src 192.168.0.0/16 # RFC 1918 Private Network
acl localnet src fc00::/7       # Unique Local IPv6
acl localnet src fe80::/10      # Link-Local IPv6

# Safe Ports ACLs
acl Safe_ports port 80          # http
acl Safe_ports port 21          # ftp
acl Safe_ports port 443         # https
acl Safe_ports port 70          # gopher
acl Safe_ports port 210         # wais
acl Safe_ports port 1025-65535  # unregistered ports
acl Safe_ports port 280         # http-mgmt
acl Safe_ports port 488         # gss-http
acl Safe_ports port 591         # filemaker
acl Safe_ports port 777         # multiling http

acl SSL_ports port 443
acl CONNECT method CONNECT

# Domain Blacklists & Custom ACLs
acl RestrictedDomains dstdomain .facebook.com .twitter.com .gambling.com
acl ManagementSubnet src 10.0.100.0/24

# Access Rules Evaluation Hierarchy
# Rule 1: Deny requests to unsafe ports
http_access deny !Safe_ports

# Rule 2: Deny CONNECT requests to non-SSL ports
http_access deny CONNECT !SSL_ports

# Rule 3: Enforce domain restrictions for standard users
http_access deny RestrictedDomains !ManagementSubnet

# Rule 4: Allow localhost manager access
http_access allow localhost manager
http_access deny manager

# Rule 5: Allow local network traffic
http_access allow localnet
http_access allow localhost

# Default Deny All Remaining Traffic
http_access deny all

# Memory and Storage Cache Architecture
cache_mem 2048 MB
maximum_object_size_in_memory 512 KB
maximum_object_size 100 MB
cache_dir ufs /var/spool/squid 10000 16 256

# Core Dump Directory
coredump_dir /var/spool/squid

# Refresh Patterns for Object Staleness Evaluation
refresh_pattern ^ftp:           1440    20%     10080
refresh_pattern ^gopher:        1440    0%      1440
refresh_pattern -i (/cgi-bin/|\?) 0     0%      0
refresh_pattern .               0       20%     4320

# Log Formatting & Privacy Anonymization
logformat custom_squid %tl %>a %ss/%03>Hs %<st %rm %ru %[un %Sh/%<a %mt
access_log daemon:/var/log/squid/access.log custom_squid
forwarded_for off
via off
```

---

## 4. Real CLI Executions & Expected Terminal Outputs

### 4.1 PKI Operations: OpenSSL Private Keys, CSR, and Self-Signed Certificates

#### Generate a 4096-bit RSA Private Key and CSR with Subject Alternative Names (SAN)
```bash
$ openssl req -new -newkey rsa:4096 -nodes \
    -keyout /etc/pki/tls/private/app.infrastructure.internal.key \
    -out /etc/pki/tls/certs/app.infrastructure.internal.csr \
    -subj "/C=US/ST=Virginia/L=Reston/O=Enterprise SRE/OU=Platform Engineering/CN=app.infrastructure.internal" \
    -addext "subjectAltName=DNS:app.infrastructure.internal,DNS:www.infrastructure.internal"
```
```text
Generating a RSA private key
................................................................................................+++++
.......................................................................................................................................+++++
writing new private key to '/etc/pki/tls/private/app.infrastructure.internal.key'
-----
```

#### Generate a Self-Signed ECC (Prime256v1) X.509 Certificate for Testing
```bash
$ openssl ecparam -name prime256v1 -genkey -out /etc/pki/tls/private/ecc_test.key
$ openssl req -new -x509 -key /etc/pki/tls/private/ecc_test.key \
    -out /etc/pki/tls/certs/ecc_test.crt -days 365 \
    -subj "/C=US/ST=Virginia/L=Reston/O=Lab/CN=test.infrastructure.internal"
```
```text
$ openssl x509 -in /etc/pki/tls/certs/ecc_test.crt -text -noout | head -n 15
Certificate:
    Data:
        Version: 3 (0x2)
        Serial Number:
            4b:a2:8f:99:cd:10:e3:11:89:ef:12:34:56:78:90:ab:cd:ef:01:23
        Signature Algorithm: ecdsa-with-SHA256
        Issuer: C = US, ST = Virginia, L = Reston, O = Lab, CN = test.infrastructure.internal
        Validity
            Not Before: Aug  6 14:00:00 2026 GMT
            Not After : Aug  6 14:00:00 2027 GMT
        Subject: C = US, ST = Virginia, L = Reston, O = Lab, CN = test.infrastructure.internal
        Subject Public Key Info:
            Public Key Algorithm: id-ecPublicKey
                Public-Key: (256 bit)
                pub:
                    04:a1:2b:3c:4d:5e:6f:7a:8b:9c:0d:1e:2f:3a:4b:
                    5c:6d:7e:8f:9a:0b:1c:2d:3e:4f:5a:6b:7c:8d:9e
```

---

### 4.2 Apache HTTPD Management & Operational Verification

#### Validate Apache Syntax and Dump Loaded Virtual Hosts
```bash
$ apachectl -t
```
```text
Syntax OK
```

```bash
$ apachectl -t -D DUMP_VHOSTS
```
```text
VirtualHost configuration:
*:80                   is a NameVirtualHost
         default server app.infrastructure.internal (/etc/httpd/conf.d/vhosts.conf:2)
         port 80 namevhost app.infrastructure.internal (/etc/httpd/conf.d/vhosts.conf:2)
                 alias www.infrastructure.internal
         port 80 namevhost admin.infrastructure.internal (/etc/httpd/conf.d/vhosts.conf:10)
*:443                  is a NameVirtualHost
         default server app.infrastructure.internal (/etc/httpd/conf.d/vhosts.conf:24)
         port 443 namevhost app.infrastructure.internal (/etc/httpd/conf.d/vhosts.conf:24)
```

#### Generate HTTP Basic Authentication File
```bash
$ htpasswd -c -B /etc/httpd/conf/.htpasswd sysadmin
```
```text
New password: 
Re-type new password: 
Adding password for user sysadmin
```

```bash
$ cat /etc/httpd/conf/.htpasswd
```
```text
sysadmin:$2y$05$vJdYhVzFw9X1.aBcD4eFg.oH91234567890abcdefghijklmnopqrst
```

#### Query Active Apache Modules
```bash
$ apachectl -M | grep -E 'mpm|ssl|proxy'
```
```text
 mpm_event_module (shared)
 ssl_module (shared)
 proxy_module (shared)
 proxy_http_module (shared)
```

---

### 4.3 NGINX Management & Reverse Proxy Verification

#### Verify NGINX Configuration Syntax
```bash
$ nginx -t
```
```text
nginx: the configuration file /etc/nginx/nginx.conf syntax is ok
nginx: configuration file /etc/nginx/nginx.conf test is successful
```

#### Inspect NGINX Active Socket Bindings and Worker Processes
```bash
$ ps aux | grep nginx
```
```text
root       10451  0.0  0.2  48120  4100 ?        Ss   14:15   0:00 nginx: master process /usr/sbin/nginx -c /etc/nginx/nginx.conf
nginx      10452  0.1  0.5  62400  9800 ?        S    14:15   0:02 nginx: worker process
nginx      10453  0.1  0.5  62400  9800 ?        S    14:15   0:02 nginx: worker process
```

```bash
$ ss -tlpn | grep nginx
```
```text
LISTEN 0      511          0.0.0.0:80        0.0.0.0:*    users:(("nginx",pid=10453,fd=6),("nginx",pid=10452,fd=6),("nginx",pid=10451,fd=6))
LISTEN 0      511          0.0.0.0:443       0.0.0.0:*    users:(("nginx",pid=10453,fd=7),("nginx",pid=10452,fd=7),("nginx",pid=10451,fd=7))
```

#### Test Ingress Reverse Proxy Connection with `curl`
```bash
$ curl -Iv -H "Host: api.infrastructure.internal" https://127.0.0.1/ --insecure
```
```text
*   Trying 127.0.0.1:443...
* Connected to 127.0.0.1 (127.0.0.1) port 443 (#0)
* ALPN: offers h2,http/1.1
* TLSv1.3 (OUT), TLS handshake, Client hello (1):
* TLSv1.3 (IN), TLS handshake, Server hello (2):
* TLSv1.3 (IN), TLS handshake, Encrypted Extensions (8):
* TLSv1.3 (IN), TLS handshake, Certificate (11):
* TLSv1.3 (IN), TLS handshake, CERT verify (15):
* TLSv1.3 (IN), TLS handshake, Finished (20):
* SSL connection using TLSv1.3 / TLS_AES_256_GCM_SHA384
* Server certificate:
*  subject: C=US; ST=Virginia; L=Reston; O=Enterprise SRE; CN=api.infrastructure.internal
*  start date: Aug  6 10:00:00 2026 GMT
*  expire date: Aug  6 10:00:00 2027 GMT
*  issuer: C=US; O=Internal CA; CN=Internal Root Agency
> HEAD / HTTP/1.1
> Host: api.infrastructure.internal
> User-Agent: curl/7.76.1
> Accept: */*
> 
< HTTP/1.1 200 OK
< Server: nginx
< Date: Thu, 06 Aug 2026 14:20:00 GMT
< Content-Type: application/json
< Content-Length: 42
< Connection: keep-alive
< X-Real-IP: 127.0.0.1
< 
```

---

### 4.4 Squid Operational Verification

#### Validate Squid Configuration File
```bash
$ squid -k parse
```
```text
2026/08/06 14:25:00| Startup: Initializing Authentication Schemes ...
2026/08/06 14:25:00| Processing Configuration File: /etc/squid/squid.conf (depth 0)
2026/08/06 14:25:00| Initializing https proxy context
2026/08/06 14:25:00| Processing ACL: acl localnet src 10.0.0.0/8
2026/08/06 14:25:00| Processing Access List: http_access allow localnet
...
2026/08/06 14:25:00| Configuration file check OK.
```

#### Test Forward Proxy Access via `curl`
```bash
$ curl -x http://127.0.0.1:3128 -I http://example.com/
```
```text
HTTP/1.1 200 OK
Accept-Ranges: bytes
Age: 324112
Cache-Control: max-age=604800
Content-Type: text/html; charset=UTF-8
Date: Thu, 06 Aug 2026 14:30:00 GMT
Etag: "3147326947"
Expires: Thu, 13 Aug 2026 14:30:00 GMT
Last-Modified: Thu, 17 Oct 2019 07:18:26 GMT
Server: ECS (dca/24B2)
X-Cache: HIT from local-proxy.infrastructure.internal
Via: 1.1 local-proxy.infrastructure.internal (squid/5.5)
Connection: keep-alive
```

---

## 5. Verification, Failure Modes & SRE Troubleshooting Runbook

```
                         [ Issue Resolution Workflow ]
                                       │
                ┌──────────────────────┴──────────────────────┐
                ▼                                             ▼
    [ Layer 4 Network / Socket ]                   [ Layer 7 Application ]
        - ss -tlpn / netstat                           - Log Parsing (awk/grep)
        - tcpdump packet analysis                      - Config Validation
        - strace syscall inspection                    - Upstream Health
```

### 5.1 Scenario 1: TLS Handshake Failure & SNI Mismatch

#### Symptom
Clients report `SSL_ERROR_UNRECOGNIZED_NAME_ALERT` or receive an incorrect fallback SSL certificate when attempting to open a TLS session to a virtual host.

#### Root Cause Analysis
1. The web server configuration lacks explicit `ServerName` matching for the requested SNI string.
2. The client application does not transmit the `server_name` extension in the TLS `Client Hello`.

#### Diagnostic Execution Strategy
Execute low-level OpenSSL handshake tracking specifying the SNI hostname explicitly:

```bash
$ openssl s_client -connect 10.0.10.50:443 -servername app.infrastructure.internal -tlsextdebug -showcerts
```
```text
CONNECTED(00000003)
TLS server extension "server_name" (id=0), len=0
depth=2 C = US, O = Internal Root Authority, CN = Internal Root CA
verify return:1
depth=1 C = US, O = Internal Issuing Authority, CN = Intermediate CA
verify return:1
depth=0 C = US, ST = Virginia, L = Reston, O = Enterprise SRE, CN = app.infrastructure.internal
verify return:1
---
Certificate chain
 0 s:C = US, ST = Virginia, L = Reston, O = Enterprise SRE, CN = app.infrastructure.internal
   i:C = US, O = Internal Issuing Authority, CN = Intermediate CA
-----BEGIN CERTIFICATE-----
MIIFzCCA9... (truncated certificate content)
-----END CERTIFICATE-----
```

#### Remediation Runbook
Ensure that SNI is enabled in Apache/NGINX and that the VirtualHost directive maps precisely to the requested domain in the TLS `subjectAltName` extension. In NGINX, ensure the default server fallback block is set:
```nginx
server {
    listen 443 ssl default_server;
    server_name _;
    ssl_reject_handshake on; # NGINX 1.19.4+ drops unauthorized SNI handshakes
}
```

---

### 5.2 Scenario 2: Apache HTTPD Worker Starvation (`HTTP 503` / Connection Rejection)

#### Symptom
Application performance degrades severely under high burst traffic; client requests fail with `503 Service Unavailable`, and error logs record `[mpm_event:error] [pid 1234] AH00484: server reached MaxRequestWorkers setting`.

#### Diagnostic Command Sequence

1. Inspect active worker thread state via `apachectl status`:
```bash
$ apachectl status
```
```text
Apache Server Status for localhost (via 127.0.0.1)

Server Version: Apache/2.4.57 (Red Hat Enterprise Linux)
Server MPM: event
Current Time: Thursday, 06-Aug-2026 14:35:00 EDT
Restart Time: Thursday, 06-Aug-2026 10:00:00 EDT
Parent Server Config. Generation: 1
Total accesses: 1450200 - Total Traffic: 4.2 GB
CPU Usage: u75.2 s12.4 cu0 cs0 - .583% CPU load
11.2 requests/sec - 33.2 kB/second - 2.9 kB/request
2048 requests currently being processed, 0 idle workers

WWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWW
WWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWW
Scoreboard Key:
 "_" Waiting for Connection, "S" Starting up, "R" Reading Request,
 "W" Sending Reply, "K" Keepalive (read), "D" DNS Lookup,
 "C" Closing connection, "L" Logging, "G" Gracefully finishing,
 "I" Idle cleanup of worker, "." Open slot with no current process
```

2. Trace active worker process system calls to check for I/O blocking:
```bash
$ strace -f -p $(pgrep -f "httpd" | head -n 1) -e trace=network,accept4,epoll_wait
```
```text
[pid 10512] epoll_wait(4, [{EPOLLIN, {u32=12, u64=12}}], 32, -1) = 1
[pid 10512] accept4(8, {sa_family=AF_INET, sin_port=htons(42100), sin_addr=inet_addr("10.0.50.21")}, [16], SOCK_CLOEXEC|SOCK_NONBLOCK) = 9
```

#### Remediation Runbook
1. Adjust the `MaxRequestWorkers` parameter in `/etc/httpd/conf/httpd.conf` ensuring system memory capacity supports the calculation:
   $$\text{MaxMemoryRequired} = \text{ParentProcess} + (\text{MaxRequestWorkers} \times \text{MemoryPerThread})$$
2. Reduce `KeepAliveTimeout` from 15s to 2s to recycle listener threads faster.

---

### 5.3 Scenario 3: NGINX `502 Bad Gateway` / Upstream Socket Connection Refusal

#### Symptom
NGINX returns `HTTP 502 Bad Gateway` to incoming HTTP clients when serving dynamic content.

#### Log Inspection Phase
Query NGINX error logs directly for upstream network failure signatures:

```bash
$ tail -n 5 /var/log/nginx/error.log
```
```text
2026/08/06 14:40:12 [error] 10452#10452: *4512 connect() failed (111: Connection refused) while connecting to upstream, client: 10.0.50.99, server: api.infrastructure.internal, request: "GET /api/v1/resource HTTP/1.1", upstream: "http://10.0.1.11:8080/api/v1/resource", host: "api.infrastructure.internal"
```

#### Socket Verification & Packet Tracing
1. Verify connectivity from NGINX host to upstream backend IP and Port:
```bash
$ nc -zvw3 10.0.1.11 8080
```
```text
nc: connect to 10.0.1.11 port 8080 (tcp) failed: Connection refused
```

2. Capture network frames using `tcpdump` to verify TCP RST flags sent by upstream:
```bash
$ tcpdump -i any host 10.0.1.11 and port 8080 -nn -vvv
```
```text
14:41:00.123456 IP (tos 0x0, ttl 64, id 54321, offset 0, flags [DF], proto TCP (6), length 60)
    10.0.1.2.45100 > 10.0.1.11.8080: Flags [S], cksum 0x1a2b (correct), seq 1000000, win 64240, options [mss 1460,sackOK,TS val 1234567 ecr 0,nop,wscale 7], length 0
14:41:00.123890 IP (tos 0x0, ttl 64, id 0, offset 0, flags [DF], proto TCP (6), length 40)
    10.0.1.11.8080 > 10.0.1.2.45100: Flags [R.], cksum 0x3c4d (correct), seq 0, ack 1000001, win 0, length 0
```

#### Remediation Runbook
1. Check process status on upstream node `10.0.1.11` (`systemctl status backend_app`).
2. Verify SELinux boolean permissions on the NGINX host allowing HTTP network connection proxies:
```bash
$ getsebool httpd_can_network_connect
```
```text
httpd_can_network_connect --> off
```
```bash
$ setsebool -P httpd_can_network_connect on
```

---

### 5.4 Scenario 4: Squid Proxy `403 Forbidden` & Cache Performance Troubleshooting

#### Symptom
Clients routed through the Squid Forward Proxy receive standard `HTTP 403 Forbidden` response pages when requesting allowed web domains.

#### Access Log Parsing with `awk`
Analyze Squid log entries to examine access control decisions and cache hit rates:

```bash
$ tail -n 1000 /var/log/squid/access.log | awk '{print $4, $5, $6, $7}' | sort | uniq -c | sort -nr | head -n 10
```
```text
    450 TCP_DENIED/403 1450 GET http://example.com/
    320 TCP_MEM_HIT/200 4510 GET http://static.infrastructure.internal/asset.js
    150 TCP_MISS/200 12400 POST http://api.external.com/v1/submit
```

#### Diagnostic Execution Strategy
Run Squid in debug mode for ACL evaluation tracking:

```bash
$ squid -k reconfigure
$ tail -f /var/log/squid/cache.log | grep -E 'ACL|access'
```
```text
2026/08/06 14:45:00.102 kit| 28,3| aclCheckFast: list 'http_access'
2026/08/06 14:45:00.102 kit| 28,3| aclMatchAcl: checking 'localnet'
2026/08/06 14:45:00.102 kit| 28,3| aclMatchAcl: matched 'localnet'
2026/08/06 14:45:00.103 kit| 28,3| aclMatchAcl: checking 'RestrictedDomains'
2026/08/06 14:45:00.103 kit| 28,3| aclMatchAcl: matched 'RestrictedDomains'
2026/08/06 14:45:00.103 kit| 28,3| match: deny RestrictedDomains !ManagementSubnet -> MATCHED (DENIED)
```

#### Remediation Runbook
Squid evaluates `http_access` rules sequentially from top to bottom. Order of rules is paramount. Ensure restrictive ACLs (such as `RestrictedDomains`) exclude permitted subnets prior to global deny rules, or reorder the declarations in `/etc/squid/squid.conf`.

---

## 6. References

* **Linux Professional Institute (LPI) LPIC-2 Objectives**:  
  https://www.lpi.org/our-certifications/lpic-2-overview/  
  https://wiki.lpi.org/wiki/LPIC-2_Objectives_V4.5

* **Apache HTTPD Official Documentation & Architecture Guides**:  
  https://httpd.apache.org/docs/2.4/  
  https://httpd.apache.org/docs/2.4/mpm.html  
  https://httpd.apache.org/docs/2.4/ssl/  
  https://httpd.apache.org/docs/2.4/mod/mod_proxy.html

* **NGINX Core Architecture & Reverse Proxy Documentation**:  
  https://nginx.org/en/docs/  
  https://nginx.org/en/docs/http/ngx_http_proxy_module.html  
  https://nginx.org/en/docs/http/ngx_http_upstream_module.html  
  https://www.nginx.com/resources/wiki/start/topics/tutorials/config_pitfalls/

* **Squid Configuration Manuals & ACL Specifications**:  
  http://www.squid-cache.org/Doc/config/  
  http://www.squid-cache.org/Doc/config/http_access/

* **OpenSSL Cryptographic Toolkit Reference**:  
  https://www.openssl.org/docs/man3.0/man1/