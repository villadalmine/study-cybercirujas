# 1.3 — Understand multi-container Pod design patterns (sidecar, init and others)

## Why multi-container Pods exist

A Pod is the atomic unit of scheduling in Kubernetes: all containers in a Pod share the same **network namespace** (one IP, one `localhost`, one port space) and can share **storage volumes**. This makes the Pod the natural boundary for grouping containers that are tightly coupled — they need to be co-located, co-scheduled, and share a lifecycle, but still benefit from being packaged, versioned, and updated as separate images.

The CKAD curriculum groups these under three classic patterns — **sidecar**, **adapter**, **ambassador** — plus **init containers** as a related-but-distinct mechanism.

Key shared primitives that make all patterns work:
- **Shared network namespace**: containers in a Pod talk to each other over `localhost:<port>`.
- **Shared volumes**: an `emptyDir` (or other volume) mounted into more than one container is the usual way to pass data/files between them.
- **Independent images/lifecycles**: each container has its own image, resources, probes — but shares the Pod's `restartPolicy` (except native sidecars, see below).

---

## Init containers

Init containers run **before** any app containers start, **sequentially**, and each must **complete successfully** (exit 0) before the next one starts. Only once all init containers finish does Kubernetes start the regular containers.

Use cases:
- Wait for a dependency (database, API) to become available.
- Populate a shared volume with data/config before the app starts.
- Run a one-off setup/migration step.
- Register the Pod with an external service before app traffic starts.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: init-demo
  labels:
    app: init-demo
spec:
  initContainers:
  - name: wait-for-db
    image: busybox:1.36
    command: ['sh', '-c', 'until nc -z db-service 5432; do echo waiting for db; sleep 2; done']
  - name: fetch-config
    image: busybox:1.36
    command: ['sh', '-c', 'wget -O /config/app.conf http://config-server/app.conf']
    volumeMounts:
    - name: config-vol
      mountPath: /config
  containers:
  - name: app
    image: nginx:1.27
    volumeMounts:
    - name: config-vol
      mountPath: /etc/app-config
  volumes:
  - name: config-vol
    emptyDir: {}
```

Behavior to remember for the exam:
- Init containers run **in order**; if one fails, the kubelet restarts it according to the Pod's `restartPolicy` until it succeeds (or the Pod is considered failed for `restartPolicy: Never`).
- `kubectl get pod` shows `Init:N/M` while init containers are still running.
- Resource requests/limits for init containers are used to compute the *effective* Pod request (the highest of: sum of app containers, or any single init container — since init containers run sequentially and not concurrently with app containers).
- Readiness/liveness probes don't apply to init containers — they only care about exit code.

```console
$ kubectl get pod init-demo
NAME        READY   STATUS     RESTARTS   AGE
init-demo   0/1     Init:1/2   0          5s

$ kubectl logs init-demo -c fetch-config
```

## Native sidecar containers (init container with `restartPolicy: Always`)

Since Kubernetes 1.29 (stable in 1.33), you can declare a **sidecar as a special init container** by setting `restartPolicy: Always` on it. This is the modern, curriculum-relevant way to run sidecars:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: sidecar-log-shipper
spec:
  initContainers:
  - name: log-shipper
    image: busybox:1.36
    restartPolicy: Always        # <-- makes this a "sidecar" init container
    command: ['sh', '-c', 'tail -F /var/log/app.log']
    volumeMounts:
    - name: logs
      mountPath: /var/log
  containers:
  - name: app
    image: myapp:1.0
    volumeMounts:
    - name: logs
      mountPath: /var/log
  volumes:
  - name: logs
    emptyDir: {}
```

Why this matters:
- It starts **before** the main containers (like a normal init container) and Kubernetes waits for it to be **`Running`** (not "completed") before starting the app containers — useful when the sidecar must be ready first (e.g. a proxy that app traffic depends on).
- It keeps running **alongside** the app containers for the whole Pod lifetime.
- It is terminated **after** app containers on Pod shutdown (reverse order), so it can keep shipping logs/metrics during graceful shutdown of the app.
- It does **not** block Pod completion for Jobs — a Job is considered complete once all *non-sidecar* containers exit, even if the sidecar is still running.

Before 1.29, the common workaround was simply declaring the "sidecar" as a normal entry under `containers:` — this still works and is the pattern you'll see in most existing manifests/exam prep material, but it lacks the ordered-startup and Job-completion benefits above.

---

## The three multi-container design patterns

### 1. Sidecar pattern

A helper container that **extends or enhances** the main container without the main container needing to know about it — typically by sharing a volume or the network namespace.

Classic example — shipping logs from a Pod that only writes to a local file:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: sidecar-example
spec:
  containers:
  - name: app
    image: busybox:1.36
    command: ['sh', '-c', 'while true; do echo "$(date) app log line" >> /var/log/app.log; sleep 5; done']
    volumeMounts:
    - name: shared-logs
      mountPath: /var/log
  - name: log-agent
    image: busybox:1.36
    command: ['sh', '-c', 'tail -F /var/log/app.log']
    volumeMounts:
    - name: shared-logs
      mountPath: /var/log
  volumes:
  - name: shared-logs
    emptyDir: {}
```

```console
$ kubectl apply -f sidecar-example.yaml
$ kubectl get pod sidecar-example
NAME              READY   STATUS    RESTARTS   AGE
sidecar-example   2/2     Running   0          10s

$ kubectl logs sidecar-example -c log-agent
Mon Jul 13 10:20:01 UTC app log line
Mon Jul 13 10:20:06 UTC app log line
```

Other sidecar examples: a service mesh proxy (Envoy/Istio), a config-reloader (watches a ConfigMap-mounted file and signals the app to reload), a metrics exporter.

### 2. Adapter pattern

A sidecar variant whose job is to **normalize/transform** the output of the main container into a common format expected by the outside world — the app itself doesn't need to know about the target format.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: adapter-example
spec:
  containers:
  - name: app
    image: myapp:1.0        # writes metrics in a custom text format to /metrics/raw.txt
    volumeMounts:
    - name: metrics
      mountPath: /metrics
  - name: metrics-adapter
    image: metrics-adapter:1.0   # reads raw.txt, exposes /metrics in Prometheus format on :9090
    volumeMounts:
    - name: metrics
      mountPath: /metrics
    ports:
    - containerPort: 9090
  volumes:
  - name: metrics
    emptyDir: {}
```

The adapter reads the raw output on the shared volume and re-exposes it in a standardized format (e.g. Prometheus exposition format) via `localhost:9090`, without the application being aware of Prometheus at all.

### 3. Ambassador pattern

A sidecar that acts as a **network proxy** between the main container and the outside world, so the main container only ever talks to `localhost`. The ambassador handles the complexity of discovering, connecting to, retrying, or load-balancing across external/backend services.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: ambassador-example
spec:
  containers:
  - name: app
    image: myapp:1.0
    env:
    - name: DB_HOST
      value: "127.0.0.1"      # app always connects to localhost
    - name: DB_PORT
      value: "6379"
  - name: redis-ambassador
    image: ambassador-proxy:1.0
    ports:
    - containerPort: 6379
    env:
    - name: BACKEND_HOST      # ambassador knows how to reach the real backend
      value: "redis-primary.prod.svc.cluster.local"
```

The application connects to `127.0.0.1:6379` unconditionally; the ambassador container forwards the connection to the real Redis endpoint. This is what lets you run the exact same app image against different environments (dev/staging/prod) by only changing the ambassador's configuration, not the app.

### Sidecar vs. adapter vs. ambassador — quick distinction

| Pattern    | Direction of data flow          | Purpose                                             |
|------------|----------------------------------|------------------------------------------------------|
| Sidecar    | General helper, any direction    | Extends main container's capability (logging, sync)  |
| Adapter    | App → outside                    | Normalizes/transforms the app's *output*              |
| Ambassador | App → outside (via proxy)        | Simplifies/abstracts the app's *outbound connections* |

---

## Practical exam tips

- Use `kubectl exec -it <pod> -c <container>` and `kubectl logs <pod> -c <container>` to target a specific container — you must specify `-c` when a Pod has more than one container.
- `kubectl describe pod <pod>` shows all containers and their individual statuses, including init container completion.
- Generate a multi-container skeleton quickly:
  ```console
  $ kubectl run app --image=nginx --dry-run=client -o yaml > pod.yaml
  ```
  then hand-edit to add the second container/init container block (there's no `kubectl` flag to add a sidecar directly).
- Remember `restartPolicy: Always` inside `initContainers[]` is what makes an init container a sidecar — a very likely point tested directly given it's a relatively recent, exam-relevant feature.
- Volume type for sharing data between containers in the exam is almost always `emptyDir` unless persistence across Pod restarts is required.

---

## Referencias

- Init Containers — https://kubernetes.io/docs/concepts/workloads/pods/init-containers/
- Sidecar Containers — https://kubernetes.io/docs/concepts/workloads/pods/sidecar-containers/
- Pod Overview — https://kubernetes.io/docs/concepts/workloads/pods/
- Communicating Between Containers in the Same Pod (tutorial) — https://kubernetes.io/docs/tasks/access-application-cluster/communicate-containers-same-pod-shared-volume/
- CKAD Curriculum v1.35 (CNCF) — https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf