# LPI DevOps Tools Engineer (701-100) — Topic 2.2: Container Deployment and Orchestration

## Official References
* **LPI DevOps Tools Engineer Overview & Objectives**: [https://www.lpi.org/our-certifications/devops-tools-engineer-overview/](https://www.lpi.org/our-certifications/devops-tools-engineer-overview/)
* **Docker Compose Specification**: [https://docs.docker.com/compose/compose-file/](https://docs.docker.com/compose/compose-file/)
* **Kubernetes Workload Management**: [https://kubernetes.io/docs/concepts/workloads/controllers/deployment/](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/)
* **Kubernetes Application Troubleshooting**: [https://kubernetes.io/docs/tasks/debug/debug-application/](https://kubernetes.io/docs/tasks/debug/debug-application/)

---

## Architectural Deep-Dive & Mechanics Overview

Container deployment and orchestration transition standalone containerized runtimes into resilient, self-healing production topologies. Understanding the underlying engine mechanics is essential for high-availability systems architecture.

### Key Architectural Concepts
1. **Container Orchestration Engine Architecture**:
   * **Control Plane State & Consensus**: Engines (such as Kubernetes or Docker Swarm) manage desired state via distributed key-value stores (`etcd` for Kubernetes, embedded Raft for Swarm). Reconciliation loops periodically compare actual runtime state against desired state specs.
   * **Networking & Service Discovery**: Overlay networks (VXLAN, Geneve, or eBPF-routed IPVLAN) assign distinct IPs to scheduling units (Pods/Containers). Internal DNS (CoreDNS) maps logical service identifiers to dynamic endpoints using proxy mechanisms (`kube-proxy`, `iptables`, or eBPF maps).

2. **Scheduling Mechanics & Resource Management**:
   * **Filtering & Scoring**: Schedulers filter nodes based on predicates (resource requests, taints/tolerations, node affinity) and score qualifying nodes to determine optimal placement.
   * **Linux Cgroups & Namespaces**: Resource boundaries (`requests` and `limits`) translate directly to Linux kernel Control Groups (`cgroups v2`). Memory limits configure `memory.max`, triggering the Out-Of-Memory (OOM) Killer (`oom-kill`) when exceeded. CPU limits map to Completely Fair Scheduler (CFS) quotas (`cpu.max`).

3. **Lifecycle Management & Health Probes**:
   * **Probe Types**:
     * `startupProbe`: Delays execution of liveness and readiness checks until the application finishes startup initialization.
     * `livenessProbe`: Determines if the process container needs to be killed and restarted.
     * `readinessProbe`: Determines if traffic should be routed to the container endpoint. Failing readiness removes the IP from Service backends without killing the container.

---

## Block 1: Advanced Multi-Container Orchestration with Docker Compose

This exercise covers building an enterprise-grade multi-container topology using Docker Compose v2. It includes health checks, explicit dependency conditions, network segmentation, and non-root execution.

### Exercise Steps

1. Create a workspace directory and define a multi-container stack configuration named `docker-compose.yml`:

```bash
mkdir -p ~/lpi-701-lab/compose-stack && cd ~/lpi-701-lab/compose-stack
cat <<'EOF' > docker-compose.yml
name: enterprise-app

services:
  redis-db:
    image: redis:7.2-alpine
    container_name: production-redis
    command: ["redis-server", "--appendonly", "yes", "--requirepass", "SecureVaultPass2026!"]
    user: "999:999"
    healthcheck:
      test: ["CMD-SHELL", "redis-cli -a SecureVaultPass2026! ping | grep PONG"]
      interval: 5s
      timeout: 3s
      retries: 5
      start_period: 5s
    volumes:
      - redis-data:/data
    networks:
      - backend-net
    deploy:
      resources:
        limits:
          cpus: '0.50'
          memory: 256M
        reservations:
          cpus: '0.10'
          memory: 64M
    restart: unless-stopped

  api-service:
    image: nginx:1.25-alpine
    container_name: production-api
    depends_on:
      redis-db:
        condition: service_healthy
    ports:
      - "8080:80"
    networks:
      - frontend-net
      - backend-net
    healthcheck:
      test: ["CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://localhost:80/"]
      interval: 10s
      timeout: 3s
      retries: 3
      start_period: 5s
    deploy:
      resources:
        limits:
          cpus: '0.25'
          memory: 128M
    restart: always

networks:
  frontend-net:
    driver: bridge
    internal: false
  backend-net:
    driver: bridge
    internal: true

volumes:
  redis-data:
    driver: local
EOF
```

2. Validate syntax and initiate the multi-container stack in detached mode:

```bash
docker compose config
docker compose up -d
```

*Expected Output:*
```text
[+] Running 3/3
 ✔ Network enterprise-app_frontend-net  Created                                                   0.1s
 ✔ Network enterprise-app_backend-net   Created                                                   0.1s
 ✔ Volume "enterprise-app_redis-data"   Created                                                   0.0s
 [+] Running 2/2
 ✔ Container production-redis           Healthy                                                   5.2s
 ✔ Container production-api             Started                                                   5.3s
```

3. Inspect the health state and resource consumption of running containers:

```bash
docker compose ps
docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}"
```

*Expected Output:*
```text
NAME               IMAGE              COMMAND                  SERVICE      CREATED          STATUS                    PORTS
production-api     nginx:1.25-alpine  "/docker-entrypoint.…"   api-service  15 seconds ago   Up 10 seconds (healthy)   0.0.0.0:8080->80/tcp
production-redis   redis:7.2-alpine   "docker-entrypoint.s…"   redis-db     15 seconds ago   Up 10 seconds (healthy)   6379/tcp

NAME               CPU %               MEM USAGE / LIMIT   MEM %
production-api     0.01%               3.12MiB / 128MiB    2.44%
production-redis   0.15%               8.45MiB / 256MiB    3.30%
```

4. Verify network isolation by attempting to access `production-redis` from an external ephemeral container attached only to `frontend-net`:

```bash
docker run --rm --network enterprise-app_frontend-net alpine ping -c 2 production-redis
```

*Expected Output:*
```text
ping: bad address 'production-redis'
```

---

### Verification Questions — Block 1

**Question 1.1**: What specific architectural guarantee does `condition: service_healthy` provide under `depends_on` compared to standard container startup ordering?

**Question 1.2**: Why is `backend-net` configured with `internal: true`, and what happens at the Linux network namespace/iptables layer when this flag is enabled?

---

## Block 2: Production Workload Orchestration with Kubernetes Manifests

This exercise covers orchestrating high-availability stateful and stateless workloads on Kubernetes. You will create zero-downtime rolling updates, resource enforcement policies, custom health probes, dynamic config management, and service routing.

### Exercise Steps

1. Create a workspace directory for Kubernetes manifest development:

```bash
mkdir -p ~/lpi-701-lab/k8s-manifests && cd ~/lpi-701-lab/k8s-manifests
```

2. Create a fully specified `ConfigMap` and `Secret` for application dynamic parameters:

```bash
cat <<'EOF' > 01-config-secret.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-config
  namespace: default
  labels:
    app.kubernetes.io/name: web-app
    app.kubernetes.io/part-of: e-commerce
data:
  APP_ENV: "production"
  LOG_LEVEL: "info"
  MAX_CONNECTIONS: "5000"
---
apiVersion: v1
kind: Secret
metadata:
  name: app-db-credentials
  namespace: default
  labels:
    app.kubernetes.io/name: web-app
type: Opaque
stringData:
  DB_USER: "pg_admin"
  DB_PASS: "SuperComplexP@ssw0rd2026!"
EOF
kubectl apply -f 01-config-secret.yaml
```

*Expected Output:*
```text
configmap/app-config created
secret/app-db-credentials created
```

3. Deploy a production-grade `Deployment` manifest featuring explicit probes, resource limits, rolling update strategy, and security contexts:

```bash
cat <<'EOF' > 02-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web-app-deployment
  namespace: default
  labels:
    app.kubernetes.io/name: web-app
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
      app: web-app
  template:
    metadata:
      labels:
        app: web-app
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 101
        runAsGroup: 101
        fsGroup: 101
      containers:
        - name: web-container
          image: nginxinc/nginx-unprivileged:1.25-alpine
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 8080
              protocol: TCP
          envFrom:
            - configMapRef:
                name: app-config
          env:
            - name: DATABASE_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: app-db-credentials
                  key: DB_PASS
          resources:
            requests:
              cpu: "100m"
              memory: "64Mi"
            limits:
              cpu: "250m"
              memory: "128Mi"
          startupProbe:
            httpGet:
              path: /
              port: 8080
            initialDelaySeconds: 2
            periodSeconds: 3
            failureThreshold: 10
          livenessProbe:
            httpGet:
              path: /
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 10
            timeoutSeconds: 2
            failureThreshold: 3
          readinessProbe:
            httpGet:
              path: /
              port: 8080
            initialDelaySeconds: 2
            periodSeconds: 5
            timeoutSeconds: 2
            successThreshold: 1
            failureThreshold: 2
EOF
kubectl apply -f 02-deployment.yaml
```

*Expected Output:*
```text
deployment.apps/web-app-deployment created
```

4. Expose the deployment using a `ClusterIP` Service with endpoint session affinity:

```bash
cat <<'EOF' > 03-service.yaml
apiVersion: v1
kind: Service
metadata:
  name: web-app-service
  namespace: default
  labels:
    app.kubernetes.io/name: web-app
spec:
  type: ClusterIP
  sessionAffinity: ClientIP
  sessionAffinityConfig:
    clientIP:
      timeoutSeconds: 10800
  ports:
    - name: http
      port: 80
      targetPort: 8080
      protocol: TCP
  selector:
    app: web-app
EOF
kubectl apply -f 03-service.yaml
```

*Expected Output:*
```text
service/web-app-service created
```

5. Verify rollout status and inspect generated Endpoints:

```bash
kubectl rollout status deployment/web-app-deployment
kubectl get endpoints web-app-service
```

*Expected Output:*
```text
deployment "web-app-deployment" successfully rolled out
NAME              ENDPOINTS                                               AGE
web-app-service   10.244.0.15:8080,10.244.0.16:8080,10.244.1.12:8080       12s
```

6. Perform a zero-downtime rolling update by updating the container image:

```bash
kubectl set image deployment/web-app-deployment web-container=nginxinc/nginx-unprivileged:1.26-alpine --record
kubectl rollout status deployment/web-app-deployment
```

*Expected Output:*
```text
deployment.apps/web-app-deployment image updated
Waiting for deployment "web-app-deployment" rollout to finish: 1 old replicas are pending termination...
Waiting for deployment "web-app-deployment" rollout to finish: 1 of 3 updated replicas are available...
Waiting for deployment "web-app-deployment" rollout to finish: 2 of 3 updated replicas are available...
deployment "web-app-deployment" successfully rolled out
```

---

### Verification Questions — Block 2

**Question 2.1**: With `maxSurge: 1` and `maxUnavailable: 0` configured for a 3-replica Deployment, how many total Pods will be running during an active rolling update, and what benefit does `maxUnavailable: 0` offer production systems?

**Question 2.2**: If a Pod container exceeds its CPU limit (`250m`), what action does the Linux kernel take? How does this compare to when a Pod container exceeds its Memory limit (`128Mi`)?

---

## Block 3: Advanced Diagnostic Techniques & Troubleshooting Workflows

This section focuses on diagnosing production container anomalies, including CrashLoopBackOff states, probe failures, network issues, and low-level container runtime errors.

### Exercise Steps

1. Simulate a crashing deployment due to a broken liveness probe path and inspect the resulting state:

```bash
kubectl patch deployment web-app-deployment --patch '
spec:
  template:
    spec:
      containers:
      - name: web-container
        livenessProbe:
          httpGet:
            path: /non-existent-health-check
            port: 8080
'
```

2. Monitor pod state and query event streams to identify the root cause:

```bash
kubectl get pods -l app=web-app
kubectl get events --field-selector reason=Unhealthy --sort-by='.metadata.creationTimestamp'
```

*Expected Output:*
```text
NAME                                  READY   STATUS    RESTARTS      AGE
web-app-deployment-789456bc-x9z12     1/1     Running   2 (20s ago)   1m
web-app-deployment-789456bc-y8w34     1/1     Running   1 (35s ago)   1m
web-app-deployment-789456bc-z7v56     1/1     Running   1 (35s ago)   1m

LAST SEEN   TYPE      REASON      OBJECT                                  MESSAGE
12s         Warning   Unhealthy   pod/web-app-deployment-789456bc-x9z12   Liveness probe failed: HTTP probe failed with statuscode: 404
```

3. Roll back the deployment revision to restore operational health:

```bash
kubectl rollout history deployment/web-app-deployment
kubectl rollout undo deployment/web-app-deployment
kubectl rollout status deployment/web-app-deployment
```

*Expected Output:*
```text
deployment.apps/web-app-deployment 
REVISION  CHANGE-CAUSE
1         <none>
2         kubectl set image deployment/web-app-deployment web-container=nginxinc/nginx-unprivileged:1.26-alpine --record
3         <none>

rollback revision 2 has been rolled back to revision 2
deployment "web-app-deployment" successfully rolled out
```

4. Perform low-level container runtime debugging. Attach an ephemeral debug container to inspect network namespaces and process lists inside a running distroless/hardened Pod:

```bash
TARGET_POD=$(kubectl get pods -l app=web-app -o jsonpath='{.items[0].metadata.name}')
kubectl debug -it ${TARGET_POD} --image=nicolaka/netshoot --target=web-container -- sh
```

Inside the debug shell, execute:

```bash
netstat -tulpn
ps aux
exit
```

*Expected Output:*
```text
Targeting container "web-container". If you don't see processes from this container it may be because the container runtime doesn't support sharesProcessNamespace.
/ # netstat -tulpn
Active Internet connections (only servers)
Proto Recv-Q Send-Q Local Address           Foreign Address         State       PID/Program name    
tcp        0      0 0.0.0.0:8080            0.0.0.0:*               LISTEN      1/nginx: master proc
/ # ps aux
PID   USER     TIME  COMMAND
    1 101       0:00 nginx: master process nginx -g daemon off;
    7 101       0:00 nginx: worker process
   15 root      0:00 sh
/ # exit
```

5. Inspect low-level host node container processes using `crictl` and `cgroups` (run on node control plane/worker node):

```bash
# Obtain Container ID from crictl
crictl ps --name web-container --state Running -q | head -n 1

# Read cgroup v2 memory limits directly from the kernel filesystem
CONTAINER_PID=$(crictl inspect --output json $(crictl ps --name web-container -q | head -n 1) | jq '.info.pid')
cat /proc/${CONTAINER_PID}/root/etc/os-release
cat /sys/fs/cgroup/system.slice/docker-${CONTAINER_ID}.scope/memory.max 2>/dev/null || cat /proc/${CONTAINER_PID}/cgroup
```

---

### Verification Questions — Block 3

**Question 3.1**: What is the key diagnostic difference between `kubectl logs <pod-name>` and `kubectl describe pod <pod-name>` when investigating a container in `CrashLoopBackOff` status?

**Question 3.2**: How does attaching an ephemeral debug container via `kubectl debug --target=<container-name>` allow network and process inspection even if the target application container does not include a shell or utilities (e.g., distroless image)?

---

## Solutions & Answer Explanations

<details>
<summary>Click here to expand solutions for all verification questions</summary>

### Block 1 Answers

* **Answer 1.1**:
  Standard `depends_on` only checks container creation/execution start (`service_started`). It does not guarantee that the application inside the container is ready to accept socket connections. 
  By specifying `condition: service_healthy`, Docker Compose postpones starting dependent containers (`api-service`) until the target container's (`redis-db`) designated `healthcheck` command executes successfully and exits with code `0`. This prevents connection-refused boot-loop cascades across microservices.

* **Answer 1.2**:
  Setting `internal: true` creates a isolated bridge network without a default gateway interface to the host or external internet. 
  At the Linux kernel level, Docker creates a custom bridge device (e.g., `br-xxxxx`) and configures `iptables` / `nftables` rules in the `FORWARD` chain. Specifically, it drops packets originating from containers on this bridge destined for external subnets or non-connected interfaces, allowing communication **only** between containers attached to that specific network.

---

### Block 2 Answers

* **Answer 2.1**:
  With `replicas: 3`, `maxSurge: 1`, and `maxUnavailable: 0`:
  * During a rolling update, Kubernetes can scale up to **4 Pods** (`replicas + maxSurge` = 3 + 1).
  * Setting `maxUnavailable: 0` ensures that Kubernetes **never** terminates an existing Pod until a newly created Pod passes its `readinessProbe` and enters the `Ready` state.
  * This guarantees that 100% of baseline traffic capacity (3 healthy Pods) is continuously available throughout the deployment process, eliminating capacity drops during updates.

* **Answer 2.2**:
  * **CPU Limit Exceeded**: CPU is a compressible resource. When a container exceeds its CFS quota (`cpu.max` in cgroups v2), the Linux kernel CFS scheduler **throttles** the container's CPU usage by freezing its execution threads for the remainder of the period enforcement slice. The process is not terminated.
  * **Memory Limit Exceeded**: Memory is an incompressible resource. When a container attempts to allocate memory beyond its configured limit (`memory.max` in cgroups v2), the Linux kernel OOM Killer selects the highest-consuming process within that cgroup and terminates it with signal `SIGKILL` (exit code `137`). Kubernetes detects this exit event and marks the Pod state as `OOMKilled`.

---

### Block 3 Answers

* **Answer 3.1**:
  * `kubectl logs`: Reads stdout and stderr streams emitted by the container process. It is useful for diagnosing application stack traces, unhandled exceptions, and logic errors. Adding `-p` (`--previous`) retrieves logs from the *prior* terminated instance of a restarting container.
  * `kubectl describe pod`: Queries the Kubernetes API server for Pod metadata, condition flags, status history, container restart counts, and lifecycle **Events**. It reveals infrastructure-level failures such as probe failures (e.g., HTTP 404/500, timeouts), OOMKill termination codes, image pull failures (`ErrImagePull`), and scheduling constraints.

* **Answer 3.2**:
  The `kubectl debug --target=<container-name>` command creates an Ephemeral Container within the existing Pod's Linux kernel namespaces. 
  By specifying `--target`, the API server configures the debug container to join the target container's **Process ID (PID) namespace** and share its **Network namespace**. This allows tools in the debug container (such as `netstat`, `tcpdump`, or `ps`) to inspect open sockets, interfaces, and running processes of the target container without modifying its filesystem or requiring installed binaries in the target image.

</details>