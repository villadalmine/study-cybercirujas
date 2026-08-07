# Incident Response and Remediation in Platform Engineering

**Certification:** CNPA (Cloud Native Platform Engineering Associate) · Exam version 2025-04-01
**Domain 3 · Topic 3.4** · Exam weight: 2.3

---

## 1. Motivation: the platform is a shared-fate blast radius

In a "you build it, you run it" world, a product team's incident is bounded by its own service. A **platform** incident is not. The internal developer platform (IDP) is a *product whose customers are other engineering teams*, and its control plane — the Kubernetes API servers, the GitOps controllers, the ingress tier, the CI/CD runners, the shared observability stack, the secrets backend — sits on the critical path of every tenant simultaneously. When the platform degrades, it degrades **N tenants at once**, and it does so *silently* from the tenant's perspective: they see their own deployment failing and open a ticket blaming their code.

This produces three architectural problems that incident response in platform engineering must solve, and which distinguish it from generic application on-call:

1. **Force-multiplied blast radius.** A bad admission webhook, a misconfigured `NetworkPolicy` default, or a corrupt platform CRD reconciliation loop can wedge every namespace. Remediation must be designed to *fail closed on itself but fail open for tenants* (e.g. `failurePolicy: Ignore` on non-security webhooks so the platform's own outage cannot become the tenants' outage).
2. **Ownership ambiguity slows MTTR.** The single most expensive minutes of a platform incident are spent deciding *whose incident it is*. The remedy is structural: SLO-based signals that attribute degradation to a layer, plus a declared incident-command structure so triage is not a negotiation.
3. **The remediation itself is a change — and changes are the top cause of incidents.** DORA data consistently shows that most production incidents are triggered by a change. A rollback is *also* a change. Platform incident response therefore leans on **declarative, reversible, and increasingly automated** remediation: the fastest safe recovery is almost always "return the declared state of the system to a known-good version," not "hand-edit live objects."

The measurable goals are the four DORA reliability/throughput metrics and the two classic SRE ones:

- **MTTD** (mean time to *detect*) — driven by alerting quality (Section 2).
- **MTTR / failed-deployment recovery time** — driven by remediation automation (Sections 3–4).
- **Change failure rate** — driven by progressive delivery guardrails that *prevent* the incident.
- **Error budget burn** — the currency that decides whether you page a human at 3 a.m. or open a ticket for Monday.

> Core reference: *Google SRE Workbook — Alerting on SLOs* and *SRE Book — Managing Incidents*, cited in Section 6.

### The incident lifecycle a platform team must instrument

```
 detect ──▶ triage ──▶ mitigate ──▶ diagnose ──▶ remediate ──▶ review
   │           │            │            │            │           │
 SLO burn   incident     stop the     root-cause   restore     blameless
 alert      commander    bleeding     analysis     known-good  postmortem
            declared     (rollback,   (Section 5)  state       (feeds guardrails)
                          drain, PDB)
```

Two rules that the CNPA blueprint stresses and that the rest of this material builds on:

- **Mitigate before you diagnose.** Restore service first (roll back, shift traffic, drain a node), *then* find the root cause. The postmortem is where you learn; the incident is where you stop the bleeding.
- **Blameless post-incident review is a feedback loop, not paperwork.** Every incident should produce at least one *guardrail* (a new SLO alert, a policy, an automated remediation, a `PodDisruptionBudget`) so the same failure class cannot recur unnoticed.

---

## 2. Detection and triage: comparative design of the alerting layer

### 2.1 Threshold alerting vs. SLO burn-rate alerting

| Dimension | Static-threshold alert (`error_rate > 1%`) | Single-window burn-rate | **Multi-window, multi-burn-rate** (recommended) |
|---|---|---|---|
| False positives | High — noisy on transient spikes | Medium | **Low** — long *and* short window must both fire |
| Detection latency for slow burns | Poor — never trips on a low steady error rate that still exhausts budget | Good | **Good** — a low burn-rate ticket window catches it |
| Reset speed after recovery | Slow / manual | Slow (long window alone) | **Fast** — short window clears the alert quickly |
| Ties paging to user impact | No | Partially | **Yes** — pages proportional to error-budget consumption |
| Config complexity | Low | Low | Higher (worth it for platform-critical SLOs) |
| Alert fatigue | Severe | Moderate | **Minimal** |

The industry-standard design from the Google SRE Workbook: page fast when a large fraction of the *monthly* error budget would be consumed quickly; open a ticket for slow burns. For a **99.9%** availability SLO (error budget = 0.1% = `0.001`):

| Severity | Long window | Short window | Burn rate | Budget consumed if sustained | Action |
|---|---|---|---|---|---|
| `page` | 1h | 5m | 14.4× | 2% in 1h | wake on-call |
| `page` | 6h | 30m | 6× | 5% in 6h | wake on-call |
| `ticket` | 24h | 2h | 3× | 10% in 1d | business-hours ticket |
| `ticket` | 3d | 6h | 1× | 10% in 3d | business-hours ticket |

The **short window is the AND-guard**: it prevents an alert from firing on a burn that has already stopped, and it clears the alert quickly once recovery lands — critical for measuring MTTR honestly.

### 2.2 Remediation strategy comparison (the heart of topic 3.4)

| Strategy | Trigger | Recovery time | Blast radius / risk | When to use |
|---|---|---|---|---|
| **Self-healing probes** (`liveness`/`readiness`) | kubelet, continuous | seconds | per-Pod, contained | Always — baseline resilience |
| **`PodDisruptionBudget`** | during voluntary disruptions | prevents outage | protects availability | Always for HA workloads |
| **HPA / cluster-autoscaler** | load / resource pressure | seconds–minutes | node/pod scaling | Capacity-driven incidents |
| **`kubectl rollout undo`** | human, imperative | seconds | fast but *drifts from Git* | Break-glass only |
| **GitOps revert** (Argo CD / Flux) | `git revert` + reconcile | 1–3 min | auditable, no drift | **Default** for change-induced incidents |
| **Argo Rollouts auto-abort** | AnalysisRun failure | seconds, *pre-impact* | catches bad deploy at canary | **Prevents** the incident |
| **Operator/controller reconcile** | drift from desired state | continuous | scoped to CRD domain | Stateful/platform services |
| **Node remediation** (NPD + descheduler / cordon+drain) | node condition | minutes | node-scoped | Infra-layer faults |

Key trade-off to internalize for the exam: **imperative `kubectl rollout undo` is faster to type but creates configuration drift** — the live state no longer matches Git, so the GitOps controller will either fight you or the next sync will re-apply the broken version. In a GitOps-managed platform, the *correct* rollback is a `git revert` that the controller reconciles; `kubectl rollout undo` is a **break-glass** action you must immediately reconcile back into Git.

---

## 3. Manifests and infrastructure (complete, syntactically valid)

### 3.1 Multi-window, multi-burn-rate SLO alerts (`PrometheusRule`)

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: platform-api-slo
  namespace: platform-monitoring
  labels:
    release: kube-prometheus-stack
    role: slo-rules
spec:
  groups:
    # --- Recording rules: error ratio over each window ------------------
    - name: platform-api.slo.recording
      interval: 30s
      rules:
        - record: job:slo_errors_per_request:ratio_rate5m
          expr: |
            sum(rate(http_requests_total{job="platform-api",code=~"5.."}[5m]))
              /
            sum(rate(http_requests_total{job="platform-api"}[5m]))
        - record: job:slo_errors_per_request:ratio_rate30m
          expr: |
            sum(rate(http_requests_total{job="platform-api",code=~"5.."}[30m]))
              /
            sum(rate(http_requests_total{job="platform-api"}[30m]))
        - record: job:slo_errors_per_request:ratio_rate1h
          expr: |
            sum(rate(http_requests_total{job="platform-api",code=~"5.."}[1h]))
              /
            sum(rate(http_requests_total{job="platform-api"}[1h]))
        - record: job:slo_errors_per_request:ratio_rate6h
          expr: |
            sum(rate(http_requests_total{job="platform-api",code=~"5.."}[6h]))
              /
            sum(rate(http_requests_total{job="platform-api"}[6h]))

    # --- Alerting rules: SLO=99.9% -> error budget = 0.001 --------------
    - name: platform-api.slo.alerts
      rules:
        - alert: PlatformAPIErrorBudgetBurnFast
          # 14.4x burn: 2% of monthly budget in 1h. Long AND short window.
          expr: |
            job:slo_errors_per_request:ratio_rate1h > (14.4 * 0.001)
              and
            job:slo_errors_per_request:ratio_rate5m > (14.4 * 0.001)
          for: 2m
          labels:
            severity: page
            slo: platform-api-availability
            team: platform
          annotations:
            summary: "platform-api burning error budget fast (14.4x)"
            description: >
              1h burn {{ $value | humanizePercentage }} exceeds 14.4x.
              At this rate the 30-day error budget is gone in ~2 days.
            runbook_url: "https://runbooks.internal/platform-api/error-budget-burn"

        - alert: PlatformAPIErrorBudgetBurnSlow
          # 6x burn: 5% of monthly budget in 6h.
          expr: |
            job:slo_errors_per_request:ratio_rate6h > (6 * 0.001)
              and
            job:slo_errors_per_request:ratio_rate30m > (6 * 0.001)
          for: 15m
          labels:
            severity: page
            slo: platform-api-availability
            team: platform
          annotations:
            summary: "platform-api burning error budget (6x)"
            runbook_url: "https://runbooks.internal/platform-api/error-budget-burn"
```

### 3.2 Alertmanager: routing, escalation, inhibition, and silences-by-config

```yaml
apiVersion: monitoring.coreos.com/v1alpha1
kind: AlertmanagerConfig
metadata:
  name: platform-routing
  namespace: platform-monitoring
spec:
  route:
    receiver: 'platform-slack'          # default catch-all
    groupBy: ['alertname', 'slo', 'namespace']
    groupWait: 30s
    groupInterval: 5m
    repeatInterval: 4h
    routes:
      - matchers:
          - name: severity
            value: page
        receiver: 'platform-pagerduty'   # wake a human
        groupWait: 10s
        continue: true                   # also fan out to Slack for visibility
      - matchers:
          - name: severity
            value: page
        receiver: 'platform-slack'
  # Suppress noise: a critical page for an SLO silences the warning-level
  # symptoms of the same SLO so the on-call sees one incident, not twenty.
  inhibitRules:
    - sourceMatch:
        - name: severity
          value: page
      targetMatch:
        - name: severity
          value: warning
      equal: ['slo', 'namespace']
  receivers:
    - name: 'platform-pagerduty'
      pagerdutyConfigs:
        - routingKey:
            name: pagerduty-secret
            key: routingKey
          severity: critical
          description: '{{ .CommonAnnotations.summary }}'
    - name: 'platform-slack'
      slackConfigs:
        - apiURL:
            name: slack-webhook
            key: url
          channel: '#platform-incidents'
          title: '{{ .CommonAnnotations.summary }}'
          text: '{{ .CommonAnnotations.description }} | <{{ .CommonAnnotations.runbook_url }}|runbook>'
```

### 3.3 Baseline self-healing: startup / liveness / readiness probes + PDB

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: platform-api
  namespace: platform-system
spec:
  replicas: 4
  selector:
    matchLabels: { app: platform-api }
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 0          # never drop below desired during a rollout
      maxSurge: 1
  template:
    metadata:
      labels: { app: platform-api }
    spec:
      terminationGracePeriodSeconds: 45
      containers:
        - name: api
          image: registry.internal/platform-api:v1.42.0
          ports: [{ containerPort: 8080 }]
          # startupProbe shields a slow boot from liveness killing it early.
          startupProbe:
            httpGet: { path: /healthz, port: 8080 }
            failureThreshold: 30
            periodSeconds: 5      # up to 150s to start before liveness applies
          # livenessProbe restarts a wedged (deadlocked) container.
          livenessProbe:
            httpGet: { path: /healthz, port: 8080 }
            periodSeconds: 10
            failureThreshold: 3
          # readinessProbe pulls a not-ready Pod out of the Service endpoints
          # WITHOUT restarting it — the key to draining bad backends.
          readinessProbe:
            httpGet: { path: /readyz, port: 8080 }
            periodSeconds: 5
            failureThreshold: 2
          lifecycle:
            preStop:
              exec: { command: ["sh", "-c", "sleep 15"] }  # let LB deregister
          resources:
            requests: { cpu: 250m, memory: 256Mi }
            limits:   { memory: 512Mi }
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: platform-api-pdb
  namespace: platform-system
spec:
  # During voluntary disruptions (node drain, upgrade), keep >=3 of 4 up.
  minAvailable: 3
  selector:
    matchLabels: { app: platform-api }
```

**Why each probe matters in an incident:** `readinessProbe` is your *manual mitigation lever made automatic* — a Pod that fails readiness is removed from Service endpoints but not killed, so it stops taking traffic while you diagnose. `livenessProbe` handles the deadlock class. `startupProbe` prevents the classic false incident where liveness kills a slow-booting Pod into a `CrashLoopBackOff`. The `PDB` guarantees that a *voluntary* disruption (a node drain done as part of *another* remediation) cannot itself become an availability incident.

### 3.4 Preventing the incident: Argo Rollouts canary with automated abort

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: platform-api
  namespace: platform-system
spec:
  replicas: 4
  selector:
    matchLabels: { app: platform-api }
  template: {}   # same Pod template as the Deployment above (elided)
  strategy:
    canary:
      maxUnavailable: 0
      steps:
        - setWeight: 20
        - pause: { duration: 2m }
        - analysis:
            templates:
              - templateName: success-rate
        - setWeight: 50
        - pause: { duration: 5m }
        - analysis:
            templates:
              - templateName: success-rate
        - setWeight: 100
---
apiVersion: argoproj.io/v1alpha1
kind: AnalysisTemplate
metadata:
  name: success-rate
  namespace: platform-system
spec:
  args:
    - name: service
      value: platform-api
  metrics:
    - name: success-rate
      interval: 30s
      count: 4
      # If success rate drops below 99% the run FAILS -> Rollout auto-aborts
      # and shifts 100% of traffic back to the stable ReplicaSet.
      successCondition: result[0] >= 0.99
      failureLimit: 1
      provider:
        prometheus:
          address: http://prometheus.platform-monitoring.svc:9090
          query: |
            sum(rate(http_requests_total{job="{{args.service}}",code!~"5.."}[2m]))
              /
            sum(rate(http_requests_total{job="{{args.service}}"}[2m]))
```

This is the highest-leverage item in the topic: the cheapest incident is the one that never reaches full production traffic. A failed `AnalysisRun` **automatically aborts and rolls back** the canary — remediation before impact, with change-failure-rate driven toward zero.

---

## 4. CLI commands and real terminal output

### 4.1 Triage: what changed, what's failing

```console
$ kubectl get pods -n platform-system -l app=platform-api
NAME                            READY   STATUS             RESTARTS      AGE
platform-api-7d4f9c8b6-2xk9p    1/1     Running            0             6d
platform-api-7d4f9c8b6-8vqzt    1/1     Running            0             6d
platform-api-6c5b7f9d4-mn2xl    0/1     CrashLoopBackOff   5 (30s ago)   3m
platform-api-6c5b7f9d4-p4rqf    0/1     CrashLoopBackOff   5 (28s ago)   3m

$ kubectl get events -n platform-system --sort-by=.lastTimestamp | tail -6
34s   Warning   Unhealthy    pod/platform-api-6c5b7f9d4-mn2xl   Liveness probe failed: HTTP probe failed with statuscode: 500
30s   Warning   BackOff      pod/platform-api-6c5b7f9d4-mn2xl   Back-off restarting failed container api
2m    Normal    ScalingReplicaSet   deployment/platform-api    Scaled up replica set platform-api-6c5b7f9d4 to 2
```

The `ScalingReplicaSet` event names the culprit: a new ReplicaSet (`6c5b7f9d4`) — this is a change-induced incident.

### 4.2 Mitigate — GitOps rollback (the correct path)

```console
$ argocd app history platform-api
ID   DATE                           REVISION
40   2026-08-05 09:12:04 +0000 UTC  main (a1b2c3d)
41   2026-08-07 08:55:31 +0000 UTC  main (e4f5g6h)   <- current, broken

$ git revert e4f5g6h && git push
[main 9z8y7x6] Revert "bump platform-api to v1.42.0"

$ argocd app sync platform-api
TIMESTAMP          GROUP  KIND        NAMESPACE        NAME          STATUS    HEALTH
2026-08-07T09:03  apps    Deployment  platform-system  platform-api  Synced    Progressing
...
Application 'platform-api' synced successfully

$ argocd app get platform-api -o wide
Name:    platform-api    Sync Status:  Synced    Health Status:  Healthy
```

### 4.3 Break-glass — imperative rollback (creates drift; reconcile after)

```console
$ kubectl rollout history deployment/platform-api -n platform-system
REVISION  CHANGE-CAUSE
40        kubectl apply --record (v1.41.3)
41        kubectl apply --record (v1.42.0)

$ kubectl rollout undo deployment/platform-api -n platform-system --to-revision=40
deployment.apps/platform-api rolled back

$ kubectl rollout status deployment/platform-api -n platform-system
Waiting for deployment "platform-api" rollout to finish: 2 of 4 updated replicas are available...
deployment "platform-api" successfully rolled out
```

> **After a break-glass undo, immediately open the `git revert` so the GitOps controller does not re-apply v1.42.0 on its next sync.**

### 4.4 Argo Rollouts: watch the automated abort in action

```console
$ kubectl argo rollouts get rollout platform-api -n platform-system --watch
Name:            platform-api
Status:          ✖ Degraded
Message:         RolloutAborted: metric "success-rate" assessed Failed
Strategy:        Canary
  Step:          2/6
  SetWeight:     20
  ActualWeight:  0
Images:          platform-api:v1.41.3 (stable)
Replicas:
  Desired:       4
  Updated:       0
  Ready:         4
  Available:     4

$ kubectl argo rollouts abort platform-api -n platform-system   # manual, if needed
$ kubectl argo rollouts undo  platform-api -n platform-system   # revert Rollout spec
```

### 4.5 Reduce alert noise during an active incident (`amtool`)

```console
$ amtool silence add alertname="PlatformAPIErrorBudgetBurnFast" \
    --duration="1h" --comment="INC-482: mitigating via GitOps revert" \
    --author="oncall@platform"
b3d1f4a2-9c77-4e1b-8a55-0f2c6e9d1a34

$ amtool silence query
ID                                    MATCHERS                                         ENDS         COMMENT
b3d1f4a2-...                          alertname=PlatformAPIErrorBudgetBurnFast         in 59m       INC-482: mitigating via GitOps revert
```

---

## 5. Verification and failure diagnosis

### 5.1 Diagnose a running/failing Pod without killing evidence

Use an **ephemeral debug container** — it attaches to a running Pod's namespaces without restarting it, so you don't destroy the failing state:

```console
$ kubectl debug -n platform-system platform-api-6c5b7f9d4-mn2xl \
    -it --image=nicolaka/netshoot --target=api -- sh
/ # curl -s -o /dev/null -w "%{http_code}\n" localhost:8080/healthz
500
/ # nslookup postgres.platform-data.svc.cluster.local
;; connection timed out; no servers could be reached      # <- dependency DNS failure
```

For a `CrashLoopBackOff` where the container exits before you can attach, read the **previous** container's logs and the exit reason:

```console
$ kubectl logs -n platform-system platform-api-6c5b7f9d4-mn2xl --previous | tail -3
FATAL: could not connect to database "platform": connection refused

$ kubectl describe pod -n platform-system platform-api-6c5b7f9d4-mn2xl | grep -A3 'Last State'
    Last State:     Terminated
      Reason:       Error
      Exit Code:    1
```

`Exit Code: 137` (128+9, SIGKILL) with `Reason: OOMKilled` points at a memory limit; `Exit Code: 1` with an app log points at a dependency or config fault — a decisive triage fork.

### 5.2 Verify the remediation actually worked (don't declare victory early)

A rollback is only successful when **the SLO signal recovers**, not when the Pods are `Running`. Confirm across three layers:

```console
# 1) Workload converged to known-good
$ kubectl get rs -n platform-system -l app=platform-api \
    -o custom-columns=NAME:.metadata.name,IMAGE:.spec.template.spec.containers[0].image,READY:.status.readyReplicas
NAME                      IMAGE                              READY
platform-api-7d4f9c8b6    registry.internal/platform-api:v1.41.3   4
platform-api-6c5b7f9d4    registry.internal/platform-api:v1.42.0   0

# 2) PDB is satisfied (no ongoing availability risk)
$ kubectl get pdb platform-api-pdb -n platform-system
NAME               MIN AVAILABLE   ALLOWED DISRUPTIONS   AGE
platform-api-pdb   3               1                     18d

# 3) The SLO signal is recovering — the ONLY proof that matters
$ curl -s 'http://prometheus.platform-monitoring:9090/api/v1/query' \
    --data-urlencode 'query=job:slo_errors_per_request:ratio_rate5m' | jq -r '.data.result[0].value[1]'
0.0003        # 0.03% < 0.1% budget -> recovered
```

Then confirm the alert cleared and remove your silence so you regain coverage:

```console
$ amtool alert query alertname="PlatformAPIErrorBudgetBurnFast"
# (empty output = alert resolved)
$ amtool silence expire b3d1f4a2-9c77-4e1b-8a55-0f2c6e9d1a34
```

### 5.3 Common failure modes and their diagnostic signatures

| Symptom | Likely cause | First diagnostic | Remediation |
|---|---|---|---|
| `CrashLoopBackOff`, exit 1, app FATAL in logs | dependency/config regression from a deploy | `kubectl logs --previous` | GitOps revert |
| `CrashLoopBackOff`, exit 137 `OOMKilled` | memory limit too low / leak in new build | `describe pod` → Last State | raise limit *or* revert |
| Pods `Running` but Service returns 5xx | `readinessProbe` too loose; bad backend serving | `kubectl get endpoints`, `readyz` | tighten readiness / revert |
| Liveness kills slow-booting Pod | missing/short `startupProbe` | probe timings in `describe` | add `startupProbe` |
| Rollout stuck `Progressing`, never `Healthy` | `maxUnavailable:0` + no schedulable nodes | `kubectl get events`, pending Pods | scale nodes / fix quota |
| Node-wide Pod evictions | node condition (disk/PID pressure) | `kubectl describe node` conditions | cordon+drain+replace |
| Alert never fires despite outage | metric cardinality/scrape gap | `up{job=...}`, target health | fix ServiceMonitor |

### 5.4 Node-layer remediation (infra incidents)

```console
$ kubectl get nodes
NAME              STATUS                     ROLES    AGE   VERSION
node-pool-a-03    Ready,SchedulingDisabled   worker   40d   v1.31.4
node-pool-a-07    NotReady                   worker   40d   v1.31.4   # <- faulty

