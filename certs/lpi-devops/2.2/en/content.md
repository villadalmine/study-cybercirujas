# LPI DevOps Tools Engineer (Exam 701-100, v1.0)
## Topic 2.2: Container Deployment and Orchestration (Weight: 8.33)

---

## 1. Production Motivation & Architectural Problem

### 1.1 The Single-Host Imperative Failure Model
In standalone containerized environments (e.g., executing applications directly via `docker run` on individual Virtual Machines), infrastructure management relies on an imperative lifecycle model. This architecture suffers from foundational operational vulnerabilities when scaled to high-concurrency production environments:

*   **Absence of Automated State Reconciliation:** If a containerized process crashes or encounters an unhandled exception, the host OS daemon may restart the container locally. However, if the underlying physical or virtual host suffers a kernel panic, hardware fault, or network partition, the application state is completely lost without multi-host failover capabilities.
*   **Imperative Port Allocation & Dynamic Binding Collisions:** Single-host deployments require static or semi-static host port mappings (`-p 8080:80`). Running multiple instances of the same service on a single host creates socket binding conflicts unless external, complex dynamic port management logic is implemented.
*   **Static Network Isolation:** Default container bridge networks operate on host-local virtual switches (`docker0`). Multi-host inter-container communication requires static IP routing, custom NAT configurations, or manual SSH tunneling, breaking standard microservice service discovery.
*   **Operational Drift & Manual Scaling:** Horizontal scaling requires imperative execution of deployment commands across disparate target nodes. There is no central control loop auditing whether actual deployed states match defined infrastructure topologies.

### 1.2 Enterprise Requirement: Declarative State Reconciliation
Production-grade container orchestration replaces imperative lifecycle commands with a continuous **Control Loop Engine** (Reconciliation Loop). 

```
                       +-------------------------+
                       |    Desired State        |
                       | (Declarative Manifest)  |
                       +------------+------------+
                                    |
                                    v
+-------------------+      +------------------+      +-------------------+
|  Observed State   | ---> |  Reconciliation  | ---> |   Corrective      |
|  (Current Cluster)|      |  Engine (Diff)   |      |   Action (Control)|
+-------------------+      +------------------+      +-------------------+
          ^                                                    |
          |                                                    v
          +----------------- Actual Infrastructure <-----------+
```

The orchestration system continuously computes the delta $\Delta$ between the **Desired State** $S_{desired}$ (specified via declarative YAML/JSON schemas) and the **Observed State** $S_{observed}$ (polled via node agents):

$$\Delta = S_{desired} \setminus S_{observed}$$

If $\Delta \neq \emptyset$, the orchestration control plane issues low-level mutations to restore equality (e.g., rescheduling pods to healthy worker nodes, spinning up missing replicas, or reconfiguring ingress load balancer targets).

---

## 2. Deep Technical Mechanics & Trade-off Matrix

### 2.1 Architecture Deep Dives

#### Docker Compose
Docker Compose is a client-side, single-host multi-container orchestration utility. 
*   **Mechanics:** Translates a multi-service `docker-compose.yml` manifest into direct Docker Engine API calls via the Unix socket (`/var/run/docker.sock`).
*   **Control Plane:** None. The CLI tool acts as the transient engine. Once resources are created, no persistent external reconciliation loop runs unless invoked via CLI commands like `docker compose up -d`.
*   **Networking:** Automates the creation of host-scoped user-defined bridge networks with embedded DNS resolution by service name.

#### Docker Swarm
Docker Swarm provides native, engine-embedded cluster management with multi-host overlay capabilities.
*   **Control Plane & Consensus:** Uses the **Raft Consensus Algorithm** among an odd number of Manager nodes (recommended 3 or 5) to maintain state consistency. Worker nodes receive tasks via gRPC streams.
*   **Ingress Mesh & Networking:** Utilizes an Ingress Overlay Network leveraging Linux kernel **IPVS** (IP Virtual Server) and **VXLAN** encapsulation (UDP port 4789). Requests to published service ports on *any* Swarm node are routed via the Routing Mesh to healthy tasks across the cluster.
*   **Task Lifecycle:** Service definitions are broken into immutable `Tasks` (containers), scheduled onto worker nodes using internal slot identifiers.

#### Kubernetes (K8s)
Kubernetes is an enterprise-grade, decoupled, distributed container orchestration platform.
*   **Control Plane Topology:** 
    *   `kube-apiserver`: Exposes the REST API; acts as the central hub for all state changes.
    *   `etcd`: Strongly consistent, distributed key-value store maintaining cluster state.
    *   `kube-scheduler`: Assigns unallocated Pods to nodes based on resource constraints, affinity/anti-affinity, and taints/tolerations.
    *   `kube-controller-manager`: Runs core control loops (Deployment, ReplicaSet, Node Controllers).
*   **Node Components:**
    *   `kubelet`: Node agent ensuring containers described in `PodSpecs` are running and healthy.
    *   `kube-proxy` / `eBPF`: Manages network routing rules (iptables or IPVS) to map `Service` virtual IPs to `Pod` endpoints.
    *   `Container Runtime Interface (CRI)`: Abstraction interface interacting with runtimes like `containerd` or `CRI-O`.

### 2.2 Orchestration Trade-off Matrix

| Feature / Dimension | Docker Compose | Docker Swarm | Kubernetes (K8s) |
| :--- | :--- | :--- | :--- |
| **Operational Complexity** | Extremely Low (Zero cluster overhead) | Low (Engine built-in, single command initialization) | High (Requires ETCD management, control plane setup, CNI, CSI) |
| **Consensus Mechanism** | None (Single host daemon) | Built-in Raft (Internal state storage) | External distributed etcd cluster |
| **Scaling Architecture** | Single-host container scaling | Native service replication across nodes | Scalable ReplicaSets, Horizontal Pod Autoscalers (HPA/KEDA) |
| **Networking Model** | Host-local bridge networks | VXLAN-based Overlay with IPVS Routing Mesh | CNI Plugin architecture (Calico, Cilium, Flannel) with Flat Pod IP spaces |
| **Storage Abstraction** | Host Volume Bindings & Named Volumes | Local volumes, Volume Plugins (REX-Ray) | StorageClasses, PersistentVolumes (PV), PersistentVolumeClaims (PVC), CSI |
| **Extensibility** | Minimal (Constrained to Compose spec) | Low (Fixed Docker Engine capabilities) | High (Custom Resource Definitions - CRDs, Operators, Admission Webhooks) |
| **Production Target** | Dev, Staging, Local Integration Testing | Small-to-Medium Multi-Host Deployments | Enterprise Large-Scale Microservices, Cloud-Native Workloads |

---

## 3. Complete Production-Ready Manifests

### 3.1 Production Multi-Container Docker Compose (`docker-compose.yml`)
```yaml
version: '3.8'

services:
  app-server:
    image: redis:7.2-alpine
    container_name: production_cache
    restart: always
    command: ["redis-server", "--appendonly", "yes", "--requirepass", "Secr3tP@ssw0rd!"]
    ports:
      - "127.0.0.1:6379:6379"
    volumes:
      - redis_data:/data
    networks:
      - backend-network
    resources:
      limits:
        cpus: '0.50'
        memory: 512M
      reservations:
        cpus: '0.25'
        memory: 256M
    healthcheck:
      test: ["CMD-SHELL", "redis-cli -a Secr3tP@ssw0rd! ping | grep PONG"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 15s
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"

networks:
  backend-network:
    driver: bridge
    ipam:
      config:
        - subnet: 172.28.0.0/16

volumes:
  redis_data:
    driver: local
```

### 3.2 Production Docker Swarm Stack (`docker-stack.yml`)
```yaml
version: '3.8'

services:
  web-service:
    image: nginx:1.25-alpine
    ports:
      - target: 80
        published: 80
        protocol: tcp
        mode: ingress
    networks:
      - overlay-frontend
    environment:
      - NODE_ENV=production
    deploy:
      mode: replicated
      replicas: 4
      placement:
        constraints:
          - node.role == worker
          - node.labels.tier == frontend
        preferences:
          - spread: node.topology.zone
      update_config:
        parallelism: 2
        delay: 10s
        failure_action: rollback
        monitor: 15s
        max_failure_ratio: 0.15
        order: start-first
      rollback_config:
        parallelism: 1
        delay: 5s
        failure_action: pause
        order: stop-first
      restart_policy:
        condition: on-failure
        delay: 5s
        max_attempts: 3
        window: 120s
      resources:
        limits:
          cpus: '1.00'
          memory: 1024M
        reservations:
          cpus: '0.20'
          memory: 256M
    healthcheck:
      test: ["CMD-SHELL", "wget -q --spider http://localhost:80/ || exit 1"]
      interval: 15s
      timeout: 3s
      retries: 3
      start_period: 10s

networks:
  overlay-frontend:
    driver: overlay
    attachable: false
```

### 3.3 Production Kubernetes Declarative Manifest (`k8s-production-app.yaml`)
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: production-workloads
  labels:
    environment: production
    security-tier: restricted
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-config
  namespace: production-workloads
data:
  LOG_LEVEL: "info"
  HTTP_PORT: "8080"
  ENABLE_METRICS: "true"
---
apiVersion: v1
kind: Secret
metadata:
  name: app-secrets
  namespace: production-workloads
type: Opaque
stringData:
  DB_PASSWORD: "SuperUnbreakableProdSecret2026!"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: core-api-service
  namespace: production-workloads
  labels:
    app.kubernetes.io/name: core-api
    app.kubernetes.io/part-of: e-commerce-platform
    app.kubernetes.io/managed-by: kubectl
spec:
  replicas: 3
  revisionHistoryLimit: 10
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  selector:
    matchLabels:
      app.kubernetes.io/name: core-api
  template:
    metadata:
      labels:
        app.kubernetes.io/name: core-api
        environment: production
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        fsGroup: 10001
        seccompProfile:
          type: RuntimeDefault
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
                        - core-api
                topologyKey: kubernetes.io/hostname
      containers:
        - name: api-container
          image: hashicorp/http-echo:1.0.0
          args:
            - "-text=Core API v1 Running"
            - "-listen=:8080"
          imagePullPolicy: IfNotPresent
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop:
                - ALL
          ports:
            - name: http-port
              containerPort: 8080
              protocol: TCP
          envFrom:
            - configMapRef:
                name: app-config
            - secretRef:
                name: app-secrets
          resources:
            requests:
              cpu: 250m
              memory: 256Mi
            limits:
              cpu: 500m
              memory: 512Mi
          startupProbe:
            httpGet:
              path: /healthz
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 5
            failureThreshold: 10
          livenessProbe:
            httpGet:
              path: /healthz
              port: 8080
            periodSeconds: 10
            timeoutSeconds: 2
            failureThreshold: 3
          readinessProbe:
            httpGet:
              path: /healthz
              port: 8080
            periodSeconds: 5
            timeoutSeconds: 2
            successThreshold: 1
            failureThreshold: 2
---
apiVersion: v1
kind: Service
metadata:
  name: core-api-svc
  namespace: production-workloads
  labels:
    app.kubernetes.io/name: core-api
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: core-api
  ports:
    - name: http
      port: 80
      targetPort: http-port
      protocol: TCP
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: core-api-ingress
  namespace: production-workloads
  annotations:
    kubernetes.io/ingress.class: "nginx"
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    nginx.ingress.kubernetes.io/backend-protocol: "HTTP"
spec:
  rules:
    - host: api.production.internal
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: core-api-svc
                port:
                  name: http
```

---

## 4. Real CLI Commands & Terminal Outputs

### 4.1 Docker Swarm Operations

#### Cluster Initialization and Node Verification
```bash
$ docker swarm init --advertise-addr 192.168.10.10
```
```text
Swarm initialized: current node (m17xz3l899gqkhu1a462pyjtr) is now a manager.

To add a worker to this swarm, run the following command:
    docker swarm join --token SWMTKN-1-49mg50wxn35k21n23z342v0-9vj102148124981 192.168.10.10:2377

To add a manager to this swarm, run 'docker swarm join-token manager' and follow the instructions.
```

```bash
$ docker node ls
```
```text
ID                          HOSTNAME       STATUS    AVAILABILITY   MANAGER STATUS   ENGINE VERSION
m17xz3l899gqkhu1a462pyjtr * node-01-mgr   Ready     Active         Leader           24.0.5
p992ks0219kskcjj1902ks018   node-02-wrk   Ready     Active                          24.0.5
z1029ksj10291029381029311   node-03-wrk   Ready     Active                          24.0.5
```

#### Deploying Stack and Auditing Tasks
```bash
$ docker stack deploy -c docker-stack.yml prod_app
```
```text
Creating network prod_app_overlay-frontend
Creating service prod_app_web-service
```

```bash
$ docker service ls
```
```text
ID             NAME                   MODE         REPLICAS   IMAGE              PORTS
z8219x01829a   prod_app_web-service   replicated   4/4        nginx:1.25-alpine   *:80->80/tcp
```

```bash
$ docker service ps prod_app_web-service
```
```text
ID             NAME                     IMAGE              NODE           DESIRED STATE   CURRENT STATE            ERROR     PORTS
1a2b3c4d5e6f   prod_app_web-service.1   nginx:1.25-alpine   node-02-wrk    Running         Running 2 minutes ago              
7g8h9i0j1k2l   prod_app_web-service.2   nginx:1.25-alpine   node-03-wrk    Running         Running 2 minutes ago              
3m4n5o6p7q8r   prod_app_web-service.3   nginx:1.25-alpine   node-02-wrk    Running         Running 2 minutes ago              
9s0t1u2v3w4x   prod_app_web-service.4   nginx:1.25-alpine   node-03-wrk    Running         Running 2 minutes ago              
```

---

### 4.2 Kubernetes Cluster Administration

#### Applying Manifests and Verifying Deployment State
```bash
$ kubectl apply -f k8s-production-app.yaml
```
```text
namespace/production-workloads created
configmap/app-config created
secret/app-secrets created
deployment.apps/core-api-service created
service/core-api-svc created
ingress.networking.k8s.io/core-api-ingress created
```

```bash
$ kubectl get pods -n production-workloads -o wide
```
```text
NAME                                READY   STATUS    RESTARTS   AGE   IP           NODE          NOMINATED NODE   READINESS GATES
core-api-service-6799659b8d-4k9l1   1/1     Running   0          42s   10.244.1.15   worker-node-1   <none>           <none>
core-api-service-6799659b8d-7x2zp   1/1     Running   0          42s   10.244.2.22   worker-node-2   <none>           <none>
core-api-service-6799659b8d-m8w9q   1/1     Running   0          42s   10.244.3.18   worker-node-3   <none>           <none>
```

#### Rolling Update Lifecycle & Rollout Tracking
```bash
$ kubectl set image deployment/core-api-service api-container=hashicorp/http-echo:1.0.1 -n production-workloads
```
```text
deployment.apps/core-api-service image updated
```

```bash
$ kubectl rollout status deployment/core-api-service -n production-workloads
```
```text
Waiting for deployment "core-api-service" rollout to finish: 1 out of 3 new replicas have been updated...
Waiting for deployment "core-api-service" rollout to finish: 2 out of 3 new replicas have been updated...
Waiting for deployment "core-api-service" rollout to finish: 1 old replicas are pending termination...
deployment "core-api-service" successfully rolled out
```

#### Log Aggregation via Label Selectors
```bash
$ kubectl logs -n production-workloads -l app.kubernetes.io/name=core-api --tail=10
```
```text
[2026-08-07T04:45:30.102Z] "GET /healthz HTTP/1.1" 200 21 "-" "kube-probe/1.28"
[2026-08-07T04:45:32.405Z] "GET /healthz HTTP/1.1" 200 21 "-" "kube-probe/1.28"
[2026-08-07T04:45:35.101Z] "GET /healthz HTTP/1.1" 200 21 "-" "kube-probe/1.28"
[2026-08-07T04:45:37.404Z] "GET /healthz HTTP/1.1" 200 21 "-" "kube-probe/1.28"
```

---

## 5. Verification & Failure Troubleshooting Guide

```
                        +----------------------------------+
                        |  Container/Pod Failure Detected  |
                        +-----------------+----------------+
                                          |
                                          v
                        +----------------------------------+
                        | Exec: kubectl describe pod <pod> |
                        +-----------------+----------------+
                                          |
                  +-----------------------+-----------------------+
                  |                                               |
                  v                                               v
      [ Event: OOMKilled / Crash ]                    [ State: Pending ]
                  |                                               |
        +---------+---------+                           +---------+---------+
        | Exited with Code 137|                           | Resource Quotas |
        +---------+---------+                           | Taints & Tolerations
                  |                                     +---------+---------+
                  v                                               |
    Increase limits in PodSpec                                    v
                                                        Check `kubectl describe node`
```

### 5.1 Diagnostic Matrix: Common Production Failures

#### 1. Pod In `CrashLoopBackOff` (Exit Code 137)
*   **Root Cause:** Container process exceeded memory limit set in Pod spec, triggering the Linux Kernel Out-Of-Memory (OOM) Killer.
*   **Inspection Commands:**
    ```bash
    $ kubectl describe pod core-api-service-6799659b8d-4k9l1 -n production-workloads
    ```
*   **Key Log Output Indicator:**
    ```text
    Last State:     Terminated
      Reason:       OOMKilled
      Exit Code:    137
      Started:      Fri, 07 Aug 2026 04:30:00 -0400
      Finished:     Fri, 07 Aug 2026 04:31:12 -0400
    ```
*   **Remediation:** Increase `resources.limits.memory` in the Deployment spec or identify memory leaks using heap profiles.

#### 2. Pod Stuck In `Pending` State
*   **Root Cause:** Scheduler cannot place the Pod due to insufficient CPU/Memory requests, node taints, or strict PodAntiAffinity rules.
*   **Inspection Commands:**
    ```bash
    $ kubectl get events -n production-workloads --sort-by='.metadata.creationTimestamp'
    ```
*   **Key Log Output Indicator:**
    ```text
    TYPE      REASON             OBJECT                                  MESSAGE
    Warning   FailedScheduling   pod/core-api-service-6799659b8d-9z9z9   0/3 nodes are available: 3 Insufficient memory, 3 node(s) didn't match PodAntiAffinity rules.
    ```
*   **Remediation:** Provision additional worker nodes, decrease `resources.requests`, or adjust affinity rules.

#### 3. Service Connectivity Failure (DNS & CNI Routing)
*   **Root Cause:** CoreDNS resolution failing or CNI plugin dropping packet routes between nodes.
*   **Inspection Workflow:**
    *   Deploy transient network diagnostic container:
        ```bash
        $ kubectl run net-debug --rm -i --tty --image=nicolaka/netshoot -n production-workloads -- bash
        ```
    *   Perform internal DNS lookup and socket test within cluster network namespace:
        ```bash
        # Inside netshoot shell:
        $ nslookup core-api-svc.production-workloads.svc.cluster.local
        $ nc -zvw3 core-api-svc 80
        ```
    *   **Expected Success Response:**
        ```text
        Server:         10.96.0.10
        Address:        10.96.0.10#53

        Name:   core-api-svc.production-workloads.svc.cluster.local
        Address: 10.108.140.91

        Connection to core-api-svc 80 port [tcp/http] succeeded!
        ```

---

## 6. References

*   **Linux Professional Institute (LPI) DevOps Tools Engineer Official Overview:**
    [https://www.lpi.org/our-certifications/devops-tools-engineer-overview/](https://www.lpi.org/our-certifications/devops-tools-engineer-overview/)
*   **Docker Compose File Specification:**
    [https://docs.docker.com/compose/compose-file/](https://docs.docker.com/compose/compose-file/)
*   **Docker Swarm Mode Overview & Architecture:**
    [https://docs.docker.com/engine/swarm/](https://docs.docker.com/engine/swarm/)
*   **Kubernetes Concepts & Production Workloads Documentation:**
    [https://kubernetes.io/docs/concepts/](https://kubernetes.io/docs/concepts/)
*   **Kubernetes Application Debugging Guide:**
    [https://kubernetes.io/docs/tasks/debug/debug-application/](https://kubernetes.io/docs/tasks/debug/debug-application/)