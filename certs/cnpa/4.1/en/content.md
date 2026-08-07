# Kubernetes Reconciliation Loop and Control Plane Architecture

> CNPA · Domain 4 · Topic 4.1 · Exam weight: 3.0
> Level: Platform Architect / Senior SRE

---

## 1. Motivation: why platforms are built on control loops, not orchestration scripts

A platform team's real product is not "a Kubernetes cluster." It is a **contract**: a developer declares intent (`I want 3 replicas of this image, exposed on port 443, with these secrets`) and the platform makes reality match that intent — and *keeps* it matching, forever, through node failures, network partitions, evictions, and human mistakes.

The naïve way to build this is **imperative orchestration**: a workflow engine that receives an event ("deploy requested"), runs a sequence of steps (pull image → start container → register in LB → open firewall), and marks the job done. This is how most pre-Kubernetes PaaS systems (and many CI/CD pipelines today) work. It has a fatal property at scale: **it only reacts to the event it was told about, once.** If step 3 succeeds but the load balancer silently drops the backend an hour later, nothing notices. If the orchestrator missed the "node died" event because it was restarting, the workload stays down. State drift accumulates and the system's model of the world diverges from reality until a human is paged.

Kubernetes chose the opposite architecture. Every actor in the system is a **reconciler**: a loop that continuously observes the *actual* state of the world, compares it to the *desired* state, and takes whatever action closes the gap — then does it again. There is no "job is done." There is only *converged* and *not yet converged*. This is the single most important architectural idea in the entire ecosystem, because every higher-order platform tool you will build or operate — Argo CD, Flux, Crossplane, cert-manager, the Cluster Autoscaler, your own Operators — is *the same pattern applied to a different resource*. Master the loop once and you understand all of them.

This topic covers (a) the control loop as a formal pattern, (b) the concrete control-plane components that implement it, and (c) how you verify, observe and debug reconciliation when it stalls — the failure mode that produces the most confusing production incidents, because the cluster looks healthy while nothing is actually happening.

---

## 2. The reconciliation loop as a pattern

### 2.1 The canonical loop

Every controller — core or custom — runs the same three-step loop:

```
for {
    desired  := read desired state   (spec, from the API server)
    observed := read actual state    (status + the real world)
    if desired != observed {
        act to move observed toward desired   // idempotent
    }
    // then wait for the next trigger and repeat
}
```

Three properties make this robust in ways an event pipeline is not:

- **Declarative, not procedural.** The controller is given the *goal* (`replicas: 3`), never the *steps*. It computes the steps each time from the current gap. If it crashes halfway, the next iteration recomputes from wherever reality actually is — there is no half-finished transaction to unwind.
- **Level-triggered, not edge-triggered.** The controller acts on the *current level* of state, not on the *event* (edge) that changed it. A missed, duplicated, or reordered event cannot corrupt the outcome, because the controller never trusts events for correctness — it re-reads full state. Events are only an *optimization* to avoid polling.
- **Idempotent by construction.** Running the reconcile twice on already-converged state is a no-op. This is what lets the loop run continuously and safely retry on any error.

### 2.2 spec vs status: the two halves of every object

Every Kubernetes object carries two sub-objects, and understanding who writes each is the key to the whole model:

| Field | Written by | Read by | Meaning |
|---|---|---|---|
| `.spec` | **User / higher controller** | Controller | *Desired* state — the intent |
| `.status` | **Controller** | User / higher controller | *Observed* state — reality as the controller last saw it |
| `.metadata.generation` | API server | Controller | Bumped when `.spec` changes |
| `.status.observedGeneration` | Controller | Everyone | Which `.spec` generation this status reflects |

The relationship `status.observedGeneration == metadata.generation` is the machine-readable definition of "converged." When they differ, the controller has seen a new intent it has not yet acted on. This single pair is the most reliable convergence probe you have, and most of section 5 leans on it.

### 2.3 Level vs edge triggering — the trade-off

