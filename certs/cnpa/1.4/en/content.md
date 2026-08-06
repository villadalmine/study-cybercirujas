# 1.4 Platform Architecture and Core Capabilities

**Exam weight: 7.2 — Domain 1: Platform Engineering Core Fundamentals**

---

## 1. The production problem: why platform architecture exists

### 1.1 The failure mode without a platform

In an organization with 40 product teams shipping to Kubernetes, the absence of a platform does not mean "no platform" — it means **40 implicit platforms**, each a snowflake assembled from tribal knowledge:

- Every team writes its own Helm charts, Dockerfiles, Terraform modules, and CI pipelines. The organization pays the integration cost of `teams × tools` instead of `1 × tools`.
- Provisioning a database is a Jira ticket to an ops queue. Lead time for a change balloons from minutes to days; the ops team becomes a synchronous bottleneck and a single point of organizational failure.
- Security, cost controls, and observability are bolted on per team, after the fact. An audit finding ("all images must come from a scanned registry") triggers 40 uncoordinated remediation projects.
- Cognitive load on stream-aligned teams explodes: a backend developer must understand VPC peering, PodSecurity admission, IAM trust policies, and PromQL just to ship a REST endpoint.

A **cloud native platform** solves this by curating the underlying capabilities (compute, CI/CD, observability, secrets, data services) behind **consistent, self-service interfaces** — APIs, golden-path templates, CLIs, and portals — so that product teams consume capabilities as products rather than operate infrastructure. The CNCF Platforms White Paper defines a platform precisely this way: *"a platform for cloud-native computing is an integrated collection of capabilities defined and presented according to the needs of the platform's users."*

Two architectural principles follow directly and appear throughout the CNPA exam:

1. **Platform as a product.** The platform has users (developers), a roadmap driven by user research, SLOs, versioned interfaces, and deprecation policies. It is not a one-off infrastructure project.
2. **Thinnest Viable Platform (TVP).** From Team Topologies: build the smallest platform that reduces cognitive load for its users — sometimes that is literally a wiki page plus a paved-road pipeline — and grow it only in response to measured demand. Over-building a platform nobody asked for is the most common failure mode of platform initiatives.

### 1.2 The CNCF Platform Engineering Maturity Model

The CNCF TAG App Delivery publishes a maturity model with five aspects, each progressing through four levels. You should be able to place an organization on this grid:

| Aspect | Level 1 — Provisional | Level 2 — Operational | Level 3 — Scalable | Level 4 — Optimizing |
|---|---|---|---|---|
| **Investment** | Voluntary / side-project | Dedicated team | Product team with PM | Enabled ecosystem, funded as product |
| **Adoption** | Erratic, forced | Extrinsic push (mandates) | Intrinsic pull (teams choose it) | Participatory — users contribute |
| **Interfaces** | Ad-hoc tickets, tribal docs | Standard tooling, some docs | Self-service APIs & golden paths | Managed, versioned services |
| **Operations** | Reactive, by request | Centrally tracked | Centrally enabled, delegated | Self-healing, autonomous |
| **Measurement** | None / anecdotal | Ad-hoc metrics | Insights from usage data | Quantitative + qualitative feedback loops |

The architectural implication: **maturity level constrains architecture**. Self-service APIs (Level 3 Interfaces) require a control-plane architecture with declarative resource management; you cannot bolt self-service onto a ticket-driven workflow.

---

## 2. Architectural anatomy: the planes of a platform

### 2.1 The five planes

