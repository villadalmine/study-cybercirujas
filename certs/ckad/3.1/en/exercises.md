# 3.1 — Implement probes and health checks · Guided Exercises

> **Requirements:** a practice cluster (minikube, kind, or similar) and `kubectl` configured. Work in a clean namespace:
>
> ```bash
> kubectl create namespace probes-lab
> kubectl config set-context --current --namespace=probes-lab
> ```

---

## Exercise 1 — Liveness Probe with `exec`

A **liveness probe** tells the kubelet if the container is still alive. If it fails, the kubelet **restarts the container**. We will simulate an app that "hangs" after 30 seconds.

1. Create `liveness-exec.yaml`:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: liveness-exec
   spec:
     containers:
     - name: app
       image: busybox:1.36
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

2. Apply it and watch the Pod in real-time:

   ```bash
   kubectl apply -f liveness-exec.yaml
   kubectl get pod liveness-exec -w
   ```

3. Wait ~60 seconds. You will see the `RESTARTS` column begin to increment. Stop the watch with `Ctrl+C`.

4. Check the events to understand what happened:

   ```bash
   kubectl describe pod liveness-exec
   ```

   Look under the `Events` section for lines like `Liveness probe failed` and `Container app failed liveness probe, will be restarted`.

**Questions:**

- **Q1.** With `periodSeconds: 5` and the default `failureThreshold`, how many seconds (approximately) pass between `/tmp/healthy` being deleted and the container restart?
- **Q2.** Why does the `RESTARTS` counter increment instead of creating a brand new Pod with a different name?

---

## Exercise 2 — Liveness Probe with `httpGet` and Auto-Healing

HTTP probes treat **any status code ≥ 200 and < 400 as success**. We will deliberately break nginx and watch the liveness probe "heal" it.

1. Create `liveness-http.yaml`:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: liveness-http
   spec:
     containers:
     - name: web
       image: nginx:1.27
       ports:
       - containerPort: 80
       livenessProbe:
         httpGet:
           path: /
           port: 80
         initialDelaySeconds: 3
         periodSeconds: 5
   ```

2. Apply it and verify it becomes `Running` with `0` restarts:

   ```bash
   kubectl apply -f liveness-http.yaml
   kubectl get pod liveness-http
   ```

3. Now break the app: delete the page responding at `/`:

   ```bash
   kubectl exec liveness-http -- rm /usr/share/nginx/html/index.html
   ```

   Without `index.html`, nginx returns `403 Forbidden` on `/`.

4. Observe the Pod for ~30 seconds:

   ```bash
   kubectl get pod liveness-http -w
   ```

5. When you see `RESTARTS: 1`, verify that the index page is restored:

   ```bash
   kubectl exec liveness-http -- ls /usr/share/nginx/html/
   ```

**Questions:**

- **Q3.** Why does a `403 Forbidden` trigger a probe failure if the nginx process is still running and responding?
- **Q4.** Why did `index.html` reappear after the restart even though nobody recreated it manually?

---

## Exercise 3 — Readiness Probe and Service Impact

A **readiness probe** does not restart anything: it decides if the Pod **receives traffic**. While failing, the Pod is removed from Service endpoints.

1. Create `readiness.yaml` with a Deployment and Service:

   ```yaml
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
           image: nginx:1.27
           ports:
           - containerPort: 80
           readinessProbe:
             exec:
               command:
               - cat
               - /tmp/ready
             periodSeconds: 5
   ---
   apiVersion: v1
   kind: Service
   metadata:
     name: web
   spec:
     selector:
       app: web
     ports:
     - port: 80
       targetPort: 80
   ```

2. Apply it and inspect state:

   ```bash
   kubectl apply -f readiness.yaml
   kubectl get pods -l app=web
   ```

   Pods are `Running` but `READY` shows `0/1` because `/tmp/ready` does not exist.

3. Confirm the Service has **no endpoints**:

   ```bash
   kubectl get endpointslices -l kubernetes.io/service-name=web
   ```

4. "Enable" just one of the Pods (replace `<POD1>` with the actual name):

   ```bash
   kubectl exec <POD1> -- touch /tmp/ready
   ```

5. Repeat steps 2 and 3: one Pod transitions to `1/1` and its IP appears in the EndpointSlice; the other remains out.

6. Note that no Pod was restarted during the exercise:

   ```bash
   kubectl get pods -l app=web
   ```

**Questions:**

- **Q5.** What is the key difference between the effect of a failing liveness probe vs a failing readiness probe?
- **Q6.** During a Deployment rolling update, what role does the readiness probe play to prevent downtime?
- **Q7.** If a Pod in this Deployment loses readiness after being `Ready` (e.g. someone deletes `/tmp/ready`), what happens to it?

---

## Exercise 4 — Startup Probe for Slow-Starting Apps

An app taking long to start can be killed by its own liveness probe before it is ready. The **startup probe** disables other probes until initial startup completes.

1. Create `startup.yaml`. The app simulates a ~40-second startup:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: slow-start
   spec:
     containers:
     - name: app
       image: busybox:1.36
       args:
       - /bin/sh
       - -c
       - sleep 40; touch /tmp/started; sleep 3600
       startupProbe:
         exec:
           command:
           - cat
           - /tmp/started
         periodSeconds: 5
         failureThreshold: 12
       livenessProbe:
         exec:
           command:
           - cat
           - /tmp/started
         periodSeconds: 5
         failureThreshold: 2
   ```

2. Apply and observe:

   ```bash
   kubectl apply -f startup.yaml
   kubectl get pod slow-start -w
   ```

   The Pod takes ~40–45 seconds to become `READY 1/1`, **with 0 restarts**.

3. Verify in events that startup probe failed multiple times without fatal consequences:

   ```bash
   kubectl describe pod slow-start | grep -A5 Events
   ```

4. For comparison, edit manifest: delete `startupProbe` block completely, delete Pod and re-apply:

   ```bash
   kubectl delete pod slow-start
   kubectl apply -f startup.yaml
   kubectl get pod slow-start -w
   ```

   Now liveness probe (allowing only 2 failures × 5s) kills container before `sleep 40` finishes, repeatedly: Pod enters `CrashLoopBackOff`.

**Questions:**

- **Q8.** With `periodSeconds: 5` and `failureThreshold: 12`, how much maximum startup time does this startup probe tolerate?
- **Q9.** Why is a startup probe a better solution than setting `initialDelaySeconds: 60` on the liveness probe?
- **Q10.** Do liveness probe and readiness probe execute while startup probe has not yet succeeded?

---

## Exercise 5 — `tcpSocket` and Probe Parameters

Not all apps speak HTTP. Databases and similar services use `tcpSocket`: probe succeeds if TCP connection opens.

1. Create a Pod with redis and TCP probe using `kubectl run` + editing. First generate base:

   ```bash
   kubectl run redis --image=redis:7 --dry-run=client -o yaml > redis.yaml
   ```

2. Edit `redis.yaml` to add both probes to the container:

   ```yaml
       readinessProbe:
         tcpSocket:
           port: 6379
         initialDelaySeconds: 2
         periodSeconds: 5
       livenessProbe:
         tcpSocket:
           port: 6379
         initialDelaySeconds: 10
         periodSeconds: 10
         timeoutSeconds: 2
   ```

3. Apply and confirm `1/1 Running`:

   ```bash
   kubectl apply -f redis.yaml
   kubectl get pod redis
   ```

4. In the exam, there is no time to look up every field in documentation. Practice querying with `kubectl explain`:

   ```bash
   kubectl explain pod.spec.containers.livenessProbe
   kubectl explain pod.spec.containers.livenessProbe.httpGet
   ```

   Read default values for `periodSeconds`, `timeoutSeconds`, `failureThreshold`, and `successThreshold`.

5. Final lab cleanup:

   ```bash
   kubectl delete namespace probes-lab
   kubectl config set-context --current --namespace=default
   ```

**Questions:**

- **Q11.** What are default values for `periodSeconds`, `timeoutSeconds`, `failureThreshold`, and `successThreshold`?
- **Q12.** For which probe is setting `successThreshold` to anything other than 1 **prohibited**, and why does that restriction make sense?
- **Q13.** Name the four check mechanisms a probe can use.

---

## Answers

<details>
<summary>View Answers</summary>

- **Q1.** Default `failureThreshold` is **3**. With `periodSeconds: 5`, kubelet needs 3 consecutive failures: approximately **15 seconds** (plus minor timing margin) between file deletion and restart.

- **Q2.** Liveness probe is handled by **kubelet**, which restarts the **container** inside the same Pod according to `restartPolicy` (default `Always`). The Pod is never destroyed or rescheduled: retains name, IP, and node; only container changes, reflected in `RESTARTS`.

- **Q3.** `httpGet` probe checks **HTTP response code**, not process existence: only codes ≥ 200 and < 400 count as success. `403` falls outside that range, so probe fails even though nginx is running. That is the core value of probes: detecting "alive but broken" apps.

- **Q4.** On restart, kubelet creates a **fresh container from image**, discarding write layer where file was deleted. Everything not in a volume is reset on restart.

- **Q5.** Failed liveness → kubelet **restarts container**. Failed readiness → Pod marked `NotReady` and **removed from Service endpoints** (no traffic), but container continues running intact.

- **Q6.** During rollout, Deployment waits for new Pods to be `Ready` before scaling down old ones (respecting `maxUnavailable`/`maxSurge`). Without readiness probe, Pod counts as ready as soon as container starts, potentially routing traffic to unready replicas.

- **Q7.** Nothing destructive: Pod returns to `NotReady`, is removed from Service endpoints, and stops receiving traffic. If probe succeeds again (per `successThreshold`), Pod automatically rejoins. Never restarts due to readiness.

- **Q8.** `12 × 5s = 60 seconds` maximum (plus first check timing). If probe does not succeed within that window, container restarts as if liveness failed.

- **Q9.** `initialDelaySeconds: 60` penalizes **all** startups with a fixed wait: if app starts in 5s, it remains 60s without liveness protection. Startup probe adapts: as soon as it succeeds, it yields control to other probes while tolerating slow starts up to its cap (`failureThreshold × periodSeconds`).

- **Q10.** No. Until startup probe succeeds, liveness and readiness probes are **disabled**. Only after startup probe passes do the other two begin executing.

- **Q11.** Defaults: `periodSeconds: 10`, `timeoutSeconds: 1`, `failureThreshold: 3`, `successThreshold: 1`. (`initialDelaySeconds` is 0 if omitted.)

- **Q12.** For **liveness** (and startup) probes, `successThreshold` must be 1. After restart, container starts fresh; requiring multiple consecutive successes adds no value and complicates restart cycles. In readiness, requiring multiple successes before resuming traffic can be useful.

- **Q13.** `exec` (executes command inside container; success if exit code 0), `httpGet` (success if HTTP status ≥ 200 and < 400), `tcpSocket` (success if TCP connection opens), and `grpc` (success if service returns `SERVING` to gRPC health check protocol).

</details>

---

## References

- CNCF — CKAD Curriculum v1.35: https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf
- Kubernetes — Configure Liveness, Readiness and Startup Probes: https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/
- Kubernetes — Pod Lifecycle (container probes): https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/#container-probes
