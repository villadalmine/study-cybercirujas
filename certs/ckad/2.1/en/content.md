# 2.1 Use Kubernetes primitives to implement common deployment strategies (blue/green, canary)

## Why this matters

Kubernetes ships with exactly one native rollout mechanism on the `Deployment` object: `RollingUpdate` (and its blunt cousin, `Recreate`). There is no `strategy.type: BlueGreen` or `strategy.type: Canary` field anywhere in the API. Blue/green and canary releases are **patterns you build** by combining ordinary primitives — `Deployment`, `Service`, `ReplicaSet`, labels/selectors, and `kubectl` traffic-shifting commands — not distinct API objects. The exam expects you to assemble these patterns quickly under time pressure, so the priority is muscle memory for the manifests and the exact commands that flip traffic, not theory.

The core mechanism behind every strategy below is the same: **a `Service` routes traffic to whatever `Pods` match its `spec.selector`, regardless of which `Deployment` or `ReplicaSet` created them.** Everything else is a variation on how you manipulate that selector or the Pods behind it.

---

## 1. Recap: rolling update (the built-in baseline)

Before building custom strategies, know the default well enough to contrast against it.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
spec:
  replicas: 4
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 1   # how many pods can be down during the update
      maxSurge: 1         # how many extra pods can be created above `replicas`
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
        image: web:1.0
```

```console
$ kubectl set image deployment/web web=web:2.0
deployment.apps/web image updated

$ kubectl rollout status deployment/web
Waiting for deployment "web" rollout to finish: 2 out of 4 new replicas have been updated...
deployment "web" successfully rolled out

$ kubectl rollout undo deployment/web
deployment.apps/web rolled back
```

A rolling update mixes old and new Pods **under the same Deployment and the same Service selector** the whole time — both versions receive live traffic simultaneously, and there is no clean point to test v2 in isolation before it's fully live. That gap is exactly what blue/green and canary solve.

`Recreate` is the other native strategy: it kills all old Pods before creating new ones (`spec.strategy.type: Recreate`), causing downtime — useful only when old and new versions cannot coexist (e.g. a schema-incompatible singleton).

---

## 2. Blue/Green deployment

### Concept

Run **two complete, independent Deployments** at once — "blue" (current/live) and "green" (new candidate) — each fully scaled and each with its own label (e.g. `version: blue` / `version: green`). Only one `Service` exists, and its `selector` targets the labels of whichever Deployment is currently live. You validate "green" internally (port-forward, a second internal Service, or a smoke-test Job) with zero production traffic, then cut over **instantly** by patching the one Service's selector to point at `version: green`. Rollback is just patching the selector back.

Trade-off: you need double the compute capacity while both versions are running, and the cutover is all-or-nothing (no gradual traffic ramp) — unlike canary.

### Implementation

Two Deployments, same `app` label but different `version` label:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web-blue
spec:
  replicas: 3
  selector:
    matchLabels:
      app: web
      version: blue
  template:
    metadata:
      labels:
        app: web
        version: blue
    spec:
      containers:
      - name: web
        image: web:1.0
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web-green
spec:
  replicas: 3
  selector:
    matchLabels:
      app: web
      version: green
  template:
    metadata:
      labels:
        app: web
        version: green
    spec:
      containers:
      - name: web
        image: web:2.0
```

The production Service, initially pointed at blue:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: web
spec:
  selector:
    app: web
    version: blue   # <-- this is the switch
  ports:
  - port: 80
    targetPort: 8080
```

### Validating green before the switch

Give green its own internal Service (no external traffic) so you can test it directly:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: web-green-preview
spec:
  selector:
    app: web
    version: green
  ports:
  - port: 80
    targetPort: 8080
```

```console
$ kubectl run tester --rm -it --image=busybox --restart=Never -- \
    wget -qO- http://web-green-preview
<response confirms green is healthy>
```

### Cutover

```console
$ kubectl get endpoints web
NAME   ENDPOINTS                                   AGE
web    10.244.1.5:8080,10.244.1.6:8080,+1 more...   4h   # blue pod IPs

$ kubectl patch service web -p '{"spec":{"selector":{"app":"web","version":"green"}}}'
service/web patched

$ kubectl get endpoints web
NAME   ENDPOINTS                                    AGE
web    10.244.2.9:8080,10.244.2.10:8080,+1 more...   4h   # now green pod IPs
```

All traffic moves in one atomic step — kube-proxy reprograms iptables/IPVS rules as soon as the Endpoints object updates, so the cutover is effectively instant, with no window where both versions receive live traffic.

### Rollback

```console
$ kubectl patch service web -p '{"spec":{"selector":{"app":"web","version":"blue"}}}'
service/web patched
```

Because `web-blue` was never scaled down, rollback is just as instant as the original cutover. Once green is confirmed stable, delete blue: `kubectl delete deployment web-blue`.

---

## 3. Canary deployment

### Concept

Release the new version to a **small subset of live traffic** first, observe it, then progressively increase its share until it fully replaces the old version. Unlike blue/green, both versions receive real production traffic simultaneously during the rollout — the risk of a bad release is limited to the canary's slice of traffic instead of an all-or-nothing switch.

### Implementation with plain Kubernetes primitives

Kubernetes has no percentage-based traffic split without a service mesh or ingress controller that supports weighted routing (e.g. Istio `VirtualService`, NGINX Ingress `canary-weight` annotation, Gateway API `HTTPRoute` weights). Using **only** core primitives — which is what's testable on the CKAD exam — you approximate a traffic percentage through the **ratio of Pod replicas** matched by one shared Service, since a Service load-balances round-robin (roughly evenly) across every Pod that matches its selector, regardless of which Deployment owns them.

One Service, selecting on the common label only (no `version`):

```yaml
apiVersion: v1
kind: Service
metadata:
  name: web
spec:
  selector:
    app: web          # matches both stable and canary pods
  ports:
  - port: 80
    targetPort: 8080
```

Stable Deployment carrying most of the load:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web-stable
spec:
  replicas: 9
  selector:
    matchLabels:
      app: web
      track: stable
  template:
    metadata:
      labels:
        app: web
        track: stable
    spec:
      containers:
      - name: web
        image: web:1.0
```

Canary Deployment carrying a small slice:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web-canary
spec:
  replicas: 1
  selector:
    matchLabels:
      app: web
      track: canary
  template:
    metadata:
      labels:
        app: web
        track: canary
    spec:
      containers:
      - name: web
        image: web:2.0
```

With 9 stable + 1 canary Pod, roughly **10% of requests** hit `web:2.0`. This ratio is coarse and quantized by whole Pods — good enough for the exam and for many real deployments, but note in your own understanding that this is *not* precise traffic-percentage control; that requires an ingress/mesh weighted split.

### Progressing the rollout

```console
$ kubectl get pods -l app=web -L track
NAME                          READY   STATUS    RESTARTS   AGE   TRACK
web-stable-6d9c5f7b4f-2xk9p   1/1     Running   0          10m   stable
web-stable-6d9c5f7b4f-4mjqz   1/1     Running   0          10m   stable
...                                                              (9 total)
web-canary-7f8b6c9d5-p2rtn    1/1     Running   0          2m    canary

# canary looks healthy -> increase its share
$ kubectl scale deployment web-canary --replicas=3
deployment.apps/web-canary scaled

$ kubectl scale deployment web-stable --replicas=7
deployment.apps/web-stable scaled

# fully confident -> promote canary to 100%
$ kubectl scale deployment web-canary --replicas=10
$ kubectl scale deployment web-stable --replicas=0
```

### Aborting a canary

If the canary shows errors, scale it back to zero — stable keeps serving 100% of traffic the whole time, so this is a safe, low-risk rollback:

```console
$ kubectl scale deployment web-canary --replicas=0
deployment.apps/web-canary scaled
```

---

## 4. Comparison

| Strategy | Native to Deployment? | Traffic exposure during rollout | Rollback speed | Extra capacity needed |
|---|---|---|---|---|
| **Recreate** | Yes (`strategy.type`) | 0% old / 0% new (downtime gap) | Redeploy old image | None |
| **RollingUpdate** | Yes (`strategy.type`, default) | Mixed old+new the whole time | `kubectl rollout undo` | `maxSurge` only |
| **Blue/Green** | No — built from 2 Deployments + 1 Service | 100% old, then instant 100% new | Instant (repatch selector) | 2x (both fully scaled) |
| **Canary** | No — built from 2 Deployments + 1 Service | Old + a controlled small % of new | Scale canary to 0 | Small (canary replica count) |

---

## 5. Exam tips

- Know that `kubectl patch service <name> -p '{"spec":{"selector":{...}}}'` (or `kubectl edit service`) is the operation that performs a blue/green cutover — it's fast to type and easy to verify with `kubectl get endpoints`.
- `kubectl get endpoints <service>` (or `kubectl get endpointslice`) is the quickest way to prove which Pods a Service is actually routing to at any point — use it to confirm both blue/green cutovers and canary pod membership.
- For canary, remember the Service selector must be **broad enough** to match both the stable and canary Pod labels (a shared label like `app: web`), while each Deployment's own `spec.selector.matchLabels` must be **narrow enough** (including the distinguishing label like `track`) to avoid one Deployment's selector accidentally matching the other's Pods.
- `kubectl scale deployment <name> --replicas=N` is the primitive used to shift canary weight; there's no dedicated "traffic percentage" object in vanilla Kubernetes.
- If a question mentions Ingress annotations for canary weighting, that's controller-specific (e.g. `nginx.ingress.kubernetes.io/canary-weight`) and outside core Kubernetes objects — CKAD focuses on the Deployment/Service/label approach shown above.

---

## Referencias

- Kubernetes Deployments (rolling update, recreate, rollback): https://kubernetes.io/docs/concepts/workloads/controllers/deployment/
- Kubernetes Services (selectors, endpoints, load balancing): https://kubernetes.io/docs/concepts/services-networking/service/
- Labels and Selectors: https://kubernetes.io/docs/concepts/overview/working-with-objects/labels/
- `kubectl patch` reference: https://kubernetes.io/docs/reference/generated/kubectl/kubectl-commands#patch
- `kubectl rollout` reference: https://kubernetes.io/docs/reference/generated/kubectl/kubectl-commands#rollout
- `kubectl scale` reference: https://kubernetes.io/docs/reference/generated/kubectl/kubectl-commands#scale
- CKAD Curriculum v1.35 (source topic list): https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf