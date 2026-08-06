# LPI-030-100: Web Development Essentials (v1.0)
## Topic 1.3: HTTP Basics (Weight: 7.5) — Advanced SRE & Platform Architecture Guide

---

### 1. Production Motivation and Architectural Problem Statement

The Hypertext Transfer Protocol (HTTP) is the application-layer foundation of the modern distributed web. Architecturally, HTTP is designed as a **stateless request-response protocol** operating over modern transport layers (TCP/IP and UDP/QUIC). 

In enterprise production environments, modern Site Reliability Engineering (SRE) and Platform Architecture are defined by how HTTP is mediated, scaled, secured, and optimized across microservices, edge proxies, and Content Delivery Networks (CDNs).

```
+-----------------------------------------------------------------------------------+
|                                  CLIENT LAYER                                     |
|                      (Browsers, Mobile Apps, Microservices)                       |
+-----------------------------------------------------------------------------------+
                                         |
                                         | HTTP/2 or HTTP/3 over TLS 1.3
                                         v
+-----------------------------------------------------------------------------------+
|                                EDGE / INGRESS LAYER                               |
|       (Cloudflare / NGINX / Envoy / Kubernetes Ingress Controller)                |
|                                                                                   |
|  - TLS Termination & ALPN Negotiation                                             |
|  - CORS Enforcement & Security Headers                                            |
|  - Cache Invalidation & Edge Revalidation (ETag, Cache-Control)                   |
|  - Connection Pooling & HTTP Keep-Alive Translation                               |
+-----------------------------------------------------------------------------------+
                                         |
                                         | HTTP/1.1 Pool (gRPC / HTTP/2 optional)
                                         v
+-----------------------------------------------------------------------------------+
|                               BACKEND SERVICES                                    |
|                      (Stateless Microservice Pods)                                |
|                                                                                   |
|  - Dynamic Rendering / REST / GraphQL APIs                                        |
|  - Session Token Validation (JWT / Redis Cookie Sessions)                         |
+-----------------------------------------------------------------------------------+
```

#### 1.1 The Stateless Paradigm vs. Stateful Application Needs
HTTP is intentionally stateless: each request-response transaction is treated in isolation. However, real-world workloads (e.g., user authentication, shopping carts, transactional processing) require persistent context. 

To bridge this architectural gap without introducing stateful coupling at the server tier, systems rely on externalized state patterns:
* **Client-Side Cookie Propagation:** Standardized via RFC 6265, servers pass set-cookie directives instructing clients to send opaque session identifiers or self-contained claims back with subsequent requests.
* **Distributed Session Stores:** Microservices query centralized, highly available key-value stores (e.g., Redis Cluster) using session tokens to resolve state without violating microservice horizontal elasticity.

#### 1.2 Transport Layer Mechanics: TCP Connection Lifecycle and Keep-Alive Overhead
At the network tier, initiating an unoptimized HTTP/1.0 request requires a standard TCP 3-Way Handshake (`SYN` -> `SYN-ACK` -> `ACK`), followed by a TLS 1.3 handshake (1 RTT), the actual HTTP Request/Response transmission, and a TCP teardown (`FIN` -> `ACK`).

```
Client                                  Server
  |------------------ SYN ----------------->|  \
  |<--------------- SYN-ACK ----------------|   |-- TCP 3-Way Handshake (1 RTT)
  |------------------ ACK ----------------->|  /
  |---------------- ClientHello ------------>|  \
  |<-- ServerHello, Certificate, Finished --|   |-- TLS 1.3 Handshake (1 RTT)
  |---------------- Finished --------------->|  /
  |------------- HTTP GET Request --------->|  \
  |<------------ HTTP 200 OK Response ------|   |-- Application Data (1 RTT)
  |------------------ FIN ----------------->|  \
  |<----------------- ACK ------------------|   |-- Connection Teardown
```

Without connection reuse, a high-throughput endpoint processing $10,000\text{ req/sec}$ will exhaust local ephemeral ports (`ip_local_port_range`), driving sockets into the `TIME_WAIT` state, leading to kernel socket starvation and elevated latency.

