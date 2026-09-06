# 3.1 — Describe cost management in Azure

**Exam:** AZ-900 (Microsoft Azure Fundamentals), syllabus version 2026-07-20
**Domain:** 3 — Describe Azure management and governance
**Weight:** 8.33 %
**Level:** Platform Architect / SRE — production depth

---

## 1. The production problem: cost is a control loop, not a report

Every SRE team eventually discovers that cloud spend behaves exactly like latency or error rate: it is an **emitted signal from a distributed system**, it drifts, it spikes, and nobody notices until somebody outside the team complains. The difference is that a p99 regression is visible in seconds, while a cost regression is visible in **8 to 24 hours** — because that is the pipeline latency between a resource emitting a usage record and that record landing in Microsoft Cost Management.

That latency defines the entire architecture of Azure cost governance. Concretely:

```
resource emits usage  ──►  metering pipeline  ──►  Cost Management store  ──►  budget evaluation
      t=0                    t + minutes            t + 8..24 h                t + 8..24 h + eval
```

A runaway `Standard_ND96asr_v4` GPU pool started at 02:00 will not appear in a budget alert until the following afternoon. By then it has burned roughly 12 hours × ~€25/h × 8 nodes ≈ **€2,400**. No budget will have stopped it, because **budgets in Azure do not stop anything** — they raise a notification. This is the single most important production truth in this objective, and it is also the most frequently missed exam question.

### 1.1 The three failure modes this objective exists to prevent

| Failure mode | Symptom in production | Root architectural cause | Mitigation covered here |
|---|---|---|---|
| **Unattributable spend** | Invoice is €180k, finance asks which product owns it, nobody can answer | Tags are *not* inherited from resource group or subscription by default; usage records carry only the tags present at emission time | Tag taxonomy + Azure Policy `Modify` + Cost Management **tag inheritance** |
| **Silent drift** | Spend grows 4 %/month with no deploy that explains it | No forecast-based budget, no anomaly detection, no daily export into a queryable store | Forecasted budget thresholds + `scheduledActions` (InsightAlert) + FOCUS exports |
| **Wrong purchase decision** | Team commits 3 years of Reserved Instances on a workload that gets refactored in 9 months | Pricing Calculator used as if it were a forecast; no amortized-cost view; no utilization telemetry | Pricing Calculator vs TCO vs Cost Management separation, amortized view, reservation utilization |

### 1.2 Where cost sits in the platform architecture

Cost management is an **extension resource plane** layered over the ARM resource plane. It does not live inside your subscription's data path; it reads the metering stream out-of-band. That has two consequences an architect must internalize:

1. **Cost Management is scoped by the billing hierarchy, not only by the ARM hierarchy.** Some scopes (billing account, billing profile, invoice section) do not exist in ARM at all.
2. **Cost data is immutable history.** You cannot retroactively re-tag a usage record emitted last month by tagging the resource today — with one narrow, deliberately engineered exception (tag inheritance, current billing month only).

---

## 2. The billing hierarchy: the substrate everything else binds to

Before any tool makes sense, you need the scope model. Cost Management operations take a **scope string**, and knowing which one to pass is 80 % of debugging "why does this API return 404".

```
Billing account  (EA enrollment | MCA billing account | MOSP)
└── Department / Billing profile          ← invoice is generated here (MCA)
    └── Enrollment account / Invoice section
        └── Subscription                   ← ARM root for most teams
            └── Management group (crosses subscriptions, ARM-only)
            └── Resource group
                └── Resource               ← emits usage records
```

### 2.1 Scope strings you will actually type

| Scope | Scope string | Cost analysis | Budgets | Exports | Notes |
|---|---|---|---|---|---|
| Subscription | `/subscriptions/{subId}` | ✅ | ✅ | ✅ | The default working scope |
| Resource group | `/subscriptions/{subId}/resourceGroups/{rg}` | ✅ | ✅ | ✅ | Cheapest unit of hard allocation |
| Management group | `/providers/Microsoft.Management/managementGroups/{mgId}` | ✅ | ✅ | ✅ | EA/MCA only; not for MOSP |
| EA billing account | `/providers/Microsoft.Billing/billingAccounts/{enrollmentId}` | ✅ | ✅ | ✅ | Needs enterprise admin |
| EA department | `/providers/Microsoft.Billing/billingAccounts/{id}/departments/{deptId}` | ✅ | ✅ | ✅ | |
| EA enrollment account | `/providers/Microsoft.Billing/billingAccounts/{id}/enrollmentAccounts/{eaId}` | ✅ | ✅ | ✅ | |
| MCA billing profile | `/providers/Microsoft.Billing/billingAccounts/{id}/billingProfiles/{pId}` | ✅ | ✅ | ✅ | Invoice boundary |
| MCA invoice section | `.../billingProfiles/{pId}/invoiceSections/{sId}` | ✅ | ✅ | ✅ | |

### 2.2 Agreement types and what they change

| Agreement | Who signs it | Price mechanism | Cost Management availability | Key operational difference |
|---|---|---|---|---|
| **Microsoft Customer Agreement (MCA)** | Direct with Microsoft, self-serve or field | Negotiated / list | Full, including billing-account scopes | The modern default; invoice sections give hard chargeback boundaries |
| **Enterprise Agreement (EA)** | Large org, 3-year commitment | Prepaid monetary commitment + overage | Full, department/enrollment scopes | Legacy but everywhere; `enrollmentId` is the billing account |
| **Pay-as-you-go (MOSP)** | Credit card / invoice | Public list price | Subscription + RG scopes only; **no management-group cost views** | Fine for labs, breaks chargeback at scale |
| **Cloud Solution Provider (CSP)** | Through a partner | Partner-set | Partner-mediated; customer sees partner-shaped data | You may not see real Microsoft list prices at all |

> **Exam trap:** "Which subscription type is required to view costs at a management group scope?" → EA or MCA. Pay-as-you-go cannot.

---

## 3. Factors that affect costs in Azure

The exam asks you to *describe* them. An architect has to *model* them. Here is the full set, ordered by how often each one blows up a budget in the field.

### 3.1 The canonical factor list

| # | Factor | Mechanism | Typical magnitude of surprise |
|---|---|---|---|
| 1 | **Resource type** | Each type has its own meters (a `Microsoft.Compute/virtualMachines` bills vCPU-hours; a `Microsoft.CognitiveServices/accounts` bills tokens) | Structural |
| 2 | **Consumption** | Per-second / per-hour / per-GB / per-operation metering | Structural |
| 3 | **Maintenance & lifecycle** | Orphaned disks, unattached public IPs, stale snapshots, idle load balancers | **10–25 % of a mature subscription** |
| 4 | **Geography (region)** | Same SKU differs by region: power, real estate, local tax, capacity | 15–40 % between e.g. `northeurope` and `brazilsouth` |
| 5 | **Network traffic** | Ingress free; egress metered by *bandwidth pricing zone*; inter-AZ and inter-region are separate meters | The #1 unmodelled line item |
| 6 | **Subscription type** | Free trial, Dev/Test, Sponsorship, CSP change the effective rate card | Up to 100 % (credit-funded) |
| 7 | **Azure Marketplace** | Third-party ISV charges billed through Azure but **not covered by Azure commitments/credits** | Silent — RIs never apply |
| 8 | **Service tier / SKU** | Basic vs Standard vs Premium, LRS vs GRS vs RA-GZRS | 2–6× |
| 9 | **Purchase model** | PAYG vs Reservation vs Savings Plan vs Spot vs Hybrid Benefit | Up to 90 % |
| 10 | **Support plan** | Developer / Standard / Professional Direct / Unified — flat monthly, separate meter | Fixed |

### 3.2 Network egress: the factor that breaks every estimate

Ingress into Azure is free. Egress is not, and it is metered along **three independent axes** that people conflate:

| Traffic pattern | Meter family | Charged? | Common architectural trigger |
|---|---|---|---|
| Internet → Azure (ingress) | — | **Free** | — |
| Azure → Internet (egress) | Bandwidth, by pricing zone, tiered | **Yes** (first 100 GB/month free per billing account) | Serving media, container image pulls from a public registry |
| VM ↔ VM, same VNet, same AZ | — | Free | — |
| VM ↔ VM, same region, **different AZ** | Inter-AZ data transfer | **Yes**, both directions | Zone-redundant AKS node pools chatting across zones |
| VM ↔ VM, different regions | Inter-region egress | **Yes**, source side | Geo-replication, cross-region DR sync |
| VNet peering, same region | Peering in/out | **Yes**, both sides | Hub-and-spoke topologies |
| VNet peering, global (cross-region) | Global peering in/out, higher rate | **Yes**, both sides | Multi-region hub |
| Through NAT Gateway | NAT hourly + per-GB processed, **on top of** egress | **Yes** | Egress-controlled AKS clusters |
| Through Azure Firewall | Firewall hourly + per-GB processed, **on top of** egress | **Yes** | Any regulated landing zone |
| Private Endpoint | Endpoint hourly + per-GB in and out | **Yes** | "We used Private Link to save money" — it does not |

> **Production anti-pattern:** a zone-redundant AKS cluster with a chatty service mesh and no topology-aware routing pays inter-AZ transfer on the majority of east-west traffic. Enabling `service.kubernetes.io/topology-mode` / topology-aware hints is a *cost* optimization before it is a latency one.

### 3.3 Compute purchase models — the real trade-off table

| Model | Discount vs PAYG | Commitment | Flexibility | Cancellable | SLA | When an SRE picks it |
|---|---|---|---|---|---|---|
| **Pay-as-you-go** | 0 % (baseline) | None | Total | n/a | Full | Spiky, unknown, or short-lived workloads |
| **Reserved Instance (1 yr)** | up to ~40 % | 1 year, specific VM series + region | Instance-size flexibility *within* a series/region | Self-service refund, capped (~$50k / rolling 12 months) and may carry an early-termination fee | Full | Stable baseline with a known SKU |
| **Reserved Instance (3 yr)** | up to ~72 % | 3 years | Same | Same | Full | Databases, domain controllers, anything you know will outlive the term |
| **Azure Savings Plan for compute** | up to ~65 % | Hourly **$ commitment**, 1 or 3 yr | Applies across VM series, regions, **and** eligible services (VMs, App Service, Container Instances, Dedicated Hosts, Functions Premium) | **No** — not cancellable, not refundable, not exchangeable | Full | Fleet is stable in *spend* but churns in *SKU* |
| **Spot VMs** | up to ~90 % | None | Evictable at 30 s notice; capacity- or price-based eviction policy | n/a | **No SLA** | Batch, CI runners, stateless AKS node pools with PDBs |
| **Azure Hybrid Benefit** | up to ~40 % (Windows Server), stacks with RI for SQL toward ~85 % | Requires **Software Assurance** or subscription licences | Bring-your-own-licence | n/a | Full | Any Windows/SQL estate with existing licences |
| **Dev/Test subscription** | Discounted rates, **no Windows/SQL licence charge** | Requires Visual Studio subscription | Non-production use only | n/a | **No SLA** | Every non-prod landing zone |

**Decision rule an architect can defend:**

```
baseline that never scales to zero, SKU is frozen        → 3-yr Reserved Instance
baseline that never scales to zero, SKU churns           → Savings Plan (commit to the P10 of hourly spend)
burst above baseline, interruption-tolerant              → Spot
burst above baseline, interruption-intolerant            → Pay-as-you-go
Windows / SQL anywhere in the above                      → stack Azure Hybrid Benefit
```

Commit to the **P10 of your hourly spend over the last 90 days**, never the mean. A commitment is a floor, and unused commitment is 100 % waste with zero salvage value.

### 3.4 Reading the rate card programmatically — the Azure Retail Prices API

This is free, unauthenticated, and the only honest way to build an internal cost model. It is also how you verify that what the Pricing Calculator showed you is the actual list price.

```bash
$ curl -sG "https://prices.azure.com/api/retail/prices" \
    --data-urlencode "currencyCode=EUR" \
    --data-urlencode "\$filter=serviceName eq 'Virtual Machines' \
       and armRegionName eq 'westeurope' \
       and armSkuName eq 'Standard_D4s_v5' \
       and priceType eq 'Consumption' \
       and contains(productName, 'Windows') eq false" \
  | jq -r '.Items[] | [.armSkuName,.meterName,.retailPrice,.unitOfMeasure,.armRegionName] | @tsv'
```

```
Standard_D4s_v5   D4s v5          0.2131000   1 Hour   westeurope
Standard_D4s_v5   D4s v5 Spot     0.0271000   1 Hour   westeurope
Standard_D4s_v5   D4s v5 Low Pri  0.0426000   1 Hour   westeurope
```

Reservation prices come from the same API with a different `priceType`:

```bash
$ curl -sG "https://prices.azure.com/api/retail/prices" \
    --data-urlencode "currencyCode=EUR" \
    --data-urlencode "\$filter=armSkuName eq 'Standard_D4s_v5' \
       and armRegionName eq 'westeurope' and priceType eq 'Reservation'" \
  | jq -r '.Items[] | [.armSkuName,.reservationTerm,.retailPrice,.unitOfMeasure] | @tsv'
```

```
Standard_D4s_v5   1 Year    1119.36000   1 Hour
Standard_D4s_v5   3 Years   2154.24000   1 Hour
```

> **Read that output carefully.** `unitOfMeasure` says `1 Hour` but the `retailPrice` for a reservation is the **whole-term upfront price**. This inconsistency has produced more wrong internal dashboards than any other single field in Azure. Compute the effective hourly rate yourself: `2154.24 / (3 × 8760) = €0.0820/h`, i.e. **61.5 % off** the €0.2131 PAYG rate.

---

## 4. Pricing Calculator vs TCO Calculator

Both are **pre-deployment estimation** tools. Neither reads a single byte of your actual telemetry. They answer different questions, and the exam tests exactly that distinction.

| Dimension | **Azure Pricing Calculator** | **Total Cost of Ownership (TCO) Calculator** |
|---|---|---|
| Question answered | "What will *this Azure design* cost per month?" | "What do I *save* by moving from on-premises to Azure?" |
| Direction | Forward-looking, Azure-only | Comparative, on-prem **vs** Azure |
| Inputs | Azure services, SKUs, regions, quantities, hours, term, support tier, currency | Servers (CPU/RAM/OS/virtualization), databases, storage volume & type, outbound bandwidth, plus **cost assumptions** |
| Models **non-Azure** costs | ❌ No | ✅ Yes — hardware, software licences, electricity, cooling, datacenter real estate, IT labour |
| Models discounts | ✅ Reservations, savings plans, Azure Hybrid Benefit, Dev/Test, EA/MCA-style discount %, support plans | ⚠️ Coarse, assumption-driven |
| Granularity | Per-SKU, per-meter | Per-workload category |
| Output | Monthly + annual estimate; **export to XLSX**; shareable/saveable estimate link | Multi-year (typically 3–5) TCO comparison report, downloadable |
| Uses your real usage data | ❌ No | ❌ No |
| Requires an Azure subscription | ❌ No (sign in only to save) | ❌ No |
| Typical consumer | Platform engineer sizing a landing zone | CFO / migration business case |
| Accuracy class | **SKU-accurate list price**, usage-assumption dependent | **Directional**, model dependent |

### 4.1 The three-tool separation you must be able to state in one line

```
Pricing Calculator  →  what a design WILL cost      (hypothetical, Azure only)
TCO Calculator      →  what migrating WOULD save    (hypothetical, on-prem vs Azure)
Cost Management     →  what you ARE spending        (actual, measured, historical + forecast)
```

> **Currency and taxes:** both calculators produce **pre-tax list estimates** in a selected currency. They do not include your negotiated EA/MCA discount unless you enter it manually, and they never include tax. Cost Management shows both `Cost` (billing currency) and `CostUSD`.

> **Status note (verify before teaching):** Microsoft retired the standalone TCO Calculator page and now steers migration business cases toward the **Azure Migrate business case** feature, which — unlike the TCO Calculator — *does* ingest real discovered on-premises inventory and utilization. The AZ-900 study guide still lists the TCO Calculator as an exam item, so know the comparison above for the exam and know the Azure Migrate business case for the job. Check the study-guide URL in §10 for the current wording before relying on this.

---

## 5. Microsoft Cost Management

Microsoft Cost Management (surfaced in the portal as **Cost Management + Billing**) is the measurement and control plane. Five capabilities matter.

### 5.1 Cost analysis — and the actual/amortized distinction

`Cost analysis` is a query engine over the usage store with views: accumulated cost, daily cost, cost by service, cost by resource, invoice details. The dimension you group by is what determines whether the answer is useful — grouping by `ResourceGroupName` is the default reflex; grouping by a `cost-center` **tag** is the one that answers finance's question.

The single most misread control is the metric selector:

| Metric | Reservation purchase appears as | Reservation-covered VM usage appears as | What unused commitment looks like | Use it to answer |
|---|---|---|---|---|
| **Actual cost** | A single lump sum on the purchase date | **€0.00** | Invisible (already paid) | "Reconcile against the invoice" |
| **Amortized cost** | Spread evenly across every day of the term | The daily amortized share, attributed to the consuming resource | An explicit `UnusedReservation` line | "What does each team really cost?" |

Both views sum to the same total **over the full reservation term**, never over a single month. A chargeback model built on Actual cost will bill one unlucky team the entire 3-year reservation in month one.

```bash
$ az extension add --name costmanagement --upgrade
$ SUB=$(az account show --query id -o tsv)

$ az costmanagement query \
    --type AmortizedCost \
    --scope "/subscriptions/$SUB" \
    --timeframe MonthToDate \
    --dataset-granularity None \
    --dataset-aggregation '{"totalCost":{"name":"Cost","function":"Sum"}}' \
    --dataset-grouping name="ServiceName" type="Dimension" \
    -o json | jq -r '.rows[] | @tsv' | sort -t$'\t' -k1 -rn | head -8
```

```
18422.71	Virtual Machines	EUR
 9310.05	Azure Kubernetes Service	EUR
 6188.40	Storage	EUR
 4402.19	Azure Database for PostgreSQL	EUR
 3971.66	Bandwidth	EUR
 2044.83	Azure Firewall	EUR
 1512.90	Log Analytics	EUR
  880.12	UnusedReservation	EUR
```

That last line — `UnusedReservation` — is pure waste, and it is **only visible in the amortized view**. €880 in a month is €10.5k/year of commitment you bought and never consumed.

Group by tag instead of service:

```bash
$ az costmanagement query \
    --type AmortizedCost \
    --scope "/subscriptions/$SUB" \
    --timeframe TheLastMonth \
    --dataset-granularity None \
    --dataset-aggregation '{"totalCost":{"name":"Cost","function":"Sum"}}' \
    --dataset-grouping name="cost-center" type="TagKey" \
    -o table
```

```
Cost           CostCenter     Currency
-------------  -------------  ----------
24880.44       CC-4471        EUR
11209.68       CC-2210        EUR
 6640.02       CC-9003        EUR
 3402.11                      EUR      <-- untagged: your allocation gap
```

The blank row is the metric that matters. **Untagged spend as a percentage of total** is the KPI for cost governance maturity; a healthy platform keeps it under 2 %.

### 5.2 Budgets — notification, not enforcement

A budget is a scoped monetary (or usage-quantity) threshold with up to **five notification rules**. Each rule has a `thresholdType`:

- `Actual` — fires when measured spend crosses the threshold. Always late by the data-latency window.
- `Forecasted` — fires when Azure's projection for the period crosses the threshold. This is the one that gives you lead time, and it is the one most teams never configure.

Budgets can filter on dimensions (`ResourceGroupName`, `ResourceType`, `MeterCategory`, …) and on tags.

**Budgets do not throttle, stop, deallocate, or block anything.** To get enforcement you wire the budget's `contactGroups` to an Action Group that triggers an Automation runbook, Logic App, or Function — §6.1 shows the full manifest.

### 5.3 Exports and the Cost Details API

For anything beyond ad-hoc portal queries you need the raw usage records in your own store.

| Mechanism | Shape | Cadence | Best for |
|---|---|---|---|
| **Scheduled export** to a storage account | CSV/Parquet, optionally partitioned & gzipped | Daily / weekly / monthly, or one-time | The FinOps data lake. This is the production answer. |
| **FOCUS dataset export** | FinOps Open Cost & Usage Specification v1.x — vendor-neutral column names | Same | Multi-cloud unification; one schema for Azure + AWS + GCP |
| **Cost Details API** (`generateCostDetailsReport`) | Async job → SAS-signed blob | On demand | Backfill, reconciliation |
| `az consumption usage list` | Paginated JSON | On demand | Small scopes, quick checks. **Do not** use for full-month EA pulls — it will page for hours |
| Cost Management **Power BI connector** | Semantic model | Scheduled refresh | Executive reporting |

FOCUS is worth calling out: it renames Azure-specific columns to a shared vocabulary (`BilledCost`, `EffectiveCost`, `ChargePeriodStart`, `ResourceId`, `ServiceCategory`, `x_SkuMeterName`…). If your organization runs more than one cloud, exporting FOCUS instead of the native Azure schema is the difference between one dashboard and three.

### 5.4 Anomaly detection and Advisor

- **Cost anomaly alerts** (`Microsoft.CostManagement/scheduledActions`, `kind: InsightAlert`) run an unsupervised model over daily subscription spend and email when a day deviates from the learned pattern. Subscription scope, no configuration of sensitivity — free, and worth enabling on every subscription on day one.
- **Azure Advisor → Cost** produces actionable recommendations: right-size or shut down underutilized VMs, delete unattached public IPs / idle disks, buy reservations or savings plans based on observed usage, delete idle load balancers and ExpressRoute circuits. Advisor's reservation recommendations are computed from your **actual last 7/30/60 days** — this is the only Microsoft-native tool in this objective that is telemetry-driven rather than assumption-driven.

### 5.5 Cost Management RBAC

| Role | Can read costs | Can create budgets/exports | Can see the ARM resources | Notes |
|---|---|---|---|---|
| **Cost Management Reader** | ✅ | ❌ | ❌ | Give this to finance. It leaks no resource metadata beyond names |
| **Cost Management Contributor** | ✅ | ✅ | ❌ | Give this to the FinOps platform identity |
| **Reader** | ✅ (inherits) | ❌ | ✅ | |
| **Contributor / Owner** | ✅ | ✅ | ✅ | |
| **Billing account roles** (EA admin, MCA Billing profile owner/contributor/reader/invoice manager) | ✅ above subscription | ✅ | ❌ | Separate plane; ARM RBAC does **not** grant these |

Never hard-code role GUIDs — resolve them:

```bash
$ az role definition list --name "Cost Management Reader" --query "[].name" -o tsv
72fafb9e-0641-4937-9268-a91bfd8191a3

$ az role definition list --name "Tag Contributor" --query "[].name" -o tsv
4a9ae827-6dc8-4573-8ac7-8239d42aa03f
```

> **Note on cross-cloud:** Cost Management's AWS connector has been retired. Multi-cloud unification is now done by exporting **FOCUS** from each provider into a shared lake, not by an in-portal connector.

---

## 6. Tags: the purpose, and the mechanics nobody reads

A tag is a `name: value` string pair attached to a subscription, resource group, or resource. Its **purpose** is metadata-driven operations: cost allocation and chargeback, ownership and on-call routing, environment classification, automation targeting (patch rings, shutdown schedules), security/compliance classification, and lifecycle (expiry dates for ephemeral infrastructure).

### 6.1 Hard limits and behaviours that cause outages of the *cost* kind

| Property | Value / behaviour | Consequence |
|---|---|---|
| Tags per resource / RG / subscription | **50** | A tag-per-microservice scheme hits the wall |
| Tag **name** length | 512 characters (**128** for storage accounts) | |
| Tag **value** length | 256 characters | JSON-in-a-tag patterns truncate silently |
| Characters forbidden in names | `< > % & \ ? /` | Policy `Modify` with a bad name fails at remediation, not at assignment |
| Case sensitivity | Names are **case-insensitive** for lookup, case-**preserving** on write. Values are **case-sensitive** | `Prod` and `prod` are two rows in cost analysis |
| Inheritance | **None.** Resources do **not** inherit RG or subscription tags | The #1 cause of the untagged bucket |
| Classic (ASM) resources | Do not support tags at all | |
| Resources outside a resource group | Cannot be tagged | |
| Appearance in cost data | Only resources that **emit usage records** carry tags into cost. Tags on a resource group do not appear on child resource usage records | Tagging the RG "for cost" does nothing by default |
| Retroactivity | Tagging a resource today does **not** re-tag yesterday's usage records | Backfill is impossible via the resource plane |

### 6.2 The one retroactive escape hatch: Cost Management tag inheritance

Cost Management has a per-scope setting (**Cost Management → Settings → Manage tag inheritance**, EA and MCA) that copies subscription- and resource-group-level tags onto the child resources' **usage records** during ingestion. Two properties make it strategically important:

1. It applies **retroactively to the beginning of the current billing month** when enabled.
2. It is configurable to let the **resource tag win** over the inherited tag, or the inherited tag win.

It does **not** modify the resources themselves — only the cost records. Combine it with Azure Policy: Policy fixes the resource plane going forward, tag inheritance fixes the cost plane immediately.

### 6.3 The three Azure Policy effects for tags, and when each is correct

| Effect | Built-in policy example | Behaviour | Existing resources | Use when |
|---|---|---|---|---|
| `Deny` | *Require a tag on resources* | Blocks creation/update without the tag | Marked non-compliant, untouched | Greenfield landing zone, day 0 |
| `Modify` | *Inherit a tag from the resource group* | Adds/replaces the tag; supports **remediation tasks** over existing resources | **Can be fixed** via remediation | Brownfield estate — this is the one you want |
| `Append` | *Inherit a tag from the resource group if missing* | Adds the tag at create/update only; **no remediation** | Untouched | Legacy; prefer `Modify` |
| `Audit` | *Require a tag and its value on resources* (audit variant) | Reports only | Reported | Measurement phase, before enforcement |

Resolve built-in definition IDs rather than trusting a copied GUID:

```bash
$ az policy definition list --query \
  "[?policyType=='BuiltIn' && contains(displayName,'tag')].{name:name, display:displayName, effect:policyRule.then.effect}" \
  -o table | head -12
```

```
Name                                  Display                                             Effect
------------------------------------  --------------------------------------------------  ------------------
871b6d14-10aa-478d-b590-94f262ecfa99  Require a tag on resources                          deny
1e30110a-5ceb-460c-a204-c1c3969c6d62  Require a tag and its value on resources            deny
96670d01-0a4d-4649-9c89-2d3abc0a5025  Require a tag on resource groups                    deny
cd3aa116-8754-49c9-a813-ad46512ece54  Inherit a tag from the resource group               modify
40df99da-1232-49b1-a39a-6da8d878f469  Inherit a tag from the subscription                 modify
4f9dc7db-30c1-420c-b61a-e1d640128d26  Add or replace a tag on resources                   modify
```

### 6.4 A tag taxonomy that survives an audit

```
cost-center      required   ^CC-[0-9]{4}$              → chargeback key, matches the finance ledger
owner            required   ^[a-z0-9._%-]+@corp\.tld$  → a group mailbox, never a person
env              required   prod | staging | dev | sandbox
service          required   ^[a-z][a-z0-9-]{2,31}$     → matches the service catalogue ID
data-class       required   public | internal | confidential | restricted
managed-by       required   terraform | bicep | portal | manual
expires-on       optional   ^\d{4}-\d{2}-\d{2}$        → sandbox reaper reads this
```

Rules that make it work: **fewer than 8 required tags** (people defeat long lists), **lowercase kebab-case keys** (values are case-sensitive; keys being consistent avoids duplicate columns), **enumerated values enforced by policy** (free text destroys grouping), and **`owner` is always a group**.

---

## 7. Complete infrastructure manifests

### 7.1 Bicep — the full cost-governance stack at subscription scope

`cost-governance.bicep`:

```bicep
// ---------------------------------------------------------------------------
// Cost governance baseline for one subscription:
//   action group -> budget (actual + forecast) -> anomaly alert
//   storage account -> daily FOCUS export
//   policy assignments -> deny untagged, inherit cost-center from RG
// Deploy:  az deployment sub create -l westeurope -f cost-governance.bicep -p @cost-governance.params.json
// ---------------------------------------------------------------------------
targetScope = 'subscription'

@description('Environment discriminator used in every resource name.')
@allowed(['prod', 'staging', 'dev'])
param env string = 'prod'

@description('Location for the regional resources created by this template.')
param location string = 'westeurope'

@description('Monthly budget ceiling in the billing currency of the subscription.')
@minValue(1)
param monthlyBudgetAmount int = 25000

@description('First day of the month the budget starts, UTC, format yyyy-MM-dd. Must be the 1st.')
param budgetStartDate string

@description('Budget end date, UTC, format yyyy-MM-dd. Max 10 years out.')
param budgetEndDate string

@description('Mailbox that receives every cost notification. Use a group, never a person.')
param finopsDistributionList string

@description('Cost centres accepted by the tag policy.')
param allowedCostCentres array = [
  'CC-4471'
  'CC-2210'
  'CC-9003'
]

var suffix          = '${env}-${location}'
var rgName          = 'rg-finops-${suffix}'
var storageName     = take(replace('stfinops${env}${uniqueString(subscription().id)}', '-', ''), 24)
var exportContainer = 'costexports'

// Built-in role and policy definition IDs. Resolve with:
//   az role definition list --name "Tag Contributor" --query [].name -o tsv
//   az policy definition list --query "[?displayName=='Inherit a tag from the resource group'].name" -o tsv
var tagContributorRoleId       = '4a9ae827-6dc8-4573-8ac7-8239d42aa03f'
var policyInheritTagFromRgId   = 'cd3aa116-8754-49c9-a813-ad46512ece54'
var policyRequireTagOnResource = '871b6d14-10aa-478d-b590-94f262ecfa99'

// ---------------------------------------------------------------------------
// 1. Container resource group for the FinOps plumbing
// ---------------------------------------------------------------------------
resource finopsRg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name:     rgName
  location: location
  tags: {
    'cost-center': 'CC-9003'
    owner:         finopsDistributionList
    env:           env
    service:       'finops-platform'
    'data-class':  'internal'
    'managed-by':  'bicep'
  }
}

// ---------------------------------------------------------------------------
// 2. Storage account that receives the cost exports
// ---------------------------------------------------------------------------
module exportStorage 'modules/export-storage.bicep' = {
  name:  'deploy-export-storage'
  scope: finopsRg
  params: {
    storageAccountName: storageName
    location:           location
    containerName:      exportContainer
    tagSet: {
      'cost-center': 'CC-9003'
      owner:         finopsDistributionList
      env:           env
      service:       'finops-platform'
      'data-class':  'confidential'
      'managed-by':  'bicep'
    }
  }
}

// ---------------------------------------------------------------------------
// 3. Action group. Budgets can only notify; enforcement lives behind this.
// ---------------------------------------------------------------------------
module costActionGroup 'modules/action-group.bicep' = {
  name:  'deploy-cost-action-group'
  scope: finopsRg
  params: {
    actionGroupName: 'ag-cost-${suffix}'
    shortName:       'costalert'
    emailAddress:    finopsDistributionList
  }
}

// ---------------------------------------------------------------------------
// 4. Budget. Five notification rules is the hard maximum.
//    thresholdType Forecasted is what gives you lead time; Actual is history.
// ---------------------------------------------------------------------------
resource subscriptionBudget 'Microsoft.Consumption/budgets@2023-05-01' = {
  name: 'bd-${suffix}-monthly'
  properties: {
    category:  'Cost'
    amount:    monthlyBudgetAmount
    timeGrain: 'Monthly'
    timePeriod: {
      startDate: '${budgetStartDate}T00:00:00Z'
      endDate:   '${budgetEndDate}T00:00:00Z'
    }
    notifications: {
      Forecast_GreaterThan_100_Percent: {
        enabled:       true
        operator:      'GreaterThan'
        threshold:     100
        thresholdType: 'Forecasted'
        contactEmails: [ finopsDistributionList ]
        contactRoles:  [ 'Owner' ]
        contactGroups: [ costActionGroup.outputs.actionGroupId ]
        locale:        'en-us'
      }
      Forecast_GreaterThan_120_Percent: {
        enabled:       true
        operator:      'GreaterThan'
        threshold:     120
        thresholdType: 'Forecasted'
        contactEmails: [ finopsDistributionList ]
        contactRoles:  [ 'Owner' ]
        contactGroups: [ costActionGroup.outputs.actionGroupId ]
        locale:        'en-us'
      }
      Actual_GreaterThan_50_Percent: {
        enabled:       true
        operator:      'GreaterThan'
        threshold:     50
        thresholdType: 'Actual'
        contactEmails: [ finopsDistributionList ]
        locale:        'en-us'
      }
      Actual_GreaterThan_80_Percent: {
        enabled:       true
        operator:      'GreaterThan'
        threshold:     80
        thresholdType: 'Actual'
        contactEmails: [ finopsDistributionList ]
        contactGroups: [ costActionGroup.outputs.actionGroupId ]
        locale:        'en-us'
      }
      Actual_GreaterThan_100_Percent: {
        enabled:       true
        operator:      'GreaterThan'
        threshold:     100
        thresholdType: 'Actual'
        contactEmails: [ finopsDistributionList ]
        contactRoles:  [ 'Owner' ]
        contactGroups: [ costActionGroup.outputs.actionGroupId ]
        locale:        'en-us'
      }
    }
  }
}

// ---------------------------------------------------------------------------
// 5. Daily FOCUS 1.0 export into the storage account.
//    FocusCost gives vendor-neutral column names; use it if you touch >1 cloud.
// ---------------------------------------------------------------------------
resource focusExport 'Microsoft.CostManagement/exports@2023-08-01' = {
  name: 'ex-${suffix}-focus-daily'
  properties: {
    format:                'Csv'
    partitionData:         true
    compressionMode:       'gzip'
    dataOverwriteBehavior: 'OverwritePreviousReport'
    schedule: {
      status:     'Active'
      recurrence: 'Daily'
      recurrencePeriod: {
        from: '${budgetStartDate}T02:00:00Z'
        to:   '${budgetEndDate}T02:00:00Z'
      }
    }
    deliveryInfo: {
      destination: {
        resourceId:     exportStorage.outputs.storageAccountId
        container:      exportContainer
        rootFolderPath: 'focus/${env}'
      }
    }
    definition: {
      type:      'FocusCost'
      timeframe: 'MonthToDate'
      dataSet: {
        granularity: 'Daily'
        configuration: {
          dataVersion: '1.0'
        }
      }
    }
  }
}

// ---------------------------------------------------------------------------
// 6. Cost anomaly alert. Unsupervised, free, subscription scope only.
// ---------------------------------------------------------------------------
resource anomalyAlert 'Microsoft.CostManagement/scheduledActions@2023-08-01' = {
  name: 'sa-${suffix}-anomaly'
  kind: 'InsightAlert'
  properties: {
    displayName: 'Daily cost anomaly - ${env}'
    status:      'Enabled'
    viewId:      '/providers/Microsoft.CostManagement/views/ms:DailyAnomalyByResourceGroup'
    notification: {
      to:      [ finopsDistributionList ]
      subject: '[${toUpper(env)}] Azure cost anomaly detected'
    }
    schedule: {
      frequency:  'Daily'
      startDate:  '${budgetStartDate}T06:00:00Z'
      endDate:    '${budgetEndDate}T06:00:00Z'
    }
  }
}

// ---------------------------------------------------------------------------
// 7. Deny resources created without a cost-center tag.
//    Deny does NOT fix what already exists - see the Modify assignment below.
// ---------------------------------------------------------------------------
resource denyUntagged 'Microsoft.Authorization/policyAssignments@2022-06-01' = {
  name: 'pa-require-cost-center'
  properties: {
    displayName:        'Require cost-center tag on all resources'
    description:        'Blocks creation of resources without a cost-center tag. Cost allocation depends on it.'
    policyDefinitionId: tenantResourceId('Microsoft.Authorization/policyDefinitions', policyRequireTagOnResource)
    enforcementMode:    'Default'
    parameters: {
      tagName: {
        value: 'cost-center'
      }
    }
    nonComplianceMessages: [
      {
        message: 'Every resource must carry a cost-center tag matching CC-nnnn. See the platform tagging standard.'
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// 8. Modify assignment: inherit cost-center from the resource group.
//    Modify needs a managed identity AND a role assignment, or remediation
//    fails with "The client ... does not have authorization to perform action".
// ---------------------------------------------------------------------------
resource inheritCostCenter 'Microsoft.Authorization/policyAssignments@2022-06-01' = {
  name:     'pa-inherit-cost-center'
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    displayName:        'Inherit cost-center tag from the resource group'
    policyDefinitionId: tenantResourceId('Microsoft.Authorization/policyDefinitions', policyInheritTagFromRgId)
    enforcementMode:    'Default'
    parameters: {
      tagName: {
        value: 'cost-center'
      }
    }
  }
}

resource inheritTagRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, 'pa-inherit-cost-center', tagContributorRoleId)
  properties: {
    roleDefinitionId: tenantResourceId('Microsoft.Authorization/roleDefinitions', tagContributorRoleId)
    principalId:      inheritCostCenter.identity.principalId
    principalType:    'ServicePrincipal'
  }
}

output budgetId          string = subscriptionBudget.id
output exportId          string = focusExport.id
output actionGroupId     string = costActionGroup.outputs.actionGroupId
output remediationTarget string = inheritCostCenter.id
output storageAccountId  string = exportStorage.outputs.storageAccountId
```

`modules/export-storage.bicep`:

```bicep
@description('Globally unique storage account name, 3-24 lowercase alphanumeric characters.')
@minLength(3)
@maxLength(24)
param storageAccountName string

param location string
param containerName string
param tagSet object

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name:     storageAccountName
  location: location
  tags:     tagSet
  sku: {
    // LRS is deliberate: cost exports are reproducible from the Cost Details API.
    // Paying for GRS on regenerable data is exactly the waste this stack exists to find.
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    accessTier:                   'Cool'
    minimumTlsVersion:            'TLS1_2'
    allowBlobPublicAccess:        false
    allowSharedKeyAccess:         true   // Cost Management exports require key-based write
    supportsHttpsTrafficOnly:     true
    publicNetworkAccess:          'Enabled'
    networkAcls: {
      bypass:        'AzureServices'   // the export service writes through the trusted-services path
      defaultAction: 'Deny'
    }
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storage
  name:   'default'
  properties: {
    deleteRetentionPolicy: {
      enabled: true
      days:    30
    }
  }
}

resource exportsContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name:   containerName
  properties: {
    publicAccess: 'None'
  }
}

resource lifecycle 'Microsoft.Storage/storageAccounts/managementPolicies@2023-05-01' = {
  parent: storage
  name:   'default'
  properties: {
    policy: {
      rules: [
        {
          name:    'archive-then-expire-cost-exports'
          enabled: true
          type:    'Lifecycle'
          definition: {
            filters: {
              blobTypes:   [ 'blockBlob' ]
              prefixMatch: [ '${containerName}/focus' ]
            }
            actions: {
              baseBlob: {
                tierToCool:    { daysAfterModificationGreaterThan: 30 }
                tierToArchive: { daysAfterModificationGreaterThan: 120 }
                delete:        { daysAfterModificationGreaterThan: 1095 }
              }
            }
          }
        }
      ]
    }
  }
}

output storageAccountId   string = storage.id
output storageAccountName string = storage.name
```

`modules/action-group.bicep`:

```bicep
@description('Action group resource name.')
param actionGroupName string

@description('1-12 character short name used as the SMS/email prefix.')
@maxLength(12)
param shortName string

param emailAddress string

resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name:     actionGroupName
  location: 'Global'   // action groups are always Global
  properties: {
    groupShortName: shortName
    enabled:        true
    emailReceivers: [
      {
        name:                 'finops-dl'
        emailAddress:         emailAddress
        useCommonAlertSchema: true
      }
    ]
    // Enforcement hook. A budget notification alone changes nothing;
    // this webhook is where a Logic App / Function deallocates the offender.
    azureFunctionReceivers: []
    webhookReceivers:       []
    logicAppReceivers:      []
  }
}

output actionGroupId string = actionGroup.id
```

`cost-governance.params.json`:

```json
{
  "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
  "contentVersion": "1.0.0.0",
  "parameters": {
    "env":                     { "value": "prod" },
    "location":                { "value": "westeurope" },
    "monthlyBudgetAmount":     { "value": 25000 },
    "budgetStartDate":         { "value": "2026-09-01" },
    "budgetEndDate":           { "value": "2029-09-01" },
    "finopsDistributionList":  { "value": "finops-platform@corp.tld" },
    "allowedCostCentres":      { "value": ["CC-4471", "CC-2210", "CC-9003"] }
  }
}
```

### 7.2 Custom Azure Policy — enforce the *shape* of the cost-center value

The built-in `Require a tag on resources` only checks presence. Free-text values destroy grouping in cost analysis, so enforce the enumeration.

`policy-cost-center-allowed-values.json`:

```json
{
  "properties": {
    "displayName": "Require a cost-center tag with an approved value",
    "policyType": "Custom",
    "mode": "Indexed",
    "description": "Denies creation or update of any indexed resource whose cost-center tag is absent or is not one of the approved cost centres. Free-text cost centres fragment the cost-allocation report and cannot be reconciled against the finance ledger.",
    "metadata": {
      "version": "1.2.0",
      "category": "Tags",
      "source": "platform-team"
    },
    "parameters": {
      "allowedCostCentres": {
        "type": "Array",
        "metadata": {
          "displayName": "Allowed cost centres",
          "description": "Exact list of cost-centre codes accepted by finance."
        }
      },
      "effect": {
        "type": "String",
        "defaultValue": "Deny",
        "allowedValues": ["Audit", "Deny", "Disabled"],
        "metadata": {
          "displayName": "Effect",
          "description": "Start at Audit, measure the non-compliance count, then flip to Deny."
        }
      },
      "exemptResourceTypes": {
        "type": "Array",
        "defaultValue": [
          "Microsoft.Resources/deploymentScripts",
          "Microsoft.Insights/actionGroups"
        ],
        "metadata": {
          "displayName": "Exempt resource types",
          "description": "Types that are created implicitly by other services and cannot be tagged at create time."
        }
      }
    },
    "policyRule": {
      "if": {
        "allOf": [
          {
            "field": "type",
            "notIn": "[parameters('exemptResourceTypes')]"
          },
          {
            "anyOf": [
              {
                "field": "tags['cost-center']",
                "exists": "false"
              },
              {
                "field": "tags['cost-center']",
                "notIn": "[parameters('allowedCostCentres')]"
              }
            ]
          }
        ]
      },
      "then": {
        "effect": "[parameters('effect')]"
      }
    }
  }
}
```

Note `"mode": "Indexed"` — it restricts evaluation to resource types that support tags and location, which is exactly what you want for a tag policy. `"mode": "All"` would also evaluate resource groups and subscriptions and generate noise you cannot remediate.

### 7.3 Terraform — the same stack

`main.tf`:

```hcl
terraform {
  required_version = ">= 1.7.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

provider "azurerm" {
  features {}
}

data "azurerm_subscription" "current" {}

locals {
  env      = "prod"
  location = "westeurope"

  # Applied to every resource this module creates. default_tags does not exist
  # in azurerm the way it does in the AWS provider, so merge it explicitly.
  common_tags = {
    "cost-center" = "CC-9003"
    "owner"       = "finops-platform@corp.tld"
    "env"         = local.env
    "service"     = "finops-platform"
    "data-class"  = "internal"
    "managed-by"  = "terraform"
  }
}

resource "azurerm_resource_group" "finops" {
  name     = "rg-finops-${local.env}-${local.location}"
  location = local.location
  tags     = local.common_tags
}

resource "azurerm_monitor_action_group" "cost" {
  name                = "ag-cost-${local.env}-${local.location}"
  resource_group_name = azurerm_resource_group.finops.name
  short_name          = "costalert"
  tags                = local.common_tags

  email_receiver {
    name                    = "finops-dl"
    email_address           = "finops-platform@corp.tld"
    use_common_alert_schema = true
  }
}

resource "azurerm_storage_account" "exports" {
  name                            = "stfinops${local.env}${substr(sha1(data.azurerm_subscription.current.id), 0, 8)}"
  resource_group_name             = azurerm_resource_group.finops.name
  location                        = azurerm_resource_group.finops.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  account_kind                    = "StorageV2"
  access_tier                     = "Cool"
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
  https_traffic_only_enabled      = true
  tags                            = merge(local.common_tags, { "data-class" = "confidential" })

  network_rules {
    default_action = "Deny"
    bypass         = ["AzureServices"]
  }
}

resource "azurerm_storage_container" "exports" {
  name                  = "costexports"
  storage_account_id    = azurerm_storage_account.exports.id
  container_access_type = "private"
}

# ---------------------------------------------------------------------------
# Budget. Notifications only - nothing here stops a single VM from running.
# ---------------------------------------------------------------------------
resource "azurerm_consumption_budget_subscription" "monthly" {
  name            = "bd-${local.env}-monthly"
  subscription_id = data.azurerm_subscription.current.id
  amount          = 25000
  time_grain      = "Monthly"

  time_period {
    # Must be the first day of a month, UTC, and no more than three months in the past.
    start_date = "2026-09-01T00:00:00Z"
    end_date   = "2029-09-01T00:00:00Z"
  }

  # Scope the budget to the workload resource groups so the platform's own
  # FinOps overhead does not consume the product team's allowance.
  filter {
    dimension {
      name = "ResourceGroupName"
      values = [
        "rg-platform-prod-weu",
        "rg-data-prod-weu",
        "rg-aks-prod-weu",
      ]
    }
  }

  notification {
    enabled        = true
    threshold      = 100
    threshold_type = "Forecasted"
    operator       = "GreaterThan"
    contact_emails = ["finops-platform@corp.tld"]
    contact_groups = [azurerm_monitor_action_group.cost.id]
    contact_roles  = ["Owner"]
  }

  notification {
    enabled        = true
    threshold      = 80
    threshold_type = "Actual"
    operator       = "GreaterThan"
    contact_emails = ["finops-platform@corp.tld"]
    contact_groups = [azurerm_monitor_action_group.cost.id]
  }

  notification {
    enabled        = true
    threshold      = 100
    threshold_type = "Actual"
    operator       = "GreaterThan"
    contact_emails = ["finops-platform@corp.tld"]
    contact_groups = [azurerm_monitor_action_group.cost.id]
    contact_roles  = ["Owner"]
  }
}

# ---------------------------------------------------------------------------
# Daily cost export
# ---------------------------------------------------------------------------
resource "azurerm_subscription_cost_management_export" "daily" {
  name                         = "ex-${local.env}-daily"
  subscription_id              = data.azurerm_subscription.current.id
  recurrence_type              = "Daily"
  recurrence_period_start_date = "2026-09-01T02:00:00Z"
  recurrence_period_end_date   = "2029-09-01T02:00:00Z"
  active                       = true

  export_data_storage_location {
    container_id     = azurerm_storage_container.exports.resource_manager_id
    root_folder_path = "azure/${local.env}"
  }

  export_data_options {
    type       = "Usage"
    time_frame = "MonthToDate"
  }
}

# ---------------------------------------------------------------------------
# Tag policy: audit first, deny second. Never ship Deny on day one.
# ---------------------------------------------------------------------------
resource "azurerm_policy_definition" "cost_center_allowed" {
  name         = "require-cost-center-allowed-values"
  policy_type  = "Custom"
  mode         = "Indexed"
  display_name = "Require a cost-center tag with an approved value"

  metadata = jsonencode({
    version  = "1.2.0"
    category = "Tags"
  })

  parameters = jsonencode({
    allowedCostCentres = {
      type     = "Array"
      metadata = { displayName = "Allowed cost centres" }
    }
    effect = {
      type          = "String"
      defaultValue  = "Audit"
      allowedValues = ["Audit", "Deny", "Disabled"]
      metadata      = { displayName = "Effect" }
    }
  })

  policy_rule = jsonencode({
    if = {
      anyOf = [
        { field = "tags['cost-center']", exists = "false" },
        { field = "tags['cost-center']", notIn = "[parameters('allowedCostCentres')]" }
      ]
    }
    then = {
      effect = "[parameters('effect')]"
    }
  })
}

resource "azurerm_subscription_policy_assignment" "cost_center_allowed" {
  name                 = "pa-cost-center-allowed"
  subscription_id      = data.azurerm_subscription.current.id
  policy_definition_id = azurerm_policy_definition.cost_center_allowed.id
  display_name         = "Require an approved cost-center tag"
  enforce              = true

  parameters = jsonencode({
    allowedCostCentres = { value = ["CC-4471", "CC-2210", "CC-9003"] }
    effect             = { value = "Audit" }
  })

  non_compliance_message {
    content = "Every resource must carry cost-center = one of CC-4471, CC-2210, CC-9003."
  }
}

# ---------------------------------------------------------------------------
# Modify assignment needs an identity, a location, and a role assignment.
# Omit any of the three and remediation fails with an authorization error.
# ---------------------------------------------------------------------------
resource "azurerm_subscription_policy_assignment" "inherit_cost_center" {
  name                 = "pa-inherit-cost-center"
  subscription_id      = data.azurerm_subscription.current.id
  policy_definition_id = "/providers/Microsoft.Authorization/policyDefinitions/cd3aa116-8754-49c9-a813-ad46512ece54"
  display_name         = "Inherit cost-center from the resource group"
  location             = local.location

  identity {
    type = "SystemAssigned"
  }

  parameters = jsonencode({
    tagName = { value = "cost-center" }
  })
}

resource "azurerm_role_assignment" "inherit_cost_center_tagger" {
  scope                = data.azurerm_subscription.current.id
  role_definition_name = "Tag Contributor"
  principal_id         = azurerm_subscription_policy_assignment.inherit_cost_center.identity[0].principal_id
}

output "budget_id"        { value = azurerm_consumption_budget_subscription.monthly.id }
output "export_id"        { value = azurerm_subscription_cost_management_export.daily.id }
output "policy_to_remediate" { value = azurerm_subscription_policy_assignment.inherit_cost_center.id }
```

### 7.4 Kubernetes — allocating AKS cost to namespaces

An AKS cluster arrives in Cost Analysis as a handful of enormous line items (`Virtual Machines`, `Managed Disks`, `Load Balancer`, `Bandwidth`) with **no visibility into which namespace caused them**. Two ways to fix it.

**Option A — the AKS cost analysis add-on** (Microsoft-managed, OpenCost-based, requires Standard or Premium cluster tier):

```bash
$ az aks update \
    --resource-group rg-aks-prod-weu \
    --name aks-prod-weu \
    --tier standard \
    --enable-cost-analysis
```

```
 \ Running ..
{
  "metricsProfile": {
    "costAnalysis": {
      "enabled": true
    }
  },
  "name": "aks-prod-weu",
  "provisioningState": "Succeeded",
  "sku": {
    "name": "Base",
    "tier": "Standard"
  }
}
```

```bash
$ az aks show -g rg-aks-prod-weu -n aks-prod-weu \
    --query "{tier:sku.tier, costAnalysis:metricsProfile.costAnalysis.enabled}" -o table
```

```
Tier      CostAnalysis
--------  --------------
Standard  True
```

After this, Cost Analysis gains `Kubernetes Namespace`, `Kubernetes Cluster`, `Kubernetes Controller` and `Kubernetes Label` dimensions for that cluster. Data starts flowing forward only — expect up to 24 h before the first namespace-level rows appear.

**Option B — self-hosted OpenCost** (portable across clouds, and the thing the add-on is built on):

`opencost.yaml`:

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: opencost
  labels:
    cost-center: CC-9003
    env: prod
    service: finops-platform
    # AKS cost analysis reads namespace labels; keep them identical to the
    # Azure tag taxonomy so a single grouping key works on both sides.
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: opencost
  namespace: opencost
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: opencost
rules:
  - apiGroups: [""]
    resources:
      - configmaps
      - nodes
      - pods
      - services
      - resourcequotas
      - replicationcontrollers
      - limitranges
      - persistentvolumeclaims
      - persistentvolumes
      - namespaces
      - endpoints
      - events
    verbs: ["get", "list", "watch"]
  - apiGroups: ["apps"]
    resources: ["statefulsets", "deployments", "daemonsets", "replicasets"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["batch"]
    resources: ["cronjobs", "jobs"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["autoscaling"]
    resources: ["horizontalpodautoscalers"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["policy"]
    resources: ["poddisruptionbudgets"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["storage.k8s.io"]
    resources: ["storageclasses"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: opencost
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: opencost
subjects:
  - kind: ServiceAccount
    name: opencost
    namespace: opencost
---
apiVersion: v1
kind: Secret
metadata:
  name: azure-service-principal
  namespace: opencost
type: Opaque
stringData:
  # Read-only principal used to pull the Azure rate card. Grant it
  # Cost Management Reader at the subscription scope and nothing else.
  service-key.json: |
    {
      "subscriptionId": "REPLACE_WITH_SUBSCRIPTION_ID",
      "serviceKey": {
        "appId": "REPLACE_WITH_APP_ID",
        "displayName": "sp-opencost-ratecard",
        "password": "REPLACE_VIA_EXTERNAL_SECRETS",
        "tenant": "REPLACE_WITH_TENANT_ID"
      }
    }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: opencost
  namespace: opencost
  labels:
    app.kubernetes.io/name: opencost
    app.kubernetes.io/component: cost-model
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: opencost
  template:
    metadata:
      labels:
        app.kubernetes.io/name: opencost
        app.kubernetes.io/component: cost-model
    spec:
      serviceAccountName: opencost
      securityContext:
        runAsNonRoot: true
        runAsUser: 1001
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: opencost
          image: ghcr.io/opencost/opencost:1.114.0
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 9003
            - name: metrics
              containerPort: 9090
          env:
            - name: PROMETHEUS_SERVER_ENDPOINT
              value: "http://prometheus-server.monitoring.svc.cluster.local:80"
            - name: CLOUD_PROVIDER_API_KEY
              value: "azure"
            - name: CLUSTER_ID
              value: "aks-prod-weu"
            - name: AZURE_OFFER_DURABLE_ID
              value: "MS-AZR-0003p"
            - name: AZURE_BILLING_ACCOUNT
              valueFrom:
                secretKeyRef:
                  name: azure-service-principal
                  key: service-key.json
                  optional: true
            - name: LOG_LEVEL
              value: "info"
          volumeMounts:
            - name: azure-key
              mountPath: /var/secrets
              readOnly: true
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              cpu: 999m
              memory: 1Gi
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          livenessProbe:
            httpGet:
              path: /healthz
              port: 9003
            initialDelaySeconds: 30
            periodSeconds: 20
          readinessProbe:
            httpGet:
              path: /healthz
              port: 9003
            initialDelaySeconds: 10
            periodSeconds: 10
      volumes:
        - name: azure-key
          secret:
            secretName: azure-service-principal
---
apiVersion: v1
kind: Service
metadata:
  name: opencost
  namespace: opencost
  labels:
    app.kubernetes.io/name: opencost
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: opencost
  ports:
    - name: http
      port: 9003
      targetPort: 9003
    - name: metrics
      port: 9090
      targetPort: 9090
---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: opencost
  namespace: opencost
  labels:
    release: kube-prometheus-stack
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: opencost
  endpoints:
    - port: metrics
      interval: 60s
      scrapeTimeout: 30s
      honorLabels: true
```

Query the allocation:

```bash
$ kubectl -n opencost port-forward svc/opencost 9003:9003 >/dev/null 2>&1 &
$ curl -s "http://localhost:9003/allocation/compute?window=7d&aggregate=namespace&accumulate=true" \
  | jq -r '.data[0] | to_entries[] | [.key, (.value.totalCost|tostring)] | @tsv' \
  | sort -k2 -rn | head
```

```
checkout-api	318.4471
search-index	204.9930
kube-system	 88.1204
ingress-nginx	 61.7710
monitoring	 55.3392
opencost	  1.9084
```

---

## 8. CLI reference — commands and real output

### 8.1 Bootstrap and scope

```bash
$ az login --tenant corp.onmicrosoft.com --only-show-errors >/dev/null
$ az account set --subscription "platform-prod-weu"
$ SUB=$(az account show --query id -o tsv)
$ echo "$SUB"
7f2b9a4c-1de8-4d6b-b0a1-3c8e5f9d2a10

$ az account show -o table
```

```
Name                 CloudName    SubscriptionId                        TenantId                              State    IsDefault
-------------------  -----------  ------------------------------------  ------------------------------------  -------  -----------
platform-prod-weu    AzureCloud   7f2b9a4c-1de8-4d6b-b0a1-3c8e5f9d2a10  3a1b7e05-9c44-4f2e-8a7d-6b1c0e4f8d33  Enabled  True
```

### 8.2 Deploy the governance stack

```bash
$ az deployment sub create \
    --name cost-governance-$(git rev-parse --short HEAD) \
    --location westeurope \
    --template-file cost-governance.bicep \
    --parameters @cost-governance.params.json \
    --query "properties.{state:provisioningState, outputs:outputs}" -o json
```

```json
{
  "state": "Succeeded",
  "outputs": {
    "actionGroupId": {
      "type": "String",
      "value": "/subscriptions/7f2b9a4c-.../resourceGroups/rg-finops-prod-westeurope/providers/Microsoft.Insights/actionGroups/ag-cost-prod-westeurope"
    },
    "budgetId": {
      "type": "String",
      "value": "/subscriptions/7f2b9a4c-.../providers/Microsoft.Consumption/budgets/bd-prod-westeurope-monthly"
    },
    "exportId": {
      "type": "String",
      "value": "/subscriptions/7f2b9a4c-.../providers/Microsoft.CostManagement/exports/ex-prod-westeurope-focus-daily"
    },
    "remediationTarget": {
      "type": "String",
      "value": "/subscriptions/7f2b9a4c-.../providers/Microsoft.Authorization/policyAssignments/pa-inherit-cost-center"
    }
  }
}
```

Always run `what-if` first on a subscription-scope deployment:

```bash
$ az deployment sub what-if \
    --location westeurope \
    --template-file cost-governance.bicep \
    --parameters @cost-governance.params.json \
    --result-format FullResourcePayloads | head -20
```

```
Note: The result may contain false positive predictions (noise).

Resource and property changes are indicated with these symbols:
  + Create
  ~ Modify
  = NoChange

The deployment will update the following scope:

Scope: /subscriptions/7f2b9a4c-1de8-4d6b-b0a1-3c8e5f9d2a10

  = Microsoft.Resources/resourceGroups/rg-finops-prod-westeurope

  ~ Microsoft.Consumption/budgets/bd-prod-westeurope-monthly
    ~ properties.amount: 22000 => 25000

  + Microsoft.CostManagement/scheduledActions/sa-prod-westeurope-anomaly
```

### 8.3 Budgets

```bash
$ az consumption budget list --query "[].{name:name, amount:amount, spent:currentSpend.amount, currency:currentSpend.unit, grain:timeGrain}" -o table
```

```
Name                        Amount    Spent      Currency    Grain
--------------------------  --------  ---------  ----------  -------
bd-prod-westeurope-monthly  25000     18442.71   EUR         Monthly
bd-data-platform-monthly    8000       6905.33   EUR         Monthly
```

The `az consumption budget create` command cannot attach action groups. When you need one outside IaC, PUT the resource directly:

```bash
$ cat > /tmp/budget.json <<'JSON'
{
  "properties": {
    "category": "Cost",
    "amount": 25000,
    "timeGrain": "Monthly",
    "timePeriod": {
      "startDate": "2026-09-01T00:00:00Z",
      "endDate":   "2029-09-01T00:00:00Z"
    },
    "filter": {
      "and": [
        { "dimensions": { "name": "ResourceGroupName", "operator": "In",
                          "values": ["rg-aks-prod-weu", "rg-data-prod-weu"] } },
        { "tags":       { "name": "env", "operator": "In", "values": ["prod"] } }
      ]
    },
    "notifications": {
      "Forecast_GreaterThan_100_Percent": {
        "enabled": true, "operator": "GreaterThan", "threshold": 100,
        "thresholdType": "Forecasted",
        "contactEmails": ["finops-platform@corp.tld"],
        "contactGroups": ["/subscriptions/7f2b9a4c-1de8-4d6b-b0a1-3c8e5f9d2a10/resourceGroups/rg-finops-prod-westeurope/providers/Microsoft.Insights/actionGroups/ag-cost-prod-westeurope"],
        "locale": "en-us"
      }
    }
  }
}
JSON

$ az rest --method put \
    --url "https://management.azure.com/subscriptions/$SUB/providers/Microsoft.Consumption/budgets/bd-prod-westeurope-monthly?api-version=2023-05-01" \
    --body @/tmp/budget.json \
    --query "{name:name, amount:properties.amount, spent:properties.currentSpend.amount}" -o json
```

```json
{
  "amount": 25000.0,
  "name": "bd-prod-westeurope-monthly",
  "spent": 18442.71
}
```

### 8.4 Querying spend

Daily trend for the current month:

```bash
$ az costmanagement query \
    --type ActualCost \
    --scope "/subscriptions/$SUB" \
    --timeframe MonthToDate \
    --dataset-granularity Daily \
    --dataset-aggregation '{"totalCost":{"name":"Cost","function":"Sum"}}' \
    -o json | jq -r '.rows[] | "\(.[1])  \(.[0]|tostring|.[0:8])  \(.[2])"'
```

```
20260901  4321.09   EUR
20260902  4488.77   EUR
20260903  4402.13   EUR
20260904  5230.72   EUR      <-- +18.8 % day over day
```

Top ten most expensive resources last month:

```bash
$ az costmanagement query \
    --type AmortizedCost \
    --scope "/subscriptions/$SUB" \
    --timeframe TheLastMonth \
    --dataset-granularity None \
    --dataset-aggregation '{"totalCost":{"name":"Cost","function":"Sum"}}' \
    --dataset-grouping name="ResourceId" type="Dimension" \
    -o json | jq -r '.rows | sort_by(-.[0])[:10][] | "\(.[0]|floor)\t\(.[1]|split("/")|last)"'
```

```
6114	aks-prod-weu-agentpool-gpu
3902	pgflex-orders-prod
2880	afw-hub-weu
1744	law-platform-prod
1502	aks-prod-weu-agentpool-sys
 988	st-media-prod-weu
 771	lbi-ingress-prod
 640	vgw-hub-expressroute
 512	kv-platform-prod
 480	acr-platform-prod
```

Raw usage records for one day:

```bash
$ az consumption usage list \
    --start-date 2026-09-04 --end-date 2026-09-04 \
    --query "[?pretaxCost > \`50\`].{meter:meterDetails.meterName, cat:meterDetails.meterCategory, qty:usageQuantity, cost:pretaxCost, res:instanceName}" \
    -o table | head
```

```
Meter                Cat                          Qty      Cost     Res
-------------------  ---------------------------  -------  -------  --------------------------
NC24ads A100 v4      Virtual Machines             192.0    719.04   aks-prod-weu-gpu-vmss_3
Data Transfer Out    Bandwidth                    2210.4   184.33   afw-hub-weu
P30 Disks            Storage                      24.0     102.72   pgflex-orders-prod-data
Data Ingestion       Azure Monitor                418.9     91.87   law-platform-prod
Standard Data Proc   Azure Firewall               1180.2    88.51   afw-hub-weu
```

### 8.5 Tag operations

```bash
$ RID=$(az aks show -g rg-aks-prod-weu -n aks-prod-weu --query id -o tsv)

$ az tag update --resource-id "$RID" --operation Merge \
    --tags cost-center=CC-4471 owner=sre-platform@corp.tld env=prod \
           service=container-platform data-class=internal managed-by=terraform \
    --query "properties.tags" -o json
```

```json
{
  "cost-center": "CC-4471",
  "data-class": "internal",
  "env": "prod",
  "managed-by": "terraform",
  "owner": "sre-platform@corp.tld",
  "service": "container-platform"
}
```

`Merge` adds/updates and leaves others alone. `Replace` wipes everything not listed. `Delete` removes the listed pairs. Using `Replace` in a bulk script is how estates lose their entire tag set in one command.

Find the allocation gap with Azure Resource Graph:

```bash
$ az extension add --name resource-graph --upgrade
$ az graph query -q "
Resources
| extend cc = tostring(tags['cost-center'])
| summarize total = count(), untagged = countif(isempty(cc)) by type
| extend pct = round(100.0 * untagged / total, 1)
| where untagged > 0
| order by untagged desc
| project type, total, untagged, pct
" --first 10 -o table
```

```
Type                                          Total    Untagged    Pct
--------------------------------------------  -------  ----------  -----
microsoft.compute/disks                       412      389         94.4
microsoft.network/networkinterfaces           188       88         46.8
microsoft.network/publicipaddresses            64       41         64.1
microsoft.compute/snapshots                    97       97        100.0
microsoft.insights/components                  22        9         40.9
```

`microsoft.compute/disks` at 94 % untagged is the classic signature: managed disks are created *by* the VM resource provider and inherit nothing.

> **Gotcha:** Azure Resource Graph is **case-sensitive on tag keys** even though ARM's tag API is case-insensitive on lookup. `tags['cost-center']` and `tags['Cost-Center']` are different properties in ARG. Normalize in the query:
> ```kusto
> | extend cc = tostring(bag_pack_columns(tags)['cost-center'])
> ```
> or the pragmatic version: `| extend cc = coalesce(tostring(tags['cost-center']), tostring(tags['Cost-Center']), tostring(tags['costCenter']))`. Then fix the source and enforce lowercase by policy.

### 8.6 Policy compliance and remediation

```bash
$ az policy state summarize --query \
  "value[0].policyAssignments[].{assignment:policyAssignmentId, nonCompliant:results.nonCompliantResources}" \
  -o table 2>/dev/null | sed 's#/subscriptions/[^/]*/providers/Microsoft.Authorization/policyAssignments/##'
```

```
Assignment                  NonCompliant
--------------------------  --------------
pa-cost-center-allowed      1046
pa-inherit-cost-center       389
```

Remediate the `Modify` assignment over the existing estate:

```bash
$ az policy remediation create \
    --name rem-inherit-cost-center-$(date -u +%Y%m%dT%H%M%SZ) \
    --policy-assignment pa-inherit-cost-center \
    --resource-discovery-mode ExistingNonCompliant \
    --query "{name:name, state:provisioningState, mode:resourceDiscoveryMode}" -o table
```

```
Name                                        State       Mode
------------------------------------------  ----------  ----------------------
rem-inherit-cost-center-20260905T081200Z    Accepted    ExistingNonCompliant
```

```bash
$ az policy remediation show \
    --name rem-inherit-cost-center-20260905T081200Z \
    --query "{state:provisioningState, total:deploymentSummary.totalDeployments, ok:deploymentSummary.successfulDeployments, failed:deploymentSummary.failedDeployments}" -o table
```

```
State      Total    Ok    Failed
---------  -------  ----  --------
Succeeded  389      386   3
```

```bash
$ az policy remediation deployment list \
    --name rem-inherit-cost-center-20260905T081200Z \
    --query "[?status!='Succeeded'].{res:remediatedResourceId, status:status, err:error.message}" -o json
```

```json
[
  {
    "err": "The resource type 'Microsoft.ClassicCompute/domainNames' does not support tags.",
    "res": "/subscriptions/7f2b.../providers/Microsoft.ClassicCompute/domainNames/legacy-app-01",
    "status": "Failed"
  }
]
```

### 8.7 Exports and Advisor

```bash
$ az costmanagement export list --scope "/subscriptions/$SUB" \
    --query "[].{name:name, type:definition.type, recurrence:schedule.recurrence, status:schedule.status, lastRun:runHistory.value[0].status}" -o table
```

```
Name                          Type        Recurrence    Status    LastRun
----------------------------  ----------  ------------  --------  ---------
ex-prod-westeurope-focus-dai  FocusCost   Daily         Active    Completed
```

```bash
$ az costmanagement export run \
    --scope "/subscriptions/$SUB" \
    --name ex-prod-westeurope-focus-daily
$ az storage blob list \
    --account-name stfinopsprod3f9a2c41 --container-name costexports \
    --prefix "focus/prod/" --auth-mode login \
    --query "[].{blob:name, mb:properties.contentLength, modified:properties.lastModified}" -o table | tail -3
```

```
Blob                                                              Mb        Modified
----------------------------------------------------------------  --------  -------------------------
focus/prod/20260901-20260930/part_0_0001.csv.gz                   18874368  2026-09-05T02:14:33+00:00
focus/prod/20260901-20260930/part_0_0002.csv.gz                   19011584  2026-09-05T02:14:41+00:00
focus/prod/20260901-20260930/manifest.json                            2841  2026-09-05T02:14:45+00:00
```

```bash
$ az advisor recommendation list --category Cost \
    --query "[].{impact:impact, problem:shortDescription.problem, res:impactedValue, savings:extendedProperties.annualSavingsAmount}" \
    -o table | head
```

```
Impact    Problem                                         Res                       Savings
--------  ----------------------------------------------  ------------------------  ---------
High      Right-size or shutdown underutilized VMs        vm-legacy-etl-01          3204.00
High      Buy a savings plan for compute and save         subscription              8811.40
Medium    Delete unattached public IP addresses           pip-orphan-weu-07          43.80
Medium    Delete or reconfigure idle load balancers       lb-legacy-internal          217.20
Low       Use lifecycle management on storage accounts    st-media-prod-weu          188.64
```

### 8.8 A daily FinOps report as CI

`.github/workflows/finops-daily.yml`:

```yaml
name: finops-daily-report

on:
  schedule:
    # 07:00 UTC - after the overnight Cost Management refresh has landed.
    # Never schedule earlier: the previous day's data is not complete yet.
    - cron: "0 7 * * *"
  workflow_dispatch:

permissions:
  id-token: write      # OIDC federation to Azure, no stored secrets
  contents: read
  issues: write

env:
  AZURE_SUBSCRIPTION_ID: ${{ vars.AZURE_SUBSCRIPTION_ID }}
  UNTAGGED_THRESHOLD_PCT: "2.0"

jobs:
  report:
    runs-on: ubuntu-latest
    timeout-minutes: 15
    steps:
      - uses: actions/checkout@v4

      - name: Azure login (OIDC)
        uses: azure/login@v2
        with:
          client-id:       ${{ vars.AZURE_CLIENT_ID }}
          tenant-id:       ${{ vars.AZURE_TENANT_ID }}
          subscription-id: ${{ vars.AZURE_SUBSCRIPTION_ID }}

      - name: Install Azure CLI extensions
        run: |
          az extension add --name costmanagement --upgrade --only-show-errors
          az extension add --name resource-graph --upgrade --only-show-errors

      - name: Month-to-date spend by cost centre
        id: spend
        run: |
          set -euo pipefail
          az costmanagement query \
            --type AmortizedCost \
            --scope "/subscriptions/${AZURE_SUBSCRIPTION_ID}" \
            --timeframe MonthToDate \
            --dataset-granularity None \
            --dataset-aggregation '{"totalCost":{"name":"Cost","function":"Sum"}}' \
            --dataset-grouping name="cost-center" type="TagKey" \
            -o json > mtd.json
          jq -r '.rows[] | "| \(.[1] // "**UNTAGGED**") | \(.[0] | floor) \(.[2]) |"' mtd.json > table.md
          total=$(jq '[.rows[][0]] | add' mtd.json)
          untag=$(jq '[.rows[] | select((.[1] // "") == "")][0][0] // 0' mtd.json)
          pct=$(python3 -c "print(f'{100*${untag}/${total}:.2f}')")
          echo "pct=${pct}" >> "$GITHUB_OUTPUT"
          echo "total=${total}"  >> "$GITHUB_OUTPUT"

      - name: Fail if the untagged share exceeds the allocation SLO
        run: |
          pct="${{ steps.spend.outputs.pct }}"
          echo "Untagged share: ${pct}% (SLO: <= ${UNTAGGED_THRESHOLD_PCT}%)"
          awk -v a="$pct" -v b="$UNTAGGED_THRESHOLD_PCT" \
            'BEGIN { if (a+0 > b+0) { print "ALLOCATION SLO BREACHED"; exit 1 } }'

      - name: Orphaned resources sweep
        if: always()
        run: |
          az graph query -q "
            Resources
            | where type =~ 'microsoft.compute/disks' and properties.diskState == 'Unattached'
               or type =~ 'microsoft.network/publicipaddresses' and isnull(properties.ipConfiguration)
            | project name, type, resourceGroup, location, tags
            | order by type asc
          " --first 200 -o table | tee orphans.txt

      - uses: actions/upload-artifact@v4
        if: always()
        with:
          name: finops-daily
          path: |
            mtd.json
            table.md
            orphans.txt
          retention-days: 90
```

---

## 9. Verification and failure diagnosis

### 9.1 The verification ladder

Run these in order. Each rung assumes the one above it passed.

```bash
# 1. Can I read cost at all at this scope?
$ az costmanagement query --type ActualCost --scope "/subscriptions/$SUB" \
    --timeframe MonthToDate --dataset-granularity None \
    --dataset-aggregation '{"totalCost":{"name":"Cost","function":"Sum"}}' \
    --query "rows[0]" -o tsv
18442.71	EUR

# 2. Does the budget exist and is it tracking?
$ az consumption budget show --budget-name bd-prod-westeurope-monthly \
    --query "{amount:amount, spent:currentSpend.amount, notifications:length(keys(notifications))}" -o json
{ "amount": 25000.0, "notifications": 5, "spent": 18442.71 }

# 3. Are the notifications actually wired to an action group?
$ az consumption budget show --budget-name bd-prod-westeurope-monthly \
    --query "notifications.*.contactGroups[]" -o tsv | sort -u
/subscriptions/7f2b.../providers/Microsoft.Insights/actionGroups/ag-cost-prod-westeurope

# 4. Does the action group deliver? (sends a real test notification)
$ az monitor action-group test-notifications create \
    --action-group-name ag-cost-prod-westeurope \
    --resource-group rg-finops-prod-westeurope \
    --alert-type budget \
    --email name=finops-dl email-address=finops-platform@corp.tld use-common-alert-schema=true \
    --query "{state:actionDetails[0].status, detail:actionDetails[0].detail}" -o table
State      Detail
---------  --------
Completed

# 5. Is the export producing bytes today?
$ az costmanagement export show --scope "/subscriptions/$SUB" \
    --name ex-prod-westeurope-focus-daily \
    --query "{status:schedule.status, lastRunStatus:runHistory.value[0].status, lastRunEnd:runHistory.value[0].processingEndTime}" -o json
{ "lastRunEnd": "2026-09-05T02:14:45Z", "lastRunStatus": "Completed", "status": "Active" }

# 6. Is the allocation gap inside SLO?
$ az costmanagement query --type AmortizedCost --scope "/subscriptions/$SUB" \
    --timeframe MonthToDate --dataset-granularity None \
    --dataset-aggregation '{"totalCost":{"name":"Cost","function":"Sum"}}' \
    --dataset-grouping name="cost-center" type="TagKey" -o json \
  | jq -r '[.rows[]] as $r | ([$r[][0]]|add) as $t
           | ([$r[] | select((.[1]//"")=="")][0][0] // 0) as $u
           | "untagged: \($u|floor) of \($t|floor) = \((100*$u/$t)|.*100|round/100)%"'
untagged: 340 of 22186 = 1.53%
```

### 9.2 Failure catalogue

| Symptom | Most likely root cause | Diagnostic | Fix |
|---|---|---|---|
| Cost analysis shows **€0.00** for a subscription that clearly has resources | Usage has not been ingested yet (new subscription < 24 h), or you are looking at a **Free Trial / sponsored** subscription where charges are credit-absorbed | `az consumption usage list --start-date <yesterday> --end-date <yesterday> --query "length(@)"` | Wait 24 h; check `az account show --query "state"` and the offer ID |
| `(NotFound) The specified scope was not found` from a Cost Management call | Wrong scope string — most often `resourcegroups` vs `resourceGroups`, or a management-group scope on a Pay-as-you-go subscription | Echo the scope; compare against §2.1 | Correct the casing; upgrade the agreement if MG scope is required |
| `(AuthorizationFailed)` on `az costmanagement query` but the portal works | The identity has ARM `Reader` but the query is at a **billing** scope, which ARM RBAC does not cover | `az role assignment list --assignee <id> --all -o table` | Grant the EA/MCA billing role in **Cost Management + Billing**, not in IAM |
| Budget exists, spend passed 100 %, **no email arrived** | (a) `enabled: false` on the notification; (b) the recipient's tenant filters it; (c) spend crossed *before* the last data refresh so the evaluation has not run; (d) the budget's `filter` excludes the resource groups that actually spent | Steps 2–4 of §9.1 | Send a test notification; widen or remove the filter; add a `Forecasted` rule for lead time |
| Budget fired but **nothing was shut down** | Working as designed. Budgets never enforce | — | Wire the action group to a Logic App / Automation runbook / Function that deallocates or applies a `ReadOnly` lock |
| Reservation bought, but the VM still shows full cost | You are in **Actual cost**, not Amortized; or the reservation **scope** is a different subscription; or the VM SKU/region does not match the reservation | Switch metric to Amortized; `az reservations reservation-order list` and check `appliedScopes` | Change the reservation scope to `Shared` or to the right subscription |
| A large charge appears once and never again | A **reservation or Marketplace purchase** in the Actual cost view | Group by `PublisherType` / `ChargeType` | Use the Amortized view for allocation; Actual only for invoice reconciliation |
| Untagged spend spikes after a deploy | A resource type that the RP creates implicitly (disks, NICs, public IPs, node resource group in AKS) | The ARG query in §8.5 | Add a `Modify` policy per orphan type; for AKS set the node-resource-group tags via `--node-resource-group-tags` / `nodeResourceGroupProfile` |
| Tagged the resource, but last month's cost is still unallocated | Tags apply to usage records **from the tagging moment forward**. History is immutable | Compare `Cost analysis` grouped by the tag across two months | Enable **tag inheritance** in Cost Management settings — it retroactively covers the current billing month only. Prior months are lost |
| Two rows `prod` and `Prod` in cost analysis | Tag **values** are case-sensitive | `az graph query -q "Resources \| distinct tostring(tags['env'])"` | Normalize with a `Modify` policy using `addOrReplace`; enforce an enumerated allowed-values policy |
| Policy `Modify` assignment is compliant but tags never appear | Missing managed identity, missing `location` on the assignment, missing role assignment, or you never created a **remediation task** (`Modify` fixes new/updated resources; existing ones need remediation) | `az policy assignment show --name pa-inherit-cost-center --query "{id:identity.principalId, loc:location}"` | Add `identity`, `location`, `Tag Contributor` role assignment, then `az policy remediation create` |
| Remediation reports `Failed` on some resources | Resource type does not support tags (classic/ASM), or is locked | `az policy remediation deployment list ... --query "[?status!='Succeeded']"` | Exempt the type in the policy; remove the `CanNotDelete`/`ReadOnly` lock temporarily |
| Export blob container is empty | Storage `networkAcls.defaultAction = Deny` without `bypass: AzureServices`; or shared-key access disabled; or the export schedule window (`recurrencePeriod.from/to`) has expired | `az costmanagement export show --query "runHistory.value[0]"` | Set `bypass: AzureServices`, `allowSharedKeyAccess: true`, extend the recurrence period |
| Cost export numbers ≠ invoice | Comparing **Amortized** against an invoice (invoices are Actual), or comparing pre-tax to post-tax, or wrong currency column (`Cost` vs `CostUSD`) | Re-run with `--type ActualCost`; check `BillingCurrency` | Reconcile Actual↔invoice; use Amortized only for internal chargeback |
| AKS namespace dimensions never appear in Cost Analysis | Cluster is on the **Free** tier; the add-on requires Standard or Premium | `az aks show --query "{tier:sku.tier, ca:metricsProfile.costAnalysis.enabled}"` | `az aks update --tier standard --enable-cost-analysis`, then wait up to 24 h |
| Forecast in Cost Analysis looks absurd | The forecast model needs history; a brand-new subscription or a one-off reservation purchase skews it badly | Look at the daily series in §8.4 | Ignore forecasts for the first ~30 days; exclude `ChargeType = Purchase` from the view |
| `az consumption usage list` hangs or times out | It pages every usage record at EA scope; a large enrollment is millions of rows | — | Use `az costmanagement query` with aggregation, or a scheduled export |

### 9.3 Making a budget actually enforce something

Because this is the gap everyone falls into, the enforcement path in full:

```
Budget (Actual > 100%)
  └─► contactGroups → Action Group
        └─► webhook / Azure Function / Logic App / Automation runbook
              ├─ tag the offending RG  lifecycle=frozen
              ├─ apply a ReadOnly management lock
              ├─ deallocate VMs where env != prod
              └─ scale AKS node pools to their minimum
```

Reasonable safety rules for that automation: **never** act on `env=prod` without a human in the loop; act only on resources carrying `env in (dev, sandbox)`; make the action **reversible** (deallocate, not delete; `ReadOnly` lock, not `CanNotDelete`); and emit an audit event so the on-call engineer knows why a dev cluster vanished at 03:00.

---

## 10. Exam-focused compression

Statements you should be able to produce verbatim:

- **Ingress is free; egress is charged.** Ingress into an Azure datacenter costs nothing.
- **Budgets notify, they do not stop spending.** Enforcement requires automation behind an action group.
- **Tags are not inherited.** A resource does not get its resource group's tags automatically. Azure Policy fixes that.
- **The Pricing Calculator estimates a future Azure design; the TCO Calculator compares on-premises against Azure over several years, including non-Azure costs like power, cooling, real estate and labour. Neither uses your real usage. Cost Management reports actual spend.**
- **Reservations = 1 or 3 years on a specific resource type/region, up to ~72 % off. Savings plans = 1 or 3 years on an hourly dollar amount, more flexible, up to ~65 % off, not cancellable. Spot = up to ~90 % off, evictable, no SLA. Azure Hybrid Benefit = reuse existing Windows Server / SQL Server licences with Software Assurance.**
- **A management-group cost scope requires an EA or MCA agreement.** Pay-as-you-go cannot.
- **Cost Management Reader** is the least-privilege role for someone who must see costs and nothing else.
- **Azure Advisor's Cost category** is where right-sizing, idle-resource and reservation-purchase recommendations live.
- **Region affects price** for the same SKU.
- **Marketplace / third-party ISV charges are not covered by Azure reservations or Azure credits.**

Distractors that show up repeatedly:

| Statement | Verdict |
|---|---|
| "A budget can automatically shut down resources when exceeded." | **False** — it notifies only |
| "Tags applied to a resource group are inherited by its resources." | **False** |
| "Data transferred into Azure is charged." | **False** — ingress is free |
| "The TCO Calculator shows your current Azure spend." | **False** — it is a hypothetical on-prem vs Azure comparison |
| "Reserved Instances require an upfront payment." | **False** — monthly payment is available at the same total price |
| "Spot VMs carry an SLA." | **False** |
| "You need a subscription to use the Pricing Calculator." | **False** |
| "Azure Hybrid Benefit works without Software Assurance." | **False** |
| "Cost Management can show cost grouped by tag." | **True** — and it is the point of tagging |

---

## Referencias

**Certification and exam**
- AZ-900 study guide (authoritative objective list): https://learn.microsoft.com/en-us/credentials/certifications/resources/study-guides/az-900
- Azure Fundamentals exam page: https://learn.microsoft.com/en-us/credentials/certifications/azure-fundamentals/

**Cost Management**
- Microsoft Cost Management documentation hub: https://learn.microsoft.com/en-us/azure/cost-management-billing/
- Understand Cost Management data (latency, refresh cadence, dataset coverage): https://learn.microsoft.com/en-us/azure/cost-management-billing/costs/understand-cost-mgt-data
- Quickstart — explore and analyze costs with Cost analysis: https://learn.microsoft.com/en-us/azure/cost-management-billing/costs/quick-acm-cost-analysis
- Understand and work with scopes: https://learn.microsoft.com/en-us/azure/cost-management-billing/costs/understand-work-scopes
- Assign access to Cost Management data: https://learn.microsoft.com/en-us/azure/cost-management-billing/costs/assign-access-acm-data
- Create and manage budgets: https://learn.microsoft.com/en-us/azure/cost-management-billing/costs/tutorial-acm-create-budgets
- Manage costs with automation (action groups, runbooks, Logic Apps): https://learn.microsoft.com/en-us/azure/cost-management-billing/costs/manage-automation
- Create and manage exported data: https://learn.microsoft.com/en-us/azure/cost-management-billing/costs/tutorial-improved-exports
- FOCUS cost and usage data in Cost Management: https://learn.microsoft.com/en-us/azure/cost-management-billing/dataset-schema/schema-index
- Identify anomalies and unexpected changes in cost: https://learn.microsoft.com/en-us/azure/cost-management-billing/understand/analyze-unexpected-charges
- Group and allocate costs using tag inheritance: https://learn.microsoft.com/en-us/azure/cost-management-billing/costs/enable-tag-inheritance
- Create and manage Azure cost allocation rules: https://learn.microsoft.com/en-us/azure/cost-management-billing/costs/allocate-costs

**Pricing, estimation, and purchase models**
- Azure Pricing Calculator: https://azure.microsoft.com/en-us/pricing/calculator/
- Azure Total Cost of Ownership (TCO) Calculator: https://azure.microsoft.com/en-us/pricing/tco/calculator/
- Build a business case with Azure Migrate: https://learn.microsoft.com/en-us/azure/migrate/concepts-business-case-calculation
- Azure Retail Prices API: https://learn.microsoft.com/en-us/rest/api/cost-management/retail-prices/azure-retail-prices
- Bandwidth pricing (egress, inter-region, inter-AZ): https://azure.microsoft.com/en-us/pricing/details/bandwidth/
- What are Azure Reservations: https://learn.microsoft.com/en-us/azure/cost-management-billing/reservations/save-compute-costs-reservations
- What is Azure savings plans for compute: https://learn.microsoft.com/en-us/azure/cost-management-billing/savings-plan/savings-plan-compute-overview
- Decide between a savings plan and a reservation: https://learn.microsoft.com/en-us/azure/cost-management-billing/savings-plan/decide-between-savings-plan-reservation
- Use Azure Spot Virtual Machines: https://learn.microsoft.com/en-us/azure/virtual-machines/spot-vms
- Azure Hybrid Benefit: https://learn.microsoft.com/en-us/azure/cost-management-billing/scope-level/overview-azure-hybrid-benefit-scope
- Azure Dev/Test pricing: https://azure.microsoft.com/en-us/pricing/dev-test/

**Tags and policy**
- Use tags to organize your Azure resources and management hierarchy: https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/tag-resources
- Tag support for Azure resources (per-type limits): https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/tag-support
- Assign policies for tag compliance: https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/tag-policies
- Azure Policy `Modify` effect: https://learn.microsoft.com/en-us/azure/governance/policy/concepts/effect-modify
- Remediate non-compliant resources: https://learn.microsoft.com/en-us/azure/governance/policy/how-to/remediate-resources
- Define your naming and tagging strategy (Cloud Adoption Framework): https://learn.microsoft.com/en-us/azure/cloud-adoption-framework/ready/azure-best-practices/resource-naming-and-tagging-decision-guide

**Optimization and Kubernetes**
- Azure Advisor cost recommendations: https://learn.microsoft.com/en-us/azure/advisor/advisor-reference-cost-recommendations
- Azure Well-Architected Framework — Cost Optimization pillar: https://learn.microsoft.com/en-us/azure/well-architected/cost-optimization/
- AKS cost analysis add-on: https://learn.microsoft.com/en-us/azure/aks/cost-analysis
- Optimize costs in Azure Kubernetes Service: https://learn.microsoft.com/en-us/azure/aks/best-practices-cost
- OpenCost (CNCF): https://www.opencost.io/docs/
- FinOps Open Cost and Usage Specification (FOCUS): https://focus.finops.org/

**API and tooling references**
- `az costmanagement` CLI reference: https://learn.microsoft.com/en-us/cli/azure/costmanagement
- `az consumption budget` CLI reference: https://learn.microsoft.com/en-us/cli/azure/consumption/budget
- `az tag` CLI reference: https://learn.microsoft.com/en-us/cli/azure/tag
- `Microsoft.Consumption/budgets` ARM/Bicep reference: https://learn.microsoft.com/en-us/azure/templates/microsoft.consumption/budgets
- `Microsoft.CostManagement/exports` ARM/Bicep reference: https://learn.microsoft.com/en-us/azure/templates/microsoft.costmanagement/exports
- Azure Resource Graph query language reference: https://learn.microsoft.com/en-us/azure/governance/resource-graph/concepts/query-language
- Terraform `azurerm_consumption_budget_subscription`: https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/consumption_budget_subscription