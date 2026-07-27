# CKAD 3.4 — Debugging in Kubernetes (Guided Exercises)

> Reference Source: [CKAD Curriculum v1.35](https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf)

**Prerequisites**: Access to a Kubernetes cluster (`minikube`, `kind`, or similar) with configured `kubectl`, and a working namespace:

```bash
kubectl create namespace debug-lab
kubectl config set-context --current --namespace=debug-lab
```

---

## Exercise 1 — Pod in `Pending` State

1. Create a Pod requesting more resources than the cluster can provide:

```yaml
# pending-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: pending-pod
spec:
  containers:
  - name: app
    image: nginx
    resources:
      requests:
        cpu: "100"
        memory: "500Gi"
```

```bash
kubectl apply -f pending-pod.yaml
```

2. Verify Pod status:

```bash
kubectl get pod pending-pod
```

3. Investigate root cause with `describe`, paying attention to the `Events` section:

```bash
kubectl describe pod pending-pod
```

4. Clean up resource:

```bash
kubectl delete -f pending-pod.yaml
```

**Questions**
- Which section of `kubectl describe pod` displays the exact reason the scheduler failed to place the Pod on a Node?
- Which command would you use to quickly verify whether the issue stems from insufficient Node resources across the cluster?

---

## Exercise 2 — `CrashLoopBackOff`

1. Create a Pod whose container exits immediately with an error:

```yaml
# crash-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: crash-pod
spec:
  containers:
  - name: app
    image: busybox
    command: ["sh", "-c", "echo 'simulated failure' && exit 1"]
```

```bash
kubectl apply -f crash-pod.yaml
```

2. Wait a few seconds and observe status and restart count:

```bash
kubectl get pod crash-pod -w
```

(exit with `Ctrl+C` upon observing `CrashLoopBackOff`)

3. Review logs for current attempt:

```bash
kubectl logs crash-pod
```

4. Review logs from previous container attempt (which crashed prior to latest restart):

```bash
kubectl logs crash-pod --previous
```

5. Clean up resource:

```bash
kubectl delete -f crash-pod.yaml
```

**Questions**
- Why might `kubectl logs crash-pod` show no useful information immediately after Pod creation, and which flag resolves this to view the prior failed attempt?
- Which field in `kubectl describe pod crash-pod` indicates how many times the container has restarted?

---

## Exercise 3 — Interactive Debugging with `kubectl exec`

1. Create a long-running Pod:

```bash
kubectl run debug-target --image=nginx --restart=Never
kubectl wait --for=condition=Ready pod/debug-target
```

2. Open an interactive shell inside the container:

```bash
kubectl exec -it debug-target -- /bin/sh
```

3. Inside the shell, verify `nginx` process is running and configuration file exists:

```bash
ps aux
cat /etc/nginx/nginx.conf
exit
```

4. Run a single command without attaching an interactive shell:

```bash
kubectl exec debug-target -- nginx -v
```

5. Clean up resource:

```bash
kubectl delete pod debug-target
```

**Questions**
- Which combination of `kubectl exec` flags is required to get an interactive terminal (TTY + stdin)?
- If the Pod contained multiple containers, which flag specifies which container to attach to?

---

## Exercise 4 — Ephemeral Containers with `kubectl debug`

1. Create a minimal Pod lacking debugging tools (simulated with basic `busybox` image):

```bash
kubectl run minimal-pod --image=busybox --restart=Never -- sleep 3600
kubectl wait --for=condition=Ready pod/minimal-pod
```

2. Attach an ephemeral container with networking/diagnostic tools to the running Pod without restarting it:

```bash
kubectl debug -it minimal-pod --image=busybox --target=minimal-pod -- sh
```

3. Inside the debug session, verify that you share process namespaces with the original container:

```bash
ps aux
exit
```

4. Confirm that the ephemeral container is registered in the Pod spec:

```bash
kubectl get pod minimal-pod -o jsonpath='{.spec.ephemeralContainers[*].name}'
```

5. Clean up resource:

```bash
kubectl delete pod minimal-pod
```

**Questions**
- What is the primary advantage of `kubectl debug` with ephemeral containers over modifying the original container image to include diagnostic tools?
- What does the `--target` flag do and why is it necessary to view original container processes with `ps aux`?

---

## Exercise 5 — `readinessProbe` / `livenessProbe` Failures

1. Create a Pod with a `readinessProbe` targeting a non-existent path:

```yaml
# probe-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: probe-pod
spec:
  containers:
  - name: app
    image: nginx
    readinessProbe:
      httpGet:
        path: /does-not-exist
        port: 80
      periodSeconds: 5
      failureThreshold: 2
```

```bash
kubectl apply -f probe-pod.yaml
```

2. Observe that Pod runs but never becomes `Ready`:

```bash
kubectl get pod probe-pod
```

3. Confirm root cause in events:

```bash
kubectl describe pod probe-pod | grep -A5 Events
```

4. Fix probe path using `kubectl edit` or by re-applying manifest with `/` as path, and verify Pod becomes `Ready`:

```bash
kubectl set probe pod probe-pod --readiness --get-url=http://:80/
kubectl get pod probe-pod -w
```

5. Clean up resource:

```bash
kubectl delete -f probe-pod.yaml
```

**Questions**
- What is the behavioral difference between a Pod failing its `readinessProbe` versus one failing its `livenessProbe`?
- Which column in `kubectl get pod` reflects that a container failed its `readinessProbe`, even while Pod status displays `Running`?

---

## Exercise 6 — `Service` Connectivity

1. Deploy an application and its Service with a misconfigured `selector`:

```yaml
# broken-svc.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
spec:
  replicas: 2
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      containers:
      - name: web
        image: nginx
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: web-svc
spec:
  selector:
    app: web-incorrect
  ports:
  - port: 80
    targetPort: 80
```

```bash
kubectl apply -f broken-svc.yaml
```

2. Verify that Service has no endpoints:

```bash
kubectl get endpoints web-svc
```

3. Confirm mismatch by comparing Deployment labels with Service selector:

```bash
kubectl get pods -l app=web --show-labels
kubectl describe service web-svc | grep Selector
```

4. Fix selector and confirm endpoints appear:

```bash
kubectl patch service web-svc -p '{"spec":{"selector":{"app":"web"}}}'
kubectl get endpoints web-svc
```

5. Test Service DNS resolution from another Pod:

```bash
kubectl run tmp-shell --image=busybox --restart=Never -it --rm -- nslookup web-svc
```

6. Clean up resources:

```bash
kubectl delete -f broken-svc.yaml
```

**Questions**
- Which command unambiguously confirms that a `Service` has no associated backend Pods?
- What name pattern does `nslookup` resolve for a Service within the same namespace vs in another namespace?

---

## Exercise 7 — Resource Consumption with `kubectl top`

1. Ensure `metrics-server` is installed (on `minikube`: `minikube addons enable metrics-server`).

2. Deploy a Pod that continuously consumes CPU:

```bash
kubectl run cpu-hog --image=busybox --restart=Never -- sh -c "while true; do :; done"
```

3. Wait ~30 seconds for metrics-server data collection and inspect usage:

```bash
kubectl top pod cpu-hog
```

4. View aggregated usage per Node:

```bash
kubectl top node
```

5. Clean up resource:

```bash
kubectl delete pod cpu-hog
```

**Questions**
- Why might `kubectl top pod` return `error: Metrics API not available` immediately after installing `metrics-server`?
- What is the difference between `kubectl top pod` reported usage and `resources.requests`/`resources.limits` declared in the manifest?

---

<details>
<summary><strong>Answers</strong></summary>

**Exercise 1**
- The `Events` section of `describe pod` (at bottom of output) displays scheduler messages, e.g. `0/1 nodes are available: 1 Insufficient cpu`.
- `kubectl describe nodes` (or `kubectl top node` with metrics-server) shows current capacity and usage per Node to compare against requested resources (`requests`).

**Exercise 2**
- Right after creation, container may be in its initial attempt or hasn't finished, so `kubectl logs` without flags shows current process (which may be empty or running). `--previous` (`-p`) displays logs from the terminated container attempt immediately preceding current one.
- `Restart Count` field in `Containers` section of `describe pod`.

**Exercise 3**
- `-i` (stdin) combined with `-t` (tty): `kubectl exec -it <pod> -- <command>`.
- `-c <container-name>` flag (`--container`).

**Exercise 4**
- Allows troubleshooting a running Pod without modifying its original spec, rebuilding container images, or restarting existing containers — ideal for shell-less `distroless` images.
- `--target` makes ephemeral container share process namespace (`PID namespace`) with specified container, enabling tools like `ps` to see target processes; without it, ephemeral container sees only its own processes.

**Exercise 5**
- If `readinessProbe` fails, container keeps running but Pod is removed from Service Endpoints (receives no traffic); if `livenessProbe` fails, kubelet restarts container.
- `READY` column in `kubectl get pod` (e.g. `0/1` instead of `1/1`), even while `STATUS` shows `Running`.

**Exercise 6**
- `kubectl get endpoints <service>`: if `ENDPOINTS` list is empty, no backend Pods match selector.
- Within same namespace `<service>` suffices; across namespaces `<service>.<namespace>` or full FQDN `<service>.<namespace>.svc.cluster.local` is required.

**Exercise 7**
- Because metrics-server requires time (typically 1-2 minutes) to perform initial metrics scrape from kubelets before Metrics API serves data.
- `kubectl top` reports actual instantaneous CPU/memory usage measured by metrics-server; `requests`/`limits` are manifest values used by scheduler and kubelet for allocation and capping, not real-time consumption.

</details>