Industry reference architectures (and the CNCF Platforms White Paper's capability mapping) converge on a layered model. A production Internal Developer Platform (IDP) decomposes into five planes:

```
┌────────────────────────────────────────────────────────────────────┐
│ DEVELOPER CONTROL PLANE                                            │
│   Portal (Backstage) · Service catalog · Templates · CLI · IDE     │
│   Workload specs (Score, OAM) · Git repositories                   │
├────────────────────────────────────────────────────────────────────┤
│ INTEGRATION & DELIVERY PLANE                                       │
│   CI (Tekton, GitHub Actions) · Registry (Harbor)                  │
│   CD / GitOps controllers (Argo CD, Flux) · Platform Orchestrator  │
├────────────────────────────────────────────────────────────────────┤
│ RESOURCE PLANE                                                     │
│   Kubernetes clusters · Databases · Queues · Object storage        │
│   DNS · Provisioned via Crossplane / Cluster API / OpenTofu        │
├──────────────────────────────┬─────────────────────────────────────┤
│ MONITORING & LOGGING PLANE   │ SECURITY PLANE                      │
│   Prometheus · OpenTelemetry │   Secrets (Vault, ESO)              │
│   Grafana · Loki · Alerting  │   Identity (SPIFFE/SPIRE, OIDC)     │
│   SLOs, cost visibility      │   Policy (OPA, Kyverno) · cert-mgr  │
└──────────────────────────────┴─────────────────────────────────────┘
```

- **Developer Control Plane** — everything the developer touches directly. The design goal is *low cognitive load*: developers declare intent ("I need a Postgres and a public route"), never implementation.
- **Integration & Delivery Plane** — turns intent into running state: build, scan, store, deploy. In GitOps architectures this plane is *pull-based*: controllers inside the cluster reconcile from Git, so CI never holds cluster credentials.
- **Resource Plane** — the actual infrastructure. Critically, in a mature platform the resource plane is *never mutated directly by humans*; it is materialized by controllers from declarative specs.
- **Monitoring & Logging Plane** — telemetry for both the workloads *and the platform itself*. A platform must publish its own SLOs (e.g., "P95 time from claim creation to database ready < 10 min").
- **Security Plane** — cross-cutting: identity for humans (OIDC/SSO) and workloads (SPIFFE/SPIRE), secrets distribution, policy enforcement, supply-chain attestation.

### 2.2 Control plane vs data plane

The single most important architectural distinction in this topic:

- The **data plane** does the work: pods serving traffic, databases storing rows, brokers moving messages.
- The **control plane** decides and reconciles: it holds *desired state*, observes *actual state*, and continuously converges the two.

Kubernetes is the canonical implementation: `etcd` stores desired state, the `kube-apiserver` is the uniform declarative API front door, and controllers run reconciliation loops (*observe → diff → act*). A cloud native platform generalizes this: **the platform is itself a control plane** whose API surface is extended with organization-specific resource types via **CustomResourceDefinitions (CRDs)**, and whose reconciliation is performed by **operators/controllers** (Crossplane, Cluster API, cert-manager, external-secrets are all instances of this one pattern).

Why the control-plane pattern wins in production over imperative pipelines (e.g., a Jenkins job that runs `terraform apply`):

| Property | Imperative pipeline | Declarative control plane |
|---|---|---|
| Drift handling | Detected only on next run (if at all) | Continuously reconciled, self-healing |
| Failure semantics | Partial applies leave unknown state | Idempotent convergence; retry is safe |
| Audit / rollback | Buried in job logs | Desired state versioned in Git + API |
| Self-service | Needs pipeline access, sequencing | `kubectl apply` / PR by any authorized team |
| Multi-tenancy | Bespoke per pipeline | Native: RBAC + namespaces on the API |
| Day-2 (resize, upgrade) | New pipeline per operation | Edit spec; controller executes the transition |

### 2.3 Where does the platform control plane run?

A production decision with real trade-offs:

| Topology | Description | Pros | Cons |
|---|---|---|---|
| **Single management cluster (hub-and-spoke)** | One cluster runs Crossplane, Argo CD, Cluster API; workload clusters are pure data plane | Central audit, one upgrade surface, clean separation | Blast radius: management cluster outage freezes all provisioning (running workloads unaffected); needs its own DR story |
| **Per-cluster controllers** | Each workload cluster runs its own GitOps + provisioning stack | Autonomy, no central SPOF, cell-based isolation | N× upgrade toil, config drift between cells, fragmented audit |
| **Hierarchical (fleet)** | Hub manages spokes; spokes run local reconcilers fed by the hub | Scales to fleets, survives hub outage (spokes keep reconciling last-known state) | Most complex; two layers to reason about during incidents |

Key production insight: because GitOps controllers *pull* and cache desired state, a hub outage degrades gracefully — spokes keep converging toward the last synced state. This is a deliberate architectural property, not luck.

---

## 3. Core capabilities of a cloud native platform

The CNCF Platforms White Paper enumerates the capability domains a platform typically curates. Learn this mapping — the exam tests both the *capability* and representative *CNCF projects*:

| Capability domain | What the platform provides | Representative projects |
|---|---|---|
| **Web portals & catalogs** | Discoverability: service catalog, docs (TechDocs), scorecards, ownership | Backstage |
| **APIs & golden-path templates** | Machine-consumable self-service; scaffolding with security/observability built in | Crossplane, KubeVela (OAM), Backstage Software Templates, Score |
| **CI/CD & artifact storage** | Build, test, scan, sign, store, deploy via GitOps | Tekton, Argo CD, Flux, Harbor |
| **Infrastructure & environment provisioning** | Clusters, namespaces, ephemeral environments as a service | Cluster API, Crossplane, OpenTofu/Terraform, vcluster |
| **Observability** | Metrics, logs, traces, SLOs, cost — instrumented by default | Prometheus, OpenTelemetry, Grafana, Loki, Jaeger, OpenCost |
| **Secrets & identity management** | Secret storage/rotation, workload identity, human SSO | Vault, External Secrets Operator, SPIFFE/SPIRE, cert-manager, Keycloak/Dex |
| **Messaging & data services** | Queues, streams, databases as managed platform services | NATS, Kafka (Strimzi), operator-managed Postgres (CloudNativePG) |
| **Security & policy** | Admission policy, supply-chain verification, runtime security | OPA/Gatekeeper, Kyverno, Falco, in-toto/Sigstore |

Two architectural rules govern how capabilities are exposed:

1. **API-first, GUI-second.** Every capability must be consumable programmatically (CRD, REST) before it gets a portal page. The portal is a *view over the API*, never the only path — otherwise automation, ephemeral environments, and disaster recovery are impossible.
2. **Golden paths, not golden cages.** The paved road (template + pipeline + defaults) is the easy 80% path with security and observability pre-wired. Teams may leave it, but they inherit the operational burden — the platform must not hard-block escape hatches, or intrinsic adoption (maturity Level 3) dies.

---

## 4. Interfaces and abstraction: trade-off analysis

### 4.1 How developers interact with the platform

| Interface | Best for | Strengths | Weaknesses |
|---|---|---|---|
| **Portal / GUI (Backstage)** | Discovery, onboarding, day-1 scaffolding | Lowest entry barrier; aggregates catalog + docs + CI status | Not automatable; can drift from API truth if it writes directly |
| **CLI** | Power users, scripting, local loops | Composable, CI-friendly | Discoverability poor; version skew across laptops |
| **Declarative API (CRDs + GitOps)** | Everything that must be repeatable and audited | Reviewable (PRs), reconciled, RBAC-native, DR-friendly | YAML fatigue; steepest learning curve |
| **ChatOps / ticket fallback** | Exceptions, approvals | Human judgment in the loop | Doesn't scale; the thing the platform exists to eliminate |

Production rule: **Git is the interface of record**; portal and CLI are ergonomic front-ends that ultimately produce commits or API objects — never a parallel source of truth.

### 4.2 The abstraction spectrum

Choosing how much Kubernetes to hide is the central design tension:

| Level | Example | Developer cognitive load | Flexibility | Leak risk when things break |
|---|---|---|---|---|
| Raw manifests | `Deployment` + `Service` + `Ingress` per team | Very high | Total | None (nothing is hidden) |
| Templating | Helm chart with org values | High | High | Medium — values interface drifts |
| Workload spec | Score / OAM `Application` | Medium | Medium | Medium — spec must cover real needs |
| Platform API | `PostgresInstance` claim (Crossplane) | Low | Constrained by design | High if abstraction is leaky: developer sees `Ready: False` but the cause is an AWS quota |
| Full PaaS | "git push → running app" | Minimal | Lowest | Highest — debugging requires platform team |

The mitigation for leak risk is **transparent abstractions**: hide the *doing*, not the *observing*. Tools like `crossplane beta trace` (§6) exist precisely so a consumer can walk the abstraction chain when Ready is False.

### 4.3 Multi-tenancy models in the resource plane

| Model | Isolation boundary | Cost efficiency | Blast radius | Typical use |
|---|---|---|---|---|
| **Namespace-as-a-Service** | Namespace + RBAC + NetworkPolicy + quotas | Best | Shared control plane & nodes: noisy neighbors, CRD/version conflicts | Trusted internal teams |
| **Cluster-as-a-Service** | Full cluster per team (Cluster API) | Worst (control-plane tax × N) | Minimal | Regulated workloads, hard isolation |
| **Virtual clusters (vcluster)** | Virtual control plane per tenant on shared nodes | Middle | Tenant gets own API server/CRDs; nodes still shared | Ephemeral envs, CRD-heavy teams |

---

## 5. Reference implementation: a platform API end to end

The following is a complete, valid implementation of one platform capability — *database-as-a-service* — using Crossplane v2-style composition (v1 APIs), exposed to developers as a namespaced `PostgresInstance` claim and surfaced in Backstage.

### 5.1 The API definition (XRD): the platform's contract

```yaml
apiVersion: apiextensions.crossplane.io/v1
kind: CompositeResourceDefinition
metadata:
  name: xpostgresinstances.platform.acme.io
spec:
  group: platform.acme.io
  names:
    kind: XPostgresInstance
    plural: xpostgresinstances
  claimNames:
    kind: PostgresInstance
    plural: postgresinstances
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
                    size:
                      type: string
                      enum: ["small", "medium", "large"]
                      default: "small"
                      description: T-shirt size mapped to instance class by the platform.
                    storageGB:
                      type: integer
                      minimum: 20
                      maximum: 500
                      default: 20
                    highAvailability:
                      type: boolean
                      default: false
                  required:
                    - size
              required:
                - parameters
```

Architectural notes:

- The schema **is the abstraction**: developers choose `small|medium|large`; the platform owns the mapping to instance classes, engine versions, backup policy, and region. Changing `medium` from `db.m6i.large` to `db.m7g.large` is a platform decision requiring zero developer changes.
- `claimNames` makes the API **namespaced**, so standard Kubernetes RBAC and ResourceQuota govern who may request databases — multi-tenancy for free.
- OpenAPI validation (`enum`, `minimum`, `maximum`) enforces guardrails *at admission time*, before any cloud call is made.

### 5.2 The Composition: the platform's implementation

```yaml
apiVersion: apiextensions.crossplane.io/v1
kind: Composition
metadata:
  name: xpostgresinstances.aws.platform.acme.io
  labels:
    provider: aws
spec:
  writeConnectionSecretsToNamespace: crossplane-system
  compositeTypeRef:
    apiVersion: platform.acme.io/v1alpha1
    kind: XPostgresInstance
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
              apiVersion: rds.aws.upbound.io/v1beta1
              kind: Instance
              spec:
                forProvider:
                  region: eu-west-1
                  engine: postgres
                  engineVersion: "16.3"
                  instanceClass: db.t3.small
                  allocatedStorage: 20
                  username: appadmin
                  autoGeneratePassword: true
                  passwordSecretRef:
                    namespace: crossplane-system
                    name: rds-master-password
                    key: password
                  storageEncrypted: true
                  publiclyAccessible: false
                  multiAz: false
                  skipFinalSnapshot: false
                  backupRetentionPeriod: 14
            patches:
              - type: FromCompositeFieldPath
                fromFieldPath: spec.parameters.storageGB
                toFieldPath: spec.forProvider.allocatedStorage
              - type: FromCompositeFieldPath
                fromFieldPath: spec.parameters.highAvailability
                toFieldPath: spec.forProvider.multiAz
              - type: FromCompositeFieldPath
                fromFieldPath: spec.parameters.size
                toFieldPath: spec.forProvider.instanceClass
                transforms:
                  - type: map
                    map:
                      small: db.t3.small
                      medium: db.m6i.large
                      large: db.m6i.2xlarge
            connectionDetails:
              - name: username
                type: FromFieldPath
                fromFieldPath: spec.forProvider.username
              - name: password
                type: FromConnectionSecretKey
                fromConnectionSecretKey: attribute.password
              - name: endpoint
                type: FromFieldPath
                fromFieldPath: status.atProvider.address
              - name: port
                type: FromFieldPath
                fromFieldPath: status.atProvider.port
```

Notes:

- The `base` encodes **non-negotiable production posture**: encryption on, not publicly accessible, 14-day backups, final snapshot required. Developers cannot opt out because these fields are not in the XRD schema.
- The `provider: aws` label enables **implementation selection**: a second Composition labeled `provider: gcp` (CloudSQL) can serve the *same* API — the abstraction is portable, the implementation is swappable.
- Connection details flow into a Kubernetes Secret in the claim's namespace — the developer never handles cloud credentials.

### 5.3 The claim: what the developer writes

This is the entire developer experience — 13 lines:

```yaml
apiVersion: platform.acme.io/v1alpha1
kind: PostgresInstance
metadata:
  name: orders-db
  namespace: team-checkout
spec:
  parameters:
    size: medium
    storageGB: 100
    highAvailability: true
  compositionSelector:
    matchLabels:
      provider: aws
  writeConnectionSecretToRef:
    name: orders-db-conn
```

### 5.4 Catalog integration: making it discoverable

The consuming service registers in the Backstage catalog and declares its dependency, closing the loop between the developer control plane and the resource plane:

```yaml
apiVersion: backstage.io/v1alpha1
kind: Component
metadata:
  name: checkout-service
  description: Order checkout API for the commerce system.
  annotations:
    github.com/project-slug: acme/checkout-service
    backstage.io/kubernetes-id: checkout-service
  tags:
    - go
    - grpc
spec:
  type: service
  lifecycle: production
  owner: team-checkout
  system: commerce
  dependsOn:
    - resource:orders-db
```

### 5.5 What the developer sees

```
$ kubectl apply -f orders-db-claim.yaml
postgresinstance.platform.acme.io/orders-db created

$ kubectl get postgresinstance -n team-checkout
NAME        SYNCED   READY   CONNECTION-SECRET   AGE
orders-db   True     False   orders-db-conn      15s

# ~8 minutes later (RDS provisioning time)
$ kubectl get postgresinstance -n team-checkout
NAME        SYNCED   READY   CONNECTION-SECRET   AGE
orders-db   True     True    orders-db-conn      8m41s

$ kubectl get secret orders-db-conn -n team-checkout \
    -o jsonpath='{.data.endpoint}' | base64 -d
orders-db-x8k2p.c9xyzexample.eu-west-1.rds.amazonaws.com
```

---

## 6. Verification and failure diagnosis

### 6.1 Verify the platform API surface

Confirm the API is actually served and offered before blaming anything else:

```
$ kubectl get xrd
NAME                                  ESTABLISHED   OFFERED   AGE
xpostgresinstances.platform.acme.io   True          True      3d2h
```

`ESTABLISHED=True` means the composite CRD is served; `OFFERED=True` means the *claim* CRD exists. If `OFFERED` is empty, `claimNames` is missing from the XRD.

```
$ kubectl api-resources --api-group=platform.acme.io
NAME                 SHORTNAMES   APIVERSION                  NAMESPACED   KIND
postgresinstances                 platform.acme.io/v1alpha1   true         PostgresInstance
xpostgresinstances                platform.acme.io/v1alpha1   false        XPostgresInstance
```

Verify the machinery underneath is healthy — an unhealthy provider or function silently stalls every composition that uses it:

```
$ kubectl get providers.pkg.crossplane.io
NAME                          INSTALLED   HEALTHY   PACKAGE                                               AGE
provider-aws-rds              True        True      xpkg.upbound.io/upbound/provider-aws-rds:v1.9.0       3d
provider-family-aws           True        True      xpkg.upbound.io/upbound/provider-family-aws:v1.9.0    3d

$ kubectl get functions.pkg.crossplane.io
NAME                          INSTALLED   HEALTHY   PACKAGE                                                        AGE
function-patch-and-transform  True        True      xpkg.upbound.io/crossplane-contrib/function-patch-and-transform:v0.7.0   3d
```

### 6.2 Runbook: a claim stuck `READY: False`

Walk the abstraction chain top-down. This is the transparent-abstraction principle in practice.

**Step 1 — trace the composite tree:**

```
$ crossplane beta trace postgresinstance orders-db -n team-checkout
NAME                                   SYNCED   READY   STATUS
PostgresInstance/orders-db (team-checkout)   True     False   Waiting: claim is waiting for composite resource to become ready
└─ XPostgresInstance/orders-db-x8k2p         True     False   Creating
   └─ Instance/orders-db-x8k2p-rds           True     False   Creating: InvalidParameterCombination: Cannot create a
                                                              db.m6i.2xlarge Multi-AZ instance: quota exceeded
```

The leaf status pinpoints the real cause (cloud quota) without the developer needing AWS console access.

**Step 2 — if the trace is empty or the claim shows `SYNCED: False`, read events:**

```
$ kubectl describe postgresinstance orders-db -n team-checkout
...
Events:
  Type     Reason                   Age    From                                 Message
  ----     ------                   ----   ----                                 -------
  Warning  CannotSelectComposition  2m10s  offered/compositeresourcedefinition  cannot select composition:
           no compatible Compositions found: no Composition matches labels {provider: gcp}
```

Classic causes: label typo in `compositionSelector`, or the Composition's `compositeTypeRef` doesn't match the XRD group/kind/version exactly.

**Step 3 — schema rejection happens at admission, so it surfaces immediately:**

```
$ kubectl apply -f bad-claim.yaml
The PostgresInstance "orders-db" is invalid:
spec.parameters.size: Unsupported value: "xlarge": supported values: "small", "medium", "large"
```

This is the guardrail working, not a platform failure.

**Step 4 — controller-level diagnosis (platform team scope):**

```
$ kubectl -n crossplane-system logs deploy/crossplane --since=10m | grep -i orders-db
$ kubectl -n crossplane-system logs -l pkg.crossplane.io/provider=provider-aws-rds --since=10m
```

Look for `AccessDenied` (ProviderConfig credentials / IRSA trust policy broken) and throttling (`Rate exceeded` — the provider will back off and converge; noisy but self-healing).

### 6.3 Platform-level failure patterns

| Symptom | Likely layer | First check | Root causes |
|---|---|---|---|
| Claim rejected on `apply` | API schema (admission) | Error message itself | Guardrail violation — fix the claim |
| `SYNCED: False`, event `CannotSelectComposition` | Composition binding | `kubectl describe` claim | Selector labels, `compositeTypeRef` mismatch |
| `SYNCED: True, READY: False` for a long time | Managed resource / cloud | `crossplane beta trace` | Quotas, IAM, invalid parameter combos, slow provisioning |
| Everything stuck, no events anywhere | Provider/controller | `kubectl get providers`, controller logs, `kubectl top -n crossplane-system` | Unhealthy provider pod, expired credentials, OOMKilled controller |
| Connection secret missing though `READY: True` | Composition wiring | `connectionDetails` + XRD `connectionSecretKeys` | Key not listed in XRD, missing `writeConnectionSecretToRef` |
| Portal shows stale/missing data | Developer control plane | Backstage catalog processor logs | Portal view drifting from API truth — the API remains authoritative |
| Nothing provisions org-wide | Management cluster | Hub cluster health, GitOps controller status | Hub outage: running workloads fine, new intent frozen — this is the documented blast radius of hub-and-spoke |

**Platform SLO practice:** instrument the claim lifecycle itself. `time(READY=True) − time(created)` per claim kind is the platform's core latency SLI; the ratio of claims reaching Ready within target is its availability SLI. A platform that cannot measure itself is at maturity Level 1 regardless of its tooling.

---

## Referencias

- CNCF Platforms White Paper — https://tag-app-delivery.cncf.io/whitepapers/platforms/
- CNCF Platform Engineering Maturity Model — https://tag-app-delivery.cncf.io/whitepapers/platform-eng-maturity-model/
- CNPA Certification (CNCF) — https://www.cncf.io/training/certification/cnpa/
- CNPA Curriculum — https://github.com/cncf/curriculum
- Kubernetes: Custom Resources & API extension — https://kubernetes.io/docs/concepts/extend-kubernetes/api-extension/custom-resources/
- Kubernetes: Controllers and reconciliation — https://kubernetes.io/docs/concepts/architecture/controller/
- Kubernetes: Operator pattern — https://kubernetes.io/docs/concepts/extend-kubernetes/operator/
- Crossplane documentation (XRDs, Compositions, Claims) — https://docs.crossplane.io/latest/
- Backstage documentation — https://backstage.io/docs/overview/what-is-backstage/
- Score workload specification — https://docs.score.dev/
- KubeVela / Open Application Model — https://kubevela.io/docs/
- Cluster API — https://cluster-api.sigs.k8s.io/
- vcluster documentation — https://www.vcluster.com/docs
- Team Topologies (platform teams, TVP) — https://teamtopologies.com/key-concepts