**HTTP Keep-Alive (Persistent Connections)** mitigates this by maintaining an open TCP socket across multiple HTTP requests, eliminating re-handshake latency and reducing CPU overhead on edge proxies.

#### 1.3 Head-of-Line (HoL) Blocking and Protocol Evolution
* **HTTP/1.1 HoL Blocking:** While HTTP/1.1 introduced Keep-Alive and pipelining, requests over a single TCP connection must strictly complete sequentially. A slow backend query processing Request #1 blocks the delivery of Request #2 and #3 on the same TCP pipe.
* **HTTP/2 Multiplexing:** HTTP/2 introduces a binary framing layer that splits messages into independent frames mapped to streams. Multiple requests and responses interleave concurrently over a single TCP socket.
* **HTTP/3 (QUIC):** Resolves **TCP-level HoL Blocking**. In HTTP/2, if a single TCP packet is dropped, the OS kernel stalls all streams on that socket until the packet is retransmitted. HTTP/3 replaces TCP with QUIC over UDP, ensuring packet loss on Stream A does not stall independent data delivery on Stream B.

---

### 2. Technical Deep-Dives and Trade-Off Matrix

#### Table 2.1: Protocol Architecture Comparison

| Architectural Attribute | HTTP/1.1 (RFC 9112) | HTTP/2 (RFC 9113) | HTTP/3 (RFC 9114) |
| :--- | :--- | :--- | :--- |
| **Transport Protocol** | TCP | TCP | UDP (via QUIC) |
| **Framing Format** | Plain Text / ASCII | Binary Framing Layer | Binary Framing Layer |
| **Multiplexing** | No (Sequential per socket; Pipeling broken in practice) | Yes (Application-layer multiplexing over 1 TCP connection) | Yes (Native multiplexing over independent QUIC streams) |
| **Head-of-Line Blocking** | Application & Transport Level | Transport Level Only (TCP loss blocks all streams) | Resolved (Per-stream frame delivery) |
| **Header Compression** | None (Raw ASCII Headers) | HPACK (Static/Dynamic Tables + Huffman) | QPACK (Out-of-order stream header decoding) |
| **TLS Integration** | Optional (TLS 1.2 / 1.3 via SNI) | Mandatory in practice (ALPN negotiation `h2`) | Fully Integrated (TLS 1.3 embedded in QUIC payload) |
| **Connection Migration** | No (Tied to 4-tuple IP/Port) | No (Tied to 4-tuple IP/Port) | Yes (Connection ID persists across IP network switches) |

#### Table 2.2: HTTP Method Semantics (RFC 9110)

| Method | Safe | Idempotent | Request Body Allowed | Cacheable | Primary Production Use Case |
| :--- | :--- | :--- | :--- | :--- | :--- |
| `GET` | **Yes** | **Yes** | No (Undefined by RFC) | **Yes** | Fetching state without mutation. Query strings in URI. |
| `HEAD` | **Yes** | **Yes** | No | **Yes** | Health checks, checking cache freshness via response headers without body payload download. |
| `POST` | No | No | **Yes** | Exceptionally | Creating non-idempotent resources, submitting form payloads, executing actions. |
| `PUT` | No | **Yes** | **Yes** | No | Fully replacing a target resource state at a known URI. |
| `DELETE` | No | **Yes** | Optional | No | Removing target resource state at a specified URI. |
| `OPTIONS`| **Yes** | **Yes** | No | No | CORS Preflight requests to query cross-origin server capabilities. |
| `PATCH` | No | No | **Yes** | No | Applying partial modifications to a resource (RFC 5789). |

#### Table 2.3: HTTP Caching Mechanics & Revalidation

