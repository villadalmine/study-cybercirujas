# 4.2 — Understand Resources for Billing, Budget, and Cost Management

**Certification:** AWS Certified Cloud Practitioner (CLF-C02, v1.0)
**Domain 4:** Billing, Pricing, and Support — **Task 4.2** — Exam weight: **4.0**
**Level:** Principal Platform Architect / SRE — production depth

---

## 1. The production problem: the bill is a distributed trace of your architecture

Every cost line in an AWS invoice is the shadow of an architectural decision that somebody made months ago. A `NatGateway-Bytes` charge of $9,400/month is not a finance problem — it is a *topology* problem: pods in private subnets are reaching S3 over the NAT gateway because nobody created a Gateway VPC endpoint. A `CloudWatch-DataProcessing-Bytes` spike is not a billing anomaly — it is a logging library that started emitting DEBUG in production.

This is why cost management belongs to the platform team and not only to finance. The failure mode that this domain exists to prevent is specific and recurrent:

> An engineering organization discovers a 40% month-over-month cost increase **on the 5th of the following month**, when the invoice is finalized. By then the anomaly has been running for 35 days, nobody can attribute it to a team because resources are untagged, and the only remediation available is a manual scavenger hunt through the console.

Treat cost as a first-class signal with the same discipline you apply to latency:

| SRE concept | Cost equivalent | AWS resource that implements it |
|---|---|---|
| Metric emission | Metered usage → rated line items | Billing pipeline → **Cost and Usage Report (CUR)** |
| Time-series store & query | Aggregated cost query API | **AWS Cost Explorer** (`ce:GetCostAndUsage`) |
| Dashboard | Cost dashboards | Cost Explorer reports, QuickSight over CUR, **CUDOS** |
| Threshold alert (symptom-based) | Budget threshold breach | **AWS Budgets** (actual + forecasted) |
| Anomaly detection (ML baseline) | Unexpected spend deviation | **AWS Cost Anomaly Detection** |
| Auto-remediation / circuit breaker | Attach a restrictive policy on breach | **AWS Budgets Actions** |
| Labels / cardinality dimensions | Cost dimensions | **Cost allocation tags**, **Cost Categories** |
| Capacity planning | Commitment purchase | **Savings Plans / Reserved Instances**, **Cost Optimization Hub** |
| Pre-production load model | Pre-deployment estimate | **AWS Pricing Calculator** |
| Multi-tenant accounting | Chargeback / showback | **AWS Organizations** consolidated billing, **AWS Billing Conductor** |

The rest of this document walks the pipeline from the bottom up, because *the tool you should reach for is determined by which stage of the pipeline your question lives in.*

---

## 2. The billing data plane: where the numbers actually come from

Understanding the internal path is what separates "I clicked Cost Explorer" from "I know why Cost Explorer and my CUR disagree by $312."

```
┌──────────────────────────────────────────────────────────────────────────┐
│  1. METERING  — every service emits usage records                        │
│     (EC2 instance-seconds, S3 GB-months, Lambda GB-seconds, GB egress)   │
│     Emission is asynchronous and per-service. Latency: minutes → hours.  │
└───────────────────────────────┬──────────────────────────────────────────┘
                                │  usage records (UsageType, Operation,
                                │  Region, ResourceId, AccountId, hour)
                                ▼
┌──────────────────────────────────────────────────────────────────────────┐
│  2. RATING  — apply public price list, then commitment/discount layers   │
│     On-Demand rate → RI/SP coverage → tiering → EDP / private pricing    │
│     → credits → tax. Produces *line items* with a line_item_type.        │
└───────────────────────────────┬──────────────────────────────────────────┘
                                │
        ┌───────────────────────┼───────────────────────────┐
        ▼                       ▼                           ▼
┌────────────────┐   ┌────────────────────────┐   ┌──────────────────────┐
│ 3a. CUR / Data │   │ 3b. Cost Explorer store│   │ 3c. Budgets engine   │
│  Exports → S3  │   │  (aggregated, indexed) │   │  (evaluates ~3×/day) │
│  hourly rows,  │   │  13 months history,    │   │  actual + forecast   │
│  resource-level│   │  12 months forecast    │   │                      │
│  ~3 refresh/day│   │  ~24 h freshness       │   │  → SNS / email /     │
│  Parquet/CSV   │   │  $0.01 per API request │   │    Chatbot / Actions │
└───────┬────────┘   └───────────┬────────────┘   └──────────┬───────────┘
        │                        │                            │
        ▼                        ▼                            ▼
   Athena / Redshift      Console, ce API,            Circuit breakers,
   QuickSight, CUDOS      Cost Anomaly Detection      IAM/SCP attachment
```

### Freshness and retention — the numbers that cause on-call confusion

| Surface | Freshness | Granularity | Retention | Cost |
|---|---|---|---|---|
| Cost Explorer (console/API) | ~24 h behind | Monthly / Daily; **Hourly & resource-level opt-in** | 13 months history (current + 12), 12 months forecast; **hourly data 14 days** | Console free; **API $0.01 per paginated request**; hourly/resource granularity metered per 1,000 usage records |
| CUR / Data Exports | Up to **3 refreshes/day**, first delivery up to 24 h | **Hourly**, resource-level, tag columns | Unlimited (your S3 bucket) | S3 storage + Athena/Glue scan cost only |
| AWS Budgets | Evaluated **~3×/day** | Per budget period | Rolling | First 2 budgets free/account, then metered per budget per day |
| Cost Anomaly Detection | Daily evaluation, alert within ~24 h of detection | Service / account / tag / cost category | 90 days of anomalies via API | **Free** |
| Bills page / invoice | Finalized in the first days of the following month | Monthly | Per account history | Free |

**Operational consequence:** never build a real-time kill-switch on billing data. The tightest feedback loop AWS offers is roughly 8–12 hours (Budgets) or ~24 hours (Anomaly Detection). If you need second-level protection — for example, capping a runaway Lambda fan-out — you must build it on **CloudWatch metrics and service quotas**, not on billing.

---

## 3. Cost metric semantics: the five numbers that are all "the cost"

This is the single most common source of "the dashboard is wrong" tickets. Cost Explorer, Budgets and CUR can all report *different values for the same hour* because they are reporting different metrics.

| Metric | Definition | When it is the right answer | Trap |
|---|---|---|---|
| **UnblendedCost** | The rate actually applied to that specific line item in that specific account. RI/SP upfront fees land as a lump sum in the month they were paid. | "What did AWS charge us this month?" — matches the invoice. **Default for Budgets and Cost Explorer.** | A 3-year All Upfront RI purchase makes one account appear to spend $180k in one hour. |
| **BlendedCost** | Usage priced at the *average* rate across the organization for that usage type, blending RI/SP-covered and on-demand hours. | Internal showback where you do not want the account that happens to hold the RI to look artificially cheap. | **Never equals the invoice.** It is an allocation construct. Do not alert on it. |
| **AmortizedCost** | Upfront commitment fees spread evenly across the hours they cover; RI/SP-covered usage priced at effective rate. | Unit economics, trend analysis, "what is our true run-rate?" | Sum over a month ≠ invoice for that month. |
| **NetUnblendedCost** | Unblended, **after** private pricing / EDP / promotional discounts. | Enterprise agreements — the only figure that matches a discounted invoice. | Zero-valued if you have no discount program; some tools silently fall back. |
| **NetAmortizedCost** | Amortized, after discounts. | Discounted-enterprise unit economics. | Requires `MANUAL_DISCOUNT_COMPATIBILITY` handling in CUR. |
| **UsageQuantity / NormalizedUsageAmount** | Raw units; normalized units express instance sizes in a common unit (e.g. `nano` = 0.25 NU) for size-flexible RIs. | Coverage math, capacity planning. | Summing `UsageQuantity` across heterogeneous usage types is meaningless. |

**Rule for platform teams:** alert on **unblended** (it is what you pay), analyze on **amortized** (it is what you consume), and never expose **blended** to engineers.

---

## 4. Account topology: AWS Organizations and consolidated billing

Cost management is an *organizational* capability before it is a tooling capability. The unit of billing is the **management (payer) account**; member accounts are the unit of attribution.

```
                       ┌───────────────────────────────────┐
                       │  Management (payer) account       │
                       │  • single invoice                 │
                       │  • owns CUR, Budgets, Cost Explorer│
                       │  • owns RI/SP inventory & sharing │
                       │  • activates cost allocation tags │
                       └────────────┬──────────────────────┘
                                    │  Service Control Policies
                                    │  Tag Policies
              ┌─────────────────────┼─────────────────────┐
              ▼                     ▼                     ▼
     ┌────────────────┐   ┌────────────────┐   ┌────────────────┐
     │ OU: Production │   │ OU: NonProd    │   │ OU: Sandbox    │
     │  prod-platform │   │  dev-platform  │   │  eng-sandbox   │
     │  prod-data     │   │  staging       │   │                │
     └────────────────┘   └────────────────┘   └────────────────┘
```

### What consolidated billing actually gives you

| Benefit | Mechanism | Failure mode if misunderstood |
|---|---|---|
| One invoice, one payment method | Payer aggregates all member charges | Member accounts cannot pay separately; leaving the org mid-month splits the bill |
| **Volume-tier aggregation** | Usage across all accounts is summed *before* applying tiered pricing (e.g. S3 storage tiers, data transfer tiers) | Splitting workloads across many accounts to "isolate cost" does not lose the discount — but leaving the org does |
| **RI / Savings Plans sharing** | Unused commitment in one account automatically covers matching usage in any other account in the family | Enabled by default. If a team "loses" its RI discount, someone else consumed it first (billing-hour priority: the account that owns the RI wins, then others) |
| Centralized governance | SCPs, tag policies, backup policies | SCPs never grant permissions; they only set the maximum |
| Blended-rate reporting | Averaged rates across the family | Confuses engineers who compare to unblended |

**RI/SP sharing is opt-out, per account, from the payer:**

```console
$ aws organizations list-accounts --query 'Accounts[].[Id,Name,Status]' --output table
------------------------------------------------------
|                    ListAccounts                     |
+--------------+----------------------+---------------+
|  111122223333|  org-management      |  ACTIVE       |
|  222233334444|  prod-platform       |  ACTIVE       |
|  333344445555|  prod-data           |  ACTIVE       |
|  444455556666|  staging             |  ACTIVE       |
|  555566667777|  eng-sandbox         |  ACTIVE       |
+--------------+----------------------+---------------+

$ aws ce get-cost-and-usage \
    --time-period Start=2026-08-01,End=2026-09-01 \
    --granularity MONTHLY \
    --metrics UnblendedCost AmortizedCost \
    --group-by Type=DIMENSION,Key=LINKED_ACCOUNT \
    --output json
{
    "GroupDefinitions": [
        {
            "Type": "DIMENSION",
            "Key": "LINKED_ACCOUNT"
        }
    ],
    "ResultsByTime": [
        {
            "TimePeriod": {
                "Start": "2026-08-01",
                "End": "2026-09-01"
            },
            "Total": {},
            "Groups": [
                {
                    "Keys": ["222233334444"],
                    "Metrics": {
                        "UnblendedCost": {"Amount": "28431.9920114", "Unit": "USD"},
                        "AmortizedCost": {"Amount": "33902.4471003", "Unit": "USD"}
                    }
                },
                {
                    "Keys": ["333344445555"],
                    "Metrics": {
                        "UnblendedCost": {"Amount": "11204.7733901", "Unit": "USD"},
                        "AmortizedCost": {"Amount": "11204.7733901", "Unit": "USD"}
                    }
                },
                {
                    "Keys": ["444455556666"],
                    "Metrics": {
                        "UnblendedCost": {"Amount": "3980.1120445", "Unit": "USD"},
                        "AmortizedCost": {"Amount": "3980.1120445", "Unit": "USD"}
                    }
                },
                {
                    "Keys": ["555566667777"],
                    "Metrics": {
                        "UnblendedCost": {"Amount": "912.4408820", "Unit": "USD"},
                        "AmortizedCost": {"Amount": "912.4408820", "Unit": "USD"}
                    }
                }
            ],
            "Estimated": true
        }
    ],
    "DimensionValueAttributes": [
        {"Value": "222233334444", "Attributes": {"description": "prod-platform"}},
        {"Value": "333344445555", "Attributes": {"description": "prod-data"}},
        {"Value": "444455556666", "Attributes": {"description": "staging"}},
        {"Value": "555566667777", "Attributes": {"description": "eng-sandbox"}}
    ]
}
```

Read the diagnostic in that output: `prod-platform` shows amortized **above** unblended ($33.9k vs $28.4k). That means the account is *consuming* commitment capacity it did not pay for this month — the upfront fee was paid in a prior month, or the RIs/SPs are owned by the payer and shared into it. `"Estimated": true` means the month is not closed; the number will move.

### AWS Billing Conductor — when consolidated billing is not enough

Consolidated billing produces one true invoice. Managed service providers, internal platform teams that resell capacity, and organizations that need to hide AWS's real rates from business units need a **pro-forma** bill: the same usage, priced with *your* rate card.

**AWS Billing Conductor** builds that second, non-authoritative view: billing groups, custom line items (add a platform-team markup, credit a business unit), and pricing rules (discount/markup a service or a global tier). It never changes what AWS charges you — it produces a parallel dataset and a pro-forma CUR.

Use it when: chargeback needs rates that differ from AWS's. Do not use it when: you only need showback — Cost Categories plus tags are free and simpler.

---

## 5. Tooling matrix: choosing the right instrument

| Tool | Question it answers | Granularity | Latency | Cost | Programmable | Primary limitation |
|---|---|---|---|---|---|---|
| **Bills page** (Billing console) | "What is on this month's invoice?" | Service, account, region | Daily → finalized monthly | Free | No API | No trend analysis |
| **AWS Cost Explorer** | "How did cost move over time, and by what dimension?" | Monthly/daily; hourly & resource-level opt-in | ~24 h | Console free; **$0.01/API request** | `ce:*` | 13 months; aggregated (not per-resource unless opted in) |
| **CUR / Data Exports (CUR 2.0)** | "Show me every line item, joined to my own metadata" | **Hourly, per-resource, per-tag** | ≤ 24 h first delivery, ~3×/day | S3 + query engine | `cur:*`, `bcm-data-exports:*` | Needs Athena/Glue/QuickSight to be useful; TB-scale for large orgs |
| **AWS Budgets** | "Tell me before I exceed a threshold" | Cost, usage, RI/SP utilization & coverage | ~3×/day | 2 free/account, then daily metered | `budgets:*`, CFN, Terraform | Not real-time; forecast needs ~5 weeks of history |
| **AWS Budgets Actions** | "Stop the bleeding automatically" | IAM policy / SCP / EC2-RDS stop | Same as Budgets | Metered with the budget | `budgets:*` | Blunt instrument; needs an execution role |
| **Cost Anomaly Detection** | "Did something change that I did not plan?" | Service / account / tag / cost category monitors | ~24 h | **Free** | `ce:*AnomalyMonitor*` | Needs ~10 days to learn a baseline; noisy on spiky workloads |
| **Cost Optimization Hub** | "What are all my savings opportunities, deduplicated and ranked?" | Per recommendation, org-wide | Daily refresh | Free (opt-in via Organizations) | `cost-optimization-hub:*` | Recommendations only; no enforcement |
| **AWS Compute Optimizer** | "Is this instance/volume/function the right size?" | Per resource, from CloudWatch metrics | Requires ≥ 30 h of metrics | Free (paid tier for enhanced metrics/3-month lookback) | `compute-optimizer:*` | Blind to memory unless the CW agent is installed |
| **AWS Trusted Advisor** | "Which best practices am I violating, including cost ones?" | Per check | Refreshed periodically | Core checks for all; **full cost checks need Business/Enterprise Support** | `support:*` | Check breadth is tied to the support plan |
| **AWS Pricing Calculator** | "What will this cost before I build it?" | Per configured service | N/A (model) | Free | Public price list via `pricing:GetProducts` | Garbage in, garbage out — you must model data transfer |
| **AWS Billing Conductor** | "What does *my* rate card say this team owes?" | Billing group | Monthly | Metered per billing group | `billingconductor:*` | Pro-forma only; not the AWS invoice |
| **AWS Cost Categories** | "Group cost by *my* org chart, not AWS's" | Rule-based virtual dimension | Applied on next refresh | Free | `ce:*CostCategory*` | Rules are evaluated in order; first match wins |

> **Retired service note:** *AWS Application Cost Profiler* has been discontinued by AWS. It still appears in older question banks — it is not a valid answer on the current exam.

---

## 6. Cost allocation: making the bill answer "who?"

An untagged AWS account produces a bill that can only be sliced by AWS's own dimensions (service, region, usage type). Cost allocation converts that into *your* dimensions.

### 6.1 The three tag layers

| Layer | Examples | Who creates it | Backfill |
|---|---|---|---|
| **AWS-generated** | `aws:createdBy`, `aws:cloudformation:stack-name`, `aws:eks:namespace`, `aws:eks:workload-name` | AWS, automatically | Activated separately; forward-looking |
| **User-defined** | `team`, `environment`, `cost-center`, `service` | You, on the resource | **Forward-looking by default** — see below |
| **Cost Categories** | `BusinessUnit = Payments` derived from account IDs + tags + services | Rule engine in Billing console | Applied on refresh; can be backdated to the start of the month |

**The critical mechanic:** creating a tag on a resource does *not* make it a cost dimension. The tag key must be **activated as a cost allocation tag in the management account**, it takes up to 24 hours to appear, and — historically — activation only applied to usage from that point forward. AWS now offers a **cost allocation tag backfill** to retroactively apply an activated key to prior periods:

```console
$ aws ce list-cost-allocation-tags --status Inactive --output table
-------------------------------------------------------------
|                 ListCostAllocationTags                     |
+---------------+----------------+---------------------------+
|    TagKey     |     Type       |          Status           |
+---------------+----------------+---------------------------+
|  cost-center  |  UserDefined   |  Inactive                 |
|  service      |  UserDefined   |  Inactive                 |
+---------------+----------------+---------------------------+

$ aws ce update-cost-allocation-tags-status \
    --cost-allocation-tags-status \
      TagKey=cost-center,Status=Active TagKey=service,Status=Active
{
    "Errors": []
}

$ aws ce start-cost-allocation-tag-backfill --backfill-from 2026-06-01T00:00:00Z
{
    "BackfillRequest": {
        "Status": "PROCESSING",
        "RequestedAt": "2026-09-04T09:12:44.201000+00:00",
        "BackfillFrom": "2026-06-01T00:00:00+00:00"
    }
}

$ aws ce list-cost-allocation-tag-backfill-history --query 'BackfillRequests[0]'
{
    "BackfillFrom": "2026-06-01T00:00:00+00:00",
    "RequestedAt": "2026-09-04T09:12:44.201000+00:00",
    "Status": "PROCESSING"
}
```

### 6.2 Enforcing tags before the resource exists

Detection is too late. Enforce at the control plane with an SCP, and standardize the *values* with an Organizations tag policy.

**SCP — deny EC2/RDS creation without a `cost-center` tag** (attach to the workload OUs, never to the root without testing):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DenyRunInstancesWithoutCostCenter",
      "Effect": "Deny",
      "Action": [
        "ec2:RunInstances",
        "rds:CreateDBInstance",
        "rds:CreateDBCluster"
      ],
      "Resource": [
        "arn:aws:ec2:*:*:instance/*",
        "arn:aws:ec2:*:*:volume/*",
        "arn:aws:rds:*:*:db:*",
        "arn:aws:rds:*:*:cluster:*"
      ],
      "Condition": {
        "Null": {
          "aws:RequestTag/cost-center": "true"
        }
      }
    },
    {
      "Sid": "DenyRemovalOfCostAllocationTags",
      "Effect": "Deny",
      "Action": [
        "ec2:DeleteTags",
        "rds:RemoveTagsFromResource"
      ],
      "Resource": "*",
      "Condition": {
        "ForAnyValue:StringEquals": {
          "aws:TagKeys": ["cost-center", "team", "environment"]
        }
      }
    },
    {
      "Sid": "ProtectBillingGuardrails",
      "Effect": "Deny",
      "Action": [
        "budgets:DeleteBudget",
        "budgets:DeleteBudgetAction",
        "ce:DeleteAnomalyMonitor",
        "ce:DeleteAnomalySubscription",
        "cur:DeleteReportDefinition",
        "bcm-data-exports:DeleteExport"
      ],
      "Resource": "*",
      "Condition": {
        "ArnNotLike": {
          "aws:PrincipalArn": "arn:aws:iam::*:role/PlatformFinOpsAdmin"
        }
      }
    }
  ]
}
```

**Organizations tag policy — constrain allowed values and capitalization:**

```json
{
  "tags": {
    "cost-center": {
      "tag_key": {
        "@@assign": "cost-center",
        "@@operators_allowed_for_child_policies": ["@@none"]
      },
      "tag_value": {
        "@@assign": ["CC-1001", "CC-1002", "CC-2100", "CC-3300"]
      },
      "enforced_for": {
        "@@assign": [
          "ec2:instance",
          "ec2:volume",
          "rds:db",
          "s3:bucket",
          "lambda:function",
          "eks:cluster"
        ]
      }
    },
    "environment": {
      "tag_key": {
        "@@assign": "environment"
      },
      "tag_value": {
        "@@assign": ["production", "staging", "development", "sandbox"]
      },
      "enforced_for": {
        "@@assign": ["ec2:instance", "rds:db", "eks:cluster"]
      }
    }
  }
}
```

> Tag policies enforce **key casing and value sets**; they do not make a tag mandatory. Mandatory-ness comes from the SCP. You need both.

### 6.3 Cost Categories: the org chart that AWS does not know about

Tags describe resources. Cost Categories describe *the business*, and can be built from accounts, services, regions, tags and other cost categories. They become a first-class dimension in Cost Explorer, Budgets and CUR.

```json
{
  "Name": "BusinessUnit",
  "RuleVersion": "CostCategoryExpression.v1",
  "DefaultValue": "Unallocated-Shared",
  "Rules": [
    {
      "Value": "Payments",
      "Rule": {
        "Or": [
          { "Dimensions": { "Key": "LINKED_ACCOUNT", "Values": ["222233334444"] } },
          { "Tags": { "Key": "cost-center", "Values": ["CC-1001", "CC-1002"] } }
        ]
      },
      "Type": "REGULAR"
    },
    {
      "Value": "DataPlatform",
      "Rule": {
        "And": [
          { "Dimensions": { "Key": "LINKED_ACCOUNT", "Values": ["333344445555"] } },
          { "Not": { "Tags": { "Key": "environment", "Values": ["sandbox"] } } }
        ]
      },
      "Type": "REGULAR"
    },
    {
      "Value": "PlatformSharedServices",
      "Rule": {
        "Dimensions": {
          "Key": "SERVICE",
          "Values": [
            "AWS Key Management Service",
            "Amazon Route 53",
            "AWS CloudTrail",
            "Amazon CloudWatch"
          ]
        }
      },
      "Type": "REGULAR"
    }
  ],
  "SplitChargeRules": [
    {
      "Source": "PlatformSharedServices",
      "Targets": ["Payments", "DataPlatform"],
      "Method": "PROPORTIONAL"
    }
  ]
}
```

`SplitChargeRules` is the piece most teams miss: it redistributes shared-service cost (KMS, Route 53, the observability stack) onto the consuming units **proportionally**, **evenly**, or by **fixed** percentages — turning "Unallocated" from 30% of the bill into something defensible.

```console
$ aws ce create-cost-category-definition --cli-input-json file://business-unit-category.json
{
    "CostCategoryArn": "arn:aws:ce::111122223333:costcategory/6f1f0e2a-8d4c-4c2f-9a55-2b1f7cbb9e10",
    "EffectiveStart": "2026-09-01T00:00:00Z"
}
```

Note `EffectiveStart`: cost categories apply from the **start of the current month**, not from the moment you created them. Rules are evaluated **top to bottom, first match wins** — order them from most specific to most general.

---

## 7. AWS Budgets: the alerting layer

### 7.1 Budget types and what they are actually for

| Budget type | Tracks | Correct use | Anti-pattern |
|---|---|---|---|
| **Cost** | Spend against a dollar limit | Team/account/environment guardrails | One org-wide budget — it tells you nothing actionable |
| **Usage** | Units (GB, hours, requests) | Free Tier protection, data transfer ceilings | Mixing usage types with incompatible units |
| **RI utilization** | % of purchased RI hours actually used | Detecting stranded commitment after a migration | Alerting at 100% — set the floor around 90–95% |
| **RI coverage** | % of eligible usage covered by RIs | Detecting under-commitment | Ignoring size-flexibility (use normalized units) |
| **Savings Plans utilization** | % of hourly commitment consumed | Same as RI utilization, for SPs | Confusing it with coverage |
| **Savings Plans coverage** | % of eligible spend covered by SPs | Deciding when to buy more commitment | Chasing 100% coverage — you lose the ability to scale down |

Each budget supports **up to 5 alerts**, each alert with **up to 10 email subscribers** plus SNS topics (and AWS Chatbot for Slack/Teams). Alerts fire on **ACTUAL** or **FORECASTED** spend, with a threshold expressed as a **percentage of the limit** or an **absolute value**.

### 7.2 Complete CloudFormation stack: budgets + actions + SNS

```yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: >
  FinOps guardrails: monthly cost budget with tiered alerting, a Savings Plans
  utilization budget, a per-team tag-scoped budget, and a budget action that
  attaches a deny-expensive-instances policy to the sandbox role at 100% actual.

Parameters:
  NotificationEmail:
    Type: String
    Description: Distribution list that receives budget notifications.
    AllowedPattern: '^[^@\s]+@[^@\s]+\.[^@\s]+$'
  MonthlyCostLimitUsd:
    Type: Number
    Default: 42000
    MinValue: 1
  SandboxAccountId:
    Type: String
    AllowedPattern: '^[0-9]{12}$'
  CostCenterTagValue:
    Type: String
    Default: CC-1001

Resources:

  ############################################################################
  # Notification fan-out. The topic policy MUST allow budgets.amazonaws.com,
  # otherwise the budget is created successfully and silently never publishes.
  ############################################################################
  BudgetAlertTopic:
    Type: AWS::SNS::Topic
    Properties:
      TopicName: finops-budget-alerts
      DisplayName: FinOps Budget Alerts
      Tags:
        - Key: cost-center
          Value: !Ref CostCenterTagValue
        - Key: environment
          Value: production

  BudgetAlertTopicPolicy:
    Type: AWS::SNS::TopicPolicy
    Properties:
      Topics:
        - !Ref BudgetAlertTopic
      PolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Sid: AllowBudgetsToPublish
            Effect: Allow
            Principal:
              Service: budgets.amazonaws.com
            Action: 'SNS:Publish'
            Resource: !Ref BudgetAlertTopic
            Condition:
              StringEquals:
                'aws:SourceAccount': !Ref 'AWS::AccountId'
              ArnLike:
                'aws:SourceArn': !Sub 'arn:${AWS::Partition}:budgets::${AWS::AccountId}:budget/*'
          - Sid: AllowCostAnomalyDetectionToPublish
            Effect: Allow
            Principal:
              Service: costalerts.amazonaws.com
            Action: 'SNS:Publish'
            Resource: !Ref BudgetAlertTopic

  BudgetAlertSubscription:
    Type: AWS::SNS::Subscription
    Properties:
      Protocol: email
      Endpoint: !Ref NotificationEmail
      TopicArn: !Ref BudgetAlertTopic

  ############################################################################
  # 1. Organization-wide monthly cost budget, tiered 50 / 80 / 100 actual
  #    plus a forecast alert. CostTypes is set EXPLICITLY: never rely on
  #    defaults, they differ between the console wizard and the API.
  ############################################################################
  MonthlyCostBudget:
    Type: AWS::Budgets::Budget
    Properties:
      Budget:
        BudgetName: org-monthly-unblended-cost
        BudgetType: COST
        TimeUnit: MONTHLY
        BudgetLimit:
          Amount: !Ref MonthlyCostLimitUsd
          Unit: USD
        CostTypes:
          IncludeCredit: false
          IncludeDiscount: true
          IncludeOtherSubscription: true
          IncludeRecurring: true
          IncludeRefund: false
          IncludeSubscription: true
          IncludeSupport: true
          IncludeTax: true
          IncludeUpfront: true
          UseAmortized: false
          UseBlended: false
      NotificationsWithSubscribers:
        - Notification:
            NotificationType: ACTUAL
            ComparisonOperator: GREATER_THAN
            Threshold: 50
            ThresholdType: PERCENTAGE
          Subscribers:
            - SubscriptionType: SNS
              Address: !Ref BudgetAlertTopic
        - Notification:
            NotificationType: ACTUAL
            ComparisonOperator: GREATER_THAN
            Threshold: 80
            ThresholdType: PERCENTAGE
          Subscribers:
            - SubscriptionType: SNS
              Address: !Ref BudgetAlertTopic
            - SubscriptionType: EMAIL
              Address: !Ref NotificationEmail
        - Notification:
            NotificationType: ACTUAL
            ComparisonOperator: GREATER_THAN
            Threshold: 100
            ThresholdType: PERCENTAGE
          Subscribers:
            - SubscriptionType: SNS
              Address: !Ref BudgetAlertTopic
            - SubscriptionType: EMAIL
              Address: !Ref NotificationEmail
        - Notification:
            NotificationType: FORECASTED
            ComparisonOperator: GREATER_THAN
            Threshold: 100
            ThresholdType: PERCENTAGE
          Subscribers:
            - SubscriptionType: SNS
              Address: !Ref BudgetAlertTopic

  ############################################################################
  # 2. Savings Plans utilization floor. If utilization drops below 95% we are
  #    paying for commitment we are not consuming.
  ############################################################################
  SavingsPlansUtilizationBudget:
    Type: AWS::Budgets::Budget
    Properties:
      Budget:
        BudgetName: savings-plans-utilization-floor
        BudgetType: SAVINGS_PLANS_UTILIZATION
        TimeUnit: MONTHLY
        BudgetLimit:
          Amount: 95
          Unit: PERCENTAGE
      NotificationsWithSubscribers:
        - Notification:
            NotificationType: ACTUAL
            ComparisonOperator: LESS_THAN
            Threshold: 95
            ThresholdType: PERCENTAGE
          Subscribers:
            - SubscriptionType: SNS
              Address: !Ref BudgetAlertTopic

  ############################################################################
  # 3. Per-team budget scoped by cost allocation tag. The tag key MUST already
  #    be ACTIVE in the management account or CostFilters silently matches
  #    nothing and the budget reports $0 forever.
  ############################################################################
  TeamScopedBudget:
    Type: AWS::Budgets::Budget
    Properties:
      Budget:
        BudgetName: !Sub 'team-${CostCenterTagValue}-monthly'
        BudgetType: COST
        TimeUnit: MONTHLY
        BudgetLimit:
          Amount: 8000
          Unit: USD
        CostFilters:
          TagKeyValue:
            - !Sub 'user:cost-center$${CostCenterTagValue}'
        CostTypes:
          IncludeCredit: false
          IncludeRefund: false
          IncludeSupport: false
          IncludeTax: false
          UseAmortized: true
          UseBlended: false
      NotificationsWithSubscribers:
        - Notification:
            NotificationType: ACTUAL
            ComparisonOperator: GREATER_THAN
            Threshold: 85
            ThresholdType: PERCENTAGE
          Subscribers:
            - SubscriptionType: SNS
              Address: !Ref BudgetAlertTopic

  ############################################################################
  # 4. Sandbox circuit breaker: a cost budget whose breach ATTACHES a deny
  #    policy. This is the only "auto-remediation" primitive in AWS Budgets.
  ############################################################################
  SandboxGuardrailPolicy:
    Type: AWS::IAM::ManagedPolicy
    Properties:
      ManagedPolicyName: SandboxBudgetBreachDenyExpensiveCompute
      Description: Attached by AWS Budgets when the sandbox budget is exceeded.
      PolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Sid: DenyLargeInstanceLaunch
            Effect: Deny
            Action:
              - 'ec2:RunInstances'
              - 'rds:CreateDBInstance'
              - 'sagemaker:CreateTrainingJob'
              - 'sagemaker:CreateEndpoint'
            Resource: '*'
          - Sid: DenyNewSpend
            Effect: Deny
            Action:
              - 'eks:CreateCluster'
              - 'emr:RunJobFlow'
              - 'redshift:CreateCluster'
            Resource: '*'

  BudgetActionExecutionRole:
    Type: AWS::IAM::Role
    Properties:
      RoleName: AWSBudgetsActionExecutionRole
      AssumeRolePolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Effect: Allow
            Principal:
              Service: budgets.amazonaws.com
            Action: 'sts:AssumeRole'
            Condition:
              StringEquals:
                'aws:SourceAccount': !Ref 'AWS::AccountId'
              ArnLike:
                'aws:SourceArn': !Sub 'arn:${AWS::Partition}:budgets::${AWS::AccountId}:budget/*'
      Policies:
        - PolicyName: AllowPolicyAttachment
          PolicyDocument:
            Version: '2012-10-17'
            Statement:
              - Effect: Allow
                Action:
                  - 'iam:AttachRolePolicy'
                  - 'iam:DetachRolePolicy'
                  - 'iam:AttachUserPolicy'
                  - 'iam:DetachUserPolicy'
                  - 'iam:AttachGroupPolicy'
                  - 'iam:DetachGroupPolicy'
                Resource: '*'
                Condition:
                  ArnEquals:
                    'iam:PolicyARN': !Ref SandboxGuardrailPolicy

  SandboxBudget:
    Type: AWS::Budgets::Budget
    Properties:
      Budget:
        BudgetName: sandbox-hard-stop
        BudgetType: COST
        TimeUnit: MONTHLY
        BudgetLimit:
          Amount: 1500
          Unit: USD
        CostFilters:
          LinkedAccount:
            - !Ref SandboxAccountId
        CostTypes:
          IncludeCredit: false
          IncludeRefund: false
          UseAmortized: false
          UseBlended: false
      NotificationsWithSubscribers:
        - Notification:
            NotificationType: ACTUAL
            ComparisonOperator: GREATER_THAN
            Threshold: 90
            ThresholdType: PERCENTAGE
          Subscribers:
            - SubscriptionType: SNS
              Address: !Ref BudgetAlertTopic

  SandboxBudgetAction:
    Type: AWS::Budgets::BudgetsAction
    Properties:
      BudgetName: !Ref SandboxBudget
      NotificationType: ACTUAL
      ActionType: APPLY_IAM_POLICY
      # AUTOMATIC applies without human intervention. Use MANUAL in production
      # until you have watched it not fire for a full billing cycle.
      ApprovalModel: AUTOMATIC
      ExecutionRoleArn: !GetAtt BudgetActionExecutionRole.Arn
      ActionThreshold:
        Type: ABSOLUTE_VALUE
        Value: 1500
      Definition:
        IamActionDefinition:
          PolicyArn: !Ref SandboxGuardrailPolicy
          Roles:
            - EngineerSandboxRole
      Subscribers:
        - Type: SNS
          Address: !Ref BudgetAlertTopic
        - Type: EMAIL
          Address: !Ref NotificationEmail

Outputs:
  BudgetAlertTopicArn:
    Description: SNS topic used by all budget notifications and anomaly subscriptions.
    Value: !Ref BudgetAlertTopic
    Export:
      Name: !Sub '${AWS::StackName}-BudgetAlertTopicArn'
  SandboxGuardrailPolicyArn:
    Description: Deny policy attached automatically on sandbox budget breach.
    Value: !Ref SandboxGuardrailPolicy
  BudgetActionExecutionRoleArn:
    Value: !GetAtt BudgetActionExecutionRole.Arn
```

Two details in that template are the difference between a working guardrail and a decorative one:

1. **`BudgetAlertTopicPolicy`** — a budget with an SNS subscriber is created successfully even when the topic rejects `budgets.amazonaws.com`. There is no error; alerts are simply dropped.
2. **`aws:SourceArn` / `aws:SourceAccount` conditions** on both the topic policy and the role trust policy — these close the confused-deputy hole that an unconditioned `Service: budgets.amazonaws.com` principal opens.

### 7.3 The same guardrails in Terraform

```hcl
terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.60"
    }
  }
}

variable "notification_email" {
  type = string
}

variable "monthly_cost_limit_usd" {
  type    = number
  default = 42000
}

variable "team_budgets" {
  description = "Per-team monthly ceilings, keyed by cost-center tag value."
  type        = map(number)
  default = {
    "CC-1001" = 8000
    "CC-1002" = 5500
    "CC-2100" = 12000
    "CC-3300" = 3000
  }
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

resource "aws_sns_topic" "budget_alerts" {
  name = "finops-budget-alerts"

  tags = {
    cost-center = "CC-1001"
    environment = "production"
  }
}

data "aws_iam_policy_document" "budget_alerts_topic" {
  statement {
    sid     = "AllowBudgetsToPublish"
    effect  = "Allow"
    actions = ["SNS:Publish"]
    resources = [aws_sns_topic.budget_alerts.arn]

    principals {
      type        = "Service"
      identifiers = ["budgets.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:${data.aws_partition.current.partition}:budgets::${data.aws_caller_identity.current.account_id}:budget/*"]
    }
  }

  statement {
    sid     = "AllowCostAnomalyDetectionToPublish"
    effect  = "Allow"
    actions = ["SNS:Publish"]
    resources = [aws_sns_topic.budget_alerts.arn]

    principals {
      type        = "Service"
      identifiers = ["costalerts.amazonaws.com"]
    }
  }
}

resource "aws_sns_topic_policy" "budget_alerts" {
  arn    = aws_sns_topic.budget_alerts.arn
  policy = data.aws_iam_policy_document.budget_alerts_topic.json
}

resource "aws_sns_topic_subscription" "budget_email" {
  topic_arn = aws_sns_topic.budget_alerts.arn
  protocol  = "email"
  endpoint  = var.notification_email
}

resource "aws_budgets_budget" "org_monthly" {
  name              = "org-monthly-unblended-cost"
  budget_type       = "COST"
  limit_amount      = var.monthly_cost_limit_usd
  limit_unit        = "USD"
  time_unit         = "MONTHLY"
  time_period_start = "2026-01-01_00:00"

  cost_types {
    include_credit             = false
    include_discount           = true
    include_other_subscription = true
    include_recurring          = true
    include_refund             = false
    include_subscription       = true
    include_support            = true
    include_tax                = true
    include_upfront            = true
    use_amortized              = false
    use_blended                = false
  }

  dynamic "notification" {
    for_each = [50, 80, 100]
    content {
      comparison_operator       = "GREATER_THAN"
      threshold                 = notification.value
      threshold_type            = "PERCENTAGE"
      notification_type         = "ACTUAL"
      subscriber_sns_topic_arns = [aws_sns_topic.budget_alerts.arn]
    }
  }

  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = 100
    threshold_type            = "PERCENTAGE"
    notification_type         = "FORECASTED"
    subscriber_sns_topic_arns = [aws_sns_topic.budget_alerts.arn]
  }
}

resource "aws_budgets_budget" "per_team" {
  for_each = var.team_budgets

  name              = "team-${each.key}-monthly"
  budget_type       = "COST"
  limit_amount      = each.value
  limit_unit        = "USD"
  time_unit         = "MONTHLY"
  time_period_start = "2026-01-01_00:00"

  cost_filter {
    name   = "TagKeyValue"
    values = ["user:cost-center$${each.key}"]
  }

  cost_types {
    include_credit  = false
    include_refund  = false
    include_support = false
    include_tax     = false
    use_amortized   = true
    use_blended     = false
  }

  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = 85
    threshold_type            = "PERCENTAGE"
    notification_type         = "ACTUAL"
    subscriber_sns_topic_arns = [aws_sns_topic.budget_alerts.arn]
  }

  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = 100
    threshold_type            = "PERCENTAGE"
    notification_type         = "FORECASTED"
    subscriber_sns_topic_arns = [aws_sns_topic.budget_alerts.arn]
  }
}

resource "aws_budgets_budget" "sp_utilization" {
  name         = "savings-plans-utilization-floor"
  budget_type  = "SAVINGS_PLANS_UTILIZATION"
  limit_amount = 95
  limit_unit   = "PERCENTAGE"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator       = "LESS_THAN"
    threshold                 = 95
    threshold_type            = "PERCENTAGE"
    notification_type         = "ACTUAL"
    subscriber_sns_topic_arns = [aws_sns_topic.budget_alerts.arn]
  }
}

output "budget_alert_topic_arn" {
  value = aws_sns_topic.budget_alerts.arn
}
```

---

## 8. Cost and Usage Report: the only complete dataset

Cost Explorer is a query surface over an aggregation. The **CUR** is the raw ledger: one row per resource, per usage type, per hour, with your tag columns joined in. Everything a serious FinOps practice does — unit economics, blast-radius analysis of a commitment purchase, chargeback that survives an audit — is built here.

**CUR 2.0 (delivered through AWS Data Exports)** is the current generation. It normalizes the schema, uses `map`-typed columns instead of hundreds of sparse columns, and supports SQL-based column selection at export time.

### 8.1 Complete CloudFormation: S3 bucket + policy + CUR 2.0 export + Athena

```yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: >
  CUR 2.0 data export via AWS Data Exports, delivered to a hardened S3 bucket,
  catalogued in Glue and queryable from Athena. Deploy in us-east-1 in the
  management (payer) account.

Parameters:
  ReportBucketName:
    Type: String
    Description: Globally unique bucket name for CUR delivery.
  ExportName:
    Type: String
    Default: org-cur2-hourly
  GlueDatabaseName:
    Type: String
    Default: cur_analytics

Conditions:
  IsUsEast1: !Equals [!Ref 'AWS::Region', 'us-east-1']

Resources:

  ############################################################################
  # Delivery bucket. NOTE: default encryption is SSE-S3 (AES256) on purpose.
  # A bucket whose default encryption is SSE-KMS is the single most common
  # cause of a CUR that is created successfully and never delivers a file.
  ############################################################################
  ReportBucket:
    Type: AWS::S3::Bucket
    DeletionPolicy: Retain
    UpdateReplacePolicy: Retain
    Properties:
      BucketName: !Ref ReportBucketName
      BucketEncryption:
        ServerSideEncryptionConfiguration:
          - ServerSideEncryptionByDefault:
              SSEAlgorithm: AES256
            BucketKeyEnabled: true
      PublicAccessBlockConfiguration:
        BlockPublicAcls: true
        BlockPublicPolicy: true
        IgnorePublicAcls: true
        RestrictPublicBuckets: true
      VersioningConfiguration:
        Status: Enabled
      OwnershipControls:
        Rules:
          - ObjectOwnership: BucketOwnerEnforced
      LifecycleConfiguration:
        Rules:
          - Id: TransitionOldPartitionsToIA
            Status: Enabled
            Prefix: cur2/
            Transitions:
              - StorageClass: STANDARD_IA
                TransitionInDays: 90
              - StorageClass: GLACIER_IR
                TransitionInDays: 365
          - Id: ExpireNoncurrentVersions
            Status: Enabled
            NoncurrentVersionExpiration:
              NoncurrentDays: 30
      Tags:
        - Key: cost-center
          Value: CC-1001
        - Key: environment
          Value: production

  ############################################################################
  # Both service principals are required for Data Exports: the legacy billing
  # reports principal AND the BCM data exports principal.
  ############################################################################
  ReportBucketPolicy:
    Type: AWS::S3::BucketPolicy
    Properties:
      Bucket: !Ref ReportBucket
      PolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Sid: AllowBillingReportsRead
            Effect: Allow
            Principal:
              Service: billingreports.amazonaws.com
            Action:
              - 's3:GetBucketAcl'
              - 's3:GetBucketPolicy'
            Resource: !GetAtt ReportBucket.Arn
            Condition:
              StringEquals:
                'aws:SourceAccount': !Ref 'AWS::AccountId'
              ArnLike:
                'aws:SourceArn': !Sub 'arn:${AWS::Partition}:cur:us-east-1:${AWS::AccountId}:definition/*'
          - Sid: AllowBillingReportsWrite
            Effect: Allow
            Principal:
              Service: billingreports.amazonaws.com
            Action: 's3:PutObject'
            Resource: !Sub '${ReportBucket.Arn}/*'
            Condition:
              StringEquals:
                'aws:SourceAccount': !Ref 'AWS::AccountId'
              ArnLike:
                'aws:SourceArn': !Sub 'arn:${AWS::Partition}:cur:us-east-1:${AWS::AccountId}:definition/*'
          - Sid: AllowDataExportsRead
            Effect: Allow
            Principal:
              Service: bcm-data-exports.amazonaws.com
            Action:
              - 's3:GetBucketAcl'
              - 's3:GetBucketPolicy'
            Resource: !GetAtt ReportBucket.Arn
            Condition:
              StringEquals:
                'aws:SourceAccount': !Ref 'AWS::AccountId'
              ArnLike:
                'aws:SourceArn': !Sub 'arn:${AWS::Partition}:bcm-data-exports:us-east-1:${AWS::AccountId}:export/*'
          - Sid: AllowDataExportsWrite
            Effect: Allow
            Principal:
              Service: bcm-data-exports.amazonaws.com
            Action: 's3:PutObject'
            Resource: !Sub '${ReportBucket.Arn}/*'
            Condition:
              StringEquals:
                'aws:SourceAccount': !Ref 'AWS::AccountId'
              ArnLike:
                'aws:SourceArn': !Sub 'arn:${AWS::Partition}:bcm-data-exports:us-east-1:${AWS::AccountId}:export/*'
          - Sid: DenyInsecureTransport
            Effect: Deny
            Principal: '*'
            Action: 's3:*'
            Resource:
              - !GetAtt ReportBucket.Arn
              - !Sub '${ReportBucket.Arn}/*'
            Condition:
              Bool:
                'aws:SecureTransport': 'false'

  ############################################################################
  # Legacy CUR definition, retained because Split Cost Allocation Data for EKS
  # and the RESOURCES schema element are configured here. AdditionalSchemaElements
  # is where the expensive-but-essential columns are switched on.
  ############################################################################
  LegacyCurDefinition:
    Type: AWS::CUR::ReportDefinition
    Condition: IsUsEast1
    DependsOn: ReportBucketPolicy
    Properties:
      ReportName: org-legacy-cur-hourly
      TimeUnit: HOURLY
      Format: Parquet
      Compression: Parquet
      AdditionalSchemaElements:
        - RESOURCES
        - SPLIT_COST_ALLOCATION_DATA
        - MANUAL_DISCOUNT_COMPATIBILITY
      S3Bucket: !Ref ReportBucket
      S3Prefix: legacy-cur/
      S3Region: us-east-1
      AdditionalArtifacts:
        - ATHENA
      RefreshClosedReports: true
      ReportVersioning: OVERWRITE_REPORT

  ############################################################################
  # Glue catalog for Athena. In production the partition projection below
  # avoids running a crawler on every refresh.
  ############################################################################
  CurGlueDatabase:
    Type: AWS::Glue::Database
    Properties:
      CatalogId: !Ref 'AWS::AccountId'
      DatabaseInput:
        Name: !Ref GlueDatabaseName
        Description: Cost and Usage Report analytics database.

  AthenaResultsBucket:
    Type: AWS::S3::Bucket
    Properties:
      BucketEncryption:
        ServerSideEncryptionConfiguration:
          - ServerSideEncryptionByDefault:
              SSEAlgorithm: AES256
      PublicAccessBlockConfiguration:
        BlockPublicAcls: true
        BlockPublicPolicy: true
        IgnorePublicAcls: true
        RestrictPublicBuckets: true
      LifecycleConfiguration:
        Rules:
          - Id: ExpireQueryResults
            Status: Enabled
            ExpirationInDays: 14

  CurAthenaWorkGroup:
    Type: AWS::Athena::WorkGroup
    Properties:
      Name: finops-cur
      State: ENABLED
      WorkGroupConfiguration:
        EnforceWorkGroupConfiguration: true
        PublishCloudWatchMetricsEnabled: true
        # Hard ceiling: a single unpartitioned SELECT * over a year of CUR
        # can scan multiple TB. This caps the blast radius at ~100 GB.
        BytesScannedCutoffPerQuery: 107374182400
        ResultConfiguration:
          OutputLocation: !Sub 's3://${AthenaResultsBucket}/query-results/'
          EncryptionConfiguration:
            EncryptionOption: SSE_S3

Outputs:
  ReportBucketArn:
    Value: !GetAtt ReportBucket.Arn
  GlueDatabase:
    Value: !Ref CurGlueDatabase
  AthenaWorkGroup:
    Value: !Ref CurAthenaWorkGroup
```

### 8.2 Creating the CUR 2.0 export from the CLI

CUR 2.0 exports are defined with a SQL-like column selection. This is the create call and its response:

```console
$ cat cur2-export.json
{
  "Export": {
    "Name": "org-cur2-hourly",
    "Description": "Hourly CUR 2.0 with resource IDs and split cost allocation.",
    "DataQuery": {
      "QueryStatement": "SELECT bill_billing_period_start_date, bill_payer_account_id, line_item_usage_account_id, line_item_usage_start_date, line_item_line_item_type, line_item_product_code, line_item_usage_type, line_item_operation, line_item_resource_id, line_item_usage_amount, line_item_unblended_cost, line_item_net_unblended_cost, product, product_servicecode, product_region_code, pricing_term, pricing_unit, reservation_effective_cost, reservation_unused_amortized_upfront_fee_for_billing_period, reservation_unused_recurring_fee, savings_plan_savings_plan_effective_cost, savings_plan_total_commitment_to_date, savings_plan_used_commitment, resource_tags, cost_category, split_line_item_parent_resource_id, split_line_item_split_cost, split_line_item_unused_cost FROM COST_AND_USAGE_REPORT",
      "TableConfigurations": {
        "COST_AND_USAGE_REPORT": {
          "TIME_GRANULARITY": "HOURLY",
          "INCLUDE_RESOURCES": "TRUE",
          "INCLUDE_SPLIT_COST_ALLOCATION_DATA": "TRUE",
          "INCLUDE_MANUAL_DISCOUNT_COMPATIBILITY": "FALSE"
        }
      }
    },
    "DestinationConfigurations": {
      "S3Destination": {
        "S3Bucket": "acme-finops-cur-111122223333",
        "S3Prefix": "cur2",
        "S3Region": "us-east-1",
        "S3OutputConfigurations": {
          "OutputType": "CUSTOM",
          "Format": "PARQUET",
          "Compression": "PARQUET",
          "Overwrite": "OVERWRITE_REPORT"
        }
      }
    },
    "RefreshCadence": {
      "Frequency": "SYNCHRONOUS"
    }
  }
}

$ aws bcm-data-exports create-export --region us-east-1 --cli-input-json file://cur2-export.json
{
    "ExportArn": "arn:aws:bcm-data-exports:us-east-1:111122223333:export/org-cur2-hourly-9d3a1f5c"
}

$ aws bcm-data-exports list-exports --region us-east-1
{
    "Exports": [
        {
            "ExportArn": "arn:aws:bcm-data-exports:us-east-1:111122223333:export/org-cur2-hourly-9d3a1f5c",
            "ExportName": "org-cur2-hourly",
            "ExportStatus": {
                "StatusCode": "HEALTHY",
                "CreatedAt": "2026-09-02T14:03:11.442000+00:00",
                "LastUpdatedAt": "2026-09-04T06:11:52.008000+00:00",
                "LastRefreshedAt": "2026-09-04T06:11:52.008000+00:00"
            }
        }
    ]
}
```

`"StatusCode": "HEALTHY"` with a recent `LastRefreshedAt` is the only proof the pipeline works. A status of `UNHEALTHY` almost always points at the bucket policy.

### 8.3 Athena: the queries that matter

**Amortized cost, the canonical formula.** Cost Explorer computes this for you; in CUR you must express it, and every FinOps dashboard that gets amortization wrong gets it wrong here:

```sql
CREATE OR REPLACE VIEW cur_analytics.v_amortized AS
SELECT
    bill_billing_period_start_date                       AS billing_period,
    line_item_usage_start_date                           AS usage_hour,
    line_item_usage_account_id                           AS account_id,
    product_servicecode                                  AS service,
    product_region_code                                  AS region,
    line_item_resource_id                                AS resource_id,
    line_item_line_item_type                             AS line_item_type,
    resource_tags['cost_center']                         AS cost_center,
    resource_tags['team']                                AS team,
    resource_tags['environment']                         AS environment,
    cost_category['BusinessUnit']                        AS business_unit,
    line_item_unblended_cost                             AS unblended_cost,
    CASE
        WHEN line_item_line_item_type = 'SavingsPlanCoveredUsage'
             THEN savings_plan_savings_plan_effective_cost
        WHEN line_item_line_item_type = 'SavingsPlanRecurringFee'
             THEN savings_plan_total_commitment_to_date - savings_plan_used_commitment
        WHEN line_item_line_item_type = 'SavingsPlanNegation'   THEN 0
        WHEN line_item_line_item_type = 'SavingsPlanUpfrontFee' THEN 0
        WHEN line_item_line_item_type = 'DiscountedUsage'
             THEN reservation_effective_cost
        WHEN line_item_line_item_type = 'RIFee'
             THEN reservation_unused_amortized_upfront_fee_for_billing_period
                  + reservation_unused_recurring_fee
        WHEN line_item_line_item_type = 'Fee'
             AND reservation_reservation_arn <> '' THEN 0
        ELSE line_item_unblended_cost
    END                                                  AS amortized_cost
