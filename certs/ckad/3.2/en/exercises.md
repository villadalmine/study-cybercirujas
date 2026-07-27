# Guided Exercises — 3.2 Use built-in CLI tools to monitor Kubernetes applications

> **Prerequisites:** A working Kubernetes cluster (minikube, kind, or similar), configured `kubectl`, and permissions to create resources. For `kubectl top` exercises you need **metrics-server** installed; Exercise 1 shows how to verify and install it.

Work in a dedicated namespace for clean teardown at the end:

```bash
kubectl create namespace monitor-lab
kubectl config set-context --current --namespace=monitor-lab
```

---

## Exercise 1 — Verify the Metrics Pipeline (metrics-server)

CPU and memory metrics displayed by `kubectl top` do not come out of nowhere: they are provided by **metrics-server**, a component that aggregates data from **kubelets** and exposes it via the **Metrics API** (`metrics.k8s.io`).

1. Verify if metrics-server is deployed:

   ```bash
   kubectl get deployment metrics-server -n kube-system
   ```

2. If missing, install it. On **minikube**:

   ```bash
   minikube addons enable metrics-server
   ```

   On other clusters:

   ```bash
   kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
   ```

3. Confirm that the Metrics API responds (may take 1–2 minutes to gather initial metrics):

   ```bash
   kubectl get apiservices | grep metrics
   kubectl top nodes
   ```

4. View raw metrics exposed by the API:

   ```bash
   kubectl get --raw /apis/metrics.k8s.io/v1beta1/nodes | head -c 500
   ```

**Questions:**

- **1.a** Which component collects metrics on each node and passes them to metrics-server?
- **1.b** If `kubectl top nodes` returns `error: Metrics API not available`, what is the most likely cause?
- **1.c** Does metrics-server store historical metrics that you can query later?

---

## Exercise 2 — `kubectl top`: Actual CPU and Memory Usage

1. Deploy a workload that consumes CPU continuously:

   ```bash
   kubectl create deployment cpu-burner --image=busybox --replicas=2 \
     -- /bin/sh -c "while true; do :; done"
   ```

2. Deploy another workload that remains mostly idle:

   ```bash
   kubectl create deployment idler --image=busybox --replicas=1 \
     -- /bin/sh -c "sleep 3600"
   ```

3. Wait ~1 minute and check consumption per pod:

   ```bash
   kubectl top pods
   ```

4. Sort by CPU consumption and then by memory:

   ```bash
   kubectl top pods --sort-by=cpu
   kubectl top pods --sort-by=memory
   ```

5. View container-level breakdown inside each pod:

   ```bash
   kubectl top pods --containers
   ```

6. View aggregated node usage and compare with node capacity:

   ```bash
   kubectl top nodes
   kubectl describe node <node-name> | grep -A 8 "Allocated resources"
   ```

**Questions:**

- **2.a** What is the difference between what `kubectl top pods` shows versus the **requests** displayed in `kubectl describe node`?
- **2.b** On the exam, you are asked to find the pod consuming the most CPU in a namespace and save its name to a file. What command would you use?
- **2.c** What does the unit `m` mean in the `CPU(cores)` column (for example, `250m`)?

---

## Exercise 3 — `kubectl logs`: Reading Application Output

1. Create a pod with **two containers** writing to stdout:

   ```bash
   cat <<'EOF' | kubectl apply -f -
   apiVersion: v1
   kind: Pod
   metadata:
     name: dual-logger
   spec:
     containers:
     - name: app
       image: busybox
       command: ["/bin/sh", "-c", "while true; do echo \"[app] processing order $RANDOM\"; sleep 2; done"]
     - name: sidecar
       image: busybox
       command: ["/bin/sh", "-c", "while true; do echo \"[sidecar] heartbeat ok\"; sleep 5; done"]
   EOF
   ```

2. Try requesting logs without specifying a container and observe the error:

   ```bash
   kubectl logs dual-logger
   ```

3. Request logs from the correct container:

   ```bash
   kubectl logs dual-logger -c app
   kubectl logs dual-logger --all-containers=true
   ```

4. Follow live logs and interrupt with `Ctrl+C`:

   ```bash
   kubectl logs dual-logger -c app -f
   ```

5. Limit output: show only the last 5 lines, and only from the last minute:

   ```bash
   kubectl logs dual-logger -c app --tail=5
   kubectl logs dual-logger -c app --since=1m
   ```

6. Request logs from **multiple pods at once** using a label selector:

   ```bash
   kubectl logs -l app=cpu-burner --prefix=true --tail=3
   ```

7. Simulate a container crashing and restarting:

   ```bash
   kubectl run crasher --image=busybox -- /bin/sh -c "echo 'starting...'; sleep 5; echo 'FATAL ERROR: no DB connection'; exit 1"
   ```

   Wait for it to restart a couple of times (`kubectl get pod crasher`) and retrieve logs from the **previous execution**:

   ```bash
   kubectl logs crasher --previous
   ```

**Questions:**

- **3.a** Why did step 2 fail and which flag resolves it?
- **3.b** A pod is in `CrashLoopBackOff` and `kubectl logs <pod>` shows nothing useful because the container just restarted. Which flag lets you see why the previous execution died?
- **3.c** What requirement must an application satisfy for its logs to appear in `kubectl logs`?

---

## Exercise 4 — `kubectl describe` and `kubectl get events`: When Pods Fail to Start

`kubectl logs` works when the application runs. When a pod **fails to start** (non-existent image, resource shortage, unmountable volumes), details live in **events**.

1. Create a pod with a non-existent image:

   ```bash
   kubectl run broken --image=nginx:nonexistent
   ```

2. Check status:

   ```bash
   kubectl get pod broken
   ```

3. Inspect with `describe` and go directly to the `Events:` section at the bottom:

   ```bash
   kubectl describe pod broken
   ```

4. View current namespace events ordered chronologically:

   ```bash
   kubectl get events --sort-by=.lastTimestamp
   ```

5. Filter Warning-type events only:

   ```bash
   kubectl get events --field-selector type=Warning
   ```

6. Open one terminal watching live events while "fixing" the pod in a second terminal:

   ```bash
   # Terminal 1
   kubectl get events -w

   # Terminal 2
   kubectl set image pod/broken broken=nginx:1.27
   ```

**Questions:**

- **4.a** Which status did `broken` pod end up in during step 2, and which `describe` event explains why?
- **4.b** What is the practical difference between `kubectl logs` and `Events:` section of `kubectl describe pod` when troubleshooting?
- **4.c** Why is `--sort-by=.lastTimestamp` useful when listing events?

---

## Exercise 5 — Observing Live Changes: `--watch` and `rollout status`

1. Deploy an application with multiple replicas:

   ```bash
   kubectl create deployment web --image=nginx:1.27 --replicas=3
   ```

2. In one terminal, keep watching:

   ```bash
   kubectl get pods -l app=web -w
   ```

3. In another terminal, trigger a rollout and follow it with dedicated command:

   ```bash
   kubectl set image deployment/web nginx=nginx:1.28
   kubectl rollout status deployment/web
   ```

4. Observe in the first terminal how new pods are created and old ones terminate.

5. Inspect Deployment aggregated status and conditions:

   ```bash
   kubectl get deployment web
   kubectl describe deployment web | grep -A 5 Conditions
   ```

**Questions:**

- **5.a** What advantage does `kubectl rollout status` offer over watching `kubectl get pods -w` during a deployment?
- **5.b** When does `kubectl rollout status` command finish (returns prompt)?

---

## Exercise 6 — Comprehensive: Diagnose an OOMKilled Pod Using Built-in Tools Only

1. Create a pod attempting to consume more memory than its **limit**:

   ```bash
   cat <<'EOF' | kubectl apply -f -
   apiVersion: v1
   kind: Pod
   metadata:
     name: memory-hog
   spec:
     containers:
     - name: hog
       image: polinux/stress
       command: ["stress", "--vm", "1", "--vm-bytes", "250M", "--vm-hang", "1"]
       resources:
         requests:
           memory: "100Mi"
         limits:
           memory: "128Mi"
   EOF
   ```

2. Observe pod status changes:

   ```bash
   kubectl get pod memory-hog -w
   ```

3. Upon observing restarts, troubleshoot using all three tools from this topic:

   ```bash
   kubectl describe pod memory-hog | grep -A 5 "Last State"
   kubectl logs memory-hog --previous
   kubectl top pod memory-hog --containers
   ```

4. Record: what did each command reveal? Which gave the decisive insight?

5. Final lab cleanup:

   ```bash
   kubectl delete namespace monitor-lab
   kubectl config set-context --current --namespace=default
   ```

**Questions:**

- **6.a** Which value appears in `Reason` under `Last State` in `describe`, and what does it mean?
- **6.b** Why might `kubectl top` alone never show you the problem in this case?
- **6.c** Summarize the CKAD "troubleshooting ladder": in what order do you use `get`, `describe`, `logs`, and `top` when a pod fails, and what question does each answer?

