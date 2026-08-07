# Topic 4.1 — Kubernetes Reconciliation Loop and Control Plane Architecture

## Guided Exercises

> **Prerequisites.** A working cluster where you have `cluster-admin` (a local `kind`, `minikube`, or a lab cluster is ideal, because several steps inspect control-plane pods and etcd). `kubectl` v1.29+ configured against it. A second terminal is useful for the `--watch` steps. Command outputs shown below are *representative*: node names, IPs, `resourceVersion` numbers, and UIDs will differ on your cluster.

---

### Exercise 1 — Watching a control loop close the gap

The control plane is a set of **controllers**, each running a loop that drives *observed state* toward *desired state*. This exercise makes one loop visible.

1. Create a namespace to keep the lab isolated:

   ```bash
   kubectl create namespace recon-lab
   ```

2. Apply a Deployment declaring **3** replicas. Note that you declare *what* you want, not *how* to achieve it:

   ```bash
   kubectl apply -n recon-lab -f - <<'EOF'
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: web
   spec:
     replicas: 3
     selector:
       matchLabels:
         app: web
     template:
       metadata:
         labels:
           app: web
       spec:
         containers:
         - name: nginx
           image: nginx:1.27-alpine
           ports:
           - containerPort: 80
   EOF
   ```

3. In a **second terminal**, start watching the Pods so you can see reconciliation happen live:

   ```bash
   kubectl get pods -n recon-lab -l app=web --watch
   ```

   Expected (steady state):

   ```
   NAME                   READY   STATUS    RESTARTS   AGE
   web-6f9c8b7d5c-2xk9p   1/1     Running   0          40s
   web-6f9c8b7d5c-8vqzt   1/1     Running   0          40s
   web-6f9c8b7d5c-lm4rn   1/1     Running   0          40s
   ```

4. Back in the **first terminal**, delete one Pod directly (an out-of-band perturbation of observed state):

   ```bash
   kubectl delete pod -n recon-lab -l app=web \
     --field-selector 'status.phase=Running' \
     $(kubectl get pods -n recon-lab -l app=web -o name | head -n1 | cut -d/ -f2) 2>/dev/null \
     || kubectl delete pod -n recon-lab "$(kubectl get pods -n recon-lab -l app=web -o name | head -n1)"
   ```

   (Simpler equivalent — just delete the first Pod by name: `kubectl delete pod -n recon-lab <pod-name>`.)

5. Watch the second terminal. Within roughly a second you should see the ReplicaSet controller create a replacement:

   ```
   web-6f9c8b7d5c-lm4rn   1/1     Terminating   0          2m
   web-6f9c8b7d5c-qp7hd   0/1     Pending       0          0s
   web-6f9c8b7d5c-qp7hd   0/1     ContainerCreating   0    0s
   web-6f9c8b7d5c-qp7hd   1/1     Running       0          2s
   ```

6. Inspect the ReplicaSet, whose `status` records the *observed* count the controller is reconciling against `spec.replicas`:

   ```bash
   kubectl get rs -n recon-lab -l app=web \
     -o custom-columns='NAME:.metadata.name,DESIRED:.spec.replicas,CURRENT:.status.replicas,READY:.status.readyReplicas'
   ```

   Expected:

   ```
   NAME             DESIRED   CURRENT   READY
   web-6f9c8b7d5c   3         3         3
   ```

**Comprehension checks (Block 1)**

- **Q1.1** You deleted a Pod but never asked anything to recreate it. Which component recreated it, and against what did it compare to decide a Pod was missing?
- **Q1.2** The Deployment `spec` has no list of Pod names. Why is this called a *declarative* API, and what would the *imperative* equivalent of step 5 have looked like?
- **Q1.3** Two controllers were actually involved between the Deployment and the Pods. Name both and state what each one owns.

---

### Exercise 2 — Level-triggered vs edge-triggered reconciliation

Kubernetes controllers are **level-triggered**: they act on the *current level* of state, not on the *event* that changed it. This exercise demonstrates why that makes them self-healing even across missed events.

1. Scale the Deployment to 5 with an imperative edit, then immediately back to 4, quickly:

   ```bash
   kubectl scale deployment/web -n recon-lab --replicas=5
   kubectl scale deployment/web -n recon-lab --replicas=4
   ```

2. Observe the converged result:

   ```bash
   kubectl get deploy/web -n recon-lab
   ```

   Expected:

   ```
   NAME   READY   UP-TO-DATE   AVAILABLE   AGE
   web    4/4     4            4           6m
   ```

3. Now simulate a controller that "missed" intermediate events. Pause the Deployment rollout, make several `spec` changes, then resume:

   ```bash
   kubectl rollout pause deployment/web -n recon-lab
   kubectl set image deployment/web -n recon-lab nginx=nginx:1.26-alpine
   kubectl set image deployment/web -n recon-lab nginx=nginx:1.27-alpine
   kubectl set resources deployment/web -n recon-lab \
     --requests=cpu=50m,memory=32Mi --limits=cpu=100m,memory=64Mi
   kubectl rollout resume deployment/web -n recon-lab
   ```

4. Check the final Pod spec. Note that only the **final** desired level matters — the intermediate image `1.26-alpine` is never rolled out:

   ```bash
   kubectl get deploy/web -n recon-lab \
     -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
   ```

   Expected:

   ```
   nginx:1.27-alpine
   ```

5. Confirm the running Pods match that final level:

   ```bash
   kubectl get pods -n recon-lab -l app=web \
     -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].image}{"\n"}{end}'
   ```

**Comprehension checks (Block 2)**

- **Q2.1** In an *edge-triggered* system, what would have happened if the controller processed the "scale to 5" event but crashed before the "scale to 4" event? Why does the level-triggered design avoid that failure mode?
- **Q2.2** In step 4, why does the intermediate image `nginx:1.26-alpine` never appear on any Pod, even though you explicitly set it?
- **Q2.3** Watches and events *do* exist in Kubernetes (informers use them). Reconcile this with the claim that controllers are level-triggered: what role does the event actually play?

---

### Exercise 3 — The API server, etcd, `resourceVersion`, and optimistic concurrency

The `kube-apiserver` is the **only** component that talks to etcd; everything else talks to the API server. State carries a `resourceVersion` that etcd uses for **optimistic concurrency control**.

1. Read the current `resourceVersion` of the Deployment object:

   ```bash
   kubectl get deploy/web -n recon-lab -o jsonpath='{.metadata.resourceVersion}{"\n"}'
   ```

   Expected (example):

   ```
   184213
   ```

2. Demonstrate optimistic concurrency directly. Fetch the object, then try to `replace` it with a **stale** `resourceVersion`:

   ```bash
   kubectl get deploy/web -n recon-lab -o yaml > /tmp/web.yaml
   # Bump replicas so an unrelated real change happens, invalidating our copy:
   kubectl scale deployment/web -n recon-lab --replicas=3
   # Now try to write back the OLD object (with the OLD resourceVersion):
   kubectl replace -n recon-lab -f /tmp/web.yaml
   ```

   Expected (the write is rejected):

   ```
   Error from server (Conflict): error when replacing "/tmp/web.yaml":
   Operation cannot be fulfilled on deployments.apps "web": the object has been
   modified; please apply your changes to the latest version and try again
   ```

3. Now do it the correct way — `kubectl apply` (three-way merge) or `kubectl edit`, both of which re-read the latest `resourceVersion`:

   ```bash
   kubectl edit deploy/web -n recon-lab   # change something trivial and save; succeeds
   ```

4. Observe the **watch** mechanism that every controller uses instead of polling. Start a raw watch stream from the API server:

   ```bash
   kubectl get pods -n recon-lab -l app=web --watch-only -o wide &
   WATCH_PID=$!
   sleep 1
   kubectl delete pod -n recon-lab "$(kubectl get pods -n recon-lab -l app=web -o name | head -n1)"
   sleep 3
   kill "$WATCH_PID"
   ```

   You will see `DELETED`/`ADDED`/`MODIFIED` lines streamed as the state changes — this is the same `?watch=true` long-poll that informers consume.

5. (If you have direct control-plane access, e.g. `kind`.) List the etcd keyspace to see that Kubernetes objects are just keys under `/registry/`:

   ```bash
   kubectl -n kube-system exec etcd-<control-plane-node> -- sh -c \
     'ETCDCTL_API=3 etcdctl \
       --cacert=/etc/kubernetes/pki/etcd/ca.crt \
       --cert=/etc/kubernetes/pki/etcd/server.crt \
       --key=/etc/kubernetes/pki/etcd/server.key \
       get /registry/deployments/recon-lab/web --keys-only --prefix'
   ```

   Expected:

   ```
   /registry/deployments/recon-lab/web
   ```

**Comprehension checks (Block 3)**

- **Q3.1** In step 2 the write was rejected with a `409 Conflict`. Explain the optimistic-concurrency algorithm the API server used, and why this is safer than last-write-wins for concurrent controllers.
- **Q3.2** Why is it an architectural rule that *only* the API server communicates with etcd? Name two properties this centralization gives you.
- **Q3.3** A controller reconciling 10,000 Pods could poll `LIST` every second, but doesn't. What does it use instead, and what is a `resourceVersion` doing in that stream so the controller can resume after a disconnect?

---

### Exercise 4 — Mapping the control plane: who runs which loop

The reconciliation loops live in named processes. This exercise enumerates them and ties each to a responsibility.

1. List the control-plane pods (on a `kubeadm`/`kind` cluster they run as static Pods in `kube-system`):

   ```bash
   kubectl get pods -n kube-system \
     -l tier=control-plane -o wide 2>/dev/null \
     || kubectl get pods -n kube-system | grep -E 'apiserver|scheduler|controller-manager|etcd'
   ```

   Expected (single control-plane node):

   ```
   etcd-kind-control-plane                      1/1   Running   ...
   kube-apiserver-kind-control-plane            1/1   Running   ...
   kube-controller-manager-kind-control-plane   1/1   Running   ...
   kube-scheduler-kind-control-plane            1/1   Running   ...
   ```

2. The `kube-controller-manager` is a *single binary hosting many controllers*. List them from its help/flags:

   ```bash
   kubectl -n kube-system logs kube-controller-manager-kind-control-plane \
     | grep -iE 'Starting.*controller' | head -n 20
   ```

   Expected (excerpt):

   ```
   ... "Starting controller" controller="deployment"
   ... "Starting controller" controller="replicaset"
   ... "Starting controller" controller="job"
   ... "Starting controller" controller="node-lifecycle"
   ... "Starting controller" controller="garbage-collector"
   ... "Starting controller" controller="endpointslice"
   ...
   ```

3. Observe **leader election**, which guarantees only one active replica of a controller manager reconciles at a time in HA setups:

   ```bash
   kubectl get lease -n kube-system kube-controller-manager \
     -o jsonpath='{"holder="}{.spec.holderIdentity}{"  renew="}{.spec.renewTime}{"\n"}'
   ```

   Expected:

   ```
   holder=kind-control-plane_9f3c...  renew=2026-08-07T12:41:03.482Z
   ```

4. Look at the scheduler as its own control loop. Watch it *bind* a Pod to a node by creating an unschedulable Pod and reading the events:

   ```bash
   kubectl run pin -n recon-lab --image=nginx:1.27-alpine \
     --overrides='{"spec":{"nodeSelector":{"disktype":"nvme-that-does-not-exist"}}}'
   kubectl describe pod/pin -n recon-lab | sed -n '/Events:/,$p'
   ```

   Expected:

   ```
   Events:
     Type     Reason            ... Message
     ----     ------            ... -------
     Warning  FailedScheduling  ... 0/1 nodes are available: 1 node(s) didn't
                                     match Pod's node affinity/selector.
   ```

5. Clean up the pin Pod:

   ```bash
   kubectl delete pod/pin -n recon-lab
   ```

**Comprehension checks (Block 4)**

- **Q4.1** Assign each responsibility to the correct process: (a) persisting cluster state, (b) admission + validation + the REST surface, (c) running the ReplicaSet/Deployment/Job loops, (d) choosing a node for a Pod. 
- **Q4.2** The `kube-controller-manager` hosts dozens of controllers in one process, yet each behaves as an independent loop. What shared machinery (a client-side cache) lets them all watch the API server efficiently without each one polling?
- **Q4.3** In an HA cluster you run 3 `kube-controller-manager` replicas, but only one reconciles at a time. What primitive enforces that, and what object did you read in step 3 to see it?

---

### Exercise 5 — Owner references and cascading garbage collection

Reconciliation includes *cleanup*. The garbage collector is a control loop that deletes objects whose owners are gone, using `ownerReferences`.

1. Inspect the ownership chain Deployment → ReplicaSet → Pod:

   ```bash
   POD=$(kubectl get pods -n recon-lab -l app=web -o name | head -n1)
   kubectl get "$POD" -n recon-lab \
     -o jsonpath='{range .metadata.ownerReferences[*]}{.kind}{"/"}{.name}{"  controller="}{.controller}{"  blockOwnerDeletion="}{.blockOwnerDeletion}{"\n"}{end}'
   ```

   Expected:

   ```
   ReplicaSet/web-6f9c8b7d5c  controller=true  blockOwnerDeletion=true
   ```

2. Delete the Deployment with **foreground** cascading and watch dependents vanish in order:

   ```bash
   kubectl delete deployment/web -n recon-lab --cascade=foreground
   kubectl get rs,pods -n recon-lab -l app=web
   ```

   Expected (eventually):

   ```
   No resources found in recon-lab namespace.
   ```

3. Now demonstrate **orphaning**. Recreate the Deployment (re-apply the manifest from Exercise 1, step 2), then delete it with `--cascade=orphan`:

   ```bash
   # (re-apply the Exercise 1 Deployment first)
   kubectl delete deployment/web -n recon-lab --cascade=orphan
   kubectl get rs,pods -n recon-lab -l app=web
   ```

   Expected — the ReplicaSet and Pods **survive** because the owner reference was removed rather than followed:

   ```
   NAME                             DESIRED   CURRENT   READY   AGE
   replicaset.apps/web-6f9c8b7d5c   3         3         3       30s
   NAME                       READY   STATUS    RESTARTS   AGE
   pod/web-6f9c8b7d5c-....    1/1     Running   0          30s
   ```

4. Clean up the orphans and the namespace:

   ```bash
   kubectl delete rs -n recon-lab -l app=web
   kubectl delete namespace recon-lab
   ```

**Comprehension checks (Block 5)**

- **Q5.1** What does the garbage collector use to know that a Pod should be deleted when its ReplicaSet is deleted? Where is that pointer stored?
- **Q5.2** Contrast `--cascade=foreground`, `--cascade=background`, and `--cascade=orphan`. Which one guarantees no dependent is left, and which leaves dependents adopted by nothing?
- **Q5.3** `blockOwnerDeletion=true` appeared on the Pod. In a foreground delete, what does that flag cause the API server to do before the owner is finally removed?

---

### Exercise 6 — Writing the reconcile logic by hand (thinking like a controller)

You will not compile an operator here, but you will implement the *exact algorithm* a controller runs, in shell, to internalize the `Reconcile(desired, observed) → actions` shape. This mirrors the `controller-runtime` reconcile loop used by CRD operators — directly relevant to platform-engineering CRDs.

1. Recreate the lab and set a target:

   ```bash
   kubectl create namespace recon-lab
   DESIRED=3
   ```

2. Write a one-shot reconcile function. It reads observed state, diffs against desired, and takes exactly the corrective action needed — then returns (a real controller would be re-invoked by its informer on the next event):

   ```bash
   reconcile() {
     local desired="$1"
     local observed
     observed=$(kubectl get pods -n recon-lab -l app=demo \
       --field-selector=status.phase=Running -o name 2>/dev/null | wc -l)
     echo "reconcile: desired=$desired observed=$observed"
     if   [ "$observed" -lt "$desired" ]; then
       for i in $(seq 1 $((desired - observed))); do
         kubectl run "demo-$RANDOM" -n recon-lab --image=nginx:1.27-alpine \
           --labels=app=demo >/dev/null
       done
       echo "  action: scaled up by $((desired - observed))"
     elif [ "$observed" -gt "$desired" ]; then
       kubectl delete pod -n recon-lab \
         "$(kubectl get pods -n recon-lab -l app=demo -o name | head -n1)" >/dev/null
       echo "  action: scaled down by 1"
     else
       echo "  action: none (converged)"
     fi
   }
   ```

3. Run the loop until it reports convergence. Note that it is **idempotent** — re-running when already converged does nothing:

   ```bash
   reconcile "$DESIRED"; sleep 2
   reconcile "$DESIRED"; sleep 2
   reconcile "$DESIRED"
   ```

   Expected (final call):

   ```
   reconcile: desired=3 observed=3
     action: none (converged)
   ```

4. Perturb observed state and reconcile once — confirm it self-corrects with a single, minimal action:

   ```bash
   kubectl delete pod -n recon-lab "$(kubectl get pods -n recon-lab -l app=demo -o name | head -n1)"
   sleep 2
   reconcile "$DESIRED"
   ```

5. Clean up:

   ```bash
   kubectl delete namespace recon-lab
   ```

**Comprehension checks (Block 6)**

- **Q6.1** Your `reconcile` reads observed state *fresh* every call and computes the delta, rather than remembering "I already created 3 Pods." Which two controller properties does that give you — and why does it survive the function being called twice in a row?
- **Q6.2** A real operator does not busy-loop calling `reconcile` on a timer. What triggers `Reconcile()` in `controller-runtime`, and what is the *resync period* fallback for when no event arrives?
- **Q6.3** Your loop takes only the *minimal* action to close the gap (add N, or delete 1). Why is "compute the diff and apply the smallest change" preferable to "delete everything and recreate to the desired count"?

---

## Answers

<details>
<summary>Click to reveal answers</summary>

### Block 1

**Q1.1** The **ReplicaSet controller** (inside `kube-controller-manager`) recreated it. It continuously compares its `spec.replicas` (desired = 3) against the count of Pods matching its `selector` that it observes via its informer cache. When the observed count dropped to 2, the diff was `+1`, so it issued a `CREATE` Pod to the API server. Nothing "remembered" the deleted Pod — the loop simply re-measured the level and closed the gap.

**Q1.2** It is *declarative* because you submit the **desired end state** (`replicas: 3`, a Pod template) and the system figures out the steps to reach and maintain it; you never enumerate operations. The *imperative* equivalent of the self-heal would have been you personally noticing the Pod died and running `kubectl run ...` (or `docker run`) yourself, once, with no ongoing guarantee. Declarative APIs are continuously reconciled; imperative commands are one-shot.

**Q1.3** (1) The **Deployment controller** owns the *Deployment* object and manages **ReplicaSets** to implement rollouts/rollbacks (it creates a new ReplicaSet on template change and scales old/new to perform the rollout). (2) The **ReplicaSet controller** owns a *ReplicaSet* and manages **Pods** to hold the replica count. Deployment → ReplicaSet → Pods is a chain of nested reconciliation loops.

### Block 2

**Q2.1** In an edge-triggered system the controller reacts to the *transition event* ("+1 replica"), so if it processed "scale to 5" and then crashed before "scale to 4," it would settle at 5 and stay wrong until another event arrived — the missed event is lost forever. Level-triggered controllers re-read the **current desired level** (`replicas: 4`) directly from state on their next reconcile, so a missed or reordered event is irrelevant: they converge to whatever the level currently is. This is the core reason Kubernetes controllers are self-healing and tolerant of restarts, dropped watches, and reordering.

**Q2.2** Because the Deployment controller reconciles the **final `spec`**, not the sequence of edits. While paused, all three `spec` mutations accumulated on the object; when you resumed, the controller compared the *current* template (image `1.27-alpine`, the new resources) against running Pods and created **one** new ReplicaSet for that final level. `1.26-alpine` was an intermediate level that was overwritten before any reconcile acted on it, so no Pod ever ran it.

**Q2.3** The event (delivered via a watch/informer) is only a **hint that "something changed, re-reconcile now"** — an efficiency mechanism so controllers don't poll. The event's *payload* is not trusted as the source of truth; on wake-up the controller re-reads the full current level and diffs it. So Kubernetes is *event-driven for latency* but *level-triggered for correctness*: losing an event costs you latency (until the periodic resync), never correctness.

### Block 3

**Q3.1** Every object carries a `resourceVersion` (an opaque etcd revision). On a `replace`/update, the API server performs a **compare-and-swap**: the write only commits if the `resourceVersion` you supplied still matches what etcd holds. Your `/tmp/web.yaml` carried the pre-scale version; the intervening `kubectl scale` bumped etcd's version, so the CAS failed and you got `409 Conflict`. This is safer than last-write-wins because two controllers editing the same object concurrently cannot silently clobber each other — the loser is told to re-read the latest state and retry, preserving the other's change.

**Q3.2** Centralizing all etcd access behind the API server gives you: (1) a **single point of enforcement** for authentication, authorization (RBAC), admission control, validation, defaulting, and versioning/conversion — no client can bypass policy by writing raw keys; and (2) a **single, consistent watch/caching surface and storage abstraction** — clients speak one stable REST API regardless of the storage backend, and etcd's client footprint (and its sensitive TLS credentials) stays confined to one component. (It also protects etcd, which is not designed for thousands of direct clients.)

**Q3.3** It uses a **watch** (`GET ...?watch=true`, an HTTP long-poll / streaming connection), consumed by an **informer** that maintains a local cache. Each watch event carries the object's `resourceVersion`; the informer tracks the latest one it has seen, so after a disconnect it can re-establish the watch **from that `resourceVersion`** and receive only subsequent changes (falling back to a full `LIST`+re-watch if the version has been compacted — the "too old resource version" case). This is `O(changes)`, not `O(objects)` per second.

### Block 4

