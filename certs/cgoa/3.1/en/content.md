# 3.1 GitOps Tooling & Implementation

**Exam weight: 25%** — the heaviest single domain. This section assumes you already accept the four OpenGitOps principles (declarative, versioned & immutable, pulled automatically, continuously reconciled). What follows is how those principles become running infrastructure, where the implementations diverge, and how they fail at 03:00.

---

## 1. The architectural problem

### 1.1 What actually breaks without a reconciler

A conventional push pipeline (`jenkins → kubectl apply`) is a **fire-and-forget state transition**. It has three structural defects that only appear at production scale:

1. **No convergence guarantee.** `kubectl apply` returns success when the API server *accepts* the object, not when the cluster *converges* to it. A Deployment whose ReplicaSet can never schedule is a green pipeline and a red cluster.
2. **No drift closure.** Between two pipeline runs the cluster is unmanaged. An operator running `kubectl scale`, a mutating webhook rewriting a field, or an operator-owned CRD controller writing back to `spec` all silently diverge the live state from Git. The next pipeline run may or may not correct it, depending on whether the field is present in the applied manifest.
3. **Inverted trust boundary.** CI holds cluster-admin credentials *outside* the cluster. Compromising the CI runner compromises every cluster it can reach. This is the reason the pull model exists — it is a security control before it is a delivery convenience.

A GitOps agent replaces the transition with a **closed control loop** running inside the trust boundary it manages.

### 1.2 The control loop, formalized

```
                 ┌──────────────────────────────────────────┐
                 │            Desired State (S_d)           │
                 │  Git ref / OCI artifact digest — immutable│
                 └────────────────┬─────────────────────────┘
                                  │  fetch (poll interval | webhook | OCI digest)
                                  ▼
                    ┌─────────────────────────┐
                    │   Renderer / Hydrator   │  kustomize build, helm template,
                    │   (pure function)       │  jsonnet, CMP plugin
                    └────────────┬────────────┘
                                 │  S_d'  (fully rendered manifests)
                                 ▼
        ┌────────────────────────────────────────────────┐
        │  Differ:  Δ = diff(S_d', S_a, S_last-applied)   │  ← three-way merge
        └────────────────────────┬───────────────────────┘
                                 │  Δ ≠ ∅
                                 ▼
        ┌────────────────────────────────────────────────┐
        │  Actuator: SSA / patch / create / delete-prune  │
        └────────────────────────┬───────────────────────┘
                                 │
                                 ▼
        ┌────────────────────────────────────────────────┐
        │  Health assessor: Kind-aware readiness → status │
        └────────────────────────┬───────────────────────┘
                                 │  emit: events, metrics, notifications
                                 ▼
                       Actual State (S_a) in etcd
```

Four properties every conforming agent must provide, and the exam vocabulary for each:

| Property | Meaning | Failure if absent |
|---|---|---|
| **Idempotency** | `apply(S_d)` applied N times ≡ applied once | Reconcile loops thrash, generation counters spin |
| **Convergence** | Loop terminates in `S_a ≡ S_d'` or reports divergence | Silent partial sync |
| **Drift detection** | `S_a ≠ S_d'` is *observable* independent of a deploy event | Undetected manual mutation |
| **Drift remediation** | The loop reverts unauthorized change (self-heal) | Detection without enforcement — audit theatre |

### 1.3 The three-way diff problem

This is the single most misunderstood mechanic and a reliable exam trap. Two-way diff (`desired` vs `live`) is wrong, because the live object contains fields *no one in Git ever wrote*: defaulted fields (`spec.strategy`, `terminationGracePeriodSeconds`), mutating-webhook injections (Istio sidecars, Vault agents), and controller-written fields (`spec.replicas` under HPA).

The reconciler must therefore diff against a record of **what it itself last applied**:

- **Client-side apply (CSA)** stores that record in the `kubectl.kubernetes.io/last-applied-configuration` annotation. It is capped by the 256 KB annotation/etcd pressure and loses fidelity on large CRDs.
- **Server-side apply (SSA)** moves ownership into `metadata.managedFields`, per-field, per-manager. The API server itself computes the merge and returns `409 Conflict` when two managers claim the same field. This is the correct default in 2026.

Both Argo CD (`ServerSideApply=true`) and Flux (SSA by default since v2) support it. Consequence you must internalize: **with SSA, "who owns `spec.replicas`" is a first-class, queryable fact.**

```bash
$ kubectl get deploy checkout-api -n payments -o jsonpath='{.metadata.managedFields[*].manager}' | tr ' ' '\n'
kustomize-controller
kube-controller-manager
horizontal-pod-autoscaler
```

---

## 2. The tooling landscape

### 2.1 Taxonomy

The CGOA curriculum treats "tooling" as a layered stack, not a product list. Know the layer, and any product slots into it:

| Layer | Responsibility | Representative implementations |
|---|---|---|
| **Source / artifact** | Fetch and verify the immutable desired state | Flux `source-controller`, Argo CD `repo-server`, OCI registries, `cosign` |
| **Manifest rendering** | Pure function: source → YAML | Kustomize, Helm, Jsonnet, cdk8s, KCL, Argo CD CMP sidecars |
| **Reconciliation / delivery** | Diff + apply + prune + health | Argo CD, Flux, Rancher Fleet, Kubestack, Sveltos |
| **Promotion / orchestration** | Move a version across environments | Kargo, ApplicationSet progressive sync, Flux image automation, PR bots |
| **Progressive delivery** | Traffic-shifted rollout with analysis | Argo Rollouts, Flagger |
| **Secrets** | Deliver ciphertext through Git safely | SOPS, Sealed Secrets, External Secrets Operator, Vault Secrets Operator |
| **Policy / admission** | Reject non-conforming desired state | Kyverno, OPA Gatekeeper, `conftest` in CI |
| **Observability** | Expose drift, sync latency, failure | Prometheus metrics, notification-controller, argocd-notifications |

Argo CD and Flux are both **CNCF Graduated** (both graduated in December 2022 under the Argo and Flux projects respectively). Anything the exam asks about "the GitOps tool" is answerable in terms of those two.

### 2.2 Argo CD architecture, component by component

```
                    ┌──────────────────────────────────────────────┐
   user / CI ──────▶│ argocd-server        (API + gRPC + web UI)   │
   SSO (OIDC) ─────▶│  ├─ RBAC (argocd-rbac-cm), projects, sessions│
                    └───────────┬──────────────────────────────────┘
                                │ gRPC
                    ┌───────────▼──────────────────────────────────┐
                    │ argocd-repo-server                           │
                    │  git clone / helm pull / OCI pull            │
                    │  → kustomize build | helm template | CMP     │
                    │  → manifest cache (Redis, keyed by revision) │
                    └───────────┬──────────────────────────────────┘
                                │ rendered manifests
     ┌──────────────────────────▼──────────────────────────────────┐
     │ argocd-application-controller   (StatefulSet, shardable)    │
     │  informers per destination cluster → live state cache       │
     │  diff → sync (waves, hooks) → health assessment (Lua)       │
     └──────────────────────────┬──────────────────────────────────┘
                                │
     ┌──────────────┬───────────┴──────────┬─────────────────┐
     │ applicationset-controller           │ notifications-  │
     │ (generators → Application CRs)      │ controller      │
     └─────────────────────────────────────┴─────────────────┘
                    argocd-redis (cache)   argocd-dex-server (SSO federation)
```

Key facts that show up in questions:

- The **application-controller is a StatefulSet**, not a Deployment, because sharding is index-based (`ARGOCD_CONTROLLER_REPLICAS` + pod ordinal).
- The **repo-server is the only component that runs untrusted rendering code** (Helm hooks, CMP plugins, Jsonnet). It is the correct place to enforce `securityContext`, egress NetworkPolicy, and CPU/memory limits.
- Argo CD is **API-driven and multi-tenant by design**: `AppProject` is a real security boundary; RBAC is application-level, not just Kubernetes RBAC.
- Custom resources: `Application`, `ApplicationSet`, `AppProject`, all `argoproj.io/v1alpha1`.

### 2.3 Flux architecture, controller by controller

Flux is the **GitOps Toolkit**: a set of single-responsibility controllers composed over the Kubernetes API. There is no central server, no UI, no separate database.

| Controller | CRDs owned | Responsibility |
|---|---|---|
| `source-controller` | `GitRepository`, `OCIRepository`, `HelmRepository`, `HelmChart`, `Bucket` | Fetch, verify (GPG/cosign/checksum), expose as a tarball over in-cluster HTTP; emit `.status.artifact.revision` |
| `kustomize-controller` | `Kustomization` | `kustomize build` → SSA apply → prune → health-check → emit events |
| `helm-controller` | `HelmRelease` | Drive Helm SDK (install/upgrade/rollback/test), drift detection on the release |
| `notification-controller` | `Provider`, `Alert`, `Receiver` | Egress alerts; ingress webhooks (`Receiver`) to trigger immediate reconciliation |
| `image-reflector-controller` | `ImageRepository`, `ImagePolicy` | Scan registry tags, select a version by policy (semver/numerical/alpha) |
| `image-automation-controller` | `ImageUpdateAutomation` | Write the selected tag **back into Git** and push |

