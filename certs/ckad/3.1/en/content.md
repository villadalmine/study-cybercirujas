# 3.1 — Implement probes and health checks

## Why do probes exist?

Kubernetes needs to know two things about every container: whether it is **alive** (should it be restarted?) and whether it is **ready** (can it accept traffic?). A process can be running and yet be broken: a deadlock, a lost database connection, or a cache warm-up taking minutes. **Probes** are periodic checks executed by the **kubelet** against each container to make those decisions automatically.

There are three types of probes, and understanding the differences between them is one of the most tested areas on the exam:

| Probe | Question Answered | Action on Failure |
|---|---|---|
| `livenessProbe` | Is the container still working? | kubelet **restarts** the container (according to `restartPolicy`) |
| `readinessProbe` | Can it receive traffic right now? | Pod is **removed from Service Endpoints** (not restarted) |
| `startupProbe` | Has it finished booting? | Restarts container; while running, **disables** liveness and readiness probes |

Key takeaway: a failing `readinessProbe` **never restarts** the container, it only stops sending traffic to it. A failing `livenessProbe` **does restart** it. Confusing this leads to dangerous setups (for example, using a liveness probe to check an external dependency: if the database drops, all Pods enter a restart loop without fixing anything).

## Check Mechanisms

Every probe (regardless of type) uses one of these four mechanisms:

### 1. `httpGet`

The kubelet sends an HTTP GET request to the container. Any response code **between 200 and 399** counts as success.

```yaml
livenessProbe:
  httpGet:
    path: /healthz
    port: 8080
    httpHeaders:
    - name: Custom-Header
      value: Awesome
```

The `port` can be a number or a **port name** declared in `containerPort` (e.g. `port: http`), which appears frequently in exam YAMLs.

### 2. `exec`

The kubelet executes a command inside the container. **Exit code 0 = success**, any other value = failure.

```yaml
livenessProbe:
  exec:
    command:
    - cat
    - /tmp/healthy
```

### 3. `tcpSocket`

The kubelet attempts to open a TCP connection to the specified port. If the connection opens, the probe passes. Useful for non-HTTP services (databases, message brokers).

```yaml
readinessProbe:
  tcpSocket:
    port: 3306
```

### 4. `grpc`

For applications implementing the [gRPC Health Checking Protocol](https://grpc.io/docs/guides/health-checking/). Stable since Kubernetes 1.27.

```yaml
livenessProbe:
  grpc:
    port: 2379
```

## Configuration Parameters

All probe types share these fields, controlling timing and fault tolerance:

| Field | Default | Meaning |
|---|---|---|
| `initialDelaySeconds` | 0 | Seconds to wait after container starts before first probe execution |
| `periodSeconds` | 10 | Frequency in seconds between probe executions |
| `timeoutSeconds` | 1 | Seconds before probe execution times out |
| `failureThreshold` | 3 | Consecutive failures needed to declare probe failed |
| `successThreshold` | 1 | Consecutive successes to mark probe healthy again (must be 1 for liveness and startup) |

Complete example with explicit timing:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: web
spec:
  containers:
  - name: web
    image: nginx:1.27
    ports:
    - name: http
      containerPort: 80
    readinessProbe:
      httpGet:
        path: /
        port: http
      initialDelaySeconds: 5
      periodSeconds: 5
      failureThreshold: 2
    livenessProbe:
      httpGet:
        path: /
        port: http
      initialDelaySeconds: 15
      periodSeconds: 10
      timeoutSeconds: 2
```

With this configuration, the container will be marked unready after `2 × 5 = 10` seconds of failures, and will be restarted after `3 × 10 = 30` seconds of liveness failures (default `failureThreshold: 3` applies where unoverridden).

## `startupProbe`: Slow-starting Applications

The classic problem: a legacy application takes up to 5 minutes to start. If `livenessProbe` starts checking before startup completes, it kills the container and the Pod enters an infinite restart loop. Naive fixes (`initialDelaySeconds: 300`) also penalize fast startups.

The `startupProbe` solves this: until it passes, **liveness and readiness probes remain disabled**. Once it passes for the first time, it stops running and the other probes take over.

```yaml
startupProbe:
  httpGet:
    path: /healthz
    port: 8080
  failureThreshold: 30
  periodSeconds: 10
livenessProbe:
  httpGet:
    path: /healthz
    port: 8080
  periodSeconds: 10
```

Here the application has up to `30 × 10 = 300` seconds to start. If it does not respond in that time, it restarts. Once started, liveness monitors it with an aggressive 10-second cycle.

## Guided Example: Observing a Failing Liveness Probe

This manifest (adapted from official documentation) creates a file, deletes it after 30 seconds, and lets the probe fail:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: liveness-exec
spec:
  containers:
  - name: liveness
    image: registry.k8s.io/busybox
    args:
    - /bin/sh
    - -c
    - touch /tmp/healthy; sleep 30; rm -f /tmp/healthy; sleep 600
    livenessProbe:
      exec:
        command:
        - cat
        - /tmp/healthy
      initialDelaySeconds: 5
      periodSeconds: 5
```

Apply and inspect events:

```bash
kubectl apply -f liveness-exec.yaml
kubectl describe pod liveness-exec
```

After ~35 seconds, the `Events` section displays something like:

```
Events:
  Type     Reason     Age    From     Message
  ----     ------     ----   ----     -------
  Normal   Started    50s    kubelet  Started container liveness
  Warning  Unhealthy  15s    kubelet  Liveness probe failed: cat: can't open '/tmp/healthy': No such file or directory
  Normal   Killing    15s    kubelet  Container liveness failed liveness probe, will be restarted
```

And restart count increases:

```bash
kubectl get pod liveness-exec
NAME            READY   STATUS    RESTARTS      AGE
liveness-exec   1/1     Running   1 (10s ago)   80s
```

## Readiness and Services: Practical Impact

When a Pod's `readinessProbe` fails, its IP is removed from the Service's `EndpointSlices`. Verify with:

```bash
kubectl get endpointslices -l kubernetes.io/service-name=web
NAME        ADDRESSTYPE   PORTS   ENDPOINTS                AGE
web-abc12   IPv4          80      10.244.1.5,10.244.2.8    5m
```

If a Pod becomes unready, it disappears from `ENDPOINTS` and `kubectl get pods` shows `READY 0/1` with `STATUS Running` — running but taking no traffic. This is a typical exam scenario: *"the Service does not respond but Pods are Running"* → check readiness.

Furthermore, in a `Deployment` with `RollingUpdate`, new Pods do not count as available until their readiness passes, so misconfigured readiness can **block a rollout** (visible with `kubectl rollout status deployment/web`).

## Exam Day Efficiency Tips

No `kubectl` flag generates probes directly; the efficient workflow is generating base YAML and editing:

```bash
kubectl run web --image=nginx --dry-run=client -o yaml > pod.yaml
# edit pod.yaml and add livenessProbe/readinessProbe block
kubectl apply -f pod.yaml
```

To avoid writing blocks from memory, built-in documentation helps:

```bash
kubectl explain pod.spec.containers.livenessProbe
kubectl explain pod.spec.containers.readinessProbe.httpGet
```

Common Mistakes Checklist:

- **Wrong Port**: Probe points to Service port instead of `containerPort`. Probes run **against the container**, not the Service.
- **Non-existent Path**: `/health` vs `/healthz` — check exact failure message in `kubectl describe pod` (includes HTTP code received).
- **Liveness Checking External Dependencies**: Causes cascading restarts. Liveness must only check container internal state.
- **`successThreshold` not 1** in liveness or startup: rejected by API server.
- **Too Aggressive Timing**: `timeoutSeconds: 1` (default) is short under heavy load; latency spikes can trigger restarts.

## Summary

- **Liveness** → restarts; **readiness** → removes from Service; **startup** → protects startup by disabling the other two.
- Four mechanisms: `httpGet` (200–399), `exec` (exit 0), `tcpSocket` (open connection), `grpc`.
- Effective failure timing is `periodSeconds × failureThreshold` (plus `initialDelaySeconds` at start).
- Troubleshooting: `kubectl describe pod` (Events section), `kubectl get pods` (READY/RESTARTS columns), `kubectl get endpointslices`.

## References

- Configure Liveness, Readiness and Startup Probes — https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/
- Pod Lifecycle (container probes) — https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/#container-probes
- API reference: Probe (v1 core) — https://kubernetes.io/docs/reference/kubernetes-api/workload-resources/pod-v1/#Probe
- gRPC Health Checking Protocol — https://grpc.io/docs/guides/health-checking/
- CKAD Curriculum v1.35 (CNCF) — https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf
