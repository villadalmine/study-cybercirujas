# 702.2 Container Orchestration — Guided Exercises

**Certification:** LPI DevOps Tools Engineer — Exam 701-100, version 2.0.0
**Topic weight:** 5
**Official objectives:** <https://www.lpi.org/our-certifications/exam-701-objectives/>

These exercises are hands-on. Every command is meant to be typed, and every output block is what you should expect to see (IDs, IPs and timestamps will differ). The questions after each block are not rhetorical — answer them before moving on. Full answers are in the collapsible section at the end.

---

## 0. Environment preparation

You need a single Linux host with Docker Engine 25+ (Compose V2 plugin included) and access to a Kubernetes cluster (kind, minikube, k3s or a real cluster) plus `kubectl` and `helm` 3.

```bash
docker version --format '{{.Server.Version}}'
docker compose version
kubectl version --client -o yaml | head -5
helm version --short
```

Expected shape:

```
27.3.1
Docker Compose version v2.29.7
clientVersion:
  buildDate: "2024-11-13T..."
  gitVersion: v1.31.3
v3.16.2+g13f07e7
```

Create a working directory:

```bash
mkdir -p ~/lab-702.2/{compose,swarm,k8s,chart} && cd ~/lab-702.2
```

---

## Exercise 1 — Declarative local orchestration with Compose

**Goal:** describe a multi-service application declaratively, express *ordering* through health, and discover where single-host Compose stops being an orchestrator.

### Block 1.1 — Write the application model

1. Create `~/lab-702.2/compose/compose.yaml`:

```yaml
name: shop

services:
  cache:
    image: redis:7-alpine
    command: ["redis-server", "--save", "60", "1", "--loglevel", "warning"]
    volumes:
      - cache-data:/data
    networks:
      - backend
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 5s
      timeout: 3s
      retries: 5
      start_period: 5s

  seed:
    image: redis:7-alpine
    command: ["redis-cli", "-h", "cache", "set", "greeting", "hello-from-compose"]
    networks:
      - backend
    depends_on:
      cache:
        condition: service_healthy
    restart: "no"

  web:
    image: nginxdemos/hello:plain-text
    ports:
      - "8080:80"
    networks:
      - backend
      - frontend
    depends_on:
      seed:
        condition: service_completed_successfully
    healthcheck:
      test: ["CMD-SHELL", "wget -q -O /dev/null http://localhost/ || exit 1"]
      interval: 10s
      timeout: 3s
      retries: 3

networks:
  frontend:
  backend:
    internal: true

volumes:
  cache-data:
```

2. Render the *effective* model the engine will act on — this is the file after interpolation, extends and profile resolution:

```bash
cd ~/lab-702.2/compose
docker compose config | head -30
```

3. Bring the stack up and watch the dependency chain resolve:

```bash
docker compose up -d
```

```
[+] Running 6/6
 ✔ Network shop_backend   Created                                 0.1s
 ✔ Network shop_frontend  Created                                 0.1s
 ✔ Volume "shop_cache-data" Created                               0.0s
 ✔ Container shop-cache-1  Healthy                                6.2s
 ✔ Container shop-seed-1   Exited                                 7.0s
 ✔ Container shop-web-1    Started                                7.2s
```

4. Inspect the result and prove the seed actually ran:

```bash
docker compose ps -a
docker compose exec cache redis-cli get greeting
```

```
NAME           IMAGE                          COMMAND                  SERVICE  STATUS                     PORTS
shop-cache-1   redis:7-alpine                 "docker-entrypoint.s…"   cache    Up 40s (healthy)           6379/tcp
shop-seed-1    redis:7-alpine                 "docker-entrypoint.s…"   seed     Exited (0) 35s ago
shop-web-1     nginxdemos/hello:plain-text    "/docker-entrypoint.…"   web      Up 34s (healthy)           0.0.0.0:8080->80/tcp
"hello-from-compose"
```

> **Q1.1** — `depends_on` in its short form (`depends_on: [cache]`) is described in Docker's own documentation as insufficient for real applications. What exactly does the short form guarantee, and what does `condition: service_healthy` add?
>
> **Q1.2** — The `backend` network is declared `internal: true`. What concrete traffic does that block, and what does it *not* block? Why can `web` still be reached on port 8080?
>
> **Q1.3** — `seed` is declared `restart: "no"`. What would happen to the whole stack's convergence if you had written `restart: always` on a one-shot container that exits 0?
>
> **Q1.4** — Why does the compose project prefix everything with `shop_` / `shop-`, and which key controls it? What breaks if two engineers run this file from directories with different names and *without* the `name:` key?

### Block 1.2 — Scale, and hit the wall

5. Try to run three copies of `web`:

```bash
docker compose up -d --scale web=3
```

```
[+] Running 3/3
 ✔ Container shop-web-1  Running                                  0.0s
 ⠿ Container shop-web-2  Starting                                 0.3s
 ⠿ Container shop-web-3  Starting                                 0.3s
Error response from daemon: driver failed programming external connectivity on
endpoint shop-web-2: Bind for 0.0.0.0:8080 failed: port is already allocated
```

6. Fix the model so it can scale, by publishing a *range* instead of a fixed host port. Edit the `web` service:

```yaml
    ports:
      - "8080-8090:80"
```

7. Re-apply and verify:

```bash
docker compose up -d --scale web=3
docker compose ps --format '{{.Name}}\t{{.Ports}}'
```

```
shop-cache-1    6379/tcp
shop-web-1      0.0.0.0:8080->80/tcp
shop-web-2      0.0.0.0:8081->80/tcp
shop-web-3      0.0.0.0:8082->80/tcp
```

8. Confirm each replica is a distinct backend:

```bash
for p in 8080 8081 8082; do curl -s localhost:$p | grep 'Server address'; done
```

```
Server address: 172.19.0.4:80
Server address: 172.19.0.5:80
Server address: 172.19.0.6:80
```

9. Now test service discovery *inside* the network:

```bash
docker compose exec cache sh -c 'for i in 1 2 3 4; do getent hosts web; done'
```

```
172.19.0.4      web
172.19.0.5      web
172.19.0.6      web
172.19.0.4      web
```

> **Q1.5** — Step 5 failed. State precisely why, and explain why this failure is a *property of the orchestration model*, not a Compose bug.
>
> **Q1.6** — After step 9, is Compose load balancing your traffic? Explain the mechanism behind the varying answers from `getent hosts web`, and name two production failure modes of relying on it.
>
> **Q1.7** — You add `deploy: {replicas: 3}` to `web` in the same file. Which of these keys does `docker compose up` honour, and which are silently ignored: `deploy.replicas`, `deploy.resources.limits`, `deploy.placement.constraints`, `deploy.update_config`?

10. Tear down, keeping the volume, then check what survived:

```bash
docker compose down
docker volume ls --filter name=shop
```

```
DRIVER    VOLUME NAME
local     shop_cache-data
```

> **Q1.8** — `docker compose down` removed containers and networks but not the volume. Which flag removes named volumes, and why is that flag *not* the default?

---

## Exercise 2 — From Compose file to cluster: Swarm services, VIPs and the routing mesh

**Goal:** deploy the same declarative model to a scheduler that owns desired state, and understand ingress vs. host publishing, VIP vs. DNSRR discovery.

### Block 2.1 — Initialise the cluster and deploy a stack

1. Initialise Swarm mode on this host:

```bash
docker swarm init --advertise-addr $(hostname -I | awk '{print $1}')
```

```
Swarm initialized: current node (kx9c1r2m4v8n0tqz3l7wpsy6a) is now a manager.

To add a worker to this swarm, run the following command:
    docker swarm join --token SWMTKN-1-3n8...q1w 192.168.178.42:2377
```

2. Inspect the node and the networks Swarm created for itself:

```bash
docker node ls
docker network ls --filter driver=overlay
```

```
ID                            HOSTNAME   STATUS    AVAILABILITY   MANAGER STATUS   ENGINE VERSION
kx9c1r2m4v8n0tqz3l7wpsy6a *   node-01    Ready     Active         Leader           27.3.1

NETWORK ID     NAME              DRIVER    SCOPE
b1e0f4c9a233   ingress           overlay   swarm
```

3. Write `~/lab-702.2/swarm/stack.yaml`:

```yaml
services:
  api:
    image: nginxdemos/hello:plain-text
    networks:
      - appnet
    ports:
      - target: 80
        published: 8080
        protocol: tcp
        mode: ingress
    healthcheck:
      test: ["CMD-SHELL", "wget -q -O /dev/null http://localhost/ || exit 1"]
      interval: 10s
      timeout: 3s
      retries: 3
      start_period: 5s
    deploy:
      replicas: 3
      endpoint_mode: vip
      restart_policy:
        condition: on-failure
        delay: 5s
        max_attempts: 3
        window: 60s
      update_config:
        parallelism: 1
        delay: 10s
        order: start-first
        failure_action: rollback
        monitor: 20s
        max_failure_ratio: 0
      rollback_config:
        parallelism: 0
        order: stop-first
      resources:
        limits:
          cpus: "0.50"
          memory: 128M
        reservations:
          cpus: "0.05"
          memory: 32M
      placement:
        max_replicas_per_node: 3
        constraints:
          - "node.platform.os == linux"

  toolbox:
    image: busybox:1.36
    command: ["sleep", "infinity"]
    networks:
      - appnet
    deploy:
      replicas: 1

networks:
  appnet:
    driver: overlay
    attachable: false
```

4. Deploy it:

```bash
cd ~/lab-702.2/swarm
docker stack deploy -c stack.yaml shop --detach=false
```

```
Creating network shop_appnet
Creating service shop_api
Creating service shop_toolbox

Service shop_api: converged
Service shop_toolbox: converged
```

5. Inspect what the scheduler actually created:

```bash
docker stack services shop
docker service ps shop_api --format 'table {{.Name}}\t{{.Node}}\t{{.DesiredState}}\t{{.CurrentState}}'
```

```
ID             NAME           MODE         REPLICAS   IMAGE                          PORTS
7f3q2m1x0abc   shop_api       replicated   3/3        nginxdemos/hello:plain-text    *:8080->80/tcp
9c1v8n2t5def   shop_toolbox   replicated   1/1        busybox:1.36

NAME           NODE      DESIRED STATE   CURRENT STATE
shop_api.1     node-01   Running         Running 45 seconds ago
shop_api.2     node-01   Running         Running 45 seconds ago
shop_api.3     node-01   Running         Running 44 seconds ago
```

> **Q2.1** — Compare `docker compose up` and `docker stack deploy`. Where does *desired state* live in each case, and what happens in each if you `kill -9` a container's main process?
>
> **Q2.2** — The stack file has no `depends_on` and no `restart:` key, but it does have `deploy.restart_policy`. What does `docker stack deploy` do with `build:`, `depends_on:` and `restart:` if you leave them in, and why is that architecturally unavoidable?
>
> **Q2.3** — `shop_appnet` was created automatically with driver `overlay`. What does the overlay driver do that a bridge network cannot, and which port(s) must be open between nodes for it to work?

### Block 2.2 — Service discovery: VIP, DNSRR and `tasks.<service>`

6. From the toolbox container, resolve the service name:

```bash
TASK=$(docker ps -qf name=shop_toolbox)
docker exec -it $TASK nslookup api
```

```
Server:    127.0.0.11
Address:   127.0.0.11:53

Name:      api
Address 1: 10.0.1.2
```

7. Now resolve the special `tasks.` form:

```bash
docker exec -it $TASK nslookup tasks.api
```

```
Name:      tasks.api
Address 1: 10.0.1.3
Address 2: 10.0.1.4
Address 3: 10.0.1.5
```

8. Confirm 10.0.1.2 is a virtual IP, not a container:

```bash
docker service inspect shop_api \
  --format '{{range .Endpoint.VirtualIPs}}{{.NetworkID}} => {{.Addr}}{{"\n"}}{{end}}'
docker exec -it $TASK sh -c 'for i in 1 2 3 4 5 6; do wget -qO- http://api/ | grep "Server address"; done'
```

```
b1e0f4c9a233 => 10.0.0.9/24
d7a3e8f01b55 => 10.0.1.2/24

Server address: 10.0.1.3:80
Server address: 10.0.1.4:80
Server address: 10.0.1.5:80
Server address: 10.0.1.3:80
Server address: 10.0.1.4:80
Server address: 10.0.1.5:80
```

9. Exercise the routing mesh from the host:

```bash
for i in 1 2 3 4; do curl -s localhost:8080 | grep 'Server address'; done
```

```
Server address: 10.0.1.3:80
Server address: 10.0.1.4:80
Server address: 10.0.1.5:80
Server address: 10.0.1.3:80
```

> **Q2.4** — `nslookup api` returns exactly one address and `nslookup tasks.api` returns three. Explain the two discovery modes behind this, and how the single VIP still spreads traffic over three tasks.
>
> **Q2.5** — You change `endpoint_mode: vip` to `dnsrr` and redeploy. What changes in step 6's output, what breaks in the `ports:` section, and for which class of client is `dnsrr` the *wrong* choice?
>
> **Q2.6** — In step 9 you curl `localhost:8080` on a node. If this were a 5-node cluster with 3 replicas all scheduled on other nodes, would `curl` on a replica-less node still work? Name the mechanism and the network it uses.
>
> **Q2.7** — Change `mode: ingress` to `mode: host` in the `ports:` block. Describe precisely what you gain and what you lose, and what now limits your replica count per node.

---

## Exercise 3 — Rolling updates, automated rollback and drain

**Goal:** drive a controlled update, force it to fail, and observe the scheduler repair itself according to declared policy.

### Block 3.1 — A healthy rolling update

1. Watch the update happen live (open a second terminal):

```bash
watch -n1 "docker service ps shop_api --filter desired-state=running \
  --format 'table {{.Name}}\t{{.Image}}\t{{.CurrentState}}'"
```

2. In the first terminal, roll to a different image tag:

```bash
docker service update --image nginxdemos/hello:plain-text shop_api --detach=false
```

```
shop_api
overall progress: 3 out of 3 tasks
1/3: running   [==================================================>]
2/3: running   [==================================================>]
3/3: running   [==================================================>]
verify: Service shop_api converged
```

3. Read the recorded update state:

```bash
docker service inspect shop_api --format '{{json .UpdateStatus}}' | python3 -m json.tool
```

```json
{
    "State": "completed",
    "StartedAt": "2026-09-03T10:12:41.882Z",
    "CompletedAt": "2026-09-03T10:13:09.117Z",
    "Message": "update completed"
}
```

> **Q3.1** — Your `update_config` declares `parallelism: 1`, `order: start-first`, `delay: 10s`. Walk through the exact sequence for 3 replicas. How would `order: stop-first` change the availability profile, and when is `stop-first` mandatory?
>
> **Q3.2** — `monitor: 20s` and `max_failure_ratio: 0` are set. What is Swarm measuring during those 20 seconds, and what is the role of the container `healthcheck` in that decision?

### Block 3.2 — Force a failure and let the policy repair it

4. Update to an image tag that cannot be pulled:

```bash
docker service update --image nginxdemos/hello:this-tag-does-not-exist shop_api --detach=false
```

```
image nginxdemos/hello:this-tag-does-not-exist could not be accessed on a registry
to record its digest. Each node will access the image independently, possibly
leading to different nodes running different versions of the image.

shop_api
overall progress: rolling back update: 0 out of 3 tasks
...
service rolled back: rolled back to previous version
```

5. Inspect the failed task and the recorded rollback:

```bash
docker service ps shop_api --no-trunc --format 'table {{.Name}}\t{{.CurrentState}}\t{{.Error}}' | head -5
docker service inspect shop_api --format '{{json .UpdateStatus}}' | python3 -m json.tool
```

```
NAME             CURRENT STATE            ERROR
shop_api.1       Running 4 minutes ago
 \_ shop_api.1   Rejected 30 seconds ago  "No such image: nginxdemos/hello:this-tag-does-not-exist"
```

```json
{
    "State": "rollback_completed",
    "StartedAt": "2026-09-03T10:18:02.441Z",
    "CompletedAt": "2026-09-03T10:18:31.902Z",
    "Message": "rollback completed"
}
```

6. Scale, then simulate a node going away for maintenance:

```bash
docker service scale shop_api=5 --detach=false
docker node update --availability drain node-01
docker service ps shop_api --format 'table {{.Name}}\t{{.DesiredState}}\t{{.CurrentState}}' | head -4
docker node update --availability active node-01
```

7. Manually roll back to the previous service spec at any time:

```bash
docker service rollback shop_api --detach=false
```

> **Q3.3** — In step 4 the task state is `Rejected`, not `Failed`. What is the difference in the Swarm task state machine, and which component produced each state?
>
> **Q3.4** — `failure_action: rollback` saved you here. What exactly is "the previous version" that Swarm rolls back to — the previous image tag, or something broader? Where is it stored?
>
> **Q3.5** — Docker warned "could not be accessed on a registry to record its digest". Why does Swarm resolve tags to digests by default, and what production incident does that prevent? Which flag disables it?
>
> **Q3.6** — After `docker node update --availability drain`, what happens to running tasks on that node versus `--availability pause`? Which one do you use before a kernel upgrade?