**Q4.1** (a) persisting cluster state → **etcd**; (b) admission + validation + REST surface → **kube-apiserver**; (c) ReplicaSet/Deployment/Job loops → **kube-controller-manager**; (d) choosing a node for a Pod → **kube-scheduler** (which sets `spec.nodeName` / creates a Binding; the node's **kubelet** then actually runs the Pod). On a cloud provider, node/route/LB lifecycle moves to the **cloud-controller-manager**.

**Q4.2** Each controller is built on the **informer / shared-informer + lister** machinery from `client-go`. A `SharedInformerFactory` opens **one** watch per resource type and maintains a single in-memory **cache (indexer/store)** that all controllers for that type share; controllers register event handlers that enqueue keys into a **workqueue**, and their reconcile reads from the local cache (the *lister*) rather than hitting the API server. So dozens of controllers watch efficiently through shared, deduplicated watches instead of independent polling.

**Q4.3** **Leader election**, implemented via a `Lease` object (a coordination lock in `kube-system`). Only the replica currently holding and renewing the lease runs its controllers; the others stand by and take over if the lease expires. You read the `kube-controller-manager` **Lease** (`.spec.holderIdentity` / `.spec.renewTime`) in step 3.

### Block 5

**Q5.1** It uses the dependent's **`metadata.ownerReferences`** — each Pod carries a reference (kind, name, UID, `controller: true`) pointing at its owning ReplicaSet, and the ReplicaSet in turn references its Deployment. The garbage collector watches for owners whose UID no longer exists and deletes the dependents pointing at them. The pointer lives on the **dependent (child)** object, not the owner.

**Q5.2**
- `--cascade=foreground`: the owner is marked with a `foregroundDeletion` finalizer and stays visible (`deletionTimestamp` set) until **all dependents are deleted first**, then the owner is removed. Guarantees nothing is left behind, and enforces order.
- `--cascade=background` (the default): the owner is deleted immediately and the garbage collector deletes dependents **asynchronously** afterward. Also leaves nothing behind, but without ordering guarantees.
- `--cascade=orphan`: the owner is deleted but its `ownerReferences` are **stripped from the dependents**, so the children survive **adopted by nothing** (until, e.g., a matching new controller adopts them).

**Q5.3** `blockOwnerDeletion=true` tells the API server that this dependent must be *fully deleted before* the owner's deletion can complete. In a foreground delete it causes the owner to remain in a "deletion in progress" state (held by the `foregroundDeletion` finalizer) until every such blocking dependent is gone; only then is the finalizer cleared and the owner actually removed from etcd.

### Block 6

**Q6.1** It gives you **idempotency** (running it when already converged is a no-op) and **statelessness / level-triggering** (correctness depends only on current observed vs. desired state, not on any remembered history). Because it re-measures observed state every call and acts on the *diff*, calling it twice in a row is safe: the first call closes the gap, and the second measures `observed == desired` and does nothing. A controller that instead remembered "I already created 3" would double-create on a restart or a duplicate invocation.

**Q6.2** In `controller-runtime`, `Reconcile()` is triggered by **watch events** on the primary resource and any resources it `Owns`/`Watches`, delivered through informers into a rate-limited **workqueue** (with dedup and exponential backoff on error via a returned `RequeueAfter`/error). The fallback for "no event arrived" is the **resync period** — the informer periodically re-delivers all cached objects (a full resync), forcing a reconcile so drift that produced no event is still corrected. A reconcile can also explicitly requeue itself.

**Q6.3** Applying the **minimal diff** is idempotent, convergent, and minimally disruptive: it doesn't churn healthy resources, doesn't cause unnecessary Pod restarts / dropped connections / rescheduling, and reaches steady state without oscillating. "Delete everything and recreate" would destroy currently-serving Pods on every reconcile pass, could never reach a quiet steady state (each pass is a large action), and would amplify any transient read error into a full outage. Reconcilers should compute the smallest set of actions that moves observed toward desired, and do nothing once converged.

</details>

---

### Sources

- Kubernetes Documentation — *Concepts: Controllers.* https://kubernetes.io/docs/concepts/architecture/controller/
- Kubernetes Documentation — *Cluster Architecture / Control Plane Components.* https://kubernetes.io/docs/concepts/overview/components/
- Kubernetes Documentation — *Cluster Architecture: The Kubernetes API.* https://kubernetes.io/docs/concepts/overview/kubernetes-api/
- Kubernetes Documentation — *Efficient detection of changes (watches, `resourceVersion`).* https://kubernetes.io/docs/reference/using-api/api-concepts/
- Kubernetes Documentation — *Owners and Dependents / Garbage Collection.* https://kubernetes.io/docs/concepts/architecture/garbage-collection/ and https://kubernetes.io/docs/concepts/overview/working-with-objects/owners-dependents/
- Kubernetes Documentation — *Coordinated Leader Election / Leases.* https://kubernetes.io/docs/concepts/architecture/leases/
- Kubernetes Documentation — *Operator pattern.* https://kubernetes.io/docs/concepts/extend-kubernetes/operator/
- CNCF Curriculum — *Cloud Native Platform Engineering Associate (CNPA).* https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf