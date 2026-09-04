# Topic 4.2 — Resources for Billing, Budget, and Cost Management
## Guided Exercises (AWS Certified Cloud Practitioner, CLF-C02 v1.0)

> **Exam weight of Domain 4 (Billing, Pricing, and Support): 12%. Task 4.2 weight: 4.0.**
> Reference: [AWS Certified Cloud Practitioner (CLF-C02) Exam Guide](https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf)

---

### How to use this lab

These exercises are executed against a **real AWS account**. Most steps are read-only and free; the ones that create resources are marked. A handful of API calls are billable — they are flagged inline with 💲 and the exact price is stated. Everything created is destroyed in Exercise 11.

Two structural facts you must internalise before typing anything, because they cause more failed labs than any other detail:

1. **Billing is a global service pinned to `us-east-1`.** The endpoints for `ce` (Cost Explorer), `budgets`, `cur`, `bcm-data-exports`, `organizations`, `freetier`, `billingconductor` and `support` live in `us-east-1` (and `us-gov-west-1` / `cn-northwest-1` for those partitions). The `AWS/Billing` CloudWatch namespace only publishes metrics in `us-east-1`. If you run these commands with `--region eu-west-1` you will get `EndpointConnectionError` or an empty result set, not a helpful message.
2. **Billing data is only visible from the management account, and only if IAM access to billing is switched on.** In an AWS Organization, member accounts see their own usage but the invoice belongs to the management (payer) account. And even a full `AdministratorAccess` IAM principal is blocked from billing pages until *Activate IAM Access* is enabled in **Account Settings → IAM user and role access to Billing information**. That toggle is account-wide, root-only, and one-way in practice.

Sources for this lab:
- [AWS Billing and Cost Management User Guide](https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/billing-what-is.html)
- [AWS Cost Management API Reference](https://docs.aws.amazon.com/aws-cost-management/latest/APIReference/Welcome.html)
- [AWS CLI v2 Command Reference](https://awscli.amazonaws.com/v2/documentation/api/latest/index.html)

---

## Exercise 0 — Establish the control plane

**Goal:** confirm who you are, where the billing endpoints are, and that you are permitted to read cost data at all.

1. Confirm the CLI version. Everything below assumes **AWS CLI v2**; v1 lacks `bcm-data-exports` and `freetier` entirely.

   ```bash
   aws --version
   ```

   ```
   aws-cli/2.31.6 Python/3.13.7 Linux/6.11.0 exe/x86_64.fedora.44
   ```

2. Identify the calling principal and the account it belongs to.

   ```bash
   aws sts get-caller-identity --output table
   ```

   ```
   -------------------------------------------------------------------------------
   |                              GetCallerIdentity                              |
   +-------------+---------------------------------------------------------------+
   |  Account    |  123456789012                                                 |
   |  Arn        |  arn:aws:sts::123456789012:assumed-role/FinOpsReadOnly/dalmine|
   |  UserId     |  AROAEXAMPLEID:dalmine                                         |
   +-------------+---------------------------------------------------------------+
   ```

3. Determine whether this account is standalone or part of an Organization. This single call decides whether the rest of the lab is about *your* bill or about *everyone's* bill.

   ```bash
   aws organizations describe-organization --region us-east-1
   ```

   ```json
   {
       "Organization": {
           "Id": "o-a1b2c3d4e5",
           "Arn": "arn:aws:organizations::123456789012:organization/o-a1b2c3d4e5",
           "FeatureSet": "ALL",
           "MasterAccountArn": "arn:aws:organizations::123456789012:account/o-a1b2c3d4e5/123456789012",
           "MasterAccountId": "123456789012",
           "MasterAccountEmail": "payer@example.com"
       }
   }
   ```

   If the account is standalone you get `AWSOrganizationsNotInUseException` — that is a valid outcome, not an error in your setup. Note that the API still says `MasterAccountId`; the console and documentation renamed this to **management account** in 2021, but the wire format was frozen for backward compatibility.

4. Inspect the IAM permissions your principal actually needs. The billing actions were migrated from the legacy coarse `aws-portal:*` and `purchase-orders:ViewPurchaseOrders` namespaces to fine-grained services in July 2023. A minimal read-only FinOps policy today looks like this — save it as `finops-readonly.json` for reference:

   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Sid": "ReadCostAndUsage",
         "Effect": "Allow",
         "Action": [
           "ce:Get*",
           "ce:List*",
           "ce:Describe*",
           "budgets:ViewBudget",
           "budgets:DescribeBudget*",
           "cur:DescribeReportDefinitions",
           "bcm-data-exports:GetExport",
           "bcm-data-exports:ListExports",
           "freetier:GetFreeTierUsage",
           "billing:Get*",
           "billing:List*",
           "payments:List*",
           "tax:List*",
           "invoicing:List*",
           "invoicing:Get*",
           "compute-optimizer:Get*",
           "organizations:DescribeOrganization",
           "organizations:ListAccounts"
         ],
         "Resource": "*"
       }
     ]
   }
   ```

   Note that every action here is `Resource: "*"`. Cost Management APIs are almost entirely non-resource-scoped: you cannot write an IAM policy that says "this role may read the bill for the `dev` account only". Per-account isolation is achieved by *account boundaries*, not by IAM resource ARNs.

5. Verify Cost Explorer is enabled. The first time anyone opens Cost Explorer, AWS begins preparing the dataset; it can take up to **24 hours** before the API returns data, and it backfills the previous **12 months**.

   ```bash
   aws ce get-cost-and-usage \
     --region us-east-1 \
     --time-period Start=2026-09-01,End=2026-09-04 \
     --granularity DAILY \
     --metrics "UnblendedCost" \
     --output json
   ```

   If Cost Explorer has never been enabled you get:

   ```
   An error occurred (DataUnavailableException) when calling the GetCostAndUsage operation:
   Data is not available. Please enable Cost Explorer in the Billing console.
   ```

### ✅ Check your understanding — Block 0

- **0.1** An IAM role in the management account has `AdministratorAccess` attached, but calls to `ce:GetCostAndUsage` return `AccessDeniedException`. IAM shows no explicit Deny and no SCP applies. What single account-level setting is almost certainly the cause?
- **0.2** Why does `aws ce get-cost-and-usage --region eu-west-1` fail even though your resources are all in `eu-west-1`?
- **0.3** A member account's administrator wants to see the consolidated invoice for the whole Organization. Can IAM grant this? Explain in one sentence.
- **0.4** You just enabled Cost Explorer for the first time in a two-year-old account. How far back will historical data go, and when will it appear?

---

## Exercise 1 — Cost Explorer: the analysis tool

**Goal:** answer "where did the money go?" with the tool designed for interactive, filtered, grouped analysis over the last 12–38 months.

💲 **Every Cost Explorer API request costs USD 0.01**, including each paginated page. The console is free. This is the single most common surprise in a FinOps automation project: a naive script that pages through daily, per-resource data can generate thousands of billable requests.

1. Get last month's spend broken down by service, unblended.

   ```bash
   aws ce get-cost-and-usage \
     --region us-east-1 \
     --time-period Start=2026-08-01,End=2026-09-01 \
     --granularity MONTHLY \
     --metrics "UnblendedCost" \
     --group-by Type=DIMENSION,Key=SERVICE
   ```

   ```json
   {
       "ResultsByTime": [
           {
               "TimePeriod": { "Start": "2026-08-01", "End": "2026-09-01" },
               "Total": {},
               "Groups": [
                   {
                       "Keys": ["Amazon Elastic Compute Cloud - Compute"],
                       "Metrics": { "UnblendedCost": { "Amount": "1412.8300000", "Unit": "USD" } }
                   },
                   {
                       "Keys": ["Amazon Relational Database Service"],
                       "Metrics": { "UnblendedCost": { "Amount": "603.1900000", "Unit": "USD" } }
                   },
                   {
                       "Keys": ["Amazon Simple Storage Service"],
                       "Metrics": { "UnblendedCost": { "Amount": "88.4200000", "Unit": "USD" } }
                   },
                   {
                       "Keys": ["AWS Cost Explorer"],
                       "Metrics": { "UnblendedCost": { "Amount": "0.4700000", "Unit": "USD" } }
                   }
               ],
               "Estimated": false
           }
       ],
       "DimensionValueAttributes": []
   }
   ```

   Two details worth reading carefully. `"Total": {}` is **empty whenever you group** — the totals move into the groups and you must sum them yourself. `"Estimated": false` means the billing period is closed and finalised; a current-month query returns `true` and the numbers can still move.

2. Compare the four cost metrics on the same period. This is the exercise that teaches the vocabulary the exam tests.

   ```bash
   aws ce get-cost-and-usage \
     --region us-east-1 \
     --time-period Start=2026-08-01,End=2026-09-01 \
     --granularity MONTHLY \
     --metrics "BlendedCost" "UnblendedCost" "AmortizedCost" "NetAmortizedCost" \
     --query 'ResultsByTime[0].Total'
   ```

   ```json
   {
       "BlendedCost":      { "Amount": "2104.9100000", "Unit": "USD" },
       "UnblendedCost":    { "Amount": "2104.9100000", "Unit": "USD" },
       "AmortizedCost":    { "Amount": "2338.7700000", "Unit": "USD" },
       "NetAmortizedCost": { "Amount": "2201.4400000", "Unit": "USD" }
   }
   ```

   - **UnblendedCost** — the cash-basis charge as it appears on the invoice for that account, on the day it was incurred. An All Upfront Reserved Instance shows its entire fee in month one and USD 0.00 thereafter.
   - **BlendedCost** — the average rate across an Organization. If account A owns a Reserved Instance and account B's usage consumes the discount, blended cost spreads the reduced rate across both. It is an accounting artefact for internal chargeback and is identical to unblended in a standalone account with no reservations.
   - **AmortizedCost** — upfront commitments (RI/Savings Plans fees) spread evenly across the term. This is the metric to use when you want "what did this month *really* cost to run", because it removes the spike from an annual prepayment.
   - **NetAmortizedCost** — amortized, after applying discounts and credits. "Net" always means *after credits/discounts* in AWS billing vocabulary.

3. Change granularity to `HOURLY` — available only for the last 14 days, and only if hourly granularity is enabled in Cost Management preferences (it carries its own charge).

   ```bash
   aws ce get-cost-and-usage \
     --region us-east-1 \
     --time-period Start=2026-09-03T00:00:00Z,End=2026-09-04T00:00:00Z \
     --granularity HOURLY \
     --metrics "UnblendedCost" \
     --query 'length(ResultsByTime)'
   ```

   ```
   24
   ```

4. Enumerate the dimensions you are allowed to filter and group by. There is a hard limit of **two** `--group-by` clauses per request.

   ```bash
   aws ce get-dimension-values \
     --region us-east-1 \
     --time-period Start=2026-08-01,End=2026-09-01 \
     --dimension PURCHASE_TYPE \
     --context COST_AND_USAGE \
     --query 'DimensionValues[].Value'
   ```

   ```json
   [
       "On Demand Instances",
       "Savings Plans",
       "Standard Reserved Instances",
       "Spot Instances"
   ]
   ```

5. Produce a forecast. Cost Explorer's forecast is a machine-learning model over your own history, expressed with a confidence interval. `Start` must be **today or later**.

   ```bash
   aws ce get-cost-forecast \
     --region us-east-1 \
     --time-period Start=2026-09-04,End=2026-10-01 \
     --metric UNBLENDED_COST \
     --granularity MONTHLY \
     --prediction-interval-level 80
   ```

   ```json
   {
       "Total": { "Amount": "1902.4400000", "Unit": "USD" },
       "ForecastResultsByTime": [
           {
               "TimePeriod": { "Start": "2026-09-04", "End": "2026-10-01" },
               "MeanValue": "1902.4400000",
               "PredictionIntervalLowerBound": "1744.1000000",
               "PredictionIntervalUpperBound": "2060.7800000"
           }
       ]
   }
   ```

   A forecast requires roughly **two consecutive months** of history; a brand-new account returns `DataUnavailableException`. The forecast covers the *remaining* period only — it does not include what you have already spent this month.

### ✅ Check your understanding — Block 1

- **1.1** Your query grouped by `SERVICE` returns `"Total": {}`. Is this a bug? What must your code do?
- **1.2** In January your team paid USD 12,000 All Upfront for a 1-year Compute Savings Plan. In March, which metric shows ~USD 1,000 for that commitment and which shows USD 0.00?
- **1.3** A standalone account with no reservations reports `BlendedCost == UnblendedCost`. Why is that expected rather than suspicious?
- **1.4** A Lambda function calls `GetCostAndUsage` with `DAILY` granularity grouped by `RESOURCE_ID`, paging through 40 pages, once per hour. Estimate the monthly Cost Explorer API charge.
- **1.5** `"Estimated": true` appears on your current-month result. What does it mean for a report you are about to send to Finance?

---

## Exercise 2 — Cost allocation tags: making the bill legible

**Goal:** turn an untagged, service-shaped bill into a bill shaped like your organisation.

A tag on a resource is invisible to billing until it is **activated as a cost allocation tag** in the payer account. Activation is not retroactive by default and takes up to **24 hours** to appear in Cost Explorer.

1. List the tag keys AWS has seen on your resources and their current activation status.

   ```bash
   aws ce list-cost-allocation-tags --region us-east-1 --max-results 20
   ```

   ```json
   {
       "CostAllocationTags": [
           { "TagKey": "Environment", "Type": "UserDefined", "Status": "Active",   "LastUpdatedDate": "2026-06-02", "LastUsedDate": "2026-09-03" },
           { "TagKey": "Team",        "Type": "UserDefined", "Status": "Inactive", "LastUpdatedDate": "2026-08-28" },
           { "TagKey": "aws:createdBy", "Type": "AWSGenerated", "Status": "Active", "LastUpdatedDate": "2026-01-15" }
       ]
   }
   ```

   `UserDefined` keys are yours and appear in the bill prefixed `user:`. `AWSGenerated` keys are created by AWS (`aws:createdBy`, `aws:cloudformation:stack-name`, …), are prefixed `aws:`, and cannot be created or deleted by you — only activated.

2. Activate the `Team` key. ⚠️ **Mutating step, payer account only.**

   ```bash
   aws ce update-cost-allocation-tags-status \
     --region us-east-1 \
     --cost-allocation-tags-status TagKey=Team,Status=Active
   ```

   ```json
   { "Errors": [] }
   ```

   An empty `Errors` array is success. There is no other output.

3. Backfill. Since 2024 you can retroactively apply an activated tag to historical data, up to 12 months back, starting from the first day of a month.

   ```bash
   aws ce start-cost-allocation-tag-backfill \
     --region us-east-1 \
     --backfill-from 2026-06-01T00:00:00Z
   ```

   ```json
   {
       "BackfillRequest": {
           "BackfillFrom": "2026-06-01T00:00:00Z",
           "RequestedAt": "2026-09-04T14:22:07Z",
           "BackfillStatus": "REQUESTED"
       }
   }
   ```

   Only **one backfill per 24 hours** per payer account. Check progress with `aws ce list-cost-allocation-tag-backfill-history --region us-east-1`.

4. Query cost grouped by the tag. Note the group key syntax differs from a dimension.

   ```bash
   aws ce get-cost-and-usage \
     --region us-east-1 \
     --time-period Start=2026-08-01,End=2026-09-01 \
     --granularity MONTHLY \
     --metrics "UnblendedCost" \
     --group-by Type=TAG,Key=Team
   ```

   ```json
   {
       "ResultsByTime": [
           {
               "TimePeriod": { "Start": "2026-08-01", "End": "2026-09-01" },
               "Total": {},
               "Groups": [
                   { "Keys": ["Team$"],          "Metrics": { "UnblendedCost": { "Amount": "731.0200000", "Unit": "USD" } } },
                   { "Keys": ["Team$platform"],  "Metrics": { "UnblendedCost": { "Amount": "902.5500000", "Unit": "USD" } } },
                   { "Keys": ["Team$data"],      "Metrics": { "UnblendedCost": { "Amount": "471.3400000", "Unit": "USD" } } }
               ],
               "Estimated": false
           }
       ]
   }
   ```

   `Team$` with an empty value after the `$` is **untagged spend** — 35% of the bill in this example. That number is the real output of this exercise: it is your tagging coverage gap, and it is the reason showback programmes fail.

5. Some costs can never carry a resource tag — support charges, tax, some data transfer, and the Cost Explorer API charges themselves. Confirm by filtering to a record type that has no resource behind it.

   ```bash
   aws ce get-cost-and-usage \
     --region us-east-1 \
     --time-period Start=2026-08-01,End=2026-09-01 \
     --granularity MONTHLY \
     --metrics "UnblendedCost" \
     --filter '{"Dimensions":{"Key":"RECORD_TYPE","Values":["Tax","Support"]}}' \
     --group-by Type=DIMENSION,Key=RECORD_TYPE
   ```

   ```json
   {
       "ResultsByTime": [
           {
               "TimePeriod": { "Start": "2026-08-01", "End": "2026-09-01" },
               "Total": {},
               "Groups": [
                   { "Keys": ["Support"], "Metrics": { "UnblendedCost": { "Amount": "210.4900000", "Unit": "USD" } } },
                   { "Keys": ["Tax"],     "Metrics": { "UnblendedCost": { "Amount": "441.9800000", "Unit": "USD" } } }
               ],
               "Estimated": false
           }
       ]
   }
   ```

### ✅ Check your understanding — Block 2

- **2.1** You tagged 400 EC2 instances with `Team=platform` on Monday and the tag does not appear in Cost Explorer on Tuesday morning. Name the two independent reasons this can happen.
- **2.2** What does the group key `Team$` (nothing after the dollar sign) represent, and why is its magnitude the most important number on the page?
- **2.3** Why can't the `aws:cloudformation:stack-name` tag key be deleted?
- **2.4** Support charges and tax appear in the bill but never under a team tag. Which tool from this topic can nonetheless assign them to a team?

---

## Exercise 3 — Cost Categories: allocation rules above the tags

**Goal:** group spend by rules — account, tag, service, region — into business dimensions, including a mechanism for splitting shared costs that tags cannot express.

⚠️ **Mutating step.** Cost Categories are free.

1. Author the ruleset. Rules are evaluated **in order**; first match wins.

   ```bash
   cat > cc-rules.json <<'JSON'
   [
     {
       "Value": "platform",
       "Type": "REGULAR",
       "Rule": {
         "Tags": { "Key": "Team", "Values": ["platform"], "MatchOptions": ["EQUALS"] }
       }
     },
     {
       "Value": "data",
       "Type": "REGULAR",
       "Rule": {
         "Or": [
           { "Tags": { "Key": "Team", "Values": ["data"], "MatchOptions": ["EQUALS"] } },
           { "Dimensions": { "Key": "LINKED_ACCOUNT", "Values": ["222222222222"], "MatchOptions": ["EQUALS"] } }
         ]
       }
     },
     {
       "Value": "shared-platform",
       "Type": "REGULAR",
       "Rule": {
         "Dimensions": { "Key": "SERVICE", "Values": ["Amazon Elastic Container Service for Kubernetes"], "MatchOptions": ["EQUALS"] }
       }
     }
   ]
   JSON
   ```

2. Add a **split charge rule** — the feature that has no equivalent in tagging. It takes the cost of a shared bucket and distributes it across target buckets proportionally to their own spend.

   ```bash
   cat > cc-split.json <<'JSON'
   [
     {
       "Source": "shared-platform",
       "Targets": ["platform", "data"],
       "Method": "PROPORTIONAL"
     }
   ]
   JSON
   ```

   `Method` accepts `PROPORTIONAL` (weighted by each target's cost), `FIXED` (with explicit `Parameters` percentages), or `EVEN`.

3. Create the definition.

   ```bash
   aws ce create-cost-category-definition \
     --region us-east-1 \
     --name Team \
     --rule-version CostCategoryExpression.v1 \
     --rules file://cc-rules.json \
     --split-charge-rules file://cc-split.json \
     --default-value Unallocated
   ```

   ```json
   {
       "CostCategoryArn": "arn:aws:ce::123456789012:costcategory/a1b2c3d4-5e6f-7890-abcd-ef1234567890",
       "EffectiveStart": "2026-09-01T00:00:00Z"
   }
   ```

   `EffectiveStart` is the **first day of the current month** — a Cost Category applies from the start of the month in which you create it, never from today. Retroactive application (up to 12 months) is requested separately.

4. Query by the new category.

   ```bash
   aws ce get-cost-and-usage \
     --region us-east-1 \
     --time-period Start=2026-09-01,End=2026-09-04 \
     --granularity MONTHLY \
     --metrics "UnblendedCost" \
     --group-by Type=COST_CATEGORY,Key=Team
   ```

   ```json
   {
       "ResultsByTime": [
           {
               "TimePeriod": { "Start": "2026-09-01", "End": "2026-09-04" },
               "Total": {},
               "Groups": [
                   { "Keys": ["Team$platform"],    "Metrics": { "UnblendedCost": { "Amount": "142.7700000", "Unit": "USD" } } },
                   { "Keys": ["Team$data"],        "Metrics": { "UnblendedCost": { "Amount": "88.0400000", "Unit": "USD" } } },
                   { "Keys": ["Team$Unallocated"], "Metrics": { "UnblendedCost": { "Amount": "19.6100000", "Unit": "USD" } } }
               ],
               "Estimated": true
           }
       ]
   }
   ```

   Notice `shared-platform` no longer appears as its own group — the split charge rule redistributed it into `platform` and `data` in proportion to their spend.

### ✅ Check your understanding — Block 3

- **3.1** A resource carries `Team=data` **and** runs in linked account `222222222222`, which rule 2 also matches. Nothing breaks. Now imagine a resource matching both rule 1 and rule 2 — which value wins, and why?
- **3.2** You create a Cost Category on 20 September. From what date does it apply?
- **3.3** Give one allocation problem a Cost Category solves that cost allocation tags structurally cannot.
- **3.4** What is `--default-value` for, and what would you learn by watching it over three months?

---

## Exercise 4 — AWS Budgets: the enforcement tool

**Goal:** move from *observing* cost to *being told about it* — and then to *acting on it*.

Cost Explorer answers "what happened". Budgets answers "tell me when a threshold is crossed, including a threshold I have not crossed yet".

💲 The first **two budgets per account are free**; each additional budget costs **USD 0.02 per day** (≈ USD 0.60/month).

1. Define the budget. This one is scoped to a tag, includes support and tax, and deliberately **excludes credits and refunds** so that promotional credits do not mask real burn.

   ```bash
   cat > budget.json <<'JSON'
   {
     "BudgetName": "prod-monthly-cost",
     "BudgetLimit": { "Amount": "2000", "Unit": "USD" },
     "TimeUnit": "MONTHLY",
     "BudgetType": "COST",
     "CostFilters": {
       "TagKeyValue": ["user:Environment$prod"]
     },
     "CostTypes": {
       "IncludeTax": true,
       "IncludeSubscription": true,
       "UseBlended": false,
       "IncludeRefund": false,
       "IncludeCredit": false,
       "IncludeUpfront": true,
       "IncludeRecurring": true,
       "IncludeOtherSubscription": true,
       "IncludeSupport": true,
       "IncludeDiscount": true,
       "UseAmortized": false
     }
   }
   JSON
   ```

   The tag filter syntax is `user:<Key>$<Value>` — the `user:` prefix and the `$` separator are both mandatory and are a frequent source of silently-empty budgets.

2. Define the notifications. Attach **two** thresholds of different types.

   ```bash
   cat > notifications.json <<'JSON'
   [
     {
       "Notification": {
         "NotificationType": "ACTUAL",
         "ComparisonOperator": "GREATER_THAN",
         "Threshold": 80,
         "ThresholdType": "PERCENTAGE"
       },
       "Subscribers": [
         { "SubscriptionType": "EMAIL", "Address": "finops@example.com" }
       ]
     },
     {
       "Notification": {
         "NotificationType": "FORECASTED",
         "ComparisonOperator": "GREATER_THAN",
         "Threshold": 100,
         "ThresholdType": "PERCENTAGE"
       },
       "Subscribers": [
         { "SubscriptionType": "SNS", "Address": "arn:aws:sns:us-east-1:123456789012:finops-alerts" }
       ]
     }
   ]
   JSON
   ```

   `ACTUAL` fires on money already spent. `FORECASTED` fires on Budgets' own projection of month-end spend — it is the only alert that can warn you **before** the overrun, and it requires ~5 weeks of history to produce a forecast at all.

3. If you use the SNS subscriber, the topic policy must allow the Budgets service principal to publish. Without this the budget is created successfully and then silently never notifies.

   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Sid": "AllowBudgetsPublish",
         "Effect": "Allow",
         "Principal": { "Service": "budgets.amazonaws.com" },
         "Action": "SNS:Publish",
         "Resource": "arn:aws:sns:us-east-1:123456789012:finops-alerts",
         "Condition": {
           "StringEquals": { "aws:SourceAccount": "123456789012" },
           "ArnLike": { "aws:SourceArn": "arn:aws:budgets::123456789012:budget/*" }
         }
       }
     ]
   }
   ```

4. Create the budget. ⚠️ **Mutating step.**

   ```bash
   aws budgets create-budget \
     --region us-east-1 \
     --account-id 123456789012 \
     --budget file://budget.json \
     --notifications-with-subscribers file://notifications.json
   ```

   Success is an **empty response body**. Verify explicitly:

   ```bash
   aws budgets describe-budget \
     --region us-east-1 \
     --account-id 123456789012 \
     --budget-name prod-monthly-cost \
     --query 'Budget.{Name:BudgetName,Limit:BudgetLimit.Amount,Actual:CalculatedSpend.ActualSpend.Amount,Forecast:CalculatedSpend.ForecastedSpend.Amount}'
   ```

   ```json
   {
       "Name": "prod-monthly-cost",
       "Limit": "2000",
       "Actual": "1487.2200000",
       "Forecast": "2140.0500000"
   }
   ```

   Actual is under limit; forecast is over. The `FORECASTED` notification has already fired — this is exactly the scenario the second threshold exists for.

5. Enumerate the budget types available. Only `COST` and `USAGE` are commonly used, but the exam expects you to know the reservation ones exist.

   | `BudgetType` | Tracks | Typical threshold |
   |---|---|---|
   | `COST` | Money | "alert at 80% of USD 2,000/month" |
   | `USAGE` | Usage units (GB, hours, requests) | "alert at 100 TB egress" |
   | `RI_UTILIZATION` | % of purchased RI hours actually used | alert **below** 90% |
   | `RI_COVERAGE` | % of eligible usage covered by RIs | alert **below** 70% |
   | `SAVINGS_PLANS_UTILIZATION` | % of SP commitment consumed | alert **below** 95% |
   | `SAVINGS_PLANS_COVERAGE` | % of eligible spend on SPs | alert **below** 80% |

   Utilisation and coverage budgets use `LESS_THAN` — you are alerting on *waste*, not on overspend.

6. Attach a **budget action**, the step that converts a budget from a notification into a control. Actions can apply an IAM policy, apply an SCP, or stop EC2/RDS instances.

   ```bash
   aws budgets create-budget-action \
     --region us-east-1 \
     --account-id 123456789012 \
     --budget-name prod-monthly-cost \
     --notification-type ACTUAL \
     --action-type APPLY_IAM_POLICY \
     --action-threshold ActionThresholdValue=100,ActionThresholdType=PERCENTAGE \
     --definition '{"IamActionDefinition":{"PolicyArn":"arn:aws:iam::123456789012:policy/DenyExpensiveLaunches","Roles":["DeveloperRole"]}}' \
     --execution-role-arn arn:aws:iam::123456789012:role/BudgetsActionExecutionRole \
     --approval-model MANUAL \
     --subscribers SubscriptionType=EMAIL,Address=finops@example.com
   ```

   ```json
   { "ActionId": "e3f4a1b2-9c8d-4e7f-a6b5-c4d3e2f1a0b9" }
   ```

   `--approval-model MANUAL` requires a human to confirm before the policy is applied; `AUTOMATIC` applies it unattended. In production, start with `MANUAL` — an automatic `APPLY_SCP` action that misfires can deny an entire OU at 03:00.

### ✅ Check your understanding — Block 4

- **4.1** Actual spend is USD 1,487 against a USD 2,000 limit and no alert has arrived from your `ACTUAL` 80% threshold... except it should have. Recompute: has it fired? Now explain what a `FORECASTED` threshold adds that `ACTUAL` cannot.
- **4.2** A budget was created with `"CostFilters": {"TagKeyValue": ["Environment$prod"]}` and always reports USD 0.00. What is wrong?
- **4.3** For an `RI_UTILIZATION` budget, would you alert with `GREATER_THAN` or `LESS_THAN`? Why?
- **4.4** You created a budget with an SNS subscriber. The budget shows the threshold exceeded but no message was published. Name the most likely cause.
- **4.5** Your account has 6 budgets. What is the monthly charge?
- **4.6** State the fundamental difference in purpose between AWS Budgets and AWS Cost Explorer in one sentence each.

---

## Exercise 5 — AWS Cost Anomaly Detection: the threshold you don't have to set

**Goal:** detect unusual spend patterns without knowing in advance what "unusual" is.

Budgets require you to name a number. Anomaly Detection learns your baseline with machine learning and alerts on deviation — the right tool for "an engineer left a `p5.48xlarge` running over the weekend", which no static monthly budget would catch until the month was already lost.

**Cost Anomaly Detection is free.**

1. Create a monitor. A `DIMENSIONAL` monitor with dimension `SERVICE` watches every AWS service independently — the recommended default.

   ```bash
   aws ce create-anomaly-monitor \
     --region us-east-1 \
     --anomaly-monitor '{
       "MonitorName": "all-services",
       "MonitorType": "DIMENSIONAL",
       "MonitorDimension": "SERVICE"
     }'
   ```

   ```json
   { "MonitorArn": "arn:aws:ce::123456789012:anomalymonitor/7c1f9a2e-4b3d-11f1-9d2a-0242ac120002" }
   ```

   Monitor types: `DIMENSIONAL` (service), `LINKED_ACCOUNT`, `COST_CATEGORY`, `CUSTOM` (an arbitrary expression over tags/accounts).

2. Create a subscription with a **threshold expression**, so you are not paged for a USD 3 anomaly.

   ```bash
   aws ce create-anomaly-subscription \
     --region us-east-1 \
     --anomaly-subscription '{
       "SubscriptionName": "finops-daily",
       "MonitorArnList": ["arn:aws:ce::123456789012:anomalymonitor/7c1f9a2e-4b3d-11f1-9d2a-0242ac120002"],
       "Subscribers": [{ "Type": "EMAIL", "Address": "finops@example.com" }],
       "Frequency": "DAILY",
       "ThresholdExpression": {
         "Dimensions": {
           "Key": "ANOMALY_TOTAL_IMPACT_ABSOLUTE",
           "MatchOptions": ["GREATER_THAN_OR_EQUAL"],
           "Values": ["100"]
         }
       }
     }'
   ```

   ```json
   { "SubscriptionArn": "arn:aws:ce::123456789012:anomalysubscription/3a9c0d51-77ee-4c8b-a1f0-9b2e6d4c8811" }
   ```

   `Frequency` is `IMMEDIATE`, `DAILY` or `WEEKLY`. **`IMMEDIATE` requires an SNS subscriber** — it cannot send individual emails. The flat `Threshold` field is deprecated; `ThresholdExpression` supersedes it and additionally supports `ANOMALY_TOTAL_IMPACT_PERCENTAGE`.

3. Retrieve detected anomalies.

   ```bash
   aws ce get-anomalies \
     --region us-east-1 \
     --date-interval StartDate=2026-08-01,EndDate=2026-09-04 \
     --total-impact NumericOperator=GREATER_THAN,StartValue=50
   ```

   ```json
   {
       "Anomalies": [
           {
               "AnomalyId": "0a1b2c3d-4e5f-6789-abcd-ef0123456789",
               "AnomalyStartDate": "2026-08-23",
               "AnomalyEndDate": "2026-08-25",
               "DimensionValue": "Amazon SageMaker",
               "RootCauses": [
                   {
                       "Service": "Amazon SageMaker",
                       "Region": "us-west-2",
                       "UsageType": "USW2-ML-p5-48xlarge-Hrs",
                       "LinkedAccount": "333333333333",
                       "LinkedAccountName": "ml-research"
                   }
               ],
               "AnomalyScore": { "MaxScore": 0.94, "CurrentScore": 0.11 },
               "Impact": {
                   "MaxImpact": 1284.6,
                   "TotalImpact": 2103.77,
                   "TotalActualSpend": 2380.11,
                   "TotalExpectedSpend": 276.34,
                   "TotalImpactPercentage": 761.3
               },
               "Feedback": "NO"
           }
       ]
   }
   ```

   Read the `Impact` block: expected USD 276, actual USD 2,380, so **TotalImpact is the difference**, USD 2,104 — the anomalous portion, not the total spend. `RootCauses` gives the account, region and usage type, which is enough to identify the offending workload without opening Cost Explorer.

4. Give feedback. This is not cosmetic — it retrains the model for your account.

   ```bash
   aws ce provide-anomaly-feedback \
     --region us-east-1 \
     --anomaly-id 0a1b2c3d-4e5f-6789-abcd-ef0123456789 \
     --feedback YES
   ```

   ```json
   { "AnomalyId": "0a1b2c3d-4e5f-6789-abcd-ef0123456789" }
   ```

   `YES` = this was a genuine anomaly. `NO` = false positive, stop alerting on this pattern. `PLANNED_ACTIVITY` = expected, e.g. a scheduled batch job or a launch.

### ✅ Check your understanding — Block 5

- **5.1** State the one-sentence difference between what triggers an AWS Budgets alert and what triggers a Cost Anomaly Detection alert.
- **5.2** An anomaly shows `TotalActualSpend: 2380.11` and `TotalImpact: 2103.77`. Why are these different numbers, and which one do you report as "the cost of the incident"?
- **5.3** You configure `"Frequency": "IMMEDIATE"` with an EMAIL subscriber and the API rejects it. Why?
- **5.4** Marketing runs an annual campaign that triples CloudFront cost every Black Friday. What should you submit via `provide-anomaly-feedback`, and what is the effect?
- **5.5** What does Cost Anomaly Detection cost?

---

## Exercise 6 — Cost and Usage Report / Data Exports: the source of truth

**Goal:** obtain the complete, line-item-level, hourly, resource-level billing dataset — the only artefact that reconciles byte-for-byte with the invoice.

Cost Explorer is an aggregated, rounded, API-limited *view*. The **AWS Cost and Usage Report (CUR)** is the raw ledger: one row per line item per hour, up to hundreds of columns, delivered to your S3 bucket. It is what you load into Athena, Redshift, QuickSight, or a third-party FinOps platform.

The modern interface is **AWS Data Exports** with the **CUR 2.0** schema; the legacy `cur` API still describes reports created the old way.

1. Inspect any legacy CUR definitions.

   ```bash
   aws cur describe-report-definitions \
     --region us-east-1 \
     --query 'ReportDefinitions[].{Name:ReportName,Bucket:S3Bucket,Format:Format,Compression:Compression,Granularity:TimeUnit,Resources:AdditionalSchemaElements}'
   ```

   ```json
   [
       {
           "Name": "legacy-hourly-cur",
           "Bucket": "acme-billing-legacy",
           "Format": "Parquet",
           "Compression": "Parquet",
           "Granularity": "HOURLY",
           "Resources": ["RESOURCES"]
       }
   ]
   ```

2. Prepare the S3 bucket policy. The export fails at creation time without it.

   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Sid": "EnableAWSDataExportsGetBucketAcl",
         "Effect": "Allow",
         "Principal": { "Service": "billingreports.amazonaws.com" },
         "Action": ["s3:GetBucketAcl", "s3:GetBucketPolicy"],
         "Resource": "arn:aws:s3:::acme-cur-exports",
         "Condition": {
           "StringEquals": { "aws:SourceAccount": "123456789012" },
           "ArnLike": { "aws:SourceArn": "arn:aws:cur:us-east-1:123456789012:definition/*" }
         }
       },
       {
         "Sid": "EnableAWSDataExportsPutObject",
         "Effect": "Allow",
         "Principal": { "Service": "billingreports.amazonaws.com" },
         "Action": "s3:PutObject",
         "Resource": "arn:aws:s3:::acme-cur-exports/*",
         "Condition": {
           "StringEquals": { "aws:SourceAccount": "123456789012" },
           "ArnLike": { "aws:SourceArn": "arn:aws:cur:us-east-1:123456789012:definition/*" }
         }
       }
     ]
   }
   ```

3. Define a CUR 2.0 export. The `QueryStatement` is real SQL against a virtual table — you select only the columns you need instead of accepting all ~300.

   ```bash
   cat > export.json <<'JSON'
   {
     "Name": "cur2-hourly-parquet",
     "Description": "Hourly CUR 2.0 with resource IDs and tags, for Athena",
     "DataQuery": {
       "QueryStatement": "SELECT bill_billing_period_start_date, bill_payer_account_id, line_item_usage_account_id, line_item_usage_start_date, line_item_product_code, line_item_line_item_type, line_item_resource_id, line_item_usage_amount, line_item_unblended_cost, pricing_term, product_region_code, resource_tags FROM COST_AND_USAGE_REPORT",
       "TableConfigurations": {
         "COST_AND_USAGE_REPORT": {
           "TIME_GRANULARITY": "HOURLY",
           "INCLUDE_RESOURCES": "TRUE",
           "INCLUDE_MANUAL_DISCOUNT_COMPATIBILITY": "FALSE",
           "INCLUDE_SPLIT_COST_ALLOCATION_DATA": "FALSE"
         }
       }
     },
     "DestinationConfigurations": {
       "S3Destination": {
         "S3Bucket": "acme-cur-exports",
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
     "RefreshCadence": { "Frequency": "SYNCHRONOUS" }
   }
   JSON
   ```

   ⚠️ **Mutating step** — creates a recurring export. There is no charge for the export itself; you pay **S3 storage, requests, and any Athena scanning**.

   ```bash
   aws bcm-data-exports create-export --region us-east-1 --export file://export.json
   ```

   ```json
   { "ExportArn": "arn:aws:bcm-data-exports:us-east-1:123456789012:export/cur2-hourly-parquet-9f8e7d6c" }
   ```

4. Understand `Overwrite`. `OVERWRITE_REPORT` replaces the month's files on each refresh — one authoritative copy, cheapest storage, and what you want for an Athena table. `CREATE_NEW_REPORT` keeps every version, which is required if you must prove what the numbers looked like on a given day, and which grows without bound.

5. Check delivery status.

   ```bash
   aws bcm-data-exports get-export \
     --region us-east-1 \
     --export-arn arn:aws:bcm-data-exports:us-east-1:123456789012:export/cur2-hourly-parquet-9f8e7d6c \
     --query 'ExportStatus'
   ```

   ```json
   {
       "CreatedAt": "2026-09-04T15:03:44.812000+00:00",
       "LastRefreshedAt": "2026-09-04T15:11:02.006000+00:00",
       "LastUpdatedAt": "2026-09-04T15:03:44.812000+00:00",
       "StatusCode": "HEALTHY"
   }
   ```

   The first delivery takes up to **24 hours**. Thereafter the report is refreshed up to **three times a day**, and AWS may restate prior data as charges finalise — which is why every CUR consumer must be idempotent on `(bill_billing_period_start_date, identity_line_item_id)`.

6. Query it with Athena, once a Glue table exists over the prefix:

   ```sql
   SELECT line_item_usage_account_id,
          line_item_product_code,
          SUM(line_item_unblended_cost) AS cost
   FROM   cur2_hourly_parquet
   WHERE  bill_billing_period_start_date = DATE '2026-08-01'
     AND  line_item_line_item_type IN ('Usage', 'DiscountedUsage', 'SavingsPlanCoveredUsage')
   GROUP  BY 1, 2
   ORDER  BY cost DESC
   LIMIT  10;
   ```

   The `line_item_line_item_type` filter is the detail that separates a correct CUR query from a wrong one. Without it you double-count: `SavingsPlanCoveredUsage` rows carry USD 0.00 unblended cost while the matching `SavingsPlanRecurringFee` row carries the money, and `Credit`, `Refund`, `Tax` and `RIFee` rows all live in the same table.

### ✅ Check your understanding — Block 6

- **6.1** Give two capabilities the CUR has that Cost Explorer does not.
- **6.2** Where is the CUR delivered, and what does AWS charge for the report itself?
- **6.3** Your Athena `SUM(line_item_unblended_cost)` over an entire month is 30% higher than the invoice. Name the most likely cause.
- **6.4** When would you choose `CREATE_NEW_REPORT` over `OVERWRITE_REPORT`?
- **6.5** Your ETL job runs at 02:00 and treats the CUR as immutable. Why is that assumption wrong?

---

## Exercise 7 — Consolidated billing and AWS Organizations

**Goal:** understand why moving 40 accounts under one payer reduces the bill without changing a single resource.

1. List the accounts sharing the invoice.

   ```bash
   aws organizations list-accounts \
     --region us-east-1 \
     --query 'Accounts[].{Id:Id,Name:Name,Status:Status}' \
     --output table
   ```

   ```
   ----------------------------------------------
   |                ListAccounts                |
   +----------------+---------------+-----------+
   |       Id       |     Name      |  Status   |
   +----------------+---------------+-----------+
   |  123456789012  |  payer        |  ACTIVE   |
   |  222222222222  |  data-prod    |  ACTIVE   |
   |  333333333333  |  ml-research  |  ACTIVE   |
   |  444444444444  |  sandbox      |  ACTIVE   |
   +----------------+---------------+-----------+
   ```

2. Break the bill down per account. This is showback: one invoice, per-account attribution.

   ```bash
   aws ce get-cost-and-usage \
     --region us-east-1 \
     --time-period Start=2026-08-01,End=2026-09-01 \
     --granularity MONTHLY \
     --metrics "UnblendedCost" \
     --group-by Type=DIMENSION,Key=LINKED_ACCOUNT
   ```

   ```json
   {
       "ResultsByTime": [
           {
               "TimePeriod": { "Start": "2026-08-01", "End": "2026-09-01" },
               "Total": {},
               "Groups": [
                   { "Keys": ["123456789012"], "Metrics": { "UnblendedCost": { "Amount": "402.1100000", "Unit": "USD" } } },
                   { "Keys": ["222222222222"], "Metrics": { "UnblendedCost": { "Amount": "1188.9000000", "Unit": "USD" } } },
                   { "Keys": ["333333333333"], "Metrics": { "UnblendedCost": { "Amount": "2380.1100000", "Unit": "USD" } } },
                   { "Keys": ["444444444444"], "Metrics": { "UnblendedCost": { "Amount": "133.7900000", "Unit": "USD" } } }
               ],
               "Estimated": false
           }
       ],
       "DimensionValueAttributes": [
           { "Value": "222222222222", "Attributes": { "description": "data-prod" } }
       ]
   }
   ```

   Consolidated billing delivers three things, and the exam tests all three:

   - **One bill.** A single invoice and payment method for all accounts.
   - **Volume/tiered pricing aggregation.** S3, data transfer and other tiered services sum usage **across the whole Organization** before applying the tier. Four accounts using 30 TB of S3 each are billed as 120 TB, reaching a cheaper tier that none of them would reach alone.
   - **Reserved Instance and Savings Plans sharing.** An unused RI or SP commitment in one account is automatically applied to matching usage in any other account in the Organization.

3. Inspect and control discount sharing. It is **on by default** for every account.

   ```bash
   aws ce get-cost-and-usage \
     --region us-east-1 \
     --time-period Start=2026-08-01,End=2026-09-01 \
     --granularity MONTHLY \
     --metrics "UnblendedCost" \
     --filter '{"Dimensions":{"Key":"PURCHASE_TYPE","Values":["Savings Plans"]}}' \
     --group-by Type=DIMENSION,Key=LINKED_ACCOUNT \
     --query 'ResultsByTime[0].Groups'
   ```

   To exclude an account from sharing — the standard treatment for a `sandbox` account you do not want silently absorbing production's committed discounts — disable it in **Billing → Preferences → Billing preferences → Reserved Instances and Savings Plans discount sharing**, per account, from the payer.

4. Confirm the feature set. `FeatureSet` from Exercise 0 matters here:

   - `CONSOLIDATED_BILLING` — billing aggregation only. No SCPs, no governance features.
   - `ALL` — consolidated billing **plus** Service Control Policies, tag policies, delegated administration, and the ability for Budget Actions to apply an SCP.

   Every new Organization is created with `ALL`; the billing-only mode exists for legacy and can be upgraded but never downgraded.

### ✅ Check your understanding — Block 7

- **7.1** Four accounts each store 30 TB in S3 Standard. Explain, without numbers, why the consolidated bill is lower than four separate bills.
- **7.2** Account A bought a Standard Reserved Instance it now barely uses. Account B runs matching On-Demand instances. What happens under consolidated billing, and what would you change if A must keep the benefit exclusively?
- **7.3** A member account administrator runs `aws ce get-cost-and-usage`. Whose costs do they see?
- **7.4** Your Organization has `FeatureSet: CONSOLIDATED_BILLING`. Can you configure a Budget Action of type `APPLY_SCP`?
- **7.5** Which metric — blended or unblended — is the natural choice for internal chargeback across accounts sharing reservations, and why?

---

## Exercise 8 — Estimating before you spend: Pricing Calculator and the Pricing API

**Goal:** every tool so far is retrospective. This one is the only one that works before a resource exists.

1. Open the [AWS Pricing Calculator](https://calculator.aws/) — **no AWS account required, free, and public**. Build a rough architecture: 3 × `m6i.large` Linux On-Demand in `us-east-1`, 500 GB `gp3` EBS, 2 TB monthly data transfer out. Export the estimate as a shareable link and as CSV. Since 2025 the Calculator is also embedded in the Billing console, where it can seed the estimate from your **actual historical usage** instead of blank inputs.

2. Get the same numbers programmatically. The **AWS Price List Query API** is free and serves the public price list. It is available only in `us-east-1`, `eu-central-1` and `ap-south-1`.

   ```bash
   aws pricing get-products \
     --region us-east-1 \
     --service-code AmazonEC2 \
     --filters \
       "Type=TERM_MATCH,Field=instanceType,Value=m6i.large" \
       "Type=TERM_MATCH,Field=location,Value=US East (N. Virginia)" \
       "Type=TERM_MATCH,Field=operatingSystem,Value=Linux" \
       "Type=TERM_MATCH,Field=tenancy,Value=Shared" \
       "Type=TERM_MATCH,Field=preInstalledSw,Value=NA" \
       "Type=TERM_MATCH,Field=capacitystatus,Value=Used" \
     --max-items 1 \
     --output text | python3 -c "import sys,json; d=json.loads(sys.stdin.read().split('\t')[-1] if False else sys.stdin.read()); print(d)" 2>/dev/null || \
   aws pricing get-products \
     --region us-east-1 --service-code AmazonEC2 \
     --filters "Type=TERM_MATCH,Field=instanceType,Value=m6i.large" \
               "Type=TERM_MATCH,Field=location,Value=US East (N. Virginia)" \
               "Type=TERM_MATCH,Field=operatingSystem,Value=Linux" \
               "Type=TERM_MATCH,Field=tenancy,Value=Shared" \
               "Type=TERM_MATCH,Field=preInstalledSw,Value=NA" \
               "Type=TERM_MATCH,Field=capacitystatus,Value=Used" \
     --max-items 1 --query 'PriceList[0]' --output text | jq -r '.terms.OnDemand[].priceDimensions[].pricePerUnit.USD'
   ```

   ```
   0.0960000000
   ```

   All six filters are mandatory in practice. Drop `capacitystatus` and you also match Capacity Reservation SKUs; drop `preInstalledSw` and you match the SQL Server-bundled variants — both return a different, higher price with no error.

3. Discover the filterable attributes for a service before guessing at them.

   ```bash
   aws pricing describe-services \
     --region us-east-1 \
     --service-code AmazonRDS \
     --query 'Services[0].AttributeNames' \
     --output text | tr '\t' '\n' | head -12
   ```

   ```
   deploymentOption
   engineCode
   instanceType
   licenseModel
   location
   locationType
   databaseEngine
   databaseEdition
   storageType
   volumeType
   usagetype
   operation
   ```

4. Note what the Calculator cannot know: your actual utilisation, your Savings Plans coverage, your Enterprise Discount Program rate, or the cost of the traffic pattern you have not measured yet. It produces a **list-price upper bound for a stated configuration** — invaluable for architecture comparison, unreliable as a budget.

### ✅ Check your understanding — Block 8

- **8.1** Name the one billing/cost tool in this topic that works with no AWS account and before any resource exists.
- **8.2** Your Pricing API query for `m6i.large` returns USD 0.212/hour instead of USD 0.096. Which filter did you most likely omit?
- **8.3** The Pricing Calculator says USD 4,100/month; the first real invoice is USD 3,050. Give two structural reasons the estimate ran high.
- **8.4** What does the Price List Query API cost?

---

## Exercise 9 — Optimisation recommendations: Compute Optimizer, Cost Explorer rightsizing, Trusted Advisor

**Goal:** get AWS to tell you where the waste is.

1. **AWS Compute Optimizer** — free, and available to every account regardless of support plan. It analyses CloudWatch metrics over a 14-day lookback (longer with paid enhanced metrics) for EC2, Auto Scaling groups, EBS, Lambda, ECS on Fargate, RDS, and commercial software licences.

   ```bash
   aws compute-optimizer get-enrollment-status --region us-east-1
   ```

   ```json
   { "status": "Active", "memberAccountsEnrolled": true, "lastUpdatedTimestamp": "2026-08-14T09:31:20+00:00" }
   ```

   ```bash
   aws compute-optimizer get-ec2-instance-recommendations \
     --region us-east-1 \
     --filters name=Finding,values=Overprovisioned \
     --max-results 2 \
     --query 'instanceRecommendations[].{Instance:instanceName,Type:currentInstanceType,Finding:finding,Recommended:recommendationOptions[0].instanceType,Savings:recommendationOptions[0].savingsOpportunity.estimatedMonthlySavings.value}'
   ```

   ```json
   [
       { "Instance": "api-worker-03", "Type": "m5.4xlarge", "Finding": "OVER_PROVISIONED", "Recommended": "m6i.xlarge", "Savings": 412.55 },
       { "Instance": "batch-runner-01", "Type": "r5.2xlarge", "Finding": "OVER_PROVISIONED", "Recommended": "r6i.large", "Savings": 288.10 }
   ]
   ```

   Findings are `UNDER_PROVISIONED`, `OVER_PROVISIONED`, `OPTIMIZED` or `NOT_OPTIMIZED`. Compute Optimizer sees CPU, network and disk by default; **memory is invisible** unless the CloudWatch agent publishes it, which is why an "over-provisioned" verdict on a memory-bound JVM must be verified before acting.

2. **Cost Explorer rightsizing** — the same idea surfaced with dollar context inside Cost Explorer.

   ```bash
   aws ce get-rightsizing-recommendation \
     --region us-east-1 \
     --service AmazonEC2 \
     --configuration '{"RecommendationTarget":"CROSS_INSTANCE_FAMILY","BenefitsConsidered":true}' \
     --query 'Summary'
   ```

   ```json
   {
       "TotalRecommendationCount": "37",
       "EstimatedTotalMonthlySavingsAmount": "3104.88",
       "EstimatedTotalMonthlySavingsPercentage": "18.4",
       "SavingsCurrencyCode": "USD"
   }
   ```

   `BenefitsConsidered: true` accounts for RI/SP coverage — without it the tool recommends downsizing instances whose cost is already covered by a commitment, producing savings that will not materialise.

3. **Savings Plans purchase recommendations.**

   ```bash
   aws ce get-savings-plans-purchase-recommendation \
     --region us-east-1 \
     --savings-plans-type COMPUTE_SP \
     --term-in-years ONE_YEAR \
     --payment-option NO_UPFRONT \
     --lookback-period-in-days SIXTY_DAYS \
     --query 'SavingsPlansPurchaseRecommendation.SavingsPlansPurchaseRecommendationSummary'
   ```

   ```json
   {
       "EstimatedROI": "21.7",
       "CurrencyCode": "USD",
       "EstimatedTotalCost": "18422.40",
       "CurrentOnDemandSpend": "23516.88",
       "EstimatedSavingsAmount": "5094.48",
       "TotalRecommendationCount": "1",
       "DailyCommitmentToPurchase": "50.47",
       "EstimatedMonthlySavingsAmount": "424.54",
       "EstimatedSavingsPercentage": "21.66",
       "EstimatedUtilization": "99.4"
   }
   ```

4. **AWS Trusted Advisor** — five pillars: cost optimization, performance, security, fault tolerance, service limits (and operational excellence). The **full cost-optimization check set requires Business, Enterprise On-Ramp or Enterprise Support**; Basic and Developer plans receive only a limited core set. The API endpoint is `us-east-1` and the API itself is Business+ only.

   ```bash
   aws support describe-trusted-advisor-checks \
     --region us-east-1 \
     --language en \
     --query "checks[?category=='cost_optimizing'].name"
   ```

   ```json
   [
       "Low Utilization Amazon EC2 Instances",
       "Idle Load Balancers",
       "Underutilized Amazon EBS Volumes",
       "Unassociated Elastic IP Addresses",
       "Amazon RDS Idle DB Instances",
       "Amazon Route 53 Latency Resource Record Sets",
       "Savings Plan Recommendations",
       "Amazon EC2 Reserved Instance Lease Expiration"
   ]
   ```

   On a Basic/Developer plan the same call fails:

   ```
   An error occurred (SubscriptionRequiredException) when calling the DescribeTrustedAdvisorChecks operation:
   AWS Premium Support Subscription is required to use this service.
   ```

   That error is itself the exam answer: Trusted Advisor's full check set is gated by support plan, while Compute Optimizer's rightsizing data is not.

### ✅ Check your understanding — Block 9

- **9.1** Two AWS services in this exercise produce EC2 rightsizing advice. Which one is free for every account, and which one is gated by support plan?
- **9.2** Compute Optimizer labels a Java service `OVER_PROVISIONED` based on 6% CPU. Why should you not act on this immediately?
- **9.3** What does `BenefitsConsidered: true` protect you from in `get-rightsizing-recommendation`?
- **9.4** Name the five Trusted Advisor check categories, and state which support plans unlock the complete set.
- **9.5** A recommendation reports `EstimatedUtilization: 99.4`. What is being predicted, and why does a low value make the recommendation dangerous?

---

## Exercise 10 — Alerts of last resort: CloudWatch billing alarms and Free Tier usage

**Goal:** the two mechanisms that exist specifically for the account with no FinOps team.

1. Enable billing alerts. In the **management account**, console → Billing → **Billing preferences** → **Alert preferences** → check *Receive AWS Free Tier alerts* and *Receive CloudWatch billing alerts*. Until this is checked, the `AWS/Billing` namespace is empty and your alarm sits permanently in `INSUFFICIENT_DATA`.

2. Confirm the metric is publishing. **`us-east-1` only** — the metric does not exist in any other region regardless of where your resources run.

   ```bash
   aws cloudwatch get-metric-statistics \
     --region us-east-1 \
     --namespace AWS/Billing \
     --metric-name EstimatedCharges \
     --dimensions Name=Currency,Value=USD \
     --start-time 2026-09-03T00:00:00Z \
     --end-time 2026-09-04T00:00:00Z \
     --period 21600 \
     --statistics Maximum \
     --query 'Datapoints | sort_by(@, &Timestamp)[-1]'
   ```

   ```json
   {
       "Timestamp": "2026-09-03T18:00:00+00:00",
       "Maximum": 487.22,
       "Unit": "None"
   }
   ```

   `EstimatedCharges` is a **cumulative month-to-date** value that resets to ~0 on the first of each month. It is published roughly every 6 hours. This is why the alarm below uses `Maximum` over a `21600`-second period: `Average` over a monotonically increasing counter is meaningless.

3. Create the alarm. ⚠️ **Mutating step.**

   ```bash
   aws cloudwatch put-metric-alarm \
     --region us-east-1 \
     --alarm-name billing-mtd-over-500-usd \
     --alarm-description "Month-to-date estimated charges exceeded USD 500" \
     --namespace AWS/Billing \
     --metric-name EstimatedCharges \
     --dimensions Name=Currency,Value=USD \
     --statistic Maximum \
     --period 21600 \
     --evaluation-periods 1 \
     --threshold 500 \
     --comparison-operator GreaterThanThreshold \
     --treat-missing-data notBreaching \
     --alarm-actions arn:aws:sns:us-east-1:123456789012:finops-alerts
   ```

   ```bash
   aws cloudwatch describe-alarms \
     --region us-east-1 \
     --alarm-names billing-mtd-over-500-usd \
     --query 'MetricAlarms[0].{State:StateValue,Reason:StateReason}'
   ```

   ```json
   {
       "State": "ALARM",
       "Reason": "Threshold Crossed: 1 datapoint [487.22 (03/09/26 18:00:00)] was not less than or equal to the threshold (500.0)."
   }
   ```

   Compared with AWS Budgets, a CloudWatch billing alarm is strictly weaker: it cannot filter by tag, service, account or Cost Category, it has no forecast, and it has no actions beyond an SNS publish. It exists because it predates Budgets and because it plugs into the CloudWatch alarm infrastructure you may already operate. **For a new deployment, use Budgets.**

4. Check Free Tier consumption against the limits, which is the specific failure mode of new accounts.

   ```bash
   aws freetier get-free-tier-usage \
     --region us-east-1 \
     --query 'freeTierUsages[?forecastedUsageAmount > limit].{Service:service,Usage:usageType,Actual:actualUsageAmount,Forecast:forecastedUsageAmount,Limit:limit,Unit:unit}' \
     --output table
   ```

   ```
   -----------------------------------------------------------------------------------------------
   |                                      GetFreeTierUsage                                       |
   +-------------------+----------+-----------+---------------------------+---------+------------+
   |      Service      |  Actual  | Forecast  |          Usage            |  Limit  |    Unit    |
   +-------------------+----------+-----------+---------------------------+---------+------------+
   |  Amazon S3        |  14.2    |  21.8     |  TimedStorage-ByteHrs     |  5.0    |  GB-Month  |
   |  AWS Lambda       |  612000  |  980000   |  Global-Request           |  1000000|  Request   |
   +-------------------+----------+-----------+---------------------------+---------+------------+
   ```

   The three Free Tier flavours the exam distinguishes: **Always Free** (e.g. 1M Lambda requests/month, forever), **12 Months Free** (e.g. 750 EC2 `t2.micro`/`t3.micro` hours per month for the first year), and **Trials** (short-term, service-specific, starting when you activate the service).

### ✅ Check your understanding — Block 10

- **10.1** Your CloudWatch billing alarm has been in `INSUFFICIENT_DATA` for a week. Give the two most likely causes.
- **10.2** Why is `Maximum` the correct statistic for `EstimatedCharges`, and why does the value collapse on the 1st of each month?
- **10.3** List three capabilities AWS Budgets has that a CloudWatch billing alarm does not.
- **10.4** Name the three categories of AWS Free Tier offer and give one example of each.

---

## Exercise 11 — Chargeback for resellers: AWS Billing Conductor, then cleanup

**Goal:** see the one tool that changes what the bill *says*, then remove everything this lab created.

1. **AWS Billing Conductor** produces a **pro forma** billing view: a second, parallel rendering of your Organization's costs with your own markups, discounts and custom line items applied. It does not change what AWS charges you — the real invoice is untouched — it changes what your internal business units or your ISV end-customers see. Billing Conductor is charged **per billing-group account per month**.

   ```bash
   aws billingconductor list-billing-groups \
     --region us-east-1 \
     --query 'BillingGroups[].{Name:Name,Arn:Arn,Size:Size,Status:Status}'
   ```

   ```json
   [
       {
           "Name": "customer-acme",
           "Arn": "arn:aws:billingconductor::123456789012:billinggroup/555555555555",
           "Size": 3,
           "Status": "ACTIVE"
       }
   ]
   ```

2. A pricing rule applies a markup or discount to a billing group's pro forma view.

   ```bash
   aws billingconductor create-pricing-rule \
     --region us-east-1 \
     --name managed-services-markup \
     --description "10% managed services fee on all AWS charges" \
     --scope GLOBAL \
     --type MARKUP \
     --modifier-percentage 10 \
     --billing-entity AWS
   ```

   ```json
   { "Arn": "arn:aws:billingconductor::123456789012:pricingrule/2c8b1a45" }
   ```

   Contrast the tools one last time: Cost Categories **group** the real bill; Billing Conductor **rewrites** a parallel bill.

3. **Cleanup.** Run these in order. Everything below is a deletion — read each target before executing.

   ```bash
   # Budget action, then budget
   aws budgets delete-budget-action --region us-east-1 \
     --account-id 123456789012 --budget-name prod-monthly-cost \
     --action-id e3f4a1b2-9c8d-4e7f-a6b5-c4d3e2f1a0b9

   aws budgets delete-budget --region us-east-1 \
     --account-id 123456789012 --budget-name prod-monthly-cost

   # Anomaly subscription must be deleted before its monitor
   aws ce delete-anomaly-subscription --region us-east-1 \
     --subscription-arn arn:aws:ce::123456789012:anomalysubscription/3a9c0d51-77ee-4c8b-a1f0-9b2e6d4c8811

   aws ce delete-anomaly-monitor --region us-east-1 \
     --monitor-arn arn:aws:ce::123456789012:anomalymonitor/7c1f9a2e-4b3d-11f1-9d2a-0242ac120002

   # Cost Category
   aws ce delete-cost-category-definition --region us-east-1 \
     --cost-category-arn arn:aws:ce::123456789012:costcategory/a1b2c3d4-5e6f-7890-abcd-ef1234567890

   # Data export (S3 objects survive and must be removed separately)
   aws bcm-data-exports delete-export --region us-east-1 \
     --export-arn arn:aws:bcm-data-exports:us-east-1:123456789012:export/cur2-hourly-parquet-9f8e7d6c

   # CloudWatch alarm
   aws cloudwatch delete-alarms --region us-east-1 \
     --alarm-names billing-mtd-over-500-usd

   # Billing Conductor pricing rule
   aws billingconductor delete-pricing-rule --region us-east-1 \
     --arn arn:aws:billingconductor::123456789012:pricingrule/2c8b1a45
   ```

   Deleting the export stops future deliveries; the Parquet files already written to S3 remain and keep incurring storage charges until you empty the prefix.

4. Verify nothing survives.

   ```bash
   aws budgets describe-budgets --region us-east-1 --account-id 123456789012 --query 'length(Budgets || `[]`)'
   aws ce get-anomaly-monitors --region us-east-1 --query 'length(AnomalyMonitors)'
   aws bcm-data-exports list-exports --region us-east-1 --query 'length(Exports)'
   aws cloudwatch describe-alarms --region us-east-1 --alarm-name-prefix billing- --query 'length(MetricAlarms)'
   ```

   ```
   0
   0
   0
   0
   ```

### ✅ Check your understanding — Block 11

- **11.1** Does a Billing Conductor markup change the amount AWS charges you? What does it change?
- **11.2** Distinguish Cost Categories from Billing Conductor in one sentence.
- **11.3** You deleted the data export. Why might your S3 bill not drop?
- **11.4** Why must the anomaly *subscription* be deleted before the *monitor*?

---

## Consolidated reference: which tool answers which question

| Question | Tool | Latency | Cost |
|---|---|---|---|
| What will this architecture cost before I build it? | **AWS Pricing Calculator** / Price List API | instant | free, no account needed |
| Where did last month's money go? | **AWS Cost Explorer** | up to 24 h | console free; API USD 0.01/request |
| Give me every line item, hourly, with resource IDs | **CUR 2.0 / AWS Data Exports** | up to 24 h first delivery | free; you pay S3 + Athena |
| Tell me when I cross a number I chose | **AWS Budgets** | ~8–12 h evaluation | 2 free, then USD 0.02/day |
| Tell me about spend I could not have predicted | **AWS Cost Anomaly Detection** | ~24 h after event | free |
| Alert me on total month-to-date charges, simply | **CloudWatch billing alarm** (`AWS/Billing`) | ~6 h metric period | standard CloudWatch alarm price |
| Am I about to exceed the Free Tier? | **Free Tier usage alerts** / `freetier` API | daily | free |
| Which resources are oversized? | **AWS Compute Optimizer** | 14-day lookback | free (enhanced metrics paid) |
| Which resources are idle or wasteful? | **AWS Trusted Advisor** | continuous | full checks need Business+ |
| Should I buy a Savings Plan, and how much? | **Cost Explorer SP recommendations** | 7/30/60-day lookback | USD 0.01/request |
| Shape the bill by team/product/environment | **Cost allocation tags + Cost Categories** | 24 h activation | free |
| One invoice, shared discounts, volume tiers | **AWS Organizations consolidated billing** | immediate | free |
| Bill my business units with a markup | **AWS Billing Conductor** | monthly | per billing-group account |

---

## Official sources

- CLF-C02 Exam Guide — https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf
- AWS Billing and Cost Management User Guide — https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/billing-what-is.html
- Analyzing your costs with AWS Cost Explorer — https://docs.aws.amazon.com/cost-management/latest/userguide/ce-what-is.html
- Managing your costs with AWS Budgets — https://docs.aws.amazon.com/cost-management/latest/userguide/budgets-managing-costs.html
- Configuring AWS Budget actions — https://docs.aws.amazon.com/cost-management/latest/userguide/budgets-controls.html
- Detecting unusual spend with AWS Cost Anomaly Detection — https://docs.aws.amazon.com/cost-management/latest/userguide/manage-ad.html
- AWS Data Exports and the CUR 2.0 table — https://docs.aws.amazon.com/cur/latest/userguide/what-is-data-exports.html
- CUR data dictionary (`line_item_line_item_type`) — https://docs.aws.amazon.com/cur/latest/userguide/data-dictionary.html
- Using cost allocation tags — https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/cost-alloc-tags.html
- Cost allocation tag backfill — https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/custom-tags.html
- AWS Cost Categories, including split charge rules — https://docs.aws.amazon.com/cost-management/latest/userguide/manage-cost-categories.html
- Consolidated billing for AWS Organizations — https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/consolidated-billing.html
- Turning off Reserved Instance and Savings Plans discount sharing — https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/ri-turn-off.html
- Creating a CloudWatch billing alarm — https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/monitor_estimated_charges_with_cloudwatch.html
- AWS Free Tier and usage alerts — https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/tracking-free-tier-usage.html
- AWS Pricing Calculator — https://docs.aws.amazon.com/pricing-calculator/latest/userguide/what-is-pricing-calculator.html
- AWS Price List Query API — https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/price-changes.html
- AWS Compute Optimizer User Guide — https://docs.aws.amazon.com/compute-optimizer/latest/ug/what-is-compute-optimizer.html
- AWS Trusted Advisor check reference — https://docs.aws.amazon.com/awssupport/latest/user/trusted-advisor-check-reference.html
- AWS Billing Conductor User Guide — https://docs.aws.amazon.com/billingconductor/latest/userguide/what-is-billingconductor.html
- Fine-grained billing IAM actions migration — https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/migrate-granularaccess-whatis.html
- AWS Cost Management pricing — https://aws.amazon.com/aws-cost-management/pricing/

---

<details>
<summary><strong>📝 Answers — click to expand</strong></summary>

### Block 0 — Control plane

**0.1** *IAM user and role access to Billing information* is not activated in **Account Settings**. This is an account-level switch, separate from IAM, that only the root user can flip. Until it is on, no IAM principal — including one with `AdministratorAccess` — can reach Billing and Cost Management data. It is the single most common cause of "AccessDenied with an admin policy attached".

**0.2** Cost Explorer is a global service whose API endpoint lives only in `us-east-1`. The location of your *resources* is irrelevant to the location of the *billing endpoint*; billing is aggregated globally into the payer account and served from one region. The same applies to `budgets`, `cur`, `bcm-data-exports`, `organizations`, `freetier`, `billingconductor` and `support`.

**0.3** No. Consolidated billing data belongs to the management account, and IAM in a member account cannot grant access to another account's billing data. The member account administrator must be given a principal *in the management account* (typically via a cross-account role assumed from their identity provider), or the payer must publish the data to them, e.g. via a shared CUR in S3.

**0.4** Cost Explorer backfills the previous **12 months** of history, and the data becomes available within **24 hours** of first enabling it. From that point forward AWS retains up to 38 months of history (13 months in the console by default, extendable).

---

### Block 1 — Cost Explorer

**1.1** Not a bug. When you supply any `--group-by`, Cost Explorer moves all values into the `Groups` array and leaves `Total` empty by design. Your code must iterate `Groups[].Metrics.<Metric>.Amount` and sum them itself. Code that reads `ResultsByTime[0].Total.UnblendedCost.Amount` unconditionally will throw a `KeyError` the moment someone adds a grouping.

**1.2** **AmortizedCost** shows ~USD 1,000 in March (12,000 ÷ 12 months). **UnblendedCost** shows USD 0.00 in March, because the entire USD 12,000 appeared as unblended cost in January when the payment was actually charged. This is the cash-basis versus accrual-basis distinction, and it is why a month-over-month unblended comparison across a commitment purchase is misleading.

**1.3** Blended cost is the *average rate across an Organization sharing reservation and Savings Plans discounts*. With no Organization to average across and no reservations to share, there is nothing to blend — the average of one rate is that rate. Equality is the expected result, not evidence of a problem.

**1.4** 40 pages × 24 runs/day × ~30 days = 28,800 requests × USD 0.01 = **USD 288/month** in Cost Explorer API charges alone. This is the classic FinOps own-goal: a cost-monitoring tool that becomes a top-10 line item. The correct architecture for resource-level daily data is a CUR export to S3 queried with Athena, not the Cost Explorer API.

**1.5** The billing period is still open. AWS has not finalised the charges: usage is still arriving, credits and refunds have not been applied, tax has not been computed, and Savings Plans/RI allocation can still shift. Numbers marked estimated **will** change. Send them clearly labelled as an estimate, or wait for the period to close and `Estimated` to flip to `false`.

---

### Block 2 — Cost allocation tags

**2.1** (a) The tag key was never **activated as a cost allocation tag** in the payer account — tagging a resource has no billing effect on its own. (b) Even after activation, propagation into Cost Explorer takes up to **24 hours**, and only usage incurred *after* activation is tagged unless you request a backfill. A third, less common cause: the tag was applied in a member account but activation must happen in the management account.

**2.2** `Team$` with an empty value is **untagged spend** — all cost that carries no `Team` tag, including resources someone forgot to tag and cost types that cannot be tagged at all. It is the most important number because it bounds the credibility of the entire report: if 35% of the bill is unallocated, no team's chargeback figure can be trusted to better than ±35%, and the correct next action is a tagging-enforcement policy, not a prettier dashboard.

**2.3** `aws:` prefixed tags are **AWS-generated**. AWS creates and maintains them (here, CloudFormation stamps every resource it provisions with its stack name). You may activate or deactivate them for cost allocation, but you cannot create, modify or delete the key itself. The reserved `aws:` prefix is enforced across all AWS tagging APIs.

**2.4** **AWS Cost Categories**, specifically **split charge rules**. A split charge rule takes the cost of an untaggable or shared bucket (support, shared EKS control plane, a NAT Gateway) and redistributes it across target categories `PROPORTIONAL`ly, `EVEN`ly, or by a `FIXED` percentage — which is precisely the allocation problem tags cannot express, since there is no resource to tag.

---

### Block 3 — Cost Categories

**3.1** **Rule 1 wins** — `platform`. Cost Category rules are evaluated **top to bottom and the first match assigns the value**; evaluation stops there. Rule ordering is therefore semantically significant, and a broad catch-all rule placed early silently swallows everything below it. Order rules from most specific to most general.

**3.2** From **1 September** — the first day of the month in which it was created. `EffectiveStart` is always month-aligned; a Cost Category never takes effect mid-month. To cover earlier months you must request retroactive application (backfill), available for up to 12 months.

**3.3** **Splitting shared costs.** A NAT Gateway, an EKS control plane, an enterprise support charge or a shared observability platform serves several teams; there is one resource (or no resource at all) and therefore at most one tag value. A split charge rule distributes that single cost across multiple categories proportionally. Secondarily: a Cost Category can classify by account, service or region — dimensions where no tag exists to apply.

**3.4** `--default-value` is the bucket for cost that matches **no rule** — here, `Unallocated`. Watching it over three months tells you whether your allocation model is converging or rotting: a shrinking `Unallocated` means new workloads are being tagged and classified as they launch; a growing one means teams are deploying faster than the ruleset is maintained, and your chargeback numbers are quietly losing coverage.

---

### Block 4 — AWS Budgets

**4.1** Yes, it has fired: 1,487 / 2,000 = 74.4%... which is **below** 80%, so it has **not** fired. Re-read the numbers — actual is at 74% of limit, under the `ACTUAL` threshold. The `FORECASTED` threshold, however, projects USD 2,140 (107% of limit) and **has** fired. That is exactly the value it adds: `ACTUAL` can only tell you about money already gone, so at best it warns you when the overrun is partially complete. `FORECASTED` warns you while there is still a month left to change the outcome. Every production cost budget should carry both.

**4.2** The `user:` prefix is missing. The correct filter value is `"user:Environment$prod"`. Without the prefix the filter matches nothing and the budget silently reports USD 0.00 — no error, no warning. (Secondarily, `Environment` must be activated as a cost allocation tag for the filter to match anything even with the correct syntax.)

**4.3** **`LESS_THAN`.** A utilisation budget tracks the percentage of purchased reservation hours actually consumed. High utilisation is good; you want to be alerted when it *drops*, because unused reservation hours are money already spent on capacity nobody is running. The same logic applies to `RI_COVERAGE`, `SAVINGS_PLANS_UTILIZATION` and `SAVINGS_PLANS_COVERAGE` — all four alert downward.

**4.4** The **SNS topic access policy does not allow the `budgets.amazonaws.com` service principal to `SNS:Publish`**. Budgets does not assume a role for notifications; it publishes as a service principal, so the permission must be granted on the topic's resource policy. Budget creation succeeds regardless, so the failure is invisible until the alert you were counting on never arrives. (A second candidate: the topic is encrypted with a KMS CMK whose key policy does not grant the Budgets principal `kms:GenerateDataKey`.)

**4.5** The first two budgets are free, leaving four billable: 4 × USD 0.02/day × ~30 days = **≈ USD 2.40/month**.

**4.6** **Cost Explorer** is an *analysis* tool: it answers "where did the money go?" retrospectively, with filtering, grouping and forecasting, and it requires a human to go and look. **AWS Budgets** is a *monitoring and enforcement* tool: it watches a threshold you declared and pushes a notification — or executes an action such as applying an IAM policy or SCP — when actual or forecasted spend crosses it, with nobody looking.

---

### Block 5 — Cost Anomaly Detection

**5.1** A **Budgets** alert fires when spend crosses a threshold **you defined in advance**. A **Cost Anomaly Detection** alert fires when spend deviates from a baseline that **machine learning derived from your own history**, with no threshold declared — which is the only way to catch cost events you did not anticipate.

**5.2** `TotalActualSpend` (USD 2,380) is everything that service cost during the anomaly window, including the portion you would have spent anyway. `TotalImpact` (USD 2,104) is `TotalActualSpend − TotalExpectedSpend` — the **excess attributable to the anomaly**. Report `TotalImpact` as the cost of the incident; reporting actual spend overstates the damage by the amount of legitimate baseline usage.

**5.3** `IMMEDIATE` frequency requires an **SNS subscriber**. Per-anomaly instant delivery is only implemented over SNS; the EMAIL subscriber type is supported for `DAILY` and `WEEKLY` digests only. Route through SNS (which can then fan out to email, Lambda, Chatbot/Slack, or PagerDuty) if you need immediate notification.

**5.4** Submit **`PLANNED_ACTIVITY`**. This tells the model the spike was expected business activity rather than a genuine anomaly or a detection error, so the pattern is incorporated into the baseline and does not generate a fresh alert next November. Submitting `NO` (false positive) is the wrong signal — it teaches the model to discount CloudFront spikes generally, including the unplanned one you do want to hear about.

**5.5** **Nothing.** AWS Cost Anomaly Detection is free, including monitors, subscriptions and notifications. There is no reason not to enable a `DIMENSIONAL`/`SERVICE` monitor in every payer account on day one.

---

### Block 6 — CUR / Data Exports

**6.1** Any two of: **hourly (and resource-level) granularity for arbitrary history**, whereas Cost Explorer's hourly data is limited to 14 days; **every billing column** (~300 fields — pricing terms, reservation ARNs, discount details, split cost allocation data) versus Cost Explorer's fixed dimensions; **arbitrary SQL** via Athena/Redshift instead of two group-by clauses per request; **no per-request charge** for the data itself; **byte-level reconciliation with the invoice**, which aggregated Cost Explorer figures cannot provide.

**6.2** It is delivered to an **S3 bucket you own**, in the account and prefix you specify. **AWS charges nothing for producing or delivering the report** — you pay only for S3 storage and requests, plus any Athena/Redshift/QuickSight processing you layer on top.

**6.3** **Double counting caused by an unfiltered `line_item_line_item_type`.** The CUR contains many row types in the same table: `SavingsPlanCoveredUsage` rows show the covered usage (at USD 0.00 unblended) while `SavingsPlanRecurringFee` rows carry the actual money; `DiscountedUsage` pairs with `RIFee`; and `Tax`, `Credit`, `Refund` and `EdpDiscount` all coexist. Summing every row without filtering by line item type inflates the total. (A second, less common cause: the S3 prefix contains overlapping report versions because `CREATE_NEW_REPORT` was used and the Glue table matches both.)

**6.4** When you need an **immutable audit trail** — proving what the billing data said on a given day, for a financial audit, a customer dispute, or a reconciliation against a restated month. `CREATE_NEW_REPORT` preserves every delivered version instead of overwriting; the cost is unbounded S3 growth and a Glue table that must be pointed at a single version rather than the whole prefix.

**6.5** The CUR is **not immutable**. AWS refreshes it up to **three times a day** and restates prior data as charges finalise (credits applied, RI/SP allocation recalculated, tax computed, refunds posted). A job that assumes yesterday's file is final will produce numbers that silently disagree with the invoice. The correct pattern is to reload the whole open billing period on each run and deduplicate on `(bill_billing_period_start_date, identity_line_item_id, identity_time_interval)`.

---

### Block 7 — Consolidated billing

**7.1** Because tiered/volume pricing is applied to the **aggregated usage of the entire Organization**, not per account. Four separate bills each start at the highest (most expensive) tier and never accumulate enough usage to reach the cheaper tiers. One consolidated bill sums the usage first, so the combined total reaches a lower price tier and part of the storage is billed at the discounted rate. The same aggregation applies to data transfer.

**7.2** Under consolidated billing, **RI and Savings Plans discount sharing is enabled by default**, so account A's unused Reserved Instance is automatically applied to account B's matching On-Demand usage — the benefit follows the usage, not the purchase. To keep the benefit exclusive to A, the payer must **turn off discount sharing for the other accounts** (or for all but A) in Billing → Preferences. Alternatively, a *size-flexible regional* RI could be converted to a *zonal* RI, which does not float, but the supported control is the sharing preference.

**7.3** **Only their own account's costs.** Cost Explorer in a member account is scoped to that account. The `LINKED_ACCOUNT` dimension and the full Organization view are available only in the management account (or in an account designated as a delegated administrator for billing).

**7.4** **No.** Service Control Policies are a feature of `FeatureSet: ALL`. With `CONSOLIDATED_BILLING` only, there are no SCPs to apply, so an `APPLY_SCP` budget action cannot be configured. You would need to enable all features in the Organization first — which requires every member account to accept the change and cannot be undone.

**7.5** **Blended cost**, in the narrow case of internal chargeback across accounts that share reservations. Unblended cost would credit the whole discount to whichever account happened to purchase the RI and charge the consuming accounts an artificially distorted rate; blended spreads the averaged rate across all accounts consuming the same instance type, which is the fairer internal allocation. For anything invoice-facing — reconciliation, accounts payable, forecasting the actual bill — use **unblended** (cash) or **amortized** (accrual). Note that most mature FinOps practices now prefer amortized over blended, because blended is an average that reconciles to nothing.

---

### Block 8 — Estimation

**8.1** The **AWS Pricing Calculator** (`calculator.aws`). It is a public web tool requiring no AWS account, no credentials and no deployed resources — the only pre-deployment estimation tool in this topic. (The Price List Query API is also free but does require credentials.)

**8.2** Most likely **`operatingSystem`** — you matched a Windows or RHEL SKU instead of Linux. The other high-probability omissions are **`preInstalledSw`** (matching the SQL Server-bundled SKU) and **`tenancy`** (matching Dedicated instead of Shared). All three return a legitimate, higher price with no error, because you asked a valid question about a different product.

**8.3** Any two of: the estimate uses **public list (On-Demand) prices** while the real bill benefits from Savings Plans, Reserved Instances, an Enterprise Discount Program rate or credits; the estimate assumes **100% utilisation for the stated period** while real instances are stopped, scaled down out of hours, or never reach the assumed size; **Free Tier** allowances were not modelled; the traffic/storage volumes entered were conservative guesses that reality did not reach.

**8.4** **Nothing.** The AWS Price List Query API is free. It serves the public price list, so it exposes no account-specific information and carries no per-request charge — unlike the Cost Explorer API at USD 0.01 per request, which serves your private usage data.

---

### Block 9 — Optimisation recommendations

**9.1** **AWS Compute Optimizer** is free and available to every account regardless of support plan (only the optional enhanced-metrics/extended-lookback feature is paid). **AWS Trusted Advisor**'s full cost-optimization check set requires **Business, Enterprise On-Ramp or Enterprise Support**; Basic and Developer plans get only a limited core set, and the `support` API itself returns `SubscriptionRequiredException` below Business.

**9.2** Because **Compute Optimizer does not see memory by default**. Its EC2 analysis is built on the CloudWatch metrics EC2 publishes natively — CPU, network, disk — and memory utilisation requires the CloudWatch agent to be installed and publishing. A JVM with a large heap can sit at 6% CPU while consuming 90% of RAM; downsizing it on CPU evidence alone causes OOM kills in production. Verify memory (and any burst/latency SLO) before acting on an `OVER_PROVISIONED` finding.

**9.3** It protects you from recommending downsizes whose savings will not materialise. With `BenefitsConsidered: true`, the analysis accounts for existing Reserved Instance and Savings Plans coverage. An instance already covered by a commitment costs you nothing extra at the margin — shrinking it does not reduce the bill, it just leaves the commitment underutilised, and you may end up paying for unused reservation *plus* the same workload. Set to `false` you get a savings number that assumes everything is On-Demand.

**9.4** **Cost optimization, performance, security, fault tolerance, and service limits** (AWS also surfaces an *operational excellence* category). The complete check set is unlocked by **Business, Enterprise On-Ramp and Enterprise** support plans. Basic and Developer receive only a limited set of core checks (primarily service limits and a few security checks).

**9.5** `EstimatedUtilization` predicts **what percentage of the recommended Savings Plan commitment your usage would actually consume** — 99.4% means almost none of the hourly commitment would be wasted. A low value is dangerous because a Savings Plan bills you the committed hourly rate **whether or not you use it**: at 60% utilisation you pay for 40% of nothing, and the "savings" can easily turn into a net loss versus On-Demand. Recommendations are built from a 7/30/60-day lookback, so any planned architecture change (a migration to Fargate, a datacentre-style teardown) invalidates the projection.

---

### Block 10 — Billing alarms and Free Tier

**10.1** (a) **"Receive CloudWatch billing alerts" is not enabled** in the management account's Billing preferences, so the `AWS/Billing` namespace is never populated. (b) The alarm was **created in a region other than `us-east-1`**, where the `EstimatedCharges` metric does not exist. A third possibility: the alarm was created in a *member* account — the metric is published only in the payer account.

**10.2** `EstimatedCharges` is a **cumulative month-to-date counter**, published roughly every 6 hours and monotonically increasing through the month. `Maximum` returns the latest, highest value in the evaluation period, which is the true month-to-date figure; `Average` would return a meaningless midpoint of a rising counter and `Sum` would multiply the total by the number of datapoints. The value collapses on the 1st because a new billing period begins and the counter restarts near zero.

**10.3** Any three of: **filtering by service, linked account, tag, Cost Category or region** (the alarm can only see the account-wide total, optionally per service); **forecast-based alerting** (`FORECASTED` notifications); **budget actions** that apply an IAM policy or SCP or stop EC2/RDS instances; **usage, RI-utilisation, RI-coverage and Savings-Plans budget types** rather than cost only; **multiple thresholds with different subscribers on one budget**; **daily, monthly, quarterly and annual periods**.

**10.4** **Always Free** — never expires, e.g. 1 million AWS Lambda requests per month, or 25 GB of DynamoDB storage. **12 Months Free** — available for the first year after account creation, e.g. 750 hours/month of EC2 `t2.micro`/`t3.micro`, or 5 GB of S3 Standard. **Trials** — short-term, service-specific, starting when you first activate the service, e.g. a 30-day Amazon Inspector trial or 750 hours of Amazon SageMaker Studio notebooks for 2 months.

---

### Block 11 — Billing Conductor and cleanup

**11.1** **No.** AWS charges you exactly the same amount; the real invoice is unaffected. Billing Conductor produces a **pro forma** billing view — a parallel rendering of the same underlying usage with your markups, discounts and custom line items applied — used to bill internal business units or end customers. Its own cost is a per-billing-group-account monthly charge, which *does* appear on your real bill.

**11.2** **Cost Categories group the real bill** into business dimensions without changing any amount; **Billing Conductor generates a second, modified bill** with different amounts (markups, discounts, custom line items) for chargeback or resale, leaving the real AWS invoice untouched.

**11.3** Deleting the export only **stops future deliveries**. Every Parquet file already written to the S3 prefix remains and continues to accrue storage charges — potentially for years, since a resource-level hourly CUR grows fast. You must empty the prefix separately (or attach a lifecycle rule) to stop paying for it.

**11.4** Because an anomaly **subscription references its monitor by ARN**. Deleting a monitor that still has subscriptions attached fails with a dependency error — the same referential-integrity ordering that applies to SNS topics with subscriptions or IAM roles with attached policies. Delete the dependent object first, then the object it depends on.

</details>