# Argo CD — Declarative GitOps Continuous Delivery for Kubernetes
### CAPA Domain 3.1 · Exam weight 20%

---

## 1. Motivation: the production problem Argo CD solves

The default way to change a Kubernetes cluster is imperative: an engineer, a CI runner, or a script executes `kubectl apply` against a live API server. At the scale of a single service this is invisible; at the scale of a platform it produces four failures that compound.

- **Configuration drift.** The live state of the cluster and the intent expressed in your repository diverge silently. Someone runs `kubectl edit`, a Horizontal Pod Autoscaler mutates a replica count, an operator patches a resource, or a hotfix is applied and never committed. There is no authoritative answer to "what is *supposed* to be running here?"
- **No audit trail or reproducibility.** The change history lives in the shell history of whoever ran the command and in the API server's short-lived audit log. A cluster becomes a *snowflake* that cannot be rebuilt from source.
- **Credential sprawl (push model).** In a CI-driven push model, every pipeline that deploys needs write credentials to the cluster. Those credentials sit in CI secret stores, are broadly scoped, and are a prime lateral-movement target. The blast radius of a compromised CI runner is the whole cluster.
- **No continuous correction.** Even if you deploy correctly once, nothing detects or corrects drift afterward. Recovery from an out-of-band change is a human noticing.

**GitOps** reframes deployment as *continuous reconciliation toward a declared desired state stored in Git*. The four principles (as formalized by the OpenGitOps working group) are:

1. **Declarative** — the entire system is described declaratively.
2. **Versioned and immutable** — desired state is stored so that it is versioned and its history is immutable (Git).
3. **Pulled automatically** — software agents *pull* the desired state; the cluster is never *pushed* to from outside.
4. **Continuously reconciled** — agents continuously observe live state and act to converge it toward desired state.

**Argo CD is a Kubernetes controller that implements principles 3 and 4.** It runs *inside* the target cluster (or a management cluster), reads desired state from Git, compares it against live state, reports the difference, and — optionally — converges the cluster automatically. Git becomes the single source of truth and the only interface with write authority; humans interact with Git via pull requests, not with the cluster.

> **The architectural inversion:** in push CD, the pipeline reaches *into* the cluster. In pull GitOps, the agent reaches *out* to Git. The cluster's write credentials never leave the cluster.

---

## 2. Architecture and internal mechanics

Argo CD is not a monolith; it is a set of cooperating components. Understanding the split is the key to diagnosing production failures, because each failure mode maps to a specific component.

| Component | Deployment | Responsibility | Stateful? |
|---|---|---|---|
| `argocd-server` (API server) | Deployment | gRPC/REST API, serves Web UI and `argocd` CLI, authentication, RBAC enforcement, repo/cluster credential management, SSO integration, exposes events and logs | No (state in K8s + Redis) |
| `argocd-repo-server` | Deployment | Clones/caches Git repos, **generates manifests** (Helm template, Kustomize build, Jsonnet, plain YAML, Config Management Plugins), returns rendered manifests to the controller | Local git cache (ephemeral) |
| `argocd-application-controller` | StatefulSet | The reconciler: compares desired vs live, computes sync/health status, runs syncs, executes resource hooks and sync waves, prunes | No (state in K8s + Redis) |
| `argocd-applicationset-controller` | Deployment | Templates `Application` resources from generators (Git, Cluster, List, Matrix, PR, SCM…) | No |
| `argocd-notifications-controller` | Deployment | Evaluates triggers and dispatches notifications (Slack, webhook, email…) | No |
| `argocd-redis` | Deployment (or HA StatefulSet) | Cache for rendered manifests and computed app state; a **performance cache**, not a source of truth | Ephemeral cache |
| `argocd-dex-server` | Deployment (optional) | OIDC federation for SSO with external identity providers | No |

### 2.1 The reconciliation loop

The `application-controller` runs a control loop per `Application`. Conceptually:

```
                 ┌────────────────────────────────────────────────┐
                 │              application-controller             │
   Git repo ───► │  1. ask repo-server to render desired manifests │
 (source of      │  2. list live resources from cluster API        │
   truth)        │  3. diff desired vs live  → Sync status         │
                 │  4. assess resource health → Health status      │
   Cluster  ◄─── │  5. if auto-sync & OutOfSync → apply + hooks    │
   API server    │  6. cache result in Redis, emit events          │
                 └────────────────────────────────────────────────┘
```

- **Refresh vs. Sync are distinct.** A *refresh* re-renders manifests and recomputes the diff (read-only). A *sync* actually applies changes to the cluster. `OutOfSync` means "diff detected"; it does **not** mean "Argo CD will act" unless an automated sync policy is set.
- **Polling interval.** By default the controller reconciles each app roughly every **180 s** (`timeout.reconciliation` in `argocd-cm`). This is a *fallback*; the production pattern is to configure a **Git webhook** (`/api/webhook`) so pushes trigger near-instant refreshes and you can raise the polling interval to reduce Git and API load.
- **The engine.** The diff/sync/health machinery is the shared `gitops-engine` library, which Argo CD and other tools build on.

### 2.2 Resource tracking — how Argo CD knows what it owns

Argo CD must distinguish resources *it* manages from everything else in a namespace. Two mechanisms, chosen via `application.resourceTrackingMethod` in `argocd-cm`:

| Method | Marker | Pros | Cons |
|---|---|---|---|
| `label` (default legacy) | `app.kubernetes.io/instance: <app-name>` | Human-readable, `kubectl`-greppable | Value truncated at 63 chars; collides with tools that use the same well-known label; a resource can only belong to one app |
| `annotation` | `argocd.argoproj.io/tracking-id` | No length limit, no collision with app labels, encodes group/kind/namespace/name | Not a label, so not selectable with `kubectl -l` |
| `annotation+label` | Both | Annotation authoritative, label for tooling compatibility | Slightly more metadata |

Production guidance: prefer **`annotation`** for greenfield installs to avoid the well-known-label collision that silently makes two apps fight over the same object.

### 2.3 Sync status and health status are orthogonal

These two axes are the most misread concept on the exam and in incidents.

- **Sync status** answers: *does live match Git?* → `Synced` | `OutOfSync` | `Unknown`.
- **Health status** answers: *is the live resource actually working?* → `Healthy` | `Progressing` | `Degraded` | `Suspended` | `Missing` | `Unknown`.

An app can be **`Synced` and `Degraded`** (Git was applied faithfully, but the Deployment's pods are CrashLooping) or **`OutOfSync` and `Healthy`** (the running app is fine, but someone hand-edited it away from Git). Health is computed by built-in assessors for core kinds (Deployment, StatefulSet, Service, Ingress, PVC, Job, …) and by **custom Lua health checks** for CRDs (defined in `argocd-cm` under `resource.customizations`).

---

## 3. Technical comparisons (trade-off tables)

### 3.1 Pull-based GitOps vs. push-based CI/CD

| Dimension | Push CD (CI applies) | Pull GitOps (Argo CD) |
|---|---|---|
| Cluster credentials | Held by CI, broad scope, off-cluster | Stay inside the cluster; CI never touches the API server |
| Drift detection | None | Continuous, first-class |
| Self-healing | None | Optional (`selfHeal: true`) |
| Source of truth | Ambiguous (last pipeline run) | Git commit SHA |
| Multi-cluster fan-out | N pipelines, N credential sets | One controller → N registered clusters, or ApplicationSet |
| Rollback | Re-run old pipeline (may not be reproducible) | `git revert` → auto-converge |
| Audit | CI logs + cluster audit | Git history (signed commits possible) |

### 3.2 Argo CD vs. Flux CD

| Aspect | Argo CD | Flux CD |
|---|---|---|
| Primary UX | Rich Web UI + CLI + CRDs | CRDs + CLI (UI via Weave GitOps) |
| Core abstraction | `Application` CRD | `Kustomization` / `HelmRelease` CRDs |
| Multi-app templating | `ApplicationSet` generators | Kustomize overlays, dependencies |
| Manifest rendering | Centralized in `repo-server` (Helm/Kustomize/Jsonnet/plugins) | Source + build controllers per type |
| RBAC / multi-tenancy | `AppProject` + built-in RBAC (`policy.csv`) | Kubernetes RBAC + tenancy via namespaces |
| Best fit | Teams wanting a visual control plane and strong multi-tenant guardrails | Teams wanting minimal, controller-native, composable pieces |

Both are CNCF Graduated. The exam scope is Argo CD; the comparison matters for architectural justification.

### 3.3 Manual vs. automated sync policy

| | `syncPolicy` unset (manual) | `automated:` (no options) | `automated: { prune, selfHeal }` |
|---|---|---|---|
| Applies Git changes automatically | No | Yes | Yes |
| Deletes resources removed from Git | No | **No** (orphans left) | Yes (prune) |
| Reverts out-of-band cluster edits | No | No | Yes (selfHeal) |
| Risk profile | Safest, needs a human | New objects appear but deletions linger | Fully autonomous — highest drift correction, requires trust in Git as truth |

`selfHeal` and `prune` are **independent** and both default to `false`. A very common production mistake is enabling `automated` without `prune`, then wondering why deleted manifests keep running.

---

## 4. Core CRDs and complete manifests

Everything Argo CD does is declarative. The three CRDs (`argoproj.io/v1alpha1`): **`Application`**, **`AppProject`**, **`ApplicationSet`**.

### 4.1 A complete, production-grade `Application`

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: payments-api
  namespace: argocd                       # Applications live in the Argo CD namespace
  # The finalizer makes deletion cascade to the app's live resources.
  # Without it, deleting the Application orphans everything it created.
  finalizers:
    - resources-finalizer.argocd.argoproj.io
  labels:
    team: payments
spec:
  project: payments                       # must reference an existing AppProject
  source:
    repoURL: https://github.com/acme/platform-manifests.git
    targetRevision: v2.7.3                 # branch, tag, or commit SHA (SHA = immutable)
    path: apps/payments-api/overlays/prod
    kustomize:                             # rendering engine hint (Helm/Jsonnet also supported)
      namePrefix: prod-
      images:
        - registry.acme.io/payments-api:1.14.2
  destination:
    server: https://kubernetes.default.svc # in-cluster; or a registered remote cluster URL
    namespace: payments
  syncPolicy:
    automated:
      prune: true                          # delete resources removed from Git
      selfHeal: true                       # revert out-of-band cluster edits
      allowEmpty: false                    # refuse to prune down to zero resources (safety)
    syncOptions:
      - CreateNamespace=true               # create the destination namespace if absent
      - PruneLast=true                     # prune only after other resources sync (avoids gaps)
      - ApplyOutOfSyncOnly=true            # skip already-synced objects — faster large syncs
      - ServerSideApply=true               # SSA: avoids client-side last-applied annotation bloat
      - RespectIgnoreDifferences=true      # don't sync fields listed in ignoreDifferences
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
  # Fields Argo CD must NOT treat as drift (controllers/mutating webhooks own them).
  ignoreDifferences:
    - group: apps
      kind: Deployment
      jsonPointers:
        - /spec/replicas                   # HPA owns replicas; ignore it or fight forever
    - group: ""
      kind: Secret
      jqPathExpressions:
        - '.data["ca.crt"]'                # cert-manager injects this
  # Bound the amount of stale revision history kept in the Application status.
  revisionHistoryLimit: 10
```

**Key production annotations you set on the *child* resources** (not the Application):

- `argocd.argoproj.io/sync-wave: "-1"` — orders sync into **waves** (lower runs first; default `0`). Namespaces/CRDs/DBs go in earlier waves than the workloads that depend on them.
- `argocd.argoproj.io/hook: PreSync` — a **resource hook**; runs as a phase around the sync. Phases: `PreSync`, `Sync`, `PostSync`, `SyncFail`, plus `Skip`.
- `argocd.argoproj.io/hook-delete-policy: HookSucceeded` — clean up hook resources (`HookSucceeded` | `HookFailed` | `BeforeHookCreation`).

Example of a database migration Job as a PreSync hook:

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: db-migrate
  annotations:
    argocd.argoproj.io/hook: PreSync
    argocd.argoproj.io/hook-delete-policy: HookSucceeded
    argocd.argoproj.io/sync-wave: "-1"
spec:
  backoffLimit: 2
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: migrate
          image: registry.acme.io/payments-api:1.14.2
          command: ["/app/migrate", "up"]
```

If this Job fails, the entire sync fails before any new Deployment rolls out — exactly what you want for schema-changing releases.

### 4.2 Multi-tenancy guardrails: `AppProject`

`AppProject` is the security boundary. It constrains *where* apps may deploy from and to, *what* they may create, and *who* may operate them.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: payments
  namespace: argocd
spec:
  description: Payments team — prod + staging only
  # Whitelist of Git repos apps in this project may pull from.
  sourceRepos:
    - https://github.com/acme/platform-manifests.git
  # Whitelist of (cluster, namespace) an app may deploy to.
  destinations:
    - server: https://kubernetes.default.svc
      namespace: 'payments*'
    - server: https://staging.k8s.acme.io
      namespace: 'payments*'
  # Cluster-scoped kinds this project may manage (default: none allowed).
  clusterResourceWhitelist:
    - group: ''
      kind: Namespace
  # Namespaced kinds explicitly forbidden even if in Git.
  namespaceResourceBlacklist:
    - group: ''
      kind: ResourceQuota
    - group: ''
      kind: LimitRange
  # Deploy freeze windows (cron). Deny prod syncs during business hours.
  syncWindows:
    - kind: deny
      schedule: '0 9 * * MON-FRI'
      duration: 8h
      applications:
        - 'payments-*'
      manualSync: true          # humans may still sync manually; automation is blocked
  # Project-scoped RBAC roles with token support for CI.
  roles:
    - name: ci-deployer
      description: Read + sync only, for the deploy pipeline
      policies:
        - p, proj:payments:ci-deployer, applications, sync, payments/*, allow
        - p, proj:payments:ci-deployer, applications, get, payments/*, allow
      groups:
        - acme:payments-ci
```

### 4.3 Scaling to many apps/clusters: `ApplicationSet`

`ApplicationSet` templates `Application`s from **generators**, eliminating copy-paste sprawl. Generators: **List, Cluster, Git (directory/file), Matrix, Merge, SCM Provider, Pull Request, Cluster Decision Resource, Plugin.**

This example uses a **Matrix** generator (Git directories × registered clusters) to deploy every app directory to every production cluster:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: platform-addons
  namespace: argocd
spec:
  goTemplate: true
  goTemplateOptions: ["missingkey=error"]
  generators:
    - matrix:
        generators:
          # 1) one element per directory under addons/
          - git:
              repoURL: https://github.com/acme/platform-manifests.git
              revision: main
              directories:
                - path: addons/*
          # 2) one element per cluster labelled env=prod
          - clusters:
              selector:
                matchLabels:
                  env: prod
  template:
    metadata:
      name: '{{.path.basename}}-{{.name}}'    # e.g. ingress-nginx-prod-eu-west
    spec:
      project: platform
      source:
        repoURL: https://github.com/acme/platform-manifests.git
        targetRevision: main
        path: '{{.path.path}}'
      destination:
        server: '{{.server}}'
        namespace: '{{.path.basename}}'
      syncPolicy:
        automated: { prune: true, selfHeal: true }
        syncOptions: [ "CreateNamespace=true" ]
```

Adding a new prod cluster (labelled `env=prod`) or a new addon directory now *automatically* materializes the full cross-product of `Application`s — no manual manifest authoring.

### 4.4 The "App of Apps" pattern

A single root `Application` whose Git path contains **other `Application` manifests**. Bootstrapping a whole cluster becomes syncing one app.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: cluster-bootstrap
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/acme/platform-manifests.git
    targetRevision: main
    path: bootstrap/prod            # this directory contains Application YAMLs
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated: { prune: true, selfHeal: true }
```

`ApplicationSet` is generally preferred over App-of-Apps for homogeneous fan-out; App-of-Apps remains useful for heterogeneous, hand-curated bootstrap sets.

### 4.5 Declarative RBAC (`argocd-rbac-cm`)

Argo CD has its own RBAC layer (independent of Kubernetes RBAC) enforced by the API server:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-rbac-cm
  namespace: argocd
data:
  policy.default: role:readonly           # everyone gets read-only by default
  scopes: '[groups]'                       # map OIDC "groups" claim to roles
  policy.csv: |
    # p, <subject>, <resource>, <action>, <object>, <effect>
    p, role:payments-admin, applications, *, payments/*, allow
    p, role:payments-admin, logs, get, payments/*, allow
    p, role:payments-admin, exec, create, payments/*, allow
    # bind an SSO group to the role
    g, acme:payments-leads, role:payments-admin
```

---

## 5. CLI commands and real terminal output

Install the CLI, then log in against the API server (here via a port-forward):

```console
$ argocd login argocd.acme.io --grpc-web
Username: admin
Password:
'admin:login' logged in successfully
Context 'argocd.acme.io' updated
```

Create an app declaratively-from-flags (equivalent to applying the `Application` CRD):

```console
$ argocd app create payments-api \
    --repo https://github.com/acme/platform-manifests.git \
    --path apps/payments-api/overlays/prod \
    --revision v2.7.3 \
    --dest-server https://kubernetes.default.svc \
    --dest-namespace payments \
    --project payments \
    --sync-policy automated --auto-prune --self-heal
application 'payments-api' created
```

Inspect status — note **Sync** and **Health** reported independently:

```console
$ argocd app get payments-api
Name:               argocd/payments-api
Project:            payments
Server:             https://kubernetes.default.svc
Namespace:          payments
Repo:               https://github.com/acme/platform-manifests.git
Target:             v2.7.3
Path:               apps/payments-api/overlays/prod
SyncWindow:         Sync Allowed
Sync Policy:        Automated (Prune, SelfHeal)
Sync Status:        Synced to v2.7.3 (a1b2c3d)
Health Status:      Healthy

GROUP  KIND        NAMESPACE  NAME              STATUS  HEALTH   HOOK  MESSAGE
       Service     payments   prod-payments-api Synced  Healthy        service/prod-payments-api created
apps   Deployment  payments   prod-payments-api Synced  Healthy        deployment.apps/prod-payments-api created
       ConfigMap   payments   prod-payments-api Synced                 configmap/prod-payments-api created
```

Preview the diff before syncing (exit code `1` means differences exist — useful in CI gates):

```console
$ argocd app diff payments-api
===== apps/Deployment payments/prod-payments-api ======
27c27
<       image: registry.acme.io/payments-api:1.14.1
---
>       image: registry.acme.io/payments-api:1.14.2
$ echo $?
1
```

Force a sync and block until healthy:

```console
$ argocd app sync payments-api --prune
TIMESTAMP                  GROUP        KIND   NAMESPACE  NAME               STATUS    HEALTH        HOOK  MESSAGE
2026-08-12T14:03:11+00:00  apps  Deployment   payments   prod-payments-api  OutOfSync  Progressing
2026-08-12T14:03:19+00:00  apps  Deployment   payments   prod-payments-api  Synced     Progressing        deployment "prod-payments-api" updated

Operation:          Sync
Sync Revision:      a1b2c3d4e5f6...
Phase:              Succeeded
Message:            successfully synced (all tasks run)

$ argocd app wait payments-api --health --timeout 300
payments-api  Synced  Healthy
```

History and rollback:

```console
$ argocd app history payments-api
ID  DATE                           REVISION
7   2026-08-10 09:12:44 +0000 UTC  v2.7.1 (9f8e7d6)
8   2026-08-12 14:03:19 +0000 UTC  v2.7.3 (a1b2c3d)

$ argocd app rollback payments-api 7
Rollback 'payments-api' to 7 ...
Phase:   Succeeded
```

Register a remote cluster (creates a `Secret` of type cluster credentials in the `argocd` namespace):

```console
$ argocd cluster add prod-eu-west --name prod-eu-west
INFO Creating ServiceAccount argocd-manager in kube-system
INFO ClusterRole and ClusterRoleBinding created
Cluster 'https://EAA1...eu-west.k8s.acme.io' added
```

---

## 6. Verification and failure diagnosis

### 6.1 First triage — the two-axis read

Always separate the axes before doing anything else:

```console
$ argocd app list -o wide
NAME          CLUSTER                         NAMESPACE  PROJECT   STATUS     HEALTH     SYNCPOLICY  CONDITIONS
payments-api  https://kubernetes.default.svc  payments   payments  OutOfSync  Degraded   Auto-Prune  SyncError
```

- `OutOfSync` → a *diff* problem (Git vs live). Investigate with `argocd app diff`.
- `Degraded` → a *runtime* problem (the workload is unhealthy). Investigate the live resource with `kubectl`.
- Both → the sync applied but the new state is broken.

### 6.2 Failure catalog

| Symptom | Likely cause | Diagnosis / fix |
|---|---|---|
| `ComparisonError` / `Unknown` sync status | `repo-server` can't render (bad Helm values, private repo auth, Kustomize error) | `kubectl logs deploy/argocd-repo-server -n argocd`; verify repo creds with `argocd repo list` |
| App perpetually `OutOfSync` on the same field | A controller/webhook mutates a field Argo tries to revert (HPA replicas, injected sidecar, defaulted values) | Add the field to `ignoreDifferences`; enable `RespectIgnoreDifferences` |
| `selfHeal` fighting an operator every few seconds | Two controllers own the same field | Use `ignoreDifferences` or `ServerSideApply` with correct field managers |
| Sync `Succeeded` but app `Degraded` | Manifests applied fine; pods crash/liveness fails | `kubectl -n <ns> describe pod`, `kubectl logs`; this is an app bug, not an Argo bug |
| Resources deleted from Git still running | `prune` is `false` | Set `automated.prune: true`, or manually `argocd app sync --prune` |
| Whole app pruned to zero unexpectedly | Bad path/empty render + prune | Set `allowEmpty: false`; verify `spec.source.path` |
| Sync hook Job never cleaned up | Wrong/missing `hook-delete-policy` | Set `argocd.argoproj.io/hook-delete-policy: HookSucceeded` |
| Custom CRD stuck `Progressing` forever | No health assessor for that kind | Add a Lua `resource.customizations` health check in `argocd-cm` |
| `Application` won't delete | Missing/blocked finalizer or a child stuck terminating | Check `resources-finalizer.argocd.argoproj.io`; inspect stuck child resources |
| Sync blocked with "Sync is not allowed" | An active `deny` **sync window** on the `AppProject` | `argocd app get <app>` → check `SyncWindow`; sync manually if `manualSync: true` |

### 6.3 Deep diagnostics

Inspect what the controller actually computed for a specific resource:

```console
$ argocd app get payments-api --show-operation
...
Operation:          Sync
Phase:              Failed
Message:            one or more objects failed to apply, reason:
                    admission webhook "validate.kyverno.svc" denied the request:
                    resource Deployment/prod-payments-api has no resource limits
```

Component logs, in order of the pipeline stage that failed:

```console
# rendering failures (Sync status Unknown/ComparisonError)
$ kubectl logs -n argocd deploy/argocd-repo-server --tail=100

# sync/health/hook failures
$ kubectl logs -n argocd sts/argocd-application-controller --tail=100

# auth / RBAC / UI / CLI errors
$ kubectl logs -n argocd deploy/argocd-server --tail=100
```

Force a hard refresh (bypass the Redis manifest cache — the fix when Argo shows stale state after you *know* Git changed):

```console
$ argocd app get payments-api --hard-refresh
```

Confirm the exact revision Argo reconciled to and prove there is no drift:

```console
$ argocd app get payments-api -o json | jq '.status.sync.revision, .status.health.status'
"a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0"
"Healthy"
```

### 6.4 Observability signals

- **Prometheus metrics** are exposed by every component (`argocd-metrics`, `argocd-server-metrics`, `argocd-repo-server` `:8084/metrics`). Key SLO signals: `argocd_app_sync_total{phase}` (sync outcomes), `argocd_app_info{sync_status,health_status}` (fleet health), and controller reconciliation queue depth/latency (`argocd_app_reconcile` histogram) to detect a saturated controller that no longer keeps up with the fleet — the trigger to enable **controller sharding** across clusters.
- **Notifications controller** should alert on `on-sync-failed` and `on-health-degraded` so a `Degraded` prod app pages someone rather than sitting silently `Synced`.

---

## 7. References (official sources)

- CAPA curriculum (exam domains and weights): https://raw.githubusercontent.com/cncf/curriculum/master/capa/README.md
- Argo CD documentation (home): https://argo-cd.readthedocs.io/en/stable/
- Architecture and components: https://argo-cd.readthedocs.io/en/stable/operator-manual/architecture/
- Application CRD & sync options: https://argo-cd.readthedocs.io/en/stable/user-guide/sync-options/
- Automated sync policy (prune / selfHeal): https://argo-cd.readthedocs.io/en/stable/user-guide/auto_sync/
- Sync waves, phases and resource hooks: https://argo-cd.readthedocs.io/en/stable/user-guide/sync-waves/ and https://argo-cd.readthedocs.io/en/stable/user-guide/resource_hooks/
- Diffing and `ignoreDifferences`: https://argo-cd.readthedocs.io/en/stable/user-guide/diffing/
- Health assessment and custom Lua checks: https://argo-cd.readthedocs.io/en/stable/operator-manual/health/
- AppProject and multi-tenancy: https://argo-cd.readthedocs.io/en/stable/user-guide/projects/
- ApplicationSet and generators: https://argo-cd.readthedocs.io/en/stable/user-guide/application-set/ and https://argocd-applicationset.readthedocs.io/en/stable/
- RBAC configuration: https://argo-cd.readthedocs.io/en/stable/operator-manual/rbac/
- Resource tracking methods: https://argo-cd.readthedocs.io/en/stable/user-guide/resource_tracking/
- Prometheus metrics: https://argo-cd.readthedocs.io/en/stable/operator-manual/metrics/
- OpenGitOps principles: https://opengitops.dev/
- gitops-engine (shared reconciliation library): https://github.com/argoproj/gitops-engine