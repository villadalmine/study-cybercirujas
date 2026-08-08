# CNPA — Topic 5.2: API-Driven Service Catalogs and Infrastructure Abstractions

**Domain 5 — Platform APIs & Provisioning · Exam weight: 2.0 · Exam version 2025-04-01**

---

## 1. Motivation: the architectural problem behind self-service

A platform team of six cannot sit in the request path of two hundred application engineers. The moment "give me a Postgres database" or "provision a staging namespace with an ingress and a TLS cert" travels through a Jira ticket, three things happen that no amount of Terraform hygiene fixes:

1. **The platform team becomes a synchronous bottleneck.** Lead time for a change is now measured in human working hours, not machine seconds. This is the exact anti-pattern Team Topologies names a "collaboration" interaction where an "X-as-a-Service" interaction belongs.
2. **Knowledge leaks into every consumer.** If the application engineer must know the RDS instance class, the subnet group, the parameter group, the KMS key ARN, and the backup retention policy, then the "abstraction" has abstracted nothing. Cognitive load is pushed *out*, not *down*.
3. **Drift is invisible and unbounded.** A ticket-driven, one-shot `terraform apply` produces infrastructure that is correct at T0 and unverified forever after. Someone clicks in the console at T+30 days and no controller notices.

The cloud-native answer is to expose infrastructure **as an API on a control plane**, not as a script behind a human. The platform team publishes a small, opinionated, versioned API — `kind: PostgreSQLInstance` with three fields — and a controller continuously reconciles that declared intent into dozens of low-level resources (VPC associations, RDS instances, IAM roles, secrets), correcting drift on every loop. This is the **Kubernetes Resource Model (KRM)** generalized beyond containers: *declare desired state, let a reconciler converge reality to it, forever.*

The topic splits cleanly into two collaborating layers:

- **The infrastructure abstraction layer** — *what* the high-level API is and *how* it fans out into real resources (Crossplane, KRO, Score, Cluster API, OAM/KubeVela, the legacy Open Service Broker model).
- **The service catalog layer** — *how a human discovers, understands, and requests* those abstractions (Backstage Software Catalog + Scaffolder Templates, portals, golden paths).

An abstraction without a catalog is an API nobody can find. A catalog without abstractions is a pretty list of tickets. Production platforms need both, wired together: the catalog's "Create" button emits a manifest that the control plane reconciles.

> **The golden path.** The organizing principle across both layers is the *golden path*: the paved, supported, opinionated route to production. The abstraction encodes the guardrails (only these regions, encryption always on, backups mandatory); the catalog makes the path discoverable and the "Create" button makes it the path of least resistance. Deviating is still possible but no longer effortless — which is the entire point.

---

## 2. Technical comparison of abstraction approaches

There is no single tool. The exam expects you to reason about *which layer of the stack each tool abstracts* and *what the reconciliation model is*. The decisive axes are: **who is the consumer** (developer vs. platform engineer), **reconciliation model** (continuous control plane vs. one-shot pipeline), and **scope** (single workload vs. arbitrary cloud infrastructure).

### 2.1 The three levels of a Crossplane API (know these cold)

| Level | Kind (example) | Namespaced? | Who touches it | Purpose |
|---|---|---|---|---|
| **Claim (XRC)** | `PostgreSQLInstance` | Yes (namespaced) | Application team | The developer-facing, RBAC-scoped request. Team A cannot see Team B's claims. |
| **Composite (XR)** | `XPostgreSQLInstance` | No (cluster-scoped) | Platform (internal) | The cluster-scoped object a Claim binds to; the "instance" of the abstraction. |
| **Managed Resource (MR)** | `Instance` (`rds.aws.upbound.io`) | No | Provider controller | One real cloud object (an RDS instance). 1 Composition → N MRs. |

The chain is **Claim → Composite → Composition (the template) → N Managed Resources → cloud API**. The **XRD** (`CompositeResourceDefinition`) *defines the API schema* for the Claim and Composite; the **Composition** *implements* it by mapping fields to Managed Resources.

### 2.2 Cross-tool trade-off matrix

| Dimension | **Crossplane** | **KRO** (Kube Resource Orchestrator) | **Score** | **Backstage Scaffolder** | **OSB API / Service Catalog** |
|---|---|---|---|---|---|
| Primary consumer | Platform eng authors, dev consumes Claim | Platform eng authors, dev consumes CRD | Developer (workload author) | Developer (via portal UI) | Developer (via `svcat`/manifests) |
| Abstracts | Arbitrary cloud infra + K8s | Arbitrary K8s resource graphs | A single workload's runtime needs | Repo/service scaffolding + any CRD | Externally-brokered services |
| Reconciliation | **Continuous** control plane; corrects drift | **Continuous** control plane; corrects drift | **None** — it's a spec, needs a platform to interpret | **One-shot** at scaffold time | Continuous (broker-mediated) |
| Extends the K8s API? | Yes — generates CRDs from XRDs | Yes — generates CRDs from RGDs | No — translated to k8s/compose by CLI | No — writes files + triggers actions | Yes — `ServiceInstance`/`ServiceBinding` CRDs |
| Drift correction | Strong (every reconcile loop) | Strong | N/A | None (scaffold then forget) | Broker-dependent |
| Multi-cloud | Yes (providers) | Yes (any resource) | Yes (platform-agnostic by design) | Indirect | Yes (any broker) |
| State location | etcd (the cluster **is** the state) | etcd | etcd/compose file after generation | Git repo + entity in catalog | etcd + broker |
| Maturity / status | CNCF **incubating**, production-proven | CNCF Sandbox / early (2025) | CNCF Sandbox | CNCF **incubating** (portal) | **Archived** — legacy, avoid for new work |
| Sweet spot | Platform team owns cloud infra as APIs | Bundling K8s resources into one CRD without writing a controller | Decoupling dev intent from platform impl | Developer discovery + day-0 scaffolding | Brokered SaaS/marketplace integration (legacy) |

### 2.3 Control plane vs. pipeline IaC (the core exam distinction)

| Property | **Control-plane IaC** (Crossplane, KRO, CAPI) | **Pipeline IaC** (Terraform/OpenTofu in CI) |
|---|---|---|
| Execution | Continuous reconciliation loop | Discrete `plan`/`apply` runs |
| Drift | Detected **and corrected** automatically | Detected only when `plan` is next run |
| State | etcd (observed via the K8s API) | State file (S3/Cloud/local) — a separate source of truth to lock & protect |
| Failure mode | Partial convergence, self-heals over loops | Half-applied state, requires manual reconcile / `import` |
| Consumption | `kubectl apply` a Claim | Merge a PR, wait for pipeline |
| Guardrails | RBAC + admission (OPA/Kyverno) on the CRD | Policy-as-code (Sentinel/Conftest) in the pipeline |
| Best when | You want infra to *stay* converged and self-service | You have deep existing HCL, ephemeral runners, or non-reconciling providers |

> Hybrid is common and legitimate: `tofu-controller`/Terraform provider *inside* Crossplane lets you keep HCL modules while gaining continuous reconciliation. The abstraction consumer never sees the difference.

---

## 3. Complete, syntactically valid manifests

### 3.1 Crossplane — the full stack for a self-service Postgres

**(a) The API definition — `CompositeResourceDefinition` (XRD).** This *is* your published API contract.

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
  # Presence of claimNames is what makes this offerable as a namespaced Claim.
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
                      description: Allocated storage in GiB.
                      minimum: 20
                      maximum: 1000
                    region:
                      type: string
                      enum: ["us-east-1", "eu-west-1"]   # guardrail: only blessed regions
                    tier:
                      type: string
                      enum: ["dev", "prod"]
                      default: dev
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
                  description: Resolved database endpoint.
      additionalPrinterColumns:
        - name: ENDPOINT
          type: string
          jsonPath: .status.endpoint
```

**(b) The implementation — `Composition` in Pipeline mode** (the modern, function-based approach; the older inline `resources:` mode is deprecated in current Crossplane).

```yaml
apiVersion: apiextensions.crossplane.io/v1
kind: Composition
metadata:
  name: xpostgresqlinstances.aws
  labels:
    provider: aws
spec:
  compositeTypeRef:
    apiVersion: database.example.org/v1alpha1
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
                  engineVersion: "15.4"
                  instanceClass: db.t3.micro
                  username: masteruser
                  allocatedStorage: 20
                  storageEncrypted: true          # guardrail baked in, not optional
                  skipFinalSnapshot: true
                  publiclyAccessible: false        # guardrail baked in
                  autoGeneratePassword: true
                  passwordSecretRef:
                    namespace: crossplane-system
                    name: rds-master-pw
                    key: password
                writeConnectionSecretToRef:
                  namespace: crossplane-system
            patches:
              - type: FromCompositeFieldPath
                fromFieldPath: spec.parameters.storageGB
                toFieldPath: spec.forProvider.allocatedStorage
              - type: FromCompositeFieldPath
                fromFieldPath: spec.parameters.region
                toFieldPath: spec.forProvider.region
              - type: FromCompositeFieldPath
                fromFieldPath: spec.parameters.tier
                toFieldPath: spec.forProvider.instanceClass
                transforms:
                  - type: map
                    map:
                      dev: db.t3.micro
                      prod: db.r6g.large
              - type: ToCompositeFieldPath
                fromFieldPath: status.atProvider.endpoint
                toFieldPath: status.endpoint
            connectionDetails:
              - name: endpoint
                fromFieldPath: status.atProvider.endpoint
              - name: port
                fromFieldPath: status.atProvider.port
    - step: automatically-detect-ready
      functionRef:
        name: function-auto-ready
```

**(c) The developer-facing request — the Claim** (this is the *only* object an application engineer writes):

```yaml
apiVersion: database.example.org/v1alpha1
kind: PostgreSQLInstance
metadata:
  name: orders-db
  namespace: team-orders
spec:
  parameters:
    storageGB: 50
    region: us-east-1
    tier: prod
  writeConnectionSecretToRef:
    name: orders-db-conn      # secret lands in the team-orders namespace, ready for the app
```

### 3.2 KRO — bundling a K8s resource graph into one CRD without writing a controller

```yaml
apiVersion: kro.run/v1alpha1
kind: ResourceGraphDefinition
metadata:
  name: webapp
spec:
  # This block SYNTHESIZES a new CRD: kind WebApplication.
  schema:
    apiVersion: v1alpha1
    kind: WebApplication
    spec:
      name: string
      image: string
      replicas: integer | default=2
      ingressEnabled: boolean | default=false
    status:
      # CEL expression referencing another resource's live status — the graph is wired here.
      url: ${service.status.loadBalancer.ingress[0].hostname}
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
              containers:
                - name: app
                  image: ${schema.spec.image}
                  ports:
                    - containerPort: 8080
    - id: service
      template:
        apiVersion: v1
        kind: Service
        metadata:
          name: ${schema.spec.name}
        spec:
          type: LoadBalancer
          selector: { app: ${schema.spec.name} }
          ports:
            - port: 80
              targetPort: 8080
    - id: ingress
      # includeWhen gates a resource on a CEL condition — conditional graph edges.
      includeWhen:
        - ${schema.spec.ingressEnabled}
      template:
        apiVersion: networking.k8s.io/v1
        kind: Ingress
        metadata:
          name: ${schema.spec.name}
        spec:
          rules:
            - http:
                paths:
                  - path: /
                    pathType: Prefix
                    backend:
                      service:
                        name: ${schema.spec.name}
                        port: { number: 80 }
```

Consumers then apply a two-field CRD instance — KRO computes the dependency DAG (`service` before `status.url`, `ingress` only when enabled) and reconciles it:

```yaml
apiVersion: kro.run/v1alpha1
kind: WebApplication
metadata:
  name: storefront
  namespace: team-web
spec:
  name: storefront
  image: ghcr.io/acme/storefront:1.4.2
  replicas: 4
  ingressEnabled: true
```

### 3.3 Score — decoupling developer intent from platform implementation

`score.yaml` is authored by the developer and is **platform-agnostic**; a `score-*` CLI translates it to Docker Compose, Kubernetes, or Helm at deploy time.

```yaml
apiVersion: score.dev/v1b1
metadata:
  name: orders-api
containers:
  orders-api:
    image: ghcr.io/acme/orders-api:2.1.0
    variables:
      PORT: "8080"
      DB_CONNECTION: "postgres://${resources.db.username}:${resources.db.password}@${resources.db.host}:${resources.db.port}/${resources.db.name}"
    resources:
      limits:
        memory: "512Mi"
        cpu: "500m"
service:
  ports:
    www:
      port: 8080
      targetPort: 8080
resources:
  db:
    type: postgres          # abstract type — the platform decides RDS vs. CloudNativePG vs. a local container
  dns:
    type: dns
    class: sensitive
```

### 3.4 Backstage — the service catalog layer

**(a) `catalog-info.yaml`** — how a service registers itself as a discoverable entity, linked to its infrastructure:

```yaml
apiVersion: backstage.io/v1alpha1
kind: Component
metadata:
  name: orders-api
  description: Handles order lifecycle and fulfilment.
  annotations:
    backstage.io/techdocs-ref: dir:.
    backstage.io/kubernetes-id: orders-api
    github.com/project-slug: acme/orders-api
  tags: [go, http, tier-1]
  links:
    - url: https://runbooks.acme.io/orders
      title: Runbook
      icon: docs
