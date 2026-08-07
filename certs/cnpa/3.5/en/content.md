# 3.5 CI/CD Relationship Fundamentals and Integration

> **CNPA domain 3 — Application Delivery.** Exam weight: **2.3**.
> Focus: understanding the *boundary* between Continuous Integration and Continuous Delivery/Deployment, how a platform team exposes both as a self-service capability, and how the two halves are wired together through an **immutable artifact contract** rather than a monolithic pipeline.

---

## 1. Motivation: the architectural problem CI/CD actually solves

Platform engineering does not "own the pipeline." It owns the **contract** between the phase that *produces* a verified artifact and the phase that *reconciles* the runtime toward that artifact. Getting the relationship between those two phases wrong is the single most common failure mode in a delivery platform, and it shows up as three concrete production problems.

**Problem 1 — the imperative "push" pipeline that becomes the source of truth.**
A classic Jenkins/GitLab pipeline ends with `kubectl apply` or `helm upgrade`. The cluster's real state is now defined by *whatever the last successful pipeline run did*, and there is no durable record of desired state that a human or controller can diff against reality. When someone runs `kubectl edit` at 3 a.m. to stop an incident, the cluster **drifts** and nothing detects it until the next deploy silently reverts the hotfix — or fails to. The pipeline had `cluster-admin`, ran outside the cluster, and left no reconciliable desired state.

**Problem 2 — coupling build and deploy into one unit of failure.**
If "integration" (compile, unit test, build image, scan) and "delivery" (roll out, verify, promote) live in one linear script, a flaky end-to-end test blocks the image from ever being *published*, and a registry outage blocks *tests* that already passed from being *recorded*. The two phases have completely different failure semantics, retry policies, RBAC, and cadence. Fusing them means you inherit the worst of both.

**Problem 3 — no artifact identity across environments.**
Teams that rebuild the image per environment (`build → deploy dev`, then `build → deploy staging`) ship a **different binary** to production than the one they tested. "Works in staging, fails in prod" is frequently just: it was never the same artifact. The whole point of CI/CD is that *one* immutable, content-addressed artifact — a container image pinned by digest — is *promoted* through environments, never rebuilt.

The resolution to all three is the same architectural stance, and it is what topic 3.5 is testing:

```
        CONTINUOUS INTEGRATION                 CONTINUOUS DELIVERY / DEPLOYMENT
   ┌──────────────────────────────┐        ┌────────────────────────────────────┐
   │ commit → build → test → scan │        │ desired state (Git) → reconcile →   │
   │        → produce ARTIFACT     │        │  runtime → verify → promote         │
   └───────────────┬──────────────┘        └────────────────▲───────────────────┘
                   │                                         │
                   │      THE CONTRACT / HANDOFF             │
                   └──►  immutable, signed, content-         │
                        addressed artifact + provenance ─────┘
                        (image digest, SBOM, attestation)
```

CI's output is **not** "a deployment." CI's output is an **immutable, attested artifact** plus a proposed change to a **declarative desired state**. CD's input is that desired state, which it reconciles independently. The artifact (an OCI image referenced by `sha256:` digest) is the API between the two systems. Everything else in this topic — GitOps, promotion, progressive delivery, supply-chain gates — is a consequence of taking that contract seriously.

**Why platform engineers care specifically:** the platform team's job is to make this contract a **paved road** — a golden path where an app team gets CI + CD wired correctly by default (templated pipeline, signed images, GitOps repo, promotion flow, rollback) without needing to understand Argo CD internals or cosign. The app team pushes code; the platform absorbs the delivery machinery. That is the "integration" in the topic title.

---

## 2. Core vocabulary — get the boundary exactly right

The exam distinguishes these precisely. Conflating "delivery" and "deployment," or "push" and "pull," is the most common miss.

| Term | What it means | Where the boundary sits |
|---|---|---|
| **Continuous Integration (CI)** | Every commit is merged frequently and automatically built, unit/integration tested, and turned into a versioned artifact. | Ends when a **verified artifact** exists in a registry with provenance. |
| **Continuous Delivery (CD)** | Every artifact that passes CI is *automatically made deployable* to production; the final promotion to prod is a **manual approval / button**. | Prod release is gated by a human decision. |
| **Continuous Deployment (CD)** | Same as above, but the final promotion to prod is **fully automated** when gates pass — no human in the loop. | No manual gate to prod. |
| **Artifact** | The immutable unit produced by CI. In cloud native this is almost always an **OCI image** (also Helm charts and other OCI artifacts). Identified by **digest**, not tag. | The interface object between CI and CD. |
| **Release vs Deploy** | *Deploy* = the new version is running in the cluster. *Release* = user traffic is actually served by it. Progressive delivery **separates** these. | Traffic shifting is release; pod scheduling is deploy. |

### CI vs CD — different systems, on purpose

| Dimension | Continuous Integration | Continuous Delivery/Deployment |
|---|---|---|
| **Trigger** | Source commit / PR / merge | New desired-state commit or new artifact digest |
| **Primary input** | Source code | Declarative manifests (Git) + artifact reference |
| **Primary output** | Signed image + SBOM + test reports | Converged runtime state matching Git |
| **Failure semantics** | Fail fast, block merge | Reconcile/retry, roll back, halt promotion |
| **State model** | Ephemeral (build runs are throwaway) | Durable desired state, continuously reconciled |
| **Where it runs** | Build farm / runners (often outside prod cluster) | Controller *inside* (or adjacent to) target cluster |
| **Identity/RBAC** | Registry push credentials, code access | Cluster apply rights (ideally pull-based, no external creds) |
| **CNCF examples** | Tekton, Argo Workflows, GitHub Actions, Jenkins | Argo CD, Flux, Argo Rollouts, Flagger |

**Rule of thumb for the exam:** if a component needs your *source code*, it is CI. If a component reconciles *cluster state toward Git*, it is CD. A tool that does `git clone && go build && docker push` is CI even if its name has "deploy" in it; a tool that watches a Git repo and applies manifests is CD even if it never builds anything.

---

## 3. Integration model 1 — Push-based vs Pull-based CD

This is the axis the topic most wants you to reason about. It determines *who holds cluster credentials* and *where drift is detected*.

```
PUSH-BASED (imperative)                    PULL-BASED / GitOps (declarative)

 CI runner ──(kubectl/helm, has          Git repo (desired state)
   cluster-admin creds)──► cluster              │
                                                │  in-cluster controller
 desired state = last pipeline run              ▼  PULLS and reconciles
 drift = undetected                        Argo CD / Flux ──► cluster
                                           desired state = Git (durable)
                                           drift = detected & (auto)corrected
```

| Property | Push-based (CI does the deploy) | Pull-based / GitOps (controller reconciles) |
|---|---|---|
| **Credential location** | External runner holds cluster creds (large blast radius) | Controller runs *in* cluster; no inbound creds, no exposed API |
| **Source of truth** | Implicit (last run) | Explicit, versioned Git commit |
| **Drift detection** | None | Continuous; `OutOfSync` surfaced, optional self-heal |
| **Rollback** | Re-run old pipeline (may not be reproducible) | `git revert` → controller converges |
| **Auditability** | Pipeline logs | Git history = full audit log of intent |
| **Multi-cluster scale** | N sets of creds pushed outward | Each cluster pulls; scales horizontally |
| **Failure mode** | Silent divergence | Explicit sync status you can alert on |
| **When it's still fine** | Ephemeral CI-only clusters, simple single-env tools | Anything long-lived, multi-env, regulated |

**GitOps** is the pull-based discipline codified by the CNCF OpenGitOps project into four principles: the system is **Declarative**, **Versioned & Immutable**, **Pulled Automatically**, and **Continuously Reconciled**. In a GitOps platform, CI *never touches the cluster*. CI's last step is to open a commit/PR against a **config repo** (image digest bump); a CD controller inside the cluster does the rest. This is the modern default answer for "how do CI and CD integrate."

### The two-repo pattern (the standard integration wiring)

```
  app repo (source)                    config repo (desired state)
  ───────────────                      ─────────────────────────────
   CI on merge:                         CD controller (Argo CD/Flux):
     1. build image                       - watches this repo
     2. test + scan                       - renders Kustomize/Helm
     3. sign + SBOM                       - applies to cluster
     4. push by digest ──┐                - reports sync/health
                         │                         ▲
                         └── CI opens PR ──────────┘
                             bumping the image
                             digest in overlays/
```

Separating the two repos means: app developers never get cluster credentials, config changes are reviewable as diffs, and the artifact reference (digest) is the only thing that crosses the boundary.

---

## 4. Integration model 2 — the CNCF tool landscape and where each fits

| Tool | Phase | Model | Runs as | Core object | Best-fit role |
|---|---|---|---|---|---|
| **Tekton** | CI (and CI-side of CD) | K8s-native, push | Cluster CRDs (`PipelineRun`) | `Task`, `Pipeline` | Reusable, in-cluster build/test/scan pipelines |
| **Argo Workflows** | CI / batch | K8s-native DAG | Cluster CRDs (`Workflow`) | `Workflow`, `WorkflowTemplate` | DAG-heavy CI, ML, data pipelines |
| **GitHub Actions / GitLab CI** | CI | Push, hosted runners | External runners | `workflow.yaml` | Source-adjacent CI, PR gating |
| **Jenkins** | CI (legacy) | Push | External controller | `Jenkinsfile` | Brownfield / heterogeneous build farms |
| **Argo CD** | CD | Pull / GitOps | In-cluster controller | `Application`, `ApplicationSet` | App-centric GitOps, strong UI, RBAC, multi-cluster |
| **Flux** | CD | Pull / GitOps | In-cluster controllers | `Kustomization`, `HelmRelease`, `ImageUpdateAutomation` | Toolkit/GitOps-as-libraries, built-in image automation |
| **Argo Rollouts** | Progressive delivery | Reconciler | In-cluster controller | `Rollout`, `AnalysisTemplate` | Canary/blue-green with metric-driven analysis |
| **Flagger** | Progressive delivery | Reconciler | In-cluster controller | `Canary` | Progressive delivery driven by service mesh/ingress metrics |
| **Kargo** | Promotion | Reconciler | In-cluster | `Stage`, `Freight`, `Warehouse` | Multi-stage promotion of Freight across environments |
| **cosign / sigstore** | Supply chain | CLI + policy | CLI / admission | signatures, attestations | Sign/verify images, gate at admission |

**Argo CD vs Flux (the comparison most likely to be probed):**

| | Argo CD | Flux |
|---|---|---|
| Shape | Single app/CD product with UI | Set of composable GitOps Toolkit controllers |
| Primary CRD | `Application` / `ApplicationSet` | `GitRepository` + `Kustomization`/`HelmRelease` |
| Built-in image update | No (needs Argo CD Image Updater add-on) | Yes (`ImageRepository`/`ImagePolicy`/`ImageUpdateAutomation`) |
| UI | Rich first-party web UI | CLI/`flux` + third-party dashboards |
| Multi-tenancy | Projects, RBAC, SSO built in | Namespaces + RBAC + tenancy patterns |
| Mental model | "An Application is a Git path → cluster" | "Sources + reconcilers you wire together" |

Neither is "CI." Both consume the artifact CI produced.

---

## 5. Complete, production manifests

These are deliberately full and syntactically valid so you can trace the whole handoff end to end: **CI (Tekton) → signed image → config repo bump → CD (Argo CD) → progressive release (Argo Rollouts)**, with a GitHub Actions equivalent and a Flux image-automation variant for contrast.

### 5.1 CI side — Tekton `Pipeline` (build → test → scan → sign → digest-pin PR)

```yaml
# tekton/pipeline.yaml
apiVersion: tekton.dev/v1
kind: Pipeline
metadata:
  name: build-verify-publish
  namespace: ci
spec:
  params:
    - name: repo-url
      type: string
    - name: revision
      type: string
      default: main
    - name: image
      type: string          # registry.example.com/team/payments-api (no tag)
  workspaces:
    - name: shared           # source checkout shared across tasks
    - name: dockerconfig     # registry push credentials (mounted, never printed)
    - name: cosign-keys      # cosign private key (or use keyless/OIDC)
  results:
    - name: image-digest
      description: The content-addressed digest CD will consume
      value: $(tasks.build.results.IMAGE_DIGEST)
  tasks:
    - name: clone
      taskRef: { name: git-clone }
      workspaces:
        - { name: output, workspace: shared }
      params:
        - { name: url, value: $(params.repo-url) }
        - { name: revision, value: $(params.revision) }

    - name: unit-test
      runAfter: [clone]
      taskRef: { name: golang-test }
      workspaces:
        - { name: source, workspace: shared }

    - name: build
      runAfter: [unit-test]
      taskRef: { name: kaniko }           # rootless, in-cluster image build
      params:
        - { name: IMAGE, value: $(params.image):$(params.revision) }
      workspaces:
        - { name: source, workspace: shared }
        - { name: dockerconfig, workspace: dockerconfig }
      # kaniko task exposes IMAGE_DIGEST as a result — the CI/CD contract value

    - name: scan
      runAfter: [build]
      taskRef: { name: trivy-scanner }    # fail the run on CRITICAL CVEs
      params:
        - name: IMAGE
          value: $(params.image)@$(tasks.build.results.IMAGE_DIGEST)
        - { name: SEVERITY, value: "CRITICAL" }
        - { name: EXIT_CODE, value: "1" }

    - name: sign-and-attest
      runAfter: [scan]
      taskRef: { name: cosign-sign }
      params:
        - name: IMAGE
          value: $(params.image)@$(tasks.build.results.IMAGE_DIGEST)
      workspaces:
        - { name: keys, workspace: cosign-keys }

    - name: promote-to-config-repo
      runAfter: [sign-and-attest]
      taskRef: { name: git-cli }          # opens PR bumping the DIGEST in the config repo
      params:
        - name: GIT_SCRIPT
          value: |
            set -euo pipefail
            git clone https://git.example.com/platform/deploy-config
            cd deploy-config/apps/payments-api/overlays/staging
            # pin by DIGEST, never by mutable tag
            yq -i '.images[0].digest = "$(tasks.build.results.IMAGE_DIGEST)"' kustomization.yaml
            git checkout -b bump-payments-$(context.pipelineRun.uid)
            git commit -am "payments-api: $(tasks.build.results.IMAGE_DIGEST)"
            git push origin HEAD
```

```yaml
# tekton/pipelinerun.yaml — one execution; created per commit by an EventListener/Trigger
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  generateName: build-verify-publish-
  namespace: ci
spec:
  pipelineRef: { name: build-verify-publish }
  params:
    - { name: repo-url, value: https://git.example.com/team/payments-api }
    - { name: revision, value: main }
    - { name: image, value: registry.example.com/team/payments-api }
  workspaces:
    - name: shared
      volumeClaimTemplate:
        spec:
          accessModes: [ReadWriteOnce]
          resources: { requests: { storage: 1Gi } }
    - name: dockerconfig
      secret: { secretName: registry-push-creds }
    - name: cosign-keys
      secret: { secretName: cosign-signing-key }
```

**Key contract detail:** the pipeline's *result* is `image-digest`. The last task pins that **digest** (not `:main`, not `:latest`) into the config repo. Everything downstream references `image@sha256:…` so the artifact is immutable across environments.

### 5.2 CI side — GitHub Actions equivalent (source-adjacent CI, keyless signing)

```yaml
# .github/workflows/ci.yaml
name: ci
on:
  push: { branches: [main] }
permissions:
  contents: read
  packages: write
  id-token: write            # required for keyless (OIDC) cosign signing
jobs:
  build:
    runs-on: ubuntu-latest
    outputs:
      digest: ${{ steps.build.outputs.digest }}
    steps:
      - uses: actions/checkout@v4

      - name: Unit tests
        run: go test ./...

      - uses: docker/setup-buildx-action@v3
      - uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - id: build
        uses: docker/build-push-action@v6
        with:
          push: true
          tags: ghcr.io/${{ github.repository }}:${{ github.sha }}
          # 'digest' output is the immutable content address

      - name: Scan
        uses: aquasecurity/trivy-action@0.24.0
        with:
          image-ref: ghcr.io/${{ github.repository }}@${{ steps.build.outputs.digest }}
          severity: CRITICAL
          exit-code: '1'

      - name: Sign (keyless via Sigstore/Fulcio)
        env: { COSIGN_EXPERIMENTAL: '1' }
        run: |
          cosign sign --yes \
            ghcr.io/${{ github.repository }}@${{ steps.build.outputs.digest }}

  promote:
    needs: build
    runs-on: ubuntu-latest
    steps:
      - name: Open PR against config repo (GitOps handoff)
        run: |
          gh repo clone platform/deploy-config
          cd deploy-config/apps/payments-api/overlays/staging
          yq -i '.images[0].digest = "${{ needs.build.outputs.digest }}"' kustomization.yaml
          gh pr create --title "payments-api ${{ needs.build.outputs.digest }}" \
                       --body "Automated digest bump from CI"
        env: { GH_TOKEN: ${{ secrets.CONFIG_REPO_TOKEN }} }
```

Note the boundary again: **CI has no cluster credentials.** Its terminal action is opening a PR against the config repo. This is what makes it composable with *any* GitOps CD.

### 5.3 CD side — Argo CD `Application` (pull-based reconcile of the config repo)

```yaml
# argocd/payments-api-staging.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: payments-api-staging
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io   # cascade-delete children on app delete
spec:
  project: payments
  source:
    repoURL: https://git.example.com/platform/deploy-config
    targetRevision: main
    path: apps/payments-api/overlays/staging      # Kustomize overlay pinned by digest
  destination:
    server: https://kubernetes.default.svc
    namespace: payments-staging
  syncPolicy:
    automated:
      prune: true          # delete resources removed from Git
      selfHeal: true       # revert manual kubectl drift back to Git
    syncOptions:
      - CreateNamespace=true
      - ApplyOutOfSyncOnly=true
    retry:
      limit: 5
      backoff: { duration: 5s, factor: 2, maxDuration: 3m }
  revisionHistoryLimit: 10
```

For fleet/multi-env fan-out, one `ApplicationSet` templates an `Application` per environment:

```yaml
# argocd/payments-appset.yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: payments-api
  namespace: argocd
spec:
  goTemplate: true
  generators:
    - list:
        elements:
          - { env: staging, cluster: https://kubernetes.default.svc, autosync: "true" }
          - { env: prod,    cluster: https://prod.example.com,        autosync: "false" }
  template:
    metadata:
      name: 'payments-api-{{.env}}'
    spec:
      project: payments
      source:
        repoURL: https://git.example.com/platform/deploy-config
        targetRevision: main
        path: 'apps/payments-api/overlays/{{.env}}'
      destination:
        server: '{{.cluster}}'
        namespace: 'payments-{{.env}}'
      syncPolicy:
        # Continuous Delivery: staging auto-syncs; prod requires a manual sync (approval gate)
        automated: '{{- if eq .autosync "true" }}{ prune: true, selfHeal: true }{{- end }}'
```

This single object encodes the **Continuous Delivery vs Continuous Deployment** distinction from §2: `staging` is Continuous Deployment (automated), `prod` is Continuous Delivery (manual `argocd app sync` = the human gate).

### 5.4 Progressive delivery — Argo Rollouts canary (separating *deploy* from *release*)

```yaml
# apps/payments-api/base/rollout.yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: payments-api
  namespace: payments-staging
spec:
  replicas: 6
  selector:
    matchLabels: { app: payments-api }
  template:
    metadata:
      labels: { app: payments-api }
    spec:
      containers:
        - name: app
          # digest injected by Kustomize overlay — same artifact CI produced
          image: registry.example.com/team/payments-api@sha256:PLACEHOLDER
          ports: [{ containerPort: 8080 }]
          readinessProbe:
            httpGet: { path: /healthz, port: 8080 }
            initialDelaySeconds: 5
  strategy:
    canary:
      canaryService: payments-api-canary
      stableService: payments-api-stable
      trafficRouting:
        nginx:
          stableIngress: payments-api
      steps:
        - setWeight: 10          # release 10% of traffic to new version
        - pause: { duration: 2m }
        - analysis:              # automated gate: query metrics, abort on regression
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
  namespace: payments-staging
spec:
  metrics:
    - name: success-rate
      interval: 30s
      count: 4
      successCondition: result[0] >= 0.99
      failureLimit: 1            # one bad reading aborts the rollout automatically
      provider:
        prometheus:
          address: http://prometheus.monitoring:9090
          query: |
            sum(rate(http_requests_total{app="payments-api",code!~"5.."}[2m]))
            /
            sum(rate(http_requests_total{app="payments-api"}[2m]))
```

Here the pods are **deployed** at `setWeight: 10`, but the version is only progressively **released** as traffic shifts — and an automated metric gate can abort before full release. This is the integration point between CD and observability.

### 5.5 Flux variant — CD *with built-in image automation* (no CI-side PR needed)

```yaml
# flux/payments-source.yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: deploy-config
  namespace: flux-system
spec:
  interval: 1m
  url: https://git.example.com/platform/deploy-config
  ref: { branch: main }
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: payments-api-staging
  namespace: flux-system
spec:
  interval: 5m
  sourceRef: { kind: GitRepository, name: deploy-config }
  path: ./apps/payments-api/overlays/staging
  prune: true
  wait: true
  timeout: 3m
  targetNamespace: payments-staging
---
# Flux discovers new digests itself and commits the bump — image automation lives in CD
apiVersion: image.toolkit.fluxcd.io/v1beta2
kind: ImageRepository
metadata:
  name: payments-api
  namespace: flux-system
spec:
  image: registry.example.com/team/payments-api
  interval: 1m
---
apiVersion: image.toolkit.fluxcd.io/v1beta2
kind: ImagePolicy
metadata:
  name: payments-api
  namespace: flux-system
spec:
  imageRepositoryRef: { name: payments-api }
  policy:
    semver: { range: '>=1.0.0' }
---
apiVersion: image.toolkit.fluxcd.io/v1beta2
kind: ImageUpdateAutomation
metadata:
  name: payments-api
  namespace: flux-system
spec:
  interval: 2m
  sourceRef: { kind: GitRepository, name: deploy-config }
  git:
    commit:
      author: { name: fluxcdbot, email: flux@example.com }
      messageTemplate: 'auto: update payments-api to {{ .NewValue }}'
    push: { branch: main }
  update: { path: ./apps/payments-api/overlays, strategy: Setters }
```

**Contrast worth memorizing:** with Argo CD the *CI system* opens the digest-bump PR (§5.1/§5.2). With Flux's image automation, the *CD system* discovers the new digest and commits the bump itself. Either way the config repo remains the single source of truth — the difference is only *which side owns the write*.

### 5.6 Supply-chain gate — verify the CI attestation at deploy time

```yaml
# policy/require-signed-images.yaml  (Kyverno admission policy)
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-signed-payments-images
spec:
  validationFailureAction: Enforce     # block unsigned images from being admitted
  webhookTimeoutSeconds: 30
  rules:
    - name: verify-cosign-signature
      match:
        any:
          - resources:
              kinds: [Pod]
              namespaces: [payments-staging, payments-prod]
      verifyImages:
        - imageReferences:
            - "registry.example.com/team/payments-api*"
          attestors:
            - entries:
                - keyless:
                    subject: "https://git.example.com/team/payments-api/.github/workflows/ci.yaml@refs/heads/main"
                    issuer: "https://token.actions.githubusercontent.com"
```

This closes the loop: CI *signs* the artifact (§5.1/§5.2), CD *reconciles* it, and admission control *refuses to run anything CI did not sign*. The artifact contract now carries verifiable provenance from build to runtime (the model formalized by **SLSA** and **in-toto**).

---

## 6. CLI: driving and observing the handoff

### 6.1 CI — launch and watch a Tekton run, read the digest result

```console
$ kubectl create -f tekton/pipelinerun.yaml
pipelinerun.tekton.dev/build-verify-publish-2m9xk created

$ tkn pipelinerun logs build-verify-publish-2m9xk -f -n ci
[clone : clone] Cloning into '/workspace/output'...
[unit-test : test] ok  	payments-api/internal/ledger	0.412s
[build : build] INFO[0031] Pushed registry.example.com/team/payments-api@sha256:7d3e...c9
[scan : scan] payments-api (alpine 3.20)  Total: 0 (CRITICAL: 0)
[sign-and-attest : sign] Pushed signature to registry.example.com/team/payments-api:sha256-7d3e...c9.sig
[promote-to-config-repo : git] remote: Create a pull request: bump-payments-...

$ tkn pipelinerun describe build-verify-publish-2m9xk -n ci -o jsonpath='{.status.results}'
[{"name":"image-digest","value":"sha256:7d3e...c9"}]
```

The `image-digest` result is the contract value that flows to CD. Nothing after this point rebuilds the image.

### 6.2 CD — inspect and drive Argo CD

```console
$ argocd app get payments-api-staging
Name:               argocd/payments-api-staging
Project:            payments
Sync Status:        Synced to main (a1b2c3d)
Health Status:      Healthy
Images:             registry.example.com/team/payments-api@sha256:7d3e...c9

GROUP  KIND     NAMESPACE          NAME          STATUS  HEALTH   HOOK
       Service  payments-staging   payments-api  Synced  Healthy
apps   Rollout  payments-staging   payments-api  Synced  Healthy

$ # prod is Continuous Delivery — the manual gate is a deliberate sync:
$ argocd app sync payments-api-prod --prune
TIMESTAMP               GROUP   KIND       NAMESPACE        NAME          STATUS    HEALTH
2026-08-07T14:22:10Z    apps    Rollout    payments-prod    payments-api  Synced    Progressing
Operation:          Sync
Phase:              Succeeded
Message:            successfully synced (all tasks run)
```

### 6.3 Progressive delivery — watch and gate the canary

```console
$ kubectl argo rollouts get rollout payments-api -n payments-staging --watch
Name:            payments-api
Status:          ॥ Paused
Strategy:        Canary
  Step:          1/6
  SetWeight:     10
  ActualWeight:  10
NAME                                       KIND        STATUS     AGE   INFO
⟳ payments-api                             Rollout     ॥ Paused   6m
├──# revision:2
│  └──⧉ payments-api-6f5c8               ReplicaSet  ✔ Healthy  2m    canary
└──# revision:1
   └──⧉ payments-api-84bd9              ReplicaSet  ✔ Healthy  6m    stable

$ # analysis passed → promote through remaining steps:
$ kubectl argo rollouts promote payments-api -n payments-staging
rollout 'payments-api' promoted

$ # a bad metric aborts automatically; to force back to stable:
$ kubectl argo rollouts abort payments-api -n payments-staging
rollout 'payments-api' aborted
```

### 6.4 Flux — reconcile on demand and confirm image automation

```console
$ flux get kustomizations
NAME                    REVISION        SUSPENDED  READY  MESSAGE
payments-api-staging    main@sha1:a1b2  False      True   Applied revision: main@sha1:a1b2

$ flux get image policy payments-api
NAME            LATEST IMAGE                                          READY  MESSAGE
payments-api    registry.example.com/team/payments-api:1.4.2          True   Latest image tag for '...' resolved

$ flux reconcile image update payments-api --with-source
► reconciling image update automation
✔ ImageUpdateAutomation reconciliation completed
✔ committed and pushed commit 'auto: update payments-api to 1.4.2'
```

### 6.5 Verify the supply-chain contract

```console
$ cosign verify \
    --certificate-identity-regexp 'https://git.example.com/team/payments-api/.*' \
    --certificate-oidc-issuer https://token.actions.githubusercontent.com \
    registry.example.com/team/payments-api@sha256:7d3e...c9
Verification for registry.example.com/team/payments-api@sha256:7d3e...c9 --
The following checks were performed on each of these signatures:
  - The cosign claims were validated
  - Existence of the claims in the transparency log was verified offline
  - The code-signing certificate was verified using trusted certificate authority
```

---

## 7. Verification & failure diagnosis

Structured triage for the integration points that break in production.

### 7.1 "CD says Synced but the app is broken"

`Synced` means *cluster == Git*. It says nothing about health. Always read **both** columns.

```console
$ argocd app get payments-api-staging -o wide
Sync Status:   Synced
Health Status: Degraded        # <-- this is the real signal
$ argocd app resources payments-api-staging | grep -i degraded
apps  Rollout  payments-staging  payments-api  Degraded
$ kubectl argo rollouts get rollout payments-api -n payments-staging
Status: ✖ Degraded  (analysis run "success-rate" failed: result[0]=0.94 < 0.99)
```
**Cause:** the canary analysis gate correctly failed the release. **Action:** roll back with `git revert` of the digest bump; the controller converges to the previous known-good digest. Do not `kubectl edit` — self-heal will revert you.

### 7.2 "The pipeline passed but nothing deployed"

The CI→CD handoff broke. Walk the contract left to right:

| Check | Command | If it fails |
|---|---|---|
| Did CI push the digest? | `crane digest registry.../payments-api:main` | CI build/push failed — check `tkn pipelinerun logs` |
| Did CI open/merge the config-repo PR? | inspect config repo history | promote step failed — check git creds / branch protection |
| Did CD see the commit? | `argocd app get … | grep 'Sync Status'` (revision) | webhook not firing → falls back to poll interval; check `argocd repo get` |
| Did CD apply cleanly? | `argocd app history` / `kubectl describe application` | `ComparisonError` — bad manifest, RBAC, or missing namespace |

```console
$ argocd app get payments-api-staging | grep 'Sync Status'
Sync Status:  OutOfSync from main (a1b2c3d)   # CD saw the commit but hasn't applied
$ argocd app sync payments-api-staging
FATA[0002] rpc error: ... one or more objects failed to apply:
  Rollout.argoproj.io "payments-api" is invalid: spec.strategy: Required value
```
**Cause:** malformed overlay reached CD. **Lesson:** validate manifests *in CI* (`kubeconform`, `kustomize build | kubeconform`) so bad desired state never reaches the config repo.

### 7.3 Drift detection (the thing push-based CD cannot do)

```console
$ kubectl scale deployment/legacy-worker --replicas=9 -n payments-staging   # manual drift
$ argocd app get payments-api-staging | grep -i sync
Sync Status:  OutOfSync from main (a1b2c3d)     # detected within seconds
# with selfHeal: true, Argo CD reverts to 6 replicas automatically; without it, alert fires
```
Alert on `argocd_app_info{sync_status="OutOfSync"}` (Argo CD) or `gotk_reconcile_condition{type="Ready",status="False"}` (Flux). A push-based pipeline would never have surfaced this.

### 7.4 Image tag vs digest — the silent classic

```console
$ kubectl get rollout payments-api -o jsonpath='{.spec.template.spec.containers[0].image}'
registry.example.com/team/payments-api:latest      # RED FLAG
```
A mutable tag means two environments can run *different bytes* under the same reference and CD may not redeploy when the tag is repushed (`imagePullPolicy` + no manifest change = no reconcile). **Fix:** always pin `@sha256:…`. This is why every manifest in §5 references a digest.

### 7.5 Webhook not firing → CD looks "slow"

```console
$ argocd app get payments-api-staging | grep 'Sync Status'
Sync Status:  Synced to main (OLD-SHA)     # stuck on an old revision
$ argocd repo get https://git.example.com/platform/deploy-config
Connection: Successful
# webhook missing → Argo CD only reconciles on its poll interval (default 3m)
```
**Action:** configure a repo webhook to Argo CD's `/api/webhook` (or Flux's receiver) so reconciliation is event-driven, not just polled. Polling isn't broken — it's just slower and looks like a hang.

### 7.6 Fast diagnostic table

| Symptom | Most likely cause | First command |
|---|---|---|
| `Synced` + `Degraded` | Runtime/analysis failure, not a sync failure | `kubectl argo rollouts get rollout <n>` |
| `OutOfSync`, won't apply | Bad manifest / RBAC / missing ns | `argocd app sync <n>` (read the error) |
| Pipeline green, no deploy | Handoff (PR/webhook) broke | walk §7.2 table |
| Old revision, stuck | Missing webhook, polling only | `argocd repo get …` |
| Prod won't deploy | Working as designed (manual gate) | `argocd app sync payments-api-prod` |
| Image runs but unsigned pod blocked | Admission policy rejected it | `cosign verify …` |
| Manual fix keeps reverting | `selfHeal: true` (correct!) | change Git, not the cluster |

---

## 8. Exam-focused summary

- **CI ≠ CD.** CI produces a **verified, immutable, signed artifact**; CD **reconciles runtime toward declared desired state**. The artifact **digest** is the API between them.
- **Continuous Delivery** keeps a manual gate to prod; **Continuous Deployment** automates it. Same pipeline, different final switch.
- **Push vs Pull:** GitOps (pull) keeps credentials in-cluster, makes Git the source of truth, and detects/heals drift. Push-based CD cannot detect drift and spreads credentials outward.
- **Integration pattern:** two repos — CI writes an artifact + opens a digest-bump PR on the config repo (or Flux image automation writes it); CD reconciles the config repo. CI never holds cluster creds.
- **Deploy ≠ Release.** Progressive delivery (Argo Rollouts / Flagger) separates scheduling pods from shifting traffic and adds automated metric gates.
- **Provenance is part of the contract:** sign in CI (cosign/sigstore), verify at admission — SLSA/in-toto make the artifact's origin verifiable end to end.
- **Diagnosis:** always read *sync* and *health* separately; pin digests not tags; alert on `OutOfSync`; roll back with `git revert`, never `kubectl edit`.

---

## References

- CNPA Curriculum (CNCF, v2025-04-01) — https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf
- OpenGitOps — Principles v1.0.0 — https://opengitops.dev/
- Argo CD — Declarative GitOps CD — https://argo-cd.readthedocs.io/en/stable/
- Argo CD ApplicationSet — https://argo-cd.readthedocs.io/en/stable/user-guide/application-set/
- Argo Rollouts — Progressive Delivery — https://argoproj.github.io/argo-rollouts/
- Argo Workflows — https://argo-workflows.readthedocs.io/en/stable/
- Flux — GitOps Toolkit — https://fluxcd.io/flux/
- Flux Image Automation — https://fluxcd.io/flux/guides/image-update/
- Flagger — Progressive Delivery Operator — https://docs.flagger.app/
- Tekton Pipelines — https://tekton.dev/docs/pipelines/
- Kargo — Multi-Stage Promotion — https://docs.kargo.io/
- Sigstore / cosign — https://docs.sigstore.dev/
- SLSA — Supply-chain Levels for Software Artifacts — https://slsa.dev/spec/v1.0/
- in-toto — Software Supply Chain Attestation — https://in-toto.io/
- Kyverno — Verify Images — https://kyverno.io/docs/writing-policies/verify-images/
- Trivy — Vulnerability Scanner — https://trivy.dev/latest/docs/
- CNCF App Delivery TAG — https://github.com/cncf/tag-app-delivery
- Kubernetes — Deployments & rollout mechanics — https://kubernetes.io/docs/concepts/workloads/controllers/deployment/