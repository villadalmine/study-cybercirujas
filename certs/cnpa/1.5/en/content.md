# 1.5 Platform Engineering Goals, Objectives, and Strategic Approaches

> **CNPA exam weight: 7.2%** — this is one of the heaviest topics in Domain 1. The exam probes whether you can articulate *why* a platform exists (goals), *how success is defined and measured* (objectives), and *which delivery strategy fits which organizational context* (strategic approaches: Platform as a Product, Thinnest Viable Platform, Team Topologies interaction modes, and the CNCF Platform Engineering Maturity Model).

---

## 1. Production Motivation: the Architectural Problem a Platform Solves

### 1.1 The cognitive load crisis

The cloud native landscape gives a stream-aligned (application) team an enormous surface to operate: Kubernetes, GitOps controllers, service mesh, observability pipelines, secret managers, policy engines, artifact registries, supply-chain signing, autoscalers. Under a naive "you build it, you run it" model, **every application team must internalize every layer**. Cognitive load theory distinguishes three kinds of load, and the distinction is the core argument for platform engineering:

- **Intrinsic load** — the essential complexity of the team's business domain (e.g., payment settlement logic). This is the load you *want* teams spending brain-cycles on.
- **Extraneous load** — complexity imposed by the environment: writing a `NetworkPolicy` correctly, tuning `PodDisruptionBudgets`, wiring OTLP exporters, rotating registry credentials. Valuable to the *organization*, waste when duplicated per team.
- **Germane load** — the learning effort to build reusable mental models.

Without a platform, extraneous load grows **O(teams × technologies)**: every team re-solves ingress, TLS, quotas, RBAC, CI, and observability, each slightly differently. The production symptoms are predictable:

| Symptom | Mechanism | Production consequence |
|---|---|---|
| **Snowflake infrastructure** | Each team hand-rolls Terraform/Helm with divergent conventions | Incident response requires per-team archaeology; no fleet-wide patching path (e.g., a CVE in an ingress controller must be fixed N different ways) |
| **Ticket-driven operations** | A central ops team gates namespace/DB/DNS creation behind queues | Lead time for a new service measured in weeks; ops team becomes the org-wide bottleneck and burns out |
| **Shadow platforms** | Teams bypass the queue with their own clusters/accounts | Ungoverned spend, unpatched control planes, compliance blind spots |
| **Expert drain** | The few engineers who understand the full stack get pulled into every incident | Bus factor of 1–2 for critical production knowledge |
| **Inconsistent security posture** | Policies applied by convention, not by construction | Audit findings scale linearly with team count |

### 1.2 The platform as the architectural answer

The **CNCF Platforms White Paper** (TAG App Delivery) defines a platform for cloud-native computing as *"an integrated collection of capabilities defined and presented according to the needs of the platform's users."* Three properties in that definition carry the entire discipline:

1. **Integrated collection of capabilities** — the platform *curates and composes* (compute, CI/CD, observability, secrets, messaging, identity) rather than exposing raw building blocks.
2. **Defined and presented** — capabilities are reached through deliberate **interfaces**: Web portals, APIs (typically Kubernetes CRDs), CLIs, and **golden path templates**. The interface *is* the product surface.
3. **According to the needs of the platform's users** — the platform's users are **internal developers and operators**, which makes it an internal *product* with customers, not an infrastructure *project* with a completion date.

Architecturally, the platform inserts a **contract layer** between application teams and infrastructure:

```text
┌─────────────────────────────────────────────────────────┐
│  Stream-aligned teams (product/app developers)          │
│  consume: portal · CLI · CRDs · golden path templates   │
├─────────────────────────────────────────────────────────┤
│  PLATFORM  (the contract / API layer)                   │
│  self-service interfaces · paved roads · guardrails     │
│  owned and operated as a product by the platform team   │
├─────────────────────────────────────────────────────────┤
│  Capability providers (curated, swappable)              │
│  K8s · Argo CD · Crossplane · Vault · Prometheus · …    │
├─────────────────────────────────────────────────────────┤
│  Infrastructure (cloud APIs, bare metal, networks)      │
└─────────────────────────────────────────────────────────┘
```

The contract layer is what makes the underlying implementation **swappable without breaking consumers** — the same reason we put Services in front of Pods. A team requesting `kind: PostgreSQLInstance` neither knows nor cares whether the platform fulfills it with CloudNativePG, RDS, or Cloud SQL today, and something else next year.

---

## 2. Goals of Platform Engineering

The white paper and the CNPA curriculum converge on a stable set of goals. Learn them as *goal → mechanism → anti-goal*:

| Goal | Mechanism | Anti-goal (what it is NOT) |
|---|---|---|
| **Reduce developer cognitive load** | Abstractions that hide *extraneous* complexity behind self-service interfaces | Hiding *all* complexity — escape hatches must exist for power users |
| **Enable self-service** | Declarative APIs (CRDs), portals, templates that provision without human approval in the loop | Removing governance — approval is replaced by *policy-as-code guardrails*, not deleted |
| **Golden paths (paved roads)** | Opinionated, supported, well-documented routes from idea to production | Golden *cages* — mandatory-only paths with no exit breed shadow IT |
| **Consistency & standardization** | Fleet-wide conventions enforced by construction (templates, admission policy) | Uniformity for its own sake; standardize the 80% common case |
| **Speed with safety** | Guardrails (Kyverno/OPA, quotas, signed artifacts) baked into the path of least resistance | Speed by skipping controls |
| **Economies of scale** | Solve each capability once, centrally, with dedicated experts | A central team doing every team's work via tickets (that's the bottleneck the platform removes) |
| **Better developer experience (DevEx)** | Fast onboarding, fast feedback loops, good docs, low-friction workflows | Vanity tooling nobody asked for — needs come from user research |

A memorable formulation from the white paper: platforms let product teams **"focus on delivering value"** while the organization gains **consistency, security and efficiency by construction**.

## 3. Objectives: How Success is Defined and Measured

Goals are directional; **objectives are measurable**. A platform with no measurement program cannot prove it deserves continued investment (this is literally the "Measurement" aspect of the CNCF maturity model, §5.4). The measurement stack the exam expects:

### 3.1 DORA metrics (delivery performance of *platform users*)

- **Deployment frequency** — how often teams ship to production.
- **Lead time for changes** — commit → running in production.
- **Change failure rate** — % of deployments causing degradation.
- **Failed deployment recovery time** — time to restore after a bad change.

The platform's value shows up as *movement in its users' DORA metrics*, not in the platform team's own.

### 3.2 SPACE framework (developer experience is more than throughput)

**S**atisfaction & well-being · **P**erformance · **A**ctivity · **C**ommunication & collaboration · **E**fficiency & flow. SPACE exists because DORA alone can be gamed; pairing quantitative telemetry with **developer surveys** (satisfaction, NPS-style "would you recommend the platform") is the expected practice.

### 3.3 Platform-native KPIs

| Objective | KPI | Instrumentation |
|---|---|---|
| Fast onboarding | **Time to first deployment / "time to hello world"** for a new team or engineer | Scaffolder run timestamp → first successful prod sync in Argo CD |
| Self-service actually used | **Golden path adoption rate** (% of workloads created via templates vs. hand-rolled) | Label injected by the template (`platform.acme.io/template: webservice-v3`), counted fleet-wide |
| Bottleneck removal | **Ticket volume for provisioning** (target ≈ 0) | Ticket system + claim-object creation events |
| Platform reliability | **Platform SLOs** (API availability, portal latency, reconcile time for claims) | Prometheus + SLO burn-rate alerts — the platform is a production system and needs its own error budget |
| Efficiency | **Cost per workload / utilization** | Kubecost/OpenCost per namespace label |

> **Exam trap:** the platform team's objective is *not* "100% of teams must use the platform." Adoption is earned (Platform as a Product, §4.1); a mandated platform with resentful users will report great adoption and terrible outcomes.

---

## 4. Strategic Approaches

### 4.1 Platform as a Product (vs. Platform as a Project)

The single most emphasized strategy in the white paper: run the platform with **product management discipline** — user research, roadmap, releases, docs, support channels, marketing to internal customers.

| Dimension | Platform as a **Project** | Platform as a **Product** |
|---|---|---|
| Lifespan | Ends at "delivery"; decays immediately after | Continuous; funded as long as it delivers value |
| Requirements | Guessed up front by architects | Discovered continuously via user research, surveys, support signals |
| Success metric | "It shipped on time" | User outcomes (DORA/SPACE/adoption of users) |
| Users | Told to use it (mandate) | Won over (internal marketing, DevEx quality) |
| Team | Temporary, disbands | Long-lived product team with PM/owner role |
| Failure mode | Abandonware nobody adopts; "v2 rewrite" cycles | Feature creep if prioritization is weak |
| Docs & support | An afterthought | First-class deliverables (docs, office hours, on-call for the platform) |

### 4.2 Thinnest Viable Platform (TVP)

Coined by Team Topologies (Skelton & Pais): build the **smallest platform that removes the current dominant source of cognitive load — and nothing more**. A TVP can literally start as *a wiki page of curated conventions* on top of a managed Kubernetes offering. Strategic implications:

- Start from the **most painful, most common** developer journey (usually: "deploy a stateless HTTP service with observability and TLS"), pave that path end-to-end, measure, iterate.
- **Buy/adopt managed services** for undifferentiated layers; spend platform-team effort only on the glue and interfaces unique to your org.
- Resist "big design up front" platform programs: an 18-month platform build with no users is the canonical failure story.

### 4.3 Team Topologies: structure and interaction modes

The platform team is one of the four fundamental team types (**stream-aligned, platform, enabling, complicated-subsystem**). What the exam tests is the **interaction modes** and *when each is appropriate*:

| Interaction mode | What it looks like | When the platform team uses it | Duration |
|---|---|---|---|
| **X-as-a-Service** | Teams consume the platform through its interfaces with minimal human contact | Steady state for mature, well-documented capabilities | Ongoing |
| **Collaboration** | Platform + stream team work side by side on something novel | Discovering requirements for a *new* capability; high-bandwidth, expensive | Deliberately time-boxed |
| **Facilitating** | Platform/enabling engineers coach a team to unblock or upskill it | Adoption pushes, migrations, closing skill gaps | Temporary |

Strategy pattern: **collaborate to discover → productize → serve as X-as-a-Service → facilitate stragglers**. A platform team stuck permanently in collaboration mode doesn't scale; one that never collaborates builds the wrong thing.

### 4.4 Adoption strategy: mandate vs. internal market

| Strategy | Pros | Cons | Fits when |
|---|---|---|---|
| **Mandated** ("everyone migrates by Q3") | Fast consolidation; predictable fleet | Resentment, malicious compliance, hides product defects (no exit signal) | Regulatory/security floor (e.g., *all* images must be signed) |
| **Voluntary / compelling product** | Adoption signal = quality signal; happy users evangelize | Slower; fragmentation persists during transition | Everything above the compliance floor |
| **Hybrid (common in practice)** | Guardrails mandated, golden paths voluntary | Requires clarity about which is which | Most production orgs |

Rule of thumb the curriculum leans on: **mandate the guardrails, market the golden paths.**

### 4.5 Build vs. buy vs. compose

| Approach | Cost profile | Flexibility | Risk | Typical choice |
|---|---|---|---|---|
| **Build from scratch** | Highest (staff, forever) | Total | Reinventing CNCF projects badly | Only for genuinely differentiating layers |
| **Buy a commercial IDP/PaaS** | License + integration | Bounded by vendor roadmap | Lock-in; interfaces you don't own | Small orgs, no platform team capacity |
| **Compose CNCF building blocks** (K8s + Argo CD + Crossplane + Backstage + Kyverno + Prometheus…) | Moderate; engineering glue | High; interfaces you own | Integration burden is real, perpetual | The cloud-native default the CNPA assumes |

### 4.6 Abstraction-level spectrum (how much to hide)

| Level | Example interface | Cognitive load on dev team | Flexibility | Platform maintenance cost |
|---|---|---|---|---|
| Raw self-service infra | Terraform modules, direct kubectl | High | Maximum | Low |
| **Golden paths + guardrails** | Backstage template → Git repo → Argo CD → Crossplane claim | **Low for the 80% case** | Escape hatches preserved | Moderate |
| Full PaaS abstraction | `git push` → magic | Minimal | Poor; wall when needs outgrow it | High |

The strategic sweet spot the curriculum endorses is the middle row: **opinionated defaults, optional depth**.

---

## 5. CNCF Platform Engineering Maturity Model

Published by TAG App Delivery. It evaluates **five aspects** across **four levels**. Know the aspect names and level names cold; the exam loves matching scenarios to cells.

**Levels:** 1 **Provisional** → 2 **Operational** → 3 **Scalable** → 4 **Optimizing**

| Aspect | Question it answers | L1 Provisional | L2 Operational | L3 Scalable | L4 Optimizing |
|---|---|---|---|---|---|
| **Investment** | How are staff/funds allocated? | Voluntary / side-project | Dedicated team | Product-funded team(s) | Org-wide strategic investment |
| **Adoption** | Why do users use it? | Erratic; forced or accidental | Extrinsic push (mandate) | Intrinsic pull (teams choose it) | Users co-invest and contribute |
| **Interfaces** | How do users interact? | Bespoke human processes (tickets) | Standard tooling, still manual steps | Self-service solutions | Integrated, managed services |
| **Operations** | How are platforms run? | By request, ad hoc | Centrally maintained | Centrally enabled, platform-managed lifecycle | Managed services with declarative lifecycle |
| **Measurement** | How is success measured? | Ad hoc / none | Basic usage metrics collected | Insights acted upon (feedback loops) | Quantitative + qualitative, org-wide learning |

Strategic use of the model: it is a **diagnostic and planning tool, not a scorecard** — the model itself warns that level 4 in every aspect is not the universal goal; you invest to the level your organization's scale justifies (TVP thinking applied to maturity).

---

## 6. Reference Implementation: One Golden Path, End to End

The strategy sections above become concrete in a minimal but complete golden path: **namespace-as-a-service with guardrails**, exposed as a Kubernetes-native API via Crossplane, consumable from a Backstage template, delivered by GitOps. This is the "Interfaces: self-service" cell of the maturity model implemented with CNCF blocks.

### 6.1 The platform API: CompositeResourceDefinition (XRD)

```yaml
# platform/apis/tenantnamespace/xrd.yaml
apiVersion: apiextensions.crossplane.io/v1
kind: CompositeResourceDefinition
metadata:
  name: xtenantnamespaces.platform.acme.io
spec:
  group: platform.acme.io
  names:
    kind: XTenantNamespace
    plural: xtenantnamespaces
  claimNames:
    kind: TenantNamespace
    plural: tenantnamespaces
  defaultCompositionRef:
    name: tenantnamespace-kubernetes
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
                team:
                  type: string
                  description: Owning team; propagated as a label for cost and policy.
                environment:
                  type: string
                  enum: ["dev", "staging", "prod"]
                  default: dev
                cpuLimit:
                  type: string
                  default: "4"
                  description: Namespace-wide CPU quota (guardrail).
                memoryLimit:
                  type: string
                  default: 8Gi
                  description: Namespace-wide memory quota (guardrail).
              required:
                - team
```

The XRD **is the platform contract**: the enum on `environment` and the defaulted quotas are guardrails enforced at the API schema layer, before any admission controller runs.

### 6.2 The implementation: Composition

```yaml
# platform/apis/tenantnamespace/composition.yaml
apiVersion: apiextensions.crossplane.io/v1
kind: Composition
metadata:
  name: tenantnamespace-kubernetes
  labels:
    platform.acme.io/provider: kubernetes
spec:
  compositeTypeRef:
    apiVersion: platform.acme.io/v1alpha1
    kind: XTenantNamespace
  mode: Pipeline
  pipeline:
    - step: patch-and-transform
      functionRef:
        name: function-patch-and-transform
      input:
        apiVersion: pt.fn.crossplane.io/v1beta1
        kind: Resources
        resources:
          - name: namespace
            base:
              apiVersion: kubernetes.crossplane.io/v1alpha2
              kind: Object
              spec:
                forProvider:
                  manifest:
                    apiVersion: v1
                    kind: Namespace
                    metadata:
                      labels:
                        platform.acme.io/managed: "true"
                providerConfigRef:
                  name: in-cluster
            patches:
              - type: FromCompositeFieldPath
                fromFieldPath: spec.claimRef.name
                toFieldPath: spec.forProvider.manifest.metadata.name
              - type: FromCompositeFieldPath
                fromFieldPath: spec.team
                toFieldPath: spec.forProvider.manifest.metadata.labels[platform.acme.io/team]
              - type: FromCompositeFieldPath
                fromFieldPath: spec.environment
                toFieldPath: spec.forProvider.manifest.metadata.labels[platform.acme.io/env]
          - name: quota
            base:
              apiVersion: kubernetes.crossplane.io/v1alpha2
              kind: Object
              spec:
                forProvider:
                  manifest:
                    apiVersion: v1
                    kind: ResourceQuota
                    metadata:
                      name: platform-quota
                    spec:
                      hard:
                        limits.cpu: "4"
                        limits.memory: 8Gi
                providerConfigRef:
                  name: in-cluster
            patches:
              - type: FromCompositeFieldPath
                fromFieldPath: spec.claimRef.name
                toFieldPath: spec.forProvider.manifest.metadata.namespace
              - type: FromCompositeFieldPath
                fromFieldPath: spec.cpuLimit
                toFieldPath: spec.forProvider.manifest.spec.hard[limits.cpu]
              - type: FromCompositeFieldPath
                fromFieldPath: spec.memoryLimit
                toFieldPath: spec.forProvider.manifest.spec.hard[limits.memory]
          - name: default-deny-netpol
            base:
              apiVersion: kubernetes.crossplane.io/v1alpha2
              kind: Object
              spec:
                forProvider:
                  manifest:
                    apiVersion: networking.k8s.io/v1
                    kind: NetworkPolicy
                    metadata:
                      name: default-deny-ingress
                    spec:
                      podSelector: {}
                      policyTypes:
                        - Ingress
                providerConfigRef:
                  name: in-cluster
            patches:
              - type: FromCompositeFieldPath
                fromFieldPath: spec.claimRef.name
                toFieldPath: spec.forProvider.manifest.metadata.namespace
```

Note the strategy encoded here: the *user* asked for a namespace; the *platform* delivered a namespace **plus** quota **plus** default-deny networking — security and cost governance **by construction**, invisible to the consumer, swappable by the platform team (a new Composition can retarget vCluster or a separate cluster without touching a single claim).

### 6.3 What the developer writes (the entire interface surface)

```yaml
# apps/payments/claim.yaml
apiVersion: platform.acme.io/v1alpha1
kind: TenantNamespace
metadata:
  name: payments-dev
  namespace: team-payments
spec:
  team: payments
  environment: dev
  cpuLimit: "8"
```

Eight lines. That delta — eight lines versus the Namespace/Quota/NetworkPolicy/RBAC boilerplate it replaces — *is* cognitive load reduction, quantified.

### 6.4 The discovery/consumption layer: Backstage template (excerpt of the full flow)

```yaml
# backstage/templates/tenant-namespace/template.yaml
apiVersion: scaffolder.backstage.io/v1beta3
kind: Template
metadata:
  name: tenant-namespace
  title: Request a Tenant Namespace
  description: Self-service namespace with quotas and network guardrails.
  tags:
    - platform
    - golden-path
spec:
  owner: group:platform-team
  type: infrastructure
  parameters:
    - title: Namespace details
      required:
        - name
        - team
      properties:
        name:
          type: string
          title: Namespace name
        team:
          type: string
          title: Owning team
        environment:
          type: string
          title: Environment
          enum: ["dev", "staging", "prod"]
          default: dev
  steps:
    - id: render
      name: Render claim manifest
      action: fetch:template
      input:
        url: ./skeleton
        values:
          name: ${{ parameters.name }}
          team: ${{ parameters.team }}
          environment: ${{ parameters.environment }}
    - id: pr
      name: Open pull request against the platform GitOps repo
      action: publish:github:pull-request
      input:
        repoUrl: github.com?owner=acme&repo=platform-claims
        branchName: ns-${{ parameters.name }}
        title: "Namespace request: ${{ parameters.name }}"
        description: Created via golden path tenant-namespace template.
  output:
    links:
      - title: Pull Request
        url: ${{ steps.pr.output.remoteUrl }}
```

The template opens a **pull request**, not a direct apply: the golden path composes with GitOps (Argo CD syncs `platform-claims` into the cluster), so every self-service action is audited, reviewable, and revertible — self-service *with* governance, the exact synthesis §4.4 argues for.

### 6.5 CLI walkthrough with expected output

```console
$ kubectl apply -f platform/apis/tenantnamespace/xrd.yaml
compositeresourcedefinition.apiextensions.crossplane.io/xtenantnamespaces.platform.acme.io created

$ kubectl get xrd xtenantnamespaces.platform.acme.io
NAME                                 ESTABLISHED   OFFERED   AGE
xtenantnamespaces.platform.acme.io   True          True      12s

$ kubectl apply -f platform/apis/tenantnamespace/composition.yaml
composition.apiextensions.crossplane.io/tenantnamespace-kubernetes created

$ kubectl apply -f apps/payments/claim.yaml
tenantnamespace.platform.acme.io/payments-dev created

$ kubectl get tenantnamespace -n team-payments
NAME           SYNCED   READY   CONNECTION-SECRET   AGE
payments-dev   True     True                        47s

$ crossplane beta trace tenantnamespace payments-dev -n team-payments
NAME                                        SYNCED   READY   STATUS
TenantNamespace/payments-dev (team-payments) True    True    Available
└─ XTenantNamespace/payments-dev-8k2vx       True    True    Available
   ├─ Object/payments-dev-8k2vx-namespace    True    True    Available
   ├─ Object/payments-dev-8k2vx-quota        True    True    Available
   └─ Object/payments-dev-8k2vx-netpol       True    True    Available

$ kubectl get resourcequota -n payments-dev
NAME             AGE   REQUEST   LIMIT
platform-quota   61s             limits.cpu: 0/8, limits.memory: 0/8Gi
```

Measuring golden-path adoption (the §3.3 KPI) with the label the platform injects:

```console
$ kubectl get namespaces -l platform.acme.io/managed=true --no-headers | wc -l
34
$ kubectl get namespaces --no-headers | grep -vE '^(kube-|default|crossplane-system|argocd)' | wc -l
41
# adoption ≈ 34/41 ≈ 83% of tenant namespaces created via the platform API
```

---

## 7. Verification and Failure Diagnosis

Two layers of diagnosis matter here: **technical** (the golden path is broken) and **strategic** (the platform is failing as a product). The exam expects you to recognize both.

### 7.1 Technical: the claim never becomes Ready

Work the resource chain top-down; `crossplane beta trace` shows exactly which node is unhealthy.

```console
$ kubectl get tenantnamespace payments-dev -n team-payments
NAME           SYNCED   READY   CONNECTION-SECRET   AGE
payments-dev   False    False                       5m

$ kubectl describe tenantnamespace payments-dev -n team-payments
...
Events:
  Type     Reason                   Age   From                                             Message
  ----     ------                   ----  ----                                             -------
  Warning  CannotSelectComposition  2m    offered/compositeresourcedefinition.apiextensions.crossplane.io
           no compatible Compositions found: no Composition matched composite type platform.acme.io/v1alpha1, Kind=XTenantNamespace
```

| Symptom | Probable cause | Diagnostic command |
|---|---|---|
| `CannotSelectComposition` | Composition's `compositeTypeRef` doesn't match the XRD group/kind, or a `compositionSelector` label mismatch | `kubectl get compositions -o wide`; compare `spec.compositeTypeRef` with the XRD |
| XRD `ESTABLISHED=False` | Invalid OpenAPI schema in the XRD | `kubectl describe xrd <name>` → conditions |
| Composed `Object`s stuck `SYNCED=False` | provider-kubernetes lacks RBAC to create the target resource | `kubectl describe object <name>`; then `kubectl logs -n crossplane-system deploy/provider-kubernetes-<hash>` |
| Pipeline error `cannot resolve function` | `function-patch-and-transform` package not installed/healthy | `kubectl get functions` → check `INSTALLED`/`HEALTHY` columns |
| Claim accepted but namespace missing | Argo CD hasn't synced the claims repo, or sync failed | `argocd app get platform-claims` → look at `STATUS`/`HEALTH`, `argocd app diff platform-claims` |
| Everything Ready, quota not enforced | Patch path typo — patch silently no-ops onto a nonexistent field | `kubectl get resourcequota -n <ns> -o yaml` and compare against the claim's values |

Provider-side confirmation when in doubt:

```console
$ kubectl get providers,functions
NAME                                                    INSTALLED   HEALTHY   PACKAGE                                              AGE
provider.pkg.crossplane.io/provider-kubernetes          True        True      xpkg.upbound.io/crossplane-contrib/provider-kubernetes:v0.14.1   40d

NAME                                                        INSTALLED   HEALTHY   PACKAGE                                                       AGE
function.pkg.crossplane.io/function-patch-and-transform     True        True      xpkg.upbound.io/crossplane-contrib/function-patch-and-transform:v0.7.0   40d
```

### 7.2 Strategic: the platform is failing as a product

These are diagnosis patterns for the *goals/objectives* layer — the exam phrases them as scenario questions:

| Signal | Diagnosis | Corrective strategy |
|---|---|---|
| Adoption high only where mandated; shadow clusters appearing | Extrinsic adoption (Maturity: Adoption L2); product not compelling | User research; fix the top friction points; market wins — move toward intrinsic pull (L3) |
| Platform team drowning in support requests for the same task | Missing or undiscoverable golden path; docs gap | Productize that journey; measure ticket volume before/after |
| Platform team permanently embedded with app teams | Stuck in Collaboration mode (Team Topologies) | Time-box collaborations; extract the learnings into X-as-a-Service capabilities |
| "The platform is done" appears on a roadmap | Project thinking | Re-fund as a product; assign ownership and a continuous roadmap |
| Great platform metrics, unhappy developers | Measuring activity, not outcomes (DORA without SPACE) | Add qualitative surveys; track satisfaction and flow, not just throughput |
| 18 months of platform build, zero production users | Big-design-up-front; TVP violated | Cut scope to the thinnest path with a real first customer team |
| Users can't leave the paved road at all | Golden cage | Add documented escape hatches; guardrails stay mandatory, abstractions become optional |

### 7.3 Verification checklist (production readiness of the platform itself)

1. **Contract tested:** XRD schema changes go through CI with example claims (`kubectl apply --dry-run=server -f examples/`).
2. **Platform SLOs defined and burning correctly:** claim-to-Ready latency, portal availability, template success rate.
3. **Escape hatch documented:** a team can request an exception and reach raw primitives without leaving governance.
4. **Adoption instrumented:** every template injects an ownership/template label; adoption dashboards read them.
5. **Feedback loop live:** a support channel plus periodic developer survey feeding the platform backlog (Measurement L3: *insights acted upon*).

---

## Referencias

- CNCF Platforms White Paper (TAG App Delivery): https://tag-app-delivery.cncf.io/whitepapers/platforms/
- CNCF Platform Engineering Maturity Model: https://tag-app-delivery.cncf.io/whitepapers/platform-eng-maturity-model/
- CNCF TAG App Delivery — Platforms Working Group: https://tag-app-delivery.cncf.io/wgs/platforms/
- CNPA Curriculum (CNCF): https://github.com/cncf/curriculum
- CNPA Exam (Linux Foundation Training): https://training.linuxfoundation.org/certification/certified-cloud-native-platform-engineering-associate-cnpa/
- Team Topologies (Skelton & Pais) — team types and interaction modes: https://teamtopologies.com/key-concepts
- DORA — DevOps Research and Assessment metrics: https://dora.dev/guides/dora-metrics-four-keys/
- The SPACE of Developer Productivity (ACM Queue): https://queue.acm.org/detail.cfm?id=3454124
- Crossplane documentation — Compositions and XRDs: https://docs.crossplane.io/latest/concepts/compositions/
- Backstage Software Templates: https://backstage.io/docs/features/software-templates/
- CNCF Glossary — Platform Engineering: https://glossary.cncf.io/platform-engineering/