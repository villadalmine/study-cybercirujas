# Debugging in Kubernetes

## Introduction

Debugging applications in Kubernetes requires combining multiple information sources: Pod status, container logs, cluster events, and in deeper cases, node-level inspection tools. The CKAD exam evaluates the ability to rapidly diagnose why a Pod fails to start, why a container restarts, or why an application stops responding, using exclusively `kubectl` and a few complementary tools.

The typical debugging workflow follows this sequence:

1. `kubectl get pods` → check general status (`STATUS`, `RESTARTS`).
2. `kubectl describe pod <pod>` → check `Events` and `Conditions`.
3. `kubectl logs <pod> [-c <container>]` → inspect application output.
4. `kubectl exec -it <pod> -- sh` → interactive inspection inside container.
5. `kubectl debug` → when the container lacks a shell or tools, or when issues are at node level.

## Pod States and Diagnosis

### Pending

The Pod has not been scheduled or its containers failed to start. Diagnosed with `describe`:

```bash
$ kubectl get pods
NAME        READY   STATUS    RESTARTS   AGE
web-7d9f8   0/1     Pending   0          2m

$ kubectl describe pod web-7d9f8
...
Events:
  Type     Reason            Age   From               Message
  ----     ------            ----  ----               -------
  Warning  FailedScheduling  2m    default-scheduler  0/3 nodes are available:
           3 Insufficient cpu.
```

Typical root causes: CPU/memory `requests` that no single node can satisfy, `nodeSelector`/`affinity` matching no nodes, `taints` missing matching `toleration`, or an unbindable `PersistentVolumeClaim`.

### ImagePullBackOff / ErrImagePull

```bash
$ kubectl describe pod web-7d9f8
Events:
  Warning  Failed     Failed to pull image "nginx:1.99": rpc error:
           code = NotFound desc = failed to pull and unpack image
  Normal   BackOff    Back-off pulling image "nginx:1.99"
```

Commonly caused by a non-existent tag, repository typo, or missing `imagePullSecrets` for a private registry.

### CrashLoopBackOff

The container repeatedly starts and crashes. Kubernetes waits progressively longer between attempts (exponential backoff). Checking logs from the **previous** attempt is crucial, as the current container instance may have just restarted with no output yet:

```bash
$ kubectl logs web-7d9f8 --previous
Error: cannot connect to database at db:5432: connection refused
```

Also check the `exit code` of the last terminated container:

```bash
$ kubectl describe pod web-7d9f8
Last State:  Terminated
  Reason:    Error
  Exit Code: 1
```

Common exit codes to recognize:

| Exit code | Meaning |
|---|---|
| `0` | Normal clean exit, no error |
| `1` | General application error |
| `137` | `SIGKILL` (128+9) — often caused by `OOMKilled` or `kubectl delete --force` |
| `143` | `SIGTERM` (128+15) — standard termination via shutdown/rolling update |

### OOMKilled

```bash
$ kubectl describe pod web-7d9f8
Last State:   Terminated
  Reason:     OOMKilled
  Exit Code:  137
```

The container exceeded its `resources.limits.memory`. Solution: increase memory limit or fix an application memory leak.

## `kubectl logs`

Most frequently used options on the exam:

```bash
# Current container logs
kubectl logs web-7d9f8

# Specific container in a multi-container Pod
kubectl logs web-7d9f8 -c sidecar

# Previous container logs (useful in CrashLoopBackOff)
kubectl logs web-7d9f8 --previous

# Follow live stream
kubectl logs -f web-7d9f8

# Last N lines
kubectl logs web-7d9f8 --tail=50

# Logs from last 10 minutes
kubectl logs web-7d9f8 --since=10m

# Logs across all containers in a Deployment (requires label selector)
kubectl logs -l app=web --all-containers=true --prefix=true
```

## `kubectl exec`

Executes commands inside a running container, useful for inspecting filesystem, environment variables, network connectivity, or processes:

```bash
# Interactive shell
kubectl exec -it web-7d9f8 -- sh

# One-off command
kubectl exec web-7d9f8 -- env

# Target specific container
kubectl exec -it web-7d9f8 -c sidecar -- bash

# Test connectivity to another Service from inside the cluster
kubectl exec -it web-7d9f8 -- curl -sv http://backend-svc:8080/health
```

`kubectl exec` requires a shell inside the container image. Minimal "distroless" or `scratch` images lack shells, leading to the next tool.

## `kubectl debug` and Ephemeral Containers

`kubectl debug` (stable since 1.23+) solves debugging when containers lack shells, network tools, or crash before `exec` can attach.

### Ephemeral Container in an Existing Pod

Injects a temporary debug container into a running Pod, sharing namespaces (network, PID as configured):

```bash
kubectl debug web-7d9f8 -it --image=busybox:1.36 --target=web
```

`--target` makes the ephemeral container share process namespace with target container, allowing process inspection via `ps` even if original image lacks `ps`.

### Copying a Pod to Debug Without Impacting Original

Useful when avoiding changes to production Pods or when containers crash immediately:

```bash
kubectl debug web-7d9f8 -it --image=busybox:1.36 --copy-to=web-debug --container=app -- sh
```

