# 3.6 GitOps Basics, Controllers, and Workflows

> CNPA — Cloud Native Platform Engineering Associate · Exam version 2025-04-01 · Domain weight **2.25**

---

## 1. The production problem: why platforms converge on GitOps

A platform team operates dozens of clusters (dev, staging, N production regions, DR) and hundreds of tenant namespaces. The failure modes that GitOps exists to eliminate are all consequences of **imperative, out-of-band change**:

- **Configuration drift.** Someone runs `kubectl edit deployment` at 3 a.m. to stop an incident. The change is never written back anywhere. Six weeks later a redeploy silently reverts it and the incident recurs. Nobody can answer "what is *actually* running in prod?" because the answer lives in etcd, not in a reviewed artifact.
- **No causal audit trail.** Who scaled the HPA max from 10 to 40, when, and why? `kubectl` mutations leave only a coarse audit-log entry — no diff, no review, no linked ticket.
- **Snowflake clusters.** Cluster A got a manual `kubectl apply` of a hotfix; cluster B did not. The two environments diverge and the divergence is invisible until it causes a regional outage.
- **Broken rollback.** Rolling back means "remember the previous state and re-apply it" — but the previous state was never captured as data. `kubectl rollout undo` only covers the last workload revision, not RBAC, CRDs, NetworkPolicies, or config.
- **Credential sprawl.** Every CI pipeline that runs `kubectl apply` needs cluster-admin-adjacent credentials stored in the CI system — a large, externally reachable attack surface (the *push* model).

The architectural insight is that a Kubernetes cluster is already a **reconciliation engine**: controllers continuously drive observed state toward declared state. GitOps extends that same control loop *outside* the cluster boundary, making **Git the single source of truth for declared state** and adding an in-cluster agent whose only job is to keep the live cluster equal to Git.

This is codified by the **OpenGitOps** project (a CNCF sandbox project) as **four principles**:

| # | Principle | Practical meaning |
|---|-----------|-------------------|
| 1 | **Declarative** | The entire desired state is expressed as data (YAML/JSON), not scripts. `kubectl apply` steps become manifests. |
| 2 | **Versioned & immutable** | Desired state is stored in a system that enforces immutability and full version history — Git. Every state is a commit SHA. |
| 3 | **Pulled automatically** | Software agents **pull** the desired state from the source automatically. No external actor pushes into the cluster. |
| 4 | **Continuously reconciled** | Agents **continuously** observe and reconcile; drift is detected and corrected without human action. |

> Source: OpenGitOps Principles v1.0.0 — https://opengitops.dev/ and https://github.com/open-gitops/documents

The key phrase for the exam is **"continuously reconciled."** GitOps is *not* "CI that runs `kubectl apply`." That is push-based CD. GitOps requires an in-cluster controller running a closed control loop.

---

## 2. The controller / reconciliation model

### 2.1 Level-triggered vs edge-triggered

Kubernetes controllers are **level-triggered**, not edge-triggered. This distinction is the intellectual core of both Kubernetes *and* GitOps.

- **Edge-triggered:** react to *events* (the transition). If you miss the event, you miss the change. A dropped "deployment updated" event leaves you permanently wrong.
- **Level-triggered:** react to the *current level* (the state). Periodically compare desired vs observed and act on the difference. A missed event is harmless — the next reconcile observes the true level and corrects it.

```
        ┌──────────────────────────────────────────────┐
        │              reconciliation loop              │
        │                                               │
   Git (desired) ──► OBSERVE ──► DIFF ──► ACT ──► OBSERVE ...
   Cluster (live) ──────┘         │        │
                                  │        └─► kubectl apply-equivalent
                                  └─► if equal: no-op (idempotent)
```

Because each pass is a full observe → diff → act cycle, the loop is **idempotent** and **self-healing**: manual `kubectl edit` drift is corrected on the next reconcile, the same way a `Deployment` recreates a deleted `Pod`.

### 2.2 Two triggers in a real agent

Production GitOps controllers reconcile on **both** signals:

1. **Poll interval / webhook** on the *source* (Git repo changed → new desired state).
2. **Watch** on the *live cluster* (a live object changed → possible drift).

Argo CD default source poll is **3 minutes** (`timeout.reconciliation`); Flux `GitRepository` default `interval` is commonly set to `1m`. Both accept Git webhooks to make source changes near-instant instead of waiting for the poll.

---

## 3. Push vs Pull: the deployment-topology trade-off

| Dimension | **Push** (CI runs `kubectl apply`) | **Pull** (in-cluster agent reconciles) |
|-----------|-----------------------------------|----------------------------------------|
| Who initiates change | External CI system | In-cluster controller |
| Credentials location | Cluster creds stored in CI | None leave the cluster; agent uses in-cluster SA |
| Network direction | CI → cluster API (inbound to cluster) | Cluster → Git (outbound only) |
| Firewall posture | Cluster API must be reachable by CI | Cluster API can be fully private |
| Drift detection | None (fire-and-forget) | Continuous |
| Self-healing | No | Yes |
| Scales to N clusters | Poorly (N sets of creds, N targets) | Well (each cluster pulls itself) |
| Is it "GitOps"? | **No** — violates principles 3 & 4 | **Yes** |

The pull model is why GitOps is a **security control**, not just a workflow. Private clusters expose *no* inbound management surface; the only egress is a read to Git. Compromising the CI system no longer yields cluster credentials.

**Hybrid reality:** CI still builds/tests/pushes images and *bumps the image tag in Git*. CD is fully pull-based. CI's job ends at a commit; it never touches a cluster.

---

## 4. The two reference implementations: Argo CD and Flux

Both are CNCF **Graduated** projects. Both implement the pull model. They differ in shape.

| Aspect | **Argo CD** | **Flux (v2 / GitOps Toolkit)** |
|--------|-------------|--------------------------------|
| CNCF status | Graduated | Graduated |
| Primary abstraction | `Application` CRD | Set of composable CRDs: `GitRepository`, `Kustomization`, `HelmRelease`, `OCIRepository` |
| UI | First-class web UI + `argocd` CLI | CLI-first (`flux`); UI via Weave GitOps / Capacitor |
| Architecture | Monolithic-ish: `application-controller`, `repo-server`, `api-server`, `redis`, `dex` | Micro-controllers: `source-controller`, `kustomize-controller`, `helm-controller`, `notification-controller`, `image-*-controllers` |
| Config source | Helm, Kustomize, plain YAML, jsonnet | Kustomize, Helm, plain YAML, OCI artifacts |
| Multi-cluster | One control-plane manages many clusters (hub-and-spoke) | Typically one Flux per cluster (spoke-only), or hub with remote |
| Templating fan-out | `ApplicationSet` (generators) | `Kustomization` + overlays; image automation controllers |
| Secrets | External (SOPS, Sealed Secrets, ESO) | Native SOPS decryption in `kustomize-controller`; also ESO |
| Reconcile model | Level-triggered, app-scoped | Level-triggered, per-controller |
| Best fit | Central platform team, many tenant clusters, strong UI/RBAC needs | Composable, Kubernetes-native, GitOps-toolkit building blocks |

Neither is "better." **Argo CD** wins when a central platform team needs a visual control plane, rich RBAC, and hub-and-spoke management. **Flux** wins when you want small composable controllers, OCI-native artifacts, and native SOPS.

---

## 5. Argo CD in depth

### 5.1 Install (declaratively, of course)

```bash
$ kubectl create namespace argocd
namespace/argocd created

$ kubectl apply -n argocd \
    -f https://raw.githubusercontent.com/argoproj/argo-cd/v2.13.2/manifests/install.yaml
customresourcedefinition.apiextensions.k8s.io/applications.argoproj.io created
customresourcedefinition.apiextensions.k8s.io/applicationsets.argoproj.io created
customresourcedefinition.apiextensions.k8s.io/appprojects.argoproj.io created
serviceaccount/argocd-application-controller created
...
deployment.apps/argocd-server created
statefulset.apps/argocd-application-controller created

$ kubectl -n argocd rollout status statefulset/argocd-application-controller
statefulset rolling update complete 1 pods at revision argocd-application-controller-6b7d9f...

$ argocd admin initial-password -n argocd
kR3Xq7pL9mZ2nB4v
```

### 5.2 The `Application` — the atomic unit

An `Application` binds a **source** (repo/path/revision) to a **destination** (cluster/namespace) and declares a **sync policy**.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: payments-api
  namespace: argocd
  # Prevents deletion of the Application from orphaning live resources
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: payments            # AppProject providing guardrails (see 5.6)
  source:
    repoURL: https://github.com/acme/platform-config.git
    targetRevision: main       # branch, tag, or commit SHA — SHA is most immutable
    path: apps/payments-api/overlays/production
    kustomize:
      images:
        - acme/payments-api:1.8.3   # image pin lives in Git, not the cluster
  destination:
    server: https://kubernetes.default.svc   # in-cluster; or a registered remote
    namespace: payments
  syncPolicy:
    automated:
      prune: true              # delete live resources removed from Git
      selfHeal: true           # revert manual drift back to Git state
      allowEmpty: false        # refuse to sync an empty desired state (guard)
    syncOptions:
      - CreateNamespace=true
      - PrunePropagationPolicy=foreground
      - ApplyOutOfSyncOnly=true
      - ServerSideApply=true   # avoids last-applied-config annotation bloat
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
  # Ignore fields mutated by other controllers to avoid perpetual OutOfSync
  ignoreDifferences:
    - group: apps
      kind: Deployment
      jsonPointers:
        - /spec/replicas          # owned by HPA, not Git
```

Two flags define GitOps' self-healing character:

- **`prune: true`** — resources deleted from Git are deleted from the cluster. Without it, GitOps is additive-only and Git stops being the full source of truth.
- **`selfHeal: true`** — the loop watches live objects and reverts drift. This is principle 4 made operational.

> `ignoreDifferences` on `/spec/replicas` is a canonical production pattern: an HPA legitimately owns replica count, so Git must *not* fight it. Omitting this causes an endless OutOfSync → sync → HPA-scales → OutOfSync flap.

### 5.3 Sync waves and resource hooks (ordered rollout)

Ordering matters: run a DB migration *before* the new app version; create a CRD *before* a CR that uses it. Argo CD orders via **sync waves** (annotation, integer, ascending) and **hooks** (lifecycle phase).

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: db-migrate
  annotations:
    argocd.argoproj.io/hook: PreSync            # run before the main sync
    argocd.argoproj.io/hook-delete-policy: HookSucceeded
    argocd.argoproj.io/sync-wave: "-1"          # lower wave = earlier
spec:
  backoffLimit: 2
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: migrate
          image: acme/payments-api:1.8.3
          command: ["/app/migrate", "up"]
```

Hook phases: `PreSync` → `Sync` → `PostSync`, plus `SyncFail`. A failed `PreSync` hook aborts the sync — the new version never deploys against an unmigrated schema.

### 5.4 App-of-Apps and ApplicationSet (fan-out at scale)

Managing 200 `Application` objects by hand doesn't scale. Two patterns:

**App-of-Apps:** one root `Application` whose Git path contains *other* `Application` manifests. Bootstrap the whole platform from a single object.

**ApplicationSet:** a controller that *templates* `Application`s from a **generator**. The cluster generator below deploys the same app to every registered cluster labeled `env=production`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: monitoring-agent
  namespace: argocd
spec:
  goTemplate: true
  goTemplateOptions: ["missingkey=error"]
  generators:
    - clusters:
        selector:
          matchLabels:
            env: production
  template:
    metadata:
      name: 'monitoring-{{.name}}'          # one Application per matched cluster
    spec:
      project: platform
      source:
        repoURL: https://github.com/acme/platform-config.git
        targetRevision: main
        path: addons/monitoring
      destination:
        server: '{{.server}}'
        namespace: monitoring
      syncPolicy:
        automated: { prune: true, selfHeal: true }
        syncOptions: ["CreateNamespace=true"]
```

Add a new production cluster → the generator emits a new `Application` → the agent installs monitoring. Zero manual steps. This is the **platform** in Cloud Native Platform Engineering.

### 5.5 CLI walkthrough with real output

```bash
$ argocd app create payments-api \
    --repo https://github.com/acme/platform-config.git \
    --path apps/payments-api/overlays/production \
    --dest-server https://kubernetes.default.svc \
    --dest-namespace payments --sync-policy automated --auto-prune --self-heal
application 'payments-api' created

$ argocd app get payments-api
Name:               argocd/payments-api
Project:            payments
Server:             https://kubernetes.default.svc
Namespace:          payments
Repo:               https://github.com/acme/platform-config.git
Target:             main
Path:               apps/payments-api/overlays/production
SyncWindow:         Sync Allowed
Sync Policy:        Automated (Prune, SelfHeal)
Sync Status:        Synced to main (a1b2c3d)
Health Status:      Healthy

GROUP  KIND        NAMESPACE  NAME          STATUS  HEALTH   HOOK  MESSAGE
       Service     payments   payments-api  Synced  Healthy        service/payments-api created
apps   Deployment  payments   payments-api  Synced  Healthy        deployment.apps/payments-api created
       ConfigMap   payments   payments-api  Synced                 configmap/payments-api created

$ argocd app sync payments-api
TIMESTAMP                  GROUP        KIND   NAMESPACE   NAME          STATUS    HEALTH
2026-08-07T10:14:02+00:00  apps   Deployment   payments   payments-api  OutOfSync  Progressing
2026-08-07T10:14:19+00:00  apps   Deployment   payments   payments-api     Synced     Healthy
Operation:          Sync
Phase:              Succeeded
Message:            successfully synced (all tasks run)
```

Watch self-heal in action — drift is reverted automatically:

```bash
$ kubectl -n payments scale deployment payments-api --replicas=7
deployment.apps/payments-api scaled

$ argocd app get payments-api -o json | jq -r '.status.sync.status'
OutOfSync

# ~seconds later, selfHeal reconciles it back to the Git-declared 3
$ kubectl -n payments get deployment payments-api -o jsonpath='{.spec.replicas}{"\n"}'
3
```

### 5.6 `AppProject` — multi-tenant guardrails

```yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: payments
  namespace: argocd
