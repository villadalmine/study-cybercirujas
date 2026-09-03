# LPI DevOps Tools Engineer (701-100) - Tema 1.1: Desarrollo de Software Moderno

---

## 1. Motivación Arquitectónica de Producción y Planteamiento del Problema

### 1.1 El Cuello de Botella Monolítico Heredado
En entornos empresariales heredados, las aplicaciones se construyen tradicionalmente como bases de código monolíticas únicas donde la lógica de negocio, las capas de acceso a datos, el procesamiento en segundo plano y la presentación web comparten un único proceso en tiempo de ejecución (runtime process) y espacio de memoria.

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

Desde una perspectiva de SRE y Platform Engineering, el modelo monolítico introduce severos anti-patrones operacionales a escala:

1. **Undifferentiated Blast Radius**: Una fuga de memoria (`java.lang.OutOfMemoryError` o desreferencia de puntero no manejada) en un módulo no crítico (por ejemplo, generación de PDF) termina el proceso del OS en ejecución, derribando rutas críticas (por ejemplo, Payment Gateway).
2. **Coupled Release Cadence & Queueing Delay**: Fusionar código requiere una coordinación continua entre equipos. Los trenes de Deployment se ralentizan al ritmo de la feature branch más lenta, aumentando el lead time de cambios ($T_{lead}$) de horas a semanas.
3. **Coarse-Grained Resource Scaling**: El escalado horizontal requiere replicar la instancia monolítica completa a través de los nodos de cómputo. Si el módulo de procesamiento de órdenes requiere CPU alta mientras que el de inventario requiere memoria alta, la plataforma debe aprovisionar nodos capaces de satisfacer ambas restricciones simultáneamente, elevando el Costo de Infraestructura ($OpEx$).
4. **Database Contention & Locks**: Múltiples equipos de dominio consultan y modifican un único esquema de base de datos relacional monolítico. Las operaciones de alta concurrencia causan contención de bloqueos (lock contention), agotamiento del pool de hilos (thread pool exhaustion) y caídas en cascada de conexiones a la base de datos.

---

### 1.2 El Paradigma de Microservicios Cloud-Native
Para resolver la deuda operacional monolítica, la ingeniería de plataformas moderna descompone las aplicaciones en microservicios distribuidos alineados con los Bounded Contexts de Domain-Driven Design (DDD).

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

La arquitectura cloud-native desacopla el estado, el ciclo de vida del proceso y la conectividad de red:

* **State Isolation**: Cada microservicio encapsula estrictamente su motor de almacenamiento. Las consultas entre dominios ocurren a través de contratos de API fuertemente tipados (gRPC/Protobuf o OpenAPI REST), evitando el acoplamiento de bases de datos compartidas.
* **Fault Isolation**: Los límites de cómputo están restringidos por primitivas del Linux Kernel (`cgroups v2`, `namespaces`, `seccomp`). Un fallo en un Pod es aislado y mitigado automáticamente por orquestadores (Kubernetes) a través de reinicios automáticos de Pod.
* **Elasticity & High Availability**: El escalado independiente permite la asignación dirigida de recursos. Los servicios de alto rendimiento escalan horizontalmente (scale out) rápidamente mediante Horizontal Pod Autoscalers (HPA) impulsados por métricas personalizadas (por ejemplo, tasas de solicitudes HTTP o profundidad de cola de mensajes).

---

## 2. Arquitecturas Técnicas y Matrices de Trade-off

### 2.1 Comparación de Arquitectura Monolítica vs. Microservicios vs. Serverless

| Atributo Arquitectónico | Arquitectura Monolítica | Arquitectura de Microservicios | Serverless / Basada en Eventos (FaaS) |
| :--- | :--- | :--- | :--- |
| **Unidad de Deployment** | Archivo único unificado (`.war`, `.jar`, fat binary) | Imágenes de Contenedor compatibles con OCI (capas `.tar`) | Funciones / Handlers (`.zip`, runtime de imagen) |
| **Ciclo de Vida del Proceso** | Proceso del OS de larga duración; gestionado manualmente o a través de Systemd | Micro-procesos de larga duración gestionados por Kubernetes | Ejecución efímera activada por eventos (latencia de cold start) |
| **Modelo de Consistencia de Datos** | Consistencia Fuerte (transacciones ACID a través de RDBMS) | Consistencia Eventual (Patrón SAGA, Patrón Outbox) | Consistencia Eventual (Event Streaming asíncrono / PubSub) |
| **Modo de Fallo y Blast Radius** | Interrupción global ante excepciones no controladas en tiempo de ejecución | Contenido al límite del microservicio; mitigado por reintentos | Contenido por invocación; sandbox en tiempo de ejecución aislado |
| **Overhead de Red** | Invocación de función en memoria ($\approx 0\text{ms}$) | Llamadas de red RPC/HTTP sobre CNI ($\approx 1-10\text{ms}$) | Gateway Gestionado + Ejecución con cold start ($\approx 50-500\text{ms}$) |
| **Complejidad de Observabilidad** | Baja: Agente APM estándar adjunto a un único runtime | Alta: Distributed Tracing (OpenTelemetry), Telemetría de Mesh | Alta: Muestreo de trazas distribuidas a través de colas del proveedor de nube |
| **Overhead Operacional** | Bajo overhead de plataforma; Alto costo de mantenimiento de aplicación | Alto overhead de plataforma (Kubernetes, Service Mesh, CI/CD) | Bajo overhead de plataforma; Alto vendor lock-in y tooling lock-in |

---

### 2.2 La Metodología Twelve-Factor App: Auditoría SRE y Aplicación en Producción

La metodología 12-Factor App proporciona reglas sistémicas para construir software cloud-native escalable. A continuación se presenta el desglose operacional de los 12 factores:

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

### 2.3 Matriz de Arquitectura Monorepo vs. Polyrepo

| Métrica / Dimensión | Estrategia Monorepo | Estrategia Polyrepo |
| :--- | :--- | :--- |
| **Visibilidad y Compartición de Código** | Acceso universal entre equipos; refactorización entre servicios simple | Aislamiento estricto de límites; código compartido distribuido a través de gestores de paquetes |
| **Rendimiento del Control de Versiones** | Requiere herramientas de VCS avanzadas (Git Sparse-Checkout, Bazel, VFS) | Operaciones de git rápidas; tamaños de repositorio pequeños |
| **Gestión de Dependencias** | Commits atómicos a través de múltiples microservicios; fuente única de la verdad | Riesgo de desviación de dependencias y "dependency hell" a través de repos |
| **Ejecución de Pipelines CI/CD** | Requiere motores de almacenamiento en caché con detección de cambios (Nx, Turborepo, Bazel) | Pipelines simples por repositorio; riesgo de deploys multiservicio no coordinados |
| **Control de Acceso (RBAC)** | Se requieren permisos de directorio de grano fino complejos | Permisos nativos de Git a nivel de repositorio |

---

## 3. Manifiestos de Producción e Infraestructura Declarativa

A continuación se presentan manifiestos de producción sintácticamente válidos que demuestran los estándares modernos de Deployment para un microservicio cloud-native en conformidad con Twelve-Factor.

### 3.1 `Dockerfile` Multi-Stage de Producción

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

### 3.2 Manifiesto de Kubernetes Deployment de Producción (`deployment.yaml`)

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

### 3.3 Infraestructura de Soporte de Kubernetes (`config-services.yaml`)

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

## 4. Sesiones de Terminal del Mundo Real y Salidas de Ejecución

### 4.1 Flujos de Trabajo de Git y Verificación de Trunk-Based Development
Los SREs confían en historiales de git limpios para garantizar la auditabilidad durante la integración continua.

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

### 4.2 Compilación de Imagen Docker Multi-Stage y Auditoría de Seguridad

Ejecutar builds de contenedores aísla de forma limpia los artefactos en tiempo de ejecución de las dependencias de compilación.

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

### 4.3 Rollout de Kubernetes Deployment y Estado del Clúster

Desplegando infraestructura de forma nativa en Kubernetes, verificando el inicio del contenedor e inspeccionando los Pods en ejecución.

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

### 4.4 Verificación de API y Telemetría de Observabilidad en Producción

Verificando el port-binding, el registro JSON en la salida estándar y los encabezados de propagación de trazas de OpenTelemetry mediante `curl`.

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

Comprobando los flujos de logs no almacenados en búfer de la `stdout` capturada del contenedor objetivo:

```bash
$ kubectl logs deployment/order-service -n production --tail=1 -c order-service
{"level":"info","ts":"2026-08-07T04:35:52.105Z","logger":"order.api","caller":"v1/order.go:88","msg":"Order processing initiated","trace_id":"4bf92f3577b34da6a3ce929d0e0e4736","span_id":"00f067aa0ba902b7","customer_id":"usr_99812","order_id":"ord_8819234","http_status":202,"latency_ms":1.42}
```

---

## 5. Verificación de Fallos, Diagnósticos y Guía de Troubleshooting

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

### Escenario A: Procesos Zombi y Absorción de Señales SIGTERM (Problema de PID 1)

#### Hipótesis de Diagnóstico
El proceso en contenedor no logra finalizar de manera elegante (gracefully) dentro de `terminationGracePeriodSeconds` (30s) durante una actualización de Deployment en Kubernetes. Kubelet se ve obligado a emitir un `SIGKILL` abrupto (señal 9), lo que provoca la pérdida de transacciones HTTP en curso y la corrupción de conexiones a la base de datos.

#### Identificación de la Causa Raíz
El `Dockerfile` utilizó un entrypoint en formato shell (`ENTRYPOINT /app/start.sh` o `CMD ./orderservice`) en lugar del arreglo en formato exec (`ENTRYPOINT ["/app/orderservice"]`). La shell (`/bin/sh`) se ejecuta como PID 1 y no reenvía las señales `SIGTERM` entrantes a los procesos hijo.

#### Secuencia de Verificación y Depuración

Ejecute `kubectl describe` para verificar el código de salida abrupto 137 (`128 + 9 (SIGKILL)`):

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

Inspeccione los procesos activos que se ejecutan dentro del entorno del contenedor:

```bash
$ kubectl exec -it order-service-6789b7868d-8x4zk -n production -- ps aux
USER         PID %CPU %MEM    VSZ   RSS TTY      STAT START   TIME COMMAND
root           1  0.0  0.0   4248  1420 ?        Ss   04:00   0:00 /bin/sh /app/start.sh
root           7  0.1  0.8 712404 34120 ?        Sl   04:00   0:02 /app/orderservice
```

*Causa Raíz Confirmada*: PID 1 es `/bin/sh`, el cual intercepta las señales sin reenviarlas a `/app/orderservice` (PID 7).

#### Matriz de Resolución
1. Convertir el entrypoint de `Dockerfile` al formato de arreglo JSON:
   ```dockerfile
   # INCORRECT (Shell Form):
   # ENTRYPOINT /app/orderservice

   # CORRECT (Exec Form):
   ENTRYPOINT ["/app/orderservice"]
   ```
2. Implementar la escucha nativa de señales del OS dentro del código de la aplicación (`os.Notify` en Go, `process.on('SIGTERM')` en Node.js).

---

### Escenario B: Fallos en Cascada por Falta de Circuit Breakers y Agotamiento del Connection Pool

#### Hipótesis de Diagnóstico
Una degradación localizada de la base de datos aguas abajo (downstream) causa el agotamiento del thread pool y connection pool en todas las réplicas de la API aguas arriba (upstream), desencadenando errores en cascada HTTP 504 Gateway Timeout en toda la plataforma del clúster.

#### Identificación de la Causa Raíz
El cliente de la aplicación omite timeouts de conexión, timeouts de lectura y patrones de circuit breaking. Las solicitudes entrantes se bloquean indefinidamente en conexiones lentas de la base de datos, consumiendo rápidamente memoria y thread workers hasta que los endpoints de comprobación de salud (health check) fallan.

#### Secuencia de Verificación y Depuración

Inspeccione los códigos de estado HTTP a través de los límites de Ingress del clúster:

```bash
$ kubectl logs -l app.kubernetes.io/name=ingress-nginx -n ingress-nginx --tail=100 \
  | grep "HTTP/1.1\" 504" | head -n 5
2026-08-07T04:36:10Z [error] 142#142: *991201 upstream timed out (110: Connection timed out) while reading response header from upstream, client: 172.16.0.4, server: api.production.internal, request: "GET /api/v1/orders HTTP/1.1", upstream: "http://10.244.2.14:8080/api/v1/orders"
```

Verifique el estado activo de la conexión a la base de datos dentro del contenedor del microservicio:

```bash
$ kubectl exec -it order-service-6789b7868d-8x4zk -n production -- netstat -an | grep 5432 | wc -l
100
```

Las 100 conexiones en el límite máximo del pool están atascadas en estado `ESTABLISHED` o `WAITING` sin retornar datos.

#### Matriz de Resolución
1. Aplicar timeouts agresivos del cliente a nivel de red en el código:
   ```go
   // Configure HTTP client with strict timeout context
   ctx, cancel := context.WithTimeout(req.Context(), 2*time.Second)
   defer cancel()
   ```
2. Implementar Service Mesh (Istio / Linkerd) o Circuit Breaking a nivel de aplicación (por ejemplo, patrón resilience4j / Hystrix):
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

### Escenario C: Liveness Probes Mal Configurados que Causan Bucles Infinitos de Reinicio (CrashLoopBackOff)

#### Hipótesis de Diagnóstico
Los Pods entran en un estado permanente de `CrashLoopBackOff` inmediatamente bajo carga pesada, a pesar de que el proceso de la aplicación se esté ejecutando correctamente.

#### Identificación de la Causa Raíz
El `livenessProbe` apuntaba a un endpoint pesado de la API (`/healthz/full-check`) que consulta la base de datos SQL de forma sincrónica. Bajo carga, la latencia de la base de datos aumenta a 3 segundos. El timeout del liveness probe (`timeoutSeconds: 2`) expira, lo que provoca que Kubelet elimine erróneamente Pods sanos, empeorando la sobrecarga del clúster.

#### Secuencia de Verificación y Depuración

Verifique los recuentos de reinicio del Pod y el historial de finalización:

```bash
$ kubectl get pods -n production -l app.kubernetes.io/name=order-service
NAME                             READY   STATUS CONF   RESTARTS      AGE
order-service-6789b7868d-8x4zk   0/1     CrashLoopBackOff   12 (2m ago)   14m

$ kubectl get events -n production --field-selector reason=Unhealthy --sort-by='.metadata.creationTimestamp'
LAST SEEN   TYPE      REASON      OBJECT                           MESSAGE
2m12s       Warning   Unhealthy   pod/order-service-6789b7868d-8x4zk  Liveness probe failed: HTTP probe failed with statuscode: 500 / timeout after 2s
```

#### Matriz de Resolución
1. Desacoplar las semánticas de Liveness y Readiness Probe:
   * **Liveness Probe**: Comprueba *únicamente* el estado interno del proceso de la aplicación (¿hay un deadlock presente?). **No** verifique dependencias externas (DB, Redis) aquí.
   * **Readiness Probe**: Comprueba si la instancia puede aceptar tráfico de red en este momento (¿está conectada la DB?). Si falla, remueva el Pod de los endpoints del Service sin matar el proceso.
2. Actualizar los probes a endpoints livianos en memoria:
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

## 6. Referencias

* **Certificación Oficial DevOps de Linux Professional Institute (LPI)**: [LPI DevOps Tools Engineer Overview & Objectives](https://www.lpi.org/our-certifications/devops-tools-engineer-overview/)
* **La Metodología Twelve-Factor App**: [Official 12-Factor Specification](https://12factor.net/)
* **Cloud Native Computing Foundation (CNCF)**: [CNCF Trail Map & Cloud-Native Definition](https://www.cncf.io/)
* **Documentación de Kubernetes**: [Kubernetes Pod Lifecycle & Probes](https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/)
* **Seguridad de Docker y Buenas Prácticas Multi-Stage**: [Docker Architecture & Multi-Stage Builds Guide](https://docs.docker.com/build/building/multi-stage/)
* **Libro SRE de Google**: [Monitoring Distributed Systems & Cascading Failures](https://sre.google/sre-book/table-of-contents/)