---

<details>
<summary><strong>Answers</strong></summary>

### Exercise 1

- **1.a** The **kubelet** on each node collects container CPU and memory metrics (via cAdvisor, built into kubelet) and metrics-server aggregates and exposes them via Metrics API (`metrics.k8s.io`).
- **1.b** That **metrics-server is not installed** (or its pod is not `Ready` yet). `kubectl top` completely relies on Metrics API; without metrics-server, the command fails even if cluster is perfectly healthy otherwise.
- **1.c** No. metrics-server only holds the **most recent value** of each metric in memory. For historical tracking and alerting, external tools like Prometheus are used (outside scope of built-in CLI tools).

### Exercise 2

- **2.a** `kubectl top pods` displays **actual instantaneous usage** measured by kubelet. `describe node` **requests** represent resources **reserved** by pods when scheduled, used or not. A pod may reserve 500m and consume 5m, or vice versa (if requests were unassigned).
- **2.b** Example:

  ```bash
  kubectl top pods -n <namespace> --sort-by=cpu --no-headers | head -1 | awk '{print $1}' > /path/to/file.txt
  ```

  Exam key is `--sort-by=cpu`: highest consuming pod appears first.
- **2.c** They are **millicores**: thousandths of a CPU core. `250m` = 0.25 cores; `1000m` = 1 full core.

### Exercise 3

- **3.a** Failed because pod has **more than one container** and `kubectl logs` does not know which to show. Resolved with `-c <container-name>` or `--all-containers=true`.
- **3.b** `kubectl logs <pod> --previous` (short `-p`): shows logs from **previous container instance**, where error messages causing crash typically reside.
- **3.c** Must write logs to **stdout/stderr**. Kubelet captures those streams; if app writes strictly to an internal container file, `kubectl logs` shows nothing.

### Exercise 4

- **4.a** Enters `ErrImagePull` then `ImagePullBackOff`. In `Events:`, a `Failed` event appears explaining image `nginx:nonexistent` could not be pulled (`manifest unknown`), followed by `BackOff` backing off with increasing delay.
- **4.b** `kubectl logs` displays what **the application** says (requires container to have started). `Events:` display what **Kubernetes** says about pod lifecycle: scheduling, image pulling, volume mounting, failing probes, memory kills. If container never started, events are your sole source.
- **4.c** Default `kubectl get events` ordering does not guarantee strict timeline, and in an active namespace relevant events might get buried. Sorting by `.lastTimestamp` puts most recent entries at bottom in view.

### Exercise 5

- **5.a** `rollout status` interprets **overall Deployment status** (new available vs desired replicas) and reports in one line whether rollout progresses, finished, or stalled; `get pods -w` requires manually deducing state from individual pods.
- **5.b** When rollout **successfully completes** (all new replicas available), returns exit code 0; if Deployment exceeds `progressDeadlineSeconds`, exits with error. While progressing, command blocks (making it useful in scripts/pipelines).

### Exercise 6

- **6.a** `Reason: OOMKilled` with `Exit Code: 137`. Means Linux kernel killed the process because container exceeded its **memory limit** (128Mi) — Out Of Memory.
- **6.b** Because `kubectl top` displays instantaneous values with scraping latency: if container consumes memory suddenly and gets killed immediately, metric snapshots may never capture it near limit. Decisive evidence lives in `describe` (`Last State: OOMKilled`), not metrics.
- **6.c** Typical troubleshooting ladder:
  1. `kubectl get pod` — **what** state is it in? (Running, CrashLoopBackOff, ImagePullBackOff, restart count).
  2. `kubectl describe pod` — **why**, according to Kubernetes? (events, Last State, probes, resources).
  3. `kubectl logs` (with `--previous` if restarted) — **why**, according to application?
  4. `kubectl top` — is it a **resource limit/usage** issue right now?

</details>

---

**References:**

- CNCF — CKAD Curriculum v1.35: https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf
- Kubernetes — Resource metrics pipeline: https://kubernetes.io/docs/tasks/debug/debug-cluster/resource-metrics-pipeline/
- Kubernetes — Debug Running Pods: https://kubernetes.io/docs/tasks/debug/debug-application/debug-running-pod/
- Kubernetes — Logging Architecture: https://kubernetes.io/docs/concepts/cluster-administration/logging/
- Kubernetes — kubectl Reference: https://kubernetes.io/docs/reference/kubectl/