| Cache Directive / Header | Type | Scope | Behavioral Description | Production SRE Trade-off |
| :--- | :--- | :--- | :--- | :--- |
| `Cache-Control: public, max-age=3600` | Response | Client & CDNs | Response can be cached by any intermediate node for up to 3600 seconds. | Reduces origin load significantly; risks serving stale data during emergency deployments. |
| `Cache-Control: private, no-cache` | Response | Browser Only | Client may cache, but **must revalidate** with origin via `ETag`/`If-None-Match` before use. | Guarantees freshness on every hit while reducing bandwidth via `304 Not Modified`. |
| `Cache-Control: no-store` | Response | All Caches | Caching forbidden. No memory or storage write allowed. | Mandatory for sensitive PII/Financial payloads; increases load on origin servers. |
| `ETag: "v104-abc"` | Header | Validation | Strong entity validator hash generated by origin based on file content. | High CPU cost for dynamic hashing, but saves outbound network bandwidth via conditional `GET`. |
| `Vary: Accept-Encoding, User-Agent` | Response | CDNs / Proxies | Directs caches to key cache entries by specific request headers alongside URI. | Prevents sending gzipped content to unsupported clients; fragments cache keys, reducing hit ratio. |

#### Table 2.4: State & Session Management Architecture

| Dimension | Cookie-Based Session (Stateful) | Bearer JWT Token (Stateless) |
| :--- | :--- | :--- |
| **Storage Location** | Browser Cookie Store / Redis Server Tier | Browser `LocalStorage`, `SessionStorage`, or Memory |
| **Security Attributes** | `HttpOnly`, `Secure`, `SameSite=Strict/Lax/None` | Manually attached in `Authorization: Bearer <token>` |
| **CSRF Vulnerability** | **High** (Browser attaches cookies automatically; requires CSRF tokens) | **Low** (Headers are not automatically attached by browser cross-origin requests) |
| **XSS Vulnerability** | **Mitigated** if `HttpOnly` flag prevents JS access (`document.cookie`) | **High** if stored in `LocalStorage` (Accessible via malicious XSS scripts) |
| **Revocation Velocity** | **Instant** (Delete key in Redis cluster) | **Hard** (Must wait for token expiration or check a distributed revocation blacklist) |

---

### 3. Production Infrastructure & Manifold Manifests

#### 3.1 Complete Production NGINX Reverse Proxy Configuration (`nginx-edge-proxy.conf`)
The following configuration implements production-grade HTTP parameter tuning, Keep-Alive connection pooling, HTTP/2 termination, CORS handling, strict security headers, and caching revalidation rules.

```nginx
# /etc/nginx/nginx.conf
user www-data;
worker_processes auto;
worker_rlimit_nofile 65535;
pid /var/run/nginx.pid;

events {
    worker_connections 8192;
    use epoll;
    multi_accept on;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    # Performance Optimizations
    sendfile        on;
    tcp_nopush      on;
    tcp_nodelay     on;
    types_hash_max_size 2048;
    server_tokens   off;

    # Timeouts & Connection Tuning
    keepalive_timeout  65;
    keepalive_requests 10000;
    client_body_timeout 12;
    client_header_timeout 12;
    send_timeout 10;

    # Upstream Pool with Keep-Alive to Backend Microservices
    upstream backend_api_cluster {
        server 10.244.1.45:8080 max_fails=3 fail_timeout=10s;
        server 10.244.2.89:8080 max_fails=3 fail_timeout=10s;
        
        # Maintain a persistent pool of idle Keep-Alive connections to backends
        keepalive 64;
    }

    # Microservice Edge Server Block
    server {
        listen 443 ssl http2;
        server_name api.production.internal;

        ssl_certificate /etc/ssl/certs/api_production.crt;
        ssl_certificate_key /etc/ssl/private/api_production.key;
        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256;
        ssl_prefer_server_ciphers off;
        ssl_session_cache shared:SSL:10m;
        ssl_session_timeout 1d;

        # Global Security Headers
        add_header X-Content-Type-Options "nosniff" always;
        add_header X-Frame-Options "DENY" always;
        add_header X-XSS-Protection "1; mode=block" always;
        add_header Content-Security-Policy "default-src 'self';" always;
        add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" always;

        # Static Asset Caching Endpoint
        location /static/ {
            root /var/www/assets;
            expires 30d;
            add_header Cache-Control "public, no-transform";
            access_log off;
        }

        # API Dynamic Routing Endpoint
        location /api/v1/ {
            # CORS Preflight Handling
            if ($request_method = 'OPTIONS') {
                add_header 'Access-Control-Allow-Origin' 'https://dashboard.production.internal' always;
                add_header 'Access-Control-Allow-Methods' 'GET, POST, PUT, DELETE, OPTIONS' always;
                add_header 'Access-Control-Allow-Headers' 'Authorization, Content-Type, Accept, Origin, X-Requested-With' always;
                add_header 'Access-Control-Max-Age' 1728000;
                add_header 'Content-Type' 'text/plain; charset=utf-8';
                add_header 'Content-Length' 0;
                return 204;
            }

            add_header 'Access-Control-Allow-Origin' 'https://dashboard.production.internal' always;
            add_header 'Access-Control-Allow-Credentials' 'true' always;

            # HTTP Proxy Translation Controls
            proxy_pass http://backend_api_cluster;
            proxy_http_version 1.1;
            
            # Clear Connection header to enable upstream Keep-Alive socket reuse
            proxy_set_header Connection "";
            
            # Forward Original HTTP Headers to Upstream Context
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;

            # Buffer Configurations for High Throughput
            proxy_buffering on;
            proxy_buffer_size 8k;
            proxy_buffers 8 64k;
            proxy_busy_buffers_size 128k;

            # Upstream Timeout Definitions
            proxy_connect_timeout 3s;
            proxy_read_timeout 15s;
            proxy_send_timeout 15s;
        }
    }
}
```

#### 3.2 Complete Kubernetes NGINX Ingress & Deployment Manifest (`k8s-ingress-deployment.yaml`)

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: http-api-backend
  namespace: production
  labels:
    app.kubernetes.io/name: http-api-backend
    app.kubernetes.io/part-of: core-platform
spec:
  replicas: 3
  selector:
    matchLabels:
      app: http-api-backend
  template:
    metadata:
      labels:
        app: http-api-backend
    spec:
      containers:
      - name: api-container
        image: registry.production.internal/platform/api:v2.4.1
        ports:
        - name: http-port
          containerPort: 8080
        env:
        - name: PORT
          value: "8080"
        resources:
          requests:
            cpu: "250m"
            memory: "256Mi"
          limits:
            cpu: "1000m"
            memory: "512Mi"
        livenessProbe:
          httpGet:
            path: /healthz
            port: http-port
          initialDelaySeconds: 10
          periodSeconds: 5
          timeoutSeconds: 2
          failureThreshold: 3
        readinessProbe:
          httpGet:
            path: /ready
            port: http-port
          initialDelaySeconds: 5
          periodSeconds: 5
          timeoutSeconds: 2
---
apiVersion: v1
kind: Service
metadata:
  name: http-api-service
  namespace: production
  labels:
    app.kubernetes.io/name: http-api-backend
spec:
  type: ClusterIP
  ports:
  - port: 80
    targetPort: http-port
    protocol: TCP
    name: http
  selector:
    app: http-api-backend
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: http-api-ingress
  namespace: production
  annotations:
    kubernetes.io/ingress.class: "nginx"
    nginx.ingress.kubernetes.io/backend-protocol: "HTTP"
    nginx.ingress.kubernetes.io/proxy-connect-timeout: "5"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "15"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "15"
    nginx.ingress.kubernetes.io/proxy-body-size: "8m"
    nginx.ingress.kubernetes.io/enable-cors: "true"
    nginx.ingress.kubernetes.io/cors-allow-origin: "https://dashboard.production.internal"
    nginx.ingress.kubernetes.io/cors-allow-methods: "GET, POST, PUT, DELETE, OPTIONS"
    nginx.ingress.kubernetes.io/cors-allow-credentials: "true"
    nginx.ingress.kubernetes.io/configuration-snippet: |
      more_set_headers "X-Service-ID: core-api-v2";
      more_set_headers "Cache-Control: no-cache, private";
