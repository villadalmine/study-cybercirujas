# 3.2 — Use built-in CLI tools to monitor Kubernetes applications

**Exam Weight: 4%**

Monitoring applications in Kubernetes during the CKAD exam means one thing: mastering `kubectl` and its observability subcommands. There is no Prometheus or Grafana in the exam; the "built-in" tools are `kubectl top`, `kubectl get`, `kubectl describe`, `kubectl events`, and `kubectl logs`. This topic focuses on resource usage metrics (CPU and memory) and observing object status.

## 1. The Metrics Pipeline: metrics-server

`kubectl top` does not work standalone: it relies on the **Metrics API** (`metrics.k8s.io`), which in practice is implemented by **metrics-server**. This component collects CPU and memory metrics from the **kubelet** on each node and exposes them via the API server.

```
kubelet (cAdvisor) ──> metrics-server ──> Metrics API ──> kubectl top
```

In the exam, the cluster comes with metrics-server pre-installed. If you see this error in your lab environment, it means metrics-server is missing:

```
error: Metrics API not available
```

You can verify that the Metrics API is available with:

```bash
kubectl get apiservices | grep metrics
# v1beta1.metrics.k8s.io   kube-system/metrics-server   True   20d
```

Key points regarding metrics:

- They are **instantaneous** (current usage snapshots), not time series. There is no historical data stored.
- CPU is measured in **cores** or **millicores** (`m`): `250m` = 0.25 CPU cores.
- Memory is measured in bytes with binary suffixes: `Mi` (mebibytes), `Gi` (gibibytes).

## 2. kubectl top: CPU and Memory Usage

### 2.1 Nodes

```bash
kubectl top nodes
```

Typical output:

```
NAME           CPU(cores)   CPU(%)   MEMORY(bytes)   MEMORY(%)
controlplane   231m         11%      1913Mi          49%
node01         89m          4%       1023Mi          26%
```

- `CPU(%)` and `MEMORY(%)` are relative to the node's **allocatable capacity**.
- Useful for answering questions such as *"identify the node with the highest memory consumption and save its name to a file"*.

### 2.2 Pods

```bash
kubectl top pods                      # current namespace
kubectl top pods -n prod              # specific namespace
kubectl top pods -A                   # all namespaces
kubectl top pods -l app=web           # filtered by label selector
```

Typical output:

```
NAME                   CPU(cores)   MEMORY(bytes)
web-5f7b9d6c4-abcde    12m          45Mi
web-5f7b9d6c4-fghij    250m         310Mi
worker-0               890m         1200Mi
```

### 2.3 Exam-solving Flags

**Sorting** by consumption (very common on the exam):

```bash
kubectl top pods --sort-by=cpu
kubectl top pods --sort-by=memory
```

Sorting is **descending**: the pod consuming the most appears first. A typical exercise pattern:

```bash
# "Find the pod consuming the most CPU with label app=stress
#  and write its name to /tmp/answer.txt"
kubectl top pods -l app=stress --sort-by=cpu --no-headers | head -1 | awk '{print $1}' > /tmp/answer.txt
```

**Container Breakdown** (for multi-container pods or sidecars):

```bash
kubectl top pods web-5f7b9d6c4-abcde --containers
```

```
POD                   NAME        CPU(cores)   MEMORY(bytes)
web-5f7b9d6c4-abcde   app         10m          38Mi
web-5f7b9d6c4-abcde   log-agent   2m           7Mi
```

Other useful flags: `--no-headers` (eases scripting) and `--sum` (adds a row displaying totals).

### 2.4 Relationship with Requests and Limits

`kubectl top` shows **actual usage**, not manifest declarations. To compare against `requests`/`limits`, combine it with:

```bash
kubectl describe pod web-5f7b9d6c4-abcde | grep -A4 Limits
kubectl get pod web-5f7b9d6c4-abcde -o jsonpath='{.spec.containers[*].resources}'
```

This is vital for diagnosis: a container whose memory usage approaches its `limit` is a candidate for **OOMKill**; a pod using significantly more CPU than its `request` may suffer **throttling** if a CPU `limit` is set.

## 3. Observing Status with kubectl get

`kubectl get` is the quick application health check:

```bash
kubectl get pods
```

