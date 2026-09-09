# gcp-cdl · 6.1 — Guided Exercises

## Recognize how Google Cloud supports an organization's ability to control their cloud costs

> **Exam weight:** 5.0 · **Exam version:** 2026-08-12
> **Objective source:** [Cloud Digital Leader exam guide](https://services.google.com/fh/files/misc/cloud_digital_leader_exam_guide_english.pdf)

The Cloud Digital Leader exam asks you to *recognize* the mechanisms. This lab makes you *operate* them, because the conceptual distinctions the exam tests — budget vs. quota, gross cost vs. net cost, label vs. tag, project vs. billing account — are exactly the distinctions that become unambiguous the moment you run the command and read the output.

Every block is a set of numbered steps followed by comprehension questions. Answers are in the collapsible section at the end. Do not read them until you have written yours down.

---

## Prerequisites and cost warning

| Requirement | Why |
|---|---|
| A Cloud Billing account you administer (`roles/billing.admin`) | Budgets, exports and hierarchy commands are billing-account scoped |
| An organization node, or at least a standalone project | Exercises 1 and 7 need a hierarchy; standalone project users skip the folder steps |
| `gcloud` ≥ 470.0.0, `bq`, `terraform` ≥ 1.5 (optional) | Some commands live in `beta`/`alpha` surfaces |
| A BigQuery dataset you can create | Billing export destination |

**Real money is involved.** BigQuery billing export storage and query costs are small (cents), but Exercise 6 creates a VM. The cleanup section at the end is not optional. Nothing in this lab commits you to a Committed Use Discount — read step warnings before pressing enter.

Set your working variables once:

```bash
export BILLING_ACCOUNT_ID="012345-6789AB-CDEF01"   # gcloud billing accounts list
export PROJECT_ID="finops-lab-001"
export REGION="us-central1"
export ZONE="us-central1-a"
export DATASET="finops_billing"

# The BigQuery table suffix is the billing account ID with dashes turned into underscores
export BA_SUFFIX="${BILLING_ACCOUNT_ID//-/_}"      # 012345_6789AB_CDEF01
echo "$BA_SUFFIX"
```

---

## Exercise 1 — Where cost is attributed: the resource hierarchy and the billing account

The single most common misconception on this objective is that the Cloud Billing account is *part of* the resource hierarchy. It is not. The hierarchy (Organization → Folder → Project → resource) is the **IAM and policy** structure. The Cloud Billing account is a separate, external payment instrument that is **attached** to projects. Cost is metered against the **project**, and rolls up through folders only because reporting tools re-join the project to its hierarchy path.

### Steps

1. List the billing accounts you can see and note the `OPEN` column:

   ```bash
   gcloud billing accounts list
   ```

   ```
   ACCOUNT_ID            NAME                    OPEN  MASTER_ACCOUNT_ID
   012345-6789AB-CDEF01  Corp Billing - Prod     True
   0AB1CD-2E3F45-6789GH  Corp Billing - Sandbox  True  012345-6789AB-CDEF01
   ```

   The second row has a `MASTER_ACCOUNT_ID`: it is a **subaccount**, a billing container whose charges roll up to the parent. Resellers and large enterprises use subaccounts to isolate a business unit's invoice without splitting the contract.

2. Print the hierarchy position of your project:

   ```bash
   gcloud projects describe "$PROJECT_ID"
   ```

   ```yaml
   createTime: '2026-09-09T12:04:11.402Z'
   lifecycleState: ACTIVE
   name: finops-lab-001
   parent:
     id: '482910375512'
     type: folder
   projectId: finops-lab-001
   projectNumber: '739104857260'
   ```

   Record the **project number** (`739104857260`). Budgets filter on `projects/<PROJECT_NUMBER>`, not on the project ID — a frequent cause of a budget that silently matches nothing.

3. Print the billing attachment, which is a *different* API surface (`cloudbilling`, not `cloudresourcemanager`):

   ```bash
   gcloud billing projects describe "$PROJECT_ID"
   ```

   ```yaml
   billingAccountName: billingAccounts/012345-6789AB-CDEF01
   billingEnabled: true
   name: projects/finops-lab-001/billingInfo
   projectId: finops-lab-001
   ```

4. List every project currently charging to the account. In a real estate this is the first line of a cost review — an unexpected project here is an unowned cost centre:

   ```bash
   gcloud billing projects list --billing-account="$BILLING_ACCOUNT_ID" \
     --format="table(projectId, billingEnabled)"
   ```

   ```
   PROJECT_ID           BILLING_ENABLED
   finops-lab-001       True
   platform-prod-eu     True
   legacy-datalake-01   True
   ```

5. Walk the folder path upward to see what a cost rollup would aggregate:

   ```bash
   gcloud resource-manager folders describe 482910375512 \
     --format="value(displayName, parent)"
   ```

   ```
   engineering	organizations/318472019283
   ```

6. **Do not run this against anything you care about.** Read it only. This is how a project is detached from billing — the "kill switch" Exercise 4 automates:

   ```bash
   # gcloud billing projects unlink "$PROJECT_ID"
   ```

### Comprehension check

- **Q1.** A project is moved from folder `engineering` to folder `research`. Its billing account is unchanged. Does historical cost data move with it in Cloud Billing reports?
- **Q2.** Can one project be charged to two Cloud Billing accounts simultaneously? Can one Cloud Billing account pay for projects in two different organizations?
- **Q3.** You want the Data Platform business unit to receive its own invoice while remaining under the corporate contract and negotiated discounts. Which construct from step 1 do you use, and why not "a second billing account"?
- **Q4.** Step 2 returned `projectNumber: '739104857260'` and `projectId: finops-lab-001`. Which one goes into a budget filter, and what is the failure mode of using the other?

---

## Exercise 2 — Labels: the only dimension that makes cost allocable

Cost attribution beyond "per project" exists only if resources carry labels, and labels only appear in billing data **from the moment they are applied forward**. There is no backfill. This is the operational reason label governance is a day-one decision rather than a cleanup task.

### Steps

1. Apply a label set to the project itself. Project labels answer "who owns this project":

   ```bash
   gcloud projects update "$PROJECT_ID" \
     --update-labels=cost-center=eng-platform,env=lab,owner=sre-team
   ```

   ```yaml
   labels:
     cost-center: eng-platform
     env: lab
     owner: sre-team
   name: finops-lab-001
   projectId: finops-lab-001
   ```

2. Create a labelled VM. Resource labels answer "which workload inside the project":

   ```bash
   gcloud compute instances create finops-lab-vm \
     --project="$PROJECT_ID" \
     --zone="$ZONE" \
     --machine-type=e2-small \
     --image-family=debian-12 \
     --image-project=debian-cloud \
     --labels=cost-center=eng-platform,workload=demo-api,env=lab
   ```

   ```
   Created [https://www.googleapis.com/compute/v1/projects/finops-lab-001/zones/us-central1-a/instances/finops-lab-vm].
   NAME           ZONE           MACHINE_TYPE  INTERNAL_IP  EXTERNAL_IP    STATUS
   finops-lab-vm  us-central1-a  e2-small      10.128.0.12  34.72.118.204  RUNNING
   ```

3. Find every unlabelled resource in the project — the population that will show up as unallocated spend. Cloud Asset Inventory does this without touching each service's API:

   ```bash
   gcloud asset search-all-resources \
     --scope="projects/$PROJECT_ID" \
     --query="NOT labels.cost-center:*" \
     --format="table(assetType, displayName, location)"
   ```

   ```
   ASSET_TYPE                              DISPLAY_NAME     LOCATION
   compute.googleapis.com/Disk             finops-lab-vm    us-central1-a
   compute.googleapis.com/Network          default          global
   compute.googleapis.com/Firewall         default-allow-ssh global
   ```

   Note that the boot disk is a **separate billable resource** and did not inherit the instance's labels. Persistent disks are billed independently of the VM and keep billing while the VM is stopped.

4. Fix the disk:

   ```bash
   gcloud compute disks add-labels finops-lab-vm \
     --zone="$ZONE" \
     --labels=cost-center=eng-platform,workload=demo-api,env=lab
   ```

5. Read the constraint set that governs label keys — it is not arbitrary text:

   ```bash
   gcloud projects update "$PROJECT_ID" --update-labels=Cost_Center=X 2>&1 | head -3
   ```

   ```
   ERROR: (gcloud.projects.update) INVALID_ARGUMENT: Label keys must start with a lowercase letter
   and can only contain lowercase letters, numeric characters, underscores and dashes.
   ```

### Comprehension check

- **Q5.** Labels and tags both attach key/value metadata to resources. Which of the two appears as a cost-allocation dimension in billing export, and what is the other one actually for?
- **Q6.** You apply `cost-center=eng-platform` to a VM that has been running for six months. What does the January bill for that VM show under that label?
- **Q7.** In step 3 the boot disk had no labels even though the VM did. Give two billing consequences of this that a monthly report would reveal.
- **Q8.** A team argues that per-project separation makes labels unnecessary: "one project per team, done." State the strongest technical argument against relying on project boundaries alone for allocation.

---

## Exercise 3 — Billing export to BigQuery, and the gross-vs-net trap

The Console reports are a view. The authoritative, joinable, retainable record is the BigQuery export. Two facts dominate every query you will ever write against it: **credits are a repeated field, and their amounts are negative**; and **the export does not backfill**.

### Steps

1. Create the destination dataset. Colocate it with your reporting region — cross-region query of a billing dataset is a recurring, avoidable cost:

   ```bash
   bq --location=US mk --dataset \
     --description="Cloud Billing export" \
     "${PROJECT_ID}:${DATASET}"
   ```

   ```
   Dataset 'finops-lab-001:finops_billing' successfully created.
   ```

2. Enable the export. This step is Console-only for the initial configuration:
   **Billing → Billing export → BigQuery export → Standard usage cost → Edit settings**, select the project and dataset, save. Repeat for **Detailed usage cost**.

3. Wait. First rows typically appear within a few hours; a full day of data settles over roughly 24 hours. Verify the tables materialized:

   ```bash
   bq ls "${PROJECT_ID}:${DATASET}"
   ```

   ```
                   tableId                    Type    Labels   Time Partitioning
    ---------------------------------------- ------- -------- -------------------
     gcp_billing_export_v1_012345_6789AB_CDEF01           TABLE            DAY (field: _PARTITIONTIME)
     gcp_billing_export_resource_v1_012345_6789AB_CDEF01  TABLE            DAY (field: _PARTITIONTIME)
   ```

4. Run the net-cost query. This is the single most important SQL pattern on this objective:

   ```sql
   SELECT
     service.description AS service,
     ROUND(SUM(cost), 2) AS gross_cost,
     ROUND(SUM(IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) AS c), 0)), 2) AS credits,
     ROUND(SUM(cost)
           + SUM(IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) AS c), 0)), 2) AS net_cost
   FROM `finops-lab-001.finops_billing.gcp_billing_export_v1_012345_6789AB_CDEF01`
   WHERE _PARTITIONTIME >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 30 DAY)
     AND cost_type = 'regular'
   GROUP BY service
   ORDER BY net_cost DESC
   LIMIT 10;
   ```

   ```
   +--------------------------+------------+----------+----------+
   | service                  | gross_cost | credits  | net_cost |
   +--------------------------+------------+----------+----------+
   | Compute Engine           |     412.88 |  -103.22 |   309.66 |
   | Cloud Storage            |      88.14 |    -4.40 |    83.74 |
   | Networking               |      61.07 |     0.00 |    61.07 |
   | BigQuery                 |      12.93 |   -12.93 |     0.00 |
   +--------------------------+------------+----------+----------+
   ```

   BigQuery nets to zero here because free-tier credits covered it. A report that showed only `gross_cost` would send someone to optimize a query workload that costs nothing.

5. Split allocated from unallocated spend. Note carefully which `labels` column you are reading:

   ```sql
   SELECT
     project.id AS project_id,
     IFNULL((SELECT l.value FROM UNNEST(labels) AS l WHERE l.key = 'cost-center'),
            '(unallocated)') AS resource_cost_center,
     IFNULL((SELECT l.value FROM UNNEST(project.labels) AS l WHERE l.key = 'cost-center'),
            '(unallocated)') AS project_cost_center,
     ROUND(SUM(cost)
           + SUM(IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) AS c), 0)), 2) AS net_cost
   FROM `finops-lab-001.finops_billing.gcp_billing_export_v1_012345_6789AB_CDEF01`
   WHERE _PARTITIONTIME >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 7 DAY)
   GROUP BY 1, 2, 3
   ORDER BY net_cost DESC;
   ```

   ```
   +------------------+----------------------+---------------------+----------+
   | project_id       | resource_cost_center | project_cost_center | net_cost |
   +------------------+----------------------+---------------------+----------+
   | platform-prod-eu | (unallocated)        | eng-platform        |    91.44 |
   | finops-lab-001   | eng-platform         | eng-platform        |     6.02 |
   +------------------+----------------------+---------------------+----------+
   ```

   Top-level `labels` are **resource** labels. `project.labels` are project labels. `system_labels` are Google-applied (machine spec, GKE cluster name). Confusing the first two produces an allocation report that is quietly wrong.

6. Confirm what the detailed export buys you that the standard one cannot:

   ```sql
   SELECT
     resource.name AS resource,
     sku.description AS sku,
     ROUND(SUM(cost), 4) AS cost
   FROM `finops-lab-001.finops_billing.gcp_billing_export_resource_v1_012345_6789AB_CDEF01`
   WHERE _PARTITIONTIME >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 2 DAY)
     AND service.description = 'Compute Engine'
   GROUP BY 1, 2
   ORDER BY cost DESC
   LIMIT 5;
   ```

   ```
   +------------------------------------------------------+----------------------------------+--------+
   | resource                                             | sku                              | cost   |
   +------------------------------------------------------+----------------------------------+--------+
   | //compute.googleapis.com/.../instances/finops-lab-vm | E2 instance Core running in Am.. | 0.3110 |
   | //compute.googleapis.com/.../disks/finops-lab-vm     | Storage PD Capacity              | 0.0224 |
   +------------------------------------------------------+----------------------------------+--------+
   ```

### Comprehension check

- **Q9.** Why is `credits` an `ARRAY<STRUCT>` rather than a single numeric column, and what does a negative `amount` mean?
- **Q10.** A CFO asks for the last 18 months of per-service spend. You enabled BigQuery export three weeks ago. What can you deliver and what cannot be recovered?
- **Q11.** You filter `WHERE cost_type = 'regular'`. Name the other values this column takes and state one scenario where excluding them makes your report wrong.
- **Q12.** A report groups by top-level `labels` and shows 80% of Compute Engine spend as `(unallocated)`, while every project carries `cost-center`. What is the bug?
- **Q13.** Standard vs. detailed export: state the trade-off in one sentence, including the cost of the detailed one.

---

## Exercise 4 — Budgets and alerts: a notification system, not a spending cap

This is the highest-yield conceptual point of the objective. **A budget does not stop anything.** It compares actual (or forecasted) spend against a threshold and emits a message. Stopping spend requires a separate, deliberate action.

### Steps

1. Create a budget with four threshold rules — three on actual spend, one on the forecast:

   ```bash
   gcloud billing budgets create \
     --billing-account="$BILLING_ACCOUNT_ID" \
     --display-name="platform-monthly-usd1000" \
     --budget-amount=1000USD \
     --calendar-period=month \
     --filter-projects="projects/739104857260" \
     --filter-labels="cost-center=eng-platform" \
     --filter-credit-types-treatment=include-all-credits \
     --threshold-rule=percent=0.5 \
     --threshold-rule=percent=0.9 \
     --threshold-rule=percent=1.0 \
     --threshold-rule=percent=1.0,basis=forecasted-spend
   ```

   ```
   Created budget [billingAccounts/012345-6789AB-CDEF01/budgets/8f3c9a71-2b4d-4e0a-9c11-77f2b0d4e5aa].
   ```

2. Read it back as the API sees it. This is the canonical resource shape:

   ```bash
   gcloud billing budgets describe \
     "billingAccounts/${BILLING_ACCOUNT_ID}/budgets/8f3c9a71-2b4d-4e0a-9c11-77f2b0d4e5aa" \
     --format=json
   ```

   ```json
   {
     "amount": {
       "specifiedAmount": { "currencyCode": "USD", "units": "1000" }
     },
     "budgetFilter": {
       "calendarPeriod": "MONTH",
       "creditTypesTreatment": "INCLUDE_ALL_CREDITS",
       "labels": { "cost-center": { "values": ["eng-platform"] } },
       "projects": ["projects/739104857260"]
     },
     "displayName": "platform-monthly-usd1000",
     "etag": "aa11bb22cc33",
     "name": "billingAccounts/012345-6789AB-CDEF01/budgets/8f3c9a71-2b4d-4e0a-9c11-77f2b0d4e5aa",
     "thresholdRules": [
       { "thresholdPercent": 0.5 },
       { "thresholdPercent": 0.9 },
       { "thresholdPercent": 1.0 },
       { "thresholdPercent": 1.0, "spendBasis": "FORECASTED_SPEND" }
     ]
   }
   ```

   `spendBasis` is absent on the first three because `CURRENT_SPEND` is the default.

3. Declare the same budget as code. In any organization above a handful of projects, budgets are provisioned by the same pipeline that provisions the project:

   ```hcl
   resource "google_pubsub_topic" "budget_alerts" {
     project = var.project_id
     name    = "billing-budget-alerts"
   }

   resource "google_billing_budget" "platform_monthly" {
     billing_account = var.billing_account_id
     display_name    = "platform-monthly-usd1000"

     budget_filter {
       projects               = ["projects/${var.project_number}"]
       calendar_period        = "MONTH"
       credit_types_treatment = "INCLUDE_ALL_CREDITS"
       labels = {
         cost-center = "eng-platform"
       }
     }

     amount {
       specified_amount {
         currency_code = "USD"
         units         = "1000"
       }
     }

     threshold_rules { threshold_percent = 0.5 }
     threshold_rules { threshold_percent = 0.9 }
     threshold_rules { threshold_percent = 1.0 }
     threshold_rules {
       threshold_percent = 1.0
       spend_basis       = "FORECASTED_SPEND"
     }

     all_updates_rule {
       pubsub_topic                   = google_pubsub_topic.budget_alerts.id
       schema_version                 = "1.0"
       disable_default_iam_recipients = true
     }
   }
   ```

4. Wire programmatic notifications. Create the topic and grant publish rights to the Cloud Billing budgets service agent (the Console does this for you; the API does not):

   ```bash
   gcloud pubsub topics create billing-budget-alerts --project="$PROJECT_ID"

   gcloud pubsub topics add-iam-policy-binding billing-budget-alerts \
     --project="$PROJECT_ID" \
     --member="serviceAccount:${BUDGETS_SERVICE_AGENT}" \
     --role="roles/pubsub.publisher"
   ```

   Attach it to the existing budget:

   ```bash
   gcloud billing budgets update \
     "billingAccounts/${BILLING_ACCOUNT_ID}/budgets/8f3c9a71-2b4d-4e0a-9c11-77f2b0d4e5aa" \
     --all-updates-rule-pubsub-topic="projects/${PROJECT_ID}/topics/billing-budget-alerts" \
     --all-updates-rule-disable-default-iam-recipients
   ```

5. Inspect the message your consumer will receive. Messages are published on **every** data refresh, not only on threshold crossings — the consumer must decide:

   ```json
   {
     "budgetDisplayName": "platform-monthly-usd1000",
     "alertThresholdExceeded": 0.9,
     "costAmount": 913.44,
     "costIntervalStart": "2026-09-01T07:00:00Z",
     "budgetAmount": 1000.0,
     "budgetAmountType": "SPECIFIED_AMOUNT",
     "currencyCode": "USD"
   }
   ```

   Message attributes carry `billingAccountId`, `budgetId` and `schemaVersion`. When no threshold has been crossed, `alertThresholdExceeded` is absent.

6. **Read, understand, then decide.** This is the automated kill switch. It detaches the billing account from a project, which terminates every billable resource in it, including data on non-replicated disks:

   ```python
   # main.py — Cloud Functions (2nd gen), Pub/Sub trigger
   import base64
   import json
   import os

   from googleapiclient import discovery

   BILLING = discovery.build("cloudbilling", "v1", cache_discovery=False)
   TARGET = f"projects/{os.environ['TARGET_PROJECT_ID']}"


   def stop_billing(event, context):
       payload = json.loads(base64.b64decode(event["data"]).decode("utf-8"))

       if payload.get("costAmount", 0) <= payload.get("budgetAmount", 0):
           return f"under budget: {payload.get('costAmount')} <= {payload.get('budgetAmount')}"

       info = BILLING.projects().getBillingInfo(name=TARGET).execute()
       if not info.get("billingAccountName"):
           return "billing already disabled"

       BILLING.projects().updateBillingInfo(
           name=TARGET, body={"billingAccountName": ""}
       ).execute()
       return f"billing disabled for {TARGET}"
   ```

   ```txt
   # requirements.txt
   google-api-python-client==2.134.0
   ```

   The function's service account needs `roles/billing.projectManager` on the project **and** `roles/billing.user` on the billing account. Deploy this only against a project whose destruction is acceptable — a sandbox, a per-PR environment, a student lab. Never against production.

### Comprehension check

- **Q14.** Your budget is $1,000 with a 100% threshold. The month closes at $4,300 and no alert automation exists beyond email. What did the budget do, and what did it not do?
- **Q15.** What does a `FORECASTED_SPEND` threshold at 100% tell you that a `CURRENT_SPEND` threshold at 100% cannot, and when is the forecast least trustworthy?
- **Q16.** `creditTypesTreatment` is set to `INCLUDE_ALL_CREDITS`. Committed use discounts and a promotional credit are active. Against which figure is the threshold evaluated, and how would `EXCLUDE_ALL_CREDITS` change when the alert fires?
- **Q17.** In step 5 the Pub/Sub message arrives with no `alertThresholdExceeded` field. Should the consumer act? Why does Google publish these messages at all?
- **Q18.** Give two reasons the kill-switch function in step 6 is inappropriate for a production project, and name the control you would use there instead.
- **Q19.** A budget filtered on `projects/finops-lab-001` (project **ID**, not number) never fires. Explain.

---

## Exercise 5 — Quotas: the control that actually prevents spend

Budgets observe. Quotas **refuse**. A quota is a hard, service-enforced ceiling evaluated at the API call, so an exhausted quota returns an error instead of provisioning a resource. Lowering a quota is the cheapest, most reliable spend guardrail available, and it is underused because people think of quotas as something you only ever request more of.

### Steps

1. Read your regional Compute Engine quotas and current consumption:

   ```bash
   gcloud compute regions describe "$REGION" \
     --project="$PROJECT_ID" \
     --flatten="quotas[]" \
     --format="table(quotas.metric, quotas.usage, quotas.limit)"
   ```

   ```
   METRIC                    USAGE  LIMIT
   CPUS                      2.0    24.0
   DISKS_TOTAL_GB            10.0   4096.0
   IN_USE_ADDRESSES          1.0    8.0
   INSTANCES                 1.0    24.0
   SSD_TOTAL_GB              0.0    500.0
   PREEMPTIBLE_CPUS          0.0    24.0
   ```

2. Read the same thing through the Cloud Quotas API, which is the service-agnostic surface:

   ```bash
   gcloud beta quotas info list \
     --service=compute.googleapis.com \
     --project="$PROJECT_ID" \
     --format="table(quotaId, metric, isPrecise)" | head -8
   ```

   ```
   QUOTA_ID                       METRIC                                 IS_PRECISE
   CPUS-per-project-region        compute.googleapis.com/cpus            True
   INSTANCES-per-project-region   compute.googleapis.com/instances       True
   read-requests-per-minute       compute.googleapis.com/read_requests   False
   ```

   `isPrecise: True` marks an **allocation** quota (a count of things that exist). `False` marks a **rate** quota (calls per unit of time). They fail differently: allocation quotas block creation; rate quotas return `429 RESOURCE_EXHAUSTED` and are meant to be retried with backoff.

3. Lower an allocation quota below what a runaway automation could consume:

   ```bash
   gcloud beta quotas preferences create cpus-cap-us-central1 \
     --service=compute.googleapis.com \
     --quota-id=CPUS-per-project-region \
     --preferred-value=8 \
     --dimensions=region="$REGION" \
     --project="$PROJECT_ID" \
     --email="platform-oncall@example.com" \
     --justification="Cap lab spend at 8 vCPU in us-central1"
   ```

   ```
   Created quota preference [projects/739104857260/locations/global/quotaPreferences/cpus-cap-us-central1].
   ```

4. Prove the ceiling is enforced. Ask for more vCPU than remains:

   ```bash
   gcloud compute instances create quota-probe \
     --project="$PROJECT_ID" --zone="$ZONE" --machine-type=n2-standard-16
   ```

   ```
   ERROR: (gcloud.compute.instances.create) Could not fetch resource:
    - Quota 'CPUS' exceeded.  Limit: 8.0 in region us-central1.
   ```

   No instance was created. No charge was incurred. Compare with the budget in Exercise 4, which would have sent an email after the fact.

5. Set the complementary guardrail at the billing account level — the one that stops a *new* project from ever charging you:

   ```bash
   gcloud beta billing accounts get-iam-policy "$BILLING_ACCOUNT_ID" \
     --format="table(bindings.role, bindings.members)"
   ```

   ```
   ROLE                          MEMBERS
   roles/billing.admin           ['user:finops-lead@example.com']
   roles/billing.user            ['group:platform-eng@example.com']
   roles/billing.viewer          ['group:all-engineers@example.com']
   ```

   Only `roles/billing.user` (plus `roles/billing.projectManager` on the project) can attach a project to this account. Removing that binding from a broad group is a spend control in its own right.

### Comprehension check

- **Q20.** State the difference between a budget and a quota in terms of *when* each one acts relative to the spend.
- **Q21.** An allocation quota and a rate quota are both exhausted. Describe the different symptom an application sees in each case, and the different remediation.
- **Q22.** A team requests a CPU quota increase to 500 in three regions "to be safe." Give the cost-governance argument for granting only what the current workload needs.
- **Q23.** Quotas are per project per region. What does that imply for an organization that wants a single organization-wide compute ceiling?

---

## Exercise 6 — Pricing models and Active Assist: paying less for the same thing

Cost control is not only "use less." Google Cloud reduces the unit price through mechanisms that are automatic (sustained use discounts), contractual (committed use discounts), or opportunistic (Spot). Active Assist recommenders surface where each applies.

### Steps

1. Query the public price of a SKU directly from the Cloud Catalog API. Compute Engine's service ID is `6F81-5844-456A`:

   ```bash
   curl -s -H "Authorization: Bearer $(gcloud auth print-access-token)" \
     "https://cloudbilling.googleapis.com/v1/services/6F81-5844-456A/skus?pageSize=200" \
   | jq -r '.skus[]
       | select(.description | test("N2 Instance Core running in Americas"))
       | {sku: .description,
          usage: .category.usageType,
          unit: .pricingInfo[0].pricingExpression.usageUnitDescription,
          nanos: .pricingInfo[0].pricingExpression.tieredRates[0].unitPrice.nanos}'
   ```

   ```json
   {
     "sku": "N2 Instance Core running in Americas",
     "usage": "OnDemand",
     "unit": "hour",
     "nanos": 31611000
   }
   {
     "sku": "Spot Preemptible N2 Instance Core running in Americas",
     "usage": "Preemptible",
     "unit": "hour",
     "nanos": 7653000
   }
   ```

   `nanos` are billionths of a unit of currency: 31,611,000 nanos = $0.031611 per vCPU-hour on demand, versus $0.007653 Spot. That ratio — roughly 75–80% off — is why batch and fault-tolerant workloads belong on Spot.

2. Ask for idle-resource recommendations. These are generated from observed utilization over a trailing window:

   ```bash
   gcloud recommender recommendations list \
     --project="$PROJECT_ID" \
     --location="$ZONE" \
     --recommender=google.compute.instance.IdleResourceRecommender \
     --format="table(name.basename(), primaryImpact.costProjection.cost.units, description)"
   ```

   ```
   NAME                                  UNITS  DESCRIPTION
   0f2a1c88-6d3e-4a1b-9e70-31c0a2f4bb19  -24    Save cost by stopping idle VM 'legacy-jenkins'.
   ```

   The sign convention matters: `costProjection.cost.units = -24` means **$24/month saved**, not $24 spent. Positive values indicate a recommendation that increases cost (a rightsizing that scales *up* for reliability).

3. Ask for machine-type rightsizing on the same scope:

   ```bash
   gcloud recommender recommendations list \
     --project="$PROJECT_ID" --location="$ZONE" \
     --recommender=google.compute.instance.MachineTypeRecommender \
     --format="value(description)"
   ```

   ```
   Save cost by changing machine type from n2-standard-8 to n2-standard-2.
   ```

4. Ask for commitment recommendations. **Reading these costs nothing; acting on one creates a binding 1- or 3-year contract.** Do not purchase in this lab:

   ```bash
   gcloud recommender recommendations list \
     --billing-account="$BILLING_ACCOUNT_ID" \
     --location=global \
     --recommender=google.cloudbilling.commitment.SpendBasedCommitmentRecommender \
     --format="table(name.basename(), primaryImpact.costProjection.cost.units, stateInfo.state)"
   ```

   ```
   NAME                                  UNITS  STATE
   c41b7e02-9a55-4d31-8f6c-2ad9e7c81d40  -1180  ACTIVE
   ```

5. Compare the three price-reduction mechanisms on the resource you already have. No command — reason from the table:

   | Mechanism | How you get it | Commitment | Typical discount | Risk |
   |---|---|---|---|---|
   | Sustained use discount | Automatic, per eligible machine family, as monthly usage accumulates | None | Up to ~30% on eligible families | None; eligibility varies by family |
   | Committed use discount | Purchased for 1 or 3 years, resource-based or spend-based | Binding | ~20–70% depending on term | You pay for the commitment whether or not you use it |
   | Spot VMs | Request `--provisioning-model=SPOT` | None | Up to ~91% | Preemption with 30 s notice; not for stateful, latency-critical work |

6. Estimate before you build. The [Google Cloud Pricing Calculator](https://cloud.google.com/products/calculator) produces a shareable estimate; step 1's Catalog API is what you use when the estimate must be generated by a pipeline rather than a person.

### Comprehension check

- **Q24.** Sustained use discounts and committed use discounts both lower the price of Compute Engine. State the decision rule for choosing between them for a given workload.
- **Q25.** A team commits to 3 years of 100 vCPU, then migrates the workload to GKE Autopilot after 8 months. What happens to the commitment charge?
- **Q26.** Step 2 returned `units: -24`. Interpret the sign, and explain why a recommender would ever emit a positive value.
- **Q27.** Spot VMs are ~80–90% cheaper. Name two workload characteristics that make Spot a correct choice, and one that makes it a wrong one.

---

## Exercise 7 — Governance guardrails: separation of duties and organization policy

Cost control that depends on people remembering is not a control. Two structural mechanisms make the desired behaviour the default: **billing IAM roles** that separate who spends from who pays, and **organization policy** that constrains what can be created at all.

### Steps

1. Examine the billing role set and what each one can actually do:

   ```bash
   gcloud iam roles describe roles/billing.costsManager \
     --format="value(description, includedPermissions)" | tr ',' '\n' | head -12
   ```

   ```
   Manage budgets and view/export cost information of billing accounts.
   billing.accounts.get
   billing.accounts.getSpendingInformation
   billing.budgets.create
   billing.budgets.delete
   billing.budgets.get
   billing.budgets.list
   billing.budgets.update
   ```

   | Role | Grants |
   |---|---|
   | `roles/billing.creator` (org level) | Create new billing accounts |
   | `roles/billing.admin` | Full control: budgets, exports, IAM, link/unlink projects |
   | `roles/billing.user` | Link a project to this billing account — the "can spend my money" role |
   | `roles/billing.projectManager` (project level) | Link/unlink billing on that project |
   | `roles/billing.costsManager` | Budgets, cost views and exports; **not** pricing or transactions |
   | `roles/billing.viewer` | Read cost data only |

   The important structural fact: `roles/owner` on a project does **not** include the right to attach that project to a billing account. That split is deliberate, and it is what lets a platform team delegate project ownership without delegating spend.

2. Apply a location constraint. Region choice is a price lever — the same SKU differs materially between regions — and a locations policy also serves data residency:

   ```yaml
   # policy-locations.yaml
   name: projects/finops-lab-001/policies/gcp.resourceLocations
   spec:
     rules:
       - values:
           allowedValues:
             - in:us-central1-locations
             - in:europe-west1-locations
   ```

   ```bash
   gcloud org-policies set-policy policy-locations.yaml
   ```

   ```
   Created policy [projects/finops-lab-001/policies/gcp.resourceLocations].
   ```

3. Verify it bites:

   ```bash
   gcloud compute instances create wrong-region-vm \
     --project="$PROJECT_ID" --zone=asia-south1-a --machine-type=e2-small \
     --image-family=debian-12 --image-project=debian-cloud
   ```

   ```
   ERROR: (gcloud.compute.instances.create) Could not fetch resource:
    - Constraint constraints/gcp.resourceLocations violated for projects/finops-lab-001.
      asia-south1-a violates constraint constraints/gcp.resourceLocations
   ```

4. Restrict machine sizes with a custom constraint — the direct analogue of a spend ceiling expressed as policy. Custom constraints are defined at the organization node:

   ```yaml
   # constraint-machine-types.yaml
   name: organizations/318472019283/customConstraints/custom.allowedMachineTypes
   resourceTypes:
     - compute.googleapis.com/Instance
   methodTypes:
     - CREATE
     - UPDATE
   condition: "resource.machineType.contains('/machineTypes/e2-') || resource.machineType.contains('/machineTypes/n2-standard-2') || resource.machineType.contains('/machineTypes/n2-standard-4')"
   actionType: ALLOW
   displayName: Allow only small e2 and n2-standard-2/4 machine types
   description: Prevents accidental provisioning of large, expensive machine types.
   ```

   ```bash
   gcloud org-policies set-custom-constraint constraint-machine-types.yaml
   ```

   ```yaml
   # policy-machine-types.yaml
   name: projects/finops-lab-001/policies/custom.allowedMachineTypes
   spec:
     rules:
       - enforce: true
   ```

   ```bash
   gcloud org-policies set-policy policy-machine-types.yaml
   ```

5. Inspect the effective policy on the project, including everything inherited from folders and the organization:

   ```bash
   gcloud org-policies describe gcp.resourceLocations \
     --project="$PROJECT_ID" --effective
   ```

   ```yaml
   name: projects/739104857260/policies/gcp.resourceLocations
   spec:
     rules:
     - values:
         allowedValues:
         - in:us-central1-locations
         - in:europe-west1-locations
   ```

### Comprehension check

- **Q28.** A developer has `roles/owner` on a new project and cannot enable an API because the project has no billing account. Which role, on which resource, is missing — and why is this separation valuable rather than annoying?
- **Q29.** An organization policy sets `gcp.resourceLocations` at the org node. A folder below sets a broader list. What is the effective policy for a project in that folder by default, and what would have to change for the folder's list to win?
- **Q30.** Compare the custom constraint of step 4 with the quota of Exercise 5 as ways of preventing an expensive VM. Give one scenario each where the other mechanism would have failed.
- **Q31.** Why is `roles/billing.viewer` on a broad engineering group a cost-control measure and not just a transparency measure?

---

## Exercise 8 — Diagnostics: investigating a cost anomaly end to end

A budget alert tells you spend is high. It does not tell you what, where, or who. This is the runbook that converts an alert into a fix. Work it in order; each step narrows the search space by an order of magnitude.

### Steps

1. **Which SKU changed?** Compare yesterday against the prior week's daily average, per SKU:

   ```sql
   WITH daily AS (
     SELECT
       DATE(usage_start_time) AS day,
       sku.description AS sku,
       SUM(cost)
         + SUM(IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) AS c), 0)) AS net_cost
     FROM `finops-lab-001.finops_billing.gcp_billing_export_v1_012345_6789AB_CDEF01`
     WHERE _PARTITIONTIME >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 15 DAY)
       AND cost_type = 'regular'
     GROUP BY day, sku
   ),
   agg AS (
     SELECT
       sku,
       SUM(IF(day = CURRENT_DATE() - 1, net_cost, 0)) AS yesterday,
       AVG(IF(day BETWEEN CURRENT_DATE() - 8 AND CURRENT_DATE() - 2, net_cost, NULL)) AS baseline
     FROM daily
     GROUP BY sku
   )
   SELECT
     sku,
     ROUND(yesterday, 2) AS yesterday,
     ROUND(baseline, 2) AS baseline,
     ROUND(SAFE_DIVIDE(yesterday - baseline, baseline) * 100, 1) AS delta_pct
   FROM agg
   WHERE yesterday > 5
   ORDER BY (yesterday - baseline) DESC
   LIMIT 10;
   ```

   ```
   +-------------------------------------------+-----------+----------+-----------+
   | sku                                       | yesterday | baseline | delta_pct |
   +-------------------------------------------+-----------+----------+-----------+
   | Network Inter Region Egress from Americas |    418.22 |     6.11 |    6743.9 |
   | N2 Instance Core running in Americas      |     52.40 |    49.90 |       5.0 |
   +-------------------------------------------+-----------+----------+-----------+
   ```

   Egress, not compute. Compute is noise.

2. **Which resource?** Only the detailed export can answer this:

   ```sql
   SELECT
     project.id AS project_id,
     resource.name AS resource,
     ROUND(SUM(cost), 2) AS cost
   FROM `finops-lab-001.finops_billing.gcp_billing_export_resource_v1_012345_6789AB_CDEF01`
   WHERE _PARTITIONTIME >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 2 DAY)
     AND sku.description LIKE '%Egress%'
   GROUP BY 1, 2
   ORDER BY cost DESC
   LIMIT 5;
   ```

   ```
   +------------------+---------------------------------------------------------+--------+
   | project_id       | resource                                                | cost   |
   +------------------+---------------------------------------------------------+--------+
   | legacy-datalake-01 | //storage.googleapis.com/projects/_/buckets/dl-archive | 411.90 |
   +------------------+---------------------------------------------------------+--------+
   ```

3. **What is that resource, and where is it?** Cross-region reads are the classic cause:

   ```bash
   gcloud asset search-all-resources \
     --scope="projects/legacy-datalake-01" \
     --query="name:dl-archive" \
     --format="table(displayName, assetType, location, labels)"
   ```

   ```
   DISPLAY_NAME  ASSET_TYPE                          LOCATION      LABELS
   dl-archive    storage.googleapis.com/Bucket       europe-west1  {'env': 'prod'}
   ```

   A bucket in `europe-west1` being read from a job in `us-central1`. The compute did not get more expensive; the *data path* did.

4. **Who changed it, and when?** Admin Activity audit logs are enabled by default and free:

   ```bash
   gcloud logging read \
     'logName:"cloudaudit.googleapis.com%2Factivity"
      AND resource.type="gcs_bucket"
      AND protoPayload.resourceName:"dl-archive"' \
     --project=legacy-datalake-01 \
     --freshness=7d \
     --limit=5 \
     --format="table(timestamp, protoPayload.authenticationInfo.principalEmail, protoPayload.methodName)"
   ```

   ```
   TIMESTAMP                       PRINCIPAL_EMAIL                        METHOD_NAME
   2026-09-07T21:14:02.118Z        etl-runner@legacy-datalake-01.iam...   storage.buckets.update
   2026-09-07T21:13:47.902Z        maria.ortiz@example.com                storage.buckets.setIamPolicy
   ```

5. **Close the loop.** Every anomaly investigation should end by adding the control that would have caught it sooner. Here: a per-project budget on `legacy-datalake-01` with a 100% `FORECASTED_SPEND` threshold, and a `cost-center` label requirement enforced as a custom constraint so the next such bucket is allocable on day one.

6. Confirm nothing was silently missed by re-running step 1 with a 2-day window after the fix.

### Comprehension check

- **Q32.** Step 1 filters `WHERE yesterday > 5`. What class of anomaly does that filter hide, and when would that matter?
- **Q33.** Step 2 required the detailed export. Describe exactly how far you could have gotten with only the standard export, and where you would have stalled.
- **Q34.** The compute SKU moved 5% while egress moved 6,700%. Explain in cost terms why the workload's *compute* profile was almost unchanged and the bill still quadrupled.
- **Q35.** Order these four controls by how early each would have intercepted this incident: budget alert, organization policy on resource locations, quota, cost anomaly review. Justify the first place.

---

## Cleanup

Run all of it. Leaving this lab standing costs money every hour.

```bash
gcloud compute instances delete finops-lab-vm --zone="$ZONE" --project="$PROJECT_ID" --quiet
gcloud compute disks list --project="$PROJECT_ID" --format="value(name,zone)"   # verify no orphan disks

gcloud billing budgets delete \
  "billingAccounts/${BILLING_ACCOUNT_ID}/budgets/8f3c9a71-2b4d-4e0a-9c11-77f2b0d4e5aa" --quiet

gcloud pubsub topics delete billing-budget-alerts --project="$PROJECT_ID" --quiet

gcloud org-policies delete gcp.resourceLocations --project="$PROJECT_ID" --quiet
gcloud org-policies delete custom.allowedMachineTypes --project="$PROJECT_ID" --quiet

gcloud beta quotas preferences delete cpus-cap-us-central1 \
  --project="$PROJECT_ID" --quiet   # optional: the lowered quota is harmless to keep

# Disable the export in the Console (Billing → Billing export) BEFORE dropping the dataset,
# or the export will recreate the tables.
bq rm -r -f -d "${PROJECT_ID}:${DATASET}"
```

Confirm the project is quiet:

```bash
gcloud asset search-all-resources --scope="projects/$PROJECT_ID" \
  --asset-types="compute.googleapis.com/Instance,compute.googleapis.com/Disk" \
  --format="value(name)"
```

Empty output means nothing billable is left in Compute Engine.

---

<details>
<summary><strong>Answers</strong></summary>

### Exercise 1 — Resource hierarchy and billing attachment

**A1.** Yes, in effect. Cost is metered against the **project**, and reports resolve the project's hierarchy path at query time. Move the project and the whole history follows it into the new folder's rollups — which is both convenient and a reporting hazard, because a month-over-month folder comparison can shift without any change in actual spend. Cost is recorded per project; the folder is a lens, not a ledger.

**A2.** No to the first: a project has exactly one Cloud Billing account at a time (or none, in which case billable services stop). Yes to the second: a billing account is outside the resource hierarchy and can pay for projects in any organization, or for projects with no organization at all. This is why the billing account is not a security boundary and must not be treated as one.

**A3.** A **billing subaccount** (the row with `MASTER_ACCOUNT_ID` in step 1). It produces a separate invoice for the business unit while charges consolidate to the parent account, so the organization keeps its contract, its negotiated pricing and its committed use discounts intact. A genuinely separate billing account would fragment all of that: separate contract, separate discount pool, separate commitment coverage.

**A4.** The **project number** (`739104857260`). `budgetFilter.projects` expects `projects/<PROJECT_NUMBER>`. Supplying the project ID produces a filter that matches no usage records, so the budget sits at $0.00 forever and never alerts. It is a silent failure — the budget exists, looks configured, and provides zero coverage.

### Exercise 2 — Labels

**A5.** **Labels** are the cost-allocation dimension: they flow into the billing export and are groupable in reports. **Tags** (resource-manager tags) are for **policy** — they are inherited through the hierarchy, key/value pairs are IAM-controlled resources, and they are consumed by IAM conditions and organization policy. Tags do appear in the detailed export, but their purpose is conditional access control, not chargeback. Rule of thumb: labels answer *who pays*, tags answer *what is allowed*.

**A6.** Nothing under that label. Labels are **not retroactive**. The label appears in billing records only for usage metered after it was applied, so January shows that VM's cost as unallocated. Six months of spend is unrecoverable for allocation purposes — you can only estimate it after the fact.

**A7.** (1) The disk's cost appears as unallocated, so `eng-platform`'s reported spend understates its true consumption — a chargeback report that is wrong in a direction nobody complains about. (2) When the VM is deleted or stopped, the disk keeps billing; because it carries no owner label, nothing links it to a team and it survives every cleanup review. Orphaned unlabelled disks are one of the most durable sources of persistent waste.

**A8.** Projects are a **coarse and unstable** allocation axis. A single project routinely hosts several workloads (an API, a batch job, a staging copy), so per-project totals cannot answer "what does the checkout service cost." Projects are also created and deleted for reasons unrelated to ownership — per-environment, per-PR, per-migration — which breaks time series. Labels give you an allocation dimension that is orthogonal to the hierarchy and can be applied consistently across every project a team touches.

### Exercise 3 — BigQuery export

**A9.** A single usage line can receive **several distinct credits at once** — a sustained use discount, a committed use discount, a promotional credit, a free-tier credit — each with its own `name`, `id`, `type` and `full_name`. Flattening them into one number would destroy the ability to answer "how much did our CUDs actually save." The `amount` is negative because it is applied additively to `cost`: net = `cost + SUM(credits.amount)`. Subtracting instead of adding is the single most common bug in hand-written billing SQL.

**A10.** You can deliver three weeks. Billing export **does not backfill** — it begins streaming from the moment it is enabled. For the earlier period you can fall back to the Console's Cost table and Reports (which retain history independently) and to downloaded invoices/CSV, but you cannot get the granular, joinable, label-annotated rows for that window into BigQuery. This is precisely why "enable billing export" is a day-one task in a landing zone, before there is anything to report on.

**A11.** Also `tax`, `adjustment` and `rounding_error`. Excluding them makes the report wrong whenever you are reconciling against the actual **invoice**: a credit memo or a service-level-agreement refund arrives as an `adjustment` row, and tax is a real line on the bill. Use `cost_type = 'regular'` for engineering-facing usage analysis; drop the filter when the number has to match finance.

**A12.** They are grouping by the wrong `labels` column. Top-level `labels` are **resource** labels; project labels live in `project.labels`. Every project carrying `cost-center` says nothing about whether individual VMs, disks and buckets carry it. The fix is either to read `project.labels`, or — better — to `COALESCE` the resource label onto the project label so a resource inherits its project's cost centre when it has none of its own.

**A13.** The standard export gives service/SKU/project/label granularity at low volume; the detailed export adds the `resource` field (individual VM, disk, bucket) at the price of substantially more rows — often an order of magnitude — and correspondingly higher BigQuery storage and query cost. Enable detailed when you need per-resource attribution or anomaly drill-down (Exercise 8 is impossible without it), and control the cost with partition pruning and scheduled aggregate tables.

### Exercise 4 — Budgets

**A14.** It sent notifications: email to the default recipients (Billing Account Administrators and Users) at each threshold crossing, plus any Pub/Sub message. It did **not** throttle, block, cap or stop a single API call. Budgets are an observability control. Spend continued to $4,300 exactly as it would have with no budget configured. This is the highest-yield fact on the objective.

**A15.** `FORECASTED_SPEND` projects end-of-period spend from the current run rate and fires **before** the money is gone, which is the only thing that leaves time to react. `CURRENT_SPEND` at 100% is a post-mortem notification. The forecast is least trustworthy early in the period (few data points, so a one-off spike extrapolates wildly) and for genuinely bursty or seasonal workloads — a batch job that runs on the 28th makes days 1–5 forecast low and day 28 forecast catastrophically high.

**A16.** With `INCLUDE_ALL_CREDITS` the threshold is evaluated against **net** cost — what you actually owe after CUDs and promotional credits. With `EXCLUDE_ALL_CREDITS` it is evaluated against **gross** list-price cost, so the alert fires **earlier** (gross is always ≥ net). Neither is universally right: net matches the invoice and is correct for finance; gross tracks consumption independent of a promotional credit that will one day expire, which is the better early-warning signal for a trial or credit-funded project.

**A17.** Generally no — it should treat the absent `alertThresholdExceeded` as "no threshold crossed" and take no action. Google publishes on every data refresh (roughly every few hours per budget) so that consumers get a **regular heartbeat** carrying current `costAmount` and `budgetAmount`. That lets you build dashboards and detect a silent pipeline, rather than only learning something is wrong when an alert that may never come fails to arrive. Note the corollary: the kill-switch function in step 6 must re-check the numbers itself, because it is invoked on every refresh, not only on breach.

**A18.** (1) Detaching billing **terminates every billable resource in the project** — VMs stop, Cloud SQL instances stop, and data on resources without independent durability is lost. It is not a throttle, it is a demolition. (2) It is triggered by budget data that lags actual usage by hours, so it fires late and unpredictably, and the trigger is a cost number that can move for reasons unrelated to a real incident (a credit expiring, a pricing change, a late-arriving usage record). For production, use **quotas** to cap what can be provisioned, organization policy to constrain what can be created, and budget alerts to page a human who decides.

**A19.** `budgetFilter.projects` accepts only the resource name built from the **project number**. `projects/finops-lab-001` matches nothing, so the budget's measured spend is permanently $0.00 and no threshold is ever crossed. The API accepts the string without error, which is what makes it dangerous — the misconfiguration is invisible until you notice a budget that has never alerted.

### Exercise 5 — Quotas

**A20.** A quota acts **before** the spend, at the moment of the API call, by refusing to create the resource. A budget acts **after** the spend, by describing what already happened. Quota is preventive and enforced by the service; budget is detective and enforced by whoever reads the email.

**A21.** An exhausted **allocation** quota returns a creation failure (`Quota 'CPUS' exceeded. Limit: 8.0 in region us-central1`) — the resource does not exist and retrying changes nothing until you free capacity or raise the limit. An exhausted **rate** quota returns `429 RESOURCE_EXHAUSTED` on individual calls — the correct remediation is exponential backoff with jitter in the client, and only then a quota increase. Treating a rate-quota 429 as a capacity problem leads to raising a limit that was never the constraint; treating an allocation failure as transient leads to a retry loop that never succeeds.

**A22.** The requested quota is a **ceiling on the blast radius of a mistake**. A 500-vCPU limit across three regions means a runaway autoscaler, a bad Terraform loop or a compromised service account can provision 1,500 vCPUs before anything stops it — a five-figure monthly commitment created by an accident. Quota costs nothing to raise later, on demand, with an audit trail; it is the cheapest reversible control available. Grant current need plus reasonable headroom, and revisit on request.

**A23.** There is no single organization-wide compute ceiling to set — quotas are enforced per project per region, so the organization's effective maximum is the **sum** of every project's quota in every region, which grows silently every time a project is created. Organization-level control therefore has to come from elsewhere: a project factory that provisions every new project with deliberately low quotas, organization policy constraining machine types and locations, and billing IAM that limits who can attach a new project to the billing account at all.

### Exercise 6 — Pricing models

**A24.** Decide on **predictability of the baseline**. Sustained use discounts are automatic, require no commitment and reward whatever you happen to run, so they are the correct default for variable workloads. Committed use discounts are worth it only for the portion of capacity you are confident you will consume for the entire 1- or 3-year term — commit to the trough of your usage curve, not the peak, and let SUD/on-demand cover the variable layer above it. Commit to the average and you pay for capacity you do not use in every quiet month.

**A25.** The commitment charge continues for the remaining 28 months regardless. CUDs are billed for the full term whether or not matching usage exists; they are not cancellable or refundable on demand. Depending on the commitment type and current program terms there may be options to change the region or machine family, or to transfer coverage within the billing account, but the baseline obligation stands. This is the entire risk of the mechanism and the reason CUD purchases belong to a finance-and-engineering decision rather than to a single engineer.

**A26.** Negative means **savings**: `-24` is $24/month you would stop spending by applying the recommendation. A recommender emits a **positive** value when the correct action increases cost — a rightsizing recommendation that scales a machine *up* because it is CPU-throttled, for instance. Active Assist optimizes for correct resource fit, not for minimum spend, so code that assumes every recommendation saves money will report nonsense.

**A27.** Correct for Spot: (1) the work is **interruptible and restartable** — batch rendering, CI runners, stateless queue workers, fault-tolerant data processing; (2) it has **no tight completion deadline**, so preemption merely delays rather than fails. Wrong for Spot: any **stateful or latency-critical serving path** — a primary database, a synchronous user-facing API without redundant on-demand capacity — because Spot instances can be reclaimed with about 30 seconds' notice, and capacity can be unavailable entirely.

### Exercise 7 — Governance

**A28.** They need `roles/billing.user` on the **billing account** (or a `roles/billing.projectManager` binding on the project combined with someone who holds `billing.user`). The separation is valuable because project ownership and spending authority are genuinely different concerns: it lets a platform team hand out full project ownership — deploy anything, manage IAM, run the workload — while keeping the decision of *which projects are allowed to charge the company* with a small, auditable group. Without it, anyone who can create a project can create unbounded spend.

**A29.** By default the organization's policy is inherited and the folder's list is **intersected** with it, not substituted — for `gcp.resourceLocations`, values that the parent does not allow cannot be re-allowed by a child. Only locations present in **both** lists are usable. To let the folder's broader list take effect, the folder policy would have to set `inheritFromParent: false` and be applied by a principal with organization-policy administrator rights at that level. Always confirm with `--effective` rather than reading the policy you set.

**A30.** The **quota** would fail where the constraint succeeds: quota counts vCPUs, so 8 separate `n2-standard-1` instances pass an 8-vCPU cap while an `n2-standard-8` does not — but a single expensive `m2-ultramem-208`-class machine in a project with a generous CPU quota also passes, and the machine-type constraint blocks it outright regardless of count. The **custom constraint** would fail where the quota succeeds: the constraint allows `e2-*` without limit, so a runaway autoscaler creating 400 permitted `e2-standard-4` instances sails through it, while the quota stops it dead at the vCPU ceiling. One bounds unit price, the other bounds total quantity — you need both.

**A31.** Because cost data that nobody can see cannot influence anybody's decisions. The teams who choose the machine type, the region, the retention policy and the query pattern are the only ones who can change the bill, and they will not optimize a number they have to file a ticket to read. Broad `roles/billing.viewer` is the cheapest possible intervention: it costs nothing, exposes no ability to spend, and converts cost from a finance report into an engineering signal. It is the operational core of FinOps.

### Exercise 8 — Anomaly diagnostics

**A32.** It hides the **long tail**: hundreds of small SKUs each below $5/day that together represent a large and growing total, and any brand-new SKU whose first day is small but whose trajectory is steep. That matters when the anomaly is not a single spike but broad drift — a fleet-wide change that adds $2/day to each of 300 resources shows nothing above the filter and $600/day on the invoice. Run the query a second time ranked by `delta_pct` with no floor, or aggregate to the service level, to see that class.

**A33.** With the standard export you could reach step 1 in full (the egress SKU is the outlier) and identify the **project** (`legacy-datalake-01`) and the label set attached to it, because project and label columns exist in the standard export. You would stall at identifying **which bucket** — `resource.name` exists only in the detailed export. From there you would be reduced to enumerating candidate buckets by hand, cross-referencing Cloud Monitoring metrics per bucket, or waiting for the detailed export to accumulate data you did not previously collect.

**A34.** The workload's compute shape did not change — the same VMs ran the same hours, hence 5% noise. What changed was **where the data lived relative to the compute**. Reading the same bytes from a bucket in the same region is typically free or near-free; reading them across regions or out to the internet is billed per gigabyte at rates that dwarf the vCPU-hours doing the reading. Data gravity is a first-class cost dimension: the price of a byte depends on the path it takes, and a one-line change to a bucket location can multiply a bill without touching a single line of application code.

**A35.** Earliest to latest: (1) **organization policy** on resource locations — it would have refused to create the bucket in `europe-west1` at all, so the cross-region path could never have existed; (2) **quota** — it caps provisioning, but no quota governs egress bytes, so it is largely irrelevant to this specific incident; (3) **budget alert** — fires hours after the spend, once the data refreshes; (4) **cost anomaly review** — a scheduled human process, days later. Organization policy takes first place because it is the only one of the four that is **preventive rather than reactive**: it converts the mistake from an expensive incident into an error message at the moment of creation, which is the cheapest possible place to catch it.

</details>

---

## Sources

- Cloud Digital Leader exam guide — https://services.google.com/fh/files/misc/cloud_digital_leader_exam_guide_english.pdf
- Resource hierarchy — https://cloud.google.com/resource-manager/docs/cloud-platform-resource-hierarchy
- Cloud Billing concepts — https://cloud.google.com/billing/docs/concepts
- Billing access control (IAM roles) — https://cloud.google.com/billing/docs/how-to/billing-access
- Create, edit and manage budgets — https://cloud.google.com/billing/docs/how-to/budgets
- Programmatic budget notifications — https://cloud.google.com/billing/docs/how-to/budgets-programmatic-notifications
- Automated cost-control responses — https://cloud.google.com/billing/docs/how-to/notify
- Export Cloud Billing data to BigQuery — https://cloud.google.com/billing/docs/how-to/export-data-bigquery
- Standard usage cost data schema — https://cloud.google.com/billing/docs/how-to/export-data-bigquery-tables/standard-usage
- Detailed usage cost data schema — https://cloud.google.com/billing/docs/how-to/export-data-bigquery-tables/detailed-usage
- Example billing export queries — https://cloud.google.com/billing/docs/how-to/bq-examples
- Creating and managing labels — https://cloud.google.com/resource-manager/docs/creating-managing-labels
- Tags overview — https://cloud.google.com/resource-manager/docs/tags/tags-overview
- Quotas overview — https://cloud.google.com/docs/quotas/overview
- View and manage quotas — https://cloud.google.com/docs/quotas/view-manage
- Sustained use discounts — https://cloud.google.com/compute/docs/sustained-use-discounts
- Committed use discounts — https://cloud.google.com/docs/cuds
- Spot VMs — https://cloud.google.com/compute/docs/instances/spot
- Recommenders (Active Assist) — https://cloud.google.com/recommender/docs/recommenders
- Cloud Catalog / pricing API — https://cloud.google.com/billing/docs/how-to/get-pricing-information-api
- Google Cloud Pricing Calculator — https://cloud.google.com/products/calculator
- Organization policy overview — https://cloud.google.com/resource-manager/docs/organization-policy/overview
- Custom organization policy constraints — https://cloud.google.com/resource-manager/docs/organization-policy/creating-managing-custom-constraints
- Cloud Asset Inventory search — https://cloud.google.com/asset-inventory/docs/searching-resources
- Cloud Audit Logs — https://cloud.google.com/logging/docs/audit