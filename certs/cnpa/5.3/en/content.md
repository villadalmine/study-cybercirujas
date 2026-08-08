# 5.3 Developer Portals for Platform Adoption (Backstage)

> **CNPA Domain 5 — Platform Engineering & Developer Experience**
> Exam weight: **2.0** · Reference syllabus: CNCF *Cloud Native Platform Engineering Associate* (CNPA), version 2025-04-01.

A platform that no one can find, understand, or self-serve is not a platform — it is a private tool. This topic is about the **presentation and self-service layer** of an Internal Developer Platform (IDP): the *portal*. Backstage is the CNCF's reference implementation and the one named in the CNPA syllabus, so we study it as the concrete artifact while keeping the architectural pattern portable.

---

## 1. Motivation and the production architectural problem

### 1.1 The scaling failure a portal fixes

At small scale, a developer knows every service, who owns it, where its runbook is, and how to spin up a new one. That knowledge lives in people's heads and in Slack scrollback. It does **not** survive growth. The failure is combinatorial: with `N` services and `M` engineers, the number of "who owns X / where is Y / how do I bootstrap Z" interactions grows roughly with `N × M`, and every one of them is an interruption that lands on a small number of senior engineers.

The symptoms are concrete and measurable in any organization past ~30 services:

| Symptom | Root cause | Cost |
|---|---|---|
| "Who owns `checkout-api`?" asked in Slack weekly | Ownership metadata is tribal, not queryable | Mean-time-to-ownership (MTTO) in hours, not seconds |
| Three teams solve service bootstrap three ways | No paved road; every start is a snowflake | Divergent security posture, un-auditable fleet |
| Security asks "which services use `log4j`?" and no one can answer in under a day | No machine-readable dependency graph | Unbounded incident exposure window |
| Onboarding a new hire takes 3 weeks to "know where things are" | Discovery is oral tradition | Ramp cost, key-person risk |
| Docs are stale because they live away from code | No docs-as-code enforcement | Runbooks that lie during an incident |

The **architectural problem** is that discovery, ownership, standardization, and documentation are treated as *social* concerns when they are in fact *data* concerns. A developer portal reframes them as a **system of record**: a queryable, versioned, code-adjacent catalog of software, its owners, its APIs, its infrastructure dependencies, and the golden paths to create more of it.

### 1.2 Portal vs. Platform — a distinction the exam tests

These are two different layers and CNPA expects you to keep them apart:

- **Internal Developer *Platform* (IDP)** — the *capabilities*: CI/CD, environments, Kubernetes clusters, secrets, observability, policy. It does the work.
- **Internal Developer *Portal*** — the *interface* onto those capabilities: discovery, self-service, documentation, insights. It exposes the work.

Backstage is a **portal**. It is deliberately *not* a delivery engine — it orchestrates and surfaces the platform's capabilities (through plugins and templates) rather than replacing them. A common production anti-pattern is to grow the portal into a bespoke CD system; the paved-road answer is to have templates trigger the *existing* CI/CD and have plugins *read* the existing systems.

### 1.3 Golden paths and cognitive load

The design goal, borrowed from Spotify's practice and *Team Topologies*, is to **reduce extraneous cognitive load** on stream-aligned teams. A **golden path** (a.k.a. paved road) is the well-lit, supported, opinionated way to do a common task — create a service, add an API, ship a doc. Backstage encodes golden paths as **Software Templates** (the Scaffolder). The metric of success is not "features shipped" but **self-service ratio**: the fraction of common tasks a developer completes without filing a ticket or interrupting the platform team.

Treat the portal as a **product**, not a project: it has users (developers), a value proposition (time saved, load reduced), and adoption metrics. A portal no one uses is a failed product regardless of engineering quality.

---

## 2. Architecture of Backstage

Backstage is a **monorepo application** you *build and own*, not a SaaS you consume. `@backstage/create-app` scaffolds a repository containing a React frontend and a Node.js backend that you extend with plugins and deploy yourself.

```
                         ┌──────────────────────────────────────────┐
   Browser (SPA) ───────▶│  Frontend  (React + TS, Material UI)      │
                         │  - App shell, plugins, Catalog UI,        │
                         │    Scaffolder UI, TechDocs reader, Search │
                         └───────────────────┬──────────────────────┘
                                             │  HTTP / JSON
                         ┌───────────────────▼──────────────────────┐
                         │  Backend  (Node.js, "new backend system") │
                         │  createBackend() + backend.add(plugin)    │
                         │  ┌──────────┬───────────┬──────────────┐  │
                         │  │ Catalog  │ Scaffolder│ TechDocs      │ │
                         │  │ Auth     │ Search    │ Permission    │ │
                         │  │ Kubernetes plugin, Proxy, ...        │ │
                         │  └──────────┴───────────┴──────────────┘  │
                         └───────┬───────────────┬──────────────┬────┘
                                 │               │              │
                          ┌──────▼─────┐  ┌──────▼──────┐  ┌────▼──────────┐
                          │ PostgreSQL │  │ Object store│  │ Integrations   │
                          │ (catalog,  │  │ (TechDocs   │  │ GitHub/GitLab, │
                          │  scaffolder│  │  static site│  │ K8s, CI, IdP,  │
                          │  tasks)    │  │  S3/GCS)    │  │ OIDC, LDAP     │
                          └────────────┘  └─────────────┘  └────────────────┘
```

**Core subsystems:**

- **Software Catalog** — the system of record. Ingests `catalog-info.yaml` **Entities** via *providers/processors*, stores them in Postgres, computes **relations**, and exposes a REST API + UI.
- **Software Templates (Scaffolder)** — parameterized golden-path generators. A `Template` entity defines input `parameters` and a sequence of `steps` (fetch, template, publish, register).
- **TechDocs** — docs-as-code. MkDocs builds Markdown that lives next to source into a static site, published to object storage, rendered inside the portal.
- **Search** — a pluggable index over catalog + docs.
- **Kubernetes plugin** — reads workload status from clusters and surfaces it per-component.
- **Auth & Permission** — sign-in via an external IdP (OIDC/GitHub/Google/…) and a policy layer over reads/writes.

### 2.1 The Catalog data model (memorize this)

Every catalog record is an **Entity** with a common **envelope** (`apiVersion`, `kind`, `metadata`, `spec`). CNPA questions frequently hinge on knowing the **kinds** and their relations.

| Kind | Represents | Key `spec` fields | Example |
|---|---|---|---|
| **Component** | A unit of software | `type` (service/website/library), `lifecycle`, `owner`, `system` | `checkout-api` |
| **API** | A boundary/contract | `type` (openapi/asyncapi/grpc/graphql), `definition`, `owner` | `checkout-openapi` |
| **Resource** | Infrastructure | `type` (database/bucket/…), `owner`, `system` | `checkout-db` |
| **System** | A cooperating set of entities | `owner`, `domain` | `payments` |
| **Domain** | Related systems / bounded context | `owner` | `commerce` |
| **Group** | An org team | `type`, `parent`, `children`, `members` | `team-payments` |
| **User** | A person | `memberOf`, `profile` | `agalindo` |
| **Location** | A pointer to more catalog data | `type`, `target(s)` | GitHub org discovery |
| **Template** | A Scaffolder golden path | `parameters`, `steps`, `output` | `nodejs-service` |

**Relations** are derived edges the catalog computes and both directions are queryable: `ownedBy`/`ownerOf`, `providesApi`/`apiProvidedBy`, `consumesApi`/`apiConsumedBy`, `dependsOn`/`dependencyOf`, `partOf`/`hasPart`, `memberOf`/`hasMember`, `parentOf`/`childOf`. This graph is what makes "which services depend on `checkout-db`?" a query instead of a Slack thread.

### 2.2 Ingestion: how entities get into the catalog

Two production models, and the choice is a real trade-off:

