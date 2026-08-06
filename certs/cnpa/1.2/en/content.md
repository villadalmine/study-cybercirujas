# Topic 1.2 — DevOps Practices and Culture in Platform Engineering

**Exam weight: 7.2 — CNPA (Certified Cloud Native Platform Engineering Associate), curriculum 2025-04-01**

---

## 1. Motivation: the production architectural problem

### 1.1 Why "you build it, you run it" stopped scaling

DevOps, as formulated between 2009 and 2016, attacked one specific pathology: the wall between the team that wrote the code and the team that operated it. The prescription — cross-functional teams owning their service end to end ("you build it, you run it", Werner Vogels, 2006) — works superbly at the scale where it was invented: a handful of teams, a small and stable toolchain.

At the scale where platform engineering becomes necessary (dozens of stream teams, hundreds of services, a CNCF-landscape-sized menu of tooling), the same prescription produces a new production failure mode:

- **Cognitive load saturation.** Every product team must now master Kubernetes primitives, Helm/Kustomize, CI pipelines, image scanning, secrets management, observability instrumentation, network policy, and cost controls — *in addition to* their business domain. Team Topologies calls this exceeding the team's **cognitive load budget**; the observable symptom in production is shallow, cargo-culted configuration (copied Deployments with wrong `resources`, no `PodDisruptionBudget`, `latest` tags).
- **Snowflake infrastructure.** Each team resolves the same problems differently: five ingress patterns, three secret stores, N bespoke CI pipelines. Every incident now begins with archaeology instead of diagnosis, and every org-wide change (a CVE in a base image, a Kubernetes API deprecation) becomes an N-team negotiation instead of one platform rollout.
- **Ticket-ops regression.** When teams cannot absorb the operational load, organizations quietly reintroduce a central ops queue. Lead time collapses back to days because every deploy waits on a human in another team — precisely the pathology DevOps existed to remove.

**Platform engineering is the industrialization of DevOps, not its replacement.** The CNCF Platforms White Paper defines a platform as a curated set of capabilities offered as a product to internal users, so that stream-aligned teams keep end-to-end ownership of *their service* while the platform team absorbs the undifferentiated operational load (source: https://tag-app-delivery.cncf.io/whitepapers/platforms/). The cultural practices of DevOps — automation, fast feedback, shared ownership, measurement, blameless learning — remain the operating system; the platform is the mechanism that makes them affordable at scale.

### 1.2 Conway's Law as a design tool

Conway's Law: *organizations design systems that mirror their communication structures*. In production this is not a metaphor — it is why a company with separate DBA, network, and security teams ships architectures with hard synchronous boundaries exactly at those org seams.

The **inverse Conway maneuver** deliberately shapes the org to obtain the architecture you want: if you want stream teams consuming infrastructure through self-service APIs, you create a platform team whose *only* interface to those teams is a product-like API — not a ticket queue, not a shared Slack channel where YAML is pasted. The platform's API surface (Backstage templates, CRDs, a portal) is therefore an organizational decision as much as a technical one.

### 1.3 Culture is measurable: the Westrum typology

DORA research consistently finds that **generative culture predicts both delivery performance and reliability** (source: https://dora.dev/capabilities/generative-organizational-culture/). Westrum's typology:

| Trait | Pathological (power-oriented) | Bureaucratic (rule-oriented) | Generative (performance-oriented) |
|---|---|---|---|
| Information flow | Hoarded, weaponized | Flows through formal channels only | High cooperation, flows to whoever needs it |
| Messengers (bad news) | Shot | Tolerated, ignored | Trained; failure triggers inquiry |
| Responsibilities | Shirked | Narrow, siloed | Shared |
| Bridging between teams | Discouraged | Permitted via process | Encouraged |
| Failure response | Scapegoating | Judgment against the rulebook | Blameless postmortem, systemic fix |
| Novelty | Crushed | Creates "problems" | Implemented |

A platform can *enforce* generative behaviors structurally: blameless postmortems as a required artifact of the incident workflow, error budgets that convert reliability arguments into arithmetic, and golden paths that make the safe thing the easy thing.

---

## 2. Organizational models: Team Topologies applied to platforms

Team Topologies (Skelton & Pais) is the de facto organizational reference of the CNCF platform ecosystem and is cited directly by the Platforms White Paper.

### 2.1 The four team types

| Team type | Mission | Platform-engineering instantiation |
|---|---|---|
| **Stream-aligned** | Deliver a continuous flow of business value | Product/feature teams; the platform's *customers* |
| **Platform** | Provide internal services that reduce stream teams' cognitive load | The IDP team: golden paths, CI/CD, runtime, observability as a service |
| **Enabling** | Grow capabilities in other teams, then leave | Platform advocates / SRE coaching squad driving adoption and migration |
| **Complicated-subsystem** | Own a component requiring deep specialist knowledge | e.g. the team owning a bespoke ML-serving stack or a low-latency network layer |

### 2.2 The three interaction modes — and their trade-offs

| Interaction mode | When to use | Cost | Production risk if misused |
|---|---|---|---|
| **X-as-a-Service** | Capability is mature, stable, self-service | Lowest ongoing cost; scales to many consumers | Applied too early → an API nobody asked for; adoption fails |
| **Collaboration** | Discovering a new capability with 1–2 pilot teams | High communication cost; does not scale | Left permanent → platform team becomes a shared-ops bottleneck again |
| **Facilitating** | Unblocking/teaching a specific team | Medium, time-boxed | Becomes disguised ticket-ops if never time-boxed |

The healthy lifecycle of every platform capability is **collaboration → X-as-a-Service**, with enabling teams facilitating migration. A platform team stuck in permanent collaboration mode is the #1 organizational smell in failed platform initiatives.

### 2.3 Operating-model comparison

| Criterion | Central ops (ticket queue) | Pure DevOps ("every team full-stack") | Platform-mediated DevOps |
|---|---|---|---|
| Lead time for changes | Days–weeks (human queue) | Hours (until cognitive overload) | Minutes–hours, sustained |
| Cognitive load on stream teams | Low but disempowering | Unbounded, grows with landscape | Bounded by platform abstraction |
| Consistency / auditability | High | Low (snowflakes) | High (golden paths, policy as code) |
| Cost of org-wide change (CVE, K8s upgrade) | Medium (one team, but overloaded) | Very high (N independent migrations) | Low (platform rolls out once) |
| Ownership of production ("on call for what you ship") | Broken | Full but exhausting | Full for the app; platform owns the substrate |
| Failure mode | Bottleneck, learned helplessness | Tool sprawl, burnout, shadow IT | Golden cage (mandatory + inflexible) if product discipline is absent |
| Scales to | ~10 services | ~10 teams | 100s of teams, with product management |

---

## 3. Platform as a product: the cultural core

The single most examinable idea in this topic: **treat the platform as an internal product, not an internal project.** Concretely:

- **Voluntary adoption over mandate.** A platform that must be mandated has failed its market test. Golden paths must win on developer experience: the paved road is used because it is genuinely the fastest way to production. A mandatory, inflexible platform is a **golden cage** and drives shadow IT.
- **Thinnest Viable Platform (TVP).** Start with the smallest platform that reduces real cognitive load — often just a wiki page plus one templated path to production — and grow it by demand signal, not by roadmap fantasy. (Team Topologies; echoed in the CNCF white paper.)
- **Product management practices**: user research with developers, a public roadmap, versioned APIs with deprecation policy, docs as a first-class deliverable, NPS/CSAT surveys of internal users.
- **Escape hatches.** Every abstraction must have a documented way down to the raw layer; without it, the first unsupported use case forks the platform.

### 3.1 CNCF Platform Engineering Maturity Model

The maturity model (source: https://tag-app-delivery.cncf.io/whitepapers/platform-eng-maturity-model/) evaluates five aspects across four levels — **Provisional → Operational → Scalable → Optimizing**:

| Aspect | Level 1 – Provisional | Level 2 – Operational | Level 3 – Scalable | Level 4 – Optimizing |
|---|---|---|---|---|
| **Investment** | Voluntary/ad-hoc effort | Dedicated team | Dedicated product team with PM | Enabled ecosystem, funded as strategy |
| **Adoption** | Erratic, forced | Extrinsic push | Intrinsic pull — teams choose it | Participatory: users contribute |
| **Interfaces** | Bespoke per request | Standard tooling, manual gating | Self-service solutions | Managed, integrated services |
| **Operations** | Per-request builds | Centrally tracked, reactive | Centrally enabled, SLO-driven | Managed services, autonomous ops |
| **Measurement** | Anecdotes | Ad-hoc collection | Consistent insights (DORA-class) | Quantitative + qualitative feedback loops |

---

## 4. Measurement culture: DORA and SPACE

### 4.1 The four keys (plus reliability)

DORA (DevOps Research and Assessment, https://dora.dev) defines the industry-standard delivery metrics. Since the 2023 report, "MTTR" is reported as **failed deployment recovery time**, and **reliability** is tracked as a fifth dimension.

| Metric | Definition | Elite cluster (2023 report, indicative) | Measures |
|---|---|---|---|
| **Deployment frequency** | How often code reaches production | On demand (multiple/day) | Throughput |
| **Lead time for changes** | Commit → running in production | < 1 day | Throughput |
| **Change failure rate** | % of deployments causing degradation requiring remediation | ~5% | Stability |
| **Failed deployment recovery time** | Time to restore service after a failed deployment | < 1 hour | Stability |

Two production-critical findings: (1) throughput and stability are **not** a trade-off — elite performers are better at both, because small frequent changes are individually low-risk and fast to revert; (2) the platform's job is to move these metrics *for its customers*: a platform whose adoption does not improve stream teams' DORA metrics is decoration.

**Goodhart's Law warning (exam-relevant anti-pattern):** any of the four keys, used as an individual performance target, corrupts. Deployment frequency is gamed by empty deploys; CFR is gamed by not declaring incidents. DORA metrics are *team- and platform-level capability signals*, never individual KPIs. The **SPACE framework** (Satisfaction, Performance, Activity, Communication, Efficiency — https://queue.acm.org/detail.cfm?id=3454124) exists precisely to force multi-dimensional measurement including developer satisfaction.

### 4.2 SRE practices as the reliability half of the culture

- **SLOs and error budgets** convert "is it reliable enough?" from opinion into arithmetic: SLO 99.9%/30d ⇒ error budget = 43.2 minutes of unavailability. Budget remaining → ship features; budget exhausted → the *pre-agreed* error budget policy freezes feature deploys in favor of reliability work. This de-politicizes the dev-vs-ops conflict (source: https://sre.google/sre-book/embracing-risk/).
- **Toil budget**: SRE caps manual, repetitive, automatable work (Google's heuristic: <50% of SRE time); the platform is the toil-elimination machine.
- **Blameless postmortems**: incidents produce systemic fixes, not culprits — the operational embodiment of Westrum-generative culture (source: https://sre.google/sre-book/postmortem-culture/).

---

## 5. The golden path, end to end (complete manifests)

The artifact that makes this culture concrete is the **golden path**: an opinionated, self-service, templated route from "idea" to "running in production with observability and ownership metadata". Below is a complete, minimal-but-real implementation: Backstage template → generated service → CI → GitOps delivery → DORA measurement → error budget alerts.

### 5.1 Backstage Software Template (`template.yaml`)

```yaml
apiVersion: scaffolder.backstage.io/v1beta3
kind: Template
metadata:
  name: golden-path-go-service
  title: Production Go Microservice (Golden Path)
  description: >
    Creates a Go service with CI, container build, GitOps delivery via
    Argo CD, SLOs, and on-call ownership wired in from commit zero.
  tags:
    - golden-path
    - go
    - recommended
spec:
  owner: group:platform-team
  type: service
  parameters:
    - title: Service identity
      required:
        - name
        - owner
        - system
      properties:
        name:
          title: Service name
          type: string
          pattern: '^[a-z0-9]([-a-z0-9]*[a-z0-9])?$'
          maxLength: 40
          description: DNS-1123 label; becomes repo, image and namespace name.
        owner:
          title: Owning team
          type: string
          ui:field: OwnerPicker
          ui:options:
            catalogFilter:
              kind: Group
        system:
          title: System
          type: string
          ui:field: EntityPicker
          ui:options:
            catalogFilter:
              kind: System
    - title: Operational profile
      required:
        - tier
        - slo_availability
      properties:
        tier:
          title: Service tier
          type: string
          enum: ['1', '2', '3']
          enumNames:
            - 'Tier 1 — customer-facing, 24x7 on-call'
            - 'Tier 2 — internal, business hours'
            - 'Tier 3 — experimental'
          default: '2'
        slo_availability:
          title: Availability SLO (30-day window)
          type: string
          enum: ['99.5', '99.9', '99.95']
          default: '99.9'
  steps:
    - id: fetch
      name: Render service skeleton
      action: fetch:template
      input:
        url: ./skeleton
        values:
          name: ${{ parameters.name }}
          owner: ${{ parameters.owner }}
          system: ${{ parameters.system }}
          tier: ${{ parameters.tier }}
          slo_availability: ${{ parameters.slo_availability }}
    - id: publish
      name: Create Git repository
      action: publish:github
      input:
        repoUrl: github.com?owner=example-org&repo=${{ parameters.name }}
        defaultBranch: main
        repoVisibility: internal
        requiredApprovingReviewCount: 1
    - id: register
      name: Register in software catalog
      action: catalog:register
      input:
        repoContentsUrl: ${{ steps['publish'].output.repoContentsUrl }}
        catalogInfoPath: /catalog-info.yaml
    - id: gitops
      name: Open PR adding the service to the GitOps repo
      action: publish:github:pull-request
      input:
        repoUrl: github.com?owner=example-org&repo=gitops-apps
        branchName: onboard-${{ parameters.name }}
        title: 'onboard: ${{ parameters.name }} (golden path)'
        description: Auto-generated Argo CD Application for ${{ parameters.name }}.
        targetPath: apps
  output:
    links:
      - title: Repository
        url: ${{ steps['publish'].output.remoteUrl }}
      - title: Open in catalog
        icon: catalog
        entityRef: ${{ steps['register'].output.entityRef }}
```

### 5.2 Generated `catalog-info.yaml` — ownership as code

```yaml
apiVersion: backstage.io/v1alpha1
kind: Component
metadata:
  name: checkout
  description: Checkout service (golden path, tier 2)
  annotations:
    github.com/project-slug: example-org/checkout
    argocd/app-name: checkout
    prometheus.io/rule: 'true'
  labels:
    example.com/tier: '2'
spec:
  type: service
  lifecycle: production
  owner: group:payments-team
  system: commerce
```

### 5.3 CI: `.github/workflows/ci.yaml` — build, test, sign-off, GitOps handover

```yaml
name: ci
on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

permissions:
  contents: read
  packages: write

concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: false

env:
  IMAGE: ghcr.io/example-org/checkout

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-go@v5
        with:
          go-version: '1.22'
      - name: Unit tests with race detector
        run: go test -race -coverprofile=cover.out ./...
      - name: Static analysis
        run: go vet ./...

  build-and-push:
    if: github.ref == 'refs/heads/main'
    needs: test
    runs-on: ubuntu-latest
    outputs:
      digest: ${{ steps.push.outputs.digest }}
    steps:
      - uses: actions/checkout@v4
      - uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      - uses: docker/build-push-action@v6
        id: push
        with:
          context: .
          push: true
          tags: ${{ env.IMAGE }}:${{ github.sha }}
          provenance: true

  promote:
    if: github.ref == 'refs/heads/main'
    needs: build-and-push
    runs-on: ubuntu-latest
    steps:
      - name: Checkout GitOps repo
        uses: actions/checkout@v4
        with:
          repository: example-org/gitops-apps
          token: ${{ secrets.GITOPS_PAT }}
      - name: Pin new image by digest
        run: |
          cd apps/checkout/overlays/production
          kustomize edit set image \
            "ghcr.io/example-org/checkout@${{ needs.build-and-push.outputs.digest }}"
      - name: Commit promotion
        run: |
          git config user.name  "platform-bot"
          git config user.email "platform-bot@example.com"
          git commit -am "deploy(checkout): ${{ github.sha }}"
          git push
```

Note the cultural encoding: the *application* pipeline never touches the cluster. It ends by writing desired state to Git. Deployment is the GitOps controller's job — this is the OpenGitOps model (declarative, versioned and immutable, pulled automatically, continuously reconciled — https://opengitops.dev).

### 5.4 GitOps delivery: Argo CD `AppProject` + `Application`

```yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: commerce
  namespace: argocd
spec:
  description: Commerce stream-aligned team applications
  sourceRepos:
    - https://github.com/example-org/gitops-apps.git
  destinations:
    - server: https://kubernetes.default.svc
      namespace: 'checkout*'
  clusterResourceWhitelist: []
  namespaceResourceBlacklist:
    - group: ''
      kind: ResourceQuota
    - group: ''
      kind: LimitRange
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: checkout
  namespace: argocd
  labels:
    example.com/tier: '2'
    example.com/team: payments-team
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: commerce
  source:
    repoURL: https://github.com/example-org/gitops-apps.git
    targetRevision: main
    path: apps/checkout/overlays/production
  destination:
    server: https://kubernetes.default.svc
    namespace: checkout
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
        duration: 10s
        factor: 2
        maxDuration: 3m
  ignoreDifferences:
    - group: apps
      kind: Deployment
      jsonPointers:
        - /spec/replicas   # HPA owns replica count; do not fight it
```

### 5.5 DORA measurement as code: Prometheus recording rules

```yaml
# platform-dora-rules.yaml — evaluated by the platform Prometheus
groups:
  - name: dora.four-keys
    interval: 1m
    rules:
      # Deployment frequency: successful Argo CD syncs per app, per day (30d avg)
      - record: dora:deployment_frequency:per_day_30d
        expr: |
          sum by (name) (
            increase(argocd_app_sync_total{phase="Succeeded"}[30d])
          ) / 30
      # Change failure rate: failed or errored syncs / all terminal syncs (30d)
      - record: dora:change_failure_ratio:30d
        expr: |
          sum by (name) (
            increase(argocd_app_sync_total{phase=~"Failed|Error"}[30d])
          )
          /
          sum by (name) (
            increase(argocd_app_sync_total{phase=~"Succeeded|Failed|Error"}[30d])
          )
      # Recovery time proxy: seconds since last successful sync, surfaced only
      # while the app is Degraded (approximates failed-deployment recovery time)
      - record: dora:time_since_last_success:seconds
        expr: |
          (time() - argocd_app_info{health_status="Degraded"} * 0
            + on (name) group_left ()
              (time() - max by (name) (argocd_app_reconcile_bucket * 0 + 1))
          ) and on (name) argocd_app_info{health_status="Degraded"}
```

Honest engineering caveat you should be able to defend in an exam scenario: **sync count is an imperfect proxy for deployment frequency** — `selfHeal` re-syncs and app-of-apps cascades inflate it. Accurate four-keys pipelines correlate three event streams (VCS commits, deployment events, incident records); reference implementation: https://dora.dev/guides/ (Four Keys). Start with the proxy, state its error bars, refine by demand — that is platform-as-a-product measurement culture.

### 5.6 Error budget enforcement: multi-window, multi-burn-rate alerts

```yaml
# checkout-slo-alerts.yaml — SLO 99.9%/30d, per Google SRE Workbook ch. 5
groups:
  - name: slo.checkout.availability
    rules:
      - record: checkout:error_ratio:rate5m
        expr: |
          sum(rate(http_requests_total{job="checkout",code=~"5.."}[5m]))
          / sum(rate(http_requests_total{job="checkout"}[5m]))
      - record: checkout:error_ratio:rate1h
        expr: |
          sum(rate(http_requests_total{job="checkout",code=~"5.."}[1h]))
          / sum(rate(http_requests_total{job="checkout"}[1h]))
      - record: checkout:error_ratio:rate6h
        expr: |
          sum(rate(http_requests_total{job="checkout",code=~"5.."}[6h]))
          / sum(rate(http_requests_total{job="checkout"}[6h]))
      - record: checkout:error_ratio:rate30m
        expr: |
          sum(rate(http_requests_total{job="checkout",code=~"5.."}[30m]))
          / sum(rate(http_requests_total{job="checkout"}[30m]))

      - alert: CheckoutErrorBudgetBurnFast
        expr: |
          checkout:error_ratio:rate1h  > (14.4 * 0.001)
          and
          checkout:error_ratio:rate5m  > (14.4 * 0.001)
        for: 2m
        labels:
          severity: page
          team: payments-team
        annotations:
          summary: 'checkout burning 30d error budget in ~2 days (14.4x)'
          runbook_url: https://backstage.example.com/docs/checkout/runbooks/slo-burn

      - alert: CheckoutErrorBudgetBurnSlow
        expr: |
          checkout:error_ratio:rate6h  > (6 * 0.001)
          and
          checkout:error_ratio:rate30m > (6 * 0.001)
        for: 15m
        labels:
          severity: ticket
          team: payments-team
        annotations:
          summary: 'checkout burning 30d error budget in ~5 days (6x)'
          runbook_url: https://backstage.example.com/docs/checkout/runbooks/slo-burn
```

The burn-rate factors (14.4× pages, 6× tickets) come directly from the SRE Workbook's multiwindow alerting chapter (https://sre.google/workbook/alerting-on-slos/). The platform ships this file *from the template* with the SLO parameter substituted — reliability culture installed at scaffold time, not retrofitted after the first outage.

---

## 6. CLI verification walkthrough

Validate the rules before they ever reach Prometheus:

```
$ promtool check rules platform-dora-rules.yaml checkout-slo-alerts.yaml
Checking platform-dora-rules.yaml
  SUCCESS: 3 rules found

Checking checkout-slo-alerts.yaml
  SUCCESS: 6 rules found
```

Confirm the golden-path service is delivered and healthy through GitOps:

```
$ argocd app list -p commerce -o wide
NAME      CLUSTER                         NAMESPACE  PROJECT   STATUS  HEALTH   SYNCPOLICY  CONDITIONS  REPO                                             PATH                             TARGET
checkout  https://kubernetes.default.svc  checkout   commerce  Synced  Healthy  Auto-Prune  <none>      https://github.com/example-org/gitops-apps.git   apps/checkout/overlays/production  main
```

```
$ argocd app get checkout --show-operation
Name:               argocd/checkout
Project:            commerce
Server:             https://kubernetes.default.svc
Namespace:          checkout
URL:                https://argocd.example.com/applications/checkout
Source:
- Repo:             https://github.com/example-org/gitops-apps.git
  Target:           main
  Path:             apps/checkout/overlays/production
SyncWindow:         Sync Allowed
Sync Policy:        Automated (Prune)
Sync Status:        Synced to main (9f31c2a)
Health Status:      Healthy

GROUP  KIND        NAMESPACE  NAME      STATUS  HEALTH   HOOK  MESSAGE
       Service     checkout   checkout  Synced  Healthy        service/checkout unchanged
apps   Deployment  checkout   checkout  Synced  Healthy        deployment.apps/checkout configured
```

Query the DORA recording rules the way a platform review meeting would:

```
$ curl -s 'http://prometheus.platform:9090/api/v1/query' \
    --data-urlencode 'query=dora:deployment_frequency:per_day_30d{name="checkout"}' | jq -r '.data.result[] | "\(.metric.name): \(.value[1]) deploys/day"'
checkout: 4.23 deploys/day

$ curl -s 'http://prometheus.platform:9090/api/v1/query' \
    --data-urlencode 'query=dora:change_failure_ratio:30d{name="checkout"}' | jq -r '.data.result[] | "\(.metric.name): \(.value[1])"'
checkout: 0.047
```

Lead time for changes, measured honestly from Git (commit timestamp → promotion commit in the GitOps repo):

```
$ git -C gitops-apps log --grep='deploy(checkout)' -1 --format='%cI  %s'
2026-08-05T14:22:31+00:00  deploy(checkout): 4e9d1b7

$ git -C checkout show -s --format='%cI' 4e9d1b7
2026-08-05T13:58:04+00:00
# Lead time ≈ 24 minutes: commit 13:58 → production desired-state 14:22
```

Verify ownership metadata coverage — the adoption signal — across the fleet:

```
$ kubectl get applications.argoproj.io -n argocd \
    -o custom-columns='NAME:.metadata.name,TEAM:.metadata.labels.example\.com/team,TIER:.metadata.labels.example\.com/tier'
NAME       TEAM            TIER
checkout   payments-team   2
catalog    catalog-team    2
legacy-api <none>          <none>
```

`legacy-api` with `<none>` is your migration backlog, discovered mechanically.

---

## 7. Failure diagnosis guide

### 7.1 Symptom → cause matrix

| Symptom | First check | Likely cause | Fix |
|---|---|---|---|
| Lead time regressing while deployment frequency is stable | CI queue time vs run time (`gh run list`) | Runner starvation or a new manual approval gate | Autoscale runners; move the gate to policy-as-code in the pipeline |
| `argocd app get` shows perpetual `OutOfSync` → `Synced` → `OutOfSync` loop | `argocd app diff checkout` | Controller fighting another actor (HPA on `replicas`, mutating webhook injecting fields) | Add `ignoreDifferences` (as in §5.4) or move the field out of Git |
| Change failure rate spikes after platform upgrade | Correlate `argocd_app_sync_total{phase="Failed"}` timestamps with platform release | Breaking change shipped to all tenants at once | Ring/canary rollout of platform changes; platform gets its own DORA metrics |
| Golden path scaffold fails at `publish:github` | Backstage logs: `kubectl -n backstage logs deploy/backstage \| grep scaffolder` | Expired GitHub App token / missing repo-creation permission | Rotate credentials; add a synthetic "scaffold canary" run to platform monitoring |
| Teams bypassing the platform (shadow IT) | Namespaces without platform labels (below) | Golden cage: missing capability or bad DX — treat as product feedback, not policy violation | User interviews, add the escape hatch or the missing capability |
| Error budget alerts never fire despite incidents | `promtool test rules`; check `http_requests_total` labels | SLI series name/label drift after re-instrumentation | Contract-test SLI queries in CI of the observability repo |

### 7.2 Diagnosis commands with expected output

Sync-loop confirmation (the classic `selfHeal` vs HPA fight):

```
$ argocd app diff checkout
===== apps/Deployment checkout/checkout ======
<   replicas: 3
>   replicas: 7
```

Desired state says 3, live says 7 (HPA scaled up). Without `ignoreDifferences`, `selfHeal` scales the service *down under load* every reconcile — a platform-inflicted outage. Confirm the fix took:

```
$ argocd app get checkout -o json | jq '.spec.ignoreDifferences'
[
  {
    "group": "apps",
    "kind": "Deployment",
    "jsonPointers": [
      "/spec/replicas"
    ]
  }
]
```

Shadow-IT sweep — workloads created outside any golden path:

```
$ kubectl get ns -l '!app.kubernetes.io/managed-by' \
    -o custom-columns='NAME:.metadata.name,CREATED:.metadata.creationTimestamp' | grep -vE '^(kube-|default|NAME)'
data-sci-scratch    2026-07-29T09:11:45Z
ml-inference-tmp    2026-08-01T16:03:12Z
```

CI queue-time regression (lead-time debugging at the right layer):

```
$ gh run list --repo example-org/checkout --workflow ci --limit 3 \
    --json displayTitle,createdAt,startedAt,conclusion \
    --jq '.[] | [.displayTitle, .createdAt, .startedAt, .conclusion] | @tsv'
deploy(checkout): 4e9d1b7   2026-08-05T13:58:10Z  2026-08-05T14:11:52Z  success
fix: idempotent retry       2026-08-05T11:02:33Z  2026-08-05T11:02:41Z  success
feat: partial capture       2026-08-04T17:45:09Z  2026-08-04T17:45:15Z  success
```

The first run waited ~13m40s to *start*: the regression is runner capacity, not test duration. This is exactly why lead time must be decomposed (queue time, build time, review time, sync time) before "fixing" it — optimizing the wrong segment is the most common DORA-driven mistake.

Alert-rule regression testing (culture point: SLO queries are code, so they get tests):

```
$ cat slo-tests.yaml
rule_files:
  - checkout-slo-alerts.yaml
evaluation_interval: 1m
tests:
  - interval: 1m
    input_series:
      - series: 'http_requests_total{job="checkout",code="500"}'
        values: '0+30x120'
      - series: 'http_requests_total{job="checkout",code="200"}'
        values: '0+970x120'
    alert_rule_test:
      - eval_time: 1h
        alertname: CheckoutErrorBudgetBurnFast
        exp_alerts:
          - exp_labels:
              severity: page
              team: payments-team

$ promtool test rules slo-tests.yaml
Unit Testing: slo-tests.yaml
  SUCCESS
```

### 7.3 Verification checklist (release gate for the golden path itself)

1. Scaffold canary: template renders, repo created, catalog entity registered — automated nightly.
2. `argocd app get <canary>` reaches `Synced/Healthy` in < 5 min from promotion commit.
3. `promtool check rules` + `promtool test rules` green in the observability repo CI.
4. DORA dashboards populated for the canary within one scrape interval.
5. Ownership labels present on 100% of golden-path apps (`kubectl` sweep from §6).
6. Error budget policy document linked from every generated runbook URL.

---

## Referencias

- CNCF TAG App Delivery — *Platforms White Paper*: https://tag-app-delivery.cncf.io/whitepapers/platforms/
- CNCF TAG App Delivery — *Platform Engineering Maturity Model*: https://tag-app-delivery.cncf.io/whitepapers/platform-eng-maturity-model/
- CNPA Curriculum (CNCF): https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf
- DORA — research program, four keys and capability articles: https://dora.dev — generative culture: https://dora.dev/capabilities/generative-organizational-culture/
- SPACE framework (Forsgren et al., ACM Queue): https://queue.acm.org/detail.cfm?id=3454124
- Google SRE Book — *Embracing Risk* (error budgets): https://sre.google/sre-book/embracing-risk/ — *Postmortem Culture*: https://sre.google/sre-book/postmortem-culture/
- Google SRE Workbook — *Alerting on SLOs* (multiwindow burn rates): https://sre.google/workbook/alerting-on-slos/
- OpenGitOps — GitOps principles v1.0.0: https://opengitops.dev
- Team Topologies (Skelton & Pais): https://teamtopologies.com
- Backstage — Software Templates: https://backstage.io/docs/features/software-templates/
- Argo CD — declarative setup and sync policies: https://argo-cd.readthedocs.io/en/stable/operator-manual/declarative-setup/
- Prometheus — recording rules and unit testing: https://prometheus.io/docs/prometheus/latest/configuration/recording_rules/ and https://prometheus.io/docs/prometheus/latest/configuration/unit_testing_rules/