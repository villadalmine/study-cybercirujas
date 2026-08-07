# LPI DevOps Tools Engineer (701-100) - Topic 1.1: Modern Software Development

---

## 1. Production Architectural Motivation & Problem Statement

### 1.1 The Legacy Monolithic Bottleneck
In legacy enterprise environments, applications are traditionally constructed as single monolithic codebases where business logic, data access layers, background processing, and web presentation share a single runtime process and memory space. 

```
                                  +-------------------------------------------------------+
                                  |                 MONOLITHIC RUNTIME                    |
                                  |                                                       |
                                  |  +-----------------+  +----------------------------+  |
                                  |  |   UI / Layout   |  |   Auth & User Directory    |  |
                                  |  +-----------------+  +----------------------------+  |
                                  |  |   Order Engine  |  |   Payment Processing       |  |
                                  |  +-----------------+  +----------------------------+  |
                                  |  |   Inventory     |  |   Notification Engine      |  |
                           +----->|  +-----------------+  +----------------------------+  |<-----+
                           |      +-------------------------------------------------------+      |
                           |                                  |                                  |
                           |                                  v                                  |
                           |               +-------------------------------------+               |
                           |               |      SHARED RDBMS (Single SPOF)      |               |
                           |               +-------------------------------------+               |
                           |                                                                     |
                           |                                                                     |
+----------------------------------------------------+               +----------------------------------------------------+
| FAIL-STOP SCENARIO A: Memory Leak                  |               | FAIL-STOP SCENARIO B: Deployment Risk              |
| Payment module leaks heap memory -> OOMKiller      |               | Updating Notification Engine requires redeploying  |
| terminates entire monolith -> Full Outage.         |               | entire 5GB binary -> 15-minute downtime window.    |
+----------------------------------------------------+               +----------------------------------------------------+
```

From an SRE and Platform Engineering perspective, the monolithic model introduces severe operational anti-patterns at scale:

1. **Undifferentiated Blast Radius**: A memory leak (`java.lang.OutOfMemoryError` or unhandled pointer dereference) in a non-critical module (e.g., PDF generation) terminates the operating OS process, taking down critical paths (e.g., Payment Gateway).
2. **Coupled Release Cadence & Queueing Delay**: Merging code requires continuous cross-team coordination. Deployment trains slow down to the rate of the slowest feature branch, increasing lead time for changes ($T_{lead}$) from hours to weeks.
3. **Coarse-Grained Resource Scaling**: Horizontal scaling requires replicating the entire monolith instance across compute nodes. If the order processing module requires high CPU while inventory requires high memory, the platform must provision nodes capable of satisfying both constraints simultaneously, driving up Infrastructure Cost ($OpEx$).
4. **Database Contention & Locks**: Multiple domain teams query and modify a single monolithic relational database schema. High-concurrency operations cause lock contention, thread pool exhaustion, and cascading database connections drops.

---

### 1.2 The Cloud-Native Microservices Paradigm
To resolve monolithic operational debt, modern platform engineering decomposes applications into distributed microservices aligned with Domain-Driven Design (DDD) Bounded Contexts.

```
       +-----------------------------------------------------------------------------------+
       |                               INGRESS EDGE LAYER                                  |
       |                   API Gateway / Layer 7 Ingress Controller                        |
       +-----------------------------------------------------------------------------------+
                                   |                                |
                      +------------+                                +------------+
                      | gRPC / HTTP2                                             | gRPC / HTTP2
                      v                                                          v
       +-------------------------------+                          +-------------------------------+
       |       ORDER MICROSERVICE      |                          |     PAYMENT MICROSERVICE      |
       |  - Language: Go               |                          |  - Language: Rust             |
       |  - Pod Scale: 10 replicas     |                          |  - Pod Scale: 3 replicas      |
       |  - Disposability: < 2s boot   |                          |  - Disposability: < 500ms boot|
       +-------------------------------+                          +-------------------------------+
                      |                                                          |
                      v                                                          v
       +-------------------------------+                          +-------------------------------+
       |  Isolated PostgreSQL Database |                          |    Isolated Redis Cache / DB  |
       +-------------------------------+                          +-------------------------------+
```

The cloud-native architecture decouples state, process lifecycle, and networking:

* **State Isolation**: Each microservice strictly encapsulates its storage engine. Cross-domain queries occur via strongly-typed API contracts (gRPC/Protobuf or OpenAPI REST), preventing shared-database coupling.
* **Fault Isolation**: Compute boundaries are constrained by Linux Kernel primitives (`cgroups v2`, `namespaces`, `seccomp`). A failure in one pod is isolated and automatically mitigated by orchestrators (Kubernetes) via automatic pod restarts.
* **Elasticity & High Availability**: Independent scaling allows targeted allocation of resources. High-throughput services scale out rapidly via Horizontal Pod Autoscalers (HPA) driven by custom metrics (e.g., HTTP request rates or message queue depth).

---

## 2. Technical Architectures & Trade-off Matrices

### 2.1 Monolithic vs. Microservices vs. Serverless Architecture Comparison

| Architectural Attribute | Monolithic Architecture | Microservices Architecture | Serverless / Event-Driven (FaaS) |
| :--- | :--- | :--- | :--- |
| **Deployment Unit** | Single unified archive (`.war`, `.jar`, fat binary) | OCI Compliant Container Images (`.tar` layers) | Functions / Handlers (`.zip`, image runtime) |
| **Process Lifecycle** | Long-running OS process; managed manually or via Systemd | Long-running micro-processes managed by Kubernetes | Ephemeral event-triggered execution (cold start latency) |
| **Data Consistency Model** | Strong Consistency (ACID transactions via RDBMS) | Eventual Consistency (SAGA Pattern, Outbox Pattern) | Eventual Consistency (Async Event Streaming / PubSub) |
| **Failure Mode & Blast Radius** | Global outage upon unhandled runtime exceptions | Contained to microservice boundary; mitigated by retries | Contained per invocation; isolated runtime sandbox |
| **Network Overhead** | In-memory function invocation ($\approx 0\text{ms}$) | RPC/HTTP network calls over CNI ($\approx 1-10\text{ms}$) | Managed Gateway + Cold start execution ($\approx 50-500\text{ms}$) |
| **Observability Complexity** | Low: Standard APM agent attached to single runtime | High: Distributed Tracing (OpenTelemetry), Mesh Telemetry | High: Distributed trace sampling across cloud provider queues |
| **Operational Overhead** | Low platform overhead; High application maintenance cost | High platform overhead (Kubernetes, Service Mesh, CI/CD) | Low platform overhead; High vendor lock-in and tooling lock-in |

---

### 2.2 The Twelve-Factor App Methodology: SRE Audit & Production Enforcement

The 12-Factor App methodology provides systemic rules for building scalable, cloud-native software. Below is the operational breakdown across all 12 factors:

```
+----------------------------------------------------------------------------------------------------+
|                                    12-FACTOR METHODOLOGY AUDIT                                     |
+------------------------------+----------------------------------+----------------------------------+
| Factor                       | Production Anti-Pattern          | Cloud-Native SRE Pattern         |
+------------------------------+----------------------------------+----------------------------------+
| I. Codebase                  | Multiple apps sharing 1 repo or  | One repo tracked in VCS per app; |
|                              | 1 app spread across repos        | multiple deploys via CI/CD tags  |
+------------------------------+----------------------------------+----------------------------------+
| II. Dependencies             | Implicit reliance on system      | Explicitly isolated via OCI      |
|                              | binaries (`curl`, `python3`)     | multi-stage builds (Distroless)  |
+------------------------------+----------------------------------+----------------------------------+
| III. Config                  | Hardcoded values or config files | Config passed via environment    |
|                              | baked inside image/code          | variables or K8s ConfigMaps      |
+------------------------------+----------------------------------+----------------------------------+
| IV. Backing Services         | Treating local DB different from | Local & remote services treated  |
|                              | cloud DB; hardcoded handles      | as attached resources via URIs   |
+------------------------------+----------------------------------+----------------------------------+
| V. Build, Release, Run       | Mutating code directly on prod   | Strict pipeline separation; immutable|
|                              | servers at runtime               | deployment artifacts with IDs    |
+------------------------------+----------------------------------+----------------------------------+
| VI. Processes                | Storing sticky sessions on local | Stateless execution; shared      |
|                              | filesystem memory                | datastores (Redis) for state     |
+------------------------------+----------------------------------+----------------------------------+
| VII. Port Binding            | Exporting HTTP via host web      | App self-contains HTTP server    |
|                              | servers (Apache/Tomcat)          | and binds to `$PORT` environment |
+------------------------------+----------------------------------+----------------------------------+
| VIII. Concurrency            | Scaling via internal OS threads  | Scale out via process model      |
|                              | on a single huge machine         | (Kubernetes Pod replicas)        |
+------------------------------+----------------------------------+----------------------------------+
| IX. Disposability            | Slow boot times; unhandled       | Fast startup times; graceful     |
|                              | SIGKILL; corrupt state on restart| handling of SIGTERM signals      |
+------------------------------+----------------------------------+----------------------------------+
| X. Dev/Prod Parity           | Long divergence between local    | Continuous Deployment; local dev |
|                              | SQLite and prod Postgres DB      | matches prod via Docker Compose  |
+------------------------------+----------------------------------+----------------------------------+
| XI. Logs                     | Writing log files to local disk  | Unbuffered streams to stdout/err;|
|                              | with custom rotation scripts     | captured by Fluentbit/Vector     |
+------------------------------+----------------------------------+----------------------------------+
| XII. Admin Processes         | Running maintenance scripts      | One-off admin tasks executed as  |
|                              | manually on live web app pod     | ephemeral K8s Jobs in same code  |
+------------------------------+----------------------------------+----------------------------------+
```

---

### 2.3 Monorepo vs. Polyrepo Architecture Matrix

| Metric / Dimension | Monorepo Strategy | Polyrepo Strategy |
| :--- | :--- | :--- |
| **Code Visibility & Sharing** | Universal access across teams; simple cross-service refactoring | Strict boundary isolation; shared code distributed via package managers |
| **Version Control Performance** | Requires advanced VCS tooling (Git Sparse-Checkout, Bazel, VFS) | Fast git operations; small repository sizes |
| **Dependency Management** | Atomic commits across multiple microservices; single version of truth | Risk of dependency drift and "dependency hell" across repos |
| **CI/CD Pipeline Execution** | Requires change-detection caching engines (Nx, Turborepo, Bazel) | Simple per-repo pipelines; risk of uncoordinated multi-service deploys |
| **Access Control (RBAC)** | Complex fine-grained directory permissions required | Native repository-level Git permissions |

---

## 3. Production Manifests & Declarative Infrastructure

Below are syntactically valid production manifests demonstrating modern deployment standards for a 12-Factor compliant cloud-native microservice.

### 3.1 Production Multi-Stage `Dockerfile`

```dockerfile
# ==========================================
# STAGE 1: Build & Compilation Environment
# ==========================================
FROM golang:1.22-alpine3.19 AS builder

# Enforce security best practices during build
RUN apk add --no-cache ca-certificates git tzdata \
    && update-ca-certificates

WORKDIR /build

# Copy dependency definitions to optimize layer caching
COPY go.mod go.sum ./
RUN go mod download && go mod verify

# Copy full application source code
COPY . .

# Build static, stripped binary without CGO dependency
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build \
    -ldflags="-w -s -X main.Version=v1.4.2 -X main.BuildTime=$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
    -o /build/orderservice ./cmd/orderservice

# ==========================================
# STAGE 2: Minimal Security Distroless Runtime
# ==========================================
FROM gcr.io/distroless/static-debian12:nonroot

# Copy security artifacts and binaries from builder
COPY --from=builder /usr/share/zoneinfo /usr/share/zoneinfo
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY --from=builder /build/orderservice /app/orderservice

# Enforce non-root security context (UID 65532 is built into distroless:nonroot)
USER 65532:65532

WORKDIR /app

# Expose HTTP service port and Prometheus metrics port
EXPOSE 8080 9090

# Environmental override for 12-factor port binding
ENV PORT=8080 \
    METRICS_PORT=9090 \
    GIN_MODE=release

# Directly execute binary to ensure it receives PID 1 OS signals (SIGTERM)
ENTRYPOINT ["/app/orderservice"]
```

---

### 3.2 Production Kubernetes Deployment Manifest (`deployment.yaml`)

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: order-service
  namespace: production
  labels:
    app.kubernetes.io/name: order-service
    app.kubernetes.io/instance: order-service-prod
    app.kubernetes.io/version: "1.4.2"
    app.kubernetes.io/component: api-backend
    app.kubernetes.io/part-of: e-commerce-platform
    app.kubernetes.io/managed-by: argocd
spec:
  replicas: 3
  revisionHistoryLimit: 10
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 25%
      maxUnavailable: 0
  selector:
    matchLabels:
      app.kubernetes.io/name: order-service
      app.kubernetes.io/instance: order-service-prod
  template:
    metadata:
      labels:
        app.kubernetes.io/name: order-service
        app.kubernetes.io/instance: order-service-prod
        app.kubernetes.io/version: "1.4.2"
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "9090"
        prometheus.io/path: "/metrics"
        checksum/config: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    spec:
      terminationGracePeriodSeconds: 30
      securityContext:
        runAsNonRoot: true
        runAsUser: 65532
        runAsGroup: 65532
        fsGroup: 65532
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: order-service
          image: registry.production.internal/apps/order-service:v1.4.2
          imagePullPolicy: IfNotPresent
          command: ["/app/orderservice"]
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop:
                - ALL
          env:
            - name: PORT
              value: "8080"
            - name: METRICS_PORT
              value: "9090"
            - name: ENVIRONMENT
              value: "production"
            - name: DATABASE_URL
              valueFrom:
                secretKeyRef:
                  name: order-service-db-credentials
                  key: DATABASE_URL
            - name: REDIS_HOST
              valueFrom:
                configMapKeyRef:
                  name: order-service-config
                  key: REDIS_HOST
          ports:
            - name: http
              containerPort: 8080
              protocol: TCP
            - name: metrics
              containerPort: 9090
              protocol: TCP
          resources:
            requests:
              cpu: 250m
              memory: 256Mi
            limits:
              cpu: 1000m
              memory: 512Mi
          startupProbe:
            httpGet:
              path: /healthz/startup
              port: 8080
            initialDelaySeconds: 2
            periodSeconds: 3
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
```

---

### 3.3 Kubernetes Supporting Infrastructure (`config-services.yaml`)

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: order-service-config
  namespace: production
data:
  REDIS_HOST: "redis-cluster.cache.production.internal:6379"
  LOG_LEVEL: "info"
  LOG_FORMAT: "json"
---
apiVersion: v1
kind: Service
metadata:
  name: order-service
  namespace: production
  labels:
    app.kubernetes.io/name: order-service
spec:
  type: ClusterIP
  ports:
    - name: http
      port: 80
      targetPort: http
      protocol: TCP
    - name: metrics
      port: 9090
      targetPort: metrics
      protocol: TCP
  selector:
    app.kubernetes.io/name: order-service
    app.kubernetes.io/instance: order-service-prod
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: order-service-hpa
  namespace: production
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: order-service
  minReplicas: 3
  maxReplicas: 15
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
    - type: Resource
      resource:
        name: memory
        target:
          type: Utilization
          averageUtilization: 80
```

---

## 4. Real-World Terminal Sessions & Execution Outputs

### 4.1 Git Workflows & Trunk-Based Development Verification
SREs rely on clean git histories to ensure auditability during continuous integration.

```bash
$ git status
On branch main
Your branch is up to date with 'origin/main'.

nothing to commit, working tree clean

$ git log --graph --oneline --decorate -n 5
* a7f8b91 (HEAD -> main, tag: v1.4.2, origin/main) feat(order): implement grace period shutdown handler (#402)
* c3d2e1f fix(db): configure connection pool max idle lifetime (#399)
* 9b8a7c6 refactor(api): transition metrics endpoint to OpenTelemetry registry (#395)
* 1e2d3c4 docs(architecture): update 12-factor compliance matrix (#390)
* 5f4e3d2 chore(deps): bump golang.org/x/net from 0.17.0 to 0.23.0 (#388)
```

---

### 4.2 Multi-Stage Docker Image Compilation & Security Audit

Executing container builds cleanly isolates runtime artifacts from compilation dependencies.

```bash
$ docker build -t registry.production.internal/apps/order-service:v1.4.2 .
[+] Building 14.2s (15/15) FINISHED                                              docker:default
 => [internal] load build definition from Dockerfile                                       0.0s
 => => transferring dockerfile: 1.25kB                                                   0.0s
 => [internal] load .dockerignore                                                        0.0s
 => => transferring context: 52B                                                         0.0s
 => [internal] load metadata for gcr.io/distroless/static-debian12:nonroot               0.4s
 => [internal] load metadata for docker.io/library/golang:1.22-alpine3.19                0.6s
 => [builder 1/6] FROM docker.io/library/golang:1.22-alpine3.19@sha256:c0d355...         0.0s
 => [stage-1 1/3] FROM gcr.io/distroless/static-debian12:nonroot@sha256:6e0d0a...       0.0s
 => [internal] load build context                                                        0.8s
 => => transferring context: 4.12MB                                                      0.8s
 => [builder 2/6] RUN apk add --no-cache ca-certificates git tzdata                     1.2s
 => [builder 3/6] WORKDIR /build                                                         0.1s
 => [builder 4/6] COPY go.mod go.sum ./                                                  0.1s
 => [builder 5/6] RUN go mod download && go mod verify                                   3.4s
 => [builder 6/6] RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -ldflags="..."      6.5s
 => [stage-1 2/3] COPY --from=builder /build/orderservice /app/orderservice             0.2s
 => exporting to image                                                                   0.9s
 => => exporting layers                                                                  0.8s
 => => writing image sha256:d8a9f3b1e4c7a6d5c2e1f0b9a8c7d6e5f4a3b2c1                      0.0s
 => => naming to registry.production.internal/apps/order-service:v1.4.2                  0.0s

$ docker images registry.production.internal/apps/order-service:v1.4.2
REPOSITORY                                        TAG       IMAGE ID       CREATED         SIZE
registry.production.internal/apps/order-service   v1.4.2    d8a9f3b1e4c7   2 minutes ago   24.8MB
```

---

### 4.3 Kubernetes Deployment Rollout & Cluster Status

Deploying infrastructure natively to Kubernetes, verifying container startup, and inspecting running pods.

```bash
$ kubectl apply -f deployment.yaml -f config-services.yaml
configmap/order-service-config created
service/order-service created
horizontalpodautoscaler.autoscaling/order-service-hpa created
deployment.apps/order-service created

$ kubectl rollout status deployment/order-service -n production --timeout=60s
Waiting for deployment "order-service" rollout to finish: 1 decision replicas are available...
Waiting for deployment "order-service" rollout to finish: 2 of 3 updated replicas are available...
deployment "order-service" successfully rolled out

$ kubectl get pods -n production -l app.kubernetes.io/name=order-service -o wide
NAME                             READY   STATUS    RESTARTS   AGE   IP           NODE           NOMINATED NODE   READINESS GATES
order-service-6789b7868d-8x4zk   1/1     Running   0          42s   10.244.2.14  k8s-worker-01  <none>           <none>
order-service-6789b7868d-9l7mq   1/1     Running   0          42s   10.244.3.88  k8s-worker-02  <none>           <none>
order-service-6789b7868d-q5p2v   1/1     Running   0          42s   10.244.1.53  k8s-worker-03  <none>           <none>
```

---

### 4.4 API Verification & Production Observability Telemetry

Verifying port-binding, standard output JSON logging, and OpenTelemetry trace propagation headers via `curl`.

```bash
$ curl -i -X POST http://order-service.production.internal/api/v1/orders \
    -H "Content-Type: application/json" \
    -H "traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01" \
    -d '{"customer_id": "usr_99812", "sku": "SKU-4412", "quantity": 2}'

HTTP/1.1 202 Accepted
Date: Fri, 07 Aug 2026 04:35:52 GMT
Content-Type: application/json; charset=utf-8
Content-Length: 134
Connection: keep-alive
X-Correlation-ID: 4bf92f3577b34da6a3ce929d0e0e4736

{"order_id":"ord_8819234","status":"PENDING_PROCESSING","timestamp":"2026-08-07T04:35:52.104Z","trace_id":"4bf92f3577b34da6a3ce929d0e0e4736"}
```

Checking captured `stdout` unbuffered log streams from the target container:

```bash
$ kubectl logs deployment/order-service -n production --tail=1 -c order-service
{"level":"info","ts":"2026-08-07T04:35:52.105Z","logger":"order.api","caller":"v1/order.go:88","msg":"Order processing initiated","trace_id":"4bf92f3577b34da6a3ce929d0e0e4736","span_id":"00f067aa0ba902b7","customer_id":"usr_99812","order_id":"ord_8819234","http_status":202,"latency_ms":1.42}
```

---

## 5. Failure Verification, Diagnostics & Troubleshooting Guide

