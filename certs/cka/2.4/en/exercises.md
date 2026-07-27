# Guided Exercises — CKA 2.4: Manage and evaluate container output streams

> Reference Source: [CKA Curriculum v1.35 (CNCF)](https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf)

Prerequisites: Access to a Kubernetes cluster (`kind`, `minikube`, etc.) with permissions to manage Pods inside a dedicated namespace.

```bash
kubectl create namespace logs-lab
kubectl config set-context --current --namespace=logs-lab
```

---

## Exercise 1 — Basic Pod Logging

1. Create a Pod writing output lines to `stdout` every second:

```bash
kubectl run logger-basic --image=busybox --restart=Never -- \
  sh -c 'i=0; while true; do echo "line $i"; i=$((i+1)); sleep 1; done'
```

2. Wait for `Running` status and inspect logs:

```bash
kubectl get pod logger-basic -w
```

(Press Ctrl+C when status enters `Running`)

```bash
kubectl logs logger-basic
```

3. Re-run `kubectl logs logger-basic` after several seconds and observe output progression.

### Comprehension Questions

1. Which standard stream(s) does `kubectl logs` capture by default: `stdout`, `stderr`, or both?
2. Does `kubectl logs` without `-f` return all accumulated logs or only new entries since last execution?

---

## Exercise 2 — Log Streaming and Filtering

1. Stream logs in real-time (`follow`):

```bash
kubectl logs -f logger-basic
```

(Press Ctrl+C after several seconds)

2. Display only the last 5 lines:

```bash
kubectl logs logger-basic --tail=5
```

3. Display logs generated within the last 10 seconds:

```bash
kubectl logs logger-basic --since=10s
```

4. Prepend RFC3339 timestamps to each line:

```bash
kubectl logs logger-basic --timestamps
```

5. Combine multiple log filtering flags:

```bash
kubectl logs logger-basic --tail=3 --timestamps
```

### Comprehension Questions

1. What distinction separates `--since=10s` vs `--since-time=<RFC3339>`?
2. How do `kubectl logs` filtering flags (`--tail`, `--since`) interact with content filtering tools like `grep`?

---

## Exercise 3 — Multi-Container Pod Logging

1. Create a Pod containing two containers logging distinct messages:

```yaml
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: multi-logger
spec:
  containers:
  - name: web
    image: busybox
    command: ["sh", "-c", "while true; do echo web: request received; sleep 2; done"]
  - name: worker
    image: busybox
    command: ["sh", "-c", "while true; do echo worker: job processed; sleep 3; done"]
EOF
```

2. Attempt to query logs without specifying a target container:

```bash
kubectl logs multi-logger
```

3. Query each container explicitly using `-c`:

```bash
kubectl logs multi-logger -c web
kubectl logs multi-logger -c worker
```

4. Display logs across all Pod containers simultaneously with source prefixes:

```bash
kubectl logs multi-logger --all-containers=true --prefix
```

### Comprehension Questions

1. Why does `kubectl logs multi-logger` (without `-c`) return an error when multiple containers exist?
2. What role does `--prefix` perform when used alongside `--all-containers`?

---

## Exercise 4 — Logs from Terminated Container Instances (`--previous`)

1. Create a Pod that terminates with a non-zero exit code, triggering container restarts:

```yaml
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: crash-logger
spec:
  containers:
  - name: app
    image: busybox
    command: ["sh", "-c", "echo starting; sleep 5; echo 'fatal error: exiting'; exit 1"]
EOF
```

2. Observe Pod entering `CrashLoopBackOff`:

```bash
kubectl get pod crash-logger -w
```

(Press Ctrl+C after observing at least 1 restart)

3. Inspect logs from the active container instance:

```bash
kubectl logs crash-logger
```

4. Inspect logs from the **previous** terminated container instance that failed:

```bash
kubectl logs crash-logger --previous
```

5. Review Pod events to correlate logs with container status:

```bash
kubectl describe pod crash-logger
```

### Comprehension Questions

1. What distinction separates `kubectl logs crash-logger` vs `kubectl logs crash-logger --previous` in `CrashLoopBackOff` scenarios?
2. When investigating `CrashLoopBackOff` errors, why should both `--previous` logs and `kubectl describe pod` be evaluated together?

---

## Exercise 5 — Interleaved stdout and stderr Streams

1. Create a Pod generating output to both `stdout` and `stderr`:

```yaml
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: dual-stream
spec:
  containers:
  - name: app
    image: busybox
    command: ["sh", "-c", "while true; do echo 'info: ok'; echo 'error: failure' >&2; sleep 2; done"]
EOF
```

2. Query Pod logs:

```bash
kubectl logs dual-stream
```

3. Observe interleaved `info:` and `error:` entries.

### Comprehension Questions

1. Does `kubectl logs` distinguish between `stdout` vs `stderr` lines, or does it merge both into a unified output stream?
2. How can application errors logged to `stderr` be isolated from standard `stdout` log entries?

---

## Exercise 6 — Sidecar Logging Pattern (Stream Redirection)

1. Deploy a Pod where the main application writes logs to an internal file, paired with a sidecar container streaming the file contents to `stdout`:

```yaml
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: sidecar-logger
spec:
  volumes:
  - name: logs
    emptyDir: {}
  containers:
  - name: app
    image: busybox
    command: ["sh", "-c", "while true; do echo \"$(date) app event\" >> /var/log/app.log; sleep 2; done"]
    volumeMounts:
    - name: logs
      mountPath: /var/log
  - name: log-shipper
    image: busybox
    command: ["sh", "-c", "tail -F /var/log/app.log"]
    volumeMounts:
    - name: logs
      mountPath: /var/log
EOF
```

2. Confirm main `app` container produces no direct `stdout` output:

```bash
kubectl logs sidecar-logger -c app
```

3. Confirm `log-shipper` sidecar container exposes internal file logs to standard Kubernetes logging:

```bash
kubectl logs sidecar-logger -c log-shipper -f
```

(Press Ctrl+C to terminate streaming)

### Comprehension Questions

1. Why does `kubectl logs sidecar-logger -c app` return empty output?
2. What architectural advantage does this sidecar pattern provide for legacy applications?

---

## Exercise 7 — Node-Level Log Rotation

1. Identify host node assignment:

```bash
kubectl get pod multi-logger -o wide
```

2. Launch a node debugging session:

```bash
kubectl debug node/<node-name> -it --image=busybox -- chroot /host sh
```

3. Inspect log file paths managed by the container runtime:

```bash
ls -la /var/log/containers/ | head
ls -la /var/log/pods/ | head
```

4. Inspect `kubelet` log rotation parameters:

```bash
cat /var/lib/kubelet/config.yaml | grep -i containerLog
```

Look for `containerLogMaxSize` and `containerLogMaxFiles`.

5. Exit debug container session:

```bash
exit
```

### Comprehension Questions

1. What setting controls container log file rotation sizes inside `KubeletConfiguration`?
2. Why might `kubectl logs` return incomplete historical logs even if a container has never restarted?

---

## Exercise 8 — Comprehensive Diagnostic Troubleshooting

1. Deploy a Deployment with an intentional startup bug:

```yaml
cat <<'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: buggy-app
spec:
  replicas: 1
  selector:
    matchLabels:
      app: buggy-app
  template:
    metadata:
      labels:
        app: buggy-app
    spec:
      containers:
      - name: app
        image: busybox
        command: ["sh", "-c", "echo 'loading config...'; sleep 3; echo 'CONFIG_MISSING: API_KEY variable unset' >&2; exit 1"]
EOF
```

2. Track Deployment Pod status:

```bash
kubectl get pods -l app=buggy-app -w
```

3. Diagnose root cause combining status, description, and previous logs:

```bash
kubectl get pods -l app=buggy-app
kubectl describe pod -l app=buggy-app
kubectl logs -l app=buggy-app --previous
```

4. Fix Deployment by injecting missing environment variables:

```bash
kubectl set env deployment/buggy-app API_KEY=demo123
kubectl rollout status deployment/buggy-app
kubectl get pods -l app=buggy-app -w
```

### Comprehension Questions

1. In what sequence should `get pods`, `describe pod`, and `logs --previous` be executed during `CrashLoopBackOff` troubleshooting?
2. Why might `kubectl logs -l app=buggy-app` (omitting `--previous`) fail to show crash error messages?

---

## Teardown

```bash
kubectl delete namespace logs-lab
```

---

<details>
<summary>View Answers</summary>

**Exercise 1**
1. Captures both `stdout` and `stderr` streams combined.
2. Returns full accumulated log history retained on node disk.

**Exercise 2**
1. `--since=10s` is a relative duration. `--since-time` takes an absolute RFC3339 timestamp.
2. `kubectl logs` filters by time/count limits; content filtering (e.g. searching for error keywords) is performed by piping output to shell tools like `grep`.

**Exercise 3**
1. `kubectl logs` requires specifying `-c <container>` or `--all-containers` to disambiguate target streams in multi-container Pods.
2. `--prefix` prepends Pod and container names to each log line when streaming multiple containers simultaneously.

**Exercise 4**
1. `kubectl logs` queries the active container instance (which may be starting fresh). `--previous` queries the terminated instance that crashed.
2. `kubectl describe` exposes lifecycle events and exit codes; `--previous` reveals application stack traces causing container failure.

**Exercise 5**
1. Merges both streams sequentially without structural stream labels.
2. Applications must output structured logs (e.g., JSON log levels) or pipe streams to dedicated log collector agents.

**Exercise 6**
1. Main application containers write to local files rather than standard process streams (`stdout`/`stderr`).
2. Exposes file-based logs to standard Kubernetes tooling without requiring application code changes.

**Exercise 7**
1. `containerLogMaxSize` specifies maximum log file sizes before rotation.
2. Node log rotation policies (`containerLogMaxSize`/`containerLogMaxFiles`) purge older rotated files from disk over time.

**Exercise 8**
1. Run `get pods` (identify state/restarts) → `describe pod` (check exit codes/events) → `logs --previous` (read application panic stack traces).
2. Active container instances in `CrashLoopBackOff` restart fresh without having emitted crash stack traces yet.

</details>
