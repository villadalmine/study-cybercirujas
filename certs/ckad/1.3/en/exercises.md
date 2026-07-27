# CKAD 1.3 — Multi-Container Pod Design Patterns

**Exam weight:** 5%
**Reference:** [CNCF CKAD Curriculum v1.35](https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf)

A Pod is the atomic scheduling unit in Kubernetes, but it is not limited to one container. All containers in a Pod share the same network namespace (one IP, one port space) and can share storage through volumes, while each container still has its own filesystem, process tree, and (by default) resource limits. This exercise set walks through why you'd combine containers, then builds each of the four canonical patterns named in the curriculum: **init containers**, **sidecar**, **adapter**, and **ambassador**.

---

## Exercise 1 — Shared network and shared storage

1. Create a working namespace and switch to it:
```bash
kubectl create namespace ckad-multi
kubectl config set-context --current --namespace=ckad-multi
```

2. Save the following as `shared-net.yaml`. Two containers, no volume yet — just to prove the network namespace is shared:
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: shared-net
spec:
  containers:
  - name: web
    image: nginx:1.27
    ports:
    - containerPort: 80
  - name: curler
    image: busybox:1.36
    command: ["sh", "-c", "sleep 3600"]
```

3. Apply it and wait for both containers to be ready:
```bash
kubectl apply -f shared-net.yaml
kubectl wait --for=condition=Ready pod/shared-net --timeout=60s
```

4. From the `curler` container, reach `nginx` over `localhost`, not a Service or Pod IP:
```bash
kubectl exec shared-net -c curler -- wget -qO- http://localhost:80 | head -n 5
```

5. Now prove storage isolation: try to list `/usr/share/nginx/html` (nginx's content dir) from `curler` — it will not exist, because each container has its own filesystem unless a volume is mounted:
```bash
kubectl exec shared-net -c curler -- ls /usr/share/nginx/html
```

**Q1.** Why did step 4 work using `localhost` instead of a Pod IP or DNS name?
**Q2.** Why did step 5 fail, given that step 4 proved the containers share a network namespace?

---

## Exercise 2 — Init containers

Init containers run sequentially, to completion, **before** any regular container starts. If one fails, Kubernetes retries it according to the Pod's `restartPolicy`; the Pod never starts its main containers until all init containers succeed.

1. Save as `init-demo.yaml` — an init container writes a config file to an `emptyDir`, which the main container then reads:
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: init-demo
spec:
  initContainers:
  - name: fetch-config
    image: busybox:1.36
    command:
    - sh
    - -c
    - |
      echo "Waiting for dependency..."
      sleep 5
      echo "app.mode=production" > /work/config.properties
    volumeMounts:
    - name: config-vol
      mountPath: /work
  containers:
  - name: app
    image: busybox:1.36
    command: ["sh", "-c", "cat /etc/config/config.properties && sleep 3600"]
    volumeMounts:
    - name: config-vol
      mountPath: /etc/config
  volumes:
  - name: config-vol
    emptyDir: {}
```

2. Apply it and immediately check status — you should see the init container running before `app` starts:
```bash
kubectl apply -f init-demo.yaml
kubectl get pod init-demo -w
```
(Press Ctrl+C once `STATUS` reaches `Running` with `1/1`.)

3. Confirm the init container ran and exited successfully, and that the main container saw the file it produced:
```bash
kubectl get pod init-demo -o jsonpath='{.status.initContainerStatuses[0].state}'
kubectl logs init-demo -c app
```

4. Break it on purpose — edit the init container's command to `exit 1` instead of writing the file, reapply, and observe:
```bash
kubectl delete pod init-demo
# edit init-demo.yaml: change the last line to `exit 1`
kubectl apply -f init-demo.yaml
kubectl get pod init-demo
kubectl describe pod init-demo | grep -A3 "Init Containers"
```

**Q1.** In step 4, what status does the Pod report, and does the `app` container ever start?
**Q2.** Give one real-world reason to use an init container instead of putting the same setup logic at the top of the main container's entrypoint script.

---

## Exercise 3 — Classic sidecar: log shipping

The sidecar pattern extends the main container with a helper that runs for the Pod's entire lifetime, sharing its network and/or storage. A very common example is a log-shipping sidecar that tails a file the app writes.

1. Save as `sidecar-logs.yaml`:
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: sidecar-logs
spec:
  containers:
  - name: app
    image: busybox:1.36
    command:
    - sh
    - -c
    - |
      i=0
      while true; do
        echo "$(date +%T) event-$i" >> /var/log/app.log
        i=$((i+1))
        sleep 2
      done
    volumeMounts:
    - name: logs
      mountPath: /var/log
  - name: log-shipper
    image: busybox:1.36
    command: ["sh", "-c", "tail -F /var/log/app.log"]
    volumeMounts:
    - name: logs
      mountPath: /var/log
  volumes:
  - name: logs
    emptyDir: {}
```

2. Apply it and follow the sidecar's own logs — it should print lines the `app` container is writing to a file it never logs to stdout itself:
```bash
kubectl apply -f sidecar-logs.yaml
kubectl logs sidecar-logs -c log-shipper --follow --tail=5
```
(Ctrl+C after a few lines appear.)

3. Confirm `app`'s own stdout is empty, since it never writes to stdout directly:
```bash
kubectl logs sidecar-logs -c app
```

4. Scale down: delete the sidecar container's image mount and observe both containers still tracked as one restart/scheduling unit:
```bash
kubectl get pod sidecar-logs -o jsonpath='{.spec.containers[*].name}{"\n"}'
kubectl get pod sidecar-logs -o jsonpath='{.status.containerStatuses[*].restartCount}{"\n"}'
```

**Q1.** What two things does the sidecar in this exercise share with `app` to do its job, and which one is doing the actual work here (the shared volume or the shared network)?
**Q2.** If `log-shipper` crashes and restarts, does `app` restart too? What does that tell you about container-level failure isolation inside a Pod?

---

## Exercise 4 — Native sidecar containers (init container with `restartPolicy: Always`)

Since Kubernetes 1.29 (stable in 1.33+), you can declare a sidecar as an `initContainer` with `restartPolicy: Always`. It starts before the main containers (like a normal init container) but keeps running afterward, and `kubectl wait`/readiness gates treat it correctly — solving the old race condition where a hand-rolled sidecar container might not be ready before the main container needs it.

1. Save as `native-sidecar.yaml`:
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: native-sidecar
spec:
  initContainers:
  - name: proxy-sidecar
    image: busybox:1.36
    restartPolicy: Always
    command: ["sh", "-c", "while true; do echo proxy-alive; sleep 5; done"]
    startupProbe:
      exec:
        command: ["true"]
      failureThreshold: 1
      periodSeconds: 1
  containers:
  - name: app
    image: busybox:1.36
    command: ["sh", "-c", "sleep 3600"]
```

2. Apply it and check container counts — a native sidecar counts toward `READY`, unlike a plain (non-`Always`) init container:
```bash
kubectl apply -f native-sidecar.yaml
kubectl get pod native-sidecar
```

3. Inspect where the sidecar is listed in the spec vs. how it behaves at runtime:
```bash
kubectl get pod native-sidecar -o jsonpath='{.spec.initContainers[0].name}{" restartPolicy="}{.spec.initContainers[0].restartPolicy}{"\n"}'
kubectl logs native-sidecar -c proxy-sidecar --tail=3
```

4. Delete the main container's process to force a restart, and confirm the sidecar is untouched (it manages its own restart lifecycle independently):
```bash
kubectl exec native-sidecar -c app -- sh -c "kill 1"
kubectl get pod native-sidecar -o jsonpath='{.status.containerStatuses[?(@.name=="app")].restartCount}{"\n"}'
kubectl get pod native-sidecar -o jsonpath='{.status.initContainerStatuses[?(@.name=="proxy-sidecar")].restartCount}{"\n"}'
```

**Q1.** What field, absent from a regular init container, turns `proxy-sidecar` into a native sidecar?
**Q2.** Name the specific ordering problem this feature solves that the Exercise 3-style sidecar does not.

---

## Exercise 5 — Adapter pattern: normalizing output for a monitoring system

An adapter sits next to the main container and transforms its output into a standard shape expected by some external system — without modifying the main container's code.

1. Save as `adapter-demo.yaml`. `app` writes metrics in a custom format; `adapter` reads them and rewrites them in Prometheus text format on a shared volume:
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: adapter-demo
spec:
  containers:
  - name: app
    image: busybox:1.36
    command:
    - sh
    - -c
    - |
      while true; do
        echo "requests_total|$RANDOM" > /data/raw-metrics.txt
        sleep 5
      done
    volumeMounts:
    - name: metrics
      mountPath: /data
  - name: adapter
    image: busybox:1.36
    command:
    - sh
    - -c
    - |
      while true; do
        if [ -f /data/raw-metrics.txt ]; then
          VAL=$(cut -d'|' -f2 /data/raw-metrics.txt)
          echo "requests_total $VAL" > /data/metrics.prom
        fi
        sleep 5
      done
    volumeMounts:
    - name: metrics
      mountPath: /data
  volumes:
  - name: metrics
    emptyDir: {}
```

2. Apply and wait, then compare the raw format `app` produces to the normalized format `adapter` produces:
```bash
kubectl apply -f adapter-demo.yaml
sleep 8
kubectl exec adapter-demo -c adapter -- cat /data/raw-metrics.txt
kubectl exec adapter-demo -c adapter -- cat /data/metrics.prom
```

3. Confirm `app`'s image and command were never changed to know about Prometheus format — only `adapter` knows that shape:
```bash
kubectl get pod adapter-demo -o jsonpath='{.spec.containers[0].command}{"\n"}'
```

**Q1.** What distinguishes the adapter pattern here from the logging sidecar in Exercise 3, given both read a file the main container wrote?
**Q2.** If you needed to also expose these metrics to a second monitoring system in a different format, would you modify `app`, or add another container? Why?

---

## Exercise 6 — Ambassador pattern: proxying outbound connections

An ambassador is a network proxy sidecar: the main container always talks to `localhost`, and the ambassador forwards traffic to the real (possibly changing, possibly remote) destination. This decouples the app from service discovery/connection details.

1. Save as `ambassador-demo.yaml`. `app` always connects to `localhost:6380`; `ambassador` forwards that to a real Redis-like endpoint (simulated here with `socat` against a public echo-style target replaced by a local netcat listener for this exercise):
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: ambassador-demo
spec:
  containers:
  - name: ambassador
    image: alpine/socat:1.8.0.0
    args:
    - "-v"
    - "TCP-LISTEN:6380,fork,reuseaddr"
    - "TCP:backend-svc:6379"
    ports:
    - containerPort: 6380
  - name: app
    image: busybox:1.36
    command: ["sh", "-c", "sleep 3600"]
```

2. Because `backend-svc` doesn't exist in this exercise, apply it and inspect the ambassador's own logs to see it attempting (and failing) the forward — the point here is to see the proxy boundary, not a working backend:
```bash
kubectl apply -f ambassador-demo.yaml
kubectl logs ambassador-demo -c ambassador --tail=5
```

3. From `app`, attempt a connection strictly to `localhost:6380` — never to `backend-svc` directly:
```bash
kubectl exec ambassador-demo -c app -- sh -c "echo test | nc -w2 localhost 6380"
```

4. Now change only the ambassador container's `args` to point at a different backend (e.g. `TCP:backend-svc-v2:6379`), leaving `app`'s spec completely untouched, and reapply:
```bash
# edit ambassador-demo.yaml: change backend-svc to backend-svc-v2 in the ambassador args
kubectl apply -f ambassador-demo.yaml
kubectl get pod ambassador-demo -o jsonpath='{.spec.containers[0].args}{"\n"}'
```

**Q1.** In step 4, why did switching backends require zero changes to `app`'s container spec?
**Q2.** How is the ambassador pattern different from the adapter pattern in terms of *what* is being abstracted away from the main container (output format vs. something else)?

---

## Cleanup

```bash
kubectl delete namespace ckad-multi
```

---

<details>
<summary><strong>Answers</strong></summary>

**Exercise 1**

*Q1.* All containers in a Pod share a single network namespace, so they share one Pod IP and one port space. From `curler`'s point of view, `nginx` listening on port 80 is indistinguishable from a process on `curler`'s own `localhost` — exactly like two processes on the same VM.

*Q2.* The network namespace is shared, but the filesystem is not — each container gets its own root filesystem from its own image, unless the Pod spec explicitly mounts a shared volume into both. No volume was defined in `shared-net.yaml`, so `curler` has no visibility into `nginx`'s files.

**Exercise 2**

*Q1.* The Pod status shows `Init:CrashLoopBackOff` (or `Init:Error` transitioning to `CrashLoopBackOff` on retries), and `app` never starts — Kubernetes will not start any regular container until every init container in the list has exited with status 0, in order.

*Q2.* Typical reasons: the init logic needs different privileges, tools, or a different base image than the main container (e.g. a `git clone` or `chmod`-heavy setup step using a full-featured image, while the main container stays minimal); it needs to block startup entirely on an external dependency (e.g. a schema migration) rather than retry inside the app's own process; or it needs to run exactly once per Pod restart with a clean, auditable start/stop, which is easier to reason about than embedding conditional logic in the app's entrypoint.

**Exercise 3**

*Q1.* The sidecar shares the volume `logs` (an `emptyDir`) with `app` — that's the mechanism doing the actual work here (reading a file `app` wrote). The network namespace is also shared but isn't used by this particular sidecar, since it isn't making any network calls.

*Q2.* No — `app` does not restart when `log-shipper` restarts. Each container has its own restart count and lifecycle within the Pod; a crash in one container does not directly restart its Pod-mates (though `restartPolicy` still governs each container independently, and the Pod as a whole stays "up" as long as at least it's not fully terminated). This demonstrates that "same Pod" means shared environment, not shared failure domain — you still get per-container isolation and independent restart accounting.

**Exercise 4**

*Q1.* `restartPolicy: Always` set on the init container entry itself (not the Pod-level `restartPolicy`). This is what tells the kubelet to start it like an init container (before regular containers) but keep it running like a sidecar, restarting it if it exits, instead of requiring it to complete before the Pod proceeds.

*Q2.* It solves the sidecar-not-ready-before-app-needs-it race: with a plain sidecar declared as a second entry under `containers:`, Kubernetes starts all regular containers concurrently, so the app container can start (and immediately try to use the sidecar, e.g. a service mesh proxy) before the sidecar has finished initializing. A native sidecar is guaranteed to be started (and can be gated on `startupProbe`/readiness) before any regular container begins.

**Exercise 5**

*Q1.* Both patterns read a file the main container produced from a shared volume, but the adapter's defining trait is that it **transforms the shape/format** of that output for an external consumer (raw custom format → Prometheus exposition format), rather than simply relaying or shipping the data unchanged, which is what the Exercise 3 sidecar did (`tail -F` just streams the same content).

*Q2.* Add another container. The adapter pattern exists specifically so format-specific logic lives outside the main application container — adding a second adapter container (or extending the existing one) keeps `app` completely unaware of any monitoring system's expected shape, which is the whole point of decoupling via this pattern.

**Exercise 6**

*Q1.* `app` never references `backend-svc` at all — it only ever talks to `localhost:6380`. All knowledge of the real backend's address lives in the `ambassador` container's config/args. Changing the backend is purely an ambassador-container change, which is the core value of the pattern: the main container's code and connection logic never change when the topology behind it does.

*Q2.* The adapter pattern abstracts away **output format** (how data the main container produces is shaped for a consumer). The ambassador pattern abstracts away **network destination/connection details** (where and how the main container's outbound — or inbound — traffic actually gets routed), letting the main container treat a complex or changeable network topology as a fixed `localhost` connection.

</details>