```
                                  +-------------------------------------------------------+
                                  |            SRE TROUBLESHOOTING FLOWCHART              |
                                  +-------------------------------------------------------+
                                                              |
                                                              v
                                              /-------------------------------\
                                             /     Pod Status / Behavior?      \
                                             \-------------------------------/
                                              /              |              \
                                             /               |               \
                        +-------------------+         +------+------+         +-------------------+
                        |                             |                     |                     |
                        v                             v                     v                     v
              [ CrashLoopBackOff ]           [ Terminated / OOM ]   [ Stale / Unresponsive ]  [ High Latency / 5xx ]
                        |                             |                     |                     |
                        v                             v                     v                     v
              +-------------------+         +-------------------+ +-------------------+ +-------------------+
              | Scenario C:       |         | Scenario A:       | | Scenario A (Alt): | | Scenario B:       |
              | Liveness Probe    |         | Memory Leak /     | | Zombie Process    | | Cascading Failure |
              | Deadlock          |         | cgroup OOMKilled  | | Ignores SIGTERM   | | Timeout / Mesh  |
              +-------------------+         +-------------------+ +-------------------+ +-------------------+
```

---

### Scenario A: Zombie Processes & SIGTERM Signal Swallowing (PID 1 Problem)

#### Diagnostic Hypothesis
The containerized process fails to terminate gracefully within `terminationGracePeriodSeconds` (30s) during a Kubernetes deployment update. Kubelet is forced to issue a ungraceful `SIGKILL` (signal 9), causing dropped in-flight HTTP transactions and database connection corruption.

#### Root Cause Identification
The `Dockerfile` used an shell-form entrypoint (`ENTRYPOINT /app/start.sh` or `CMD ./orderservice`) instead of the exec-form array (`ENTRYPOINT ["/app/orderservice"]`). The shell (`/bin/sh`) executes as PID 1 and does not forward incoming `SIGTERM` signals down to child processes.

#### Verification & Debugging Sequence

Execute `kubectl describe` to verify ungraceful exit code 137 (`128 + 9 (SIGKILL)`):

```bash
$ kubectl describe pod order-service-6789b7868d-8x4zk -n production
...
    State:          Terminated
      Reason:       Error
      Exit Code:    137
      Started:      Fri, 07 Aug 2026 04:00:00 GMT
      Finished:     Fri, 07 Aug 2026 04:30:30 GMT
...
```

Inspect active processes running inside the container environment:

```bash
$ kubectl exec -it order-service-6789b7868d-8x4zk -n production -- ps aux
USER         PID %CPU %MEM    VSZ   RSS TTY      STAT START   TIME COMMAND
root           1  0.0  0.0   4248  1420 ?        Ss   04:00   0:00 /bin/sh /app/start.sh
root           7  0.1  0.8 712404 34120 ?        Sl   04:00   0:02 /app/orderservice
```

*Root Cause Confirmed*: PID 1 is `/bin/sh`, which intercepts signals without forwarding them to `/app/orderservice` (PID 7).

#### Resolution Matrix
1. Convert `Dockerfile` entrypoint to JSON array format:
   ```dockerfile
   # INCORRECT (Shell Form):
   # ENTRYPOINT /app/orderservice

   # CORRECT (Exec Form):
   ENTRYPOINT ["/app/orderservice"]
   ```
2. Implement native OS signal listening within the application code (`os.Notify` in Go, `process.on('SIGTERM')` in Node.js).

---

### Scenario B: Cascading Failures via Missing Circuit Breakers & Connection Pool Exhaustion

#### Diagnostic Hypothesis
A localized downstream database degradation causes thread pool and connection pool exhaustion across all upstream API replicas, triggering cascading HTTP 504 Gateway Timeouts across the entire cluster platform.

#### Root Cause Identification
The application client omits connection timeouts, read timeouts, and circuit breaking patterns. Incoming requests block indefinitely on slow database connections, rapidly consuming memory and thread workers until health check endpoints fail.

#### Verification & Debugging Sequence

Inspect HTTP status codes across the cluster ingress boundaries:

```bash
$ kubectl logs -l app.kubernetes.io/name=ingress-nginx -n ingress-nginx --tail=100 \
  | grep "HTTP/1.1\" 504" | head -n 5
2026-08-07T04:36:10Z [error] 142#142: *991201 upstream timed out (110: Connection timed out) while reading response header from upstream, client: 172.16.0.4, server: api.production.internal, request: "GET /api/v1/orders HTTP/1.1", upstream: "http://10.244.2.14:8080/api/v1/orders"
```

Verify active database connection state inside the microservice container:

```bash
$ kubectl exec -it order-service-6789b7868d-8x4zk -n production -- netstat -an | grep 5432 | wc -l
100
```

All 100 connections in the max pool limit are stuck in `ESTABLISHED` or `WAITING` state without returning data.

#### Resolution Matrix
1. Enforce aggressive network level client timeouts in code:
   ```go
   // Configure HTTP client with strict timeout context
   ctx, cancel := context.WithTimeout(req.Context(), 2*time.Second)
   defer cancel()
   ```
2. Implement Service Mesh (Istio / Linkerd) or application-level Circuit Breaking (e.g., resilience4j / Hystrix pattern):
   ```yaml
   apiVersion: networking.istio.io/v1alpha3
   kind: DestinationRule
   metadata:
     name: order-service-circuit-breaker
     namespace: production
   spec:
     host: order-service
     trafficPolicy:
       connectionPool:
         tcp:
           maxConnections: 100
         http:
           http1MaxPendingRequests: 10
           maxRequestsPerConnection: 10
       outlierDetection:
         consecutive5xxErrors: 3
         interval: 10s
         baseEjectionTime: 30s
   ```

---

### Scenario C: Misconfigured Liveness Probes Causing Infinite Restart Loops (CrashLoopBackOff)

#### Diagnostic Hypothesis
Pods enter a permanent `CrashLoopBackOff` state immediately under heavy load, even though the application process is running correctly.

#### Root Cause Identification
The `livenessProbe` was pointed to a heavy API endpoint (`/healthz/full-check`) that queries the SQL database synchronously. Under load, database latency rises to 3 seconds. The liveness probe timeout (`timeoutSeconds: 2`) expires, causing Kubelet to mistakenly kill healthy pods, worsening cluster overload.

#### Verification & Debugging Sequence

Check pod restart counts and termination history:

```bash
$ kubectl get pods -n production -l app.kubernetes.io/name=order-service
NAME                             READY   STATUS CONF   RESTARTS      AGE
order-service-6789b7868d-8x4zk   0/1     CrashLoopBackOff   12 (2m ago)   14m

$ kubectl get events -n production --field-selector reason=Unhealthy --sort-by='.metadata.creationTimestamp'
LAST SEEN   TYPE      REASON      OBJECT                           MESSAGE
2m12s       Warning   Unhealthy   pod/order-service-6789b7868d-8x4zk  Liveness probe failed: HTTP probe failed with statuscode: 500 / timeout after 2s
```

#### Resolution Matrix
1. Decouple Liveness and Readiness Probe semantics:
   * **Liveness Probe**: Checks *only* internal application process state (is deadlock present?). Do **not** verify external dependencies (DB, Redis) here.
   * **Readiness Probe**: Checks whether the instance can currently accept network traffic (is the DB connected?). If it fails, remove the pod from Service endpoints without killing the process.
2. Update probes to lightweight in-memory endpoints:
   ```yaml
   # CORRECT SEPARATION:
   livenessProbe:
     httpGet:
       path: /healthz/liveness # Returns 200 OK statically from memory
       port: 8080
     timeoutSeconds: 1
     periodSeconds: 10
   readinessProbe:
     httpGet:
       path: /healthz/readiness # Checks DB connectivity pool
       port: 8080
     timeoutSeconds: 2
     periodSeconds: 5
   ```

---

## 6. References

* **Linux Professional Institute (LPI) Official DevOps Certification**: [LPI DevOps Tools Engineer Overview & Objectives](https://www.lpi.org/our-certifications/devops-tools-engineer-overview/)
* **The Twelve-Factor App Methodology**: [Official 12-Factor Specification](https://12factor.net/)
* **Cloud Native Computing Foundation (CNCF)**: [CNCF Trail Map & Cloud-Native Definition](https://www.cncf.io/)
* **Kubernetes Documentation**: [Kubernetes Pod Lifecycle & Probes](https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/)
* **Docker Security & Multi-Stage Best Practices**: [Docker Architecture & Multi-Stage Builds Guide](https://docs.docker.com/build/building/multi-stage/)
* **Google SRE Book**: [Monitoring Distributed Systems & Cascading Failures](https://sre.google/sre-book/table-of-contents/)