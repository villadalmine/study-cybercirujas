# 1.1 Declarative Resource Management and Infrastructure Concepts

**Domain:** Platform Engineering Core Fundamentals · **Exam weight:** 7.2 · **CNPA 2025-04-01**

---

## 1. The architectural problem: why platforms are declarative

### 1.1 The imperative failure mode at scale

Consider a platform team operating 14 clusters (3 prod regions, 4 staging, 7 ephemeral preview environments) with 900 workloads and 60 stream-aligned teams. The infrastructure is driven by a runbook of imperative commands: `kubectl create`, `kubectl scale`, `kubectl set image`, `aws rds create-db-instance`, `helm upgrade` with `--set` flags typed by hand.

Four structural failures appear, and they are not operator discipline problems — they are properties of the imperative model:

| Failure | Mechanism | Production symptom |
|---|---|---|
| **No convergence point** | The system state is the *sum of all commands ever run*. There is no artifact that says what the system should be. | `us-east-1` and `eu-west-1` diverge over 8 months. Nobody can enumerate the differences. An incident is "unreproducible in staging." |
| **Non-idempotent recovery** | Re-running the runbook after partial failure produces `AlreadyExists`, duplicate resources, or overwrites. | A failed rollout at step 7 of 12 leaves the cluster in a state that neither rollback nor roll-forward handles. |
| **Ordering coupling** | The operator must know that the Namespace precedes the ServiceAccount which precedes the Deployment. | Bootstrap of a new cluster takes 3 days and a senior engineer, because the dependency graph lives in someone's head. |
| **No drift signal** | Actual state is only observable by inspection; there is no expected state to compare against. | An engineer manually scales a Deployment during an incident. Six weeks later a routine deploy silently reverts it and causes a capacity outage. |

### 1.2 The declarative contract

Declarative resource management inverts the relationship. The operator submits a description of **desired state** (the *what*), and an autonomous **controller** computes and executes the transitions (the *how*) continuously.

```
                    ┌──────────────────────────────────────────┐
                    │  Desired state (Git / API server etcd)    │
                    │  spec: replicas: 5, image: api:v2.3.1     │
                    └────────────────┬─────────────────────────┘
                                     │  observe (watch/list)
                                     ▼
     ┌───────────────────────────────────────────────────────────┐
     │  Controller reconcile loop                                 │
     │   diff := desired − observed                               │
     │   if diff ≠ ∅: act(diff)                                   │
     │   write status (observedGeneration, conditions)            │
     └────────────────┬──────────────────────────────────────────┘
                      │  actuate (create/update/delete)
                      ▼
     ┌───────────────────────────────────────────────────────────┐
     │  Actual state (Pods, cloud resources, DNS, certificates)   │
     └───────────────────────────────────────────────────────────┘
                      │  observe
                      └──────────────► (loop, forever)
```

Three properties follow, and every one of them is a platform-engineering requirement:

- **Idempotency** — applying the same manifest N times yields the same state as applying it once. Retry becomes safe, so automation becomes safe.
- **Convergence** — the loop runs forever, not once. Manual drift is corrected without human intervention.
- **Composability** — because desired state is data (not a script), it can be templated, validated, diffed, signed, reviewed, and stored in version control.

### 1.3 Level-triggered vs. edge-triggered: the design decision that makes it work

This is the single most misunderstood mechanic, and it is examinable.

| Property | Edge-triggered (event-driven) | Level-triggered (state-driven) |
|---|---|---|
| Trigger | Reacts to the *transition* ("replicas changed 3→5") | Reacts to the *current level* ("desired 5, observed 3") |
| Missed event | State is permanently wrong; no self-correction | Next resync corrects it |
| Controller restart | Must replay a durable event log | Just re-lists all objects and reconciles |
| Network partition | Events lost during partition are lost forever | Converges on reconnect |
| Implementation cost | Requires exactly-once delivery | Requires only eventual delivery |

Kubernetes controllers are **level-triggered with edge-triggered optimisation**: watches provide low-latency hints, but correctness never depends on them. A periodic full resync (`--min-resync-period`, default 12 h ±jitter for many controllers; typically 10 h for the informer resync in controller-manager) guarantees convergence even if every watch event is dropped.

> **Consequence for platform design:** a reconcile function must be written so that it can be called at any moment, with any input, any number of times, and still compute the correct action from the *observed world* — never from remembered internal state. Any controller that keeps "I already did X" in memory is a bug waiting for a pod restart.

---

## 2. The Kubernetes Resource Model (KRM)

The KRM is the schema and protocol that make declarative management uniform. Everything that follows — Helm, Kustomize, Argo CD, Crossplane, Cluster API, Gateway API — is built on it.

### 2.1 Canonical object shape

Every KRM object, built-in or custom, has the same four top-level sections:

```yaml
apiVersion: apps/v1          # <group>/<version>; "v1" = core group
kind: Deployment             # the Kind in Group-Version-Kind (GVK)
metadata:                    # identity, ownership, lifecycle
  name: payments-api
  namespace: payments
  labels:
    app.kubernetes.io/name: payments-api
  annotations:
    platform.acme.io/owner: team-payments
  generation: 7              # server-managed: bumped on spec change
  resourceVersion: "8829134" # server-managed: optimistic concurrency token
  uid: 7a5b0d0e-...          # server-managed: unique across space and time
  finalizers: []             # deletion hooks
  ownerReferences: []        # GC parent links
spec:                        # DESIRED state — written by the user
  replicas: 5
status:                      # OBSERVED state — written by the controller
  observedGeneration: 7
  readyReplicas: 5
```

### 2.2 The `spec`/`status` split is the load-bearing abstraction

| Section | Written by | Read by | Persisted through | Recovery if lost |
|---|---|---|---|---|
| `spec` | Humans, CI, GitOps agents | Controllers | etcd (source of truth) | Re-apply from Git |
| `status` | Controllers only | Humans, dependent controllers, monitoring | etcd, but **reconstructible** | Recomputed by the controller from the real world |

A correctly designed API can have its entire `status` deleted and the controller will rebuild it. If your custom controller stores something in `status` that cannot be re-derived from the world (e.g. a generated password, a cloud resource ID with no lookup path), you have created a durable single point of data loss. Store such values in a Secret or an external system, and reference them.

**`generation` / `observedGeneration` is the standard progress protocol:**

- The API server increments `metadata.generation` **only when `spec` changes** (requires the resource to have a `status` subresource registered).
- The controller copies the generation it acted on into `status.observedGeneration`.
- Therefore `status.observedGeneration < metadata.generation` means **"the controller has not yet seen your change"**, which is categorically different from **"the controller saw it and failed"** (`observedGeneration == generation` with a `False` condition).

This distinction is the first branch of every serious troubleshooting decision tree.

### 2.3 Conditions

The conventional status vocabulary (`k8s.io/apimachinery` `metav1.Condition`):

```yaml
status:
  observedGeneration: 7
  conditions:
    - type: Available
      status: "True"                      # "True" | "False" | "Unknown"
      observedGeneration: 7
      lastTransitionTime: "2025-03-14T09:12:44Z"
      reason: MinimumReplicasAvailable    # machine-readable CamelCase
      message: Deployment has minimum availability.
    - type: Progressing
      status: "False"
      observedGeneration: 7
      lastTransitionTime: "2025-03-14T09:22:01Z"
      reason: ProgressDeadlineExceeded
      message: ReplicaSet "payments-api-7d4f8" has timed out progressing.
```

`Unknown` is a first-class value and means "the controller cannot currently determine this" — not "false". Alerting that treats `Unknown` as `False` produces false pages during control-plane maintenance.

### 2.4 Ownership and cascading deletion

```yaml
metadata:
  ownerReferences:
    - apiVersion: apps/v1
      kind: ReplicaSet
      name: payments-api-7d4f8c9b6
      uid: 3c9a1f52-...
      controller: true              # exactly one owner may be the controller
      blockOwnerDeletion: true      # requires delete perms on the owner
```

Garbage collection propagation policies:

| Policy | Behaviour | Use case |
|---|---|---|
| `Background` (default for most kinds) | Owner deleted immediately; GC removes dependents asynchronously | Normal deletes |
| `Foreground` | Owner enters deletion with `foregroundDeletion` finalizer; dependents deleted first, owner last | Ordered teardown, e.g. drain before removing infra |
| `Orphan` | Dependents survive, `ownerReferences` stripped | Migrating resources between owners |

```bash
$ kubectl delete deployment payments-api --cascade=foreground
```

**Cross-namespace ownership is invalid.** A namespaced dependent may not be owned by an object in another namespace, and a cluster-scoped object may not be owned by a namespaced one. Violations cause the GC to mark the dependent for deletion (`ownerRefInvalidNamespace` event) — a classic cause of "my resources keep disappearing" on hand-written operators.

---

## 3. Apply semantics: how desired state is merged

Understanding *why* `kubectl apply` behaves differently from `kubectl replace` and `kubectl edit` is the practical core of this topic.

### 3.1 The three write verbs

| Verb | Semantics | Concurrency safety | Loses unknown fields? |
|---|---|---|---|
| `create` | Fails if the object exists | N/A | N/A |
| `replace` (`PUT`) | Overwrites the whole object; requires `resourceVersion` | Optimistic lock; fails with `409 Conflict` if stale | **Yes** — everything not in your file is deleted |
| `apply` (`PATCH`) | Merges your intent with other managers' intent | Field-level | No — other managers' fields survive |
| `patch` (strategic/merge/JSON) | Surgical mutation | Depends on patch type | No |

`kubectl edit` is `GET` + `PUT` — it is `replace`, not `apply`. Editing a live object dropped from a Git-managed set is how drift is born.

### 3.2 Client-Side Apply (CSA) and the three-way merge

Legacy `kubectl apply` computes a **three-way merge** between:

1. **last-applied** — the previous manifest, stashed in the annotation `kubectl.kubernetes.io/last-applied-configuration`
2. **live** — the current object from the API server
3. **new** — the manifest you are applying

The diff `last-applied − new` yields deletions; `new` yields additions/updates; everything else in `live` is preserved. This is what allows the HPA to own `replicas` while you own `image`.

Its defects are structural:

- The annotation is a full copy of the manifest, subject to the ~262 kB annotation limit, and it is visible in every `kubectl get -o yaml`.
- It only tracks **one** client's intent. Two CI systems applying the same object silently fight.
- Merge logic lives in the client, so `kubectl`, Helm, Argo CD and Terraform each implement it slightly differently.
- Removing a field from the manifest only deletes it if it was in *your* last-applied. Objects created with `create` have no annotation, so the first `apply` cannot delete anything.

### 3.3 Server-Side Apply (SSA) — GA since Kubernetes 1.22

SSA moves the merge into the API server and records **field-level ownership** in `metadata.managedFields`.

```bash
$ kubectl apply --server-side -f deployment.yaml
deployment.apps/payments-api serverside-applied
```

```bash
$ kubectl get deployment payments-api -n payments --show-managed-fields -o yaml | sed -n '/managedFields/,/^  name:/p'
  managedFields:
  - apiVersion: apps/v1
    fieldsType: FieldsV1
    fieldsV1:
      f:metadata:
        f:labels:
          f:app.kubernetes.io/name: {}
      f:spec:
        f:selector: {}
        f:template:
          f:metadata:
            f:labels:
              f:app.kubernetes.io/name: {}
          f:spec:
            f:containers:
              k:{"name":"api"}:
                .: {}
                f:image: {}
                f:name: {}
                f:resources:
                  f:limits:
                    f:memory: {}
                  f:requests:
                    f:cpu: {}
                    f:memory: {}
    manager: kubectl
    operation: Apply
    time: "2025-03-14T09:12:40Z"
  - apiVersion: autoscaling/v2
    fieldsType: FieldsV1
    fieldsV1:
      f:spec:
        f:replicas: {}
    manager: horizontal-pod-autoscaler
    operation: Apply
    time: "2025-03-14T09:18:03Z"
  - apiVersion: apps/v1
    fieldsType: FieldsV1
    fieldsV1:
      f:status:
        f:availableReplicas: {}
        f:conditions: {}
        f:observedGeneration: {}
        f:readyReplicas: {}
    manager: kube-controller-manager
    operation: Update
    subresource: status
    time: "2025-03-14T09:19:11Z"
```

Read the encoding:

- `f:<name>` — a field
- `k:{"name":"api"}` — an entry in an **associative list** keyed by `name`
- `v:"value"` — an entry in a set-like list
- `i:3` — an index in an atomic/ordered list
- `.` — the entry container itself is owned

### 3.4 Conflicts

If a second manager applies a field already owned by another manager with `operation: Apply`, the server rejects the request:

```bash
$ kubectl apply --server-side -f deployment-with-replicas.yaml
error: Apply failed with 1 conflict: conflict with "horizontal-pod-autoscaler" using autoscaling/v2: .spec.replicas
Please review the fields above--they currently have other managers. Here
are the ways you can resolve this warning:
* If you intend to manage all of these fields, please re-run the apply
  command with the `--force-conflicts` flag.
* If you do not intend to manage all of the fields, please edit your
  manifest to remove references to the fields that should keep their
  current managers.
* You may co-own fields by updating your manifest to match the existing
  value; in this case, you'll become the manager if the other manager(s)
  stop managing the field (remove it from their configuration).
See https://kubernetes.io/docs/reference/using-api/server-side-apply/#conflicts
```

This is a *feature*: the imperative model would have silently reset `replicas` to 1 and taken the service down. The three resolutions map to three real platform decisions:

| Resolution | Command / change | When it is correct |
|---|---|---|
| Take ownership | `--force-conflicts` | GitOps agent is the authority; drift must be reverted |
| Yield ownership | Remove the field from your manifest | Another controller (HPA, VPA, service mesh injector) legitimately owns it |
| Co-own | Set the identical value | Two managers must agree, e.g. a shared label |

**Ownership transfer on removal:** when a manager removes a field from its applied configuration, the server deletes the field *unless another manager also owns it*, in which case ownership simply passes. This is how "stop managing `replicas`, let the HPA have it" works cleanly.

### 3.5 Choosing an apply mode

| Dimension | Client-Side Apply | Server-Side Apply |
|---|---|---|
| Merge location | kubectl / client library | kube-apiserver |
| Intent storage | `last-applied-configuration` annotation | `metadata.managedFields` |
| Multi-writer | Undefined behaviour; last writer wins | Explicit conflicts, field-level ownership |
| Object size cost | Full manifest duplicated in an annotation | Compact field set, but grows with manager count |
| CRD support | Requires an OpenAPI schema for strategic merge; falls back to JSON merge | Uses the structural schema and list markers |
| Deleting a field | Only if present in *your* last-applied | Any field you own and then drop |
| Dry run | `--dry-run=client` (no server validation) | `--dry-run=server` (full admission chain) |
| Typical failure | Silent overwrite of another controller's field | Loud `409` conflict |

**Platform recommendation:** standardise on SSA everywhere — kubectl (`--server-side`), Argo CD (`ServerSideApply=true`), Flux (`spec.commonMetadata` + SSA is the default), and any in-house controller (`client.Apply` with a stable `FieldOwner`). Use a **distinct, stable field manager name per system** (`argocd-controller`, `platform-bootstrap`, `team-payments-ci`) so ownership is legible in `managedFields`.

Migration is handled by kubectl: applying with `--server-side` to an object carrying the legacy annotation converts that intent into a `managedFields` entry and removes the annotation, so ownership is not lost. Verify with a dry run first:

```bash
$ kubectl apply --server-side --dry-run=server -f ./manifests/ | tee /tmp/ssa-migration.log
deployment.apps/payments-api serverside-applied (server dry run)
service/payments-api serverside-applied (server dry run)
configmap/payments-api-config serverside-applied (server dry run)
```

### 3.6 Schema markers control merge semantics — including for your CRDs

The API server can only merge intelligently if the schema declares how lists behave. This is the number-one cause of "my Custom Resource keeps clobbering another controller's array".

| Marker | Merge behaviour | Example |
|---|---|---|
| `x-kubernetes-list-type: atomic` (**default when unspecified**) | The whole list is a single owned unit. One manager owns all of it. | `command`, `args` |
| `x-kubernetes-list-type: set` | Scalar list, merged as a set; per-element ownership | `finalizers` |
| `x-kubernetes-list-type: map` + `x-kubernetes-list-map-keys: [name]` | Object list merged by key; per-entry ownership | `spec.template.spec.containers` (key: `name`), `ports` (keys: `containerPort`, `protocol`) |
| `x-kubernetes-map-type: atomic` | The whole map is one unit | `metadata.labels` on some embedded types |

If you author a CRD with a list of, say, `allowedIngressRules` and omit the marker, it defaults to `atomic`: a sidecar injector and your GitOps agent cannot each contribute entries — they will conflict on the entire list.

---

## 4. Reference manifests

### 4.1 A complete, production-shaped workload

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: payments
  labels:
    app.kubernetes.io/managed-by: platform
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: v1.31
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: payments-api
  namespace: payments
automountServiceAccountToken: false
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: payments-api-config
  namespace: payments
data:
  LOG_LEVEL: "info"
  OTEL_EXPORTER_OTLP_ENDPOINT: "http://otel-collector.observability.svc:4317"
  DB_MAX_OPEN_CONNS: "25"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payments-api
  namespace: payments
  labels:
    app.kubernetes.io/name: payments-api
    app.kubernetes.io/component: api
    app.kubernetes.io/part-of: payments
spec:
  # replicas is deliberately OMITTED: the HPA owns this field.
  revisionHistoryLimit: 5
  progressDeadlineSeconds: 600
  selector:
    matchLabels:
      app.kubernetes.io/name: payments-api
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 25%
      maxUnavailable: 0
  template:
    metadata:
      labels:
        app.kubernetes.io/name: payments-api
        app.kubernetes.io/component: api
    spec:
      serviceAccountName: payments-api
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 65532
        runAsGroup: 65532
        fsGroup: 65532
        seccompProfile:
          type: RuntimeDefault
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: payments-api
      containers:
        - name: api
          image: registry.acme.io/payments/api:v2.3.1
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 8080
              protocol: TCP
          envFrom:
            - configMapRef:
                name: payments-api-config
          env:
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
            - name: DB_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: payments-db-conn
                  key: password
          resources:
            requests:
              cpu: 250m
              memory: 256Mi
            limits:
              memory: 512Mi
          startupProbe:
            httpGet:
              path: /healthz
              port: http
            failureThreshold: 30
            periodSeconds: 2
          readinessProbe:
            httpGet:
              path: /readyz
              port: http
            periodSeconds: 5
            timeoutSeconds: 2
          livenessProbe:
            httpGet:
              path: /healthz
              port: http
            periodSeconds: 10
            timeoutSeconds: 2
            failureThreshold: 3
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: tmp
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: payments-api
  namespace: payments
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: payments-api
  ports:
    - name: http
      port: 80
      targetPort: http
      protocol: TCP
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: payments-api
  namespace: payments
spec:
  minAvailable: 2
  selector:
    matchLabels:
      app.kubernetes.io/name: payments-api
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: payments-api
  namespace: payments
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: payments-api
  minReplicas: 3
  maxReplicas: 30
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
  behavior:
    scaleDown:
      stabilizationWindowSeconds: 300
      policies:
        - type: Percent
          value: 50
          periodSeconds: 60
```

The omission of `spec.replicas` is the declarative discipline in miniature: **do not declare what another controller owns.** With SSA this is enforced; with CSA it is a convention that breaks silently.

### 4.2 Extending the model: a CustomResourceDefinition with correct merge markers

```yaml
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: postgresinstances.platform.acme.io
spec:
  group: platform.acme.io
  scope: Namespaced
  names:
    plural: postgresinstances
    singular: postgresinstance
    kind: PostgresInstance
    shortNames: ["pgi"]
    categories: ["platform"]
  versions:
    - name: v1alpha1
      served: true
      storage: true
      subresources:
        status: {}                # enables metadata.generation semantics
        scale:
          specReplicasPath: .spec.replicas
          statusReplicasPath: .status.replicas
      additionalPrinterColumns:
        - name: Size
          type: string
          jsonPath: .spec.size
        - name: Version
          type: string
          jsonPath: .spec.engineVersion
        - name: Ready
          type: string
          jsonPath: .status.conditions[?(@.type=="Ready")].status
        - name: Age
          type: date
          jsonPath: .metadata.creationTimestamp
      schema:
        openAPIV3Schema:
          type: object
          required: [spec]
          properties:
            spec:
              type: object
              required: [size, engineVersion]
              properties:
                size:
                  type: string
                  enum: ["small", "medium", "large"]
                engineVersion:
                  type: string
                  pattern: '^1[4-7]$'
                replicas:
                  type: integer
                  minimum: 1
                  maximum: 5
                  default: 1
                storageGB:
                  type: integer
                  minimum: 20
                  maximum: 4096
                  default: 100
                allowedCIDRs:
                  type: array
                  x-kubernetes-list-type: set     # per-entry ownership
                  items:
                    type: string
                    pattern: '^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$'
                parameters:
                  type: array
                  x-kubernetes-list-type: map     # per-entry ownership
                  x-kubernetes-list-map-keys: ["name"]
                  items:
                    type: object
                    required: [name, value]
                    properties:
                      name:  { type: string }
                      value: { type: string }
              x-kubernetes-validations:
                # CEL: immutability and cross-field rules, enforced by the API server
                - rule: "self.engineVersion >= oldSelf.engineVersion"
                  message: "engineVersion cannot be downgraded"
                  # applies only on update; oldSelf is unavailable on create
                - rule: "self.size != 'small' || self.storageGB <= 500"
                  message: "size=small supports at most 500 GB"
            status:
              type: object
              properties:
                replicas:
                  type: integer
                observedGeneration:
                  type: integer
                  format: int64
                endpoint:
                  type: string
                conditions:
                  type: array
                  x-kubernetes-list-type: map
                  x-kubernetes-list-map-keys: ["type"]
                  items:
                    type: object
                    required: [type, status, lastTransitionTime, reason]
                    properties:
                      type:               { type: string }
                      status:             { type: string, enum: ["True","False","Unknown"] }
                      observedGeneration: { type: integer, format: int64 }
                      lastTransitionTime: { type: string, format: date-time }
                      reason:             { type: string }
                      message:            { type: string }
```

Three things here are worth internalising: the `status` subresource (without it `generation` never increments and `observedGeneration` is meaningless), the CEL `x-kubernetes-validations` (declarative validation without an admission webhook), and the list markers (declarative merge semantics).

Consuming it is indistinguishable from a built-in type:

```bash
$ kubectl apply --server-side -f postgresinstance.yaml
postgresinstance.platform.acme.io/payments-db serverside-applied

$ kubectl get pgi -n payments
NAME          SIZE     VERSION   READY   AGE
payments-db   medium   16        True    4m18s
```

### 4.3 Declarative infrastructure inside the Kubernetes API: Crossplane

Crossplane projects cloud resources into the KRM so that a database, a bucket and a Deployment are managed by the same apply/reconcile/GitOps machinery.

```yaml
---
apiVersion: apiextensions.crossplane.io/v1
kind: CompositeResourceDefinition
metadata:
  name: xpostgresinstances.platform.acme.io
spec:
  group: platform.acme.io
  names:
    kind: XPostgresInstance
    plural: xpostgresinstances
  claimNames:                       # the namespaced, developer-facing API
    kind: PostgresInstance
    plural: postgresinstances
  defaultCompositionRef:
    name: postgres-aws
  versions:
    - name: v1alpha1
      served: true
      referenceable: true
      schema:
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: object
              required: [parameters]
              properties:
                parameters:
                  type: object
                  required: [size, region]
                  properties:
                    size:
                      type: string
                      enum: ["small", "medium", "large"]
                    region:
                      type: string
                    engineVersion:
                      type: string
                      default: "16"
            status:
              type: object
              properties:
                endpoint:
                  type: string
---
apiVersion: apiextensions.crossplane.io/v1
kind: Composition
metadata:
  name: postgres-aws
  labels:
    provider: aws
spec:
  compositeTypeRef:
    apiVersion: platform.acme.io/v1alpha1
    kind: XPostgresInstance
  writeConnectionSecretsToNamespace: crossplane-system
  mode: Pipeline
  pipeline:
    - step: patch-and-transform
      functionRef:
        name: function-patch-and-transform
      input:
        apiVersion: pt.fn.crossplane.io/v1beta1
        kind: Resources
        resources:
          - name: rds-subnet-group
            base:
              apiVersion: rds.aws.upbound.io/v1beta1
              kind: SubnetGroup
              spec:
                forProvider:
                  subnetIdSelector:
                    matchLabels:
                      network: platform-private
            patches:
              - type: FromCompositeFieldPath
                fromFieldPath: spec.parameters.region
                toFieldPath: spec.forProvider.region
          - name: rds-instance
            base:
              apiVersion: rds.aws.upbound.io/v1beta2
              kind: Instance
              spec:
                forProvider:
                  engine: postgres
                  storageEncrypted: true
                  storageType: gp3
                  autoMinorVersionUpgrade: true
                  backupRetentionPeriod: 14
                  deletionProtection: true
                  publiclyAccessible: false
                  skipFinalSnapshot: false
                  dbSubnetGroupNameSelector:
                    matchControllerRef: true
                  passwordSecretRef:
                    namespace: crossplane-system
                    name: rds-master-password
                    key: password
                writeConnectionSecretToRef:
                  namespace: crossplane-system
            patches:
              - type: FromCompositeFieldPath
                fromFieldPath: spec.parameters.region
                toFieldPath: spec.forProvider.region
              - type: FromCompositeFieldPath
                fromFieldPath: spec.parameters.engineVersion
                toFieldPath: spec.forProvider.engineVersion
              - type: FromCompositeFieldPath
                fromFieldPath: spec.parameters.size
                toFieldPath: spec.forProvider.instanceClass
                transforms:
                  - type: map
                    map:
                      small:  db.t4g.medium
                      medium: db.m6g.large
                      large:  db.m6g.2xlarge
              - type: FromCompositeFieldPath
                fromFieldPath: spec.parameters.size
                toFieldPath: spec.forProvider.allocatedStorage
                transforms:
                  - type: map
                    map:
                      small:  "50"
                      medium: "200"
                      large:  "1000"
                  - type: convert
                    convert:
                      toType: int64
              - type: FromCompositeFieldPath
                fromFieldPath: metadata.uid
                toFieldPath: spec.writeConnectionSecretToRef.name
                transforms:
                  - type: string
                    string:
                      type: Format
                      fmt: "%s-rds-conn"
              - type: ToCompositeFieldPath
                fromFieldPath: status.atProvider.endpoint
                toFieldPath: status.endpoint
            connectionDetails:
              - name: host
                type: FromFieldPath
                fromFieldPath: status.atProvider.endpoint
              - name: port
                type: FromFieldPath
                fromFieldPath: status.atProvider.port
              - name: password
                type: FromConnectionSecretKey
                fromConnectionSecretKey: attribute.password
```

The developer-facing artifact is now three fields:

```yaml
apiVersion: platform.acme.io/v1alpha1
kind: PostgresInstance
metadata:
  name: payments-db
  namespace: payments
spec:
  parameters:
    size: medium
    region: eu-west-1
  writeConnectionSecretToRef:
    name: payments-db-conn
```

```bash
$ kubectl apply --server-side -f claim.yaml
postgresinstance.platform.acme.io/payments-db serverside-applied

$ kubectl get postgresinstance -n payments
NAME          SYNCED   READY   CONNECTION-SECRET   AGE
payments-db   True     False   payments-db-conn    92s

$ kubectl get managed
NAME                                            SYNCED  READY  EXTERNAL-NAME             AGE
subnetgroup.rds.aws.upbound.io/payments-db-8xk  True    True   payments-db-8xk           91s
instance.rds.aws.upbound.io/payments-db-h2z9v   True    False  payments-db-h2z9v         90s

# ...six minutes later
$ kubectl get postgresinstance -n payments
NAME          SYNCED   READY   CONNECTION-SECRET   AGE
payments-db   True     True    payments-db-conn    7m4s
```

### 4.4 Declarative infrastructure outside the cluster: Terraform / OpenTofu

```hcl
terraform {
  required_version = ">= 1.7.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }
  backend "s3" {
    bucket         = "acme-tfstate-prod"
    key            = "platform/eu-west-1/payments.tfstate"
    region         = "eu-west-1"
    dynamodb_table = "acme-tfstate-locks"   # state locking; without it, concurrent
    encrypt        = true                   # applies corrupt state
  }
}

variable "environment" {
  type = string
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of dev, staging, prod."
  }
}

locals {
  instance_class = {
    dev     = "db.t4g.medium"
    staging = "db.m6g.large"
    prod    = "db.m6g.2xlarge"
  }
  common_tags = {
    ManagedBy   = "terraform"
    Environment = var.environment
    Owner       = "team-payments"
  }
}

resource "aws_db_instance" "payments" {
  identifier                 = "payments-${var.environment}"
  engine                     = "postgres"
  engine_version             = "16.3"
  instance_class             = local.instance_class[var.environment]
  allocated_storage          = 200
  max_allocated_storage      = 1000
  storage_type               = "gp3"
  storage_encrypted          = true
  multi_az                   = var.environment == "prod"
  backup_retention_period    = 14
  deletion_protection        = var.environment == "prod"
  auto_minor_version_upgrade = true
  publicly_accessible        = false
  skip_final_snapshot        = false
  final_snapshot_identifier  = "payments-${var.environment}-final"
  tags                       = local.common_tags

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [engine_version]   # minor upgrades applied out of band
  }
}

output "db_endpoint" {
  value = aws_db_instance.payments.endpoint
}
```

```bash
$ tofu plan -out=payments.tfplan

OpenTofu used the selected providers to generate the following execution plan.
Resource actions are indicated with the following symbols:
  ~ update in-place

OpenTofu will perform the following actions:

  # aws_db_instance.payments will be updated in-place
  ~ resource "aws_db_instance" "payments" {
        id                    = "payments-prod"
      ~ allocated_storage     = 100 -> 200
      ~ backup_retention_period = 7 -> 14
        # (43 unchanged attributes hidden)
    }

Plan: 0 to add, 1 to change, 0 to destroy.

Saved the plan to: payments.tfplan
```

`plan` is the artifact that makes an external-state declarative system reviewable, and it is the direct analogue of `kubectl diff` / `argocd app diff`.

---

## 5. Comparative analysis: choosing declarative tools

### 5.1 Configuration authoring and composition

| Tool | Model | Strengths | Weaknesses | Fits |
|---|---|---|---|---|
| **Plain YAML** | Literal manifests | Zero abstraction; exactly what the API sees | Duplication across environments; no parameterisation | Small, stable sets; bootstrap layers |
| **Kustomize** | Overlay/patch on a base; pure KRM in, KRM out | No templating language; output is always valid YAML; native to `kubectl -k` | Awkward for large conditional variance; patch indirection can be hard to read | Environment/region variance over a common base |
| **Helm** | Go text/template + values; packaged charts | Distribution and versioning of third-party software; hooks; rollback | Templates operate on *text*, so invalid YAML is possible; `--set` drift; release state in Secrets | Consuming vendor software; complex conditional packaging |
| **CUE / KCL / jsonnet** | Typed configuration language with constraints | Real validation and unification; catches invalid config before apply | Learning cost; small talent pool | Platform teams codifying golden paths at scale |
| **cdk8s / Pulumi** | General-purpose language generating KRM | Loops, abstraction, unit tests in a real language | Turing-complete config becomes software to maintain | Teams already deep in TS/Python/Go |
| **Operators / CRDs** | Domain API + controller | Day-2 automation, not just day-1 rendering; continuous reconciliation | You are writing and running a distributed system | Stateful workloads, platform abstractions |

**The decisive distinction:** Kustomize, Helm and CUE are **rendering** tools — they produce desired state and then stop. Operators and Crossplane are **reconciling** systems — they keep acting. A platform needs both, and confusing them is why teams try to solve day-2 problems with chart templating.

A complete Kustomize structure:

```
manifests/
├── base/
│   ├── kustomization.yaml
│   ├── deployment.yaml
│   ├── service.yaml
│   └── hpa.yaml
└── overlays/
    ├── staging/
    │   ├── kustomization.yaml
    │   └── patch-resources.yaml
    └── prod-eu-west-1/
        ├── kustomization.yaml
        ├── patch-resources.yaml
        └── patch-topology.yaml
```

```yaml
# manifests/base/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - deployment.yaml
  - service.yaml
  - hpa.yaml
labels:
  - pairs:
      app.kubernetes.io/name: payments-api
    includeSelectors: false     # NEVER mutate selectors: they are immutable
configMapGenerator:
  - name: payments-api-config
    literals:
      - LOG_LEVEL=info
      - DB_MAX_OPEN_CONNS=25
generatorOptions:
  disableNameSuffixHash: false  # hash suffix => rollout on config change
```

```yaml
# manifests/overlays/prod-eu-west-1/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: payments
resources:
  - ../../base
images:
  - name: registry.acme.io/payments/api
    newTag: v2.3.1
patches:
  - path: patch-resources.yaml
    target:
      kind: Deployment
      name: payments-api
  - path: patch-topology.yaml
    target:
      kind: Deployment
      name: payments-api
  - target:
      kind: HorizontalPodAutoscaler
      name: payments-api
    patch: |-
      - op: replace
        path: /spec/minReplicas
        value: 6
      - op: replace
        path: /spec/maxReplicas
        value: 60
configMapGenerator:
  - name: payments-api-config
    behavior: merge
    literals:
      - LOG_LEVEL=warn
      - DB_MAX_OPEN_CONNS=60
```

```yaml
# manifests/overlays/prod-eu-west-1/patch-resources.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payments-api
spec:
  template:
    spec:
      containers:
        - name: api
          resources:
            requests:
              cpu: "1"
              memory: 1Gi
            limits:
              memory: 2Gi
```

```bash
$ kubectl kustomize manifests/overlays/prod-eu-west-1 | kubectl apply --server-side --dry-run=server -f -
configmap/payments-api-config-9f7t2mk64b serverside-applied (server dry run)
service/payments-api serverside-applied (server dry run)
deployment.apps/payments-api serverside-applied (server dry run)
horizontalpodautoscaler.autoscaling/payments-api serverside-applied (server dry run)
```

The `configMapGenerator` name hash is a declarative idiom worth naming explicitly: because the ConfigMap's *name* changes when its *content* changes, and the Deployment references it by name, a config change becomes a Pod-template change and therefore a rolling update. Immutable-by-construction configuration removes the entire class of "changed the ConfigMap, forgot to restart" incidents.

### 5.2 Infrastructure provisioning models

| | **Terraform / OpenTofu** | **Crossplane** | **Cluster API** | **Cloud-native controllers (ACK, Config Connector, ASO)** |
|---|---|---|---|---|
| Desired state lives in | HCL in Git + state file | Kubernetes API (etcd) | Kubernetes API (etcd) | Kubernetes API (etcd) |
| Reconciliation | On invocation (`apply`) | Continuous | Continuous | Continuous |
| Drift correction | Only when someone runs `apply` | Automatic | Automatic | Automatic |
| State store | External state file (S3 + lock) | No separate state; the API object *is* the state | Same | Same |
| Abstraction mechanism | Modules | XRDs + Compositions | Templates + `ClusterClass` | None (1:1 with cloud API) |
| RBAC / policy | Provider-side IAM, plan review | Kubernetes RBAC + admission (OPA/Kyverno) | Same | Same |
| Scope | Anything with a provider | Anything with a provider, plus in-cluster | Kubernetes clusters specifically | One cloud |
| Maturity of ecosystem | Very high | High | High (CNCF) | Medium–high per vendor |
| Main risk | Stale state, lock contention, drift between runs | Provider CRD sprawl (thousands of CRDs), cluster becomes a control plane SPOF | Management-cluster availability | Vendor lock-in |

**Design guidance for the "who bootstraps the bootstrapper" problem:** something must exist before Kubernetes does. The common production topology is a thin Terraform/OpenTofu layer that creates the network and the *management* cluster, then Cluster API for workload clusters and Crossplane for application-scoped infrastructure. Putting the management cluster's own lifecycle inside itself creates an unrecoverable circular dependency.

### 5.3 Cluster API — clusters as declarative objects

```yaml
---
apiVersion: cluster.x-k8s.io/v1beta1
kind: Cluster
metadata:
  name: workload-eu-west-1a
  namespace: clusters
  labels:
    platform.acme.io/tier: production
spec:
  clusterNetwork:
    pods:
      cidrBlocks: ["192.168.0.0/16"]
    services:
      cidrBlocks: ["10.128.0.0/12"]
    serviceDomain: cluster.local
  controlPlaneRef:
    apiVersion: controlplane.cluster.x-k8s.io/v1beta1
    kind: KubeadmControlPlane
    name: workload-eu-west-1a-cp
  infrastructureRef:
    apiVersion: infrastructure.cluster.x-k8s.io/v1beta2
    kind: AWSCluster
    name: workload-eu-west-1a
---
apiVersion: controlplane.cluster.x-k8s.io/v1beta1
kind: KubeadmControlPlane
metadata:
  name: workload-eu-west-1a-cp
  namespace: clusters
spec:
  replicas: 3
  version: v1.31.4
  rolloutStrategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
  machineTemplate:
    infrastructureRef:
      apiVersion: infrastructure.cluster.x-k8s.io/v1beta2
      kind: AWSMachineTemplate
      name: workload-eu-west-1a-cp
  kubeadmConfigSpec:
    clusterConfiguration:
      apiServer:
        extraArgs:
          audit-log-path: /var/log/kubernetes/audit.log
          audit-log-maxage: "30"
          audit-log-maxbackup: "10"
      controllerManager:
        extraArgs:
          bind-address: 0.0.0.0
    initConfiguration:
      nodeRegistration:
        kubeletExtraArgs:
          cloud-provider: external
    joinConfiguration:
      nodeRegistration:
        kubeletExtraArgs:
          cloud-provider: external
---
apiVersion: cluster.x-k8s.io/v1beta1
kind: MachineDeployment
metadata:
  name: workload-eu-west-1a-md-0
  namespace: clusters
spec:
  clusterName: workload-eu-west-1a
  replicas: 6
  selector:
    matchLabels: {}
  template:
    spec:
      clusterName: workload-eu-west-1a
      version: v1.31.4
      bootstrap:
        configRef:
          apiVersion: bootstrap.cluster.x-k8s.io/v1beta1
          kind: KubeadmConfigTemplate
          name: workload-eu-west-1a-md-0
      infrastructureRef:
        apiVersion: infrastructure.cluster.x-k8s.io/v1beta2
        kind: AWSMachineTemplate
        name: workload-eu-west-1a-md-0
```

A cluster upgrade is now a one-field diff, reconciled as a rolling replacement of immutable machines:

```bash
$ kubectl patch kubeadmcontrolplane workload-eu-west-1a-cp -n clusters \
    --type=merge -p '{"spec":{"version":"v1.32.1"}}'
kubeadmcontrolplane.controlplane.cluster.x-k8s.io/workload-eu-west-1a-cp patched

$ kubectl get machines -n clusters -l cluster.x-k8s.io/cluster-name=workload-eu-west-1a
NAME                            CLUSTER               NODENAME       PROVIDERID       PHASE          AGE   VERSION
workload-eu-west-1a-cp-4kx2p    workload-eu-west-1a   ip-10-0-1-14   aws:///eu-w...   Running        41d   v1.31.4
workload-eu-west-1a-cp-9jd7l    workload-eu-west-1a   ip-10-0-2-31   aws:///eu-w...   Running        41d   v1.31.4
workload-eu-west-1a-cp-tq88r    workload-eu-west-1a   ip-10-0-3-77   aws:///eu-w...   Running        41d   v1.31.4
workload-eu-west-1a-cp-zzn4d    workload-eu-west-1a                                   Provisioning   38s   v1.32.1
```

### 5.4 GitOps: the delivery mechanism for declarative state

Declarative manifests describe *what*; GitOps defines *where the desired state lives* and *who is allowed to change it*. The OpenGitOps principles (CNCF) are the examinable definition:

1. **Declarative** — the whole system is described declaratively.
2. **Versioned and immutable** — desired state is stored with immutable versions and complete history.
3. **Pulled automatically** — agents pull the state; nobody pushes credentials into the cluster from CI.
4. **Continuously reconciled** — agents observe and correct drift, forever.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: payments-api-prod
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io   # cascade delete on App removal
spec:
  project: payments
  source:
    repoURL: https://git.acme.io/platform/payments-manifests.git
    targetRevision: v2.3.1                     # a tag, not HEAD: immutable
    path: manifests/overlays/prod-eu-west-1
  destination:
    server: https://kubernetes.default.svc
    namespace: payments
  syncPolicy:
    automated:
      prune: true        # delete resources removed from Git
      selfHeal: true     # revert manual cluster-side changes
      allowEmpty: false  # refuse to prune everything on an empty render
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
      - ApplyOutOfSyncOnly=true
      - PruneLast=true
    retry:
      limit: 5
      backoff:
        duration: 10s
        factor: 2
        maxDuration: 5m
  revisionHistoryLimit: 10
  ignoreDifferences:
    - group: apps
      kind: Deployment
      jsonPointers:
        - /spec/replicas        # the HPA owns this
    - group: ""
      kind: Service
      jqPathExpressions:
        - '.spec.ports[] | select(.name == "http") | .nodePort'
```

The Flux equivalent:

```yaml
---
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: payments-manifests
  namespace: flux-system
spec:
  interval: 1m
  url: https://git.acme.io/platform/payments-manifests.git
  ref:
    tag: v2.3.1
  verify:
    mode: HEAD
    secretRef:
      name: git-signing-pubkeys       # reject unsigned commits
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: payments-api-prod
  namespace: flux-system
spec:
  interval: 5m
  retryInterval: 1m
  timeout: 5m
  prune: true
  wait: true
  targetNamespace: payments
  sourceRef:
    kind: GitRepository
    name: payments-manifests
  path: ./manifests/overlays/prod-eu-west-1
  healthChecks:
    - apiVersion: apps/v1
      kind: Deployment
      name: payments-api
      namespace: payments
  postBuild:
    substituteFrom:
      - kind: ConfigMap
        name: cluster-vars
```

```bash
$ argocd app get payments-api-prod
Name:               argocd/payments-api-prod
Project:            payments
Server:             https://kubernetes.default.svc
Namespace:          payments
Repo:               https://git.acme.io/platform/payments-manifests.git
Target:             v2.3.1
Path:               manifests/overlays/prod-eu-west-1
SyncWindow:         Sync Allowed
Sync Policy:        Automated (Prune, SelfHeal)
Sync Status:        Synced to v2.3.1 (a91f4c2)
Health Status:      Healthy

GROUP  KIND                   NAMESPACE  NAME                            STATUS  HEALTH   HOOK  MESSAGE
       Namespace              payments   payments                        Synced                 namespace/payments unchanged
       ConfigMap              payments   payments-api-config-9f7t2mk64b  Synced                 configmap/... unchanged
       Service                payments   payments-api                    Synced  Healthy        service/... unchanged
apps   Deployment             payments   payments-api                    Synced  Healthy        deployment.apps/... configured
autoscaling HorizontalPodAutoscaler payments payments-api               Synced  Healthy        horizontalpodautoscaler.autoscaling/... unchanged
policy PodDisruptionBudget    payments   payments-api                    Synced  Healthy        poddisruptionbudget.policy/... unchanged
```

**The pruning trap.** `prune: true` combined with a rendering error is the most dangerous configuration in GitOps: if the Kustomize build silently produces zero resources, the agent concludes every resource should be deleted. Mitigations, in order of importance: `allowEmpty: false`, render-and-diff in CI before merge, `PruneLast=true`, and `Prune=false` annotations on stateful resources (`argocd.argoproj.io/sync-options: Prune=false`).

---

## 6. Verification and failure diagnosis

### 6.1 The pre-apply gate

```bash
# 1. Schema and syntax against the LIVE cluster's schemas, including CRDs.
$ kubectl apply --server-side --dry-run=server -f manifests/
deployment.apps/payments-api serverside-applied (server dry run)

# A real schema violation:
$ kubectl apply --server-side --dry-run=server -f bad.yaml
error: error validating "bad.yaml": error validating data:
ValidationError(Deployment.spec.template.spec.containers[0].resources.requests.cpu):
invalid type for io.k8s.apimachinery.pkg.api.resource.Quantity: got "map", expected "string"

# 2. Semantic diff against live state. Exit code 1 == differences exist.
$ kubectl diff -f manifests/
diff -u -N /tmp/LIVE-3910284/apps.v1.Deployment.payments.payments-api /tmp/MERGED-190823/apps.v1.Deployment.payments.payments-api
--- /tmp/LIVE-3910284/apps.v1.Deployment.payments.payments-api
+++ /tmp/MERGED-190823/apps.v1.Deployment.payments.payments-api
@@ -34,7 +34,7 @@
       containers:
       - name: api
-        image: registry.acme.io/payments/api:v2.3.0
+        image: registry.acme.io/payments/api:v2.3.1
         imagePullPolicy: IfNotPresent
$ echo $?
1

# 3. Policy validation (admission rules evaluated offline, in CI).
$ kubectl kustomize manifests/overlays/prod-eu-west-1 | kyverno apply policies/ --resource -
Applying 14 policy rule(s) to 6 resource(s)...

pass: 12, fail: 1, warn: 0, error: 0, skip: 1
policy require-pod-requests-limits -> resource payments/Deployment/payments-api failed:
  autogen-validate-resources: 'validation error: CPU and memory resource requests and
  limits are required. rule autogen-validate-resources failed at path
  /spec/template/spec/containers/0/resources/limits/cpu/'
```

`--dry-run=server` runs the full admission chain (mutating webhooks, validating webhooks, quota, CEL policies); `--dry-run=client` only parses locally. In CI, only server dry-run is meaningful.

### 6.2 The post-apply verification ladder

```bash
# Rung 1 — did the API server accept and record my intent?
$ kubectl get deployment payments-api -n payments \
    -o jsonpath='{.metadata.generation}{"\t"}{.status.observedGeneration}{"\n"}'
9	9

# Rung 2 — did the controller succeed?
$ kubectl get deployment payments-api -n payments -o jsonpath='{range .status.conditions[*]}{.type}={.status} ({.reason}){"\n"}{end}'
Available=True (MinimumReplicasAvailable)
Progressing=True (NewReplicaSetAvailable)

# Rung 3 — did the rollout converge?
$ kubectl rollout status deployment/payments-api -n payments --timeout=10m
Waiting for deployment "payments-api" rollout to finish: 4 of 6 updated replicas are available...
deployment "payments-api" successfully rolled out

# Rung 4 — is the world actually right?
$ kubectl get pods -n payments -l app.kubernetes.io/name=payments-api \
    -o custom-columns='NAME:.metadata.name,IMAGE:.spec.containers[0].image,READY:.status.containerStatuses[0].ready,NODE:.spec.nodeName'
NAME                            IMAGE                                    READY   NODE
payments-api-7d4f8c9b6-2xk4z    registry.acme.io/payments/api:v2.3.1     true    ip-10-0-1-14
payments-api-7d4f8c9b6-8jm7q    registry.acme.io/payments/api:v2.3.1     true    ip-10-0-2-31
payments-api-7d4f8c9b6-b9tn2    registry.acme.io/payments/api:v2.3.1     true    ip-10-0-3-77
payments-api-7d4f8c9b6-kd3wl    registry.acme.io/payments/api:v2.3.1     true    ip-10-0-1-52
payments-api-7d4f8c9b6-p7v6x    registry.acme.io/payments/api:v2.3.1     true    ip-10-0-2-08
payments-api-7d4f8c9b6-w4rj9    registry.acme.io/payments/api:v2.3.1     true    ip-10-0-3-19

# Rung 5 — is desired state == Git?
$ kubectl diff -k manifests/overlays/prod-eu-west-1 && echo "NO DRIFT"
NO DRIFT
```

### 6.3 Failure catalogue

#### Failure A — "I applied it and nothing happened"

```bash
$ kubectl get pgi payments-db -n payments -o jsonpath='{.metadata.generation}{" / "}{.status.observedGeneration}{"\n"}'
14 / 11
```

`observedGeneration` lags: the **controller is not processing**. Do not debug the manifest.

```bash
$ kubectl get pods -n platform-system -l control-plane=postgres-operator
NAME                                READY   STATUS             RESTARTS       AGE
postgres-operator-6c9b7d5f4-nq2vt   0/1     CrashLoopBackOff   9 (2m1s ago)   24m

$ kubectl logs -n platform-system deploy/postgres-operator --previous --tail=20
E0314 09:41:02.118  1 leaderelection.go:369] Failed to update lock: Operation cannot be
  fulfilled on leases.coordination.k8s.io "postgres-operator": the object has been modified
E0314 09:41:02.119  1 main.go:144] problem running manager: leader election lost
```

Two controller replicas were fighting for the lease after a partial upgrade. Also check: RBAC (`kubectl auth can-i --as=system:serviceaccount:platform-system:postgres-operator update postgresinstances/status`), a filtered watch that excludes the namespace, and webhook timeouts blocking the update.

#### Failure B — the fight between two managers (endless rollout)

Symptom: a Deployment rolls repeatedly with no Git change. `kubectl get events` shows `ScalingReplicaSet` every few minutes.

```bash
$ kubectl get deployment payments-api -n payments --show-managed-fields \
    -o json | jq -r '.metadata.managedFields[] | "\(.manager)\t\(.operation)\t\(.time)"'
kubectl                     Apply    2025-03-14T09:12:40Z
argocd-controller           Apply    2025-03-14T10:41:22Z
horizontal-pod-autoscaler   Apply    2025-03-14T10:41:25Z
istio-sidecar-injector      Update   2025-03-14T10:41:26Z
```

Find who owns the flapping field:

```bash
$ kubectl get deployment payments-api -n payments --show-managed-fields -o json \
  | jq -r '.metadata.managedFields[] | select(.fieldsV1 | tostring | contains("resources")) | .manager'
argocd-controller
vertical-pod-autoscaler
```

Argo CD is applying `resources` from Git; the VPA is mutating `resources` in place. Each write triggers the other. Resolutions: (a) put the VPA in `updateMode: Off` and let it only recommend; (b) add the field to `ignoreDifferences` in the Application; (c) remove `resources` from Git and let the VPA own it exclusively. Anything that leaves two `Apply` managers writing the same field will oscillate forever.

The general rule: **exactly one manager per field.** Ownership is the declarative system's concurrency control, and violating it produces livelock, not an error.

#### Failure C — deletion hangs forever

```bash
$ kubectl delete postgresinstance payments-db -n payments
postgresinstance.platform.acme.io "payments-db" deleted
^C

$ kubectl get pgi payments-db -n payments -o jsonpath='{.metadata.deletionTimestamp}{"\n"}{.metadata.finalizers}{"\n"}'
2025-03-14T11:02:31Z
["finalizer.platform.acme.io/deprovision"]
```

`deletionTimestamp` is set, so the object is in terminating state; the API server will not remove it until every finalizer is cleared by its owner. Diagnose the *owner of the finalizer*, do not remove it:

```bash
$ kubectl logs -n platform-system deploy/postgres-operator --tail=5
E0314 11:03:44 controller.go:212 "deprovision failed" err="AccessDenied: User is not
  authorized to perform: rds:DeleteDBInstance" instance="payments-db"
```

Force-removing a finalizer (`kubectl patch ... -p '{"metadata":{"finalizers":null}}' --type=merge`) deletes the Kubernetes object and **orphans the real cloud resource, which keeps billing and keeps its data**. Use it only after you have manually confirmed the external resource's fate.

A whole terminating namespace usually points at an unavailable aggregated API service:

```bash
$ kubectl get apiservice | grep -v True
NAME                              SERVICE                       AVAILABLE                  AGE
v1beta1.metrics.k8s.io            kube-system/metrics-server    False (ServiceNotFound)    88d
```

#### Failure D — silent drift under client-side apply

```bash
$ kubectl diff -k manifests/overlays/prod-eu-west-1
--- LIVE
+++ MERGED
@@
-        - name: DEBUG_MODE
-          value: "true"
```

Someone `kubectl edit`-ed the Deployment during an incident. Under CSA the field is not in your last-applied, so `apply` will *not* remove it — the drift survives every deployment. Under SSA with a GitOps agent using `selfHeal`, it is reverted within one reconcile interval. Confirm the culprit in the audit log:

```bash
$ kubectl get events -n payments --field-selector reason=ScalingReplicaSet --sort-by=.lastTimestamp | tail -3
LAST SEEN   TYPE     REASON              OBJECT                        MESSAGE
12m         Normal   ScalingReplicaSet   deployment/payments-api       Scaled up replica set payments-api-6b9c4 to 3
```

```
# kube-apiserver audit log
{"kind":"Event","verb":"update","user":{"username":"oncall@acme.io"},
 "objectRef":{"resource":"deployments","namespace":"payments","name":"payments-api"},
 "requestReceivedTimestamp":"2025-03-14T02:14:09Z","responseStatus":{"code":200}}
```

#### Failure E — immutable field rejection

```bash
$ kubectl apply -f deployment.yaml
The Deployment "payments-api" is invalid: spec.selector: Invalid value:
v1.LabelSelector{MatchLabels:map[string]string{"app.kubernetes.io/name":"payments-api",
"env":"prod"}, MatchExpressions:[]v1.LabelSelectorRequirement(nil)}: field is immutable
```

`Deployment.spec.selector`, `Service.spec.clusterIP`, `Job.spec.template`, `PVC.spec.resources` (shrink), `StatefulSet` fields other than a small allow-list, and `CronJob.spec.jobTemplate` sub-fields are immutable. Declarative systems handle this by **replacement, not mutation**: delete with `--cascade=orphan` and re-create, or deploy under a new name and shift traffic. This is why Kustomize's `labels` transformer defaults to `includeSelectors: false` — a naive global label injection breaks every Deployment in the repo.

#### Failure F — CRD schema pruning silently drops your fields

```bash
$ kubectl apply -f pgi.yaml
postgresinstance.platform.acme.io/payments-db created

$ kubectl get pgi payments-db -o jsonpath='{.spec.backupSchedule}{"\n"}'
                       # empty!
```

Structural schemas **prune** any field not declared in `openAPIV3Schema`. No error is raised. Either declare the field or, as a deliberate escape hatch, set `x-kubernetes-preserve-unknown-fields: true` on that subtree — accepting that you lose validation and per-field SSA ownership there.

```bash
$ kubectl explain postgresinstances.spec --recursive | head -20
GROUP:      platform.acme.io
KIND:       PostgresInstance
VERSION:    v1alpha1

FIELD: spec <Object>
DESCRIPTION:
FIELDS:
  allowedCIDRs  <[]string>
  engineVersion <string>
  parameters    <[]Object>
    name        <string>
    value       <string>
  replicas      <integer>
  size          <string>
  storageGB     <integer>
```

`kubectl explain` reading from the live OpenAPI schema is the fastest way to confirm what the server will accept — including for CRDs.

#### Failure G — `resourceVersion` conflicts under write contention

```
Operation cannot be fulfilled on deployments.apps "payments-api": the object has been
modified; please apply your changes to the latest version and try again
```

This is optimistic concurrency working correctly. In a controller, the fix is to re-read and retry (`retry.RetryOnConflict`), never to blindly re-`PUT` with a stale object. In a pipeline, prefer `apply` (a PATCH, which does not carry a `resourceVersion` precondition) over `replace`.

### 6.4 Diagnostic command reference

| Question | Command |
|---|---|
| What does the server think my object is? | `kubectl get <kind>/<name> -o yaml --show-managed-fields` |
| Who owns which field? | `kubectl get ... -o json \| jq '.metadata.managedFields'` |
| Will this change do what I think? | `kubectl diff -k <dir>` / `kubectl apply --server-side --dry-run=server` |
| Has the controller seen my change? | compare `.metadata.generation` with `.status.observedGeneration` |
| Why is it not ready? | `kubectl get ... -o jsonpath='{.status.conditions}' \| jq` |
| What happened recently? | `kubectl events --for deployment/payments-api -n payments --types=Warning` |
| What fields exist on this CRD? | `kubectl explain <kind>.spec --recursive` |
| What API versions exist? | `kubectl api-resources`, `kubectl api-versions` |
| What is deprecated in this cluster? | `kubectl get --raw /metrics \| grep apiserver_requested_deprecated_apis` |
| Why is delete stuck? | `.metadata.deletionTimestamp` + `.metadata.finalizers` + owning controller logs |
| Is anything orphaned? | `kubectl get <kind> -o json \| jq '.items[] \| select(.metadata.ownerReferences == null) \| .metadata.name'` |

---

## 7. Platform-engineering synthesis

The declarative model is not a syntax preference; it is what makes a platform possible. Every capability the CNPA curriculum builds on top of this topic depends on desired state being **data**:

- **Golden paths** exist because a Composition/XRD/module can encode an opinionated default that a developer consumes with five fields.
- **Policy as code** (Kyverno, OPA Gatekeeper, Validating Admission Policy with CEL) can only evaluate a request if the request is a declarative document.
- **GitOps** requires a source of truth that is diffable and reviewable.
- **Self-service with guardrails** works because RBAC, admission and quota all operate on the same uniform API surface.
- **Measurement** (change lead time, change failure rate) is possible because every change is a commit and every apply is an audited API call.

The rules that survive contact with production:

1. **One owner per field.** Enforce it with SSA and distinct field managers.
2. **Never declare what a controller owns** (`replicas` under an HPA, injected sidecars, `clusterIP`).
3. **Level-triggered, always.** Reconcile from the observed world, never from remembered state.
4. **Git is the desired state; the cluster is a cache.** If you cannot rebuild the cluster from the repo, you do not have GitOps.
5. **`spec` is authored, `status` is derived.** Nothing irreplaceable lives in `status`.
6. **Immutability where possible** (hashed ConfigMaps, tagged images by digest, replaced machines) turns update bugs into create bugs, which are far easier.
7. **Dry-run and diff are gates, not conveniences.** They are the plan step of a declarative change.

---

## 8. References

- CNCF — CNPA (Cloud Native Platform Engineering Associate) curriculum: https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf
- Kubernetes — Objects and desired state: https://kubernetes.io/docs/concepts/overview/working-with-objects/
- Kubernetes — Declarative management with configuration files: https://kubernetes.io/docs/tasks/manage-kubernetes-objects/declarative-config/
- Kubernetes — Server-Side Apply: https://kubernetes.io/docs/reference/using-api/server-side-apply/
- Kubernetes — Controllers and the reconciliation loop: https://kubernetes.io/docs/concepts/architecture/controller/
- Kubernetes — Operator pattern: https://kubernetes.io/docs/concepts/extend-kubernetes/operator/
- Kubernetes — CustomResourceDefinitions: https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/
- Kubernetes — CRD validation rules (CEL): https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/#validation-rules
- Kubernetes — Owners, dependents and garbage collection: https://kubernetes.io/docs/concepts/architecture/garbage-collection/
- Kubernetes — Finalizers: https://kubernetes.io/docs/concepts/overview/working-with-objects/finalizers/
- Kubernetes — Field selectors, labels and annotations: https://kubernetes.io/docs/concepts/overview/working-with-objects/labels/
- Kubernetes — API conventions (`spec`/`status`, conditions, `observedGeneration`): https://github.com/kubernetes/community/blob/master/contributors/devel/sig-architecture/api-conventions.md
- Kubernetes — Recommended labels: https://kubernetes.io/docs/concepts/overview/working-with-objects/common-labels/
- Kustomize — Reference and API: https://kubectl.docs.kubernetes.io/references/kustomize/
- Helm — Documentation: https://helm.sh/docs/
- OpenGitOps — Principles v1.0.0 (CNCF): https://opengitops.dev/
- Argo CD — Declarative setup and sync options: https://argo-cd.readthedocs.io/en/stable/operator-manual/declarative-setup/
- Flux — Kustomization API: https://fluxcd.io/flux/components/kustomize/kustomizations/
- Crossplane — Composition and CompositeResourceDefinitions: https://docs.crossplane.io/latest/concepts/compositions/
- Cluster API — The Cluster API Book: https://cluster-api.sigs.k8s.io/
- Kubernetes Resource Model (KRM) design document: https://github.com/kubernetes/design-proposals-archive/blob/main/architecture/resource-management.md
- OpenTofu — State and backends: https://opentofu.org/docs/language/state/
- CNCF Platforms White Paper: https://tag-app-delivery.cncf.io/whitepapers/platforms/