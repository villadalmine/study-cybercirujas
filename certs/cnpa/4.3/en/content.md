# Infrastructure Provisioning with Kubernetes (Crossplane / Kratix)

> CNPA 4.3 · Exam weight 3.0 · Domain: *Platform Provisioning & Delivery*

---

## 1. The production problem: the control plane as the unit of infrastructure

Infrastructure-as-Code (IaC) tools like Terraform, Pulumi or CloudFormation operate on a **run-to-completion** model: a human or a CI job invokes `apply`, the tool reconciles once against a state file, and then it *walks away*. The desired state and the live state diverge silently between runs. This produces the two failure modes every platform team eventually hits at scale:

- **Drift.** Someone edits a security group in the AWS console; nothing detects it until the next `terraform plan`, which may be days later — or never, if the module was orphaned. The state file becomes a lie.
- **The provisioning bottleneck.** A single `terraform.tfstate` (or workspace) becomes a serialization point. Locking, blast radius, and "who owns this state" turn into an operational tax that grows super-linearly with the number of teams.

The **Kubernetes control-plane model** answers this by turning infrastructure into a set of **custom resources reconciled continuously** by controllers running *inside* a cluster. The reconciliation loop is not a CI job — it is a daemon that observes the external system every few minutes (or on webhook/watch events), computes the diff, and corrects drift automatically. The desired state lives in `etcd`, is protected by RBAC, admission control, and audit logging, and is queryable with the same `kubectl` verbs your workloads already use.

Two CNCF projects productionize this idea from opposite directions:

- **Crossplane** — a *reconciliation engine*. It extends the Kubernetes API with CRDs that represent cloud/external resources and continuously enforces them. It is a **control plane you build**.
- **Kratix** — a *platform-delivery framework*. It packages an API + its imperative workflows + its GitOps distribution into a portable object called a **Promise**, and schedules the outputs across a *fleet* of destination clusters. It is a **framework for building the platform API and shipping its results**.

The CNPA exam treats these as the canonical answers to *"how does a platform team expose self-service infrastructure through the Kubernetes API?"* — Crossplane for continuous, provider-driven reconciliation; Kratix for workflow-based, multi-cluster platform delivery. They are frequently **complementary**: a Kratix Promise can deliver Crossplane Compositions to worker clusters.

The architectural shift the exam wants you to internalize:

```
Terraform model:     desired ──apply──▶ live   (one-shot, then blind)
Control-plane model: desired ◀─reconcile─▶ live (continuous, self-healing)
```

---

## 2. Two philosophies: reconciliation vs. delivery

### 2.1 Crossplane — declarative reconciliation

The control plane **directly owns** the external resources. A `Provider` installs CRDs (Managed Resources) that map 1:1 to cloud objects (`Instance` → an RDS instance, `Bucket` → an S3 bucket). A **Composition** bundles several Managed Resources behind a single higher-level, opinionated API (a *Composite Resource*, XR) that platform consumers claim. The controller reconciles each Managed Resource forever.

### 2.2 Kratix — workflow-driven delivery

The platform cluster **does not own** the end infrastructure directly. A **Promise** defines a user-facing CRD; when a user submits a *Resource Request*, Kratix runs a **pipeline** (a sequence of containers — which may run `helm template`, `kustomize`, Terraform, or emit Crossplane manifests) whose YAML output is written to a **State Store** (a Git repo or S3/MinIO bucket). A GitOps agent (Flux, installed by default) on each **Destination** cluster then applies those documents. Kratix's job is *scheduling and delivery across a fleet*, not reconciling cloud APIs itself.

### 2.3 Trade-off matrix

| Dimension | **Crossplane** | **Kratix** |
|---|---|---|
| Primary abstraction | Composition / Composite Resource (XR) | Promise |
| Execution model | Continuous reconciliation (level-triggered) | Pipeline runs on request/update, then GitOps sync |
| Drift correction | Native, automatic, per Managed Resource | Only for what the GitOps agent re-applies; pipeline logic itself is edge-triggered |
| Who owns cloud resources | Crossplane providers, directly | Whatever the pipeline emits (often Crossplane, Terraform, Helm) |
| Multi-cluster fleet | Not native (one control plane; needs add-ons) | First-class: Destinations + label scheduling |
| Delivery mechanism | Direct API calls from provider pods | GitOps (Flux/Argo) pulling from State Store |
| Extensibility unit | Provider (Upjet-generated) + Composition Functions | Pipeline container (any language/tool) |
| Imperative escape hatch | Composition Functions (Go/KCL/Python/templating) | Native — pipelines are arbitrary containers |
| State of record | `etcd` + external-name annotation | `etcd` (requests) + Git/bucket (rendered output) |
| Typical failure surface | Provider auth, composition patch errors, MR reconcile errors | Pipeline job failures, scheduling (no matching Destination), GitOps sync errors |
| Best fit | Cloud resource lifecycle as a reconciled API | Packaging & distributing a full platform API across many clusters |

**Rule of thumb for the exam:** *"continuously reconcile this cloud resource"* → Crossplane. *"expose an X-as-a-Service API and ship its manifests to N clusters via GitOps"* → Kratix. *"do both"* → Kratix Promise whose pipeline emits Crossplane Claims.

### 2.4 Where the Kubernetes-native approach beats a Terraform Operator

A "Terraform in a pod" operator (e.g., running `terraform apply` from a controller) inherits Terraform's state-file coupling and one-shot semantics; it wraps the old model rather than replacing it. Crossplane and Kratix are **level-triggered** and **API-native** — no external state file, RBAC-scoped per resource, and drift is a first-class, observable condition.

---

## 3. Crossplane in depth

### 3.1 The object model

```
Provider ─────────────▶ installs Managed Resource CRDs (e.g. Instance, Bucket)
ProviderConfig ───────▶ credentials + endpoint for a provider
Function ─────────────▶ installs a Composition Function runtime (gRPC)
CompositeResourceDefinition (XRD) ─▶ defines your platform API (XR + optional Claim)
Composition ──────────▶ maps an XR to a set of Managed Resources (via a function pipeline)
Composite Resource (XR) ─▶ cluster-scoped instance of your API
Claim ────────────────▶ namespaced, RBAC-friendly handle to an XR
Managed Resource (MR) ─▶ one external object, reconciled forever
```

The **XRD** is your API contract. It generates two CRDs: the cluster-scoped **XR** (`XPostgreSQLInstance`) and, if `claimNames` is set, the namespaced **Claim** (`PostgreSQLInstance`). Developers create Claims; the platform team owns Compositions.

### 3.2 Reconciliation internals you must know

- **External-name annotation.** `crossplane.io/external-name` on a Managed Resource is the *identity* Crossplane uses to find/adopt the external object. On create, Crossplane sets it from the provider's returned ID; you can pre-set it to **import** an existing resource (Observe-only). Losing this annotation orphans the resource.
- **`deletionPolicy`** (`Delete` | `Orphan`) — whether deleting the MR deletes the cloud object. Production databases are frequently `Orphan`.
- **`managementPolicies`** (beta, on by default since v1.15) — a granular list controlling which reconcile actions the controller may take: `Observe`, `Create`, `Update`, `Delete`, `LateInitialize`. `["*"]` = full management. `["Observe"]` = read-only import/monitoring. This replaces the older boolean semantics and enables safe adoption.
- **`compositionUpdatePolicy`** (`Automatic` | `Manual`) + **CompositionRevisions** — every change to a Composition creates an immutable revision; `Manual` pins an XR to a revision so a bad Composition edit does not fan out to every consumer at once.
- **Readiness** — an XR is `Ready` when its composed resources report readiness. `function-auto-ready` infers this from each MR's `Ready` condition.
- **Connection details** — MRs publish secrets (endpoint, password) that Compositions aggregate into the XR's `writeConnectionSecretToRef` / the Claim's secret.
- **`Usage`** (`apiextensions.crossplane.io/v1alpha1`) — declares an ordering/protection dependency so Crossplane deletes resources in the right sequence (e.g., don't delete the VPC before the subnet).

### 3.3 Full, working manifest set (AWS RDS behind a self-service Postgres API)

**(a) Install the provider (family provider via Upjet):**

```yaml
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: provider-aws-rds
spec:
  package: xpkg.upbound.io/upbound/provider-aws-rds:v1.15.0
  packagePullPolicy: IfNotPresent
  revisionActivationPolicy: Automatic
  revisionHistoryLimit: 1
```

**(b) Provider credentials + ProviderConfig:**

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: aws-creds
  namespace: crossplane-system
type: Opaque
stringData:
  creds: |
    [default]
    aws_access_key_id = AKIAIOSFODNN7EXAMPLE
    aws_secret_access_key = wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
---
apiVersion: aws.upbound.io/v1beta1
kind: ProviderConfig
metadata:
  name: default
spec:
  credentials:
    source: Secret
    secretRef:
      namespace: crossplane-system
      name: aws-creds
      key: creds
```

> **Production note:** prefer `source: IRSA` (EKS) or `source: WebIdentity` (OIDC/Workload Identity) over static keys — no long-lived secrets in `etcd`.

**(c) Install the Composition Functions used by the pipeline:**

```yaml
apiVersion: pkg.crossplane.io/v1
kind: Function
metadata:
  name: function-patch-and-transform
spec:
  package: xpkg.upbound.io/crossplane-contrib/function-patch-and-transform:v0.8.2
---
apiVersion: pkg.crossplane.io/v1
kind: Function
metadata:
  name: function-auto-ready
spec:
  package: xpkg.upbound.io/crossplane-contrib/function-auto-ready:v0.4.1
```

**(d) The XRD — your platform API contract:**

```yaml
apiVersion: apiextensions.crossplane.io/v1
kind: CompositeResourceDefinition
metadata:
  name: xpostgresqlinstances.database.example.org
spec:
  group: database.example.org
  names:
    kind: XPostgreSQLInstance
    plural: xpostgresqlinstances
  claimNames:
    kind: PostgreSQLInstance
    plural: postgresqlinstances
  defaultCompositionRef:
    name: xpostgresqlinstances.aws
  connectionSecretKeys:
    - username
    - password
    - endpoint
    - port
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
              properties:
                parameters:
                  type: object
                  properties:
                    storageGB:
                      type: integer
                      minimum: 20
                      maximum: 1000
                    region:
                      type: string
                      enum: ["us-east-1", "eu-west-1"]
                    instanceClass:
                      type: string
                      default: db.t3.micro
                  required:
                    - storageGB
                    - region
              required:
                - parameters
            status:
              type: object
              properties:
                endpoint:
                  type: string
                  description: The resolved RDS endpoint address.
```

**(e) The Composition — function pipeline mode (the current, non-deprecated form):**

```yaml
apiVersion: apiextensions.crossplane.io/v1
kind: Composition
metadata:
  name: xpostgresqlinstances.aws
  labels:
    provider: aws
    service: postgresql
spec:
  compositeTypeRef:
    apiVersion: database.example.org/v1alpha1
    kind: XPostgreSQLInstance
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
          - name: rds-instance
            base:
              apiVersion: rds.aws.upbound.io/v1beta2
              kind: Instance
              spec:
                forProvider:
                  engine: postgres
                  engineVersion: "15.5"
                  instanceClass: db.t3.micro
                  allocatedStorage: 20
                  username: masteruser
                  autoGeneratePassword: true
                  passwordSecretRef:
                    namespace: crossplane-system
                    name: rds-master-password
                    key: password
                  skipFinalSnapshot: true
                  publiclyAccessible: false
                deletionPolicy: Orphan
                managementPolicies: ["*"]
                writeConnectionSecretToRef:
                  namespace: crossplane-system
                  name: rds-conn
            patches:
              - type: FromCompositeFieldPath
                fromFieldPath: spec.parameters.storageGB
                toFieldPath: spec.forProvider.allocatedStorage
              - type: FromCompositeFieldPath
                fromFieldPath: spec.parameters.region
                toFieldPath: spec.forProvider.region
              - type: FromCompositeFieldPath
                fromFieldPath: spec.parameters.instanceClass
                toFieldPath: spec.forProvider.instanceClass
              - type: ToCompositeFieldPath
                fromFieldPath: status.atProvider.address
                toFieldPath: status.endpoint
            connectionDetails:
              - name: endpoint
                type: FromConnectionSecretKey
                fromConnectionSecretKey: endpoint
              - name: port
                type: FromConnectionSecretKey
                fromConnectionSecretKey: port
              - name: username
                type: FromConnectionSecretKey
                fromConnectionSecretKey: username
              - name: password
                type: FromConnectionSecretKey
                fromConnectionSecretKey: password
    - step: ready
      functionRef:
        name: function-auto-ready
```

**(f) The Claim — what a developer submits (namespaced, RBAC-scoped):**

```yaml
apiVersion: database.example.org/v1alpha1
kind: PostgreSQLInstance
metadata:
  name: orders-db
  namespace: team-payments
spec:
  parameters:
    storageGB: 50
    region: us-east-1
    instanceClass: db.t3.medium
  compositionUpdatePolicy: Manual        # pin to a revision; opt into upgrades
  writeConnectionSecretToRef:
    name: orders-db-conn
```

### 3.4 CLI walkthrough with real output

```bash
$ kubectl get providers
NAME                INSTALLED   HEALTHY   PACKAGE                                             AGE
provider-aws-rds    True        True      xpkg.upbound.io/upbound/provider-aws-rds:v1.15.0    4m12s

$ kubectl get functions
NAME                            INSTALLED   HEALTHY   PACKAGE                                                              AGE
function-auto-ready             True        True      xpkg.upbound.io/crossplane-contrib/function-auto-ready:v0.4.1        3m50s
function-patch-and-transform    True        True      xpkg.upbound.io/crossplane-contrib/function-patch-and-transform:...  3m50s

$ kubectl apply -f xrd.yaml
compositeresourcedefinition.apiextensions.crossplane.io/xpostgresqlinstances.database.example.org created

$ kubectl get xrd
NAME                                            ESTABLISHED   OFFERED   AGE
xpostgresqlinstances.database.example.org       True          True      15s

$ kubectl apply -f claim.yaml
postgresqlinstance.database.example.org/orders-db created

# The Claim spawns a cluster-scoped XR with a generated suffix:
$ kubectl get postgresqlinstance -n team-payments
NAME        SYNCED   READY   CONNECTION-SECRET   AGE
orders-db   True     False   orders-db-conn      20s

$ kubectl get xpostgresqlinstance
NAME              SYNCED   READY   COMPOSITION                    AGE
orders-db-7bqxz   True     False   xpostgresqlinstances.aws       22s
```

**Render/validate a Composition offline before shipping it** (no cluster, no cloud calls — CI gate):

```bash
$ crossplane render claim.yaml composition.yaml functions.yaml
---
apiVersion: database.example.org/v1alpha1
kind: XPostgreSQLInstance
metadata:
  name: orders-db
status:
  endpoint: ""
---
apiVersion: rds.aws.upbound.io/v1beta2
kind: Instance
metadata:
  annotations:
    crossplane.io/composition-resource-name: rds-instance
  generateName: orders-db-
spec:
  forProvider:
    allocatedStorage: 50
    engine: postgres
    engineVersion: "15.5"
    instanceClass: db.t3.medium
    region: us-east-1
```

```bash
$ crossplane validate xrd.yaml composition.yaml
[✓] xpostgresqlinstances.database.example.org validated successfully
[✓] Composition xpostgresqlinstances.aws validated successfully
```

### 3.5 Live trace — the single most valuable diagnostic command

```bash
$ crossplane trace postgresqlinstance/orders-db -n team-payments
NAME                                              SYNCED   READY   STATUS
PostgreSQLInstance/orders-db (team-payments)      True     False   Waiting: ...
└─ XPostgreSQLInstance/orders-db-7bqxz            True     False   Creating: ...
   └─ Instance/orders-db-7bqxz-x9k2p              True     False   Creating: creating

# ... a few minutes later ...

$ crossplane trace postgresqlinstance/orders-db -n team-payments
NAME                                              SYNCED   READY   STATUS
PostgreSQLInstance/orders-db (team-payments)      True     True    Available
└─ XPostgreSQLInstance/orders-db-7bqxz            True     True    Available
   └─ Instance/orders-db-7bqxz-x9k2p              True     True    Available
```

> `crossplane trace` (formerly `crossplane beta trace`) is the fastest way to see *which* rung of the XR→MR tree is stuck and why.

---

## 4. Kratix in depth

### 4.1 The object model

```
Platform cluster ──▶ runs the Kratix controller
Promise ───────────▶ { api (CRD) + dependencies + workflows (pipelines) }
StateStore ────────▶ BucketStateStore | GitStateStore  (where rendered YAML lands)
Destination ───────▶ a target cluster/namespace, with labels, bound to a StateStore path
Resource Request ──▶ an instance of the Promise's CRD, created by a user
Pipeline ──────────▶ ordered containers: read /kratix/input, write /kratix/output
Scheduling ────────▶ destinationSelectors (labels) route output to Destinations
GitOps agent ──────▶ Flux (default) on each Destination pulls & applies the output
```

**Promise anatomy:**

- `spec.api` — the CRD you expose to users (the platform API).
- `spec.dependencies` — prerequisite manifests installed on scheduled Destinations *once* per Promise (operators, CRDs, namespaces).
- `spec.workflows.promise.configure` — runs when the Promise is installed (bootstrap).
- `spec.workflows.resource.configure` — runs on **each** Resource Request; this is where a request is transformed into concrete manifests.
- `...delete` workflows — run on teardown.

**Pipeline container contract:**

| Path | Direction | Purpose |
|---|---|---|
| `/kratix/input/object.yaml` | read | the triggering Resource Request (or Promise) |
| `/kratix/output/` | write | manifests Kratix ships to Destinations |
| `/kratix/metadata/destination-selectors.yaml` | write | per-request label overrides for scheduling |
| `/kratix/metadata/status.yaml` | write | merged back into the request's `.status` |

### 4.2 Full manifest set

**(a) State Store (MinIO/S3 bucket):**

```yaml
apiVersion: platform.kratix.io/v1alpha1
kind: BucketStateStore
metadata:
  name: default
spec:
  endpoint: minio.kratix-platform-system.svc.cluster.local
  insecure: true
  bucketName: kratix
  secretRef:
    name: minio-credentials
    namespace: kratix-platform-system
```

**(b) Destinations with scheduling labels:**

```yaml
apiVersion: platform.kratix.io/v1alpha1
kind: Destination
metadata:
  name: worker-dev
  labels:
    environment: dev
    region: us-east-1
spec:
  stateStoreRef:
    name: default
    kind: BucketStateStore
  path: worker-dev
  strictMatchLabels: false
  filepath:
    mode: nestedByMetadata
---
apiVersion: platform.kratix.io/v1alpha1
kind: Destination
metadata:
  name: worker-prod
  labels:
    environment: prod
    region: us-east-1
spec:
  stateStoreRef:
    name: default
    kind: BucketStateStore
  path: worker-prod
```

**(c) The Promise — a self-service PostgreSQL X-as-a-Service:**

```yaml
apiVersion: platform.kratix.io/v1alpha1
kind: Promise
metadata:
  name: postgresql
  labels:
    kratix.io/promise-version: v1.0.0
spec:
  api:
    apiVersion: apiextensions.k8s.io/v1
    kind: CustomResourceDefinition
    metadata:
      name: postgresqls.marketplace.kratix.io
    spec:
      group: marketplace.kratix.io
      scope: Namespaced
      names:
        kind: postgresql
        plural: postgresqls
        singular: postgresql
      versions:
        - name: v1alpha1
          served: true
          storage: true
          schema:
            openAPIV3Schema:
              type: object
              properties:
                spec:
                  type: object
                  properties:
                    teamId:
                      type: string
                    dbName:
                      type: string
                    environment:
                      type: string
                      default: dev
                  required:
                    - teamId
                    - dbName
  destinationSelectors:
    - matchLabels:
        environment: dev
  dependencies:
    - apiVersion: v1
      kind: Namespace
      metadata:
        name: postgres-operator
  workflows:
    resource:
      configure:
        - apiVersion: platform.kratix.io/v1alpha1
          kind: Pipeline
          metadata:
            name: instance-configure
          spec:
            containers:
              - name: create-db-manifests
                image: myorg/postgresql-request-pipeline:v1.0.0
```

**(d) The pipeline container logic** (`myorg/postgresql-request-pipeline:v1.0.0`, entrypoint `execute-pipeline.sh`) — reads the request, emits a Zalando Postgres Operator manifest, and refines scheduling by environment:

```bash
#!/usr/bin/env bash
set -euo pipefail

# 1. Read the triggering Resource Request.
export team_id=$(yq '.spec.teamId'      /kratix/input/object.yaml)
export db_name=$(yq '.spec.dbName'      /kratix/input/object.yaml)
export env=$(yq '.spec.environment'     /kratix/input/object.yaml)

# 2. Emit a concrete cluster resource for the GitOps agent to apply.
cat <<EOF > /kratix/output/postgres-cluster.yaml
apiVersion: acid.zalan.do/v1
kind: postgresql
metadata:
  name: ${team_id}-${db_name}
  namespace: postgres-operator
spec:
  teamId: "${team_id}"
  numberOfInstances: 2
  postgresql:
    version: "15"
  volume:
    size: 10Gi
EOF

# 3. Refine scheduling: route prod requests to prod Destinations only.
cat <<EOF > /kratix/metadata/destination-selectors.yaml
- directory: ""
  matchLabels:
    environment: ${env}
EOF

# 4. Surface status back onto the Resource Request.
echo "message: Provisioning ${team_id}-${db_name} to ${env}" \
  > /kratix/metadata/status.yaml
```

**(e) The Resource Request — what a developer submits:**

```yaml
apiVersion: marketplace.kratix.io/v1alpha1
kind: postgresql
metadata:
  name: payments-db
  namespace: team-payments
spec:
  teamId: payments
  dbName: orders
  environment: prod
```

### 4.3 CLI walkthrough with real output

```bash
$ kubectl get promises
NAME         STATUS      KIND         API VERSION                        VERSION   AGE
postgresql   Available   postgresql   marketplace.kratix.io/v1alpha1     v1.0.0    2m

$ kubectl get destinations
NAME          AGE
worker-dev    9m
worker-prod   9m

$ kubectl apply -f resource-request.yaml
postgresql.marketplace.kratix.io/payments-db created

# Kratix launches a pipeline Job on the platform cluster:
$ kubectl get jobs -n kratix-platform-system
NAME                                     COMPLETIONS   DURATION   AGE
kratix-postgresql-payments-db-abc12      1/1           14s        18s

$ kubectl get postgresql payments-db -n team-payments -o jsonpath='{.status.message}'
Provisioning payments-orders to prod

# The rendered manifest now lives in the bucket, under the prod Destination path:
$ mc ls kratix/kratix/worker-prod/resources/team-payments/postgresql/payments-db/
[2026-08-07 14:22:31 UTC]   412B  postgres-cluster.yaml

# On worker-prod, Flux has pulled and applied it:
$ kubectl --context worker-prod get postgresql -n postgres-operator
NAME               TEAM       VERSION   PODS   VOLUME   STATUS    AGE
payments-orders    payments   15        2      10Gi     Running   47s
```

---

## 5. Verification and failure diagnosis

### 5.1 Crossplane — the diagnosis ladder

**Rung 1 — Is the package plane healthy?** If a Provider/Function is not `HEALTHY`, nothing downstream can reconcile.

```bash
$ kubectl get providers,functions
$ kubectl describe provider provider-aws-rds | sed -n '/Conditions/,/Events/p'
```

**Rung 2 — Is the XR SYNCED and READY?** `SYNCED=False` means the *Composition* failed (patch/template error). `SYNCED=True, READY=False` means composition succeeded but the *external resource* isn't ready yet (or is failing at the cloud API).

```bash
$ crossplane trace xpostgresqlinstance/orders-db-7bqxz
```

**Rung 3 — Read the Managed Resource conditions and events.** This is where provider/cloud errors surface verbatim:

```bash
$ kubectl describe instance orders-db-7bqxz-x9k2p
...
Status:
  Conditions:
    Type:     Synced
    Status:   False
    Reason:   ReconcileError
    Message:  observe failed: cannot run refresh: refreshing state:
              InvalidParameterValue: Invalid DB engine version 15.99 for postgres
  Conditions:
    Type:     Ready
    Status:   False
    Reason:   Unavailable
Events:
  Warning  CannotObserveExternalResource  12s (x4)  managed/instance
           InvalidParameterValue: Invalid DB engine version 15.99 for postgres
```

**Rung 4 — Provider pod logs** for auth/permission failures the MR only summarizes:

```bash
$ kubectl -n crossplane-system logs deploy/provider-aws-rds-<hash> --tail=50 | grep -i error
```

| Symptom | Likely cause | Fix |
|---|---|---|
| Provider `HEALTHY=False` | Bad package ref / image pull / arch | Check `describe provider`; correct `spec.package` |
| XR `SYNCED=False`, reason `ReconcileError` in Composition | Patch to a non-existent field path; wrong MR `apiVersion` | `crossplane render` locally; fix the field path |
| MR `Synced=False`, `AccessDenied`/`UnauthorizedOperation` | ProviderConfig creds / IAM policy | Fix Secret/IRSA; check IAM |
| XR `Ready=False` forever, MR `Ready=True` | Missing `function-auto-ready` step | Add the ready step to the pipeline |
| Resource deleted in cloud but comes back | Reconciler recreated it (working as designed) | Set `managementPolicies: ["Observe"]` or delete the MR |
| Delete hangs | `Usage`/finalizer ordering; child still referenced | `crossplane trace`; check `Usage` objects |

### 5.2 Kratix — the diagnosis ladder

**Rung 1 — Is the Promise `Available`?** `Unavailable`/`Pending` usually means the Promise workflow or CRD install failed.

```bash
$ kubectl get promise postgresql -o jsonpath='{.status.status}{"\n"}'
```

**Rung 2 — Did the request schedule to any Destination?** The most common Kratix failure is a **selector that matches no Destination** — the pipeline output has nowhere to go.

```bash
$ kubectl describe postgresql payments-db -n team-payments
...
Events:
  Warning  NoMatchingDestination  8s  kratix
           no Destinations match labels {environment: prod}
```

**Rung 3 — Did the pipeline Job succeed?** A crashed container leaves the request without output.

```bash
$ kubectl get jobs -n kratix-platform-system | grep payments-db
$ kubectl logs job/kratix-postgresql-payments-db-abc12 -n kratix-platform-system
```

**Rung 4 — Did the output reach the State Store?** If the Job succeeded but nothing appears in the bucket/Git repo, inspect the writer/state-store credentials.

```bash
$ mc ls --recursive kratix/kratix/worker-prod/ | grep payments
```

**Rung 5 — Did the GitOps agent sync it onto the Destination?** The last hop is Flux/Argo on the worker.

```bash
$ kubectl --context worker-prod get kustomizations -n flux-system
NAME                    READY   MESSAGE
kratix-workload-deps    True    Applied revision: ...
kratix-workload-res     False   kustomize build failed: accumulating resources: ...
```

| Symptom | Likely cause | Fix |
|---|---|---|
| Request created, nothing happens | Selector matches no Destination | Fix `destinationSelectors` labels or add a matching Destination |
| Pipeline Job `Error`/`BackoffLimitExceeded` | Bug in container script; missing `yq`/input | `kubectl logs job/...`; fix the image |
| Job succeeds, bucket empty | State-store credentials/endpoint wrong | Check `BucketStateStore` secretRef & `describe` |
| Output in bucket, not on worker | Flux not installed / can't reach store | Check `kustomizations` on the Destination |
| Dependencies missing on worker | Promise `dependencies` not scheduled | Confirm Destination matches Promise `destinationSelectors` |

### 5.3 Cross-cutting production checks

- **RBAC:** developers get `create/get` on Claims (Crossplane) or the Promise CRD (Kratix), **never** on Managed Resources / rendered manifests.
- **Drift test (Crossplane):** mutate the resource out-of-band (console) and confirm the controller reverts it within one reconcile interval — this proves the level-triggered loop is live.
- **Idempotency test (both):** re-submit the same request; expect *no* new external object — Crossplane keys on external-name, Kratix overwrites the same State Store path.
- **Disaster check:** verify `deletionPolicy: Orphan` on stateful resources and a `skipFinalSnapshot: false` / snapshot policy for real databases before any teardown.

---

## 6. References

- CNPA Curriculum (CNCF) — https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf
- Crossplane documentation (concepts: Providers, Compositions, Composite Resources, Functions) — https://docs.crossplane.io/latest/
- Crossplane — Composition Functions — https://docs.crossplane.io/latest/concepts/compositions/
- Crossplane — Managed Resources (management & deletion policies, external-name) — https://docs.crossplane.io/latest/concepts/managed-resources/
- Crossplane — `crossplane` CLI (`render`, `validate`, `trace`) — https://docs.crossplane.io/latest/cli/
- `function-patch-and-transform` — https://github.com/crossplane-contrib/function-patch-and-transform
- `function-auto-ready` — https://github.com/crossplane-contrib/function-auto-ready
- Upbound AWS providers (Upjet family providers) — https://marketplace.upbound.io/providers/upbound/provider-family-aws
- Kratix documentation — https://docs.kratix.io/
- Kratix — Writing a Promise (API, dependencies, workflows) — https://docs.kratix.io/main/guides/writing-a-promise
- Kratix — Pipeline container contract (`/kratix/input`, `/kratix/output`, `/kratix/metadata`) — https://docs.kratix.io/main/reference/workflows/pipelines
- Kratix — Destinations, State Stores & scheduling — https://docs.kratix.io/main/reference/destinations/intro
- Kratix source & marketplace of Promises — https://github.com/syntasso/kratix
- CNCF landscape (App Definition & Development / Provisioning) — https://landscape.cncf.io/