spec:
  tls:
  - hosts:
    - api.production.internal
    secretName: api-production-tls-secret
  rules:
  - host: api.production.internal
    http:
      paths:
      - path: /api/v1
        pathType: Prefix
        backend:
          service:
            name: http-api-service
            port:
              number: 80
```

---

### 4. Real CLI Commands & Raw Terminal Outputs

#### 4.1 Scenario 1: Verbose HTTP/1.1 Request Inspection (`curl`)
Executing an authenticated `POST` payload inspection with custom headers:

```bash
$ curl -i -v -X POST "https://api.production.internal/api/v1/resource" \
  -H "Host: api.production.internal" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json" \
  -H "Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c" \
  -d '{"resource_name":"k8s-cluster-01","environment":"production"}'
```

```http
*   Trying 192.168.1.100:443...
* Connected to api.production.internal (192.168.1.100) port 443 (#0)
* ALPN, offering h2
* ALPN, offering http/1.1
* TLSv1.3 (OUT), TLS handshake, Client hello (1):
* TLSv1.3 (IN), TLS handshake, Server hello (2):
* TLSv1.3 (IN), TLS handshake, Encrypted Extensions (8):
* TLSv1.3 (IN), TLS handshake, Certificate (11):
* TLSv1.3 (IN), TLS handshake, CERT verify (15):
* TLSv1.3 (IN), TLS handshake, Finished (20):
* SSL connection using TLSv1.3 / TLS_AES_256_GCM_SHA384
* ALPN, server accepted to use http/1.1
* Server certificate:
*  subject: CN=api.production.internal
*  start date: Aug 01 00:00:00 2026 GMT
*  expire date: Nov 01 00:00:00 2026 GMT
*  issuer: C=US; O=Let's Encrypt; CN=R3

> POST /api/v1/resource HTTP/1.1
> Host: api.production.internal
> User-Agent: curl/7.88.1
> Content-Type: application/json
> Accept: application/json
> Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c
> Content-Length: 61
> 

< HTTP/1.1 201 Created
< Server: nginx
< Date: Thu, 06 Aug 2026 18:50:00 GMT
< Content-Type: application/json; charset=utf-8
< Content-Length: 118
< Connection: keep-alive
< ETag: W/"76-a1b2c3d4e5"
< Cache-Control: no-cache, private
< X-Content-Type-Options: nosniff
< X-Frame-Options: DENY
< Access-Control-Allow-Origin: https://dashboard.production.internal
< Access-Control-Allow-Credentials: true
< Set-Cookie: __Host-SessionId=s%3A987654321; Path=/; Secure; HttpOnly; SameSite=Strict
< 
{
  "status": "success",
  "data": {
    "id": "res-99482",
    "resource_name": "k8s-cluster-01",
    "environment": "production"
  }
}
* Connection #0 to host api.production.internal left intact
```

#### 4.2 Scenario 2: TLS ALPN Protocol Negotiation via `openssl`
Checking whether an edge proxy supports HTTP/2 (`h2`) via Application-Layer Protocol Negotiation (ALPN):

```bash
$ openssl s_client -connect api.production.internal:443 -alpn h2 -servername api.production.internal < /dev/null
```

```text
CONNECTED(00000003)
depth=2 C = US, O = Internet Security Research Group, CN = ISRG Root X1
verify return:1
depth=1 C = US, O = Let's Encrypt, CN = R3
verify return:1
depth=0 CN = api.production.internal
verify return:1
---
Certificate chain
 0 s:CN = api.production.internal
   i:C = US, O = Let's Encrypt, CN = R3
   a:PKEY: rsaEncryption, 2048 (bits); conds: pkcs1 cryptographic
---
Server certificate
-----BEGIN CERTIFICATE-----
MIIFdTCCBG2gAwIBAgISA17xR8kL4A234...
-----END CERTIFICATE-----
subject=CN = api.production.internal
issuer=C = US, O = Let's Encrypt, CN = R3
---
No client certificate CA names sent
Peer signing digest: SHA256
Peer signature type: RSA-PSS
Server Temp Key: X25519, 253 bits
---
SSL handshake has read 3450 bytes and written 392 bytes
Verification: OK
---
New, TLSv1.3, Cipher is TLS_AES_256_GCM_SHA384
Server public key is 2048 bit
Secure Renegotiation IS NOT supported
Compression: NONE
Expansion: NONE
No ALPN negotiated
ALPN protocol: h2
Early data was not sent
Verify return code: 0 (ok)
---
DONE
```

#### 4.3 Scenario 3: Real-Time Packet Capture via `tshark`
Filtering HTTP status codes and headers at the network interface layer:

```bash
$ sudo tshark -i eth0 -n -Y "http.request or http.response" \
  -T fields -e frame.time_relative -e ip.src -e ip.dst -e http.request.method \
  -e http.request.uri -e http.response.status_code -e http.response.phrase
```

```text
0.000000000 10.244.0.5 -> 10.244.1.45 GET /api/v1/healthz  
0.001243110 10.244.1.45 -> 10.244.0.5   200 OK
4.120485922 10.244.0.12 -> 10.244.1.45 POST /api/v1/checkout  
4.482019481 10.244.1.45 -> 10.244.0.12   504 Gateway Timeout
8.910243102 10.244.0.18 -> 10.244.1.45 OPTIONS /api/v1/user  
8.910948192 10.244.1.45 -> 10.244.0.18   204 No Content
```

---

### 5. Verification, Failure Diagnostics & SRE Troubleshooting Guide

```
                        HTTP INCIDENT DIAGNOSTIC FLOW
                                      |
                           [Check HTTP Status Code]
                                      |
         +----------------------------+----------------------------+
         |                                                         |
     [5xx Series]                                              [4xx Series]
         |                                                         |
   +-----+-----+                                             +-----+-----+
   |           |                                             |           |
[502 Bad    [504 Gateway                                 [403/CORS]   [429 Rate
Gateway]     Timeout]                                        |         Limited]
   |           |                                             |           |
 Check       Check Upstream                            Check Missing   Check Token
Upstream     Read Timeout                              Headers & OPTIONS Bucket / Redis
 Process     or DB Lock                                 Preflight       Limits
 Alive       Exhaustion
```

#### 5.1 Troubleshooting Matrix for Common Production Incidents

##### Case 1: `502 Bad Gateway` vs. `504 Gateway Timeout`
* **Root Cause (502 Bad Gateway):** Edge proxy received an explicit `RST` (TCP Reset) or `FIN` segment from the upstream application service while attempting to connect. The process crashed, worker threads hung, or the socket backlog queue was full.
* **Root Cause (504 Gateway Timeout):** Edge proxy successfully established a TCP socket connection with upstream, but upstream failed to send an HTTP response payload within `proxy_read_timeout` (e.g., long-running database query, unhandled thread deadlock).
* **Diagnostic Workflow:**
  1. Inspect proxy error logs (`/var/log/nginx/error.log`):
     * *502 signature:* `connect() failed (111: Connection refused) while connecting to upstream`
     * *504 signature:* `upstream timed out (110: Connection timed out) while reading response header from upstream`
  2. Verify backend container socket listener:
     ```bash
     $ kubectl logs deployment/http-api-backend -n production --tail=100
     $ nc -zv 10.244.1.45 8080
     ```

##### Case 2: Cross-Origin Resource Sharing (CORS) Blocking
* **Symptom:** Browser blocks client-side JavaScript from processing response data with error: `Access to fetch at 'https://api.production.internal' from origin 'https://dashboard.production.internal' has been blocked by CORS policy`.
* **Root Cause:** 
  1. Missing `Access-Control-Allow-Origin` matching client origin.
  2. Failed OPTIONS preflight call due to backend returning non-2xx status code on preflight.
  3. Attempting to send credentials (`Cookie`/`Authorization` header) when `Access-Control-Allow-Credentials` is `false` or `Access-Control-Allow-Origin` is set to wildcard `*`.
* **Diagnostic Workflow:**
  Execute manual OPTIONS preflight curl test:
  ```bash
  $ curl -i -X OPTIONS "https://api.production.internal/api/v1/resource" \
    -H "Origin: https://dashboard.production.internal" \
    -H "Access-Control-Request-Method: POST" \
    -H "Access-Control-Request-Headers: Authorization, Content-Type"
  ```
  *Expectation:* HTTP status `204 No Content` or `200 OK` with valid CORS headers.

##### Case 3: Cache Poisoning & Stale Data Contamination
* **Symptom:** Clients view incorrect cached states across user sessions after a deployment.
* **Root Cause:** Origin omitted the `Vary: Cookie` or `Vary: Authorization` header while returning a cacheable (`Cache-Control: public`) response. Intermediate CDNs aggregated response payloads across multiple users using URI as the sole cache key.
* **Diagnostic Workflow:**
  1. Inspect response headers using `curl -I`:
     ```bash
     $ curl -I -H "Authorization: Bearer token-A" https://api.production.internal/api/v1/user/profile
     ```
  2. Verify presence of `Vary` header and correct `Cache-Control` scopes:
     ```http
     HTTP/1.1 200 OK
     Cache-Control: private, no-cache
     Vary: Authorization, Accept-Encoding
     ```

##### Case 4: Cookie Dropped / Session Loss Across Subdomains
* **Symptom:** Browser loses authentication session state when navigating between `app.production.internal` and `api.production.internal`.
* **Root Cause:**
  1. Cookie `Domain` attribute set explicitly to `app.production.internal` instead of parent wildcard `.production.internal`.
  2. Cookie configured with `SameSite=Strict`, preventing cross-subdomain top-level navigation state propagation.
  3. Missing `Secure` attribute when operating under HTTPS causing modern browsers to reject `Set-Cookie`.
* **Diagnostic Workflow:**
  Inspect raw raw set-cookie header attributes:
  ```bash
  $ curl -i https://api.production.internal/api/v1/login | grep -i "set-cookie"
  ```
  *Correct Output:*
  ```http
  Set-Cookie: session_token=xyz123; Domain=.production.internal; Path=/; Secure; HttpOnly; SameSite=Lax
  ```

---

### 6. References

1. **Linux Professional Institute (LPI) Official Site**
   [https://www.lpi.org/our-certifications/web-development-essentials-overview/](https://www.lpi.org/our-certifications/web-development-essentials-overview/)
2. **IETF RFC 9110: HTTP Semantics (Standardized June 2022)**
   [https://www.rfc-editor.org/rfc/rfc9110.html](https://www.rfc-editor.org/rfc/rfc9110.html)
3. **IETF RFC 9111: HTTP Caching**
   [https://www.rfc-editor.org/rfc/rfc9111.html](https://www.rfc-editor.org/rfc/rfc9111.html)
4. **IETF RFC 9112: HTTP/1.1 Protocol Specifications**
   [https://www.rfc-editor.org/rfc/rfc9112.html](https://www.rfc-editor.org/rfc/rfc9112.html)
5. **IETF RFC 9113: HTTP/2 Specification**
   [https://www.rfc-editor.org/rfc/rfc9113.html](https://www.rfc-editor.org/rfc/rfc9113.html)
6. **IETF RFC 9114: HTTP/3 Protocol Specification**
   [https://www.rfc-editor.org/rfc/rfc9114.html](https://www.rfc-editor.org/rfc/rfc9114.html)
7. **MDN Web Docs: HTTP Protocols and Headers**
   [https://developer.mozilla.org/en-US/docs/Web/HTTP](https://developer.mozilla.org/en-US/docs/Web/HTTP)
8. **NGINX Core Architecture & Tuning Documentation**
   [https://nginx.org/en/docs/](https://nginx.org/en/docs/)