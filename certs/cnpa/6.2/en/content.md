# 6.2 DORA Metrics and Indicators for Platform Initiatives

> Domain 6 — Measuring your Platform · Exam weight for this competency: **4.0**
> Audience: Platform Architects / SRE building an Internal Developer Platform (IDP) on Kubernetes and needing a *defensible*, *automated*, *tamper-resistant* measurement layer for delivery performance and platform value.

---

## 1. Motivation and the production architectural problem

A platform team is a product team whose product is the paved road. The recurring failure mode is that the platform is *asserted* to be valuable ("we shipped Backstage, we adopted Argo CD") without a causal, quantitative link to the outcomes the business funds: faster, safer delivery. DORA (DevOps Research and Assessment) exists to close that gap with four keys that are (a) predictive of organizational performance, (b) balanced between throughput and stability, and (c) derivable from telemetry the platform already emits.

The four keys, plus the fifth (operational) metric:

| Metric | What it measures | Axis | Data lineage (where the event is born) |
|---|---|---|---|
| **Deployment Frequency (DF)** | How often you successfully release to production | Throughput | CD tool sync/rollout success → prod |
| **Lead Time for Changes (LT)** | Time from *code committed* to *code running in prod* | Throughput | git commit timestamp → deployment timestamp |
| **Change Failure Rate (CFR)** | % of deployments causing a degraded service requiring remediation | Stability | deployments ⋈ incidents/rollbacks |
| **Failed Deployment Recovery Time (FDRT)** *(renamed 2024 from "Time to Restore Service")* | Time to recover from a failed deployment | Stability | incident open → resolved, scoped to deploy-caused |
| **Reliability** *(5th metric, added 2021)* | Operational performance vs. SLO targets (availability, latency, correctness) | Operability | SLO/error budget from SLIs |

Source: DORA, *"The four keys"* — https://dora.dev/guides/dora-metrics-four-keys/ and *State of DevOps Report 2024* — https://dora.dev/research/2024/.

### 1.1 The architectural problem is a *data engineering* problem, not a dashboard problem

The hard part is not drawing four charts. It is:

1. **Event provenance.** A "deployment" is not a `git push`. It is a *successful promotion to the production environment*. On a GitOps platform the authoritative signal lives in the CD controller (Argo CD `OperationState.Phase == Succeeded`, Flux `Kustomization Ready`), not in CI. Counting CI pipeline runs inflates DF and corrupts every downstream ratio.
2. **Join correctness.** CFR and FDRT are *joins*: `deployments ⋈ incidents`. If deployments and incidents live in two systems with two clocks and two identity schemes (git SHA vs. incident tag vs. service name), the join is lossy and the metric silently biases toward "everything is fine."
3. **Attribution across a multi-tenant platform.** A platform serves N teams. A single global DF number is meaningless; you need per-`service`, per-`team`, per-`golden-path` cardinality without exploding Prometheus series or violating tenant isolation.
4. **Non-repudiation.** If a team can hand-edit the deployment log, the metric is theater. Events must originate from the control plane the team *cannot* bypass (the admission/deploy path), signed and immutable.

The reference architecture that satisfies all four is an **event-sourced pipeline**: control-plane emits **CloudEvents** → a collector normalizes → a warehouse/TSDB stores immutable facts → a metrics engine computes the four keys as *derived* views. Two dominant implementations: **Apache DevLake** (warehouse/ELT model, batch) and an **OpenTelemetry + Prometheus** model (streaming, TSDB). Google's **Four Keys** is the canonical reference design (webhook → Pub/Sub → BigQuery).

### 1.2 Why platforms need *more* than DORA — the indicator layer

DORA measures *delivery*. A platform initiative must also prove it improves *developer experience* and *reduces cognitive load*, otherwise you optimize DF by pushing toil onto product teams. The exam-relevant framing pairs DORA with **DevEx** and **SPACE**:

| Framework | Purpose | Representative indicators for a platform |
|---|---|---|
| **DORA** (4 keys + reliability) | Delivery performance outcome | DF, LT, CFR, FDRT, SLO attainment |
| **SPACE** | Multidimensional productivity (avoid single-metric gaming) | **S**atisfaction (eNPS/DevEx survey), **P**erformance (DORA), **A**ctivity (PRs, deploys), **C**ommunication/collaboration, **E**fficiency/flow (uninterrupted focus) |
| **DevEx** (Feedback loops, Cognitive load, Flow state) | Leading indicators of DORA | build/test feedback time, # of tools to ship a change, context switches |
| **Platform adoption** | Is the paved road actually used? | % services on golden path, self-service ratio, time-to-first-deploy (T2FD), onboarding lead time |

Sources: SPACE framework — https://queue.acm.org/detail.cfm?id=3454124 ; DevEx — https://queue.acm.org/detail.cfm?id=3595878 ; CNCF Platforms White Paper — https://tag-app-delivery.cncf.io/whitepapers/platforms/ ; CNCF Platform Engineering Maturity Model — https://tag-app-delivery.cncf.io/whitepapers/platform-eng-maturity-model/.

> **Golden rule for platform teams:** never report a throughput metric (DF, LT) without its paired stability metric (CFR, FDRT). The pairing is what makes DORA resistant to gaming — you cannot "improve" by deploying recklessly, because CFR/FDRT will move against you.

---

## 2. Technical comparisons and trade-offs

### 2.1 Performance clusters (benchmark, DORA 2023/2024)

Use these to *classify*, not to *target*. Ranges shift year to year; cite the report year.

| Metric | Elite | High | Medium | Low |
|---|---|---|---|---|
| Deployment Frequency | On-demand (multiple/day) | Once/day → once/week | Once/week → once/month | < once/month |
| Lead Time for Changes | < 1 day | 1 day → 1 week | 1 week → 1 month | 1 → 6 months |
| Change Failure Rate | ~5% | ~10% | ~15% | ~40–65% |
| Failed Deployment Recovery Time | < 1 hour | < 1 day | 1 day → 1 week | > 1 week |

Source: https://dora.dev/research/2024/ (clusters via cluster analysis; exact bounds vary by report edition).

### 2.2 Where do you source the "deployment" event? (throughput lineage)

| Source of DF/LT | Fidelity | Pros | Cons / failure mode |
|---|---|---|---|
| **CI pipeline "deploy" job** | Low | Trivial to hook | Counts *attempts*, not prod success; misses GitOps auto-sync; double counts on retries |
| **Argo CD `app-sync-succeeded` (Notifications)** | High | Authoritative prod signal; per-app cardinality; cannot be bypassed | Requires notifications controller; app≠service mapping needs labels |
| **Flux `Kustomization`/`HelmRelease` Ready event** | High | Native `Event` objects; GitOps truth | Ready≠healthy; must filter revision changes only |
| **Kubernetes `Deployment` `.status.observedGeneration` roll** | Medium | Works without CD tool | Noisy (HPA, config reloads); no git SHA without annotations |
| **OpenTelemetry CI/CD semconv (`cicd.pipeline.*`)** | High (emerging) | Vendor-neutral, spans carry SHA + duration | Semconv still *development* status; collector plumbing required |

### 2.3 Storage & compute engine trade-offs

| Approach | Model | Best for | Trade-offs |
|---|---|---|---|
| **Apache DevLake** | ELT into MySQL/PostgreSQL; pre-built DORA dbt-style transforms + Grafana | Multi-source correlation (GitHub/GitLab/Jira/Jenkins/Argo), historical backfill | Batch (minutes–hours latency); another stateful DB to run; heavier footprint |
| **OpenTelemetry Collector → Prometheus/Cortex/Mimir** | Streaming metrics; recording rules compute rates | Real-time DF/CFR on existing observability stack; low incremental cost | LT/joins awkward in PromQL; long-window LT needs a real DB or a histogram; high-cardinality risk |
| **Google Four Keys** | Webhook → Pub/Sub → Dataflow → BigQuery → Looker | Reference implementation, cloud-scale | GCP-coupled; ELT latency; not CNCF-native |
| **Keptn (KeptnMetric / Analysis)** | CRD-driven metric queries + SLO gates | *In-cluster* gating on DORA/SLO thresholds before promotion | Not a warehouse; complements, not replaces, storage |
| **Backstage plugin (DORA/DevLake/Roadie)** | Presentation over an underlying source | Developer-facing scorecards in the IDP portal | Only as good as the backing data source |

**Architectural recommendation:** stream **DF, CFR, Reliability** through OpenTelemetry→Prometheus for real-time SLO gating; run **DevLake** in parallel for **LT** and cross-tool CFR joins that need historical backfill and mutable late-arriving incident data. Surface both in Backstage.

---

## 3. Complete manifests and infrastructure (unabridged)

The pipeline below is production-shaped:

```
Argo CD sync-succeeded ┐
Flux Kustomization Ready├─(CloudEvents)→ OTel Collector ─→ Prometheus (DF, CFR, Reliability, recording rules)
git commit SHA + ts    ┘                    │
Incident (Alertmanager / PagerDuty) ────────┘─→ Apache DevLake (LT, CFR joins, backfill) ─→ Grafana / Backstage
```

### 3.1 CloudEvents deployment fact (the immutable event contract)

Every producer emits this exact schema. `type` and `subject` are the join keys.

```json
{
  "specversion": "1.0",
  "type": "dev.cncf.dora.deployment.finished.v1",
  "source": "/argocd/prod/checkout-api",
  "id": "b41f5d0a-3f7e-4a4a-9c2b-2b6c9c1e7a11",
  "time": "2026-08-07T14:32:07Z",
  "subject": "checkout-api",
  "datacontenttype": "application/json",
  "data": {
    "service": "checkout-api",
    "team": "payments",
    "golden_path": "grpc-service-v2",
    "environment": "production",
    "outcome": "succeeded",
    "revision": "9f3c1e2a7b4d5f60c8a1b2c3d4e5f6a7b8c9d0e1",
    "source_repo": "github.com/acme/checkout-api",
    "first_commit_time": "2026-08-07T13:58:41Z",
    "deploy_start_time": "2026-08-07T14:31:52Z",
    "deploy_end_time": "2026-08-07T14:32:07Z"
  }
}
```

### 3.2 Argo CD Notifications — emit the deployment event on sync success

`argocd-notifications-cm` in the `argocd` namespace. This is the *authoritative* DF/LT producer.

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-notifications-cm
  namespace: argocd
data:
  service.webhook.dora-collector: |
    url: http://otel-collector.observability.svc.cluster.local:8080/events
    headers:
      - name: Content-Type
        value: application/cloudevents+json
  template.dora-deploy-finished: |
    webhook:
      dora-collector:
        method: POST
        body: |
          {
            "specversion": "1.0",
            "type": "dev.cncf.dora.deployment.finished.v1",
            "source": "/argocd/{{.app.spec.destination.namespace}}/{{.app.metadata.name}}",
            "id": "{{.app.status.operationState.syncResult.revision}}-{{.app.status.operationState.finishedAt}}",
            "time": "{{.app.status.operationState.finishedAt}}",
            "subject": "{{index .app.metadata.labels "app.kubernetes.io/name"}}",
            "datacontenttype": "application/json",
            "data": {
              "service": "{{index .app.metadata.labels "app.kubernetes.io/name"}}",
              "team": "{{index .app.metadata.labels "platform.acme.io/team"}}",
              "golden_path": "{{index .app.metadata.labels "platform.acme.io/golden-path"}}",
              "environment": "{{.app.spec.destination.namespace}}",
              "outcome": "{{.app.status.operationState.phase}}",
              "revision": "{{.app.status.operationState.syncResult.revision}}",
              "source_repo": "{{.app.spec.source.repoURL}}",
              "deploy_start_time": "{{.app.status.operationState.startedAt}}",
              "deploy_end_time": "{{.app.status.operationState.finishedAt}}"
            }
          }
  trigger.on-prod-sync-succeeded: |
    - when: >
        app.status.operationState.phase in ['Succeeded'] and
        app.spec.destination.namespace == 'production'
      send: [dora-deploy-finished]
```

Subscribe an Application by annotation:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: checkout-api
  namespace: argocd
  labels:
    app.kubernetes.io/name: checkout-api
    platform.acme.io/team: payments
    platform.acme.io/golden-path: grpc-service-v2
  annotations:
    notifications.argoproj.io/subscribe.on-prod-sync-succeeded.dora-collector: ""
spec:
  project: payments
  source:
    repoURL: https://github.com/acme/checkout-api
    targetRevision: main
    path: deploy/prod
  destination:
    server: https://kubernetes.default.svc
    namespace: production
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

### 3.3 OpenTelemetry Collector — normalize events into Prometheus metrics

`otel-collector` receives CloudEvents on `:8080`, converts to a counter, and exposes it for Prometheus scraping. Uses the `webhookevent` receiver + `transform` processor.

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: otel-collector-config
  namespace: observability
data:
  collector.yaml: |
    receivers:
      webhookevent:
        endpoint: 0.0.0.0:8080
        path: /events
        health_path: /healthz
    processors:
      transform/dora:
        log_statements:
          - context: log
            statements:
              - set(attributes["service"], body["data"]["service"])
              - set(attributes["team"], body["data"]["team"])
              - set(attributes["golden_path"], body["data"]["golden_path"])
              - set(attributes["outcome"], body["data"]["outcome"])
              - set(attributes["revision"], body["data"]["revision"])
      # Emit a metric data point per deployment event
      logstometrics/dora:
        metrics:
          - name: dora_deployments_total
            description: "Deployment events reaching production"
            unit: "1"
            sum:
              value_type: int
              aggregation_temporality: cumulative
              is_monotonic: true
            attributes:
              - key: service
              - key: team
              - key: golden_path
              - key: outcome
      batch:
        timeout: 5s
    exporters:
      prometheus:
        endpoint: 0.0.0.0:9464
        enable_open_metrics: true
        resource_to_telemetry_conversion:
          enabled: true
      debug:
        verbosity: basic
    service:
      pipelines:
        logs:
          receivers: [webhookevent]
          processors: [transform/dora, logstometrics/dora, batch]
          exporters: [debug]
        metrics:
          receivers: [webhookevent]
          processors: [transform/dora, logstometrics/dora, batch]
          exporters: [prometheus]
```

Deployment + Service:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: otel-collector
  namespace: observability
spec:
  replicas: 2
  selector:
    matchLabels: {app: otel-collector}
  template:
    metadata:
      labels: {app: otel-collector}
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "9464"
    spec:
      containers:
        - name: otel-collector
          image: otel/opentelemetry-collector-contrib:0.109.0
          args: ["--config=/conf/collector.yaml"]
          ports:
            - {name: events, containerPort: 8080}
            - {name: metrics, containerPort: 9464}
          readinessProbe:
            httpGet: {path: /healthz, port: 8080}
          resources:
            requests: {cpu: 100m, memory: 128Mi}
            limits: {cpu: 500m, memory: 512Mi}
          volumeMounts:
            - {name: conf, mountPath: /conf}
      volumes:
        - name: conf
          configMap: {name: otel-collector-config}
---
apiVersion: v1
kind: Service
metadata:
  name: otel-collector
  namespace: observability
spec:
  selector: {app: otel-collector}
  ports:
    - {name: events, port: 8080, targetPort: 8080}
    - {name: metrics, port: 9464, targetPort: 9464}
```

### 3.4 Prometheus recording rules — compute the four keys

`PrometheusRule` CRD (Prometheus Operator). `dora_deployment_failed_total` is fed by CFR remediation events (rollback/hotfix) using the same webhook contract with `type=dev.cncf.dora.remediation.v1`.

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: dora-metrics
  namespace: observability
  labels:
    release: kube-prometheus-stack
spec:
  groups:
    - name: dora.throughput
      interval: 30s
      rules:
        # Deployment Frequency: successful prod deploys per day, per service
        - record: dora:deployment_frequency:per_day
          expr: |
            sum by (service, team, golden_path) (
              increase(dora_deployments_total{outcome="Succeeded"}[1d])
            )
        # Rolling 7d deploys/day for cluster classification
        - record: dora:deployment_frequency:rate7d
          expr: |
            sum by (service, team) (
              rate(dora_deployments_total{outcome="Succeeded"}[7d]) * 86400
            )
    - name: dora.stability
      interval: 30s
      rules:
        # Change Failure Rate = failed deploys / total deploys (28d window)
        - record: dora:change_failure_rate:28d
          expr: |
            sum by (service, team) (increase(dora_deployment_failed_total[28d]))
            /
            clamp_min(
              sum by (service, team) (increase(dora_deployments_total{outcome="Succeeded"}[28d])),
              1
            )
        # Failed Deployment Recovery Time (mean seconds), fed by remediation events
        - record: dora:fdrt:mean_seconds:28d
          expr: |
            sum by (service, team) (increase(dora_deployment_recovery_seconds_sum[28d]))
            /
            clamp_min(sum by (service, team) (increase(dora_deployment_recovery_seconds_count[28d])), 1)
    - name: dora.reliability
      interval: 30s
      rules:
        # Reliability (5th metric): SLO attainment = good/total over 28d
        - record: dora:reliability:availability_slo:28d
          expr: |
            sum by (service) (increase(http_requests_total{code!~"5..",environment="production"}[28d]))
            /
            clamp_min(sum by (service) (increase(http_requests_total{environment="production"}[28d])), 1)
    - name: dora.alerts
      rules:
        # Alert when a service crosses out of the "Elite" CFR band
        - alert: DoraChangeFailureRateHigh
          expr: dora:change_failure_rate:28d > 0.15
          for: 1h
          labels: {severity: warning}
          annotations:
            summary: "CFR {{ $value | humanizePercentage }} for {{ $labels.service }}"
            runbook: "https://backstage.acme.io/docs/default/component/{{ $labels.service }}/dora"
```

### 3.5 Lead Time — Apache DevLake (git ⋈ deploy join, backfill-capable)

DevLake ingests git + Argo/Jenkins + incidents and computes LT natively. Helm-installable; the DORA transformation is a built-in blueprint. Minimal values and the blueprint scope:

```yaml
# values.yaml for the apache/devlake Helm chart
mysql:
  storage: 10Gi
  rootPassword: "REDACTED-use-a-Secret"
grafana:
  enabled: true          # ships the pre-built "DORA" dashboard
lake:
  replicaCount: 1
  resources:
    requests: {cpu: 250m, memory: 512Mi}
    limits:   {cpu: "1",  memory: 1Gi}
config-ui:
  ingress:
    enabled: true
    host: devlake.acme.io
```

DevLake DORA scope (POSTed to its API or set in the UI): map each deployment to a git repo so `lead_time = deploy_finished_time − first_commit_time`, honoring squash-merge caveats:

```json
{
  "name": "payments-dora-blueprint",
  "mode": "NORMAL",
  "enable": true,
  "cronConfig": "0 */2 * * *",
  "connections": [
    {
      "plugin": "github",
      "connectionId": 1,
      "scopes": [{ "id": "acme/checkout-api", "name": "checkout-api" }],
      "scopeConfig": {
        "deploymentPattern": "(?i)deploy",
        "productionPattern": "(?i)prod",
        "transformationRules": {
          "prType": "type/(.*)$",
          "prComponent": "component/(.*)$",
          "deploymentPattern": "prod-deploy"
        }
      }
    },
    {
      "plugin": "webhook",
      "connectionId": 2,
      "comment": "Argo CD deployments pushed as DevLake incoming deployments"
    }
  ]
}
```

Push each Argo deployment to DevLake's incoming-webhook so LT joins on the SHA:

```yaml
# additional Argo CD notifications webhook target → DevLake
service.webhook.devlake: |
  url: https://devlake.acme.io/api/plugins/webhook/1/deployments
  headers:
    - name: Authorization
      value: "Bearer $devlake-token"
    - name: Content-Type
      value: application/json
```

### 3.6 In-cluster DORA/SLO gate — Keptn Metrics + Analysis

Block a promotion if the target service is already outside its stability band. Keptn `KeptnMetric` queries Prometheus; `AnalysisDefinition` scores it.

```yaml
apiVersion: metrics.keptn.sh/v1
kind: KeptnMetric
metadata:
  name: checkout-cfr-28d
  namespace: production
spec:
  provider:
    name: prometheus-provider
  query: 'dora:change_failure_rate:28d{service="checkout-api"}'
  fetchIntervalSeconds: 60
---
apiVersion: metrics.keptn.sh/v1
kind: AnalysisDefinition
metadata:
  name: dora-promotion-gate
  namespace: production
spec:
  objectives:
    - analysisValueTemplate: {name: checkout-cfr-28d}
      target:
        failure:
          greaterThan: {fixedValue: "0.15"}   # >15% CFR fails the gate
        warning:
          greaterThan: {fixedValue: "0.05"}   # >5% warns (out of Elite band)
      weight: 10
      keyObjective: true
  totalScore:
    passPercentage: 90
    warningPercentage: 75
```

### 3.7 Reliability as an SLO (OpenSLO / Sloth)

The 5th metric is an SLO. Generate Prometheus rules from an OpenSLO spec with Sloth:

```yaml
apiVersion: sloth.slok.dev/v1
kind: PrometheusServiceLevel
metadata:
  name: checkout-api-slo
  namespace: observability
spec:
  service: "checkout-api"
  labels: {team: "payments"}
  slos:
    - name: "availability"
      objective: 99.9
      description: "Reliability metric feeding DORA operational performance"
      sli:
        events:
          errorQuery: sum(rate(http_requests_total{service="checkout-api",environment="production",code=~"5.."}[{{.window}}]))
          totalQuery: sum(rate(http_requests_total{service="checkout-api",environment="production"}[{{.window}}]))
      alerting:
        name: CheckoutAPIErrorBudgetBurn
        pageAlert:   {labels: {severity: critical}}
        ticketAlert: {labels: {severity: warning}}
```

---

## 4. CLI commands and real terminal output

### 4.1 Confirm the deployment event fired from Argo CD

```console
$ kubectl -n argocd logs deploy/argocd-notifications-controller | grep -i checkout-api | tail -3
time="2026-08-07T14:32:08Z" level=info msg="Trigger on-prod-sync-succeeded result: [{[0].dora-collector [dora-deploy-finished] true}]" resource=argocd/checkout-api
time="2026-08-07T14:32:08Z" level=info msg="Notification 'dora-deploy-finished' delivered via 'dora-collector'" resource=argocd/checkout-api
time="2026-08-07T14:32:08Z" level=info msg="Sending webhook to http://otel-collector.observability.svc.cluster.local:8080/events"
```

### 4.2 Verify the collector turned it into a metric

```console
$ kubectl -n observability port-forward svc/otel-collector 9464:9464 >/dev/null 2>&1 &
$ curl -s localhost:9464/metrics | grep dora_deployments_total
# HELP dora_deployments_total Deployment events reaching production
# TYPE dora_deployments_total counter
dora_deployments_total{service="checkout-api",team="payments",golden_path="grpc-service-v2",outcome="Succeeded"} 47
dora_deployments_total{service="ledger-api",team="payments",golden_path="grpc-service-v2",outcome="Succeeded"} 12
```

### 4.3 Query the four keys with promtool

```console
$ promtool query instant http://prometheus.observability:9090 'dora:deployment_frequency:rate7d{service="checkout-api"}'
dora:deployment_frequency:rate7d{service="checkout-api", team="payments"} => 6.714285714285714 @[1754577127]
```

```console
$ promtool query instant http://prometheus.observability:9090 'dora:change_failure_rate:28d{service="checkout-api"}'
dora:change_failure_rate:28d{service="checkout-api", team="payments"} => 0.0425531914893617 @[1754577140]
```

Interpretation: ~6.7 successful prod deploys/day (Elite DF) and CFR ≈ 4.3% (Elite CFR band). Throughput *and* stability are both in-band — the platform is not being gamed.

### 4.4 Compute Lead Time from git independently (spot-check DevLake)

Squash-merges collapse the first-commit timestamp; this script recovers it from the PR's first commit and joins on the deployed SHA.

```console
$ DEPLOY_SHA=9f3c1e2a7b4d5f60c8a1b2c3d4e5f6a7b8c9d0e1
$ DEPLOY_TS=$(date -u -d '2026-08-07T14:32:07Z' +%s)
$ FIRST_COMMIT_TS=$(git -C ./checkout-api log --format=%ct --reverse \
    $(git merge-base main $DEPLOY_SHA)..$DEPLOY_SHA | head -1)
$ echo "lead_time_seconds=$(( DEPLOY_TS - FIRST_COMMIT_TS ))"
lead_time_seconds=2006
$ python3 -c "print(f'lead_time = {2006/60:.1f} min')"
lead_time = 33.4 min
```

### 4.5 Confirm the promotion gate blocks an out-of-band service

```console
$ kubectl -n production get analysis dora-promotion-gate-checkout -o jsonpath='{.status}' | jq
{
  "state": "Completed",
  "warning": false,
  "pass": false,
  "totalScore": "0/10",
  "raw": "{\"objectiveResults\":[{\"value\":0.19,\"score\":0,\"keyObjective\":true,\"error\":\"\",\"failed\":true}]}"
}
$ echo "gate result: $(kubectl -n production get analysis dora-promotion-gate-checkout -o jsonpath='{.status.pass}')"
gate result: false
```

CFR is 19% (> 0.15 failure threshold) → key objective failed → promotion blocked.

### 4.6 DevLake DORA API readout

```console
$ curl -s -H "Authorization: Bearer $DEVLAKE_TOKEN" \
    'https://devlake.acme.io/api/dora/metrics?project=payments&window=P28D' | jq
{
  "deployment_frequency": "On-demand (Elite)",
  "median_lead_time_for_changes_minutes": 41,
  "change_failure_rate": 0.061,
  "median_time_to_restore_service_minutes": 38,
  "sample": { "deployments": 188, "incidents": 12 }
}
```

---

## 5. Verification and failure diagnosis

### 5.1 The seven classic distortions and how to detect them

| Symptom | Likely root cause | Diagnostic | Fix |
|---|---|---|---|
| **DF is 3–5× too high** | Counting CI runs / auto-sync retries / config reloads, not prod releases | `curl :9464/metrics` — is the counter incremented on non-revision syncs? Check `outcome` label distribution | Filter to `outcome="Succeeded"` **and** revision change; source from CD, never CI |
| **DF drops to zero after a "successful" deploy** | Webhook silently dropped (collector 5xx, wrong path, NetworkPolicy) | `kubectl logs argocd-notifications-controller`; `kubectl -n observability logs deploy/otel-collector` for receiver errors | Add readiness gating; alert on `absent(dora_deployments_total)`; open egress in NetworkPolicy |
| **Lead Time absurdly small** | Squash-merge collapsed commit history to one timestamp at merge | Compare DevLake LT vs. the §4.4 git spot-check | Recover first-commit time via `merge-base`; or measure from PR *open* time |
| **Lead Time absurdly large** | Long-lived feature branch or a SHA that never matched a deploy join | DevLake shows `null` deploy for the commit | Fix `deploymentPattern`/`productionPattern`; ensure Argo pushes SHA to DevLake |
| **CFR stuck near 0%** | Incidents not joined to deployments (clock skew, tag mismatch, service-name mismatch) | `sample.incidents` in §4.6 is 0 while you know there were rollbacks | Standardize `service` identity + UTC timestamps across producers; verify remediation webhook fires |
| **CFR > 100% or NaN** | Denominator = 0 (no successful deploys in window) | PromQL returns `+Inf` | `clamp_min(denominator, 1)` (already in §3.4) |
| **FDRT missing** | No remediation/incident-resolved event; only the *failure* is recorded | `dora_deployment_recovery_seconds_count` is empty | Emit `incident.resolved` events; close the loop on both ends |

### 5.2 Prove the join is correct (the highest-value check)

CFR and FDRT are only trustworthy if `deployments ⋈ incidents` loses nothing. Assert reconciliation:

```console
$ curl -s :9464/metrics | grep -c 'dora_deployments_total.*Succeeded'   # sources emitting
2
$ promtool query instant http://prometheus.observability:9090 \
    'count(count by (service)(dora_deployments_total)) == bool count(count by (service)(dora:reliability:availability_slo:28d))'
{} => 1 @[1754577200]     # every deploying service also has a reliability series → no orphans
```

### 5.3 Detect a stalled event pipeline before it silently zeroes your metrics

A dead webhook makes DF look like "we stopped deploying" — indistinguishable from a real freeze. Guard it:

```yaml
- alert: DoraDeploymentPipelineStalled
  expr: |
    (time() - max(dora_deployments_last_event_timestamp_seconds)) > 86400
    and on() (hour() > 8 < 20)     # only during working hours
  for: 30m
  labels: {severity: warning}
  annotations:
    summary: "No DORA deployment events ingested in 24h — check Argo notifications → collector path"
```

### 5.4 Verify the collector receiver and metric conversion end-to-end

```console
$ curl -s -X POST http://localhost:8080/events \
    -H 'Content-Type: application/cloudevents+json' \
    -d '{"specversion":"1.0","type":"dev.cncf.dora.deployment.finished.v1","source":"/test","id":"t1","time":"2026-08-07T15:00:00Z","subject":"canary","data":{"service":"canary","team":"platform","golden_path":"test","outcome":"Succeeded","revision":"deadbeef"}}'
$ sleep 6 && curl -s localhost:9464/metrics | grep 'service="canary"'
dora_deployments_total{service="canary",team="platform",golden_path="test",outcome="Succeeded"} 1
```

If the synthetic event does not appear within the batch window, the fault is in the collector (receiver/transform), not the producers — bisected in one command.

### 5.5 Anti-gaming and validity checklist for a platform initiative

- **Pair every metric.** Reject any dashboard that shows DF/LT without CFR/FDRT on the same row.
- **No local vanity aggregates.** Report per-`service`/`team` with medians (LT/FDRT are skewed — never use the mean as the headline; the mean is stored only for alert math).
- **Baseline before/after.** Capture 8–12 weeks pre-platform to make the platform's effect *causal*, not anecdotal.
- **Cardinality budget.** Keep DF/CFR label set to `{service, team, golden_path, outcome}`; never add `revision` as a metric label (unbounded) — it belongs in the event store, not the TSDB.
- **Complement DORA with adoption + DevEx.** A rising DF with falling developer-satisfaction (SPACE/DevEx survey) means you shifted toil onto teams — surface both.

---

## 6. References

- DORA — The four keys (metric definitions): https://dora.dev/guides/dora-metrics-four-keys/
- DORA — State of DevOps Report 2024 (performance clusters, "Failed Deployment Recovery Time" rename): https://dora.dev/research/2024/
- DORA — Reliability as the fifth metric: https://dora.dev/guides/dora-metrics-four-keys/#reliability
- CNCF App Delivery TAG — Platforms White Paper (measuring platform value): https://tag-app-delivery.cncf.io/whitepapers/platforms/
- CNCF — Platform Engineering Maturity Model: https://tag-app-delivery.cncf.io/whitepapers/platform-eng-maturity-model/
- CNPA Curriculum (CNCF): https://github.com/cncf/curriculum
- SPACE framework (Forsgren et al., ACM Queue): https://queue.acm.org/detail.cfm?id=3454124
- DevEx framework (Noda, Storey, Forsgren et al., ACM Queue): https://queue.acm.org/detail.cfm?id=3595878
- Google Cloud — Four Keys reference implementation: https://github.com/dora-team/fourkeys
- Apache DevLake (DORA metrics engine): https://devlake.apache.org/docs/DORA
- Argo CD Notifications (triggers, templates, webhooks): https://argo-cd.readthedocs.io/en/stable/operator-manual/notifications/
- OpenTelemetry — CI/CD semantic conventions: https://opentelemetry.io/docs/specs/semconv/cicd/
- OpenTelemetry Collector Contrib (webhookevent receiver, transform processor): https://github.com/open-telemetry/opentelemetry-collector-contrib
- Prometheus Operator — PrometheusRule / recording rules: https://prometheus-operator.dev/docs/user-guides/recording-rules/
- Keptn — Metrics & Analysis (KeptnMetric, AnalysisDefinition): https://keptn.sh/stable/docs/reference/api-reference/metrics/
- Sloth / OpenSLO (Reliability SLO generation): https://sloth.dev/ · https://openslo.com/
- Backstage — DORA/DevLake plugins: https://backstage.io/docs/features/software-catalog/ · https://devlake.apache.org/docs/DORA

---

*Note on delivery:* this session has no filesystem tools available, so I could not write this to `certs/cnpa/6.2/en/content.md` myself — the material above is the full topic body, ready to be saved to that path (and to seed `exercises.md` / `lab/` and the `es` translation via `teach cert translate`, per the workflow).