```
 Git / OCI / S3 / Helm repo
        │
        ▼
 ┌────────────────┐   artifact (tar.gz + revision)   ┌────────────────────┐
 │ source-        │─────────────────────────────────▶│ kustomize-         │──▶ SSA apply
 │ controller     │                                  │ controller         │──▶ prune
 └────────────────┘─────────────────────────────────▶│ helm-controller    │──▶ helm upgrade
        ▲                                            └─────────┬──────────┘
        │  ImageUpdateAutomation writes back                   │ events
 ┌──────┴──────────┐   ┌─────────────────┐          ┌──────────▼──────────┐
 │ image-automation│◀──│ image-reflector │          │ notification-       │──▶ Slack/Teams/
 └─────────────────┘   └─────────────────┘          │ controller          │    GitHub/Alertmgr
                                                    └─────────────────────┘
```

The critical architectural consequence: **in Flux, the desired state of Flux itself is a `Kustomization` named `flux-system` that reconciles the directory containing Flux's own manifests.** Flux upgrades itself by reconciling itself. Argo CD achieves the equivalent with an `Application` managing the `argocd` namespace ("Argo CD manages Argo CD").

### 2.4 Head-to-head trade-offs

| Dimension | Argo CD | Flux v2 |
|---|---|---|
| **Unit of delivery** | `Application` (one source path → one destination) | `Kustomization` / `HelmRelease` (decoupled from source) |
| **Source reuse** | Source is embedded in each `Application` | One `GitRepository`, N `Kustomization`s referencing it — less Git polling load |
| **UI / API** | First-class web UI, gRPC/REST API, CLI | No UI in core (Flux UI is third-party/Weave GitOps); `kubectl` + `flux` CLI |
| **Multi-cluster model** | **Hub-and-spoke** by default: one Argo CD manages many clusters via stored kubeconfigs (`Secret` labelled `argocd.argoproj.io/secret-type: cluster`) | **Cluster-local** by default: one Flux per cluster; hub model possible via `spec.kubeConfig` |
| **Blast radius of the control plane** | Central Argo CD holds credentials to every spoke — a high-value target | Each cluster's Flux holds only its own credentials |
| **Tenancy primitive** | `AppProject` (repo allowlist, destination allowlist, resource allow/deny, sync windows, RBAC roles) | `ServiceAccount` impersonation per `Kustomization` + `--no-cross-namespace-refs=true` |
| **RBAC model** | Application-level RBAC in `argocd-rbac-cm`, decoupled from k8s RBAC | Pure Kubernetes RBAC — no second authorization system to reason about |
| **Ordering** | Sync waves (`argocd.argoproj.io/sync-wave`) + hooks (PreSync/Sync/PostSync/SyncFail) | `spec.dependsOn` between `Kustomization`s / `HelmRelease`s + `spec.wait: true` |
| **Drift remediation** | Opt-in: `syncPolicy.automated.selfHeal: true` | Implicit: every interval re-applies via SSA; `spec.force` for immutable-field conflicts |
| **Prune** | Opt-in: `syncPolicy.automated.prune: true` | Opt-in: `spec.prune: true` (inventory tracked in the `Kustomization` status) |
| **Garbage-collection mechanism** | Tracking label/annotation (`app.kubernetes.io/instance` or `argocd.argoproj.io/tracking-id`) | Explicit inventory list in `Kustomization.status.inventory` |
| **Image automation** | Argo CD Image Updater (separate, less mature) or Kargo | Native `image-reflector` + `image-automation` controllers, writes commits to Git |
| **Helm handling** | `helm template` — **no Helm release object in-cluster**; Helm hooks partially emulated | Real Helm SDK — `helm list` works; full hook/test/rollback semantics |
| **OCI as source of truth** | Supported (`Application.spec.source.repoURL` with `oci://`) | First-class (`OCIRepository` + `flux push artifact`), with cosign keyless verification |
| **Scaling limit** | Central controller: shard by cluster; repo-server CPU on Helm/Kustomize rendering | Horizontal by design; per-controller `--concurrent`, sharding via `sharding.fluxcd.io/key` |
| **Failure mode when the agent is down** | Cluster keeps running; drift accumulates unnoticed; central outage affects all clusters | Cluster keeps running; drift accumulates on that cluster only |

**Selection heuristic for a production platform:**

- Many clusters, many tenants, humans need a self-service surface and visual diff → **Argo CD**.
- Cluster-as-a-product, everything through PRs, no human console, strongest supply-chain story (OCI + cosign + SOPS native) → **Flux**.
- The combination is legitimate and common: **Flux for platform/infra layer, Argo CD for application teams**, or Argo CD for delivery + Flagger for progressive delivery.

### 2.5 Push vs pull, stated precisely

| | Push (CI applies) | Pull (agent reconciles) |
|---|---|---|
| Credential location | Outside cluster, in CI | Inside cluster, scoped to that cluster |
| Network requirement | CI must reach the API server (often public or VPN'd) | Cluster reaches Git/OCI egress-only; API server can be fully private |
| Drift handling | None between runs | Continuous |
| Latency to deploy | Immediate | Poll interval, or immediate with a webhook `Receiver` |
| Auditability | CI logs (mutable, retention-bound) | Git history + cluster events (the commit *is* the audit record) |
| Works for non-Kubernetes targets | Yes, trivially | Requires a reconciler for that target (Crossplane, Terraform controller, Cluster API) |

The pull model's honest cost: **you cannot deploy faster than the reconcile interval unless you wire webhooks**, and a Git outage freezes promotion (though not the running workload).

---

## 3. Repository topology and manifest generation

### 3.1 Monorepo vs polyrepo

| Criterion | Monorepo (one repo, all envs/apps) | Polyrepo (repo per app or per cluster) |
|---|---|---|
| Atomic cross-cutting change | Single PR, single commit SHA | N PRs, no atomicity |
| RBAC granularity | Directory-based via `CODEOWNERS` — weak boundary | Repo-level — strong boundary |
| Agent load | One `GitRepository`/repo-server clone reused by N `Kustomization`s | N clones, N poll cycles |
| Blast radius of a bad commit | Whole platform potentially | One app |
| Reviewability of a promotion diff | Excellent (env dirs side by side) | Requires cross-repo tooling |
| Scaling limit | Git clone time; Argo CD repo-server CPU; webhook fan-out | Repo sprawl, drifting conventions |

**Production default:** *source code* in per-app repos; *desired state* in one or a few **config repos**, separated by trust boundary (`platform-gitops`, `tenant-a-gitops`). Never put desired state in the app repo if CI can write to it *and* humans deploy from it — you lose the review gate.

### 3.2 Environment modeling

| Pattern | Mechanism | Verdict |
|---|---|---|
| **Branch per environment** (`dev`, `staging`, `prod`) | Agent tracks a different branch per cluster | **Anti-pattern.** Promotion becomes a merge; merges carry unintended changes; branches drift and cherry-picks become the norm. Explicitly discouraged by both projects. |
| **Directory per environment** (`envs/prod/…`) | Same branch, different `path` | **Recommended.** Promotion is a diff you can read. |
| **Kustomize base + overlays** | `base/` + `overlays/<env>` | Recommended, with a caveat: overlays hide the final result — you review the patch, not the manifest. |
| **Rendered manifests branch** | CI renders every env into `env/<name>` branches containing plain YAML; agent tracks those, never templates | **Strongest reviewability.** The PR diff is literally what will exist in etcd. Costs a CI hydration step. |
| **OCI artifact per environment** | CI renders + `flux push artifact` + `cosign sign`; agent pulls by digest | **Strongest supply chain.** Desired state is immutable by construction (digest), signed, and decoupled from Git availability. |

### 3.3 The rendered manifests pattern, concretely

```
platform-gitops (repo)
├── main                        ← source of truth, humans edit here
│   ├── base/
│   └── envs/{dev,stg,prod}/
└── env/prod                    ← machine-written branch, humans only READ
    └── manifests.yaml          ← output of `kustomize build envs/prod`
```

CI job on merge to `main`:

```bash
$ kustomize build envs/prod --enable-helm > /tmp/manifests.yaml
$ kubeconform -strict -summary -schema-location default \
    -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
    /tmp/manifests.yaml
Summary: 214 resources found parsing stdin - Valid: 214, Invalid: 0, Errors: 0, Skipped: 0
$ git checkout env/prod && cp /tmp/manifests.yaml . && git commit -am "render: main@$(git rev-parse --short main)" && git push
```

The reconciler then points at `env/prod` with **no rendering at all**, which removes an entire class of "it rendered differently in the cluster than in my terminal" incidents.

---

## 4. Implementation: Flux end to end

### 4.1 Pre-flight and bootstrap

```bash
$ flux check --pre
► checking prerequisites
✔ Kubernetes 1.31.4 >=1.30.0-0
✔ prerequisites checks passed

$ export GITHUB_TOKEN=ghp_xxxxxxxxxxxxxxxxxxxx
$ flux bootstrap github \
    --owner=acme \
    --repository=platform-gitops \
    --branch=main \
    --path=clusters/prod-eu-west-1 \
    --components-extra=image-reflector-controller,image-automation-controller \
    --token-auth=false \
    --personal=false
► connecting to github.com
► cloning branch "main" from Git repository "https://github.com/acme/platform-gitops.git"
✔ cloned repository
► generating component manifests
✔ generated component manifests
✔ committed component manifests to "main" ("7f3ac21")
► pushing component manifests to "https://github.com/acme/platform-gitops.git"
► installing components in "flux-system" namespace
✔ installed components
✔ reconciled components
► determining if source secret "flux-system/flux-system" exists
► generating source secret
✔ public key: ecdsa-sha2-nistp384 AAAAE2VjZHNhLXNoYTItbmlzdHAzODQAAAAI...
✔ configured deploy key "flux-system-main-flux-system-./clusters/prod-eu-west-1"
► applying source secret "flux-system/flux-system"
✔ reconciled source secret
► generating sync manifests
✔ generated sync manifests
✔ committed sync manifests to "main" ("a91b04e")
► pushing sync manifests to "https://github.com/acme/platform-gitops.git"
► applying sync manifests
✔ reconciled sync configuration
► confirming components are healthy
✔ helm-controller: deployment ready
✔ image-automation-controller: deployment ready
✔ image-reflector-controller: deployment ready
✔ kustomize-controller: deployment ready
✔ notification-controller: deployment ready
✔ source-controller: deployment ready
✔ all components are healthy
```

What `bootstrap` did, in GitOps terms: it committed Flux's own manifests to Git, applied them once imperatively to break the chicken-and-egg, then created a `GitRepository` + `Kustomization` pair that makes Flux reconcile that same path forever. **From this point every change to Flux itself is a PR.**

### 4.2 Repository layout

```
platform-gitops/
├── clusters/
│   ├── prod-eu-west-1/
│   │   ├── flux-system/                 # written by bootstrap, do not hand-edit
│   │   │   ├── gotk-components.yaml
│   │   │   ├── gotk-sync.yaml
│   │   │   └── kustomization.yaml
│   │   ├── infra-controllers.yaml       # Kustomization → infra/controllers
│   │   ├── infra-configs.yaml           # Kustomization → infra/configs
│   │   └── tenants.yaml                 # Kustomization → tenants/prod
│   └── stg-eu-west-1/
├── infra/
│   ├── controllers/                     # cert-manager, ingress-nginx, ESO, kyverno
│   └── configs/                         # ClusterIssuer, ClusterSecretStore, policies
└── tenants/
    ├── base/checkout/
    └── prod/checkout/
```

### 4.3 The dependency chain — complete manifests

`clusters/prod-eu-west-1/infra-controllers.yaml`:

```yaml
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: infra-controllers
  namespace: flux-system
spec:
  interval: 1h
  retryInterval: 2m
  timeout: 5m
  path: ./infra/controllers
  prune: true
  wait: true
  sourceRef:
    kind: GitRepository
    name: flux-system
  # Fail fast instead of hanging for the full timeout on a bad chart.
  healthChecks:
    - apiVersion: apps/v1
      kind: Deployment
      name: cert-manager-webhook
      namespace: cert-manager
    - apiVersion: apps/v1
      kind: Deployment
      name: ingress-nginx-controller
      namespace: ingress-nginx
```

`clusters/prod-eu-west-1/infra-configs.yaml` — depends on the controllers because it creates CRs owned by them:

```yaml
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: infra-configs
  namespace: flux-system
spec:
  interval: 1h
  retryInterval: 2m
  timeout: 5m
  dependsOn:
    - name: infra-controllers
  path: ./infra/configs
  prune: true
  wait: true
  sourceRef:
    kind: GitRepository
    name: flux-system
  decryption:
    provider: sops
    secretRef:
      name: sops-age
  postBuild:
    substitute:
      cluster_name: prod-eu-west-1
      cluster_region: eu-west-1
    substituteFrom:
      - kind: ConfigMap
        name: cluster-vars
        optional: false
  patches:
    - target:
        kind: ClusterIssuer
        name: letsencrypt
      patch: |
        - op: replace
          path: /spec/acme/server
          value: https://acme-v02.api.letsencrypt.org/directory
```

`clusters/prod-eu-west-1/tenants.yaml` — tenant reconciliation under an impersonated ServiceAccount, which is how Flux enforces multi-tenancy:

```yaml
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: tenants
  namespace: flux-system
spec:
  interval: 10m
  retryInterval: 1m
  timeout: 5m
  dependsOn:
    - name: infra-configs
  path: ./tenants/prod
  prune: true
  wait: false
  sourceRef:
    kind: GitRepository
    name: flux-system
  # Impersonate a namespace-scoped SA: the tenant cannot escalate beyond
  # what this SA's RoleBindings allow, regardless of what YAML they commit.
  serviceAccountName: tenant-reconciler
  targetNamespace: checkout
```

### 4.4 Source with signature verification (supply chain)

```yaml
---
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: flux-system
  namespace: flux-system
spec:
  interval: 1m
  ref:
    branch: main
  secretRef:
    name: flux-system
  url: ssh://git@github.com/acme/platform-gitops
  ignore: |
    /*
    !/clusters
    !/infra
    !/tenants
  # Reject any commit not signed by a key in this ConfigMap.
  verify:
    mode: HEAD
    secretRef:
      name: platform-gpg-public-keys
```

OCI variant — desired state as a signed, immutable artifact:

```yaml
---
apiVersion: source.toolkit.fluxcd.io/v1beta2
kind: OCIRepository
metadata:
  name: checkout-manifests
  namespace: flux-system
spec:
  interval: 5m
  url: oci://ghcr.io/acme/checkout-manifests
  ref:
    semver: ">=1.4.0 <2.0.0"
  secretRef:
    name: ghcr-auth
  verify:
    provider: cosign
    matchOIDCIdentity:
      - issuer: "^https://token\\.actions\\.githubusercontent\\.com$"
        subject: "^https://github\\.com/acme/checkout/\\.github/workflows/release\\.yaml@refs/tags/v.*$"
```

> Note: `OCIRepository` was promoted from `v1beta2` to `v1` in recent Flux releases. Always confirm with `kubectl api-resources --api-group=source.toolkit.fluxcd.io` on the cluster you are targeting rather than trusting a memorized version.

### 4.5 HelmRelease with real release semantics

```yaml
---
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: ingress-nginx
  namespace: flux-system
spec:
  interval: 24h
  url: https://kubernetes.github.io/ingress-nginx
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: ingress-nginx
  namespace: ingress-nginx
spec:
  interval: 30m
  timeout: 10m
  chart:
    spec:
      chart: ingress-nginx
      version: "4.12.x"
      sourceRef:
        kind: HelmRepository
        name: ingress-nginx
        namespace: flux-system
      interval: 12h          # chart version re-resolution cadence
  install:
    remediation:
      retries: 3
    crds: CreateReplace
  upgrade:
    remediation:
      retries: 3
      remediateLastFailure: true
      strategy: rollback
    crds: CreateReplace
    cleanupOnFail: true
  # Detect and correct drift on the rendered release, not just on the values.
  driftDetection:
    mode: enabled
    ignore:
      - paths: ["/spec/replicas"]
        target:
          kind: Deployment
  test:
    enable: true
    ignoreFailures: false
  values:
    controller:
      replicaCount: 3
      service:
        annotations:
          service.beta.kubernetes.io/aws-load-balancer-type: nlb
      metrics:
        enabled: true
        serviceMonitor:
          enabled: true
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: ingress-nginx
              app.kubernetes.io/component: controller
  valuesFrom:
    - kind: ConfigMap
      name: ingress-nginx-cluster-values
      valuesKey: values.yaml
      optional: true
```

### 4.6 Image automation — the write-back loop

```yaml
---
apiVersion: image.toolkit.fluxcd.io/v1beta2
kind: ImageRepository
metadata:
  name: checkout
  namespace: flux-system
spec:
  image: ghcr.io/acme/checkout
  interval: 5m
  secretRef:
    name: ghcr-auth
---
apiVersion: image.toolkit.fluxcd.io/v1beta2
kind: ImagePolicy
metadata:
  name: checkout
  namespace: flux-system
spec:
  imageRepositoryRef:
    name: checkout
  filterTags:
    # Only tags of the form 1.4.2-<sha>; extract the semver part.
    pattern: '^(?P<semver>[0-9]+\.[0-9]+\.[0-9]+)-[a-f0-9]+$'
    extract: '$semver'
  policy:
    semver:
      range: ">=1.4.0 <2.0.0"
---
apiVersion: image.toolkit.fluxcd.io/v1beta2
kind: ImageUpdateAutomation
metadata:
  name: checkout-prod
  namespace: flux-system
spec:
  interval: 10m
  sourceRef:
    kind: GitRepository
    name: flux-system
  git:
    checkout:
      ref:
        branch: main
    commit:
      author:
        name: fluxcdbot
        email: fluxcdbot@acme.io
      messageTemplate: |
        chore(prod): update images

        {{ range .Changed.Changes -}}
        - {{ .OldValue }} -> {{ .NewValue }}
        {{ end -}}
      signingKey:
        secretRef:
          name: flux-git-signing-key
    push:
      branch: main
  update:
    path: ./tenants/prod
    strategy: Setters
```

And the marker in the tenant manifest that tells the automation controller which field to rewrite:

```yaml
spec:
  template:
    spec:
      containers:
        - name: checkout
          image: ghcr.io/acme/checkout:1.4.2-9f3ac21 # {"$imagepolicy": "flux-system:checkout"}
```

**Architectural point:** the new tag lands in Git *first*. The cluster changes only because the reconciler observed a commit. The audit trail is never broken.

### 4.7 Notifications and webhook-triggered reconciliation

```yaml
---
apiVersion: notification.toolkit.fluxcd.io/v1beta3
kind: Provider
metadata:
  name: slack-platform
  namespace: flux-system
spec:
  type: slack
  channel: platform-alerts
  secretRef:
    name: slack-webhook-url
---
apiVersion: notification.toolkit.fluxcd.io/v1beta3
kind: Alert
metadata:
  name: on-call
  namespace: flux-system
spec:
  providerRef:
    name: slack-platform
  eventSeverity: error
  eventSources:
    - kind: GitRepository
      name: '*'
    - kind: Kustomization
      name: '*'
    - kind: HelmRelease
      name: '*'
  exclusionList:
    - "waiting for rollout to finish"
  suspend: false
---
apiVersion: notification.toolkit.fluxcd.io/v1
kind: Receiver
metadata:
  name: github-push
  namespace: flux-system
spec:
  type: github
  events:
    - "ping"
    - "push"
  secretRef:
    name: github-webhook-token
  resources:
    - kind: GitRepository
      name: flux-system
```

```bash
$ kubectl -n flux-system get receiver github-push
NAME           AGE   READY   STATUS
github-push    3d    True    Receiver initialized for path: /hook/12ef9a...c4b1
```

That path, exposed through the `webhook-receiver` Service/Ingress, is what you register in GitHub. It collapses reconcile latency from `interval` to sub-second while leaving the poll as a safety net.

---

## 5. Implementation: Argo CD end to end

### 5.1 Install and the app-of-apps root

```bash
$ kubectl create namespace argocd
namespace/argocd created
$ kubectl apply -n argocd -k https://github.com/argoproj/argo-cd/manifests/cluster-install?ref=stable
customresourcedefinition.apiextensions.k8s.io/applications.argoproj.io created
customresourcedefinition.apiextensions.k8s.io/applicationsets.argoproj.io created
customresourcedefinition.apiextensions.k8s.io/appprojects.argoproj.io created
serviceaccount/argocd-application-controller created
...
statefulset.apps/argocd-application-controller created
deployment.apps/argocd-repo-server created
deployment.apps/argocd-server created

$ argocd login argocd.acme.io --sso --grpc-web
Opening browser for authentication
Authentication successful
'villadalmine@gmail.com' logged in successfully
Context 'argocd.acme.io' updated
```

The **app-of-apps** root — the single imperative act, after which everything is declarative:

```yaml
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: platform-bootstrap
  namespace: argocd
  finalizers:
    # Cascading delete: removing this Application prunes its children.
    - resources-finalizer.argocd.argoproj.io
spec:
  project: platform
  source:
    repoURL: https://github.com/acme/platform-gitops.git
    targetRevision: main
    path: clusters/prod-eu-west-1/apps
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
      allowEmpty: false
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
      - PrunePropagationPolicy=foreground
      - PruneLast=true
      - ApplyOutOfSyncOnly=true
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
  revisionHistoryLimit: 10
```

### 5.2 `AppProject` — the tenancy boundary

```yaml
---
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: tenant-checkout
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  description: Checkout squad — payments domain
  sourceRepos:
    - https://github.com/acme/checkout-gitops.git
    - https://acme.github.io/charts
  destinations:
    - server: https://kubernetes.default.svc
      namespace: checkout
    - server: https://kubernetes.default.svc
      namespace: checkout-jobs
  # Tenants may not create cluster-scoped objects at all...
  clusterResourceWhitelist: []
  # ...and are denied the namespaced escalation vectors.
  namespaceResourceBlacklist:
    - group: ""
      kind: ResourceQuota
    - group: ""
      kind: LimitRange
    - group: rbac.authorization.k8s.io
      kind: RoleBinding
    - group: rbac.authorization.k8s.io
      kind: Role
  roles:
    - name: deployer
      description: Sync and rollback, no destination edits
      policies:
        - p, proj:tenant-checkout:deployer, applications, get,      tenant-checkout/*, allow
        - p, proj:tenant-checkout:deployer, applications, sync,     tenant-checkout/*, allow
        - p, proj:tenant-checkout:deployer, applications, action/*, tenant-checkout/*, allow
        - p, proj:tenant-checkout:deployer, applications, delete,   tenant-checkout/*, deny
      groups:
        - acme:checkout-engineers
  syncWindows:
    - kind: deny
      schedule: "0 22 * * 5"      # Friday 22:00
      duration: 58h               # through Monday 08:00
      applications:
        - "*"
      manualSync: true            # break-glass still permitted
      timeZone: "Europe/Madrid"
  orphanedResources:
    warn: true
```

### 5.3 `ApplicationSet` — generating Applications instead of writing them

The **matrix generator** (clusters × app directories) is the canonical fleet pattern:

```yaml
---
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: tenant-apps
  namespace: argocd
spec:
  goTemplate: true
  goTemplateOptions: ["missingkey=error"]
  generators:
    - matrix:
        generators:
          - clusters:
              selector:
                matchLabels:
                  argocd.argoproj.io/secret-type: cluster
                  env: prod
          - git:
              repoURL: https://github.com/acme/platform-gitops.git
              revision: main
              files:
                - path: "tenants/prod/*/config.json"
  strategy:
    type: RollingSync
    rollingSync:
      steps:
        - matchExpressions:
            - key: wave
              operator: In
              values: ["canary"]
        - matchExpressions:
            - key: wave
              operator: In
              values: ["primary"]
          maxUpdate: 25%
  template:
    metadata:
      name: '{{ .name }}-{{ .tenant }}'
      labels:
        wave: '{{ .wave }}'
      finalizers:
        - resources-finalizer.argocd.argoproj.io
    spec:
      project: 'tenant-{{ .tenant }}'
      source:
        repoURL: https://github.com/acme/platform-gitops.git
        targetRevision: main
        path: 'tenants/prod/{{ .tenant }}'
        kustomize:
          commonAnnotations:
            acme.io/cluster: '{{ .name }}'
      destination:
        server: '{{ .server }}'
        namespace: '{{ .tenant }}'
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
          - ServerSideApply=true
  # Safety rail: refuse to act if the generator suddenly yields far fewer apps.
  # Without this, a bad `git` generator path deletes the whole fleet.
  syncPolicy:
    applicationsSync: create-update
    preserveResourcesOnDeletion: false
```

> The `strategy.rollingSync` block is what turns an `ApplicationSet` from a fan-out into a **progressive fleet rollout**: canary clusters sync first, and the next step only begins when the previous step's Applications report `Healthy`.

### 5.4 Ordering: sync waves and hooks

```yaml
---
# Wave -2: CRDs must exist before any CR referencing them is validated.
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: rollouts.argoproj.io
  annotations:
    argocd.argoproj.io/sync-wave: "-2"
    argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true
spec: {} # …
---
# Wave -1 PreSync hook: schema migration must complete before new pods start.
apiVersion: batch/v1
kind: Job
metadata:
  name: checkout-db-migrate
  namespace: checkout
  annotations:
    argocd.argoproj.io/hook: PreSync
    argocd.argoproj.io/hook-delete-policy: BeforeHookCreation
    argocd.argoproj.io/sync-wave: "-1"
spec:
  backoffLimit: 2
  activeDeadlineSeconds: 900
  ttlSecondsAfterFinished: 3600
  template:
    spec:
      restartPolicy: Never
      serviceAccountName: checkout-migrator
      containers:
        - name: migrate
          image: ghcr.io/acme/checkout-migrations:1.4.2
          command: ["/bin/migrate", "up", "--lock-timeout=300s"]
          env:
            - name: DATABASE_URL
              valueFrom:
                secretKeyRef:
                  name: checkout-db
                  key: url
          resources:
            requests: {cpu: 100m, memory: 128Mi}
            limits:   {memory: 512Mi}
---
# Wave 0: the workload itself.
apiVersion: apps/v1
kind: Deployment
metadata:
  name: checkout-api
  namespace: checkout
  annotations:
    argocd.argoproj.io/sync-wave: "0"
spec:
  replicas: 6
  selector:
    matchLabels: {app: checkout-api}
  template:
    metadata:
      labels: {app: checkout-api}
    spec:
      containers:
        - name: api
          image: ghcr.io/acme/checkout@sha256:6f2a1c9b8e4d5a3f7c0b1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a
          ports: [{containerPort: 8080, name: http}]
          readinessProbe:
            httpGet: {path: /readyz, port: http}
            periodSeconds: 5
          livenessProbe:
            httpGet: {path: /livez, port: http}
            periodSeconds: 10
          resources:
            requests: {cpu: 250m, memory: 256Mi}
            limits:   {memory: 1Gi}
---
# PostSync: smoke test. Failure triggers the SyncFail hook.
apiVersion: batch/v1
kind: Job
metadata:
  name: checkout-smoke
  namespace: checkout
  annotations:
    argocd.argoproj.io/hook: PostSync
    argocd.argoproj.io/hook-delete-policy: HookSucceeded
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: smoke
          image: ghcr.io/acme/smoke:1.4.2
          args: ["--endpoint", "http://checkout-api.checkout.svc:8080"]
```

| Hook phase | Runs when | Typical use |
|---|---|---|
| `PreSync` | Before any wave is applied | DB migration, backup snapshot |
| `Sync` | Alongside the manifests, obeys waves | Custom apply orchestration |
| `Skip` | Never applied by Argo CD | Manifests managed elsewhere |
| `PostSync` | After all resources report Healthy | Smoke test, cache warm, notify |
| `SyncFail` | After a failed sync | Rollback trigger, incident open |

`hook-delete-policy`: `HookSucceeded` | `HookFailed` | `BeforeHookCreation` (default). Choose `BeforeHookCreation` when you need the failed Job's logs to survive for triage.

### 5.5 Taming false drift: `ignoreDifferences`

The most common operational complaint — "Argo CD says OutOfSync forever" — is almost always a field written by another controller.

```yaml
spec:
  ignoreDifferences:
    # HPA owns replicas. Argo CD must not fight it.
    - group: apps
      kind: Deployment
      name: checkout-api
      namespace: checkout
      jsonPointers:
        - /spec/replicas
    # Istio/Linkerd sidecar injection adds containers at admission time.
    - group: apps
      kind: Deployment
      jqPathExpressions:
        - '.spec.template.spec.containers[] | select(.name == "istio-proxy")'
        - '.spec.template.spec.initContainers[] | select(.name == "istio-init")'
    # cert-manager writes the CA bundle into the webhook config.
    - group: admissionregistration.k8s.io
      kind: ValidatingWebhookConfiguration
      jqPathExpressions:
        - '.webhooks[]?.clientConfig.caBundle'
    # With SSA, ignore everything a named manager owns — the precise tool.
    - group: "*"
      kind: "*"
      managedFieldsManagers:
        - kube-controller-manager
        - horizontal-pod-autoscaler
  syncPolicy:
    syncOptions:
      - RespectIgnoreDifferences=true   # also skip these fields during SYNC, not just diff
```

`RespectIgnoreDifferences=true` is the part people miss: without it, `ignoreDifferences` hides the diff in the UI but the sync still overwrites the field, so the HPA and Argo CD ping-pong.

### 5.6 Custom health for a CRD (Lua, in `argocd-cm`)

Argo CD cannot know whether your `Cluster` CR is healthy. Teach it:

```yaml
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-cm
  namespace: argocd
  labels:
    app.kubernetes.io/part-of: argocd
data:
  application.resourceTrackingMethod: annotation
  timeout.reconciliation: 180s
  resource.customizations.health.cert-manager.io_Certificate: |
    hs = {}
    if obj.status ~= nil and obj.status.conditions ~= nil then
      for i, condition in ipairs(obj.status.conditions) do
        if condition.type == "Ready" and condition.status == "False" then
          hs.status = "Degraded"
          hs.message = condition.message
          return hs
        end
        if condition.type == "Ready" and condition.status == "True" then
          hs.status = "Healthy"
          hs.message = condition.message
          return hs
        end
      end
    end
    hs.status = "Progressing"
    hs.message = "Waiting for certificate to be issued"
    return hs
  resource.customizations.ignoreResourceUpdates.all: |
    jsonPointers:
      - /status
      - /metadata/resourceVersion
```

`application.resourceTrackingMethod: annotation` is a production-grade change: the default `label` method writes `app.kubernetes.io/instance`, a 63-character label that collides with Helm/Kustomize conventions and truncates long Application names, causing **mis-attributed pruning**. The `annotation` method uses `argocd.argoproj.io/tracking-id` with no length constraint.

---

## 6. Secrets: the unavoidable design decision

Git is public-by-default within your organization. Plaintext `Secret` manifests are a breach, not a shortcut.

| Approach | Where ciphertext lives | Where the key lives | Rotation | Break-glass recovery | Trade-off |
|---|---|---|---|---|---|
| **SOPS + age/KMS** | In Git, per-file, per-key encryption | Cluster `Secret` (age) or cloud KMS (IRSA/Workload Identity) | Re-encrypt files; key rotation is a repo-wide commit | Full: decrypt locally with the key | Diffable per key; MAC covers the whole file; native in Flux (`spec.decryption`) |
| **Sealed Secrets** | In Git, asymmetric ciphertext | Controller's private key, in-cluster only | Re-seal against the new public key | Requires backing up the controller key — **frequently forgotten** | Cluster-and-namespace-bound by default; simple; ciphertext is not diffable |
| **External Secrets Operator** | *Not in Git at all* — Git holds a reference | External vault (AWS SM, Vault, GCP SM, Azure KV) | Rotate in the vault; cluster picks it up on `refreshInterval` | Vault is the system of record | Adds a runtime dependency; the "GitOps purity" objection — desired state is now a pointer |
| **Vault Agent / CSI driver** | Not in Git | Vault | Native | Vault | Bypasses `Secret` objects entirely; least Kubernetes-native |

**Position for the exam:** none of these violate GitOps. Principle 2 requires the desired state to be *versioned and immutable*; a versioned *reference* to a secret satisfies it. What violates GitOps is a secret that exists only because a human ran `kubectl create secret`.

### 6.1 SOPS with Flux

```bash
$ age-keygen -o age.agekey
Public key: age1f8qmn3pkxhs8yqvzjhpq3v5s5rrqx5uzvxk2y8y6q3sqnp2zj4wsyz2pqk

$ kubectl -n flux-system create secret generic sops-age \
    --from-file=age.agekey=./age.agekey
secret/sops-age created

$ cat .sops.yaml
creation_rules:
  - path_regex: infra/configs/.*\.yaml$
    encrypted_regex: '^(data|stringData)$'
    age: age1f8qmn3pkxhs8yqvzjhpq3v5s5rrqx5uzvxk2y8y6q3sqnp2zj4wsyz2pqk

$ sops --encrypt --in-place infra/configs/checkout-db-secret.yaml
$ head -12 infra/configs/checkout-db-secret.yaml
apiVersion: v1
kind: Secret
metadata:
    name: checkout-db
    namespace: checkout
type: Opaque
stringData:
    url: ENC[AES256_GCM,data:h7Kc2Pq9wZ3nT1v...,iv:6bF2...,tag:9pQ...,type:str]
sops:
    age:
        - recipient: age1f8qmn3pkxhs8yqvzjhpq3v5s5rrqx5uzvxk2y8y6q3sqnp2zj4wsyz2pqk
```

Only the *values* are encrypted (`encrypted_regex`), so `kind`, `name` and `namespace` remain reviewable in a PR — this is why SOPS beats whole-file encryption for GitOps.

### 6.2 External Secrets Operator

```yaml
---
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: aws-secretsmanager
spec:
  provider:
    aws:
      service: SecretsManager
      region: eu-west-1
      auth:
        jwt:
          serviceAccountRef:
            name: external-secrets
            namespace: external-secrets
---
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: checkout-db
  namespace: checkout
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: aws-secretsmanager
  target:
    name: checkout-db
    creationPolicy: Owner
    deletionPolicy: Retain
    template:
      engineVersion: v2
      type: Opaque
      data:
        url: "postgres://{{ .username }}:{{ .password }}@checkout-db.prod.eu-west-1.rds.amazonaws.com:5432/checkout?sslmode=verify-full"
  data:
    - secretKey: username
      remoteRef:
        key: prod/checkout/db
        property: username
    - secretKey: password
      remoteRef:
        key: prod/checkout/db
        property: password
```

Add the generated `Secret` to `ignoreDifferences` / Flux exclusions, otherwise the reconciler will see an object it does not own and, with prune enabled, may delete it.

---

## 7. Progressive delivery: closing the loop with metrics

A reconciler converges to Git. It does **not** know whether the converged state is *good*. Progressive delivery adds an analysis gate.

| | **Argo Rollouts** | **Flagger** |
|---|---|---|
| Mechanism | Replaces `Deployment` with a `Rollout` CRD | Wraps an existing `Deployment`, generates primary/canary |
| Strategies | Canary, blue-green, with fine step control | Canary, A/B, blue-green, mirroring |
| Traffic providers | Istio, Linkerd, SMI, NGINX, ALB, Gateway API, Traefik, Apache APISIX | Same set, plus Gateway API |
| Analysis | `AnalysisTemplate` → Prometheus, Datadog, NewRelic, CloudWatch, Job, Web | `MetricTemplate` → same providers |
| Manual gate | `pause: {}` + `argo rollouts promote` | Webhook gates / `flagger` confirm-rollout hook |
| GitOps friction | The `Rollout` object's `spec.replicas`/status churn needs `ignoreDifferences` | Flagger *creates* `-primary` objects the reconciler doesn't own → must be excluded from prune |
| Best fit | Argo CD shops; you control the workload CRD | Flux shops; you want to keep plain `Deployment` in Git |

```yaml
---
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: checkout-api
  namespace: checkout
spec:
  replicas: 10
  strategy:
    canary:
      canaryService: checkout-api-canary
      stableService: checkout-api-stable
      trafficRouting:
        istio:
          virtualService:
            name: checkout-api
            routes: [primary]
      analysis:
        templates:
          - templateName: success-rate
        startingStep: 2
        args:
          - name: service-name
            value: checkout-api-canary.checkout.svc.cluster.local
      steps:
        - setWeight: 5
        - pause: {duration: 5m}
        - setWeight: 20
        - pause: {duration: 10m}
        - setWeight: 50
        - pause: {duration: 10m}
        - setWeight: 100
  selector:
    matchLabels: {app: checkout-api}
  template:
    metadata:
      labels: {app: checkout-api}
    spec:
      containers:
        - name: api
          image: ghcr.io/acme/checkout:1.4.2
          resources:
            requests: {cpu: 250m, memory: 256Mi}
---
apiVersion: argoproj.io/v1alpha1
kind: AnalysisTemplate
metadata:
  name: success-rate
  namespace: checkout
spec:
  args:
    - name: service-name
  metrics:
    - name: success-rate
      interval: 1m
      count: 5
      successCondition: result[0] >= 0.99
      failureLimit: 1
      provider:
        prometheus:
          address: http://prometheus.monitoring.svc:9090
          query: |
            sum(irate(istio_requests_total{
              reporter="source",
              destination_service=~"{{args.service-name}}",
              response_code!~"5.."}[2m]))
            /
            sum(irate(istio_requests_total{
              reporter="source",
              destination_service=~"{{args.service-name}}"}[2m]))
    - name: p99-latency
      interval: 1m
      count: 5
      successCondition: result[0] <= 500
      provider:
        prometheus:
          address: http://prometheus.monitoring.svc:9090
          query: |
            histogram_quantile(0.99, sum(rate(istio_request_duration_milliseconds_bucket{
              destination_service=~"{{args.service-name}}"}[2m])) by (le))
```

```bash
$ kubectl argo rollouts get rollout checkout-api -n checkout --watch
Name:            checkout-api
Namespace:       checkout
Status:          ॥ Paused
Message:         CanaryPauseStep
Strategy:        Canary
  Step:          3/8
  SetWeight:     20
  ActualWeight:  20
Images:          ghcr.io/acme/checkout:1.4.1 (stable)
                 ghcr.io/acme/checkout:1.4.2 (canary)
Replicas:
  Desired:       10
  Current:       12
  Updated:       2
  Ready:         12
  Available:     12

NAME                                      KIND        STATUS     AGE  INFO
⟳ checkout-api                            Rollout     ॥ Paused   14d
├──# revision:12
│  ├──⧉ checkout-api-7c9d5f8b6d           ReplicaSet  ✔ Healthy  3m   canary
│  │  ├──□ checkout-api-7c9d5f8b6d-k2vqx  Pod         ✔ Running  3m   ready:2/2
│  │  └──□ checkout-api-7c9d5f8b6d-m8xlp  Pod         ✔ Running  3m   ready:2/2
│  └──α checkout-api-7c9d5f8b6d-2         AnalysisRun ✔ Successful 3m  ✔ 5
└──# revision:11
   └──⧉ checkout-api-5b8f4c2a19           ReplicaSet  ✔ Healthy  6d   stable
      └──□ (8 pods)                       Pod         ✔ Running  6d   ready:2/2
```

**Interaction with the reconciler:** when analysis fails, Rollouts scales the canary ReplicaSet to zero. Git still says `1.4.2`. The reconciler will keep re-applying `1.4.2` and Rollouts will keep aborting. **The rollback is a Git revert, not a cluster action** — this is the single most important operational discipline in GitOps.

---

## 8. Scale and performance tuning

### 8.1 Argo CD

```yaml
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-cmd-params-cm
  namespace: argocd
data:
  # Application controller
  controller.status.processors: "50"
  controller.operation.processors: "25"
  controller.repo.server.timeout.seconds: "180"
  controller.sharding.algorithm: "consistent-hashing"
  controller.diff.server.side: "true"        # offload diff to repo-server
  # Repo server
  reposerver.parallelism.limit: "10"
  reposerver.git.request.timeout: "120s"
  # Server
  server.enable.gzip: "true"
  # Do not re-render on every status write of every resource
  resource.ignoreResourceUpdatesEnabled: "true"
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: argocd-application-controller
  namespace: argocd
spec:
  replicas: 3
  template:
    spec:
      containers:
        - name: argocd-application-controller
          env:
            - name: ARGOCD_CONTROLLER_REPLICAS
              value: "3"
          resources:
            requests: {cpu: "2", memory: 4Gi}
            limits:   {memory: 8Gi}
```

| Symptom at scale | Root cause | Remedy |
|---|---|---|
| Sync latency grows linearly with app count | Single controller shard | `ARGOCD_CONTROLLER_REPLICAS` > 1 + `consistent-hashing` |
| repo-server OOMKilled | Large Helm charts / Jsonnet rendered concurrently | Raise memory limit, lower `reposerver.parallelism.limit`, enable manifest cache TTL |
| Git provider rate-limits Argo CD | Every Application polls independently (default 3 min) | Webhook + raise `timeout.reconciliation` to 30m+ |
| Redis eviction → constant re-render | Undersized `argocd-redis` | Deploy `redis-ha`, size `maxmemory`, monitor `argocd_redis_request_total{failed="true"}` |
| Controller CPU pinned, no syncs happening | High-churn CRD status updates flooding informers | `resource.customizations.ignoreResourceUpdates.*` on `/status` |

### 8.2 Flux

```yaml
# Patch applied via clusters/<name>/flux-system/kustomization.yaml
patches:
  - target:
      kind: Deployment
      name: "(kustomize-controller|helm-controller|source-controller)"
    patch: |
      - op: add
        path: /spec/template/spec/containers/0/args/-
        value: --concurrent=8
      - op: add
        path: /spec/template/spec/containers/0/args/-
        value: --kube-api-qps=500
      - op: add
        path: /spec/template/spec/containers/0/args/-
        value: --kube-api-burst=1000
      - op: add
        path: /spec/template/spec/containers/0/args/-
        value: --requeue-dependency=5s
  - target:
      kind: Deployment
      name: "(kustomize-controller|source-controller)"
    patch: |
      - op: replace
        path: /spec/template/spec/containers/0/resources/limits/memory
        value: 2Gi
```

Sharding (Flux 2.2+): label a controller Deployment with `sharding.fluxcd.io/key: <shard>` and the matching label on the objects it should own. Objects without the label go to the default shard.

---

## 9. Verification and failure diagnosis

### 9.1 Argo CD triage ladder

```bash
$ argocd app list -o wide
NAME                        CLUSTER                   NAMESPACE  PROJECT          STATUS     HEALTH    SYNCPOLICY  CONDITIONS         REPO                                            PATH                            TARGET
argocd/platform-bootstrap   https://kubernetes...     argocd     platform         Synced     Healthy   Auto-Prune  <none>             https://github.com/acme/platform-gitops.git     clusters/prod-eu-west-1/apps    main
argocd/checkout             https://kubernetes...     checkout   tenant-checkout  OutOfSync  Degraded  Auto-Prune  SyncError          https://github.com/acme/checkout-gitops.git     envs/prod                       main
argocd/ingress-nginx        https://kubernetes...     ingress    platform         Synced     Healthy   Auto-Prune  <none>             https://acme.github.io/charts                   .                               4.12.1

$ argocd app get checkout --hard-refresh
Name:               argocd/checkout
Project:            tenant-checkout
Server:             https://kubernetes.default.svc
Namespace:          checkout
URL:                https://argocd.acme.io/applications/checkout
Repo:               https://github.com/acme/checkout-gitops.git
Target:             main
Path:               envs/prod
SyncWindow:         Sync Allowed
Sync Policy:        Automated (Prune, SelfHeal)
Sync Status:        OutOfSync from main (9f3ac21)
Health Status:      Degraded

CONDITION  MESSAGE                                                                                   LAST TRANSITION
SyncError  one or more objects failed to apply, reason: Deployment.apps "checkout-api" is invalid:   2026-08-18T09:14:02Z
           spec.template.spec.containers[0].resources.requests: Invalid value: "250"

GROUP  KIND        NAMESPACE  NAME              STATUS     HEALTH     HOOK  MESSAGE
       Namespace   checkout   checkout          Synced
       Service     checkout   checkout-api      Synced     Healthy          service/checkout-api unchanged
apps   Deployment  checkout   checkout-api      OutOfSync  Degraded         Deployment.apps "checkout-api" is invalid
batch  Job         checkout   checkout-db-...   Synced     Succeeded  PreSync  job.batch/checkout-db-migrate created
```

```bash
$ argocd app diff checkout --hard-refresh
===== apps/Deployment checkout/checkout-api ======
6c6
<     image: ghcr.io/acme/checkout:1.4.1
---
>     image: ghcr.io/acme/checkout:1.4.2
14c14
<     replicas: 10
---
>     replicas: 6
```

That `replicas` diff on an HPA-managed workload is the textbook false drift → `ignoreDifferences` (§5.5).

**Render locally exactly as the repo-server would** — this eliminates "works on my machine":

```bash
$ argocd app manifests checkout --source live   > /tmp/live.yaml
$ argocd app manifests checkout --source git    > /tmp/git.yaml
$ dyff between /tmp/live.yaml /tmp/git.yaml
```

Server-side apply conflict, the highest-signal error in modern Argo CD:

```bash
$ argocd app sync checkout
FATA[0004] rpc error: code = Unknown desc = Apply error: 
Deployment.apps "checkout-api" is invalid: 
Apply failed with 1 conflict: conflict with "kube-controller-manager" using apps/v1:
  .spec.replicas
```

Resolution — decide who owns it, then encode the decision:

| Decision | Action |
|---|---|
| Git owns `replicas` (no HPA) | `syncOptions: [ServerSideApply=true, Force=true]` or remove the HPA |
| HPA owns `replicas` | Remove `replicas` from the manifest **and** add `ignoreDifferences` + `RespectIgnoreDifferences=true` |

### 9.2 Flux triage ladder

```bash
$ flux check
► checking prerequisites
✔ Kubernetes 1.31.4 >=1.30.0-0
► checking version in cluster
✔ distribution: flux-v2.6.4
✔ bootstrapped: true
► checking controllers
✔ helm-controller: deployment ready
► ghcr.io/fluxcd/helm-controller:v1.3.0
✔ kustomize-controller: deployment ready
► ghcr.io/fluxcd/kustomize-controller:v1.6.1
✔ notification-controller: deployment ready
► ghcr.io/fluxcd/notification-controller:v1.6.0
✔ source-controller: deployment ready
► ghcr.io/fluxcd/source-controller:v1.6.2
► checking crds
✔ alerts.notification.toolkit.fluxcd.io/v1beta3
✔ buckets.source.toolkit.fluxcd.io/v1
✔ gitrepositories.source.toolkit.fluxcd.io/v1
✔ helmreleases.helm.toolkit.fluxcd.io/v2
✔ kustomizations.kustomize.toolkit.fluxcd.io/v1
✔ all checks passed

$ flux get all -A
NAMESPACE       NAME                            REVISION                SUSPENDED  READY  MESSAGE
flux-system     gitrepository/flux-system       main@sha1:9f3ac21       False      True   stored artifact for revision 'main@sha1:9f3ac21'

NAMESPACE       NAME                            REVISION                SUSPENDED  READY  MESSAGE
flux-system     kustomization/flux-system       main@sha1:9f3ac21       False      True   Applied revision: main@sha1:9f3ac21
flux-system     kustomization/infra-controllers main@sha1:9f3ac21       False      True   Applied revision: main@sha1:9f3ac21
flux-system     kustomization/infra-configs     main@sha1:7f3ac21       False      False  Kustomization/flux-system/infra-configs dry-run failed: error validating data: ValidationError(ClusterIssuer.spec.acme): unknown field "sever"
flux-system     kustomization/tenants           main@sha1:7f3ac21       False      False  dependency 'flux-system/infra-configs' is not ready
```

Note the propagation: `tenants` is not broken — it is **correctly refusing to proceed** because `dependsOn` was declared. That is the ordering guarantee working.

```bash
# Where did this live object come from? The GitOps provenance question.
$ flux trace deployment/checkout-api -n checkout
Object:         Deployment/checkout-api
Namespace:      checkout
Status:         Managed by Flux
---
Kustomization:  tenants
Namespace:      flux-system
Path:           ./tenants/prod
Revision:       main@sha1:9f3ac21
Status:         Last reconciled at 2026-08-18 09:12:41 +0200 CEST
Message:        Applied revision: main@sha1:9f3ac21
---
GitRepository:  flux-system
Namespace:      flux-system
URL:            ssh://git@github.com/acme/platform-gitops
Branch:         main
Revision:       main@sha1:9f3ac21
Status:         Last reconciled at 2026-08-18 09:12:38 +0200 CEST
Message:        stored artifact for revision 'main@sha1:9f3ac21'

# Preview server-side what a commit will change, before merging.
$ flux diff kustomization tenants --path ./tenants/prod
✚ Deployment/checkout/checkout-worker created
► Deployment/checkout/checkout-api drifted
@@ -28,7 +28,7 @@
       containers:
       - name: api
-        image: ghcr.io/acme/checkout:1.4.1
+        image: ghcr.io/acme/checkout:1.4.2

# Full ownership tree with the inventory used for pruning.
$ flux tree kustomization tenants --namespace flux-system
Kustomization/flux-system/tenants
├── Namespace/checkout
├── ServiceAccount/checkout/checkout-api
├── Service/checkout/checkout-api
├── Deployment/checkout/checkout-api
├── Deployment/checkout/checkout-worker
└── HorizontalPodAutoscaler/checkout/checkout-api

# Force an immediate cycle down the whole chain.
$ flux reconcile kustomization tenants --with-source
► annotating GitRepository flux-system in flux-system namespace
✔ GitRepository annotated
◎ waiting for GitRepository reconciliation
✔ fetched revision main@sha1:9f3ac21
► annotating Kustomization tenants in flux-system namespace
✔ Kustomization annotated
◎ waiting for Kustomization reconciliation
✔ Kustomization reconciliation completed
✔ applied revision main@sha1:9f3ac21
```

Controller logs are structured JSON — filter by object:

```bash
$ kubectl -n flux-system logs deploy/kustomize-controller --tail=200 \
    | jq -r 'select(.level=="error") | "\(.ts) \(.name) \(.msg)"'
2026-08-18T09:11:04.882Z infra-configs Reconciliation failed after 1.4s, next try in 2m0s
2026-08-18T09:13:06.118Z infra-configs server-side apply dry-run failed: admission webhook "validate.kyverno.svc-fail" denied the request
```

### 9.3 Failure catalogue

| Symptom | Likely cause | Diagnostic | Fix |
|---|---|---|---|
| App perpetually `OutOfSync`, no visible diff | Field written by another controller or defaulted | `argocd app diff --hard-refresh`; `kubectl get -o yaml \| grep managedFields -A20` | `ignoreDifferences` + `RespectIgnoreDifferences=true` |
| `ComparisonError: rpc error … repository not accessible` | Deploy key rotated/revoked; repo moved; private CA | `kubectl -n argocd logs deploy/argocd-repo-server`; `flux get sources git` | Recreate the credential `Secret`; add CA bundle to `argocd-tls-certs-cm` / `GitRepository.spec.secretRef` |
| `SharedResourceWarning` / two apps fight over one object | Overlapping `path`s, or a chart shipping a shared CRD | `argocd app resources <app>` on both | Add `FailOnSharedResource=true`; move the shared object into its own Application/Kustomization at an earlier wave |
| Sync succeeds, workload never Ready | Health assessment passes but probes fail | `kubectl describe pod`; `kubectl get events --sort-by=.lastTimestamp` | Real bug — the reconciler is correct. Revert the commit. |
| Prune deleted a resource nobody expected | Tracking label collision, or object removed from Git by an unrelated refactor | `argocd app history`; `git log -p -- <path>` | Switch to `resourceTrackingMethod: annotation`; enable `PruneLast=true`; `Prune=confirm` for cluster-scoped |
| Flux `Kustomization` stuck `Progressing` forever | `wait: true` + a `healthChecks` target that never becomes ready | `flux get kustomizations`; `flux logs --kind=Kustomization --name=<n>` | Fix the workload, or set a `timeout` so it fails loudly instead of hanging |
| `HelmRelease` `upgrade retries exhausted` | Immutable field change (e.g. `Service.spec.clusterIP`, StatefulSet `volumeClaimTemplates`) | `helm history <rel> -n <ns>`; controller logs | `upgrade.force: true` (recreates), or a migration plan — never blind-force a StatefulSet |
| CRs applied before their CRD exists | No ordering declared | Sync error `no matches for kind` | Argo CD: `sync-wave: "-1"` on CRDs + `SkipDryRunOnMissingResource=true`. Flux: split into two `Kustomization`s with `dependsOn` |
| Git provider returns HTTP 429 | Every Application/GitRepository polling independently | Provider audit log; `argocd_git_request_total` | Webhook `Receiver` + increase intervals; consolidate onto one `GitRepository` |
| Change merged, nothing happens | `suspend: true`, active deny sync window, or `automated` absent | `flux get kustomizations` (SUSPENDED col); `argocd app get` (SyncWindow line) | `flux resume`; adjust `syncWindows` |
| Self-heal fights a legitimate operator | Operator writes into a field Git also declares | `managedFields` inspection | Remove the field from Git; the operator is the owner |
| ApplicationSet deleted the whole fleet | Generator returned an empty/short list (bad path, API error) | `argocd appset get <name>`; controller logs | `applicationsSync: create-update`, `preserveResourcesOnDeletion: true`, and never `allowEmpty: true` on the root |

### 9.4 Observability — the four signals that matter

| Signal | Argo CD metric | Flux metric |
|---|---|---|
| **Drift / sync state** | `argocd_app_info{sync_status="OutOfSync"}` | `gotk_reconcile_condition{type="Ready",status="False"}` |
| **Reconcile latency** | `argocd_app_reconcile_bucket` | `gotk_reconcile_duration_seconds_bucket` |
| **Source fetch failure** | `argocd_git_request_total{request_type="ls-remote"}` | `gotk_reconcile_condition{kind="GitRepository",status="False"}` |
| **Suspended / silenced** | `argocd_app_info{sync_policy="<none>"}` | `gotk_suspend_status == 1` |

```yaml
---
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: gitops-slo
  namespace: monitoring
spec:
  groups:
    - name: gitops.rules
      rules:
        - alert: GitOpsDriftUnresolved
          expr: |
            sum by (name, namespace, dest_namespace) (
              argocd_app_info{sync_status="OutOfSync"}
            ) > 0
          for: 15m
          labels: {severity: warning}
          annotations:
            summary: "Application {{ $labels.name }} has been OutOfSync for 15m"
            description: "Self-heal is failing or disabled. Reconciliation is not converging."
        - alert: GitOpsReconcilerBlind
          expr: |
            sum by (kind, name, exported_namespace) (
              gotk_reconcile_condition{type="Ready",status="False"}
            ) > 0
          for: 10m
          labels: {severity: critical}
          annotations:
            summary: "Flux {{ $labels.kind }}/{{ $labels.name }} not Ready for 10m"
        - alert: GitOpsSuspendedTooLong
          expr: gotk_suspend_status == 1
          for: 24h
          labels: {severity: warning}
          annotations:
            summary: "{{ $labels.kind }}/{{ $labels.name }} suspended >24h — Git is no longer the source of truth"
        - alert: GitOpsSourceStale
          expr: |
            time() - argocd_app_info * on() group_left()
              max(argocd_app_reconcile_sum) by (name) > 1800
          for: 10m
          labels: {severity: critical}
          annotations:
            summary: "Argo CD has not reconciled {{ $labels.name }} in 30m"
```

The alert most teams forget is **`GitOpsSuspendedTooLong`**. A suspended reconciler is indistinguishable from a healthy one on every other dashboard, and it silently converts your GitOps platform back into a push pipeline.

### 9.5 The verification checklist for a new cluster

```bash
# 1. The agent reconciles itself
$ flux get kustomization flux-system
NAME         REVISION            SUSPENDED  READY  MESSAGE
flux-system  main@sha1:9f3ac21   False      True   Applied revision: main@sha1:9f3ac21

# 2. Drift is actually remediated — inject drift, measure recovery
$ kubectl -n checkout scale deploy/checkout-api --replicas=1
deployment.apps/checkout-api scaled
$ sleep 60 && kubectl -n checkout get deploy checkout-api -o jsonpath='{.spec.replicas}{"\n"}'
6

# 3. Deletion is remediated too
$ kubectl -n checkout delete svc checkout-api
service "checkout-api" deleted
$ sleep 60 && kubectl -n checkout get svc checkout-api
NAME           TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)   AGE
checkout-api   ClusterIP   10.100.42.117   <none>        8080/TCP  47s

# 4. Prune works — remove from Git, confirm removal from cluster
# 5. Nothing in the cluster is unmanaged
$ kubectl get all -n checkout -o json \
  | jq -r '.items[] | select(.metadata.annotations["kustomize.toolkit.fluxcd.io/name"] == null
           and .metadata.labels["app.kubernetes.io/managed-by"] != "Helm")
           | "\(.kind)/\(.metadata.name)"'
(empty output = fully managed)

# 6. The bootstrap credential is not a human's PAT
$ kubectl -n flux-system get secret flux-system -o jsonpath='{.data}' | jq 'keys'
[ "identity", "identity.pub", "known_hosts" ]
```

A GitOps implementation that fails tests 2, 3 or 5 is **continuous deployment from Git**, not GitOps. That distinction is exactly what the exam tests.

---

## 10. Referencias

- CNCF CGOA curriculum — https://raw.githubusercontent.com/cncf/curriculum/master/cgoa/README.md
- OpenGitOps — Principles v1.0.0 — https://opengitops.dev/
- OpenGitOps — Glossary and Principles (repository) — https://github.com/open-gitops/documents
- Argo CD documentation — https://argo-cd.readthedocs.io/en/stable/
- Argo CD — Sync Options — https://argo-cd.readthedocs.io/en/stable/user-guide/sync-options/
- Argo CD — Resource Hooks and Sync Waves — https://argo-cd.readthedocs.io/en/stable/user-guide/resource_hooks/
- Argo CD — Diffing customization — https://argo-cd.readthedocs.io/en/stable/user-guide/diffing/
- Argo CD — ApplicationSet controller — https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/
- Argo CD — High Availability and scaling — https://argo-cd.readthedocs.io/en/stable/operator-manual/high_availability/
- Argo CD — Projects (`AppProject`) — https://argo-cd.readthedocs.io/en/stable/user-guide/projects/
- Argo Rollouts — https://argo-rollouts.readthedocs.io/en/stable/
- Flux documentation — https://fluxcd.io/flux/
- Flux — Bootstrap — https://fluxcd.io/flux/installation/bootstrap/
- Flux — Kustomization API — https://fluxcd.io/flux/components/kustomize/kustomizations/
- Flux — HelmRelease API — https://fluxcd.io/flux/components/helm/helmreleases/
- Flux — GitRepository API — https://fluxcd.io/flux/components/source/gitrepositories/
- Flux — OCIRepository API — https://fluxcd.io/flux/components/source/ocirepositories/
- Flux — Image update automation — https://fluxcd.io/flux/guides/image-update/
- Flux — Multi-tenancy lockdown — https://fluxcd.io/flux/installation/configuration/multitenancy/
- Flux — Manage Kubernetes secrets with SOPS — https://fluxcd.io/flux/guides/mozilla-sops/
- Flux — Monitoring and metrics — https://fluxcd.io/flux/monitoring/metrics/
- Flagger — https://fluxcd.io/flagger/
- Kubernetes — Server-Side Apply — https://kubernetes.io/docs/reference/using-api/server-side-apply/
- Kubernetes — Declarative management with Kustomize — https://kubernetes.io/docs/tasks/manage-kubernetes-objects/kustomization/
- SOPS — https://github.com/getsops/sops
- Sealed Secrets — https://github.com/bitnami-labs/sealed-secrets
- External Secrets Operator — https://external-secrets.io/latest/
- Sigstore cosign — https://docs.sigstore.dev/cosign/signing/overview/
- CNCF Landscape, Continuous Delivery / GitOps category — https://landscape.cncf.io/