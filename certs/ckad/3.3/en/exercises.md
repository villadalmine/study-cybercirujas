# CKAD 3.3 — Utilize container logs

**Exam Weight:** 4
**Reference Source:** [CKAD Curriculum v1.35 (PDF)](https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf)
**Complementary Official Documentation:** [kubectl logs — reference](https://kubernetes.io/docs/reference/kubectl/generated/kubectl_logs/) · [Logging Architecture](https://kubernetes.io/docs/concepts/cluster-administration/logging/)

---

## Environment Setup

1. Create a dedicated namespace for these exercises:

```bash
kubectl create namespace ckad-logs
kubectl config set-context --current --namespace=ckad-logs
```

2. Confirm the namespace is selected as default:

```bash
kubectl config view --minify | grep namespace:
```

**Comprehension Questions — Block 0**

1. When a container writes to `stdout`/`stderr`, who is responsible for capturing and storing those lines before `kubectl logs` can read them?

---

## Block 1 — Basic `kubectl logs`

3. Create the following Pod, which emits a log line every 2 seconds:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: logger-basic
spec:
  containers:
  - name: app
    image: busybox:1.36
    command: ["sh", "-c", "i=0; while true; do i=$((i+1)); echo \"$(date -Iseconds) log-line-$i\"; sleep 2; done"]
```

```bash
kubectl apply -f logger-basic.yaml
kubectl wait --for=condition=Ready pod/logger-basic --timeout=30s
```

4. Wait a few seconds and query complete log history:

```bash
kubectl logs logger-basic
```

5. Repeat query requesting only the last 5 lines:

```bash
kubectl logs logger-basic --tail=5
```

6. Now request only logs generated in the last 10 seconds:

```bash
kubectl logs logger-basic --since=10s
```

7. Query logs again, this time with explicit kubelet timestamps (useful when container output omits dates):

```bash
kubectl logs logger-basic --timestamps
```

**Comprehension Questions — Block 1**

2. What is the difference between timestamp added by `--timestamps` vs timestamp printed inside each line by the container `command` itself?
3. If container has completed (`Completed`) an hour ago, does `kubectl logs` still return its output? Why or why not?

---

## Block 2 — Real-Time Streaming Logs (`-f`)

8. Open a live log stream from the same Pod:

```bash
kubectl logs -f logger-basic
```

9. Keep running for a few seconds, observe new lines arriving, and interrupt with `Ctrl+C`.

10. Combine with `--tail` to avoid pulling entire history upon stream connection:

```bash
kubectl logs -f --tail=3 logger-basic
```

**Comprehension Questions — Block 2**

4. If while running `kubectl logs -f` the Pod is deleted (`kubectl delete pod logger-basic`) from another terminal, what happens to the stream?
5. Does `kubectl logs -f` automatically reconnect if the container restarts while the stream is open?

---

## Block 3 — Multi-container Pods

11. Create a Pod with two containers, each logging different output:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: logger-multi
spec:
  containers:
  - name: web
    image: busybox:1.36
    command: ["sh", "-c", "while true; do echo \"web: request handled\"; sleep 3; done"]
  - name: worker
    image: busybox:1.36
    command: ["sh", "-c", "while true; do echo \"worker: job processed\"; sleep 5; done"]
```

```bash
kubectl apply -f logger-multi.yaml
```

12. Attempt to request logs without specifying a container:

```bash
kubectl logs logger-multi
```

13. Specify explicitly which container to view:

```bash
kubectl logs logger-multi -c web
kubectl logs logger-multi -c worker
```

14. Fetch logs from all containers at once, prefixed with each container name:

```bash
kubectl logs logger-multi --all-containers=true --prefix=true
```

**Comprehension Questions — Block 3**

6. What error message does `kubectl logs` give in step 12, and what is it asking you to do?
7. What is `--prefix=true` used for when working with `--all-containers=true`?

---

## Block 4 — Logs from Previous Container Instance (`--previous`)

15. Create a Pod whose container crashes after starting (triggering restarts and eventually `CrashLoopBackOff`):

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: logger-crash
spec:
  restartPolicy: Always
  containers:
  - name: app
    image: busybox:1.36
    command: ["sh", "-c", "echo \"starting up\"; sleep 5; echo \"fatal: simulated crash\"; exit 1"]
```

```bash
kubectl apply -f logger-crash.yaml
```

16. Wait for at least one restart to occur:

```bash
kubectl get pod logger-crash -w
```

(interrupt with `Ctrl+C` when `RESTARTS` is 1 or more).

17. Inspect logs from **current** container instance, then logs from **previous** instance:

```bash
kubectl logs logger-crash
kubectl logs logger-crash --previous
```

**Comprehension Questions — Block 4**

8. Why might `kubectl logs logger-crash` (without `--previous`) show very few lines or simply "starting up" again, instead of the fatal error that occurred previously?
9. If the entire Pod (not just container) is recreated — e.g. deleted and re-applied —, does `--previous` still have logs available? Why?

---

## Block 5 — Logging Sidecar Pattern (Streaming Sidecar)

Many legacy applications write logs to a file inside the filesystem rather than `stdout`. The sidecar pattern solves this by adding a second container reading that file and writing it to its own `stdout`, allowing `kubectl logs` (and cluster logging agents) to capture it normally.

18. Create the following Pod where `app` writes to a shared log file and `log-shipper` tails it to stdout:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: logger-sidecar
spec:
  volumes:
  - name: shared-logs
    emptyDir: {}
  containers:
  - name: app
    image: busybox:1.36
    command: ["sh", "-c", "i=0; while true; do i=$((i+1)); echo \"$(date -Iseconds) app-event-$i\" >> /var/log/app/app.log; sleep 2; done"]
    volumeMounts:
    - name: shared-logs
      mountPath: /var/log/app
  - name: log-shipper
    image: busybox:1.36
    command: ["sh", "-c", "touch /var/log/app/app.log; tail -n+1 -f /var/log/app/app.log"]
    volumeMounts:
    - name: shared-logs
      mountPath: /var/log/app
```

```bash
kubectl apply -f logger-sidecar.yaml
```

19. Confirm container `app` has almost no stdout output via `kubectl logs`, but sidecar does:

```bash
kubectl logs logger-sidecar -c app
kubectl logs logger-sidecar -c log-shipper
```

**Comprehension Questions — Block 5**

10. Which Kubernetes resource allows both containers to access the same `app.log` file?
11. What advantage does this pattern have over running `kubectl exec logger-sidecar -c app -- cat /var/log/app/app.log` whenever you need to view logs?

---

## Block 6 — Job Logs

20. Create a short-lived Job:

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: log-job
spec:
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: reporter
        image: busybox:1.36
        command: ["sh", "-c", "echo 'job started'; sleep 3; echo 'job finished successfully'"]
```

```bash
kubectl apply -f log-job.yaml
kubectl wait --for=condition=complete job/log-job --timeout=30s
```

21. Query logs directly against Job object without looking up Pod name first:

```bash
kubectl logs job/log-job
```

**Comprehension Questions — Block 6**

12. What would happen with `kubectl logs job/log-job` if Job had `parallelism: 3` and thus 3 associated Pods?

---

## Teardown

22. Remove all created resources:

```bash
kubectl delete namespace ckad-logs
```

---

<details>
<summary><strong>Answers</strong></summary>

1. The **container runtime** (containerd/CRI-O via kubelet) redirects `stdout`/`stderr` from container main process to log files on the node; `kubectl logs` does not read app directly, but requests data from node's kubelet where Pod runs.

2. `--timestamps` appends a timestamp recorded by **kubelet** upon receiving each line (nanosecond precision in UTC); timestamp printed by `date -Iseconds` inside container `command` is generated by application itself and may differ slightly or use different formatting. They are two independent sources.

3. Yes, output is still returned as long as container (or its node log file) has not been deleted by log rotation or Pod deletion. `kubectl logs` does not require container to be currently running, only that log files exist.

4. `kubectl logs -f` stream terminates as soon as container disappears (kubelet closes connection), displaying an error or exiting; no automatic reconnection to a different Pod occurs.

5. No. `kubectl logs -f` follows output of a specific container instance. If container restarts, stream ends (or shows connection error) and command must be re-run; does not jump automatically to new instance.

6. Returns error stating Pod has multiple containers and specifying which container is required via `-c <name>` (or using `--all-containers`), as `kubectl logs` defaults to single-container Pods.

7. `--prefix=true` prepends Pod name and source container (e.g. `[pod/logger-multi/web]`) to each line, essential for distinguishing output when multiple container streams combine.

8. Because `kubectl logs` without `--previous` displays logs from **currently active container instance** (started after latest restart), which is fresh in its "starting up" cycle and hasn't hit `exit 1` yet. Previous error remains in prior instance, visible only with `--previous`.

9. No: `--previous` retains logs only for immediately prior instance **within the same Pod** (same `spec.containers` managed by same kubelet). If entire Pod is deleted and recreated, it is a new object without prior instance history; those logs are lost unless sent to external log aggregator.

10. The shared volume `emptyDir`, mounted in both containers at same `mountPath` (`/var/log/app`). `emptyDir` exists as long as Pod exists and is accessible to all Pod containers mounting it.

11. Sidecar pattern makes log output continuously and standardized via `kubectl logs` (and any cluster log aggregation agent listening to `stdout`/`stderr`), requiring no manual on-demand commands or reliance on container remaining active when auditing log files.

12. `kubectl logs job/log-job` only returns logs from **one** Pod of the Job (typically fails or warns if ambiguous with multiple Pods). With `parallelism > 1`, label selectors over Job Pods are preferred (e.g. `kubectl logs -l job-name=log-job --all-containers=true --prefix=true`).

</details>
