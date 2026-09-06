# Topic 3.4 — Describe monitoring tools in Azure

**Certification:** AZ-900 (Microsoft Azure Fundamentals) · Exam version 2026-07-20
**Domain:** 3 — Describe Azure management and governance · **Exam weight:** 8.33 %
**Format:** guided lab. You execute every numbered step; each block closes with comprehension checks. Answers are collapsed at the end.

---

## Scope of this topic

The exam blueprint for 3.4 covers four surfaces. This lab treats them as one telemetry system rather than four feature pages, because in production they are wired together:

| Surface | What it answers | Data origin |
|---|---|---|
| **Azure Advisor** | "Is my configuration a good idea?" | Derived analysis of resource configuration + platform telemetry |
| **Azure Service Health** | "Is the problem me or Microsoft?" | Platform-authored events, scoped to your subscriptions |
| **Azure Monitor** | "What is my system doing, right now and historically?" | Metrics store + Logs (Log Analytics workspace) |
| **Application Insights** | "Why is *this request* slow?" | APM SDK / auto-instrumentation, stored **in a Log Analytics workspace** |

The single most important architectural fact in this topic — and the one most often missed at fundamentals level — is that **Application Insights is not a separate product with a separate database**. Since the retirement of classic components (February 2024), every Application Insights resource is *workspace-based*: it writes into a Log Analytics workspace you own, and its data is queryable with the same KQL engine as everything else. Azure Monitor is the platform; Log Analytics is its log store; Application Insights is an application-shaped view over that store.

---

## Prerequisites and cost warning

```bash
# Required tooling
az version
# Expect Azure CLI >= 2.60; the labs use the application-insights extension.

az extension add --name application-insights --upgrade --only-show-errors
az extension add --name log-analytics       --upgrade --only-show-errors
```

> **Cost.** Everything in Labs 1–3 and Lab 8 is free to read. Labs 4, 5, 7 and 9 create a Log Analytics workspace and an Application Insights component. Ingestion is billed per GB; the volumes here are a few MB, well inside the 5 GB/month free grant that applies per billing account, but **run the cleanup in Lab 10 regardless**. Alert rules (Lab 6) bill per time series per month; the rules created here cost cents, not dollars, and are deleted at the end.
>
> All prices quoted are indicative list prices (East US, pay-as-you-go) and change. Verify in the Azure Pricing Calculator before quoting them to anyone.

---

## Lab 0 — Bootstrap a disposable environment

**Step 1.** Pin your shell to one subscription so nothing leaks into a neighbouring one.

```bash
az account set --subscription "<your-subscription-name-or-id>"
az account show --query "{name:name, id:id, tenant:tenantId, state:state}" -o table
```

Expected:

```
Name                 Id                                    Tenant                                State
-------------------  ------------------------------------  ------------------------------------  --------
Visual Studio Enterprise  00000000-1111-2222-3333-444444444444  aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee  Enabled
```

**Step 2.** Export the variables used throughout. Keep this shell open; every later lab reuses them.

```bash
export SUB_ID=$(az account show --query id -o tsv)
export LOC=eastus
export RG=rg-az900-mon-lab
export LAW=law-az900-lab
export AI=appi-az900-lab
export AG=ag-az900-lab
```

**Step 3.** Create the resource group. `az group create` is idempotent — re-running it returns the existing group unchanged.

```bash
az group create --name "$RG" --location "$LOC" --tags purpose=az900-lab ttl=1d -o table
```

```
Location    Name
----------  -----------------
eastus      rg-az900-mon-lab
```

**Step 4.** Register the resource providers the labs need. Registration is per-subscription and takes up to a couple of minutes; it is a no-op if already registered.

```bash
for ns in Microsoft.OperationalInsights Microsoft.Insights Microsoft.AlertsManagement Microsoft.ResourceHealth Microsoft.Advisor; do
  az provider register --namespace "$ns" --only-show-errors
done

az provider list --query "[?namespace=='Microsoft.Insights' || namespace=='Microsoft.OperationalInsights'].{ns:namespace, state:registrationState}" -o table
```

```
Ns                            State
----------------------------  ----------
Microsoft.Insights            Registered
Microsoft.OperationalInsights Registered
```

### Comprehension check — Lab 0

**Q1.** `Microsoft.Insights` and `Microsoft.OperationalInsights` are two different resource providers. Which one owns the Log Analytics *workspace* resource, and which owns *diagnostic settings, metric alert rules and action groups*? Why does that split exist?

**Q2.** Why does the lab register `Microsoft.AlertsManagement` separately from `Microsoft.Insights`, given that alert rules live under `Microsoft.Insights`?

---

## Lab 1 — Azure Advisor: the recommendation engine

Advisor is a **read-only analysis layer**. It owns no telemetry of its own: it periodically evaluates your resource configuration and usage metrics against a rule catalogue derived from the Microsoft Azure Well-Architected Framework, and materialises the results as `Microsoft.Advisor/recommendations` objects. Cost recommendations typically refresh on a slower cadence (up to ~24 h) than the others, because they depend on aggregated utilisation history rather than on a configuration read.

**Step 1.** List every recommendation in the subscription, grouped by category.

```bash
az advisor recommendation list \
  --query "[].{category:category, impact:impact, resource:impactedValue, problem:shortDescription.problem}" \
  -o table | head -20
```

Representative output (trimmed):

```
Category                Impact    Resource                 Problem
----------------------  --------  -----------------------  --------------------------------------------------
Cost                    Medium    vm-legacy-01             Right-size or shutdown underutilized virtual machines
HighAvailability        High      st0az900lab              Use Zone-redundant storage for higher availability
Security                High      kv-prod-01               Key vaults should have soft delete enabled
OperationalExcellence   Medium    rg-prod                  Create an Azure Service Health alert
Performance             Low       sqldb-orders             Improve performance with Accelerated Networking
```

**Step 2.** Count recommendations per pillar. This is the shape a platform team actually tracks over time.

```bash
az advisor recommendation list --query "[].category" -o tsv | sort | uniq -c | sort -rn
```

```
     14 Cost
      9 Security
      6 HighAvailability
      4 OperationalExcellence
      2 Performance
```

> **Naming trap.** The portal shows five pillars named **Reliability, Security, Cost Optimization, Operational Excellence, Performance Efficiency**. The API still returns the legacy value `HighAvailability` where the portal says *Reliability*. Filter on the API value in scripts.

**Step 3.** Filter to a single category and inspect one recommendation in full. Note that `--category` accepts the API spelling.

```bash
az advisor recommendation list --category Cost \
  --query "[0].{id:id, problem:shortDescription.problem, solution:shortDescription.solution, impact:impact, meta:extendedProperties}" \
  -o jsonc
```

```jsonc
{
  "id": "/subscriptions/0000.../resourceGroups/rg-prod/providers/Microsoft.Compute/virtualMachines/vm-legacy-01/providers/Microsoft.Advisor/recommendations/8a1b...",
  "impact": "Medium",
  "meta": {
    "MaxCpuP95": "3.42",
    "MaxMemoryP95": "18.7",
    "regionId": "eastus",
    "roleName": "vm-legacy-01",
    "savingsAmount": "83.22",
    "savingsCurrency": "USD",
    "targetSku": "Standard_B2s"
  },
  "problem": "Right-size or shutdown underutilized virtual machines",
  "solution": "We have observed low CPU and network usage over the last 7 days..."
}
```

Read `extendedProperties` carefully: `MaxCpuP95: 3.42` is the *evidence*. Advisor is telling you the 95th-percentile CPU over the observation window was 3.4 %. A recommendation you cannot trace to evidence is a recommendation you cannot defend in a change review.

**Step 4.** Inspect the Advisor configuration. This is where the CPU threshold that drives right-sizing lives, and where you can exclude noisy resource groups.

```bash
az advisor configuration list --query "[].{scope:id, lowCpu:properties.lowCpuThreshold, excluded:properties.exclude}" -o table
```

```
Scope                                                     LowCpu    Excluded
--------------------------------------------------------  --------  ----------
/subscriptions/0000.../providers/Microsoft.Advisor/config  5         False
```

**Step 5.** Read the Advisor score. The score is not exposed by a first-class CLI verb, so call the ARM REST surface directly — a technique worth internalising, because it works for every preview or CLI-less API in Azure.

```bash
az rest --method get \
  --url "https://management.azure.com/subscriptions/$SUB_ID/providers/Microsoft.Advisor/advisorScore?api-version=2023-01-01" \
  --query "value[].{category:name, score:properties.lastRefreshedScore.score, consumed:properties.lastRefreshedScore.consumptionUnits}" \
  -o table
```

```
Category               Score    Consumed
---------------------  -------  ----------
Advisor                71.4     412.0
Cost                   64.2     118.0
Security               88.0     97.0
HighAvailability       59.7     84.0
OperationalExcellence  76.1     63.0
Performance            92.3     50.0
```

The Advisor score is a **consumption-weighted** percentage: each category's score is weighted by the spend of the resources it evaluates, so a misconfigured production VM moves the needle far more than an idle dev disk. This is why a subscription can hold dozens of open recommendations and still score above 90.

### Comprehension check — Lab 1

**Q3.** Advisor surfaces a *Security* recommendation. Which service actually generated it, and what does that imply about whether Advisor is the system of record for security posture?

**Q4.** A cost recommendation reports `savingsAmount: 83.22`. Is that a monthly or an annual figure by default, and why must you check before putting it in a savings report?

**Q5.** Your subscription has 40 open recommendations but an Advisor score of 93. Explain, mechanically, how both are true at once.

**Q6.** You right-size the VM in Step 3 at 14:00. At 14:10 the recommendation is still listed. Is this a bug? What would you check?

---

## Lab 2 — Service Health and Resource Health: is it me or is it Microsoft?

Two distinct services, frequently conflated:

- **Azure Status** (`status.azure.com`) — global, unauthenticated, for outages so large they are public. Never build automation on it.
- **Azure Service Health** — authenticated and **personalised**: it only shows events affecting *regions and services you actually use*. Four event classes: **Service issues**, **Planned maintenance**, **Health advisories**, **Security advisories**.
- **Resource Health** — per-resource verdict on *your specific instance*: `Available`, `Unavailable`, `Degraded`, `Unknown`. Derived from platform signals plus, for some resource types, active health checks.

**Step 1.** Query the health of every resource in the subscription that reports one.

```bash
az rest --method get \
  --url "https://management.azure.com/subscriptions/$SUB_ID/providers/Microsoft.ResourceHealth/availabilityStatuses?api-version=2023-07-01-preview" \
  --query "value[].{resource:id, status:properties.availabilityState, reason:properties.reasonType, since:properties.occuredTime}" \
  -o table | head
```

```
Resource                                            Status       Reason     Since
--------------------------------------------------  -----------  ---------  --------------------------
/subscriptions/.../virtualMachines/vm-legacy-01     Available    Unknown    2026-08-29T04:11:02Z
/subscriptions/.../vaults/kv-prod-01                Available    Unknown    2026-09-01T00:00:00Z
/subscriptions/.../virtualMachines/vm-batch-07      Unavailable  Customer   2026-09-04T22:40:18Z
```

**Step 2.** Interpret `reasonType`. This field is the whole point of Resource Health.

| `reasonType` | Meaning | Who acts |
|---|---|---|
| `Unplanned` | Platform fault — host failure, fabric issue | Microsoft; you fail over |
| `Planned` | Platform-initiated maintenance | Microsoft; you schedule around it |
| `UserInitiated` / `Customer` | You stopped, deallocated, or misconfigured it | You |
| `Unknown` | Platform lost the signal; not evidence of failure | Investigate; do not page on this alone |

`vm-batch-07` above is `Unavailable / Customer` — someone deallocated it. That is not an incident.

**Step 3.** List Service Health events currently visible to your subscription.

```bash
az rest --method get \
  --url "https://management.azure.com/subscriptions/$SUB_ID/providers/Microsoft.ResourceHealth/events?api-version=2023-10-01-preview&\$filter=properties/status eq 'Active'" \
  --query "value[].{type:properties.eventType, level:properties.level, title:properties.title, impactStart:properties.impactStartTime}" \
  -o table
```

```
Type              Level       Title                                              ImpactStart
----------------  ----------  -------------------------------------------------  --------------------------
PlannedMaintenance  Warning   Planned maintenance - Azure SQL Database - East US  2026-09-11T02:00:00Z
HealthAdvisory      Warning   TLS 1.0/1.1 retirement for Azure Storage           2026-10-31T00:00:00Z
```

An empty `value: []` is a healthy, normal result.

**Step 4.** Create the alert that Advisor's *Operational Excellence* pillar keeps recommending. The mechanic matters: **a Service Health alert is an Activity Log alert**, not a metric alert. Service Health events are written into the subscription Activity Log under the `ServiceHealth` category, and the alert rule is a filter over that stream.

First an action group — the reusable notification target that every alert type shares:

```bash
az monitor action-group create \
  --name "$AG" \
  --resource-group "$RG" \
  --short-name az900lab \
  --action email oncall villadalmine@gmail.com \
  -o table
```

```
Enabled    GroupShortName    Location    Name           ResourceGroup
---------  ----------------  ----------  -------------  -----------------
True       az900lab          Global      ag-az900-lab   rg-az900-mon-lab
```

> `--short-name` is limited to 12 characters; it is what appears as the SMS/email sender prefix.

Now the rule:

```bash
export AG_ID=$(az monitor action-group show -g "$RG" -n "$AG" --query id -o tsv)

az monitor activity-log alert create \
  --name "alert-servicehealth-all" \
  --resource-group "$RG" \
  --scope "/subscriptions/$SUB_ID" \
  --condition category=ServiceHealth \
  --action-group "$AG_ID" \
  --description "All Service Health events for this subscription" \
  -o table
```

```
Enabled    Location    Name                      ResourceGroup
---------  ----------  ------------------------  -----------------
True       Global      alert-servicehealth-all   rg-az900-mon-lab
```

**Step 5.** Verify the emitted rule, and note the two hard constraints on Activity Log alerts.

```bash
az monitor activity-log alert show -g "$RG" -n "alert-servicehealth-all" \
  --query "{scopes:scopes, location:location, conditions:condition.allOf[].{f:field, e:equals}}" -o jsonc
```

```jsonc
{
  "conditions": [ { "e": "ServiceHealth", "f": "category" } ],
  "location": "Global",
  "scopes": [ "/subscriptions/00000000-1111-2222-3333-444444444444" ]
}
```

The rule's `location` is `Global` — Activity Log alert rules are not regional resources, because the Activity Log itself is a subscription-scoped, region-independent stream. And the `scope` must be a subscription, resource group, or resource **in that subscription**: one rule cannot span subscriptions. A tenant with 30 subscriptions needs 30 rules, which is exactly the kind of thing you deploy with a policy `deployIfNotExists` rather than by hand.

**Step 6.** Refine to production shape — most teams do not want a page for every health advisory.

```bash
az monitor activity-log alert update \
  --name "alert-servicehealth-all" \
  --resource-group "$RG" \
  --condition "category=ServiceHealth and properties.incidentType=Incident" \
  -o none
```

`incidentType=Incident` narrows to live service issues, excluding `Maintenance`, `Informational` (health advisories) and `Security`.

### Comprehension check — Lab 2

**Q7.** A VM reports `Unavailable` with `reasonType: Unplanned`, while Service Health shows no active event for that region. Is this contradictory? Explain.

**Q8.** Why is a Service Health alert implemented as an Activity Log alert instead of a metric alert? What property of the underlying data forces that choice?

**Q9.** Your team is paged at 03:00 for a `PlannedMaintenance` event announced three weeks in advance. Which single field in Step 6's condition fixes this, and what is the trade-off of the fix?

**Q10.** You must alert on Service Health across 30 subscriptions. Why can you not simply widen `--scope` to the management group, and what is the standard remedy?

---

## Lab 3 — Azure Monitor, part 1: the metrics pillar

Azure Monitor stores two fundamentally different data shapes, and choosing wrongly is the most expensive mistake in Azure observability.

| | **Metrics** | **Logs** |
|---|---|---|
| Store | Purpose-built time-series database | Log Analytics workspace (Kusto) |
| Shape | Numeric, fixed schema, pre-aggregated | Arbitrary records, variable schema |
| Latency | Low (seconds to ~3 min) | Higher (typically ~1–5 min ingestion) |
| Granularity | 1-minute default for platform metrics | Per-event |
| Retention | 93 days for platform metrics | Configurable, up to 12 years total |
| Query | Metrics Explorer / Metrics API | KQL |
| **Platform cost** | **Free to collect and query** | **Billed per GB ingested + retained** |
| Best for | Alerting, dashboards, "is it up / how fast" | Investigation, correlation, audit, "why" |

Platform metrics are emitted by the resource provider automatically. **You do not configure anything and you are not billed for them.** This is the free tier of Azure observability and it is routinely left unused.

**Step 1.** Discover what a resource emits, before assuming. Use the action group's resource group as a target — or substitute any resource you own.

```bash
# Use any existing resource; a storage account is a good example.
export TARGET=$(az storage account list --query "[0].id" -o tsv)
echo "$TARGET"

az monitor metrics list-definitions --resource "$TARGET" \
  --query "[].{metric:name.value, unit:unit, aggregations:supportedAggregationTypes, dims:join(',',metricAvailabilities[0].timeGrain && [''] || [''])}" \
  -o table | head -15
```

```
Metric                  Unit           Aggregations
----------------------  -------------  ----------------------------------------------
UsedCapacity            Bytes          Average
Transactions            Count          Total
Ingress                 Bytes          Total, Average
Egress                  Bytes          Total, Average
SuccessServerLatency    MilliSeconds   Average
SuccessE2ELatency       MilliSeconds   Average
Availability            Percent        Average
```

**Step 2.** Read actual values. Note the explicit `--aggregation` and `--interval`: choosing the wrong aggregation for a metric silently produces a meaningless number.

```bash
az monitor metrics list --resource "$TARGET" \
  --metric "Transactions" \
  --aggregation Total \
  --interval PT1H \
  --start-time "$(date -u -d '6 hours ago' +%Y-%m-%dT%H:%M:%SZ)" \
  --query "value[0].timeseries[0].data[].{time:timeStamp, total:total}" \
  -o table
```

```
Time                       Total
-------------------------  -------
2026-09-05T08:00:00+00:00  1420.0
2026-09-05T09:00:00+00:00  1588.0
2026-09-05T10:00:00+00:00  1201.0
2026-09-05T11:00:00+00:00  9930.0
2026-09-05T12:00:00+00:00  1355.0
2026-09-05T13:00:00+00:00  1290.0
```

**Step 3.** Split by dimension. Dimensions are the reason metrics remain cheap while still being diagnosable: the spike above is aggregate, and useless until you break it apart.

```bash
az monitor metrics list --resource "$TARGET" \
  --metric "Transactions" \
  --aggregation Total \
  --interval PT1H \
  --filter "ResponseType eq '*'" \
  --start-time "$(date -u -d '6 hours ago' +%Y-%m-%dT%H:%M:%SZ)" \
  --query "value[0].timeseries[].{responseType:metadatavalues[0].value, peak:max(data[].total)}" \
  -o table
```

```
ResponseType             Peak
-----------------------  ------
Success                  1402.0
ClientOtherError         8510.0
ServerTimeoutError       18.0
```

The 11:00 spike was `ClientOtherError`, not load. That distinction — obtained for free, in seconds, without ingesting a byte of logs — is the argument for reaching for metrics first.

**Step 4.** Understand the retention boundary empirically. Ask for data older than 93 days:

```bash
az monitor metrics list --resource "$TARGET" --metric "Transactions" --aggregation Total \
  --interval P1D \
  --start-time "$(date -u -d '120 days ago' +%Y-%m-%dT%H:%M:%SZ)" \
  --query "length(value[0].timeseries[0].data)"
```

You will get at most ~93 days of buckets regardless of the start time you requested. Platform metric retention is fixed and not configurable. If you need a year-over-year comparison, you must **export metrics into Logs via a diagnostic setting** — which is Lab 4, and which is no longer free.

### Comprehension check — Lab 3

**Q11.** You need to alert within 60 seconds when a web app's HTTP 5xx rate rises. Metrics or Logs? Justify with two properties from the comparison table.

**Q12.** A colleague queries `SuccessE2ELatency` with `--aggregation Total`. Why is the result meaningless, and what does it actually compute?

**Q13.** Platform metrics are free. Name the *two* distinct circumstances under which collecting metric data nonetheless generates a bill.

**Q14.** Compliance requires 400 days of storage-account transaction history. Platform metric retention is 93 days. Describe the mechanism that satisfies the requirement and name the new cost it introduces.

---

## Lab 4 — Azure Monitor, part 2: Log Analytics and diagnostic settings

Platform metrics arrive automatically. **Resource logs do not.** Every Azure resource can emit detailed operational logs, but they are discarded unless a **diagnostic setting** on that resource routes them somewhere. This is the single most common gap in a real environment: the audit trail everyone assumed existed was never turned on.

**Step 1.** Create the workspace. `PerGB2018` is the standard pay-as-you-go pricing tier.

```bash
az monitor log-analytics workspace create \
  --resource-group "$RG" \
  --workspace-name "$LAW" \
  --location "$LOC" \
  --sku PerGB2018 \
  --retention-time 30 \
  -o table
```

```
CreatedDate                    Location    Name          ProvisioningState    ResourceGroup      RetentionInDays
-----------------------------  ----------  ------------  -------------------  -----------------  ---------------
Fri, 05 Sep 2026 14:02:11 GMT  eastus      law-az900-lab  Succeeded            rg-az900-mon-lab   30
```

**Step 2.** Capture both identifiers. They are different and are not interchangeable.

```bash
export LAW_ID=$(az monitor log-analytics workspace show -g "$RG" -n "$LAW" --query id -o tsv)
export LAW_GUID=$(az monitor log-analytics workspace show -g "$RG" -n "$LAW" --query customerId -o tsv)
echo "ARM resource ID : $LAW_ID"
echo "Workspace GUID  : $LAW_GUID"
```

```
ARM resource ID : /subscriptions/0000.../resourceGroups/rg-az900-mon-lab/providers/Microsoft.OperationalInsights/workspaces/law-az900-lab
Workspace GUID  : 7f3c9a10-2b44-4c7e-9e21-8d55a1f0c3b9
```

The **ARM ID** is the control-plane handle: used by diagnostic settings, RBAC, alert rules. The **customerId GUID** is the data-plane handle: used by the query API and by agents. Passing one where the other is expected is a classic 30-minute debugging detour.

**Step 3.** Route the subscription Activity Log into the workspace. The Activity Log is the *control-plane* record — who created, modified or deleted what — retained for 90 days free in its own store. Exporting it to a workspace lets you correlate a deployment against an application regression, which is the capstone in Lab 9.

```bash
az monitor diagnostic-settings subscription create \
  --name "diag-activitylog-to-law" \
  --location "$LOC" \
  --workspace "$LAW_ID" \
  --logs '[
    {"category":"Administrative","enabled":true},
    {"category":"ServiceHealth","enabled":true},
    {"category":"ResourceHealth","enabled":true},
    {"category":"Alert","enabled":true},
    {"category":"Policy","enabled":true},
    {"category":"Autoscale","enabled":true},
    {"category":"Security","enabled":true},
    {"category":"Recommendation","enabled":true}
  ]' -o none

az monitor diagnostic-settings subscription list \
  --query "value[].{name:name, categories:join(',', properties.logs[?enabled].category)}" -o table
```

```
Name                        Categories
--------------------------  --------------------------------------------------------------------
diag-activitylog-to-law     Administrative,ServiceHealth,ResourceHealth,Alert,Policy,Autoscale,Security,Recommendation
```

**Step 4.** Add a resource-scoped diagnostic setting. First inspect what the resource can emit — never guess category names, they differ per resource type:

```bash
az monitor diagnostic-settings categories list --resource "$TARGET/blobServices/default" \
  --query "value[].{category:name, type:properties.categoryType, group:properties.categoryGroups}" -o table
```

```
Category         Type      Group
---------------  --------  ------------------
StorageRead      Logs      allLogs, audit
StorageWrite     Logs      allLogs
StorageDelete    Logs      allLogs, audit
Transaction      Metrics
```

Then create it:

```bash
az monitor diagnostic-settings create \
  --name "diag-blob-to-law" \
  --resource "$TARGET/blobServices/default" \
  --workspace "$LAW_ID" \
  --logs '[{"categoryGroup":"audit","enabled":true}]' \
  --metrics '[{"category":"Transaction","enabled":true}]' \
  -o none
```

Using `categoryGroup: audit` rather than an explicit category list is the durable choice: when Microsoft adds a new audit-relevant category to that resource type, the setting picks it up without a redeploy.

**Step 5.** Understand the fan-out. A diagnostic setting is a one-to-many router with four destination types:

| Destination | Typical purpose | Cost model |
|---|---|---|
| **Log Analytics workspace** | Query, alert, correlate | Per GB ingested + retained |
| **Storage account** | Cheap long-term archive, compliance | Storage rates (very cheap) |
| **Event Hub** | Stream to SIEM / third party / custom pipeline | Event Hub throughput units |
| **Partner solution** | Datadog, Elastic, Dynatrace, … | Partner billing |

A resource supports **up to 5 diagnostic settings**, so a common production pattern is one setting to a workspace with 30-day retention for operations, plus a second to a storage account for seven-year compliance archive at roughly 1 % of the cost per GB.

**Step 6.** Deploy the same thing declaratively. Portal clicks do not survive an audit; this Bicep is the artefact you actually check in.

```bicep
// monitoring.bicep — workspace, Application Insights, action group, and a
// subscription-wide Service Health alert. Deploy at resource-group scope.
targetScope = 'resourceGroup'

@description('Deployment region for regional resources.')
param location string = resourceGroup().location

@description('Base name; all resources derive from it.')
param baseName string = 'az900lab'

@description('Interactive retention in days for the workspace (30–730).')
@minValue(30)
@maxValue(730)
param retentionInDays int = 30

@description('Email address that receives alert notifications.')
param alertEmail string

var workspaceName    = 'law-${baseName}'
var appInsightsName  = 'appi-${baseName}'
var actionGroupName  = 'ag-${baseName}'

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: workspaceName
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: retentionInDays
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

// Workspace-based Application Insights: telemetry lands in the workspace above.
resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: workspace.id
    IngestionMode: 'LogAnalytics'
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
    RetentionInDays: 90
  }
}

resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: actionGroupName
  location: 'Global'
  properties: {
    groupShortName: 'az900lab'
    enabled: true
    emailReceivers: [
      {
        name: 'oncall'
        emailAddress: alertEmail
        useCommonAlertSchema: true
      }
    ]
  }
}

// Activity Log alert: fires on live Service Health incidents only.
resource serviceHealthAlert 'Microsoft.Insights/activityLogAlerts@2020-10-01' = {
  name: 'alert-servicehealth-incidents'
  location: 'Global'
  properties: {
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
          field: 'properties.incidentType'
          equals: 'Incident'
        }
      ]
    }
    actions: {
      actionGroups: [
        {
          actionGroupId: actionGroup.id
        }
      ]
    }
    description: 'Live Azure Service Health incidents affecting this subscription.'
  }
}

output workspaceResourceId string = workspace.id
output workspaceCustomerId string = workspace.properties.customerId
output appInsightsConnectionString string = appInsights.properties.ConnectionString
output actionGroupId string = actionGroup.id
```

Validate it without deploying (`what-if` shows the exact delta ARM would apply):

```bash
az deployment group what-if \
  --resource-group "$RG" \
  --template-file monitoring.bicep \
  --parameters alertEmail=villadalmine@gmail.com
```

```
Resource and property changes are indicated with these symbols:
  + Create
  ~ Modify
  = Nochange

The deployment will update the following scope:

Scope: /subscriptions/0000.../resourceGroups/rg-az900-mon-lab

  = Microsoft.OperationalInsights/workspaces/law-az900lab
  + Microsoft.Insights/components/appi-az900lab
  + Microsoft.Insights/activityLogAlerts/alert-servicehealth-incidents
```

### Comprehension check — Lab 4

**Q15.** A resource has *no* diagnostic setting. Which of the following are still available: platform metrics, resource logs, Activity Log entries for operations on it? Explain each.

**Q16.** Distinguish the **Activity Log** from **resource logs** in one sentence each, then state which one records "a `DELETE` was issued against this key vault" versus "a secret was read from this key vault".

**Q17.** In the Bicep, `actionGroup.location` is `'Global'` while `workspace.location` is a region. Why?

**Q18.** A team needs logs queryable for 30 days and retained for 7 years for auditors. Describe the two-destination design and explain why it costs far less than 7 years of workspace retention.

**Q19.** The Bicep sets `WorkspaceResourceId` on the Application Insights component. What would be missing if that property were omitted, and why is omitting it no longer possible?

---

## Lab 5 — KQL: querying the log store

KQL is a read-only, pipelined query language. Data flows left to right through `|` operators; each operator takes a tabular input and returns a tabular output. There is no `UPDATE`, no `DELETE`, and no way to mutate ingested data from a query.

**Step 1.** Confirm the workspace has data. Newly created workspaces are empty for the first few minutes; `Heartbeat` and `Usage` appear first.

```bash
az monitor log-analytics query \
  --workspace "$LAW_GUID" \
  --analytics-query "union withsource=TableName * | summarize Records=count(), Latest=max(TimeGenerated) by TableName | sort by Records desc" \
  -o table
```

```
TableName        Records    Latest
---------------  ---------  --------------------------
AzureActivity    1284       2026-09-05T14:41:12.33Z
Usage            96         2026-09-05T14:00:00.00Z
Operation        12         2026-09-05T14:05:44.10Z
StorageBlobLogs  431        2026-09-05T14:40:57.88Z
```

> `union *` is a full-workspace scan. It is fine on an empty lab workspace and reckless on a production one holding terabytes. Prefer the metadata-only form for discovery: `search * | distinct $table` is no better — use the workspace's **Tables** blade or the `Usage` table instead.

**Step 2.** The five operators that cover most real work.

```bash
az monitor log-analytics query --workspace "$LAW_GUID" --analytics-query '
AzureActivity
| where TimeGenerated > ago(24h)
| where CategoryValue == "Administrative"
| where ActivityStatusValue == "Success"
| summarize Operations = count() by Caller, OperationNameValue
| top 5 by Operations desc
' -o table
```

```
Caller                       OperationNameValue                                        Operations
---------------------------  --------------------------------------------------------  ----------
villadalmine@gmail.com       Microsoft.Insights/diagnosticSettings/write               6
villadalmine@gmail.com       Microsoft.OperationalInsights/workspaces/write            3
7c1f...@tenant (SPN)         Microsoft.Compute/virtualMachines/write                   2
```

Read the pipeline as a funnel: `where` on `TimeGenerated` **first**, always. Log Analytics partitions by ingestion time; a leading time filter lets the engine skip entire partitions, and it is the difference between a 200 ms query and a 40-second one.

**Step 3.** Time-bucket and render — the shape behind every chart in the portal.

```bash
az monitor log-analytics query --workspace "$LAW_GUID" --analytics-query '
AzureActivity
| where TimeGenerated > ago(24h)
| summarize Events = count() by bin(TimeGenerated, 1h), CategoryValue
| order by TimeGenerated asc
' -o table | head
```

```
TimeGenerated               CategoryValue   Events
--------------------------  --------------  ------
2026-09-05T09:00:00Z        Administrative  14
2026-09-05T09:00:00Z        Policy          122
2026-09-05T10:00:00Z        Administrative  3
2026-09-05T10:00:00Z        Policy          118
```

`bin(TimeGenerated, 1h)` rounds each timestamp down to the hour — this is how you convert an event stream into a time series. Appending `| render timechart` has no effect in the CLI but drives the visualisation in the portal and in workbooks.

**Step 4.** Measure your own ingestion. This query is the one to keep: it is the difference between a predictable bill and a surprise.

```bash
az monitor log-analytics query --workspace "$LAW_GUID" --analytics-query '
Usage
| where TimeGenerated > ago(7d)
| where IsBillable == true
| summarize BillableGB = round(sum(Quantity) / 1000, 3) by DataType
| order by BillableGB desc
' -o table
```

```
DataType          BillableGB
----------------  ----------
AzureActivity     0.041
StorageBlobLogs   0.012
AppRequests       0.004
```

**Step 5.** Understand table plans — the cost lever most teams never pull.

| Plan | Interactive retention | Query capability | Indicative ingestion price | Use for |
|---|---|---|---|---|
| **Analytics** | 30 days included, up to 730 | Full KQL, alerts, all features | ~$2.76/GB | Data you query and alert on |
| **Basic** | 30 days | Restricted KQL (single-table, no joins/alerts), **billed per query** | ~$0.65/GB | High-volume verbose logs, occasional forensics |
| **Auxiliary** | 30 days | Very restricted, billed per query | ~$0.15/GB | Bulk, rarely-read, compliance-shaped data |

Beyond interactive retention, data moves to **long-term retention** (up to 12 years total) at roughly $0.026/GB/month, but is no longer directly queryable — you must run a **search job** or **restore** it, each billed separately.

```bash
# Inspect the plan and retention of a table
az monitor log-analytics workspace table show \
  -g "$RG" --workspace-name "$LAW" -n StorageBlobLogs \
  --query "{plan:plan, interactive:retentionInDays, total:totalRetentionInDays}" -o jsonc
```

```jsonc
{
  "interactive": 30,
  "plan": "Analytics",
  "total": 30
}
```

```bash
# Move a chatty table to Basic and keep 1 year of long-term retention
az monitor log-analytics workspace table update \
  -g "$RG" --workspace-name "$LAW" -n StorageBlobLogs \
  --plan Basic --total-retention-time 365 -o none
```

### Comprehension check — Lab 5

**Q20.** Why does putting `| where TimeGenerated > ago(24h)` at the *top* of a query matter, mechanically? What is the engine able to skip?

**Q21.** You move a table to the **Basic** plan and your log alert rule on it stops working. Is this a bug? What is the rule you violated?

**Q22.** A table holds 500 GB/month, is never queried, and must be kept 1 year for auditors. Compare Analytics-plan-with-365-day-retention against Basic/Auxiliary-plus-long-term-retention, and name the operational cost of the cheaper option.

**Q23.** `Usage | where IsBillable == true` — name two categories of data that land in a workspace and are **not** billable.

---

## Lab 6 — Alerts: rules, action groups, and the state machine

Azure Monitor alerts have three composable parts, and keeping them separate is what makes the system maintainable:

1. **Alert rule** — *what* to detect (a condition over metrics, logs, the Activity Log, or resource health).
2. **Action group** — *who/what* to notify. Reusable across hundreds of rules.
3. **Alert processing rule** — *when to suppress or reroute*, e.g. during a maintenance window. Applied on top, without editing any rule.

**Step 1.** Inspect the action group from Lab 2 and add a webhook using the **common alert schema** — the normalised payload that makes one downstream handler work for every alert type.

```bash
az monitor action-group update \
  --name "$AG" --resource-group "$RG" \
  --add-action webhook chatops "https://example.invalid/hooks/az900" useCommonAlertSchema=true \
  -o none

az monitor action-group show -g "$RG" -n "$AG" \
  --query "{email:emailReceivers[].name, webhook:webhookReceivers[].{n:name, schema:useCommonAlertSchema}}" -o jsonc
```

```jsonc
{
  "email": [ "oncall" ],
  "webhook": [ { "n": "chatops", "schema": true } ]
}
```

Without `useCommonAlertSchema=true`, a metric alert, a log alert and an Activity Log alert each POST a *different* JSON shape, and your handler needs three parsers.

**Step 2.** Create a static-threshold metric alert.

```bash
az monitor metrics alert create \
  --name "alert-blob-availability" \
  --resource-group "$RG" \
  --scopes "$TARGET" \
  --condition "avg Availability < 99" \
  --window-size 5m \
  --evaluation-frequency 1m \
  --severity 2 \
  --description "Storage availability below 99% over 5 minutes" \
  --action "$AG_ID" \
  -o table
```

```
Enabled    Location    Name                       ResourceGroup      Severity
---------  ----------  -------------------------  -----------------  ----------
True       global      alert-blob-availability    rg-az900-mon-lab   2
```

Two parameters do the real work and are constantly confused:

- **`--window-size` (aggregation granularity)** — how much history each evaluation looks at. `5m` means "average the last 5 minutes".
- **`--evaluation-frequency`** — how often that evaluation runs. `1m` means every minute, over a sliding 5-minute window.

A 5-minute window with 1-minute frequency smooths single-sample noise while still detecting within roughly a minute of a sustained breach. A 1-minute window with 1-minute frequency will page you on every transient blip.

**Step 3.** Severity is a contract, not decoration.

| Severity | Label | Convention |
|---|---|---|
| Sev 0 | Critical | Wake a human now |
| Sev 1 | Error | Page during business hours |
| Sev 2 | Warning | Ticket |
| Sev 3 | Informational | Dashboard only |
| Sev 4 | Verbose | Record, never notify |

**Step 4.** Create a dynamic-threshold rule. Instead of a fixed number, the platform learns the metric's historical pattern — including daily and weekly seasonality — and alerts on deviation.

```bash
az monitor metrics alert create \
  --name "alert-blob-transactions-dynamic" \
  --resource-group "$RG" \
  --scopes "$TARGET" \
  --condition "total Transactions > dynamic medium 4 of 5 since $(date -u -d '3 days ago' +%Y-%m-%dT%H:%M:%SZ)" \
  --window-size 5m \
  --evaluation-frequency 5m \
  --severity 3 \
  --action "$AG_ID" \
  -o none
```

Decode the condition: sensitivity `medium`, and fire only when the threshold is violated in **4 of the last 5** evaluation periods. That `4 of 5` clause is the noise suppressor — it is what stops a single anomalous sample from paging anyone. Dynamic thresholds need roughly **3 days of history** before the model is usable; enabling one on a resource created an hour ago produces nothing useful.

**Step 5.** Understand statefulness. Metric alerts are **stateful**: the rule transitions `Resolved → Fired` on breach and back to `Resolved` when the condition clears, and it does **not** re-notify every evaluation while firing. Inspect the resulting alert instances:

```bash
az monitor activity-log alert list -g "$RG" -o table
az rest --method get \
  --url "https://management.azure.com/subscriptions/$SUB_ID/providers/Microsoft.AlertsManagement/alerts?api-version=2019-05-05-preview&timeRange=1d" \
  --query "value[].{name:name, sev:properties.essentials.severity, state:properties.essentials.alertState, mon:properties.essentials.monitorCondition, fired:properties.essentials.startDateTime}" \
  -o table
```

```
Name                                  Sev     State        Mon       Fired
------------------------------------  ------  -----------  --------  --------------------------
alert-blob-availability               Sev2    New          Fired     2026-09-05T14:22:00Z
```

Note the two independent state fields, which people conflate constantly:

- **`monitorCondition`** — `Fired` / `Resolved`. Owned by the platform: *is the condition true?*
- **`alertState`** — `New` / `Acknowledged` / `Closed`. Owned by humans: *has anyone dealt with it?*

An alert can be `Resolved` and still `New` (it self-healed, nobody looked). It can be `Fired` and `Closed` (someone triaged it as expected). Your on-call process must decide which field drives the queue.

**Step 6.** Create an alert processing rule to suppress notifications during a maintenance window — the correct way to silence alerts, as opposed to disabling rules and forgetting to re-enable them.

```bash
az monitor alert-processing-rule create \
  --name "apr-maintenance-window" \
  --resource-group "$RG" \
  --rule-type RemoveAllActionGroups \
  --scopes "/subscriptions/$SUB_ID/resourceGroups/$RG" \
  --description "Suppress notifications during the weekly patch window" \
  --schedule-recurrence-type Weekly \
  --schedule-recurrence Saturday \
  --schedule-start-time "02:00:00" \
  --schedule-end-time "04:00:00" \
  --schedule-time-zone "UTC" \
  --enabled true \
  -o table
```

```
Enabled    Location    Name                     ResourceGroup
---------  ----------  -----------------------  -----------------
True       Global      apr-maintenance-window   rg-az900-mon-lab
```

The alerts still **fire and are recorded** — you keep the history — but no action group is invoked in the window. Disabling the rules instead would have destroyed the record and created a permanent risk of leaving them off.

### Comprehension check — Lab 6

**Q24.** Distinguish `--window-size` from `--evaluation-frequency`. Give one concrete symptom of setting `--window-size 1m` on a spiky metric.

**Q25.** An alert shows `monitorCondition: Resolved` and `alertState: New`. What happened, and what does it tell you about your on-call process?

**Q26.** Why is `useCommonAlertSchema=true` close to mandatory once you have more than one alert *type* pointing at the same webhook?

**Q27.** A dynamic-threshold alert on a brand-new resource fires constantly for two days, then settles. Explain the mechanism, and state the minimum history the model needs.

**Q28.** Compare *disabling an alert rule* against *an alert processing rule* for a planned maintenance window. Name one thing you lose with the first approach and one operational risk it creates.

---

## Lab 7 — Application Insights: the application-level view

Application Insights is Azure Monitor's APM. It answers questions the platform cannot: *which* dependency call is slow, *which* exception correlates with the error rate, *what path* did this request take through five services.

**Step 1.** Create a workspace-based component.

```bash
az monitor app-insights component create \
  --app "$AI" \
  --location "$LOC" \
  --resource-group "$RG" \
  --workspace "$LAW_ID" \
  --application-type web \
  --kind web \
  -o table
```

```
AppId                                 ApplicationType    Location    Name            ResourceGroup      RetentionInDays
------------------------------------  -----------------  ----------  --------------  -----------------  ---------------
c41a9e77-58f2-4a1d-9d0f-2b6b1e3f77aa  web                eastus      appi-az900-lab  rg-az900-mon-lab   90
```

**Step 2.** Retrieve the connection string. Note what you must *not* use.

```bash
az monitor app-insights component show --app "$AI" -g "$RG" \
  --query "{connectionString:connectionString, workspace:WorkspaceResourceId}" -o jsonc
```

```jsonc
{
  "connectionString": "InstrumentationKey=8e2f...;IngestionEndpoint=https://eastus-8.in.applicationinsights.azure.com/;LiveEndpoint=https://eastus.livediagnostics.monitor.azure.com/;ApplicationId=c41a9e77-58f2-4a1d-9d0f-2b6b1e3f77aa",
  "workspace": "/subscriptions/0000.../workspaces/law-az900-lab"
}
```

**Use the connection string, never the bare instrumentation key.** The key alone carries no endpoint information, so it cannot work in sovereign clouds, cannot route through regional ingestion endpoints, and cannot reach Live Metrics. Instrumentation-key-only ingestion is deprecated.

**Step 3.** Wire it into an application. For an Azure App Service, auto-instrumentation requires no code change:

```bash
export CONN=$(az monitor app-insights component show --app "$AI" -g "$RG" --query connectionString -o tsv)

# Against a real App Service:
az webapp config appsettings set \
  --name "<your-webapp>" --resource-group "<its-rg>" \
  --settings \
    APPLICATIONINSIGHTS_CONNECTION_STRING="$CONN" \
    ApplicationInsightsAgent_EXTENSION_VERSION="~3" \
    XDT_MicrosoftApplicationInsights_Mode="recommended" \
  -o none
```

**Step 4.** Learn the telemetry schema. Because the component is workspace-based, the data is in the workspace under `App*` table names; the Application Insights query blade shows the legacy camelCase aliases for the same rows.

| Workspace table | App Insights alias | Contains |
|---|---|---|
| `AppRequests` | `requests` | Inbound requests: name, duration, resultCode, success |
| `AppDependencies` | `dependencies` | Outbound calls: SQL, HTTP, queues — target, duration, success |
| `AppExceptions` | `exceptions` | Unhandled and tracked exceptions with stack traces |
| `AppTraces` | `traces` | Application log lines (ILogger, console) |
| `AppPageViews` | `pageViews` | Browser page loads |
| `AppAvailabilityResults` | `availabilityResults` | Synthetic availability test outcomes |
| `AppMetrics` | `customMetrics` | Custom numeric telemetry |
| `AppPerformanceCounters` | `performanceCounters` | Host CPU/memory counters |

**Step 5.** Query it. Two paths — the App Insights data plane (uses the **App ID**) and the workspace (uses the **workspace GUID**):

```bash
# Via the Application Insights API — legacy schema names
az monitor app-insights query --app "$AI" -g "$RG" --analytics-query '
requests
| where timestamp > ago(24h)
| summarize Calls = count(), P95 = percentile(duration, 95), Failures = countif(success == false) by name
| top 10 by Calls desc
' -o table
```

```
name                       Calls   P95      Failures
-------------------------  ------  -------  --------
GET /api/orders            18422   412.3    37
POST /api/checkout         3120    1980.7   211
GET /health                86400   4.1      0
```

```bash
# Via the workspace — App* schema, and joinable with everything else in it
az monitor log-analytics query --workspace "$LAW_GUID" --analytics-query '
AppRequests
| where TimeGenerated > ago(24h)
| summarize Calls = count(), P95 = percentile(DurationMs, 95) by Name
| top 10 by Calls desc
' -o table
```

The second form is why workspace-based components matter: `AppRequests` sits in the same database as `AzureActivity`, `AzureDiagnostics` and your VM `Perf` data, so a single query can join application symptoms to infrastructure causes. Classic components could not do this.

**Step 6.** Understand sampling, because it silently changes your numbers. To control cost, the SDK may keep only a fraction of telemetry. **Adaptive sampling** (the ASP.NET Core default) varies the rate with load. Every retained record carries `itemCount` = how many original items it represents.

```bash
az monitor log-analytics query --workspace "$LAW_GUID" --analytics-query '
AppRequests
| where TimeGenerated > ago(24h)
| summarize Retained = count(), EstimatedTrue = sum(ItemCount), SamplingRate = round(100.0 * count() / sum(ItemCount), 1)
' -o table
```

```
Retained    EstimatedTrue    SamplingRate
----------  ---------------  ------------
21014       84056            25.0
```

Only 25 % of requests were kept. Therefore:

- `count()` **under-reports by 4×**. Use `sum(ItemCount)` for counts.
- `percentile(DurationMs, 95)` is still broadly valid — sampling is *operation-scoped*, so latency distributions are preserved.
- A specific rare exception may simply not be there. Sampling is the correct first hypothesis when a trace you know occurred cannot be found.

**Step 7.** Distributed tracing. Application Insights stitches a call chain using W3C Trace Context: every telemetry item carries `OperationId` (the whole trace) and `ParentId` (the immediate caller).

```bash
az monitor log-analytics query --workspace "$LAW_GUID" --analytics-query '
let slow =
    AppRequests
    | where TimeGenerated > ago(1h) and Name == "POST /api/checkout"
    | top 1 by DurationMs desc
    | project OperationId, RequestDuration = DurationMs;
slow
| join kind=inner (
    AppDependencies
    | where TimeGenerated > ago(1h)
    | project OperationId, Target, DependencyName = Name, DependencyType, DurationMs, Success
  ) on OperationId
| project Target, DependencyType, DependencyName, DurationMs, Success, RequestDuration
| order by DurationMs desc
' -o table
```

```
Target              DependencyType  DependencyName              DurationMs  Success  RequestDuration
------------------  --------------  --------------------------  ----------  -------  ---------------
sqldb-orders        SQL             SELECT dbo.OrderLines        4180.2      True     4890.6
api-payments        HTTP            POST /v2/authorize           412.8       True     4890.6
st0az900lab.blob    Azure blob      PUT /receipts/9931.pdf       88.1        True     4890.6
```

The 4.89 s request spent 4.18 s in one SQL statement. That is the answer, and no platform metric could have produced it.

**Step 8.** Live Metrics. A separate, low-latency channel: telemetry is streamed to the portal in near real time and **not persisted** — so it does not count toward ingestion billing and does not appear in any table. It is the right tool while watching a deployment roll out, and the wrong tool for anything you need to look at tomorrow.

### Comprehension check — Lab 7

**Q29.** Where does a workspace-based Application Insights component physically store its data, and name one capability this enables that classic components lacked.

**Q30.** Adaptive sampling is at 25 %. Which of these are distorted and which are not: `count()` of requests, `sum(ItemCount)`, the p95 of `DurationMs`, the presence of one specific rare exception? Justify each.

**Q31.** Why must you configure the connection string rather than the instrumentation key alone? Give two concrete failures the bare key causes.

**Q32.** `OperationId` and `ParentId` — what does each identify, and which one lets you reconstruct the *ordering* of a call chain?

**Q33.** You watch a deployment on Live Metrics and see a 5xx spike. Ten minutes later you want to re-examine that exact spike. What can you do, and what can you not?

---

## Lab 8 — Choosing the right tool: a decision drill

No new commands. For each scenario, name the tool, the data type (metric / log / event / recommendation), and justify it in one line. Write your answers before opening the collapsible section.

| # | Scenario |
|---|---|
| **S1** | The finance team wants to know which VMs are oversized. |
| **S2** | Page on-call within 2 minutes when a VM's CPU exceeds 90 % for 5 minutes. |
| **S3** | Determine who deleted a production key vault, and when. |
| **S4** | Determine which client IP read a specific blob at 03:14. |
| **S5** | The Azure SQL service is degraded in East US and you need to notify the on-call channel. |
| **S6** | One checkout request took 9 seconds; find which downstream call caused it. |
| **S7** | A single VM is `Unavailable` while the rest of the region is fine. |
| **S8** | Prove for an audit that no one accessed a storage container over the past 5 years. |
| **S9** | Watch error rates second-by-second during a canary deployment. |
| **S10** | The monthly Azure Monitor bill tripled and nobody knows why. |

### Comprehension check — Lab 8

**Q34.** Answer S1–S10.

**Q35.** State the general decision rule this drill encodes, in the form "use metrics when…, use logs when…".

---

## Lab 9 — Capstone: correlate an application regression with a platform change

This is the exercise that only works because Application Insights and the Activity Log live in the same workspace.

**Scenario.** At approximately 11:00 UTC, `POST /api/checkout` p95 latency tripled. Nobody admits to deploying anything.

**Step 1.** Establish the symptom and its exact onset.

```bash
az monitor log-analytics query --workspace "$LAW_GUID" --analytics-query '
AppRequests
| where TimeGenerated between (ago(6h) .. now())
| where Name == "POST /api/checkout"
| summarize P95 = percentile(DurationMs, 95), Calls = sum(ItemCount) by bin(TimeGenerated, 15m)
| order by TimeGenerated asc
' -o table
```

```
TimeGenerated          P95      Calls
---------------------  -------  -----
2026-09-05T10:15:00Z   611.4    780
2026-09-05T10:30:00Z   598.2    802
2026-09-05T10:45:00Z   624.9    791
2026-09-05T11:00:00Z   1902.7   776
2026-09-05T11:15:00Z   2044.1   769
```

Call volume is flat. This is not a load problem — the system got slower at constant traffic, which points at a change, not at capacity.

**Step 2.** Localise it to a layer: request time versus dependency time.

```bash
az monitor log-analytics query --workspace "$LAW_GUID" --analytics-query '
AppDependencies
| where TimeGenerated between (ago(6h) .. now())
| summarize P95 = percentile(DurationMs, 95) by bin(TimeGenerated, 15m), DependencyType, Target
| where P95 > 200
| order by TimeGenerated asc, P95 desc
' -o table | head
```

```
TimeGenerated          DependencyType  Target        P95
---------------------  --------------  ------------  ------
2026-09-05T10:45:00Z   SQL             sqldb-orders  340.1
2026-09-05T11:00:00Z   SQL             sqldb-orders  1710.5
2026-09-05T11:15:00Z   SQL             sqldb-orders  1854.9
```

The regression is in the SQL dependency, not in application code.

**Step 3.** Correlate against control-plane changes — the step that closes the case.

```bash
az monitor log-analytics query --workspace "$LAW_GUID" --analytics-query '
AzureActivity
| where TimeGenerated between (datetime_add("minute", -60, todatetime("2026-09-05T11:00:00Z")) .. todatetime("2026-09-05T11:15:00Z"))
| where CategoryValue == "Administrative" and ActivityStatusValue == "Success"
| project TimeGenerated, Caller, OperationNameValue, _ResourceId
| order by TimeGenerated asc
' -o table
```

```
TimeGenerated          Caller                  OperationNameValue                                 _ResourceId
---------------------  ----------------------  -------------------------------------------------  --------------------------------
2026-09-05T10:58:41Z   svc-deploy@tenant       Microsoft.Sql/servers/databases/write              /.../databases/sqldb-orders
```

A service principal rescaled the database two minutes before the regression. The p95 tripled because the service tier changed.

**Step 4.** Confirm with a platform metric — the independent, free corroboration.

```bash
export SQLDB=$(az sql db list --ids $(az sql server list --query "[0].id" -o tsv) --query "[?name=='sqldb-orders'].id" -o tsv 2>/dev/null)

az monitor metrics list --resource "$SQLDB" \
  --metric "dtu_consumption_percent" --aggregation Maximum --interval PT15M \
  --start-time "$(date -u -d '6 hours ago' +%Y-%m-%dT%H:%M:%SZ)" \
  --query "value[0].timeseries[0].data[].{t:timeStamp, max:maximum}" -o table | tail -6
```

```
T                          Max
-------------------------  -----
2026-09-05T10:30:00+00:00  41.2
2026-09-05T10:45:00+00:00  44.8
2026-09-05T11:00:00+00:00  99.6
2026-09-05T11:15:00+00:00  100.0
```

Three independent sources — application traces, control-plane audit, platform metric — converge on one cause. That triangulation is the working method this topic exists to teach.

**Step 5.** Codify the finding so the next occurrence detects itself.

```bash
cat > /tmp/query-latency.kql <<'EOF'
AppRequests
| where Name == "POST /api/checkout"
| summarize P95 = percentile(DurationMs, 95) by bin(TimeGenerated, 5m)
| where P95 > 1500
EOF

az monitor scheduled-query create \
  --name "alert-checkout-p95" \
  --resource-group "$RG" \
  --scopes "$LAW_ID" \
  --condition "count 'placeholder' > 0" \
  --condition-query placeholder="$(cat /tmp/query-latency.kql)" \
  --window-size 15m \
  --evaluation-frequency 5m \
  --severity 2 \
  --action-groups "$AG_ID" \
  --description "Checkout p95 above 1.5s" \
  -o table
```

```
Enabled    Location    Name                 ResourceGroup      Severity
---------  ----------  -------------------  -----------------  ----------
True       eastus      alert-checkout-p95   rg-az900-mon-lab   2
```

Unlike a metric alert, a **log search alert** is scoped to the *workspace*, runs arbitrary KQL, and is billed per rule per month. It is strictly more powerful and strictly slower and more expensive — which is why the rule of thumb is: alert on metrics when a metric will do, and fall back to log alerts only when the condition cannot be expressed as one.

### Comprehension check — Lab 9

**Q36.** In Step 1, call volume was flat while p95 tripled. Why does that single observation eliminate an entire class of hypotheses?

**Q37.** Step 3 required the Activity Log to be in the workspace. What was configured in Lab 4 to make that possible, and what would the investigation have looked like without it?

**Q38.** Step 4 used a platform metric to confirm what the traces already suggested. Why is that corroboration worth the extra step, given it produced no new conclusion?

**Q39.** Step 5 used a log search alert. Under what condition would a metric alert have been the better choice, and what would you have lost?

---

## Lab 10 — Cleanup

**Step 1.** Remove the subscription-scoped diagnostic setting — it is **not** in the resource group and survives its deletion.

```bash
az monitor diagnostic-settings subscription delete \
  --name "diag-activitylog-to-law" --yes -o none

az monitor diagnostic-settings subscription list --query "length(value)"
```

```
0
```

**Step 2.** Remove the resource-scoped diagnostic setting, for the same reason: it is a child of the storage account, which lives elsewhere.

```bash
az monitor diagnostic-settings delete \
  --name "diag-blob-to-law" \
  --resource "$TARGET/blobServices/default" -o none
```

**Step 3.** Delete the resource group. This removes the workspace, Application Insights component, action group, alert rules and processing rule.

```bash
az group delete --name "$RG" --yes --no-wait
```

**Step 4.** Verify nothing was orphaned.

```bash
az monitor activity-log alert list --query "[].name" -o tsv
az monitor alert-processing-rule list --query "[].name" -o tsv
az group exists --name "$RG"
```

> **Note on workspace deletion.** A deleted Log Analytics workspace enters a **soft-delete state for 14 days** and its name remains reserved. Re-creating a workspace with the same name inside that window *recovers* the old one, data included, rather than creating an empty one. To free the name immediately, use `az monitor log-analytics workspace delete --force`.

### Comprehension check — Lab 10

**Q40.** Why do the two diagnostic settings need explicit deletion when `az group delete` removes everything in the group?

**Q41.** You delete `law-az900-lab` and recreate it with the same name two days later, expecting an empty workspace. What actually happens, and how do you get the behaviour you wanted?

---

## Exam-focused summary

- **Advisor** = recommendations across five pillars (Reliability, Security, Cost, Operational Excellence, Performance). Read-only, derived, consumption-weighted score. Security content originates in Microsoft Defender for Cloud.
- **Service Health** = personalised platform events for *your* services and regions; four classes (service issues, planned maintenance, health advisories, security advisories). **Resource Health** = the verdict on *your instance*. Alerts on both are **Activity Log alerts**.
- **Azure Monitor** = the umbrella. **Metrics** are numeric, near-real-time, 93-day retention, free. **Logs** live in a **Log Analytics workspace**, are queried with **KQL**, and are billed per GB ingested and retained.
- **Diagnostic settings** are what turn resource logs on; nothing is collected without one. Up to 5 per resource, fanning out to workspace / storage / Event Hub / partner.
- **Alerts** = rule + action group (+ optional processing rule). Metric alerts are fast and cheap; log search alerts are powerful and slower.
- **Application Insights** = APM, always workspace-based, storing into a Log Analytics workspace. Distributed tracing via `OperationId`. Sampling means `sum(ItemCount)`, not `count()`.

---

## Sources

- AZ-900 study guide (official skills-measured list) — <https://learn.microsoft.com/en-us/credentials/certifications/resources/study-guides/az-900>
- Azure Monitor overview — <https://learn.microsoft.com/en-us/azure/azure-monitor/overview>
- Azure Monitor Logs / table plans and retention — <https://learn.microsoft.com/en-us/azure/azure-monitor/logs/data-retention-configure>
- Diagnostic settings — <https://learn.microsoft.com/en-us/azure/azure-monitor/platform/diagnostic-settings>
- Azure Monitor alerts overview — <https://learn.microsoft.com/en-us/azure/azure-monitor/alerts/alerts-overview>
- Dynamic thresholds — <https://learn.microsoft.com/en-us/azure/azure-monitor/alerts/alerts-dynamic-thresholds>
- Alert processing rules — <https://learn.microsoft.com/en-us/azure/azure-monitor/alerts/alerts-processing-rules>
- Common alert schema — <https://learn.microsoft.com/en-us/azure/azure-monitor/alerts/alerts-common-schema>
- Application Insights overview — <https://learn.microsoft.com/en-us/azure/azure-monitor/app/app-insights-overview>
- Workspace-based Application Insights — <https://learn.microsoft.com/en-us/azure/azure-monitor/app/create-workspace-resource>
- Application Insights sampling — <https://learn.microsoft.com/en-us/azure/azure-monitor/app/sampling>
- Application Insights table reference — <https://learn.microsoft.com/en-us/azure/azure-monitor/app/convert-classic-resource>
- Azure Advisor overview — <https://learn.microsoft.com/en-us/azure/advisor/advisor-overview>
- Advisor score — <https://learn.microsoft.com/en-us/azure/advisor/azure-advisor-score>
- Azure Service Health overview — <https://learn.microsoft.com/en-us/azure/service-health/overview>
- Resource Health overview — <https://learn.microsoft.com/en-us/azure/service-health/resource-health-overview>
- Azure Activity log — <https://learn.microsoft.com/en-us/azure/azure-monitor/essentials/activity-log>
- KQL quick reference — <https://learn.microsoft.com/en-us/azure/data-explorer/kql-quick-reference>
- Azure Monitor cost and usage — <https://learn.microsoft.com/en-us/azure/azure-monitor/cost-usage>

---

<details>
<summary><strong>Answers</strong></summary>

**Q1.** `Microsoft.OperationalInsights` owns the Log Analytics workspace (`workspaces`, tables, saved searches, data export). `Microsoft.Insights` owns diagnostic settings, metric alert rules, activity log alerts, action groups, Application Insights components, autoscale settings and data collection rules. The split reflects history and layering: `OperationalInsights` is the log *store* (originally OMS/Operations Management Suite), while `Insights` is the *monitoring control plane* that decides what gets collected, evaluated and notified. The store is one possible destination among several — the router is deliberately a separate provider from the thing it routes into.

**Q2.** Alert *rules* are definitions and live under `Microsoft.Insights`. Alert *instances* — the fired objects with severity, `monitorCondition` and `alertState`, plus alert processing rules and smart groups — live under `Microsoft.AlertsManagement`. This is the same rule/instance separation seen throughout Azure: `Microsoft.Insights` says "watch for X", `Microsoft.AlertsManagement` holds "X happened, here is its lifecycle". Querying fired alerts hits the second provider, so it must be registered independently.

**Q3.** Microsoft Defender for Cloud generates the security recommendations; Advisor surfaces them as a convenience aggregation. Advisor is therefore **not** the system of record for security posture — it is a read-only mirror. Consequences: the full detail (attack paths, regulatory compliance mapping, secure score breakdown, remediation automation) exists only in Defender for Cloud; and if Defender for Cloud is not enabled on a subscription, Advisor's Security pillar will be thin or empty, which is easy to misread as "we are secure".

**Q4.** `savingsAmount` in `extendedProperties` is typically an **annualised** projection for VM right-sizing recommendations, but the unit is not guaranteed uniform across recommendation types, and the portal can display monthly or annual depending on the view and the currency toggle. You must check the accompanying properties (`savingsCurrency`, and the recommendation type's documented semantics) before aggregating. Summing a mix of monthly and annual figures into one "projected savings" number is a genuinely common reporting error, and it is off by 12×.

**Q5.** The Advisor score is **consumption-weighted**, not a count. Each category's score weights every evaluated resource by its spend (the `consumptionUnits` field in Step 5's output). Forty recommendations spread across cheap, idle, non-production resources contribute almost nothing to the weighted denominator, while a handful of correctly configured expensive production resources dominate it. A high score with many open recommendations means "the things that cost money are configured well"; it is not a claim that few problems exist.

**Q6.** Not a bug — expected. Advisor recommendations are materialised by a periodic evaluation, not computed on read. Cost recommendations in particular depend on a rolling utilisation window (commonly 7 days) and can take up to ~24 hours to refresh after a change; even after refresh, the utilisation history that justified the recommendation does not disappear instantly. What to check: the recommendation's `lastUpdated`/refresh timestamp, trigger a manual refresh from the Advisor portal blade, and confirm the resize actually completed in the Activity Log. If it persists after a full refresh cycle, then investigate.

**Q7.** Not contradictory, and this is the normal case. Service Health reports events with **broad, multi-customer** impact — a region-level or service-level incident. Resource Health reports **your single instance**. An `Unplanned` unavailability with no Service Health event almost always means a **localised failure**: the physical host running your VM failed, or a single fabric node degraded. Microsoft does not raise a Service Health event for a one-host failure, because it affects only the customers on that host. The correct read is "the platform broke *my* instance, and it is expected to self-heal via service healing / redeploy" — which is precisely the failure that availability sets, availability zones and multi-instance designs exist to absorb.

**Q8.** Service Health events are **discrete, irregular, text-bearing records**, not numeric time series. They have no value to aggregate, no fixed sampling interval, and carry structured properties (`incidentType`, `impactedServices`, `communication`) that a metric alert's condition grammar (aggregation + operator + threshold) cannot express. The Activity Log is Azure's event stream for exactly this shape of data, and Service Health writes into it under the `ServiceHealth` category. Activity Log alerts are a *filter over an event stream*; metric alerts are a *threshold over a time series*. The data shape forces the choice.

**Q9.** `properties.incidentType`, set to `Incident`, narrows the rule to live service issues and excludes `Maintenance`, `Informational` and `Security`. The trade-off: you stop receiving planned-maintenance and security-advisory notifications through that rule entirely. Planned maintenance genuinely does require action (draining a node, rescheduling a batch window, patching before a TLS retirement date) — so the correct production design is *two* rules with different action groups and severities: incidents → paging action group at Sev 1; maintenance and advisories → email/ticket action group at Sev 3. Filtering the noise out of the paging path is right; deleting it is not.

**Q10.** An Activity Log alert's `scopes` must be a subscription, resource group, or resource — the Activity Log is a **per-subscription stream**, and there is no tenant-wide or management-group-wide Activity Log to filter. So one rule cannot cover 30 subscriptions. The standard remedy is **Azure Policy with a `deployIfNotExists` effect assigned at the management group**, which deploys an identical alert rule (plus its action group) into every in-scope subscription and remediates newly created ones automatically. Alternatives — Bicep/Terraform in a pipeline looping over subscriptions — work but drift as subscriptions are added; the policy approach is self-healing.

**Q11.** **Metrics.** Two properties from the table decide it: (1) **latency** — metrics land in the time-series store within seconds to ~3 minutes, while log ingestion adds minutes on top, so a 60-second detection target is not reliably achievable through Logs; (2) **cost** — platform metrics such as `Http5xx` are collected and alerted on for free, whereas the same alert via Logs requires enabling a diagnostic setting, paying per GB of ingestion, and paying per log search alert rule. Metric alerts are also evaluated by a dedicated near-real-time path rather than by scheduled KQL execution.

**Q12.** `SuccessE2ELatency` is a **duration in milliseconds per operation**. `Total` sums those durations across every operation in the interval, producing "the aggregate number of milliseconds all requests collectively spent" — a number that grows with traffic and says nothing about how slow anything was. Under constant latency it doubles when traffic doubles. The meaningful aggregations for a latency metric are `Average`, `Minimum` and `Maximum`; the metric definition's `supportedAggregationTypes` lists only `Average` for exactly this reason, and Azure will not stop you from asking for a nonsensical one.

**Q13.** (1) **Custom metrics.** Metrics you emit yourself — via the Azure Monitor custom metrics API, Application Insights `customMetrics`, or the Azure Monitor Agent from a guest OS — are billed per time series / per metric-dimension combination. Only *platform* metrics emitted by the resource provider are free. (2) **Routing metrics into Logs.** A diagnostic setting with a `metrics` section (as in Lab 4 Step 4) copies metric data into the Log Analytics workspace, where it is billed as ordinary log ingestion per GB. Related third case worth knowing: **metric alert rules** bill per monitored time series per month, so alerting on a free metric is not itself free — and splitting an alert by a high-cardinality dimension multiplies that charge.

**Q14.** Add a **diagnostic setting** on the storage account with the `Transaction` metric category enabled, targeting either a Log Analytics workspace (queryable via KQL, retention configurable up to 730 days interactive and 12 years total) or a storage account (cheapest, but not directly queryable). The new cost is **per-GB ingestion plus per-GB-month retention** — metric data that was free in the metrics store becomes billable the moment it is copied into Logs. For a pure retention requirement with rare access, routing to a storage account (or a workspace table on the Auxiliary plan with long-term retention) is dramatically cheaper than Analytics-plan retention; the trade-off is that reading it back requires a search job or an external tool rather than an interactive query.

**Q15.** **Platform metrics: available.** Emitted automatically by the resource provider into the metrics store; no configuration, no cost, ~93 days. **Resource logs: NOT available, and unrecoverably so.** Without a diagnostic setting the resource emits them and the platform discards them — there is no buffer, no retroactive enablement, and no way to recover yesterday's data by turning it on today. **Activity Log entries: available.** The Activity Log records control-plane operations (create/update/delete) at the subscription level, independently of any per-resource setting, and is retained 90 days free. The practical consequence is the most important one in this whole topic: after an incident you can always see *that the resource was changed* and *how it performed numerically*, but you can only see *what it did internally* if someone turned resource logs on beforehand.

**Q16.** **Activity Log** — the subscription-scoped record of **control-plane** operations: who called which ARM API against which resource, when, with what result. **Resource logs** — **data-plane** records emitted by the resource about its own internal operations, available only via a diagnostic setting. Therefore: "a `DELETE` was issued against this key vault" is the **Activity Log** (an ARM operation on the resource); "a secret was read from this key vault" is a **resource log** (`AuditEvent` category → `KeyVaultAuditLogs`), because reading a secret is a data-plane call that never touches ARM.

**Q17.** Action groups are **global** resources: they hold notification configuration (email addresses, webhook URLs, SMS numbers) with no regional data plane and no region-bound state, and they must be reachable from alert rules in any region — including Activity Log alerts, which are themselves global because the Activity Log is a region-independent subscription stream. The Log Analytics workspace, by contrast, is a real **regional data store**: it physically holds ingested log data, so it has a region for latency, data-residency and sovereignty reasons. The rule generalises — resources that store data are regional, resources that only hold configuration used cross-region are global.

**Q18.** Two diagnostic settings on the same resource (up to 5 are allowed): setting A → **Log Analytics workspace** with 30-day retention, for operational queries, alerting and correlation; setting B → **storage account** with an immutability policy and a lifecycle-management rule tiering blobs to Cool then Archive, for the 7-year audit obligation. It is far cheaper because workspace retention is billed at roughly $0.13/GB/month against archive-tier blob storage at a small fraction of a cent per GB/month — two to three orders of magnitude apart — and because you are not paying Analytics-plan *ingestion* rates for data that will never be queried interactively. The trade-off is real: the archived copy is not KQL-queryable, so answering an auditor's question means a search job, a restore, or an external tool. That is the correct trade when the expected number of reads over seven years is approximately zero.

**Q19.** Without `WorkspaceResourceId` the component would be a **classic** Application Insights resource with its own isolated storage. What you would lose: KQL joins between application telemetry and any other data in the workspace (`AzureActivity`, `AzureDiagnostics`, `Perf`, `Heartbeat`) — i.e. exactly the capstone in Lab 9; unified retention and table-plan configuration; workspace-level RBAC and customer-managed keys; Private Link; and commitment-tier pricing. Omitting it is no longer possible because classic Application Insights was **retired in February 2024** — new classic components cannot be created, and the ARM API requires the workspace linkage.

**Q20.** Log Analytics stores data in **time-based partitions/extents** ordered by ingestion time, with per-extent min/max timestamp metadata. A leading `where TimeGenerated > ago(24h)` lets the query planner apply **partition elimination**: entire extents outside the window are never opened, decompressed, or scanned. Placed *after* a `summarize` or a `join`, the filter can no longer prune partitions — the engine must materialise the full table first and then discard rows, so it reads terabytes to return kilobytes. On a large workspace this is the difference between a sub-second query and a timeout, and it is the single highest-leverage KQL habit.

**Q21.** Not a bug — it is a documented constraint of the plan. The **Basic** table plan supports only a restricted KQL subset (single-table queries, a limited operator set, no `join` across tables) and explicitly **does not support alert rules**. It also bills per query rather than including query cost in ingestion. The rule violated: *the table plan must match how the data is used*. Basic is for high-volume data you ingest for occasional forensic search; anything you alert on, join, or query routinely belongs on Analytics. Choose the plan from the access pattern, not from the ingestion volume alone.

**Q22.** **Analytics with 365-day retention:** ~$2.76/GB ingestion (≈$1,380/month for 500 GB) plus retention beyond the included 30 days at ~$0.13/GB/month, compounding as the corpus grows toward 6 TB — several thousand dollars a month at steady state. **Basic or Auxiliary plus long-term retention:** ingestion at ~$0.65/GB (Basic) or ~$0.15/GB (Auxiliary), with data beyond interactive retention held at long-term rates near $0.026/GB/month — comfortably an order of magnitude cheaper overall. The operational cost of the cheap option: the data is **not interactively queryable**. Retrieving it requires a **search job** or a **restore**, each separately billed, each taking minutes to hours, and neither usable inside an alert rule or a live incident. You are trading incident-time latency for standing cost — the right trade for data that is genuinely never read, and the wrong one the first time an auditor's question turns into an outage-time question.

**Q23.** (1) **Basic ingestion-tier data for certain data types.** Some data is ingested free by design — historically the first ~5 GB/month per billing account, and specific tables such as `Usage`, `AzureActivity`, `Heartbeat` and `Operation` are not billed for ingestion. (2) **Metadata and platform tables** — `Usage` and `Operation` themselves, plus the free Activity Log ingestion, carry `IsBillable == false`. Also worth knowing: **Microsoft Sentinel free data connectors** and some Defender for Cloud data ingest free into an enabled workspace. The general point is that `IsBillable` is a per-record flag maintained by the platform, so `Usage | where IsBillable == true` is the only trustworthy source for what you are actually paying for — do not compute it from raw record counts.

**Q24.** **`--window-size`** (aggregation granularity) is *how much history each evaluation examines* — with `5m`, every evaluation averages the last 5 minutes. **`--evaluation-frequency`** is *how often that evaluation runs* — with `1m`, once per minute over a sliding window. They are independent; `5m`/`1m` is a smoothed condition checked frequently. Symptom of `--window-size 1m` on a spiky metric: **alert flapping** — a single anomalous one-minute sample (a garbage-collection pause, a deployment restart, a retried batch) breaches the threshold, the rule fires, the next minute is normal, the rule resolves, and on-call receives a fired-then-resolved pair every few minutes. The alert becomes noise, and noisy alerts get muted, which is how a real incident goes unnoticed.

**Q25.** `monitorCondition: Resolved` means the platform observed the condition become true and then become false again — the problem occurred and self-healed. `alertState: New` means **no human ever acknowledged or closed it**. So: something broke, recovered on its own, and nobody looked. What this tells you about your on-call process depends on frequency. One instance is fine. A recurring pattern of `Resolved`/`New` alerts is a signal that either (a) the threshold is too tight and generating self-clearing noise that people have learned to ignore, or (b) a genuine intermittent fault is repeatedly self-healing and masking a degrading component. Both need action, and both are invisible if your queue filters on `monitorCondition` alone. Track the `Resolved`+`New` count as a health metric of the *alerting system itself*.

**Q26.** Without it, each alert type POSTs a structurally different JSON payload: a metric alert nests its data under one shape, a log search alert under another, an Activity Log alert under a third, and Application Insights smart detection under a fourth — with different field names for the same concepts (resource ID, severity, fired time, condition description). A single webhook receiver would need a discriminator and one parser per type, and would silently break whenever Microsoft versions a payload. The **common alert schema** normalises all of them into one envelope with a shared `essentials` block (alertRule, severity, signalType, monitorCondition, firedDateTime, alertTargetIDs) plus a type-specific `alertContext`. One handler, one parser, and new alert types work on day one without a code change.

**Q27.** Dynamic thresholds train a model on the metric's **historical behaviour**, learning its baseline level, variance, and daily/weekly seasonality. A brand-new resource has no history, so the model has nothing to distinguish "normal" from "anomalous" and treats ordinary variation as deviation — hence constant firing. As data accumulates the model converges and the noise stops. The minimum is roughly **3 days of history and about 30 samples** before the threshold is meaningful; a full week is better, because that is what captures weekday/weekend seasonality. Operational implication: never enable dynamic thresholds as part of a resource's initial deployment — deploy the resource, wait out the training period, then enable them, or you will train your team to ignore the alert before it ever works.

**Q28.** **Disabling the rule** stops evaluation entirely — no alerts fire, and **no history is recorded**. You lose the record of what happened during the maintenance window, which is exactly when things are most likely to break; if the patch caused a regression, you have no telemetry of when the condition first went true. The operational risk: **the rule stays disabled**. Someone disables it at 02:00 Saturday, the window runs long, nobody re-enables it, and the alert is silently off for weeks — a failure mode with a long history of causing undetected outages. **An alert processing rule** suppresses only the *action* (`RemoveAllActionGroups`): alerts still evaluate, still fire, still appear in the alerts list with full timestamps, but no one is paged. It has a declarative schedule with an end time, so it self-expires and cannot be forgotten. Suppress notifications, never detection.

**Q29.** It stores its data in the **Log Analytics workspace** referenced by `WorkspaceResourceId`, in tables named `AppRequests`, `AppDependencies`, `AppExceptions`, `AppTraces`, etc. (the `requests`/`dependencies` names in the App Insights query blade are aliases over the same rows). The capability this enables and classic components lacked: **cross-source KQL joins** — a single query can correlate application telemetry with `AzureActivity`, `AzureDiagnostics`, VM `Perf` counters or Sentinel data, which is exactly what makes the Lab 9 capstone possible. Classic components had a separate, isolated store; correlating a latency regression with a control-plane change meant exporting both and joining them by hand. Secondary benefits: unified retention and table-plan configuration, workspace-level RBAC, customer-managed keys, Private Link, and commitment-tier pricing across all telemetry.

**Q30.** **`count()` of requests — distorted.** It counts *retained* records only, under-reporting the true volume by roughly 4× at a 25 % rate. **`sum(ItemCount)` — correct.** Each retained record carries `ItemCount` = the number of original items it represents, so summing it reconstructs the true count; this is why every count-style aggregation over sampled telemetry must use `sum(ItemCount)` rather than `count()`. **p95 of `DurationMs` — essentially valid.** Sampling in Application Insights is *operation-scoped* and effectively random with respect to latency: it keeps or drops an entire operation's telemetry together, without preferring fast or slow ones. The retained set is therefore a representative sample of the latency distribution, and percentiles hold up well — though confidence in the extreme tail (p99.9) degrades as the retained count shrinks. **Presence of one specific rare exception — unreliable.** A rare event has a ~25 % chance of surviving sampling. Its absence is not evidence it did not occur, which is why "sampling dropped it" should be your first hypothesis when a trace you know happened cannot be found — and why critical telemetry should be excluded from sampling explicitly rather than hoped for.

**Q31.** The connection string carries the instrumentation key **plus the endpoints**: `IngestionEndpoint`, `LiveEndpoint`, and the `ApplicationId`. A bare instrumentation key implies the *global public-cloud default endpoints*. Two concrete failures: (1) **Sovereign and regional clouds** — in Azure Government, Azure China, or any deployment expected to use a regional ingestion endpoint, the default endpoint is wrong or unreachable, so telemetry is silently dropped with no error surfaced in the application; (2) **Live Metrics does not work** — the live stream uses a separate `LiveEndpoint` that a bare key cannot supply, so the real-time view stays empty. A third, increasingly relevant failure: Private Link / regional-endpoint routing cannot be expressed at all with a key. Instrumentation-key-only ingestion is deprecated; treat the connection string as the only supported configuration.

**Q32.** **`OperationId`** identifies the **entire distributed trace** — one logical end-to-end transaction. Every telemetry item produced anywhere in the call chain, across every service and process, shares the same `OperationId`; filtering on it retrieves the complete trace. **`ParentId`** identifies the **immediate caller** — the specific span that invoked this one. It is `ParentId` that lets you reconstruct **ordering and nesting**: `OperationId` gives you an unordered bag of spans belonging to the same transaction, while the `ParentId → Id` edges form the tree that shows what called what, in what sequence, and which call is nested inside which. Both are propagated across process boundaries via the W3C Trace Context `traceparent` header.

**Q33.** **You cannot re-examine it in Live Metrics.** Live Metrics is a streaming, non-persisted channel: telemetry is sampled and pushed straight to the connected portal session, never written to the workspace. Nothing is stored, which is also why it incurs no ingestion cost and has ~1-second latency. **What you can do:** query the *persisted* telemetry for the same time range — `AppRequests | where TimeGenerated between (...) | where Success == false` — because the regular (sampled) telemetry pipeline was recording throughout, independently of whether anyone was watching Live Metrics. The distinction to internalise: Live Metrics is an instrument, not a recorder. Use it to watch a deployment in the moment; use Logs to reconstruct it afterwards. If a spike matters, capture the timestamp while you are watching, because that timestamp is the only thing Live Metrics leaves behind.

**Q34.** Scenario answers:

- **S1** — **Azure Advisor**, Cost pillar (*recommendation*). Advisor already computes right-sizing from P95 CPU/memory over a rolling window and reports a savings figure with its evidence; building this from metrics by hand duplicates work Microsoft does for free.
- **S2** — **Azure Monitor metric alert** on `Percentage CPU` (*metric*), `--window-size 5m --evaluation-frequency 1m`, wired to a paging action group. Metrics because of latency and cost: the platform metric is free and evaluated in near-real-time, which a log-based path cannot match.
- **S3** — **Activity Log** (*event*), queried directly or via `AzureActivity` in the workspace. Deleting a key vault is a control-plane ARM operation, recorded with `Caller` and timestamp regardless of any diagnostic setting.
- **S4** — **Resource logs** (*log*): the storage account's `StorageRead` category → `StorageBlobLogs`, enabled by a diagnostic setting. Reading a blob is a data-plane operation and never appears in the Activity Log. Critically, this only works if the setting existed *before* 03:14.
- **S5** — **Service Health alert**, i.e. an **Activity Log alert** with `category = ServiceHealth` and `properties.incidentType = Incident` (*event*), targeting an action group with a webhook to the channel. Not a metric alert — the data is a discrete text-bearing event, not a time series.
- **S6** — **Application Insights** distributed tracing (*log*): take the request's `OperationId` and join `AppDependencies` on it, ordering by `DurationMs`, exactly as in Lab 7 Step 7. No platform metric can attribute latency to a specific downstream call.
- **S7** — **Resource Health** (*event*), reading `availabilityState` and especially `reasonType` to separate a platform fault (`Unplanned`) from your own action (`UserInitiated`). Service Health would show nothing — a single-host failure is not a multi-customer incident.
- **S8** — **Diagnostic setting → storage account** with an immutability policy and lifecycle tiering to Archive (*log*, archived). Five years of workspace retention would cost orders of magnitude more for data that will be read approximately never; the trade-off is that answering the auditor requires a search job or external tooling rather than a live query.
- **S9** — **Live Metrics** (*streamed, non-persisted*). Sub-second latency and no ingestion cost, which is what "second-by-second during a canary" requires. Note the ceiling: nothing is stored, so capture timestamps while watching and reconstruct afterwards from `AppRequests`.
- **S10** — **`Usage` table in the workspace** (*log*): `Usage | where IsBillable == true | summarize sum(Quantity) by DataType, bin(TimeGenerated, 1d)`. This attributes the increase to a specific table and a specific day, which is what turns "the bill tripled" into "someone enabled `allLogs` on a chatty resource on the 12th".

**Q35.** **Use metrics when the question is "how much / how fast / is it up", the answer is numeric, and you need it fast or cheap** — alerting, dashboards, capacity trends, first-response triage. Metrics are pre-aggregated, low-latency, fixed-schema and free for platform data, but they cannot tell you *which* request, *which* caller, or *why*. **Use logs when the question is "what exactly happened, to which entity, in what order, and why"** — investigation, correlation, audit, forensics. Logs carry arbitrary structure and full context and can be joined across sources, but they cost per GB and arrive minutes later. The practical operating rule that follows: **detect on metrics, diagnose in logs.** Alert on the cheap fast signal, then pivot into the expensive rich one once a human is already looking. Inverting this — building alerting on log queries because logs are more expressive — is the most common and most expensive Azure Monitor design mistake.

**Q36.** Flat call volume with tripled p95 **eliminates every load- and capacity-driven hypothesis**: traffic spikes, a viral event, retry storms, a noisy-neighbour surge in your own traffic, autoscale lagging behind demand. All of those necessarily show up as increased request volume. If the system got slower while doing the same amount of work, the *work itself* became more expensive — which points at a change: a deployment, a configuration or SKU change, a schema or index change, a dependency degrading, or a resource being throttled. This single observation cuts the hypothesis space roughly in half before any further query, which is why establishing the volume/latency relationship is the correct first step in any latency investigation rather than an afterthought.

**Q37.** Lab 4 Step 3 created a **subscription-scoped diagnostic setting** exporting the Activity Log's `Administrative` (and other) categories into the Log Analytics workspace, which is what populates the `AzureActivity` table. Without it, the Activity Log still exists in its own 90-day store and the same information is retrievable — via `az monitor activity-log list`, the portal blade, or the Activity Log API. But it would be a **separate, manual, un-joinable step**: you would export or eyeball a time-filtered list, read timestamps by hand, and mentally correlate them against the KQL results from Steps 1–2. With the export in place, application telemetry and control-plane audit are in one database, so the correlation is a single query that can be saved, alerted on, and put in a workbook. The difference is not access to the data — it is whether the correlation is a repeatable artefact or a human doing timestamp arithmetic during an incident.

**Q38.** Because the trace evidence and the audit evidence are both **circumstantial about the mechanism**. `AppDependencies` proves the SQL calls got slower; `AzureActivity` proves someone wrote to the database resource. Neither proves the write *caused* the slowness — the operation could have been an unrelated tag update, and the SQL slowdown could have had a coincident cause. `dtu_consumption_percent` going from ~44 % to 100 % at exactly the transition is **independent, platform-authored evidence of the mechanism**: the database is now resource-saturated, which is what a tier reduction produces and what a tag update does not. Three sources of different provenance — the application's own SDK, ARM's audit trail, and the resource provider's metrics — converging on one explanation is a materially stronger claim than any two of them. It matters because the output of this investigation is a change request against someone else's system, and "we think the rescale did it" gets argued with while "the DTU ceiling was hit two minutes after the documented rescale" does not.

**Q39.** A **metric alert** would have been better if the condition were expressible over a single platform metric on a single resource — for example, alerting on the App Service's `HttpResponseTime` average or on the SQL database's `dtu_consumption_percent`. It would be **faster** (near-real-time evaluation instead of a scheduled KQL run on a 5-minute frequency, so detection in ~1–2 minutes rather than 5–10), **cheaper** (billed per time series rather than per rule per month, with no query cost), and operationally simpler. What you would lose: the **precision of the condition**. The metric alert cannot express "p95 of `DurationMs` for the specific operation named `POST /api/checkout`" — that requires filtering telemetry by operation name and computing a percentile, which is a KQL query, not a metric aggregation. You would end up alerting on average latency across *all* endpoints, where a slow checkout path is diluted by a fast, high-volume `/health` endpoint and may never breach the threshold. The general rule stands — prefer metric alerts and fall back to log search alerts only when the condition genuinely cannot be expressed as one — and this is a case where it genuinely cannot.

**Q40.** Because a diagnostic setting is **not a child of the workspace, and not a member of the resource group you deleted** — it is a child resource of the *monitored* object. The subscription-scoped setting (`diag-activitylog-to-law`) is a child of the **subscription**, which obviously outlives any resource group. The resource-scoped setting (`diag-blob-to-law`) is a child of the **storage account**, which lives in a different resource group. `az group delete` removes only resources contained in that group; both settings survive it, now pointing at a destination workspace that no longer exists. The practical consequence is a class of orphan that accumulates quietly in real subscriptions: settings referencing deleted workspaces or Event Hubs, silently failing to deliver, cluttering the resource's Diagnostic settings blade, and occasionally blocking the monitored resource's own deletion. Delete the router before deleting the destination.

**Q41.** You get the **old workspace back, with its data**. Deleted Log Analytics workspaces enter a **soft-delete state for 14 days** during which the name stays reserved in the subscription; creating a workspace with the same name, resource group and subscription inside that window performs a **recovery**, restoring the previous workspace including its ingested data, table configuration and retention settings — not a fresh empty one. To get a genuinely empty workspace you have two options: delete with **`az monitor log-analytics workspace delete --force`**, which performs a permanent (hard) delete and immediately releases the name; or simply choose a different name. The behaviour exists as a safety net against accidental deletion of an observability store, and it is worth knowing before an incident-response drill: recovering a workspace deleted by mistake is a `create` away, and only within those 14 days.

</details>