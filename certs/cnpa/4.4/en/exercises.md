# Kubernetes Operator Pattern for Integration and Automation — Guided Exercises

> **Topic 4.4 · CNPA (exam version 2025-04-01) · Exam weight: 3.0**
>
> These exercises take you from the *reconciliation loop* that already powers every built-in Kubernetes controller, through *extending the API* with CRDs, *writing a working reconciler by hand*, *scaffolding a production operator* with the Operator SDK, and finally *packaging and delivering* it with OLM. By the end you will be able to explain — and demonstrate — why the Operator pattern is the canonical way to encode operational knowledge and automate integrations on Kubernetes.

## What you need

- A throw-away cluster. `kind` is assumed throughout (`kind create cluster --name op-lab`), but any cluster where you are `cluster-admin` works (minikube, k3d, a scratch namespace on a shared cluster).
- `kubectl` v1.29+.
- For Exercises 4 and 6 only: `operator-sdk` v1.34+ and a Go 1.22+ toolchain. If you cannot install them, you can still read every step — the generated code and expected output are shown inline.
- Two terminals side by side are handy: one to *watch*, one to *act*.

Create the cluster now:

```bash
kind create cluster --name op-lab
kubectl cluster-info --context kind-op-lab
```

Expected:

```
Kubernetes control plane is running at https://127.0.0.1:43127
CoreDNS is running at https://127.0.0.1:43127/api/v1/namespaces/kube-system/services/kube-dns:dns/proxy
```

---

## Exercise 1 — Reconciliation is not new: watch a built-in controller heal drift

The Operator pattern generalizes something Kubernetes already does everywhere. Before writing an operator, feel the loop that every controller runs: *observe desired state → observe actual state → act to close the gap → repeat.*

**Step 1.** In terminal A, start watching pods:

```bash
kubectl get pods -l app=nginx -w
```

**Step 2.** In terminal B, declare desired state — 3 replicas:

```bash
kubectl create deployment nginx --image=nginx:1.27-alpine --replicas=3
```

Terminal A shows three pods reaching `Running`:

```
NAME                     READY   STATUS    RESTARTS   AGE
nginx-6b9f4c8d7c-4wq2z   0/1     Pending   0          0s
nginx-6b9f4c8d7c-4wq2z   1/1     Running   0          3s
nginx-6b9f4c8d7c-hg7pn   1/1     Running   0          3s
nginx-6b9f4c8d7c-tt8kx   1/1     Running   0          3s
```

**Step 3.** Now *inject drift* — kill one pod and watch the controller notice and repair:

```bash
kubectl delete pod -l app=nginx --field-selector=status.phase=Running --grace-period=0 --force $(kubectl get pod -l app=nginx -o name | head -1 | cut -d/ -f2)
```

Terminal A: the deleted pod goes `Terminating` and a **new** pod is created within a second — you never told it to; the ReplicaSet controller reconciled the gap between *desired 3* and *actual 2*.

**Step 4.** Inspect who did the work and what triggered it:

```bash
kubectl get replicaset -l app=nginx
kubectl get events --sort-by=.lastTimestamp | grep -i replicaset | tail -3
```

Expected (abridged):

```
NAME               DESIRED   CURRENT   READY   AGE
nginx-6b9f4c8d7c   3         3         3       90s

... ReplicaSet nginx-6b9f4c8d7c   SuccessfulCreate   Created pod: nginx-6b9f4c8d7c-p4l9d
```

> **Check your understanding — 1**
> 1. What is the *desired state* here, where is it stored, and what is the *actual state* being compared against it?
> 2. The controller repaired the drift even though nothing "watched for a delete event" on your behalf. Explain the difference between **level-based** and **edge-based** reconciliation, and say which one this is.
> 3. Kubernetes docs describe operators as controllers that follow the same principle. In one sentence, what does an operator add on top of what the ReplicaSet controller already does?

---

## Exercise 2 — Extend the API: CustomResourceDefinitions and Custom Resources