$ kubectl describe node node-pool-a-07 | grep -A2 Conditions | head -5
  Type             Status    Reason
  MemoryPressure   True      KubeletHasInsufficientMemory
  Ready            False     KubeletNotReady

# Respect PDBs while draining — this is why 3.3's PDB matters here
$ kubectl cordon node-pool-a-07
$ kubectl drain node-pool-a-07 --ignore-daemonsets --delete-emptydir-data --grace-period=45
evicting pod platform-system/platform-api-7d4f9c8b6-8vqzt
error when evicting pod "..." (will retry): Cannot evict pod as it would violate the pod disruption budget.
evicting pod platform-system/platform-api-7d4f9c8b6-8vqzt
pod/platform-api-7d4f9c8b6-8vqzt evicted     # proceeds once a replacement is Ready elsewhere
node/node-pool-a-07 drained
```

The `PodDisruptionBudget` from Section 3.3 is what forces the drain to *wait* for a healthy replacement rather than dropping below `minAvailable` — an automated remediation guardrail preventing your fix from causing a second incident.

---

## 6. References

- CNCF — *CNPA Curriculum* (exam blueprint, incident response competencies): https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf
- Google SRE Workbook — *Alerting on SLOs* (multi-window, multi-burn-rate): https://sre.google/workbook/alerting-on-slos/
- Google SRE Book — *Managing Incidents* (incident command, roles): https://sre.google/sre-book/managing-incidents/
- Google SRE Book — *Postmortem Culture: Learning from Failure*: https://sre.google/sre-book/postmortem-culture/
- Kubernetes — *Configure Liveness, Readiness and Startup Probes*: https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/
- Kubernetes — *Specifying a Disruption Budget* & *Disruptions*: https://kubernetes.io/docs/tasks/run-application/configure-pdb/ · https://kubernetes.io/docs/concepts/workloads/pods/disruptions/
- Kubernetes — *Rolling Back a Deployment*: https://kubernetes.io/docs/concepts/workloads/controllers/deployment/#rolling-back-a-deployment
- Kubernetes — *Debug Running Pods* (ephemeral containers, `kubectl debug`): https://kubernetes.io/docs/tasks/debug/debug-application/debug-running-pod/
- Kubernetes — *Safely Drain a Node*: https://kubernetes.io/docs/tasks/administer-cluster/safely-drain-node/
- Prometheus — *Alerting Rules*: https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/
- Prometheus Alertmanager — *Configuration* (routing, inhibition) & `amtool`: https://prometheus.io/docs/alerting/latest/configuration/ · https://github.com/prometheus/alertmanager#amtool
- Prometheus Operator — *PrometheusRule / AlertmanagerConfig* CRDs: https://prometheus-operator.dev/docs/developer/getting-started/
- Argo Rollouts — *Analysis & Progressive Delivery* (automated rollback): https://argo-rollouts.readthedocs.io/en/stable/features/analysis/
- Argo CD — *Rollback / App History*: https://argo-cd.readthedocs.io/en/stable/user-guide/commands/argocd_app_rollback/
- Kubernetes SIGs — *node-problem-detector* & *descheduler*: https://github.com/kubernetes/node-problem-detector · https://github.com/kubernetes-sigs/descheduler
- PagerDuty — *Incident Response Documentation* (roles, severities, comms): https://response.pagerduty.com/
- DORA — *Software Delivery & Operational Performance metrics*: https://dora.dev/guides/dora-metrics-four-keys/
- OpenSLO — *SLO/error-budget specification*: https://github.com/OpenSLO/OpenSLO