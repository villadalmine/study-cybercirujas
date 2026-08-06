# LPI 050-100: Open Source Essentials — Topic 6.3: Communication and Collaboration Tools
## Advanced Production Architecture & SRE Reference Manual

---

## 1. Production Motivation & Architectural Problem Statement

In enterprise production environments, open-source communication and collaboration tools form the **central nervous system of Operations and Incident Response**. Far beyond simple team chat or wiki pages, modern platform engineering integrates these systems directly into automated CI/CD pipelines, observability platforms, and automated remediation engines (ChatOps).

### Enterprise SRE Challenges & Architectural Requirements

```
                                +---------------------------------------+
                                |      Observability & CI/CD Drivers    |
                                | (Prometheus, Alertmanager, GitLab CI) |
                                +-------------------+-------------------+
                                                    |
                                       HTTP Webhooks / JSON Payload
                                                    |
                                                    v
+------------------------+      +-------------------+-------------------+
|  Stateless Web Access  |----->|  Ingress Gateway (Reverse Proxy / TLS) |
| (REST API / Nextcloud) |      +-------------------+-------------------+
+------------------------+                          |
                                       Persistent WebSockets / HTTP/2
                                                    |
                                                    v
                                +-------------------+-------------------+
                                | Collaboration App Cluster (Mattermost)|
                                +---------+-------------------+---------+
                                          |                   |
                     Shared Session State |                   | Object Storage
                                          v                   v
                                +---------+-------+   +-------+---------+
                                | Redis Cluster   |   | S3 / MinIO Store|
                                | (Pub/Sub Sync)  |   | (Blobs / Attach)|
                                +-----------------+   +-----------------+
                                          |
                                          | Relational State & ACID
                                          v
                                +---------+-------------------+
                                | PostgreSQL HA Database Cluster|
                                +-------------------------------+
```

1. **State Synchronization at Scale (WebSockets & Long-Polling):**
   Real-time chat platforms (e.g., Mattermost, Matrix Synapse) maintain thousands of persistent, concurrent long-lived TCP/WebSocket connections. Unlike stateless web applications, multi-node deployments of real-time collaboration engines require a low-latency pub/sub layer (e.g., Redis Cluster) to broadcast state updates across nodes instantly when an event occurs on any node.

2. **Incident Storm Resilience & Throttling:**
   During a major outage (P0/P1 events), automated monitoring tools (Prometheus Alertmanager, Datadog) generate surge bursts of incoming webhooks into incident channels. If the collaboration stack lacks inbound queue buffering, backpressure controls, or connection pooling, the platform itself will suffer database lock contention, memory spikes, and cascading failovers precisely when engineers need it most.

3. **Data Sovereignty, Compliance, & Air-Gapped Operation:**
   Regulated industries (FinTech, Healthcare, Defense) require complete data governance. Proprietary SaaS platforms (Slack, Teams, Notion) introduce vendor lock-in, external compliance risks, and dependency on external internet routing. Self-hosted open-source solutions allow end-to-end encryption (E2EE), local database storage, immutable audit logging, and full operation inside air-gapped VPCs or sovereign Kubernetes clusters.

4. **Integration Architecture (ChatOps & API Interoperability):**
   A robust collaboration stack acts as an event bus. SRE teams automate infrastructure actions using bidirectional webhooks, slash commands, and bot frameworks. The backend must enforce cryptographic payload integrity (HMAC signatures), mutual TLS (mTLS), and fine-grained Role-Based Access Control (RBAC) to prevent unauthorized privilege escalation via chat interfaces.

---

## 2. Technical Mechanism & Architecture Comparison

Open-source collaboration platforms span distinct architecture patterns depending on their operational focus: synchronous messaging, asynchronous knowledge sharing, distributed file synchronization, and code collaboration.

### Core Architectural Classifications

1. **Synchronous Messaging & ChatOps Platforms:**
   * **Mattermost:** Go-based monolithic binary designed for horizontal scaling. Uses PostgreSQL/MySQL for relational persistence, Redis for multi-node WebSocket synchronization, and S3-compatible storage for file attachments. High compatibility with Slack webhooks and API schemas.
   * **Matrix (Synapse/Dendrite):** Open, decentralized, federated communication protocol. Events form a Directed Acyclic Graph (DAG) replicated across federated servers via E2EE. Highly resilient against single-node failures, but requires significant database indexing and caching due to DAG state resolution overhead.
   * **Rocket.Chat:** Node.js/TypeScript application leveraging MongoDB for document storage and Meteor framework/WebSockets for real-time reactive data distribution.

2. **Asynchronous Knowledge & Documentation Repositories:**
   * **BookStack:** PHP/Laravel platform utilizing MySQL/MariaDB. Employs a visual hierarchy (Shelves -> Books -> Chapters -> Pages) designed for operational documentation and internal Knowledge Bases (KB).
   * **MediaWiki:** PHP database-backed wiki engine powering Wikipedia. Highly extensible with complex caching layers (Varnish, Redis, Memcached) to serve read-heavy production documentation workloads.
   * **DokuWiki:** Light, database-less wiki storing content in plain text files. Uses directory trees and filesystem locking, ideal for simple infrastructure documentation without database overhead.

3. **Revision Control & Code Collaboration Ecosystems:**
   * **GitLab CE:** Enterprise suite combining Ruby on Rails, Go microservices (Gitaly for Git RPCs), PostgreSQL, Redis, and Workhorse. Highly scalable, providing full CI/CD pipeline integration, code review, and issue tracking.
   * **Gitea / Forgejo:** Ultra-lightweight Go application with minimal resource utilization. Operates on SQLite, MySQL, or PostgreSQL, suitable for edge deployments and lightweight code collaboration.

4. **File Synchronization & Productivity Suites:**
   * **Nextcloud:** PHP-based enterprise cloud platform implementing WebDAV, CalDAV, and CardDAV. Uses transactional file locking via Redis and relational databases to manage file indexing, desktop synchronization, and external storage mounting.

### Comprehensive SRE Trade-Off Matrix

| System | Architecture Model | State Persistence Backend | Real-Time Transport Mechanism | Horizontal Scaling Vector | Latency Profile | Operational Complexity (1-10) | Primary SRE Use Case |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **Mattermost** | Monolithic Go Service + Stateful Micro-plugins | PostgreSQL / MySQL + S3 | WebSockets + Long-Polling | App: Stateless Horiz. DB: Primary-Replica Cache: Redis | Low (< 50ms) | 4 / 10 | Enterprise ChatOps, Automated Incident Alerting |
| **Matrix (Synapse)**| Federated Server Mesh (Python/Go) | PostgreSQL (Federated DAG state) | HTTP Matrix Matrix Client-Server API / WS | Matrix Federation Mesh + Matrix Workers | Low-Medium (50-200ms) | 8 / 10 | Air-Gapped Federated E2EE Infrastructure |
| **GitLab CE** | Distributed Microservices (Rails + Go/Gitaly) | PostgreSQL + Redis + S3 + Git RPC | WebSockets (ActionCable) + REST/gRPC | Gitaly Nodes + App Stateless Runners | Medium (100-300ms) | 9 / 10 | Enterprise SCM, CI/CD Engine, Issue Tracking |
| **BookStack** | MVC Monolith (PHP/Laravel) | MariaDB / PostgreSQL | HTTP Sync (REST API) | Web Stateless + DB Cluster | Low (Read Cached) | 3 / 10 | Standardized Operational Runbooks & KBs |
| **Nextcloud** | WebDAV Monolith / OCIS Microservices | PostgreSQL / MariaDB + S3 / Local NFS | WebDAV / WebSockets (Notify Push) | PHP App Horizontal + Redis Lock Manager | Medium (WebDAV I/O dependent) | 6 / 10 | Sovereign Enterprise Storage & Sync |

---

## 3. Production-Grade Infrastructure & Kubernetes Manifests

The following production-ready Kubernetes manifest defines a High Availability (HA) Mattermost enterprise deployment. It includes app node deployments, session state caching via Redis, database connectivity to PostgreSQL, ingress routing with explicit WebSocket protocol upgrade configurations, a PodDisruptionBudget, and tight NetworkPolicies.

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: collaboration-system
  labels:
    environment: production
    tier: collaboration
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: mattermost-config
  namespace: collaboration-system
data:
  config.json: |
    {
      "ServiceSettings": {
        "SiteURL": "https://chat.production.internal",
        "ListenAddress": ":8065",
        "WebsocketPort": 8065,
        "EnableDeveloper": false,
        "EnableIncomingWebhooks": true,
        "EnableOutgoingWebhooks": true,
        "EnablePostMetadata": true,
        "GoroutineEventLoopSize": 2048,
        "ReadTimeout": 300,
        "WriteTimeout": 300,
        "IdleTimeout": 60
      },
      "SqlSettings": {
        "DriverName": "postgres",
        "DataSourceReplicas": [
          "postgres://mm_user:SecretDBPass123@postgres-read.database.svc.cluster.local:5432/mattermost?sslmode=require&connect_timeout=10"
        ],
        "MaxIdleConns": 20,
        "MaxOpenConns": 300,
        "ConnMaxLifetimeMilliseconds": 3600000,
        "Trace": false
      },
      "ClusterSettings": {
        "Enable": true,
        "ClusterName": "prod-cluster",
        "OverrideHostname": "",
        "UseIpAddress": false,
        "EnableExperimentalGossipEncryption": true,
        "GossipPort": 8074,
        "StreamingPort": 8075
      },
      "RedisSettings": {
        "Enable": true,
        "Url": "redis://redis-sentinel.collaboration-system.svc.cluster.local:26379",
        "MaxIdle": 50,
        "MaxActive": 500,
        "IdleTimeoutInSeconds": 60
      },
      "FileSettings": {
        "DriverName": "amazons3",
        "AmazonS3AccessKeyId": "AKIAIOSFODNN7EXAMPLE",
        "AmazonS3Bucket": "enterprise-chat-attachments",
        "AmazonS3Region": "us-east-1",
        "AmazonS3Endpoint": "s3.us-east-1.amazonaws.com",
        "AmazonS3SSL": true
      }
    }
---
apiVersion: v1
kind: Secret
metadata:
  name: mattermost-secrets
  namespace: collaboration-system
type: Opaque
stringData:
  MM_SQLSETTINGS_DATASOURCE: "postgres://mm_user:SecretDBPass123@postgres-primary.database.svc.cluster.local:5432/mattermost?sslmode=require&connect_timeout=10"
  MM_REDISSETTINGS_PASSWORD: "ProductionRedisPasswordStrong987!"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mattermost-app
  namespace: collaboration-system
  labels:
    app.kubernetes.io/name: mattermost
    app.kubernetes.io/component: app-server
spec:
  replicas: 3
  selector:
    matchLabels:
      app.kubernetes.io/name: mattermost
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  template:
    metadata:
      labels:
        app.kubernetes.io/name: mattermost
        app.kubernetes.io/component: app-server
    spec:
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              podAffinityTerm:
                labelSelector:
                  matchExpressions:
                    - key: app.kubernetes.io/name
                      operator: In
                      values:
                        - mattermost
                topologyKey: "kubernetes.io/hostname"
      containers:
        - name: mattermost-node
          image: mattermost/mattermost-enterprise-edition:9.5.1
          imagePullPolicy: IfNotPresent
          ports:
            - name: http-ws
              containerPort: 8065
              protocol: TCP
            - name: gossip
              containerPort: 8074
              protocol: TCP
            - name: streaming
              containerPort: 8075
              protocol: TCP
          env:
            - name: MM_SQLSETTINGS_DATASOURCE
              valueFrom:
                secretKeyRef:
                  name: mattermost-secrets
                  key: MM_SQLSETTINGS_DATASOURCE
            - name: MM_REDISSETTINGS_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: mattermost-secrets
                  key: MM_REDISSETTINGS_PASSWORD
          volumeMounts:
            - name: config-volume
              mountPath: /mattermost/config/config.json
              subPath: config.json
          resources:
            requests:
              cpu: "1000m"
              memory: "2Gi"
            limits:
              cpu: "4000m"
              memory: "8Gi"
          readinessProbe:
            httpGet:
              path: /api/v4/system/ping
              port: 8065
            initialDelaySeconds: 15
            periodSeconds: 5
            timeoutSeconds: 3
            failureThreshold: 3
          livenessProbe:
            httpGet:
              path: /api/v4/system/ping
              port: 8065
            initialDelaySeconds: 30
            periodSeconds: 10
            timeoutSeconds: 5
            failureThreshold: 3
      volumes:
        - name: config-volume
          configMap:
            name: mattermost-config
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: mattermost-pdb
  namespace: collaboration-system
spec:
  minAvailable: 2
  selector:
    matchLabels:
      app.kubernetes.io/name: mattermost
---
apiVersion: v1
kind: Service
metadata:
  name: mattermost-service
  namespace: collaboration-system
  labels:
    app.kubernetes.io/name: mattermost
spec:
  type: ClusterIP
  ports:
    - name: http-ws
      port: 8065
      targetPort: 8065
      protocol: TCP
  selector:
    app.kubernetes.io/name: mattermost
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: mattermost-ingress
  namespace: collaboration-system
  annotations:
    kubernetes.io/ingress.class: "nginx"
    nginx.ingress.kubernetes.io/proxy-connect-timeout: "300"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "300"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "300"
    nginx.ingress.kubernetes.io/proxy-body-size: "100M"
    nginx.ingress.kubernetes.io/websocket-services: "mattermost-service"
    nginx.ingress.kubernetes.io/configuration-snippet: |
      proxy_set_header Upgrade $http_upgrade;
      proxy_set_header Connection "upgrade";
      proxy_set_header X-Forwarded-Ssl on;
spec:
  tls:
    - hosts:
        - chat.production.internal
      secretName: chat-tls-certificate
  rules:
    - host: chat.production.internal
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: mattermost-service
                port:
                  number: 8065
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: mattermost-network-policy
  namespace: collaboration-system
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: mattermost
  policyTypes:
    - Ingress
    - Egress
  ingress:
    # Allow traffic from NGINX Ingress Controller
    - from:
        - namespaceSelector:
            matchLabels:
              network.ingress: "true"
      ports:
        - protocol: TCP
          port: 8065
    # Allow gossip/mesh traffic between Mattermost pods in the same namespace
    - from:
        - podSelector:
            matchLabels:
              app.kubernetes.io/name: mattermost
      ports:
        - protocol: TCP
          port: 8074
        - protocol: TCP
          port: 8075
  egress:
    # Allow connection to PostgreSQL database cluster
    - to:
        - namespaceSelector:
            matchLabels:
              name: database
      ports:
        - protocol: TCP
          port: 5432
    # Allow connection to Redis Caching cluster
    - to:
        - podSelector:
            matchLabels:
              app: redis
      ports:
        - protocol: TCP
          port: 26379
        - protocol: TCP
          port: 6379
    # Allow CoreDNS lookups
    - to:
        - namespaceSelector: {}
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - protocol: UDP
          port: 53
```

---

## 4. CLI Operations & Execution Flows

This section contains real-world administrative commands and HTTP REST API execution patterns used to manage enterprise collaboration infrastructure, manage Webhooks, and verify system status.

### 4.1 CLI Administration with `mmctl`

The `mmctl` CLI tool allows operators to interact with Mattermost servers via REST APIs.

```bash
$ mmctl auth login https://chat.production.internal --name prod-cluster --username sre-admin --password 'SuperSecureAdminPass2026!'
Credentials stored for server https://chat.production.internal

$ mmctl system status
[✔] Server Version: 9.5.1
[✔] Database Status: OK (Connections Active: 42, Max: 300)
[✔] Redis Cluster Status: OK (Ping response: PONG)
[✔] License Status: Enterprise Edition (Valid until: 2027-12-31)

$ mmctl team list
+------------------+------------------+------------------+
|        ID        |       Name       |   Display Name   |
+------------------+------------------+------------------+
| 9zk4j18p7fb3...  | incident-ops     | Incident Ops     |
| 3bm2n89a1cc4...  | platform-eng     | Platform Eng     |
+------------------+------------------+------------------+

$ mmctl channel create --team incident-ops --name p0-war-room --display-name "P0 Emergency War Room" --header "Active Outage Diagnostics & ChatOps Channel"
Successfully created channel 'p0-war-room' (ID: q71m5x98p3y1z2a4b5c6d7e8f9)
```

### 4.2 Webhook Management & Diagnostic Webhook Triggering via `curl`

ChatOps engines depend on incoming webhooks. The following commands generate an incoming webhook and execute an authenticated payload submission with structural JSON formatting.

```bash
$ mmctl webhook create-incoming \
  --channel incident-ops:p0-war-room \
  --user sre-bot \
  --display-name "Alertmanager Ingestion Bot" \
  --description "Receives PAGER notifications from Alertmanager Cluster"

URL: https://chat.production.internal/hooks/8f9a2b3c4d5e6f7a8b9c0d1e2f
Id: 8f9a2b3c4d5e6f7a8b9c0d1e2f
Token: tok_9876543210fedcba
Channel Id: q71m5x98p3y1z2a4b5c6d7e8f9
User Id: u1v2w3x4y5z6a7b8c9d0e1f2
Create At: 1770415791000
```

Executing a test HTTP POST against the incoming Webhook API endpoint:

```bash
$ curl -i -X POST \
  -H "Content-Type: application/json" \
  -d '{
    "channel": "p0-war-room",
    "username": "Prometheus-Alertmanager",
    "icon_url": "https://prometheus.io/assets/prometheus_logo.png",
    "attachments": [
      {
        "fallback": "[FIRING:1] HighDatabaseLatency (postgres-primary database/production critical)",
        "color": "#FF0000",
        "title": "🚨 [CRITICAL] High Database Query Latency Exceeded 500ms",
        "title_link": "https://grafana.production.internal/d/pg-perf?orgId=1",
        "fields": [
          {
            "short": true,
            "title": "Severity",
            "value": "P1 - Critical"
          },
          {
            "short": true,
            "title": "Service Impacted",
            "value": "PostgreSQL Primary Node 01"
          },
          {
            "short": false,
            "title": "Alert Details",
            "value": "p99 query execution latency currently at 1240ms. Transaction buffer pool utilization > 94%."
          }
        ],
        "footer": "Kubernetes Alertmanager | Cluster: prod-us-east-1",
        "ts": 1770415820
      }
    ]
  }' \
  https://chat.production.internal/hooks/8f9a2b3c4d5e6f7a8b9c0d1e2f
```

**Output Expected from Server:**

```http
HTTP/2 200 OK
content-type: text/html; charset=utf-8
x-request-id: r8a7f6e5d4c3b2a1
x-version-id: 9.5.1.9.5.1.84759392.plain
date: Thu, 06 Aug 2026 23:30:20 GMT
content-length: 3

ok
```

### 4.3 Low-Level Backend Inspection via `psql` & `redis-cli`

Verifying backend real-time subscription keys and database connection states during high-load events:

```bash
$ kubectl exec -it -n collaboration-system deployment/mattermost-app -- redis-cli -h redis-sentinel -a 'ProductionRedisPasswordStrong987!' PUBSUB CHANNELS
1) "websocket_hub:events"
2) "cluster_events"
3) "user_status_broadcast"

$ kubectl exec -it -n database statefulset/postgres-primary -- psql -U mm_user -d mattermost -c "SELECT count(*), state, query FROM pg_stat_activity WHERE datname='mattermost' GROUP BY state, query;"
 count | state  |                                   query                                    
-------+--------+----------------------------------------------------------------------------
    38 | idle   | 
     4 | active | SELECT * FROM Posts WHERE ChannelId = 'q71m5x98p3y1z2a4b5c6d7e8f9' ORDER BY CreateAt DESC LIMIT 60;
(2 rows)
```

---

## 5. Verification, Diagnostics & Troubleshooting Guide

High-availability communication platforms suffer distinct operational failure modes when subjected to production incidents. The following diagnostic runbook provides structured mitigation procedures.

### SRE Failure Mitigation Matrix

```
                      +----------------------------------+
                      |   Ingress HTTP 502/504 Detected  |
                      +----------------+-----------------+
                                       |
                                       v
                     /-----------------------------------\
                    < Is WebSocket Connection Failing?    >
                     \-----------------------------------/
                               /               \
                       YES    /                 \ NO
                             v                   v
            +------------------------+   +------------------------+
            | Check Ingress Header   |   | Inspect App Readiness  |
            | Settings (Upgrade/Conn)|   | Probes & DB Pool Saturation|
            +------------------------+   +------------------------+
                         |                           |
                         v                           v
            +------------------------+   +------------------------+
            | Verify NGINX Proxy     |   | Query pg_stat_activity |
            | Read/Write Timeouts    |   | Check Redis PubSub     |
            +------------------------+   +------------------------+
