# 4.2 APIs for Self-Service Platforms (Custom Resource Definitions)

> **Exam domain:** Platform APIs & Self-Service · **Weight:** 3.0 · **Exam version:** 2025-04-01
> **Audience level:** Platform Architect / SRE. This topic assumes you already understand the Kubernetes control loop, RBAC, admission control, and etcd storage semantics.

---

## 1. Motivation: the architectural problem CRDs solve

A platform team's real product is **an API**, not a cluster. The value proposition of platform engineering — "golden paths," self-service, paved roads — collapses to a single technical question: *through what interface does a developer ask for a capability, and who reconciles that request into running infrastructure?*

Before CRDs, the industry answered this three ways, each with a structural flaw:

- **A bespoke REST service + database** (an internal developer portal backend). This forces you to re-implement authentication, authorization, auditing, optimistic concurrency, validation, watch/streaming, and a reconciliation engine — everything the Kubernetes API server already does. You now run *two* control planes with *two* sources of truth that drift.
- **Config-as-data in Git rendered by templating** (Helm values, raw YAML). This exposes the *primitives* (Deployments, Secrets, NetworkPolicies) directly to developers. There is no abstraction boundary: a developer must understand the whole substrate, and the platform team cannot evolve the implementation without breaking every consumer.
- **Ticket-driven provisioning.** Not self-service at all — a human is the API.

The **Custom Resource Definition (CRD)** dissolves this by making the Kubernetes API server *itself* the platform API. You register a new resource type — `ManagedDatabase`, `Environment`, `TenantCluster` — and the API server immediately gives you, for free:

- A **declarative, versioned, schema-validated REST endpoint** under `/apis/<group>/<version>/…`, discoverable and self-documenting.
- **RBAC, admission control, audit logging, optimistic concurrency (resourceVersion), server-side apply, and watch** — the same machinery that governs a `Pod`.
- **A single source of truth in etcd**, reconciled by a controller you write. The developer declares intent (`spec`); a control loop drives reality to match and reports back (`status`). This is the *operator pattern*, and it is the reconciliation engine you would otherwise have built by hand.

The architectural payoff is a **stable abstraction boundary**. Developers consume `kind: ManagedDatabase`. The platform team owns how that expands — a StatefulSet today, a Crossplane-managed RDS instance tomorrow — and can change it without touching a single consumer manifest. The CRD *is* the contract.

> **The self-service constraint that defines the design:** a self-service API is only "self-service" if the developer can be granted access to the *abstraction* without being granted access to the *primitives* it expands into. A developer with `create manageddatabases` must **not** need (and must **not** have) `create secrets` or `create statefulsets`. The controller runs those privileged actions with its own service account. This RBAC asymmetry — narrow developer access to the CR, broad controller access to the substrate — is the whole point, and Section 3 shows it explicitly.

---

## 2. Design space and trade-offs

### 2.1 CRD + controller vs. the alternatives

| Dimension | **CRD + controller** | **Aggregated API server** (`APIService`) | **ConfigMap-as-config** | **External SaaS API** |
|---|---|---|---|---|
| Backing store | etcd (kube-apiserver's) | Anything (your own etcd, SQL, computed/virtual) | etcd (opaque blob) | Vendor's |
| Serving process | **In-process** in kube-apiserver | Separate extension API server process | In-process | Off-cluster |
| Schema & validation | OpenAPI v3 structural schema + CEL | Fully custom (you code it) | None (stringly-typed) | Vendor-defined |
| RBAC / audit / watch | **Native, free** | Native, free (you delegate authn/authz) | Native but on the ConfigMap, not fields | External, separate |
| kubectl integration | Full (`get/describe/explain/scale`) | Full | Generic only | None |
| Effort to build | Low–medium (kubebuilder) | **High** (run a whole apiserver) | Trivial | N/A |
| Right when… | You want declarative resources stored in etcd | You need computed/virtual resources, non-etcd storage, or millions of objects (e.g. `metrics.k8s.io`) | Truly free-form, no API contract | Capability lives outside the cluster |

**Rule of thumb:** reach for the **aggregation layer** only when you cannot live in etcd — virtual resources computed on the fly (metrics-server), a resource type with a cardinality or churn profile that would overwhelm etcd, or storage you must own. For **everything that is "a declarative object a controller reconciles,"** CRDs win decisively on effort. Aggregated API servers are the correct-but-expensive escape hatch, not the default.

### 2.2 Where validation lives (defense in depth)

| Layer | Mechanism | Runs where | Best for | Limits |
|---|---|---|---|---|
| **Structural schema** | OpenAPI v3 (`type`, `enum`, `minimum`, `pattern`, `required`) | kube-apiserver, in-process | Shape, types, ranges, enums | Single-field, no cross-field logic |
| **CEL validation rules** | `x-kubernetes-validations` in the schema | kube-apiserver, in-process | Cross-field, immutability (`oldSelf`), conditional invariants | Bounded by CEL cost budget; object-local only |
| **ValidatingAdmissionPolicy (VAP)** | CEL policy object, no webhook | kube-apiserver, in-process | Cluster-wide guardrails, namespace-conditional rules, param objects | GA in v1.30; object + limited external via params |
| **Validating/Mutating webhook** | External HTTPS callout | Out-of-process, on the request path | Logic needing external lookups, defaulting from other objects | Adds latency; an availability liability; TLS to manage |

**Prefer in-process (schema → CEL → VAP) over webhooks.** Every webhook is a synchronous dependency on the write path: if it is slow or down, writes to that resource stall or fail depending on `failurePolicy`. Since Kubernetes 1.30, **VAP replaces most validating webhooks** with no extra process to run, no TLS to rotate, and no latency budget to guard. Keep webhooks for the genuinely irreducible cases (validation requiring external state, complex mutation).

### 2.3 Tooling to build the controller

| Tool | Layer | Use when |
|---|---|---|
| `client-go` + `informers` (raw) | SDK | You need full control / are building framework-level code |
| **controller-runtime / Kubebuilder** | Framework | Default for Go operators; scaffolds CRD, RBAC, webhooks, manager |
| **Operator SDK** | Framework | Kubebuilder + OLM packaging, Ansible/Helm-based operators |
| **Metacontroller** | Declarative | Reconcile via a webhook that returns desired children; no Go |
| **Crossplane (`CompositeResourceDefinition`)** | Higher-level | Compose cloud/infra primitives; XRDs *generate* CRDs for you |
| **kro / KubeVela** | Higher-level | Define platform APIs as compositions without writing a controller |

Crossplane and kro are the "don't write a controller" path for platform teams: you *declare* how a high-level claim expands into managed resources, and the engine reconciles. Underneath, they still produce ordinary CRDs — so everything in this topic still applies.

---

## 3. Complete, production-grade manifests

The scenario: a self-service `ManagedDatabase` API. Developers request a database by intent; the platform's controller provisions it. We ship **two versions** (`v1alpha1` deprecated, `v1` current) with a **conversion webhook**, `status` and `scale` subresources, **CEL validation**, **defaulting**, **printer columns**, **selectable fields**, aggregated **RBAC**, and a **ValidatingAdmissionPolicy** guardrail. Nothing is elided.

### 3.1 The CustomResourceDefinition

```yaml
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: manageddatabases.platform.acme.io   # MUST be <plural>.<group>
  labels:
    app.kubernetes.io/part-of: acme-platform
    platform.acme.io/self-service-api: "true"
  annotations:
    # cert-manager's CA injector patches spec.conversion.webhook.clientConfig.caBundle
    # from the named Certificate's secret. Without a valid caBundle, ALL reads of this
    # resource fail once conversion is enabled — see the diagnosis section.
    cert-manager.io/inject-ca-from: acme-platform-system/managed-db-conversion-cert
    # Required ONLY for groups under *.k8s.io. Shown to document the mechanism; our
    # group is platform.acme.io, so it is not strictly needed here.
    # api-approved.kubernetes.io: "https://github.com/acme/platform/pull/142"
spec:
  group: platform.acme.io
  scope: Namespaced                          # Namespaced ties the object to a team's namespace + RBAC
  names:
    plural: manageddatabases
    singular: manageddatabase
    kind: ManagedDatabase
    listKind: ManagedDatabaseList
    shortNames: ["mdb"]
    categories: ["acme", "platform"]         # `kubectl get acme` returns all acme-platform CRs

  conversion:
    strategy: Webhook                        # required once versions are structurally different
    webhook:
      conversionReviewVersions: ["v1"]
      clientConfig:
        service:
          namespace: acme-platform-system
          name: managed-db-conversion
          path: /convert
          port: 443
        # caBundle: <injected by cert-manager>

  versions:
    # ---------- v1alpha1: served, deprecated, NOT the storage version ----------
    - name: v1alpha1
      served: true
      storage: false
      deprecated: true
      deprecationWarning: "platform.acme.io/v1alpha1 ManagedDatabase is deprecated; migrate to v1 before 2026-01-01."
      schema:
        openAPIV3Schema:
          type: object
          required: ["spec"]
          properties:
            spec:
              type: object
              required: ["engine", "size"]
              properties:
                engine: { type: string, enum: ["postgres", "mysql"] }
                size:   { type: string, enum: ["small", "medium", "large"] }
                diskGB: { type: integer, minimum: 10 }   # renamed to storageGB in v1
            status:
              type: object
              x-kubernetes-preserve-unknown-fields: true
      subresources:
        status: {}
      additionalPrinterColumns:
        - { name: Engine, type: string, jsonPath: .spec.engine }
        - { name: Size,   type: string, jsonPath: .spec.size }

    # ---------- v1: served AND the single storage version ----------
    - name: v1
      served: true
      storage: true                          # EXACTLY ONE version may set storage: true
      schema:
        openAPIV3Schema:
          type: object
          required: ["spec"]
          properties:
            spec:
              type: object
              required: ["engine", "version", "size"]
              properties:
                engine:
                  type: string
                  enum: ["postgres", "mysql"]
                  x-kubernetes-validations:
                    # Transition rule: oldSelf exists only on UPDATE -> enforces immutability.
                    - rule: "self == oldSelf"
                      message: "engine is immutable once provisioned"
                version:
                  type: string
                  pattern: '^[0-9]+(\.[0-9]+)?$'
                size:
                  type: string
                  enum: ["small", "medium", "large"]
                  default: "small"
                storageGB:
                  type: integer
                  minimum: 10
                  maximum: 16384
                  default: 20
                readReplicas:
                  type: integer
                  minimum: 0
                  maximum: 5
                  default: 0
                highAvailability:
                  type: boolean
                  default: false
                backup:
                  type: object
                  default: {}                # object default lets nested defaults apply
                  properties:
                    enabled:       { type: boolean, default: true }
                    retentionDays: { type: integer, minimum: 1, maximum: 35, default: 7 }
                    schedule:      { type: string, default: "0 2 * * *" }
                team:
                  type: string
                  minLength: 2
                  maxLength: 63
              # Object-scoped CEL: cross-field invariants the platform catalog enforces.
              x-kubernetes-validations:
                - rule: "!(self.engine == 'mysql' && self.version.startsWith('9'))"
                  message: "mysql 9.x is not in the platform catalog"
                - rule: "self.highAvailability || self.size != 'small'"
                  message: "highAvailability requires size medium or large"
                - rule: "self.readReplicas == 0 || self.highAvailability"
                  message: "readReplicas require highAvailability for a stable primary"
                  fieldPath: ".readReplicas"
            status:
              type: object
              properties:
                phase:
                  type: string
                  enum: ["Pending", "Provisioning", "Ready", "Failed", "Deleting"]
                observedGeneration: { type: integer, format: int64 }
                endpoint:  { type: string }
                readyReplicas: { type: integer }
                selector:  { type: string }   # label selector string for the scale subresource
                conditions:
                  type: array
                  x-kubernetes-list-type: map          # SSA-correct merge semantics
                  x-kubernetes-list-map-keys: ["type"]
                  items:
                    type: object
                    required: ["type", "status", "lastTransitionTime", "reason"]
                    properties:
                      type:               { type: string, maxLength: 316 }
                      status:             { type: string, enum: ["True", "False", "Unknown"] }
                      lastTransitionTime: { type: string, format: date-time }
                      reason:             { type: string, maxLength: 1024 }
                      message:            { type: string, maxLength: 32768 }
                      observedGeneration: { type: integer, format: int64 }
      subresources:
        status: {}                           # spec and status get independent write paths
        scale:                               # enables `kubectl scale` and HPA targeting
          specReplicasPath: .spec.readReplicas
          statusReplicasPath: .status.readyReplicas
          labelSelectorPath: .status.selector
      selectableFields:                      # GA in v1.32: field selectors on custom fields
        - jsonPath: .spec.engine
        - jsonPath: .spec.team
      additionalPrinterColumns:
        - { name: Engine,   type: string,  jsonPath: .spec.engine }
        - { name: Version,  type: string,  jsonPath: .spec.version }
        - { name: Size,     type: string,  jsonPath: .spec.size }
        - { name: HA,       type: boolean, jsonPath: .spec.highAvailability }
        - { name: Phase,    type: string,  jsonPath: .status.phase }
        - { name: Endpoint, type: string,  jsonPath: .status.endpoint, priority: 1 }  # -o wide only
        - { name: Age,      type: date,    jsonPath: .metadata.creationTimestamp }
```

**Why each advanced piece matters:**

- **Structural schema is mandatory** for `apiextensions.k8s.io/v1`. It is also the precondition for `default`, `x-kubernetes-validations`, and pruning. Any field absent from the schema is **silently pruned** from the stored object (unless you set `x-kubernetes-preserve-unknown-fields: true`) — a classic "my field disappeared" bug.
- **`status` subresource** splits writes: a client updating `spec` cannot touch `status` and vice versa, and `metadata.generation` bumps only on `spec` changes. This is what lets a controller compute `status.observedGeneration == metadata.generation` to know it has reconciled the latest intent.
- **`scale` subresource** makes the CR a first-class scaling target: `kubectl scale`, and an `HPA` pointing `scaleTargetRef` at `ManagedDatabase`, both drive `spec.readReplicas`. (Contrived for a DB, but demonstrates the mechanism; the paths must exist in the schema.)
- **CEL `x-kubernetes-validations`** (GA for CRDs in v1.29) runs in-process — no webhook. Transition rules (`oldSelf`) give you immutability without admission code. Rules are bounded by a **cost budget** checked at CRD creation, so a rule that could iterate an unbounded list is rejected up front.
- **`x-kubernetes-list-type: map`** on `conditions` gives server-side apply the merge keys it needs so two controllers writing different conditions don't clobber each other.

### 3.2 Conversion webhook infrastructure (cert-manager + Service + Deployment)

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: managed-db-conversion-cert
  namespace: acme-platform-system
spec:
  secretName: managed-db-conversion-tls
  dnsNames:
    - managed-db-conversion.acme-platform-system.svc
    - managed-db-conversion.acme-platform-system.svc.cluster.local
  issuerRef:
    name: platform-selfsigned-ca
    kind: ClusterIssuer
---
apiVersion: v1
kind: Service
metadata:
  name: managed-db-conversion
  namespace: acme-platform-system
spec:
  selector: { app: managed-db-controller }
  ports:
    - port: 443
      targetPort: 9443
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: managed-db-controller
  namespace: acme-platform-system
spec:
  replicas: 2                                # conversion is on the read path: keep it HA
  selector: { matchLabels: { app: managed-db-controller } }
  template:
    metadata:
      labels: { app: managed-db-controller }
    spec:
      serviceAccountName: managed-db-controller   # the PRIVILEGED substrate identity
      containers:
        - name: manager
          image: registry.acme.io/platform/managed-db-controller:v1.4.2
          args:
            - --leader-elect
            - --conversion-webhook-bind=:9443
            - --tls-cert=/tls/tls.crt
            - --tls-key=/tls/tls.key
          ports:
            - { name: conversion, containerPort: 9443 }
          volumeMounts:
            - { name: tls, mountPath: /tls, readOnly: true }
          resources:
            requests: { cpu: 100m, memory: 128Mi }
            limits:   { memory: 256Mi }
      volumes:
        - name: tls
          secret: { secretName: managed-db-conversion-tls }
```

> **Round-tripping rule:** a conversion webhook must be **lossless**. Converting `v1 → v1alpha1 → v1` must reproduce the original. When a newer version has fields the older one lacks (`storageGB` vs `diskGB`), stash the unrepresentable data in an annotation during down-conversion and restore it on up-conversion. Non-round-trippable conversion silently corrupts stored objects.

### 3.3 Self-service RBAC (the abstraction boundary made real)

```yaml
# Developers: full CRUD on the ABSTRACTION only. Note there is NO grant here for
# statefulsets, secrets, or services — those belong to the controller alone.
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: acme:manageddatabase:editor
  labels:
    rbac.authorization.k8s.io/aggregate-to-edit: "true"   # folds into the built-in "edit" role
    rbac.authorization.k8s.io/aggregate-to-admin: "true"
rules:
  - apiGroups: ["platform.acme.io"]
    resources: ["manageddatabases"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["platform.acme.io"]
    resources: ["manageddatabases/status"]
    verbs: ["get"]                                   # read status, never write it
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: acme:manageddatabase:viewer
  labels:
    rbac.authorization.k8s.io/aggregate-to-view: "true"
rules:
  - apiGroups: ["platform.acme.io"]
    resources: ["manageddatabases", "manageddatabases/status"]
    verbs: ["get", "list", "watch"]
---
# The controller's identity: broad on the substrate, because IT does the privileged work.
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: acme:manageddatabase:controller
rules:
  - apiGroups: ["platform.acme.io"]
    resources: ["manageddatabases", "manageddatabases/status", "manageddatabases/finalizers"]
    verbs: ["*"]
  - apiGroups: ["apps"]
    resources: ["statefulsets"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: [""]
    resources: ["secrets", "services", "persistentvolumeclaims", "configmaps"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: [""]
    resources: ["events"]
    verbs: ["create", "patch"]
```

Because the editor role carries `aggregate-to-edit: "true"`, **anyone who already holds `edit` in a namespace automatically gains `ManagedDatabase` CRUD** — no per-team RoleBinding churn. That is how a new self-service API rolls out to every existing tenant atomically.

### 3.4 Guardrail without a webhook: ValidatingAdmissionPolicy

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: acme-manageddb-prod-guardrails
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - apiGroups:   ["platform.acme.io"]
        apiVersions: ["v1"]
        operations:  ["CREATE", "UPDATE"]
        resources:   ["manageddatabases"]
  matchConditions:
    - name: only-prod-namespaces
      expression: "request.namespace.endsWith('-prod')"
  validations:
    - expression: "object.spec.backup.enabled == true"
      message: "production databases must have backups enabled"
      reason: Forbidden
    - expression: "object.spec.highAvailability == true"
      message: "production databases must run highly available"
      reason: Forbidden
    - expression: "object.spec.backup.retentionDays >= 14"
      message: "production backup retention must be >= 14 days"
      reason: Forbidden
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: acme-manageddb-prod-guardrails
spec:
  policyName: acme-manageddb-prod-guardrails
  validationActions: ["Deny", "Audit"]
```

This enforces prod-only policy **in the API server process** — no TLS, no extra Deployment, no latency on the write path, and it cannot cause an outage the way a downed webhook can.

### 3.5 What a developer actually submits

```yaml
apiVersion: platform.acme.io/v1
kind: ManagedDatabase
metadata:
  name: inventory-db
  namespace: team-a-prod
spec:
  engine: postgres
  version: "16"
  size: medium
  storageGB: 100
  highAvailability: true
  readReplicas: 2
  team: team-a
  backup:
    enabled: true
    retentionDays: 30
```

Nine lines of intent. The developer never sees a StatefulSet, a PVC, a Secret, or a backup CronJob — the controller creates all of them, owns them via `ownerReferences`, and garbage-collects them when this object is deleted.

---

## 4. CLI commands and real terminal output

**Register and confirm the CRD is `Established`:**

```console
$ kubectl apply -f manageddatabase-crd.yaml
customresourcedefinition.apiextensions.k8s.io/manageddatabases.platform.acme.io created

$ kubectl get crd manageddatabases.platform.acme.io
NAME                                  CREATED AT
manageddatabases.platform.acme.io     2026-08-07T14:02:11Z

$ kubectl get crd manageddatabases.platform.acme.io \
    -o jsonpath='{range .status.conditions[*]}{.type}={.status} ({.reason}){"\n"}{end}'
NamesAccepted=True (NoConflicts)
Established=True (InitialNamesAccepted)
```

**Discovery — the API is now first-class:**

```console
$ kubectl api-resources --api-group platform.acme.io
NAME              SHORTNAMES   APIVERSION                 NAMESPACED   KIND
manageddatabases  mdb          platform.acme.io/v1        true         ManagedDatabase

$ kubectl get --raw /apis/platform.acme.io | jq '.versions[].version'
"v1"
"v1alpha1"

$ kubectl get --raw /apis/platform.acme.io/v1 \
    | jq '.resources[] | {name, storageVersionHash, verbs}'
{
  "name": "manageddatabases",
  "storageVersionHash": "sf9tK3b1QeE=",
  "verbs": ["create","delete","deletecollection","get","list","patch","update","watch"]
}
{
  "name": "manageddatabases/scale",
  "storageVersionHash": null,
  "verbs": ["get","patch","update"]
}
{
  "name": "manageddatabases/status",
  "storageVersionHash": null,
  "verbs": ["get","patch","update"]
}
```

**Self-documenting schema via `explain` (served straight from the published OpenAPI):**

```console
$ kubectl explain manageddatabase.spec.backup --api-version=platform.acme.io/v1
GROUP:      platform.acme.io
KIND:       ManagedDatabase
VERSION:    v1

FIELD: backup <Object>

FIELDS:
  enabled       <boolean>
  retentionDays <integer>
  schedule      <string>
```

**Create, watch defaulting and printer columns take effect:**

```console
$ kubectl apply -f inventory-db.yaml
manageddatabase.platform.acme.io/inventory-db created

$ kubectl get mdb -n team-a-prod
NAME           ENGINE     VERSION   SIZE     HA     PHASE     AGE
inventory-db   postgres   16        medium   true   Ready     41s

$ kubectl get mdb inventory-db -n team-a-prod -o wide
NAME           ENGINE     VERSION   SIZE     HA     PHASE   ENDPOINT                                       AGE
inventory-db   postgres   16        medium   true   Ready   inventory-db.team-a-prod.svc:5432              52s

# Defaults were materialized server-side (backup.schedule was never in the manifest):
$ kubectl get mdb inventory-db -n team-a-prod -o jsonpath='{.spec.backup.schedule}{"\n"}'
0 2 * * *
```

**CEL rejection is immediate and in-process:**

```console
$ kubectl apply -f - <<'EOF'
apiVersion: platform.acme.io/v1
kind: ManagedDatabase
metadata: { name: bad-db, namespace: team-a-dev }
spec: { engine: postgres, version: "16", size: small, highAvailability: true }
EOF
The ManagedDatabase "bad-db" is invalid: spec: Invalid value: "object":
  highAvailability requires size medium or large
```

**Immutability transition rule fires only on update:**

```console
$ kubectl patch mdb inventory-db -n team-a-prod --type merge -p '{"spec":{"engine":"mysql"}}'
The ManagedDatabase "inventory-db" is invalid: spec.engine: Invalid value: "string":
  engine is immutable once provisioned
```

**Field selectors (selectableFields, v1.32+) and the scale subresource:**

```console
$ kubectl get mdb -A --field-selector spec.engine=postgres
NAMESPACE     NAME           ENGINE     VERSION   SIZE     HA     PHASE   AGE
team-a-prod   inventory-db   postgres   16        medium   true   Ready   6m

$ kubectl scale mdb/inventory-db -n team-a-prod --replicas=3
manageddatabase.platform.acme.io/inventory-db scaled
$ kubectl get mdb inventory-db -n team-a-prod -o jsonpath='{.spec.readReplicas}{"\n"}'
3
```

**The VAP guardrail denies a non-compliant prod object:**

```console
$ kubectl apply -f - <<'EOF'
apiVersion: platform.acme.io/v1
kind: ManagedDatabase
metadata: { name: risky-db, namespace: team-b-prod }
spec: { engine: postgres, version: "16", size: medium, highAvailability: true,
        backup: { enabled: false } }
EOF
The manageddatabases "risky-db" is forbidden: ValidatingAdmissionPolicy
  'acme-manageddb-prod-guardrails' denied request: production databases must have backups enabled
```

---

## 5. Verification and failure diagnosis

### 5.1 The CRD never becomes usable

Read the CRD's conditions first — they are the ground truth:

```console
$ kubectl get crd manageddatabases.platform.acme.io -o jsonpath='{.status.conditions}' | jq
```

| Condition seen | Root cause | Fix |
|---|---|---|
| `NamesAccepted=False` (`reason: ListKindConflict` / `PluralConflict`) | Another CRD or built-in already owns that `plural`/`kind`/`shortName` | Rename in `spec.names`; short names are cluster-global |
| `Established=False` | Names accepted but API server hasn't wired the handler (often transient, or a bad schema) | Wait; if persistent, check apiserver logs |
| `NonStructuralSchema=True` | Schema violates structural rules (e.g. `type` missing, constraints under `oneOf`) | Make the schema structural; without it, defaults/CEL/pruning silently don't apply |
| Rejected at apply with `must have the api-approved.kubernetes.io annotation` | Group ends in `*.k8s.io` and lacks the approval annotation | Add the annotation with the approving PR URL, or use a non-`k8s.io` group |

### 5.2 A conversion webhook outage — the highest-severity CRD failure

If the conversion webhook is unreachable or its `caBundle` is stale, **every read of the resource fails, in every version** — because the API server must convert stored objects to the requested version on the way out:

```console
$ kubectl get mdb -A
Error from server: conversion webhook for platform.acme.io/v1, Kind=ManagedDatabase failed:
  Post "https://managed-db-conversion.acme-platform-system.svc:443/convert?timeout=30s":
  dial tcp 10.96.31.7:443: connect: connection refused
```

This is worse than it looks: your GitOps controller can no longer read the objects to reconcile them, backups of those objects fail, and `kubectl delete` may hang. Triage:

```console
# Is the webhook backend actually up?
$ kubectl get endpoints managed-db-conversion -n acme-platform-system
NAME                    ENDPOINTS                         AGE
managed-db-conversion   <none>                            12m          # <-- no ready pods

# Is the caBundle present and matching the serving cert?
$ kubectl get crd manageddatabases.platform.acme.io \
    -o jsonpath='{.spec.conversion.webhook.clientConfig.caBundle}' | wc -c
0                                                                       # <-- injection failed
```

**Prevention:** run the webhook with `replicas >= 2` and a PodDisruptionBudget, keep the CA injector healthy, and prefer `strategy: None` when versions are structurally identical (only the `apiVersion` string differs) so there is no webhook on the read path at all.

### 5.3 You cannot remove a deprecated version

`apiextensions` refuses to drop a version still listed in `status.storedVersions`, because objects encoded with it still live in etcd:

```console
$ kubectl get crd manageddatabases.platform.acme.io -o jsonpath='{.status.storedVersions}'
["v1alpha1","v1"]
```

You must **rewrite every stored object into the new storage version**, then prune `storedVersions`. Automate with the storage-version-migrator:

```console
$ kubectl apply -f - <<'EOF'
apiVersion: migration.k8s.io/v1alpha1
kind: StorageVersionMigration
metadata: { name: manageddatabases-to-v1 }
spec:
  resource: { group: platform.acme.io, version: v1, resource: manageddatabases }
EOF
storageversionmigration.migration.k8s.io/manageddatabases-to-v1 created

# After it reports Succeeded, storedVersions collapses to just the storage version:
$ kubectl get crd manageddatabases.platform.acme.io -o jsonpath='{.status.storedVersions}'
["v1"]
```

Now `v1alpha1` can be removed from `spec.versions`.

### 5.4 A stuck finalizer blocks namespace deletion

A CR with a finalizer will not be removed until its controller clears the finalizer; a `Terminating` namespace waits on it forever if the controller is gone:

```console
$ kubectl get ns team-a-dev
NAME         STATUS        AGE
team-a-dev   Terminating   19m

$ kubectl get mdb -n team-a-dev -o jsonpath='{range .items[*]}{.metadata.name}: {.metadata.finalizers}{"\n"}{end}'
scratch-db: ["platform.acme.io/deprovision"]
```

The **correct** fix is to make the controller healthy so it runs its cleanup and removes the finalizer. Force-removing the finalizer is a last resort and **leaks the external resource** the finalizer existed to clean up:

```console
$ kubectl patch mdb scratch-db -n team-a-dev --type merge -p '{"metadata":{"finalizers":[]}}'
```

### 5.5 Fields silently disappear (pruning)

If a submitted field is not in the structural schema, v1 CRDs **prune it** — no error, the data is just gone:

```console
$ kubectl apply -f - <<'EOF'
apiVersion: platform.acme.io/v1
kind: ManagedDatabase
metadata: { name: t, namespace: team-a-dev }
spec: { engine: postgres, version: "16", size: small, tuning: { sharedBuffers: "512MB" } }
EOF
$ kubectl get mdb t -n team-a-dev -o jsonpath='{.spec.tuning}{"\n"}'
                                          # empty: `tuning` was pruned — add it to the schema
```

**Diagnosis rule:** whenever "my field isn't saved," first confirm the field exists in the served version's `openAPIV3Schema`. Only add `x-kubernetes-preserve-unknown-fields: true` deliberately, for genuinely free-form subtrees.

### 5.6 Reconciliation health (the `observedGeneration` check)

A converged controller writes `status.observedGeneration = metadata.generation`. Divergence means the controller is behind or wedged:

```console
$ kubectl get mdb inventory-db -n team-a-prod \
  -o jsonpath='gen={.metadata.generation} observed={.status.observedGeneration} phase={.status.phase}{"\n"}'
gen=7 observed=5 phase=Provisioning        # controller has NOT yet acted on the last 2 spec edits

$ kubectl describe mdb inventory-db -n team-a-prod | sed -n '/Conditions/,/Events/p'
Conditions:
  Type       Status  Reason              Message
  Ready      False   WaitingForStorage   PVC inventory-db-0 pending: no PV for storageClass gp3-io2
  Degraded   True    ReplicaLag          replica 1 lag 42s exceeds threshold
```

### 5.7 Capacity awareness (CRDs are served by kube-apiserver)

Because custom resources live in the **same kube-apiserver process and etcd** as core objects, they consume the shared request budget (API Priority & Fairness) and etcd's storage/watch capacity. Watch for: very large per-object size, high CR counts driving watch-cache memory, and expensive CEL/webhooks inflating write latency. If a resource type is genuinely high-cardinality or high-churn, that is the signal to move it to an **aggregated API server** with its own backing store (Section 2.1).

---

## 6. References

- Kubernetes — Custom Resources (concepts): <https://kubernetes.io/docs/concepts/extend-kubernetes/api-extension/custom-resources/>
- Kubernetes — Extend the API with CustomResourceDefinitions: <https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/>
- Kubernetes — Structural schemas, pruning, defaulting: <https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/#specifying-a-structural-schema>
- Kubernetes — CRD versioning & conversion webhooks: <https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definition-versioning/>
- Kubernetes — Validation rules (CEL / `x-kubernetes-validations`): <https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/#validation-rules>
- Kubernetes — Common Expression Language in Kubernetes: <https://kubernetes.io/docs/reference/using-api/cel/>
- Kubernetes — Validating Admission Policy: <https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/>
- Kubernetes — API server aggregation layer: <https://kubernetes.io/docs/concepts/extend-kubernetes/api-extension/apiserver-aggregation/>
- Kubernetes — Setup an extension API server: <https://kubernetes.io/docs/tasks/extend-kubernetes/setup-extension-api-server/>
- Kubernetes — Server-Side Apply (`x-kubernetes-list-type`): <https://kubernetes.io/docs/reference/using-api/server-side-apply/>
- Kubernetes — Field selectors & CRD `selectableFields`: <https://kubernetes.io/docs/concepts/overview/working-with-objects/field-selectors/>
- Kubernetes — API deprecation policy: <https://kubernetes.io/docs/reference/using-api/deprecation-policy/>
- Kubernetes — RBAC and aggregated ClusterRoles: <https://kubernetes.io/docs/reference/access-authn-authz/rbac/#aggregated-clusterroles>
- kube-storage-version-migrator: <https://github.com/kubernetes-sigs/kube-storage-version-migrator>
- Kubebuilder book: <https://book.kubebuilder.io/>
- Operator SDK: <https://sdk.operatorframework.io/>
- Crossplane (CompositeResourceDefinitions): <https://docs.crossplane.io/latest/concepts/composite-resource-definitions/>
- CNCF Platforms White Paper (TAG App Delivery): <https://tag-app-delivery.cncf.io/whitepapers/platforms/>
- CNCF Curriculum (CNPA): <https://github.com/cncf/curriculum>