spec:
  description: Payments tenant — restricted blast radius
  sourceRepos:
    - https://github.com/acme/platform-config.git   # only this repo allowed
  destinations:
    - server: https://kubernetes.default.svc
      namespace: payments                            # only this namespace
  clusterResourceWhitelist: []                        # no cluster-scoped resources
  namespaceResourceBlacklist:
    - group: ""
      kind: ResourceQuota                             # tenants can't edit their own quota
  roles:
    - name: deployer
      policies:
        - p, proj:payments:deployer, applications, sync, payments/*, allow
```

`AppProject` bounds *what* a tenant can deploy, *where*, and *from which repo* — the primary multi-tenancy control in Argo CD.

---

## 6. Flux in depth

Flux decomposes GitOps into small controllers. A minimal pipeline is a **`GitRepository`** (source) plus a **`Kustomization`** (apply + reconcile).

```bash
$ flux check --pre
► checking prerequisites
✔ Kubernetes 1.30.2 >=1.28.0-0
✔ prerequisites checks passed

$ flux bootstrap github \
    --owner=acme --repository=platform-config \
    --branch=main --path=clusters/production --personal
► connecting to github.com
► cloning branch "main"
✔ installed components
✔ reconciled sync configuration
◎ waiting for Kustomization "flux-system/flux-system" to be reconciled
✔ Kustomization reconciled successfully
► confirming components are healthy
✔ all components are healthy
```

```yaml
---
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: platform-config
  namespace: flux-system
spec:
  interval: 1m                 # poll Git every minute (level trigger)
  url: https://github.com/acme/platform-config.git
  ref:
    branch: main
  ignore: |
    /*
    !/apps/
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: payments-api
  namespace: flux-system
spec:
  interval: 5m                 # re-apply / drift-check every 5 minutes
  retryInterval: 1m
  timeout: 3m
  sourceRef:
    kind: GitRepository
    name: platform-config
  path: ./apps/payments-api/overlays/production
  prune: true                  # Flux's equivalent of Argo prune
  wait: true                   # block until all applied resources are Ready
  targetNamespace: payments
  # Native SOPS decryption — no external controller needed
  decryption:
    provider: sops
    secretRef:
      name: sops-age
  healthChecks:
    - apiVersion: apps/v1
      kind: Deployment
      name: payments-api
      namespace: payments
```

Flux's `dependsOn` gives cross-`Kustomization` ordering (Flux's analogue to sync waves):

```yaml
spec:
  dependsOn:
    - name: crds          # this Kustomization won't apply until "crds" is Ready
```

Operating Flux:

```bash
$ flux get kustomizations
NAME            REVISION            SUSPENDED  READY  MESSAGE
flux-system     main@sha1:a1b2c3d   False      True   Applied revision: main@sha1:a1b2c3d
payments-api    main@sha1:a1b2c3d   False      True   Applied revision: main@sha1:a1b2c3d

$ flux reconcile kustomization payments-api --with-source
► annotating GitRepository platform-config in flux-system namespace
✔ GitRepository annotated
◎ waiting for GitRepository reconciliation
✔ fetched revision main@sha1:e4f5a6b
✔ applied revision main@sha1:e4f5a6b

$ flux trace deployment/payments-api -n payments
Object:        Deployment/payments-api
Namespace:     payments
Status:        Managed by Flux
Kustomization: payments-api
Revision:      main@sha1:e4f5a6b
Source:        GitRepository/platform-config
```

`flux trace` answers "why is this object here and what commit produced it?" — the audit-trail property, on demand.

---

## 7. Workflows: pipelines as first-class Kubernetes objects

The "Workflows" half of 3.6 is about running **multi-step, DAG-structured jobs** on Kubernetes — the CI-side and job-orchestration complement to CD. The reference implementation is **Argo Workflows** (CNCF Graduated), driven by **Argo Events** and, for progressive delivery, **Argo Rollouts**.

### 7.1 Argo Workflows — DAG of containers

Each step is a container; dependencies form a DAG; the `workflow-controller` reconciles the DAG to completion.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Workflow
metadata:
  generateName: build-test-publish-
  namespace: ci
spec:
  entrypoint: pipeline
  serviceAccountName: argo-workflow
  arguments:
    parameters:
      - name: revision
        value: "main"
  templates:
    - name: pipeline
      dag:
        tasks:
          - name: checkout
            template: git-clone
            arguments:
              parameters: [{name: revision, value: "{{workflow.parameters.revision}}"}]
          - name: unit-test
            template: run
            dependencies: [checkout]
            arguments: {parameters: [{name: cmd, value: "make test"}]}
          - name: build-image
            template: run
            dependencies: [checkout]
            arguments: {parameters: [{name: cmd, value: "make image"}]}
          - name: publish
            template: run
            dependencies: [unit-test, build-image]   # fan-in: both must pass
            arguments: {parameters: [{name: cmd, value: "make push"}]}

    - name: git-clone
      inputs:
        parameters: [{name: revision}]
      container:
        image: alpine/git:2.45.2
        command: [sh, -c]
        args: ["git clone --depth 1 --branch {{inputs.parameters.revision}} https://github.com/acme/payments-api /work"]

    - name: run
      inputs:
        parameters: [{name: cmd}]
      container:
        image: acme/ci-toolbox:1.4.0
        command: [sh, -c]
        args: ["{{inputs.parameters.cmd}}"]
```

`unit-test` and `build-image` run **in parallel** (both depend only on `checkout`); `publish` is a **fan-in** that waits for both. This is a true DAG, not a linear script.

```bash
$ argo submit -n ci workflow.yaml --watch
Name:                build-test-publish-9x2kf
Namespace:           ci
Status:              Running
Created:             Fri Aug 07 10:31:44 +0000 (5 seconds ago)

STEP                        TEMPLATE   PODNAME                       DURATION  MESSAGE
 ● build-test-publish-9x2kf pipeline
 ├─✔ checkout               git-clone  build-test-publish-9x2kf-...  8s
 ├─● unit-test              run        build-test-publish-9x2kf-...  3s
 └─● build-image            run        build-test-publish-9x2kf-...  3s

$ argo list -n ci
NAME                       STATUS      AGE   DURATION   PRIORITY   MESSAGE
build-test-publish-9x2kf   Succeeded   2m    1m         0
```

### 7.2 Argo Events — event-driven triggering

Argo Events couples an **EventSource** (webhook, Kafka, S3, cron…) to a **Sensor** that, on a matching event, triggers a `Workflow`. A Git push webhook then launches the pipeline above — closing the CI loop event-driven, while CD stays pull-based.

### 7.3 Where Workflows and GitOps meet

A frequent production shape:

1. **Argo Events** fires on a Git push →
2. **Argo Workflows** builds, tests, and publishes `acme/payments-api:1.8.4`, then commits the new tag into `platform-config` (a *write-back*) →
3. **Argo CD / Flux** detects the commit and **pulls** it into the cluster.

CI (push-based, event-driven) ends at a Git commit. CD (pull-based, continuously reconciled) takes over there. The Git commit is the clean seam between the two control loops — and the single auditable record of what shipped.

---

## 8. Secrets in GitOps — the "don't commit plaintext" problem

GitOps stores desired state in Git, but a `Secret`'s `data` must not sit in plaintext in a repo. Three sanctioned patterns:

| Approach | Mechanism | Where the ciphertext lives | Trade-off |
|----------|-----------|----------------------------|-----------|
| **SOPS + age/KMS** | Encrypt values in Git; controller decrypts at apply | In Git (encrypted) | Native in Flux; Argo needs a plugin. Key management on you |
| **Sealed Secrets** | `kubeseal` encrypts to a `SealedSecret` CRD; in-cluster controller decrypts | In Git (encrypted) | Cluster-scoped private key; per-cluster re-seal |
| **External Secrets Operator (ESO)** | Git holds only a *reference*; ESO pulls from Vault/AWS SM/GCP SM | In an external vault, never in Git | Extra dependency; strongest separation |

```yaml
# External Secrets Operator — Git contains only a pointer, never the secret value
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: payments-db
  namespace: payments
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vault-backend
    kind: SecretStore
  target:
    name: payments-db          # the synthesized Kubernetes Secret
  data:
    - secretKey: password
      remoteRef:
        key: secret/data/payments/db
        property: password
```

The exam-relevant point: **plaintext secrets never enter Git.** Either the ciphertext is committed (SOPS/Sealed Secrets) or only a reference is committed (ESO).

---

## 9. Verification and failure diagnosis

### 9.1 Diagnostic decision table

| Symptom | Likely cause | Investigate |
|---------|--------------|-------------|
| `OutOfSync` that never clears | Another controller mutates a field (HPA→replicas, webhook→annotations) | Add `ignoreDifferences`; `argocd app diff <app>` |
| Perpetual sync flap | selfHeal fights HPA/mutating webhook | `ignoreDifferences` on the contested path |
| `Unknown` health | Custom resource with no health check / stuck CRD | `argocd app get`; add a Lua health check |
| `SyncFailed` / `ComparisonError` | Bad manifest, missing CRD, RBAC denial | `argocd app logs`; `kubectl describe application` |
| Argo CD sees no new commit | Poll not fired / webhook misconfigured | `argocd app get` revision; hard-refresh |
| Flux `Kustomization` not Ready | Source not fetched, build error, health check fail | `flux get sources git`; `flux logs` |
| Resource keeps getting deleted | `prune: true` + removed from Git accidentally | `git log` the path; check `ApplicationSet` output |
| Deleting an App orphans resources | Missing `resources-finalizer` | Add finalizer to `Application` |

### 9.2 Argo CD

```bash
# Exact drift between Git (desired) and cluster (live)
$ argocd app diff payments-api
===== apps/Deployment payments/payments-api ======
2c2
<   replicas: 3
---
>   replicas: 7

# Full status incl. conditions and last operation
$ argocd app get payments-api --show-operation

# Controller-side logs for a failed sync
$ argocd app logs payments-api --container application-controller

# Force a re-read of Git bypassing the cache
$ argocd app get payments-api --hard-refresh
```

`kubectl` view of the same object (the CRD *is* the API):

```bash
$ kubectl -n argocd get application payments-api \
    -o jsonpath='{.status.sync.status}{"  "}{.status.health.status}{"\n"}'
Synced  Healthy

$ kubectl -n argocd describe application payments-api | sed -n '/Conditions/,/Events/p'
Conditions:
  Type            Status  Message
  ----            ------  -------
  <none>
Events:
  Type    Reason  Age   From                  Message
  ----    ------  ----  ----                  -------
  Normal  Synced  30s   argocd-application-controller  Synced to main (a1b2c3d)
```

### 9.3 Flux

```bash
$ flux get all -A
NAMESPACE    NAME                                 REVISION           READY  MESSAGE
flux-system  gitrepository/platform-config        main@sha1:a1b2c3d  True   stored artifact
flux-system  kustomization/payments-api           main@sha1:a1b2c3d  True   Applied revision: main@sha1:a1b2c3d

# Why is a Kustomization not Ready?
$ flux logs --kind Kustomization --name payments-api --since 10m
2026-08-07T10:40:12Z info Kustomization/payments-api - server-side apply completed
2026-08-07T10:40:12Z error Kustomization/payments-api - Deployment/payments/payments-api dry-run failed: quota exceeded

# Pause reconciliation during an incident (stops self-heal fighting you)
$ flux suspend kustomization payments-api
► suspending kustomization payments-api in flux-system
✔ kustomization suspended

$ flux resume kustomization payments-api
```

> **Operational rule:** during an incident where you must hand-edit live state, **`flux suspend`** (or `argocd app set <app> --sync-policy none`) *first*. Otherwise self-heal reverts your emergency change mid-mitigation. Re-enable only after the fix is committed to Git.

### 9.4 The verification ladder (what is proven vs assumed)

1. **Synced** proves live == Git *at last reconcile* — not that Git is correct.
2. **Healthy** proves the resources report readiness — not that the app is functionally correct.
3. Correctness of the *declared* state is proven only by **review of the commit** and by tests in the Workflow (Section 7). GitOps guarantees "the cluster equals a reviewed commit," which is exactly why the commit review gate is load-bearing.

---

## 10. Exam-focused summary

- GitOps = **declarative + versioned/immutable + pulled + continuously reconciled** (OpenGitOps four principles). Missing the pull loop → it's just push CD, not GitOps.
- The engine is a **level-triggered reconciliation controller** that extends Kubernetes' own control-loop pattern past the cluster boundary. Idempotent, self-healing, drift-correcting.
- **Pull > Push** for security: no cluster creds in CI, no inbound cluster surface, works with private clusters.
- **Argo CD** (`Application`, `ApplicationSet`, `AppProject`, sync waves/hooks, self-heal/prune) vs **Flux** (`GitRepository` + `Kustomization`/`HelmRelease`, `dependsOn`, native SOPS). Both CNCF Graduated.
- **Workflows** (Argo Workflows DAGs + Argo Events triggers) handle CI/job orchestration; the clean seam to CD is a **Git commit**.
- **Secrets** never enter Git in plaintext: SOPS, Sealed Secrets, or External Secrets Operator.
- Diagnose with `argocd app get/diff/logs` and `flux get/logs/trace`; `ignoreDifferences` for controller-owned fields; **suspend before manual edits**.

---

## Referencias

- OpenGitOps — Principles & documents (CNCF): https://opengitops.dev/ · https://github.com/open-gitops/documents
- CNPA Curriculum (CNCF): https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf
- Argo CD — Documentation: https://argo-cd.readthedocs.io/en/stable/
- Argo CD — Declarative Setup (`Application`, `AppProject`): https://argo-cd.readthedocs.io/en/stable/operator-manual/declarative-setup/
- Argo CD — Sync Waves & Resource Hooks: https://argo-cd.readthedocs.io/en/stable/user-guide/sync-waves/ · https://argo-cd.readthedocs.io/en/stable/user-guide/resource_hooks/
- Argo CD — ApplicationSet: https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/
- Argo Workflows — Documentation: https://argo-workflows.readthedocs.io/en/latest/
- Argo Events — Documentation: https://argoproj.github.io/argo-events/
- Argo Rollouts — Progressive Delivery: https://argo-rollouts.readthedocs.io/en/stable/
- Flux — Documentation & GitOps Toolkit: https://fluxcd.io/flux/ · https://fluxcd.io/flux/components/
- Flux — Kustomization & dependencies: https://fluxcd.io/flux/components/kustomize/kustomizations/
- Flux — Mozilla SOPS guide: https://fluxcd.io/flux/guides/mozilla-sops/
- Sealed Secrets (Bitnami Labs): https://github.com/bitnami-labs/sealed-secrets
- External Secrets Operator: https://external-secrets.io/latest/
- CNCF Landscape — Graduated projects (Argo, Flux): https://landscape.cncf.io/
- Kubernetes — Controllers & the reconciliation loop: https://kubernetes.io/docs/concepts/architecture/controller/