FROM cur_analytics.org_cur2_hourly
WHERE line_item_line_item_type NOT IN ('Tax', 'Refund', 'Credit');
```

**Untagged spend — the number that justifies the whole tagging program:**

```sql
SELECT
    product_servicecode                                   AS service,
    line_item_usage_account_id                            AS account_id,
    SUM(line_item_unblended_cost)                         AS untagged_usd
FROM cur_analytics.org_cur2_hourly
WHERE bill_billing_period_start_date = DATE '2026-08-01'
  AND line_item_line_item_type = 'Usage'
  AND (resource_tags['cost_center'] IS NULL OR resource_tags['cost_center'] = '')
GROUP BY 1, 2
HAVING SUM(line_item_unblended_cost) > 100
ORDER BY untagged_usd DESC
LIMIT 25;
```

```console
$ aws athena start-query-execution \
    --work-group finops-cur \
    --query-string "$(cat untagged.sql)" \
    --query-execution-context Database=cur_analytics
{
    "QueryExecutionId": "b7c1f4de-2a08-4c3d-9f21-6e0a7b5c2d19"
}

$ aws athena get-query-results --query-execution-id b7c1f4de-2a08-4c3d-9f21-6e0a7b5c2d19 \
    --query 'ResultSet.Rows[1:6].Data[*].VarCharValue' --output text
AmazonEC2       222233334444    9142.7712
AWSDataTransfer 222233334444    4877.1093
AmazonS3        333344445555    3011.9820
AmazonRDS       444455556666    1204.5511
AWSLambda       222233334444     388.2077
```

**Per-pod cost on EKS, via split cost allocation data.** Enabling `SPLIT_COST_ALLOCATION_DATA` makes AWS attribute the EC2/Fargate cost of a node down to individual pods, using the ratio of requested-vs-used CPU and memory, and it surfaces AWS-generated tags `aws:eks:namespace`, `aws:eks:workload-name`, `aws:eks:workload-type` and `aws:eks:node`:

```sql
SELECT
    resource_tags['aws_eks_cluster_name']                 AS cluster,
    resource_tags['aws_eks_namespace']                    AS namespace,
    resource_tags['aws_eks_workload_type']                AS workload_type,
    resource_tags['aws_eks_workload_name']                AS workload,
    SUM(split_line_item_split_cost)                       AS attributed_usd,
    SUM(split_line_item_unused_cost)                      AS unused_capacity_usd,
    SUM(split_line_item_split_cost)
      / NULLIF(SUM(split_line_item_split_cost)
               + SUM(split_line_item_unused_cost), 0)     AS packing_efficiency
FROM cur_analytics.org_cur2_hourly
WHERE bill_billing_period_start_date = DATE '2026-08-01'
  AND split_line_item_parent_resource_id IS NOT NULL
GROUP BY 1, 2, 3, 4
ORDER BY attributed_usd DESC
LIMIT 20;
```

`packing_efficiency` below ~0.5 means you are paying for a fleet that is half idle — usually because pod `requests` are set far above real consumption. That is a Kubernetes scheduling defect surfaced by the billing pipeline.

For sub-hour, in-cluster attribution the AWS-native data is too coarse; pair it with **OpenCost** running in-cluster:

```yaml
# values-opencost.yaml — OpenCost on EKS, reconciling in-cluster allocation
# against the authoritative AWS CUR so that showback matches the invoice.
apiVersion: v1
kind: ConfigMap
metadata:
  name: opencost-cur-config
  namespace: opencost
data:
  athenaBucketName: "s3://acme-finops-cur-111122223333"
  athenaRegion: "us-east-1"
  athenaDatabase: "cur_analytics"
  athenaTable: "org_cur2_hourly"
  athenaWorkgroup: "finops-cur"
  projectID: "111122223333"
---
opencost:
  exporter:
    defaultClusterId: prod-eks-euw1
    extraEnv:
      CLOUD_PROVIDER_API_KEY: ""
      CLUSTER_PROFILE: production
      # Reconcile in-cluster estimates with real CUR line items nightly.
      ETL_ENABLED: "true"
      CLOUD_COST_ENABLED: "true"
    resources:
      requests:
        cpu: 100m
        memory: 256Mi
      limits:
        memory: 1Gi
  cloudIntegrationSecret: opencost-cloud-integration
  prometheus:
    internal:
      enabled: false
    external:
      enabled: true
      url: "http://prometheus-server.monitoring.svc.cluster.local:80"
  serviceAccount:
    create: true
    annotations:
      eks.amazonaws.com/role-arn: arn:aws:iam::111122223333:role/OpenCostCurReader
```

The IRSA role `OpenCostCurReader` needs only `athena:StartQueryExecution`, `athena:GetQueryResults`, `glue:GetTable`, `s3:GetObject` on the CUR prefix and `s3:PutObject` on the Athena results prefix. **Nothing in-cluster should ever hold `ce:*` — the Cost Explorer API bills per request and a crash-looping pod will happily generate thousands.**

---

## 9. Cost Anomaly Detection: the ML layer

Budgets answer "am I above a line I drew?". Anomaly Detection answers "did the shape of my spend change?" — which catches the failures you did not think to draw a line around. It is **free**, it learns a per-monitor baseline, and it evaluates daily.

```yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: Cost Anomaly Detection monitors and subscriptions.

Parameters:
  AlertTopicArn:
    Type: String
  FinOpsEmail:
    Type: String

Resources:

  # Monitor 1: every AWS service, dimension-based. The broadest useful net.
  ServiceMonitor:
    Type: AWS::CE::AnomalyMonitor
    Properties:
      MonitorName: all-services
      MonitorType: DIMENSIONAL
      MonitorDimension: SERVICE

  # Monitor 2: per business unit, driven by the cost category built earlier.
  BusinessUnitMonitor:
    Type: AWS::CE::AnomalyMonitor
    Properties:
      MonitorName: by-business-unit
      MonitorType: CUSTOM
      MonitorSpecification: >-
        {
          "CostCategories": {
            "Key": "BusinessUnit",
            "Values": ["Payments", "DataPlatform", "PlatformSharedServices"]
          }
        }

  # Monitor 3: the sandbox account, where surprises are most likely.
  SandboxMonitor:
    Type: AWS::CE::AnomalyMonitor
    Properties:
      MonitorName: sandbox-account
      MonitorType: CUSTOM
      MonitorSpecification: >-
        {
          "Dimensions": {
            "Key": "LINKED_ACCOUNT",
            "Values": ["555566667777"]
          }
        }

  # High-signal subscription: page immediately when total impact > $500.
  ImmediateHighImpactSubscription:
    Type: AWS::CE::AnomalySubscription
    Properties:
      SubscriptionName: high-impact-immediate
      Frequency: IMMEDIATE
      MonitorArnList:
        - !Ref ServiceMonitor
        - !Ref BusinessUnitMonitor
        - !Ref SandboxMonitor
      Subscribers:
        - Type: SNS
          Address: !Ref AlertTopicArn
      # ThresholdExpression replaces the deprecated scalar Threshold and lets
      # you combine absolute impact with a percentage deviation.
      ThresholdExpression: >-
        {
          "And": [
            {
              "Dimensions": {
                "Key": "ANOMALY_TOTAL_IMPACT_ABSOLUTE",
                "MatchOptions": ["GREATER_THAN_OR_EQUAL"],
                "Values": ["500"]
              }
            },
            {
              "Dimensions": {
                "Key": "ANOMALY_TOTAL_IMPACT_PERCENTAGE",
                "MatchOptions": ["GREATER_THAN_OR_EQUAL"],
                "Values": ["30"]
              }
            }
          ]
        }

  # Low-signal digest: everything else, once a day, to a mailbox not a pager.
  DailyDigestSubscription:
    Type: AWS::CE::AnomalySubscription
    Properties:
      SubscriptionName: daily-digest
      Frequency: DAILY
      MonitorArnList:
        - !Ref ServiceMonitor
      Subscribers:
        - Type: EMAIL
          Address: !Ref FinOpsEmail
      ThresholdExpression: >-
        {
          "Dimensions": {
            "Key": "ANOMALY_TOTAL_IMPACT_ABSOLUTE",
            "MatchOptions": ["GREATER_THAN_OR_EQUAL"],
            "Values": ["100"]
          }
        }

Outputs:
  ServiceMonitorArn:
    Value: !Ref ServiceMonitor
  BusinessUnitMonitorArn:
    Value: !Ref BusinessUnitMonitor
```

The `And` of absolute dollars **and** percentage deviation is the alert-fatigue fix: a $600 anomaly on a $2M monthly bill is noise; a $600 anomaly that is 300% of the baseline for that service is a bug.

Reading an anomaly like an incident:

```console
$ aws ce get-anomalies \
    --date-interval StartDate=2026-08-25,EndDate=2026-09-04 \
    --total-impact NumericOperator=GREATER_THAN,StartValue=500 \
    --output json
{
    "Anomalies": [
        {
            "AnomalyId": "a1d9f77c-3b52-4b8e-9f01-27c4d5b6e8a3",
            "AnomalyStartDate": "2026-08-28T00:00:00Z",
            "AnomalyEndDate": "2026-08-31T00:00:00Z",
            "DimensionValue": "AmazonCloudWatch",
            "RootCauses": [
                {
                    "Service": "AmazonCloudWatch",
                    "Region": "eu-west-1",
                    "LinkedAccount": "222233334444",
                    "LinkedAccountName": "prod-platform",
                    "UsageType": "EUW1-DataProcessing-Bytes"
                }
            ],
            "AnomalyScore": {
                "MaxScore": 0.87,
                "CurrentScore": 0.71
            },
            "Impact": {
                "MaxImpact": 1842.31,
                "TotalImpact": 4120.55,
                "TotalActualSpend": 5980.12,
                "TotalExpectedSpend": 1859.57,
                "TotalImpactPercentage": 221.59
            },
            "MonitorArn": "arn:aws:ce::111122223333:anomalymonitor/3f1c8e22-9a7d-4c11-b0e6-51ab2d7f9c40",
            "Feedback": "YES"
        }
    ],
    "NextPageToken": null
}
```

`UsageType: EUW1-DataProcessing-Bytes` on CloudWatch names the cause precisely: log ingestion volume, in Ireland, in `prod-platform`. Expected $1,859 → actual $5,980. The next step is `aws logs describe-log-groups --query 'logGroups | sort_by(@, &storedBytes) | reverse(@)[:5]'`, not a conversation with finance.

Always send `put-anomaly-feedback` — the model uses it:

```console
$ aws ce provide-anomaly-feedback \
    --anomaly-id a1d9f77c-3b52-4b8e-9f01-27c4d5b6e8a3 \
    --feedback YES
{
    "AnomalyId": "a1d9f77c-3b52-4b8e-9f01-27c4d5b6e8a3"
}
```

---

## 10. Purchase options and commitment instruments

Cost management is not only observation; the largest lever is *how* you buy compute. The exam tests recognition of these options and their trade-offs.

| Option | Discount vs On-Demand | Commitment | Flexibility | Interruption risk | Best for |
|---|---|---|---|---|---|
| **On-Demand** | baseline | none | total | none | Spiky, unpredictable, short-lived workloads |
| **Spot Instances** | up to ~90% | none | any instance type | **2-minute interruption notice** | Fault-tolerant batch, CI, stateless workers, big-data |
| **Compute Savings Plans** | up to ~66% | $/hour for 1 or 3 years | **Any region, family, size, OS, tenancy; EC2 + Fargate + Lambda** | none | Default choice for most organizations |
| **EC2 Instance Savings Plans** | up to ~72% | $/hour, 1 or 3 years, **locked to a family in a region** | Size/OS/tenancy flexible within that family | none | Stable, well-known steady-state fleets |
| **SageMaker Savings Plans** | up to ~64% | $/hour, 1 or 3 years | SageMaker instance families/regions | none | ML platforms |
| **Standard Reserved Instances** | up to ~72% | Instance attributes, 1 or 3 years | Size-flexible within family (Linux/shared); **sellable on the RI Marketplace** | none | Stable workloads where marketplace exit matters |
| **Convertible RIs** | up to ~54% | 1 or 3 years | Exchangeable for different family/OS/tenancy | none | Long horizon, uncertain instance mix |
| **Capacity Reservations** | **no discount** | none (billed as On-Demand while active) | Reserve capacity in a specific AZ | none | Guaranteed capacity for DR/failover; combine with an SP for the discount |
| **Dedicated Hosts** | varies; supports BYOL | On-Demand or reserved | Physical server, visible sockets/cores | none | Licence compliance (Windows Server, Oracle, SQL Server) |
| **Dedicated Instances** | premium | On-Demand or reserved | Isolated hardware, no socket visibility | none | Regulatory isolation without licence needs |

**Payment options** (RIs and Savings Plans): **All Upfront** (largest discount) > **Partial Upfront** > **No Upfront** (smallest discount, no capital outlay).

Two mistakes to internalize:

1. **A Capacity Reservation is not a discount.** It reserves capacity and bills On-Demand rates whether or not you run instances in it. Pair it with a Savings Plan if you want both guarantees.
2. **Savings Plans and RIs are billing constructs, not capacity guarantees.** Buying an SP does not reserve anything; only a Zonal RI or a Capacity Reservation does.

Getting a recommendation before committing:

```console
$ aws ce get-savings-plans-purchase-recommendation \
    --savings-plans-type COMPUTE_SP \
    --term-in-years ONE_YEAR \
    --payment-option NO_UPFRONT \
    --lookback-period-in-days SIXTY_DAYS \
    --query 'SavingsPlansPurchaseRecommendation.SavingsPlansPurchaseRecommendationSummary'
{
    "EstimatedROI": "38.42",
    "CurrencyCode": "USD",
    "EstimatedTotalCost": "412880.11",
    "CurrentOnDemandSpend": "596441.72",
    "EstimatedSavingsAmount": "183561.61",
    "TotalRecommendationCount": "1",
    "DailyCommitmentToPurchase": "1131.18",
    "HourlyCommitmentToPurchase": "47.13",
    "EstimatedSavingsPercentage": "30.77",
    "EstimatedMonthlySavingsAmount": "15296.80",
    "EstimatedOnDemandCostWithCurrentCommitment": "596441.72"
}

$ aws ce get-savings-plans-utilization \
    --time-period Start=2026-08-01,End=2026-09-01 \
    --granularity MONTHLY
{
    "SavingsPlansUtilizationsByTime": [
        {
            "TimePeriod": {"Start": "2026-08-01", "End": "2026-09-01"},
            "Utilization": {
                "TotalCommitment": "35064.72",
                "UsedCommitment": "34210.09",
                "UnusedCommitment": "854.63",
                "UtilizationPercentage": "97.56"
            },
            "Savings": {
                "NetSavings": "11842.30",
                "OnDemandCostEquivalent": "46052.39"
            },
            "AmortizedCommitment": {
                "AmortizedRecurringCommitment": "35064.72",
                "AmortizedUpfrontCommitment": "0",
                "TotalAmortizedCommitment": "35064.72"
            }
        }
    ],
    "Total": { "...": "..." }
}
```

`UtilizationPercentage: 97.56` is healthy. Anything under ~90% sustained means you over-committed and are burning money on unused commitment — exactly the condition the `SAVINGS_PLANS_UTILIZATION` budget in §7.2 was built to catch.

**Cost Optimization Hub** aggregates and deduplicates recommendations from Compute Optimizer, Cost Explorer and idle-resource detection into a single ranked list, expressed in *your* discount-adjusted terms:

```console
$ aws cost-optimization-hub list-recommendations \
    --filter '{"actionTypes":["Rightsize","Stop","Delete"]}' \
    --order-by '{"dimension":"EstimatedMonthlySavings","order":"Desc"}' \
    --max-results 4
{
    "items": [
        {
            "recommendationId": "1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d",
            "accountId": "222233334444",
            "region": "eu-west-1",
            "resourceId": "i-0fa71c8e2b9d43a10",
            "resourceArn": "arn:aws:ec2:eu-west-1:222233334444:instance/i-0fa71c8e2b9d43a10",
            "currentResourceType": "Ec2Instance",
            "recommendedResourceType": "Ec2Instance",
            "estimatedMonthlySavings": 1284.40,
            "estimatedSavingsPercentage": 62.0,
            "estimatedMonthlyCost": 2071.61,
            "currencyCode": "USD",
            "implementationEffort": "Medium",
            "restartNeeded": true,
            "actionType": "Rightsize",
            "rollbackPossible": true,
            "source": "ComputeOptimizer",
            "lastRefreshTimestamp": "2026-09-04T03:22:10+00:00",
            "tags": [{"key": "cost-center", "value": "CC-1001"}]
        },
        {
            "recommendationId": "2b3c4d5e-6f7a-4b8c-9d0e-1f2a3b4c5d6e",
            "accountId": "333344445555",
            "region": "eu-west-1",
            "resourceId": "vol-08c1d92f3ba74e6f1",
            "currentResourceType": "EbsVolume",
            "recommendedResourceType": "EbsVolume",
            "estimatedMonthlySavings": 612.09,
            "estimatedSavingsPercentage": 44.0,
            "implementationEffort": "VeryLow",
            "restartNeeded": false,
            "actionType": "Rightsize",
            "rollbackPossible": true,
            "source": "ComputeOptimizer",
            "lastRefreshTimestamp": "2026-09-04T03:22:10+00:00"
        },
        {
            "recommendationId": "3c4d5e6f-7a8b-4c9d-0e1f-2a3b4c5d6e7f",
            "accountId": "555566667777",
            "region": "us-east-1",
            "resourceId": "i-0b2c9e7f1a4d83b62",
            "currentResourceType": "Ec2Instance",
            "estimatedMonthlySavings": 498.22,
            "estimatedSavingsPercentage": 100.0,
            "implementationEffort": "VeryLow",
            "restartNeeded": false,
            "actionType": "Stop",
            "rollbackPossible": true,
            "source": "CostExplorer",
            "lastRefreshTimestamp": "2026-09-04T03:22:10+00:00"
        },
        {
            "recommendationId": "4d5e6f7a-8b9c-4d0e-1f2a-3b4c5d6e7f80",
            "accountId": "222233334444",
            "region": "eu-west-1",
            "resourceId": "eipalloc-0d41f8b7c9e2a6503",
            "currentResourceType": "Ec2AutoScalingGroup",
            "estimatedMonthlySavings": 87.60,
            "estimatedSavingsPercentage": 100.0,
            "implementationEffort": "VeryLow",
            "restartNeeded": false,
            "actionType": "Delete",
            "rollbackPossible": false,
            "source": "CostExplorer",
            "lastRefreshTimestamp": "2026-09-04T03:22:10+00:00"
        }
    ]
}
```

Prioritize by `estimatedMonthlySavings / implementationEffort`, and treat `restartNeeded: true` as a change that needs a maintenance window — the "$1,284/month" number is only real if the change actually ships.

---

## 11. IAM and access control for billing data

Billing permissions are a distinct surface with two gates that catch every team once.

**Gate 1 — the account-level switch.** In the management account, the root user must enable *IAM user and role access to Billing information*. Until that is on, **no** IAM policy grants access to the Billing console, no matter how permissive.

**Gate 2 — the IAM policy.** AWS replaced the coarse legacy `aws-portal:*` actions with fine-grained services. Policies written against the old actions no longer work.

| Concern | Fine-grained actions (current) | Legacy (deprecated) |
|---|---|---|
| View bills & billing console | `billing:GetBillingData`, `billing:GetBillingDetails`, `billing:GetBillingNotifications` | `aws-portal:ViewBilling` |
| Cost Explorer | `ce:GetCostAndUsage`, `ce:GetCostForecast`, `ce:GetDimensionValues`, `ce:GetTags` | — |
| Budgets | `budgets:ViewBudget`, `budgets:ModifyBudget`, `budgets:DescribeBudgetAction` | `aws-portal:ViewBudget` |
| CUR / Data Exports | `cur:DescribeReportDefinitions`, `bcm-data-exports:GetExport` | — |
| Payment methods | `payments:ListPaymentMethods`, `payments:UpdatePaymentMethods` | `aws-portal:ViewPaymentMethods` |
| Account settings | `account:GetAccountInformation`, `account:GetContactInformation` | `aws-portal:ViewAccount` |
| Tax settings | `tax:GetTaxRegistration`, `tax:UpdateTaxRegistration` | — |
| Free Tier usage | `freetier:GetFreeTierUsage` | — |
| Consolidated billing | `consolidatedbilling:GetAccountBillingRole`, `consolidatedbilling:ListLinkedAccounts` | — |
| Invoices | `invoicing:GetInvoicePDF`, `invoicing:ListInvoiceSummaries` | — |

A read-only FinOps role — note the explicit deny on the metered Cost Explorer calls being *absent*, and instead a permission boundary you should pair with rate limiting at the application layer:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "BillingConsoleReadOnly",
      "Effect": "Allow",
      "Action": [
        "billing:Get*",
        "billing:List*",
        "consolidatedbilling:Get*",
        "consolidatedbilling:List*",
        "invoicing:Get*",
        "invoicing:List*",
        "account:GetAccountInformation",
        "account:GetContactInformation",
        "freetier:Get*",
        "tax:Get*",
        "tax:List*"
      ],
      "Resource": "*"
    },
    {
      "Sid": "CostExplorerReadOnly",
      "Effect": "Allow",
      "Action": [
        "ce:Describe*",
        "ce:Get*",
        "ce:List*"
      ],
      "Resource": "*"
    },
    {
      "Sid": "BudgetsAndReportsReadOnly",
      "Effect": "Allow",
      "Action": [
        "budgets:Describe*",
        "budgets:View*",
        "cur:DescribeReportDefinitions",
        "bcm-data-exports:GetExport",
        "bcm-data-exports:ListExports",
        "cost-optimization-hub:GetRecommendation",
        "cost-optimization-hub:ListRecommendations",
        "cost-optimization-hub:ListRecommendationSummaries",
        "compute-optimizer:Get*",
        "compute-optimizer:Describe*",
        "pricing:GetProducts",
        "pricing:DescribeServices",
        "pricing:GetAttributeValues"
      ],
      "Resource": "*"
    },
    {
      "Sid": "DenyAnyMutation",
      "Effect": "Deny",
      "Action": [
        "budgets:ModifyBudget",
        "budgets:DeleteBudget",
        "ce:CreateCostCategoryDefinition",
        "ce:UpdateCostCategoryDefinition",
        "ce:DeleteCostCategoryDefinition",
        "ce:UpdateCostAllocationTagsStatus",
        "cur:PutReportDefinition",
        "cur:DeleteReportDefinition",
        "bcm-data-exports:CreateExport",
        "bcm-data-exports:DeleteExport",
        "payments:*",
        "billingconductor:Create*",
        "billingconductor:Update*",
        "billingconductor:Delete*"
      ],
      "Resource": "*"
    }
  ]
}
```

**Member-account visibility** is a third gate: by default a member account cannot open Cost Explorer for its own data. The payer must enable *linked account access to Cost Explorer* in the management account's Cost Management preferences. Enabling it exposes the member's own costs, not the organization's.

---

## 12. CLI cookbook

```console
# --- Where is the money going, by service, last 30 days ---------------------
$ aws ce get-cost-and-usage \
    --time-period Start=2026-08-05,End=2026-09-04 \
    --granularity MONTHLY \
    --metrics AmortizedCost \
    --group-by Type=DIMENSION,Key=SERVICE \
    --query 'ResultsByTime[0].Groups[?to_number(Metrics.AmortizedCost.Amount)>`1000`].[Keys[0],Metrics.AmortizedCost.Amount]' \
    --output table
--------------------------------------------------------------------
|                        GetCostAndUsage                           |
+---------------------------------------------+--------------------+
|  Amazon Elastic Compute Cloud - Compute      |  18422.7310394     |
|  Amazon Relational Database Service          |   9104.2280110     |
|  AWS Data Transfer                           |   6877.1093004     |
|  Amazon Simple Storage Service               |   4011.9820773     |
|  Amazon Elastic Container Service for Kube.. |   2190.0000000     |
|  AmazonCloudWatch                            |   5980.1200041     |
|  Amazon Virtual Private Cloud                |   3402.8811009     |
+---------------------------------------------+--------------------+

# --- Same period, but split by the cost category we defined -----------------
$ aws ce get-cost-and-usage \
    --time-period Start=2026-08-01,End=2026-09-01 \
    --granularity MONTHLY \
    --metrics UnblendedCost \
    --group-by Type=COST_CATEGORY,Key=BusinessUnit \
    --query 'ResultsByTime[0].Groups[].[Keys[0],Metrics.UnblendedCost.Amount]' \
    --output text
BusinessUnit$DataPlatform             14882.331200
BusinessUnit$Payments                 21044.770100
BusinessUnit$PlatformSharedServices    7104.209800
BusinessUnit$Unallocated-Shared        1497.128900

# --- Forecast the rest of the month, with a confidence interval -------------
$ aws ce get-cost-forecast \
    --time-period Start=2026-09-05,End=2026-10-01 \
    --metric UNBLENDED_COST \
    --granularity MONTHLY \
    --prediction-interval-level 80
{
    "Total": {
        "Amount": "38104.5521",
        "Unit": "USD"
    },
    "ForecastResultsByTime": [
        {
            "TimePeriod": {"Start": "2026-09-05", "End": "2026-10-01"},
            "MeanValue": "38104.5521",
            "PredictionIntervalLowerBound": "35218.7710",
            "PredictionIntervalUpperBound": "41302.9944"
        }
    ]
}

# --- Which dimension values exist? (avoid guessing filter strings) ----------
$ aws ce get-dimension-values \
    --time-period Start=2026-08-01,End=2026-09-01 \
    --dimension PURCHASE_TYPE \
    --query 'DimensionValues[].Value' --output text
Credit  On Demand Instances     Savings Plans   Spot Instances  Standard Reserved Instances

# --- Budget state right now -------------------------------------------------
$ aws budgets describe-budgets --account-id 111122223333 \
    --query 'Budgets[].[BudgetName,BudgetLimit.Amount,CalculatedSpend.ActualSpend.Amount,CalculatedSpend.ForecastedSpend.Amount]' \
    --output table
---------------------------------------------------------------------------------
|                                DescribeBudgets                                |
+--------------------------------+-----------+--------------+------------------+
|  org-monthly-unblended-cost    |  42000.0  |  31877.42    |  44012.09        |
|  savings-plans-utilization-floor| 95.0     |  97.56       |  None            |
|  team-CC-1001-monthly          |  8000.0   |   6720.11    |   9104.88        |
|  sandbox-hard-stop             |  1500.0   |    912.44    |   1288.03        |
+--------------------------------+-----------+--------------+------------------+

# --- Did any budget action fire? -------------------------------------------
$ aws budgets describe-budget-actions-for-budget \
    --account-id 111122223333 --budget-name sandbox-hard-stop \
    --query 'Actions[].[ActionId,ActionType,Status,ApprovalModel]' --output text
1f0a4b2c-...  APPLY_IAM_POLICY  STANDBY  AUTOMATIC

$ aws budgets describe-budget-action-histories \
    --account-id 111122223333 --budget-name sandbox-hard-stop \
    --action-id 1f0a4b2c-8e33-4c71-9a02-6b7d5e4f1a99 \
    --query 'ActionHistories[0]'
{
    "Timestamp": "2026-08-29T18:07:44.112000+00:00",
    "Status": "EXECUTION_SUCCESS",
    "EventType": "SYSTEM",
    "ActionHistoryDetails": {
        "Message": "Budget action executed: policy attached to role EngineerSandboxRole.",
        "Action": {
            "ActionId": "1f0a4b2c-8e33-4c71-9a02-6b7d5e4f1a99",
            "BudgetName": "sandbox-hard-stop",
            "ActionType": "APPLY_IAM_POLICY",
            "Status": "EXECUTION_SUCCESS"
        }
    }
}

# --- Free Tier consumption (endpoint is us-east-1 only) --------------------
$ aws freetier get-free-tier-usage --region us-east-1 \
    --query 'freeTierUsages[?forecastedUsageAmount>limit].[service,usageType,actualUsageAmount,forecastedUsageAmount,limit,unit]' \
    --output table
------------------------------------------------------------------------------------
|                              GetFreeTierUsage                                    |
+-------------+----------------------------+-------+--------+--------+-------------+
|  AWSLambda  |  Global-Request            | 812441| 1204880| 1000000|  Requests   |
|  AmazonEC2  |  BoxUsage:t3.micro         |  612.0|   784.0|   750.0|  Hrs        |
+-------------+----------------------------+-------+--------+--------+-------------+

# --- Public price list: what does an m6i.2xlarge cost on-demand in eu-west-1?
$ aws pricing get-products --region us-east-1 \
    --service-code AmazonEC2 \
    --filters \
      Type=TERM_MATCH,Field=instanceType,Value=m6i.2xlarge \
      Type=TERM_MATCH,Field=regionCode,Value=eu-west-1 \
      Type=TERM_MATCH,Field=operatingSystem,Value=Linux \
      Type=TERM_MATCH,Field=tenancy,Value=Shared \
      Type=TERM_MATCH,Field=preInstalledSw,Value=NA \
      Type=TERM_MATCH,Field=capacitystatus,Value=Used \
    --query 'PriceList[0]' --output text | \
  jq -r '.terms.OnDemand | to_entries[0].value.priceDimensions | to_entries[0].value | "\(.pricePerUnit.USD) USD per \(.unit) — \(.description)"'
0.4280000000 USD per Hrs — $0.428 per On Demand Linux m6i.2xlarge Instance Hour

# --- Cost allocation tag status ------------------------------------------
$ aws ce list-cost-allocation-tags --status Active \
    --query 'CostAllocationTags[].[TagKey,Type,Status]' --output text
cost-center     UserDefined     Active
environment     UserDefined     Active
team            UserDefined     Active
aws:createdBy   AWSGenerated    Active

# --- Organization-wide RI/SP sharing check --------------------------------
$ aws organizations describe-organization --query 'Organization.[Id,FeatureSet,MasterAccountId]' --output text
o-a1b2c3d4e5    ALL     111122223333
```

---

## 13. Verification and failure diagnosis

### 13.1 Post-deployment verification checklist

Run this after building the guardrails; each step proves one link in the chain.

```console
# 1. The CUR/Data Export is actually delivering.
$ aws bcm-data-exports list-exports --region us-east-1 \
    --query 'Exports[].[ExportName,ExportStatus.StatusCode,ExportStatus.LastRefreshedAt]' --output text
org-cur2-hourly HEALTHY 2026-09-04T06:11:52+00:00

# 2. Objects exist in the bucket for the current billing period.
$ aws s3 ls s3://acme-finops-cur-111122223333/cur2/org-cur2-hourly/ --recursive \
    | tail -3
2026-09-04 06:14:02   48213991 cur2/org-cur2-hourly/data/BILLING_PERIOD=2026-09/org-cur2-hourly-00001.snappy.parquet
2026-09-04 06:14:07       2044 cur2/org-cur2-hourly/metadata/BILLING_PERIOD=2026-09/org-cur2-hourly-Manifest.json
2026-09-04 06:14:07        918 cur2/org-cur2-hourly/metadata/BILLING_PERIOD=2026-09/org-cur2-hourly-Metadata.json

# 3. Athena can read it and the totals are non-zero.
$ aws athena start-query-execution --work-group finops-cur \
    --query-execution-context Database=cur_analytics \
    --query-string "SELECT count(*) rows, round(sum(line_item_unblended_cost),2) usd FROM org_cur2_hourly WHERE bill_billing_period_start_date = DATE '2026-08-01'" \
    --query QueryExecutionId --output text
c9e2a1b4-77d0-4e18-9b3a-2f5c8d1e6a04

$ aws athena get-query-results --query-execution-id c9e2a1b4-77d0-4e18-9b3a-2f5c8d1e6a04 \
    --query 'ResultSet.Rows[1].Data[*].VarCharValue' --output text
41882913        45528.44

# 4. The CUR total reconciles with Cost Explorer within rounding.
$ aws ce get-cost-and-usage --time-period Start=2026-08-01,End=2026-09-01 \
    --granularity MONTHLY --metrics UnblendedCost \
    --query 'ResultsByTime[0].Total.UnblendedCost.Amount' --output text
45528.4412210

# 5. The SNS topic accepts a publish from the Budgets principal.
$ aws sns get-topic-attributes --topic-arn arn:aws:sns:eu-west-1:111122223333:finops-budget-alerts \
    --query 'Attributes.Policy' --output text | jq -r '.Statement[].Principal.Service'
budgets.amazonaws.com
costalerts.amazonaws.com

# 6. End-to-end alert test: publish to the topic directly.
$ aws sns publish --topic-arn arn:aws:sns:eu-west-1:111122223333:finops-budget-alerts \
    --subject "FinOps pipeline test" --message "verification $(date -u +%FT%TZ)"
{
    "MessageId": "8f1c2d4e-9a0b-4c3d-8e7f-1a2b3c4d5e6f"
}

# 7. Anomaly monitors exist and are attached to a subscription.
$ aws ce get-anomaly-monitors --query 'AnomalyMonitors[].[MonitorName,MonitorType,DimensionalValueCount]' --output text
all-services            DIMENSIONAL     412
by-business-unit        CUSTOM          None
sandbox-account         CUSTOM          None

$ aws ce get-anomaly-subscriptions --query 'AnomalySubscriptions[].[SubscriptionName,Frequency,length(MonitorArnList)]' --output text
high-impact-immediate   IMMEDIATE       3
daily-digest            DAILY           1
```

Step 4 is the one that matters most: **if the CUR total and the Cost Explorer total do not reconcile, every downstream dashboard is lying.** A gap here is almost always a metric mismatch (§3) or an excluded `line_item_line_item_type`.

### 13.2 Failure diagnosis table

| Symptom | Likely cause | Diagnostic | Fix |
|---|---|---|---|
| CUR created, **no files ever appear** in S3 | Bucket policy missing `billingreports.amazonaws.com` / `bcm-data-exports.amazonaws.com`, or the bucket's **default encryption is SSE-KMS** | `aws s3api get-bucket-policy --bucket X`; `aws s3api get-bucket-encryption --bucket X` | Apply the policy in §8.1; set default encryption to `AES256` (SSE-S3) |
| CUR files appear ~24 h late on first setup | Normal — first delivery can take up to 24 hours | `ExportStatus.LastRefreshedAt` | Wait one cycle before escalating |
| Bucket policy correct, still `UNHEALTHY` | CUR/Data Export was created outside `us-east-1`, or the bucket was deleted/renamed | `aws bcm-data-exports get-export --export-arn ...` | Recreate the export in `us-east-1` |
| Cost allocation tag column is **empty for past months** | Tag activation is forward-looking | `aws ce list-cost-allocation-tags` — check `Status` and activation date | `aws ce start-cost-allocation-tag-backfill --backfill-from <date>` |
| Tag exists on the resource but never appears in Cost Explorer | Key never **activated** in the management account, or activation is <24 h old, or the key uses the reserved `aws:` prefix | `aws ce list-cost-allocation-tags --status Inactive` | Activate the key; wait 24 h; rename keys that collide with `aws:` |
| Tag-filtered **budget always reports $0** | `CostFilters.TagKeyValue` references an inactive tag key, or the `user:key$value` syntax is wrong | `aws budgets describe-budget --budget-name X --query 'Budget.CostFilters'` | Activate the key; use exactly `user:<key>$<value>` |
| **Budget never sends an alert** | SNS topic policy rejects `budgets.amazonaws.com`; or email subscription never confirmed; or evaluation has not run yet (~3×/day) | Publish to the topic manually (verification step 6); `aws sns list-subscriptions-by-topic` — look for `PendingConfirmation` | Add the topic policy statement; confirm the email subscription |
| **Forecast alerts never fire**, actual alerts do | Insufficient history — forecasting needs roughly five weeks of usage data | `CalculatedSpend.ForecastedSpend` is absent/`None` in `describe-budgets` | Wait for history to accumulate; rely on ACTUAL thresholds meanwhile |
| **Budget action did not execute** | `ApprovalModel: MANUAL` (awaiting approval); or the execution role's trust policy omits `budgets.amazonaws.com`; or the role lacks `iam:AttachRolePolicy` for that policy ARN | `describe-budget-action-histories` → look for `EXECUTION_FAILURE` or `PENDING` | Switch to `AUTOMATIC` after testing; fix the trust policy and the `iam:PolicyARN` condition |
| Member account sees **"You do not have permission to access billing"** | Root-level "IAM user and role access to Billing information" is off; or the payer has not enabled linked-account Cost Explorer access | Sign in as root → Account settings; management account → Cost Management preferences | Enable both toggles; then attach the fine-grained IAM policy (§11) |
| IAM policy with `aws-portal:ViewBilling` no longer works | Legacy actions replaced by fine-grained `billing:`/`ce:`/`payments:`/`account:` actions | IAM Access Analyzer / CloudTrail `AccessDenied` events | Rewrite policies against the fine-grained actions |
| **Unexpected Cost Explorer charges** on the bill | `ce:GetCostAndUsage` is billed per paginated request; a dashboard polling every minute generates thousands | CUR: filter `line_item_usage_type LIKE '%CostExplorer%'` | Cache results; move recurring analytics to CUR + Athena; never grant `ce:*` to in-cluster workloads |
| Cost Explorer total ≠ CUR total | Different metric (blended vs unblended vs amortized); CUR includes `Tax`/`Credit`/`Refund` line item types you filtered out; time zone is UTC in both but your `WHERE` clause is local | Re-run both with `UnblendedCost` and no line-item-type filter | Align the metric and the line-item-type filter explicitly |
| Hourly Cost Explorer data **disappears after two weeks** | Hourly granularity has a 14-day retention window | — | Use the CUR for anything older than 14 days |
| Anomaly Detection is **silent** during a real spike | Monitor scope excludes the account/service; `ThresholdExpression` too high; monitor created <10 days ago (no baseline) | `aws ce get-anomaly-monitors`; `get-anomaly-subscriptions` → inspect `ThresholdExpression` | Broaden the monitor; lower the absolute threshold; wait for the baseline |
| Anomaly Detection is **too noisy** | Single absolute threshold on a spiky workload | Same | Combine absolute **and** percentage in an `And` expression (§9); send `provide-anomaly-feedback NO` |
| Cost Category shows everything as `Unallocated` | Rules never matched (order matters, first match wins), or the category was created after the resources were billed | `aws ce describe-cost-category-definition --cost-category-arn ...` | Reorder rules most-specific-first; check `EffectiveStart` |
| Savings Plan bought, **discount not applied** to some accounts | RI/SP sharing disabled for that member account, or the account left the organization | Management account → Billing preferences → sharing settings | Re-enable sharing for the account |
| `UtilizationPercentage` dropped after a migration | Committed spend now exceeds the workload (stranded commitment) | `aws ce get-savings-plans-utilization` | Cannot cancel an SP; shift eligible workloads back into scope, or let it expire and right-size the next purchase |
| Compute Optimizer says "insufficient data" | Fewer than ~30 hours of CloudWatch metrics, or the instance is too new | `aws compute-optimizer get-ec2-instance-recommendations --instance-arns ...` → `finding: NotOptimized` vs missing | Wait for the metric window; install the CloudWatch agent for memory-aware recommendations |
| Athena query on CUR is catastrophically expensive | `SELECT *` over an unpartitioned table scans the whole history | Athena console → *Data scanned* | Always filter on `bill_billing_period_start_date`; store as Parquet; set `BytesScannedCutoffPerQuery` on the workgroup (§8.1) |
| EKS split cost columns are all `NULL` | `SPLIT_COST_ALLOCATION_DATA` not enabled on the report definition | `aws cur describe-report-definitions --query 'ReportDefinitions[].AdditionalSchemaElements'` | Add the schema element; data is forward-looking from that point |

### 13.3 A worked diagnosis: "the budget fired but nothing was attached"

```console
$ aws budgets describe-budget-action-histories \
    --account-id 111122223333 --budget-name sandbox-hard-stop \
    --action-id 1f0a4b2c-8e33-4c71-9a02-6b7d5e4f1a99 \
    --query 'ActionHistories[0].[Timestamp,Status,ActionHistoryDetails.Message]' --output text
2026-08-29T18:07:44.112000+00:00  EXECUTION_FAILURE  User: arn:aws:sts::111122223333:assumed-role/AWSBudgetsActionExecutionRole/BudgetsActionExecution is not authorized to perform: iam:AttachRolePolicy on resource: role EngineerSandboxRole

$ aws iam get-role --role-name AWSBudgetsActionExecutionRole \
    --query 'Role.AssumeRolePolicyDocument.Statement[0].Principal'
{
    "Service": "budgets.amazonaws.com"
}
```

Trust is fine — the failure is on the permissions side. The inline policy in §7.2 restricts `iam:AttachRolePolicy` with a condition on `iam:PolicyARN`, which is correct, but the *resource* is `*`. The error says the action itself is denied on the target role, which means an SCP or permissions boundary on the account is blocking `iam:AttachRolePolicy`:

```console
$ aws organizations list-policies-for-target --target-id 555566667777 \
    --filter SERVICE_CONTROL_POLICY --query 'Policies[].[Name,Id]' --output text
SandboxRestrictions     p-9f3a1c2e

$ aws organizations describe-policy --policy-id p-9f3a1c2e \
    --query 'Policy.Content' --output text | jq '.Statement[] | select(.Action | tostring | test("iam:"))'
{
  "Sid": "DenyIamMutation",
  "Effect": "Deny",
  "Action": ["iam:Attach*", "iam:Put*", "iam:Create*"],
  "Resource": "*"
}
```

There it is. The SCP that hardens the sandbox also blocks the budget action's own remediation. The fix is an exception in the SCP for the budget execution role — the same shape used in §6.2:

```json
{
  "Sid": "DenyIamMutation",
  "Effect": "Deny",
  "Action": ["iam:Attach*", "iam:Put*", "iam:Create*"],
  "Resource": "*",
  "Condition": {
    "ArnNotLike": {
      "aws:PrincipalArn": "arn:aws:iam::*:role/AWSBudgetsActionExecutionRole"
    }
  }
}
```

The general lesson: **a guardrail that can be blocked by another guardrail is not a guardrail until you have watched it execute successfully at least once.** Test budget actions by temporarily setting an absurdly low threshold, confirming `EXECUTION_SUCCESS`, then restoring the real value.

---

## 14. Support plans, briefly (where they intersect with cost)

Trusted Advisor's cost optimization checks are gated by support tier, which is why this shows up in cost-management questions:

| Plan | Trusted Advisor checks | Cost-relevant capability |
|---|---|---|
| **Basic** | Core checks (service quotas + selected security) | Free Tier alerts, Billing console, Budgets, Cost Explorer |
| **Developer** | Core checks | Everything in Basic |
| **Business** | **All checks**, including the full cost optimization category | Full Trusted Advisor cost recommendations, API access to Trusted Advisor |
| **Enterprise On-Ramp** | All checks | Adds a pool of Technical Account Managers, cost optimization reviews |
| **Enterprise** | All checks | Designated TAM, proactive cost/architecture guidance, Concierge Support (billing) |

**Concierge Support** (Enterprise) is the billing-specific one: a dedicated team for billing and account inquiries.

---

## 15. Exam distillation for Task 4.2

The recognition patterns most likely to be tested:

| Scenario in the question stem | Correct service |
|---|---|
| "Estimate the cost of a proposed architecture **before** building it" | **AWS Pricing Calculator** |
| "Get notified when spend exceeds / is forecast to exceed a threshold" | **AWS Budgets** |
| "Visualize and analyze cost trends over the past year, filter by service/tag" | **AWS Cost Explorer** |
| "The most detailed, line-item-level, hourly data for custom analysis in Athena/Redshift" | **AWS Cost and Usage Report / Data Exports** |
| "Automatically detect unusual spending using machine learning" | **AWS Cost Anomaly Detection** |
| "Combine multiple accounts into one bill and get volume discounts" | **AWS Organizations consolidated billing** |
| "Tag resources so cost can be attributed to teams/projects" | **Cost allocation tags** (activated in the management account) |
| "Group costs by business unit using rules across accounts, services and tags" | **AWS Cost Categories** |
| "Recommendations to right-size EC2/EBS/Lambda based on utilization" | **AWS Compute Optimizer** |
| "One ranked list of all savings opportunities across the organization" | **Cost Optimization Hub** |
| "Best-practice checks including cost optimization (needs Business/Enterprise Support)" | **AWS Trusted Advisor** |
| "Bill internal teams with custom rates / act as a reseller" | **AWS Billing Conductor** |
| "Automatically apply a restrictive IAM policy or stop instances when a budget is exceeded" | **AWS Budgets Actions** |
| "Track Free Tier usage and get alerted before exceeding it" | **Free Tier usage alerts / AWS Budgets usage budget** |
| "Programmatically query current AWS public prices" | **AWS Price List API** (`pricing:GetProducts`) |
| "Grant a finance team read-only access to billing without console admin" | **IAM policy with fine-grained `billing:`/`ce:`/`budgets:` actions** + root-level billing access toggle |
| "See invoices, payment methods, credits, tax settings" | **AWS Billing and Cost Management console** |

Facts worth memorizing verbatim for the exam:

- Cost Explorer: **13 months** of history (current + 12), **12 months** of forecast; console free, **API is $0.01 per request**.
- AWS Budgets: **first two budgets free per account**; budgets are evaluated **about three times a day**; up to **5 alerts per budget**, **10 email subscribers per alert**; alerts on **actual or forecasted**.
- Cost Anomaly Detection: **free**.
- CUR: delivered to **S3**, can be **hourly/daily/monthly**, up to **three refreshes per day**, integrates with **Athena, Redshift, QuickSight**.
- Cost allocation tags must be **activated in the management (payer) account** and can take **up to 24 hours** to appear.
- Consolidated billing gives **one bill**, **volume-tier aggregation**, and **RI/Savings Plans sharing** across the organization.
- Savings Plans commit to a **$/hour** amount for **1 or 3 years**; Reserved Instances commit to **instance attributes**.
- **Compute Savings Plans** are the most flexible (any region, family, size, OS, tenancy; EC2 + Fargate + Lambda); **EC2 Instance Savings Plans** give the deepest discount but lock the family and region.
- A **Capacity Reservation** guarantees capacity but provides **no discount**.
- Trusted Advisor's **full** check set, including cost optimization, requires **Business** or **Enterprise** Support.

---

## 16. References

**Exam guide**
- AWS Certified Cloud Practitioner (CLF-C02) Exam Guide — https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf

**Billing and Cost Management**
- AWS Billing and Cost Management User Guide — https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/billing-what-is.html
- AWS Cost Management User Guide — https://docs.aws.amazon.com/cost-management/latest/userguide/what-is-costmanagement.html
- Billing and Cost Management permissions reference — https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/billing-permissions-ref.html
- Migrating from `aws-portal` to fine-grained billing actions — https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/migrate-granularaccess-iam-mapping-reference.html

**Cost Explorer**
- Analyzing your costs with AWS Cost Explorer — https://docs.aws.amazon.com/cost-management/latest/userguide/ce-what-is.html
- Understanding cost metrics (unblended, blended, amortized, net) — https://docs.aws.amazon.com/cost-management/latest/userguide/ce-advanced.html
- Cost Explorer API reference — https://docs.aws.amazon.com/aws-cost-management/latest/APIReference/API_Operations_AWS_Cost_Explorer_Service.html

**AWS Budgets**
- Managing your costs with AWS Budgets — https://docs.aws.amazon.com/cost-management/latest/userguide/budgets-managing-costs.html
- Configuring AWS Budgets actions — https://docs.aws.amazon.com/cost-management/latest/userguide/budgets-controls.html
- `AWS::Budgets::Budget` CloudFormation reference — https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-resource-budgets-budget.html
- `AWS::Budgets::BudgetsAction` CloudFormation reference — https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-resource-budgets-budgetsaction.html

**Cost and Usage Reports / Data Exports**
- What are AWS Cost and Usage Reports — https://docs.aws.amazon.com/cur/latest/userguide/what-is-cur.html
- AWS Data Exports (CUR 2.0) — https://docs.aws.amazon.com/cur/latest/userguide/what-is-data-exports.html
- CUR data dictionary — https://docs.aws.amazon.com/cur/latest/userguide/data-dictionary.html
- Split cost allocation data for Amazon EKS — https://docs.aws.amazon.com/cur/latest/userguide/split-cost-allocation-data.html
- Setting up an S3 bucket for CUR delivery — https://docs.aws.amazon.com/cur/latest/userguide/cur-s3.html
- Querying Cost and Usage Reports with Amazon Athena — https://docs.aws.amazon.com/cur/latest/userguide/cur-query-athena.html

**Cost allocation and categorization**
- Using cost allocation tags — https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/cost-alloc-tags.html
- Activating user-defined cost allocation tags — https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/activating-tags.html
- Cost allocation tag backfill — https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/enable-cost-allocation-tag-backfill.html
- AWS Cost Categories — https://docs.aws.amazon.com/cost-management/latest/userguide/manage-cost-categories.html
- Split charge rules for cost categories — https://docs.aws.amazon.com/cost-management/latest/userguide/split-charge-rules.html
- Tagging best practices (AWS Whitepaper) — https://docs.aws.amazon.com/whitepapers/latest/tagging-best-practices/tagging-best-practices.html

**Cost Anomaly Detection**
- Detecting unusual spend with AWS Cost Anomaly Detection — https://docs.aws.amazon.com/cost-management/latest/userguide/manage-ad.html
- `AWS::CE::AnomalyMonitor` CloudFormation reference — https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-resource-ce-anomalymonitor.html
- `AWS::CE::AnomalySubscription` CloudFormation reference — https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-resource-ce-anomalysubscription.html

**Organizations, consolidated billing and Billing Conductor**
- Consolidated billing for AWS Organizations — https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_accounts_consolidated-billing.html
- Service control policies (SCPs) — https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_scps.html
- Tag policies — https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_tag-policies.html
- Turning off Reserved Instance and Savings Plans discount sharing — https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/ri-turn-off.html
- What is AWS Billing Conductor — https://docs.aws.amazon.com/billingconductor/latest/userguide/what-is-billingconductor.html

**Pricing, commitments and optimization**
- AWS Pricing Calculator — https://calculator.aws/
- AWS Price List API — https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/price-changes.html
- What are Savings Plans — https://docs.aws.amazon.com/savingsplans/latest/userguide/what-is-savings-plans.html
- Amazon EC2 Reserved Instances — https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-reserved-instances.html
- Amazon EC2 Spot Instances — https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/using-spot-instances.html
- On-Demand Capacity Reservations — https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-capacity-reservations.html
- AWS Compute Optimizer — https://docs.aws.amazon.com/compute-optimizer/latest/ug/what-is-compute-optimizer.html
- Cost Optimization Hub — https://docs.aws.amazon.com/cost-management/latest/userguide/cost-optimization-hub.html
- AWS Trusted Advisor — https://docs.aws.amazon.com/awssupport/latest/user/trusted-advisor.html
- AWS Well-Architected Framework — Cost Optimization Pillar — https://docs.aws.amazon.com/wellarchitected/latest/cost-optimization-pillar/welcome.html

**Free Tier**
- Using the AWS Free Tier — https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/billing-free-tier.html
- AWS Free Tier — https://aws.amazon.com/free/

**Pricing of the cost-management tools themselves**
- AWS Cost Management pricing — https://aws.amazon.com/aws-cost-management/pricing/