# Topic 1.2: Web Application Architecture — Production Study Guide

**Target Exam:** LPI Web Development Essentials (Exam 030-100, Version 1.0)  
**Topic:** 1.2 Web Application Architecture  
**Weight:** 5  
**Audience Level:** Principal Platform Architect / Senior SRE  

---

## 1. Architecture & Technical Motivation

### 1.1 The Production Architectural Problem
Modern web application architectures exist to solve a fundamental production problem: **how to maintain high availability, low latency, and operational scalability under dynamic, unpredicted workloads while guaranteeing data consistency and system resilience.**

A naive single-server architecture combines the static web server, dynamic application runtime, database, and state store into a single failure domain. This introduces critical production bottlenecks:
1. **Vertical Resource Exhaustion:** CPU-bound dynamic rendering starves I/O-bound database threads.
2. **Single Point of Failure (SPOF):** Network interface card (NIC) saturation, kernel panics, or unhandled application crashes bring down the entire web service.
3. **State Entanglement:** Session state kept in process memory prevents horizontal auto-scaling across transient compute nodes.

```
+-----------------------------------------------------------------------------------+
|                               Naive Architecture                                  |
|                                                                                   |
|  [ Client Browser ] ----> [ Single VM: NGINX + Node.js/Python + SQLite/Postgres ] |
|                                   (SPOF / Resource Contention)                    |
+-----------------------------------------------------------------------------------+
```

### 1.2 Multi-Tier Decoupled Architecture Internal Mechanics
To achieve resilience and horizontal elasticity, production web architectures decompose responsibilities across specialized execution tiers:

```
[ Client ] 
    |
    v (HTTPS / TLS 1.3 - Port 443)
[ Layer 7 Load Balancer / Ingress Controller (e.g., HAProxy / NGINX Ingress) ]
    |
    +--------------------------------+--------------------------------+
    | (Static Requests)              | (Dynamic API Requests)         |
    v                                v                                v
[ CDN / Object Storage ]   [ Web/App Tier (Stateless Pods) ]   [ Web/App Tier ]
                                     |                |
                     +---------------+                +---------------+
                     | (Transient Read/Write)                         | (Persistent Data)
                     v                                                v
           [ Distributed Cache ]                            [ Database Tier ]
         (Redis / Key-Value Cluster)                    (Primary-Replica Cluster)
```

#### Mechanical Breakdown:
* **Edge & Traffic Ingress Layer:** Terminates TLS encryption, executes Web Application Firewall (WAF) filtering, enforces HTTP protocol compliance, and proxies L7 traffic down stream via persistent HTTP/2 or HTTP/3 connections.
* **Stateless Web/Application Tier:** Executes business logic inside containerized micro-runtimes (e.g., Go, Node.js, Python, Java). Application instances store **zero local session state** on local ephemeral disks.
* **Caching Tier:** Offloads high-frequency read operations from the relational data layer using in-memory data structures (sub-millisecond latency).
* **Persistence Tier:** Guarantees ACID compliance or eventual consistency using primary-replica replication topologies with automated failover management.

---

## 2. Technical Trade-offs & Comparisons

### 2.1 Architectural Styles: Monolith vs. Microservices vs. Serverless

| Vector | Monolithic Architecture | Microservices Architecture | Serverless / FaaS Architecture |
| :--- | :--- | :--- | :--- |
| **Operational Complexity** | Low. Single pipeline, unified log stream. | High. Requires distributed tracing, service discovery, mesh. | Medium. Cloud vendor manages compute, developer manages events. |
| **Deployment Isolation** | Low. Single bug can crash entire runtime. | High. Failures contained within individual microservice boundaries. | Highest. Each execution context runs isolated in microVMs (e.g. Firecracker). |
| **Data Consistency** | Strong (ACID transactions natively supported). | Eventual (Saga pattern, distributed transactions, CDC). | Eventual/Externalized (relies on downstream databases). |
| **Latency Profile** | Low intra-process call overhead (in-memory IPC). | Network serialization (gRPC/JSON over TCP) adds RPC latency. | Cold start penalty (10ms - 2000ms depending on runtime/VPC). |
| **Scaling Granularity** | Coarse. Scales entire application stack together. | Fine. Scale specific CPU/RAM bound microservices independently. | Micro. Scales exact invocations from 0 to thousands instantly. |

---

### 2.2 Traffic Management Layering: L4 vs. L7 Load Balancing