| Dimension | Edge-triggered (event pipelines) | Level-triggered (Kubernetes) |
|---|---|---|
| Trigger | The *change event* | The *current state* |
| Missed event | Permanent inconsistency | Self-heals on next sync |
| Duplicate event | May double-apply | Harmless (idempotent) |
| Out-of-order events | Corrupts state | Irrelevant — full re-read |
| Cost of correctness | Cheap per event | Requires periodic full resync |
| Recovery after controller downtime | Must replay event log | Just LIST current state and continue |
| Typical failure mode | Silent drift, stuck jobs | Slow convergence, hot reconcile loops |

Kubernetes is *level-triggered with an edge-triggered optimization*: it uses watches (edges) to know *when* to look, but always acts on the current level. That is why a controller that was offline for an hour recovers by doing one full `LIST` and carrying on — no event replay, no catch-up logic. Platform engineers exploit this constantly: it is why `kubectl apply` the same manifest a thousand times is safe, why GitOps can re-sync from Git at any moment, and why deleting a controller Pod never loses data.

---

## 3. Control-plane architecture

### 3.1 Component map

```
                         ┌───────────────────────────────────────────────┐
                         │                 CONTROL PLANE                  │
                         │                                                │
   kubectl / clients ───►│  kube-apiserver ──(gRPC)──►  etcd  (Raft)      │
        (REST over TLS)  │        ▲   ▲   ▲              (source of truth) │
                         │        │   │   │                               │
                         │   watch│   │   │watch                          │
                         │        │   │   │                               │
                         │  kube-scheduler  kube-controller-manager       │
                         │                  cloud-controller-manager      │
                         └────────┬───────────────────┬──────────────────┘
                                  │ watch (bind pods)  │ watch
                         ┌────────▼────────────────────▼──────────────────┐
                         │                   WORKER NODES                  │
                         │   kubelet  ──►  container runtime (CRI)         │
                         │   kube-proxy ──► iptables / IPVS / nftables     │
                         └─────────────────────────────────────────────────┘
```

The defining architectural rule: **components never talk to each other directly. They all talk to the API server, and the API server talks to etcd.** The scheduler does not call the kubelet; it writes `pod.spec.nodeName` to the API server, and the kubelet — watching its own node's pods — notices and acts. This *hub-and-spoke through a shared datastore* topology is what makes the control plane loosely coupled: any component can restart independently, and the watch mechanism lets it resume from the current state with no coordination.

### 3.2 The components

**etcd** — the only stateful component and the single source of truth. A distributed key-value store using the **Raft** consensus algorithm for strong consistency across an odd-numbered quorum (typically 3 or 5 members). Every piece of cluster state — every object's spec and status — lives here as a serialized (protobuf) blob under a key like `/registry/pods/default/nginx`. etcd's **watch** primitive (a streaming API keyed on a monotonic `revision`) is what the API server builds its own watch on top of. etcd is the availability floor of the whole cluster: lose quorum and the API server goes read-only-then-unavailable, though existing workloads keep running because kubelet and kube-proxy already have their local state.

**kube-apiserver** — the front door and the *only* client of etcd. It is a stateless (horizontally scalable) REST server that:
- authenticates and authorizes every request (RBAC, webhooks),
- runs the **admission chain** (mutating → validating admission webhooks, then schema validation),
- performs optimistic-concurrency writes to etcd,
- serves **watch** streams to every controller, backed by an in-memory **watch cache** so thousands of watchers don't each hammer etcd.

**kube-scheduler** — a specialized controller with exactly one job: watch for Pods where `spec.nodeName == ""` and choose a node. It runs a two-phase algorithm — **Filter** (predicates: does the node have enough CPU/memory, does it tolerate the taints, do affinities allow it?) then **Score** (rank the feasible nodes) — and then *binds* the Pod by writing `nodeName`. It does not start the container; it only makes the placement decision. That decision is another state write that a *different* reconciler (kubelet) picks up.

**kube-controller-manager** — a single binary that hosts dozens of independent core control loops in separate goroutines: the Deployment controller, ReplicaSet controller, Node controller, Job controller, EndpointSlice controller, ServiceAccount controller, PersistentVolume controller, and more. Each is a textbook reconciler over its own resource type.

**cloud-controller-manager** — the cloud-specific loops (provision a real load balancer for a `Service type=LoadBalancer`, attach a cloud disk for a PV, mark a Node `NotReady` when the cloud API says the VM is gone). Split out so the core is cloud-agnostic.

### 3.3 The chain of reconcilers: one `kubectl apply`, five loops

The power of the model is that a single high-level intent decomposes into a *pipeline of independent reconcilers*, each watching the output of the previous one. Creating one Deployment triggers:

| # | Controller | Watches | Produces (writes to API) |
|---|---|---|---|
| 1 | Deployment controller | Deployments | A ReplicaSet with the pod template + revision |
| 2 | ReplicaSet controller | ReplicaSets | N Pods (with `ownerReferences` back to the RS) |
| 3 | kube-scheduler | unscheduled Pods | `pod.spec.nodeName` set |
| 4 | kubelet (on that node) | Pods bound to *its* node | Running containers; `pod.status` updated |
| 5 | EndpointSlice controller | Pods + Services | EndpointSlices; kube-proxy then programs dataplane |

No controller knows about any other. Each one only closes the gap on *its* resource, and the gap it closes becomes the desired state for the next. This is the same composition you rely on when you stack Argo CD (reconciles Git → cluster) on top of Crossplane (reconciles a `Composition` → cloud resources) on top of these core loops. Understanding it is the difference between "the Pod is Pending, I'll restart the scheduler" and "`observedGeneration` on the RS is stale, the RS controller is wedged, let me check its leader Lease."

---

## 4. The mechanics under the loop: informers, watches, and the work queue

A controller does not poll the API server in a `for` loop — that would melt etcd. It uses the **informer / list-watch** machinery, and knowing this internal plumbing is what lets you read controller metrics and debug a stalled loop.

### 4.1 List-watch and the informer cache

```
   API server                          Controller process
   ──────────                          ──────────────────
                                       ┌──────────────────────────────┐
   1. LIST pods  ──────────────────►   │ Reflector: full sync,        │
      (resourceVersion=8871)           │ seeds the local cache        │
                                       │                              │
   2. WATCH pods?resourceVersion=8871  │ Delta FIFO queue             │
      ◄── stream of ADD/UPD/DEL ────►  │      │                       │
                                       │      ▼                       │
                                       │ Indexer (in-memory cache) ── │──► your Reconcile()
                                       │      │                       │        reads from cache,
                                       │      ▼ (key: ns/name)        │        NOT from apiserver
                                       │ Rate-limited work queue ─────┼──►  (dedupes + backoff)
                                       └──────────────────────────────┘
```

1. **Reflector** does one `LIST` to seed a local **cache (Indexer)**, recording the `resourceVersion`.
2. It then opens a **WATCH** starting *after* that `resourceVersion`, receiving a stream of `ADDED`/`MODIFIED`/`DELETED` deltas that keep the cache current.
3. Deltas are pushed as **keys** (`namespace/name`, never the object) into a **rate-limited work queue** that **de-duplicates** — 100 rapid changes to one Pod collapse into one queued key.
4. Worker goroutines pop keys and call `Reconcile(key)`, which reads the *current* object from the local cache (a memory read, cheap) and does the level-triggered comparison.

Two consequences you must internalize:

- **The cache can be stale.** `Reconcile` reads from the informer cache, which lags the API server by milliseconds-to-seconds. A controller that writes an object and immediately re-reads it from its cache may see the *old* value. This is the root cause of a huge class of "my Operator double-created the resource" bugs — the fix is to tolerate it (idempotency) or read-your-writes via a live client.
- **The queue absorbs load.** Because the queue de-dupes on key and applies **exponential backoff** on error, a failing reconcile does not spin — it requeues with increasing delay. `workqueue_depth` and `workqueue_retries_total` are your primary health signals (section 5.4).

### 4.2 resourceVersion, optimistic concurrency, and expired watches

- **`resourceVersion`** is an opaque, monotonically increasing token (backed by etcd's revision). It is the cursor for watches and the compare-and-swap token for writes.
- **Writes are optimistic-concurrency-controlled.** An `UPDATE` carries the `resourceVersion` you read. If someone else wrote in between, the API server returns **`409 Conflict`** and you must re-read and retry. This is how two controllers editing the same object avoid lost updates without locks.
- **Watches expire.** etcd only retains a compaction window of history. If a controller's watch falls too far behind, the API server returns **`410 Gone`** and the reflector must **re-LIST** (a full resync). A controller stuck in a re-list storm is a classic symptom of an overloaded etcd or an under-provisioned watch cache.

### 4.3 Leader election: why "the controller is running" isn't enough

You run `kube-controller-manager` (and most Operators) with **more than one replica for availability**, but you must **not** run the reconcile loops concurrently — two Deployment controllers fighting over the same ReplicaSet is chaos. The answer is **leader election** via a `Lease` object: replicas race to acquire and periodically renew a Lease; only the holder runs the loops; the others sit as hot standbys. If the leader's process hangs (but the pod stays "Running"), it stops renewing, the Lease expires, and a standby takes over.

This is the single most common cause of "the cluster is up but nothing reconciles": the leader Pod is `Running` and `Ready`, but its reconcile goroutines are deadlocked and it is still renewing the Lease (or clock skew is preventing failover). `kubectl get lease -n kube-system` is the first thing to check (section 5.3).

---

## 5. Verification and failure diagnosis

This is where the pattern pays or fails you in production. The recurring, high-confusion incident is **the cluster looks healthy but reconciliation has silently stopped.** The following is the diagnostic ladder, from "is the loop even converging?" down to "which internal queue is wedged?"

### 5.1 Is a specific object converged?

The `generation` / `observedGeneration` pair is the ground truth.

```console
$ kubectl get deploy web -o jsonpath='{.metadata.generation} {.status.observedGeneration}{"\n"}'
7 7
```

Equal ⇒ the Deployment controller has *seen and acted on* the latest spec. If they diverge and stay diverged, the controller is not processing this object.

```console
$ kubectl rollout status deploy/web --timeout=60s
Waiting for deployment "web" rollout to finish: 2 of 3 updated replicas are available...
deployment "web" successfully rolled out
```

Look at the standardized `conditions` — every well-behaved resource publishes them:

```console
$ kubectl get deploy web -o jsonpath='{range .status.conditions[*]}{.type}={.status} ({.reason}){"\n"}{end}'
Available=True (MinimumReplicasAvailable)
Progressing=True (NewReplicaSetAvailable)
```

A stuck rollout shows `Progressing=False (ProgressDeadlineExceeded)` — the controller *is* working but cannot converge (bad image, failing probes), which is a completely different problem from "the controller stopped."

### 5.2 Watch the loop live and read what it decided

`--watch` streams the level changes as the controller writes them; `events` are the controller's own audit log of *why* it acted.

```console
$ kubectl get pods -w
NAME                   READY   STATUS              RESTARTS   AGE
web-6f8c9d5b7c-2xk4p   0/1     Pending             0          0s
web-6f8c9d5b7c-2xk4p   0/1     ContainerCreating   0          2s
web-6f8c9d5b7c-2xk4p   1/1     Running             0          6s
```

```console
$ kubectl get events --sort-by=.lastTimestamp -A | tail -8
NAMESPACE  LAST SEEN  TYPE      REASON             OBJECT                     MESSAGE
default    12s        Normal    ScalingReplicaSet  deployment/web             Scaled up replica set web-6f8c9d5b7c to 3
default    11s        Normal    SuccessfulCreate   replicaset/web-6f8c9d5b7c  Created pod: web-6f8c9d5b7c-2xk4p
default    10s        Normal    Scheduled          pod/web-6f8c9d5b7c-2xk4p   Successfully assigned default/web-... to node-2
default    8s         Normal    Pulled             pod/web-6f8c9d5b7c-2xk4p   Container image "nginx:1.27" already present
default    6s         Normal    Started            pod/web-6f8c9d5b7c-2xk4p   Started container nginx
```

Absence of events for a resource you just changed is itself the signal: **no reconciler picked it up.**

### 5.3 Is the control plane itself alive, and who is the leader?

```console
$ kubectl get pods -n kube-system -l tier=control-plane
NAME                            READY   STATUS    RESTARTS   AGE
kube-apiserver-cp-1             1/1     Running   0          21d
kube-controller-manager-cp-1    1/1     Running   4 (3h ago) 21d
kube-scheduler-cp-1             1/1     Running   0          21d

$ kubectl get componentstatuses      # legacy but still fast
NAME                 STATUS    MESSAGE   ERROR
scheduler            Healthy   ok
controller-manager   Healthy   ok
etcd-0               Healthy   ok
```

The leader Leases — the answer to "is anyone actually holding the loop?":

```console
$ kubectl get lease -n kube-system kube-controller-manager kube-scheduler
NAME                      HOLDER                 AGE
kube-controller-manager   cp-1_5f3a...           21d
kube-scheduler            cp-2_9b1c...           21d

$ kubectl get lease -n kube-system kube-controller-manager \
    -o jsonpath='{.spec.holderIdentity} renewed {.spec.renewTime}{"\n"}'
cp-1_5f3a... renewed 2026-08-07T14:02:11.000000Z
```

**If `renewTime` is not advancing** (compare two calls a few seconds apart) while the Pod is `Running`, the leader is wedged — the classic silent stall. Force a failover by deleting the leader Pod; a standby acquires the Lease and reconciliation resumes.

### 5.4 Read the controller's internal queue metrics

Controllers expose Prometheus metrics on `/metrics`. These are the *only* window into whether the loop is churning, backing off, or idle.

```console
$ kubectl get --raw /metrics | grep -E 'workqueue_(depth|adds_total|retries_total)' | grep deployment
workqueue_depth{name="deployment"} 0
workqueue_adds_total{name="deployment"} 184213
workqueue_retries_total{name="deployment"} 27
```

For controller-manager itself (scrape a control-plane node's endpoint):

```console
$ kubectl -n kube-system exec kube-controller-manager-cp-1 -- \
    wget -qO- https://127.0.0.1:10257/metrics --no-check-certificate \
    | grep -E 'leader_election_master_status|workqueue_depth' | head
leader_election_master_status{name="kube-controller-manager"} 1
workqueue_depth{name="node"} 0
workqueue_depth{name="deployment"} 2
```

Interpretation table:

| Symptom in metrics | Meaning | Action |
|---|---|---|
| `workqueue_depth` high and **not draining** | Reconcile is failing or too slow | Check controller logs for reconcile errors; check downstream (etcd, webhooks) |
| `workqueue_depth` = 0 but objects unconverged | Nothing is being *enqueued* — watch broken / not leader | Check `leader_election_master_status`, watch health, informer sync |
| `workqueue_retries_total` climbing fast | Reconcile erroring in a hot retry loop | Read the returned error in logs; usually a downstream 409/timeout/webhook |
| `rest_client_requests_total{code="429"}` rising | API server / etcd throttling the controller | etcd overloaded; check etcd latency (5.5) |
| `..._request_total{code="410"}` on watches | Watches expiring → re-list storms | Under-sized watch cache or etcd compaction pressure |

### 5.5 etcd health — the availability floor

Every stall eventually asks "is etcd healthy?" — because a slow etcd makes *every* write time out and *every* controller back off.

```console
$ ETCDCTL_API=3 etcdctl \
    --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/server.crt \
    --key=/etc/kubernetes/pki/etcd/server.key \
    endpoint status --write-out=table
+------------------------+------------------+---------+---------+-----------+------------+
|        ENDPOINT        |        ID        | VERSION | DB SIZE | IS LEADER | RAFT INDEX |
+------------------------+------------------+---------+---------+-----------+------------+
| https://127.0.0.1:2379 | 8e9e05c52164694d |  3.5.16 |  118 MB |      true |   40218873 |
+------------------------+------------------+---------+---------+-----------+------------+

$ etcdctl ... endpoint health
https://127.0.0.1:2379 is healthy: successfully committed proposal: took = 3.114ms
```

From the API server's own view, the two golden latency signals (SLO: 99th percentile write < ~1s):

```console
$ kubectl get --raw /metrics | grep 'etcd_request_duration_seconds_bucket' | tail -3
etcd_request_duration_seconds_bucket{operation="update",type="pods",le="1"} 918342
etcd_request_duration_seconds_bucket{operation="update",type="pods",le="2.5"} 918901
etcd_request_duration_seconds_bucket{operation="update",type="pods",le="+Inf"} 918905
```

A rising `etcd_request_duration` p99, a growing DB size approaching the `--quota-backend-bytes` limit, or `mvcc: database space exceeded` in etcd logs will manifest cluster-wide as *nothing reconciling* — because writes are failing and every controller is dutifully backing off. The fix is defrag + compaction, or raising the quota, not restarting controllers.

### 5.6 API server flags that govern the loop's plumbing

For platform operators, these are the knobs that shape reconciliation behavior at scale:

```console
$ kubectl -n kube-system get pod kube-apiserver-cp-1 -o jsonpath='{.spec.containers[0].command}' \
    | tr ',' '\n' | grep -E 'etcd|watch-cache|max-requests|priority'
"--etcd-servers=https://127.0.0.1:2379"
"--watch-cache=true"
"--default-watch-cache-size=100"
"--max-requests-inflight=400"
"--max-mutating-requests-inflight=200"
"--enable-priority-and-fairness=true"
```

`--enable-priority-and-fairness` (**API Priority and Fairness**) is the mechanism that stops one runaway controller's re-list storm from starving the scheduler — it fair-shares inflight requests across `FlowSchema`/`PriorityLevelConfiguration` classes. When a single Operator floods the API server, you will see it isolated to its own priority level rather than taking down the control plane.

---

## 6. Applying the pattern: a minimal custom reconciler

The reason this topic carries weight for a *platform* certification: every platform capability you add is a new reconciler. Below is a complete, minimal Operator that reconciles a custom `Website` resource into a Deployment — the same loop, one level up. This is what Crossplane compositions, cert-manager, and your internal platform APIs all *are* underneath.

### 6.1 The CRD (the new desired-state contract)

```yaml
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: websites.platform.example.com
spec:
  group: platform.example.com
  scope: Namespaced
  names:
    plural: websites
    singular: website
    kind: Website
    shortNames: ["web"]
  versions:
    - name: v1alpha1
      served: true
      storage: true
      subresources:
        status: {}                     # split spec/status; status is written via /status
      schema:
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: object
              required: ["image", "replicas"]
              properties:
                image:
                  type: string
                replicas:
                  type: integer
                  minimum: 1
                  maximum: 20
            status:
              type: object
              properties:
                observedGeneration:
                  type: integer
                  format: int64
                readyReplicas:
                  type: integer
                conditions:
                  type: array
                  items:
                    type: object
                    required: ["type", "status"]
                    properties:
                      type:    { type: string }
                      status:  { type: string }
                      reason:  { type: string }
                      message: { type: string }
      additionalPrinterColumns:
        - name: Image
          type: string
          jsonPath: .spec.image
        - name: Ready
          type: integer
          jsonPath: .status.readyReplicas
        - name: Age
          type: date
          jsonPath: .metadata.creationTimestamp
```

### 6.2 An instance (the intent a developer submits)

```yaml
apiVersion: platform.example.com/v1alpha1
kind: Website
metadata:
  name: marketing-site
  namespace: apps
spec:
  image: registry.example.com/marketing:2.4.1
  replicas: 3
```

### 6.3 The Reconcile function (controller-runtime)

The entire controller is this idempotent, level-triggered function. Note the shape: read desired, read observed, converge, update status, return.

```go
// Reconcile is called with just a namespaced name — never the object.
// It re-reads current state every time (level-triggered) and must be idempotent.
func (r *WebsiteReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
    log := ctrl.LoggerFrom(ctx)

    // 1. READ DESIRED STATE. NotFound => the object was deleted; nothing to do
    //    (garbage collection removes the owned Deployment via ownerReferences).
    var site platformv1.Website
    if err := r.Get(ctx, req.NamespacedName, &site); err != nil {
        return ctrl.Result{}, client.IgnoreNotFound(err)
    }

    // 2. COMPUTE the desired child object from the parent spec.
    desired := buildDeployment(&site) // labels, replicas, image, ownerRef -> site

    // Set ownerReference so the Deployment is garbage-collected with the Website.
    if err := ctrl.SetControllerReference(&site, desired, r.Scheme); err != nil {
        return ctrl.Result{}, err
    }

    // 3. READ OBSERVED STATE and converge. Server-Side Apply is idempotent:
    //    running it on already-converged state is a no-op.
    if err := r.Patch(ctx, desired, client.Apply,
        client.FieldOwner("website-controller"), client.ForceOwnership); err != nil {
        return ctrl.Result{}, err // returning an error => requeue with backoff
    }

    // 4. REPORT STATUS back up the chain (the /status subresource).
    var dep appsv1.Deployment
    if err := r.Get(ctx, client.ObjectKeyFromObject(desired), &dep); err != nil {
        return ctrl.Result{}, err
    }
    site.Status.ReadyReplicas = dep.Status.ReadyReplicas
    site.Status.ObservedGeneration = site.Generation            // convergence marker
    meta.SetStatusCondition(&site.Status.Conditions, metav1.Condition{
        Type:   "Ready",
        Status: readyCond(dep.Status.ReadyReplicas, *site.Spec.Replicas),
        Reason: "DeploymentReconciled",
    })
    if err := r.Status().Update(ctx, &site); err != nil {
        // 409 Conflict here is normal under contention: drop and requeue,
        // the next pass re-reads the fresh resourceVersion.
        return ctrl.Result{}, client.IgnoreNotFound(err)
    }

    log.Info("reconciled", "ready", site.Status.ReadyReplicas, "desired", *site.Spec.Replicas)
    return ctrl.Result{}, nil // success => dequeued; re-triggered by the next watch event
}

// SetupWithManager wires the informer/watch: reconcile on Website changes AND on
// changes to owned Deployments (so drift in the child re-triggers the parent loop).
func (r *WebsiteReconciler) SetupWithManager(mgr ctrl.Manager) error {
    return ctrl.NewControllerManagedBy(mgr).
        For(&platformv1.Website{}).
        Owns(&appsv1.Deployment{}).
        Complete(r)
}
```

Every property from sections 2–4 is visible here: it reads from the cache (`r.Get`), converges idempotently (Server-Side Apply), tolerates `409 Conflict`, reports `observedGeneration`, and `Owns()` wires a second watch so that *drift in the child* (someone `kubectl edit`s the Deployment down to 1 replica) re-enqueues the parent and gets healed. That last point is the whole value proposition: **the platform continuously defends the developer's declared intent against drift**, with no pipeline and no human.

### 6.4 Verifying the custom loop

```console
$ kubectl apply -f website.yaml
website.platform.example.com/marketing-site created

$ kubectl get website marketing-site -n apps
NAME             IMAGE                                     READY   AGE
marketing-site   registry.example.com/marketing:2.4.1      3       14s

$ kubectl get website marketing-site -n apps \
    -o jsonpath='{.metadata.generation} {.status.observedGeneration} ready={.status.readyReplicas}{"\n"}'
1 1 ready=3

# Drift test: scale the child Deployment behind the controller's back.
$ kubectl scale deploy/marketing-site -n apps --replicas=1
deployment.apps/marketing-site scaled

# The Owns() watch re-enqueues the Website; the loop heals it back to 3.
$ kubectl get deploy marketing-site -n apps -w
NAME             READY   UP-TO-DATE   AVAILABLE   AGE
marketing-site   1/3     3            1           40s
marketing-site   2/3     3            2           41s
marketing-site   3/3     3            3           43s
```

The drift was corrected in seconds by the same level-triggered loop, with no external trigger — the definitive demonstration of the pattern.

---

## 7. Trade-offs summary for platform design

| Design choice | Reconciliation model (Kubernetes) | Imperative orchestration | When the alternative wins |
|---|---|---|---|
| Consistency model | Eventual, self-healing convergence | Immediate, but no drift correction | Strict linear workflows with human gates (some CI/CD) |
| Failure recovery | Automatic on next sync | Needs replay/compensation logic | One-shot batch jobs that must *not* re-run |
| State authority | Single source of truth (etcd) | Distributed across steps | Multi-system sagas with external transactions |
| Operational visibility | `generation`/`status`/conditions/metrics | Job logs | Rich per-step audit trails |
| Cost | Continuous CPU + API/etcd load | Cheap when idle | Very high object counts overwhelming one etcd |
| Extensibility | Add a CRD + a reconciler | New pipeline per capability | — (reconciler pattern dominates) |
| Concurrency safety | Optimistic concurrency + leader election | Locks / queues | — |

The reconciliation loop is not free — it trades continuous compute and etcd pressure for the guarantee that reality is *always* being pulled toward intent. For a platform, that guarantee is the product. The failure modes it introduces (silent stalls, hot reconcile loops, watch-cache and etcd pressure) are precisely what section 5 exists to diagnose, and they are where a platform SRE earns their keep.

---

## 8. Referencias

- Kubernetes — *Controllers* (the reconciliation loop, level-triggered design): https://kubernetes.io/docs/concepts/architecture/controller/
- Kubernetes — *Kubernetes Components* (control-plane and node components): https://kubernetes.io/docs/concepts/overview/components/
- Kubernetes — *The Kubernetes API* and *API Concepts* (watch, `resourceVersion`, bookmarks, optimistic concurrency): https://kubernetes.io/docs/reference/using-api/api-concepts/
- Kubernetes — *Leases* (leader election objects): https://kubernetes.io/docs/concepts/architecture/leases/
- Kubernetes — *API Priority and Fairness*: https://kubernetes.io/docs/concepts/cluster-administration/flow-control/
- Kubernetes — *kube-apiserver* reference (flags: `--etcd-servers`, `--watch-cache`, inflight limits): https://kubernetes.io/docs/reference/command-line-tools-reference/kube-apiserver/
- Kubernetes — *kube-scheduler* reference (Filter/Score framework): https://kubernetes.io/docs/reference/scheduling/config/
- Kubernetes — *Operating etcd clusters for Kubernetes* (backup, defrag, quota): https://kubernetes.io/docs/tasks/administer-cluster/configure-upgrade-etcd/
- Kubernetes — *Custom Resources* and *CustomResourceDefinitions*: https://kubernetes.io/docs/concepts/extend-kubernetes/api-extension/custom-resources/
- Kubernetes — *Server-Side Apply*: https://kubernetes.io/docs/reference/using-api/server-side-apply/
- etcd — official documentation (Raft, watch, MVCC/compaction): https://etcd.io/docs/
- kubebuilder / controller-runtime — *The Kubebuilder Book* (Reconcile, informers, owner references): https://book.kubebuilder.io/
- controller-runtime — API reference: https://pkg.go.dev/sigs.k8s.io/controller-runtime
- CNCF — CNPA Curriculum (exam domains and weights): https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf