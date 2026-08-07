# Kubernetes Operator Pattern for Integration and Automation

> **CNPA 4.4** — Cloud Native Platform Engineering Associate · Exam version 2025-04-01 · Domain weight **3.0**
> Profile: Principal Platform Architect / Senior SRE. This material assumes you are comfortable with the Kubernetes API machinery, controllers, and RBAC.

---

## 1. Motivation and the production architectural problem

A platform team's job is to encode operational knowledge so that it runs 24/7 without a human on the keyboard. Kubernetes already does this for its built-in objects: you declare a `Deployment` with `replicas: 3`, and a controller inside `kube-controller-manager` works continuously to make the observed state match. You never run `kubectl scale` in a loop after a node dies — the **Deployment controller** does it for you. That controller is the reference implementation of the pattern.

The **Operator pattern** is the generalization of that idea to *your* domain. An Operator is a **domain-specific controller** that manages a **custom resource** and drives the operational lifecycle of an application the way a skilled human operator would: provisioning, configuration, backups, failover, version upgrades, scaling, and recovery.

### 1.1 The problem it solves

Consider running a stateful, clustered application — PostgreSQL with streaming replication, a Kafka cluster, or a Vault HA quorum — on Kubernetes. A raw `StatefulSet` gets you stable network identities and ordered rollout, but it is *state-unaware*:

| Operational task | `StatefulSet` alone | Human runbook | Operator |
|---|---|---|---|
| Initial provisioning | ✅ (pods start) | manual `initdb` | ✅ automated |
| Primary election / failover | ❌ no notion of "primary" | pager at 03:00 | ✅ leader promoted in seconds |
| Backup + point-in-time restore | ❌ | cron + hope | ✅ scheduled, verified |
| Version upgrade with schema migration | ❌ rolling restart breaks quorum | multi-hour maintenance window | ✅ orchestrated, quorum-safe |
| Scale-out with data rebalancing | ❌ new pod has no data | manual `pg_basebackup` | ✅ clone + join automatically |
| Reacting to a failed replica | pod restarts, but cluster membership is stale | manual re-attach | ✅ reconciled |

The core architectural insight: **a `StatefulSet` reconciles pods; an Operator reconciles a *system*.** The Operator watches a high-level object (`Cluster`, `Database`, `Backup`) and manages the whole fleet of lower-level objects (`StatefulSet`, `Service`, `Secret`, `ConfigMap`, `PVC`, `PodDisruptionBudget`, `Job`) plus the application's *internal* state (replication topology, quorum membership) needed to satisfy it.

### 1.2 The two halves of an Operator

```
Operator = Custom Resource Definition (the API)  +  Controller (the reconcile logic)
```

1. **CRD** — extends the Kubernetes API server with a new resource type. After you apply a CRD, `kubectl get postgresclusters` works exactly like `kubectl get pods`: same authentication, RBAC, admission, audit logging, `kubectl` verbs, field selectors, and `etcd` persistence. You did not build an API server; you *extended* the one you have.
2. **Controller** — a long-running process (a `Deployment` inside the cluster) that **watches** those custom resources and **reconciles** desired state toward observed state, on a level-triggered control loop.

### 1.3 Why the control loop is level-triggered, not edge-triggered

This is the single most important mechanical concept in the topic, and a frequent exam and interview discriminator.

- **Edge-triggered**: react to the *event* ("a Pod was deleted"). If you miss the event — controller was down, watch connection dropped, network blipped — you never act. State drifts silently.
- **Level-triggered**: react to the *current state* ("desired = 3 replicas, observed = 2, therefore create 1"). The trigger merely tells you *when to look*; the decision is always made by comparing full desired vs. observed state. Missing an event only delays reconciliation; a periodic resync guarantees convergence anyway.

Kubernetes controllers are level-triggered. The `Reconcile` function must be:

- **Idempotent** — running it twice with the same input produces the same result. It never says "create X"; it says "ensure X exists, and if it does, ensure it matches."
- **Stateless between invocations** — all truth lives in the API server (the `spec`) and the world (observed objects), never in controller memory. If the Operator pod is killed and rescheduled, the new pod reconciles from scratch with no data loss.
- **Requeue-driven** — on transient failure it returns an error or a `RequeueAfter`, and the work item is retried with exponential backoff.

```
                 watch events (Pods, CRs, Services…)          periodic resync
                         │                                         │
                         ▼                                         ▼
   ┌──────────┐   ┌──────────────┐   ┌────────────┐   ┌────────────────────────┐
   │ Informer │──▶│ Shared cache │──▶│ Work queue │──▶│  Reconcile(key)        │
   │ (watch)  │   │ (indexed)    │   │ (rate-lim) │   │  observe → diff → act  │
   └──────────┘   └──────────────┘   └────────────┘   └───────────┬────────────┘
        ▲                                    ▲                     │
        │                                    └── requeue on error ─┘
        └──────────── API server ◀── create/update/patch child objects
```

---

## 2. Anatomy of the reconcile loop and the client-go machinery

### 2.1 The pipeline behind `controller-runtime`

Almost every modern Operator is built on `sigs.k8s.io/controller-runtime` (used by Kubebuilder and the Operator SDK). The pieces:

| Component | Role | Failure consequence if misconfigured |
|---|---|---|
| **Informer** | Establishes a `watch` on a resource type, maintains a local cache, emits add/update/delete events | Stale cache → reconcile on old data |
| **Shared cache** | In-memory, indexed store of objects the controller reads from — *not* the API server | Reads bypass etcd; cache lag causes "object not found" races |
| **Work queue** | Deduplicating, rate-limited queue of object keys (`namespace/name`) | No dedup → thundering herd; no rate limit → API server overload |
| **Reconciler** | Your `Reconcile(ctx, req)` — the only code you write | Non-idempotent logic → duplicated children, hot loops |
| **Manager** | Wires everything, runs leader election, serves metrics + health | No leader election → split-brain with multiple replicas |

Key property: the work queue **collapses** multiple events for the same object into a single key. If a `PostgresCluster` is updated 50 times in a second, `Reconcile` may run once, seeing the final state. This is *why* reconcile must read current state rather than trust the event payload.

### 2.2 The Reconcile contract (Go, controller-runtime)

```go
// Reconcile is invoked with just a NamespacedName. It never receives the object
// or the event type — it must fetch current state itself. This is the level-
// triggered contract in code form.
func (r *PostgresClusterReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
    log := log.FromContext(ctx)

    // 1. OBSERVE — read desired state from the API server (via cache).
    var cluster dbv1alpha1.PostgresCluster
    if err := r.Get(ctx, req.NamespacedName, &cluster); err != nil {
        // NotFound is normal: the CR was deleted. Owned children are garbage-
        // collected by ownerReferences, so there is nothing to do. Do NOT requeue.
        return ctrl.Result{}, client.IgnoreNotFound(err)
    }

    // 2. FINALIZER — handle deletion of external state the GC cannot reach
    //    (e.g. an S3 bucket, a cloud DNS record). See §6.
    if !cluster.DeletionTimestamp.IsZero() {
        return r.reconcileDelete(ctx, &cluster)
    }
    if !controllerutil.ContainsFinalizer(&cluster, pgFinalizer) {
        controllerutil.AddFinalizer(&cluster, pgFinalizer)
        return ctrl.Result{}, r.Update(ctx, &cluster)
    }

    // 3. ACT — ensure every child object exists and matches. Each step is
    //    idempotent: CreateOrUpdate patches toward the desired shape.
    if err := r.ensureHeadlessService(ctx, &cluster); err != nil {
        return ctrl.Result{}, err // returning err requeues with backoff
    }
    if err := r.ensureStatefulSet(ctx, &cluster); err != nil {
        return ctrl.Result{}, err
    }
    if err := r.ensurePodDisruptionBudget(ctx, &cluster); err != nil {
        return ctrl.Result{}, err
    }

    // 4. STATUS — report observed reality on the status subresource, not spec.
    cluster.Status.ReadyReplicas = r.countReadyReplicas(ctx, &cluster)
    meta.SetStatusCondition(&cluster.Status.Conditions, metav1.Condition{
        Type:    "Available",
        Status:  metav1.ConditionTrue,
        Reason:  "AllReplicasReady",
        Message: fmt.Sprintf("%d/%d replicas ready", cluster.Status.ReadyReplicas, cluster.Spec.Replicas),
    })
    if err := r.Status().Update(ctx, &cluster); err != nil {
        return ctrl.Result{}, err
    }

    // 5. REQUEUE — poll the application's internal state that has no watch.
    return ctrl.Result{RequeueAfter: 30 * time.Second}, nil
}
```

The four verbs — **observe → diff → act → report** — are the entire pattern. Everything else is detail.

---

## 3. Building blocks — the CRD and the controller deployment

### 3.1 A complete, structurally-valid CRD with schema validation and subresources

This is the API contract. Note the **structural schema** (required by `apiextensions.k8s.io/v1`), the **status subresource**, the **scale subresource**, **printer columns**, and a **conversion strategy**.

```yaml
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: postgresclusters.db.example.com
spec:
  group: db.example.com
  scope: Namespaced
  names:
    plural: postgresclusters
    singular: postgrescluster
    kind: PostgresCluster
    shortNames:
      - pgc
    categories:
      - all            # so `kubectl get all` surfaces it
  versions:
    - name: v1alpha1
      served: true
      storage: true    # exactly ONE version may be the storage version
      subresources:
        status: {}      # enables the /status subresource → spec/status split
        scale:          # enables `kubectl scale postgrescluster/x --replicas=5`
          specReplicasPath: .spec.replicas
          statusReplicasPath: .status.readyReplicas
          labelSelectorPath: .status.selector
      additionalPrinterColumns:
        - name: Replicas
          type: integer
          jsonPath: .spec.replicas
        - name: Ready
          type: integer
          jsonPath: .status.readyReplicas
        - name: Phase
          type: string
          jsonPath: .status.phase
        - name: Age
          type: date
          jsonPath: .metadata.creationTimestamp
      schema:
        openAPIV3Schema:
          type: object
          required: ["spec"]
          properties:
            spec:
              type: object
              required: ["replicas", "version"]
              properties:
                replicas:
                  type: integer
                  minimum: 1
                  maximum: 9
                  default: 3
                version:
                  type: string
                  pattern: '^1[4-6]\.[0-9]+$'   # e.g. 16.2 — validated at admission
                storage:
                  type: object
                  required: ["size"]
                  properties:
                    size:
                      type: string
                      pattern: '^[0-9]+(Gi|Mi|Ti)$'
                    storageClassName:
                      type: string
                backup:
                  type: object
                  properties:
                    schedule:
                      type: string
                      # cron expression, validated by the mutating/validating webhook
                    retention:
                      type: integer
                      minimum: 1
                      default: 7
              # Reject unknown fields instead of silently dropping them.
              x-kubernetes-validations:
                - rule: "self.replicas % 2 == 1"
                  message: "replicas must be odd to guarantee a quorum majority"
            status:
              type: object
              properties:
                phase:
                  type: string
                  enum: ["Pending", "Provisioning", "Running", "Degraded", "Deleting"]
                readyReplicas:
                  type: integer
                selector:
                  type: string
                primaryPod:
                  type: string
                conditions:
                  type: array
                  items:
                    type: object
                    required: ["type", "status"]
                    properties:
                      type:        { type: string }
                      status:      { type: string, enum: ["True", "False", "Unknown"] }
                      reason:      { type: string }
                      message:     { type: string }
                      lastTransitionTime: { type: string, format: date-time }
      # CEL validation via x-kubernetes-validations (above) needs Kubernetes ≥1.25.
```

> **CEL note (`x-kubernetes-validations`)** moved to GA in Kubernetes 1.29. It lets the API server itself enforce cross-field invariants — like "replicas must be odd" — without a webhook, removing a whole class of availability risk (a down webhook can block all writes). Prefer CEL over a validating webhook when the rule is a pure function of the object.

### 3.2 RBAC — least privilege for the controller

An Operator has broad power; scope it tightly. It needs full control over the CR and its children, and *watch* on anything it observes.

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: postgres-operator
  namespace: operators
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: postgres-operator
rules:
  # The custom resource and its status/finalizers.
  - apiGroups: ["db.example.com"]
    resources: ["postgresclusters", "postgresclusters/status", "postgresclusters/finalizers"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  # Child workloads it owns.
  - apiGroups: ["apps"]
    resources: ["statefulsets"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: [""]
    resources: ["services", "configmaps", "secrets", "persistentvolumeclaims"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["policy"]
    resources: ["poddisruptionbudgets"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  # Read pods to compute status; NOT create — the StatefulSet does that.
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list", "watch"]
  # Emit Events for observability (`kubectl describe` / `kubectl get events`).
  - apiGroups: [""]
    resources: ["events"]
    verbs: ["create", "patch"]
  # Leader election lease (see §7).
  - apiGroups: ["coordination.k8s.io"]
    resources: ["leases"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: postgres-operator
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: postgres-operator
subjects:
  - kind: ServiceAccount
    name: postgres-operator
    namespace: operators
```

> **Least-privilege discriminator:** notice the operator has `watch` on `pods` but not `create`. It never creates pods directly — it lets the `StatefulSet` controller do that. An Operator that creates pods itself is reimplementing a `StatefulSet` and is almost always a design smell.

### 3.3 The controller Deployment (the Operator itself, running HA)

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postgres-operator
  namespace: operators
  labels:
    app.kubernetes.io/name: postgres-operator
spec:
  replicas: 2                      # HA: two replicas, but only the leader reconciles
  selector:
    matchLabels:
      app.kubernetes.io/name: postgres-operator
  template:
    metadata:
      labels:
        app.kubernetes.io/name: postgres-operator
    spec:
      serviceAccountName: postgres-operator
      securityContext:
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: manager
          image: registry.example.com/postgres-operator:v1.4.2
          args:
            - --leader-elect                          # enable HA leader election
            - --health-probe-bind-address=:8081
            - --metrics-bind-address=:8443
            - --metrics-secure=true
          ports:
            - name: metrics
              containerPort: 8443
            - name: health
              containerPort: 8081
          livenessProbe:
            httpGet: { path: /healthz, port: health }
            initialDelaySeconds: 15
            periodSeconds: 20
          readinessProbe:
            httpGet: { path: /readyz, port: health }
            initialDelaySeconds: 5
            periodSeconds: 10
          resources:
            requests: { cpu: 100m, memory: 128Mi }
            limits:   { memory: 256Mi }               # no CPU limit: avoid reconcile throttling
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
      terminationGracePeriodSeconds: 30
```

> **Why no CPU limit on a controller:** reconcile work is bursty (a node failure triggers a storm). A CPU limit throttles the controller precisely when the cluster most needs it to act. Keep the `requests` for scheduling; drop the CPU `limit`. Keep a memory limit to bound the informer cache blast radius.

### 3.4 A user-facing custom resource instance

```yaml
apiVersion: db.example.com/v1alpha1
kind: PostgresCluster
metadata:
  name: orders-db
  namespace: production
spec:
  replicas: 3
  version: "16.2"
  storage:
    size: 100Gi
    storageClassName: fast-ssd
  backup:
    schedule: "0 2 * * *"     # 02:00 daily
    retention: 14
```

The platform contract is now: an application team writes those 12 lines; the Operator produces the `StatefulSet`, `Service`, `PDB`, `Secret`, backup `CronJob`, and keeps a 3-node quorum healthy forever. That is the abstraction the Operator sells.

---

## 4. Comparative analysis: when to reach for an Operator

The Operator is not always the right tool. It is expensive to build and operate; a controller that misbehaves has cluster-wide RBAC and runs unattended. Choose deliberately.

### 4.1 Operator vs. Helm vs. raw manifests vs. GitOps

| Dimension | Raw manifests | Helm chart | GitOps (Argo/Flux) | Operator |
|---|---|---|---|---|
| **Abstraction** | none | templating | declarative sync | domain API (new `kind`) |
| **Day-1 install** | manual | ✅ one command | ✅ | ✅ |
| **Day-2 ops (backup, failover, upgrade)** | ❌ runbooks | ❌ chart upgrade only | ❌ syncs YAML, not app state | ✅ core purpose |
| **Reacts to runtime events** | ❌ | ❌ | ❌ (drift detect only) | ✅ continuous reconcile |
| **App-internal state awareness** | ❌ | ❌ | ❌ | ✅ (replication, quorum) |
| **Where logic lives** | your head | Go templates | Git + sync engine | compiled controller |
| **Cost to build** | trivial | low | low | **high** |
| **Failure blast radius** | per-apply | per-release | per-app | **cluster-wide RBAC** |
| **Best for** | one-offs | packaging | fleet deployment | stateful/complex lifecycle |

**Decision rule:** if the operational knowledge is *"apply this YAML"*, Helm or GitOps is sufficient. If it is *"watch the cluster and take corrective action a human would take"* — promote a replica, run a backup, migrate a schema during upgrade — you need an Operator. GitOps and Operators are **complementary**, not competing: Argo CD syncs the `PostgresCluster` CR from Git, and the Operator acts on it. The winning platform stack uses both.

### 4.2 Operator SDK vs. Kubebuilder vs. Metacontroller vs. KUDO vs. shell-operator

| Framework | Language | Reconcile model | When to choose |
|---|---|---|---|
| **Kubebuilder** | Go | full controller-runtime | Upstream-idiomatic; the foundation the others build on |
| **Operator SDK** | Go / Ansible / Helm | wraps Kubebuilder (+Ansible/Helm modes) | Same as Kubebuilder plus OLM packaging; Ansible/Helm modes for teams without Go |
| **Metacontroller** | any (webhook) | you implement a sync webhook; it runs the loop | Compose behavior from existing resources; no Go |
| **KUDO** | declarative YAML "plans" | plan/phase/step engine | Ops encoded as ordered plans, no code |
| **shell-operator / kubectl-based** | shell | hook scripts on events | Glue automation, small tasks; not for complex state |

**Operator Capability / Maturity Levels** (the industry rubric, from OperatorHub) — use it to describe *how much* an Operator does, and as a roadmap:

| Level | Name | Capability |
|---|---|---|
| 1 | Basic Install | Provision the app and configuration |
| 2 | Seamless Upgrades | Upgrade the app *and the operator*, versions managed |
| 3 | Full Lifecycle | Backups, restore, failover, scaling |
| 4 | Deep Insights | Metrics, alerts, log processing, workload analysis |
| 5 | Auto Pilot | Auto-scaling, auto-healing, auto-tuning, anomaly detection |

Ansible/Helm-based Operators typically top out at Level 2. Levels 3–5 require real controller code because they react to *application* state, not just Kubernetes objects.

---

## 5. Integration and automation — the exam's emphasis

Topic 4.4 is titled *"…for Integration and Automation."* The Operator pattern is how a platform **integrates** third-party systems into the Kubernetes API surface and **automates** their lifecycle. Two production patterns dominate.

### 5.1 Pattern A — Operator as an integration bridge to external systems

An Operator does not have to manage in-cluster workloads. It can reconcile a custom resource against an *external* API — a cloud provider, a DNS zone, a secrets vault. This is how you present *"everything is a Kubernetes object"* to app teams.

```yaml
# Crossplane-style: a claim for a cloud database, reconciled against AWS RDS.
apiVersion: database.example.com/v1alpha1
kind: ManagedDatabase
metadata:
  name: analytics
  namespace: data-platform
spec:
  engine: postgres
  version: "16"
  instanceClass: db.r6g.large
  region: eu-west-1
  writeConnectionSecretToRef:
    name: analytics-conn         # the operator writes credentials here
```

The controller's `Reconcile` calls the AWS API (`CreateDBInstance`), stores the endpoint + password in the referenced `Secret`, and sets `status.ready`. App teams never touch the AWS console; they write a Kubernetes object, get a `Secret`, and mount it. **This is the "integration" half of 4.4.** Real-world implementations: **Crossplane**, **AWS Controllers for Kubernetes (ACK)**, **Config Connector** (GCP), **Azure Service Operator**, and **External Secrets Operator** (sync from Vault/AWS Secrets Manager into `Secret`s).

### 5.2 Pattern B — Operator as scheduled/event-driven automation

Encode a runbook as a controller. Example: a `Backup` custom resource plus a controller that owns a `CronJob`, watches the resulting `Job`s, records success on the `Backup.status`, and prunes old backups per retention policy. The automation is now declarative, auditable, and RBAC-scoped — not a shell script on a bastion host.

```yaml
apiVersion: db.example.com/v1alpha1
kind: PostgresBackup
metadata:
  name: orders-db-nightly
  namespace: production
spec:
  clusterRef:
    name: orders-db
  destination:
    s3:
      bucket: prod-pg-backups
      region: eu-west-1
  retention: 14
```

### 5.3 Admission webhooks — the automation guardrail

Operators frequently ship **admission webhooks** to validate and default their CRs at write time (in addition to, or instead of, CEL). Three kinds:

| Webhook | Purpose | Example |
|---|---|---|
| **Mutating** | Default/inject fields before persistence | fill `storageClassName` from a platform default |
| **Validating** | Reject invalid objects at admission | forbid shrinking `storage.size` |
| **Conversion** | Convert between CRD versions on read/write | `v1alpha1` ⇆ `v1beta1` |

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingWebhookConfiguration
metadata:
  name: postgrescluster-validator
webhooks:
  - name: vpostgrescluster.db.example.com
    admissionReviewVersions: ["v1"]
    sideEffects: None
    failurePolicy: Fail            # reject writes if the webhook is down — safety over availability
    timeoutSeconds: 5
    clientConfig:
      service:
        name: postgres-operator-webhook
        namespace: operators
        path: /validate-db-example-com-v1alpha1-postgrescluster
      caBundle: <base64-CA>        # usually injected by cert-manager
    rules:
      - apiGroups:   ["db.example.com"]
        apiVersions: ["v1alpha1"]
        operations:  ["CREATE", "UPDATE"]
        resources:   ["postgresclusters"]
        scope: Namespaced
```

> **`failurePolicy` trade-off:** `Fail` protects invariants but couples all CR writes to the webhook's uptime — a down webhook blocks even deletes. `Ignore` favors availability but lets invalid objects through. For a webhook that gates a whole resource type, deploy it HA (≥2 replicas, PDB) and scope the `rules` tightly so an outage cannot brick unrelated resources.

---

## 6. Ownership, garbage collection, and finalizers

### 6.1 Owner references — automatic cascade deletion

Every child object the Operator creates must carry an `ownerReference` back to the CR. Then Kubernetes garbage collection deletes children automatically when the CR is deleted — you write *zero* deletion code for in-cluster children.

```go
// Set on every child before Create. controllerutil does it in one call:
if err := controllerutil.SetControllerReference(&cluster, statefulSet, r.Scheme); err != nil {
    return err
}
```

Rendered into the child's metadata:

```yaml
metadata:
  name: orders-db
  ownerReferences:
    - apiVersion: db.example.com/v1alpha1
      kind: PostgresCluster
      name: orders-db
      uid: 6f2a...c91
      controller: true
      blockOwnerDeletion: true
```

### 6.2 Finalizers — cleaning up what GC cannot reach

GC handles in-cluster children. It cannot delete an **S3 bucket**, a **cloud DNS record**, or **deregister from an external load balancer**. For that, register a **finalizer**: a string on `metadata.finalizers` that blocks actual deletion until the controller removes it.

Deletion becomes a two-phase handshake:

1. User runs `kubectl delete`. The API server sets `deletionTimestamp` but keeps the object because a finalizer is present.
2. The controller sees `deletionTimestamp != nil`, runs external cleanup, then removes its finalizer.
3. With no finalizers left, the API server actually deletes the object.

```go
func (r *PostgresClusterReconciler) reconcileDelete(ctx context.Context, c *dbv1alpha1.PostgresCluster) (ctrl.Result, error) {
    if controllerutil.ContainsFinalizer(c, pgFinalizer) {
        // External, non-GC-managed cleanup. Must be idempotent: a second call
        // after a crash must not fail because the bucket is already gone.
        if err := r.deleteS3Backups(ctx, c); err != nil {
            return ctrl.Result{}, err // requeue; the object stays until this succeeds
        }
        controllerutil.RemoveFinalizer(c, pgFinalizer)
        if err := r.Update(ctx, c); err != nil {
            return ctrl.Result{}, err
        }
    }
    return ctrl.Result{}, nil // finalizer gone → API server completes deletion
}
```

> **The classic "stuck terminating" bug:** a CR sits in `Terminating` forever because the controller crashed, was uninstalled, or its finalizer logic errors on every run. The object cannot be deleted until the finalizer is removed. See §8 for diagnosis and the emergency escape hatch.

---

## 7. High availability of the Operator itself

Two operator replicas that both reconcile the same CR will fight — creating duplicate children, flapping status, corrupting external state. The controller-runtime `Manager` solves this with **leader election**: replicas race for a `Lease` in `coordination.k8s.io`; only the holder reconciles. The standby is a hot spare that takes over within the lease duration if the leader dies.

```bash
$ kubectl -n operators get lease
NAME                       HOLDER                                    AGE
postgres-operator.example  postgres-operator-7d9c4b6f8-2xk4p_a1b2   3d
```

```bash
$ kubectl -n operators get deploy postgres-operator
NAME                READY   UP-TO-DATE   AVAILABLE   AGE
postgres-operator   2/2     2            2           3d

# Only ONE pod logs reconciles; the other waits on the lease.
$ kubectl -n operators logs postgres-operator-7d9c4b6f8-9m2rt | head -3
I0807 09:14:02  attempting to acquire leader lease operators/postgres-operator.example...
# ...and it blocks here as the standby.
```

| Concern | Setting | Rationale |
|---|---|---|
| Split-brain | `--leader-elect=true` | Single active reconciler |
| Failover speed | `LeaseDuration` / `RenewDeadline` | Shorter = faster failover, more API traffic |
| API overload | work-queue rate limiter | Exponential backoff on the queue |
| Cache memory | `Manager` cache options / namespace scoping | Bound informer memory per limit |

---

## 8. Verification and failure diagnosis

This is the SRE core of the topic. An Operator fails *silently and continuously* if you do not watch it — it is a robot, and a broken robot keeps trying.

### 8.1 Verify the CRD and API registration

```bash
$ kubectl get crd postgresclusters.db.example.com
NAME                              CREATED AT
postgresclusters.db.example.com   2026-08-07T09:03:11Z

$ kubectl api-resources | grep postgres
postgresclusters   pgc   db.example.com/v1alpha1   true   PostgresCluster

# Confirm the schema is 'Established' and 'NamesAccepted' — a failed CRD lists here.
$ kubectl get crd postgresclusters.db.example.com -o jsonpath='{.status.conditions[*].type}'
NamesAccepted Established

# Explain works because the CRD carries an OpenAPI schema — proof it registered.
$ kubectl explain postgrescluster.spec.replicas
KIND:     PostgresCluster
FIELD:    replicas <integer>
DESCRIPTION:
     <no description>
```

### 8.2 Verify a CR reconciles and reaches Ready

```bash
$ kubectl -n production apply -f orders-db.yaml
postgrescluster.db.example.com/orders-db created

$ kubectl -n production get pgc
NAME        REPLICAS   READY   PHASE      AGE
orders-db   3          0       Pending    4s

# Watch it converge — the printer columns come from additionalPrinterColumns.
$ kubectl -n production get pgc orders-db -w
NAME        REPLICAS   READY   PHASE          AGE
orders-db   3          0       Provisioning   9s
orders-db   3          2       Provisioning   41s
orders-db   3          3       Running        72s

# The Operator created the children — verify ownerReferences cascade is in place.
$ kubectl -n production get statefulset,svc,pdb -l app.kubernetes.io/instance=orders-db
NAME                             READY   AGE
statefulset.apps/orders-db       3/3     72s
NAME                    TYPE        CLUSTER-IP   PORT(S)    AGE
service/orders-db       ClusterIP   None         5432/TCP   72s
NAME                                          MIN AVAILABLE   ALLOWED DISRUPTIONS   AGE
poddisruptionbudget.policy/orders-db          2               1                     72s
```

### 8.3 Read status conditions — the operator's self-report

```bash
$ kubectl -n production get pgc orders-db -o jsonpath='{range .status.conditions[*]}{.type}={.status} ({.reason}){"\n"}{end}'
Available=True (AllReplicasReady)
Progressing=False (ReconcileComplete)

$ kubectl -n production describe pgc orders-db
...
Status:
  Phase:           Running
  Ready Replicas:  3
  Primary Pod:     orders-db-0
  Conditions:
    Type:      Available
    Status:    True
    Reason:    AllReplicasReady
    Message:   3/3 replicas ready
Events:
  Type    Reason              Age   From              Message
  ----    ------              ----  ----              -------
  Normal  Provisioning        72s   postgres-operator  Creating StatefulSet orders-db
  Normal  PrimaryElected      41s   postgres-operator  Promoted orders-db-0 as primary
  Normal  Available           30s   postgres-operator  Cluster is serving traffic
```

> Events are the operator's audit trail. A well-built Operator emits an Event for every meaningful state transition; `kubectl describe` and `kubectl get events --sort-by=.lastTimestamp` are your first diagnostic stop.

### 8.4 The diagnostic ladder — symptom → probable cause → command

| Symptom | Probable cause | Diagnostic command |
|---|---|---|
| CR created, nothing happens | Controller not running / not leader / RBAC denies watch | `kubectl -n operators logs deploy/postgres-operator` |
| CR stuck `Pending` forever | Reconcile erroring every loop | grep controller logs for `Reconciler error` |
| `Terminating` won't finish | Finalizer never removed (controller down/buggy) | `kubectl get pgc x -o jsonpath='{.metadata.finalizers}'` |
| Duplicate children created | Leader election off → two reconcilers | `kubectl -n operators get lease` |
| Children not deleted with CR | Missing `ownerReferences` | `kubectl get sts x -o jsonpath='{.metadata.ownerReferences}'` |
| Reconcile hot-loops (high CPU) | Non-idempotent write → status update triggers watch → repeat | metrics: `controller_runtime_reconcile_total` rate |
| Writes to CR rejected | Webhook down + `failurePolicy: Fail`, or CEL/schema rule | `kubectl -n operators get pods` for webhook; read admission error |

### 8.5 Reading controller logs — the primary signal

```bash
$ kubectl -n operators logs deploy/postgres-operator --tail=20
I0807 09:14:03  Starting workers  controller=postgrescluster worker count=1
E0807 09:15:11  Reconciler error  controller=postgrescluster
  PostgresCluster=production/orders-db
  error="failed to create StatefulSet: statefulsets.apps is forbidden:
  User \"system:serviceaccount:operators:postgres-operator\" cannot create
  resource \"statefulsets\" in API group \"apps\" in the namespace \"production\""
```

That single line diagnoses an **RBAC gap** — the `ClusterRole` is missing `apps/statefulsets: create`. Because reconcile is level-triggered, the controller retries with backoff; the moment you fix the `ClusterRole`, it converges with no manual re-trigger.

```bash
$ kubectl -n operators logs deploy/postgres-operator | grep -c "Reconciler error"
147
# 147 errors → this CR has been failing to reconcile for a while. Backoff is climbing.
```

### 8.6 Operator metrics — the SRE observability layer

controller-runtime exposes Prometheus metrics on `:8443/metrics`. The four you alert on:

```bash
$ kubectl -n operators port-forward deploy/postgres-operator 8443:8443 &
$ curl -sk https://localhost:8443/metrics | grep -E 'reconcile_total|reconcile_time|workqueue_depth|reconcile_errors'
controller_runtime_reconcile_total{controller="postgrescluster",result="success"} 8241
controller_runtime_reconcile_total{controller="postgrescluster",result="error"} 147
controller_runtime_reconcile_errors_total{controller="postgrescluster"} 147
workqueue_depth{name="postgrescluster"} 0
controller_runtime_reconcile_time_seconds_bucket{controller="postgrescluster",le="0.5"} 8100
```

| Metric | What it tells you | Alert when |
|---|---|---|
| `controller_runtime_reconcile_total{result="error"}` | reconcile failures | error rate rising |
| `controller_runtime_reconcile_errors_total` | cumulative errors | derivative > 0 sustained |
| `workqueue_depth` | backlog of pending work | depth grows unbounded → controller stuck/slow |
| `controller_runtime_reconcile_time_seconds` | reconcile latency | p99 climbs → slow external calls |
| `workqueue_longest_running_processor_seconds` | a wedged reconcile | > lease duration → possible deadlock |

### 8.7 Emergency: force-delete a CR stuck in `Terminating`

Only when the finalizer's owner is gone for good (operator uninstalled) and you accept that external cleanup will **not** run — you must do it by hand.

```bash
# Inspect what is blocking deletion.
$ kubectl -n production get pgc orders-db -o jsonpath='{.metadata.finalizers}'
["db.example.com/cleanup-s3"]

# Escape hatch: strip the finalizer so the API server completes deletion.
$ kubectl -n production patch pgc orders-db --type=json \
    -p='[{"op":"remove","path":"/metadata/finalizers/0"}]'
postgrescluster.db.example.com/orders-db patched
# WARNING: the S3 backups the finalizer would have removed are now orphaned. Clean them up manually.
```

### 8.8 Dry-run and diff before applying — validate CRs safely

```bash
# Server-side dry-run runs schema + CEL + webhooks WITHOUT persisting.
$ kubectl -n production apply --server-side --dry-run=server -f orders-db.yaml
postgrescluster.db.example.com/orders-db serverside-applied (server dry run)

# A rule violation surfaces here, at review time, not in production:
$ kubectl -n production apply --dry-run=server -f bad-even-replicas.yaml
The PostgresCluster "orders-db" is invalid: spec.replicas: Invalid value: 4:
  replicas must be odd to guarantee a quorum majority

$ kubectl -n production diff -f orders-db.yaml     # exit 1 = there IS a diff
```

---

## 9. Operator lifecycle: install, upgrade, and OLM

At scale you do not `kubectl apply` operators by hand — you use the **Operator Lifecycle Manager (OLM)**, which installs Operators from catalogs, resolves CRD/version dependencies, manages RBAC, and orchestrates upgrades through channels.

| Concept | Object | Role |
|---|---|---|
| Package definition | `ClusterServiceVersion` (CSV) | Operator metadata, install strategy, RBAC, owned CRDs |
| Install intent | `Subscription` | "install operator X from channel `stable`, auto-upgrade" |
| Where operators run | `OperatorGroup` | Namespaces the operator watches |
| Source of operators | `CatalogSource` | An index image of available operators |

```yaml
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: postgres-operator
  namespace: operators
spec:
  channel: stable
  name: postgres-operator
  source: community-operators
  sourceNamespace: olm
  installPlanApproval: Manual     # require human approval before an upgrade applies
```

```bash
$ kubectl -n operators get csv
NAME                       DISPLAY             VERSION   REPLACES                   PHASE
postgres-operator.v1.4.2   Postgres Operator   1.4.2     postgres-operator.v1.4.1   Succeeded

# A pending upgrade waits for approval because installPlanApproval: Manual.
$ kubectl -n operators get installplan
NAME            CSV                        APPROVAL   APPROVED
install-9fk2x   postgres-operator.v1.5.0   Manual     false
```

> **CRD upgrade hazard:** upgrading an Operator often upgrades its CRD. Removing or narrowing a field in the stored schema can orphan or invalidate existing CRs. Use **CRD versioning + conversion webhooks** to migrate `v1alpha1` → `v1beta1` without breaking stored objects, and never delete the `storage: true` version while instances of it exist.

---

## 10. Production checklist and anti-patterns

**Ship checklist**

- [ ] Reconcile is idempotent and reads current state (never trusts the event).
- [ ] Every child carries an `ownerReference` for GC cascade.
- [ ] Finalizers guard all *external* (non-GC) state; cleanup is idempotent.
- [ ] `status` uses the status subresource + typed `conditions`; `spec` is never written by the controller.
- [ ] Leader election is on; ≥2 replicas; PDB on the operator.
- [ ] RBAC is least-privilege (`watch` on observed, full verbs only on owned).
- [ ] Prometheus metrics scraped; alerts on error rate and `workqueue_depth`.
- [ ] Schema validation via structural schema + CEL; webhooks HA with a chosen `failurePolicy`.
- [ ] CRD versioning + conversion path before any breaking schema change.
- [ ] Events emitted on every meaningful transition.

**Anti-patterns to reject in review**

| Anti-pattern | Why it fails | Fix |
|---|---|---|
| Trusting the event payload | Work queue collapses events; you see stale data | Always `Get` current state |
| Storing state in controller memory | Lost on restart → drift | State lives in `spec` + the world |
| Writing to `spec` from the controller | Fights the user; hot-loops | Write only to `status` |
| Reconciling pods directly | Reimplements `StatefulSet` | Own high-level workloads |
| No leader election with >1 replica | Split-brain, duplicate children | `--leader-elect` |
| Non-idempotent create | Duplicated objects on retry | `CreateOrUpdate` / server-side apply |
| Finalizer cleanup that isn't idempotent | Stuck `Terminating` after a crash | Tolerate "already gone" |
| `failurePolicy: Fail` webhook, single replica | One pod down bricks all CR writes | HA webhook + PDB, or CEL |

---

## Referencias

- Operator pattern — Kubernetes concepts: https://kubernetes.io/docs/concepts/extend-kubernetes/operator/
- Custom Resources (CRDs): https://kubernetes.io/docs/concepts/extend-kubernetes/api-extension/custom-resources/
- Extend the Kubernetes API with CustomResourceDefinitions: https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/
- Versions in CustomResourceDefinitions (conversion webhooks): https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions-versioning/
- Validation with CEL (`x-kubernetes-validations`): https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/#validation-rules
- Dynamic Admission Control (webhooks): https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/
- Finalizers: https://kubernetes.io/docs/concepts/overview/working-with-objects/finalizers/
- Owner references & garbage collection: https://kubernetes.io/docs/concepts/architecture/garbage-collection/
- Controllers (control loop) concept: https://kubernetes.io/docs/concepts/architecture/controller/
- Coordinated Leader Election / Leases: https://kubernetes.io/docs/concepts/cluster-administration/coordinated-leader-election/
- Kubebuilder Book: https://book.kubebuilder.io/
- `sigs.k8s.io/controller-runtime`: https://pkg.go.dev/sigs.k8s.io/controller-runtime
- Operator SDK: https://sdk.operatorframework.io/docs/
- Operator Capability Levels: https://operatorframework.io/operator-capabilities/
- Operator Lifecycle Manager (OLM): https://olm.operatorframework.io/docs/
- Crossplane (integration/composition): https://docs.crossplane.io/latest/concepts/
- CNPA Curriculum (CNCF): https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf