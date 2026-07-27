# Container Logs in Kubernetes (CKAD 1.35 — 3.3)

## 1. The Kubernetes Logging Model

Kubernetes does not have a native logging system that persists or indexes logs by itself. The contract is simple: any process running inside a container must write its logs to **stdout** and **stderr**. The **container runtime** (containerd, CRI-O) captures those streams and persists them as files on the node (typically under `/var/log/containers/` and `/var/log/pods/`, with symlinks to `/var/lib/docker/containers/` or containerd equivalents).

`kubectl logs` is simply a client requesting those log files from the node's **kubelet** via the Kubelet API. There is no aggregation, persistent storage, or indexing: those concerns are outside the core cluster scope and are solved with logging architectures (Section 8).

Practical implication: if your application writes logs to an internal file inside the container instead of stdout/stderr, `kubectl logs` will show nothing.

## 2. `kubectl logs` — Basic Usage

```bash
kubectl logs my-pod
```

Typical output:

```
2026-07-13T10:15:02Z INFO  Starting server on :8080
2026-07-13T10:15:02Z INFO  Connected to database
2026-07-13T10:15:05Z WARN  Slow query detected (320ms)
```

If the pod contains a single container, specifying its name is unnecessary. If it contains more than one, `kubectl logs` fails and prompts for a container name:

```bash
kubectl logs my-pod
```
```
error: a container name must be specified for pod my-pod, choose one of: [app sidecar-log]
```

## 3. Multi-container Pods

```bash
kubectl logs my-pod -c app
kubectl logs my-pod --container=sidecar-log
```

To view logs from **all** containers in a pod at once (including completed init containers if applicable):

```bash
kubectl logs my-pod --all-containers=true
```

Each log line can be prefixed with the container name when combined with `--prefix`:

```bash
kubectl logs my-pod --all-containers=true --prefix
```
```
[pod/my-pod/app] 2026-07-13T10:15:02Z INFO  Starting server on :8080
[pod/my-pod/sidecar-log] 2026-07-13T10:15:02Z INFO  Tailing /var/log/app.log
```

For logs from an **init container**:

```bash
kubectl logs my-pod -c init-db
```

## 4. Logs from a Crash or Previous Restart

When a container crashes and Kubernetes restarts it (`CrashLoopBackOff`), logs from the current execution attempt may be uninformative because the process just started. Logs from the previous attempt can be retrieved using `--previous` (or `-p`):

```bash
kubectl get pods
```
```
NAME      READY   STATUS             RESTARTS   AGE
my-pod    0/1     CrashLoopBackOff   3          4m
```

```bash
kubectl logs my-pod --previous
```
```
panic: connection refused to db:5432
goroutine 1 [running]:
main.connectDB(...)
	/app/main.go:42
```

This is one of the most common patterns on the exam: troubleshooting a `CrashLoopBackOff` by inspecting the terminated container's log, rather than the newly restarted one.

## 5. Real-Time Streaming (`--follow`)

```bash
kubectl logs -f my-pod
```

Keeps the connection open and streams new log lines as they are generated, similar to `tail -f`. Can be combined with `-c` for a specific container:

```bash
kubectl logs -f my-pod -c app
```

With `--follow` on a pod that restarts, the stream connection breaks when the container dies; you must re-run the command (or use `--previous` to see what happened).

## 6. Filtering by Time and Line Count

```bash
# last 50 lines
kubectl logs my-pod --tail=50

# logs from the last 10 minutes
kubectl logs my-pod --since=10m

# logs from an absolute timestamp (RFC3339)
kubectl logs my-pod --since-time=2026-07-13T10:00:00Z

# add timestamps to each line (useful if app doesn't output timestamps)
kubectl logs my-pod --timestamps
```

Combined common debugging pattern:

```bash
kubectl logs my-pod -c app --tail=100 --timestamps -f
```

## 7. Logs from Multiple Pods via Selector

`kubectl logs` accepts `-l`/`--selector` to retrieve logs from all pods matching a label, useful for Deployments/ReplicaSets:

```bash
kubectl logs -l app=web --all-containers=true --max-log-requests=10
```

`--max-log-requests` limits how many pods are queried in parallel (default 5) to prevent overwhelming the API if the selector matches many pods.

> Note: `kubectl logs -l` concatenates outputs rather than interleaving by timestamp; for real chronological inspection in production, use a central aggregator (see Section 8) or external CLI tool `stern` (outside core `kubectl`).

## 8. Logging Architecture: Beyond `kubectl logs`

`kubectl logs` only works while the pod exists (or until kubelet rotates/deletes the file). For long-term retention and historical search, Kubernetes defines three logging patterns (documented in Kubernetes Logging Architecture):

### a) Node-level logging agent
A **DaemonSet** runs a logging agent (Fluentd, Fluent Bit, Filebeat) on every node, mounting `/var/log/pods` as a `hostPath`, and forwards logs to an external backend (Elasticsearch, Loki, CloudWatch, etc.). Transparent to applications: requires no code or container changes.

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: log-agent
spec:
  selector:
    matchLabels:
      app: log-agent
  template:
    metadata:
      labels:
        app: log-agent
    spec:
      containers:
        - name: fluent-bit
          image: fluent/fluent-bit:3.1
          volumeMounts:
            - name: varlog
              mountPath: /var/log
              readOnly: true
      volumes:
        - name: varlog
          hostPath:
            path: /var/log
```

### b) Sidecar container with streaming
When an application writes to a file instead of stdout (and cannot be modified), a **sidecar container** is added to the same pod that tails that log file and redirects it to its own stdout. Thus `kubectl logs -c sidecar` (and the node logging agent) can capture it.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: app-with-sidecar
spec:
  containers:
    - name: app
      image: my-app:1.0
      volumeMounts:
        - name: logs
          mountPath: /var/log/app
    - name: sidecar-log
      image: busybox:1.36
      args: [/bin/sh, -c, 'tail -n+1 -F /var/log/app/app.log']
      volumeMounts:
        - name: logs
          mountPath: /var/log/app
  volumes:
    - name: logs
      emptyDir: {}
```

With this pattern, `app` writes to `/var/log/app/app.log` (shared via `emptyDir`) and `sidecar-log` tails it to stdout, making it visible with:

```bash
kubectl logs app-with-sidecar -c sidecar-log -f
```

### c) Sidecar with embedded logging agent
A variation of the above where the sidecar doesn't just `tail` stdout, but directly runs a logging agent (Fluent Bit) configured specifically for that pod, pushing logs directly to the backend without relying on the node DaemonSet. Grants granular app-level control at higher resource costs (one agent per pod instead of one per node).

## 9. Log Rotation

The kubelet manages container log rotation to avoid filling the node disk via flags `--container-log-max-size` (maximum size per file, default `10Mi`) and `--container-log-max-files` (number of rotated files to retain, default `5`). When a file is rotated or deleted, that content becomes unavailable via `kubectl logs`: another reason production systems rely on external aggregators.

## 10. Summary of `kubectl logs` Flags

| Flag | Purpose |
|---|---|
| `-c`, `--container` | Select container in a multi-container pod |
| `--all-containers` | Logs from all containers in the pod |
| `-p`, `--previous` | Logs from previous container instance (after crash/restart) |
| `-f`, `--follow` | Live log streaming |
| `--tail=N` | Display last N lines |
| `--since=DURATION` / `--since-time` | Filter logs by time window |
| `--timestamps` | Prefix each line with a timestamp |
| `-l`, `--selector` | Logs from all pods matching label selector |
| `--max-log-requests` | Limit parallel pod log requests when using `-l` |
| `--prefix` | Prefix `[pod/container]` to each line (useful with `--all-containers` or `-l`) |

## References

- Kubernetes Logging Architecture: https://kubernetes.io/docs/concepts/cluster-administration/logging/
- `kubectl logs` reference: https://kubernetes.io/docs/reference/generated/kubectl/kubectl-commands#logs
- Debug Running Pods (includes troubleshooting logs and `--previous`): https://kubernetes.io/docs/tasks/debug/debug-application/debug-running-pod/
- Kubelet log rotation flags (`--container-log-max-size`, `--container-log-max-files`): https://kubernetes.io/docs/reference/config-api/kubelet-config.v1beta1/
- CKAD Curriculum v1.35 (CNCF): https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf
