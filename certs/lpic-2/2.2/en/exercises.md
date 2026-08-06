# LPIC-2 (Exam 202-450, v4.5) — Topic 208: Web Services (Weight: 8)
**Advanced Production Architecture, Configuration, Performance Tuning, and Diagnostics Guide**

---

## Official Reference Documentation
- **LPI Exam Objectives**: [LPIC-2 202-450 Exam Objectives](https://www.lpi.org/our-certifications/lpic-2-overview/)
- **Apache HTTP Server Documentation**: [Apache HTTPD 2.4 Documentation](https://httpd.apache.org/docs/2.4/)
- **NGINX Core Architecture & Modules**: [NGINX Reference Documentation](https://nginx.org/en/docs/)

---

## Module 1: Apache HTTPD Internal Mechanics & Advanced Configuration

### 1.1 Multi-Processing Modules (MPM): Deep Architectural Comparison

Apache HTTPD abstracts request-handling concurrency through Multi-Processing Modules (MPMs). Choosing the correct MPM determines how the operating system manages process memory, context switching, file descriptors, and worker threads under heavy network traffic.

```
       +-----------------------------------------------------------------------+
       |                           APACHE HTTPD PARENT                         |
       |                             (Root Process)                            |
       +-----------------------------------------------------------------------+
           |                                |                              |
           v                                v                              v
+-----------------------+        +---------------------+        +---------------------+
|      MPM PREFORK      |        |     MPM WORKER      |        |      MPM EVENT      |
| Single Thread/Process |        | Multi-Threaded/Proc |        | Async Listener Event|
+-----------------------+        +---------------------+        +---------------------+
| Child Proc 1 (Worker) |        | Child Proc 1        |        | Child Proc 1        |
| Child Proc 2 (Worker) |        |  |- Thread 1        |        |  |- Listener (epoll)|
| Child Proc N (Worker) |        |  |- Thread 2        |        |  |- Worker Thread 1 |
|                       |        |  |- Thread N        |        |  |- Worker Thread N |
|  * High Memory Footpr |        |  * Shared Memory    |        |  * Dedicated Async  |
|  * Non-thread-safe PHP|        |  * Thread contention|        |    Keep-Alive Pool  |
+-----------------------+        +---------------------+        +---------------------+
```

#### 1. MPM Prefork (`mod_mpm_prefork`)
- **Execution Model**: Non-threaded, process-based architecture. A single parent process manages a pool of single-threaded child worker processes. Each child handles exactly one request at a time.
- **Memory Profile**: High memory footprint. Process isolation guarantees memory safety, preventing thread-safety issues with non-thread-safe modules (e.g., legacy `mod_php`).
- **I/O Behavior**: Blocking synchronous I/O. If a client initiates a long Keep-Alive connection, the dedicated worker process remains locked and unavailable to serve incoming HTTP requests.

#### 2. MPM Worker (`mod_mpm_worker`)
- **Execution Model**: Hybrid multi-process, multi-threaded architecture. The parent process spawns a fixed number of child processes. Each child process spawns a fixed number of worker threads and a single listener thread.
- **Memory Profile**: Low memory usage relative to Prefork. Shared memory address space across threads within the same process.
- **I/O Behavior**: Synchronous multi-threaded I/O. A thread remains tied to an active connection for the duration of the HTTP transaction, including Keep-Alive wait states.

#### 3. MPM Event (`mod_mpm_event`)
- **Execution Model**: Asynchronous, event-driven multi-process multi-threaded architecture based on OS event notifications (`epoll` on Linux, `kqueue` on BSD).
- **Internal Mechanism**: A dedicated **Listener Thread** per child process listens on the socket. When an HTTP request header arrives, the listener hands off the connection to an available **Worker Thread**. 
- **Keep-Alive Offloading**: Once the HTTP response is sent, if Keep-Alive is active, the worker thread does **not** block. The socket descriptor is passed back to a central `epoll` interest list managed by the listener thread. When new bytes arrive on the idle Keep-Alive socket, the listener re-assigns it to a worker thread. This allows MPM Event to sustain tens of thousands of concurrent Keep-Alive clients using minimal worker threads.

---

### 1.2 Context Directory Resolution & Access Control (`mod_authz_core`)

Apache processes configuration directives according to a strict hierarchical evaluation order, regardless of their appearance in `httpd.conf`:

1. `<Directory>` (processed from shortest path to longest path)
2. `<DirectoryMatch>` (and regex `~`)
3. `<Files>` and `<FilesMatch>` (evaluated concurrently with Directory blocks)
4. `<Location>` and `<LocationMatch>` (evaluated strictly **after** filesystem path resolution)

> **Architectural Rule**: Use `<Directory>` for filesystem resources and `<Location>` strictly for non-filesystem URI locations (e.g., `mod_status` endpoints or proxied routes). Applying access controls to `<Location>` for local files can allow authorization bypasses via symlinks or canonical path traversal.

#### Production Configuration: Complete `/etc/httpd/conf.d/vhost_production.conf`

```apache
# /etc/httpd/conf.d/vhost_production.conf
# Syntactically Valid Apache 2.4 Advanced Production Configuration

<VirtualHost *:80>
    ServerName app.enterprise.internal
    ServerAlias www.app.enterprise.internal
    DocumentRoot "/var/www/html/app"
    ServerAdmin sysadmin@enterprise.internal

    # Global Defensive Base Directive
    <Directory "/">
        AllowOverride None
        Require all denied
    </Directory>

    # Application Root Context
    <Directory "/var/www/html/app">
        Options -Indexes +FollowSymLinks
        AllowOverride AuthConfig Options=ExecCGI,Indexes
        Require all granted
    </Directory>

    # Restricted Administrative Filesystem Area
    <Directory "/var/www/html/app/admin">
        Options -Indexes
        AllowOverride None
        
        AuthType Basic
        AuthName "Restricted Internal Platform Administration"
        AuthUserFile "/etc/httpd/security/.htpasswd"
        
        <RequireAll>
            Require valid-user
            Require ip 10.50.0.0/16 192.168.1.0/24
            Require not ip 10.50.99.100
        </RequireAll>
    </Directory>

    # Protect Hidden Dotfiles (e.g., .git, .env)
    <FilesMatch "^\.(?!well-known)">
        Require all denied
    </FilesMatch>

    # Custom Log Formats with Performance Microsecond Timing (%D)
    LogFormat "%h %l %u %t \"%r\" %>s %b \"%{Referer}i\" \"%{User-Agent}i\" %D" combined_performance
    CustomLog "/var/log/httpd/app_access.log" combined_performance
    ErrorLog "/var/log/httpd/app_error.log"
    LogLevel warn
</VirtualHost>
```

---

## Module 2: Apache HTTPD Tuning, Resource Math & Observability

### 2.1 Sizing Math for `mod_mpm_event` Under High Concurrency

To calculate maximum concurrent client capacity and prevent Out-Of-Memory (OOM) kernel panics, system administrators must align thread limits with available system RAM.

#### Configuration Parameters
- `ServerLimit`: Maximum limit on the number of active child processes.
- `ThreadsPerChild`: Exact number of worker threads created by each child process.
- `MaxRequestWorkers`: Total maximum number of worker threads serving requests concurrently (`ServerLimit` × `ThreadsPerChild`).
- `AsyncRequestWorkerFactor`: Multiplier determining maximum idle Keep-Alive connections allowed per worker thread (Default: `2`).

#### Mathematical Derivation Formula:
$$\text{Max Processes} = \left\lfloor \frac{\text{Total RAM} - \text{OS/Buffer Reserve}}{\text{Average Child Process RSS Memory}} \right\rfloor$$

$$\text{MaxRequestWorkers} = \text{Max Processes} \times \text{ThreadsPerChild}$$

#### Enterprise Sizing Example:
- Total Server RAM: **16 GB**
- Reserved for OS/Monitoring/Buffers: **4 GB**
- Available RAM for Apache: **12 GB** (12,288 MB)
- Average Memory per `mod_mpm_event` Child Process (RSS): **60 MB**
- `ThreadsPerChild` Target: **64**

$$\text{Max Processes} = \left\lfloor \frac{12288 \text{ MB}}{60 \text{ MB}} \right\rfloor = 204 \text{ processes}$$

$$\text{MaxRequestWorkers} = 204 \times 64 = 13,056 \text{ threads}$$

#### Syntactically Valid Directive Block (`/etc/httpd/conf.modules.d/00-mpm.conf`):

```apache
# /etc/httpd/conf.modules.d/00-mpm.conf
LoadModule mpm_event_module modules/mod_mpm_event.so

<IfModule mpm_event_module>
    ServerLimit              25
    StartServers              5
    MinSpareThreads          128
    MaxSpareThreads          512
    ThreadsPerChild           64
    ThreadLimit               64
    MaxRequestWorkers       1600
    MaxConnectionsPerChild  10000
    AsyncRequestWorkerFactor   2
</IfModule>
```

---

### 2.2 Deep Diagnostics & Live Status Profiling via CLI

To inspect server status without a GUI, configure `mod_status` with `ExtendedStatus On`.

#### Server Status Directive (`/etc/httpd/conf.d/status.conf`):

```apache
<Location "/server-status">
    SetHandler server-status
    Require ip 127.0.0.1 10.50.0.0/16
</Location>
ExtendedStatus On
```

#### Real-Time Command Execution and Expected Machine Output:

Execute a non-interactive fetch of server metrics using `curl`:

```bash
curl -s http://127.0.0.1/server-status?auto
```

**Expected Command Output:**
```text
Total Accesses: 450921
Total kBytes: 1849201
Uptime: 86400
CPULoad: .425
ReqPerSec: 5.21899
BytesPerSec: 21915.2
BytesPerReq: 4200.73
BusyWorkers: 14
IdleWorkers: 114
ConnsTotal: 48
ConnsAsyncWriting: 2
ConnsAsyncKeepAlive: 32
ConnsAsyncClosing: 2
Scoreboard: ____________W___W__W________W_W____W___W_W_W_W_____W_W________________________________________________________________________________________________________________________________________________________________________________________________
```

#### Scoreboard Key Interpretation:
- `_`: Waiting for connection
- `S`: Starting up
- `R`: Reading Request
- `W`: Sending Reply (Busy Worker)
- `K`: Keepalive (read)
- `D`: DNS Lookup
- `C`: Closing connection
- `L`: Logging
- `G`: Gracefully finishing
- `I`: Idle cleanup of worker

---

## Module 3: NGINX Architecture & High-Performance Reverse Proxy

### 3.1 NGINX Event Loop Architecture vs Process Model

NGINX relies on an asynchronous, non-blocking, event-driven architecture designed to eliminate thread context-switching overhead.

```
+-----------------------------------------------------------------------+
|                             NGINX MASTER                              |
|                         (Reads Conf, Binds Ports)                     |
+-----------------------------------------------------------------------+
     |                                                             |
     v                                                             v
+------------------------------------+           +------------------------------------+
|           WORKER PROCESS 1         |           |           WORKER PROCESS 2         |
|  +------------------------------+  |           |  +------------------------------+  |
|  |       Non-Blocking I/O       |  |           |  |       Non-Blocking I/O       |  |
|  |     Event Loop (epoll)       |  |           |  |     Event Loop (epoll)       |  |
|  +------------------------------+  |           |  +------------------------------+  |
|    |           |           |       |           |    |           |           |       |
|    v           v           v       |           |    v           v           v       |
|  Socket 1   Socket 2   Socket N    |           |  Socket 1   Socket 2   Socket N    |
+------------------------------------+           +------------------------------------+
```

1. **Master Process**: Operates under `root` privileges. Performs privileged tasks: reads configuration, validates syntax, binds to network sockets (`:80`, `:443`), and spawns worker processes.
2. **Worker Processes**: Unprivileged processes running under `nginx` or `www-data`. Each worker executes a continuous non-blocking event loop leveraging system calls like `epoll_wait()`. A single worker process can handle thousands of simultaneous connections without spawning additional threads.
3. **File Descriptor Limits**: Each TCP connection requires a dedicated file descriptor socket. The maximum theoretical connection count per worker is bounded by `worker_connections` and system `ulimit -n` (`worker_rlimit_nofile`).

$$\text{Max Client Connections} = \text{worker\_processes} \times \text{worker\_connections}$$
*(Divided by 2 when acting as a Reverse Proxy due to backend connection overhead).*

---

### 3.2 NGINX Location Matching Algorithm Engine

NGINX evaluates `location` directives using a explicit priority hierarchy. It does **not** simply execute top-to-bottom.

#### Resolution Priority Hierarchy:
1. **Exact String Match**: `location = /path` (Immediate termination on match)
2. **Preferential Prefix Match**: `location ^~ /path` (If matched, stops regex scanning)
3. **Regular Expression Match**: `location ~ pattern` (Case-sensitive) or `location ~* pattern` (Case-insensitive) — evaluated in sequential file order.
4. **Standard Prefix Match**: `location /path` (Longest prefix match selected if no regex matches).

#### Matching Truth Table & Execution Logic:

| Modifier | Match Type | Priority | Stops Scanning on Match? |
| :--- | :--- | :--- | :--- |
| `=` | Exact Match | 1 (Highest) | **Yes** |
| `^~` | Preferential Prefix Match | 2 | **Yes** |
| `~` | Case-Sensitive Regex | 3 | **Yes** (First matching regex wins) |
| `~*` | Case-Insensitive Regex | 3 | **Yes** (First matching regex wins) |
| *(None)* | Generic Prefix Match | 4 (Lowest) | **No** (Remembers longest match, tests regexes) |

---

### 3.3 Production NGINX Reverse Proxy Configuration

#### Complete `/etc/nginx/nginx.conf`:

```nginx
# /etc/nginx/nginx.conf
# Complete Syntactically Valid Production Configuration

user nginx;
worker_processes auto;
worker_rlimit_nofile 65535;
error_log /var/log/nginx/error.log warn;
pid /run/nginx.pid;

events {
    worker_connections 8192;
    use epoll;
    multi_accept on;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    log_format enterprise_json escape=json
      '{"time_local":"$time_local",'
      '"remote_addr":"$remote_addr",'
      '"request":"$request",'
      '"status": "$status",'
      '"body_bytes_sent":"$body_bytes_sent",'
      '"request_time":"$request_time",'
      '"upstream_response_time":"$upstream_response_time",'
      '"upstream_addr":"$upstream_addr",'
      '"http_x_forwarded_for":"$http_x_forwarded_for"}';

    access_log /var/log/nginx/access.log enterprise_json;

    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;

    # Upstream Backend Pool definition with Keep-Alive connection pooling
    upstream backend_nodes {
        least_conn;
        server 10.100.1.10:8080 max_fails=3 fail_timeout=10s weight=5;
        server 10.100.1.11:8080 max_fails=3 fail_timeout=10s weight=5;
        server 10.100.1.12:8080 backup;

        # Keepalive connection pool to upstream nodes
        keepalive 32;
    }

    server {
        listen 80;
        server_name api.enterprise.internal;
        return 301 https://$host$request_uri;
    }

    server {
        listen 443 ssl http2;
        server_name api.enterprise.internal;

        ssl_certificate /etc/pki/tls/certs/api_combined.crt;
        ssl_certificate_key /etc/pki/tls/private/api.key;
        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
        ssl_prefer_server_ciphers off;
        ssl_session_cache shared:SSL:10m;
        ssl_session_timeout 1d;

        # Static Asset Caching Context
        location ^~ /static/ {
            root /var/www/html/assets;
            expires 30d;
            add_header Cache-Control "public, no-transform";
            access_log off;
        }

        # Dynamic Application Proxy Context
        location / {
            proxy_pass http://backend_nodes;
            proxy_http_version 1.1;
            
            # Connection reuse headers for HTTP/1.1 upstream keepalive
            proxy_set_header Connection "";
            
            # Client identification headers
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;

            # Advanced Buffer Tuning for High Throughput
            proxy_buffering on;
            proxy_buffer_size 8k;
            proxy_buffers 64 8k;
            proxy_busy_buffers_size 16k;

            # Timeouts
            proxy_connect_timeout 5s;
            proxy_read_timeout 60s;
            proxy_send_timeout 60s;
        }
    }
}
```

---

## Module 4: Guided Hands-On Lab Exercises

### Exercise 1: Apache MPM Event Optimization & Live Tuning

#### Objective
Configure Apache HTTPD 2.4 to use `mod_mpm_event`, apply resource-calculated limits, verify syntactical validity, and validate thread operations using native Linux diagnostic tools.

#### Guided Steps

1. Verify that `mod_mpm_event` is currently loaded by inspecting the active Apache modules:
   ```bash
   httpd -M | grep mpm
   # Or on Debian/Ubuntu systems:
   apache2ctl -M | grep mpm
   ```
   *Expected Output:*
   ```text
   mpm_event_module (shared)
   ```

2. Open `/etc/httpd/conf.modules.d/00-mpm.conf` (or `/etc/apache2/mods-available/mpm_event.conf`) in an editor and configure the parameters matching a target server with 8GB RAM:
   ```apache
   <IfModule mpm_event_module>
       StartServers             3
       MinSpareThreads         64
       MaxSpareThreads        256
       ThreadLimit             64
       ThreadsPerChild         64
       MaxRequestWorkers     1024
       MaxConnectionsPerChild 5000
   </IfModule>
   ```

3. Perform a syntax check before reloading the system daemon:
   ```bash
   apachectl configtest
   ```
   *Expected Output:*
   ```text
   Syntax OK
   ```

4. Reload the systemd service to apply structural changes without dropping active sockets:
   ```bash
   systemctl reload httpd
   ```

5. Run `ss` to inspect the TCP socket listen queue backlog state for Apache:
   ```bash
   ss -tlpn '( sport = :80 || sport = :443 )'
   ```
   *Expected Output:*
   ```text
   State      Recv-Q Send-Q Local Address:Port  Peer Address:Port Process
   LISTEN     0      511    *:80                *:*               users:(("httpd",pid=10234,fd=3),("httpd",pid=10235,fd=3))
   ```

---

#### Verification Questions — Exercise 1
1. **Q1**: What happens if `MaxRequestWorkers` is configured to `1024` but `ServerLimit` is kept at its default value of `16` with `ThreadsPerChild` set to `32`? 
2. **Q2**: Why does `mpm_event` outperform `mpm_worker` when handling thousands of long-lived Keep-Alive HTTP client requests?

---

### Exercise 2: NGINX Reverse Proxy & SSL/TLS Offloading Implementation

#### Objective
Deploy an NGINX reverse proxy with an upstream load balancing group, configure SSL/TLS terminating parameters, and verify proxy header propagation.

#### Guided Steps

1. Test the syntax of your NGINX configuration file:
   ```bash
   nginx -t
   ```
   *Expected Output:*
   ```text
   nginx: the configuration file /etc/nginx/nginx.conf syntax is ok
   nginx: configuration file /etc/nginx/nginx.conf test is successful
   ```

2. Execute a detailed dump of the fully compiled NGINX configuration to verify loaded includes:
   ```bash
   nginx -T | grep -E "(server_name|proxy_pass|upstream)"
   ```
   *Expected Output:*
   ```text
   upstream backend_nodes {
   server_name api.enterprise.internal;
   proxy_pass http://backend_nodes;
   ```

3. Issue a verbose `curl` HTTP/2 request to verify TLS handshake negotiation and custom security response headers:
   ```bash
   curl -ivk --resolve api.enterprise.internal:443:127.0.0.1 https://api.enterprise.internal/
   ```
   *Expected Output Snippet:*
   ```text
   * ALPN, offering h2
   * ALPN, offering http/1.1
   * SSL connection using TLSv1.3 / TLS_AES_256_GCM_SHA384
   * Server certificate:
   *  subject: C=US; O=Enterprise; CN=api.enterprise.internal
   > GET / HTTP/2
   > Host: api.enterprise.internal
   > user-agent: curl/7.76.1
   > accept: */*
   > 
   < HTTP/2 200 
   < server: nginx
   < date: Thu, 06 Aug 2026 10:29:24 GMT
   < content-type: text/html
   ```

4. Monitor the NGINX structured log output in real time using `tail` to observe upstream routing:
   ```bash
   tail -f /var/log/nginx/access.log
   ```

---

#### Verification Questions — Exercise 2
1. **Q1**: In an NGINX `upstream` block, why is the `proxy_set_header Connection "";` directive explicitly required when combined with the `keepalive` directive?
2. **Q2**: Given the following location blocks:
   - `location /docs { ... }`
   - `location ~* ^/docs/.*\.html$ { ... }`
   - `location ^~ /docs/api { ... }`
   
   Which block will handle a request for `/docs/api/index.html`? Explain the evaluation flow.

---

### Exercise 3: Advanced Diagnostics & Troubleshooting Bottlenecks

#### Objective
Diagnose resource contention, HTTP 502 Bad Gateway errors, and file descriptor limits using system tracing and network state commands.

#### Guided Steps

1. Simulate an exhausted process file descriptor limit by reviewing system and process limits:
   ```bash
   cat /proc/$(cat /run/nginx.pid)/limits | grep "Max open files"
   ```
   *Expected Output:*
   ```text
   Max open files            65535                65535                files     
   ```

2. Trace active system calls executed by an Apache child process under load using `strace`:
   ```bash
   strace -fp $(pgrep -f "httpd" | head -n 1) -e trace=accept4,epoll_wait,read,write
   ```
   *Expected Output:*
   ```text
   [pid 10236] epoll_wait(6, [{EPOLLIN, {u32=1, u64=1}}], 32, -1) = 1
   [pid 10236] accept4(3, {sa_family=AF_INET, sin_port=htons(49152), sin_addr=inet_addr("10.50.1.15")}, [16], SOCK_CLOEXEC|SOCK_NONBLOCK) = 4
   [pid 10236] read(4, "GET /index.html HTTP/1.1\r\nHost: "..., 8000) = 158
   [pid 10236] write(4, "HTTP/1.1 200 OK\r\nDate: Thu, 06 A"..., 342) = 342
   ```

3. Trace socket connections established to backends to debug NGINX `502 Bad Gateway` errors:
   ```bash
   ss -t unresolved
   # Check state of upstream ports:
   ss -ta | grep -E "(8080|80|443)"
   ```
   *Expected Output:*
   ```text
   ESTAB      0      0      10.0.0.1:45322    10.100.1.10:8080
   SYN-SENT   0      1      10.0.0.1:45324    10.100.1.11:8080
   ```

---

#### Verification Questions — Exercise 3
1. **Q1**: If NGINX writes `1024 worker_connections are not enough` to `/var/log/nginx/error.log`, which two separate configuration levels must be scaled to resolve the bottleneck?
2. **Q2**: What does an `HTTP 504 Gateway Timeout` indicate in an NGINX reverse proxy setup, as opposed to an `HTTP 502 Bad Gateway` error?

---

## Exercise Solutions & Technical Explanations

<details>
<summary>Click to Expand Exercise Solutions and Explanations</summary>

### Solutions for Exercise 1

- **A1**: Apache will automatically limit `MaxRequestWorkers` to `512` (`ServerLimit` × `ThreadsPerChild` = 16 × 32). Apache will output a configuration warning on startup stating that `MaxRequestWorkers` exceeds `ServerLimit` × `ThreadsPerChild` and will lower `MaxRequestWorkers` to match the structural capacity boundary. To achieve 1024 workers with 32 threads per child, `ServerLimit` must be explicitly raised to `32`.
- **A2**: In `mpm_worker`, every active connection (including idle Keep-Alive clients) consumes a full worker thread for the duration of the timeout. In `mpm_event`, idle Keep-Alive sockets are transferred back to a central non-blocking `epoll` listener thread context. Worker threads are immediately released back to the global worker pool to serve active incoming requests.

---

### Solutions for Exercise 2

- **A1**: NGINX defaults to using HTTP/1.0 for upstream proxying, which includes a implicit `Connection: close` header in requests sent to backend servers. The `proxy_set_header Connection "";` directive strips the `close` instruction, allowing long-lived HTTP/1.1 TCP connections to remain open and be pooled inside the specified `upstream` `keepalive` queue.
- **A2**: The request `/docs/api/index.html` will be handled by `location ^~ /docs/api`. 
  - *Evaluation Flow*: 
    1. NGINX tests prefix locations first. `/docs` matches, but `/docs/api` is a longer prefix match.
    2. Because `/docs/api` utilizes the preferential prefix modifier (`^~`), NGINX immediately terminates further location matching and skips testing regular expressions (`location ~* ^/docs/.*\.html$`). 
    3. The request is routed to `location ^~ /docs/api`.

---

### Solutions for Exercise 3

- **A1**: 
  1. **NGINX Directive Level**: Increase `worker_connections` inside the `events {}` configuration block in `/etc/nginx/nginx.conf`.
  2. **Operating System File Descriptor Level**: Increase OS max open files limits by setting `worker_rlimit_nofile` in `/etc/nginx/nginx.conf` and updating the system security limits (`/etc/security/limits.conf` or systemd service unit `LimitNOFILE=65535`).
- **A2**: 
  - **HTTP 502 Bad Gateway**: Indicates that NGINX was able to connect to the upstream server, but the upstream server actively refused the connection, closed the TCP socket prematurely, or returned an invalid/corrupted HTTP response payload.
  - **HTTP 504 Gateway Timeout**: Indicates that NGINX successfully established a TCP connection to the upstream backend, but the upstream failed to send an HTTP response payload within the configured time boundary (`proxy_read_timeout`).

</details>