8. Clean up before the Kubernetes exercises:

```bash
docker stack rm shop
docker swarm leave --force
```

---

## Exercise 4 — Kubernetes: Deployment, Service, and a controlled rollout

**Goal:** express the same workload against the Kubernetes API, and understand ReplicaSet-based rollouts, probe-gated readiness, and configuration drift.

### Block 4.1 — Apply the manifests

1. Create `~/lab-702.2/k8s/app.yaml`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: shop
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: shop-web-config
  namespace: shop
data:
  default.conf: |
    server {
        listen 8080;
        server_name _;
        default_type text/plain;

        location /healthz {
            access_log off;
            return 200 "ok\n";
        }

        location / {
            return 200 "shop release v1\n";
        }
    }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: shop-web
  namespace: shop
  labels:
    app.kubernetes.io/name: shop-web
spec:
  replicas: 4
  revisionHistoryLimit: 5
  minReadySeconds: 5
  progressDeadlineSeconds: 120
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  selector:
    matchLabels:
      app.kubernetes.io/name: shop-web
  template:
    metadata:
      labels:
        app.kubernetes.io/name: shop-web
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 101
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: nginx
          image: nginxinc/nginx-unprivileged:1.27-alpine
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 8080
              protocol: TCP
          readinessProbe:
            httpGet:
              path: /healthz
              port: http
            initialDelaySeconds: 2
            periodSeconds: 5
            timeoutSeconds: 2
            failureThreshold: 3
          livenessProbe:
            httpGet:
              path: /healthz
              port: http
            initialDelaySeconds: 10
            periodSeconds: 10
            timeoutSeconds: 2
            failureThreshold: 3
          resources:
            requests:
              cpu: 25m
              memory: 32Mi
            limits:
              memory: 64Mi
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - name: conf
              mountPath: /etc/nginx/conf.d
              readOnly: true
            - name: cache
              mountPath: /var/cache/nginx
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: conf
          configMap:
            name: shop-web-config
        - name: cache
          emptyDir: {}
        - name: tmp
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: shop-web
  namespace: shop
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: shop-web
  ports:
    - name: http
      port: 80
      targetPort: http
      protocol: TCP
---
apiVersion: v1
kind: Service
metadata:
  name: shop-web-headless
  namespace: shop
spec:
  clusterIP: None
  selector:
    app.kubernetes.io/name: shop-web
  ports:
    - name: http
      port: 80
      targetPort: http
      protocol: TCP
```

2. Validate against the API server *without* applying, then apply:

```bash
cd ~/lab-702.2/k8s
kubectl apply -f app.yaml --dry-run=server
kubectl apply -f app.yaml
```

```
namespace/shop created
configmap/shop-web-config created
deployment.apps/shop-web created
service/shop-web created
service/shop-web-headless created
```

3. Observe the controller chain:

```bash
kubectl -n shop get deploy,rs,pod -o wide
```

```
NAME                       READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/shop-web   4/4     4            4           35s

NAME                                  DESIRED   CURRENT   READY   AGE
replicaset.apps/shop-web-6c8f9d5b74   4         4         4       35s

NAME                            READY   STATUS    RESTARTS   AGE   IP           NODE
pod/shop-web-6c8f9d5b74-2xk4t   1/1     Running   0          35s   10.244.1.7   worker-1
pod/shop-web-6c8f9d5b74-8vqzp   1/1     Running   0          35s   10.244.2.4   worker-2
pod/shop-web-6c8f9d5b74-jr9mn   1/1     Running   0          35s   10.244.1.8   worker-1
pod/shop-web-6c8f9d5b74-w7t2c   1/1     Running   0          35s   10.244.2.5   worker-2
```

4. Verify the Service actually selected those Pods:

```bash
kubectl -n shop get endpointslices -l kubernetes.io/service-name=shop-web \
  -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]}{" ready="}{.conditions.ready}{"\n"}{end}'
```

```
10.244.1.7 ready=true
10.244.2.4 ready=true
10.244.1.8 ready=true
10.244.2.5 ready=true
```

5. Test discovery and load balancing from inside the cluster:

```bash
kubectl -n shop run curl --rm -it --restart=Never \
  --image=curlimages/curl:8.10.1 -- \
  sh -c 'for i in 1 2 3; do curl -s http://shop-web.shop.svc.cluster.local/; done'
```

```
shop release v1
shop release v1
shop release v1
pod "curl" deleted
```

6. Compare the two Services' DNS answers:

```bash
kubectl -n shop run dns --rm -it --restart=Never --image=busybox:1.36 -- \
  sh -c 'nslookup shop-web; echo ---; nslookup shop-web-headless'
```

```
Name:      shop-web.shop.svc.cluster.local
Address 1: 10.96.184.22
---
Name:      shop-web-headless.shop.svc.cluster.local
Address 1: 10.244.1.7
Address 2: 10.244.2.4
Address 3: 10.244.1.8
Address 4: 10.244.2.5
```

> **Q4.1** — Map the three-level ownership chain Deployment → ReplicaSet → Pod. Which object holds the rollout history, and what would `kubectl delete rs shop-web-6c8f9d5b74` do?
>
> **Q4.2** — `spec.selector.matchLabels` and `spec.template.metadata.labels` are identical here. What happens if you `kubectl apply` a change to `spec.selector` on an existing Deployment, and why?
>
> **Q4.3** — Step 6 is the Kubernetes analogue of Exercise 2's `api` vs `tasks.api`. Match each Kubernetes construct to its Swarm counterpart and explain the one behavioural difference in how the load balancing is implemented on the node.
>
> **Q4.4** — The Service listens on `port: 80` with `targetPort: http`. Why is naming the port and referencing it by name better practice than `targetPort: 8080`?
>
> **Q4.5** — The container sets `readOnlyRootFilesystem: true` and yet nginx starts. Which two `emptyDir` volumes make that possible, and what would the Pod event log show if you removed them?
>
> **Q4.6** — There is a memory `limit` but deliberately no CPU `limit`. Justify this choice in terms of what the kernel does when each limit is exceeded.

### Block 4.2 — Rolling update and the ConfigMap trap

7. Trigger a rollout by changing the image, and record the change cause:

```bash
kubectl -n shop set image deployment/shop-web nginx=nginxinc/nginx-unprivileged:1.27-alpine \
  --record=false
kubectl -n shop annotate deployment/shop-web \
  kubernetes.io/change-cause="bump nginx to 1.27-alpine" --overwrite
kubectl -n shop rollout status deployment/shop-web --timeout=180s
```

```
Waiting for deployment "shop-web" rollout to finish: 1 out of 4 new replicas have been updated...
Waiting for deployment "shop-web" rollout to finish: 3 of 4 updated replicas are available...
deployment "shop-web" successfully rolled out
```

8. Now change *only* the ConfigMap and observe what happens:

```bash
kubectl -n shop patch configmap shop-web-config --type merge -p \
  '{"data":{"default.conf":"server {\n  listen 8080;\n  default_type text/plain;\n  location /healthz { access_log off; return 200 \"ok\\n\"; }\n  location / { return 200 \"shop release v2\\n\"; }\n}\n"}}'

kubectl -n shop rollout status deployment/shop-web --timeout=30s
kubectl -n shop get pods -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.startTime}{"\n"}{end}'
```

```
deployment "shop-web" successfully rolled out
shop-web-6c8f9d5b74-2xk4t 2026-09-03T11:02:11Z
shop-web-6c8f9d5b74-8vqzp 2026-09-03T11:02:11Z
...
```

9. Check what the running container serves:

```bash
kubectl -n shop run curl --rm -it --restart=Never --image=curlimages/curl:8.10.1 -- \
  curl -s http://shop-web/
```

```
shop release v1
```

10. Force the config to take effect:

```bash
kubectl -n shop rollout restart deployment/shop-web
kubectl -n shop rollout status deployment/shop-web
kubectl -n shop run curl --rm -it --restart=Never --image=curlimages/curl:8.10.1 -- \
  curl -s http://shop-web/
