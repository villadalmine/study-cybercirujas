# Topic 3.2 — Continuous Delivery Concepts and GitOps Principles

**Certification:** CNPA (Cloud Native Platform Engineering Associate) · Exam version 2025-04-01
**Domain weight:** 2.3

---

## 1. The production problem: why imperative delivery does not scale

A platform team that operates dozens of clusters and hundreds of workloads cannot ship changes with `kubectl apply` run from a laptop or a CI job holding cluster-admin credentials. That model fails on four production axes simultaneously:

- **No source of truth.** After a `kubectl edit`, a `kubectl scale`, or an operator mutating a field, the live state of the cluster diverges from whatever the last pipeline pushed. Nobody can answer "what *should* be running here" without querying the API server — which only tells you what *is* running, drift included.
- **No audit trail or attribution.** A push pipeline records "job 4821 succeeded". It does not record *who* approved the change, *what* the exact rendered object was, or *how* to revert it. Compliance frameworks (SOC 2, PCI-DSS change management) require both.
- **Credential blast radius.** Push delivery means the CI system holds standing write credentials to every production cluster. A compromised runner is a compromised fleet. This is the single most common finding in cloud-native security audits.
- **No convergence guarantee.** A push applies once. If the apply half-fails, or an admin later hand-edits the object, nothing brings the cluster back. There is no controller continuously asserting the intended state.

GitOps and modern Continuous Delivery exist to close exactly these four gaps: a versioned declarative source of truth, a complete audit trail via Git history, a **pull** model that removes standing cluster credentials from CI, and a **reconciliation loop** that continuously converges live state toward the declared state.

---

## 2. CI, CD, and Continuous Deployment — precise definitions

These three terms are routinely conflated. The exam and real platform design both depend on separating them.

| Term | Boundary | Trigger | Human gate | Output |
|---|---|---|---|---|
| **Continuous Integration (CI)** | Code → tested, built, signed artifact | Every commit / PR | PR review | Immutable artifact (image + digest) in a registry |
| **Continuous Delivery (CD)** | Artifact → *deployable and released to staging*; production release is one click away | Merge to main | **Yes** — a human approves the production release | Every change is *always* releasable; release is a business decision |
| **Continuous Deployment** | Artifact → automatically released to production, no gate | Merge to main | **No** | Every green build reaches production automatically |

Key distinction: **Continuous Delivery keeps the system permanently in a releasable state but leaves the *release* as a deliberate act; Continuous Deployment removes that act.** GitOps is the *mechanism* that implements either — it does not, by itself, decide whether a human approves. You get Continuous Deployment by enabling automated sync; you get Continuous Delivery by gating the merge or the promotion PR.

**The artifact must be immutable.** CD promotes the *same* bit-identical artifact through environments — you build once and promote the digest, never rebuild per environment. Pinning to a mutable tag such as `:latest` breaks reproducibility: the thing you tested in staging is not guaranteed to be the thing that runs in production. Always promote by image **digest** (`sha256:…`) or an immutable version tag.

---

## 3. GitOps: the four principles and the reconciliation loop

GitOps is a *specific* operational model for CD. The vendor-neutral definition is maintained by the **OpenGitOps** project (a CNCF Sandbox project). GitOps v1.0.0 defines four principles — a system is GitOps only if it satisfies all four:

1. **Declarative.** The entire desired state is expressed declaratively (the *what*, not the *how*).
2. **Versioned and Immutable.** Desired state is stored so that it is immutable, versioned, and retains a complete version history. (Git is the canonical store, hence the name — but the principle allows any immutable, versioned store, e.g. an OCI registry.)
3. **Pulled Automatically.** Software agents automatically **pull** the desired state from the source — no external system pushes into the cluster.
4. **Continuously Reconciled.** Software agents continuously observe actual system state and attempt to apply the desired state, closing any drift.

### The reconciliation loop

The controller (Argo CD's application-controller, Flux's kustomize/helm/source controllers) runs a permanent control loop:

```
                ┌──────────────────────────────────────────┐
                │              Git / OCI source             │
                │        (declared desired state)           │
                └──────────────────┬───────────────────────┘
                                   │  1. pull + render (kustomize/helm/plain)
                                   ▼
        ┌────────────────────────────────────────────────┐
        │             Reconciliation loop                 │
        │                                                 │
        │  2. observe live state (Kubernetes API)         │
        │  3. diff  desired  vs  live                     │
        │  4. if drift → apply desired (or alert only)    │
        │  5. report Sync + Health status                 │
        └──────────────────┬─────────────────────────────┘
                           │  server-side apply
                           ▼
                ┌──────────────────────────┐
                │     Kubernetes cluster    │
                │      (actual state)       │
                └──────────────────────────┘
```

Two properties fall directly out of this loop:

- **Drift detection.** Because the controller re-diffs on a schedule (default ~3 min for Argo CD, `interval:` for Flux) *and* on webhook events, an out-of-band `kubectl edit` is detected as `OutOfSync`.
- **Self-healing.** If `selfHeal` (Argo CD) is enabled, or Flux by default, the controller re-applies the declared state, reverting the manual change. Drift becomes non-persistent.

---

## 4. Push vs Pull delivery

This is the architectural decision GitOps hinges on.

| Dimension | **Push CD** (Jenkins/GitLab CI runs `kubectl apply`) | **Pull CD / GitOps** (in-cluster agent reconciles) |
|---|---|---|
| Credential location | CI holds standing cluster-admin creds (egress from CI → cluster) | Agent runs *inside* the cluster; no inbound cluster creds in CI |
| Blast radius | Compromised runner ⇒ whole fleet writable | Compromised runner ⇒ can only open a PR (still gated) |
| Drift correction | None — applies once | Continuous reconciliation + optional self-heal |
| Source of truth | The pipeline's last run (ephemeral) | Git/OCI (durable, versioned, diffable) |
| Firewalled/edge clusters | Requires inbound access to each cluster | Agent pulls *outbound* only — works behind NAT |
| Multi-cluster scale | CI fans out N applies, N credential sets | Each cluster self-reconciles from Git; scales horizontally |
| Rollback | Re-run old pipeline (may not be reproducible) | `git revert` — deterministic, audited |
| Failure visibility | Pipeline log | Declarative `Sync`/`Health` status object in-cluster |

The pull model wins decisively on security and multi-cluster scale, which is why it is the CNCF-endorsed default. Push retains one legitimate niche: bootstrapping the GitOps agent itself, and imperative one-off tasks (a bootstrap `flux install` or Argo CD Helm install) — a chicken-and-egg step you do exactly once per cluster.

---

## 5. Argo CD vs Flux — the two CNCF Graduated GitOps engines

Both are CNCF **Graduated** projects. They implement the same four principles with different ergonomics.

| Dimension | **Argo CD** | **Flux** |
|---|---|---|
| Primary abstraction | `Application` / `ApplicationSet` CRD | `GitRepository` + `Kustomization`/`HelmRelease` CRDs |
| Architecture | Monolithic-ish: api-server, repo-server, application-controller, redis | Composable controllers: source, kustomize, helm, notification, image-automation |
| UI | Rich first-party web UI + `argocd` CLI | No first-party UI (Weave GitOps / Capacitor add-ons); `flux` CLI |
| Multi-tenancy | `AppProject` (RBAC, source/dest allow-lists) | Namespace + RBAC + `Kustomization` `serviceAccountName` impersonation |
| Multi-cluster | One control-plane cluster manages many | Typically one Flux per cluster (hub-and-spoke possible) |
| App generation | `ApplicationSet` generators (list, cluster, git, matrix, PR) | Same repo structure applied per cluster; image-automation controller |
| Image update | Argo CD Image Updater (separate) | Built-in image-reflector + image-automation controllers |
| Secrets | Bring your own (SOPS/Sealed/ESO) | Native SOPS decryption in kustomize-controller |
| Sync ordering | Sync waves + resource hooks (`PreSync`/`Sync`/`PostSync`) | `dependsOn` between Kustomizations + health checks |

Neither is "better" — Argo CD favors a central control plane with a strong UI and human-driven sync; Flux favors a Kubernetes-native, controller-composable, cluster-local model. Both are testable exam topics.

---

## 6. Complete, valid manifests

### 6.1 Argo CD `Application` (auto-sync, prune, self-heal, retry)

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: payments
  namespace: argocd
  # Ensures the Application object is itself removed cleanly (finalizer).
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: platform
  source:
    repoURL: https://github.com/acme/platform-config.git
    targetRevision: main
    path: apps/payments/overlays/production
    kustomize:
      images:
        - registry.acme.io/payments@sha256:9f2c...   # promote by digest, never :latest
  destination:
    server: https://kubernetes.default.svc
    namespace: payments
  syncPolicy:
    automated:
      prune: true        # delete resources removed from Git
      selfHeal: true     # revert out-of-band drift
      allowEmpty: false  # refuse to prune everything (safety)
    syncOptions:
      - CreateNamespace=true
      - PrunePropagationPolicy=foreground
      - ServerSideApply=true
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
  # Ignore fields other controllers legitimately own (prevents false drift).
  ignoreDifferences:
    - group: apps
      kind: Deployment
      jsonPointers:
        - /spec/replicas          # owned by HPA, not Git
```

### 6.2 Argo CD `AppProject` (tenant boundary — the real multi-tenancy control)

```yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: platform
  namespace: argocd
spec:
  description: Platform team applications
  sourceRepos:
    - https://github.com/acme/platform-config.git   # only this repo may be a source
  destinations:
    - server: https://kubernetes.default.svc
      namespace: 'payments'
    - server: https://kubernetes.default.svc
      namespace: 'checkout'
  clusterResourceWhitelist:
    - group: ''
      kind: Namespace
  namespaceResourceBlacklist:
    - group: ''
      kind: ResourceQuota          # tenants may not set their own quota
  roles:
    - name: deployer
      policies:
        - p, proj:platform:deployer, applications, sync, platform/*, allow
```

### 6.3 Argo CD `ApplicationSet` (one Application per cluster, generated)

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: payments-all-clusters
  namespace: argocd
spec:
  goTemplate: true
  generators:
    - clusters:
        selector:
          matchLabels:
            env: production            # fan out to every prod cluster
  template:
    metadata:
      name: 'payments-{{.name}}'
    spec:
      project: platform
      source:
        repoURL: https://github.com/acme/platform-config.git
        targetRevision: main
        path: 'apps/payments/overlays/{{.metadata.labels.region}}'
      destination:
        server: '{{.server}}'
        namespace: payments
      syncPolicy:
        automated: { prune: true, selfHeal: true }
```

### 6.4 Flux — `GitRepository` + `Kustomization` (with health gate and dependency)

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: platform-config
  namespace: flux-system
spec:
  interval: 1m
  url: https://github.com/acme/platform-config.git
  ref:
    branch: main
  # Verify commit signatures — reject unsigned history.
  verify:
    mode: HEAD
    secretRef:
      name: git-signing-keys
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: payments
  namespace: flux-system
spec:
  interval: 10m
  retryInterval: 1m
  timeout: 5m
  prune: true                     # garbage-collect removed resources
  wait: true                      # block until health checks pass
  sourceRef:
    kind: GitRepository
    name: platform-config
  path: ./apps/payments/overlays/production
  dependsOn:
    - name: infra-controllers      # ordering: CRDs/operators first
  healthChecks:
    - apiVersion: apps/v1
      kind: Deployment
      name: payments
      namespace: payments
  decryption:                      # native SOPS decryption
    provider: sops
    secretRef:
      name: sops-age
```

### 6.5 Flux — `HelmRelease` from an OCI chart

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: OCIRepository
metadata:
  name: podinfo
  namespace: flux-system
spec:
  interval: 5m
  url: oci://ghcr.io/stefanprodan/charts/podinfo
  ref:
    semver: ">=6.0.0"
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: podinfo
  namespace: podinfo
spec:
  interval: 10m
  chartRef:
    kind: OCIRepository
    name: podinfo
    namespace: flux-system
  install:
    remediation: { retries: 3 }
  upgrade:
    remediation: { retries: 3, remediateLastFailure: true }   # auto-rollback on failed upgrade
  values:
    replicaCount: 3
```

---

## 7. Repository and environment topology

Two decisions define a GitOps repo layout: **how many repos**, and **how environments are represented**.

| Pattern | Description | Trade-off |
|---|---|---|
| **Monorepo** | All apps + all envs in one repo | Simple atomic PRs across apps; noisy history, coarse RBAC |
| **Polyrepo** | One repo per app or per team | Clean RBAC per team; cross-app changes need coordinated PRs |
| **Config repo separate from source** | App code in repo A, rendered/declared config in repo B | CI writes to config repo, agent reads it — clean push/pull split; the recommended default |
| **App-of-apps** (Argo CD) | A root `Application` points at a directory of child `Application`s | Bootstrap a whole environment from one object; superseded by ApplicationSet for generation |
| **Overlays per env** (Kustomize) | `base/` + `overlays/{staging,production}/` | Same base, per-env patches; promotion = edit the overlay |
| **Rendered Manifests / hydrate** | CI renders final YAML per env into a branch/dir; agent applies plain YAML | Fully reviewable diffs, no in-cluster templating surprises; extra CI step |

**Environment promotion** in GitOps is *always* a Git operation, never a `kubectl` operation. Promoting a validated image digest from staging to production is a pull request that changes the production overlay's image reference:

```console
$ git switch -c promote/payments-1.8.3
$ yq -i '.images[0].newTag = "sha256:9f2c..."' apps/payments/overlays/production/kustomization.yaml
$ git commit -am "promote payments to 1.8.3 (validated in staging run #4821)"
$ git push -u origin promote/payments-1.8.3
$ gh pr create --base main --title "Promote payments 1.8.3 to production"
```

The PR *is* the change-management gate that turns Continuous Deployment (auto everywhere) into Continuous Delivery (human-approved production release).

---

## 8. Progressive delivery — safe release strategies

Continuous Delivery does not end at "apply the new version". *How* the new version replaces the old is the delivery strategy, and it directly governs blast radius.

| Strategy | Mechanism | Downtime | Rollback speed | Extra capacity | Traffic control |
|---|---|---|---|---|---|
| **Recreate** | Kill all old, then start new | Yes | Slow (redeploy) | 1× | None |
| **RollingUpdate** | Replace pods incrementally (`maxSurge`/`maxUnavailable`) | No | Medium | ~1.1× | None (all-or-nothing per pod) |
| **Blue-Green** | Stand up full new stack, flip traffic atomically | No | Instant (flip back) | 2× | Switch at LB/Service |
| **Canary** | Route small % to new, increase gradually | No | Fast (shift weight to 0) | ~1.1–1.3× | Weighted (Ingress/service mesh) |
| **Feature flags** | Ship code dark, toggle at runtime per user | No | Instant (toggle off) | 1× | Per-request, app-level |

**Canary is analysis-gated in production.** Tools like **Argo Rollouts** and **Flagger** shift traffic in steps and query metrics (success rate, latency) between steps, auto-rolling-back if an analysis fails.

### 8.1 Argo Rollouts — canary with automated analysis

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: payments
  namespace: payments
spec:
  replicas: 5
  selector:
    matchLabels: { app: payments }
  template:
    metadata:
      labels: { app: payments }
    spec:
      containers:
        - name: payments
          image: registry.acme.io/payments@sha256:9f2c...
          ports: [{ containerPort: 8080 }]
  strategy:
    canary:
      canaryService: payments-canary
      stableService: payments-stable
      trafficRouting:
        nginx:
          stableIngress: payments
      steps:
        - setWeight: 20
        - pause: { duration: 5m }
        - analysis:
            templates:
              - templateName: success-rate
        - setWeight: 50
        - pause: { duration: 5m }
        - setWeight: 100
---
apiVersion: argoproj.io/v1alpha1
kind: AnalysisTemplate
metadata:
  name: success-rate
  namespace: payments
spec:
  metrics:
    - name: success-rate
      interval: 1m
      successCondition: result[0] >= 0.99
      failureLimit: 2                # 2 failing checks → auto-rollback
      provider:
        prometheus:
          address: http://prometheus.monitoring:9090
          query: |
            sum(rate(http_requests_total{app="payments",code!~"5.."}[2m]))
            /
            sum(rate(http_requests_total{app="payments"}[2m]))
```

### 8.2 Flagger `Canary` (equivalent, controller-driven)

```yaml
apiVersion: flagger.app/v1beta1
kind: Canary
metadata:
  name: payments
  namespace: payments
spec:
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: payments
  service:
    port: 8080
  analysis:
    interval: 1m
    threshold: 5           # max failed checks before rollback
    maxWeight: 50
    stepWeight: 10
    metrics:
      - name: request-success-rate
        thresholdRange: { min: 99 }
        interval: 1m
      - name: request-duration
        thresholdRange: { max: 500 }   # p99 latency ms
        interval: 1m
    webhooks:
      - name: load-test
        url: http://flagger-loadtester.test/
        metadata:
          cmd: "hey -z 1m -q 10 -c 2 http://payments-canary.payments:8080/"
```

---

## 9. Secrets in GitOps

Git is the source of truth, but plaintext secrets must never live in Git. The three production-grade patterns:

| Approach | How it works | Trust boundary | Rotation |
|---|---|---|---|
| **Sealed Secrets** (Bitnami) | `kubeseal` encrypts to a `SealedSecret` with the controller's public key; only the in-cluster controller can decrypt | Cluster-scoped key | Re-seal on rotation; key backup is critical |
| **SOPS + age/KMS** (Flux native) | Values encrypted with SOPS; kustomize-controller decrypts using an age/KMS key held in-cluster | KMS or age key | Re-encrypt file; easy per-key access control |
| **External Secrets Operator (ESO)** | A `SecretStore` + `ExternalSecret` pull live values from Vault/AWS SM/GCP SM into a native `Secret` | External vault | Rotate in the vault; ESO syncs automatically |

Only *references* and *ciphertext* go in Git; the plaintext is materialized in-cluster. Example ESO manifest (nothing secret is committed):

```yaml
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
    name: payments-db          # the K8s Secret ESO will create
    creationPolicy: Owner
  data:
    - secretKey: password
      remoteRef:
        key: secret/data/payments/db
        property: password
```

---

## 10. Verification and failure diagnosis

### 10.1 Argo CD — inspect, diff, sync, history, rollback

```console
$ argocd app get payments
Name:               argocd/payments
Project:            platform
Server:             https://kubernetes.default.svc
Namespace:          payments
URL:                https://argocd.acme.io/applications/payments
Repo:               https://github.com/acme/platform-config.git
Target:             main
Path:               apps/payments/overlays/production
Sync Policy:        Automated (Prune, SelfHeal)
Sync Status:        OutOfSync from main (a1b2c3d)
Health Status:      Progressing

GROUP  KIND        NAMESPACE  NAME      STATUS     HEALTH       HOOK  MESSAGE
apps   Deployment  payments   payments  OutOfSync  Progressing        deployment.apps/payments configured
       Service     payments   payments  Synced     Healthy
```

Drift explains *why* `OutOfSync`:

```console
$ argocd app diff payments
===== apps/Deployment payments/payments ======
2c2
<   replicas: 5      # live (someone ran kubectl scale)
---
>   replicas: 3      # desired (Git)
```

Force convergence, then confirm and roll back if needed:

```console
$ argocd app sync payments
TIMESTAMP                  GROUP        KIND   NAMESPACE  NAME      STATUS   HEALTH
2026-08-07T14:02:11+00:00  apps   Deployment  payments   payments  Synced   Healthy
Operation:  Sync
Phase:      Succeeded
Message:    successfully synced (all tasks run)

$ argocd app history payments
ID  DATE                           REVISION
6   2026-08-07 14:02:11 +0000 UTC  main (a1b2c3d)
5   2026-08-06 09:15:44 +0000 UTC  main (f9e8d7c)

$ argocd app rollback payments 5
Rollback 'payments' to 5? [y/n] y
Phase:  Succeeded
```

### 10.2 Flux — reconcile, trace, logs

```console
$ flux get kustomizations
NAME         REVISION            SUSPENDED  READY  MESSAGE
flux-system  main@sha1:a1b2c3d   False      True   Applied revision: main@sha1:a1b2c3d
payments     main@sha1:f9e8d7c   False      False  Deployment/payments/payments not ready

$ flux reconcile kustomization payments --with-source
► annotating GitRepository platform-config in flux-system namespace
✔ GitRepository reconciliation completed
✔ fetched revision main@sha1:a1b2c3d
► annotating Kustomization payments in flux-system namespace
✔ Kustomization reconciliation completed
✔ applied revision main@sha1:a1b2c3d

$ flux trace deployment/payments -n payments
Object:        Deployment/payments
Status:        Managed by Flux
Kustomization: payments
Revision:      main@sha1:a1b2c3d
Source:        GitRepository/platform-config
URL:           https://github.com/acme/platform-config.git

$ flux logs --level=error --kind=Kustomization --name=payments
2026-08-07T14:01:03Z error Kustomization/payments - Deployment/payments dry-run failed:
  admission webhook denied the request: image not signed
```

### 10.3 Argo Rollouts — watch a canary and abort

```console
$ kubectl argo rollouts get rollout payments --watch
Name:            payments
Namespace:       payments
Status:          ॥ Paused
Message:         CanaryPauseStep
Strategy:        Canary
  Step:          1/6
  SetWeight:     20
  ActualWeight:  20
Images:          registry.acme.io/payments (canary, stable)
Replicas:
  Desired:       5
  Current:       6
  Updated:       1
  Ready:         6
  Available:     6

NAME                                  KIND        STATUS     AGE  INFO
⟳ payments                            Rollout     ॥ Paused   4h
├──# revision:2
│  └──⧉ payments-7d9f (canary)        ReplicaSet  ✔ Healthy  2m   canary
└──# revision:1
   └──⧉ payments-5c4b (stable)        ReplicaSet  ✔ Healthy  4h   stable

# analysis failed → abort and revert to stable
$ kubectl argo rollouts abort payments
$ kubectl argo rollouts get rollout payments | grep Status
Status:  ✖ Degraded  (RolloutAborted)
```

### 10.4 Diagnostic decision table

| Symptom | Likely cause | First command | Fix |
|---|---|---|---|
| Stuck `OutOfSync`, never syncs | `automated` disabled, or `AppProject` blocks the destination | `argocd app get` / check `AppProject` | Enable auto-sync or widen project allow-list |
| Reappearing drift after every `kubectl edit` | `selfHeal` working as designed | `argocd app diff` | Change it in **Git**, not the cluster |
| Constant false `OutOfSync` on `replicas` | HPA owns `/spec/replicas` | `argocd app diff` | Add `ignoreDifferences` for that field |
| Flux `Ready: False`, "not ready" | Health check / `wait: true` timing out on a broken Deployment | `flux logs`, `kubectl describe` | Fix workload or raise `timeout` |
| Prune deleted everything | `path` pointed at an empty/wrong dir | `git log` on the manifest dir | `allowEmpty: false` (Argo) prevents this |
| Secret is empty in-cluster | SOPS/ESO decryption failing | `flux logs`, ESO events | Fix decryption key / `SecretStore` auth |
| Canary never promotes | Analysis metric below threshold | `kubectl argo rollouts get rollout` | Inspect Prometheus query / abort |

**Verification checklist for any GitOps change:** (1) the PR merged and CI is green; (2) `Sync Status: Synced` / `flux get` shows the new revision; (3) `Health Status: Healthy`; (4) `argocd app history` / `flux trace` shows the expected revision hash; (5) the live object matches Git (`argocd app diff` empty). Only all five together prove the declared state actually landed.

---

## 11. References

- CNPA Curriculum (CNCF/Linux Foundation) — https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf
- OpenGitOps — Principles v1.0.0 — https://opengitops.dev/ · https://github.com/open-gitops/documents
- Argo CD — Declarative GitOps CD for Kubernetes — https://argo-cd.readthedocs.io/
- Argo CD — Automated Sync & Self-Heal — https://argo-cd.readthedocs.io/en/stable/user-guide/auto_sync/
- Argo CD — ApplicationSet — https://argo-cd.readthedocs.io/en/stable/user-guide/application-set/
- Argo Rollouts — Progressive Delivery — https://argoproj.github.io/argo-rollouts/
- Flux — GitOps Toolkit documentation — https://fluxcd.io/flux/
- Flux — Kustomization & health checks — https://fluxcd.io/flux/components/kustomize/kustomizations/
- Flux — Manage Kubernetes secrets with SOPS — https://fluxcd.io/flux/guides/mozilla-sops/
- Flagger — Progressive delivery operator — https://docs.flagger.app/
- External Secrets Operator — https://external-secrets.io/
- Sealed Secrets — https://github.com/bitnami-labs/sealed-secrets
- CNCF — Cloud Native Glossary (GitOps, CI/CD) — https://glossary.cncf.io/
- Kubernetes — Deployment strategies — https://kubernetes.io/docs/concepts/workloads/controllers/deployment/