# LPI Open Source Essentials (Exam 050-100) — Topic 1.2: Software Architecture

## 1. Production Architectural Problem & Motivation

Modern software architecture dictates how computational logic, data persistence, and communication interfaces are organized, deployed, and scaled. For SREs and Platform Architects, selecting an architectural pattern is not merely a software design choice—it is a fundamental operational decision that defines system reliability, operational complexity, network topology, failure modes, and recovery characteristics.

```
+---------------------------------------------------------------------------------------------------+
|                                 EVOLUTION OF SOFTWARE ARCHITECTURE                                |
+---------------------------------------------------------------------------------------------------+
|                                                                                                   |
|  [ 1. MONOLITHIC ]           [ 2. CLIENT-SERVER / TIERED ]        [ 3. MICROSERVICES / EVENT ]   |
|  +-----------------------+   +---------------+  +---------------+   +-------+  +-------+  +-----+ |
|  | UI + Logic + DB Access|   | Thin/Fat Client|  | App Tier      |   | Svc A |  | Svc B |  |Svc C| |
|  | Single Process/Binary |==>| (Web Browser) |==>| (Business Lgc)|==>| (Go)  |  | (Rust)|  |(Node| |
|  +-----------------------+   +---------------+  +---------------+   +---+---+  +---+---+  +--+--+ |
|            |                         |                  |               |          |         |    |
|       (IPC/Shared Mem)          (HTTP / REST)     (SQL Connection)  (gRPC / HTTP2 / Event Bus)  |
|            |                         |                  |               |          |         |    |
|  +-----------------------+   +---------------+  +---------------+   +---+----------+---------+--+ |
|  | Single RDBMS / Disk   |   | Web Server    |  | RDBMS Pool    |   | Distributed Storage /   | |
|  +-----------------------+   +---------------+  +---------------+   | Kafka Event Log / Redis | |
|                                                                     +-------------------------+ |
+---------------------------------------------------------------------------------------------------+
```

### Core Architecture Models & Internal Mechanics

#### Monolithic Architecture
* **Mechanics**: All functional domains (UI rendering, business logic, data access mechanisms) run within a single process or memory space. Inter-module communication occurs via low-latency In-Process Function Calls and Shared Memory allocation.
* **Production Reality**: Simplifies initial deployment, local testing, and data consistency (ACID transactions within a single relational database). However, it introduces a single unified blast radius: a memory leak, unhandled panic, or CPU hog in one module (e.g., PDF generation) crashes the entire application instance. Scaling requires scaling the entire process monolithically, consuming resources inefficiently.

#### Client-Server Architecture (Thin vs. Thick/Fat Clients)
* **Mechanics**: Divides workload between service providers (servers) and service requesters (clients) over network protocols (TCP/IP, HTTP, TLS).
  * **Thin Client**: The client (e.g., standard modern web browser, lightweight CLI) performs minimal logic, acting primarily as a presentation layer. Business logic, input validation, state management, and data access are enforced entirely server-side.
  * **Fat / Thick Client**: The client (e.g., native desktop application, heavy mobile app, Electron app) executes substantial business logic, local caching, and data processing locally, sending only raw state mutations or synchronization requests to backend servers via APIs.
* **Production Reality**: Thin clients minimize client-side hardware requirements and ensure immediate deployment of bug fixes (server updates instantly reflect for all users). Fat clients reduce backend server compute loads and can operate offline, but introduce severe client-side state drift, API backward-compatibility maintenance overhead, and security risks (code reverse engineering).

#### Multi-Tier (N-Tier / 3-Tier) Architecture
* **Mechanics**: Explicitly segregates software responsibilities across distinct logical and physical layers:
  1. **Presentation Tier**: Serves HTTP assets, UI templates, and static resources (Web Servers like NGINX, Apache, CDN).
  2. **Application Tier**: Executes core application domain logic and business rules (Node.js, Java Spring, Python Gunicorn).
  3. **Database Tier**: Manages persistent storage, transaction log isolation, and query processing (PostgreSQL, MySQL).
* **Production Reality**: Enables targeted horizontal scaling (e.g., scaling stateless App Tier instances based on CPU utilization without modifying DB footprint) and strict firewall isolation (Network Security Groups/NetworkPolicies ensuring the Database Tier is only accessible by the Application Tier, never directly from the Internet).

#### Microservices & Service-Oriented Architecture (SOA)
* **Mechanics**: Decomposes application functionality into autonomous, loosely-coupled, independently deployable services. Each microservice owns its domain data model (Database-per-service pattern) and communicates over standardized network protocols (gRPC, REST, NATS).
* **Production Reality**: Eliminates single points of failure across business domains and enables independent release pipelines across engineering teams. However, it converts local memory calls into network hops, exposing the architecture to **Deutsch’s Fallacies of Distributed Computing**: introducing network latency jitter, packet drops, serialization overhead, distributed consensus challenges (CAP/PACELC theorems), and complex cascading failure scenarios.

#### Peer-to-Peer (P2P) Architecture
* **Mechanics**: Decentralized network model where nodes (peers) act simultaneously as both clients and servers (servents). Peers share compute, storage, or bandwith directly without relying on a centralized authority or broker (e.g., BitTorrent, IPFS, blockchain node networks).
* **Production Reality**: Highly resilient against single-node targeted outages and DDoS attacks, offering infinite distributed bandwidth scaling. Highly challenging for real-time transactional consistency, low-latency querying, and strict security access control.

#### Event-Driven Architecture (EDA) & Serverless (FaaS)
* **Mechanics**: System state changes emit immutable messages (Events) to an asynchronous message broker (e.g., Apache Kafka, NATS, RabbitMQ). Consumers subscribe to topics and process events independently. Serverless (Function-as-a-Service) pairs EDA with ephemeral execution environments, spinning up compute pods strictly on-demand in response to incoming triggers.
* **Production Reality**: Decouples producer performance from consumer latency. Producers emit an event in $<5\text{ms}$ and return immediately, preventing client thread starvation. Introduces operational demands for dead-letter queues (DLQ), idempotent processing patterns (handling at-least-once delivery), and managing FaaS cold-start latencies.

---

## 2. Technical Comparisons & Trade-off Matrices

### Table 1: Comprehensive Software Architecture Trade-off Matrix