Creates `web-debug`, a copy of the Pod, replacing the specified container to attach an interactive shell.

### Node Debugging

Spins up a privileged Pod on the target node, mounting node root filesystem at `/host` to inspect host OS, `crictl`, or `journalctl`:

```bash
kubectl debug node/worker-2 -it --image=busybox:1.36

# Inside debug Pod:
chroot /host
crictl ps -a
journalctl -u kubelet -n 100
```

## Probe Debugging (Liveness / Readiness / Startup)

If a Pod remains `Running` but `READY 0/1`, the culprit is usually `readinessProbe`:

```bash
$ kubectl get pods
NAME        READY   STATUS    RESTARTS   AGE
web-7d9f8   0/1     Running   0          5m

$ kubectl describe pod web-7d9f8
Events:
  Warning  Unhealthy  30s (x5 over 2m)  kubelet  Readiness probe failed:
           HTTP probe failed with statuscode: 503
```

If instead `RESTARTS` increments alongside `Unhealthy` events followed by `Killing`, `livenessProbe` is terminating the container:

```bash
Warning  Unhealthy  Liveness probe failed: Get "http://10.244.1.5:8080/healthz":
                     dial tcp 10.244.1.5:8080: connect: connection refused
Normal   Killing    Container app failed liveness probe, will be restarted
```

Common causes: `initialDelaySeconds` too short for actual app startup time (better solved with `startupProbe`), incorrect probe path/port, or insufficient `timeoutSeconds` under load.

## Resource Debugging (`kubectl top`)

Requires `metrics-server` installed in cluster:

```bash
$ kubectl top pod web-7d9f8
NAME        CPU(cores)   MEMORY(bytes)
web-7d9f8   950m         480Mi

$ kubectl top node
NAME       CPU(cores)   CPU%   MEMORY(bytes)   MEMORY%
worker-1   1800m        90%    3200Mi          82%
```

Useful for confirming CPU throttling (usage pinned near `limit`) or memory pressure preceding an `OOMKilled` event.

## Services and Network Debugging

When a Pod cannot reach a Service, follow this troubleshooting checklist:

```bash
# Check if Service has endpoints
kubectl get endpoints backend-svc
# If <none> appears, Service selector matches no Pod labels

# Compare Service selector against actual Pod labels
kubectl get svc backend-svc -o jsonpath='{.spec.selector}'
kubectl get pods --show-labels

# Verify target Pod responds locally
kubectl exec -it backend-7d9f8 -- curl -s localhost:8080/health

# Test internal DNS resolution from another Pod
kubectl exec -it web-7d9f8 -- nslookup backend-svc.default.svc.cluster.local

# Temporarily forward port to test from local machine
kubectl port-forward pod/backend-7d9f8 8080:8080
```

If `nslookup` fails, inspect `coredns` status: `kubectl -n kube-system get pods -l k8s-app=kube-dns` and review its logs.

## `kubectl get events`

Global namespace events view sorted by timestamp, useful for correlating issues across objects (Pod, ReplicaSet, Node):

```bash
kubectl get events --sort-by=.metadata.creationTimestamp
kubectl get events --field-selector type=Warning
```

## Command Summary Table

| Command | Purpose |
|---|---|
| `kubectl describe pod <pod>` | Events, Conditions, Last State, exit code |
| `kubectl logs [-c] [--previous] [-f]` | Application output |
| `kubectl exec -it <pod> -- sh` | Interactive inspection (requires container shell) |
| `kubectl debug <pod> --copy-to=... --target=...` | Debug without shell or impacting original Pod |
| `kubectl debug node/<node>` | Node-level inspection (`crictl`, `journalctl`) |
| `kubectl top pod\|node` | CPU/memory usage (requires metrics-server) |
| `kubectl get endpoints <svc>` | Verify Service has backend endpoints |
| `kubectl port-forward` | Test Pod/Service without external exposure |

## References

- CNCF, *CKAD Curriculum v1.35*: https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf
- Kubernetes docs, *Debug Pods*: https://kubernetes.io/docs/tasks/debug/debug-application/debug-pods/
- Kubernetes docs, *Debug Running Pods*: https://kubernetes.io/docs/tasks/debug/debug-application/debug-running-pod/
- Kubernetes docs, *Debug with ephemeral containers*: https://kubernetes.io/docs/tasks/debug/debug-application/debug-ephemeral-container/
- Kubernetes docs, *Debugging Kubernetes Nodes with crictl*: https://kubernetes.io/docs/tasks/debug/debug-cluster/crictl/
- Kubernetes docs, *Debug a StatefulSet*: https://kubernetes.io/docs/tasks/debug/debug-application/debug-statefulset/
- Kubernetes docs, *Troubleshoot Services*: https://kubernetes.io/docs/tasks/debug/debug-application/debug-service/
- Kubernetes docs, *Resource Metrics Pipeline (metrics-server)*: https://kubernetes.io/docs/tasks/debug/debug-cluster/resource-metrics-pipeline/
- Kubernetes docs, *Configure Liveness, Readiness and Startup Probes*: https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/
- `kubectl` reference: https://kubernetes.io/docs/reference/generated/kubectl/kubectl-commands
