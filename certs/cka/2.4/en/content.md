# 2.4 Manage and evaluate container output streams

## Introduction

In Kubernetes, container logs provide the primary mechanism for diagnosing application behavior and runtime failures. Kubernetes does not enforce a centralized logging backend by default: instead, it captures standard process streams (`stdout` and `stderr`) from each container, persisting them on host nodes so `kubelet` and container runtimes (containerd or CRI-O, via CRI) expose them via `kubectl logs`.

This topic addresses three core skills tested on the CKA exam: understanding how output streams are captured and stored, mastering `kubectl logs` options for multi-container Pods, init containers, and restarted containers, and understanding cluster-level logging architecture patterns.

## Standard Streams: stdout and stderr

Container design best practices mandate that applications **should not write logs to internal file paths inside the container filesystem**. Instead, applications must stream output to:

- `stdout` (file descriptor 1): Standard application output messages.
- `stderr` (file descriptor 2): Errors, warnings, and diagnostic stack traces.

The container runtime captures both streams and persists them as log files on host nodes under `/var/log/pods/<namespace>_<pod-name>_<pod-uid>/<container-name>/`, with symlinks maintained under `/var/log/containers/`. The `kubelet` exposes these files to the Kubernetes API when `kubectl logs` is executed.

If an application writes logs directly to internal files rather than `stdout`/`stderr`, Kubernetes cannot stream them directly — sidecar logging patterns are required (see below).

## The `kubectl logs` Command

### Basic Syntax

```bash
kubectl logs <pod-name>
kubectl logs <pod-name> -c <container-name>
```

If a Pod contains a single container, `-c` is optional. For multi-container Pods, `-c` (or `--all-containers`) is mandatory.

### Essential Flags

| Flag | Description |
|---|---|
| `-f`, `--follow` | Streams logs in real-time (similar to `tail -f`) |
| `--previous` (`-p`) | Displays logs from the **previous** terminated container instance |
| `--since=1h` | Displays logs generated within the last hour |
| `--since-time=<RFC3339>` | Displays logs generated since an absolute timestamp |
| `--tail=50` | Displays only the last N log lines |
| `--timestamps` | Prepends RFC3339 timestamps to each log entry |
| `-l app=web` | Fetches logs from all Pods matching label selectors |
| `--all-containers` | Fetches logs across all containers in matching Pods (including sidecars) |
| `--prefix` | Prepends Pod and container names to log lines (useful with `-l`) |
| `--limit-bytes=1024` | Caps log output retrieval to N bytes |
| `-n <namespace>` | Specifies target namespace |

### Command Usage Examples

Inspect recent logs from a single-container Pod:

```bash
kubectl logs webapp-6d9f8c7b4-x2plq
```

```
2026-07-16T10:01:03Z INFO  starting server on :8080
2026-07-16T10:01:03Z INFO  connected to db at postgres:5432
2026-07-16T10:02:11Z ERROR failed to reach payment-service: connection refused
```

Stream live logs from a specific container in a multi-container Pod:

```bash
kubectl logs -f webapp-6d9f8c7b4-x2plq -c app
```

Inspect logs from a crashed container instance following a restart:

```bash
kubectl get pods
```

```
NAME                       READY   STATUS             RESTARTS   AGE
webapp-6d9f8c7b4-x2plq     0/1     CrashLoopBackOff   4          6m
```

```bash
kubectl logs webapp-6d9f8c7b4-x2plq --previous
```

```
2026-07-16T09:58:40Z FATAL panic: config file /etc/webapp/config.yaml not found
```

`--previous` is critical: omitting it displays the **current** container instance, which in a `CrashLoopBackOff` state may be starting up without having produced the error that caused the prior termination.

Fetch logs from all Pods matching label selectors with container name prefixes:

```bash
kubectl logs -l app=webapp --all-containers --prefix --tail=20
```

```
[pod/webapp-6d9f8c7b4-x2plq/app] 2026-07-16T10:05:00Z INFO handling GET /health
[pod/webapp-6d9f8c7b4-x2plq/sidecar] 2026-07-16T10:05:00Z INFO shipping batch of 12 log lines
[pod/webapp-7f6d9b7c9-abcde/app] 2026-07-16T10:05:01Z INFO handling GET /health
```

### Inspecting Init Containers

Init containers run to completion before app containers start. Inspecting init container logs is essential when Pods freeze in `Init:Error` or `Init:CrashLoopBackOff` states:

```bash
kubectl get pod db-migrator-xyz
```

```
NAME              READY   STATUS       RESTARTS   AGE
db-migrator-xyz   0/1     Init:Error   2          90s
```

```bash
kubectl logs db-migrator-xyz -c wait-for-db
```

```
2026-07-16T10:10:00Z waiting for postgres:5432...
2026-07-16T10:10:30Z timeout: could not connect to postgres:5432
```

## Logging in Multi-Container Pods

In multi-container Pods (app + sidecars), each container generates independent `stdout`/`stderr` streams captured separately by the container runtime:

- Executing `kubectl logs <pod>` without specifying `-c` returns errors requiring explicit container selection.
- Each container tracks its own `restartCount`; `--previous` applies per container instance rather than across the entire Pod.
- `kubectl describe pod <pod>` reports container execution states (`Last State`, `Reason`, `Exit Code`) for each container — helpful prior to inspecting log streams.

Example `kubectl describe pod` output identifying non-zero exit codes:

```
Containers:
  app:
    State:          Waiting
      Reason:       CrashLoopBackOff
    Last State:     Terminated
      Reason:       Error
      Exit Code:    1
      Started:      Thu, 16 Jul 2026 09:58:38 +0000
      Finished:     Thu, 16 Jul 2026 09:58:40 +0000
```

`Exit Code: 1` with `Reason: Error` indicates checking `stderr` via `--previous`. `Exit Code: 137` indicates `OOMKilled` terminations, where application logs might be empty and `kubectl describe` provides root causes.

## Host Node Log Rotation

The `kubelet` manages host log file rotation on disk via `KubeletConfiguration` parameters:

- `containerLogMaxSize`: Maximum log file size before rotation occurs (default `10Mi`).
- `containerLogMaxFiles`: Maximum number of rotated log files retained per container (default `5`).

Configured inside `/var/lib/kubelet/config.yaml`:

```yaml
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
containerLogMaxSize: 20Mi
containerLogMaxFiles: 10
```

`kubectl logs` retrieves only log data remaining on host disk: if high log volume triggers rapid rotation, older log entries may be purged before inspection, even when querying `--previous`.

## Cluster-Level Logging Architectures

Kubernetes omits built-in log aggregation backends (such as Elasticsearch, Loki, or Cloud Logging), but exam objectives test understanding common **architectural logging patterns**:

### 1. Node-Level Logging Agent (DaemonSet)

A logging agent (Fluentd, Fluent Bit, Vector) runs as a `DaemonSet` on every node, mounting host `/var/log/pods` and `/var/log/containers` via `hostPath` mounts to ship log streams to central storage.

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: fluent-bit
spec:
  selector:
    matchLabels:
      app: fluent-bit
  template:
    metadata:
      labels:
        app: fluent-bit
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

### 2. Sidecar Container Redirecting File Logs to stdout

When legacy applications write logs strictly to internal files, a sidecar container streams file contents to stdout via `tail -f`:

```yaml
spec:
  containers:
    - name: app
      image: legacy-app:1.0
      volumeMounts:
        - name: logs
          mountPath: /var/log/app
    - name: log-tailer
      image: busybox:1.36
      args: [/bin/sh, -c, 'tail -n+1 -F /var/log/app/app.log']
      volumeMounts:
        - name: logs
          mountPath: /var/log/app
  volumes:
    - name: logs
      emptyDir: {}
```

With this pattern, `kubectl logs <pod> -c log-tailer` exposes internal file logs to standard Kubernetes tooling.

### 3. Sidecar Container with Embedded Logging Agent

A sidecar container runs a dedicated logging agent (e.g. Fluent Bit) transmitting log files directly to remote log collectors without depending on node-level DaemonSets.

## Diagnostic Troubleshooting Workflow

1. Execute `kubectl get pods` → identify `STATUS` and `RESTARTS`.
2. Execute `kubectl describe pod <pod>` → inspect `Events`, `Last State`, `Exit Code`, and `Reason` per container.
3. Execute `kubectl logs <pod> -c <container>` → view active instance stdout/stderr.
4. Execute `kubectl logs <pod> -c <container> --previous` → view logs from crashed instances prior to restart.
5. For multi-container Pods, repeat for suspect containers or execute `kubectl logs <pod> --all-containers --prefix`.
6. For Pods stuck in `Init:Error` or `Pending`, inspect init containers and run `kubectl describe` before querying main application containers.

Integrated example — diagnosing a Pod crashing due to missing environment variables:

```bash
kubectl get pods
```

```
NAME                     READY   STATUS             RESTARTS   AGE
worker-5b8f9c6d7-ttpqz   0/1     CrashLoopBackOff   6          10m
```

```bash
kubectl logs worker-5b8f9c6d7-ttpqz --previous --timestamps
```

```
2026-07-16T09:50:12Z INFO starting worker
2026-07-16T09:50:12Z FATAL required env var QUEUE_URL is not set
```

The error log pinpoints the root cause immediately: missing `QUEUE_URL` definitions inside Deployment or ConfigMap manifests.

## References

- CNCF, *Certified Kubernetes Administrator (CKA) Curriculum v1.35*: https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf
- Kubernetes docs, *Logging Architecture*: https://kubernetes.io/docs/concepts/cluster-administration/logging/
- Kubernetes docs, *kubectl logs reference*: https://kubernetes.io/docs/reference/generated/kubectl/kubectl-commands#logs
- Kubernetes docs, *Debug Running Pods*: https://kubernetes.io/docs/tasks/debug/debug-application/debug-running-pod/
- Kubernetes docs, *Determine the Reason for Pod Failure*: https://kubernetes.io/docs/tasks/debug/debug-application/determine-reason-pod-failure/
- Kubernetes docs, *Kubelet Configuration (v1beta1)*: https://kubernetes.io/docs/reference/config-api/kubelet-config.v1beta1/
