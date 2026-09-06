# 3.4 Describe monitoring tools in Azure

**Certification:** AZ-900 — Microsoft Azure Fundamentals (exam version 2026-07-20)
**Domain:** 3 — Describe Azure management and governance
**Objective weight:** 8.33
**Profile:** Principal Platform Architect / Senior SRE
**Authoring language:** English

---

## 0. What the exam asks vs. what production demands

The AZ-900 study guide states this objective as three bullets:

| Exam bullet | Minimum exam answer | What a Platform Architect must actually be able to design |
|---|---|---|
| Describe the purpose of Azure Advisor | "Personalized best-practice recommendations" | Advisor Score as an SLO input; automating Reliability recommendations into backlog items via Activity Log alerts on `Category=Recommendation` |
| Describe Azure Service Health | "Health of Azure services and your resources" | The three-tier split (Azure Status / Service Health / Resource Health), scoped Activity Log alerts, and why Resource Health is the only tier that is *your-resource* specific |
| Describe Azure Monitor, including Log Analytics, Azure Monitor alerts, and Application Insights | "Collects and analyzes telemetry" | A full telemetry pipeline: ingestion paths, table plans, retention tiers, cardinality and cost control, correlation, alert state machines, and a diagnosis playbook when telemetry silently stops |

The exam tests recognition. Production tests **whether telemetry survives the incident that needs it**. This material is written for the second bar; the exam-mapping table in §14 collapses it back to the first.

---

## 1. The architectural problem

### 1.1 The failure mode that motivates everything

A platform team runs 140 microservices on three AKS clusters, 60 VM scale sets, Azure SQL, Service Bus, and an Application Gateway. At 03:14 the checkout flow starts returning HTTP 502 for 8% of requests. The on-call engineer opens the portal and finds:

- **Application Gateway metrics** show `FailedRequests` rising — but metrics have no request identity, so they cannot say *which* backend, *which* tenant, or *which* code path.
- **AKS container logs** are there — but the workspace hit its daily cap at 02:50 and ingestion stopped. There is a gap exactly across the incident.
- **Application Insights** shows the failures — but adaptive sampling dropped 94% of the telemetry under load, and the surviving items lack the dependency spans.
- **Service Health** shows nothing, because the alert was scoped to the wrong subscription.
- Six alerts fired at once, all pointing at the same root cause, all paging the same three people.

Every one of those is a **design** failure, not a tooling failure. Azure Monitor gave the correct answer to the question it was configured to answer.

### 1.2 The four questions a monitoring platform must answer

| # | Question | Signal class | Azure surface | Latency budget |
|---|---|---|---|---|
| 1 | *Is the platform itself broken?* | Provider health | **Azure Service Health** + **Resource Health** | seconds–minutes (provider-driven) |
| 2 | *Is my resource breaching a numeric threshold right now?* | Metrics (time series) | **Azure Monitor Metrics**, **Managed Prometheus** | ~30–120 s end-to-end |
| 3 | *What exactly happened, to which request, in which order?* | Logs + traces (events) | **Log Analytics**, **Application Insights** | ~1–5 min typical ingestion latency |
| 4 | *Am I configured badly in a way that will hurt me later?* | Posture / advice | **Azure Advisor**, Defender for Cloud, Azure Policy | hours–days |

A design that cannot answer all four is not observable, it is merely instrumented. Note the asymmetry: **questions 1 and 4 are answered by Azure about Azure**; questions 2 and 3 are answered by *your* pipeline about *your* workload, and only if you built it.

### 1.3 Control plane vs. data plane telemetry

This distinction is the single most common source of "the logs aren't there" in Azure, and it is not obvious from the portal.

```
                         ┌───────────────────────────────────────────┐
   ARM operations        │            CONTROL PLANE                  │
   (create/delete/       │  Activity Log  — subscription-scoped      │
    scale/RBAC/policy)   │  ON BY DEFAULT, 90 days free              │
                         │  Categories: Administrative, ServiceHealth,│
                         │  ResourceHealth, Alert, Autoscale,        │
                         │  Recommendation, Policy, Security         │
                         └───────────────────────────────────────────┘
                                          ║
                                          ║  diagnostic setting (subscription level)
                                          ▼
   ┌──────────────────────────────────────────────────────────────────────┐
   │                          DATA PLANE                                  │
   │                                                                      │
   │  Platform metrics      → ON by default, 93-day retention, free       │
   │  Resource logs         → OFF by default. Nothing is stored until you │
   │                          create a diagnostic setting on the resource │
   │  Guest OS perf/logs    → OFF. Requires Azure Monitor Agent + a DCR   │
   │  Application telemetry → OFF. Requires SDK / OTel / auto-instrument  │
   │  Custom app data       → Logs Ingestion API + DCR + custom table     │
   └──────────────────────────────────────────────────────────────────────┘
```

> **Rule to internalize:** *Platform metrics are opt-out. Everything else is opt-in.* A brand-new subscription with 200 resources and zero diagnostic settings has exactly one useful log source: the Activity Log.

### 1.4 Reference architecture

```
 ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌──────────────┐  ┌───────────┐
 │ Azure PaaS  │  │  VMs / VMSS │  │ AKS cluster │  │ Applications │  │ Non-Azure │
 │ (SQL, SB,   │  │  Arc servers│  │             │  │ (.NET/Java/  │  │ (on-prem, │
 │  AppGW, KV) │  │             │  │             │  │  Py/Node/Go) │  │  other    │
 └──────┬──────┘  └──────┬──────┘  └──────┬──────┘  └──────┬───────┘  │  clouds)  │
        │                │                │                │          └─────┬─────┘
        │ diagnostic     │ Azure Monitor  │ ama-logs DS    │ App Insights   │ Azure Arc
        │ setting        │ Agent (AMA)    │ ama-metrics    │ SDK / OTel     │ + AMA
        │                │  + DCR/DCE     │  + DCR         │ Distro         │
        ▼                ▼                ▼                ▼                ▼
 ╔══════════════════════════════════════════════════════════════════════════════════╗
 ║                        A Z U R E   M O N I T O R                                 ║
 ║                                                                                  ║
 ║  ┌───────────────────────┐   ┌────────────────────────┐  ┌────────────────────┐  ║
 ║  │  Metrics store        │   │  Log Analytics         │  │ Azure Monitor      │  ║
 ║  │  (time series DB)     │   │  workspace             │  │ workspace          │  ║
 ║  │  93-day, 1-min grain  │   │  (Azure Data Explorer  │  │ (Prometheus TSDB,  │  ║
 ║  │  dimensioned          │   │   engine, KQL)         │  │  PromQL, 18 months)│  ║
 ║  │                       │   │  Analytics / Basic /   │  │                    │  ║
 ║  │                       │   │  Auxiliary table plans │  │                    │  ║
 ║  └───────────┬───────────┘   └───────────┬────────────┘  └─────────┬──────────┘  ║
 ║              │                           │                         │             ║
 ║              └───────────┬───────────────┴─────────────┬───────────┘             ║
 ║                          ▼                             ▼                         ║
 ║              ┌───────────────────────┐     ┌──────────────────────────┐          ║
 ║              │  Alerts               │     │  Visualization           │          ║
 ║              │  metric / log /       │     │  Workbooks, Dashboards,  │          ║
 ║              │  activity log /       │     │  Managed Grafana,        │          ║
 ║              │  Prometheus / health  │     │  Power BI                │          ║
 ║              └───────────┬───────────┘     └──────────────────────────┘          ║
 ╚══════════════════════════╪═══════════════════════════════════════════════════════╝
                            ▼
              ┌──────────────────────────────┐
              │  Action groups               │
              │  email / SMS / push / voice  │
              │  webhook / secure webhook    │
              │  Logic App / Function /      │
              │  Automation runbook / ITSM / │
              │  Event Hub                   │
              └──────────────────────────────┘
                            │
              ┌─────────────┴──────────────┐
              │ Alert processing rules     │  ← suppression windows, action override
              └────────────────────────────┘

 ── Out-of-band, provider-driven ──────────────────────────────────────────────────
   Azure Status (public)  →  Service Health (subscription)  →  Resource Health (resource)
   Azure Advisor (posture: Reliability / Security / Performance / Cost / OpEx)
```

---

## 2. The Azure Monitor data model

### 2.1 Metrics vs. Logs — the decision that drives cost and capability

| Dimension | **Metrics** | **Logs (Log Analytics)** |
|---|---|---|
| Shape | Numeric time series: `(timestamp, value, dimensions[])` | Typed rows, arbitrary columns, including text and dynamic JSON |
| Store | Purpose-built TSDB | Azure Data Explorer engine |
| Query language | Metrics Explorer / REST / PromQL (Managed Prometheus) | **KQL** |
| Ingestion latency | ~30–120 s typical | ~1–5 min typical, can exceed under load |
| Retention | 93 days (platform metrics), fixed | 30 days default → 730 days interactive; up to 12 years long-term |
| Cost | Platform metrics free; custom metrics billed per time series | Billed per GB ingested + retention beyond the free window |
| Cardinality tolerance | **Low.** Dimensions are bounded; high-cardinality (per-request-ID) destroys the model | **High.** Cardinality is a query concern, not a storage concern |
| Aggregation | Pre-aggregated at write time (Avg/Min/Max/Sum/Count) | Aggregated at query time, so you can change the question later |
| Best for | Thresholds, autoscale, dashboards, SLI numerators/denominators | Root cause, forensics, correlation, audit, compliance |
| Alert latency | Best — near real time, 1-minute granularity | Worse — bounded by ingestion latency + evaluation frequency |
| Failure mode | You cannot ask a question you did not pre-dimension | You pay for questions you never ask |

**Architectural rule:** *alert on metrics, diagnose on logs.* Paging on a log search alert for a symptom that has a metric equivalent adds 2–6 minutes of ingestion latency to your MTTA for no benefit.

### 2.2 Log Analytics table plans

Choosing the plan per table is the highest-leverage cost lever in the whole platform.

| | **Analytics** | **Basic** | **Auxiliary** |
|---|---|---|---|
| Ingestion cost | Baseline (1.0×) | ~0.25× baseline | ~0.02× baseline |
| Query cost | Included | **Billed per GB scanned** | **Billed per GB scanned** |
| Interactive retention | 30 days default (configurable 4–730; 90 free for App Insights & Sentinel tables) | 30 days, fixed | 30 days, fixed |
| Long-term retention | Up to 12 years | Up to 12 years | Up to 12 years |
| KQL surface | Full language | Restricted subset (no `join` across tables, limited operators) | Restricted subset |
| Query performance | Optimized, indexed | Slower | Slowest (unindexed) |
| Log search alerts | ✅ Supported | ❌ Not supported | ❌ Not supported |
| Microsoft Sentinel | ✅ | Partial | Ingest-only |
| Correct use | Signals you alert on, join, or dashboard | Verbose but occasionally-needed: firewall flow logs, IIS/NGINX access logs, `ContainerLogV2` chatter | Compliance-only archives: CDN logs, audit dumps you must keep but will query twice a year |

> **Trap:** switching a table to Basic silently breaks every log search alert on it, with no error at switch time. Audit alert rules **before** re-planing a table.

### 2.3 Diagnostic setting destinations

Each resource supports up to **5 diagnostic settings**, each with its own destination set.

| Destination | Query surface | Retention model | Typical cost profile | Use when |
|---|---|---|---|---|
| **Log Analytics workspace** | KQL, alerts, workbooks, Sentinel | Per-table plan + retention | Highest per GB | You will actually query it |
| **Storage account** | None natively (blob download, or ADX external table) | Lifecycle management policy | Lowest per GB | Long compliance holds, cheap archive |
| **Event Hub** | Streaming consumer | Retention 1–7 days (up to 90 on Premium/Dedicated) | Throughput-unit based | SIEM off-Azure (Splunk, QRadar), real-time fan-out |
| **Partner solution** | Vendor's | Vendor's | Vendor's | Datadog / Elastic / Dynatrace native integration |

A common production pattern is **two settings on the same resource**: one to Log Analytics with only the categories you alert on, and one to Storage with `allLogs` for the compliance archive at ~2% of the cost.

### 2.4 `AzureDiagnostics` vs. resource-specific mode

Older resource types write into the single wide `AzureDiagnostics` table, which has a hard limit of ~500 columns and applies suffixing (`_s`, `_d`, `_b`) to disambiguate types across resource providers. **Resource-specific mode** writes to dedicated tables (`AGWAccessLogs`, `AZFWNetworkRule`, `AKSAuditAdmin`, …).

| | `AzureDiagnostics` | Resource-specific |
|---|---|---|
| Schema | One shared wide table | One table per log category |
| Column limit risk | Real (~500 columns, then drops) | None in practice |
| Per-table plan (Basic/Auxiliary) | ❌ Cannot be set | ✅ Can be set |
| Query cost | Scans everything | Scans only the relevant table |
| Migration | — | One-way per resource; historical rows stay in the old table |

**Always choose resource-specific** for new deployments. The one-way nature means a migration leaves data split across both tables — write your queries with a `union` during the overlap window.

---

## 3. Ingestion paths in detail

### 3.1 Azure Monitor Agent (AMA) and Data Collection Rules

The legacy Log Analytics agent (MMA/OMS) reached end of support on **31 August 2024**. AMA is the only supported guest agent. Its defining architectural change is that configuration moved *off* the workspace and *into* a separate ARM resource — the **Data Collection Rule (DCR)**.

```
   ┌──────────────┐      ┌───────────────────────────┐      ┌──────────────────┐
   │ VM / VMSS /  │─────▶│ Data Collection Rule      │─────▶│ Log Analytics    │
   │ Arc server / │ DCRA │  dataSources[]            │      │ workspace        │
   │ AKS node     │      │  streams[]                │      │ (or Storage,     │
   └──────┬───────┘      │  transformKql             │      │  Event Hub, AMW) │
          │              │  destinations[]           │      └──────────────────┘
          │              │  dataFlows[]              │
          │              └───────────┬───────────────┘
          │                          │
          │              ┌───────────▼───────────────┐
          └─────────────▶│ Data Collection Endpoint  │  ← required for private link,
                  config │ (DCE)                     │    Logs Ingestion API, and
                         └───────────────────────────┘    custom text/JSON logs
```

Why this matters operationally:

- **One agent, many rules.** A VM can be associated with N DCRs. The Windows-security-events DCR is owned by the security team; the app-performance DCR is owned by the app team. Neither can break the other.
- **Transformations at ingest.** `transformKql` runs *before* billing. Dropping a noisy column or filtering `Severity == "Debug"` in the DCR is the cheapest possible cost control — you are not billed for what the transformation drops (with the caveat that a transformation that only *filters* rows is free, while one that adds columns can incur processing charges on some tiers).
- **Association is a resource.** `Microsoft.Insights/dataCollectionRuleAssociations` — if it is missing, the agent is healthy, reports a heartbeat, and collects nothing. This is failure mode #2 in §12.

### 3.2 Application Insights

Workspace-based Application Insights only; the classic (non-workspace) resource type was retired on **29 February 2024**, and **instrumentation-key-based ingestion was retired on 31 March 2025** — use connection strings.

Telemetry types and their KQL tables:

| Telemetry type | Table | Emitted by |
|---|---|---|
| Incoming HTTP request | `requests` | Server SDK / OTel span (kind=SERVER) |
| Outgoing call (HTTP, SQL, queue, blob) | `dependencies` | Auto-collected / OTel span (kind=CLIENT) |
| Unhandled + tracked exceptions | `exceptions` | SDK, with stack trace |
| Application log lines | `traces` | ILogger, log4j, logging module bridges |
| Domain events | `customEvents` | `TrackEvent` / OTel |
| App-defined metrics | `customMetrics` | `TrackMetric` / OTel meters |
| Browser page loads | `pageViews`, `browserTimings` | JS SDK |
| Synthetic probe results | `availabilityResults` | Standard availability tests |

**Correlation model.** Azure Monitor uses W3C Trace Context (`traceparent`). Each telemetry item carries `operation_Id` (the trace) and `operation_ParentId` (the parent span), which is what makes the end-to-end transaction view and Application Map possible. If a hop drops the header — a proxy stripping unknown headers, a queue consumer not restoring context — the trace splits into orphan fragments. That is a *distributed systems* bug that presents as a *monitoring* bug.

**Sampling** — three mechanisms, and you must know which one is active:

| Sampling type | Where it runs | Adjusts under load | Preserves correlation | Reduces ingestion cost | Default? |
|---|---|---|---|---|---|
| **Adaptive** | SDK, in-process | ✅ Yes, dynamically | ✅ Yes (per-operation) | ✅ Yes | ✅ ASP.NET / ASP.NET Core SDK |
| **Fixed-rate** | SDK, in-process | ❌ Fixed % you set | ✅ Yes | ✅ Yes | Opt-in (default for OTel Distro, `1.0`) |
| **Ingestion** | Azure service, after transmission | ❌ Fixed % you set | ✅ Yes | ❌ **No** — you paid to send it | Off |

Metrics remain accurate under sampling because the SDK writes an `itemCount` on each retained item; KQL must therefore use `sum(itemCount)`, not `count()`, or your numbers will be off by the sampling factor.

### 3.3 Managed Prometheus and Managed Grafana

For Kubernetes, Azure offers a fully managed Prometheus-compatible path:

- **Azure Monitor workspace** (`Microsoft.Monitor/accounts`) — the Prometheus TSDB, 18-month retention, PromQL query endpoint.
- **`ama-metrics` pods** on the cluster scrape targets and remote-write into it. Configuration is via ConfigMaps in `kube-system`, plus `PodMonitor`/`ServiceMonitor` CRDs in the `azmonitoring.coreos.com/v1` API group.
- **Prometheus rule groups** (`Microsoft.AlertsManagement/prometheusRuleGroups`) evaluate recording and alerting rules *server-side*, in Azure, not in the cluster — so rules survive cluster loss.
- **Azure Managed Grafana** for visualization, with a managed identity data source into the Azure Monitor workspace.

| | Azure Monitor Metrics | Managed Prometheus | Container Insights (logs) |
|---|---|---|---|
| Query language | Metrics Explorer / REST | **PromQL** | **KQL** |
| Store | Platform TSDB | Azure Monitor workspace | Log Analytics workspace |
| Retention | 93 days | 18 months | Per table plan, up to 12 years |
| Cardinality | Low | High (Prometheus label model) | Very high |
| Kubernetes-native | ❌ | ✅ CRDs, exporters, dashboards | Partial |
| Cost driver | Custom metric time series | Samples ingested + queries | GB ingested |
| Alerting | Metric alerts | Prometheus rule groups | Log search alerts |

The production pattern on AKS is **all three**: platform metrics for the cluster resource itself, Managed Prometheus for workload SLIs and `kube-state-metrics`, Container Insights (`ContainerLogV2`, `KubeEvents`) for forensics — with `ContainerLogV2` on the **Basic** plan to keep the bill sane.

---

## 4. Alerting architecture

### 4.1 Signal types

| Alert type | Source | Min frequency | Stateful | Dimensions | Typical use |
|---|---|---|---|---|---|
| **Metric alert** | Metrics store | 1 min | ✅ Fired → Resolved | ✅ Multi-dimensional, splits into one alert per combination | Latency, error rate, CPU, queue depth |
| **Metric alert (dynamic threshold)** | Metrics store + ML | 1 min | ✅ | ✅ | Seasonal workloads where a static number is wrong at 03:00 and right at 13:00 |
| **Log search alert** | Log Analytics / App Insights | 1 min (5 min recommended) | Optional (`autoMitigate`) | ✅ via `dimensions[]` | Anything with no metric equivalent; text patterns; cross-table joins |
| **Activity log alert** | Activity Log | Event-driven | ✅ | Condition-based | Someone deleted a production NSG rule |
| **Service Health alert** | Activity Log, `category=ServiceHealth` | Event-driven | ✅ | Service + region filters | Azure outage in your region |
| **Resource Health alert** | Activity Log, `category=ResourceHealth` | Event-driven | ✅ | Health status transitions | *This specific VM* is Unavailable |
| **Prometheus alert rule** | Azure Monitor workspace | Per group `interval` | ✅ (`for:` duration) | PromQL labels | Kubernetes workload SLOs |
| **Smart detection** (App Insights) | ML over App Insights | Automatic | ✅ | — | Anomalous failure rate / latency degradation |

### 4.2 The stateful alert lifecycle

```
   condition true for N of M periods
              │
              ▼
   ┌──────────────────┐   user ack     ┌──────────────────┐
   │   New / Fired    ├───────────────▶│  Acknowledged    │
   └────────┬─────────┘                └────────┬─────────┘
            │ condition clears &                │
            │ autoMitigate = true               │
            ▼                                   ▼
   ┌────────────────────────────────────────────────────────┐
   │                       Closed                           │
   └────────────────────────────────────────────────────────┘
```

`autoMitigate: true` is what prevents an alert storm from a flapping resource. With `numberOfEvaluationPeriods: 4` and `minFailingPeriodsToAlert: 3`, the rule only fires when 3 of the last 4 evaluations failed — the standard cure for single-datapoint noise.

### 4.3 Action groups — limits that bite in production

| Action | Rate limit (per action group) | Notes |
|---|---|---|
| Email | No more than 100 emails per hour to a given address | Excess is throttled, not queued |
| SMS | No more than 1 SMS every 5 minutes per phone number | Country-specific availability |
| Voice | No more than 1 call every 5 minutes per number | |
| Webhook | No more than 1500 per hour | Non-2xx is retried with backoff, then dropped |
| Push (Azure mobile app) | No more than 1 per 5 minutes per Entra user | |

**Secure webhook** uses Microsoft Entra ID authentication instead of a shared secret in the URL — the correct choice for anything that mutates state downstream (PagerDuty, ServiceNow, an internal auto-remediation Function).

**Alert processing rules** (`Microsoft.AlertsManagement/actionRules`) sit *between* the alert and the action group. They implement two things declaratively: suppression during a maintenance window, and applying one action group to a whole subscription or resource group at once rather than editing 300 rules.

---

## 5. Azure Advisor

Advisor is a **free, always-on posture engine** that reads your resource configuration and telemetry and produces recommendations across five pillars, aligned with the Microsoft Azure Well-Architected Framework.

| Pillar | Example recommendations | Signal Advisor uses |
|---|---|---|
| **Reliability** | Enable zone redundancy; configure geo-replication; add a second AZ to a VMSS | Configuration + service topology |
| **Security** | Delegated to Microsoft Defender for Cloud | Defender assessments |
| **Performance** | Upgrade to Premium SSD; increase App Service instance count; add SQL indexes | Metric history |
| **Cost** | Right-size or shut down idle VMs; buy Reservations / Savings Plan; delete unattached disks and idle public IPs | 7–60 day utilization |
| **Operational Excellence** | Enable diagnostic logging; set up Service Health alerts; use Azure Policy | Configuration + Activity Log |

**Advisor Score** is a 0–100 aggregate, weighted by the resources each recommendation affects. It is the number to trend on a quarterly platform-health review; the absolute value is less meaningful than its slope.

**Production integration:** Advisor writes recommendation events into the Activity Log under `category=Recommendation`, so new recommendations can be piped into an action group → Logic App → work item. That closes the loop between "Azure told us" and "someone owns it."

> **Scope note:** Advisor recommendations are role-filtered. A user with Reader on a resource group sees only that group's recommendations. The Cost pillar additionally requires billing-scope access to see Reservation purchase advice.

---

## 6. Azure Service Health — the three tiers

This is where AZ-900 candidates most often lose a point, because three distinct products carry similar names.

| | **Azure Status** | **Service Health** | **Resource Health** |
|---|---|---|---|
| Scope | Global, all regions, all customers | **Your** subscriptions, services, regions | **A single resource** you own |
| Authentication | Public page, no sign-in | Portal, requires sign-in | Portal, requires sign-in |
| Answers | "Is Azure Storage down in West Europe for anyone?" | "Does the current incident affect *me*?" | "Is *this* VM healthy right now?" |
| Event types | Widespread outages only | Service issues, Planned maintenance, Health advisories, Security advisories | Available / Unavailable / Degraded / Unknown |
| Cause attribution | — | Platform-initiated | Distinguishes **platform-initiated** from **user-initiated** (you stopped the VM) |
| Alertable | ❌ | ✅ Activity Log alert, `category=ServiceHealth` | ✅ Activity Log alert, `category=ResourceHealth` |
| History in portal | Recent | Event history retained for a rolling window (currently up to 90 days for issues; longer for some categories) | 30 days |
| URL | `https://status.azure.com` | Portal → Service Health | Portal → resource → Resource health |

**Resource Health status semantics:**

| Status | Meaning | On-call action |
|---|---|---|
| `Available` | No platform events affecting this resource | — |
| `Unavailable` | Platform has detected the resource is not running as expected | Check whether cause is `PlatformInitiated` or `UserInitiated` before failing over |
| `Degraded` | Reduced performance / partial functionality | Correlate with your own SLI metrics |
| `Unknown` | Platform has not received health signals for >10 minutes | Often a network path problem, **not** proof the resource is down |

> **`Unknown` is the dangerous one.** It is frequently misread as "healthy" on a dashboard. Treat `Unknown` as `Degraded` in any automated decision.

---

## 7. Complete infrastructure — Bicep

The following is a single deployable Bicep file that provisions the full observability stack described above: workspace, DCE, DCR, Application Insights, Azure Monitor workspace, action groups, and every alert class.

### `monitoring-stack.bicep`

```bicep
targetScope = 'resourceGroup'

// ─────────────────────────────────────────────────────────────────────────────
// Parameters
// ─────────────────────────────────────────────────────────────────────────────

@description('Short workload identifier used to name every resource.')
@minLength(3)
@maxLength(12)
param workload string = 'checkout'

@description('Deployment environment.')
@allowed([ 'dev', 'stg', 'prd' ])
param env string = 'prd'

@description('Primary Azure region for all regional resources.')
param location string = resourceGroup().location

@description('Interactive retention for the Analytics plan tables, in days.')
@minValue(30)
@maxValue(730)
param retentionInDays int = 90

@description('Hard ceiling on daily ingestion, in GB. -1 disables the cap.')
param dailyQuotaGb int = 50

@description('Distribution list that receives Sev0/Sev1 pages.')
param pagerEmail string = 'sre-oncall@example.com'

@description('Secure webhook endpoint of the incident management platform.')
param incidentWebhookUri string = 'https://events.pagerduty.com/integration/EXAMPLE/enqueue'

@description('Resource ID of the AKS cluster to attach Container Insights to.')
param aksClusterId string

@description('Azure service names to watch in Service Health alerts.')
param watchedServices array = [
  'Azure Kubernetes Service (AKS)'
  'Virtual Machines'
  'Azure Database for PostgreSQL'
  'Application Gateway'
]

@description('Regions to watch in Service Health alerts.')
param watchedRegions array = [
  'West Europe'
  'North Europe'
]

var suffix = '${workload}-${env}'
var tags = {
  workload: workload
  environment: env
  costCenter: 'platform-engineering'
  managedBy: 'bicep'
}

// ─────────────────────────────────────────────────────────────────────────────
// 1. Log Analytics workspace — the logs backbone
// ─────────────────────────────────────────────────────────────────────────────

resource law 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: 'log-${suffix}'
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: retentionInDays
    workspaceCapping: {
      dailyQuotaGb: dailyQuotaGb
    }
    features: {
      // Resource-context RBAC: a user with read access on a VM can query that
      // VM's rows without being granted read access on the whole workspace.
      enableLogAccessUsingOnlyResourcePermissions: true
      immediatePurgeDataOn30Days: false
    }
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

// Per-table plan overrides. ContainerLogV2 is high-volume and rarely joined,
// so it goes to Basic: ~4x cheaper to ingest, billed per GB scanned on query.
resource containerLogPlan 'Microsoft.OperationalInsights/workspaces/tables@2023-09-01' = {
  parent: law
  name: 'ContainerLogV2'
  properties: {
    plan: 'Basic'
    totalRetentionInDays: 365
  }
}

// Application Insights request telemetry stays on Analytics: it backs alerts,
// the Application Map, and cross-table joins against dependencies.
resource requestsPlan 'Microsoft.OperationalInsights/workspaces/tables@2023-09-01' = {
  parent: law
  name: 'AppRequests'
  properties: {
    plan: 'Analytics'
    retentionInDays: retentionInDays
    totalRetentionInDays: 730
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 2. Data Collection Endpoint — required for custom logs and private link
// ─────────────────────────────────────────────────────────────────────────────

resource dce 'Microsoft.Insights/dataCollectionEndpoints@2023-03-11' = {
  name: 'dce-${suffix}'
  location: location
  tags: tags
  kind: 'Linux'
  properties: {
    description: 'Ingestion endpoint for AMA and the Logs Ingestion API'
    networkAcls: {
      publicNetworkAccess: 'Enabled'
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 3. Data Collection Rule — Linux guest OS performance + syslog
// ─────────────────────────────────────────────────────────────────────────────

resource dcrLinuxHost 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
  name: 'dcr-linux-host-${suffix}'
  location: location
  tags: tags
  kind: 'Linux'
  properties: {
    description: 'Guest OS performance counters and syslog for Linux fleet'
    dataCollectionEndpointId: dce.id
    dataSources: {
      performanceCounters: [
        {
          name: 'hostPerfCounters'
          streams: [
            'Microsoft-Perf'
          ]
          samplingFrequencyInSeconds: 60
          counterSpecifiers: [
            'Processor(*)\\% Processor Time'
            'Processor(*)\\% Idle Time'
            'Memory(*)\\% Used Memory'
            'Memory(*)\\Available MBytes Memory'
            'Logical Disk(*)\\% Used Space'
            'Logical Disk(*)\\Disk Read Bytes/sec'
            'Logical Disk(*)\\Disk Write Bytes/sec'
            'Logical Disk(*)\\Disk Transfers/sec'
            'Network(*)\\Total Bytes Transmitted'
            'Network(*)\\Total Bytes Received'
          ]
        }
      ]
      syslog: [
        {
          name: 'criticalSyslog'
          streams: [
            'Microsoft-Syslog'
          ]
          facilityNames: [
            'auth'
            'authpriv'
            'cron'
            'daemon'
            'kern'
            'syslog'
          ]
          logLevels: [
            'Warning'
            'Error'
            'Critical'
            'Alert'
            'Emergency'
          ]
        }
      ]
    }
    destinations: {
      logAnalytics: [
        {
          workspaceResourceId: law.id
          name: 'primaryWorkspace'
        }
      ]
    }
    dataFlows: [
      {
        streams: [
          'Microsoft-Perf'
        ]
        destinations: [
          'primaryWorkspace'
        ]
      }
      {
        streams: [
          'Microsoft-Syslog'
        ]
        destinations: [
          'primaryWorkspace'
        ]
        // Ingest-time transformation: drop the CRON spam that no one reads,
        // and normalise the hostname. Runs BEFORE billing.
        transformKql: 'source | where not(SyslogMessage has_cs "CRON" and SeverityLevel == "warning") | extend Computer = tolower(Computer)'
      }
    ]
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 4. Data Collection Rule — Container Insights for AKS
// ─────────────────────────────────────────────────────────────────────────────

resource dcrContainerInsights 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
  name: 'MSCI-${location}-${suffix}'
  location: location
  tags: tags
  kind: 'Linux'
  properties: {
    description: 'Container Insights collection for the AKS cluster'
    dataSources: {
      extensions: [
        {
          name: 'ContainerInsightsExtension'
          extensionName: 'ContainerInsights'
          streams: [
            'Microsoft-ContainerLogV2'
            'Microsoft-KubeEvents'
            'Microsoft-KubePodInventory'
            'Microsoft-KubeNodeInventory'
            'Microsoft-KubePVInventory'
            'Microsoft-KubeServices'
            'Microsoft-InsightsMetrics'
          ]
          extensionSettings: {
            dataCollectionSettings: {
              interval: '1m'
              namespaceFilteringMode: 'Exclude'
              namespaces: [
                'kube-system'
                'gatekeeper-system'
                'azure-arc'
              ]
              enableContainerLogV2: true
            }
          }
        }
      ]
    }
    destinations: {
      logAnalytics: [
        {
          workspaceResourceId: law.id
          name: 'primaryWorkspace'
        }
      ]
    }
    dataFlows: [
      {
        streams: [
          'Microsoft-ContainerLogV2'
        ]
        destinations: [
          'primaryWorkspace'
        ]
        // Drop health-probe noise before it is billed. This single line
        // routinely removes 30-50% of a cluster's log volume.
        transformKql: 'source | where LogMessage !has "/healthz" and LogMessage !has "/readyz" and LogMessage !has "kube-probe"'
      }
      {
        streams: [
          'Microsoft-KubeEvents'
          'Microsoft-KubePodInventory'
          'Microsoft-KubeNodeInventory'
          'Microsoft-KubePVInventory'
          'Microsoft-KubeServices'
          'Microsoft-InsightsMetrics'
        ]
        destinations: [
          'primaryWorkspace'
        ]
      }
    ]
  }
}

resource dcraAks 'Microsoft.Insights/dataCollectionRuleAssociations@2022-06-01' = {
  name: 'ContainerInsightsExtension'
  scope: aks
  properties: {
    description: 'Associates the AKS cluster with the Container Insights DCR'
    dataCollectionRuleId: dcrContainerInsights.id
  }
}

resource aks 'Microsoft.ContainerService/managedClusters@2024-05-01' existing = {
  name: last(split(aksClusterId, '/'))
}

// ─────────────────────────────────────────────────────────────────────────────
// 5. Custom table + DCR for the Logs Ingestion API
// ─────────────────────────────────────────────────────────────────────────────

resource auditTable 'Microsoft.OperationalInsights/workspaces/tables@2023-09-01' = {
  parent: law
  name: 'CheckoutAudit_CL'
  properties: {
    plan: 'Analytics'
    retentionInDays: 730
    totalRetentionInDays: 2555
    schema: {
      name: 'CheckoutAudit_CL'
      columns: [
        { name: 'TimeGenerated',  type: 'datetime' }
        { name: 'OrderId',        type: 'string'   }
        { name: 'TenantId',       type: 'string'   }
        { name: 'Action',         type: 'string'   }
        { name: 'ActorUpn',       type: 'string'   }
        { name: 'AmountMinor',    type: 'long'     }
        { name: 'Currency',       type: 'string'   }
        { name: 'Result',         type: 'string'   }
        { name: 'CorrelationId',  type: 'string'   }
        { name: 'SourceIp',       type: 'string'   }
      ]
    }
  }
}

resource dcrAudit 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
  name: 'dcr-audit-${suffix}'
  location: location
  tags: tags
  kind: 'Direct'
  dependsOn: [
    auditTable
  ]
  properties: {
    description: 'Logs Ingestion API endpoint for the checkout audit trail'
    dataCollectionEndpointId: dce.id
    streamDeclarations: {
      'Custom-CheckoutAudit': {
        columns: [
          { name: 'time',          type: 'datetime' }
          { name: 'orderId',       type: 'string'   }
          { name: 'tenantId',      type: 'string'   }
          { name: 'action',        type: 'string'   }
          { name: 'actor',         type: 'string'   }
          { name: 'amountMinor',   type: 'long'     }
          { name: 'currency',      type: 'string'   }
          { name: 'result',        type: 'string'   }
          { name: 'correlationId', type: 'string'   }
          { name: 'sourceIp',      type: 'string'   }
        ]
      }
    }
    destinations: {
      logAnalytics: [
        {
          workspaceResourceId: law.id
          name: 'primaryWorkspace'
        }
      ]
    }
    dataFlows: [
      {
        streams: [
          'Custom-CheckoutAudit'
        ]
        destinations: [
          'primaryWorkspace'
        ]
        outputStream: 'Custom-CheckoutAudit_CL'
        transformKql: 'source | project TimeGenerated = time, OrderId = orderId, TenantId = tenantId, Action = action, ActorUpn = actor, AmountMinor = amountMinor, Currency = currency, Result = result, CorrelationId = correlationId, SourceIp = sourceIp'
      }
    ]
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 6. Application Insights — workspace-based
// ─────────────────────────────────────────────────────────────────────────────

resource appi 'Microsoft.Insights/components@2020-02-02' = {
  name: 'appi-${suffix}'
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: law.id
    IngestionMode: 'LogAnalytics'
    Flow_Type: 'Bluefield'
    Request_Source: 'rest'
    RetentionInDays: retentionInDays
    SamplingPercentage: json('100')
    DisableIpMasking: false
    DisableLocalAuth: true
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

// Standard availability test: a real HTTPS probe from five Azure regions.
resource availabilityTest 'Microsoft.Insights/webtests@2022-06-15' = {
  name: 'wt-${suffix}-checkout-health'
  location: location
  tags: union(tags, {
    // This tag is mandatory: it is how the portal links the test to the
    // Application Insights component. Deployment succeeds without it and the
    // test then never appears in the UI.
    'hidden-link:${appi.id}': 'Resource'
  })
  kind: 'standard'
  properties: {
    Name: 'checkout-health'
    SyntheticMonitorId: 'wt-${suffix}-checkout-health'
    Enabled: true
    Frequency: 300
    Timeout: 30
    Kind: 'standard'
    RetryEnabled: true
    Locations: [
      { Id: 'emea-nl-ams-azr' }
      { Id: 'emea-gb-db3-azr' }
      { Id: 'emea-fr-pra-edge' }
      { Id: 'us-va-ash-azr' }
      { Id: 'apac-sg-sin-azr' }
    ]
    Request: {
      RequestUrl: 'https://checkout.example.com/health/ready'
      HttpVerb: 'GET'
      ParseDependentRequests: false
      FollowRedirects: false
      Headers: [
        {
          key: 'X-Synthetic-Probe'
          value: 'azure-availability-test'
        }
      ]
    }
    ValidationRules: {
      ExpectedHttpStatusCode: 200
      SSLCheck: true
      SSLCertRemainingLifetimeCheck: 14
      ContentValidation: {
        ContentMatch: '"status":"ok"'
        IgnoreCase: true
        PassIfTextFound: true
      }
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 7. Azure Monitor workspace — Managed Prometheus TSDB
// ─────────────────────────────────────────────────────────────────────────────

resource amw 'Microsoft.Monitor/accounts@2023-04-03' = {
  name: 'amw-${suffix}'
  location: location
  tags: tags
  properties: {
    publicNetworkAccess: 'Enabled'
  }
}

resource grafana 'Microsoft.Dashboard/grafana@2023-09-01' = {
  name: 'graf-${suffix}'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    apiKey: 'Disabled'
    deterministicOutboundIP: 'Enabled'
    publicNetworkAccess: 'Enabled'
    zoneRedundancy: 'Enabled'
    grafanaIntegrations: {
      azureMonitorWorkspaceIntegrations: [
        {
          azureMonitorWorkspaceResourceId: amw.id
        }
      ]
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 8. Action groups — two severities, two escalation paths
// ─────────────────────────────────────────────────────────────────────────────

resource agPage 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: 'ag-${suffix}-page'
  location: 'global'
  tags: tags
  properties: {
    groupShortName: 'page'
    enabled: true
    emailReceivers: [
      {
        name: 'sre-oncall-email'
        emailAddress: pagerEmail
        useCommonAlertSchema: true
      }
    ]
    webhookReceivers: [
      {
        name: 'incident-platform'
        serviceUri: incidentWebhookUri
        useCommonAlertSchema: true
        useAadAuth: false
      }
    ]
    azureAppPushReceivers: [
      {
        name: 'oncall-mobile'
        emailAddress: pagerEmail
      }
    ]
  }
}

resource agTicket 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: 'ag-${suffix}-ticket'
  location: 'global'
  tags: tags
  properties: {
    groupShortName: 'ticket'
    enabled: true
    emailReceivers: [
      {
        name: 'platform-team-email'
        emailAddress: 'platform-team@example.com'
        useCommonAlertSchema: true
      }
    ]
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 9. Metric alerts
// ─────────────────────────────────────────────────────────────────────────────

// Static threshold, multi-dimensional, on Application Insights server response time.
resource alertLatency 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: 'alert-${suffix}-p95-latency'
  location: 'global'
  tags: tags
  properties: {
    description: 'Server response time above 1500 ms averaged over 5 minutes'
    severity: 2
    enabled: true
    scopes: [
      appi.id
    ]
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    autoMitigate: true
    targetResourceType: 'Microsoft.Insights/components'
    targetResourceRegion: location
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.MultipleResourceMultipleMetricCriteria'
      allOf: [
        {
          criterionType: 'StaticThresholdCriterion'
          name: 'ServerResponseTime'
          metricName: 'requests/duration'
          metricNamespace: 'microsoft.insights/components'
          operator: 'GreaterThan'
          threshold: 1500
          timeAggregation: 'Average'
          skipMetricValidation: false
          dimensions: [
            {
              name: 'request/performanceBucket'
              operator: 'Exclude'
              values: [
                '<250ms'
              ]
            }
          ]
        }
      ]
    }
    actions: [
      {
        actionGroupId: agPage.id
        webHookProperties: {
          runbookTag: 'latency'
        }
      }
    ]
  }
}

// Dynamic threshold: the ML model learns the daily and weekly seasonality
// instead of forcing one number that is wrong twice a day.
resource alertFailedRequests 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: 'alert-${suffix}-failed-requests-anomaly'
  location: 'global'
  tags: tags
  properties: {
    description: 'Failed request count deviates from the learned baseline'
    severity: 1
    enabled: true
    scopes: [
      appi.id
    ]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT15M'
    autoMitigate: true
    targetResourceType: 'Microsoft.Insights/components'
    targetResourceRegion: location
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.MultipleResourceMultipleMetricCriteria'
      allOf: [
        {
          criterionType: 'DynamicThresholdCriterion'
          name: 'FailedRequestsAnomaly'
          metricName: 'requests/failed'
          metricNamespace: 'microsoft.insights/components'
          operator: 'GreaterThan'
          alertSensitivity: 'Medium'
          timeAggregation: 'Count'
          failingPeriods: {
            numberOfEvaluationPeriods: 4
            minFailingPeriodsToAlert: 3
          }
          skipMetricValidation: false
        }
      ]
    }
    actions: [
      {
        actionGroupId: agPage.id
      }
    ]
  }
}

// Availability test failure alert — the canonical "is the site up" signal.
resource alertAvailability 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: 'alert-${suffix}-availability'
  location: 'global'
  tags: tags
  properties: {
    description: 'Standard availability test failing from 2 or more locations'
    severity: 0
    enabled: true
    scopes: [
      appi.id
      availabilityTest.id
    ]
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    autoMitigate: true
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.WebtestLocationAvailabilityCriteria'
      webTestId: availabilityTest.id
      componentId: appi.id
      failedLocationCount: 2
    }
    actions: [
      {
        actionGroupId: agPage.id
      }
    ]
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 10. Log search alert (scheduled query rule)
// ─────────────────────────────────────────────────────────────────────────────

resource alertPodCrashLoop 'Microsoft.Insights/scheduledQueryRules@2023-12-01' = {
  name: 'alert-${suffix}-pod-crashloop'
  location: location
  tags: tags
  kind: 'LogAlert'
  properties: {
    displayName: 'Pods entering CrashLoopBackOff'
    description: 'Fires when any workload namespace produces BackOff events'
    severity: 2
    enabled: true
    scopes: [
      law.id
    ]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT15M'
    autoMitigate: true
    checkWorkspaceAlertsStorageConfigured: false
    skipQueryValidation: false
    criteria: {
      allOf: [
        {
          query: '''
KubeEvents
| where TimeGenerated > ago(15m)
| where Reason in ("BackOff", "Failed", "FailedCreatePodSandBox")
| where Namespace !in ("kube-system", "gatekeeper-system")
| summarize EventCount = count() by Namespace, Name, Reason, ClusterName
| where EventCount >= 3
'''
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          resourceIdColumn: '_ResourceId'
          dimensions: [
            {
              name: 'Namespace'
              operator: 'Include'
              values: [ '*' ]
            }
            {
              name: 'Name'
              operator: 'Include'
              values: [ '*' ]
            }
          ]
          failingPeriods: {
            numberOfEvaluationPeriods: 2
            minFailingPeriodsToAlert: 2
          }
        }
      ]
    }
    actions: {
      actionGroups: [
        agTicket.id
      ]
      customProperties: {
        runbook: 'https://wiki.example.com/runbooks/crashloop'
      }
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 11. Prometheus rule group — evaluated server-side, survives cluster loss
// ─────────────────────────────────────────────────────────────────────────────

resource promRules 'Microsoft.AlertsManagement/prometheusRuleGroups@2023-03-01' = {
  name: 'prg-${suffix}-slo'
  location: location
  tags: tags
  properties: {
    description: 'SLO recording and alerting rules for the checkout workload'
    enabled: true
    clusterName: last(split(aksClusterId, '/'))
    scopes: [
      amw.id
      aksClusterId
    ]
    interval: 'PT1M'
    rules: [
      {
        record: 'checkout:http_request_error_ratio:rate5m'
        expression: 'sum(rate(http_requests_total{job="checkout",code=~"5.."}[5m])) / sum(rate(http_requests_total{job="checkout"}[5m]))'
        enabled: true
        labels: {
          workload: 'checkout'
        }
      }
      {
        alert: 'CheckoutErrorBudgetBurnFast'
        expression: 'checkout:http_request_error_ratio:rate5m > (14.4 * 0.001)'
        for: 'PT2M'
        enabled: true
        severity: 1
        labels: {
          workload: 'checkout'
          burnrate: 'fast'
        }
        annotations: {
          summary: 'Checkout is burning its 99.9% error budget 14.4x faster than sustainable'
          runbook_url: 'https://wiki.example.com/runbooks/checkout-error-budget'
        }
        resolveConfiguration: {
          autoResolved: true
          timeToResolve: 'PT10M'
        }
        actions: [
          {
            actionGroupId: agPage.id
          }
        ]
      }
      {
        alert: 'CheckoutErrorBudgetBurnSlow'
        expression: 'checkout:http_request_error_ratio:rate5m > (6 * 0.001)'
        for: 'PT15M'
        enabled: true
        severity: 3
        labels: {
          workload: 'checkout'
          burnrate: 'slow'
        }
        annotations: {
          summary: 'Sustained elevated error rate on checkout'
        }
        resolveConfiguration: {
          autoResolved: true
          timeToResolve: 'PT30M'
        }
        actions: [
          {
            actionGroupId: agTicket.id
          }
        ]
      }
    ]
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 12. Alert processing rule — suppress everything during the maintenance window
// ─────────────────────────────────────────────────────────────────────────────

resource maintenanceSuppression 'Microsoft.AlertsManagement/actionRules@2021-08-08' = {
  name: 'apr-${suffix}-maintenance-window'
  location: 'Global'
  tags: tags
  properties: {
    description: 'Suppress non-Sev0 alerts during the weekly patch window'
    enabled: true
    scopes: [
      resourceGroup().id
    ]
    conditions: [
      {
        field: 'Severity'
        operator: 'NotEquals'
        values: [
          'Sev0'
        ]
      }
    ]
    actions: [
      {
        actionType: 'RemoveAllActionGroups'
      }
    ]
    schedule: {
      timeZone: 'W. Europe Standard Time'
      effectiveFrom: '2026-09-06T00:00:00'
      recurrences: [
        {
          recurrenceType: 'Weekly'
          startTime: '02:00:00'
          endTime: '04:00:00'
          daysOfWeek: [
            'Sunday'
          ]
        }
      ]
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 13. Diagnostic settings — Activity Log at subscription scope is in a separate
//     module because it targets a different ARM scope. See activity-log.bicep.
// ─────────────────────────────────────────────────────────────────────────────

resource aksDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'diag-to-law'
  scope: aks
  properties: {
    workspaceId: law.id
    logAnalyticsDestinationType: 'Dedicated' // resource-specific tables
    logs: [
      { category: 'kube-apiserver',          enabled: true }
      { category: 'kube-audit-admin',        enabled: true }
      { category: 'kube-controller-manager', enabled: true }
      { category: 'kube-scheduler',          enabled: false }
      { category: 'cluster-autoscaler',      enabled: true }
      { category: 'guard',                   enabled: true }
      // 'kube-audit' (full) is deliberately OFF: it is typically the single
      // largest log source on any AKS cluster. kube-audit-admin keeps the
      // mutating operations, which is what forensics actually needs.
      { category: 'kube-audit',              enabled: false }
    ]
    metrics: [
      { category: 'AllMetrics', enabled: true }
    ]
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Outputs
// ─────────────────────────────────────────────────────────────────────────────

output workspaceId string = law.id
output workspaceCustomerId string = law.properties.customerId
output dceLogsIngestionEndpoint string = dce.properties.logsIngestion.endpoint
output auditDcrImmutableId string = dcrAudit.properties.immutableId
output appInsightsConnectionString string = appi.properties.ConnectionString
output azureMonitorWorkspaceId string = amw.id
output grafanaEndpoint string = grafana.properties.endpoint
```

### Subscription-scope module — `activity-log.bicep`

Service Health, Resource Health, and Advisor alerts all live at subscription scope, because the Activity Log is a subscription-level resource.

```bicep
targetScope = 'subscription'

@description('Resource ID of the action group that receives platform-health events.')
param actionGroupId string

@description('Resource ID of the Log Analytics workspace receiving the Activity Log.')
param workspaceId string

param watchedServices array = [
  'Azure Kubernetes Service (AKS)'
  'Virtual Machines'
  'Application Gateway'
]

param watchedRegions array = [
  'West Europe'
  'North Europe'
  'Global'
]

// Ship the Activity Log into Log Analytics so it is queryable with KQL and
// joinable against resource logs. Without this, it is only visible in the
// portal blade and expires after 90 days.
resource activityLogToLaw 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'activitylog-to-law'
  properties: {
    workspaceId: workspaceId
    logs: [
      { category: 'Administrative',     enabled: true }
      { category: 'Security',           enabled: true }
      { category: 'ServiceHealth',      enabled: true }
      { category: 'Alert',              enabled: true }
      { category: 'Recommendation',     enabled: true }
      { category: 'Policy',             enabled: true }
      { category: 'Autoscale',          enabled: true }
      { category: 'ResourceHealth',     enabled: true }
    ]
  }
}

// ── Service Health: platform incidents that affect MY services in MY regions ──
resource serviceHealthAlert 'Microsoft.Insights/activityLogAlerts@2020-10-01' = {
  name: 'alert-service-health'
  location: 'Global'
  properties: {
    description: 'Azure platform incidents, maintenance and advisories in scope'
    enabled: true
    scopes: [
      subscription().id
    ]
    condition: {
      allOf: [
        {
          field: 'category'
          equals: 'ServiceHealth'
        }
        {
          anyOf: [
            { field: 'properties.incidentType', equals: 'Incident'         }
            { field: 'properties.incidentType', equals: 'Maintenance'      }
            { field: 'properties.incidentType', equals: 'Security'         }
            { field: 'properties.incidentType', equals: 'Informational'    }
          ]
        }
        {
          field: 'properties.impactedServices[*].ServiceName'
          containsAny: watchedServices
        }
        {
          field: 'properties.impactedServices[*].ImpactedRegions[*].RegionName'
          containsAny: watchedRegions
        }
      ]
    }
    actions: {
      actionGroups: [
        {
          actionGroupId: actionGroupId
        }
      ]
    }
  }
}

// ── Resource Health: THIS resource became unavailable, platform-initiated ──
resource resourceHealthAlert 'Microsoft.Insights/activityLogAlerts@2020-10-01' = {
  name: 'alert-resource-health-unavailable'
  location: 'Global'
  properties: {
    description: 'A resource transitioned to Unavailable or Degraded'
    enabled: true
    scopes: [
      subscription().id
    ]
    condition: {
      allOf: [
        {
          field: 'category'
          equals: 'ResourceHealth'
        }
        {
          anyOf: [
            { field: 'properties.currentHealthStatus', equals: 'Unavailable' }
            { field: 'properties.currentHealthStatus', equals: 'Degraded'    }
          ]
        }
        {
          field: 'properties.previousHealthStatus'
          equals: 'Available'
        }
        {
          // Exclude self-inflicted transitions: you stopped the VM, that is
          // not an incident. This filter removes the majority of the noise.
          field: 'properties.cause'
          equals: 'PlatformInitiated'
        }
      ]
    }
    actions: {
      actionGroups: [
        {
          actionGroupId: actionGroupId
        }
      ]
    }
  }
}

// ── Advisor: new High-impact Reliability or Cost recommendations ──
resource advisorAlert 'Microsoft.Insights/activityLogAlerts@2020-10-01' = {
  name: 'alert-advisor-high-impact'
  location: 'Global'
  properties: {
    description: 'New high-impact Advisor recommendation raised'
    enabled: true
    scopes: [
      subscription().id
    ]
    condition: {
      allOf: [
        {
          field: 'category'
          equals: 'Recommendation'
        }
        {
          field: 'properties.recommendationImpact'
          equals: 'High'
        }
        {
          anyOf: [
            { field: 'properties.recommendationCategory', equals: 'HighAvailability' }
            { field: 'properties.recommendationCategory', equals: 'Cost'             }
            { field: 'properties.recommendationCategory', equals: 'Performance'      }
          ]
        }
      ]
    }
    actions: {
      actionGroups: [
        {
          actionGroupId: actionGroupId
        }
      ]
    }
  }
}

// ── Administrative: someone deleted a production network resource ──
resource destructiveOpAlert 'Microsoft.Insights/activityLogAlerts@2020-10-01' = {
  name: 'alert-destructive-network-op'
  location: 'Global'
  properties: {
    description: 'Delete operation on a network security or routing resource'
    enabled: true
    scopes: [
      subscription().id
    ]
    condition: {
      allOf: [
        {
          field: 'category'
          equals: 'Administrative'
        }
        {
          field: 'status'
          equals: 'Succeeded'
        }
        {
          anyOf: [
            { field: 'operationName', equals: 'Microsoft.Network/networkSecurityGroups/delete'             }
            { field: 'operationName', equals: 'Microsoft.Network/networkSecurityGroups/securityRules/delete' }
            { field: 'operationName', equals: 'Microsoft.Network/routeTables/delete'                       }
            { field: 'operationName', equals: 'Microsoft.Network/azureFirewalls/delete'                    }
          ]
        }
      ]
    }
    actions: {
      actionGroups: [
        {
          actionGroupId: actionGroupId
        }
      ]
    }
  }
}
```

### Terraform equivalent — `monitoring.tf`

```hcl
terraform {
  required_version = ">= 1.9.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.14"
    }
  }
}

provider "azurerm" {
  features {
    log_analytics_workspace {
      permanently_delete_on_destroy = false
    }
  }
}

locals {
  workload = "checkout"
  env      = "prd"
  suffix   = "${local.workload}-${local.env}"
  location = "westeurope"

  tags = {
    workload    = local.workload
    environment = local.env
    managedBy   = "terraform"
  }
}

resource "azurerm_resource_group" "obs" {
  name     = "rg-observability-${local.suffix}"
  location = local.location
  tags     = local.tags
}

resource "azurerm_log_analytics_workspace" "law" {
  name                       = "log-${local.suffix}"
  location                   = azurerm_resource_group.obs.location
  resource_group_name        = azurerm_resource_group.obs.name
  sku                        = "PerGB2018"
  retention_in_days          = 90
  daily_quota_gb             = 50
  internet_ingestion_enabled = true
  internet_query_enabled     = true
  tags                       = local.tags
}

resource "azurerm_application_insights" "appi" {
  name                       = "appi-${local.suffix}"
  location                   = azurerm_resource_group.obs.location
  resource_group_name        = azurerm_resource_group.obs.name
  workspace_id               = azurerm_log_analytics_workspace.law.id
  application_type           = "web"
  retention_in_days          = 90
  sampling_percentage        = 100
  local_authentication_disabled = true
  tags                       = local.tags
}

resource "azurerm_monitor_action_group" "page" {
  name                = "ag-${local.suffix}-page"
  resource_group_name = azurerm_resource_group.obs.name
  short_name          = "page"
  tags                = local.tags

  email_receiver {
    name                    = "sre-oncall-email"
    email_address           = "sre-oncall@example.com"
    use_common_alert_schema = true
  }

  webhook_receiver {
    name                    = "incident-platform"
    service_uri             = var.incident_webhook_uri
    use_common_alert_schema = true
  }
}

resource "azurerm_monitor_metric_alert" "latency" {
  name                = "alert-${local.suffix}-p95-latency"
  resource_group_name = azurerm_resource_group.obs.name
  scopes              = [azurerm_application_insights.appi.id]
  description         = "Server response time above 1500 ms over 5 minutes"
  severity            = 2
  frequency           = "PT1M"
  window_size         = "PT5M"
  auto_mitigate       = true
  tags                = local.tags

  criteria {
    metric_namespace = "microsoft.insights/components"
    metric_name      = "requests/duration"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = 1500
  }

  action {
    action_group_id = azurerm_monitor_action_group.page.id
  }
}

resource "azurerm_monitor_scheduled_query_rules_alert_v2" "crashloop" {
  name                = "alert-${local.suffix}-pod-crashloop"
  resource_group_name = azurerm_resource_group.obs.name
  location            = azurerm_resource_group.obs.location
  description         = "Pods entering CrashLoopBackOff"
  severity            = 2
  enabled             = true
  scopes              = [azurerm_log_analytics_workspace.law.id]
  evaluation_frequency = "PT5M"
  window_duration      = "PT15M"
  auto_mitigation_enabled = true
  tags                 = local.tags

  criteria {
    query = <<-KQL
      KubeEvents
      | where Reason in ("BackOff", "Failed", "FailedCreatePodSandBox")
      | where Namespace !in ("kube-system", "gatekeeper-system")
      | summarize EventCount = count() by Namespace, Name, Reason
      | where EventCount >= 3
    KQL

    time_aggregation_method = "Count"
    threshold               = 0
    operator                = "GreaterThan"

    dimension {
      name     = "Namespace"
      operator = "Include"
      values   = ["*"]
    }

    failing_periods {
      minimum_failing_periods_to_trigger_alert = 2
      number_of_evaluation_periods             = 2
    }
  }

  action {
    action_groups = [azurerm_monitor_action_group.page.id]
  }
}

resource "azurerm_monitor_activity_log_alert" "service_health" {
  name                = "alert-service-health"
  resource_group_name = azurerm_resource_group.obs.name
  location            = "global"
  scopes              = [data.azurerm_subscription.current.id]
  description         = "Azure platform incidents affecting our services"
  tags                = local.tags

  criteria {
    category = "ServiceHealth"

    service_health {
      events    = ["Incident", "Maintenance", "Security"]
      locations = ["West Europe", "North Europe", "Global"]
      services  = ["Azure Kubernetes Service (AKS)", "Virtual Machines", "Application Gateway"]
    }
  }

  action {
    action_group_id = azurerm_monitor_action_group.page.id
  }
}

data "azurerm_subscription" "current" {}

variable "incident_webhook_uri" {
  type        = string
  description = "Secure webhook endpoint of the incident management platform"
  sensitive   = true
}

output "app_insights_connection_string" {
  value     = azurerm_application_insights.appi.connection_string
  sensitive = true
}
```

---

## 8. Kubernetes manifests

### 8.1 Container Insights agent configuration — `container-azm-ms-agentconfig.yaml`

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: container-azm-ms-agentconfig
  namespace: kube-system
  labels:
    app.kubernetes.io/name: ama-logs
    app.kubernetes.io/component: log-collection
data:
  schema-version: v1
  config-version: "prod-2026-09"

  log-data-collection-settings: |-
    [log_collection_settings]
       [log_collection_settings.stdout]
          enabled = true
          # Namespaces whose stdout is NOT collected. Control-plane chatter is
          # the largest avoidable cost on almost every cluster.
          exclude_namespaces = ["kube-system", "gatekeeper-system", "azure-arc", "kube-node-lease"]

       [log_collection_settings.stderr]
          enabled = true
          # stderr is kept for kube-system: that is where crashes surface.
          exclude_namespaces = ["gatekeeper-system", "kube-node-lease"]

       [log_collection_settings.env_var]
          # Environment variables per container. Frequently leaks secrets into
          # the workspace. Default to false and turn on per-investigation.
          enabled = false

       [log_collection_settings.enrich_container_logs]
          # Adds Name/Image to every log row. Costs bytes; buys joins.
          enabled = true

       [log_collection_settings.collect_all_kube_events]
          # false = only non-Normal events. true multiplies KubeEvents volume.
          enabled = false

       [log_collection_settings.schema]
          # ContainerLogV2 supports the Basic table plan and multi-line logs.
          # ContainerLog (v1) does not. Always v2 for new clusters.
          containerlog_schema_version = "v2"

       [log_collection_settings.enable_multiline_logs]
          enabled = true
          stacktrace_languages = ["java", "python", "go", "dotnet"]

       [log_collection_settings.metadata_collection]
          enabled = true
          include_fields = ["podLabels", "podAnnotations", "podUid", "image", "imageID", "imageRepo", "imageTag"]

  prometheus-data-collection-settings: |-
    [prometheus_data_collection_settings.cluster]
       interval = "1m"
       fieldpass = ["kube_pod_status_phase", "kube_deployment_status_replicas_unavailable"]
       monitor_kubernetes_pods = false

    [prometheus_data_collection_settings.node]
       interval = "1m"
       urls = ["http://$NODE_IP:9100/metrics"]
       fieldpass = ["node_filesystem_avail_bytes", "node_filesystem_size_bytes", "node_memory_MemAvailable_bytes"]

  metric_collection_settings: |-
    [metric_collection_settings.collect_kube_system_pv_metrics]
       enabled = true

  alertable-metrics-configuration-settings: |-
    [alertable_metrics_configuration_settings.container_resource_utilization_thresholds]
       container_cpu_threshold_percentage = 90.0
       container_memory_rss_threshold_percentage = 90.0
       container_memory_working_set_threshold_percentage = 90.0

    [alertable_metrics_configuration_settings.pv_utilization_thresholds]
       pv_usage_threshold_percentage = 80.0

    [alertable_metrics_configuration_settings.job_completion_time]
       job_completion_time_threshold_minutes = 360

  agent-settings: |-
    [agent_settings.fbit_config]
       log_flush_interval_secs = "1"
       tail_mem_buf_limit_megabytes = "10"
       tail_buf_chunksize_megabytes = "1"
       tail_buf_maxsize_megabytes = "1"

    [agent_settings.high_log_scale]
       # Raises the per-node throughput ceiling above ~10 MB/s. Requires
       # ContainerLogV2 and additional node resources.
       enabled = false
```

### 8.2 Managed Prometheus scrape configuration — `ama-metrics-settings-configmap.yaml`

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: ama-metrics-settings-configmap
  namespace: kube-system
data:
  schema-version: v1
  config-version: "prod-2026-09"

  # Which built-in targets the managed collector scrapes.
  default-scrape-settings-enabled: |-
    kubelet = true
    coredns = true
    cadvisor = true
    kubeproxy = false
    apiserver = true
    kubestate = true
    nodeexporter = true
    windowsexporter = false
    windowskubeproxy = false
    kappiebasic = true
    networkobservabilityRetina = true
    networkobservabilityHubble = false
    networkobservabilityCilium = false
    prometheuscollectorhealth = true
    controlplane-apiserver = true
    controlplane-cluster-autoscaler = true
    controlplane-kube-scheduler = false
    controlplane-kube-controller-manager = false
    controlplane-etcd = true
    acstor-capacity-provisioner = false
    acstor-metrics-exporter = false

  # Keep-lists are the primary cost and cardinality control. Without them a
  # medium cluster ingests millions of unused series per minute.
  default-targets-metrics-keep-list: |-
    kubelet = "kubelet_volume_stats_used_bytes|kubelet_volume_stats_capacity_bytes|kubelet_node_name|kubelet_running_pods|kubelet_running_containers|kubelet_pod_start_duration_seconds.*|kubelet_runtime_operations_errors_total"
    coredns = "coredns_dns_request_duration_seconds.*|coredns_dns_responses_total|coredns_panics_total|coredns_forward_healthcheck_broken_total"
    cadvisor = "container_cpu_usage_seconds_total|container_memory_working_set_bytes|container_memory_rss|container_network_receive_bytes_total|container_network_transmit_bytes_total|container_fs_usage_bytes|container_fs_limit_bytes"
    kubeproxy = ""
    apiserver = "apiserver_request_total|apiserver_request_duration_seconds.*|apiserver_current_inflight_requests|etcd_request_duration_seconds.*"
    kubestate = "kube_pod_status_phase|kube_pod_status_ready|kube_pod_container_status_restarts_total|kube_pod_container_status_waiting_reason|kube_deployment_status_replicas.*|kube_deployment_spec_replicas|kube_node_status_condition|kube_node_status_allocatable|kube_job_status_failed|kube_horizontalpodautoscaler_status_.*|kube_persistentvolumeclaim_status_phase"
    nodeexporter = "node_cpu_seconds_total|node_memory_MemAvailable_bytes|node_memory_MemTotal_bytes|node_filesystem_avail_bytes|node_filesystem_size_bytes|node_filesystem_readonly|node_load1|node_load5|node_load15|node_network_receive_bytes_total|node_network_transmit_bytes_total|node_vmstat_pgmajfault|node_disk_io_time_seconds_total"
    windowsexporter = ""
    windowskubeproxy = ""
    podannotations = ""
    kappiebasic = ""
    networkobservabilityRetina = "networkobservability.*"
    controlplane-apiserver = "apiserver_request_total|apiserver_request_duration_seconds.*|apiserver_storage_objects"
    controlplane-cluster-autoscaler = "cluster_autoscaler_unschedulable_pods_count|cluster_autoscaler_failed_scale_ups_total|cluster_autoscaler_scale_down_in_cooldown"
    controlplane-etcd = "etcd_server_has_leader|etcd_mvcc_db_total_size_in_bytes|etcd_server_proposals_failed_total|etcd_disk_wal_fsync_duration_seconds.*"
    minimalingestionprofile = "true"

  # Restricts annotation-based auto-discovery to labelled namespaces, so a
  # single misconfigured pod cannot flood the TSDB cluster-wide.
  pod-annotation-based-scraping: |-
    podannotationnamespaceregex = "checkout|payments|orders"

  prometheus-collector-settings: |-
    cluster_alias = "aks-checkout-prd-weu"
    default_metric_account_name = "amw-checkout-prd"

  debug-mode: |-
    enabled = false
```

### 8.3 Custom scrape target — `PodMonitor` CRD

```yaml
---
apiVersion: azmonitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: checkout-api-podmonitor
  namespace: kube-system   # Managed Prometheus CRs live in kube-system
  labels:
    app.kubernetes.io/part-of: checkout
spec:
  jobLabel: checkout-api
  namespaceSelector:
    matchNames:
      - checkout
  selector:
    matchLabels:
      app.kubernetes.io/name: checkout-api
      app.kubernetes.io/component: http
  podMetricsEndpoints:
    - port: metrics
      path: /metrics
      scheme: http
      interval: 30s
      scrapeTimeout: 25s
      honorLabels: false
      relabelings:
        # Promote pod labels to series labels so PromQL can group by tenant.
        - sourceLabels: [__meta_kubernetes_pod_label_tenant]
          targetLabel: tenant
          action: replace
        - sourceLabels: [__meta_kubernetes_pod_node_name]
          targetLabel: node
          action: replace
        - sourceLabels: [__meta_kubernetes_namespace]
          targetLabel: namespace
          action: replace
      metricRelabelings:
        # Drop Go runtime internals: high volume, near-zero operational value.
        - sourceLabels: [__name__]
          regex: 'go_(gc|memstats|sched)_.*'
          action: drop
        # Drop per-request-id histograms: unbounded cardinality kills the TSDB.
        - sourceLabels: [request_id]
          regex: '.+'
          action: labeldrop
---
apiVersion: azmonitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: checkout-worker-servicemonitor
  namespace: kube-system
spec:
  namespaceSelector:
    matchNames:
      - checkout
  selector:
    matchLabels:
      app.kubernetes.io/name: checkout-worker
  endpoints:
    - port: http-metrics
      path: /metrics
      interval: 30s
      scrapeTimeout: 25s
```

### 8.4 Application instrumentation — OpenTelemetry with the Azure Monitor exporter

```yaml
---
apiVersion: v1
kind: Secret
metadata:
  name: appinsights-connection
  namespace: checkout
type: Opaque
stringData:
  # Connection string, NOT an instrumentation key: ikey-only ingestion was
  # retired on 2025-03-31.
  APPLICATIONINSIGHTS_CONNECTION_STRING: >-
    InstrumentationKey=00000000-0000-0000-0000-000000000000;IngestionEndpoint=https://westeurope-5.in.applicationinsights.azure.com/;LiveEndpoint=https://westeurope.livediagnostics.monitor.azure.com/;ApplicationId=11111111-1111-1111-1111-111111111111
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: checkout-api
  namespace: checkout
  labels:
    app.kubernetes.io/name: checkout-api
spec:
  replicas: 6
  selector:
    matchLabels:
      app.kubernetes.io/name: checkout-api
  template:
    metadata:
      labels:
        app.kubernetes.io/name: checkout-api
        app.kubernetes.io/component: http
        tenant: shared
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "9090"
        prometheus.io/path: "/metrics"
    spec:
      serviceAccountName: checkout-api
      containers:
        - name: api
          image: registry.example.com/checkout/api:2026.09.1
          ports:
            - name: http
              containerPort: 8080
            - name: metrics
              containerPort: 9090
          env:
            - name: APPLICATIONINSIGHTS_CONNECTION_STRING
              valueFrom:
                secretKeyRef:
                  name: appinsights-connection
                  key: APPLICATIONINSIGHTS_CONNECTION_STRING

            # cloud_RoleName / cloud_RoleInstance: these two drive the
            # Application Map topology. Without them every service collapses
            # into one unnamed node and the map is useless.
            - name: OTEL_SERVICE_NAME
              value: checkout-api
            - name: OTEL_RESOURCE_ATTRIBUTES
              value: "service.namespace=checkout,deployment.environment=prd"
            - name: OTEL_SERVICE_INSTANCE_ID
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name

            # Head-based sampling at the SDK. 1.0 = keep everything; lower it
            # only after measuring ingestion, and always in a trace-consistent
            # sampler so spans of the same trace share the decision.
            - name: OTEL_TRACES_SAMPLER
              value: parentbased_traceidratio
            - name: OTEL_TRACES_SAMPLER_ARG
              value: "1.0"

            - name: OTEL_PROPAGATORS
              value: tracecontext,baggage
            - name: OTEL_METRICS_EXPORTER
              value: none        # metrics go to Managed Prometheus, not App Insights
            - name: OTEL_LOGS_EXPORTER
              value: azuremonitor
          resources:
            requests:
              cpu: 250m
              memory: 512Mi
            limits:
              memory: 1Gi
          readinessProbe:
            httpGet:
              path: /health/ready
              port: http
            periodSeconds: 5
          livenessProbe:
            httpGet:
              path: /health/live
              port: http
            periodSeconds: 10
```

---

## 9. CLI walkthrough

### 9.1 Provisioning and verifying the workspace

```console
$ az extension add --name log-analytics --upgrade --only-show-errors
$ az extension add --name monitor-control-service --upgrade --only-show-errors

$ az group create --name rg-observability-checkout-prd --location westeurope -o table
Location    Name
----------  -----------------------------
westeurope  rg-observability-checkout-prd

$ az deployment group create \
    --resource-group rg-observability-checkout-prd \
    --name obs-stack-2026-09-05 \
    --template-file monitoring-stack.bicep \
    --parameters workload=checkout env=prd \
                 aksClusterId=/subscriptions/8f3a.../resourceGroups/rg-aks-prd/providers/Microsoft.ContainerService/managedClusters/aks-checkout-prd-weu \
    --query "properties.provisioningState" -o tsv
Succeeded

$ az monitor log-analytics workspace show \
    --resource-group rg-observability-checkout-prd \
    --workspace-name log-checkout-prd \
    --query "{name:name, customerId:customerId, sku:sku.name, retention:retentionInDays, dailyCapGb:workspaceCapping.dailyQuotaGb, capState:workspaceCapping.dataIngestionStatus}" -o jsonc
{
  "capState": "RespectQuota",
  "customerId": "5b1f2c9e-4d7a-4a2f-9e11-c0a3f6d8b742",
  "dailyCapGb": 50.0,
  "name": "log-checkout-prd",
  "retention": 90,
  "sku": "PerGB2018"
}
```

> `dataIngestionStatus` is the field to check first when logs stop. `RespectQuota` means ingesting normally; `ForceOff` means the daily cap was hit and **data is being dropped, not queued**.

### 9.2 Inspecting table plans

```console
$ az monitor log-analytics workspace table list \
    --resource-group rg-observability-checkout-prd \
    --workspace-name log-checkout-prd \
    --query "[?plan!=null].{Table:name, Plan:plan, Interactive:retentionInDays, Total:totalRetentionInDays}" \
    -o table
Table                      Plan       Interactive    Total
-------------------------  ---------  -------------  -------
AppRequests                Analytics  90             730
AppDependencies            Analytics  90             90
AppExceptions              Analytics  90             90
AppTraces                  Analytics  90             90
ContainerLogV2             Basic      30             365
KubeEvents                 Analytics  90             90
KubePodInventory           Analytics  90             90
Heartbeat                  Analytics  90             90
Perf                       Analytics  90             90
Syslog                     Analytics  90             90
AzureActivity              Analytics  90             90
CheckoutAudit_CL           Analytics  730            2555

$ az monitor log-analytics workspace table update \
    --resource-group rg-observability-checkout-prd \
    --workspace-name log-checkout-prd \
    --name AppDependencies \
    --plan Basic \
    --total-retention-time 365 \
    --query "{table:name, plan:plan}" -o jsonc
{
  "plan": "Basic",
  "table": "AppDependencies"
}
```

### 9.3 Data collection rules and their associations

```console
$ az monitor data-collection rule list \
    --resource-group rg-observability-checkout-prd \
    --query "[].{Name:name, Kind:kind, Endpoint:dataCollectionEndpointId!=null, Flows:length(dataFlows)}" -o table
Name                             Kind    Endpoint    Flows
-------------------------------  ------  ----------  -------
dcr-linux-host-checkout-prd      Linux   True        2
MSCI-westeurope-checkout-prd     Linux   False       2
dcr-audit-checkout-prd           Direct  True        1

$ az monitor data-collection rule association list \
    --resource /subscriptions/8f3a.../resourceGroups/rg-app-prd/providers/Microsoft.Compute/virtualMachines/vm-worker-01 \
    --query "[].{Association:name, Rule:dataCollectionRuleId}" -o table
Association                  Rule
---------------------------  --------------------------------------------------------------------------------
dcra-linux-host              /subscriptions/8f3a.../dataCollectionRules/dcr-linux-host-checkout-prd

$ az vm extension show \
    --resource-group rg-app-prd \
    --vm-name vm-worker-01 \
    --name AzureMonitorLinuxAgent \
    --query "{name:name, version:typeHandlerVersion, autoUpgrade:enableAutomaticUpgrade, state:provisioningState}" -o jsonc
{
  "autoUpgrade": true,
  "name": "AzureMonitorLinuxAgent",
  "provisioningState": "Succeeded",
  "state": "Succeeded",
  "version": "1.33"
}
```

### 9.4 Querying logs from the CLI

```console
$ WS=$(az monitor log-analytics workspace show -g rg-observability-checkout-prd \
        -n log-checkout-prd --query customerId -o tsv)

$ az monitor log-analytics query --workspace "$WS" --analytics-query '
Heartbeat
| where TimeGenerated > ago(30m)
| summarize LastSeen = max(TimeGenerated), Agent = any(Version) by Computer
| extend MinutesStale = datetime_diff("minute", now(), LastSeen)
| where MinutesStale > 5
| project Computer, Agent, LastSeen, MinutesStale
| order by MinutesStale desc
' -o table
Computer          Agent    LastSeen                       MinutesStale
----------------  -------  -----------------------------  --------------
vm-worker-07      1.33.0   2026-09-05T09:41:12.4130000Z   23
vm-worker-11      1.31.4   2026-09-05T09:47:03.9820000Z   17
arc-onprem-db02   1.29.5   2026-09-05T08:12:55.1010000Z   112

$ az monitor log-analytics query --workspace "$WS" --analytics-query '
Usage
| where TimeGenerated > ago(7d)
| where IsBillable == true
| summarize BillableGB = round(sum(Quantity) / 1000, 2) by DataType
| order by BillableGB desc
| take 10
' -o table
DataType             BillableGB
-------------------  ------------
ContainerLogV2       412.87
AppDependencies      188.34
AzureDiagnostics     97.51
AppTraces            64.02
Perf                 41.19
AppRequests          33.66
KubePodInventory     22.90
Syslog               14.75
KubeEvents           6.31
AzureActivity        1.08
```

### 9.5 Metrics from the CLI

```console
$ az monitor metrics list-definitions \
    --resource /subscriptions/8f3a.../providers/Microsoft.Insights/components/appi-checkout-prd \
    --query "[?contains(name.value,'requests')].{Metric:name.value, Unit:unit, Aggs:join(',',supportedAggregationTypes)}" -o table
Metric                      Unit            Aggs
--------------------------  --------------  ----------------------------
requests/count              Count           None,Count
requests/duration           MilliSeconds    None,Average,Minimum,Maximum
requests/failed             Count           None,Count
requests/rate               CountPerSecond  None,Average

$ az monitor metrics list \
    --resource /subscriptions/8f3a.../providers/Microsoft.Insights/components/appi-checkout-prd \
    --metric "requests/duration" \
    --aggregation Average Maximum \
    --interval PT5M \
    --start-time 2026-09-05T08:00:00Z \
    --end-time   2026-09-05T09:00:00Z \
    --query "value[0].timeseries[0].data[].{Time:timeStamp, AvgMs:average, MaxMs:maximum}" -o table
Time                        AvgMs      MaxMs
--------------------------  ---------  ---------
2026-09-05T08:00:00Z        184.21     1102.40
2026-09-05T08:05:00Z        191.88     1340.77
2026-09-05T08:10:00Z        203.14      987.65
2026-09-05T08:15:00Z       1471.09    14882.31
2026-09-05T08:20:00Z       1688.53    18204.66
2026-09-05T08:25:00Z       1702.77    17993.02
2026-09-05T08:30:00Z        412.66     3011.90
2026-09-05T08:35:00Z        197.02     1188.44
```

### 9.6 Alert state

```console
$ az monitor metrics alert list \
    --resource-group rg-observability-checkout-prd \
    --query "[].{Name:name, Sev:severity, Enabled:enabled, Freq:evaluationFrequency, Window:windowSize}" -o table
Name                                       Sev    Enabled    Freq    Window
-----------------------------------------  -----  ---------  ------  --------
alert-checkout-prd-p95-latency             2      True       PT1M    PT5M
alert-checkout-prd-failed-requests-anomaly 1      True       PT5M    PT15M
alert-checkout-prd-availability            0      True       PT1M    PT5M

$ az monitor activity-log alert list \
    --query "[].{Name:name, Enabled:enabled, Category:condition.allOf[0].equals}" -o table
Name                                Enabled    Category
----------------------------------  ---------  ---------------
alert-service-health                True       ServiceHealth
alert-resource-health-unavailable   True       ResourceHealth
alert-advisor-high-impact           True       Recommendation
alert-destructive-network-op        True       Administrative

$ az rest --method get \
    --url "https://management.azure.com/subscriptions/8f3a.../providers/Microsoft.AlertsManagement/alerts?api-version=2019-03-01&timeRange=1d&alertState=New" \
    --query "value[].{Name:properties.essentials.alertRule, Sev:properties.essentials.severity, State:properties.essentials.monitorCondition, Fired:properties.essentials.startDateTime}" -o table
Name                                       Sev    State    Fired
-----------------------------------------  -----  -------  ----------------------------
alert-checkout-prd-p95-latency             Sev2   Fired    2026-09-05T08:18:44.1220000Z
alert-checkout-prd-failed-requests-anomaly Sev1   Fired    2026-09-05T08:21:10.6650000Z
alert-service-health                       Sev1   Fired    2026-09-05T08:16:02.0000000Z
```

### 9.7 Service Health and Resource Health from the CLI

```console
$ az monitor activity-log list \
    --offset 24h \
    --query "[?category.value=='ServiceHealth'].{Service:properties.impactedServices, Type:properties.incidentType, Stage:properties.stage, Title:properties.title, Time:eventTimestamp}" \
    -o json | head -40
[
  {
    "Service": "[{\"ServiceName\":\"Application Gateway\",\"ImpactedRegions\":[{\"RegionName\":\"West Europe\"}]}]",
    "Stage": "Active",
    "Time": "2026-09-05T08:16:02.0000000Z",
    "Title": "Application Gateway - West Europe - Investigating",
    "Type": "Incident"
  }
]

$ az rest --method get \
    --url "https://management.azure.com/subscriptions/8f3a.../resourceGroups/rg-app-prd/providers/Microsoft.Compute/virtualMachines/vm-worker-07/providers/Microsoft.ResourceHealth/availabilityStatuses/current?api-version=2023-07-01-preview" \
    --query "properties.{Status:availabilityState, Summary:summary, Cause:reasonType, Since:occuredTime, Reported:reportedTime}" -o jsonc
{
  "Cause": "Unplanned",
  "Reported": "2026-09-05T09:52:07.8814523Z",
  "Since": "2026-09-05T09:38:44.0000000Z",
  "Status": "Unavailable",
  "Summary": "We're sorry, your virtual machine isn't available because of an unexpected host failure. Azure has begun the auto-recovery process."
}
```

### 9.8 Advisor from the CLI

```console
$ az advisor recommendation list \
    --category HighAvailability \
    --query "[].{Impact:impact, Resource:impactedValue, Problem:shortDescription.problem}" -o table
Impact    Resource                 Problem
--------  -----------------------  ---------------------------------------------------------------
High      aks-checkout-prd-weu     Enable Autoscaling for your system node pool
High      psql-checkout-prd        Enable geo-redundant backup for the flexible server
Medium    st-checkout-artifacts    Use zone-redundant storage for critical data
Medium    vmss-worker-prd          Add instances to your Virtual Machine Scale Set

$ az advisor recommendation list --category Cost \
    --query "[].{Impact:impact, Resource:impactedValue, Savings:extendedProperties.savingsAmount, Currency:extendedProperties.savingsCurrency, Problem:shortDescription.problem}" -o table
Impact    Resource                 Savings    Currency    Problem
--------  -----------------------  ---------  ----------  -----------------------------------------
High      subscription             4127.64    EUR         Buy virtual machine reserved instances
Medium    vm-batch-04              218.90     EUR         Right-size or shut down underutilized VM
Medium    disk-orphan-091          64.22      EUR         Delete unattached Premium SSD disks
Low       pip-legacy-lb            11.06      EUR         Delete idle public IP addresses

$ az rest --method get \
    --url "https://management.azure.com/subscriptions/8f3a.../providers/Microsoft.Advisor/advisorScore?api-version=2023-01-01" \
    --query "value[].{Category:name, Score:properties.lastRefreshedScore.score, Potential:properties.lastRefreshedScore.potentialScoreIncrease}" -o table
Category            Score    Potential
------------------  -------  -----------
Advisor             71.40    28.60
Cost                88.12    11.88
HighAvailability    62.05    37.95
OperationalExcellence 79.33  20.67
Performance         84.77    15.23
Security            58.90    41.10
```

### 9.9 Managed Prometheus on the cluster

```console
$ kubectl get pods -n kube-system -l rsName=ama-metrics -o wide
NAME                           READY   STATUS    RESTARTS   AGE   IP             NODE
ama-metrics-6b7d9f4c88-2xq7k   2/2     Running   0          6d    10.244.3.117   aks-sys-31882043-vmss000001
ama-metrics-6b7d9f4c88-r4mzp   2/2     Running   0          6d    10.244.1.204   aks-sys-31882043-vmss000000

$ kubectl get ds -n kube-system ama-metrics-node ama-logs
NAME               DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   AGE
ama-metrics-node   9         9         9       9            9           6d
ama-logs           9         9         9       9            9           6d

$ kubectl exec -n kube-system ama-metrics-6b7d9f4c88-2xq7k -c prometheus-collector -- \
    curl -s http://localhost:9090/api/v1/targets | jq -r '
      .data.activeTargets[] | "\(.labels.job)\t\(.health)\t\(.lastError)"' | sort | uniq -c | sort -rn
     18 kubernetes-pods	up	
      9 node	up	
      2 kube-state-metrics	up	
      2 coredns	up	
      1 kube-apiserver	up	
      1 checkout-api	down	server returned HTTP status 503 Service Unavailable

$ kubectl logs -n kube-system ama-metrics-6b7d9f4c88-2xq7k -c prometheus-collector --tail=6
2026-09-05T09:55:12.104Z	info	Scrape config loaded: 6 jobs, 33 targets
2026-09-05T09:55:12.219Z	info	Remote write endpoint: https://amw-checkout-prd-xy4z.westeurope.prometheus.monitor.azure.com/dataCollectionRules/dcr-abc.../streams/Microsoft-PrometheusMetrics/api/v1/write
2026-09-05T09:55:42.881Z	info	remote_write: sent batch	series=48211	duration=182ms	status=200
2026-09-05T09:56:12.903Z	info	remote_write: sent batch	series=48355	duration=176ms	status=200
2026-09-05T09:56:22.117Z	warn	scrape_pool=checkout-api target=10.244.5.31:9090 msg="Scrape failed" err="server returned HTTP status 503 Service Unavailable"
2026-09-05T09:56:42.874Z	info	remote_write: sent batch	series=48190	duration=190ms	status=200
```

---

## 10. KQL for diagnosis

### 10.1 End-to-end transaction reconstruction

```kusto
// Reconstruct the full call tree for the slowest checkout requests in the
// incident window, including every downstream dependency and exception.
let window = datetime(2026-09-05 08:15:00) .. datetime(2026-09-05 08:35:00);
let slowOps =
    AppRequests
    | where TimeGenerated between (window)
    | where AppRoleName == "checkout-api"
    | where Name == "POST /api/v2/orders"
    | where DurationMs > 5000
    | top 25 by DurationMs desc
    | project OperationId, RootDuration = DurationMs, ResultCode, ClientIP;
slowOps
| join kind=leftouter (
    AppDependencies
    | where TimeGenerated between (window)
    | project OperationId, DepTarget = Target, DepType = DependencyType,
              DepName = Name, DepMs = DurationMs, DepSuccess = Success
  ) on OperationId
| join kind=leftouter (
    AppExceptions
    | where TimeGenerated between (window)
    | summarize Exceptions = make_set(ExceptionType, 5) by OperationId
  ) on OperationId
| project OperationId, RootDuration, ResultCode, DepType, DepTarget, DepName,
          DepMs, DepSuccess, Exceptions
| order by RootDuration desc, DepMs desc
```

```
OperationId                       RootDuration  ResultCode  DepType     DepTarget                  DepName                    DepMs    DepSuccess  Exceptions
--------------------------------  ------------  ----------  ----------  -------------------------  -------------------------  -------  ----------  -----------------------------
a41f9c0b7e2d4f118a3c6e5b9d02f713  18204         502         SQL         psql-checkout-prd          SELECT orders.reserve      17886    false       ["Npgsql.NpgsqlException"]
a41f9c0b7e2d4f118a3c6e5b9d02f713  18204         502         HTTP        payments.internal          POST /v1/authorize            41    true        ["Npgsql.NpgsqlException"]
c8b2e5417a9d40f3b6c1d8e2f5a70941  17993         502         SQL         psql-checkout-prd          SELECT orders.reserve      17640    false       ["Npgsql.NpgsqlException"]
3e7d1a80f5c94b22ae6f0c9d4b81e625  14882         500         SQL         psql-checkout-prd          UPDATE inventory.hold      14522    false       ["Npgsql.NpgsqlException"]
```

The dependency rows localise the problem to PostgreSQL in ~15 seconds of query time. That is what "logs answer question 3" means concretely.

### 10.2 Correct rates under sampling

```kusto
// WRONG under sampling: count() ignores itemCount and undercounts by the
// sampling factor. RIGHT: sum(itemCount) reconstructs the true population.
AppRequests
| where TimeGenerated > ago(6h)
| where AppRoleName == "checkout-api"
| summarize
    SampledRows   = count(),
    TrueRequests  = sum(ItemCount),
    TrueFailures  = sumif(ItemCount, Success == false),
    SamplingRatio = round(todouble(count()) / todouble(sum(ItemCount)), 4)
    by bin(TimeGenerated, 15m)
| extend ErrorRatePct = round(100.0 * TrueFailures / TrueRequests, 3)
| order by TimeGenerated asc
```

```
TimeGenerated          SampledRows  TrueRequests  TrueFailures  SamplingRatio  ErrorRatePct
---------------------  -----------  ------------  ------------  -------------  ------------
2026-09-05 04:00:00    22140        22140         14            1.0000         0.063
2026-09-05 04:15:00    21987        21987         11            1.0000         0.050
2026-09-05 08:15:00     9812        188406        13977         0.0521         7.419
2026-09-05 08:30:00     9744        174022         9218         0.0560         5.297
2026-09-05 08:45:00    23110         23110           31         1.0000         0.134
```

`SamplingRatio` collapsing from 1.0 to 0.05 is adaptive sampling reacting to load — expected behaviour, and the reason `count()` would have reported a *drop* in traffic during a traffic *surge*.

### 10.3 Ingestion latency

```kusto
// ingestion_time() is a system function returning when the row landed in the
// workspace, as opposed to TimeGenerated (when the event happened).
// The delta is the true observability latency of your pipeline.
union withsource=SourceTable
    AppRequests, ContainerLogV2, Syslog, Perf, AzureActivity, Heartbeat
| where TimeGenerated > ago(2h)
| extend LatencySec = datetime_diff("second", ingestion_time(), TimeGenerated)
| summarize
    p50 = percentile(LatencySec, 50),
    p95 = percentile(LatencySec, 95),
    p99 = percentile(LatencySec, 99),
    max = max(LatencySec),
    rows = count()
    by SourceTable
| order by p95 desc
```

```
SourceTable       p50   p95    p99     max     rows
----------------  ----  -----  ------  ------  ---------
ContainerLogV2    94    412    1103    3877    18442190
Syslog            61    188     406    1244      882014
AzureActivity     58    170     311     622        4118
Perf              47    121     240     498     1204776
AppRequests       38     97     185     402     2210945
Heartbeat         31     72     140     288      129600
```

> Any log search alert with `evaluationFrequency` shorter than the p95 ingestion latency of its source table will evaluate against incomplete data and produce false negatives.

### 10.4 Cost attribution

```kusto
// Bill the workspace back to the teams that fill it. Requires
// enrich_container_logs = true so PodNamespace is present.
ContainerLogV2
| where TimeGenerated > ago(7d)
| summarize
    Rows  = count(),
    Bytes = sum(estimate_data_size(LogMessage) + estimate_data_size(ContainerName))
    by PodNamespace
| extend GB = round(Bytes / 1024.0 / 1024.0 / 1024.0, 2)
| extend PctOfTotal = round(100.0 * GB / toscalar(
        ContainerLogV2
        | where TimeGenerated > ago(7d)
        | summarize sum(estimate_data_size(LogMessage)) / 1024.0 / 1024.0 / 1024.0), 1)
| project PodNamespace, Rows, GB, PctOfTotal
| order by GB desc
| take 10
```

```
PodNamespace     Rows        GB       PctOfTotal
---------------  ----------  -------  -----------
checkout         6218440     141.22   34.2
payments         4901112      98.77   23.9
orders           3117092      71.03   17.2
search           1884201      44.16   10.7
notifications     980417      22.90    5.5
identity          611330      18.04    4.4
istio-system      408119      11.67    2.8
```

### 10.5 Workspace health and dropped data

```kusto
// _LogOperation surfaces workspace-level problems the portal does not
// prominently show: ingestion throttling, daily cap hits, invalid data.
_LogOperation
| where TimeGenerated > ago(7d)
| summarize Occurrences = count(), LastSeen = max(TimeGenerated), Sample = any(Detail)
    by Category, Operation, Level
| order by Occurrences desc
```

```
Category    Operation                Level    Occurrences  LastSeen                 Sample
----------  -----------------------  -------  -----------  -----------------------  -----------------------------------------------------
Ingestion   Data collection          Warning  412          2026-09-05 02:51:33      Data collection stopped due to daily limit of 50 GB
Ingestion   Ingestion rate           Warning  88           2026-09-04 21:14:02      Ingestion rate exceeded 6 GB/min; data was throttled
Solution    Data collection          Error    12           2026-09-03 11:07:41      Invalid custom log format for stream Custom-CheckoutAudit
```

The first row is the incident from §1.1: the workspace stopped ingesting at 02:51 because of the daily cap, so the 03:14 outage has no logs. `_LogOperation` would have said so in five seconds.

---

## 11. Verification and failure diagnosis playbook

### 11.1 The verification ladder — run in this order

| Rung | Question | Command / query | Pass condition |
|---|---|---|---|
| 0 | Does the resource exist? | `az resource show --ids <id>` | `provisioningState: Succeeded` |
| 1 | Is telemetry configured at all? | `az monitor diagnostic-settings list --resource <id>` | At least one setting, correct destination |
| 2 | Is the agent alive? | `Heartbeat \| where Computer == "x" \| top 1 by TimeGenerated` | Row within the last 5 minutes |
| 3 | Is the agent *assigned work*? | `az monitor data-collection rule association list --resource <id>` | At least one association |
| 4 | Is data landing? | `<Table> \| where TimeGenerated > ago(15m) \| count` | Non-zero |
| 5 | Is the workspace ingesting? | `_LogOperation \| where Level != "Info"` | No `daily limit` / `throttled` rows |
| 6 | Is the alert rule evaluating? | Portal → rule → **History**, or `az monitor scheduled-query show` | Recent evaluations, no `Failed` |
| 7 | Is the action group reachable? | Portal → action group → **Test**, or check `AlertHistory` | Delivery `Succeeded` |

Diagnosing top-down is a mistake: "the alert didn't fire" is rung 6, but the cause is almost always at rung 3 or 5.

### 11.2 Failure mode catalogue

#### FM-1 — Diagnostic setting exists, table is empty

**Symptom:** `az monitor diagnostic-settings list` shows a setting; the KQL table returns 0 rows.

**Causes, in order of frequency:**

1. **Category enabled but the resource emits nothing.** Many categories only produce rows on activity. An Application Gateway with no traffic writes no `AGWAccessLogs`.
2. **`logAnalyticsDestinationType` mismatch.** With `Dedicated` the rows go to `AGWAccessLogs`; without it, to `AzureDiagnostics`. Query both:
   ```kusto
   union isfuzzy=true AzureDiagnostics, AGWAccessLogs
   | where TimeGenerated > ago(1h)
   | summarize count() by $table, Category = column_ifexists("Category", "n/a")
   ```
3. **Wrong workspace.** Two workspaces with similar names; the setting points at the other one.
   ```console
   $ az monitor diagnostic-settings list --resource "$RID" \
       --query "value[].{Setting:name, Workspace:workspaceId}" -o table
   ```
4. **First-write latency.** A brand-new category can take up to ~15 minutes to appear, and the table itself does not exist in the schema until the first row arrives — a query against a never-populated table fails with `Failed to resolve table or column expression`, which is *not* the same as returning zero rows. Use `union isfuzzy=true` to distinguish.

#### FM-2 — AMA heartbeat present, no Perf/Syslog data

This is the DCR-association failure, and it is the most common AMA problem because the agent looks perfectly healthy.

```console
$ az monitor data-collection rule association list --resource "$VMID" -o table
# Empty output → the agent has no instructions. It will heartbeat forever.

$ az monitor data-collection rule association create \
    --name dcra-linux-host \
    --rule-id /subscriptions/8f3a.../dataCollectionRules/dcr-linux-host-checkout-prd \
    --resource "$VMID" \
    --query "{name:name, state:provisioningState}" -o jsonc
{
  "name": "dcra-linux-host",
  "state": "Succeeded"
}
```

On the VM itself:

```console
$ sudo systemctl status azuremonitoragent --no-pager
● azuremonitoragent.service - Azure Monitor Agent
     Loaded: loaded (/lib/systemd/system/azuremonitoragent.service; enabled)
     Active: active (running) since Sat 2026-08-30 04:12:07 UTC; 6 days ago
   Main PID: 1187 (agentlauncher)
      Tasks: 62 (limit: 19093)
     Memory: 214.8M

$ sudo tail -n 8 /var/opt/microsoft/azuremonitoragent/log/mdsd.err
2026-09-05T09:12:44.1821Z ERR  Failed to fetch configuration from
  https://global.handler.control.monitor.azure.com/agentConfigurations
  : Connection timed out after 30000 ms
2026-09-05T09:13:14.9903Z WARN Retrying config fetch (attempt 4/10)

$ curl -sS -o /dev/null -w '%{http_code}\n' \
    https://global.handler.control.monitor.azure.com/ping
000
```

**Root cause:** egress firewall / NSG / UDR blocking the AMA control and ingestion endpoints. Required outbound FQDNs:

| Purpose | FQDN pattern | Port |
|---|---|---|
| Agent configuration (control) | `global.handler.control.monitor.azure.com`, `<region>.handler.control.monitor.azure.com` | 443 |
| Log ingestion | `<workspace-id>.ods.opinsights.azure.com` | 443 |
| DCE ingestion | `<dce>-<hash>.<region>.ingest.monitor.azure.com` | 443 |
| Entra ID (managed identity token) | `login.microsoftonline.com` | 443 |
| Metrics ingestion | `<region>.monitoring.azure.com` | 443 |

Two additional prerequisites that fail silently: the VM must have a **managed identity** (system- or user-assigned), and the transport must negotiate **TLS 1.2 or higher**.

#### FM-3 — Application Insights telemetry missing or thinned

Decision tree:

```
No telemetry at all?
├── Connection string set?                        → check APPLICATIONINSIGHTS_CONNECTION_STRING
│   └── Using only an instrumentation key?        → ikey ingestion retired 2025-03-31. Migrate.
├── Egress to <region>.in.applicationinsights.azure.com allowed on 443?
├── DisableLocalAuth = true and no Entra token?   → MonitoringMetricsPublisher role required
└── Daily cap hit?                                → check below

Some telemetry, incomplete traces?
├── Adaptive sampling engaged?                    → sum(itemCount), check SamplingRatio
├── traceparent stripped by a proxy/gateway?      → orphan operation_Id fragments
└── Queue/async hop losing context?               → manual context propagation needed
```

```console
$ az monitor app-insights component show \
    -g rg-observability-checkout-prd -a appi-checkout-prd \
    --query "{ingestion:IngestionMode, workspace:WorkspaceResourceId, sampling:SamplingPercentage, localAuth:DisableLocalAuth}" -o jsonc
{
  "ingestion": "LogAnalytics",
  "localAuth": true,
  "sampling": 100.0,
  "workspace": "/subscriptions/8f3a.../workspaces/log-checkout-prd"
}

$ az monitor app-insights component billing show \
    -g rg-observability-checkout-prd -a appi-checkout-prd -o jsonc
{
  "currentBillingFeatures": [ "Basic" ],
  "dataVolumeCap": {
    "cap": 30.0,
    "maxHistoryCap": 100.0,
    "resetTime": 24,
    "stopSendNotificationWhenHitCap": true,
    "warningThreshold": 90
  }
}
```

> `dataVolumeCap.cap: 30.0` on a workspace-based component is a per-component daily cap **in addition to** the workspace cap. Hitting either stops ingestion. Two independent caps, two independent ways to lose your incident data.

Verify the sampling in effect right now:

```kusto
AppRequests
| where TimeGenerated > ago(1h)
| summarize Retained = count(), Actual = sum(ItemCount)
| extend EffectiveSamplingPct = round(100.0 * Retained / Actual, 2)
```

#### FM-4 — Log search alert never fires

| Check | How | Why it fails |
|---|---|---|
| Query returns rows at all | Run it in Logs with the exact `windowSize` as the time range | The query is right, the window is too short for the ingestion latency |
| Time filter conflict | Remove any `ago()` inside the query | The rule applies `windowSize` *and* your `ago()`; the intersection can be empty |
| `resourceIdColumn` present | `| project _ResourceId, ...` must survive the summarize | Without `_ResourceId` the alert cannot scope, and dimension splitting silently yields nothing |
| Threshold direction | `operator: GreaterThan`, `threshold: 0` | `GreaterThanOrEqual 0` fires permanently |
| `failingPeriods` | `minFailingPeriodsToAlert` ≤ `numberOfEvaluationPeriods` | Misconfigured, it can never be satisfied |
| Rule health | Portal → rule → **History** tab | Query cost/timeout failures show here and nowhere else |
| Alert processing rule | `az rest` on `Microsoft.AlertsManagement/actionRules` | A forgotten suppression window is muting it |

```console
$ az monitor scheduled-query show \
    -g rg-observability-checkout-prd -n alert-checkout-prd-pod-crashloop \
    --query "{enabled:enabled, freq:evaluationFrequency, window:windowSize, autoMitigate:autoMitigate, actions:actions.actionGroups}" -o jsonc
{
  "actions": [
    "/subscriptions/8f3a.../actionGroups/ag-checkout-prd-ticket"
  ],
  "autoMitigate": true,
  "enabled": true,
  "freq": "PT5M",
  "window": "PT15M"
}
```

#### FM-5 — Alert fires, nobody is notified

```console
$ az monitor action-group test-notifications create \
    --action-group-name ag-checkout-prd-page \
    --resource-group rg-observability-checkout-prd \
    --alert-type servicehealth \
    --notification-type Email Name=sre-oncall-email EmailAddress=sre-oncall@example.com \
    -o jsonc
{
  "actionDetails": [
    {
      "MechanismType": "Email",
      "Name": "sre-oncall-email",
      "SendTime": "2026-09-05T10:04:11.7729Z",
      "Status": "Succeeded"
    }
  ],
  "completedTime": "2026-09-05T10:04:14.1102Z",
  "context": { "notificationSource": "Microsoft.Insights/TestNotification" }
}
```

Failure causes, ranked: webhook returning non-2xx (retried, then dropped); email rate limit exceeded (>100/hr to one address); SMS carrier filtering; the Azure mobile app receiver bound to an Entra user who has left; an alert processing rule with `RemoveAllActionGroups` still in effect after a maintenance window.

#### FM-6 — Managed Prometheus target missing

```console
$ kubectl get configmap ama-metrics-settings-configmap -n kube-system -o yaml | \
    grep -A2 'podannotationnamespaceregex'
    podannotationnamespaceregex = "checkout|payments|orders"

$ kubectl port-forward -n kube-system ama-metrics-6b7d9f4c88-2xq7k 9090:9090 >/dev/null 2>&1 &
$ curl -s localhost:9090/api/v1/targets | jq -r '
    .data.droppedTargets[]? | .discoveredLabels["__meta_kubernetes_pod_name"]' | head
checkout-worker-7d9b4f6c5-hkq22
checkout-worker-7d9b4f6c5-p2v8n
```

Ranked causes: (1) the metric is filtered out by the `default-targets-metrics-keep-list` regex; (2) the pod's namespace is not in `podannotationnamespaceregex`; (3) the `PodMonitor` CR was created in the workload namespace instead of `kube-system`; (4) the AKS cluster identity lacks **Monitoring Metrics Publisher** on the Azure Monitor workspace DCR — remote-write then returns 403 and the collector logs it once per batch.

#### FM-7 — Ingestion cost spike

```kusto
// Week-over-week volume delta per table, to find what changed.
let thisWeek = Usage | where TimeGenerated between (ago(7d) .. now())
    | where IsBillable | summarize GB_now = sum(Quantity)/1000 by DataType;
let lastWeek = Usage | where TimeGenerated between (ago(14d) .. ago(7d))
    | where IsBillable | summarize GB_prev = sum(Quantity)/1000 by DataType;
thisWeek
| join kind=fullouter lastWeek on DataType
| extend DataType = coalesce(DataType, DataType1)
| extend GB_now = coalesce(GB_now, 0.0), GB_prev = coalesce(GB_prev, 0.0)
| extend DeltaGB = round(GB_now - GB_prev, 2),
         DeltaPct = iff(GB_prev == 0, 999.0, round(100.0*(GB_now-GB_prev)/GB_prev, 1))
| where abs(DeltaGB) > 1
| project DataType, GB_prev = round(GB_prev,2), GB_now = round(GB_now,2), DeltaGB, DeltaPct
| order by DeltaGB desc
```

```
DataType          GB_prev   GB_now    DeltaGB   DeltaPct
----------------  --------  --------  --------  ---------
AppDependencies    41.20     188.34    147.14     357.1
ContainerLogV2    398.11     412.87     14.76       3.7
AzureDiagnostics   62.04      97.51     35.47      57.2
Perf               40.88      41.19      0.31       0.8
```

A 357% jump in `AppDependencies` in one week is a deploy that turned on verbose dependency tracking, or a retry loop. Mitigations in order of preference: **DCR `transformKql` filter** (free, drops before billing) → **table plan change to Basic** → **SDK-side sampling** → **daily cap** (last resort: it drops *everything*, including the telemetry you need).

### 11.3 Cost-control levers, ranked

| Lever | Reduces ingest? | Loses data? | Effort | Notes |
|---|---|---|---|---|
| DCR `transformKql` filter | ✅ Before billing | Only what you filtered | Low | Best ratio in the product |
| Container Insights `exclude_namespaces` | ✅ | That namespace's stdout | Low | Kill `kube-system` chatter first |
| Managed Prometheus keep-lists | ✅ | Unlisted series | Low | Cardinality is the real cost driver |
| `kube-audit` off, `kube-audit-admin` on | ✅ Massively | Read operations in the audit trail | Low | Usually the single largest AKS log |
| Table plan → Basic | ✅ ~75% of ingest cost | Alerting + full KQL on that table | Medium | Audit alert rules first |
| Table plan → Auxiliary | ✅ ~98% | Alerting, joins, performance | Medium | Compliance archives only |
| SDK sampling | ✅ | Individual items (rates stay correct via `itemCount`) | Medium | Adaptive is on by default in .NET |
| Commitment tier | ❌ | ❌ | Low | Pure discount above ~100 GB/day |
| Diagnostic setting → Storage instead of LAW | ✅ | Queryability | Low | Compliance-only data |
| Daily cap | ✅ | **Everything after the cap** | Low | Safety net, never a strategy |

---

## 12. Visualization surfaces

| Surface | Data sources | Sharing / RBAC | Parameterization | Best for |
|---|---|---|---|---|
| **Metrics Explorer** | Metrics only | Portal RBAC | Minimal | Ad-hoc metric investigation |
| **Log Analytics query view** | Logs | Workspace/resource RBAC | None | Ad-hoc KQL |
| **Azure Dashboard** | Metrics, logs, resource tiles | Shared as an ARM resource | None | At-a-glance NOC screen |
| **Workbook** | Logs, metrics, ARG, Alerts, custom endpoints | ARM resource, RBAC | ✅ Rich parameters, conditional sections, tabs | Runbook-as-a-document, cost reports, cross-source reports |
| **Azure Managed Grafana** | Azure Monitor, Managed Prometheus, non-Azure sources | Grafana RBAC + Entra | ✅ Template variables | Kubernetes SRE dashboards, mixed-cloud |
| **Power BI** | Log Analytics export | Power BI licensing | ✅ | Executive/business reporting |

The practical split: **Grafana for real-time operations** (PromQL, per-cluster, per-pod, refreshed every 30 s), **Workbooks for anything that combines logs, metrics, and Azure Resource Graph** (Grafana cannot easily join `AppRequests` to a KQL join to an ARG query), **Dashboards for the wall screen**.

---

## 13. Comparative summary of the whole toolchain

| Tool | Answers | Scope | Data horizon | Cost | Configuration required |
|---|---|---|---|---|---|
| **Azure Status** | Is Azure broken, globally? | Public | Live + recent | Free | None |
| **Service Health** | Does the incident affect me? | Subscription | Event history window | Free | Alert rule to be notified |
| **Resource Health** | Is *this* resource healthy? | Resource | 30 days | Free | Alert rule to be notified |
| **Azure Advisor** | Am I configured badly? | Sub / RG / resource | Rolling (7–60 day utilization) | Free | None; alerts optional |
| **Azure Monitor Metrics** | Is a number out of range? | Resource | 93 days | Platform metrics free | None for platform metrics |
| **Log Analytics** | What exactly happened? | Workspace | 30 d → 12 y | Per GB + retention | Diagnostic settings, DCRs |
| **Application Insights** | Which request, which dependency, which exception? | Application | Per workspace retention | Per GB (via workspace) | SDK / OTel / auto-instrumentation |
| **Managed Prometheus** | Kubernetes/workload SLIs in PromQL | Azure Monitor workspace | 18 months | Per sample + query | AKS add-on + ConfigMaps/CRDs |
| **Azure Monitor alerts** | Tell me when | Any of the above | — | Per rule / per time series | Rules + action groups |
| **Managed Grafana** | Show me | Multi-source | — | Per instance | Data source + dashboards |

### Decision guide

```
Need to know about an Azure platform problem?
├── Affects everyone, no sign-in?                → Azure Status
├── Affects my subscription's services/regions?  → Service Health  (+ Activity Log alert)
└── Affects one specific resource I own?         → Resource Health (+ Activity Log alert)

Need to know about MY workload?
├── A number crossing a threshold, fast?         → Metric alert
│   └── Threshold varies by time of day?         → Dynamic threshold
├── Kubernetes workload SLI in PromQL?           → Managed Prometheus + prometheusRuleGroups
├── A text pattern / cross-table correlation?    → Log search alert (accept ingestion latency)
├── Which request failed and why?                → Application Insights transaction search
└── Is the site reachable from outside?          → Standard availability test + webtest alert

Need to know what I should improve?
└── Azure Advisor  (Reliability / Security / Performance / Cost / Operational Excellence)
```

---

## 14. AZ-900 exam mapping

| Exam statement | One-line answer to memorize |
|---|---|
| Purpose of **Azure Advisor** | Free, personalized recommendations across **Reliability, Security, Performance, Cost, Operational Excellence**, based on the Well-Architected Framework. |
| Purpose of **Azure Service Health** | Personalized view of the health of **Azure services and regions you use** — service issues, planned maintenance, health advisories, security advisories. Alertable via Activity Log. |
| **Azure Status** vs Service Health vs Resource Health | Status = public/global. Service Health = your subscription. Resource Health = one specific resource. |
| Purpose of **Azure Monitor** | The full-stack platform that **collects, analyzes, and acts on telemetry** from Azure, other clouds, and on-premises. |
| **Log Analytics** | The tool/workspace for **writing and running KQL queries against log data**. |
| **Azure Monitor alerts** | Proactive notification/automation when a condition is met; delivery via **action groups**. |
| **Application Insights** | The **APM** feature of Azure Monitor: availability, performance, failures, usage of a live web application. |
| Are logs collected by default? | **No.** Platform metrics and the Activity Log are on by default; resource logs, guest OS data, and application telemetry all require explicit configuration. |
| Where does Application Insights store data? | In a **Log Analytics workspace** (workspace-based; classic was retired 2024-02-29). |

---

## 15. References

**Exam and certification**
- AZ-900 study guide: https://learn.microsoft.com/en-us/credentials/certifications/resources/study-guides/az-900
- Microsoft Certified: Azure Fundamentals: https://learn.microsoft.com/en-us/credentials/certifications/azure-fundamentals/

**Azure Monitor — platform**
- Azure Monitor overview: https://learn.microsoft.com/en-us/azure/azure-monitor/overview
- Data platform (metrics, logs, traces, changes): https://learn.microsoft.com/en-us/azure/azure-monitor/data-platform
- Sources of monitoring data: https://learn.microsoft.com/en-us/azure/azure-monitor/data-sources
- Best practices for Azure Monitor: https://learn.microsoft.com/en-us/azure/azure-monitor/best-practices
- Cost optimization and Azure Monitor: https://learn.microsoft.com/en-us/azure/azure-monitor/best-practices-cost
- Azure Monitor service limits: https://learn.microsoft.com/en-us/azure/azure-monitor/service-limits

**Logs and Log Analytics**
- Log Analytics workspace overview: https://learn.microsoft.com/en-us/azure/azure-monitor/logs/log-analytics-workspace-overview
- Design a Log Analytics workspace architecture: https://learn.microsoft.com/en-us/azure/azure-monitor/logs/workspace-design
- Table plans (Analytics, Basic, Auxiliary): https://learn.microsoft.com/en-us/azure/azure-monitor/logs/data-platform-logs
- Manage data retention: https://learn.microsoft.com/en-us/azure/azure-monitor/logs/data-retention-configure
- Manage table plans: https://learn.microsoft.com/en-us/azure/azure-monitor/logs/logs-table-plans
- Set daily cap: https://learn.microsoft.com/en-us/azure/azure-monitor/logs/daily-cap
- Analyze usage in a Log Analytics workspace: https://learn.microsoft.com/en-us/azure/azure-monitor/logs/analyze-usage
- Log Analytics workspace health / `_LogOperation`: https://learn.microsoft.com/en-us/azure/azure-monitor/logs/monitor-workspace
- Data ingestion time: https://learn.microsoft.com/en-us/azure/azure-monitor/logs/data-ingestion-time
- Manage access to log data: https://learn.microsoft.com/en-us/azure/azure-monitor/logs/manage-access

**KQL**
- Kusto Query Language overview: https://learn.microsoft.com/en-us/kusto/query/
- Log queries in Azure Monitor: https://learn.microsoft.com/en-us/azure/azure-monitor/logs/log-query-overview
- Azure Monitor Logs table reference: https://learn.microsoft.com/en-us/azure/azure-monitor/reference/tables-index

**Metrics**
- Azure Monitor Metrics overview: https://learn.microsoft.com/en-us/azure/azure-monitor/essentials/data-platform-metrics
- Supported metrics reference: https://learn.microsoft.com/en-us/azure/azure-monitor/reference/supported-metrics/metrics-index
- Metrics Explorer: https://learn.microsoft.com/en-us/azure/azure-monitor/essentials/analyze-metrics

**Diagnostic settings, Activity Log, DCRs**
- Diagnostic settings: https://learn.microsoft.com/en-us/azure/azure-monitor/essentials/diagnostic-settings
- Azure Monitor resource logs: https://learn.microsoft.com/en-us/azure/azure-monitor/essentials/resource-logs
- Azure Activity Log: https://learn.microsoft.com/en-us/azure/azure-monitor/essentials/activity-log
- Data collection rules overview: https://learn.microsoft.com/en-us/azure/azure-monitor/data-collection/data-collection-rule-overview
- Data collection rule structure: https://learn.microsoft.com/en-us/azure/azure-monitor/data-collection/data-collection-rule-structure
- Data collection transformations: https://learn.microsoft.com/en-us/azure/azure-monitor/data-collection/data-collection-transformations
- Data collection endpoints: https://learn.microsoft.com/en-us/azure/azure-monitor/data-collection/data-collection-endpoint-overview
- Logs Ingestion API: https://learn.microsoft.com/en-us/azure/azure-monitor/logs/logs-ingestion-api-overview

**Azure Monitor Agent**
- Azure Monitor Agent overview: https://learn.microsoft.com/en-us/azure/azure-monitor/agents/azure-monitor-agent-overview
- Migrate from the Log Analytics agent: https://learn.microsoft.com/en-us/azure/azure-monitor/agents/azure-monitor-agent-migration
- AMA network configuration and endpoints: https://learn.microsoft.com/en-us/azure/azure-monitor/agents/azure-monitor-agent-network-configuration
- Troubleshoot the Azure Monitor Agent on Linux: https://learn.microsoft.com/en-us/azure/azure-monitor/agents/azure-monitor-agent-troubleshoot-linux-vm

**Application Insights**
- Application Insights overview: https://learn.microsoft.com/en-us/azure/azure-monitor/app/app-insights-overview
- Workspace-based Application Insights: https://learn.microsoft.com/en-us/azure/azure-monitor/app/create-workspace-resource
- Connection strings: https://learn.microsoft.com/en-us/azure/azure-monitor/app/connection-strings
- Telemetry sampling: https://learn.microsoft.com/en-us/azure/azure-monitor/app/sampling
- Telemetry correlation: https://learn.microsoft.com/en-us/azure/azure-monitor/app/distributed-trace-data
- Azure Monitor OpenTelemetry Distro: https://learn.microsoft.com/en-us/azure/azure-monitor/app/opentelemetry-enable
- Application Map: https://learn.microsoft.com/en-us/azure/azure-monitor/app/app-map
- Live Metrics: https://learn.microsoft.com/en-us/azure/azure-monitor/app/live-stream
- Availability tests: https://learn.microsoft.com/en-us/azure/azure-monitor/app/availability
- Application Insights data model: https://learn.microsoft.com/en-us/azure/azure-monitor/app/data-model-complete

**Alerts**
- Azure Monitor alerts overview: https://learn.microsoft.com/en-us/azure/azure-monitor/alerts/alerts-overview
- Metric alerts: https://learn.microsoft.com/en-us/azure/azure-monitor/alerts/alerts-types
- Dynamic thresholds: https://learn.microsoft.com/en-us/azure/azure-monitor/alerts/alerts-dynamic-thresholds
- Log search alerts: https://learn.microsoft.com/en-us/azure/azure-monitor/alerts/alerts-create-log-alert-rule
- Activity Log alerts: https://learn.microsoft.com/en-us/azure/azure-monitor/alerts/alerts-activity-log
- Action groups: https://learn.microsoft.com/en-us/azure/azure-monitor/alerts/action-groups
- Alert processing rules: https://learn.microsoft.com/en-us/azure/azure-monitor/alerts/alerts-processing-rules
- Common alert schema: https://learn.microsoft.com/en-us/azure/azure-monitor/alerts/alerts-common-schema
- Troubleshoot log search alert rules: https://learn.microsoft.com/en-us/azure/azure-monitor/alerts/alerts-troubleshoot-log
- Azure Monitor Baseline Alerts (AMBA): https://azure.github.io/azure-monitor-baseline-alerts/

**Containers and Prometheus**
- Container insights overview: https://learn.microsoft.com/en-us/azure/azure-monitor/containers/container-insights-overview
- Configure Container insights agent data collection: https://learn.microsoft.com/en-us/azure/azure-monitor/containers/container-insights-data-collection-configmap
- Container insights log schema (ContainerLogV2): https://learn.microsoft.com/en-us/azure/azure-monitor/containers/container-insights-logs-schema
- Azure Monitor managed service for Prometheus: https://learn.microsoft.com/en-us/azure/azure-monitor/metrics/prometheus-metrics-overview
- Customize Prometheus metrics scraping: https://learn.microsoft.com/en-us/azure/azure-monitor/metrics/prometheus-metrics-scrape-configuration
- Prometheus alerts and rule groups: https://learn.microsoft.com/en-us/azure/azure-monitor/alerts/prometheus-alerts
- Azure Monitor workspace: https://learn.microsoft.com/en-us/azure/azure-monitor/metrics/azure-monitor-workspace-overview

**Advisor**
- Azure Advisor overview: https://learn.microsoft.com/en-us/azure/advisor/advisor-overview
- Advisor Score: https://learn.microsoft.com/en-us/azure/advisor/azure-advisor-score
- Reliability recommendations: https://learn.microsoft.com/en-us/azure/advisor/advisor-reference-reliability-recommendations
- Cost recommendations: https://learn.microsoft.com/en-us/azure/advisor/advisor-reference-cost-recommendations
- Alerts on Advisor recommendations: https://learn.microsoft.com/en-us/azure/advisor/advisor-alerts-portal

**Service Health and Resource Health**
- Azure Service Health overview: https://learn.microsoft.com/en-us/azure/service-health/overview
- Service Health portal experience: https://learn.microsoft.com/en-us/azure/service-health/service-health-overview
- Create Service Health alerts: https://learn.microsoft.com/en-us/azure/service-health/alerts-activity-log-service-notifications-portal
- Resource Health overview: https://learn.microsoft.com/en-us/azure/service-health/resource-health-overview
- Resource types and health checks: https://learn.microsoft.com/en-us/azure/service-health/resource-health-checks-resource-types
- Azure Status: https://azure.status.microsoft/en-us/status

**Visualization**
- Azure Workbooks: https://learn.microsoft.com/en-us/azure/azure-monitor/visualize/workbooks-overview
- Azure Managed Grafana: https://learn.microsoft.com/en-us/azure/managed-grafana/overview
- Visualizing data in Azure Monitor: https://learn.microsoft.com/en-us/azure/azure-monitor/visualize/visualize-overview

**Reference and tooling**
- Bicep resource reference — `Microsoft.Insights`: https://learn.microsoft.com/en-us/azure/templates/microsoft.insights/
- Bicep resource reference — `Microsoft.OperationalInsights/workspaces`: https://learn.microsoft.com/en-us/azure/templates/microsoft.operationalinsights/workspaces
- `az monitor` CLI reference: https://learn.microsoft.com/en-us/cli/azure/monitor
- Terraform AzureRM provider — monitor resources: https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs
- Azure Monitor pricing: https://azure.microsoft.com/en-us/pricing/details/monitor/
- Well-Architected Framework — Operational Excellence: https://learn.microsoft.com/en-us/azure/well-architected/operational-excellence/