An operator needs a *vocabulary* — a new resource kind the API server understands. That is what a CRD provides. In this exercise you teach the API server a brand-new `Website` kind, with schema validation and a status subresource, **before** any controller exists.

**Step 1.** Apply the CRD. Note the group, versions, structural schema, `subresources.status`, and printer columns:

```yaml
# website-crd.yaml
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: websites.examples.cnpa.io
spec:
  group: examples.cnpa.io
  scope: Namespaced
  names:
    plural: websites
    singular: website
    kind: Website
    shortNames: [web]
  versions:
    - name: v1alpha1
      served: true
      storage: true
      subresources:
        status: {}
      schema:
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: object
              required: [replicas]
              properties:
                gitRepo:
                  type: string
                replicas:
                  type: integer
                  minimum: 1
                  maximum: 10
            status:
              type: object
              properties:
                observedReplicas:
                  type: integer
                phase:
                  type: string
      additionalPrinterColumns:
        - name: Desired
          type: integer
          jsonPath: .spec.replicas
        - name: Observed
          type: integer
          jsonPath: .status.observedReplicas
        - name: Phase
          type: string
          jsonPath: .status.phase
```

```bash
kubectl apply -f website-crd.yaml
kubectl get crd websites.examples.cnpa.io
kubectl api-resources | grep websites
```

Expected:

```
customresourcedefinition.apiextensions.k8s.io/websites.examples.cnpa.io created
NAME                        CREATED AT
websites.examples.cnpa.io   2026-08-07T12:00:11Z
websites   web   examples.cnpa.io/v1alpha1   true   Website
```

**Step 2.** Prove the schema is *enforced by the API server*, not by a controller. Try an invalid Custom Resource:

```bash
kubectl apply -f - <<'EOF'
apiVersion: examples.cnpa.io/v1alpha1
kind: Website
metadata:
  name: broken
spec:
  replicas: 99
EOF
```

Expected — rejected at admission, no controller involved:

```
The Website "broken" is invalid: spec.replicas: Invalid value: 99: spec.replicas in body should be less than or equal to 10
```

**Step 3.** Create a valid Custom Resource and inspect how it is stored:

```bash
kubectl apply -f - <<'EOF'
apiVersion: examples.cnpa.io/v1alpha1
kind: Website
metadata:
  name: hello
spec:
  gitRepo: https://github.com/example/hello
  replicas: 3
EOF

kubectl get websites
kubectl get website hello -o yaml | grep -A2 'managedFields\|uid:\|resourceVersion:' | head
```

Expected:

```
website.examples.cnpa.io/hello created

NAME    DESIRED   OBSERVED   PHASE
hello   3         <none>     <none>
```

Notice **`OBSERVED`** and **`PHASE`** are empty: the desired state is recorded, but nothing is acting on it and nothing is reporting status. A CRD with no controller is an inert data structure.

> **Check your understanding — 2**
> 1. Distinguish precisely between a **CRD** and a **CR (Custom Resource)**. Which one is cluster-scoped metadata, and which is namespaced data?
> 2. The invalid `replicas: 99` was rejected *before* any operator ran. Which component enforced it, and why does putting validation in the CRD's OpenAPI v3 schema (a **structural schema**) matter for security and correctness?
> 3. Why did we declare `subresources.status: {}`? What changes about how `spec` and `status` can be written once a status subresource exists?

---

## Exercise 3 — Write a reconciler by hand

To internalize the loop, you will now *be* the controller. This 20-line level-based reconciler watches every `Website` CR and guarantees a matching `Deployment` exists with the requested replica count, then writes back status. It is deliberately crude — no informers, no work queue — but the control logic is exactly what a real operator does.

**Step 1.** Save the reconciler:

```bash
cat > reconcile-websites.sh <<'EOF'
#!/usr/bin/env bash
# A level-based reconciler for the Website CRD. It re-reads the full
# desired state every cycle (level, not edge) and is idempotent (apply).
set -euo pipefail
echo "website-operator: starting reconcile loop"
while true; do
  # 1. OBSERVE desired state: every Website CR in every namespace.
  for pair in $(kubectl get websites -A \
      -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name} {end}'); do
    ns="${pair%/*}"; name="${pair#*/}"
    replicas=$(kubectl -n "$ns" get website "$name" -o jsonpath='{.spec.replicas}')

    # 2. ACT: converge actual state toward desired state. apply == idempotent.
    kubectl -n "$ns" apply -f - >/dev/null <<MANIFEST
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${name}
  labels: { app.kubernetes.io/managed-by: website-operator }
spec:
  replicas: ${replicas}
  selector: { matchLabels: { app: ${name} } }
  template:
    metadata: { labels: { app: ${name} } }
    spec:
      containers:
        - name: web
          image: nginx:1.27-alpine
          ports: [ { containerPort: 80 } ]
MANIFEST

    # 3. REPORT: write observed state back onto the CR's status subresource.
    ready=$(kubectl -n "$ns" get deploy "$name" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
    kubectl -n "$ns" patch website "$name" --subresource=status --type=merge \
      -p "{\"status\":{\"observedReplicas\":${ready:-0},\"phase\":\"Reconciled\"}}" >/dev/null
    echo "reconciled ${ns}/${name}: desired=${replicas} ready=${ready:-0}"
  done
  sleep 5
done
EOF
chmod +x reconcile-websites.sh
```

**Step 2.** Run it in terminal A:

```bash
./reconcile-websites.sh
```

Expected:

```
website-operator: starting reconcile loop
reconciled default/hello: desired=3 ready=0
reconciled default/hello: desired=3 ready=3
```

**Step 3.** In terminal B, confirm the CR now reports status, and that the managed Deployment exists:

```bash
kubectl get websites
kubectl get deploy hello
```

Expected:

```
NAME    DESIRED   OBSERVED   PHASE
hello   3         3          Reconciled

NAME    READY   UP-TO-DATE   AVAILABLE   AGE
hello   3/3     3            3           20s
```

**Step 4.** Prove it is a *closed loop*. Inject drift two ways and watch it self-heal:

```bash
# (a) mutate the managed resource directly
kubectl scale deployment hello --replicas=1
# (b) change desired state on the CR
kubectl patch website hello --type=merge -p '{"spec":{"replicas":5}}'
```

Within one cycle, terminal A converges the Deployment back to the CR's `spec.replicas`:

```
reconciled default/hello: desired=5 ready=1
reconciled default/hello: desired=5 ready=5
```

**Step 5.** Stop the loop (Ctrl-C), then re-run it. Nothing changes — the same inputs produce the same result. That is *idempotency*.

> **Check your understanding — 3**
> 1. This script re-reads *all* `Website` CRs every 5 seconds instead of subscribing to change events. Name one robustness advantage this level-based design has over a purely edge-triggered one (hint: what happens if the controller was down when the CR changed?).
> 2. Why is `kubectl apply` — rather than `kubectl create` — essential to making `reconcile()` safe to run on every cycle?
> 3. In step 4 you edited the Deployment directly (`kubectl scale`) and the operator undid it. Restate, as a principle, why humans should treat operator-managed resources as read-only.
> 4. Real operators replace the `for … sleep` loop with an **informer + work queue** feeding a `Reconcile(request)` function. What two problems does that machinery solve that our bash loop does not (think: 10,000 CRs; API server load)?

---

## Exercise 4 — Scaffold a production operator with the Operator SDK

Now meet the real thing. The Operator SDK (and Kubebuilder underneath it) generate a project built on **controller-runtime**: a `Manager` that owns shared **informers/caches**, a **work queue**, and your `Reconcile` method. You will scaffold a `Memcached` operator and read the moving parts. *(If you lack Go/operator-sdk, read along — the generated artifacts are shown.)*

**Step 1.** Initialize the project and create an API + controller:

```bash
mkdir memcached-operator && cd memcached-operator
operator-sdk init --domain example.com --repo github.com/example/memcached-operator
operator-sdk create api --group cache --version v1alpha1 --kind Memcached --resource --controller
```

Generated layout (abridged):

```
├── api/v1alpha1/memcached_types.go     # Spec/Status structs -> the CRD schema
├── internal/controller/
│   └── memcached_controller.go         # your Reconcile() lives here
├── config/crd/                         # generated CRD manifests
├── config/rbac/                        # generated RBAC (from // +kubebuilder markers)
├── cmd/main.go                         # wires up the Manager
└── Makefile
```

**Step 2.** Read the desired/observed contract in `api/v1alpha1/memcached_types.go`. Set a `Size` field on the spec:

```go
// MemcachedSpec defines the desired state of Memcached
type MemcachedSpec struct {
    // +kubebuilder:validation:Minimum=1
    // +kubebuilder:validation:Maximum=10
    Size int32 `json:"size"`
}

// MemcachedStatus defines the observed state of Memcached
type MemcachedStatus struct {
    Conditions []metav1.Condition `json:"conditions,omitempty"`
}
```

**Step 3.** Read the heart of the operator — `internal/controller/memcached_controller.go`. The signature and the manager wiring are the two things to understand:

```go
func (r *MemcachedReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
    // 1. OBSERVE desired state (the CR). NotFound => it was deleted; stop.
    memcached := &cachev1alpha1.Memcached{}
    if err := r.Get(ctx, req.NamespacedName, memcached); err != nil {
        return ctrl.Result{}, client.IgnoreNotFound(err)
    }

    // 2. OBSERVE actual state (the managed Deployment).
    found := &appsv1.Deployment{}
    err := r.Get(ctx, types.NamespacedName{Name: memcached.Name, Namespace: memcached.Namespace}, found)
    if apierrors.IsNotFound(err) {
        // 3. ACT: create it, stamping an OwnerReference for garbage collection.
        dep := r.deploymentForMemcached(memcached)
        ctrl.SetControllerReference(memcached, dep, r.Scheme)
        return ctrl.Result{}, r.Create(ctx, dep)
    }

    // 4. ACT: converge — reconcile replica count toward desired Size.
    if *found.Spec.Replicas != memcached.Spec.Size {
        found.Spec.Replicas = &memcached.Spec.Size
        return ctrl.Result{Requeue: true}, r.Update(ctx, found)
    }
    return ctrl.Result{}, nil
}

// SetupWithManager registers the controller: watch Memcached, own Deployments.
func (r *MemcachedReconciler) SetupWithManager(mgr ctrl.Manager) error {
    return ctrl.NewControllerManagedBy(mgr).
        For(&cachev1alpha1.Memcached{}).   // primary resource -> enqueues req
        Owns(&appsv1.Deployment{}).        // owned resource -> re-enqueues owner on change
        Complete(r)
}
```

**Step 4.** Note the RBAC markers just above `Reconcile` — they *generate* the ServiceAccount permissions the operator needs:

```go
// +kubebuilder:rbac:groups=cache.example.com,resources=memcacheds,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=cache.example.com,resources=memcacheds/status,verbs=get;update;patch
// +kubebuilder:rbac:groups=apps,resources=deployments,verbs=get;list;watch;create;update;patch;delete
```

**Step 5.** Install the CRD and run the controller against your cluster (out-of-cluster mode):

```bash
make install    # applies config/crd to the cluster
make run        # runs the manager locally against your kubeconfig
```

Expected (abridged manager log):

```
INFO  setup       starting manager
INFO  controller-runtime.metrics  Serving metrics server  {"bindAddress": ":8080"}
INFO  Starting EventSource  {"controller": "memcached", "source": "kind source: *v1alpha1.Memcached"}
INFO  Starting Controller   {"controller": "memcached"}
INFO  Starting workers      {"controller": "memcached", "worker count": 1}
```

Apply a CR in another terminal and watch a Deployment appear, owned by the CR:

```bash
kubectl apply -f config/samples/cache_v1alpha1_memcached.yaml
kubectl get deploy,memcached
kubectl get deploy memcached-sample -o jsonpath='{.metadata.ownerReferences[0].kind}{"\n"}'   # -> Memcached
```

> **Check your understanding — 4**
> 1. `Reconcile` receives only a `ctrl.Request` (a namespace/name), *not* the object or the event that triggered it. Why is that deliberate, and how does it keep the controller level-based?
> 2. In `SetupWithManager`, what is the difference between `For(&Memcached{})` and `Owns(&Deployment{})`? When someone deletes the managed Deployment, which line causes `Reconcile` to run again?
> 3. `ctrl.SetControllerReference` stamps an OwnerReference. What does that buy you at *delete* time, and which built-in controller acts on it?
> 4. The manager holds a shared **cache** populated by **informers**. Why does the reconciler call `r.Get` (cache read) constantly without hammering the API server, and what stale-read hazard must you still guard against?

---

## Exercise 5 — Finalizers, ownership, and status: the lifecycle contract

Operators that integrate with external systems (a cloud DB, a DNS zone, a message broker) must clean up when their CR is deleted — you cannot rely on Kubernetes garbage collection for resources it does not manage. **Finalizers** give you that hook. Owner references give you the *in-cluster* cleanup for free.

**Step 1.** Observe automatic cleanup via owner references. Reuse the `Website` from Exercise 3 (make sure the Exercise 3 loop is stopped). Add an owner reference from the CR to its Deployment, then delete the CR:

```bash
UID=$(kubectl get website hello -o jsonpath='{.metadata.uid}')
kubectl patch deployment hello --type=merge -p "{\"metadata\":{\"ownerReferences\":[{\"apiVersion\":\"examples.cnpa.io/v1alpha1\",\"kind\":\"Website\",\"name\":\"hello\",\"uid\":\"${UID}\",\"controller\":true,\"blockOwnerDeletion\":true}]}}"

kubectl delete website hello
kubectl get deploy hello    # gone — the garbage collector cascaded the delete
```

Expected:

```
website.examples.cnpa.io "hello" deleted
Error from server (NotFound): deployments.apps "hello" not found
```

**Step 2.** Now demonstrate a **finalizer** blocking deletion until external cleanup runs. Recreate the CR and add a finalizer:

```bash
kubectl apply -f - <<'EOF'
apiVersion: examples.cnpa.io/v1alpha1
kind: Website
metadata:
  name: hello
  finalizers:
    - websites.examples.cnpa.io/cleanup-dns
spec:
  replicas: 2
EOF

kubectl delete website hello --timeout=5s
```

Expected — the delete *hangs*; the object is not gone, it is marked for deletion:

```
error: timed out waiting for the condition on websites/hello
```

```bash
kubectl get website hello -o jsonpath='{.metadata.deletionTimestamp}{"\n"}{.metadata.finalizers}{"\n"}'
```

Expected:

```
2026-08-07T12:31:44Z
["websites.examples.cnpa.io/cleanup-dns"]
```

The object is in *terminating* state. A real operator's `Reconcile` would now see `deletionTimestamp != nil`, perform the external cleanup (delete the DNS record), and only then remove its finalizer.

**Step 3.** Simulate the operator finishing cleanup by removing the finalizer. The object disappears immediately:

```bash
kubectl patch website hello --type=json -p='[{"op":"remove","path":"/metadata/finalizers"}]'
kubectl get website hello    # NotFound
```

> **Check your understanding — 5**
> 1. In step 1 the Deployment was deleted for you when the CR was deleted; in step 2 the CR itself refused to delete. Explain the different mechanisms — **ownerReference-driven garbage collection** vs **finalizer** — and when each is the right tool.
> 2. What exactly does the API server do when you `delete` an object that still carries a finalizer? What field appears, and what does the object's continued existence let the controller do?
> 3. A buggy operator crashes permanently while a CR holds its finalizer. From the user's point of view, what happens to `kubectl delete`, and what is the (dangerous) manual escape hatch?
> 4. Why should status be written via the `/status` subresource and reported with **Conditions** rather than the operator overwriting `spec`?

---

## Exercise 6 — Deliver the operator: OLM, OperatorHub, and capability levels

An operator is software with a lifecycle of its own — it must be installed, upgraded, and have its RBAC and CRDs managed. The **Operator Lifecycle Manager (OLM)** does this declaratively, and **OperatorHub** is the catalog. This exercise installs OLM and inspects how an operator is packaged and subscribed.

**Step 1.** Install OLM into the cluster:

```bash
operator-sdk olm install
kubectl get pods -n olm
```

Expected:

```
NAME                                READY   STATUS    RESTARTS   AGE
catalog-operator-6b8c7f9d5-xk2mn    1/1     Running   0          40s
olm-operator-77d9c8f4b6-9lqtz       1/1     Running   0          40s
operatorhubio-catalog-abcde         1/1     Running   0          35s
packageserver-6c5b8f7d9c-2pq4r      1/1     Running   0          30s
```

**Step 2.** Browse the catalog exactly as OperatorHub does, then subscribe to an operator declaratively (here, the community `grafana-operator`):

```bash
kubectl get packagemanifests -n olm | head
```

```yaml
# subscription.yaml — declarative install intent
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: grafana-operator
  namespace: operators
spec:
  channel: v5
  name: grafana-operator
  source: operatorhubio-catalog
  sourceNamespace: olm
  installPlanApproval: Manual   # require human approval before each upgrade
```

```bash
kubectl apply -f subscription.yaml
kubectl get installplan,csv -n operators
```

Expected — an `InstallPlan` awaits approval; the operator is delivered as a **ClusterServiceVersion (CSV)**:

```
NAME                                            CSV                       APPROVAL   APPROVED
installplan.../install-7fk2p                    grafana-operator.v5.x.y   Manual     false

NAME                                            DISPLAY            VERSION   PHASE
clusterserviceversion.../grafana-operator...    Grafana Operator   5.x.y     Installing
```

Approve it:

```bash
kubectl patch installplan install-7fk2p -n operators --type=merge -p '{"spec":{"approved":true}}'
kubectl get csv -n operators   # PHASE -> Succeeded
```

**Step 3.** Read the operator's declared **capability level** from its CSV — the industry maturity model from Basic Install to Auto Pilot:

```bash
kubectl get csv -n operators -o jsonpath='{.items[0].metadata.annotations.capabilities}{"\n"}'
```

Expected:

```
Deep Insights
```

The five levels, in order, are: **1 Basic Install → 2 Seamless Upgrades → 3 Full Lifecycle → 4 Deep Insights → 5 Auto Pilot.**

> **Check your understanding — 6**
> 1. Without OLM you install an operator by `kubectl apply`-ing its manifests. Name three lifecycle concerns OLM manages that a raw `kubectl apply` does not.
> 2. What is a **ClusterServiceVersion (CSV)**, and what is a **Subscription**? Which one expresses *intent to track a channel*, and which one *is the running operator's descriptor*?
> 3. You set `installPlanApproval: Manual`. Explain the risk this mitigates on a production cluster, and what changes with `Automatic`.
> 4. Map each capability level to a concrete behavior: which level means "installs the operand," which means "handles upgrades of the operand," and which means "metrics/alerts and horizontal/vertical auto-scaling of the operand"?

---

## Clean up

```bash
kind delete cluster --name op-lab
```

---

## Sources

- Operator pattern — https://kubernetes.io/docs/concepts/extend-kubernetes/operator/
- Custom Resources & CRDs — https://kubernetes.io/docs/concepts/extend-kubernetes/api-extension/custom-resources/
- Extend the API with CustomResourceDefinitions — https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/
- Controllers & the reconciliation loop — https://kubernetes.io/docs/concepts/architecture/controller/
- Owner references & garbage collection — https://kubernetes.io/docs/concepts/architecture/garbage-collection/
- Finalizers — https://kubernetes.io/docs/concepts/overview/working-with-objects/finalizers/
- Operator SDK (Go tutorial) — https://sdk.operatorframework.io/docs/building-operators/golang/tutorial/
- Kubebuilder book (controller-runtime, informers, cache) — https://book.kubebuilder.io/
- Operator Lifecycle Manager — https://olm.operatorframework.io/
- Operator Capability Levels — https://operatorframework.io/operator-capabilities/

---

<details>
<summary><strong>Answer key</strong> (open only after attempting the exercises)</summary>

### Exercise 1
1. **Desired state** = the Deployment's `spec.replicas: 3`, persisted by the API server in etcd. **Actual state** = the set of Pods that currently exist and match the ReplicaSet's selector, discovered by the controller listing/watching Pods. Reconciliation continuously drives actual toward desired.
2. **Edge-based** reacts only to the *transition event* ("a pod was deleted"); if the controller misses the event, the drift is never repaired. **Level-based** repeatedly compares full desired vs full actual state and acts on the *difference*, so a missed event is self-correcting on the next pass. Kubernetes controllers — including the ReplicaSet controller here — are level-based (they use watches as an optimization to know *when* to re-check, but the decision is always made by re-reading current state). This is the case here.
3. An operator applies the same reconcile loop to a **CustomResource that encodes application-/domain-specific operational knowledge** (e.g., "provision and back up a database"), whereas the ReplicaSet controller only knows the built-in `apps/v1` types.

### Exercise 2
1. A **CRD** is a single, **cluster-scoped** object that *registers a new API type* (kind, group, version, schema) with the API server — it is metadata about the API. A **CR** is an *instance* of that type — ordinary API data, here **namespaced** (`scope: Namespaced`). One CRD; many CRs.
2. The **kube-apiserver** enforced it during admission, using the CRD's OpenAPI v3 **structural schema**. Putting validation there means every write is validated centrally, before persistence, regardless of which client wrote it — no operator needs to be running, and a broken/absent controller cannot let malformed objects into etcd. Structural schemas are also required for features like pruning of unknown fields, protecting against injection of unexpected data.
3. `subresources.status: {}` splits the object into two independently-writable endpoints: clients write `spec` via the main resource; the controller writes `status` via `/status`. This prevents the controller from accidentally clobbering user-set `spec` (and vice versa), gives each its own update path, and lets `metadata.generation` track only spec changes so the controller can tell "the user changed the desired state" from "I updated status."

### Exercise 3
1. If the controller is down when a `Website` is created or changed, an edge-based design would miss that event and never act. The level-based loop re-reads *all* CRs on the next cycle and reconciles them regardless of when they changed — recovery is automatic after any downtime, restart, or missed event.
2. `create` fails if the object already exists, so it is only correct on the very first cycle; every subsequent cycle would error. `apply` is **declarative and idempotent** — it creates if absent and converges if present — which is exactly the contract a reconcile function needs so it can run safely on every pass.
3. Operator-managed resources have a single source of truth: the CR's `spec`. Any manual edit to a managed resource is *drift* that the operator will detect and revert, so hand-editing is at best futile and at worst destabilizing. Change the CR, not the managed object.
4. (a) **Efficiency/scale** — polling every CR every 5s does N full `LIST`s and does needless work when nothing changed; an **informer** maintains a local cache fed by a single watch, and a **work queue** enqueues only the keys that actually changed, with dedup and rate-limiting. (b) **Correctness under concurrency/failure** — the work queue provides ordered, deduplicated, rate-limited, retry-with-backoff processing per object key, which a naive loop cannot.

### Exercise 4
1. Passing only a name/namespace forces `Reconcile` to **re-fetch current state** (`r.Get`) every time rather than trusting the triggering event's payload, which may be stale or one of several coalesced events. This makes the controller level-based and idempotent: the same request can fire many times and always converges to current desired state.
2. `For(&Memcached{})` declares the **primary resource** — a change to a `Memcached` enqueues a reconcile request for that object. `Owns(&Deployment{})` sets up a watch on Deployments and maps any owned Deployment's change back to its **owner** `Memcached`, enqueuing the owner. Deleting the managed Deployment triggers reconcile via the `Owns(...)` line.
3. It records the CR as the Deployment's **owner** (with `controller: true`). At delete time, when the owner `Memcached` is removed, the **garbage collector** (in kube-controller-manager) cascades the delete to owned objects automatically — you get cleanup of in-cluster resources for free. The garbage collector acts on it.
4. Reads go to the manager's in-memory **cache**, kept fresh by informers via a single long-lived watch per type, instead of a request per read — so `r.Get`/`r.List` are cheap and do not scale API-server load with reconcile frequency. The hazard is **cache staleness**: a read may lag a very recent write, so updates must be written optimistically (with `resourceVersion`) and conflicts (`409`) handled by requeue/retry rather than assuming the cache is authoritative.

### Exercise 5
1. **OwnerReference GC** cleans up *in-cluster* resources the operator created: set the owner once, and Kubernetes cascades the delete — no operator code needed at delete time. A **finalizer** is for cleanup Kubernetes *cannot* do itself — external side effects (cloud resources, DNS records, external DB users). Use owner refs for owned K8s objects; use finalizers when deletion must run custom logic before the object may vanish.
2. The API server does **not** delete the object; it sets `metadata.deletionTimestamp` and leaves the object present ("terminating") as long as any finalizer remains in `metadata.finalizers`. That grace window lets the controller observe `deletionTimestamp != nil`, perform external cleanup, and then remove its finalizer — after which the API server actually deletes the object.
3. `kubectl delete` **hangs indefinitely** (the object stays terminating) because no one removes the finalizer. The dangerous escape hatch is manually stripping the finalizer (`kubectl patch --type=json -p '[{"op":"remove","path":"/metadata/finalizers"}]'`), which forces deletion but **skips the external cleanup**, potentially orphaning cloud resources — do it only when you understand and accept that leak.
4. Writing `status` via the `/status` subresource keeps it separate from user-owned `spec` (the operator never clobbers desired state, and `generation` stays meaningful). **Conditions** are a standard, extensible, machine-readable vocabulary (`type/status/reason/message/lastTransitionTime`) that tools and humans already understand, versus ad-hoc status fields that every consumer must special-case.

### Exercise 6
1. Any three of: **dependency resolution** (required CRDs/other operators), **versioned upgrades over channels** with rollback safety, **RBAC/ServiceAccount provisioning** from the CSV, **CRD ownership and conflict detection** across operators, **install approval gating**, and a **catalog/discovery** surface (OperatorHub). Raw `kubectl apply` does none of these — it just writes YAML.
2. A **ClusterServiceVersion (CSV)** is the operator's descriptor/manifest *as installed*: its deployment, RBAC, owned CRDs, version, and metadata (including capability level). A **Subscription** expresses **intent to install and track a channel** of an operator from a catalog; OLM turns it into `InstallPlan`s that install/upgrade CSVs. The Subscription is intent-to-track; the CSV is the running operator's descriptor.
3. `Manual` approval means OLM stages an upgrade as an `InstallPlan` but **waits for a human to approve** before applying it — mitigating the risk that an automatic operator upgrade silently changes behavior/CRDs and breaks workloads in production. `Automatic` applies new versions in the channel as soon as they appear, trading control for hands-off currency.
4. **Level 1 Basic Install** = deploys the operator and provisions the operand. **Level 2 Seamless Upgrades** = handles upgrades of both operator and operand. **Level 3 Full Lifecycle** = plus backups, failover, restore. **Level 4 Deep Insights** = metrics, alerts, log processing, workload analysis. **Level 5 Auto Pilot** = automated scaling (horizontal/vertical), auto-tuning/healing, and config self-management. So "installs the operand" = Level 1; "handles operand upgrades" = Level 2; "metrics/alerts and auto-scaling" spans Level 4 (insights) into Level 5 (auto-scaling).

</details>