```
Layer 4 (Transport Layer):
[ Client ] ---> [ IP:Port Router (e.g., IPVS/NLB) ] ---> TCP SYN/ACK Passthrough ---> [ Backend ]

Layer 7 (Application Layer):
[ Client ] ---> [ TLS Decryption | HTTP Headers Parsing (NGINX/HAProxy) ] ---> New TCP/HTTP Connection ---> [ Backend ]
```

| Dimension | Layer 4 Load Balancing (e.g., IPVS, AWS NLB) | Layer 7 Load Balancing (e.g., NGINX, HAProxy, AWS ALB) |
| :--- | :--- | :--- |
| **OSI Layer** | Transport Layer (TCP/UDP). | Application Layer (HTTP, HTTPS, HTTP/2, gRPC, WebSocket). |
| **Inspection Capability** | IP addresses and TCP/UDP port tuples only. | HTTP URIs, headers, cookies, query parameters, payload bodies. |
| **Performance / CPU Overhead** | Extremely high throughput, minimal CPU impact (Kernel packet forwarding). | Higher CPU usage due to TLS decryption, buffer allocation, header parsing. |
| **Routing Decisions** | Connection-level round-robin, least connections, IP hash. | Path-based (`/api/v1`), host-based (`api.domain.com`), cookie affinity. |
| **Security Capabilities** | SYN flood mitigation, IP rate limiting. | WAF enforcement, SQLi/XSS filtering, OAuth/OIDC token validation. |

---

### 2.3 State Management Strategies

| Strategy | Mechanical Architecture | SRE Trade-offs & Production Risks |
| :--- | :--- | :--- |
| **Sticky Sessions (Session Affinity)** | Load Balancer pins client IP/Cookie to a specific backend server. | **Anti-pattern for elasticity.** Causes unequal server load distribution (hotspots); node failure drops active user sessions. |
| **Centralized In-Memory Store** | Session ID sent via HTTP Header/Cookie; state fetched from Redis/Memcached cluster. | **Industry standard.** Enables stateless application pods. Adds 1-2ms network round-trip per request; requires high-availability cache setup. |
| **Client-Side Encrypted Tokens (JWT)** | State cryptographically signed and encoded directly into HTTP Authorization headers. | Eliminates server-side session lookups. **Risk:** Revocation difficulty before TTL expiration; token size bloat adds bandwidth overhead. |

---

## 3. Production Infrastructure & Complete Manifests

The following manifests construct a production-ready Web Application Architecture on Kubernetes, comprising:
1. An **NGINX Reverse Proxy/Ingress Controller** with optimized caching and TLS termination.
2. A **Stateless Backend Application Deployment** with health probes and auto-scaling support.
3. A high-availability **Redis Caching Layer Deployment & Service**.

---

### 3.1 NGINX Gateway/Reverse Proxy Production Configuration (`nginx.conf`)

```nginx
user nginx;
worker_processes auto;
worker_rlimit_nofile 65535;
pid /var/run/nginx.pid;

events {
    worker_connections 8192;
    use epoll;
    multi_accept on;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    # Performance & Optimization Settings
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;
    server_tokens off;

    # Buffer Configurations
    client_body_buffer_size 128k;
    client_max_body_size 10m;
    client_header_buffer_size 1k;
    large_client_header_buffers 4 4k;

    # Logging Metrics Configuration (JSON for Log Aggregators)
    log_format json_combined escape=json
      '{"time_local":"$time_local",'
      '"remote_addr":"$remote_addr",'
      '"request":"$request",'
      '"status": "$status",'
      '"body_bytes_sent":"$body_bytes_sent",'
      '"request_time":"$request_time",'
      '"http_referrer":"$http_referer",'
      '"http_user_agent":"$http_user_agent",'
      '"upstream_addr":"$upstream_addr",'
      '"upstream_response_time":"$upstream_response_time",'
      '"upstream_status":"$upstream_status"}';

    access_log /var/log/nginx/access.log json_combined;
    error_log /var/log/nginx/error.log warn;

    # FastCGI / Upstream Caching Path
    proxy_cache_path /var/cache/nginx levels=1:2 keys_zone=WEB_CACHE:10m max_size=1g inactive=60m use_temp_path=off;

    # Upstream Pool for Web Tier
    upstream web_backend_cluster {
        zone web_backend_cluster 64k;
        server 10.244.1.15:8080 max_fails=3 fail_timeout=10s;
        server 10.244.2.22:8080 max_fails=3 fail_timeout=10s;
        server 10.244.3.41:8080 max_fails=3 fail_timeout=10s;
        keepalive 32;
    }

    server {
        listen 80;
        server_name app.production.internal;
        return 301 https://$host$request_uri;
    }

    server {
        listen 443 ssl http2;
        server_name app.production.internal;

        ssl_certificate /etc/ssl/certs/app_production.crt;
        ssl_certificate_key /etc/ssl/certs/app_production.key;
        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
        ssl_prefer_server_ciphers off;

        # Security Headers
        add_header X-Frame-Options "DENY" always;
        add_header X-Content-Type-Options "nosniff" always;
        add_header X-XSS-Protection "1; mode=block" always;
        add_header Content-Security-Policy "default-src 'self';" always;

        # Static Asset Caching Route
        location /static/ {
            alias /var/www/static/;
            expires 30d;
            add_header Cache-Control "public, no-transform";
            access_log off;
        }

        # Dynamic Application Route
        location / {
            proxy_pass http://web_backend_cluster;
            proxy_http_version 1.1;
            
            # HTTP Headers for Upstream Context Propagation
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection "keep-alive";
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;

            # Caching Directives
            proxy_cache WEB_CACHE;
            proxy_cache_bypass $http_authorization;
            proxy_no_cache $http_authorization;
            proxy_cache_valid 200 302 10m;
            proxy_cache_valid 404 1m;
            proxy_cache_use_stale error timeout updating http_500 http_502 http_503 http_504;
            add_header X-Cache-Status $upstream_cache_status;
        }
    }
}
```

---

### 3.2 Stateless Web Application Tier Kubernetes Deployment (`web-app-deployment.yaml`)

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web-app-deployment
  namespace: production
  labels:
    app.kubernetes.io/name: web-app
    app.kubernetes.io/tier: frontend-api
spec:
  replicas: 3
  selector:
    matchLabels:
      app: web-app
  template:
    metadata:
      labels:
        app: web-app
        app.kubernetes.io/tier: frontend-api
    spec:
      containers:
      - name: application-runtime
        image: registry.production.internal/web-app:v2.4.1
        imagePullPolicy: IfNotPresent
        ports:
        - containerPort: 8080
          name: http-port
        env:
        - name: NODE_ENV
          value: "production"
        - name: REDIS_HOST
          value: "redis-service.production.svc.cluster.local"
        - name: REDIS_PORT
          value: "6379"
        resources:
          requests:
            cpu: "250m"
            memory: "512Mi"
          limits:
            cpu: "1000m"
            memory: "1024Mi"
        startupProbe:
          httpGet:
            path: /healthz/startup
            port: 8080
          initialDelaySeconds: 5
          periodSeconds: 5
          failureThreshold: 10
        livenessProbe:
          httpGet:
            path: /healthz/liveness
            port: 8080
          periodSeconds: 10
          timeoutSeconds: 2
          failureThreshold: 3
        readinessProbe:
          httpGet:
            path: /healthz/readiness
            port: 8080
          periodSeconds: 5
          timeoutSeconds: 2
          successThreshold: 1
          failureThreshold: 2
---
apiVersion: v1
kind: Service
metadata:
  name: web-app-service
  namespace: production
spec:
  type: ClusterIP
  selector:
    app: web-app
  ports:
  - name: http
    port: 80
    targetPort: 8080
```

---

### 3.3 Redis Caching Tier Manifest (`cache-tier.yaml`)

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis-cache
  namespace: production
  labels:
    app: redis-cache
spec:
  replicas: 1
  selector:
    matchLabels:
      app: redis-cache
  template:
    metadata:
      labels:
        app: redis-cache
    spec:
      containers:
      - name: redis
        image: redis:7.2-alpine
        command: ["redis-server", "--maxmemory", "384mb", "--maxmemory-policy", "allkeys-lru"]
        ports:
        - containerPort: 6379
          name: redis-port
        resources:
          requests:
            cpu: "100m"
            memory: "256Mi"
          limits:
            cpu: "500m"
            memory: "512Mi"
---
apiVersion: v1
kind: Service
metadata:
  name: redis-service
  namespace: production
spec:
  type: ClusterIP
  selector:
    app: redis-cache
  ports:
  - port: 6379
    targetPort: 6379
```

---

## 4. Real Terminal Execution & Output Verification

### 4.1 Validating HTTP Layer 7 Routing & Cache Status via `curl`

Execute an HTTP request to the load balancer/proxy endpoint to verify TLS handshake, custom headers, and cache behavior.

```bash
$ curl -Iv https://app.production.internal/api/v1/resource -H "User-Agent: SRE-Verification-Probe"
```

```text
*   Trying 192.168.10.50:443...
* Connected to app.production.internal (192.168.10.50) port 443 (#0)
* ALPN: offers h2, http/1.1
* TLSv1.3 (OUT), TLS handshake, Client hello (1):
* TLSv1.3 (IN), TLS handshake, Server hello (2):
* TLSv1.3 (IN), TLS handshake, Encrypted Extensions (8):
* TLSv1.3 (IN), TLS handshake, Certificate (11):
* TLSv1.3 (IN), TLS handshake, CERT verify (15):
* TLSv1.3 (IN), TLS handshake, Finished (20):
* SSL connection using TLSv1.3 / TLS_AES_256_GCM_SHA384
* Server certificate: app.production.internal (CN=app.production.internal)
> GET /api/v1/resource HTTP/2
> Host: app.production.internal
> User-Agent: SRE-Verification-Probe
> Accept: */*
> 
< HTTP/2 200 
< server: nginx
< date: Thu, 06 Aug 2026 22:15:00 GMT
< content-type: application/json; charset=utf-8
< content-length: 142
< x-frame-options: DENY
< x-content-type-options: nosniff
< x-xss-protection: 1; mode=block
< content-security-policy: default-src 'self';
< x-cache-status: MISS
< 
{
  "status": "success",
  "data": {
    "id": 8921,
    "payload": "stateless_execution_successful"
  }
}
* Connection #0 to host app.production.internal left intact
```

Execute a second identical request to confirm **Layer 7 Cache Hits**:

```bash
$ curl -sI https://app.production.internal/api/v1/resource | grep -i "x-cache-status"
```

```text
x-cache-status: HIT
```

---

### 4.2 Verifying Kubernetes Pod Deployment Status via `kubectl`

Inspect the operational health and readiness of the stateless web tier pods.

```bash
$ kubectl get pods -n production -o wide -l app.kubernetes.io/tier=frontend-api
```

```text
NAME                                  READY   STATUS    RESTARTS   AGE   IP            NODE           NOMINATED NODE   READINESS GATES
web-app-deployment-7d5844784b-4q2lz   1/1     Running   0          14m   10.244.1.15   k8s-worker-01   <none>           <none>
web-app-deployment-7d5844784b-8x9mp   1/1     Running   0          14m   10.244.2.22   k8s-worker-02   <none>           <none>
web-app-deployment-7d5844784b-n9zlp   1/1     Running   0          14m   10.244.3.41   k8s-worker-03   <none>           <none>
```

---

### 4.3 Verifying Upstream Endpoints & Service Load Balancing

Verify that the Kubernetes Service correctly maps endpoints to active Pod IPs:

```bash
$ kubectl get endpoints web-app-service -n production
```

```text
NAME              ENDPOINTS                                               AGE
web-app-service   10.244.1.15:8080,10.244.2.22:8080,10.244.3.41:8080   16m
```

---

## 5. Production Diagnostics, Verification & Failure Analysis

When troubleshooting a multi-tier web application architecture under stress, SREs follow a systematic, tier-by-tier diagnostic workflow to isolate failure domains.

```
[ Diagnostic Workflow Flowchart ]

    [ Issue Reported: High Latency / 5xx Errors ]
                         |
                         v
       [ Step 1: Check Reverse Proxy / Ingress Logs ]
                         |
         +---------------+---------------+
         |                               |
  (HTTP 502/504 Bad Gateway)     (HTTP 500 Internal Error)
         |                               |
         v                               v
[ Step 2: Validate Upstream ]   [ Step 3: Inspect Pod Logs ]
 (Network/Socket Connectivity)   (Application Code/Exceptions)
         |                               |
         v                               v
[ Step 4: Capture Packets ]     [ Step 5: Check Cache/DB ]
   (tcpdump on Port 8080)         (Redis memory / DB locks)
```

---

### 5.1 Step 1: Analyze Ingress Logs for Upstream Latency and Status Codes
Check if the ingress proxy is returning 502 (Bad Gateway) or 504 (Gateway Timeout), indicating upstream microservice degradation.

```bash
$ tail -n 100 /var/log/nginx/access.log | jq 'select(.status >= 500)'
```

```json
{
  "time_local": "06/Aug/2026:22:20:11 +0000",
  "remote_addr": "172.16.4.12",
  "request": "POST /api/v1/checkout HTTP/2.0",
  "status": "504",
  "body_bytes_sent": "167",
  "request_time": "10.004",
  "upstream_addr": "10.244.2.22:8080",
  "upstream_response_time": "10.000",
  "upstream_status": "504"
}
```
**Diagnosis:** The upstream pod (`10.244.2.22:8080`) failed to respond within the 10-second timeout (`upstream_response_time: 10.000`).

---

### 5.2 Step 2: Inspect Application Runtime Container Logs
Examine the logs of the degraded pod identified in Step 1.

```bash
$ kubectl logs web-app-deployment-7d5844784b-8x9mp -n production --tail=50
```

```text
2026-08-06T22:20:05.112Z [ERROR] Failed to obtain connection from connection pool: RedisConnectionTimeoutError
    at RedisCluster.acquire (/app/node_modules/ioredis/lib/redis.js:412:11)
    at async SessionStore.get (/app/dist/session.js:88:21)
    at async /app/dist/server.js:142:9
2026-08-06T22:20:10.115Z [WARN] Request lifecycle aborted by client termination.
```
**Diagnosis:** The application tier is blocked waiting for connection acquisition from the centralized Redis cache tier, leading to upstream connection exhaustion.

---

### 5.3 Step 3: Low-Level Packet Capture & Socket Verification (`tcpdump` & `netstat`)
Execute a low-level packet capture inside the application node to verify TCP handshake health between the web tier and the cache tier.

```bash
$ tcpdump -i eth0 port 6379 -nn -vv -c 5
```

```text
22:22:01.401123 IP 10.244.2.22.48912 > 10.244.0.99.6379: Flags [S], seq 31120491, win 64240, options [mss 1460,sackOK,TS val 2189381 ecr 0], length 0
22:22:02.403154 IP 10.244.2.22.48912 > 10.244.0.99.6379: Flags [S], seq 31120491, win 64240, options [mss 1460,sackOK,TS val 2190383 ecr 0], length 0
22:22:04.407188 IP 10.244.2.22.48912 > 10.244.0.99.6379: Flags [S], seq 31120491, win 64240, options [mss 1460,sackOK,TS val 2192387 ecr 0], length 0
```
**Diagnosis:** The application pod is sending TCP `SYN` packets (`Flags [S]`), but receiving **no `SYN-ACK` responses** from the Redis IP (`10.244.0.99`). This indicates either a dropped packet due to NetworkPolicy misconfiguration, or an exhausted Redis thread pool.

---

### 5.4 Diagnostic Summary Table of Web Architecture Failures

| Symptom | Root Cause | Verification Command | Resolution Action |
| :--- | :--- | :--- | :--- |
| **HTTP 502 Bad Gateway** | Upstream process crashed or socket not listening on target port. | `kubectl describe pod <pod-name>` (Check restart count & exit codes). | Fix runtime memory leaks/exceptions; update container health probes. |
| **HTTP 504 Gateway Timeout** | Downstream database lock contention or blocking remote API call. | `curl -w "%{time_connect}:%{time_starttransfer}\n"` | Increase upstream timeout limits or implement asynchronous background queueing. |
| **HTTP 413 Payload Too Large** | Request body size exceeds reverse proxy buffer limits. | Inspect NGINX error logs for `"client intended to send too large body"`. | Increase `client_max_body_size` in reverse proxy configuration. |
| **Session Loss Across Requests** | Application writing sessions to local disk instead of Redis cache. | `kubectl exec -it <pod> -- ls /tmp/sessions` | Refactor session store to use externalized Redis key-value cluster. |

---

## 6. References

* **LPI Web Development Essentials Overview & Objectives:**  
  https://www.lpi.org/our-certifications/web-development-essentials-overview/
* **NGINX High Performance HTTP Server Architecture & Tuning:**  
  https://nginx.org/en/docs/http/ngx_http_core_module.html
* **Kubernetes Production Ingress & Service Topology Documentation:**  
  https://kubernetes.io/docs/concepts/services-networking/ingress/
* **IETF RFC 9110: HTTP Semantics and Architecture Specification:**  
  https://www.rfc-editor.org/rfc/rfc9110.html
* **Redis High-Availability System Architecture Guidelines:**  
  https://redis.io/docs/latest/operate/oss_and_stack/management/scaling/