- **Static locations** — you list `Location` entities pointing at specific `catalog-info.yaml` files. Explicit, auditable, but manual — every new repo needs a registration.
- **Discovery providers** — a provider (e.g. `GithubEntityProvider`) scans an org on a schedule and ingests any repo containing a `catalog-info.yaml`. Zero-touch onboarding, but requires broad read credentials and a scheduling budget.

| Ingestion strategy | Onboarding effort | Credential scope | Failure blast radius | Best for |
|---|---|---|---|---|
| Static `Location` list | High (per repo) | Narrow (per repo) | Small, explicit | Small/regulated orgs |
| GitHub/GitLab discovery | Near-zero | Org-wide read | Large (one bad file can spam errors) | Large self-service orgs |
| API push (`catalog:register` from templates) | Zero (born registered) | Template's token | Contained to the new entity | Golden-path-first orgs |

The production sweet spot: **discovery for existing repos + `catalog:register` in every template**, so anything created through the paved road is registered at birth.

---

## 3. Technical comparisons and trade-offs

### 3.1 Backstage vs. managed portals vs. build-your-own

| Dimension | **Backstage (self-hosted, OSS)** | **Managed portal (Port, Cortex, OpsLevel)** | **Custom-built (React + internal API)** |
|---|---|---|---|
| Licensing | Apache-2.0, CNCF-governed | Commercial SaaS/seat-based | Your engineering time |
| Ownership model | You run the app (monorepo you own) | Vendor runs it | You run everything |
| Extensibility | Plugin ecosystem (100s), full code access | Config + vendor plugins/API | Unlimited but all bespoke |
| Data model | Opinionated catalog (Entity kinds/relations) | Vendor's flexible blueprint/entity model | Whatever you invent |
| Ops burden | **High** (Postgres, upgrades, plugin conflicts, TypeScript build) | **Low** (vendor-operated) | Highest |
| Upgrade cadence | Frequent (weekly-ish), breaking changes possible | Vendor-managed | You decide |
| Lock-in | Low (OSS, portable YAML) | Medium–high (vendor schema/API) | Low but non-transferable |
| Time-to-first-value | Days–weeks | Hours–days | Weeks–months |
| CNCF alignment | **Native** (this is the reference impl) | Some support Backstage schema | None |

**Decision guidance for the exam:** Backstage is chosen when you need deep customization, want to avoid seat-based lock-in, and have a platform team that can carry the operational burden (Postgres + a non-trivial TypeScript app). Managed portals win when the platform team is small and time-to-value dominates. "Build your own portal from scratch" is almost always the wrong answer once a catalog standard exists — it reinvents the Entity model badly.

### 3.2 Frontend / backend system choices

- **New backend system** (`@backstage/backend-defaults`, `createBackend()`) is the current, required model for new apps; the legacy "backend wiring in `index.ts`" is deprecated. Exam and production both assume the new system.
- **Database:** SQLite is for local dev only; **PostgreSQL is mandatory for production** (concurrent access, durability, the scaffolder task queue). Never ship SQLite to a cluster.
- **TechDocs build strategy:** `local` (backend builds docs on read — simple, but couples doc build to the portal process) vs. **`external`** (CI builds and publishes the static site to object storage; the portal only *reads*). Production uses `external` so a broken doc build cannot degrade the portal.

| TechDocs approach | Where docs build | Portal CPU cost | Scales to 1000s of docs? | Recommended |
|---|---|---|---|---|
| `builder: local` | Inside backend on demand | High (spikes on read) | No | Dev only |
| `builder: external` + S3/GCS publisher | In CI, pushed to bucket | Near-zero (read-only) | Yes | **Production** |

---

## 4. Complete, unabridged manifests

### 4.1 Catalog entities — a full `catalog-info.yaml`

A single descriptor file can hold multiple entities separated by `---`. This is the code-adjacent file that lives in a service repo.

```yaml
# catalog-info.yaml — lives at the repo root of checkout-api
apiVersion: backstage.io/v1alpha1
kind: Component
metadata:
  name: checkout-api
  description: Handles cart checkout, tax, and order creation.
  annotations:
    backstage.io/techdocs-ref: dir:.                    # docs are in this repo
    github.com/project-slug: acme/checkout-api          # enables GitHub plugin
    backstage.io/kubernetes-id: checkout-api            # links K8s workloads
    prometheus.io/rule: memory                          # example plugin annotation
    pagerduty.com/service-id: PXYZ123
  tags:
    - nodejs
    - payments
    - tier1
  links:
    - url: https://grafana.acme.internal/d/checkout
      title: Grafana Dashboard
      icon: dashboard
    - url: https://acme.pagerduty.com/service/PXYZ123
      title: On-call
      icon: alert
spec:
  type: service
  lifecycle: production            # experimental | production | deprecated
  owner: group:team-payments
  system: payments
  providesApis:
    - checkout-openapi
  consumesApis:
    - inventory-openapi
  dependsOn:
    - resource:checkout-db
---
apiVersion: backstage.io/v1alpha1
kind: API
metadata:
  name: checkout-openapi
  description: REST contract for the checkout service.
spec:
  type: openapi
  lifecycle: production
  owner: group:team-payments
  system: payments
  definition:
    $text: ./openapi/checkout.yaml     # inlined at ingestion from the referenced file
---
apiVersion: backstage.io/v1alpha1
kind: Resource
metadata:
  name: checkout-db
  description: Managed PostgreSQL 15 instance for checkout.
spec:
  type: database
  lifecycle: production
  owner: group:team-payments
  system: payments
---
apiVersion: backstage.io/v1alpha1
kind: System
metadata:
  name: payments
  description: Everything that moves money.
spec:
  owner: group:team-payments
  domain: commerce
```

Organizational entities usually live in a separate, centrally-owned repo:

```yaml
# org.yaml — owned by the platform team
apiVersion: backstage.io/v1alpha1
kind: Domain
metadata:
  name: commerce
spec:
  owner: group:team-payments
---
apiVersion: backstage.io/v1alpha1
kind: Group
metadata:
  name: team-payments
  description: Owns checkout, billing, and refunds.
spec:
  type: team
  profile:
    displayName: Team Payments
    email: team-payments@acme.io
  parent: engineering
  children: []
  members:
    - agalindo
---
apiVersion: backstage.io/v1alpha1
kind: User
metadata:
  name: agalindo
spec:
  profile:
    displayName: Ada Galindo
    email: agalindo@acme.io
  memberOf:
    - team-payments
```

### 4.2 `app-config.yaml` — production configuration

Secrets come from the environment (`${VAR}`), never inlined. This is the file that wires integrations, database, auth, catalog ingestion, and TechDocs.

```yaml
app:
  title: ACME Developer Portal
  baseUrl: https://backstage.acme.io

organization:
  name: ACME

backend:
  baseUrl: https://backstage.acme.io
  listen:
    port: 7007
    host: 0.0.0.0
  csp:
    connect-src: ["'self'", 'http:', 'https:']
  cors:
    origin: https://backstage.acme.io
    methods: [GET, HEAD, PATCH, POST, PUT, DELETE]
    credentials: true
  database:
    client: pg
    connection:
      host: ${POSTGRES_HOST}
      port: ${POSTGRES_PORT}
      user: ${POSTGRES_USER}
      password: ${POSTGRES_PASSWORD}
      ssl:
        rejectUnauthorized: false
  cache:
    store: memory
  reading:
    allow:
      - host: '*.acme.io'

integrations:
  github:
    - host: github.com
      apps:
        - $include: github-app-acme-credentials.yaml   # GitHub App creds, mounted secret

auth:
  environment: production
  providers:
    github:
      production:
        clientId: ${AUTH_GITHUB_CLIENT_ID}
        clientSecret: ${AUTH_GITHUB_CLIENT_SECRET}
        signIn:
          resolvers:
            - resolver: usernameMatchingUserEntityName

catalog:
  rules:
    - allow: [Component, System, API, Resource, Location, Template, Group, User, Domain]
  locations:
    # Organizational data — explicit, centrally owned
    - type: url
      target: https://github.com/acme/backstage-catalog/blob/main/org.yaml
      rules:
        - allow: [Group, User, Domain]
  providers:
    github:
      acmeOrg:
        organization: 'acme'
        catalogPath: '/catalog-info.yaml'
        filters:
          branch: 'main'
          repository: '.*'                 # discover every repo
        schedule:
          frequency: { minutes: 30 }
          timeout: { minutes: 3 }
          initialDelay: { seconds: 15 }

techdocs:
  builder: 'external'                      # CI builds; portal only reads
  generator:
    runIn: 'local'
  publisher:
    type: 'awsS3'
    awsS3:
      bucketName: 'acme-techdocs'
      region: 'us-east-1'

permission:
  enabled: true

kubernetes:
  serviceLocatorMethod:
    type: 'multiTenant'
  clusterLocatorMethods:
    - type: 'config'
      clusters:
        - name: prod-use1
          url: ${K8S_PROD_URL}
          authProvider: 'serviceAccount'
          serviceAccountToken: ${K8S_PROD_SA_TOKEN}
          caData: ${K8S_PROD_CA}
```

### 4.3 The new backend system — `packages/backend/src/index.ts`

```typescript
import { createBackend } from '@backstage/backend-defaults';

const backend = createBackend();

// App (serves the built frontend)
backend.add(import('@backstage/plugin-app-backend'));

// Catalog + entity providers/processors
backend.add(import('@backstage/plugin-catalog-backend'));
backend.add(import('@backstage/plugin-catalog-backend-module-github'));
backend.add(import('@backstage/plugin-catalog-backend-module-scaffolder-entity-model'));

// Scaffolder (golden paths)
backend.add(import('@backstage/plugin-scaffolder-backend'));
backend.add(import('@backstage/plugin-scaffolder-backend-module-github'));

// TechDocs
backend.add(import('@backstage/plugin-techdocs-backend'));

// Auth
backend.add(import('@backstage/plugin-auth-backend'));
backend.add(import('@backstage/plugin-auth-backend-module-github-provider'));

// Permissions
backend.add(import('@backstage/plugin-permission-backend'));
backend.add(import('@backstage/plugin-permission-backend-module-allow-all-policy'));

// Search
backend.add(import('@backstage/plugin-search-backend'));
backend.add(import('@backstage/plugin-search-backend-module-catalog'));
backend.add(import('@backstage/plugin-search-backend-module-techdocs'));

// Kubernetes
backend.add(import('@backstage/plugin-kubernetes-backend'));

backend.start();
```

### 4.4 A complete Software Template (golden path)

```yaml
apiVersion: scaffolder.backstage.io/v1beta3
kind: Template
metadata:
  name: nodejs-service
  title: Node.js Microservice
  description: Paved road for a production Node.js service — repo, CI, catalog entry, docs.
  tags:
    - recommended
    - nodejs
spec:
  owner: group:platform-team
  type: service
  parameters:
    - title: Service details
      required: [name, owner]
      properties:
        name:
          title: Service name
          type: string
          pattern: '^[a-z0-9-]+$'
          description: lowercase, dash-separated (e.g. checkout-api)
        owner:
          title: Owner
          type: string
          ui:field: OwnerPicker
          ui:options:
            catalogFilter:
              kind: Group
    - title: Repository
      required: [repoUrl]
      properties:
        repoUrl:
          title: Repository location
          type: string
          ui:field: RepoUrlPicker
          ui:options:
            allowedHosts: ['github.com']
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
        repoUrl: ${{ parameters.repoUrl }}
        description: 'Service ${{ parameters.name }}'
        defaultBranch: main
        repoVisibility: internal
        requireCodeOwnerReviews: true
    - id: register
      name: Register in catalog
      action: catalog:register        # born registered — no manual onboarding
      input:
        repoContentsUrl: ${{ steps.publish.output.repoContentsUrl }}
        catalogInfoPath: '/catalog-info.yaml'
  output:
    links:
      - title: Repository
        url: ${{ steps.publish.output.remoteUrl }}
      - title: Open in catalog
        icon: catalog
        entityRef: ${{ steps.register.output.entityRef }}
```

### 4.5 Kubernetes deployment (raw manifests)

The portal is a stateful-adjacent web app: stateless pods backed by an external Postgres. Never bake the DB into the pod.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backstage
  namespace: backstage
  labels: { app: backstage }
spec:
  replicas: 2
  selector:
    matchLabels: { app: backstage }
  template:
    metadata:
      labels: { app: backstage }
    spec:
      serviceAccountName: backstage
      containers:
        - name: backstage
          image: registry.acme.io/backstage:2026-08-07
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 7007
          envFrom:
            - secretRef:
                name: backstage-secrets      # POSTGRES_*, AUTH_*, GITHUB_*, K8S_*
          resources:
            requests: { cpu: '250m', memory: '512Mi' }
            limits:   { cpu: '1',    memory: '1Gi'  }
          readinessProbe:
            httpGet: { path: /healthcheck, port: 7007 }
            initialDelaySeconds: 15
            periodSeconds: 10
          livenessProbe:
            httpGet: { path: /healthcheck, port: 7007 }
            initialDelaySeconds: 60
            periodSeconds: 30
---
apiVersion: v1
kind: Service
metadata:
  name: backstage
  namespace: backstage
spec:
  selector: { app: backstage }
  ports:
    - name: http
      port: 80
      targetPort: 7007
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: backstage
  namespace: backstage
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
spec:
  ingressClassName: nginx
  tls:
    - hosts: [backstage.acme.io]
      secretName: backstage-tls
  rules:
    - host: backstage.acme.io
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: backstage
                port: { number: 80 }
```

For the officially supported install, the community Helm chart (`backstage/charts`) is the paved road:

```yaml
# values.yaml for the backstage/backstage Helm chart
backstage:
  image:
    registry: registry.acme.io
    repository: backstage
    tag: '2026-08-07'
  replicas: 2
  extraEnvVarsSecrets:
    - backstage-secrets
  appConfig:
    app:
      baseUrl: https://backstage.acme.io
    backend:
      baseUrl: https://backstage.acme.io
      database:
        client: pg
        connection:
          host: ${POSTGRES_HOST}
          port: ${POSTGRES_PORT}
          user: ${POSTGRES_USER}
          password: ${POSTGRES_PASSWORD}

ingress:
  enabled: true
  host: backstage.acme.io
  className: nginx

postgresql:
  enabled: false        # use an external, managed Postgres in production
```

---

## 5. CLI commands and real terminal output

### 5.1 Scaffold, run, and build the app

```console
$ npx @backstage/create-app@latest
? Enter a name for the app [required] acme-portal
Creating the app...
 Checking if the directory is available:
  checking      acme-portal ✔
 Executing package installer...
  ⠹ Installing dependencies with yarn
 Moving to final location:
  moving        acme-portal ✔
🥇  Successfully created acme-portal

$ cd acme-portal
$ yarn install --immutable
$ yarn dev
[0] Loaded config from app-config.yaml
[1] <i> [webpack-dev-server] Project is running at http://localhost:3000/
[0] 2026-08-07T14:22:10.114Z catalog info Performing database migration
[0] 2026-08-07T14:22:11.842Z backstage info Listening on :7007
[0] 2026-08-07T14:22:12.006Z catalog info Discovered 0 entities (github:acmeOrg)
```

Production image build:

```console
$ yarn install --immutable
$ yarn tsc
$ yarn build:backend --config ../../app-config.yaml
$ docker build . -f packages/backend/Dockerfile --tag registry.acme.io/backstage:2026-08-07
 => exporting to image
 => => writing image sha256:8f2a...c91
 => => naming to registry.acme.io/backstage:2026-08-07
$ docker push registry.acme.io/backstage:2026-08-07
```

### 5.2 Interrogate the Catalog API

The catalog is a REST API; everything the UI shows is available programmatically.

```console
$ curl -s http://localhost:7007/api/catalog/entities | jq 'length'
128

$ curl -s "http://localhost:7007/api/catalog/entities/by-name/component/default/checkout-api" \
    | jq '{name: .metadata.name, owner: .spec.owner, lifecycle: .spec.lifecycle}'
{
  "name": "checkout-api",
  "owner": "group:team-payments",
  "lifecycle": "production"
}

# Every tier1 service and who owns it — the query that replaces a Slack thread
$ curl -s "http://localhost:7007/api/catalog/entities?filter=metadata.tags=tier1" \
    | jq -r '.[] | "\(.metadata.name)\t\(.spec.owner)"'
checkout-api    group:team-payments
billing-api     group:team-payments
inventory-api   group:team-supply

# The dependency graph edge that answers "what breaks if checkout-db goes down?"
$ curl -s "http://localhost:7007/api/catalog/entities/by-name/resource/default/checkout-db" \
    | jq '.relations[] | select(.type=="dependencyOf") | .targetRef'
"component:default/checkout-api"
```

### 5.3 Deploy and verify on Kubernetes

```console
$ kubectl create namespace backstage
namespace/backstage created

$ kubectl -n backstage create secret generic backstage-secrets \
    --from-literal=POSTGRES_HOST=pg.acme.internal \
    --from-literal=POSTGRES_PORT=5432 \
    --from-literal=POSTGRES_USER=backstage \
    --from-literal=POSTGRES_PASSWORD='***' \
    --from-literal=AUTH_GITHUB_CLIENT_ID='***' \
    --from-literal=AUTH_GITHUB_CLIENT_SECRET='***'
secret/backstage-secrets created

$ kubectl -n backstage apply -f k8s/
deployment.apps/backstage created
service/backstage created
ingress.networking.k8s.io/backstage created

$ kubectl -n backstage rollout status deploy/backstage
Waiting for deployment "backstage" rollout to finish: 1 of 2 updated replicas are available...
deployment "backstage" successfully rolled out

$ kubectl -n backstage get pods
NAME                         READY   STATUS    RESTARTS   AGE
backstage-6c9f8b7d5c-4kv2p   1/1     Running   0          92s
backstage-6c9f8b7d5c-h7t9m   1/1     Running   0          92s

$ kubectl -n backstage exec deploy/backstage -- wget -qO- localhost:7007/healthcheck
{"status":"ok"}
```

---

## 6. Verification and failure diagnosis

The portal fails in a small number of characteristic ways. Learn the signature, the probe, and the fix.

### 6.1 Health and readiness

```console
$ curl -s https://backstage.acme.io/healthcheck ; echo
{"status":"ok"}
```

`/healthcheck` returning `ok` means the backend is up — it does **not** mean the catalog ingested anything. Verify ingestion separately (§5.2, `entities | jq length`).

### 6.2 Failure catalog

| Symptom | Likely cause | Diagnostic | Fix |
|---|---|---|---|
| Pod `CrashLoopBackOff` immediately | DB unreachable / migration failed | `kubectl logs` shows `ECONNREFUSED` or `password authentication failed` | Fix `POSTGRES_*` secret; confirm network policy allows egress to Postgres |
| App loads but catalog is empty | Discovery provider not matching, or token lacks scope | Grep logs for `github:acmeOrg`; check `catalog.providers` filters | Correct `organization`/`filters.repository`; grant GitHub App `contents:read` |
| Entity present but shows `metadata.annotations` error / red banner | Invalid `catalog-info.yaml` | Catalog UI → entity → **Inspect** → *processing errors*; or `GET /api/catalog/entities/by-name/...` | Fix YAML per descriptor spec; malformed files surface as processing errors, not silent drops |
| `owner` shows as broken ref (`group:team-x` unknown) | Group/User entity not ingested, or ordering | Query the referenced entity; check org.yaml `Location` | Ensure org entities ingest before/with components; dangling refs are allowed but rendered broken |
| TechDocs page: *"Documentation not found"* | `builder: external` but nothing published to bucket | Check object store for `<namespace>/<kind>/<name>/index.html` | Run the CI docs build; verify publisher creds/bucket |
| Login redirect loop | `auth.environment` / callback URL mismatch | Browser network tab: repeated `/api/auth/github/handler/frame` | Align OAuth app callback with `backend.baseUrl`; set correct `environment` and `signIn.resolvers` |
| Scaffolder task hangs / fails at `publish:github` | Integration token missing or wrong scope | Scaffolder UI → task log; backend logs for the step id | Add `integrations.github` credentials with repo-create scope |
| K8s tab empty for a component | Missing annotation or cluster auth | Confirm `backstage.io/kubernetes-id` on the entity; check `kubernetes.clusters` SA token | Add annotation; grant the SA `get/list` on workloads |

### 6.3 Reading processing errors programmatically

The catalog does not silently discard broken entities — it records **processing errors** you can query:

```console
$ curl -s "http://localhost:7007/api/catalog/entities/by-name/component/default/checkout-api" \
    | jq '.status.items[]? | select(.type=="backstage.io/catalog-processing")'
{
  "type": "backstage.io/catalog-processing",
  "level": "error",
  "message": "Placed entity ... failed: spec.owner must be a non-empty string",
  "error": { "name": "InputError" }
}
```

This is the single most useful diagnostic for "my service isn't showing up correctly": the error travels with the entity.

### 6.4 Ingestion latency

Discovery runs on the schedule in `catalog.providers.*.schedule` (30 minutes in §4.2). A newly pushed `catalog-info.yaml` will not appear instantly. To verify without waiting, either lower `frequency` in a staging config or register the location explicitly:

```console
$ curl -s -X POST http://localhost:7007/api/catalog/locations \
    -H 'Content-Type: application/json' \
    -d '{"type":"url","target":"https://github.com/acme/checkout-api/blob/main/catalog-info.yaml"}' \
    | jq '.entities[].metadata.name'
"checkout-api"
"checkout-openapi"
"checkout-db"
```

### 6.5 Adoption is the real verification

The portal is a product; "it's up" is necessary but not sufficient. Track these as the actual success metrics:

| Metric | Signal it captures | Healthy direction |
|---|---|---|
| Catalog coverage (`entities` vs. known repos) | Completeness of the system of record | → 100% of active repos |
| Self-service ratio (templates run vs. bootstrap tickets) | Golden-path adoption | Tickets → 0 |
| MTTO (time to answer "who owns X") | Discovery value | Seconds |
| TechDocs freshness (docs built in last N days) | Docs-as-code discipline | Recent |
| Weekly active developers on the portal | Product adoption | ↑ and sustained |

A portal with 100% uptime and 5% catalog coverage has failed. A portal that answers ownership in seconds and bootstraps services in minutes has succeeded — regardless of how clever its plugins are.

---

## Referencias

- **What is Backstage** — https://backstage.io/docs/overview/what-is-backstage
- **Software Catalog (overview)** — https://backstage.io/docs/features/software-catalog/
- **Catalog descriptor format (Entity kinds, relations)** — https://backstage.io/docs/features/software-catalog/descriptor-format
- **Well-known relations between entities** — https://backstage.io/docs/features/software-catalog/well-known-relations
- **Software Templates (Scaffolder)** — https://backstage.io/docs/features/software-templates/
- **TechDocs (docs-as-code)** — https://backstage.io/docs/features/techdocs/
- **Backend system (createBackend)** — https://backstage.io/docs/backend-system/
- **Kubernetes plugin** — https://backstage.io/docs/features/kubernetes/
- **Authentication** — https://backstage.io/docs/auth/
- **Deploying Backstage** — https://backstage.io/docs/deployment/
- **Helm deployment & community chart** — https://backstage.io/docs/deployment/helm · https://github.com/backstage/charts
- **Backstage source (monorepo)** — https://github.com/backstage/backstage
- **CNCF project page (Backstage, Incubating)** — https://www.cncf.io/projects/backstage/
- **CNPA curriculum (source syllabus)** — https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf