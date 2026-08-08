# Topic 5.3 — Developer Portals for Platform Adoption (Backstage)

## Guided Exercises

> **CNPA domain 5 — Platform Observability, Analytics & Adoption.** These labs walk the full adoption path a platform team follows with Backstage: stand up the portal, model your estate in the Software Catalog, ship a golden path with the Scaffolder, wire docs-like-code, and surface live runtime state. Execute each numbered step, then answer the comprehension checks before moving on. Model answers are collapsed at the end.

**Prerequisites**

- Node.js Active LTS (20 or 22), `yarn` (Corepack-enabled), and `git`.
- Docker running (TechDocs generation uses a container).
- A GitHub account and a Personal Access Token (`repo`, `workflow` scopes) exported as `GITHUB_TOKEN` for the integration exercises.
- Optional for Exercise 5: a reachable Kubernetes cluster and a read-only ServiceAccount token.

---

## Exercise 1 — Scaffold and run the portal

**Goal:** create a standalone Backstage app and understand its monorepo layout and the frontend/backend split.

1. Scaffold a new app. Answer `acme-portal` when prompted for the app name:

   ```bash
   npx @backstage/create-app@latest
   ```

   Expected (abridged):

   ```
   ? Enter a name for the app [required] acme-portal

   Creating the app...
    Checking if the directory is available:
      checking      acme-portal ✔
    Executing package installer:
      executing     yarn install ✔ (this can take a while)

   🥇  Successfully created acme-portal

    All set! Now you might want to:
      Run the app: cd acme-portal && yarn dev
   ```

2. Inspect the workspace layout:

   ```bash
   cd acme-portal
   ls packages
   ```

   Expected:

   ```
   app  backend
   ```

3. Start both processes with a single command (frontend on `:3000`, backend on `:7007`):

   ```bash
   yarn dev
   ```

   Expected (abridged):

   ```
   [0] webpack compiled successfully
   [1] {"service":"backstage","level":"info","message":"Listening on :7007"}
   ```

4. Open `http://localhost:3000`. You land on the Software Catalog, pre-seeded with the example `example-website` component.

5. Look at where wiring lives. Open `packages/backend/src/index.ts` and note the plugin registration style:

   ```ts
   import { createBackend } from '@backstage/backend-defaults';

   const backend = createBackend();
   backend.add(import('@backstage/plugin-catalog-backend'));
   backend.add(import('@backstage/plugin-scaffolder-backend'));
   backend.add(import('@backstage/plugin-techdocs-backend'));
   backend.start();
   ```

**Comprehension check 1**

1. Backstage is a monorepo with `packages/app` and `packages/backend`. What does each package do, and why does a developer portal need a backend at all (name two responsibilities that cannot live in the browser)?
2. `create-app` produces a *standalone application*, not a library you `npm install`. What is the architectural consequence of that choice for how you add a plugin or upgrade Backstage?
3. The backend uses `backend.add(import('...'))`. What is this pattern called, and what problem in the older “manually wire every plugin” backend was it designed to solve?

---

## Exercise 2 — Model your estate in the Software Catalog

**Goal:** describe real software with catalog entities and the relations between them, then register them so they appear in the portal.

1. In a service repo, create `catalog-info.yaml` describing a **Component** with ownership, a system, an API it provides, and a resource it depends on:

   ```yaml
   apiVersion: backstage.io/v1alpha1
   kind: Component
   metadata:
     name: payments-api
     description: Authorizes and captures card payments
     annotations:
       github.com/project-slug: acme/payments-api
       backstage.io/techdocs-ref: dir:.
       backstage.io/kubernetes-id: payments-api
     tags:
       - java
       - payments
     links:
       - url: https://acme.pagerduty.com/service-directory/PXXXX
         title: On-call
         icon: dashboard
   spec:
     type: service
     lifecycle: production
     owner: team-payments
     system: checkout
     providesApis:
       - payments-api
     dependsOn:
       - resource:payments-db
   ```

2. In the same file (YAML documents separated by `---`), add the **API**, **System**, **Domain**, **Group**, and **Resource** it references so no relation dangles:

   ```yaml
   ---
   apiVersion: backstage.io/v1alpha1
   kind: API
   metadata:
     name: payments-api
   spec:
     type: openapi
     lifecycle: production
     owner: team-payments
     definition:
       $text: ./openapi.yaml
   ---
   apiVersion: backstage.io/v1alpha1
   kind: System
   metadata:
     name: checkout
   spec:
     owner: team-payments
     domain: commerce
   ---
   apiVersion: backstage.io/v1alpha1
   kind: Domain
   metadata:
     name: commerce
   spec:
     owner: team-payments
   ---
   apiVersion: backstage.io/v1alpha1
   kind: Group
   metadata:
     name: team-payments
   spec:
     type: team
     children: []
   ---
   apiVersion: backstage.io/v1alpha1
   kind: Resource
   metadata:
     name: payments-db
   spec:
     type: database
     owner: team-payments
     system: checkout
   ```

3. Register the entity set. Either add a static location to `app-config.yaml`:

   ```yaml
   catalog:
     rules:
       - allow: [Component, API, System, Domain, Group, User, Resource, Location, Template]
     locations:
       - type: url
         target: https://github.com/acme/payments-api/blob/main/catalog-info.yaml
   ```

   …or register it at runtime from the UI: **Create → Register Existing Component →** paste the `catalog-info.yaml` URL → **Analyze → Import**.

4. Validate the descriptor without importing, using the catalog CLI:

   ```bash
   yarn backstage-cli repo test        # runs your repo tests
   npx @backstage/cli@latest package ... # (app dev)
   # Or validate the descriptor directly:
   npx @techdocs/cli --version           # confirms tooling
   ```

   Then confirm the entity resolved via the backend API:

   ```bash
   curl -s localhost:7007/api/catalog/entities/by-name/component/default/payments-api | jq '.spec.owner, .relations[].type'
   ```

   Expected:

   ```
   "team-payments"
   "ownedBy"
   "partOf"
   "providesApi"
   "dependsOn"
   ```

5. In the UI, open the component and view its **Relations** graph. Note that `owner: team-payments` in the spec became an `ownedBy` **relation**, and `team-payments` gained the reciprocal `ownerOf`.

**Comprehension check 2**

1. `spec.owner: team-payments` is a *string* in the descriptor, but the catalog exposes an `ownedBy` *relation* pointing at `group:default/team-payments`. Explain the two-phase process (ingestion vs. stitching) that turns spec fields into a bidirectional relation graph, and why relations are derived rather than authored directly.
2. What is the difference in *intent* between `System`, `Component`, and `Resource`? Give a one-line example of each for the `payments-api`.
3. A teammate registers a `Component` whose `spec.system: checkout` refers to a System that does not exist yet. Does ingestion fail? What does the entity’s status show, and what happens once the System is added later?
4. Why does the `catalog.rules` `allow` list matter for a multi-team portal — what abuse does it prevent when you ingest descriptors from repos you do not fully control?

---

## Exercise 3 — Ship a golden path with the Scaffolder

**Goal:** turn “create a new production-ready service” from a wiki page into a self-service action that creates the repo, seeds it, and registers it — the core of platform *adoption*.

1. Create a Software Template. Save as `template.yaml` in a templates repo:

   ```yaml
   apiVersion: scaffolder.backstage.io/v1beta3
   kind: Template
   metadata:
     name: node-service
     title: Node.js Microservice
     description: Production-ready Node service with CI, Dockerfile and TechDocs
     tags:
       - recommended
       - nodejs
   spec:
     owner: group:platform
     type: service
     parameters:
       - title: Service details
         required: [name, owner]
         properties:
           name:
             title: Name
             type: string
             description: Unique name of the component
             ui:field: EntityNamePicker
           owner:
             title: Owner
             type: string
             ui:field: OwnerPicker
             ui:options:
               catalogFilter:
                 kind: [Group]
       - title: Repository location
         required: [repoUrl]
         properties:
           repoUrl:
             title: Repository Location
             type: string
             ui:field: RepoUrlPicker
             ui:options:
               allowedHosts: [github.com]
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
           description: Created by Backstage
           defaultBranch: main
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

2. Create the templated skeleton alongside it at `./skeleton/`. Template variables use the `${{ values.x }}` syntax and are rendered by the `fetch:template` action:

   ```
   skeleton/
   ├── catalog-info.yaml
   ├── package.json
   ├── Dockerfile
   ├── mkdocs.yml
   └── docs/index.md
   ```

   `skeleton/catalog-info.yaml`:

   ```yaml
   apiVersion: backstage.io/v1alpha1
   kind: Component
   metadata:
     name: ${{ values.name }}
     annotations:
       backstage.io/techdocs-ref: dir:.
   spec:
     type: service
     lifecycle: experimental
     owner: ${{ values.owner }}
   ```

3. Register the template in `app-config.yaml` so it appears under **Create**:

   ```yaml
   catalog:
     locations:
       - type: url
         target: https://github.com/acme/software-templates/blob/main/node-service/template.yaml
         rules:
           - allow: [Template]
   ```

4. Confirm the GitHub integration is present (the `publish:github` action needs it):

   ```yaml
   integrations:
     github:
       - host: github.com
         token: ${GITHUB_TOKEN}
   ```

5. In the UI, go to **Create → Node.js Microservice**, fill the form, and run it. Watch the step log stream. Expected task output (abridged):

   ```
   Run of Node.js Microservice
   info: Fetching template content from ./skeleton
   info: Publishing to github.com acme/orders-api
   info: Created a commit ... on branch main
   info: Registering entity from /catalog-info.yaml
   info: Task completed with status 'completed'
   ```

**Comprehension check 3**

1. The template mixes two templating layers: `${{ parameters.x }}` inside `template.yaml`, and `${{ values.x }}` inside `skeleton/`. Which layer is evaluated *when*, and why can’t they be the same syntax evaluated at the same time?
2. Trace the data flow that lets the final `output.link` deep-link into the catalog. Which step produces `entityRef`, and what earlier step’s output does `catalog:register` consume?
3. `ui:field: OwnerPicker` with `catalogFilter: {kind: [Group]}` is more than cosmetic. What correctness property does it enforce at form time that a free-text field would not?
4. From an *adoption* standpoint, why is a template that ends in `catalog:register` fundamentally more valuable than one that only creates a repo? What organizational anti-pattern does the missing registration create?

---

## Exercise 4 — Docs-like-code with TechDocs

**Goal:** make documentation live next to code and render inside the portal, so “where are the docs” stops being a question.

1. In the `payments-api` repo, add an MkDocs config at the root:

   ```yaml
   site_name: payments-api
   nav:
     - Home: index.md
     - Runbook: runbook.md
   plugins:
     - techdocs-core
   ```

2. Add `docs/index.md` and `docs/runbook.md`. Confirm the descriptor already carries the ref annotation from Exercise 2:

   ```yaml
   metadata:
     annotations:
       backstage.io/techdocs-ref: dir:.
   ```

3. Configure the TechDocs pipeline for local development in `app-config.yaml` (generate on demand, in Docker, store on local disk):

   ```yaml
   techdocs:
     builder: 'local'
     generator:
       runIn: 'docker'
     publisher:
       type: 'local'
   ```

4. Preview the docs build locally before relying on the portal:

   ```bash
   npx @techdocs/cli@latest generate --no-docker --source-dir . --output-dir ./site
   ```

   Expected:

   ```
   INFO    - Building documentation...
   INFO    - Documentation built in 0.42 seconds
   ```

5. In the UI, open **payments-api → Docs**. The portal renders the site inline. Change a heading in `docs/index.md`, refresh, and confirm the rebuild.

6. Contrast with production. Swap the config to the recommended **external/CI-built** pattern, where a CI job runs `techdocs-cli generate && techdocs-cli publish` and Backstage only reads pre-built HTML from object storage:

   ```yaml
   techdocs:
     builder: 'external'
     publisher:
       type: 'awsS3'
       awsS3:
         bucketName: 'acme-techdocs'
         region: 'eu-west-1'
   ```

**Comprehension check 4**

1. In `builder: 'local'`, *who* builds the docs and *when*? Name two concrete reasons this is unacceptable in production and how `builder: 'external'` fixes each.
2. `backstage.io/techdocs-ref: dir:.` — what does `dir:.` mean, and what would `url:https://github.com/acme/payments-api` change about where the source is fetched?
3. TechDocs is called a “docs-like-code” approach. State the adoption benefit in terms of *drift*: why does co-locating `docs/` with source and building in CI keep documentation truthful in a way a wiki does not?

---

## Exercise 5 — Surface live runtime state (Kubernetes plugin)

**Goal:** close the loop between the catalog entity and what is actually running, so the portal is a source of *operational* truth, not just metadata.

1. Add cluster configuration to `app-config.yaml` using a read-only ServiceAccount:

   ```yaml
   kubernetes:
     serviceLocatorMethod:
       type: 'multiTenant'
     clusterLocatorMethods:
       - type: 'config'
         clusters:
           - name: production
             url: https://k8s.prod.acme.internal
             authProvider: 'serviceAccount'
             serviceAccountToken: ${K8S_SA_TOKEN}
             caData: ${K8S_CA_DATA}
   ```

2. Tell the plugin which workloads belong to the entity. Two selection strategies — pick one on the component annotations:

   ```yaml
   metadata:
     annotations:
       # strategy A: match resources labeled with this id
       backstage.io/kubernetes-id: payments-api
       # strategy B: an explicit label selector
       backstage.io/kubernetes-label-selector: 'app=payments-api,env=prod'
   ```

3. Ensure your workloads carry the matching label so strategy A resolves them:

   ```yaml
   # Deployment excerpt
   metadata:
     labels:
       backstage.io/kubernetes-id: payments-api
   ```

4. In the UI, open **payments-api → Kubernetes**. Expected: Deployments, Pods, and their health per cluster, e.g.:

   ```
   Cluster: production
   Deployment payments-api   3/3 available
     pod payments-api-7c9f… Running   Ready
     pod payments-api-7c9f… Running   Ready
     pod payments-api-7c9f… Running   Ready
   ```

5. Break something to see the diagnostic value: scale a replica to a bad image and refresh. Expected surfaced condition:

   ```
   Deployment payments-api   2/3 available   ⚠
     pod payments-api-5d2a… ImagePullBackOff
   ```

**Comprehension check 5**

1. Why does the Kubernetes plugin authenticate with its *own* ServiceAccount token rather than the viewing user’s credentials? What is the trade-off in terms of least privilege, and what should that SA be allowed to do (and not do)?
2. Compare `backstage.io/kubernetes-id` vs. `backstage.io/kubernetes-label-selector`. When does the explicit selector become necessary?
3. The catalog says a component exists; the Kubernetes tab says three pods are `Running`. Name two *other* adoption/observability signals (from elsewhere in domain 5) a mature portal folds onto the same entity page, and why concentrating them there drives adoption.

---

## References (official sources)

- Backstage — What is Backstage / Overview: https://backstage.io/docs/overview/what-is-backstage
- Backstage — Getting Started (create-app): https://backstage.io/docs/getting-started/
- Backstage — Software Catalog: https://backstage.io/docs/features/software-catalog/
- Backstage — Descriptor Format of Catalog Entities: https://backstage.io/docs/features/software-catalog/descriptor-format
- Backstage — Software Catalog: System Model & relations: https://backstage.io/docs/features/software-catalog/system-model
- Backstage — Software Templates (Scaffolder): https://backstage.io/docs/features/software-templates/
- Backstage — Writing Templates & built-in actions: https://backstage.io/docs/features/software-templates/writing-templates
- Backstage — TechDocs Overview & Architecture: https://backstage.io/docs/features/techdocs/
- Backstage — TechDocs: How to build in CI / external builder: https://backstage.io/docs/features/techdocs/how-to-guides
- Backstage — Kubernetes plugin: https://backstage.io/docs/features/kubernetes/
- Backstage — New Backend System: https://backstage.io/docs/backend-system/
- CNCF Curriculum — CNPA (Certified Cloud Native Platform Engineering Associate): https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf

---

## Answers

<details>
<summary><strong>Model answers — all comprehension checks</strong></summary>

### Exercise 1