```
NAME                   READY   STATUS             RESTARTS      AGE
web-5f7b9d6c4-abcde    1/1     Running            0             2d
api-7c9f8b5d6-xyz12    0/1     CrashLoopBackOff   7 (45s ago)   12m
```

What to look for:

- **READY `0/1`**: container runs but **readiness probe** fails, or container did not complete startup.
- High **RESTARTS**: **liveness probe** fails or process crashes (`CrashLoopBackOff`).
- **STATUS**: `Pending` (scheduling failed or missing image), `ImagePullBackOff`, `OOMKilled` (visible in `describe`), etc.

Useful modes for continuous monitoring:

```bash
kubectl get pods -w                          # --watch: change stream
kubectl get pods -o wide                     # appends IP and node
kubectl get deploy web                       # READY/UP-TO-DATE/AVAILABLE replicas
kubectl rollout status deployment/web       # waits for rollout convergence
```

## 4. kubectl describe and Events

When `get` indicates a problem, `describe` explains why:

```bash
kubectl describe pod api-7c9f8b5d6-xyz12
```

At the end of output, the **Events** section records cluster actions regarding that object:

```
Events:
  Type     Reason     Age                 From               Message
  ----     ------     ----                ----               -------
  Normal   Scheduled  12m                 default-scheduler  Successfully assigned default/api-... to node01
  Normal   Pulled     10m (x5 over 12m)   kubelet            Container image "api:2.1" already present on machine
  Warning  BackOff    2m (x32 over 11m)   kubelet            Back-off restarting failed container
  Warning  Unhealthy  90s (x8 over 11m)   kubelet            Liveness probe failed: HTTP probe failed with statuscode: 500
```

You can also query events directly without targeting a specific object:

```bash
kubectl events                                   # current namespace events
kubectl events --for pod/api-7c9f8b5d6-xyz12     # specific object events
kubectl events --types=Warning                   # warnings only
kubectl events -w                                # live watch
```

`kubectl events` (stable since v1.26) replaces legacy `kubectl get events`, offering better default chronological ordering. Legacy syntax still works:

```bash
kubectl get events --sort-by=.metadata.creationTimestamp
```

Events are retained for **one hour** by default: if an issue occurred earlier, it will not be listed.

## 5. kubectl logs as a Monitoring Tool

Logs are covered in depth in topic 3.3, but for monitoring remember streaming options:

```bash
kubectl logs -f deploy/web                     # live tail stream
kubectl logs --since=5m api-7c9f8b5d6-xyz12    # last 5 minutes
kubectl logs --tail=50 -l app=web --prefix     # last 50 lines from all pods matching selector
kubectl logs api-7c9f8b5d6-xyz12 --previous    # previous instance (crucial in CrashLoopBackOff)
```

## 6. Recommended Troubleshooting Workflow for the Exam

1. `kubectl get pods` — which pod is unhealthy? (READY, STATUS, RESTARTS)
2. `kubectl describe pod <pod>` — what do **Events** say? (probes, image, scheduling, OOM)
3. `kubectl logs <pod> [--previous]` — what does application output say?
4. `kubectl top pods --sort-by=...` — is it a resource usage issue? Compare with `requests`/`limits`.

Practice `--sort-by`, `-l`, `--containers`, and `--no-headers` flags until memorized: questions on this topic are typically quick ("identify highest consuming pod and save to file") and yield fast points if syntax is familiar.

## References

- CNCF — CKAD Curriculum v1.35: https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf
- Kubernetes — Resource metrics pipeline: https://kubernetes.io/docs/tasks/debug/debug-cluster/resource-metrics-pipeline/
- Kubernetes — `kubectl top`: https://kubernetes.io/docs/reference/kubectl/generated/kubectl_top/
- Kubernetes — `kubectl events`: https://kubernetes.io/docs/reference/kubectl/generated/kubectl_events/
- Kubernetes — Debug running pods: https://kubernetes.io/docs/tasks/debug/debug-application/debug-running-pod/
- Kubernetes — Tools for monitoring resources: https://kubernetes.io/docs/tasks/debug/debug-cluster/resource-usage-monitoring/
- metrics-server (SIG Instrumentation): https://github.com/kubernetes-sigs/metrics-server
- Kubernetes — kubectl Quick Reference: https://kubernetes.io/docs/reference/kubectl/quick-reference/