spec:
  type: service
  lifecycle: production
  owner: team-orders
  system: commerce
  providesApis:
    - orders-api
  dependsOn:
    - resource:default/orders-db      # ties the catalog entity to the Crossplane-provisioned DB
```

**(b) A Scaffolder `Template`** — the "Create" button that emits the golden path (here: scaffold a repo *and* apply a Crossplane Claim):

```yaml
apiVersion: scaffolder.backstage.io/v1beta3
kind: Template
metadata:
  name: service-with-database
  title: New Service + Postgres (Golden Path)
  description: Scaffolds a Go service repo and provisions a managed Postgres via Crossplane.
spec:
  owner: platform-team
  type: service
  parameters:
    - title: Service details
      required: [name, owner]
      properties:
        name:
          title: Name
          type: string
          pattern: '^[a-z0-9-]+$'
        owner:
          title: Owner
          type: string
          ui:field: OwnerPicker
        storageGB:
          title: DB storage (GiB)
          type: integer
          default: 50
  steps:
    - id: fetch
      name: Fetch skeleton
      action: fetch:template
      input:
        url: ./skeleton
        values:
          name: ${{ parameters.name }}
          owner: ${{ parameters.owner }}
    - id: publish
      name: Publish to GitHub
      action: publish:github
      input:
        repoUrl: github.com?owner=acme&repo=${{ parameters.name }}
    - id: register
      name: Register in catalog
      action: catalog:register
      input:
        repoContentsUrl: ${{ steps.publish.output.repoContentsUrl }}
        catalogInfoPath: /catalog-info.yaml
  output:
    links:
      - title: Open in catalog
        icon: catalog
        entityRef: ${{ steps.register.output.entityRef }}
```

### 3.5 Legacy — Open Service Broker API (know it exists; do not build new on it)

The **Kubernetes Service Catalog** implemented the Open Service Broker API. **It is archived**; the KRM/Crossplane control-plane model superseded it. Recognize the shapes for the exam:

```yaml
apiVersion: servicecatalog.k8s.io/v1beta1
kind: ClusterServiceBroker
metadata:
  name: aws-servicebroker
spec:
  url: https://aws-servicebroker.example.com
---
apiVersion: servicecatalog.k8s.io/v1beta1
kind: ServiceInstance
metadata:
  name: my-rds
  namespace: team-orders
spec:
  clusterServiceClassExternalName: rds-postgresql
  clusterServicePlanExternalName: production
  parameters:
    allocatedStorage: 50
---
apiVersion: servicecatalog.k8s.io/v1beta1
kind: ServiceBinding
metadata:
  name: my-rds-binding
  namespace: team-orders
spec:
  instanceRef:
    name: my-rds
  secretName: my-rds-credentials
```

The parallel to Crossplane is exact: `ServiceInstance` ≈ Claim, `ServiceBinding` ≈ `writeConnectionSecretToRef`, the broker ≈ the provider. The difference is *who runs the reconciler* (an external broker over HTTP vs. an in-cluster provider controller).

---

## 4. CLI commands and real terminal output

### 4.1 Standing up the abstraction (platform engineer)

```console
$ kubectl apply -f xrd.yaml
compositeresourcedefinition.apiextensions.crossplane.io/xpostgresqlinstances.database.example.org created

$ kubectl apply -f composition.yaml
composition.apiextensions.crossplane.io/xpostgresqlinstances.aws created

$ kubectl get xrd
NAME                                        ESTABLISHED   OFFERED   AGE
xpostgresqlinstances.database.example.org   True          True      12s
```

`ESTABLISHED=True` means the CRDs were generated; `OFFERED=True` means the namespaced Claim CRD exists. **Both must be True or consumers cannot create Claims.**

```console
$ kubectl get composition
NAME                       XR-KIND               XR-APIVERSION                   AGE
xpostgresqlinstances.aws   XPostgreSQLInstance   database.example.org/v1alpha1   20s
```

### 4.2 Consuming the abstraction (application engineer)

```console
$ kubectl apply -f claim.yaml
postgresqlinstance.database.example.org/orders-db created

$ kubectl get postgresqlinstance -n team-orders
NAME        SYNCED   READY   CONNECTION-SECRET   AGE
orders-db   True     False   orders-db-conn      25s
```

`SYNCED=True, READY=False` is the normal *provisioning* state: the intent reached the cloud API, but RDS is still creating. Trace the full tree with the Crossplane CLI:

```console
$ crossplane beta trace postgresqlinstance/orders-db -n team-orders
NAME                              SYNCED   READY   STATUS
PostgreSQLInstance/orders-db      True     False   Waiting: ...resource claim is waiting for composite
└─ XPostgreSQLInstance/orders-db-7q2xk  True   False   Creating: ...
   └─ Instance/orders-db-7q2xk-rds      True   False   Creating: instance is in state 'creating'
```

After the cloud converges:

```console
$ kubectl get postgresqlinstance -n team-orders
NAME        SYNCED   READY   CONNECTION-SECRET   AGE
orders-db   True     True    orders-db-conn      6m14s

$ kubectl get secret orders-db-conn -n team-orders -o jsonpath='{.data.endpoint}' | base64 -d
orders-db-7q2xk.abc1234.us-east-1.rds.amazonaws.com
```

### 4.3 KRO

```console
$ kubectl apply -f webapp-rgd.yaml
resourcegraphdefinition.kro.run/webapp created

$ kubectl get rgd
NAME     APIVERSION   KIND             STATE    AGE
webapp   v1alpha1     WebApplication   Active   8s

$ kubectl apply -f storefront.yaml
webapplication.kro.run/storefront created

$ kubectl get webapplication -n team-web
NAME         STATE    SYNCED   AGE
storefront   ACTIVE   True     40s

$ kubectl get deploy,svc,ingress -n team-web -l app=storefront
NAME                          READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/storefront    4/4     4            4           38s
NAME                 TYPE           EXTERNAL-IP                       PORT(S)
service/storefront   LoadBalancer   a1b2c3.elb.us-east-1.aws.com      80:31840/TCP
NAME                                   CLASS   HOSTS   ADDRESS         AGE
ingress.networking.k8s.io/storefront   nginx   *       203.0.113.10    38s
```

### 4.4 Score

```console
$ score-k8s init
$ score-k8s generate score.yaml --output manifests.yaml
INFO: resource 'db' (postgres) provisioned via provisioner 'template://default/postgres'
INFO: wrote 3 manifests to manifests.yaml

$ kubectl apply -f manifests.yaml
deployment.apps/orders-api created
service/orders-api created
secret/orders-api-db created
```

### 4.5 Backstage catalog

```console
$ curl -s localhost:7007/api/catalog/entities/by-name/component/default/orders-api | jq '.spec'
{
  "type": "service",
  "lifecycle": "production",
  "owner": "team-orders",
  "system": "commerce"
}
```

---

## 5. Verification and failure diagnosis

The failure modes cluster around the *seams* between layers. Work the ladder top-down: is the API established → is the Claim bound → is the Composite synced → are the Managed Resources ready → did the connection secret propagate.

### 5.1 Diagnostic decision table

| Symptom | Most likely cause | Command to confirm | Fix |
|---|---|---|---|
| Claim CRD doesn't exist / `kubectl apply claim` → `no matches for kind` | XRD not `OFFERED` (no `claimNames`) or not `ESTABLISHED` | `kubectl get xrd` | Add `claimNames`; check XRD schema is valid |
| Claim stuck `SYNCED=False` | No Composition matches, or ambiguous selector | `kubectl describe postgresqlinstance orders-db -n …` → events | Set `compositionRef`/`defaultCompositionRef`; fix label selector |
| Claim `SYNCED=True, READY=False` **forever** | A Managed Resource is failing at the cloud API (quota, IAM, invalid param) | `crossplane beta trace …`; `kubectl describe instance …` | Read MR event `.status.conditions`; fix credentials/params |
| MR event: `cannot create: AccessDenied` | Provider `ProviderConfig` / IRSA credentials wrong | `kubectl get providerconfig -o yaml`; provider pod logs | Fix the referenced credential secret / IAM role |
| Connection secret never appears in app namespace | `writeConnectionSecretToRef` missing, or `connectionSecretKeys` not published by XRD | `kubectl get secret -n <app-ns>` | Add the ref to the Claim; declare keys in XRD + Composition |
| Composition changes but running XRs don't update | XR pinned to an old `compositionRevision` | `kubectl get compositionrevision` | Set `compositionUpdatePolicy: Automatic` |
| KRO CRD instance `SYNCED=False` | CEL expression references a field that never resolves | `kubectl describe <kind> …`; KRO controller logs | Fix `${...}` path; check resource `id` names |

### 5.2 Provider and control-plane health (Crossplane)

```console
$ kubectl get providers
NAME                    INSTALLED   HEALTHY   PACKAGE                                        AGE
provider-aws-rds        True        True      xpkg.upbound.io/upbound/provider-aws-rds:v1    3d

$ kubectl get providerconfig
NAME      AGE
default   3d

# If HEALTHY=False, the revision or a dependency is broken:
$ kubectl get providerrevision
$ kubectl -n crossplane-system logs deploy/provider-aws-rds-<hash> --tail=50
```

`INSTALLED=True, HEALTHY=False` means the package image pulled but the controller Deployment isn't Ready — almost always RBAC or a crash-looping pod. `kubectl -n crossplane-system get pods` and read the logs.

### 5.3 Validate *before* apply (shift left)

```console
# Render the Composition locally against a Claim — catches patch/transform bugs without touching the cloud:
$ crossplane render claim.yaml composition.yaml functions.yaml
---
apiVersion: rds.aws.upbound.io/v1beta1
kind: Instance
metadata:
  annotations:
    crossplane.io/composition-resource-name: rds-instance
spec:
  forProvider:
    allocatedStorage: 50
    instanceClass: db.r6g.large      # confirm the tier→class map fired
    region: us-east-1
    storageEncrypted: true

# Validate resources against provider CRD schemas:
$ crossplane beta validate crossplane.yaml claim.yaml
[✓] database.example.org/v1alpha1, Kind=PostgreSQLInstance, orders-db validated successfully
```

### 5.4 Confirm drift correction actually works (the value proposition)

The point of a control plane is that out-of-band changes are reverted. Prove it:

```console
# Someone disables encryption directly in AWS. Within one reconcile interval:
$ kubectl get instance orders-db-7q2xk-rds -o jsonpath='{.status.conditions[?(@.type=="Synced")]}'
{"reason":"ReconcileSuccess","status":"True","type":"Synced"}

$ kubectl describe instance orders-db-7q2xk-rds | grep -A2 "Late Init\|Update"
  Normal   UpdatedExternalResource   controller   Enterprise update: restored storageEncrypted=true
```

If drift is *not* corrected, check `managementPolicies` on the MR — a policy of `["Observe"]` (rather than the default full set) makes Crossplane read-only and it will *not* enforce.

### 5.5 Catalog-layer verification (Backstage)

```console
# Entity failed to appear? Check processing errors, not just the UI:
$ curl -s localhost:7007/api/catalog/entities/by-name/component/default/orders-api \
    | jq '.metadata.annotations["backstage.io/managed-by-location"], .status.items'
```

A malformed `catalog-info.yaml` surfaces as a `status.items[]` error on the entity (e.g. `InputError: owner is not a valid entity ref`) — the entity is registered but flagged, not silently dropped.

---

## 6. References

- CNCF Curriculum — *Certified Cloud Native Platform Engineering Associate (CNPA)*: https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf
- Crossplane — Composition, XRDs, Claims: https://docs.crossplane.io/latest/concepts/
- Crossplane — Composition Functions & `crossplane render`: https://docs.crossplane.io/latest/concepts/composition-functions/
- Crossplane CLI (`crossplane beta trace`, `validate`): https://docs.crossplane.io/latest/cli/
- KRO (Kube Resource Orchestrator) — ResourceGraphDefinition: https://kro.run/docs/overview
- Score specification (`score.dev/v1b1`): https://docs.score.dev/
- Backstage — Software Catalog (`catalog-info.yaml`): https://backstage.io/docs/features/software-catalog/descriptor-format/
- Backstage — Software Templates / Scaffolder: https://backstage.io/docs/features/software-templates/
- Open Service Broker API specification: https://github.com/openservicebrokerapi/servicebroker/blob/master/spec.md
- Kubernetes Service Catalog (archived, historical reference): https://github.com/kubernetes-retired/service-catalog
- Kubernetes — Custom Resources & the Kubernetes Resource Model: https://kubernetes.io/docs/concepts/extend-kubernetes/api-extension/custom-resources/
- CNCF Platforms Working Group — *Platforms White Paper* (golden paths, platform-as-product): https://tag-app-delivery.cncf.io/whitepapers/platforms/
- Cluster API (infrastructure abstraction for clusters): https://cluster-api.sigs.k8s.io/