```

```
shop release v2
```

11. Inspect and undo:

```bash
kubectl -n shop rollout history deployment/shop-web
kubectl -n shop rollout undo deployment/shop-web --to-revision=1
kubectl -n shop rollout status deployment/shop-web
```

> **Q4.7** — In step 8 `rollout status` reported success but nothing was restarted, and step 9 still served v1. Explain both halves: why the Deployment considered itself rolled out, and why the container kept the old config even though projected ConfigMap volumes are refreshed by the kubelet.
>
> **Q4.8** — `kubectl rollout restart` does not "restart" anything in place. What field does it actually mutate, and what makes that a *rolling* operation rather than a mass kill?
>
> **Q4.9** — With `maxSurge: 1` and `maxUnavailable: 0` on 4 replicas, what is the minimum and maximum number of Pods in existence during the rollout, and what capacity assumption does this settings pair make about your cluster?
>
> **Q4.10** — `minReadySeconds: 5` and `progressDeadlineSeconds: 120` are set. Describe what each protects against, and what the Deployment's `.status.conditions` looks like when the deadline is exceeded.
>
> **Q4.11** — `revisionHistoryLimit: 5` — what is physically retained, and what is the failure mode of setting it to `0`?

---

## Exercise 5 — Diagnosing a broken rollout

**Goal:** build the reflex sequence for a stuck deployment. This is the highest-value skill in the objective.

1. Deliberately break the Deployment:

```bash
kubectl -n shop set image deployment/shop-web nginx=nginxinc/nginx-unprivileged:9.99-nope
kubectl -n shop rollout status deployment/shop-web --timeout=60s
```

```
Waiting for deployment "shop-web" rollout to finish: 1 out of 4 new replicas have been updated...
error: timed out waiting for the condition
```

2. Run the diagnostic ladder, top down:

```bash
kubectl -n shop get pods
kubectl -n shop describe pod -l app.kubernetes.io/name=shop-web | sed -n '/^Events/,$p' | head -20
```

```
NAME                        READY   STATUS             RESTARTS   AGE
shop-web-6c8f9d5b74-2xk4t   1/1     Running            0          22m
shop-web-7d4b8c9f11-q6r8s   0/1     ImagePullBackOff   0          65s
...

Events:
  Type     Reason     Age                From               Message
  ----     ------     ----               ----               -------
  Normal   Scheduled  66s                default-scheduler  Successfully assigned shop/shop-web-7d4b8c9f11-q6r8s to worker-1
  Normal   Pulling    66s                kubelet            Pulling image "nginxinc/nginx-unprivileged:9.99-nope"
  Warning  Failed     64s                kubelet            Failed to pull image ...: manifest unknown
  Warning  Failed     64s                kubelet            Error: ErrImagePull
  Warning  Failed     50s (x3 over 63s)  kubelet            Error: ImagePullBackOff
```

3. Confirm at the controller level:

```bash
kubectl -n shop get deploy shop-web -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}{"\n"}{end}'
kubectl -n shop get events --sort-by=.lastTimestamp | tail -8
```

```
Available=True MinimumReplicasAvailable
Progressing=False ProgressDeadlineExceeded
```

4. Recover:

```bash
kubectl -n shop rollout undo deployment/shop-web
kubectl -n shop rollout status deployment/shop-web
```

5. Now break it a different way — make the readiness probe fail:

```bash
kubectl -n shop patch deployment shop-web --type json -p \
  '[{"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/httpGet/path","value":"/nope"}]'
kubectl -n shop rollout status deployment/shop-web --timeout=45s
kubectl -n shop describe pod -l app.kubernetes.io/name=shop-web | grep -A3 'Readiness probe failed' | head -5
```

```
  Warning  Unhealthy  12s (x4 over 32s)  kubelet  Readiness probe failed: HTTP probe failed with statuscode: 404
```

6. Roll back and verify recovery:

```bash
kubectl -n shop rollout undo deployment/shop-web
kubectl -n shop rollout status deployment/shop-web
```

> **Q5.1** — In step 1, old Pods stayed `Running` and served traffic while the new ones failed. Which single field in the manifest guaranteed that, and what would have happened with `maxUnavailable: 1` and `maxSurge: 0`?
>
> **Q5.2** — Step 3 shows `Available=True` and `Progressing=False/ProgressDeadlineExceeded` simultaneously. Explain how both can be true, and which one your CI/CD gate must check.
>
> **Q5.3** — Distinguish `ErrImagePull`, `ImagePullBackOff`, `CrashLoopBackOff` and `CreateContainerConfigError`. For each, name the first command you run and the layer at fault.
>
> **Q5.4** — In step 5 the probe failure never restarted the container, unlike a liveness failure. State the exact consequence of each probe failing, and the classic outage caused by pointing both at the same deep health endpoint.
>
> **Q5.5** — Write the Swarm equivalent of the step-2/step-3 diagnostic ladder: which three commands give you scheduling reason, task error and service-level update state?

---

## Exercise 6 — Packaging the orchestration: Helm

**Goal:** turn the manifests into a versioned, parameterised release, and solve the ConfigMap trap from Exercise 4 idiomatically.

### Block 6.1 — Build a minimal chart by hand

1. Create the chart skeleton:

```bash
mkdir -p ~/lab-702.2/chart/shop/templates && cd ~/lab-702.2/chart/shop
```

2. `Chart.yaml`:

```yaml
apiVersion: v2
name: shop
description: Guided-exercise chart for LPI 702.2
type: application
version: 0.1.0
appVersion: "1.27"
```

3. `values.yaml`:

```yaml
replicaCount: 3

image:
  repository: nginxinc/nginx-unprivileged
  tag: "1.27-alpine"
  pullPolicy: IfNotPresent

greeting: "hello from helm"

service:
  type: ClusterIP
  port: 80

resources:
  requests:
    cpu: 25m
    memory: 32Mi
  limits:
    memory: 64Mi
```

4. `templates/configmap.yaml`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ .Release.Name }}-config
  labels:
    app.kubernetes.io/name: {{ .Chart.Name }}
    app.kubernetes.io/instance: {{ .Release.Name }}
data:
  default.conf: |
    server {
        listen 8080;
        default_type text/plain;
        location /healthz { access_log off; return 200 "ok\n"; }
        location / { return 200 "{{ .Values.greeting }}\n"; }
    }
```

5. `templates/deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .Release.Name }}
  labels:
    app.kubernetes.io/name: {{ .Chart.Name }}
    app.kubernetes.io/instance: {{ .Release.Name }}
    app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
spec:
  replicas: {{ .Values.replicaCount }}
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  selector:
    matchLabels:
      app.kubernetes.io/name: {{ .Chart.Name }}
      app.kubernetes.io/instance: {{ .Release.Name }}
  template:
    metadata:
      labels:
        app.kubernetes.io/name: {{ .Chart.Name }}
        app.kubernetes.io/instance: {{ .Release.Name }}
      annotations:
        checksum/config: {{ include (print $.Template.BasePath "/configmap.yaml") . | sha256sum }}
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 101
      containers:
        - name: nginx
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          ports:
            - name: http
              containerPort: 8080
          readinessProbe:
            httpGet:
              path: /healthz
              port: http
            periodSeconds: 5
          resources:
            {{- toYaml .Values.resources | nindent 12 }}
          volumeMounts:
            - name: conf
              mountPath: /etc/nginx/conf.d
            - name: cache
              mountPath: /var/cache/nginx
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: conf
          configMap:
            name: {{ .Release.Name }}-config
        - name: cache
          emptyDir: {}
        - name: tmp
          emptyDir: {}
```

6. `templates/service.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: {{ .Release.Name }}
spec:
  type: {{ .Values.service.type }}
  selector:
    app.kubernetes.io/name: {{ .Chart.Name }}
    app.kubernetes.io/instance: {{ .Release.Name }}
  ports:
    - name: http
      port: {{ .Values.service.port }}
      targetPort: http
```

7. Lint and render locally — never install something you have not read:

```bash
cd ~/lab-702.2/chart
helm lint ./shop
helm template demo ./shop --set greeting="rendered locally" | grep -A2 'checksum/config'
```

```
==> Linting ./shop
1 chart(s) linted, 0 chart(s) failed

      annotations:
        checksum/config: 8c1f0a4d9e2b6a7c5f31d0be44a9c7f2b8e1d603a5c7e9f0b2d4a6c8e0f1a3b5
```

8. Install and inspect release state:

```bash
helm upgrade --install demo ./shop -n shop --create-namespace --atomic --wait --timeout 3m
helm -n shop list
kubectl -n shop get secret -l owner=helm
```

```
NAME    NAMESPACE  REVISION  UPDATED               STATUS    CHART        APP VERSION
demo    shop       1         2026-09-03 12:04:11   deployed  shop-0.1.0   1.27

NAME                          TYPE                 DATA   AGE
sh.helm.release.v1.demo.v1    helm.sh/release.v1   1      40s
```

9. Change only the greeting and watch the checksum annotation force a rollout:

```bash
helm upgrade demo ./shop -n shop --set greeting="hello from helm v2" --atomic --wait
kubectl -n shop rollout status deployment/demo
kubectl -n shop run curl --rm -it --restart=Never --image=curlimages/curl:8.10.1 -- curl -s http://demo/
```

```
Release "demo" has been upgraded. Happy Helming!
REVISION: 2
deployment "demo" successfully rolled out
hello from helm v2
```

10. Roll the release back:

```bash
helm -n shop history demo
helm -n shop rollback demo 1 --wait
kubectl -n shop run curl --rm -it --restart=Never --image=curlimages/curl:8.10.1 -- curl -s http://demo/
```

```
REVISION  UPDATED              STATUS      CHART       APP VERSION  DESCRIPTION
1         2026-09-03 12:04:11  superseded  shop-0.1.0  1.27         Install complete
2         2026-09-03 12:09:33  deployed    shop-0.1.0  1.27         Upgrade complete

Rollback was a success! Happy Helming!
hello from helm v2   <-- read Q6.5 before trusting this
```

> **Q6.1** — Explain the `checksum/config` annotation line token by token: what does `$.Template.BasePath` resolve to, why `include` rather than `.Files.Get`, and what problem from Exercise 4 does the whole line solve?
>
> **Q6.2** — Contrast `helm template`, `helm install --dry-run`, and `kubectl apply --dry-run=server`. Which one catches an invalid `apiVersion`, and which one catches a bad Go template?
>
> **Q6.3** — `helm upgrade --install --atomic --wait` is used instead of plain `helm upgrade`. What does each of the three flags buy you, and what does `--atomic` do on failure that plain `--wait` does not?
>
> **Q6.4** — Helm 3 stores `sh.helm.release.v1.demo.v1` as a Secret in the release namespace. What are the operational consequences: where do you back it up, what happens if two operators upgrade concurrently, and how does this differ from Helm 2?
>
> **Q6.5** — Step 10's rollback appears to have returned the old content, yet the curl output shows `v2`. Give the two most likely explanations and the exact commands that distinguish them.
>
> **Q6.6** — Position Helm against `docker stack deploy` and raw `kubectl apply -f`. Which of the three gives you release history and atomic rollback, and which gives you server-side desired-state reconciliation? Are those the same property?

### Cleanup

```bash
helm -n shop uninstall demo
kubectl delete namespace shop
docker compose -f ~/lab-702.2/compose/compose.yaml down -v
```

---

<details>
<summary><strong>Answers</strong></summary>

### Exercise 1 — Compose

**A1.1.** The short form guarantees only *start ordering*: Compose creates and starts `cache` before it starts `web`, and stops them in reverse order. It says nothing about the dependency being usable — a Redis container is "started" the instant the process is exec'd, milliseconds before it can accept connections. `condition: service_healthy` gates on the container's `healthcheck` transitioning to `healthy`, i.e. `redis-cli ping` returning `PONG`. The three conditions are `service_started` (the default short form), `service_healthy` (requires a `healthcheck` on the dependency; Compose errors if there is none) and `service_completed_successfully` (dependency exited 0 — the correct condition for migration/seed jobs). Production note: even `service_healthy` is a *startup* gate only. It does not protect you if the dependency dies later, so the application still needs connection retry with backoff. Ref: <https://docs.docker.com/reference/compose-file/services/#depends_on>

**A1.2.** `internal: true` removes the default gateway from that bridge network, so containers attached *only* to `backend` have no route to the outside world — no egress to the internet, and no external ingress. It does **not** block container-to-container traffic inside the network, and it does not block DNS resolution via the embedded resolver at 127.0.0.11. `web` remains reachable on 8080 because it is attached to *two* networks: the published port is bound on the host and DNAT'd to the container, and the `frontend` network provides the gateway. This is the standard two-tier pattern: the datastore has no path to the internet even if compromised.

**A1.3.** `restart: always` on a container that legitimately exits 0 creates a restart loop: Docker restarts it, the command runs again, it exits 0, Docker restarts it. Worse, in this dependency graph `web` waits on `service_completed_successfully`, and a service that keeps being restarted never settles into a terminal completed state — `docker compose up` blocks or times out. One-shot jobs must be `restart: "no"` (quoted, because unquoted `no` is the YAML boolean `false`) or `on-failure`.

**A1.4.** The project name namespaces every resource: containers `<project>-<service>-<index>`, networks and volumes `<project>_<name>`. It is what lets two stacks coexist on one engine and what `docker compose down` uses to know what to delete. Precedence: `-p` flag > `COMPOSE_PROJECT_NAME` env var > `name:` top-level key > sanitised basename of the project directory. Without `name:`, engineer A in `~/work/shop` and engineer B in `~/repos/shop-app` get projects `shop` and `shop-app` — different networks, different volumes, and `docker compose down` run from the wrong directory silently does nothing. Pinning `name:` in the file makes the deployment reproducible regardless of checkout path.

**A1.5.** A published port is a host-level resource: `0.0.0.0:8080` can be bound by exactly one process. Compose asked for three containers each DNAT'ing host 8080 → container 80, and the second bind failed at the kernel/`docker-proxy` level. This is a property of the model: **Compose has no load balancer and no routing mesh.** It is a single-host tool that maps host ports directly to containers. Any orchestrator that scales behind one address must insert a layer that Compose does not have — Swarm's ingress network + IPVS, or Kubernetes' Service + kube-proxy/eBPF. The port range `8080-8090:80` works around it by giving each replica its own host port, which is exactly the "now you need an external load balancer and service registry" problem that orchestrators exist to solve.

**A1.6.** No — Compose is not load balancing. What varies is *DNS*. Docker's embedded DNS server at 127.0.0.11 resolves the service name `web` to all container IPs of that service and returns the records in rotating order (round-robin DNS). The distribution of *connections* is then entirely at the client's discretion. Two production failure modes: (1) **client-side caching** — JVMs and many HTTP clients cache the first A record for the process lifetime (or forever, with a default `networkaddress.cache.ttl` of -1), pinning all traffic to one replica; (2) **no health awareness** — a dead or unready container's IP is removed only when the container stops, so DNS keeps handing out addresses of containers that cannot serve, and there is no readiness gate at all. This is precisely why Swarm defaults to VIP mode instead of DNSRR.

**A1.7.** Compose V2 honours `deploy.replicas` (equivalent to `--scale`) and `deploy.resources.limits` / `reservations` (translated to cgroup limits). It ignores the Swarm-only keys: `deploy.placement`, `deploy.update_config`, `deploy.rollback_config`, `deploy.endpoint_mode`, `deploy.mode: global`. Ignored keys are dropped silently or with a warning — which is the trap: the same file behaves differently under `docker compose up` and `docker stack deploy`, and the update policy you carefully wrote is simply not applied locally.

**A1.8.** `docker compose down -v` (or `--volumes`) removes named volumes declared in the `volumes:` section. It is not the default because named volumes hold state — database files, uploads, certificates. `down` is the routine "stop this stack" verb; making it destructive by default would make an ordinary restart a data-loss event. Anonymous volumes are removed by `--volumes` too; `--rmi local|all` additionally removes images.

---

### Exercise 2 — Swarm

**A2.1.** With Compose, desired state lives in the file *plus your shell*: the client reads the file and issues imperative container API calls. Nothing on the host remembers "there should be three of these". With Swarm, `docker stack deploy` submits a **service spec** to the manager, which persists it in the Raft-replicated cluster store; the orchestrator then continuously reconciles actual state against it. Killing a container's PID 1: under Compose, it stays dead unless you set `restart:` (and then it is the *engine*, not an orchestrator, restarting it in place — same container, incremented restart count). Under Swarm, the task enters `Failed`, and the orchestrator schedules a **new task** — a brand-new container, possibly on a different node — subject to `restart_policy`. The distinction between "restart the container" and "reschedule the task" is the essence of orchestration.

**A2.2.** `docker stack deploy` prints `Ignoring unsupported options: build, depends_on` and ignores `restart:` in favour of `deploy.restart_policy`. Architecturally: **`build:`** — the manager schedules tasks onto arbitrary nodes that must all be able to pull an identical image; a build context exists only on your workstation, so images must be built and pushed to a registry beforehand. **`depends_on:`** — it expresses a start order on one host, but in a cluster the scheduler places tasks concurrently across nodes and any node can die and reschedule at any moment; there is no global "start A then B" primitive, and no meaningful one either, since after a node failure B may restart before A. Ordering must therefore be handled by the application (retry/backoff) or by an init container pattern. **`restart:`** is a per-container engine policy; in a cluster the equivalent decision belongs to the orchestrator, hence `deploy.restart_policy` with `condition`, `delay`, `max_attempts` and `window`.

**A2.3.** The overlay driver builds a layer-2 network spanning multiple hosts by encapsulating container Ethernet frames in **VXLAN** (UDP), so containers on different nodes share one flat address space and one embedded DNS namespace — a bridge network is host-local and cannot do this. Required between nodes: **TCP 2377** (cluster management / Raft, managers only), **TCP+UDP 7946** (control plane gossip, node discovery), **UDP 4789** (VXLAN data plane). A very common failure is 4789 blocked or clashing with an existing VXLAN/VMware NSX deployment — containers resolve each other but traffic silently blackholes. Ref: <https://docs.docker.com/engine/network/drivers/overlay/>

**A2.4.** The two modes are **VIP** (default) and **DNSRR**. In VIP mode, Swarm allocates one *virtual* IP per service per attached network. `nslookup api` returns that single stable VIP. It belongs to no container; it is a load-balancing target programmed into every participating node's kernel with **IPVS** (via iptables/ipvsadm in the node's network namespace). A connection to 10.0.1.2 is DNAT'd by IPVS round-robin to one of the healthy task IPs. `tasks.<service>` is the escape hatch: it always returns the A records of every individual task, in every mode. The client-side advantage of VIP is decisive — clients cache one address forever and that address never goes stale, while IPVS updates the backend set as tasks come and go, and unhealthy tasks are removed from the set.

**A2.5.** With `endpoint_mode: dnsrr`, no VIP is allocated: `nslookup api` returns all three task IPs directly, exactly like `tasks.api`, and the load-balancing decision moves back to the client. The `ports:` section breaks — **DNSRR is incompatible with `mode: ingress` publishing**, because the routing mesh is implemented on top of the service VIP; deploying it errors with "port published with ingress mode can't be used with dnsrr mode" and you must switch to `mode: host`. DNSRR is wrong for any client that caches DNS or holds long-lived connections (JVM applications, connection pools, gRPC channels) — they pin to one backend and never learn about rescheduling. It is right for clients that do their own service-aware balancing, and it is required when the backend protocol is not TCP/UDP-DNAT-friendly or when you deliberately want per-endpoint addressing (e.g. clustering databases).

**A2.6.** Yes. That is the **routing mesh**. Every node in the swarm participates in the `ingress` overlay network and programs the published port on *all* nodes, whether or not they run a task. A packet arriving on 8080 at a replica-less node is picked up by the ingress sandbox, load-balanced by IPVS to a healthy task's IP, and forwarded over the `ingress` VXLAN network to the node that actually runs it. This is what makes any node a valid target for an external L4 load balancer or DNS round-robin — you point at all nodes and never have to track placement. Cost: an extra network hop and loss of the client's source IP (SNAT). Ref: <https://docs.docker.com/engine/swarm/ingress/>

**A2.7.** `mode: host` binds the published port directly on the node's interface for the local task only, bypassing ingress and IPVS entirely. **Gained:** one less hop (lower latency), and the real client source IP is preserved — which matters for access logging, rate limiting and geo-routing. **Lost:** you must know which nodes run the service, so an external load balancer needs a real service-discovery integration; and there is no cluster-wide port. **Replica limit:** a host port is exclusive, so at most **one task per node** per published port. In practice you pair `mode: host` with `deploy.mode: global` (one task per node) — the standard pattern for ingress controllers and node-local agents.

---

### Exercise 3 — Rolling updates and rollback

**A3.1.** With `parallelism: 1` and `order: start-first`, for each of the three tasks in turn: start the new task → wait for it to reach `Running` and pass the `monitor` window healthy → stop the old task → wait `delay: 10s` → next task. Peak count is 4 tasks (N+1), minimum is 3 — capacity never dips below desired. `order: stop-first` inverts it: stop the old task, then start the new one, so the peak is 3 and the **minimum is 2** — you run degraded during the update. `stop-first` is mandatory when the task holds an exclusive resource that two instances cannot share: a host port under `mode: host`, a single-writer volume lock, a fixed cluster identity, or a licence-seat-limited product.

**A3.2.** During `monitor: 20s` after each task starts, Swarm watches whether that task stays in `Running` and — if the image defines a `healthcheck` — whether it becomes and remains `healthy`. A task that exits, is rejected, or fails its healthcheck within the monitor window is counted as a failed update task. `max_failure_ratio: 0` means *zero tolerance*: one failed task out of three (ratio 0.33 > 0) triggers `failure_action`, here `rollback`. Without a `healthcheck` the monitor window can only detect a *crash* — a process that starts and then serves 500s to every request looks perfectly healthy to the scheduler, and the bad version rolls out to 100%. The healthcheck is what turns "the process is alive" into "the service works", so it is the load-bearing part of any automated-rollback strategy.

**A3.3.** `Rejected` means the **agent on the node** refused to run the task — it never became a container. Causes: image cannot be pulled, a mount source is missing, a secret/config does not exist, an invalid user or capability. `Failed` means the container **ran and then terminated** abnormally — non-zero exit, OOM-kill, healthcheck exhausted. The distinction routes your investigation: `Rejected` is an infrastructure/spec problem (registry credentials, node config, typo in the spec), `Failed` is an application problem. Both are visible in `docker service ps --no-trunc <svc>`; the `--no-trunc` matters because the error column is truncated by default and truncation usually cuts exactly the interesting part.

**A3.4.** Swarm rolls back to the **entire previous service spec**, not just the image — environment, mounts, resource limits, replica count, networks, labels, command, healthcheck: every field of the `ServiceSpec`. The manager keeps the last-known-good spec in `.PreviousSpec` of the service object, persisted in the Raft store on the managers. Two consequences: there is exactly **one** level of history (rolling back twice returns you to where you started — it is a toggle, not a stack), so Swarm is not a substitute for versioned manifests in Git; and the rollback itself is governed by `rollback_config`, not `update_config`, which is why `rollback_config: {parallelism: 0}` is a common choice — parallelism 0 means "all tasks at once", i.e. get back to safety as fast as possible.

**A3.5.** By default the CLI resolves the tag to an immutable content digest (`sha256:...`) at update time and distributes *that* to every node. Without it, each node independently pulls `myapp:latest` at whatever moment it happens to schedule a task — and if the tag is republished mid-rollout, or a node has a stale cached layer, you end up with different code running under one service name, producing an outage that is nearly impossible to diagnose because `docker service ls` shows one consistent image string. Pinning the digest makes the rollout atomic in content. The flag is `--no-resolve-image`. The warning you saw simply says the tag could not be found in the registry to resolve — which was the real error, surfaced as a warning.

**A3.6.** `drain` marks the node unavailable **and evicts**: every task on it is stopped and rescheduled onto other `Active` nodes, and no new tasks are placed there. `pause` stops *new* placement but **leaves running tasks in place**. Before a kernel upgrade / reboot you want `drain`, so the workload has already moved and converged elsewhere before the node goes down; after the reboot you set `--availability active` and (note) tasks do **not** automatically rebalance back — Swarm does not preemptively move running tasks, so the node stays empty until the next update or scaling event, or until you force it with `docker service update --force`. `pause` is for debugging a node without disturbing what runs on it.

---

### Exercise 4 — Kubernetes

**A4.1.** The Deployment is a declarative controller for ReplicaSets; each ReplicaSet is a controller for a Pod set matching one exact pod template hash. On a template change the Deployment creates a **new** ReplicaSet and shifts replicas from old to new according to `strategy`. Ownership is expressed via `metadata.ownerReferences` on each child, which is also what makes deletion cascade. **The history lives in the retained old ReplicaSets** — `kubectl rollout history` and `rollout undo` simply read and re-scale them; that is why `revisionHistoryLimit` controls how far back you can undo. Deleting the current ReplicaSet by hand deletes its Pods (cascading), then the Deployment controller immediately reconciles and creates a *new* ReplicaSet — a full-outage way of doing `rollout restart`.

**A4.2.** `spec.selector` is **immutable** on `apps/v1` Deployments. The API server rejects the change: `The Deployment "shop-web" is invalid: spec.selector: Invalid value: ...: field is immutable`. The reason is orphaning: the selector is the only link between the Deployment and its ReplicaSets/Pods. Changing it would leave the existing ReplicaSets unowned and still running, while the Deployment created a fresh set — silently doubling your workload with no controller managing the old half. To change a selector you must delete and recreate the Deployment (with `--cascade=orphan` if you want a zero-downtime hand-over, then adopt/clean up manually).

**A4.3.** `shop-web` (ClusterIP) ↔ Swarm **VIP mode**: one stable virtual address fronting the healthy backends. `shop-web-headless` (`clusterIP: None`) ↔ Swarm **DNSRR** / `tasks.<service>`: DNS returns the Pod IPs directly. The behavioural difference is in the data path: Swarm's VIP is implemented with **IPVS in the ingress/overlay sandbox**, while Kubernetes' ClusterIP is implemented by **kube-proxy** — historically iptables DNAT rules with `statistic random probability` (so, statistically random rather than true round robin), optionally IPVS mode, and in modern CNIs (Cilium) replaced entirely by eBPF at the socket layer. A second, more important difference: Kubernetes gates membership on **readiness** (a Pod is removed from the EndpointSlice the moment its readiness probe fails, without being killed), which Swarm has no equivalent of — its healthcheck failure leads to task replacement, not to quiet removal from the load-balancing set.

**A4.4.** `targetPort` accepts either a number or the *name* of a `containerPort`. Naming decouples the Service from the container's listening port: if the container image later moves from 8080 to 8081, you edit the Pod template only, and the Service, the probes (`port: http`) and any NetworkPolicy referencing the name follow automatically. It also documents intent — `http` versus `metrics` versus `grpc` — and it is required for multi-port Services where positional numbers become ambiguous. The Service's own `port: 80` is the stable contract for clients and should not track the container.

**A4.5.** nginx must write to two paths at runtime: `/var/cache/nginx` (proxy/client/fastcgi temp paths, created by `ngx_create_paths` during startup) and `/tmp` (the unprivileged image writes its PID file to `/tmp/nginx.pid`). Mounting `emptyDir` volumes there gives writable, container-lifetime-scoped storage over the read-only root. Without them the container exits immediately and the Pod enters `CrashLoopBackOff`; `kubectl logs` shows `nginx: [emerg] mkdir() "/var/cache/nginx/client_temp" failed (30: Read-only file system)`. The general pattern: `readOnlyRootFilesystem: true` plus an explicit, auditable list of writable paths — an attacker with code execution cannot drop a binary anywhere else.

**A4.6.** They are enforced by different kernel mechanisms with different failure semantics. **Memory** is incompressible: exceeding `limits.memory` gets the process **OOM-killed** by the cgroup memory controller (container terminated, `Reason: OOMKilled`, exit 137). There is no graceful degradation, so a limit is essential to stop one Pod taking down its node. **CPU** is compressible: exceeding `limits.cpu` causes **CFS throttling** — the cgroup is stalled until the next 100 ms period. Nothing is killed, but tail latency degrades sharply and, because the quota is enforced per period, multi-threaded runtimes can be throttled while the node is idle. The mainstream production guidance is therefore: always set memory requests **equal to** limits, always set CPU requests (for scheduling and fair-share weighting), and omit CPU limits unless you need hard multi-tenant isolation or deterministic benchmarking.

**A4.7.** Two independent facts. (1) `rollout status` reported success because the Deployment's rollout is driven **only** by changes to `spec.template`. A ConfigMap edit does not touch the Pod template, so no new ReplicaSet is created, the observed generation already matches, and the Deployment is by definition "successfully rolled out". The controller has no notion that a mounted ConfigMap is part of the workload's identity. (2) The kubelet *does* refresh projected ConfigMap volumes — via an atomic symlink swap of the `..data` directory, typically within a sync period plus cache TTL (order of a minute). So the **file on disk did change**; what did not change is nginx's in-memory configuration, because nginx reads its config once at startup and only re-reads it on `SIGHUP`. Any application that parses config at boot needs an explicit restart. (Note: a ConfigMap consumed via `envFrom`/`env` is *never* refreshed — environment variables are fixed at container creation. And `subPath` mounts are never refreshed either.)

**A4.8.** It patches `spec.template.metadata.annotations["kubectl.kubernetes.io/restartedAt"]` with the current timestamp. Because that field is inside the pod template, the template hash changes, the Deployment creates a new ReplicaSet, and the normal `strategy` takes over — so it is a rolling replacement honouring `maxSurge`/`maxUnavailable`, readiness probes, `minReadySeconds` and any PodDisruptionBudget, with no downtime. It also becomes a normal revision in `rollout history`, so it is undoable. This is why `rollout restart` is the correct verb and `kubectl delete pod --all` is not.

**A4.9.** `maxUnavailable: 0` means the number of *available* Pods never drops below `replicas`, i.e. never below 4. `maxSurge: 1` allows one extra Pod above desired, so the total never exceeds 5. The rollout proceeds one Pod at a time: create #5, wait for Ready + `minReadySeconds`, terminate one old Pod, repeat. The assumption is that the cluster has **spare capacity for one more Pod** — with `maxSurge: 1, maxUnavailable: 0` on a cluster with no schedulable headroom, the surge Pod stays `Pending` (`Insufficient cpu`) and the rollout hangs until `progressDeadlineSeconds` fires. This pair is the right default for stateless web services; capacity-constrained clusters use `maxSurge: 0, maxUnavailable: 1` and accept running N-1 during the rollout.

**A4.10.** `minReadySeconds: 5` requires a new Pod to stay Ready continuously for 5 seconds before it counts as *available* and the rollout advances. It defends against the "passes the first probe, then crashes" class of bug — a Pod that is ready for 200 ms would otherwise let the rollout march on and take down every replica. `progressDeadlineSeconds: 120` bounds how long the Deployment may make *no progress* before the controller gives up: it sets

```
type: Progressing
status: "False"
reason: ProgressDeadlineExceeded
message: ReplicaSet "shop-web-7d4b8c9f11" has timed out progressing.
```

Crucially, this **marks** the failure; it does not roll back (Kubernetes Deployments, unlike Swarm, have no automatic `failure_action: rollback` — that is what `--atomic` in Helm, or Argo Rollouts, provides). The deadline timer resets on any progress, so a slow-but-advancing rollout is not penalised.

**A4.11.** Kubernetes retains the last 5 **old ReplicaSet objects** (scaled to 0 replicas — they consume API storage, not compute). Each is one entry in `rollout history` and one possible `--to-revision` target. With `revisionHistoryLimit: 0`, old ReplicaSets are garbage-collected immediately: `rollout history` shows nothing useful and `rollout undo` fails with `error: no rollout history found`. You have removed your fastest rollback path — the one you reach for at 3 a.m. when re-applying from Git is blocked because the Git change is exactly what broke things.

---

### Exercise 5 — Diagnosis

**A5.1.** `maxUnavailable: 0`. The controller will not terminate an old Pod until a new one is Ready, and no new Pod ever became Ready, so all four originals kept serving — a failed rollout with zero user impact. With `maxUnavailable: 1, maxSurge: 0` the controller terminates an old Pod *first*, then creates the replacement; the replacement fails to pull, so you are permanently at 3/4 capacity, and depending on the controller's pacing you can lose more. That single field is the difference between "a broken deploy" and "a broken deploy that is also an outage".

**A5.2.** They describe different things. `Available` reflects whether at least `replicas - maxUnavailable` Pods are Ready **right now**, counting old and new alike — the four healthy v1 Pods satisfy it, so `Available=True`. `Progressing` reflects whether the Deployment is converging on the **desired** template; it is not, hence `False/ProgressDeadlineExceeded`. A CI/CD gate must check **`Progressing`**, which is exactly what `kubectl rollout status` does (it exits non-zero on `ProgressDeadlineExceeded` or `--timeout`). Gating on `Available` or on `kubectl get deploy` showing `4/4` is the classic silent-failure pipeline: it reports green while the new version was never deployed.

**A5.3.**

| Status | Meaning | First command | Layer at fault |
|---|---|---|---|
| `ErrImagePull` | The pull attempt just failed (transient state, first try) | `kubectl describe pod` → Events | Registry / image reference / credentials |
| `ImagePullBackOff` | Repeated pull failures; kubelet is backing off exponentially (up to 5 min) | `kubectl describe pod`; check `imagePullSecrets`, tag existence, node network/proxy | Same, now confirmed persistent |
| `CrashLoopBackOff` | The container **started** and exited repeatedly; kubelet is backing off restarts | `kubectl logs <pod> --previous` (`-c <container>` if multi-container) | Application / config / missing dependency |
| `CreateContainerConfigError` | The kubelet cannot build the container spec — a referenced ConfigMap/Secret key does not exist, or an invalid env source | `kubectl describe pod` → Events; then `kubectl get cm,secret` | The manifest itself |

Related: `CreateContainerError` (runtime rejected it — bad command, bad user), `RunContainerError`, and `Pending` with no node assigned (`kubectl describe pod` → scheduler events: taints, insufficient resources, unbound PVC).

**A5.4.** A failing **readiness** probe removes the Pod's address from the Service's EndpointSlice — it stops receiving traffic but **keeps running**, so you can exec into it and debug, and it rejoins automatically when it recovers. A failing **liveness** probe makes the kubelet **kill the container** and restart it per `restartPolicy`, incrementing `RESTARTS`. The classic outage: pointing both probes at a `/health` endpoint that transitively checks the database. The database has a hiccup → every Pod's liveness fails simultaneously → the kubelet kills every replica of every service at once → they all restart, hammer the recovering database with reconnects, fail again, and the cluster enters a cascading `CrashLoopBackOff` that outlives the original fault. Rule: **liveness must be shallow and local** ("is my process wedged?"), **readiness may be deep** ("can I serve a request right now?"), and slow-starting applications get a `startupProbe` rather than an inflated `initialDelaySeconds`.

**A5.5.**

```bash
docker service ps <svc> --no-trunc            # per-task node, desired/current state, and the full ERROR column
docker service logs <svc> --tail 100 -f       # aggregated stdout/stderr across all tasks (application layer)
docker service inspect <svc> --pretty         # or --format '{{json .UpdateStatus}}' — service-level update/rollback state
```

Plus `docker inspect <task-container>` on the node for the healthcheck log (`.State.Health.Log`), and `docker node ps <node>` to see everything scheduled on a suspect node. The mapping to the Kubernetes ladder is: `service ps` ≈ `kubectl get pods` + `describe` events, `service logs` ≈ `kubectl logs`, `service inspect .UpdateStatus` ≈ the Deployment's `.status.conditions`.

---

### Exercise 6 — Helm

**A6.1.** `$.Template.BasePath` is the chart-relative path to the templates directory of the chart currently rendering (`shop/templates`); `$` is the root context, so it resolves correctly even inside a `range` or `with` block where `.` has been rebound. `print` concatenates it with `/configmap.yaml` to form the template's name as Helm registered it. `include` renders that named template **as a string** with the current context, so all values, release name and functions inside it are expanded — `.Files.Get` would return the raw, unrendered file, so a greeting change would not alter the checksum. `sha256sum` hashes the rendered text into the Pod template annotation. Effect: any change to the ConfigMap's rendered content changes `spec.template`, which changes the pod-template hash, which creates a new ReplicaSet — a normal rolling update. This solves A4.7 declaratively: config changes become deployments, undoable via `helm rollback` and `kubectl rollout undo`.

**A6.2.** `helm template` renders locally with **no cluster contact** — it catches Go template errors, missing values, and bad indentation, and it is what you diff in CI. `helm install --dry-run` renders *and* sends the manifests to the API server for validation, so it catches an invalid `apiVersion`, an unknown field, an immutable-field violation, and admission-webhook rejections (add `--dry-run=server` on Helm 3.13+ for full server-side dry run; the older plain `--dry-run` is client-side rendering with limited validation). `kubectl apply --dry-run=server` runs the full admission chain including mutating/validating webhooks and quota checks, but takes already-rendered YAML, so it cannot see a Go template error at all. Practical pipeline: `helm lint` → `helm template | kubeconform` → `helm upgrade --install --dry-run=server` → real upgrade.

**A6.3.** `--install` makes the command idempotent: install if the release does not exist, upgrade if it does — one command for both CI paths, no "release not found" branch. `--wait` blocks until the created resources report ready (Deployments/StatefulSets/DaemonSets at their expected ready counts, Services with endpoints, PVCs bound) or `--timeout` expires, so the pipeline's exit code reflects the workload's real state rather than "the API server accepted my YAML". `--atomic` implies `--wait` **and adds automatic rollback on failure**: if the wait times out or any resource fails, Helm restores the previous release revision, so a failed deploy leaves the cluster in the last known-good state instead of half-migrated. Without `--atomic`, a timed-out upgrade leaves the release in `failed` status *and* leaves the broken objects running. Note that `--atomic` extends the wall-clock cost of a bad deploy (you wait for the timeout, then for the rollback), so set `--timeout` deliberately.

**A6.4.** Each revision is a gzipped, base64-encoded Secret named `sh.helm.release.v1.<release>.v<revision>` in the release's namespace. Consequences: (1) **Backup** — release history is namespace-scoped cluster state, so your etcd/Velero backup covers it, but a `kubectl delete ns` destroys the entire release history along with the workload; the chart in Git is the real source of truth. (2) **Concurrency** — there is no distributed lock; two simultaneous `helm upgrade` runs race, and the common outcome is a release stuck in `pending-upgrade`, after which every subsequent upgrade fails with `another operation is in progress` until you `helm rollback` or delete the pending revision Secret. Serialise deploys per release in CI. (3) **Versus Helm 2** — Helm 2 stored state as ConfigMaps in `kube-system`, written by **Tiller**, a cluster-wide server-side component that typically ran with `cluster-admin`; anyone who could talk to Tiller inherited those rights. Helm 3 removed Tiller entirely: the client uses *your* kubeconfig and RBAC, and state moved to Secrets in the release namespace. Also note that a large chart can exceed the ~1 MiB Secret/etcd object limit.

**A6.5.** Most likely: (a) **the rollback is still converging** — `helm rollback` without `--wait` returns as soon as the API objects are patched, and you curl'd while the new ReplicaSet was still rolling; or (b) **you hit a stale endpoint** — the `curl` Pod resolved the Service and connected to a not-yet-terminated v2 Pod. A third, subtler possibility on a real chart: the ConfigMap name is templated per-release but the *content* comparison happened against a merged three-way patch that dropped your change. Commands to distinguish:

```bash
helm -n shop history demo                                   # is revision 3 'deployed'?
helm -n shop status demo
kubectl -n shop rollout status deployment/demo              # has it converged?
kubectl -n shop get cm demo-config -o jsonpath='{.data.default\.conf}'   # what is the desired config now?
kubectl -n shop get rs -l app.kubernetes.io/instance=demo   # which ReplicaSets still have replicas?
kubectl -n shop get pods -o custom-columns=\
NAME:.metadata.name,ANN:.metadata.annotations.checksum/config
```

Comparing the ConfigMap content with each Pod's `checksum/config` annotation tells you immediately whether the config rolled back and the Pods have not caught up, or whether the rollback itself did not include the ConfigMap. The general lesson: **always `--wait` a rollback, and verify at the object level, never by a single request through a load balancer.**

**A6.6.** They solve orthogonal problems.

- **`kubectl apply -f`** — server-side desired state, continuously reconciled by controllers. No release grouping, no history beyond per-resource `rollout history`, no atomic multi-object rollback.
- **`docker stack deploy`** — server-side desired state, continuously reconciled by the Swarm orchestrator. History limited to one previous spec per service (`.PreviousSpec`), rollback is per-service, not per-stack.
- **Helm** — a *client-side release manager*: templating, values, revision history, atomic install/upgrade/rollback of a whole multi-object release. But Helm does **not** reconcile: once objects are applied, Kubernetes' own controllers do all the ongoing work, and if someone edits a Deployment by hand, Helm neither knows nor corrects it (it only notices at the next upgrade, via the three-way merge — hence `helm diff` and drift-detection tooling).

So **release history + atomic rollback** and **desired-state reconciliation** are genuinely different properties. Helm supplies the first; Kubernetes and Swarm supply the second. GitOps tools (Argo CD, Flux) exist precisely to add continuous reconciliation *of the release definition itself*, closing the loop Helm leaves open.

</details>

---

## Sources

- LPI — Exam 701 Objectives (DevOps Tools Engineer, version 2.0): <https://www.lpi.org/our-certifications/exam-701-objectives/>
- Docker — Compose file reference: <https://docs.docker.com/reference/compose-file/>
- Docker — Compose `depends_on` and service conditions: <https://docs.docker.com/reference/compose-file/services/#depends_on>
- Docker — Swarm mode overview: <https://docs.docker.com/engine/swarm/>
- Docker — Deploy a stack to a swarm: <https://docs.docker.com/engine/swarm/stack-deploy/>
- Docker — Use swarm mode routing mesh: <https://docs.docker.com/engine/swarm/ingress/>
- Docker — Overlay network driver: <https://docs.docker.com/engine/network/drivers/overlay/>
- Docker — Apply rolling updates to a service: <https://docs.docker.com/engine/swarm/swarm-tutorial/rolling-update/>
- Docker — `docker service update` reference: <https://docs.docker.com/reference/cli/docker/service/update/>
- Kubernetes — Deployments: <https://kubernetes.io/docs/concepts/workloads/controllers/deployment/>
- Kubernetes — Service: <https://kubernetes.io/docs/concepts/services-networking/service/>
- Kubernetes — DNS for Services and Pods: <https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/>
- Kubernetes — Configure Liveness, Readiness and Startup Probes: <https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/>
- Kubernetes — ConfigMaps: <https://kubernetes.io/docs/concepts/configuration/configmap/>
- Kubernetes — Resource Management for Pods and Containers: <https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/>
- Helm — Charts: <https://helm.sh/docs/topics/charts/>
- Helm — `helm upgrade`: <https://helm.sh/docs/helm/helm_upgrade/>
- Helm — Chart development tips and tricks (ConfigMap checksum pattern): <https://helm.sh/docs/howto/charts_tips_and_tricks/>