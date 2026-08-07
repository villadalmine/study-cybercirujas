# CNPA 5.1 — Simplified Access to Platform Capabilities for Developers

> Domain 5 · *Platform APIs & Provisioning* · Exam weight **2.0** · Exam version 2025-04-01

---

## 1. Motivation: the architectural problem of "who holds the cognitive load"

An Internal Developer Platform (IDP) exists to make a proven, secure, compliant path the **easiest** path. The failure mode it corrects is well documented: on raw Kubernetes, shipping a single stateless service to production requires an application developer to author and reconcile — correctly, and *together* — a `Deployment`, `Service`, `Ingress`/`HTTPRoute`, `HorizontalPodAutoscaler`, `PodDisruptionBudget`, `NetworkPolicy`, `ServiceAccount`, RBAC, `ResourceQuota` awareness, probes, security context, an image-pull secret, a `ConfigMap`/`Secret`, and usually a database provisioned out-of-band via a ticket. That is 10–15 tightly-coupled API objects and roughly 300 lines of YAML for a "hello world." Kubernetes is a **platform for building platforms**, not a product for application developers — its API surface is intentionally low-level and composable, which is exactly what makes it a poor *direct* developer interface.

The CNCF Platforms White Paper frames this as the tension between **capabilities** (what the platform can do — provision clusters, deploy workloads, emit telemetry, manage secrets, issue certificates, hand out databases) and **interfaces** (how a consumer *invokes* a capability — API, CLI, GUI, docs, IaC module, ticket). Topic 5.1 is specifically about the interface layer: how you expose platform capabilities so that a developer consumes them with the *minimum necessary* Kubernetes knowledge, without stripping away the guardrails.

The organizing principles from Team Topologies and platform-engineering practice:

- **Reduce extraneous cognitive load.** The platform team (an *enabling* / *platform* team operating in an "X-as-a-Service" interaction mode) owns the accidental complexity — networking, IAM, cluster lifecycle — so stream-aligned teams spend their finite cognitive budget on the domain, not on the substrate.
- **Platform as a Product.** The interface has users, a backlog, versioning, docs, and adoption metrics. It is *pulled* by developers because it is the best option, not *pushed* by mandate. An interface nobody adopts is a failed product regardless of its technical elegance.
- **Golden paths (paved roads), not golden cages.** The default path is opinionated and self-service; escape hatches exist for the 5% of cases the abstraction does not cover, and using one is a signal to extend the platform — not to fork it.
- **Thinnest Viable Platform (TVP).** Start with the smallest thing that removes friction (often a well-written wiki page + a template repo), and only add machinery when the friction justifies it.

The design decision underneath every subsequent section is: **at what layer do you place the abstraction, and how do developers reach through it?**

---

## 2. The interface taxonomy and its trade-offs

### 2.1 The five interfaces (CNCF Platforms White Paper)

The white paper enumerates the ways a capability is exposed. A mature platform offers *several* over the *same* capability, because different personas and automation contexts prefer different entry points.

| Interface | Consumer persona | Strength | Weakness |
|---|---|---|---|
| **API** (Kubernetes CRDs, aggregated APIs) | Automation, GitOps controllers, other platforms | Declarative, versioned, machine-native, composable, gets RBAC/audit/GitOps *for free* | Not human-friendly; requires a client |
| **GUI / Portal** (Backstage, Port) | Application developers, especially onboarding | Discoverability, catalog, scaffolding, low barrier | Can hide too much; drift between portal state and cluster reality |
| **CLI** (`kubectl` plugins, custom `plat` CLI, `score`) | Developers in the inner loop, power users | Scriptable, fast, fits local dev | Yet another tool to install/version; discoverability is weak |
| **Docs / Templates / Golden Paths** (TechDocs, template repos) | Everyone | Cheapest to build; encodes the paved road | Static; rots if not tested/owned |
| **IaC modules** (Terraform/OpenTofu, Helm, Kustomize) | Ops-leaning teams, infra provisioning | Familiar, ecosystem-rich | Client-side state, drift, weaker RBAC story than an API |

**Key architectural insight for the exam:** building the abstraction *as a Kubernetes API* (a CRD, backed by an operator or by Crossplane) is disproportionately powerful, because it inherits `kubectl`, RBAC, admission control, audit logging, `kubectl explain`, watch/informers, and GitOps reconciliation *without you building any of it*. The portal and CLI then become thin clients over that API rather than parallel sources of truth.

### 2.2 Abstraction tooling compared

| Tool | Abstraction layer | Who runs the reconcile | Developer authors | Escape hatch | Best for |
|---|---|---|---|---|---|
| **Raw manifests + `kubectl`** | None | — | Everything | N/A | Never, for app devs |
| **Helm** | Template + package | Client (or Flux/Argo) | `values.yaml` | Edit chart | Packaging/distribution |
| **Kustomize** | Overlay/patch | Client (or GitOps) | Overlay dir | Any patch | Env variation of known base |
| **Score** (`score.dev`) | Workload spec, platform-agnostic | `score-k8s`/`score-compose` translator | ~15-line `score.yaml` | Drop to native manifests | Same spec across local & cluster |
| **Crossplane** | Custom API (XRD) → cloud + K8s resources | In-cluster controller | A *Claim* (few fields) | Author your own Composition | Provisioning infra as a self-service API |
| **kro** (Kube Resource Orchestrator) | Custom API from a graph of K8s resources | In-cluster controller | A CR of your kind | Edit the ResourceGraphDefinition | App-shaped abstractions, pure K8s |
| **Backstage** software templates | Scaffolding + catalog | Scaffolder (one-shot) | Fill a form | Edit generated repo | Day-0 bootstrapping, discovery |

The distinction that trips people up: **Backstage scaffolds once** (a day-0, imperative "create repo + PR" action), whereas **Crossplane/kro reconcile continuously** (day-2, declarative, drift-correcting). They are complementary — the Backstage form's output is often a Crossplane `Claim` committed to Git, then reconciled forever.

### 2.3 Consumption path trade-offs

| Path | Latency to running | Auditability | Drift risk | Fit |
|---|---|---|---|---|
| Portal → creates PR → GitOps reconciles | Minutes (review gate) | Excellent (Git history + K8s audit) | Low | Regulated, review-required |
| Portal → writes directly to cluster API | Seconds | Good (audit log) but no review | Medium | Trusted, fast inner loop |
| `kubectl apply` a Claim | Seconds | K8s audit only | Medium | Power users |
| GitOps-only (developer opens PR by hand) | Minutes | Excellent | Low | Ops-mature teams |

---

## 3. Complete, production-grade manifests

The worked example: a platform team exposes **"give me a Postgres"** and **"deploy my web app"** as self-service APIs, and a Backstage template to bootstrap a repo. Everything a developer touches is small; everything complex is owned by the platform team.

### 3.1 A self-service database API with Crossplane (XRD → Composition → Claim)

**Platform team authors the API surface (the XRD).** This defines the *developer-facing schema* — deliberately tiny, with sane defaults and enums as guardrails.

```yaml
# platform-team-owned: xrd-postgresql.yaml
apiVersion: apiextensions.crossplane.io/v1
kind: CompositeResourceDefinition
metadata:
  name: xpostgresqlinstances.platform.acme.io
spec:
  group: platform.acme.io
  names:
    kind: XPostgreSQLInstance
    plural: xpostgresqlinstances
  # The namespaced, developer-facing "Claim" type:
  claimNames:
    kind: PostgreSQLInstance
    plural: postgresqlinstances
  defaultCompositionRef:
    name: postgresql.aws.platform.acme.io
  connectionSecretKeys:
    - host
    - port
    - username
    - password
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
                    tier:
                      type: string
                      description: "dev = burstable/cheap, prod = HA/backed-up"
                      enum: ["dev", "prod"]
                      default: "dev"
                    storageGB:
                      type: integer
                      minimum: 20
                      maximum: 1000
                      default: 20
                    engineVersion:
                      type: string
                      enum: ["14", "15", "16"]
                      default: "16"
                  required: ["tier"]
              required: ["parameters"]
            status:
              type: object
              properties:
                endpoint:
                  type: string
```

**Platform team authors the implementation (the Composition).** Modern Crossplane (v1.14+) uses `mode: Pipeline` with composition functions. The developer never sees this file.

```yaml
# platform-team-owned: composition-postgresql-aws.yaml
apiVersion: apiextensions.crossplane.io/v1
kind: Composition
metadata:
  name: postgresql.aws.platform.acme.io
  labels:
    provider: aws
spec:
  compositeTypeRef:
    apiVersion: platform.acme.io/v1alpha1
    kind: XPostgreSQLInstance
  mode: Pipeline
  writeConnectionSecretsToNamespace: crossplane-system
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
                  region: us-east-1
                  engine: postgres
                  username: masteruser
                  autoGeneratePassword: true
                  masterPasswordSecretRef:
                    namespace: crossplane-system
                    key: password
                  skipFinalSnapshot: true
                  publiclyAccessible: false
                  storageEncrypted: true
                writeConnectionSecretToRef:
                  namespace: crossplane-system
            patches:
              - type: FromCompositeFieldPath
                fromFieldPath: spec.parameters.storageGB
                toFieldPath: spec.forProvider.allocatedStorage
              - type: FromCompositeFieldPath
                fromFieldPath: spec.parameters.engineVersion
                toFieldPath: spec.forProvider.engineVersion
              # Map the developer's abstract "tier" to a concrete instance class.
              - type: FromCompositeFieldPath
                fromFieldPath: spec.parameters.tier
                toFieldPath: spec.forProvider.instanceClass
                transforms:
                  - type: map
                    map:
                      dev: db.t3.micro
                      prod: db.r6g.large
              # prod gets multi-AZ + 7-day backups; dev does not.
              - type: FromCompositeFieldPath
                fromFieldPath: spec.parameters.tier
                toFieldPath: spec.forProvider.multiAz
                transforms:
                  - type: map
                    map: { dev: false, prod: true }
              - type: FromCompositeFieldPath
                fromFieldPath: spec.parameters.tier
                toFieldPath: spec.forProvider.backupRetentionPeriod
                transforms:
                  - type: map
                    map: { dev: 0, prod: 7 }
              # Surface the endpoint back to the developer's status.
              - type: ToCompositeFieldPath
                fromFieldPath: status.atProvider.address
                toFieldPath: status.endpoint
```

**Developer authors this — and nothing else.** Fifteen lines, no cloud knowledge, no networking, no IAM:

```yaml
# app-team-owned, committed to Git: orders-db.yaml
apiVersion: platform.acme.io/v1alpha1
kind: PostgreSQLInstance          # the namespaced Claim
metadata:
  name: orders-db
  namespace: team-orders
spec:
  parameters:
    tier: prod
    storageGB: 100
  compositionSelector:
    matchLabels:
      provider: aws
  writeConnectionSecretToRef:
    name: orders-db-conn          # app pulls host/port/user/pass from here
```

### 3.2 A self-service application API with kro (pure Kubernetes, no cloud)

kro (a CNCF Sandbox project) turns a *graph of standard Kubernetes resources* into a single custom API — ideal for app-shaped golden paths that stay inside the cluster.

```yaml
# platform-team-owned: rgd-webapp.yaml
apiVersion: kro.run/v1alpha1
kind: ResourceGraphDefinition
metadata:
  name: webapp.platform.acme.io
spec:
  schema:
    apiVersion: v1alpha1
    kind: WebApp
    spec:
      name: string
      image: string
      replicas: integer | default=2
      port: integer | default=8080
      ingress:
        enabled: boolean | default=false
        host: string | default=""
    status:
      # CEL, resolved from the live child resources:
      availableReplicas: ${deployment.status.availableReplicas}
      url: ${ingress.spec.rules[0].host}
  resources:
    - id: deployment
      template:
        apiVersion: apps/v1
        kind: Deployment
        metadata:
          name: ${schema.spec.name}
        spec:
          replicas: ${schema.spec.replicas}
          selector:
            matchLabels: { app: ${schema.spec.name} }
          template:
            metadata:
              labels: { app: ${schema.spec.name} }
            spec:
              securityContext:
                runAsNonRoot: true
                seccompProfile: { type: RuntimeDefault }
              containers:
                - name: main
                  image: ${schema.spec.image}
                  ports:
                    - containerPort: ${schema.spec.port}
                  resources:
                    requests: { cpu: "100m", memory: "128Mi" }
                    limits:   { cpu: "500m", memory: "512Mi" }
                  securityContext:
                    allowPrivilegeEscalation: false
                    readOnlyRootFilesystem: true
                    capabilities: { drop: ["ALL"] }
    - id: service
      template:
        apiVersion: v1
        kind: Service
        metadata:
          name: ${schema.spec.name}
        spec:
          selector: { app: ${schema.spec.name} }
          ports:
            - port: 80
              targetPort: ${schema.spec.port}
    - id: ingress
      includeWhen:
        - ${schema.spec.ingress.enabled}      # conditional resource
      template:
        apiVersion: networking.k8s.io/v1
        kind: Ingress
        metadata:
          name: ${schema.spec.name}
        spec:
          rules:
            - host: ${schema.spec.ingress.host}
              http:
                paths:
                  - path: /
                    pathType: Prefix
                    backend:
                      service:
                        name: ${service.metadata.name}
                        port: { number: 80 }
```

Developer-facing object — the golden path bakes in the security context, resource limits, and probes the platform team decided are mandatory:

```yaml
# app-team-owned: orders-webapp.yaml
apiVersion: kro.run/v1alpha1
kind: WebApp
metadata:
  name: orders-api
  namespace: team-orders
spec:
  name: orders-api
  image: ghcr.io/acme/orders-api:1.4.2
  replicas: 3
  ingress:
    enabled: true
    host: orders.acme.internal
```

### 3.3 A platform-agnostic workload spec with Score

Score decouples the *workload description* from *any single platform*. The same `score.yaml` runs locally via `score-compose` (Docker Compose) and in-cluster via `score-k8s`, so the inner loop matches production.

```yaml
# score.yaml — lives in the app repo
apiVersion: score.dev/v1b1
metadata:
  name: orders-api
containers:
  orders-api:
    image: ghcr.io/acme/orders-api:1.4.2
    variables:
      DB_HOST: "${resources.db.host}"
      DB_PORT: "${resources.db.port}"
      DB_NAME: "${resources.db.name}"
      DB_USER: "${resources.db.username}"
    resources:
      requests: { cpu: "250m", memory: "256Mi" }
      limits:   { cpu: "500m", memory: "512Mi" }
service:
  ports:
    http:
      port: 80
      targetPort: 8080
resources:
  db:
    type: postgres            # the platform decides HOW to satisfy "postgres"
  dns:
    type: dns
```

### 3.4 A Backstage software template (day-0 scaffolding)

The portal turns a form into a repo + a PR containing the golden-path files above, then registers the result in the software catalog for discoverability.

```yaml
# template-nodejs-service.yaml (registered in Backstage)
apiVersion: scaffolder.backstage.io/v1beta3
kind: Template
metadata:
  name: nodejs-microservice
  title: Node.js Microservice (golden path)
  description: Repo + CI + kro WebApp manifest, wired to the catalog
  tags: [recommended, nodejs]
spec:
  owner: group:platform-team
  type: service
  parameters:
    - title: Service metadata
      required: [name, owner]
      properties:
        name:
          title: Name
          type: string
          pattern: '^[a-z][a-z0-9-]{2,29}$'
        owner:
          title: Owner
          type: string
          ui:field: OwnerPicker
          ui:options: { catalogFilter: { kind: Group } }
    - title: Runtime
      required: [cluster]
      properties:
        cluster:
          title: Target cluster
          type: string
          enum: [dev, staging, prod]
          default: dev
  steps:
    - id: fetch
      name: Render skeleton
      action: fetch:template
      input:
        url: ./skeleton               # contains catalog-info.yaml + kro WebApp CR
        values:
          name: ${{ parameters.name }}
          owner: ${{ parameters.owner }}
          cluster: ${{ parameters.cluster }}
    - id: publish
      name: Publish to GitHub
      action: publish:github
      input:
        repoUrl: github.com?owner=acme&repo=${{ parameters.name }}
        defaultBranch: main
        protectDefaultBranch: true
    - id: register
      name: Register in catalog
      action: catalog:register
      input:
        repoContentsUrl: ${{ steps.publish.output.repoContentsUrl }}
        catalogInfoPath: /catalog-info.yaml
  output:
    links:
      - title: Repository
        url: ${{ steps.publish.output.remoteUrl }}
      - title: Open in catalog
        icon: catalog
        entityRef: ${{ steps.register.output.entityRef }}
```

### 3.5 The guardrail that makes self-service *safe*: scoped RBAC

Simplified access means a developer can create the **abstraction** but is *not* granted the underlying primitives. This is what keeps self-service from becoming "cluster-admin for everyone."

```yaml
# platform-team-owned: rbac-team-orders.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: developer-self-service
  namespace: team-orders
rules:
  # Developers CREATE the high-level Claims / CRs:
  - apiGroups: ["platform.acme.io"]
    resources: ["postgresqlinstances"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["kro.run"]
    resources: ["webapps"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  # ...but can only READ the low-level objects the platform generated:
  - apiGroups: ["apps"]
    resources: ["deployments"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["services", "configmaps", "secrets", "pods", "pods/log"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: developer-self-service
  namespace: team-orders
subjects:
  - kind: Group
    name: team-orders
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: developer-self-service
  apiGroup: rbac.authorization.k8s.io
```

---

## 4. CLI and real terminal output

**Discover the self-service APIs the platform offers (the "catalog" from the API side):**

```console
$ kubectl get xrd
NAME                                        ESTABLISHED   OFFERED   AGE
xpostgresqlinstances.platform.acme.io       True          True      21d

$ kubectl get resourcegraphdefinitions
NAME                        APIVERSION   KIND     STATE    AGE
webapp.platform.acme.io     v1alpha1     WebApp   Active   9d

$ kubectl api-resources --api-group=platform.acme.io
NAME                   SHORTNAMES   APIVERSION                    NAMESPACED   KIND
postgresqlinstances                 platform.acme.io/v1alpha1     true         PostgreSQLInstance
xpostgresqlinstances                platform.acme.io/v1alpha1     false        XPostgreSQLInstance
```

**Self-document the interface — `kubectl explain` reads the OpenAPI schema the XRD published, so the API is discoverable with no external docs:**

```console
$ kubectl explain postgresqlinstance.spec.parameters
KIND:     PostgreSQLInstance
VERSION:  platform.acme.io/v1alpha1

RESOURCE: parameters <Object>

FIELDS:
   engineVersion  <string>
     enum: 14, 15, 16 (default "16")
   storageGB      <integer>
     minimum 20, maximum 1000 (default 20)
   tier           <string>  -required-
     dev = burstable/cheap, prod = HA/backed-up. enum: dev, prod
```

**Verify a developer can actually self-serve *before* they hit a wall (impersonation):**

```console
$ kubectl auth can-i create postgresqlinstances -n team-orders \
    --as=jane --as-group=team-orders
yes

$ kubectl auth can-i create instances.rds.aws.upbound.io -n team-orders \
    --as=jane --as-group=team-orders
no
```

That `yes`/`no` pair is the whole thesis: **create the abstraction — yes; touch the primitive — no.**

**Provision, then watch the Claim converge:**

```console
$ kubectl apply -f orders-db.yaml
postgresqlinstance.platform.acme.io/orders-db created

$ kubectl get postgresqlinstance orders-db -n team-orders -w
NAME        SYNCED   READY   CONNECTION-SECRET   AGE
orders-db   True     False   orders-db-conn      8s
orders-db   True     False   orders-db-conn      3m
orders-db   True     True    orders-db-conn      6m40s

$ kubectl get secret orders-db-conn -n team-orders \
    -o jsonpath='{.data.host}' | base64 -d
orders-db-7q2mn-rds.abc123.us-east-1.rds.amazonaws.com
```

**Score: same spec, two targets:**

```console
$ score-k8s init
$ score-k8s generate score.yaml --output manifests.yaml
$ kubectl apply -f manifests.yaml
deployment.apps/orders-api created
service/orders-api created

# ...and locally, from the identical score.yaml:
$ score-compose generate score.yaml
$ docker compose up -d
[+] Running 3/3
 ✔ Container orders-api-db-1        Started
 ✔ Container orders-api-orders-api  Started
```

---

## 5. Verification and failure diagnosis

Self-service shifts a burden: when the abstraction breaks, the developer lacks the RBAC (by design) to see the primitive that failed. The platform team must provide a diagnosis path that reads *through* the layers. The single most important tool is Crossplane's trace, which renders the whole tree in one command.

**Healthy tree:**

```console
$ crossplane beta trace postgresqlinstance/orders-db -n team-orders
NAME                                         SYNCED   READY   STATUS
PostgreSQLInstance/orders-db (team-orders)   True     True    Available
└─ XPostgreSQLInstance/orders-db-7q2mn       True     True    Available
   └─ Instance/orders-db-7q2mn-rds           True     True    Available
```

**Failing tree — the failure surfaces at the leaf, not at the Claim:**

```console
$ crossplane beta trace postgresqlinstance/orders-db -n team-orders
NAME                                         SYNCED   READY   STATUS
PostgreSQLInstance/orders-db (team-orders)   True     False   Waiting: composed resources not ready
└─ XPostgreSQLInstance/orders-db-7q2mn       True     False   Creating
   └─ Instance/orders-db-7q2mn-rds           False    False   ReconcileError: cannot create: InvalidParameterValue:
                                                              DB instance class db.r6g.large not supported in us-east-1a
```

The Claim says `READY=False` with a generic "not ready"; the *cause* — an unsupported instance class produced by the `tier: prod` → `db.r6g.large` mapping in the Composition — is only visible at the managed-resource leaf, which the developer cannot read. Escalate to the platform team, who fixes the Composition, not the Claim.

### 5.1 A layered diagnosis checklist

| Symptom | Command | What it tells you |
|---|---|---|
| Claim rejected on apply | `kubectl apply` error / admission message | Schema validation (enum, min/max) — developer's input is wrong |
| Claim `SYNCED=False` | `kubectl describe postgresqlinstance …` → events | Composition selection failed / no matching Composition |
| Claim `SYNCED=True, READY=False` | `crossplane beta trace …` | A composed resource is stuck — read the leaf status |
| `WebApp`/kro CR stuck | `kubectl get webapp orders-api -o yaml` → `.status.conditions` | Which templated resource failed to apply/reconcile |
| "It says created but nothing runs" | `kubectl get events -n team-orders --sort-by=.lastTimestamp` | Quota denied, image pull, scheduling |
| Developer "permission denied" | `kubectl auth can-i <verb> <res> -n <ns> --as <user>` | RBAC gap in the self-service Role |
| Portal succeeded, cluster empty | Compare Git PR vs `kubectl get` | Drift between scaffold output and reconciled state |

**Diagnosing a stuck kro object:**

```console
$ kubectl get webapp orders-api -n team-orders -o jsonpath='{.status.conditions}' | jq
[
  {
    "type": "InstanceSynced",
    "status": "False",
    "reason": "ResourceApplyFailed",
    "message": "ingress.networking.k8s.io \"orders-api\" is invalid: spec.rules[0].host: required value — ingress.enabled=true but ingress.host is empty"
  }
]
```

The abstraction did its job: the error is expressed in terms of the *WebApp's* fields (`ingress.host`), not in terms of an `Ingress` object the developer never wrote.

**Confirming Composition selection (a common silent failure):**

```console
$ kubectl describe postgresqlinstance orders-db -n team-orders | sed -n '/Events/,$p'
Events:
  Type     Reason                   Age   From                Message
  ----     ------                   ----  ----                -------
  Warning  CompositionSelection     12s   defined/claim       no CompositionRevision matches labels {provider: gcp}
```

The `compositionSelector.matchLabels` in the Claim named a provider with no matching Composition — fix the Claim's selector or publish the missing Composition.

### 5.2 Acceptance criteria for "simplified access" (what to actually test)

- **Self-service works without a ticket:** an impersonated developer (`--as`) can create the Claim/CR and reach `READY=True`.
- **The blast radius is bounded:** the same developer gets `no` from `kubectl auth can-i` on every underlying primitive.
- **The interface is self-documenting:** `kubectl explain <kind>.spec` returns the schema with defaults and enums.
- **Golden-path defaults are enforced, not optional:** inspect a generated `Deployment` and confirm the security context, resource limits, and probes the developer never wrote are present.
- **Errors speak the developer's language:** an invalid input surfaces in terms of the abstraction's fields, not the primitives'.
- **Local == cluster (if using Score):** `score-compose` and `score-k8s` render the same workload from one spec.

---

## 6. References

- CNPA Curriculum (official domains and competencies) — https://github.com/cncf/curriculum/blob/master/CNPA_Curriculum.pdf
- CNCF Platforms White Paper (capabilities & interfaces taxonomy) — https://tag-app-delivery.cncf.io/whitepapers/platforms/
- CNCF Platform Engineering Maturity Model — https://tag-app-delivery.cncf.io/whitepapers/platform-eng-maturity-model/
- platformengineering.org — Internal Developer Platform reference — https://internaldeveloperplatform.org/
- Team Topologies (cognitive load, team interaction modes) — https://teamtopologies.com/key-concepts
- Crossplane documentation — Composite Resource Definitions & Compositions — https://docs.crossplane.io/latest/concepts/composite-resource-definitions/
- Crossplane composition functions — https://docs.crossplane.io/latest/concepts/compositions/
- kro (Kube Resource Orchestrator) documentation — https://kro.run/docs/
- Score specification — https://docs.score.dev/docs/score-specification/
- Backstage Software Templates (Scaffolder) — https://backstage.io/docs/features/software-templates/
- Backstage Software Catalog — https://backstage.io/docs/features/software-catalog/
- Kubernetes — Extending the API with CustomResourceDefinitions — https://kubernetes.io/docs/concepts/extend-kubernetes/api-extension/custom-resources/
- Kubernetes — Using RBAC Authorization — https://kubernetes.io/docs/reference/access-authn-authz/rbac/