```

#### Issue 1: WebSocket Connection Drops & Client Reconnection Storms (`HTTP 504 / WS Code 1006`)
* **Symptom:** Clients repeatedly disconnect, showing "Connecting..." banners. Ingress logs show `504 Gateway Time-out` on `/api/v4/websocket`.
* **Root Cause:** Reverse proxy read/write timeouts are set to standard HTTP defaults (e.g., 60 seconds). Idle WebSockets are severed by the proxy when heartbeat signals fall outside the timeout window.
* **Diagnostic Command:**
  ```bash
  $ kubectl logs -n collaboration-system -l app.kubernetes.io/name=mattermost --tail=100 | grep -E "websocket|timeout|ping"
  ```
* **Remediation:** Ensure ingress annotations explicitly override proxy timeouts to at least 300s (`nginx.ingress.kubernetes.io/proxy-read-timeout: "300"`) and verify `Upgrade` and `Connection` HTTP headers are injected properly in NGINX configuration.

#### Issue 2: PostgreSQL Connection Pool Exhaustion during Alert Bursts
* **Symptom:** Incoming webhooks fail with `HTTP 500 Internal Server Error`. Mattermost logs display `sql: database is closed` or `pq: sorry, too many clients already`.
* **Root Cause:** A sudden spike in incoming webhooks combined with high concurrent user read actions saturates `MaxOpenConns`.
* **Diagnostic Command:**
  ```bash
  $ kubectl exec -it -n database statefulset/postgres-primary -- psql -U mm_user -d mattermost -c "SELECT max_val, current_val FROM (SELECT setting::int AS max_val FROM pg_settings WHERE name='max_connections') a, (SELECT count(*) AS current_val FROM pg_stat_activity) b;"
  ```
* **Remediation:** 
  1. Deploy `PgBouncer` to multiplex client connections.
  2. Increase `MaxOpenConns` in `config.json` while maintaining safe memory thresholds on PostgreSQL.
  3. Configure replica read-scaling (`SqlSettings.DataSourceReplicas`) to offload read queries away from the primary DB.

#### Issue 3: Inbound Webhook Dropped due to HMAC Mismatch or Rate Limiting
* **Symptom:** Third-party CI/CD tools (e.g., GitLab webhooks, GitHub Actions) report `HTTP 403 Forbidden` or `HTTP 429 Too Many Requests`.
* **Diagnostic Command:**
  ```bash
  $ kubectl logs -n collaboration-system -l app.kubernetes.io/name=mattermost | grep -i "webhook rate limit"
  ```
* **Remediation:** Tune the application rate limiter in `config.json`:
  ```json
  "RateLimitSettings": {
    "Enable": true,
    "PerSec": 100,
    "MaxBurst": 200,
    "MemoryStoreSize": 10000,
    "VaryByRemoteAddr": false,
    "VaryByHeader": "X-Forwarded-For"
  }
  ```

### Key Prometheus Alerting Rules for SRE Monitoring

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: collaboration-sre-alerts
  namespace: collaboration-system
spec:
  groups:
    - name: mattermost.rules
      rules:
        - alert: MattermostWebSocketDropSpike
          expr: rate(mattermost_websocket_broadcast_buffer_users_dropped_total[2m]) > 10
          for: 1m
          labels:
            severity: critical
          annotations:
            summary: "High rate of WebSocket message drops detected"
            description: "Mattermost node {{ $labels.pod }} is dropping WebSocket events due to buffer saturation."

        - alert: MattermostDatabaseConnPoolExhausted
          expr: (mattermost_db_open_connections / mattermost_db_max_open_connections) > 0.85
          for: 3m
          labels:
            severity: warning
          annotations:
            summary: "Database connection pool utilization > 85%"
            description: "PostgreSQL pool on {{ $labels.pod }} is near exhaustion. Current utilization: {{ $value | humanizePercentage }}."
```

---

## 6. References & Official Documentation

* **Linux Professional Institute (LPI) Official Site:**
  * LPI Open Source Essentials 050-100 Overview: [https://www.lpi.org/our-certifications/open-source-essentials-overview/](https://www.lpi.org/our-certifications/open-source-essentials-overview/)
  * LPI Learning Resources: [https://learning.lpi.org/](https://learning.lpi.org/)

* **Mattermost Enterprise Architecture & Deployment Guides:**
  * Mattermost Deployment Overview: [https://docs.mattermost.com/deploy/deployment-overview.html](https://docs.mattermost.com/deploy/deployment-overview.html)
  * Mattermost High Availability Configuration: [https://docs.mattermost.com/scale/high-availability-cluster.html](https://docs.mattermost.com/scale/high-availability-cluster.html)
  * Mattermost REST API v4 Reference: [https://api.mattermost.com/](https://api.mattermost.com/)

* **Matrix Protocol Specification & Synapse Architecture:**
  * Matrix Specification: [https://spec.matrix.org/latest/](https://spec.matrix.org/latest/)
  * Synapse System Administrator Guide: [https://matrix-org.github.io/synapse/latest/](https://matrix-org.github.io/synapse/latest/)

* **GitLab Architecture & Scalability Reference:**
  * GitLab Architecture Overview: [https://docs.gitlab.com/ee/development/architecture.html](https://docs.gitlab.com/ee/development/architecture.html)
  * Gitaly Architecture: [https://docs.gitlab.com/ee/administration/gitaly/](https://docs.gitlab.com/ee/administration/gitaly/)

* **Nextcloud Enterprise Architecture:**
  * Nextcloud Server Administration Manual: [https://docs.nextcloud.com/server/latest/admin_manual/](https://docs.nextcloud.com/server/latest/admin_manual/)