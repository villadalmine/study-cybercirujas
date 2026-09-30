# 2.5 Configuring Pod Endpoint Availability

> **Exam weight:** 4.17% · **Scope:** readiness, startup and liveness probes, EndpointSlice conditions (`ready` / `serving` / `terminating`), readiness gates, graceful termination and connection draining, `publishNotReadyAddresses`, rollout availability knobs (`maxUnavailable`, `maxSurge`, `minReadySeconds`), PodDisruptionBudgets, and selectorless Services with hand-managed EndpointSlices.

---

## 1. Motivation: the production problem

A Kubernetes Service is only as reliable as its **endpoint list**. A Pod IP should receive traffic only while the process behind it can answer correctly. Every consumer of Service discovery reads that list: kube-proxy (iptables/nftables/IPVS), eBPF dataplanes such as Cilium, CoreDNS for headless Services, Ingress and Gateway controllers, and service meshes.

Most 5xx spikes in a healthy cluster come from the endpoint list being wrong for a few seconds:

| Symptom in production | Root cause at the endpoint layer |
|---|---|
| 502/503 burst on every deploy | New Pods marked ready before warm-up, or old Pods killed before the dataplane removed them |
| `connection refused` during node drain | Process exits on SIGTERM before kube-proxy and the load balancers have converged |
| Whole service goes dark when a database blips | Readiness probe checks a shared downstream dependency, so every replica fails at once |
| Slow-starting JVM stuck in a restart loop | Liveness probe fires before startup finishes (no `startupProbe`) |
| StatefulSet peers can't find each other at bootstrap | Headless Service only publishes *ready* Pods, but readiness depends on peers being present |
| Cluster upgrade takes down a quorum | No PodDisruptionBudget, so voluntary evictions are unbounded |
| Cloud LB sends traffic to Pods it has not registered yet | Pod readiness does not include the external system's state (no readiness gate) |

What this topic teaches is controlling **exactly when a Pod IP enters and leaves the endpoint set**, and making every consumer converge before the process stops accepting connections.

---

## 2. The availability pipeline: from probe to packet

```
 kubelet (per node)                 control plane                        consumers
 ──────────────────                 ─────────────                        ─────────
 startupProbe ─┐
 readinessProbe├─► Pod.status.conditions ──► EndpointSlice controller ──► kube-proxy / eBPF
 livenessProbe ┘     ContainersReady          (kube-controller-manager)    CoreDNS (headless)
 readinessGates ───► Ready                    discovery.k8s.io/v1          Ingress / Gateway
 (external ctrl)     deletionTimestamp ──►    endpoints[].conditions:      mesh control planes
                                                ready / serving /
                                                terminating
```

Key facts:

1. **The kubelet owns `ContainersReady`**. It is `True` when every container's readiness probe passes, or when a container has no readiness probe and is running.
2. **`Ready` = `ContainersReady` AND every `readinessGates` condition is `True`.**
3. The **EndpointSlice controller** watches Pods and Services. For each Pod matched by a Service selector it writes one endpoint with three conditions:

| Condition | Meaning | Derived from |
|---|---|---|
| `ready` | Should receive **new** traffic | Pod `Ready=True` **and** not terminating (always `true` if `publishNotReadyAddresses: true`) |
| `serving` | Process is passing readiness, whether or not it is terminating | Pod `Ready` condition only |
| `terminating` | Pod has a `deletionTimestamp` | Pod metadata |

So `ready == serving && !terminating` in the normal case. `serving` and `terminating` have been GA since v1.26. They exist so that a dataplane can tell apart "shutting down but still able to finish work" and "broken".

4. **kube-proxy** programs only `ready` endpoints. When a Service has **no ready endpoints at all**, it falls back to endpoints that are `serving && terminating`. This is the *ProxyTerminatingEndpoints* behavior, GA in v1.28. It stops a rolling restart of an `externalTrafficPolicy: Local` Service from blackholing a node that has only terminating Pods left.
5. The legacy `v1 Endpoints` object is still mirrored but was **deprecated in v1.33**. It caps at 1000 addresses (annotation `endpoints.kubernetes.io/over-capacity: truncated`) and cannot express `serving`/`terminating`. Always diagnose with EndpointSlices.

---

## 3. Probes: design and trade-offs

### 3.1 The three probes

| Probe | Question it answers | Effect on failure | Runs when |
|---|---|---|---|
| `startupProbe` | Has the app finished booting? | Container restarted after `failureThreshold × periodSeconds` | Only until the first success; liveness and readiness are **suspended** while it runs |
| `readinessProbe` | Should this Pod receive traffic **right now**? | Pod removed from `ready` endpoints; **no restart** | Whole container lifetime, **including termination** (this drives `serving`) |
| `livenessProbe` | Is the process wedged beyond self-recovery? | Container **killed and restarted** | After startup succeeds |

### 3.2 Mechanisms

| Handler | Use when | Caveats |
|---|---|---|
| `httpGet` | HTTP apps; dedicated `/readyz` and `/livez` endpoints | 200–399 = success. Redirects to another host are not followed (treated as success with an event). Runs from the kubelet's network namespace to the Pod IP |
| `tcpSocket` | Non-HTTP servers (DBs, brokers) | Only proves `accept()` works, not that the app is healthy |
| `grpc` | gRPC servers implementing `grpc.health.v1.Health` (GA v1.27) | Needs the health service; `service:` field selects the named service |
| `exec` | Complex local checks | Forks a process on every period; expensive at scale; subject to `timeoutSeconds` |

### 3.3 Timing fields (defaults in parentheses)

| Field | Default | Notes |
|---|---|---|
| `initialDelaySeconds` | 0 | Prefer a `startupProbe` over large delays |
| `periodSeconds` | 10 | Readiness reaction time ≈ `period × failureThreshold` |
| `timeoutSeconds` | 1 | Too low under CPU throttling means false negatives |
| `successThreshold` | 1 | Must be 1 for liveness and startup; >1 is allowed for readiness |
| `failureThreshold` | 3 | |
| `terminationGracePeriodSeconds` (probe-level) | inherits Pod | Liveness/startup only (GA v1.25): shorter kill window when a probe triggers the restart |

**Detection latency** for a readiness failure ≈ `periodSeconds × failureThreshold` + EndpointSlice controller batching (`--endpointslice-updates-batch-period`, 0 by default) + dataplane sync. With the defaults that is about 30 s of blackholed requests. Tune `periodSeconds: 2–5` and `failureThreshold: 2–3` for latency-sensitive services.

### 3.4 Anti-patterns

| Anti-pattern | Why it hurts | Better |
|---|---|---|
| Readiness checks a shared DB/cache | Dependency outage marks **all** replicas unready, so the Service has 0 endpoints and fails fast with `connection refused` instead of degrading | Check local ability to serve; handle dependency failures in the app (circuit breaker, 503 per request) |
| Liveness == readiness endpoint | A temporary overload makes liveness fail, restarts pile up and the outage cascades | Liveness checks only "event loop alive"; readiness checks "can serve" |
| No startup probe + big `initialDelaySeconds` on liveness | Slow boots restart forever; fast boots wait for no reason | `startupProbe` with a generous `failureThreshold` |
| `exec` probe running `curl` | Needs a binary in the image; fork cost | `httpGet` |
| `timeoutSeconds: 1` on a GC-heavy runtime | Pause spikes flap readiness | 2–5 s timeout and `failureThreshold ≥ 3` |

---

## 4. Lab: a fully instrumented Service

Everything below works on any conformant cluster (kind, kubeadm, managed). The readiness probe reads a file that you can delete to simulate "not ready" without killing the process.

### 4.1 Namespace, Deployment, Service, PDB

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: ckne-avail
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: ckne-avail
  labels:
    app.kubernetes.io/name: web
spec:
  replicas: 3
  revisionHistoryLimit: 5
  progressDeadlineSeconds: 300
  minReadySeconds: 10
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  selector:
    matchLabels:
      app.kubernetes.io/name: web
  template:
    metadata:
      labels:
        app.kubernetes.io/name: web
    spec:
      terminationGracePeriodSeconds: 45
      initContainers:
        - name: seed-content
          image: busybox:1.36
          command:
            - sh
            - -c
            - |
              echo "hello from $(hostname)" > /work/index.html
              echo "ok" > /work/ready
          volumeMounts:
            - name: html
              mountPath: /work
      containers:
        - name: nginx
          image: nginx:1.27
          ports:
            - name: http
              containerPort: 80
              protocol: TCP
          startupProbe:
            httpGet:
              path: /
              port: http
            periodSeconds: 2
            failureThreshold: 30
          readinessProbe:
            httpGet:
              path: /ready
              port: http
            periodSeconds: 2
            timeoutSeconds: 2
            successThreshold: 1
            failureThreshold: 2
          livenessProbe:
            httpGet:
              path: /
              port: http
            periodSeconds: 10
            timeoutSeconds: 3
            failureThreshold: 3
          lifecycle:
            preStop:
              sleep:
                seconds: 10
          resources:
            requests:
              cpu: 50m
              memory: 32Mi
            limits:
              memory: 64Mi
          volumeMounts:
            - name: html
              mountPath: /usr/share/nginx/html
      volumes:
        - name: html
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: web
  namespace: ckne-avail
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: web
  ports:
    - name: http
      port: 80
      targetPort: http
      protocol: TCP
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: web
  namespace: ckne-avail
spec:
  minAvailable: 2
  unhealthyPodEvictionPolicy: AlwaysAllow
  selector:
    matchLabels:
      app.kubernetes.io/name: web
```

Design notes:

- `lifecycle.preStop.sleep` is the native sleep action (enabled by default since v1.30), so the image does not need a `sleep` binary. On older clusters use `exec: {command: ["sleep", "10"]}`.
- `terminationGracePeriodSeconds: 45` **includes** the preStop time. Here that leaves 35 s for nginx to drain after the stop signal. The official `nginx` image declares `STOPSIGNAL SIGQUIT`, which is nginx's *graceful* shutdown, and the container runtime honors it.
- `maxUnavailable: 0` + `maxSurge: 1` means capacity never drops below `replicas` during a rollout.
- `minReadySeconds: 10` means a new Pod counts as *available* to the Deployment controller only after it has been Ready for 10 s. This catches Pods that pass readiness once and then crash.

### 4.2 Apply and inspect

```
$ kubectl apply -f web.yaml
namespace/ckne-avail created
deployment.apps/web created
service/web created
poddisruptionbudget.policy/web created

$ kubectl -n ckne-avail rollout status deploy/web
Waiting for deployment "web" rollout to finish: 0 of 3 updated replicas are available...
Waiting for deployment "web" rollout to finish: 2 of 3 updated replicas are available...
deployment "web" successfully rolled out

$ kubectl -n ckne-avail get pods -o wide
NAME                   READY   STATUS    RESTARTS   AGE   IP            NODE       NOMINATED NODE   READINESS GATES
web-7d9c8b6f5d-4kq2x   1/1     Running   0          41s   10.244.1.12   worker-1   <none>           <none>
web-7d9c8b6f5d-8vzlp   1/1     Running   0          41s   10.244.2.7    worker-2   <none>           <none>
web-7d9c8b6f5d-r6ntm   1/1     Running   0          41s   10.244.1.13   worker-1   <none>           <none>

$ kubectl -n ckne-avail get endpointslices -l kubernetes.io/service-name=web
NAME        ADDRESSTYPE   PORTS   ENDPOINTS                           AGE
web-x8f2k   IPv4          80      10.244.1.12,10.244.2.7,10.244.1.13  41s
```

The `ENDPOINTS` column lists **every** address in the slice, including non-ready ones. It is not proof of readiness. Read the conditions:

```
$ kubectl -n ckne-avail get endpointslices -l kubernetes.io/service-name=web \
    -o jsonpath='{range .items[*].endpoints[*]}{.targetRef.name}{"\t"}{.addresses[0]}{"\tready="}{.conditions.ready}{"\tserving="}{.conditions.serving}{"\tterminating="}{.conditions.terminating}{"\n"}{end}'
web-7d9c8b6f5d-4kq2x	10.244.1.12	ready=true	serving=true	terminating=false
web-7d9c8b6f5d-8vzlp	10.244.2.7	ready=true	serving=true	terminating=false
web-7d9c8b6f5d-r6ntm	10.244.1.13	ready=true	serving=true	terminating=false
```

### 4.3 Simulate a readiness failure (no restart)

```
$ kubectl -n ckne-avail exec web-7d9c8b6f5d-4kq2x -- rm /usr/share/nginx/html/ready

$ kubectl -n ckne-avail get pods
NAME                   READY   STATUS    RESTARTS   AGE
web-7d9c8b6f5d-4kq2x   0/1     Running   0          3m2s
web-7d9c8b6f5d-8vzlp   1/1     Running   0          3m2s
web-7d9c8b6f5d-r6ntm   1/1     Running   0          3m2s

$ kubectl -n ckne-avail get events --field-selector reason=Unhealthy
LAST SEEN   TYPE      REASON      OBJECT                     MESSAGE
4s          Warning   Unhealthy   pod/web-7d9c8b6f5d-4kq2x   Readiness probe failed: HTTP probe failed with statuscode: 404

$ kubectl -n ckne-avail get endpointslices -l kubernetes.io/service-name=web \
    -o jsonpath='{range .items[*].endpoints[*]}{.targetRef.name}{"\tready="}{.conditions.ready}{"\tserving="}{.conditions.serving}{"\n"}{end}'
web-7d9c8b6f5d-4kq2x	ready=false	serving=false
web-7d9c8b6f5d-8vzlp	ready=true	serving=true
web-7d9c8b6f5d-r6ntm	ready=true	serving=true
```

The Pod IP **stays in the slice** with `ready=false`, and kube-proxy removes it from its rules. Restore it:

```
$ kubectl -n ckne-avail exec web-7d9c8b6f5d-4kq2x -- sh -c 'echo ok > /usr/share/nginx/html/ready'
$ kubectl -n ckne-avail get pod web-7d9c8b6f5d-4kq2x
NAME                   READY   STATUS    RESTARTS   AGE
web-7d9c8b6f5d-4kq2x   1/1     Running   0          3m40s
```

Verify on the node dataplane (iptables mode):

```
$ sudo iptables -t nat -L KUBE-SVC-$(...) -n     # or simpler:
$ sudo iptables-save -t nat | grep 'ckne-avail/web:http' | grep -c KUBE-SEP
3
```

With nftables mode (`kube-proxy --proxy-mode=nftables`, GA v1.33):

```
$ sudo nft list chain ip kube-proxy service-XXXXXXXX-ckne-avail/web/tcp/http
```

With Cilium:

```
$ kubectl -n kube-system exec ds/cilium -- cilium-dbg service list | grep -A4 ':80/TCP'
```

---

## 5. Graceful termination and connection draining

### 5.1 The race

Deleting a Pod starts **two independent, concurrent** chains:

```
t=0  API server sets deletionTimestamp (grace = 45s)
      │
      ├──► EndpointSlice controller: ready=false, terminating=true   ──► kube-proxy on N nodes,
      │                                                                   Ingress, LB, mesh
      │                                                                   converge in 1–10+ s
      │
      └──► kubelet: run preStop (sleep 10) ──► send STOPSIGNAL ──► process drains
                                                                   ──► exits (or SIGKILL at t=45)
```

Nothing orders these two chains. Without a preStop delay the process can get SIGTERM, close its listener and return `connection refused`, while remote nodes are still sending new connections to it. The `preStop` sleep is not a hack. It is the documented way to let consumers converge before the app stops accepting connections.

### 5.2 Timeline with this lab's settings

| t (s) | Event |
|---|---|
| 0 | `deletionTimestamp` set; endpoint → `ready=false, serving=true, terminating=true` |
| 0 | kubelet starts `preStop` sleep 10 |
| 0–10 | Dataplanes remove the endpoint; existing connections keep being served |
| 10 | Runtime sends `SIGQUIT` (image STOPSIGNAL); nginx stops accepting and finishes in-flight requests |
| 10–45 | Drain window; readiness probes keep running, so `serving` tracks reality |
| 45 | `SIGKILL` if still running |

### 5.3 Choosing the numbers

| Parameter | Rule of thumb |
|---|---|
| `preStop` delay | ≥ worst-case dataplane convergence: kube-proxy sync + external LB deregistration. 5–15 s in-cluster; cloud LBs with instance/IP targets often need 15–30 s+ |
| `terminationGracePeriodSeconds` | `preStop` + longest legitimate request/stream + margin |
| Long-lived connections (WebSockets, gRPC streams) | App must actively close/`GOAWAY` on SIGTERM. kube-proxy does not cut established conntrack flows |
| App SIGTERM handling | Stop accepting, drain, exit 0. Readiness should start returning failure on SIGTERM so `serving=false` |

### 5.4 Observing termination conditions

```
$ kubectl -n ckne-avail delete pod web-7d9c8b6f5d-8vzlp --wait=false
pod "web-7d9c8b6f5d-8vzlp" deleted

$ kubectl -n ckne-avail get endpointslices -l kubernetes.io/service-name=web \
    -o jsonpath='{range .items[*].endpoints[*]}{.targetRef.name}{"\tready="}{.conditions.ready}{"\tserving="}{.conditions.serving}{"\tterminating="}{.conditions.terminating}{"\n"}{end}'
web-7d9c8b6f5d-4kq2x	ready=true	serving=true	terminating=false
web-7d9c8b6f5d-8vzlp	ready=false	serving=true	terminating=true
web-7d9c8b6f5d-r6ntm	ready=true	serving=true	terminating=false
web-7d9c8b6f5d-zq5dw	ready=false	serving=false	terminating=false
```

The last line is the replacement Pod created by the ReplicaSet, still in its startup/readiness phase.

### 5.5 Terminating-endpoint fallback and traffic policy

| Service setting | Endpoints considered | Fallback when none are ready |
|---|---|---|
| `internalTrafficPolicy: Cluster` (default) | All ready endpoints cluster-wide | `serving && terminating` endpoints |
| `internalTrafficPolicy: Local` | Ready endpoints on the same node only | Local `serving && terminating`; otherwise traffic is **dropped**, not rerouted |
| `externalTrafficPolicy: Local` | Ready endpoints on the receiving node; preserves client IP | Local `serving && terminating`. The `healthCheckNodePort` reports 503 when there are no local ready endpoints, so cloud LBs drain the node |

With `externalTrafficPolicy: Local`, add enough preStop delay for the **cloud LB health check** to fail on `healthCheckNodePort` (interval × unhealthy threshold). Otherwise the LB keeps sending to a node whose Pods are gone.

---

## 6. Rollout availability: Deployment and StatefulSet knobs

| Knob | Default | Effect | Trade-off |
|---|---|---|---|
| `maxUnavailable` | 25% | Pods allowed below `replicas` during rollout | 0 keeps capacity but needs `maxSurge ≥ 1` (extra quota/nodes) |
| `maxSurge` | 25% | Extra Pods above `replicas` | Faster rollouts; needs headroom |
| `minReadySeconds` | 0 | Ready time before a Pod counts as available | Catches crash-after-ready; slows rollout linearly |
| `progressDeadlineSeconds` | 600 | Marks `Progressing=False, reason=ProgressDeadlineExceeded` | Does **not** roll back automatically; your pipeline must react |
| StatefulSet `minReadySeconds` | 0 | Same semantics (GA v1.25) | |
| StatefulSet `rollingUpdate.maxUnavailable` | 1 | Parallel updates of StatefulSet Pods | Beta; check that the feature gate is enabled in your version |

Stalled rollout because new Pods never become ready:

```
$ kubectl -n ckne-avail set image deploy/web nginx=nginx:1.27-doesnotexist
deployment.apps/web image updated

$ kubectl -n ckne-avail rollout status deploy/web --timeout=60s
Waiting for deployment "web" rollout to finish: 1 out of 3 new replicas have been updated...
error: timed out waiting for the condition

$ kubectl -n ckne-avail get pods
NAME                   READY   STATUS             RESTARTS   AGE
web-5b8f6c7d9-t2wqn    0/1     ImagePullBackOff   0          62s
web-7d9c8b6f5d-4kq2x   1/1     Running            0          12m
web-7d9c8b6f5d-r6ntm   1/1     Running            0          12m
web-7d9c8b6f5d-zq5dw   1/1     Running            0          6m

$ kubectl -n ckne-avail rollout undo deploy/web
deployment.apps/web rolled back
```

Because `maxUnavailable: 0`, all three old Pods kept serving throughout.

---

## 7. Readiness gates: readiness that depends on external systems

Some consumers are **outside** the kubelet's view: a cloud load balancer target group, a mesh or proxy config push, an external DNS registration. `spec.readinessGates` adds custom Pod conditions that must be `True` before the Pod is `Ready`, and therefore before its endpoint is `ready`. A controller (for example the AWS Load Balancer Controller with `elbv2.k8s.aws/pod-readiness-gate-inject: enabled` on the namespace) patches those conditions.

Why it matters: with `maxUnavailable: 0`, the Deployment controller waits for new Pods to be **Ready** before killing old ones. Without a gate, a Pod can be Ready in Kubernetes while the cloud LB has not registered it yet. The rollout then deletes old targets before new ones take traffic, and capacity at the LB drops to zero.

### 7.1 Manifest

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: gated-web
  namespace: ckne-avail
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: gated-web
  template:
    metadata:
      labels:
        app.kubernetes.io/name: gated-web
    spec:
      readinessGates:
        - conditionType: "example.com/lb-registered"
      containers:
        - name: nginx
          image: nginx:1.27
          ports:
            - name: http
              containerPort: 80
          readinessProbe:
            httpGet:
              path: /
              port: http
            periodSeconds: 2
---
apiVersion: v1
kind: Service
metadata:
  name: gated-web
  namespace: ckne-avail
spec:
  selector:
    app.kubernetes.io/name: gated-web
  ports:
    - name: http
      port: 80
      targetPort: http
```

### 7.2 Drive the gate manually (acting as the controller)

```
$ kubectl -n ckne-avail get pods -l app.kubernetes.io/name=gated-web -o wide
NAME                         READY   STATUS    RESTARTS   AGE   IP            NODE       NOMINATED NODE   READINESS GATES
gated-web-6c5f7d8b9c-p4m2h   1/1     Running   0          20s   10.244.2.9    worker-2   <none>           0/1

$ kubectl -n ckne-avail get pod gated-web-6c5f7d8b9c-p4m2h \
    -o jsonpath='{range .status.conditions[*]}{.type}={.status}{"\n"}{end}'
PodReadyToStartContainers=True
Initialized=True
Ready=False
ContainersReady=True
PodScheduled=True
```

`READY 1/1` counts containers. The **Pod** is still `Ready=False` because the gate condition is missing, and a missing condition counts as `False`. Set it through the status subresource. The default strategic-merge patch merges conditions by `type`:

```
$ kubectl -n ckne-avail patch pod gated-web-6c5f7d8b9c-p4m2h --subresource=status \
    -p '{"status":{"conditions":[{"type":"example.com/lb-registered","status":"True"}]}}'
pod/gated-web-6c5f7d8b9c-p4m2h patched

$ kubectl -n ckne-avail get pods -l app.kubernetes.io/name=gated-web -o wide
NAME                         READY   STATUS    RESTARTS   AGE   IP            NODE       NOMINATED NODE   READINESS GATES
gated-web-6c5f7d8b9c-p4m2h   1/1     Running   0          95s   10.244.2.9    worker-2   <none>           1/1

$ kubectl -n ckne-avail get endpointslices -l kubernetes.io/service-name=gated-web \
    -o jsonpath='{.items[0].endpoints[0].conditions}{"\n"}'
{"ready":true,"serving":true,"terminating":false}
```

Do **not** use `--type=merge` for this: a JSON merge patch replaces the entire `conditions` list.

---

## 8. `publishNotReadyAddresses`: discovery before readiness

StatefulSets for clustered systems (etcd, ZooKeeper, Cassandra, Kafka KRaft) need **peer DNS records before they are ready**, because readiness often *requires* quorum. `spec.publishNotReadyAddresses: true` makes the EndpointSlice controller set `ready=true` for every endpoint regardless of Pod readiness. CoreDNS then publishes A/AAAA and SRV records immediately.

Use it on a **separate** headless "peer" Service. Keep a normal client Service that respects readiness.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: kv-peers
  namespace: ckne-avail
spec:
  clusterIP: None
  publishNotReadyAddresses: true
  selector:
    app.kubernetes.io/name: kv
  ports:
    - name: peer
      port: 2380
      targetPort: 2380
---
apiVersion: v1
kind: Service
metadata:
  name: kv-client
  namespace: ckne-avail
spec:
  selector:
    app.kubernetes.io/name: kv
  ports:
    - name: client
      port: 2379
      targetPort: 2379
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: kv
  namespace: ckne-avail
spec:
  serviceName: kv-peers
  replicas: 3
  podManagementPolicy: Parallel
  minReadySeconds: 5
  selector:
    matchLabels:
      app.kubernetes.io/name: kv
  template:
    metadata:
      labels:
        app.kubernetes.io/name: kv
    spec:
      terminationGracePeriodSeconds: 30
      containers:
        - name: kv
          image: busybox:1.36
          command:
            - sh
            - -c
            - |
              mkdir -p /www
              echo peer > /www/index.html
              httpd -f -p 2380 -h /www &
              httpd -f -p 2379 -h /www
          ports:
            - name: peer
              containerPort: 2380
            - name: client
              containerPort: 2379
          readinessProbe:
            exec:
              command:
                - sh
                - -c
                - test -f /tmp/quorum
            periodSeconds: 3
```

The readiness probe is deliberately unsatisfied (no `/tmp/quorum`), which stands in for "waiting for quorum":

```
$ kubectl -n ckne-avail get pods -l app.kubernetes.io/name=kv
NAME   READY   STATUS    RESTARTS   AGE
kv-0   0/1     Running   0          30s
kv-1   0/1     Running   0          30s
kv-2   0/1     Running   0          30s

$ kubectl -n ckne-avail run dns --rm -it --restart=Never --image=busybox:1.36 -- \
    nslookup kv-peers.ckne-avail.svc.cluster.local
Name:   kv-peers.ckne-avail.svc.cluster.local
Address: 10.244.1.21
Name:   kv-peers.ckne-avail.svc.cluster.local
Address: 10.244.2.14
Name:   kv-peers.ckne-avail.svc.cluster.local
Address: 10.244.1.22
pod "dns" deleted

$ kubectl -n ckne-avail get endpointslices -l kubernetes.io/service-name=kv-client \
    -o jsonpath='{range .items[*].endpoints[*]}{.targetRef.name}{"\tready="}{.conditions.ready}{"\n"}{end}'
kv-0	ready=false
kv-1	ready=false
kv-2	ready=false
```

The peer Service publishes every Pod. The client Service correctly publishes none.

| Approach | Pros | Cons |
|---|---|---|
| `publishNotReadyAddresses: true` on a peer Service | Declarative; standard for StatefulSets | Clients of *that* Service can reach unready Pods, so never point application traffic at it |
| Legacy annotation `service.alpha.kubernetes.io/tolerate-unready-endpoints` | Nothing | Deprecated; do not use |
| Readiness that ignores quorum | Simple | Clients reach members that cannot serve consistent reads |

---

## 9. PodDisruptionBudgets: bounding voluntary disruption

A PDB limits **voluntary** disruptions that go through the **Eviction API**: `kubectl drain`, cluster-autoscaler scale-down, node upgrades, Karpenter consolidation. It does **not** protect against node failure, OOM kills, `kubectl delete pod`, or Deployment rollouts. Rollouts are governed by `maxUnavailable`.

| Field | Semantics | Notes |
|---|---|---|
| `minAvailable` | Healthy Pods that must remain | Integer or %. `100%` or `= replicas` blocks every drain |
| `maxUnavailable` | Pods that may be unavailable | Tracks scaling better; preferred for Deployments |
| `unhealthyPodEvictionPolicy` | `IfHealthyBudget` (default) or `AlwaysAllow` | `AlwaysAllow` lets drains evict Pods that are already unready (e.g., CrashLoopBackOff) instead of deadlocking; GA v1.31 |

"Healthy" for a PDB means the Pod's `Ready` condition is `True`. Readiness gates and probes therefore feed directly into disruption math.

```
$ kubectl -n ckne-avail get pdb web
NAME   MIN AVAILABLE   MAX UNAVAILABLE   ALLOWED DISRUPTIONS   AGE
web    2               N/A               1                     14m

$ kubectl drain worker-1 --ignore-daemonsets --delete-emptydir-data
node/worker-1 cordoned
evicting pod ckne-avail/web-7d9c8b6f5d-4kq2x
evicting pod ckne-avail/web-7d9c8b6f5d-r6ntm
error when evicting pods/"web-7d9c8b6f5d-r6ntm" -n "ckne-avail" (will retry after 5s): Cannot evict pod as it would violate the pod's disruption budget.
pod/web-7d9c8b6f5d-4kq2x evicted
evicting pod ckne-avail/web-7d9c8b6f5d-r6ntm
pod/web-7d9c8b6f5d-r6ntm evicted
node/worker-1 drained

$ kubectl uncordon worker-1
node/worker-1 uncordoned
```

The drain succeeded once the evicted Pod's replacement became Ready on another node and `ALLOWED DISRUPTIONS` returned to 1. Note that `emptyDir` data is lost, hence `--delete-emptydir-data`.

PDB pitfalls:

| Pitfall | Result |
|---|---|
| `minAvailable: 1` with `replicas: 1` | `ALLOWED DISRUPTIONS 0`; node drains hang forever |
| Selector matches Pods of two workloads | Budget math is wrong; one workload can be fully evicted |
| Multiple PDBs select the same Pod | Eviction API returns 500 for that Pod |
| No anti-affinity/topology spread | PDB permits the eviction, but all replicas were on the same node anyway |

Pair a PDB with spread constraints:

```yaml
topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: kubernetes.io/hostname
    whenUnsatisfiable: DoNotSchedule
    labelSelector:
      matchLabels:
        app.kubernetes.io/name: web
```

---

## 10. Selectorless Services and hand-managed EndpointSlices

For backends outside the cluster (a VM database, a legacy service), create a Service **without a selector** and manage EndpointSlices yourself. You then own the conditions: dataplanes honor `ready: false` just as they do for controller-managed slices.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: legacy-db
  namespace: ckne-avail
spec:
  ports:
    - name: pg
      port: 5432
      targetPort: 5432
      protocol: TCP
---
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
metadata:
  name: legacy-db-1
  namespace: ckne-avail
  labels:
    kubernetes.io/service-name: legacy-db
    endpointslice.kubernetes.io/managed-by: ops-team.example.com
addressType: IPv4
ports:
  - name: pg
    port: 5432
    protocol: TCP
endpoints:
  - addresses:
      - "192.168.50.10"
    conditions:
      ready: true
    zone: zone-a
  - addresses:
      - "192.168.50.11"
    conditions:
      ready: false
    zone: zone-b
```

Rules:

- `kubernetes.io/service-name` links the slice to the Service.
- `endpointslice.kubernetes.io/managed-by` must **not** be `endpointslice-controller.k8s.io`, or the controller will delete your slice.
- The port **`name`** in the slice must match the Service port name (`""` when unnamed).
- Endpoints must not be loopback, link-local, or ClusterIPs of other Services.
- For availability you need an external health checker or operator that flips `ready`. Kubernetes will not probe these addresses.

```
$ kubectl -n ckne-avail get endpointslice legacy-db-1
NAME          ADDRESSTYPE   PORTS   ENDPOINTS                     AGE
legacy-db-1   IPv4          5432    192.168.50.10,192.168.50.11   8s
```

Only `192.168.50.10` is programmed by kube-proxy.

---

## 11. Diagnosis guide

### 11.1 Decision flow

```
Service returns errors / times out
│
├─ kubectl get endpointslices -l kubernetes.io/service-name=<svc>
│   ├─ No slices at all ──────────────► selector doesn't match Pod labels, or selectorless Service
│   │                                   without a slice / wrong service-name label
│   ├─ Slice exists, no endpoints ─────► no Pods match; check labels and namespace
│   └─ Endpoints present
│       ├─ all ready=false ────────────► readiness probe / readiness gate failing (describe pod)
│       ├─ ready=true but conn refused ► targetPort mismatch (named port missing in container?)
│       │                                or app listening on 127.0.0.1
│       └─ ready=true, intermittent ───► dataplane lag, termination race (no preStop),
│                                        externalTrafficPolicy/internalTrafficPolicy Local
└─ Errors only during deploys/drains ──► maxUnavailable, minReadySeconds, preStop, grace period, PDB
```

### 11.2 Command toolbox

```
# Pod-level truth
$ kubectl -n ckne-avail describe pod <pod> | sed -n '/Conditions:/,/Volumes:/p'
$ kubectl -n ckne-avail get pod <pod> -o jsonpath='{.spec.readinessGates}{"\n"}{.status.conditions}{"\n"}'
$ kubectl -n ckne-avail get events --field-selector involvedObject.name=<pod>,reason=Unhealthy

# Probe the same URL the kubelet uses, from the node or a debug pod
$ kubectl -n ckne-avail debug -it <pod> --image=busybox:1.36 --target=nginx -- wget -qO- -S http://127.0.0.1:80/ready

# Selector vs labels
$ kubectl -n ckne-avail get svc web -o jsonpath='{.spec.selector}{"\n"}'
$ kubectl -n ckne-avail get pods -l app.kubernetes.io/name=web --show-labels

# Named targetPort must exist on the container
$ kubectl -n ckne-avail get pod <pod> -o jsonpath='{.spec.containers[*].ports}{"\n"}'

# Endpoint conditions, full detail
$ kubectl -n ckne-avail describe endpointslice <slice>

# Watch endpoints flip in real time during a rollout
$ kubectl -n ckne-avail get endpointslices -l kubernetes.io/service-name=web -w -o wide

# Disruption budget state
$ kubectl -n ckne-avail get pdb -o wide
$ kubectl -n ckne-avail describe pdb web

# Controller side
$ kubectl -n kube-system logs -l component=kube-controller-manager | grep -i endpointslice
$ kubectl -n kube-system logs ds/kube-proxy | grep -iE 'sync|error'
```

Sample `describe endpointslice`:

```
Name:         web-x8f2k
Namespace:    ckne-avail
Labels:       endpointslice.kubernetes.io/managed-by=endpointslice-controller.k8s.io
              kubernetes.io/service-name=web
Annotations:  endpoints.kubernetes.io/last-change-trigger-time: 2026-09-30T10:14:03Z
AddressType:  IPv4
Ports:
  Name  Port  Protocol
  ----  ----  --------
  http  80    TCP
Endpoints:
  - Addresses:  10.244.1.12
    Conditions:
      Ready:    true
    Hostname:   <unset>
    TargetRef:  Pod/web-7d9c8b6f5d-4kq2x
    NodeName:   worker-1
    Zone:       <unset>
  - Addresses:  10.244.2.7
    Conditions:
      Ready:    false
    Hostname:   <unset>
    TargetRef:  Pod/web-7d9c8b6f5d-8vzlp
    NodeName:   worker-2
    Zone:       <unset>
Events:         <none>
```

### 11.3 Failure matrix

| Observation | Likely cause | Fix |
|---|---|---|
| `Readiness probe failed: ... connect: connection refused` | App not listening yet, wrong port, or bound to `127.0.0.1` | Bind `0.0.0.0`; add `startupProbe`; check the named port |
| `Readiness probe failed: context deadline exceeded` | `timeoutSeconds` too low, CPU throttling | Raise the timeout; review CPU limits |
| `Liveness probe failed` + rising `RESTARTS` right after start | No startup probe | Add `startupProbe` |
| All endpoints `ready=false` simultaneously | Readiness checks a shared dependency | Make readiness local |
| `READY 1/1` but Pod not in Service | Readiness gate unsatisfied (`READINESS GATES 0/1`) | Check the gate's controller; inspect `.status.conditions` |
| 502s for ~1–5 s on each Pod deletion | No `preStop` delay; app exits immediately on SIGTERM | `preStop` sleep ≥ convergence time; graceful shutdown in the app |
| Pod killed mid-request at the same second every time | `terminationGracePeriodSeconds` exhausted by preStop plus drain | Raise the grace period; it includes the preStop time |
| `kubectl drain` hangs with "violate the pod's disruption budget" | `ALLOWED DISRUPTIONS 0`: too few replicas, replacements unready, or unhealthy Pods with `IfHealthyBudget` | Scale up, fix readiness, or use `unhealthyPodEvictionPolicy: AlwaysAllow` |
| StatefulSet never forms a cluster | Peer DNS depends on readiness | Headless peer Service with `publishNotReadyAddresses: true` |
| Traffic dropped on some nodes only | `internalTrafficPolicy: Local` / `externalTrafficPolicy: Local` with no local ready endpoint | Spread Pods, run a DaemonSet, or use `Cluster` |
| Rollout stuck, `ProgressDeadlineExceeded` | New Pods never Ready | `kubectl rollout undo`; fix image, probes or config |

---

## 12. Exam-oriented checklist

- Remember what each probe does on failure: readiness **removes from endpoints**, liveness **restarts**, startup **gates the other two**.
- `kubectl get endpointslices -l kubernetes.io/service-name=<svc>` is the first command; read `conditions`, not just the address list.
- `ready = serving && !terminating`; `publishNotReadyAddresses` forces `ready=true`.
- A Pod is `Ready` only when containers are ready **and** all `readinessGates` conditions are `True`. Patch gates through `--subresource=status`.
- Zero-downtime Deployment: readiness probe + `maxUnavailable: 0` + `maxSurge ≥ 1` + `minReadySeconds` + `preStop` delay + a grace period larger than the preStop time plus drain.
- A PDB protects only against Eviction-API disruptions; `ALLOWED DISRUPTIONS` must be ≥ 1 for drains to progress.
- Selectorless Service: the slice needs the `kubernetes.io/service-name` label, a custom `managed-by` label, and port names that match the Service.

---

## Referencias

- CKNE certification page — https://training.linuxfoundation.org/certification/certified-kubernetes-network-engineer-ckne/
- Liveness, Readiness and Startup Probes (concepts) — https://kubernetes.io/docs/concepts/configuration/liveness-readiness-startup-probes/
- Configure Liveness, Readiness and Startup Probes — https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/
- Pod Lifecycle (conditions, readiness gates, termination) — https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/
- Container Lifecycle Hooks — https://kubernetes.io/docs/concepts/containers/container-lifecycle-hooks/
- EndpointSlices — https://kubernetes.io/docs/concepts/services-networking/endpoint-slices/
- Service (selectorless Services, `publishNotReadyAddresses`, traffic policies) — https://kubernetes.io/docs/concepts/services-networking/service/
- Service Internal Traffic Policy — https://kubernetes.io/docs/concepts/services-networking/service-traffic-policy/
- Virtual IPs and Service Proxies (kube-proxy, terminating endpoints) — https://kubernetes.io/docs/reference/networking/virtual-ips/
- Deployments (rolling update strategy, `minReadySeconds`, progress deadline) — https://kubernetes.io/docs/concepts/workloads/controllers/deployment/
- StatefulSets — https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/
- Disruptions — https://kubernetes.io/docs/concepts/workloads/pods/disruptions/
- Specifying a Disruption Budget for your Application — https://kubernetes.io/docs/tasks/run-application/configure-pdb/
- Safely Drain a Node — https://kubernetes.io/docs/tasks/administer-cluster/safely-drain-node/
- Pod Topology Spread Constraints — https://kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints/
- EndpointSlice API reference (discovery.k8s.io/v1) — https://kubernetes.io/docs/reference/kubernetes-api/service-resources/endpoint-slice-v1/
- KEP-1672: Tracking Terminating Endpoints — https://github.com/kubernetes/enhancements/tree/master/keps/sig-network/1672-tracking-terminating-endpoints
- KEP-1669: Proxy Terminating Endpoints — https://github.com/kubernetes/enhancements/tree/master/keps/sig-network/1669-proxy-terminating-endpoints
- AWS Load Balancer Controller: Pod readiness gate — https://kubernetes-sigs.github.io/aws-load-balancer-controller/latest/deploy/pod_readiness_gate/