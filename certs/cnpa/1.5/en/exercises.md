# CNPA 1.5 — Platform Engineering Goals, Objectives, and Strategic Approaches
## Guided Exercises

These exercises make the *strategy* of platform engineering tangible: you will first feel the problem platforms exist to solve (developer cognitive load), then build a minimal golden path, treat it as a product, assess it against the CNCF Platform Engineering Maturity Model, and instrument the metrics that tell you whether the strategy is working.

**Prerequisites**

- `kind` ≥ 0.23, `kubectl`, `helm` ≥ 3.14, `yq` (mikefarah, v4), `jq`, `awk`
- ~4 GB free RAM for a single-node kind cluster

**Reference sources**

- CNPA Curriculum — https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf
- CNCF Platforms White Paper — https://tag-app-delivery.cncf.io/whitepapers/platforms/
- CNCF Platform Engineering Maturity Model — https://tag-app-delivery.cncf.io/whitepapers/platform-eng-maturity-model/
- DORA metrics — https://dora.dev/guides/dora-metrics-four-keys/
- Team Topologies (Thinnest Viable Platform) — https://teamtopologies.com/key-concepts

---

## Exercise 1 — Quantify the problem: cognitive load without a platform

The stated **goal** of platform engineering, per the CNCF Platforms White Paper, is to reduce the cognitive load on product teams by offering shared capabilities as self-service. Before optimizing anything, measure the baseline: what does it cost a developer to ship *one* stateless service "the hard way"?

**1.** Create a lab cluster:

```bash
kind create cluster --name cnpa-15
```

Expected output (versions may differ):

```
Creating cluster "cnpa-15" ...
 ✓ Ensuring node image (kindest/node:v1.33.1) 🖼
 ✓ Preparing nodes 📦
 ✓ Writing configuration 📜
 ✓ Starting control-plane 🕹️
 ✓ Installing CNI 🔌
 ✓ Installing StorageClass 💾
Set kubectl context to "kind-cnpa-15"
```

**2.** Write the full production-grade manifest set a developer would need with **no platform**: workload, service, autoscaling, disruption budget, network policy, and a security posture that passes the `restricted` Pod Security Standard.

```bash
cat > app-the-hard-way.yaml <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: team-checkout
  labels:
    pod-security.kubernetes.io/enforce: restricted
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: checkout
  namespace: team-checkout
  labels:
    app.kubernetes.io/name: checkout
    app.kubernetes.io/part-of: shop
spec:
  replicas: 2
  revisionHistoryLimit: 3
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  selector:
    matchLabels:
      app.kubernetes.io/name: checkout
  template:
    metadata:
      labels:
        app.kubernetes.io/name: checkout
    spec:
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: app
          image: nginxinc/nginx-unprivileged:1.27-alpine
          ports:
            - name: http
              containerPort: 8080
          resources:
            requests:
              cpu: 100m
              memory: 64Mi
            limits:
              memory: 128Mi
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
          readinessProbe:
            httpGet:
              path: /
              port: http
            initialDelaySeconds: 2
            periodSeconds: 5
          livenessProbe:
            httpGet:
              path: /
              port: http
            initialDelaySeconds: 10
            periodSeconds: 10
---
apiVersion: v1
kind: Service
metadata:
  name: checkout
  namespace: team-checkout
spec:
  selector:
    app.kubernetes.io/name: checkout
  ports:
    - name: http
      port: 80
      targetPort: http
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: checkout
  namespace: team-checkout
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: checkout
  minReplicas: 2
  maxReplicas: 6
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: checkout
  namespace: team-checkout
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: checkout
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: checkout-ingress
  namespace: team-checkout
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: checkout
  policyTypes: ["Ingress"]
  ingress:
    - from:
        - namespaceSelector: {}
      ports:
        - port: 8080
EOF
kubectl apply -f app-the-hard-way.yaml
```

Expected output:

```
namespace/team-checkout created
deployment.apps/checkout created
service/checkout created
horizontalpodautoscaler.autoscaling/checkout created
poddisruptionbudget.policy/checkout created
networkpolicy.networking.k8s.io/checkout-ingress created
```

> Note: kind's default CNI (kindnet) does **not** enforce NetworkPolicy, and without metrics-server the HPA reports `<unknown>` targets. The objects are still valid — this gap between "the API accepts it" and "the capability actually works" is itself a platform-capability lesson.

**3.** Measure the interface a developer had to master:

```bash
grep -Evc '^\s*(#|$)' app-the-hard-way.yaml   # non-empty lines
grep -c ':' app-the-hard-way.yaml             # rough count of fields (decisions)
```

Expected output (yours may vary by a few):

```
133
120
```

Roughly **120 fields**, spanning six API kinds, of which only about six actually vary per service (name, team, image, port, replicas, max replicas). Everything else is organizational policy that every team currently re-decides — and can get wrong — independently.

**Check your understanding**

- **Q1.1** — In the manifest above, classify each field as *differentiating* (the app team must decide it) or *undifferentiated* (organizational policy). Roughly what fraction is undifferentiated, and what does that ratio tell you about where a platform should draw its abstraction line?
- **Q1.2** — The CNCF Platforms White Paper distinguishes *intrinsic* from *extraneous* cognitive load. Which kind does the `seccompProfile` field impose on a checkout-service developer, and why does the distinction matter for platform scope decisions?

---

## Exercise 2 — Build a golden path and measure the reduction

A **golden path** (also "paved road") is an opinionated, supported, self-service route to production. You will encode the policy from Exercise 1 into a template whose user-facing interface is only the differentiating fields.

**1.** Create the template as a Helm chart:

```bash
mkdir -p golden-service/templates

cat > golden-service/Chart.yaml <<'EOF'
apiVersion: v2
name: golden-service
description: Golden path for stateless HTTP services (org policy baked in)
version: 0.1.0
EOF

cat > golden-service/values.yaml <<'EOF'
name: checkout
team: shop
image: nginxinc/nginx-unprivileged:1.27-alpine
port: 8080
replicas: 2
maxReplicas: 6
EOF
```

**2.** Write the single template that expands those six values into the full stack:

```bash
cat > golden-service/templates/all.yaml <<'EOF'
{{- $name := .Values.name }}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ $name }}
  labels:
    app.kubernetes.io/name: {{ $name }}
    app.kubernetes.io/part-of: {{ .Values.team }}
    platform.cnpa.dev/template: golden-service
spec:
  replicas: {{ .Values.replicas }}
  revisionHistoryLimit: 3
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  selector:
    matchLabels:
      app.kubernetes.io/name: {{ $name }}
  template:
    metadata:
      labels:
        app.kubernetes.io/name: {{ $name }}
    spec:
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: app
          image: {{ .Values.image }}
          ports:
            - name: http
              containerPort: {{ .Values.port }}
          resources:
            requests:
              cpu: 100m
              memory: 64Mi
            limits:
              memory: 128Mi
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
          readinessProbe:
            httpGet:
              path: /
              port: http
            initialDelaySeconds: 2
            periodSeconds: 5
          livenessProbe:
            httpGet:
              path: /
              port: http
            initialDelaySeconds: 10
            periodSeconds: 10
---
apiVersion: v1
kind: Service
metadata:
  name: {{ $name }}
spec:
  selector:
    app.kubernetes.io/name: {{ $name }}
  ports:
    - name: http
      port: 80
      targetPort: http
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: {{ $name }}
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: {{ $name }}
  minReplicas: {{ .Values.replicas }}
  maxReplicas: {{ .Values.maxReplicas }}
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: {{ $name }}
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: {{ $name }}
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: {{ $name }}-ingress
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: {{ $name }}
  policyTypes: ["Ingress"]
  ingress:
    - from:
        - namespaceSelector: {}
      ports:
        - port: {{ .Values.port }}
EOF
```

**3.** Consume the golden path as a product team would — one command, six inputs:

```bash
helm install checkout ./golden-service -n team-checkout-gp --create-namespace
kubectl get deploy,svc,hpa,pdb,networkpolicy -n team-checkout-gp
```

Expected output:

```
NAME: checkout
NAMESPACE: team-checkout-gp
STATUS: deployed
REVISION: 1
...
NAME                       READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/checkout   2/2     2            2           25s

NAME               TYPE        CLUSTER-IP     EXTERNAL-IP   PORT(S)   AGE
service/checkout   ClusterIP   10.96.201.13   <none>        80/TCP    25s

NAME                                           REFERENCE             TARGETS              MINPODS   MAXPODS   REPLICAS
horizontalpodautoscaler.autoscaling/checkout   Deployment/checkout   cpu: <unknown>/70%   2         6         2

NAME                                    MIN AVAILABLE   MAX UNAVAILABLE   ALLOWED DISRUPTIONS
poddisruptionbudget.policy/checkout     1               N/A               1

NAME                                               POD-SELECTOR
networkpolicy.networking.k8s.io/checkout-ingress   app.kubernetes.io/name=checkout
```

**4.** Verify policy parity (the abstraction must not silently weaken the posture) and compare interface sizes:

```bash
kubectl get deploy checkout -n team-checkout -o yaml \
  | yq '.spec.template.spec.containers[0].securityContext'
kubectl get deploy checkout -n team-checkout-gp -o yaml \
  | yq '.spec.template.spec.containers[0].securityContext'

echo "hard way: $(grep -c ':' app-the-hard-way.yaml) fields"
echo "golden path: $(grep -c ':' golden-service/values.yaml) fields"
```

Expected output — both `securityContext` blocks identical, and:

```
hard way: 120 fields
golden path: 6 fields
```

A ~20x reduction in the decision surface, with policy now versioned in **one** place instead of N copies.

**Check your understanding**

- **Q2.1** — A golden path becomes a "golden cage" when it blocks legitimate needs. Name two concrete escape-hatch designs for this chart, and state the strategic rule that decides when a team's divergence should instead be folded back into the template.
- **Q2.2** — In Team Topologies terms, `helm install checkout ./golden-service` is which interaction mode between the platform team and the stream-aligned team? Which anti-pattern mode would a ticket saying "please deploy my service for me" represent, and why does it fail to scale?
- **Q2.3** — Suppose security wants to change `revisionHistoryLimit` org-wide. Compare the cost of that change before and after the golden path, and name the strategic property this demonstrates.

---

## Exercise 3 — Platform as a Product: personas, capabilities, and the Thinnest Viable Platform

The white paper's core **strategic approach** is treating the platform as a *product*: it has users (personas), a capability roadmap driven by their needs, and it starts as the **Thinnest Viable Platform (TVP)** — the smallest thing that delivers value, per Team Topologies even "a wiki page describing the paved road".

**1.** Capture your users before your features:

```bash
cat > personas.yaml <<'EOF'
personas:
  - name: app-developer
    goal: "Ship features; never open a ticket to get to production"
    pain: "120-field YAML, PSS rejections, cargo-culted manifests"
  - name: sre
    goal: "Uniform fleet: same probes, budgets and labels everywhere"
    pain: "Every service is a snowflake during incidents"
  - name: security-engineer
    goal: "Policy enforced by default, provable in audit"
    pain: "Reviewing N copies of the same securityContext"
  - name: product-manager
    goal: "Predictable lead time for new services"
    pain: "First deploy of a new service takes two weeks"
EOF
```

**2.** Build a capability inventory using the capability domains from the CNCF Platforms White Paper, and mark which subset forms your TVP:

```bash
cat > capabilities.yaml <<'EOF'
capabilities:
  - domain: "Golden path templates and docs"
    item: golden-service chart + README
    persona: app-developer
    tvp: true
  - domain: "Automation for building and testing"
    item: shared CI pipeline
    persona: app-developer
    tvp: false
  - domain: "Delivery / environments"
    item: GitOps-managed namespaces per team
    persona: sre
    tvp: false
  - domain: "Observability"
    item: metrics-server + default dashboards
    persona: sre
    tvp: false
  - domain: "Security services (identity, secrets, policy)"
    item: PSS restricted + NetworkPolicy by default
    persona: security-engineer
    tvp: true
  - domain: "Web portal / service catalog"
    item: Backstage instance
    persona: product-manager
    tvp: false
EOF

yq '.capabilities[] | select(.tvp == true) | .item' capabilities.yaml
```

Expected output:

```
golden-service chart + README
PSS restricted + NetworkPolicy by default
```

**3.** Make the TVP real — its missing half is the *documentation contract*:

```bash
cat > TVP-README.md <<'EOF'
# Paved road: stateless HTTP service
1. helm install <name> ./golden-service -n team-<team> --create-namespace \
     --set name=<name> --set team=<team> --set image=<image> --set port=<port>
2. You get: rolling deploys, HPA 2-6 pods, PDB, restricted security, netpol.
3. Not covered yet (talk to #platform): stateful workloads, public ingress, GPUs.
Support: #platform channel, office hours Tue 14:00.
EOF
```

**Check your understanding**

- **Q3.1** — Contrast the *product* mindset with the *project* mindset for this platform: name three observable differences (funding, lifecycle, success criteria). Why does the maturity model treat "as product" investment as a higher level than "dedicated team"?
- **Q3.2** — Why is the Backstage portal (`tvp: false` above) deliberately *excluded* from the TVP even though "web portal" is a canonical platform capability in the white paper? What ordering rule does TVP impose on the capability roadmap?
- **Q3.3** — The `Not covered yet` section of the README is strategically important. Which platform-as-product failure mode does an *implicit* scope (no such section) cause?

---

## Exercise 4 — Self-assess with the CNCF Platform Engineering Maturity Model

The maturity model evaluates five **aspects** — Investment, Adoption, Interfaces, Operations, Measurement — across four levels: 1 *Provisional*, 2 *Operational*, 3 *Scalable*, 4 *Optimizing*. It is a *direction-finding* tool, not a scoreboard: the model itself warns that higher is not always better if it exceeds what the organization needs.

**1.** Score the platform you just built, with evidence per aspect:

```bash
cat > maturity.yaml <<'EOF'
platform: shop-idp
assessed: "2026-08-06"
aspects:
  - name: investment
    question: "How are staff and funds allocated to platform capabilities?"
    level: 2
    evidence: "Dedicated platform team exists, funded as a cost center, no PM."
  - name: adoption
    question: "Why and how do users discover and use the platform?"
    level: 1
    evidence: "One pilot team; discovery is word of mouth."
  - name: interfaces
    question: "How do users interact with and consume capabilities?"
    level: 2
    evidence: "Standard tooling (helm chart in a shared repo); no self-service portal or API."
  - name: operations
    question: "How are platforms planned, prioritized and maintained?"
    level: 2
    evidence: "Upgrades happen on request via tickets; changes centrally tracked."
  - name: measurement
    question: "What is the process for gathering and acting on feedback?"
    level: 1
    evidence: "No adoption, DORA or satisfaction metrics collected."
EOF
```

**2.** Compute the profile and find the constraint:

```bash
yq -o=json '.' maturity.yaml | jq -r '
  (.aspects[] | "\(.name): level \(.level)"),
  "---",
  "min=\([.aspects[].level] | min) avg=\([.aspects[].level] | add / length)"'
```

Expected output:

```
investment: level 2
adoption: level 1
interfaces: level 2
operations: level 2
measurement: level 1
---
min=1 avg=1.6
```

**3.** Turn the weakest aspects (adoption, measurement) into an **objective with measurable key results** — this is where "goals and objectives" stop being slideware:

```bash
cat > okr-q3.yaml <<'EOF'
objective: "Teams choose the platform because it is the fastest safe path to production"
key_results:
  - kr: "Voluntary golden-path adoption grows from 1 to 6 of 12 service teams"
    metric: adoption_ratio
  - kr: "New-service onboarding takes < 1 day, from repo creation to first deploy"
    metric: onboarding_lead_time
  - kr: "Quarterly platform satisfaction survey established with a baseline NPS"
    metric: platform_nps
EOF
yq '.key_results[].metric' okr-q3.yaml
```

Expected output:

```
adoption_ratio
onboarding_lead_time
platform_nps
```

**Check your understanding**

- **Q4.1** — For the *Adoption* aspect, the model's trajectory runs roughly *erratic → extrinsic push → intrinsic pull → participatory*. Your org considers mandating the golden path by policy to "fix" adoption. Which level does mandation actually correspond to, and what signal do you permanently lose by mandating instead of earning adoption?
- **Q4.2** — Why did we compute `min` and not just the average? Frame your answer in terms of which aspect gates the others (e.g., can Interfaces reach level 4 while Measurement stays at level 1?).
- **Q4.3** — Give one concrete scenario where deliberately *staying* at level 2 in an aspect is the correct strategic decision.

---

## Exercise 5 — Measure success: adoption ratio and DORA-style signals from the cluster

Objectives need instrumentation. You will derive two platform KPIs directly from cluster state: **adoption ratio** (a platform-specific leading indicator) and a **deployment-frequency proxy** (one of the four DORA keys: deployment frequency, lead time for changes, change failure rate, failed-deployment recovery time — https://dora.dev/guides/dora-metrics-four-keys/).

**1.** Create a realistic fleet: some teams on the platform, some not, and mark onboarding with a label (the platform's own telemetry contract):

```bash
kubectl create namespace team-payments
kubectl create namespace team-search
kubectl label namespace team-checkout-gp platform.cnpa.dev/onboarded=true
```

**2.** Compute the adoption ratio:

```bash
total=$(kubectl get ns -o json \
  | jq '[.items[].metadata.name | select(startswith("team-"))] | length')
onboarded=$(kubectl get ns -l platform.cnpa.dev/onboarded=true -o json \
  | jq '.items | length')
awk -v o="$onboarded" -v t="$total" \
  'BEGIN {printf "platform adoption: %d/%d (%.0f%%)\n", o, t, 100*o/t}'
```

Expected output (four `team-*` namespaces exist: `team-checkout`, `team-checkout-gp`, `team-payments`, `team-search`):

```
platform adoption: 1/4 (25%)
```

**3.** Simulate three releases and read the deployment-frequency proxy from the Deployment's revision counter:

```bash
for i in 1 2 3; do
  kubectl -n team-checkout-gp rollout restart deployment/checkout
  kubectl -n team-checkout-gp rollout status deployment/checkout --timeout=120s
done
kubectl -n team-checkout-gp get deploy checkout \
  -o jsonpath='{.metadata.annotations.deployment\.kubernetes\.io/revision}{"\n"}'
```

Expected output (1 initial rollout + 3 restarts):

```
4
```

**4.** Assemble the scorecard your platform team would review weekly:

```bash
printf "%-28s %s\n" "adoption_ratio" "$onboarded/$total" \
                    "deployments_this_window" "4" \
                    "maturity_min_aspect" "adoption=1"
```

Expected output:

```
adoption_ratio               1/4
deployments_this_window      4
maturity_min_aspect          adoption=1
```

**Check your understanding**

- **Q5.1** — The revision annotation is a *proxy* for deployment frequency. Name two ways it misrepresents the real DORA metric, and what a production platform would measure instead (and from where).
- **Q5.2** — Classify each scorecard row as a *leading* or *lagging* indicator of platform success, and explain why a platform team obsessing only over DORA numbers of its tenant teams can still fail as a product.
- **Q5.3** — Why must the adoption label be applied by the platform's own tooling (e.g., by the chart or onboarding automation) rather than by hand, for the metric to stay trustworthy?

---

## Exercise 6 — Strategic approach: build, adopt OSS, or buy

The last strategic decision the curriculum expects you to reason about: for each capability, do you **build** it, **adopt/operate open source**, or **buy** a managed service? Make the trade-offs explicit and weighted instead of vibes-based.

**1.** Score the "developer portal" capability from Exercise 3 (scores 1–5, higher = better for the org; weights sum to 1.0):

```bash
cat > decision.csv <<'EOF'
criterion,weight,build,adopt_oss,buy_saas
time_to_value,0.25,1,3,5
cost_efficiency_3y,0.20,2,4,3
customization_fit,0.20,5,4,2
operational_burden_relief,0.20,1,2,5
exit_cost_lock_in,0.15,5,4,2
EOF

awk -F, 'NR>1 {b+=$2*$3; o+=$2*$4; s+=$2*$5}
  END {printf "build=%.2f  adopt_oss=%.2f  buy_saas=%.2f\n", b, o, s}' decision.csv
```

Expected output:

```
build=2.60  adopt_oss=3.35  buy_saas=3.55
```

**2.** Clean up the lab:

```bash
kind delete cluster --name cnpa-15
```

Expected output:

```
Deleting cluster "cnpa-15" ...
Deleted nodes: ["cnpa-15-control-plane"]
```

**Check your understanding**

- **Q6.1** — `buy_saas` scored highest. Give two reasons the platform team might still legitimately choose `adopt_oss`, and name the class of criteria the matrix cannot capture.
- **Q6.2** — How does the TVP principle from Exercise 3 interact with this decision? Which option does "start thin, iterate on user feedback" usually favor for a capability whose requirements are not yet understood?

---

<details>
<summary><strong>Answers</strong></summary>

### Exercise 1

**Q1.1** — Differentiating fields: `name`, `team`/`part-of`, `image`, `containerPort`, `replicas`/`maxReplicas` — roughly 6 of ~120 fields (~5%). The other ~95% (security context, probes' cadence, rollout strategy, PDB, netpol shape, resource policy, label conventions) is organizational policy identical across services. The abstraction line should sit exactly on that boundary: the platform interface exposes the differentiating ~5% and encodes the rest as defaults. Exposing more leaks policy back into every team; exposing less (e.g., hiding `image`) blocks the team's actual job.

**Q1.2** — `seccompProfile` is **extraneous** cognitive load for a checkout developer: it is essential to the *organization's* security posture but contributes nothing to the developer's problem domain (payment flows). Intrinsic load (their business logic, their API design) cannot be removed; extraneous load can be absorbed by a platform. The distinction matters because platform scope should target extraneous load exclusively — a platform that tries to abstract intrinsic domain complexity becomes an obstacle, while one that leaves extraneous load exposed fails its core goal (CNCF Platforms White Paper, "Why platforms?").

### Exercise 2

**Q2.1** — Escape hatches: (a) an optional `overrides:`/`extraManifests:` values block that lets a team patch or append raw YAML while keeping the paved defaults; (b) explicit opt-out with visibility — the team may write raw manifests, but a required label like `platform.cnpa.dev/off-road=true` makes divergence auditable and support-scoped. The fold-back rule: when the *same* divergence appears in two or three teams, it is no longer an exception but an unmet product requirement — promote it into the template (paved roads are widened by observed traffic, not by upfront speculation).

**Q2.2** — It is **X-as-a-Service**: the platform team publishes a self-service capability consumed without per-use interaction. The ticket is **collaboration degraded into a service desk** — effectively the platform team doing the stream team's work by hand. It fails to scale because platform-team throughput becomes the org-wide bottleneck (queues grow linearly with tenant count), and it inverts the goal: instead of reducing cognitive load via self-service, it centralizes toil. Team Topologies reserves *collaboration* mode for discovering new capabilities, not operating established ones.

**Q2.3** — Before: edit N repos owned by N teams, N reviews, drift guaranteed, completion unverifiable. After: one-line change in `golden-service/templates/all.yaml`, one version bump, rollout tracked by chart version per namespace. The property is **centralized policy with decentralized consumption** (fleet-wide change amortization) — a primary economic justification for platform investment.

### Exercise 3

**Q3.1** — Project mindset: funded once with an end date; "done" at delivery; success = milestones shipped. Product mindset: persistent funding and a persistent team; a roadmap driven by user (persona) feedback; success = adoption, satisfaction, and reduced lead time — measured continuously. Third difference: a project has a handover, a product has a lifecycle including deprecation policy and support (the README's support channel and office hours). The maturity model ranks "as product" above "dedicated team" because a dedicated team can still operate ticket-driven and roadmap-blind; product operation adds user research, prioritization by value, and accountability to outcome metrics rather than output.

**Q3.2** — TVP orders the roadmap by *validated user pain*, not by capability catalogs. The dominant pain (Exercise 1) was manifest complexity and policy drift — solved by the template plus enforced security defaults. A portal is discovery/UX polish on top of capabilities that must exist first; building it now would spend the platform's scarce early credibility on shelfware. The ordering rule: ship the thinnest thing that changes a persona's daily reality, measure, then thicken only where feedback demands it.

**Q3.3** — Implicit scope produces **unbounded implied support**: users assume stateful workloads, ingress, GPUs are covered, hit the edge, file urgent tickets, and perceive the platform as broken rather than scoped. The team then firefights unplanned work and the product's reputation — its adoption engine — erodes. An explicit "not covered yet, here's the channel" converts that failure mode into roadmap signal.

### Exercise 4

**Q4.1** — Mandation is **level 2, extrinsic push**: usage driven by external force rather than user preference. You permanently lose the *adoption-as-feedback* signal: voluntary uptake is the platform's most honest fitness function — if teams route around the platform, the product is wrong. Under mandate, usage is 100% by construction, dissatisfaction goes underground (shadow IT, workaround forks), and the measurement aspect is blinded exactly where it matters. Intrinsic pull (level 3) means the paved road wins because it is genuinely the easiest safe path.

**Q4.2** — The aspects are coupled, and the minimum is the constraint (theory-of-constraints reading). Measurement at level 1 gates everything: without adoption/satisfaction/DORA data you cannot prioritize interface work, justify investment, or know whether operations changes helped — so Interfaces cannot meaningfully progress to "self-service solutions driven by user need" while flying blind. An average hides this; a 4-4-4-4-1 platform is a level-1-constrained platform with expensive decoration.

**Q4.3** — Example: a 40-engineer company with 8 product teams. Pushing Interfaces from level 2 (standard tooling: the chart) to level 3–4 (self-service portal, platform API) costs more than the entire remaining toil it would remove; the maturity model explicitly frames levels as "what your organization needs", not a ladder to climb for its own sake. Staying at level 2 and spending the delta on, say, measurement is the higher-return move. (Same logic as this repo's TVP: a chart plus a README *is* the right interface at this scale.)

### Exercise 5

**Q5.1** — (a) The revision counter conflates *any* template change — including `rollout restart`, which ships zero code — with a release, and misses deploys that don't touch the pod template (ConfigMap-only changes) as well as resets (`revisionHistoryLimit` prunes old ReplicaSets; a deleted/recreated Deployment restarts at 1). (b) It has no time dimension and no per-change identity, so you can't compute frequency per unit time or correlate a deploy with an incident for change-failure-rate. A production platform measures deployment events at the delivery system — CI/CD pipeline completions or GitOps sync events (e.g., Argo CD application sync history) tagged with commit SHA and timestamp — and joins them with incident data for the other DORA keys.

**Q5.2** — `adoption_ratio` and `maturity_min_aspect` are **leading** indicators: they predict whether the platform will produce org-wide outcomes. `deployments_this_window` (DORA) is **lagging**: it reflects outcomes already achieved by tenant teams. The trap: tenant DORA numbers can be good *despite* the platform (heroics, shadow tooling), or a platform can improve its own SLOs while adoption stalls — meaning it optimizes a product nobody chooses. A platform succeeds as a product only when leading indicators (voluntary adoption, satisfaction) and lagging outcomes move together.

**Q5.3** — A hand-applied label measures *labeling discipline*, not adoption: it drifts (teams onboard without the label, offboard without removing it), and once a metric feeds goals it invites gaming (Goodhart's law — label namespaces to hit the KR). Emitted by the onboarding automation itself (chart metadata, controller, or provisioning pipeline), the label is a side effect of the actual behavior being measured, so the metric stays causally tied to reality and auditable.

### Exercise 6

**Q6.1** — Legitimate reasons: (a) data residency/sovereignty or air-gapped environments where SaaS is non-viable regardless of score; (b) the capability is close to the org's differentiation or must integrate deeply with internal systems (identity, audit), where OSS's customization and exit-cost scores dominate long-term even if year-one is slower; also existing in-house operational expertise can flip `operational_burden_relief` in practice. The matrix cannot capture **veto-class constraints** — compliance, legal, procurement, security classification — which are binary gates, not weighted criteria: apply them as filters *before* scoring.

**Q6.2** — TVP favors deferring irreversible commitments while requirements are unvalidated: start with the thinnest option that yields user feedback (often adopt-OSS with minimal configuration, or even a wiki-page process), because SaaS contracts and bespoke builds both encode today's guesses expensively. Once real usage clarifies requirements, re-run the decision with actual data — the matrix is a living product artifact, not a one-time gate.

</details>

---

**Sources**

- CNPA Curriculum, CNCF — https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf
- *Platforms for Cloud Native Computing* (CNCF Platforms White Paper), CNCF TAG App Delivery — https://tag-app-delivery.cncf.io/whitepapers/platforms/
- *Platform Engineering Maturity Model*, CNCF TAG App Delivery — https://tag-app-delivery.cncf.io/whitepapers/platform-eng-maturity-model/
- *DORA's software delivery metrics: the four keys* — https://dora.dev/guides/dora-metrics-four-keys/
- Skelton & Pais, *Team Topologies* — key concepts including Thinnest Viable Platform — https://teamtopologies.com/key-concepts