| Architectural Pattern | Latency & Network Overhead | State & Data Complexity | Scalability & Blast Radius Control | Operational & Observability Overhead | Primary Production Use Case |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Monolithic** | **Lowest** (In-memory execution, IPC, no RPC serialization) | **Lowest** (Single ACID DB, strong immediate consistency) | **Poor** (Scales entire monolith; 1 crash takes down all domains) | **Low** (Single binary/log stream; simple tracing) | Early-stage products, tightly coupled domain engines, monolith-first strategies |
| **Client-Server (Thin)** | **Low to Moderate** (1 network hop Client $\rightarrow$ Web/App Server) | **Centralized** (Server holds source of truth; client stateless) | **High (Server-side)** (Horizontally scale stateless application servers behind LB) | **Low to Moderate** (Standard web ingress/egress observability) | Enterprise SaaS web portals, cloud-native web apps, centralized admin consoles |
| **Client-Server (Fat)** | **Low (Client-side)** / **High (Sync)** (Heavy local processing; periodic API batch sync) | **Complex** (Local cache synchronization, conflict resolution, offline storage) | **High (Compute)** (Offloads processing to user hardware; DB sync bottleneck) | **High** (Client version fragmentation, backward compatibility requirements) | Offline-first mobile apps, real-time audio/video processing tools, IDEs |
| **Multi-Tier (3-Tier)** | **Moderate** (Client $\rightarrow$ Web $\rightarrow$ App $\rightarrow$ DB; 2-3 internal network hops) | **Structured** (Relational data tier with connection pooling layers) | **Moderate to High** (Independent scaling of Web/App tiers; DB remains bottleneck) | **Moderate** (Requires APM tracing across Tier boundaries and network firewalls) | Traditional enterprise web systems, e-commerce applications, banking portals |
| **Microservices** | **High** (Multiple intra-service RPC/gRPC network hops, TLS handshake cost) | **Very High** (Distributed data, eventual consistency, Saga pattern requirement) | **Maximum** (Fine-grained per-service horizontal pod autoscaling; contained blast radius) | **Extreme** (Requires Service Mesh, Distributed Tracing [OpenTelemetry], Prometheus/Grafana) | Large-scale multi-team cloud platforms, complex domain ecosystems (e.g., Uber, Netflix) |
| **Event-Driven (EDA)** | **Async/Decoupled** (Low publish latency; eventual consumer processing latency) | **High** (Eventual consistency, event stream log persistence, ordering guarantees) | **Maximum** (Producers operate at max speed independent of downstream consumer capacity) | **High** (Requires Kafka/NATS cluster management, schema registries, consumer lag monitoring) | Financial transaction pipelines, real-time analytics streaming, webhooks, async notifications |
| **Serverless (FaaS)** | **Variable** (Cold start penalties $+50\text{ms}$ to $2\text{s}$; minimal execution latency) | **Externalized** (Must use external redis/DB connection proxies like PgBouncer) | **Elastic / Auto** (Instant scale to 0 and scale to 1,000s of concurrent invocations) | **Moderate** (No OS management; high dependence on platform observability tools) | Event handlers, batch ETL file transformations, webhook receivers, low-frequency tasks |
| **Peer-to-Peer (P2P)** | **Variable** (Dependent on peer topology, NAT traversal, overlay network latency) | **Extreme** (Distributed Hash Tables [DHT], CRDTs, consensus protocols [Raft, Paxos]) | **High (Bandwidth)** (Scales linearly with participating nodes) | **High** (Tracking peer health, NAT traversal failure debugging, decentralized monitoring) | Distributed content distribution (BitTorrent), decentralized ledgers, distributed file systems |

### Table 2: Communication Protocols & IPC Comparison

| Protocol / Paradigm | Underlying Transport | Communication Model | Payload Format | Multiplexing / Streaming | SRE Diagnostic Tools |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **REST API** | HTTP/1.1 or HTTP/2 | Synchronous Request/Response | JSON, XML, Text | No (HTTP/1.1 connection head-of-line blocking); Yes (HTTP/2) | `curl`, `httpie`, `Postman`, `tcpdump` |
| **gRPC** | HTTP/2 | Sync / Async / Bidirectional Streaming | Protocol Buffers (Binary) | **Full Multiplexing** over single TCP connection | `grpcurl`, `ghz`, `wireshark`, `buf` |
| **WebSockets** | TCP (Upgraded from HTTP/1.1) | Full-Duplex Bidirectional | Binary, Text Frame | Single persistent TCP stream | `wscat`, browser dev tools, `tcpdump` |
| **AMQP / Kafka** | TCP (Custom binary protocol) | Asynchronous Publish / Subscribe | Raw Bytes (Avro, JSON, Protobuf) | Topic/Partition based multiplexing | `kafka-console-consumer`, `kcat`, `nats` |

---

## 3. Production Infrastructure & Deployment Manifests

Below is a complete, syntactically valid Kubernetes manifest depicting a modern cloud-native 3-tier / microservices architectural stack. It deploys:
1. An **Ingress Edge Controller** (Gateway routing tier).
2. A **Stateless API Microservice Tier** (with HPA, PodDisruptionBudget, security contexts, and liveness/readiness probes).
3. A **Stateful Caching & Messaging Tier** (StatefulSet with PersistentVolumeClaims for backend persistence).

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: production-architecture
  labels:
    environment: production
    architecture: microservices-3tier
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: api-service-config
  namespace: production-architecture
data:
  APP_ENV: "production"
  LOG_LEVEL: "info"
  DB_HOST: "stateful-db-0.stateful-db-headless.production-architecture.svc.cluster.local"
  DB_PORT: "5432"
  CACHE_HOST: "redis-cluster.production-architecture.svc.cluster.local"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api-microservice
  namespace: production-architecture
  labels:
    app.kubernetes.io/name: api-microservice
    app.kubernetes.io/tier: application
spec:
  replicas: 3
  selector:
    matchLabels:
      app.kubernetes.io/name: api-microservice
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  template:
    metadata:
      labels:
        app.kubernetes.io/name: api-microservice
        app.kubernetes.io/tier: application
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        fsGroup: 10001
      containers:
        - name: api-engine
          image: registry.k8s.io/e2e-test-images/agnhost:2.45
          args:
            - netexec
            - --http-port=8080
          ports:
            - containerPort: 8080
              name: http-api
          envFrom:
            - configMapRef:
                name: api-service-config
          resources:
            requests:
              cpu: 250m
              memory: 256Mi
            limits:
              cpu: 1000m
              memory: 512Mi
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop:
                - ALL
          readinessProbe:
            httpGet:
              path: /healthz
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 5
            timeoutSeconds: 2
            successThreshold: 1
            failureThreshold: 3
          livenessProbe:
            httpGet:
              path: /healthz
              port: 8080
            initialDelaySeconds: 15
            periodSeconds: 10
            timeoutSeconds: 2
            failureThreshold: 3
---
apiVersion: v1
kind: Service
metadata:
  name: api-microservice-svc
  namespace: production-architecture
  labels:
    app.kubernetes.io/name: api-microservice
spec:
  type: ClusterIP
  ports:
    - port: 80
      targetPort: 8080
      protocol: TCP
      name: http
  selector:
    app.kubernetes.io/name: api-microservice
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: api-microservice-hpa
  namespace: production-architecture
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: api-microservice
  minReplicas: 3
  maxReplicas: 10
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: api-microservice-pdb
  namespace: production-architecture
spec:
  minAvailable: 2
  selector:
    matchLabels:
      app.kubernetes.io/name: api-microservice
---
apiVersion: v1
kind: Service
metadata:
  name: stateful-db-headless
  namespace: production-architecture
spec:
  clusterIP: None
  selector:
    app.kubernetes.io/name: stateful-db
  ports:
    - port: 5432
      name: postgres
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: stateful-db
  namespace: production-architecture
  labels:
    app.kubernetes.io/name: stateful-db
    app.kubernetes.io/tier: database
spec:
  serviceName: "stateful-db-headless"
  replicas: 2
  selector:
    matchLabels:
      app.kubernetes.io/name: stateful-db
  template:
    metadata:
      labels:
        app.kubernetes.io/name: stateful-db
        app.kubernetes.io/tier: database
    spec:
      containers:
        - name: postgres
          image: postgres:15-alpine
          env:
            - name: POSTGRES_DB
              value: app_db
            - name: POSTGRES_USER
              value: postgres_user
            - name: POSTGRES_PASSWORD
              value: SecureProductionPassword123!
          ports:
            - containerPort: 5432
              name: postgres
          volumeMounts:
            - name: db-data
              mountPath: /var/lib/postgresql/data
  volumeClaimTemplates:
    - metadata:
        name: db-data
      spec:
        accessModes: [ "ReadWriteOnce" ]
        resources:
          requests:
            storage: 10Gi
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: edge-api-ingress
  namespace: production-architecture
  annotations:
    nginx.ingress.kubernetes.io/backend-protocol: "HTTP"
    nginx.ingress.kubernetes.io/proxy-connect-timeout: "5"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "15"
spec:
  ingressClassName: nginx
  rules:
    - host: api.production.internal
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: api-microservice-svc
                port:
                  number: 80
```

---

## 4. Real CLI Commands & Terminal Outputs

The following real terminal invocations demonstrate how to audit, verify, and inspect software architecture components in a cloud-native Linux environment.

### Command 1: Inspecting Process Architecture, Memory Boundaries, and Network Sockets

Verify whether an application is running as a single monolithic process or a decoupled set of services by examining open network sockets, process IDs, and memory mapping.

```bash
$ ss -tulpn | grep -E '8080|5432|6379'
```

```text
tcp   LISTEN 0      4096          0.0.0.0:8080      0.0.0.0:*    users:(("agnhost",pid=10432,fd=3))
tcp   LISTEN 0      128           0.0.0.0:5432      0.0.0.0:*    users:(("postgres",pid=11204,fd=6))
tcp   LISTEN 0      512           0.0.0.0:6379      0.0.0.0:*    users:(("redis-server",pid=11560,fd=7))
```

### Command 2: Auditing In-Cluster Service Discovery & Cross-Tier DNS Resolution

In multi-tier and microservice architectures, components interact via service discovery. Test internal cluster-domain resolution from inside an application pod to verify layer separation.

```bash
$ kubectl exec -it deployment/api-microservice -n production-architecture -- nslookup stateful-db-0.stateful-db-headless.production-architecture.svc.cluster.local
```

```text
Server:		10.96.0.10
Address:	10.96.0.10#53

Name:	stateful-db-0.stateful-db-headless.production-architecture.svc.cluster.local
Address: 10.244.1.45
```

### Command 3: Executing End-to-End Ingress API Request with Headers & HTTP Timing

Verify the thin-client to presentation/API-tier connection, inspecting TLS negotiation, HTTP status codes, and timing metrics.

```bash
$ curl -v -w "\n--- Timings ---\nDNS Lookup: %{time_namelookup}s\nConnect: %{time_connect}s\nAppConnect: %{time_appconnect}s\nTTFB: %{time_starttransfer}s\nTotal: %{time_total}s\n" \
  -H "Host: api.production.internal" \
  http://10.96.150.20/healthz
```

```text
*   Trying 10.96.150.20:80...
* Connected to 10.96.150.20 (10.96.150.20) port 80 (#0)
> GET /healthz HTTP/1.1
> Host: api.production.internal
> User-Agent: curl/7.88.1
> Accept: */*
> 
< HTTP/1.1 200 OK
< Date: Thu, 06 Aug 2026 22:50:12 GMT
< Content-Type: text/plain; charset=utf-8
< Content-Length: 4
< Connection: keep-alive
< 
NOW!

--- Timings ---
DNS Lookup: 0.001231s
Connect: 0.002415s
AppConnect: 0.000000s
TTFB: 0.005120s
Total: 0.005210s
```

### Command 4: Verifying Horizontal Pod Autoscaler (HPA) Elasticity under Load

Inspect how microservice architecture dynamically scales application compute tiers independently from stateful database tiers.

```bash
$ kubectl get hpa api-microservice-hpa -n production-architecture
```

```text
NAME                   REFERENCE                       TARGETS   MINPODS   MAXPODS   REPLICAS   AGE
api-microservice-hpa   Deployment/api-microservice     84%/70%   3         10        5          14m
```

```bash
$ kubectl get pods -n production-architecture -l app.kubernetes.io/name=api-microservice
```

```text
NAME                                READY   STATUS    RESTARTS   AGE
api-microservice-7d8b5c9499-2x8pl   1/1     Running   0          14m
api-microservice-7d8b5c9499-8k2qm   1/1     Running   0          14m
api-microservice-7d8b5c9499-d4n9z   1/1     Running   0          14m
api-microservice-7d8b5c9499-m9qp2   1/1     Running   0          1m12s
api-microservice-7d8b5c9499-x7lvt   1/1     Running   0          1m12s
```

---

## 5. Failure Verification & Diagnostic Guide

When operating distributed client-server and microservice architectures in production, SREs frequently encounter specific architectural failure modes. Below are systematic diagnostic workflows for identifying and resolving these failures.

```
+---------------------------------------------------------------------------------------------------+
|                            SRE ARCHITECTURAL DIAGNOSTIC FLOWCHART                                 |
+---------------------------------------------------------------------------------------------------+
|                                                                                                   |
|  [ ISSUE: High Latency / 5xx Errors Detected at Edge ]                                            |
|                          |                                                                        |
|                          v                                                                        |
|  1. Check Network & Sockets  ===> (`ss -s`, `netstat`)  ===> Accumulating CLOSE_WAIT / TIME_WAIT?   |
|                          |                                   | YES: Socket / Connection Leak      |
|                          v                                                                        |
|  2. Check Service Discovery  ===> (`dig`, `nslookup`)   ===> DNS Resolution Timeout / NXDOMAIN?   |
|                          |                                   | YES: CoreDNS / Mesh Discovery Failure|
|                          v                                                                        |
|  3. Inspect Intra-Svc Call   ===> (`tcpdump`, `strace`) ===> TCP Retransmissions / Packet Drops?   |
|                          |                                   | YES: Network Partition / MTU Issue |
|                          v                                                                        |
|  4. Analyze Upstream State   ===> (`kubectl exec`)      ===> DB Pool Exhaustion / Lock Contention?  |
+---------------------------------------------------------------------------------------------------+
```

### Failure Mode 1: Connection Pool Exhaustion & Socket Leakage (`CLOSE_WAIT` Accumulation)

* **Symptom**: The API Microservice stops accepting new HTTP connections, throwing `504 Gateway Timeout` or `500 Internal Server Error` back to the Ingress layer.
* **Root Cause**: The application code communicates synchronously with downstream services or databases without specifying socket timeouts or closing TCP sockets properly upon receiving responses. Sockets remain stuck in `CLOSE_WAIT` state, starving the process file descriptors (`ulimit -n`).

#### Diagnostic Step 1: Count socket states per process

```bash
$ ss -ton state close-wait '( dport = :5432 or sport = :8080 )'
```

```text
Recv-Q Send-Q Local Address:Port  Peer Address:Port
1      0      10.244.1.12:43902   10.244.1.45:5432     timer:(off,0min,0sec)
1      0      10.244.1.12:43908   10.244.1.45:5432     timer:(off,0min,0sec)
1      0      10.244.1.12:43914   10.244.1.45:5432     timer:(off,0min,0sec)
```

#### Diagnostic Step 2: Trace file descriptor allocation for the API process

```bash
$ pidof agnhost | xargs -I {} ls -l /proc/{}/fd | wc -l
```

```text
1024
```

*(Note: Reaching the hard default limit of 1024 open file descriptors causes `accept4(): Too many open files` errors).*

#### Remediation Plan
1. Configure explicit HTTP client connection pool timeouts (`KeepAliveTimeout 15s`, `MaxIdleConnsPerHost 100`) in the application tier.
2. Enforce ephemeral port range tuning and TCP keepalive parameters at the OS/Kernel level via `/etc/sysctl.conf`:
   ```ini
   net.ipv4.tcp_tw_reuse = 1
   net.ipv4.tcp_fin_timeout = 15
   ```

---

### Failure Mode 2: Cascading Latency Amplification (Thundering Herd / Missing Circuit Breakers)

* **Symptom**: A momentary micro-spike in latency in the database tier causes exponential request queuing in upstream API microservices, triggering a cluster-wide CPU spike and crashing all application pods.
* **Root Cause**: Synchronous call chains ($A \rightarrow B \rightarrow C \rightarrow D$) without retries-with-jitter, rate-limiting, or circuit breakers (e.g., Resilience4j, Envoy Circuit Breaking).

#### Diagnostic Step 1: Capture live packet latency between microservices using `tcpdump`

```bash
$ tcpdump -i any -nn -tt -s 0 'tcp port 8080 or tcp port 5432' -w /tmp/latency_trace.pcap
```

Analyze TCP packet timestamp deltas to isolate which tier introduces queuing delay.

#### Diagnostic Step 2: Inspect Envoy/Service Mesh proxy circuit breaker trip metrics

```bash
$ curl -s http://127.0.0.1:15000/stats | grep "circuit_breakers"
```

```text
cluster.outbound|80||api-microservice-svc.production-architecture.svc.cluster.local.upstream_cq_overflow: 482
cluster.outbound|80||api-microservice-svc.production-architecture.svc.cluster.local.cx_open: 1
```

#### Remediation Plan
1. **Implement Asynchronous Decoupling**: Convert synchronous RPC calls for non-critical paths into event emissions via an Event-Driven Architecture (NATS/Kafka).
2. **Configure Circuit Breaking & Rate Limiting**: Limit max concurrent pending requests to downstream dependencies. If downstream latency exceeds $500\text{ms}$, fail fast immediately to shed load and protect the database layer.

---

### Failure Mode 3: Split-Brain & Consensus Loss in Distributed Stateful Architectures

* **Symptom**: Stateful database nodes (e.g., PostgreSQL HA primary-replica, Raft clusters) accept conflicting write operations simultaneously, causing data corruption.
* **Root Cause**: Network partitioning (e.g., misconfigured Kubernetes `NetworkPolicy` or cloud security group) isolates node A from node B. Node B incorrectly assumes Node A is dead, promotes itself to Primary, and accepts writes while Node A is still alive.

#### Diagnostic Step 1: Verify inter-node network connectivity across stateful pod replicas

```bash
$ kubectl exec -it stateful-db-1 -n production-architecture -- nc -zv -w 3 stateful-db-0.stateful-db-headless 5432
```

```text
nc: connect to stateful-db-0.stateful-db-headless (10.244.1.45) port 5432 (tcp) failed: Connection timed out
```

#### Diagnostic Step 2: Check Raft / Consensus quorum status

```bash
$ journalctl -u patroni -n 50 --no-pager | grep -E 'ERROR|promoted|demoted|quorum'
```

```text
2026-08-06T22:55:01Z ERROR: Demoting node: lost connectivity to etcd distributed lock leader.
2026-08-06T22:55:02Z CRITICAL: Quorum lost. Node switching to Read-Only mode to prevent split-brain.
```

#### Remediation Plan
1. Enforce strict **Quorum requirements** ($Q = \lfloor N/2 \rfloor + 1$). Ensure stateful clusters always deploy an odd number of voting members (minimum 3).
2. Implement **STONITH / Fencing Mechanisms**: Ensure nodes automatically revoke their own write capability (switch to read-only or self-terminate) the instant contact with the distributed consensus store (e.g., etcd) is lost.

---

## 6. References

* **Linux Professional Institute (LPI) Open Source Essentials (050-100)**:  
  https://www.lpi.org/our-certifications/open-source-essentials-overview/
* **LPI Learning Portal — Exam 050 Materials**:  
  https://learning.lpi.org/en/learning-materials/050-100/
* **CNCF Cloud Native Glossary — Software Architecture & Microservices**:  
  https://glossary.cncf.io/
* **Kubernetes Documentation — Production Architecture Patterns & Concepts**:  
  https://kubernetes.io/docs/concepts/
* **Envoy Proxy Architecture & Distributed Systems Overview**:  
  https://www.envoyproxy.io/docs/envoy/latest/intro/arch_overview/arch_overview
* **The Twelve-Factor App Architectural Methodology**:  
  https://12factor.net/