1. **`packages/app`** is the React frontend (the SPA served on `:3000`): pages, plugins’ UI surfaces, theme, routing. **`packages/backend`** is a Node service (`:7007`) hosting plugin *backends*: the catalog processing loop, the scaffolder task engine, TechDocs generation/serving, auth, and proxying. A portal needs a backend because some responsibilities cannot safely or possibly run in a browser: (a) holding privileged integration credentials (GitHub tokens, cluster SA tokens) — these must never reach the client; (b) long-running, stateful work such as the catalog ingestion loop and scaffolder tasks, plus a database. Also CORS/rate-limited third-party calls and TechDocs building.
2. `create-app` gives you an app *you own and commit*, not a dependency you consume. Consequence: adding a plugin or upgrading is done **in your repo** — you edit `packages/backend/src/index.ts` / the app, bump versions, and resolve changes yourself (aided by `backstage-cli versions:bump` and upgrade helpers). It’s maximally flexible (you can fork any behavior) but it makes *you* the integrator: upgrades are your maintenance burden, which is the central operational cost of running Backstage.
3. It is the **new backend system** using dependency injection / plugin *installation* (`backend.add(import('...'))`). The old backend required hand-wiring every plugin’s router, dependencies (logger, database, config, discovery, tokenManager) and stitching them into an Express app — hundreds of lines of boilerplate that broke on every upgrade. The new system lets a plugin declare what it needs and register itself, so installing a plugin is one line and cross-cutting services are injected consistently.

### Exercise 2

1. **Ingestion (processing):** each location is read and each raw entity is validated, its fields normalized, and *emitted relations* computed by processors — e.g. the `owner` field emits an `ownedBy`/`ownerOf` pair. **Stitching:** the catalog merges all processed entities and their emitted relations into the final graph, resolving references to concrete entity refs (`group:default/team-payments`) and attaching the reciprocal side to the target. Relations are **derived, not authored**, so they are always consistent and bidirectional: you state ownership once on the component, and both endpoints of the relation are guaranteed to agree — you can’t create a dangling or contradictory relation by hand.
2. **System** = a bounded set of entities that work together and present a coherent boundary (`checkout` — the whole checkout capability). **Component** = a piece of software you build and run (`payments-api` — the deployable service). **Resource** = infrastructure a component needs to operate (`payments-db` — the database). Rule of thumb: Components are code, Resources are the things Components depend on, Systems group them.
3. Ingestion does **not** fail. Backstage ingests entities independently and resolves references during stitching; an unresolved `system: checkout` simply produces no `partOf` relation yet and may surface a *status/processing* note on the entity. When the `System` entity is later added and processed, the next stitch resolves the reference and the `partOf`/`hasPart` relation appears automatically — no re-registration needed. This tolerance is deliberate: entities arrive from many repos at different times.
4. `catalog.rules.allow` is an **allow-list of entity kinds a location may contribute**. Ingesting descriptors from repos you don’t fully control means anyone who can edit a `catalog-info.yaml` could otherwise inject, say, a `Template` (self-service code execution) or a `Group`/`User` (identity/ownership spoofing). Restricting a location to `[Component, API, Resource]` prevents privilege- and identity-relevant kinds from being self-declared by untrusted repos.

### Exercise 3

1. **`${{ parameters.x }}`** is resolved by the **scaffolder at task run time**, using the values the user typed into the form; it lives in `template.yaml` and feeds action inputs. **`${{ values.x }}`** is resolved *later*, by the **`fetch:template` action** as it renders the `skeleton/` files (a Nunjucks pass), where `values` are the ones that action was handed. They can’t be one pass because the skeleton files must survive *untouched* until the fetch step runs — if the scaffolder eagerly evaluated `${{ }}` everywhere, it would try to interpolate the skeleton before the user’s inputs were bound to that specific render, and template literals meant for the generated repo would be consumed prematurely.
2. `catalog:register` (the `register` step) emits `entityRef` in its output; the final `output.link` reads `${{ steps.register.output.entityRef }}`. `catalog:register` in turn consumes `${{ steps.publish.output.repoContentsUrl }}` — the location of the freshly created repo produced by the **`publish:github`** step. So the chain is: `publish` creates the repo and reports its contents URL → `register` reads the `catalog-info.yaml` there and reports the resulting entity ref → `output` deep-links to it.
3. `OwnerPicker` with `catalogFilter: {kind: [Group]}` guarantees the chosen owner is an **entity that actually exists in the catalog and is a Group**. A free-text field could produce a typo or a non-existent owner, creating a component with a dangling `ownedBy` relation and no real accountable team — exactly the orphaned-ownership problem the catalog is meant to prevent. It enforces referential integrity at creation time.
4. A template ending in `catalog:register` makes the new service **born discoverable and owned** — it appears in the catalog, has an owner, docs ref, and relations from minute zero. Without registration you get *shadow services*: repos that exist and run but are invisible to the portal, unowned, undocumented, and excluded from every org-wide query (security scans, on-call mapping, deprecation sweeps). That gap between “what exists” and “what the catalog knows” is the anti-pattern that kills portal adoption.

### Exercise 4

1. In `builder: 'local'`, the **Backstage backend builds the docs on demand**, the first time someone opens the Docs tab (running MkDocs in Docker). Two reasons it fails in production: (a) **latency & load** — the first viewer pays a multi-second build, and the backend needs Docker + build toolchains, coupling doc rendering to request handling; (b) **no isolation/caching** — a broken `mkdocs.yml` or slow build degrades the live portal. `builder: 'external'` moves generation into **CI** (build once on merge, `techdocs-cli generate && publish` to object storage); Backstage then only *serves pre-built HTML*, so viewing is fast, stateless, and independent of build health.
2. `dir:.` means “the TechDocs source (the `mkdocs.yml` and `docs/`) is in the **same directory as this `catalog-info.yaml`**, in the entity’s own repo,” fetched via the configured SCM integration at the entity’s location. `url:https://github.com/acme/payments-api` would instead point TechDocs at that **absolute repository URL** as the docs source, decoupling where the docs live from where the descriptor was registered (useful when docs are maintained in a different repo).
3. Docs-like-code binds documentation to the same lifecycle as code: it lives in `docs/`, is reviewed in the same pull request, and is rebuilt/published by CI on merge. Because a doc change and the code change ship together (and can be required in review), the docs **can’t silently fall behind** the code the way a separately-edited wiki does — the wiki has no mechanism forcing it to change when the code does, so it drifts into being wrong. Co-location + CI publish keeps the rendered docs a deterministic function of the current source.

### Exercise 5

1. The plugin uses a **backend-held ServiceAccount** because (a) the viewing user is a portal user, not necessarily a Kubernetes principal — most developers have no cluster RBAC — and (b) credentials must stay server-side; a user token in the browser would leak. Trade-off: it’s a form of **impersonation with a shared identity**, so least privilege must be enforced on the *SA itself*. That SA should be **read-only** (`get`/`list`/`watch` on Deployments, Pods, Services, ReplicaSets, etc.), scoped as narrowly as the multi-tenant model allows, and must **not** be able to mutate or read Secrets. The portal presents view-only runtime state, so the SA never needs write.
2. `backstage.io/kubernetes-id` matches all resources carrying the label `backstage.io/kubernetes-id: <value>` — clean when you can add that label to your manifests. `backstage.io/kubernetes-label-selector` lets you match on **existing labels you don’t own or can’t change** (e.g. `app=payments-api,env=prod`), or express a more specific/compound selection (a single env, a canary subset). Use the explicit selector when you can’t stamp the Backstage id label or need finer matching than a single id provides.
3. Beyond catalog metadata and live pod health, a mature portal concentrates on the entity page: **CI/CD status** (last build/deploy, pipeline health), **incident/on-call state** (PagerDuty/Opsgenie), **SLOs / dashboards / error budgets** (monitoring links or embedded panels), **cost**, and **security/compliance signals** (scorecards, vulnerable-dependency checks). Concentrating them drives adoption because the entity page becomes the **single pane** where an engineer answers “is my service healthy, who owns it, is it on fire, is it compliant” without hopping tools — the portal earns daily use, which is the whole point of measuring platform adoption in domain 5.

</details>