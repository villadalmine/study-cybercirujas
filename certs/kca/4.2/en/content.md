# 4.2 Resource Selection

> **Domain 4 · Exam weight: 3.33** · Advanced SRE / Platform Architect profile
>
> *Selection* is the load-bearing abstraction of the Kubernetes control plane. Almost nothing in Kubernetes references another object by name or IP — controllers, Services, policies and schedulers all discover the resources they act on by *matching* declarative criteria. This topic covers the three distinct selection subsystems and the failure modes each one produces in production: **label selectors** (selecting objects by identity), **field selectors** (selecting objects by live state), and **node/topology selection** (selecting *where* a workload's resources land).

---

## 1. Motivation: the architectural problem selection solves

### 1.1 Why nothing references anything by name

A naïve orchestrator would let a load balancer point at a fixed list of backend IPs. In a cluster where Pods are cattle — created, killed, rescheduled onto new nodes with new IPs dozens of times an hour by the Deployment and node-autoscaler control loops — that fixed list is stale within seconds. Every controller would need to be notified on every Pod lifecycle event, and the coupling between a Service and its backends would be a hard, brittle dependency.

Kubernetes inverts this with **loose coupling through selection**. A Service does not know which Pods serve it; it declares a *predicate* (`selector: app=web`) and a controller continuously reconciles reality against that predicate. Add a Pod that matches → it joins the backend set. Delete one → it leaves. No Service edit, no restart, no notification wiring. The same pattern drives:

| Consumer | What it selects | Selection mechanism |
|---|---|---|
| `Service` | Ready Pods to load-balance across | `.spec.selector` (equality map) → EndpointSlices |
| `Deployment` / `ReplicaSet` / `DaemonSet` / `StatefulSet` | Pods it owns and counts | `.spec.selector.matchLabels` / `matchExpressions` |
| `NetworkPolicy` | Pods the policy applies to; allowed peers | `podSelector`, `namespaceSelector` |
| `PodDisruptionBudget` | Pods whose voluntary evictions it gates | `.spec.selector` |
| Pod (anti-)affinity | Peer Pods to co-locate with / avoid | `labelSelector` + `topologyKey` |
| `topologySpreadConstraints` | Pods to spread evenly | `labelSelector` + `topologyKey` |
| Scheduler node fit | Nodes a Pod may bind to | `nodeSelector`, `nodeAffinity` |
| `kubectl` / operators | Any set of objects to operate on | `-l` / `--field-selector` |

The recurring production incident this design *prevents* is "the load balancer is pointing at dead backends." The recurring incident it *introduces* is **selector drift**: a one-character mismatch between a selector and the labels it was meant to match silently produces an empty set. A Service with a mismatched selector does not error — it returns zero endpoints and every client gets connection-refused. Learning to diagnose that (§5) is the practical core of this topic.

### 1.2 The three axes of "resource selection"

The term is overloaded. Keep these separate — they use different syntax, different operators, and fail differently:

| Axis | Question it answers | Primary API surface | Backend |
|---|---|---|---|
| **Object selection** | *Which objects does this controller/policy act on?* | Label selectors | Watch cache, indexed by labels |
| **State selection** | *Which objects are currently in state X?* | Field selectors | apiserver field indices |
| **Placement selection** | *Which node / topology should this Pod's resources land on?* | `nodeSelector`, node affinity, topology spread | kube-scheduler filter+score |

---

## 2. Label selectors — selecting objects by identity

Labels are key/value metadata (`app=web`, `tier=frontend`); a **label selector** is a query over them. There are two grammars.

### 2.1 Equality-based vs set-based

```
# Equality-based (operators: = , == , != ; comma = logical AND)
environment = production
tier != frontend
environment=production,tier=frontend            # AND of both

# Set-based (operators: in , notin , exists / !exists)
environment in (production, qa)
tier notin (frontend, backend)
partition                                         # key exists (any value)
!partition                                        # key does NOT exist
environment in (production),!canary               # AND: in-set AND key absent
```

Both grammars can be mixed in a single `kubectl -l` string. `=` and `==` are synonyms.

| | Equality-based | Set-based |
|---|---|---|
| Operators | `=`, `==`, `!=` | `In`, `NotIn`, `Exists`, `DoesNotExist` |
| Multi-value match | ✗ (one value per key) | ✓ (`In (a, b, c)`) |
| Existence test | ✗ | ✓ (`Exists` / `DoesNotExist`) |
| Supported by legacy `Service`, `ReplicationController` | ✓ (only this) | ✗ |
| Supported by `Deployment`, `ReplicaSet`, `DaemonSet`, `Job`, `NetworkPolicy`, PDB, affinity | ✓ | ✓ |
| Empty-value semantics | `key=` matches empty string | `In ("")` matches empty string |

**Rule of thumb:** a `Service.spec.selector` is a *map*, so it is equality-only and every entry is ANDed. Everything modern (`.spec.selector` on workload controllers) uses the structured `LabelSelector` object that supports both.

### 2.2 The structured `LabelSelector` object

Modern controllers do not use the flat string. They use `matchLabels` (map, equality, ANDed) plus `matchExpressions` (list, set-based, ANDed), and the two blocks are themselves ANDed:

```yaml
selector:
  matchLabels:
    app: web              # app == web  AND
  matchExpressions:
    - key: tier           # tier ∈ {frontend, edge}  AND
      operator: In
      values: [frontend, edge]
    - key: track          # track ∉ {canary}  AND
      operator: NotIn
      values: [canary]
    - key: temporary      # label "temporary" must NOT exist
      operator: DoesNotExist
```

Semantics that bite people:

- `operator: Exists` / `DoesNotExist` **require `values` to be empty or omitted**. Supplying values → API validation error.
- `operator: In` / `NotIn` **require a non-empty `values` list**.
- `matchLabels: {app: web}` is exactly equivalent to a `matchExpressions` entry `{key: app, operator: In, values: [web]}`.
- An **empty selector** behaves differently by context and is the single most common source of surprise:

| Empty selector value | Meaning |
|---|---|
| `selector: {}` on a Deployment/ReplicaSet | Selects **all** Pods in the namespace — dangerous, usually rejected because it can't match the template uniquely |
| `podSelector: {}` in a NetworkPolicy `spec` | Selects **all** Pods in the policy's namespace (intentional idiom for "default deny/allow all") |
| `spec.selector` absent on a Service | Service is **headless/manual** — no EndpointSlices auto-populated; you manage Endpoints yourself or it's `ExternalName` |
| `namespaceSelector: {}` in NetworkPolicy | Selects **all namespaces** |

### 2.3 Two invariants the apiserver enforces on workload controllers

1. **`.spec.selector` must match `.spec.template.metadata.labels`.** The controller must be able to select the Pods it stamps out. If the template labels don't satisfy the selector, create/update is rejected.
2. **`.spec.selector` is immutable** on `Deployment`, `ReplicaSet`, `StatefulSet`, and `DaemonSet` (`apps/v1`). You cannot re-target an existing controller at a different Pod set — you must delete and recreate. This exists precisely to prevent a controller from silently orphaning its running Pods and adopting an unrelated set.

Both are demonstrated as failures in §5.

---

## 3. Complete, production-grade manifests

### 3.1 Deployment with a precise set-based selector

A canary-aware Deployment that owns only stable-track `web` Pods and refuses to adopt canary Pods sharing the `app` label:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: storefront
  labels:
    app: web
    track: stable
spec:
  replicas: 4
  revisionHistoryLimit: 5
  selector:
    matchLabels:
      app: web
    matchExpressions:
      - key: track
        operator: In
        values: [stable]        # this Deployment owns ONLY stable-track pods
  template:
    metadata:
      labels:
        app: web                # must satisfy selector above...
        track: stable           # ...including this
        tier: frontend
    spec:
      containers:
        - name: web
          image: registry.k8s.io/nginx-slim:0.27
          ports:
            - containerPort: 8080
          resources:
            requests:
              cpu: "250m"
              memory: "128Mi"
            limits:
              cpu: "500m"
              memory: "256Mi"
          readinessProbe:        # <-- gates EndpointSlice membership (§3.2)
            httpGet:
              path: /healthz
              port: 8080
            periodSeconds: 5
            failureThreshold: 3
```

### 3.2 Service selecting the same Pods — and why readiness matters

```yaml
apiVersion: v1
kind: Service
metadata:
  name: web
  namespace: storefront
spec:
  selector:
    app: web
    tier: frontend            # equality map: app==web AND tier==frontend
  ports:
    - name: http
      port: 80
      targetPort: 8080
  # NOTE: no set-based selectors here — Service.spec.selector is equality-only.
  # It will select BOTH stable and canary web pods if both carry tier=frontend.
```

The EndpointSlice controller adds a Pod to this Service's EndpointSlices only when the Pod **matches the selector AND is `Ready`** (readiness probe passing). A matching-but-not-Ready Pod is present in the slice with `conditions.ready: false` and receives no traffic. This is why a selector can be *correct* and the endpoint set still be empty — every matching Pod is failing readiness.

### 3.3 NetworkPolicy — three selectors, three roles

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: web-allow-from-gateway
  namespace: storefront
spec:
  podSelector:                 # role 1: which pods THIS policy governs
    matchLabels:
      app: web
  policyTypes: [Ingress]
  ingress:
    - from:
        - namespaceSelector:   # role 2: source namespaces...
            matchLabels:
              kubernetes.io/metadata.name: ingress-system
          podSelector:         # role 3: ...AND source pods within them
            matchLabels:
              app: gateway
      ports:
        - protocol: TCP
          port: 8080
```

Critical semantic: inside a single `from` element, `namespaceSelector` and `podSelector` are **ANDed** (gateway Pods *in* ingress-system). Split across two `-` list items they would be **ORed**. This AND/OR distinction is a top exam trap and a real-world policy hole.

### 3.4 Placement selection — node affinity + topology spread + anti-affinity

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: storefront
spec:
  replicas: 6
  selector:
    matchLabels: { app: web }
  template:
    metadata:
      labels: { app: web }
    spec:
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:   # HARD filter
            nodeSelectorTerms:
              - matchExpressions:                            # terms are ORed;
                  - key: topology.kubernetes.io/zone         # exprs within a term ANDed
                    operator: In
                    values: [us-east-1a, us-east-1b]
                  - key: node.kubernetes.io/instance-type
                    operator: NotIn
                    values: [t3.micro]
          preferredDuringSchedulingIgnoredDuringExecution:  # SOFT score
            - weight: 80
              preference:
                matchExpressions:
                  - key: kubernetes.io/arch
                    operator: In
                    values: [amd64]
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            - labelSelector:
                matchLabels: { app: web }
              topologyKey: kubernetes.io/hostname            # ≤1 web pod per node
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels: { app: web }                        # spread THESE pods evenly
      containers:
        - name: web
          image: registry.k8s.io/nginx-slim:0.27
          resources:
            requests: { cpu: "250m", memory: "128Mi" }
```

| Placement primitive | Operators | Hard/soft | Selects |
|---|---|---|---|
| `nodeSelector` | equality only | hard | nodes by label |
| `nodeAffinity.required…` | In/NotIn/Exists/DoesNotExist/**Gt/Lt** | hard | nodes by expression (Gt/Lt enable numeric matches) |
| `nodeAffinity.preferred…` | same + `weight` 1–100 | soft | nodes, weighted |
| `podAffinity`/`podAntiAffinity` | label selector + `topologyKey` | hard or soft | topology domains containing matching Pods |
| `topologySpreadConstraints` | label selector + `topologyKey` + `maxSkew` | `DoNotSchedule` (hard) / `ScheduleAnyway` (soft) | even distribution of matching Pods |

`nodeName` is the escape hatch: setting `.spec.nodeName` binds the Pod directly and **bypasses the scheduler entirely** — no filtering, no affinity, no resource fit check. Use only for debugging or DaemonSet-like static pods.

---

## 4. Field selectors — selecting objects by live state

Field selectors query **resource field values**, not labels. They are evaluated by the apiserver against a *fixed, per-resource allow-list* of indexed fields — you cannot select on an arbitrary field.

```
# Universal (all resource types):
metadata.name
metadata.namespace

# Pods (the richest set):
status.phase          spec.nodeName          spec.schedulerName
status.podIP          spec.serviceAccountName spec.restartPolicy
status.nominatedNodeName

# Nodes:
metadata.name         spec.unschedulable

# Events:
involvedObject.kind   involvedObject.name    reason    type    source
```

Operators are **`=`, `==`, `!=` only** — no set-based, no `Gt`/`Lt`. Comma = AND.

| | Label selector (`-l`) | Field selector (`--field-selector`) |
|---|---|---|
| Queries | `metadata.labels` | a curated set of spec/status fields |
| Operators | equality **and** set-based | equality only |
| Extensible | ✓ (add any label) | ✗ (per-resource hard-coded list) |
| Typical use | "which app/tier?" (identity) | "which are Running / on node X?" (state) |
| Server-side filtered | ✓ | ✓ |

Attempting an unsupported field returns a hard error, e.g. `field label not supported: status.hostIP`. This is deliberate: unindexed fields would force full-collection scans.

---

## 5. Verification and failure diagnosis

### 5.1 Baseline: inspecting labels and selecting objects

```console
$ kubectl get pods -n storefront --show-labels
NAME                   READY   STATUS    RESTARTS   AGE   LABELS
web-6c9f7b8d4-2xk9p    1/1     Running   0          9m    app=web,pod-template-hash=6c9f7b8d4,tier=frontend,track=stable
web-6c9f7b8d4-5pl2m    1/1     Running   0          9m    app=web,pod-template-hash=6c9f7b8d4,tier=frontend,track=stable
web-canary-79bd-abc    1/1     Running   0          3m    app=web,pod-template-hash=79bd0,tier=frontend,track=canary

# Equality-based, ANDed:
$ kubectl get pods -n storefront -l 'app=web,track=stable'
NAME                   READY   STATUS    RESTARTS   AGE
web-6c9f7b8d4-2xk9p    1/1     Running   0          9m
web-6c9f7b8d4-5pl2m    1/1     Running   0          9m

# Set-based — everything on a non-canary track:
$ kubectl get pods -n storefront -l 'app=web,track notin (canary)'
NAME                   READY   STATUS    RESTARTS   AGE
web-6c9f7b8d4-2xk9p    1/1     Running   0          9m
web-6c9f7b8d4-5pl2m    1/1     Running   0          9m

# Project label values as columns with -L:
$ kubectl get pods -n storefront -L track,tier
NAME                   READY   STATUS    RESTARTS   AGE   TRACK    TIER
web-6c9f7b8d4-2xk9p    1/1     Running   0          9m    stable   frontend
web-canary-79bd-abc    1/1     Running   0          3m    canary   frontend
```

Combine label + field selection to answer "which stable Pods are actually Running on a given node":

```console
$ kubectl get pods -n storefront \
    -l app=web,track=stable \
    --field-selector status.phase=Running,spec.nodeName=ip-10-0-1-23
NAME                   READY   STATUS    RESTARTS   AGE
web-6c9f7b8d4-2xk9p    1/1     Running   0          9m
```

### 5.2 The #1 production failure: Service with zero endpoints

Symptom: clients get `connection refused` / `no route to host` hitting a Service that "clearly exists."

```console
$ kubectl get endpoints web -n storefront
NAME   ENDPOINTS   AGE
web    <none>      6m                 # <-- red flag: no backends

$ kubectl get endpointslices -n storefront -l kubernetes.io/service-name=web
NAME         ADDRESSTYPE   PORTS   ENDPOINTS   AGE
web-abc12    IPv4          8080    <unset>     6m
```

Diagnose by comparing the Service selector against actual Pod labels:

```console
$ kubectl get svc web -n storefront -o jsonpath='{.spec.selector}{"\n"}'
{"app":"web","tier":"frontend"}

$ kubectl get pods -n storefront -l app=web,tier=frontend
No resources found in storefront namespace.
```

The selector is `app=web,tier=frontend`, but the Pods are labeled `app=web,tier=web-frontend` — a one-word drift. Two verification cross-checks:

```console
# Ask directly: does anything match the exact selector?
$ kubectl get pods -n storefront -l app=web,tier=frontend -o name
# (empty) -> selector matches nothing

# What DO the pods carry?
$ kubectl get pods -n storefront -l app=web -o \
    jsonpath='{range .items[*]}{.metadata.name}{"  "}{.metadata.labels.tier}{"\n"}{end}'
web-6c9f7b8d4-2xk9p  web-frontend
web-6c9f7b8d4-5pl2m  web-frontend
```

Fix by correcting whichever side is wrong (here, relabel or fix the Service). A second, subtler variant: selector matches, but every Pod is **not Ready**, so it never enters the slice:

```console
$ kubectl get endpointslices -n storefront -l kubernetes.io/service-name=web \
    -o jsonpath='{range .items[*].endpoints[*]}{.addresses}{" ready="}{.conditions.ready}{"\n"}{end}'
["10.0.3.14"] ready=false
["10.0.3.15"] ready=false          # matched, but readiness probe failing -> no traffic
```

### 5.3 Selector/template mismatch on create

```console
$ kubectl apply -f web-deploy.yaml
The Deployment "web" is invalid: spec.template.metadata.labels: Invalid value:
map[string]string{"app":"web", "tier":"frontend"}: `selector` does not match
template `labels`
```

The `.spec.selector` requires `track In [stable]`, but the Pod template omits `track`. The controller could never select the Pods it creates → rejected at admission. Fix: add `track: stable` to `template.metadata.labels`.

### 5.4 Selector immutability

```console
$ kubectl patch deployment web -n storefront \
    --type=merge -p '{"spec":{"selector":{"matchLabels":{"app":"webv2"}}}}'
The Deployment "web" is invalid: spec.selector: Invalid value:
v1.LabelSelector{...MatchLabels:map[string]string{"app":"webv2"}...}:
field is immutable
```

You cannot re-point a live controller. Recreate it (`kubectl delete deployment web` then apply the new one), or run a new Deployment alongside and shift traffic.

### 5.5 Orphaned / adopted Pods from overlapping selectors

Two controllers whose selectors overlap will fight over the same Pods. Detect ownership via `ownerReferences`:

```console
$ kubectl get pod web-6c9f7b8d4-2xk9p -n storefront \
    -o jsonpath='{.metadata.ownerReferences[0].kind}/{.metadata.ownerReferences[0].name}{"\n"}'
ReplicaSet/web-6c9f7b8d4

# A pod with NO ownerReferences that still matches a selector is an ADOPTION risk:
$ kubectl get pods -n storefront -l app=web \
    -o jsonpath='{range .items[*]}{.metadata.name}{" owner="}{.metadata.ownerReferences[0].name}{"\n"}{end}'
web-6c9f7b8d4-2xk9p  owner=web-6c9f7b8d4
legacy-web-manual    owner=            # <-- bare pod matching selector -> may be adopted/counted
```

A bare Pod carrying `app=web` will be **counted by** the Deployment's ReplicaSet (it matches the selector) and can even be scaled-down as if it were a replica. Guard against this with more specific selectors (`track In [stable]`) and never run bare Pods sharing a workload's identity labels.

### 5.6 Placement selection didn't match any node

```console
$ kubectl get pod web-xxx -n storefront
NAME       READY   STATUS    RESTARTS   AGE
web-xxx    0/1     Pending   0          40s

$ kubectl describe pod web-xxx -n storefront | sed -n '/Events/,$p'
Events:
  Type     Reason            Age   From               Message
  ----     ------            ----  ----               -------
  Warning  FailedScheduling  38s   default-scheduler  0/6 nodes are available:
           2 node(s) didn't match Pod's node affinity/selector,
           3 node(s) didn't match pod anti-affinity rules,
           1 Insufficient cpu. preemption: 0/6 nodes are available.
```

Read the tally literally: node-affinity eliminated 2, anti-affinity 3, resource fit 1. Verify the node labels the affinity expected actually exist:

```console
$ kubectl get nodes -L topology.kubernetes.io/zone,node.kubernetes.io/instance-type
NAME            STATUS   ROLES    AGE   VERSION   ZONE         INSTANCE-TYPE
ip-10-0-1-23    Ready    <none>   21d   v1.31.4   us-east-1a   m5.large
ip-10-0-2-51    Ready    <none>   21d   v1.31.4   us-east-1c   m5.large   # <-- zone not in [1a,1b]
```

Here the affinity required zone `us-east-1a`/`1b`, but half the fleet is in `1c`, and hostname anti-affinity caps one Pod per node — so six replicas can't fit two eligible nodes. Fixes: widen the zone `values`, relax hostname anti-affinity to `preferred`, or add nodes with matching labels.

### 5.7 Verification checklist

```console
# 1. Does the selector match the intended objects, and only those?
kubectl get pods -l '<selector>' -o name

# 2. For a Service, does selection resolve to Ready endpoints?
kubectl get endpointslices -l kubernetes.io/service-name=<svc> \
  -o custom-columns=SLICE:.metadata.name,READY:.endpoints[*].conditions.ready

# 3. Does the controller's selector match its own template?
kubectl get deploy <name> -o jsonpath='{.spec.selector}{"\n"}{.spec.template.metadata.labels}{"\n"}'

# 4. Any bare pods that a controller could adopt?
kubectl get pods -l '<controller-selector>' \
  -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.ownerReferences}{"\n"}{end}'

# 5. For placement failures, read the scheduler's per-reason node tally:
kubectl describe pod <name> | grep -A5 Events
```

---

## 6. References

- Labels and Selectors — https://kubernetes.io/docs/concepts/overview/working-with-objects/labels/
- Field Selectors — https://kubernetes.io/docs/concepts/overview/working-with-objects/field-selectors/
- LabelSelector API definition — https://kubernetes.io/docs/reference/kubernetes-api/common-definitions/label-selector/
- Service (`spec.selector`, headless, endpoints) — https://kubernetes.io/docs/concepts/services-networking/service/
- EndpointSlices (readiness → membership) — https://kubernetes.io/docs/concepts/services-networking/endpoint-slices/
- Deployments (selector immutability, template matching) — https://kubernetes.io/docs/concepts/workloads/controllers/deployment/
- ReplicaSet (adoption via selectors, `ownerReferences`) — https://kubernetes.io/docs/concepts/workloads/controllers/replicaset/
- Assigning Pods to Nodes (`nodeSelector`, node affinity, inter-pod affinity) — https://kubernetes.io/docs/concepts/scheduling-eviction/assign-pod-node/
- Pod Topology Spread Constraints — https://kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints/
- Network Policies (podSelector / namespaceSelector AND-vs-OR) — https://kubernetes.io/docs/concepts/services-networking/network-policies/
- Pod Disruption Budget (`spec.selector`) — https://kubernetes.io/docs/tasks/run-application/configure-pdb/
- kubectl reference (`-l`, `--field-selector`, `-L`, `--show-labels`) — https://kubernetes.io/docs/reference/generated/kubectl/kubectl-commands
- kubectl cheat sheet — https://kubernetes.io/docs/reference/kubectl/cheatsheet/