# LPIC-3 305 · Topic 352.4 — Container Orchestration Platforms
## Guided Exercises (exam 305-300, v3.0 · weight 5)

> **Scope of this topic.** The 305-300 objective 352.4 asks you to *understand the importance of container orchestration and the key concepts of Docker Compose and Docker Swarm*, to actually *use* both, and to have *awareness of Kubernetes and Helm*. The terms and utilities you must be fluent with are: `docker-compose.yml`, `docker compose`, `docker swarm`, `docker node`, `docker service`, `docker stack`.
> Source: LPI Exam 305 Objectives — <https://www.lpi.org/our-certifications/exam-305-objectives/>
>
> **Lab prerequisites.** You need Docker Engine ≥ 20.10 with the Compose v2 plugin (`docker compose version`). For the Swarm exercises you need at least one host with a routable IP; a second host (or a second VM) lets you observe manager/worker roles for real, but a single-node swarm is enough for every command in this objective.

---

## Exercise 1 — Define and run a multi-service application with `docker compose`

**Goal:** understand what a `docker-compose.yml` declares (services, networks, volumes, dependencies, health) and why declarative orchestration beats a shell script full of `docker run`.

### Steps

1. Create a working directory and enter it:

   ```bash
   mkdir -p ~/lab-3524/compose && cd ~/lab-3524/compose
   ```

2. Write the following `docker-compose.yml`. It declares three services — a reverse proxy, a stateless API, and a stateful database — plus a named volume and two user-defined networks:

   ```yaml
   # docker-compose.yml
   services:
     proxy:
       image: nginx:1.27-alpine
       ports:
         - "8080:80"
       volumes:
         - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
       depends_on:
         api:
           condition: service_healthy
       networks:
         - frontend

     api:
       image: hashicorp/http-echo:1.0
       command: ["-text=hello from api", "-listen=:5678"]
       healthcheck:
         test: ["CMD", "wget", "-qO-", "http://localhost:5678"]
         interval: 5s
         timeout: 3s
         retries: 5
         start_period: 5s
       networks:
         - frontend
         - backend

     db:
       image: postgres:16-alpine
       environment:
         POSTGRES_PASSWORD: s3cret
         POSTGRES_DB: appdb
       volumes:
         - pgdata:/var/lib/postgresql/data
       networks:
         - backend

   volumes:
     pgdata:

   networks:
     frontend:
     backend:
   ```

3. Create the `nginx.conf` referenced by the proxy service:

   ```bash
   cat > nginx.conf <<'EOF'
   server {
       listen 80;
       location / {
           proxy_pass http://api:5678;
       }
   }
   EOF
   ```

4. Validate and normalise the file **before** starting anything. `docker compose config` resolves variables, applies defaults, and fails loudly on schema errors:

   ```bash
   docker compose config
   ```

   Expected (truncated) — note it injects the project-scoped network/volume names:

   ```yaml
   name: compose
   services:
     api:
       image: hashicorp/http-echo:1.0
       ...
   networks:
     backend:
       name: compose_backend
     frontend:
       name: compose_frontend
   volumes:
     pgdata:
       name: compose_pgdata
   ```

5. Bring the stack up in the background:

   ```bash
   docker compose up -d
   ```

   Expected:

   ```
   [+] Running 6/6
    ✔ Network compose_frontend  Created
    ✔ Network compose_backend   Created
    ✔ Volume  compose_pgdata     Created
    ✔ Container compose-db-1     Started
    ✔ Container compose-api-1    Healthy
    ✔ Container compose-proxy-1  Started
   ```

6. Inspect state and the resolved service graph:

   ```bash
   docker compose ps
   ```

   ```
   NAME              IMAGE                    COMMAND                  SERVICE   STATUS                 PORTS
   compose-api-1     hashicorp/http-echo:1.0  "/http-echo -text=he…"   api       Up (healthy)
   compose-db-1      postgres:16-alpine       "docker-entrypoint.s…"   db        Up
   compose-proxy-1   nginx:1.27-alpine        "/docker-entrypoint.…"   proxy     Up                     0.0.0.0:8080->80/tcp
   ```

7. Verify the request path proxy → api actually works:

   ```bash
   curl -s http://localhost:8080
   ```

   ```
   hello from api
   ```

8. Prove network isolation. The `proxy` is only on `frontend`; the `db` is only on `backend`. From the proxy, `api` resolves but `db` must **not**:

   ```bash
   docker compose exec proxy sh -c 'getent hosts api; echo "---"; getent hosts db || echo "db unreachable"'
   ```

   ```
   172.19.0.3      api
   ---
   db unreachable
   ```

**Comprehension check — Block 1**

1. `docker compose up` created `compose_frontend` rather than a network literally named `frontend`. Where does the `compose_` prefix come from, and how do you override it?
2. The `proxy` service uses `depends_on ... condition: service_healthy`. What exactly does that wait for, and why is a plain `depends_on: [api]` (list form) insufficient for a service that must not receive traffic until the API is actually serving?
3. Why could the `proxy` resolve `api` by name but not `db`, even though all three containers run under the same Compose project?
4. The `pgdata` volume is declared under the top-level `volumes:` key. What happens to the Postgres data if you run `docker compose down`? And with `docker compose down -v`?

---

## Exercise 2 — Scale a stateless service and read Compose's limits

**Goal:** see horizontal scaling and understand why Compose alone is a *single-host* tool (no scheduling across machines, no rolling update primitive).

### Steps

1. Scale the stateless `api` to three replicas without editing the file:

   ```bash
   docker compose up -d --scale api=3
   ```

   ```
   [+] Running 6/6
    ✔ Container compose-api-1    Running
    ✔ Container compose-api-2    Started
    ✔ Container compose-api-3    Started
    ...
   ```

2. Confirm three containers now back the single `api` service name:

   ```bash
   docker compose ps api
   ```

   ```
   NAME            IMAGE                    SERVICE   STATUS
   compose-api-1   hashicorp/http-echo:1.0  api       Up (healthy)
   compose-api-2   hashicorp/http-echo:1.0  api       Up (healthy)
   compose-api-3   hashicorp/http-echo:1.0  api       Up (healthy)
   ```

3. Observe that Docker's embedded DNS load-balances the service name across the three container IPs. Run the lookup a few times:

   ```bash
   for i in 1 2 3 4; do docker compose exec -T proxy getent hosts tasks.api 2>/dev/null || docker compose exec -T proxy sh -c 'nslookup api 2>/dev/null | grep Address | tail -n +2'; done
   ```

   You will see the three backend IPs cycle. (On Compose the proxy still targets a single VIP unless you round-robin at the DNS level; contrast this with Swarm's built-in VIP + IPVS in Exercise 4.)

4. Now try to do a **zero-downtime image change** the way orchestrators do it. Compose has no rolling-update verb — the closest is recreate:

   ```bash
   docker compose up -d --force-recreate api
   ```

   Watch the output: Compose stops and recreates the containers. There is no `max_parallelism`, no `order: start-first`, no automatic rollback. This gap is the whole reason Swarm's `docker service update` exists.

5. Tear the stack down (keep the data):

   ```bash
   docker compose down
   ```

**Comprehension check — Block 2**

1. `docker compose up --scale api=3` worked, but if you tried `--scale proxy=2` with the current file it would fail. Why? (Hint: look at the `ports:` mapping.)
2. Name two orchestration capabilities that Docker Compose does **not** provide on its own, and which are precisely what Swarm/Kubernetes add.
3. During step 4, was there a moment where zero `api` containers were serving? What Swarm `update_config` setting would prevent that?

---

## Exercise 3 — Bootstrap a Docker Swarm and read its control plane

**Goal:** understand Swarm architecture — managers vs workers, the Raft-replicated store, join tokens, and node roles.

### Steps

1. Initialise a swarm on the current host. Use the host's real IP for `--advertise-addr` (replace `192.168.178.20`):

   ```bash
   docker swarm init --advertise-addr 192.168.178.20
   ```

   ```
   Swarm initialized: current node (kf9c... ) is now a manager.

   To add a worker to this swarm, run the following command:

       docker swarm join --token SWMTKN-1-49nj1...-8vx...  192.168.178.20:2377

   To add a manager to this swarm, run 'docker swarm join-token manager' and follow the instructions.
   ```

2. Look at the node inventory. On a single-host lab the one node is both a manager (control plane) and a worker (runs tasks):

   ```bash
   docker node ls
   ```

   ```
   ID          HOSTNAME   STATUS   AVAILABILITY   MANAGER STATUS   ENGINE VERSION
   kf9c...*    node-a     Ready    Active         Leader           27.1.1
   ```

   The `*` marks the node you are talking to; `Leader` is the Raft leader among managers.

3. Retrieve the two join tokens. They are distinct secrets — one grants worker membership, one grants manager (control-plane) membership:

   ```bash
   docker swarm join-token worker
   docker swarm join-token manager
   ```

4. *(Optional, two-host lab.)* On a second host, join as a worker using the worker token from step 1, then re-run `docker node ls` **on the manager** to see it appear:

   ```bash
   # on host B:
   docker swarm join --token SWMTKN-1-49nj1...-8vx...  192.168.178.20:2377
   # on host A (manager):
   docker node ls
   ```

   ```
   ID          HOSTNAME   STATUS   AVAILABILITY   MANAGER STATUS   ENGINE VERSION
   kf9c...*    node-a     Ready    Active         Leader           27.1.1
   pa72...     node-b     Ready    Active                          27.1.1
   ```

5. Inspect a node to read its role, availability, and resources:

   ```bash
   docker node inspect self --format 'Role={{.Spec.Role}} Availability={{.Spec.Availability}} Addr={{.Status.Addr}}'
   ```

   ```
   Role=manager Availability=active Addr=192.168.178.20
   ```

6. Add a label to a node — labels drive placement constraints later:

   ```bash
   docker node update --label-add tier=edge node-a
   docker node inspect node-a --format '{{ .Spec.Labels }}'
   ```

   ```
   map[tier:edge]
   ```

**Comprehension check — Block 3**

1. What role does the Raft consensus algorithm play in a Swarm, and which nodes participate in it — managers, workers, or both?
2. In a production swarm you are told to run 4 managers. Why is that a *worse* choice than 3 or 5? State the fault-tolerance rule.
3. The worker join token and manager join token are different. What is the security consequence of leaking the **manager** token specifically?
4. What is the difference between a node's `AVAILABILITY` being `Active`, `Pause`, and `Drain`?

---

## Exercise 4 — Deploy, scale, and roll a `docker service`

**Goal:** use the Swarm scheduler directly — `docker service` — and observe the reconciliation loop, the routing mesh, rolling updates, and rollback.

### Steps

1. Create a replicated service. Swarm schedules tasks (containers) to satisfy the declared replica count and publishes port 8080 on the **routing mesh** (every node accepts the port and forwards to a healthy task):

   ```bash
   docker service create --name web --replicas 3 --publish published=8080,target=80 nginx:1.27-alpine
   ```

   ```
   z1k3m... 
   overall progress: 3 out of 3 tasks
   1/3: running
   2/3: running
   3/3: running
   verify: Service converged
   ```

2. List services and inspect the individual tasks and where they landed:

   ```bash
   docker service ls
   docker service ps web
   ```

   ```
   ID       NAME   MODE         REPLICAS   IMAGE               PORTS
   z1k3m…   web    replicated   3/3        nginx:1.27-alpine   *:8080->80/tcp

   ID       NAME    IMAGE               NODE     DESIRED STATE   CURRENT STATE
   a1b2…    web.1   nginx:1.27-alpine   node-a   Running         Running 40 seconds ago
   c3d4…    web.2   nginx:1.27-alpine   node-b   Running         Running 40 seconds ago
   e5f6…    web.3   nginx:1.27-alpine   node-a   Running         Running 40 seconds ago
   ```

3. Test the reconciliation loop. Kill one task's container by hand and watch Swarm replace it:

   ```bash
   docker rm -f $(docker ps --filter "name=web." -q | head -1)
   sleep 3
   docker service ps web --filter desired-state=running
   ```

   You will see a new task with an incremented name (e.g. `web.2` gets a fresh task ID) — the declared state (`3/3`) is restored automatically. The failed task shows `Shutdown/Failed` in the history.

4. Scale imperatively:

   ```bash
   docker service scale web=5
   ```

   ```
   web scaled to 5
   overall progress: 5 out of 5 tasks
   verify: Service converged
   ```

5. Configure a proper rolling update policy and apply a new image. `--update-parallelism 1` and `--update-delay 5s` mean one task at a time; `start-first` keeps capacity up:

   ```bash
   docker service update \
     --update-parallelism 1 \
     --update-delay 5s \
     --update-order start-first \
     --update-failure-action rollback \
     --image nginx:1.27 web
   ```

   ```
   image nginx:1.27 pinned to ... 
   overall progress: 5 out of 5 tasks
   1/5: running
   2/5: running
   ...
   verify: Service converged
   ```

6. Force a rollback to the previous image spec:

   ```bash
   docker service rollback web
   docker service ps web --format '{{.Name}} {{.Image}} {{.CurrentState}}' | sort -u
   ```

7. Pin a task to a labelled node using a placement constraint (recall the `tier=edge` label from Exercise 3):

   ```bash
   docker service update --constraint-add 'node.labels.tier == edge' web
   docker service ps web
   ```

   All running tasks now sit only on nodes carrying `tier=edge`.

8. Remove the service:

   ```bash
   docker service rm web
   ```

**Comprehension check — Block 4**

1. You published port 8080 and have 3 replicas across 2 nodes, but you `curl` node-B on 8080 and get a response even when *no* `web` task runs on node-B. Which Swarm feature makes that work, and what is doing the forwarding under the hood?
2. In step 3 you deleted a container with plain `docker rm -f`. Explain, in terms of *desired state* vs *observed state*, why a replacement appeared without you asking.
3. What is the practical difference between `--update-order stop-first` (the default) and `start-first`, and for which kind of workload is `start-first` unsafe?
4. `docker service scale web=5` and `docker service update --replicas 5 web` do the same thing. When would you reach for `docker service update` instead of `scale`?

---

## Exercise 5 — Deploy a full stack with `docker stack` (Compose file on Swarm)

**Goal:** connect the two halves of the objective — reuse the *same* Compose file format to deploy across a swarm via `docker stack`, using the `deploy:` key that Compose (single-host) ignores but Swarm honours.

### Steps

1. In a fresh directory, write a Swarm-aware Compose file. The `deploy:` block is the Swarm-only part — replicas, rolling-update policy, restart policy, and placement:

   ```yaml
   # stack.yml
   services:
     web:
       image: nginx:1.27-alpine
       ports:
         - "8080:80"
       deploy:
         replicas: 4
         update_config:
           parallelism: 2
           delay: 10s
           order: start-first
           failure_action: rollback
         restart_policy:
           condition: on-failure
           max_attempts: 3
         placement:
           constraints:
             - node.role == worker
       networks:
         - appnet

     redis:
       image: redis:7-alpine
       deploy:
         replicas: 1
         placement:
           constraints:
             - node.role == manager
       networks:
         - appnet

   networks:
     appnet:
       driver: overlay
   ```

2. Deploy the stack. On a single-node lab, relax the `web` constraint first (a single node is a manager, so `node.role == worker` would leave `web` unscheduled) — either remove that constraint or add `--with-registry-auth` is not needed here:

   ```bash
   docker stack deploy -c stack.yml myapp
   ```

   ```
   Creating network myapp_appnet
   Creating service myapp_redis
   Creating service myapp_web
   ```

3. List the stack, its services, and its tasks:

   ```bash
   docker stack ls
   docker stack services myapp
   docker stack ps myapp
   ```

   ```
   NAME    SERVICES
   myapp   2

   ID       NAME          MODE         REPLICAS   IMAGE
   x9…      myapp_web     replicated   4/4        nginx:1.27-alpine
   y8…      myapp_redis   replicated   1/1        redis:7-alpine
   ```

4. Confirm that the `driver: overlay` network spans the swarm (multi-host L2 over VXLAN) rather than being a local bridge:

   ```bash
   docker network ls --filter name=myapp_appnet
   ```

   ```
   NETWORK ID     NAME            DRIVER    SCOPE
   a1b2c3d4e5f6   myapp_appnet    overlay   swarm
   ```

5. Roll the whole stack by editing the image (`nginx:1.27` → `nginx:1.27.1`) in `stack.yml` and re-deploying — `docker stack deploy` is declarative and idempotent, applying the diff:

   ```bash
   sed -i 's#nginx:1.27-alpine#nginx:1.27.1-alpine#' stack.yml
   docker stack deploy -c stack.yml myapp
   docker stack ps myapp --filter desired-state=running
   ```

6. Remove the entire stack in one command:

   ```bash
   docker stack rm myapp
   ```

   ```
   Removing service myapp_web
   Removing service myapp_redis
   Removing network myapp_appnet
   ```

7. Leave the swarm (single-node cleanup):

   ```bash
   docker swarm leave --force
   ```

**Comprehension check — Block 5**

1. The `deploy:` key was *silently ignored* when you used `docker compose up` in Exercise 1, but honoured by `docker stack deploy`. What does that tell you about the division of responsibility between the Compose file *format* and the *engine* that consumes it?
2. Why did `myapp_appnet` come up with the `overlay` driver and `swarm` scope, and why is that mandatory for a multi-node service to communicate — as opposed to the default `bridge`?
3. `docker stack deploy` is described as idempotent. If you run the exact same command twice with an unchanged `stack.yml`, what happens on the second run?
4. Your `web` service declares `restart_policy: condition: on-failure, max_attempts: 3`. A task crashes 4 times in a row. What state does it end in, and how does this differ from the reconciliation you saw in Exercise 4 step 3?

---

## Exercise 6 — Awareness of Kubernetes and Helm

**Goal:** the objective only requires *awareness*. You should be able to map Swarm concepts onto Kubernetes and state what Helm is for — no cluster required.

### Steps

1. Study this concept map and be able to reproduce it. It is the single most exam-relevant table for this sub-topic:

   | Docker Swarm | Kubernetes | Purpose |
   |---|---|---|
   | Manager node | Control-plane node (`kube-apiserver`, `etcd`, `scheduler`, `controller-manager`) | Cluster brain / desired-state store |
   | Worker node | Worker node (`kubelet`, `kube-proxy`, container runtime) | Runs the workloads |
   | Raft store (in managers) | `etcd` | Consistent, replicated cluster state |
   | Task (a running container) | **Pod** (one or more containers) | Smallest schedulable unit |
   | Service (`replicated`) | **ReplicaSet** (usually via a **Deployment**) | Maintains N replicas |
   | `docker service update --image` | **Deployment** rolling update | Zero/low-downtime version change |
   | Service + routing mesh / VIP | **Service** (ClusterIP / NodePort / LoadBalancer) | Stable virtual endpoint + load-balancing |
   | Overlay network | CNI plugin (Calico, Cilium, Flannel …) | Pod-to-pod networking |
   | `docker stack deploy -c file` | `kubectl apply -f file` / a **Helm** release | Declarative multi-object deploy |

2. Read (do not run — awareness only) a minimal Kubernetes Deployment + Service equivalent to the `web` service you built in Exercise 4:

   ```yaml
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: web
   spec:
     replicas: 3
     selector:
       matchLabels: { app: web }
     template:
       metadata:
         labels: { app: web }
       spec:
         containers:
           - name: web
             image: nginx:1.27-alpine
             ports:
               - containerPort: 80
   ---
   apiVersion: v1
   kind: Service
   metadata:
     name: web
   spec:
     selector: { app: web }
     ports:
       - port: 8080
         targetPort: 80
     type: ClusterIP
   ```

   Note the correspondence: `replicas: 3` ≈ `--replicas 3`; the `Deployment` gives you the rolling update you configured with `--update-parallelism`; the `Service` plays the role of Swarm's VIP/routing mesh.

3. Understand what **Helm** adds. Helm is the *package manager* for Kubernetes: a **chart** is a parameterised, versioned bundle of manifests; `values.yaml` supplies the parameters; installing a chart creates a tracked **release** you can upgrade or roll back. The mental model:

   ```
   apt package  : Debian system   ::  Helm chart : Kubernetes cluster
   ```

   Awareness-level commands you should recognise (not execute):

   ```bash
   helm repo add bitnami https://charts.bitnami.com/bitnami
   helm install my-nginx bitnami/nginx        # create a release from a chart
   helm upgrade my-nginx bitnami/nginx --set replicaCount=3
   helm rollback my-nginx 1                    # revert to revision 1
   helm list                                   # show releases
   ```

**Comprehension check — Block 6**

1. In Kubernetes, what is the smallest unit the scheduler places, and how does it differ from a Swarm *task*?
2. Which Kubernetes object do you normally create to get *N* replicas plus rolling updates and rollback — the ReplicaSet, or the Deployment? Why the difference?
3. In one sentence: what problem does Helm solve that raw `kubectl apply -f` does not?
4. A colleague says "Docker Swarm's routing mesh is basically a Kubernetes Service." Is that a fair one-line analogy? Name one thing the analogy glosses over.

---

## Command reference (must-know for 352.4)

| Utility | Representative commands |
|---|---|
| `docker-compose.yml` | the declarative file: `services:`, `volumes:`, `networks:`, `deploy:`, `healthcheck:`, `depends_on:` |
| `docker compose` | `up -d`, `down [-v]`, `ps`, `logs -f`, `config`, `up -d --scale svc=N`, `exec` |
| `docker swarm` | `init --advertise-addr <ip>`, `join --token <t> <mgr>:2377`, `join-token worker\|manager`, `leave --force` |
| `docker node` | `ls`, `inspect self`, `update --label-add k=v`, `update --availability drain`, `promote`, `demote`, `rm` |
| `docker service` | `create`, `ls`, `ps <svc>`, `scale svc=N`, `update --image ...`, `rollback`, `logs`, `rm` |
| `docker stack` | `deploy -c file <name>`, `ls`, `services <name>`, `ps <name>`, `rm <name>` |

---

<details>
<summary><strong>Answers — click to expand</strong></summary>

### Block 1 — Compose basics
1. **The `compose_` prefix is the *project name*.** By default Compose derives it from the directory the file lives in (here `compose`). Everything Compose creates — networks, volumes, default container names — is namespaced by it so multiple copies of the same stack don't collide. Override it with `docker compose -p <name> ...`, the `COMPOSE_PROJECT_NAME` env var, or the top-level `name:` key in the file.
2. `condition: service_healthy` waits until the `api` container's **healthcheck** reports `healthy` (the `wget` probe succeeds), not merely until the container process has started. The list form `depends_on: [api]` only orders *startup* — it waits for the container to be *created/started*, which can happen seconds before the app inside is actually accepting connections. For a proxy that must not forward to a dead upstream, you need the health condition.
3. Because `proxy` and `db` share **no common user-defined network**. Docker's embedded DNS only resolves a service name for containers attached to the same network. `proxy` is on `frontend`, `db` is on `backend`, and only `api` bridges both — so `api` can reach `db`, `proxy` can reach `api`, but `proxy` cannot even resolve `db`. This is how you enforce tiered network segmentation declaratively.
4. `docker compose down` removes containers and the default networks but **keeps named volumes** — Postgres data in `pgdata` survives. `docker compose down -v` *also* removes named volumes declared in the file, destroying the database. (Anonymous/bind data behaves differently; only the named top-level volume is what `-v` targets here.)

### Block 2 — Scaling & Compose limits
1. You cannot scale `proxy` to 2 while it statically publishes host port `8080:80`, because two containers cannot bind the *same host port* on one host — the second replica has nowhere to map 8080. Stateless services you scale must either not publish a fixed host port, or you need an orchestrator with a routing mesh/load balancer (Swarm, Kubernetes) that decouples the published port from individual replicas.
2. Any two of: **multi-host scheduling** (placing containers across a cluster), **built-in rolling updates with rollback**, **self-healing/reconciliation** (restart on a *different* host after node failure), **service discovery + load-balancing across hosts (VIP/routing mesh)**, **declarative desired-state maintenance**, **secrets/configs distributed cluster-wide**. Compose is single-host and does none of these on its own.
3. Yes — `--force-recreate` performs stop-then-start, so there is a window with reduced (or, for a single replica, zero) capacity. In Swarm you avoid this with `update_config: order: start-first` (bring the new task up and healthy *before* stopping the old one) combined with `parallelism` to limit how many change at once.

### Block 3 — Swarm architecture
1. **Raft** provides consensus for the Swarm's replicated state store — the "desired state" of every service, secret, and config. Only **manager** nodes participate in Raft; workers do not hold or vote on cluster state, they just execute tasks assigned to them. One manager is elected **Leader**; the rest are followers that can take over if it fails.
2. Fault tolerance follows the quorum rule: a cluster of *N* managers tolerates the loss of `floor((N-1)/2)` and needs `floor(N/2)+1` alive for quorum. 3 managers tolerate 1 failure; **4 managers also tolerate only 1** (quorum is 3) yet add cost and a larger Raft group — so 4 buys nothing over 3 while raising the odds of losing quorum. Use an **odd** number (3 or 5). More than 7 managers is discouraged for performance.
3. The manager token grants **control-plane membership**: anyone with it can join as a manager, read the full Raft store (including secrets), schedule/kill any workload, and effectively own the cluster. Leaking the *worker* token is bad (an attacker can run tasks and read the overlay traffic they touch) but leaking the *manager* token is a total compromise. Rotate with `docker swarm join-token --rotate`.
4. `Active` — the scheduler may place new tasks on the node. `Pause` — existing tasks keep running but **no new** tasks are scheduled there. `Drain` — existing tasks are **rescheduled off** the node and no new ones are placed; used for maintenance or to keep managers task-free.

### Block 4 — docker service
1. The **routing mesh**. Every node in the swarm listens on the service's published port and, via the ingress overlay network and **IPVS** load-balancing in the kernel, forwards the connection to a healthy task *wherever it runs* — even if that node hosts none of the service's tasks. So `curl node-B:8080` works because node-B forwards you into the mesh.
2. Swarm continuously compares **desired state** (`replicas: 3`, stored in Raft) against **observed state** (tasks actually running). Deleting a container makes observed = 2, which no longer matches desired = 3, so the orchestrator's reconciliation loop schedules a replacement task to close the gap. You never asked; the controller did, because its job is to converge observed onto desired.
3. `stop-first` (default) stops the old task, then starts the new one — brief capacity dip per replica, but only one version's data-path is ever live at a time. `start-first` starts the new task and waits for it healthy *before* stopping the old — no capacity dip, but **both old and new run simultaneously**. That is unsafe for workloads that can't tolerate two versions at once (e.g. a schema-incompatible change, or a singleton that must not run twice).
4. Use `docker service update` when you're changing replicas **together with** other properties in one converged operation (image, constraints, env, update policy), or scripting a declarative change. `docker service scale` is the shorthand when replica count is the *only* thing changing (and it can scale several services in one line: `docker service scale a=3 b=5`).

### Block 5 — docker stack
1. The Compose **file format** is a data schema; the `deploy:` key is part of it, but *acting* on `deploy:` is the responsibility of the **engine** consuming the file. `docker compose` (single-host) parses the file and simply ignores `deploy:` (there is no scheduler to honour replicas/placement); `docker stack deploy` hands the same file to the **Swarm orchestrator**, which does honour it. Same format, different execution engine.
2. Multi-host services need an **overlay** network: it builds an L2 segment on top of the physical network using **VXLAN** encapsulation, so containers on different hosts share one subnet and can reach each other by service name. A default `bridge` network is **host-local** — it cannot span nodes, so tasks on different hosts couldn't communicate. Swarm-scoped overlay is created automatically for stacks; scope shows as `swarm`.
3. On the second identical run, `docker stack deploy` computes a diff between desired (the file) and current (Raft state), finds no differences, and makes **no changes** — services stay as they are (`Updating`/no-op). That is what "declarative and idempotent" means: the command expresses a target state, not a step to perform, so re-running is safe.
4. `restart_policy` governs restarting a task **in place** on failure; after `max_attempts: 3` failed restarts the task is left in a **`Failed`/`Rejected`** terminal state and is *not* retried in place. This is distinct from Exercise-4 reconciliation: that was the orchestrator creating a **brand-new task** to restore the replica count after a task was removed. Restart policy = per-task local recovery; reconciliation/replica maintenance = service-level convergence that can spawn a fresh task (often on another node).

### Block 6 — Kubernetes & Helm awareness
1. The smallest schedulable unit in Kubernetes is the **Pod** — a group of one or more containers sharing a network namespace (one IP) and optionally storage. A Swarm **task** is a single container. So a Pod is a slightly higher-level wrapper: co-scheduled containers ("sidecars") live in one Pod, which has no direct Swarm equivalent.
2. The **Deployment**. It manages ReplicaSets for you and adds the rollout machinery — versioned rolling updates, pause/resume, and rollback to a prior revision. A bare ReplicaSet only guarantees *N* replicas; it has no rollout/rollback controller. You almost never create a ReplicaSet directly.
3. Helm turns a pile of static manifests into a **parameterised, versioned, installable package (chart)** with a tracked **release**, so you can template values, share/reuse the bundle, and `upgrade`/`rollback` atomically — none of which raw `kubectl apply -f` gives you.
4. It's a *reasonable* one-liner (both provide a stable virtual endpoint and load-balance across backends), but it glosses over that a Kubernetes **Service** has multiple types (ClusterIP, NodePort, LoadBalancer, plus Ingress on top) and uses label selectors to find its Pods, whereas the Swarm routing mesh is a single mechanism (ingress overlay + IPVS VIP) tied to a published port. Different flexibility and different plumbing.

</details>

---

**Sources**
- LPI Exam 305 Objectives (352.4) — <https://www.lpi.org/our-certifications/exam-305-objectives/>
- Docker Compose file reference — <https://docs.docker.com/reference/compose-file/>
- `docker compose` CLI — <https://docs.docker.com/reference/cli/docker/compose/>
- Swarm mode overview & key concepts — <https://docs.docker.com/engine/swarm/key-concepts/>
- Raft consensus in Swarm — <https://docs.docker.com/engine/swarm/raft/>
- Routing mesh — <https://docs.docker.com/engine/swarm/ingress/>
- `docker service` / rolling updates — <https://docs.docker.com/engine/swarm/swarm-tutorial/rolling-update/>
- `docker stack deploy` — <https://docs.docker.com/reference/cli/docker/stack/deploy/>
- Kubernetes components — <https://kubernetes.io/docs/concepts/overview/components/>
- Kubernetes Deployments — <https://kubernetes.io/docs/concepts/workloads/controllers/deployment/>
- Helm documentation — <https://helm.sh/docs/>