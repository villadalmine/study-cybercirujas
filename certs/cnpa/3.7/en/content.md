# 3.7 GitOps for Multi-Environment Application Management

> Domain 3 — Continuous Delivery & Platform Engineering · Exam weight ≈ 2.25
>
> This topic is where declarative delivery stops being a single-cluster demo and becomes an operating model: the same application definition promoted, safely and auditably, across `dev → staging → prod`, across many clusters, without a human running `kubectl apply` and without configuration silently drifting between environments.

---

## 1. The production problem: why "multi-environment" breaks naive CD

A push-based CI/CD pipeline that runs `kubectl apply` (or `helm upgrade`) from a runner works for one cluster and one team. It fails predictably at scale:

- **Configuration drift.** An operator hotfixes prod with `kubectl edit`, or an autoscaler/mutating webhook changes a field. The cluster no longer matches any source of truth, and nobody can answer "what is actually running in prod?" without diffing live state by hand.
- **Credential blast radius.** Push CD needs cluster-admin-grade credentials *outside* the cluster, in the CI system. A compromised runner or a leaked kubeconfig is a path straight into every environment the pipeline can reach.
- **Environment divergence.** Dev, staging and prod are copy-pasted YAML that rot independently. A resource limit fixed in staging never reaches prod; a feature flag left on in dev leaks into a promotion. There is no *single* definition with per-environment *differences* — there are three whole definitions.
- **No promotion contract.** "Promote to prod" means "someone re-runs the pipeline with different variables," which is neither reviewable nor atomic nor revertible. Rollback is "run the old pipeline again and hope."
- **Auditability gap.** Who changed what, when, and why? With imperative pipelines the answer lives in CI logs that expire, not in an immutable, signed history.

**GitOps** reframes deployment as *continuous reconciliation of live state toward a declared desired state stored in Git*. The four OpenGitOps principles (CNCF) define the contract:

| # | Principle | What it forces in a multi-env setup |
|---|-----------|--------------------------------------|
| 1 | **Declarative** | Every environment's desired state is expressed as data (YAML/Helm/Kustomize), not as pipeline steps. |
| 2 | **Versioned & Immutable** | Git is the single source of truth; every promotion is a commit/tag with a full audit trail and instant `git revert`. |
| 3 | **Pulled automatically** | An in-cluster agent pulls desired state. No external credentials, no push access to the cluster. |
| 4 | **Continuously reconciled** | An agent constantly detects and corrects drift — the cluster *converges* to Git, it doesn't merely get "applied to." |

The architectural shift is from a **push model** (CI has cluster credentials, imperatively mutates the cluster) to a **pull model** (a controller *inside* each cluster watches Git and reconciles). Multi-environment management is then a problem of *how you structure Git and how you fan out one definition to N targets* — which is the substance of the rest of this topic.

---

## 2. The core design decisions (with trade-offs)

Three orthogonal decisions define any multi-environment GitOps topology. Get them wrong and you will fight the tooling forever.

### 2.1 Repository topology

| Pattern | Structure | Pros | Cons | Use when |
|---------|-----------|------|------|----------|
| **Monorepo, dir-per-env** | one repo, `envs/dev`, `envs/staging`, `envs/prod` | atomic cross-env changes; one place to reason about; trivial diff between envs | coarse RBAC (repo-level); large blob for big orgs | small/medium org, few teams |
| **Polyrepo (per team/app)** | one config repo per app or team | fine-grained RBAC; independent lifecycles; smaller blast radius | cross-cutting changes span repos; harder to see the whole platform | many teams, strong isolation needs |
| **Split app vs config repo** | source code in repo A, deploy manifests in repo B | CI writes to config repo; clean separation of "build" vs "run" | two-repo dance; promotion is a commit to repo B | almost always — keep app code and desired state apart |

**Rule of thumb:** separate the *application source repo* (where CI builds images) from the *config/GitOps repo* (what the reconciler watches). CI's only write into the GitOps repo is bumping an image tag — that commit *is* the deployment.

### 2.2 Environment modeling: branch-per-env vs directory-per-env

This is the single most consequential decision, and the industry has converged hard on one answer.

| Model | How promotion works | Verdict |
|-------|--------------------|---------|
| **Branch-per-environment** (`dev`, `staging`, `prod` branches) | promote = merge `dev` → `staging` → `prod` | **Anti-pattern.** Merges carry *unrelated* changes forward; envs diverge via cherry-picks; you cannot see per-env differences as a diff; drift between branches is invisible. |
| **Directory-per-environment** (one branch, `overlays/{dev,staging,prod}`) | promote = copy/patch the changed field (usually an image tag) into the next overlay | **Recommended.** Differences are explicit overlays over a shared base; the *whole* platform state is one commit; per-env diff is a `diff overlays/staging overlays/prod`. |

Directory-per-env pairs naturally with **Kustomize overlays** or **Helm value files**: one base, N thin overlays that encode only what differs (replicas, resources, ingress host, image tag).

### 2.3 Configuration templating

| Tool | Model | Strengths | Weaknesses |
|------|-------|-----------|------------|
| **Raw manifests** | static YAML | zero magic; exactly what runs | no reuse; N copies drift |
| **Kustomize** | patch/overlay (no templating) | declarative overlays, strategic-merge & JSON6902 patches, built into `kubectl`; env = base + patch | awkward for deeply parameterized charts; no loops/conditionals |
| **Helm** | Go-template + values | rich ecosystem, packaging, conditionals/loops, versioned releases | template rendering hides the final YAML until render time; value precedence is subtle |
| **Helm rendered by Kustomize** | `helmCharts` in kustomization, or CMP | best of both: chart reuse + overlay patches | two mental models stacked |

For exam purposes and for production: **Kustomize base+overlays is the canonical multi-env primitive**; Helm is used where a packaged chart already exists, often wrapped in a Flux `HelmRelease` or an Argo CD Application pointing at a chart.

---

## 3. The two reference implementations

The CNCF GitOps ecosystem has two mature, graduated/incubating reconcilers: **Argo CD** and **Flux**. Know both; the exam treats them as interchangeable expressions of the same principles.

### 3.1 Argo CD vs Flux — architecture and trade-offs

| Dimension | Argo CD | Flux |
|-----------|---------|------|
| **CNCF status** | Graduated (Argo project) | Graduated |
| **Model** | Application CRD + application-controller reconciliation loop; strong UI | Set of composable controllers (source, kustomize, helm, notification, image-automation) |
| **UX** | Rich web UI, RBAC, SSO, project isolation | CLI/GitOps-native, no first-party UI (Weave GitOps / Capacitor add one) |
| **Fan-out primitive** | **ApplicationSet** (generators) | **Kustomization** per env + templating, or Flux `tenants`/`Kustomization` composition |
| **Multi-cluster** | one control-plane Argo CD manages many clusters (cluster secrets) | typically Flux-per-cluster (pull-native), or hub-and-spoke |
| **Image automation** | Argo CD Image Updater (separate) | built-in image-reflector + image-automation controllers |
| **Progressive delivery** | Argo Rollouts | Flagger |
| **Sync semantics** | sync waves, hooks, self-heal, prune, server-side apply | dependsOn ordering, health checks, prune via inventory, server-side apply |

**Mental model:**
- Argo CD is a *centralized control plane* with a great operator UX. Multi-env = **ApplicationSet** generating one `Application` per (env, cluster).
- Flux is a *set of controllers running in each cluster* that pull Git. Multi-env = one `Kustomization` per environment path, composed with `dependsOn` and sources.

### 3.2 Reconciliation loop mechanics (what "continuously reconciled" actually means)

**Argo CD:** the `application-controller` runs a loop per Application:
1. **Refresh** desired state from Git (polls every `timeout.reconciliation`, default 180s — or instantly via a Git webhook).
2. **Compute diff** between desired (rendered manifests) and live (cluster) state → status `Synced` / `OutOfSync`.
3. **Assess health** via built-in + Lua custom health checks → `Healthy` / `Progressing` / `Degraded` / `Missing`.
4. **Sync** (if `automated`) applies via `kubectl apply` or **server-side apply**, honoring sync waves/hooks; with `selfHeal: true` it reverts manual drift; with `prune: true` it deletes resources removed from Git.

**Flux:** `source-controller` fetches the `GitRepository`/`OCIRepository` at `.spec.interval`; `kustomize-controller` builds the path, applies with **server-side apply**, tracks an inventory for pruning, and reports readiness. `dependsOn` orders Kustomizations (e.g. infra before apps).

The key production property both give you: **drift is not just detected, it is corrected**. A `kubectl edit` on prod is reverted on the next reconcile (with self-heal on), and the event is visible.

---

## 4. Full manifests — Argo CD multi-environment

### 4.1 The shared Kustomize base and per-env overlays (the config repo)

Config repo layout (`platform-config` repo, `main` branch):

```
apps/web/
├── base/
│   ├── kustomization.yaml
│   ├── deployment.yaml
│   ├── service.yaml
│   └── hpa.yaml
└── overlays/
    ├── dev/
    │   ├── kustomization.yaml
    │   └── replicas-and-resources.yaml
    ├── staging/
    │   ├── kustomization.yaml
    │   └── replicas-and-resources.yaml
    └── prod/
        ├── kustomization.yaml
        ├── replicas-and-resources.yaml
        └── ingress-host.yaml
```

**`apps/web/base/deployment.yaml`**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  labels:
    app.kubernetes.io/name: web
    app.kubernetes.io/part-of: storefront
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: web
  template:
    metadata:
      labels:
        app.kubernetes.io/name: web
    spec:
      securityContext:
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: web
          image: registry.example.com/storefront/web:REPLACED_BY_OVERLAY
          ports:
            - containerPort: 8080
              name: http
          readinessProbe:
            httpGet:
              path: /healthz/ready
              port: http
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /healthz/live
              port: http
            initialDelaySeconds: 15
            periodSeconds: 20
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 250m
              memory: 256Mi
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
```

**`apps/web/base/service.yaml`**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: web
  labels:
    app.kubernetes.io/name: web
spec:
  selector:
    app.kubernetes.io/name: web
  ports:
    - name: http
      port: 80
      targetPort: http
```

**`apps/web/base/hpa.yaml`**

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: web
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: web
  minReplicas: 1
  maxReplicas: 3
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
```

**`apps/web/base/kustomization.yaml`**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - deployment.yaml
  - service.yaml
  - hpa.yaml
commonLabels:
  app.kubernetes.io/managed-by: argocd
```

**`apps/web/overlays/prod/kustomization.yaml`** — the overlay encodes *only* what differs in prod:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: storefront-prod
resources:
  - ../../base
  - ingress-host.yaml
# The image tag is the promotion unit: CI (or Image Updater) bumps this line.
images:
  - name: registry.example.com/storefront/web
    newTag: "1.14.2"
patches:
  - path: replicas-and-resources.yaml
    target:
      kind: Deployment
      name: web
```

**`apps/web/overlays/prod/replicas-and-resources.yaml`** — a strategic-merge patch:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
spec:
  replicas: 6
  template:
    spec:
      containers:
        - name: web
          resources:
            requests:
              cpu: 500m
              memory: 512Mi
            limits:
              cpu: "1"
              memory: 1Gi
```

**`apps/web/overlays/prod/ingress-host.yaml`**

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: web
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
spec:
  ingressClassName: nginx
  tls:
    - hosts: ["shop.example.com"]
      secretName: web-tls
  rules:
    - host: shop.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: web
                port:
                  number: 80
```

The `dev` and `staging` overlays are structurally identical, differing only in `namespace`, `newTag`, `replicas`, resources, and host — *exactly* the fields that legitimately vary by environment. Everything else is inherited from the single base, so a change to the base propagates to all three the moment each overlay is reconciled.

### 4.2 Fan-out with ApplicationSet (one Application per environment)

Instead of hand-writing three `Application` CRDs, use an **ApplicationSet** with a **Git directory generator** that discovers each overlay and templates one Application per environment:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: web
  namespace: argocd
spec:
  goTemplate: true
  goTemplateOptions: ["missingkey=error"]
  generators:
    - matrix:
        generators:
          # 1) one entry per overlay directory
          - git:
              repoURL: https://git.example.com/platform/platform-config.git
              revision: main
              directories:
                - path: apps/web/overlays/*
          # 2) join each env with its target cluster (cluster generator by label)
          - clusters:
              selector:
                matchLabels:
                  argocd.argoproj.io/secret-type: cluster
  template:
    metadata:
      name: 'web-{{ index .path.segments 3 }}'   # web-dev / web-staging / web-prod
    spec:
      project: storefront
      source:
        repoURL: https://git.example.com/platform/platform-config.git
        targetRevision: main
        path: '{{ .path.path }}'                  # apps/web/overlays/<env>
      destination:
        server: '{{ .server }}'
        namespace: 'storefront-{{ index .path.segments 3 }}'
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
          - ServerSideApply=true
        retry:
          limit: 5
          backoff:
            duration: 5s
            factor: 2
            maxDuration: 3m
```

> **Production note:** using `selfHeal: true` on **prod** is a deliberate choice. It guarantees no manual drift survives — but it also means an operator cannot hot-patch prod outside Git. That is the point: the *only* way to change prod is a reviewed commit. Many teams keep `selfHeal` on everywhere and gate prod with a `manual` sync (`automated` omitted, `argocd app sync web-prod` after PR merge) plus sync windows.

### 4.3 AppProject — the isolation boundary

`ApplicationSet` needs an `AppProject` to constrain *where* Applications may deploy and *what* they may create — the multi-tenant guardrail:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: storefront
  namespace: argocd
spec:
  description: Storefront team — web + api
  sourceRepos:
    - https://git.example.com/platform/platform-config.git
  destinations:
    - server: '*'
      namespace: 'storefront-*'
  clusterResourceWhitelist:
    - group: ''
      kind: Namespace
  namespaceResourceBlacklist:
    - group: ''
      kind: ResourceQuota     # only the platform team sets quotas
  roles:
    - name: deployer
      description: promote via CI
      policies:
        - p, proj:storefront:deployer, applications, sync, storefront/*, allow
      groups:
        - storefront-ci
```

### 4.4 The app-of-apps alternative

Where `ApplicationSet` generators don't fit (heterogeneous apps with bespoke settings), the **app-of-apps** pattern nests a root Application whose Git path contains child `Application` manifests. It is simpler to reason about but does not template — you maintain each child by hand. Prefer `ApplicationSet` for *homogeneous fan-out* (same app across envs/clusters) and app-of-apps for *curating a set of distinct apps*.

---

## 5. Full manifests — Flux multi-environment

Flux expresses the same topology with composable controllers. The source is declared once; a `Kustomization` per environment reconciles a path.

**`clusters/prod/flux-system/gotk-sync` — the source:**

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: platform-config
  namespace: flux-system
spec:
  interval: 1m
  url: https://git.example.com/platform/platform-config.git
  ref:
    branch: main
  # verify commit signatures — supply-chain guardrail
  verify:
    mode: HEAD
    secretRef:
      name: flux-gpg-pubkeys
```

**Per-environment Kustomization (prod cluster):**

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: web-prod
  namespace: flux-system
spec:
  interval: 5m
  retryInterval: 1m
  timeout: 3m
  sourceRef:
    kind: GitRepository
    name: platform-config
  path: ./apps/web/overlays/prod
  prune: true                 # delete resources removed from Git (inventory-tracked)
  wait: true                  # block until all applied resources are Ready
  targetNamespace: storefront-prod
  dependsOn:
    - name: infra-controllers # infra reconciles before apps
  postBuild:
    substitute:
      cluster_env: "prod"
  healthChecks:
    - apiVersion: apps/v1
      kind: Deployment
      name: web
      namespace: storefront-prod
  decryption:                 # SOPS-encrypted secrets in the repo
    provider: sops
    secretRef:
      name: sops-age
```

**A Helm-based app via `HelmRelease`** (for packaged charts), with per-env values:

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: bitnami
  namespace: flux-system
spec:
  interval: 30m
  url: https://charts.bitnami.com/bitnami
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: redis
  namespace: storefront-prod
spec:
  interval: 10m
  chart:
    spec:
      chart: redis
      version: "20.x"
      sourceRef:
        kind: HelmRepository
        name: bitnami
        namespace: flux-system
  install:
    remediation:
      retries: 3
  upgrade:
    remediation:
      retries: 3
      remediateLastFailure: true
  values:
    architecture: replication
    replica:
      replicaCount: 3
```

The multi-env story in Flux: **the same `apps/web/overlays/prod` path** is reconciled by the prod cluster's Flux, while `overlays/staging` is reconciled by staging's Flux. Each cluster pulls only its slice — pull-native isolation with no central credential.

---

## 6. Promotion strategies (the heart of "multi-environment management")

Promotion is *how a change moves from one environment to the next*. Compare the mainstream patterns:

| Strategy | Mechanism | Auditability | Automation | Risk |
|----------|-----------|-------------|------------|------|
| **Manual overlay edit** | human edits `newTag` in next overlay, opens PR | high (PR) | low | slow but deliberate; good for prod |
| **Image automation** (Argo Image Updater / Flux image-automation) | controller watches registry, commits new tag to overlay | high (git commit) | high | needs tight tag-filter policy or it promotes everything |
| **PR-based promotion** | CI opens a PR from lower→higher overlay diff | high (review gate) | medium | best balance for regulated prod |
| **Rendered-manifests pattern** | CI renders final YAML per env into a branch/dir; reconciler applies raw YAML | very high (diff is literal) | high | eliminates "template rendered differently in prod" surprises |
| **Kargo / promotion controller** | declarative Stage graph with freight promotion + verification | very high | high | extra component; strong for complex pipelines |

### 6.1 Flux image automation (build → auto-promote to dev)

```yaml
apiVersion: image.toolkit.fluxcd.io/v1beta2
kind: ImageRepository
metadata:
  name: web
  namespace: flux-system
spec:
  image: registry.example.com/storefront/web
  interval: 5m
---
apiVersion: image.toolkit.fluxcd.io/v1beta2
kind: ImagePolicy
metadata:
  name: web-dev
  namespace: flux-system
spec:
  imageRepositoryRef:
    name: web
  policy:
    semver:
      range: ">=1.0.0 <2.0.0"    # only 1.x into dev
---
apiVersion: image.toolkit.fluxcd.io/v1beta1
kind: ImageUpdateAutomation
metadata:
  name: web-dev
  namespace: flux-system
spec:
  interval: 5m
  sourceRef:
    kind: GitRepository
    name: platform-config
  git:
    checkout:
      ref:
        branch: main
    commit:
      author:
        name: fluxbot
        email: fluxbot@example.com
      messageTemplate: "chore(dev): promote web to {{ .NewTag }}"
    push:
      branch: main
  update:
    path: ./apps/web/overlays/dev
    strategy: Setters
```

The overlay's image line is marked with a **setter comment** so the controller knows what to bump:

```yaml
images:
  - name: registry.example.com/storefront/web
    newTag: "1.14.2" # {"$imagepolicy": "flux-system:web-dev:tag"}
```

**Promotion to staging/prod is deliberately *not* automated** — it is a PR that copies the dev tag into the next overlay, gated by review and (for prod) a sync window. This encodes the promotion contract in Git history.

### 6.2 Sync waves & hooks (ordering within a sync — Argo CD)

Multi-env deploys frequently need ordering: run a DB migration before the new Deployment, create namespaces before workloads. Argo CD sync waves and hooks:

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: db-migrate
  annotations:
    argocd.argoproj.io/hook: PreSync          # run before the main sync
    argocd.argoproj.io/hook-delete-policy: HookSucceeded
    argocd.argoproj.io/sync-wave: "-1"        # lower waves apply first
spec:
  backoffLimit: 2
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: migrate
          image: registry.example.com/storefront/web:1.14.2
          command: ["/app/migrate", "up"]
```

Flux achieves the same ordering with `dependsOn` between Kustomizations and per-object health gates.

---

## 7. Secrets across environments

You cannot commit plaintext secrets to Git. The three production-grade patterns:

| Pattern | How it works | Trust model | Multi-env fit |
|---------|--------------|-------------|---------------|
| **Sealed Secrets** | `kubeseal` encrypts to a `SealedSecret` (asymmetric, controller-held private key); safe to commit | controller in each cluster holds the key | per-cluster key ⇒ re-seal per env; simple |
| **External Secrets Operator (ESO)** | `ExternalSecret` references a `ClusterSecretStore` (Vault, AWS/GCP SM, Azure KV); operator syncs into a K8s Secret | external secret manager is source of truth | excellent — per-env store path, nothing sensitive in Git |
| **SOPS (Mozilla)** | encrypt values with age/KMS; Flux `decryption` / Argo CD plugin decrypts at apply | age/KMS key per env | native to Flux; keeps ciphertext in Git |

**ESO example (prod overlay references a prod Vault path):**

```yaml
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: vault-prod
spec:
  provider:
    vault:
      server: https://vault.example.com
      path: secret
      version: v2
      auth:
        kubernetes:
          mountPath: kubernetes
          role: storefront-prod
          serviceAccountRef:
            name: eso
            namespace: external-secrets
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: web-db
  namespace: storefront-prod
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: vault-prod
  target:
    name: web-db          # the K8s Secret ESO creates/keeps in sync
    creationPolicy: Owner
  data:
    - secretKey: DATABASE_URL
      remoteRef:
        key: storefront/prod/db
        property: url
```

The overlay differs by *store name/path* (`vault-prod` vs `vault-staging`), so the *reference* is versioned in Git while the *secret material* never is. This is the cleanest multi-env secrets story.

---

## 8. Verification & failure diagnosis

### 8.1 Steady-state verification — Argo CD

```console
$ argocd app list -p storefront
NAME         CLUSTER                         NAMESPACE          PROJECT     STATUS   HEALTH   SYNCPOLICY  CONDITIONS
web-dev      https://kubernetes.default.svc  storefront-dev     storefront  Synced   Healthy  Auto-Prune  <none>
web-staging  https://10.0.2.10:6443          storefront-staging storefront  Synced   Healthy  Auto-Prune  <none>
web-prod     https://10.0.3.10:6443          storefront-prod    storefront  Synced   Healthy  Auto        <none>

$ argocd app get web-prod
Name:               argocd/web-prod
Project:            storefront
Server:             https://10.0.3.10:6443
Namespace:          storefront-prod
Sync Policy:        Automated (Prune, SelfHeal)
Sync Status:        Synced to main (a1b2c3d)
Health Status:      Healthy

GROUP  KIND        NAMESPACE        NAME  STATUS  HEALTH   HOOK  MESSAGE
       Service     storefront-prod  web   Synced  Healthy        service/web created
apps   Deployment  storefront-prod  web   Synced  Healthy        deployment.apps/web configured
       Ingress     storefront-prod  web   Synced  Healthy        ingress.networking.k8s.io/web created
```

### 8.2 Drift detection & correction

Simulate manual drift, then watch self-heal:

```console
$ kubectl -n storefront-prod scale deploy/web --replicas=1
deployment.apps/web scaled

$ argocd app get web-prod --refresh -o wide | grep -E 'Sync Status|Deployment'
Sync Status:  OutOfSync from main (a1b2c3d)
apps  Deployment  storefront-prod  web  OutOfSync  Progressing  deployment.apps/web configured

$ argocd app diff web-prod
===== apps/Deployment storefront-prod/web ======
23c23
<   replicas: 1        # live
---
>   replicas: 6        # desired (Git)

# with selfHeal:true the controller reverts within one reconcile:
$ argocd app get web-prod -o wide | grep 'Sync Status'
Sync Status:  Synced to main (a1b2c3d)
```

This is the observable proof of principle #4 — the cluster was pulled back to Git without human action.

### 8.3 Diagnosing a failed sync

```console
$ argocd app sync web-prod
FATA[0004] Operation has completed with phase: Failed

$ argocd app get web-prod | sed -n '/CONDITIONS/,+3p'
CONDITIONS:
  SyncError: one or more objects failed to apply, reason: admission webhook
  "validate.kyverno.svc" denied the request: resource limits are required

# root-cause the rejected object, fix the base/overlay, commit, re-sync
$ kubectl -n storefront-prod get events --sort-by=.lastTimestamp | tail -3
2m  Warning  FailedCreate  replicaset/web-7c9  admission webhook denied the request
```

### 8.4 Steady-state verification — Flux

```console
$ flux get kustomizations -A
NAMESPACE     NAME               REVISION            SUSPENDED  READY  MESSAGE
flux-system   infra-controllers  main@sha1:9f3a...   False      True   Applied revision: main@sha1:9f3a
flux-system   web-prod           main@sha1:9f3a...   False      True   Applied revision: main@sha1:9f3a

$ flux get sources git
NAME              REVISION            SUSPENDED  READY  MESSAGE
platform-config   main@sha1:9f3a...   False      True   stored artifact for revision 'main@sha1:9f3a'

# Force an immediate reconcile (don't wait for the interval):
$ flux reconcile kustomization web-prod --with-source
► annotating GitRepository platform-config in flux-system namespace
✔ GitRepository annotated
◎ waiting for GitRepository reconciliation
✔ fetched revision main@sha1:9f3a
► annotating Kustomization web-prod in flux-system namespace
✔ Kustomization reconciliation completed
✔ applied revision main@sha1:9f3a
```

### 8.5 Diagnosing a failed Flux reconcile

```console
$ flux get kustomizations -A
NAMESPACE    NAME      REVISION           SUSPENDED  READY  MESSAGE
flux-system  web-prod  main@sha1:9f3a...  False      False  Deployment/storefront-prod/web dry-run failed:
                                                            admission webhook "validate.kyverno.svc" denied

# Drill into controller logs and events for the object-level cause:
$ flux logs --kind Kustomization --name web-prod --since 10m
2026-08-07T12:04:11Z error Kustomization/web-prod - reconciliation failed:
  Deployment/storefront-prod/web dry-run failed (admission webhook denied: resource limits required)

$ kubectl -n flux-system describe kustomization web-prod | sed -n '/Conditions/,+6p'
```

### 8.6 Diagnosing ApplicationSet fan-out that produced the wrong set

```console
$ kubectl -n argocd get applicationset web -o jsonpath='{.status.conditions}' | jq
[
  {"type":"ErrorOccurred","status":"True",
   "message":"generated duplicate application name: web-prod"}
]

# The Git directory generator matched two paths mapping to the same name segment.
# Fix the template name expression, then:
$ kubectl -n argocd get applications -l argocd.argoproj.io/application-set-name=web
NAME          SYNC STATUS   HEALTH STATUS
web-dev       Synced        Healthy
web-staging   Synced        Healthy
web-prod      Synced        Healthy
```

### 8.7 Diagnostic checklist

- **`OutOfSync` but no obvious diff** → a mutating webhook or defaulting is changing a field; add it to `ignoreDifferences`, don't fight the reconciler.
- **Sync loops / never converges** → an operator/controller owns a field you also declare; use server-side apply field management or `ignoreDifferences`.
- **`Degraded` health** → check readiness/liveness probes and Events; health ≠ sync (Synced+Degraded is common right after a bad image).
- **Promotion "didn't happen"** → the commit landed on the wrong branch/path, or the reconcile interval hasn't elapsed — `argocd app get --refresh` / `flux reconcile`.
- **Secret missing** → ESO `ExternalSecret` status, or SealedSecret sealed with the wrong cluster's key, or SOPS decryption key absent.
- **Wrong env values in prod** → overlay precedence or Helm value ordering; render locally (`kustomize build overlays/prod` / `helm template`) and diff against live.

---

## 9. Key takeaways

- **Git is the single source of truth; the reconciler makes the cluster converge to it.** Multi-environment management is the discipline of structuring Git (directory-per-env overlays, separate config repo) so that one definition fans out to N targets and promotion is an auditable commit.
- **Directory-per-environment + Kustomize/Helm overlays**, not branch-per-environment. Differences are explicit, diffable, and inherit a shared base.
- **ApplicationSet (Argo CD)** and **per-env Kustomization (Flux)** are the fan-out primitives; both reconcile continuously, detect and correct drift, and enforce isolation via `AppProject`/tenants.
- **Promotion is a Git operation** — automate the low environments (image automation), gate prod behind PRs and sync windows. Keep secrets out of Git via ESO/SOPS/Sealed Secrets.
- **Diagnosis is state-first:** compare desired (Git-rendered) vs live, separate *sync status* from *health*, and never hot-patch a self-healed environment — change Git.

---

## 10. References

- OpenGitOps — Principles v1.0.0 — https://opengitops.dev/ and https://github.com/open-gitops/documents
- CNCF App Delivery / GitOps Working Group — https://github.com/cncf/tag-app-delivery
- CNPA Curriculum (Cloud Native Platform Engineering Associate) — https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf
- Argo CD documentation — https://argo-cd.readthedocs.io/en/stable/
- Argo CD ApplicationSet & generators — https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/
- Argo CD sync waves & hooks — https://argo-cd.readthedocs.io/en/stable/user-guide/sync-waves/
- Argo CD AppProject / RBAC — https://argo-cd.readthedocs.io/en/stable/operator-manual/rbac/
- Argo Rollouts (progressive delivery) — https://argo-rollouts.readthedocs.io/en/stable/
- Argo CD Image Updater — https://argocd-image-updater.readthedocs.io/en/stable/
- Flux documentation — https://fluxcd.io/flux/
- Flux Kustomization API — https://fluxcd.io/flux/components/kustomize/kustomizations/
- Flux HelmRelease API — https://fluxcd.io/flux/components/helm/helmreleases/
- Flux image automation — https://fluxcd.io/flux/guides/image-update/
- Flux + SOPS decryption — https://fluxcd.io/flux/guides/mozilla-sops/
- Flagger (progressive delivery for Flux) — https://docs.flagger.app/
- Kustomize documentation — https://kubectl.docs.kubernetes.io/references/kustomize/
- Helm documentation — https://helm.sh/docs/
- External Secrets Operator — https://external-secrets.io/latest/
- Sealed Secrets (Bitnami) — https://github.com/bitnami-labs/sealed-secrets
- Kargo (promotion orchestration) — https://docs.kargo.io/
- Kubernetes Server-Side Apply — https://kubernetes.io/docs/reference/using-api/server-side-apply/