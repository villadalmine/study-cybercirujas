# AWS Certified Cloud Practitioner (CLF-C02)
## Domain 1, Task Statement 1.4 — Understand concepts of cloud economics
### Guided exercises — production depth

> **Exam weight context:** this task statement carries **6.0** of the domain scoring. The exam tests recognition of the concepts (fixed vs. variable cost, on-premises vs. cloud cost structure, licensing strategies, right-sizing, automation, managed services). These exercises take you past recognition into the arithmetic and the APIs an SRE actually uses, because the concepts only become durable once you have watched the numbers move.
> Source: [AWS Certified Cloud Practitioner Exam Guide (CLF-C02)](https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf)

---

## Prerequisites

| Requirement | Notes |
|---|---|
| AWS account with billing visibility | An IAM principal with `Billing`, `ce:*`, `pricing:*`, `compute-optimizer:*`, `budgets:*` read access. The **root user must first enable IAM access to Billing** (Account settings → IAM user and role access to Billing information), or every Cost Explorer call returns `AccessDeniedException` regardless of your IAM policy. |
| AWS CLI v2 | `aws --version` → `aws-cli/2.x.x`. |
| `jq` | The Price List API returns JSON documents *encoded as strings*; `jq` twice is the idiom. |
| Region | Use `us-east-1` for all pricing queries. The Price List API and Cost Explorer API have **global endpoints hosted in `us-east-1`** (plus `ap-south-1`/`eu-central-1` for Pricing) — they are not per-region services. |

### Cost and safety notice

| Exercise | Resources created | Approximate cost |
|---|---|---|
| 1, 2, 3, 5 | none — modelling and read-only API calls | **$0.00** (Price List API is free) |
| 4 | none if you already run an EC2 instance | $0.00–$0.10 |
| 6 | 1 × `t3.micro`, 1 IAM role, 2 EventBridge schedules | < $0.05 if cleaned up same day |
| 7 | none (modelling); optional RDS deploy is opt-in | $0.00 / ~$0.50 if you deploy |
| 8 | 1 budget, 1 anomaly monitor, ~10 Cost Explorer calls | ~$0.10 (see the note about `ce` API pricing) |

**Every dollar figure printed in this document is an illustrative snapshot of `us-east-1` list pricing at the time of writing.** AWS changes prices. You are being taught the *method*, not the numbers — and Exercise 2 exists precisely so that you never have to trust a number printed in a training document again.

---

## Exercise 1 — Build the on-premises baseline and split fixed from variable cost

**Objective:** produce the number that every cloud business case is measured against, and discover experimentally why "cloud is cheaper per hour" is the wrong claim.

### Scenario

Your company runs an internal application platform in a colocation facility:

- 12 × dual-socket servers, **32 vCPU / 256 GiB each** → 384 vCPU, 3,072 GiB total
- Purchase price **$9,200 per server**, depreciated straight-line over **5 years**
- 2 racks of colocation at **$900/rack/month**
- Measured average draw **450 W per server**; facility **PUE 1.6**; electricity **$0.12/kWh**
- Transit + cross-connects: **$1,200/month**
- Hardware support contract: **10% of capital cost per year**
- Hypervisor licensing: **$600/month**
- 0.5 FTE of platform engineering time at **$120,000/year fully loaded**

Twelve months of vCenter data show **22% average CPU utilization** and a **61% peak**.

### Steps

1. Compute the monthly depreciation charge.

   ```
   depreciation = (12 × $9,200) / (5 × 12 months)
   ```

2. Compute monthly energy, remembering that PUE multiplies IT load to give facility load:

   ```
   IT load      = 12 × 450 W = 5.4 kW
   facility kWh = 5.4 kW × 730 h × 1.6 (PUE)
   energy cost  = facility kWh × $0.12
   ```

3. Build the full monthly cost table. Fill in the last column yourself — for each line, ask: *if the application's load dropped to zero tomorrow, would this bill change this month?*

   | Line item | $/month | Fixed or variable? |
   |---|---:|---|
   | Depreciation | ? | |
   | Colocation | 1,800 | |
   | Power + cooling | ? | |
   | Network transit | 1,200 | |
   | Hardware support | ? | |
   | Hypervisor licensing | 600 | |
   | Platform engineering (0.5 FTE) | 5,000 | |
   | **Total** | **?** | |

4. Compute two unit economics figures:

   ```
   cost per PROVISIONED vCPU-month = total / 384
   cost per USED vCPU-month        = cost per provisioned vCPU / 0.22
   ```

5. Compute the fixed-cost percentage: `fixed lines ÷ total`.

### Verification questions

- **Q1.1** — What is the total monthly cost, and what percentage of it is fixed?
- **Q1.2** — Why is the cost per *used* vCPU roughly 4.5× the cost per *provisioned* vCPU, and which of the AWS "six advantages of cloud computing" is that gap the direct evidence for?
- **Q1.3** — The CFO proposes cutting cost by shutting down 3 of the 12 servers overnight. Using your table, calculate the actual monthly saving. What does the result tell you about the elasticity of an on-premises cost structure?
- **Q1.4** — In accounting terms, which line items are **CapEx** and which are **OpEx**? Which one does an AWS bill consist of, entirely?
- **Q1.5** — The hardware refresh is due in 14 months and requires a fresh $110,400 decision *made today*, based on a 5-year demand forecast. Name the AWS advantage that eliminates this decision, and explain in one sentence what replaces it.

---

## Exercise 2 — Stop trusting price tables: query the AWS Price List API

**Objective:** retrieve real, current prices programmatically, and derive the cost of a *software licence* from the difference between two hardware-identical SKUs.

### Steps

1. Confirm you can reach the Pricing endpoint and see how AWS models a product:

   ```bash
   aws pricing describe-services \
     --region us-east-1 \
     --service-code AmazonEC2 \
     --query 'Services[0].AttributeNames' \
     --output text | tr '\t' '\n' | head -20
   ```

   Expected (abridged):

   ```
   volumeType
   maxIopsvolume
   instancesku
   instanceFamily
   operatingSystem
   ...
   ```

   Every one of those attribute names is a filterable dimension. A "price" in AWS is the intersection of *all* of them — which is why two engineers quoting "the m5.large price" can both be right and disagree.

2. Retrieve the On-Demand price of `m5.large`, Linux, shared tenancy, `us-east-1`:

   ```bash
   aws pricing get-products \
     --region us-east-1 \
     --service-code AmazonEC2 \
     --filters \
       "Type=TERM_MATCH,Field=instanceType,Value=m5.large" \
       "Type=TERM_MATCH,Field=regionCode,Value=us-east-1" \
       "Type=TERM_MATCH,Field=operatingSystem,Value=Linux" \
       "Type=TERM_MATCH,Field=tenancy,Value=Shared" \
       "Type=TERM_MATCH,Field=preInstalledSw,Value=NA" \
       "Type=TERM_MATCH,Field=capacitystatus,Value=Used" \
     --output json \
   | jq -r '.PriceList[]' \
   | jq -r '.terms.OnDemand[].priceDimensions[]
            | "\(.pricePerUnit.USD)  \(.unit)  \(.description)"'
   ```

   Expected output:

   ```
   0.0960000000  Hrs  $0.096 per On Demand Linux m5.large Instance Hour
   ```

   > **Why `capacitystatus=Used`.** Omit it and you also match `AllocatedCapacityReservation` and `UnusedCapacityReservation` SKUs — the price of *reserved but idle* capacity. Forgetting this filter is the single most common reason a home-grown cost tool reports triple the real price.

3. Now change exactly one dimension — the operating system — and nothing else:

   ```bash
   aws pricing get-products \
     --region us-east-1 \
     --service-code AmazonEC2 \
     --filters \
       "Type=TERM_MATCH,Field=instanceType,Value=m5.large" \
       "Type=TERM_MATCH,Field=regionCode,Value=us-east-1" \
       "Type=TERM_MATCH,Field=operatingSystem,Value=Windows" \
       "Type=TERM_MATCH,Field=tenancy,Value=Shared" \
       "Type=TERM_MATCH,Field=preInstalledSw,Value=NA" \
       "Type=TERM_MATCH,Field=licenseModel,Value=No License required" \
       "Type=TERM_MATCH,Field=capacitystatus,Value=Used" \
     --output json \
   | jq -r '.PriceList[]' \
   | jq -r '.terms.OnDemand[].priceDimensions[] | .pricePerUnit.USD'
   ```

   Expected output:

   ```
   0.1880000000
   ```

4. Compute the delta and annualise it for a 50-instance fleet:

   ```
   licence premium/hour     = 0.188 − 0.096
   licence premium/instance/month = premium × 730
   fleet annual licence cost = premium × 730 × 12 × 50
   ```

5. Repeat step 2 for `m5.xlarge` and `m6g.xlarge` (Graviton, ARM64) and compute the percentage difference.

   ```
   m5.xlarge  → 0.1920000000
   m6g.xlarge → 0.1540000000
   ```

### Verification questions

- **Q2.1** — What is the hourly, monthly-per-instance, and annual-fleet cost of the Windows licence in step 4? What does the `licenseModel` value `No License required` actually mean here, given that you clearly *are* paying for a licence?
- **Q2.2** — The `m6g.xlarge` has the same vCPU and memory count as `m5.xlarge` at a lower price. Calculate the percentage saving. Name the two engineering preconditions that must hold before you can bank it.
- **Q2.3** — Your finance team asks for "a spreadsheet of all our EC2 prices." Why is that request malformed? Reference at least three of the attribute dimensions from step 1.
- **Q2.4** — Which of these is a *pricing* concern and which is a *cost* concern: the Price List API, and Cost Explorer? State the difference in one sentence.

---

## Exercise 3 — Commitment mathematics: derive the break-even utilization

**Objective:** replace "Reserved Instances save up to 72%" with a formula you can apply to any workload in ten seconds.

### Steps

1. Retrieve a real Reserved Instance offering rather than reading a marketing page:

   ```bash
   aws ec2 describe-reserved-instances-offerings \
     --region us-east-1 \
     --instance-type m5.large \
     --product-description "Linux/UNIX" \
     --offering-class standard \
     --offering-type "No Upfront" \
     --instance-tenancy default \
     --filters Name=duration,Values=31536000 \
     --query 'ReservedInstancesOfferings[0].{Fixed:FixedPrice,Recurring:RecurringCharges[0].Amount,Duration:Duration,Class:OfferingClass}' \
     --output table
   ```

   Expected shape:

   ```
   ------------------------------------------------------
   |          DescribeReservedInstancesOfferings        |
   +-----------+------------+------------+--------------+
   |  Class    |  Duration  |  Fixed     |  Recurring   |
   +-----------+------------+------------+--------------+
   |  standard |  31536000  |  0.0       |  0.06        |
   +-----------+------------+------------+--------------+
   ```

2. Retrieve Savings Plans rates for the same instance:

   ```bash
   aws savingsplans describe-savings-plans-offering-rates \
     --service-codes AmazonEC2 \
     --products EC2 \
     --filters \
       name=region,values=us-east-1 \
       name=instanceType,values=m5.large \
       name=tenancy,values=shared \
       name=productDescription,values=Linux/UNIX \
     --query 'searchResults[].{Rate:rate,Plan:savingsPlanOffering.planType,Pay:savingsPlanOffering.paymentOption,Secs:savingsPlanOffering.durationSeconds}' \
     --output table
   ```

3. Check the current Spot market for the same shape:

   ```bash
   aws ec2 describe-spot-price-history \
     --region us-east-1 \
     --instance-types m5.large \
     --product-descriptions "Linux/UNIX" \
     --start-time "$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)" \
     --query 'SpotPriceHistory[].{AZ:AvailabilityZone,Price:SpotPrice}' \
     --output table
   ```

   Illustrative:

   ```
   ---------------------------------
   |    DescribeSpotPriceHistory   |
   +--------------+----------------+
   |      AZ      |     Price      |
   +--------------+----------------+
   |  us-east-1a  |  0.035500      |
   |  us-east-1b  |  0.036100      |
   |  us-east-1d  |  0.034800      |
   +--------------+----------------+
   ```

4. Assemble the comparison table (illustrative snapshot — yours will differ):

   | Purchase option | Effective $/hr | Obligation | Cost of 1 year, 24×7 |
   |---|---:|---|---:|
   | On-Demand | 0.0960 | none | $840.96 |
   | Standard RI, 1 yr, No Upfront | 0.0600 | 8,760 h billed regardless | $525.60 |
   | Standard RI, 3 yr, All Upfront | 0.0385 | paid on day 1 | $337.26/yr |
   | Compute Savings Plan, 3 yr, All Upfront | 0.0326 | $/hr of *spend*, 3 yr | $285.58/yr |
   | EC2 Instance Savings Plan, 3 yr, All Upfront | 0.0269 | $/hr, family + region locked | $235.64/yr |
   | Spot | ~0.0355 | interruptible, 2-min notice | $310.98 (if never interrupted) |

5. Derive the break-even. A commitment is billed for **every hour of its term whether you use it or not**; On-Demand is billed only for hours consumed. Therefore:

   ```
   break-even utilization = committed hourly rate ÷ On-Demand hourly rate
   ```

   Compute it for each committed row, then convert to hours per week (`× 168`).

6. Apply it. Classify each workload — commit, or stay On-Demand?

   | Workload | Running hours | Verdict |
   |---|---|---|
   | Production API, always on | 168 h/wk (100%) | ? |
   | Developer workstations, business hours | 60 h/wk (35.7%) | ? |
   | Nightly batch ETL, 3 h × 7 | 21 h/wk (12.5%) | ? |
   | CI build fleet, bursty, fault-tolerant | ~40 h/wk, unpredictable | ? |

### Verification questions

- **Q3.1** — Calculate the break-even utilization for all four committed options in step 4, in both percentage and hours-per-week.
- **Q3.2** — Complete the table in step 6 with a recommended purchase option and a one-line justification each.
- **Q3.3** — A Savings Plan commitment is expressed in **dollars per hour of spend**, not in instances. What happens to an hour in which your actual usage falls *below* the commitment? What happens to usage *above* it?
- **Q3.4** — Your team plans to migrate from `m5` to Graviton `m6g` in six months. You are about to buy a 3-year **EC2 Instance Savings Plan** for the `m5` family in `us-east-1` because it is the deepest discount available. What is wrong with this plan, and which commitment instrument fixes it at the cost of a few points of discount?
- **Q3.5** — Neither Savings Plans nor Regional Reserved Instances guarantee that capacity will be available when you call `RunInstances`. Which two mechanisms *do* reserve capacity, and what is the billing consequence of each?
- **Q3.6** — State the correct order of the four cost-optimization actions: *commit*, *right-size*, *eliminate waste*, *modernize to managed services*. Justify the position of *commit* in one sentence.

---

## Exercise 4 — Right-sizing from evidence, not from opinion

**Objective:** turn utilization telemetry into a defensible instance-type decision, and learn the failure mode that makes naive right-sizing an outage generator.

### Steps

1. Pick a running instance and capture 14 days of CPU:

   ```bash
   INSTANCE_ID=i-0123456789abcdef0

   aws cloudwatch get-metric-statistics \
     --namespace AWS/EC2 \
     --metric-name CPUUtilization \
     --dimensions Name=InstanceId,Value=$INSTANCE_ID \
     --start-time "$(date -u -d '14 days ago' +%Y-%m-%dT%H:%M:%SZ)" \
     --end-time   "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
     --period 3600 \
     --statistics Average Maximum \
     --query 'sort_by(Datapoints,&Maximum)[-3:].{T:Timestamp,Avg:Average,Max:Maximum}' \
     --output table
   ```

2. Averages hide spikes and maxima over-react to them. Get the p99, which is the statistic you should actually size against:

   ```bash
   aws cloudwatch get-metric-statistics \
     --namespace AWS/EC2 \
     --metric-name CPUUtilization \
     --dimensions Name=InstanceId,Value=$INSTANCE_ID \
     --start-time "$(date -u -d '14 days ago' +%Y-%m-%dT%H:%M:%SZ)" \
     --end-time   "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
     --period 86400 \
     --extended-statistics p99 \
     --query 'sort_by(Datapoints,&Timestamp)[].{Day:Timestamp,P99:ExtendedStatistics.p99}' \
     --output table
   ```

   Illustrative:

   ```
   -------------------------------------------------
   |             GetMetricStatistics                |
   +------------------------------+-----------------+
   |             Day              |      P99        |
   +------------------------------+-----------------+
   |  2026-08-20T00:00:00+00:00   |  9.8            |
   |  2026-08-21T00:00:00+00:00   |  11.2           |
   |  2026-08-22T00:00:00+00:00   |  10.4           |
   +------------------------------+-----------------+
   ```

3. Ask AWS. Opt in to Compute Optimizer (free tier of recommendations, no charge) and read its finding:

   ```bash
   aws compute-optimizer update-enrollment-status --status Active

   aws compute-optimizer get-ec2-instance-recommendations \
     --filters name=Finding,values=Overprovisioned \
     --query 'instanceRecommendations[].{
        Name:instanceName,
        Current:currentInstanceType,
        Finding:finding,
        Recommended:recommendationOptions[0].instanceType,
        Risk:recommendationOptions[0].performanceRisk,
        MonthlySaving:recommendationOptions[0].savingsOpportunity.estimatedMonthlySavings.value}' \
     --output table
   ```

   Illustrative:

   ```
   ----------------------------------------------------------------------------------------
   |                        GetEC2InstanceRecommendations                                  |
   +-----------+-------------+----------------+----------------+-------+------------------+
   |   Name    |   Current   |    Finding     |  Recommended   | Risk  |  MonthlySaving   |
   +-----------+-------------+----------------+----------------+-------+------------------+
   |  app-01   | m5.4xlarge  | Overprovisioned|  m5.xlarge     |  1.0  |  420.48          |
   |  app-02   | m5.4xlarge  | Overprovisioned|  m5.xlarge     |  1.0  |  420.48          |
   +-----------+-------------+----------------+----------------+-------+------------------+
   ```

   > **Enrollment note:** Compute Optimizer needs at least **30 hours** of CloudWatch data and can take up to 12 hours after opt-in to produce its first recommendations. An empty array on a fresh account is the expected result, not an error.

4. Cross-check the arithmetic yourself against Exercise 2's prices:

   ```
   m5.4xlarge = $0.768/hr      m5.xlarge = $0.192/hr
   saving     = (0.768 − 0.192) × 730
   ```

5. Now find the trap. Query the memory metric:

   ```bash
   aws cloudwatch list-metrics \
     --namespace AWS/EC2 \
     --dimensions Name=InstanceId,Value=$INSTANCE_ID \
     --query 'Metrics[].MetricName' --output text | tr '\t' '\n' | sort
   ```

   Expected:

   ```
   CPUUtilization
   DiskReadBytes
   DiskReadOps
   DiskWriteBytes
   DiskWriteOps
   NetworkIn
   NetworkOut
   NetworkPacketsIn
   NetworkPacketsOut
   ```

6. Also check for waste that requires no sizing decision at all — unattached EBS volumes and idle Elastic IPs:

   ```bash
   aws ec2 describe-volumes \
     --filters Name=status,Values=available \
     --query 'Volumes[].{Id:VolumeId,GiB:Size,Type:VolumeType,Created:CreateTime}' \
     --output table

   aws ec2 describe-addresses \
     --query 'Addresses[?AssociationId==`null`].{IP:PublicIp,Alloc:AllocationId}' \
     --output table
   ```

### Verification questions

- **Q4.1** — Confirm the $420.48/month figure from step 4. For a fleet of 6 identical instances, what is the annual saving?
- **Q4.2** — Step 5's output does not contain a memory metric. Why not, what must you install to get one, and what specific production incident does right-sizing on CPU alone invite?
- **Q4.3** — `performanceRisk: 1.0` on a scale where lower is safer. What does Compute Optimizer *not* know about your workload that this number cannot capture? Give two examples.
- **Q4.4** — These 6 instances are already covered by a 3-year EC2 Instance Savings Plan sized to the `m5.4xlarge` fleet. You right-size them to `m5.xlarge`. How much do you actually save this month? Restate the rule this demonstrates.
- **Q4.5** — Each unattached EBS volume in step 6 is 500 GiB `gp3`. At $0.08/GiB-month, what does one cost per year? Why is this category of waste strictly better to attack than right-sizing?
- **Q4.6** — Since 1 February 2024, every public IPv4 address is charged at $0.005/hour **whether attached or not**. Calculate the monthly cost of one address, and of 40 forgotten ones.

---

## Exercise 5 — Licensing strategies: Included, BYOL, and where the money hides

**Objective:** determine, for a given commercial software product, whether AWS is selling you the licence or renting you the hardware to run your own.

### Steps

1. Establish the two models by inspecting what AWS will sell you for RDS. Query engine availability:

   ```bash
   aws rds describe-orderable-db-instance-options \
     --engine oracle-ee \
     --db-instance-class db.m5.large \
     --query 'OrderableDBInstanceOptions[0].{Engine:Engine,Version:EngineVersion,MultiAZ:MultiAZCapable}' \
     --output table

   aws rds describe-orderable-db-instance-options \
     --engine sqlserver-se \
     --db-instance-class db.m5.large \
     --query 'OrderableDBInstanceOptions[0].{Engine:Engine,Version:EngineVersion,MultiAZ:MultiAZCapable}' \
     --output table
   ```

2. Compare the two licensing postures against the official documentation:

   | Engine | License Included | Bring Your Own License |
   |---|---|---|
   | RDS for Oracle | yes (SE2 only) | **yes** — you hold the Oracle licence, AWS bills infrastructure only |
   | RDS for SQL Server | **yes — and only this** | no |
   | RDS for MySQL / PostgreSQL / MariaDB | n/a — open source | n/a |

   Sources: [RDS Oracle licensing](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/Oracle.Concepts.licensing.html), [RDS for SQL Server](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/CHAP_SQLServer.html)

3. Quantify the EC2 side. You already derived the Windows licence premium in Exercise 2. Now price the BYOL alternative — a Dedicated Host, which is billed per *host*, not per instance:

   ```bash
   aws ec2 describe-host-reservation-offerings \
     --filter Name=instance-family,Values=m5 \
     --query 'OfferingSet[?PaymentOption==`NoUpfront` && Duration==`31536000`].{
        Family:InstanceFamily,Hourly:HourlyPrice,Upfront:UpfrontPrice,Payment:PaymentOption}' \
     --output table
   ```

4. Build the decision model for **50 Windows Server instances of `m5.large`**:

   ```
   Option A — License Included, shared tenancy:
     50 × $0.188/hr × 730

   Option B — BYOL on Dedicated Hosts:
     50 × $0.096/hr equivalent capacity  +  host charges  +  your existing licence cost
   ```

   An `m5` Dedicated Host provides 96 vCPUs (48 physical cores). Fifty `m5.large` need 100 vCPU → **2 hosts**.

5. Track entitlements so that BYOL does not become an audit finding. Create a License Manager configuration with a hard limit:

   ```bash
   aws license-manager create-license-configuration \
     --name "windows-server-datacenter-cores" \
     --description "Windows Server DC core entitlements under Software Assurance" \
     --license-counting-type Core \
     --license-count 192 \
     --license-count-hard-limit \
     --license-rules "#minimumCores=4,#maximumCores=96"

   aws license-manager list-license-configurations \
     --query 'LicenseConfigurations[].{Name:Name,Type:LicenseCountingType,Limit:LicenseCount,Consumed:ConsumedLicenses}' \
     --output table
   ```

   Expected:

   ```
   -------------------------------------------------------------------------
   |                     ListLicenseConfigurations                          |
   +--------------------------------------+-------+---------+--------------+
   |                 Name                 | Type  |  Limit  |  Consumed    |
   +--------------------------------------+-------+---------+--------------+
   |  windows-server-datacenter-cores     | Core  |  192    |  0           |
   +--------------------------------------+-------+---------+--------------+
   ```

### Verification questions

- **Q5.1** — Compute Option A and Option B from step 4, using $4.608/hr as the illustrative `m5` Dedicated Host On-Demand rate. At what annual cost of your own Windows licences do the two options break even?
- **Q5.2** — A team wants to migrate a SQL Server Enterprise Edition database to RDS using licences they already own. Explain precisely why this is not possible, and give the two AWS services that *do* support that requirement.
- **Q5.3** — BYOL on shared tenancy for Microsoft products bought after 1 October 2019 is generally not permitted under Microsoft's licensing terms. What is the AWS-side consequence for your architecture, and what does it cost you in cloud-economics terms? (Think about the two things shared tenancy gives you that a Dedicated Host does not.)
- **Q5.4** — `--license-count-hard-limit` causes AWS to *block* instance launches that would exceed the entitlement count. Name one production scenario where this flag prevents a compliance breach, and one where it causes an outage.
- **Q5.5** — Which licensing strategy has zero licence cost, zero audit exposure, and zero tenancy constraint — and why does it not appear in the table in step 2?

---

## Exercise 6 — Automation as a cost control: schedule non-production capacity

**Objective:** implement infrastructure-as-code that removes cost without removing capability, and measure why the realised saving is always smaller than the compute saving.

### Steps

1. Create the template. Save as `office-hours-scheduler.yaml`:

   ```yaml
   AWSTemplateFormatVersion: '2010-09-09'
   Description: >-
     Cost-avoidance scheduler for non-production EC2 instances. Stops the listed
     instances on weekday evenings and starts them on weekday mornings using
     EventBridge Scheduler universal targets. No Lambda function is required.

   Parameters:
     InstanceIds:
       Type: List<AWS::EC2::Instance::Id>
       Description: Non-production instances to place on an office-hours schedule.
     ScheduleTimezone:
       Type: String
       Default: America/Argentina/Buenos_Aires
       Description: IANA timezone name. Handles DST automatically.
     StartExpression:
       Type: String
       Default: cron(0 8 ? * MON-FRI *)
     StopExpression:
       Type: String
       Default: cron(0 20 ? * MON-FRI *)

   Resources:

     SchedulerRole:
       Type: AWS::IAM::Role
       Properties:
         Description: Assumed by EventBridge Scheduler to start and stop tagged instances.
         AssumeRolePolicyDocument:
           Version: '2012-10-17'
           Statement:
             - Effect: Allow
               Principal:
                 Service: scheduler.amazonaws.com
               Action: sts:AssumeRole
               Condition:
                 StringEquals:
                   aws:SourceAccount: !Ref 'AWS::AccountId'
         Policies:
           - PolicyName: StartStopScheduledInstances
             PolicyDocument:
               Version: '2012-10-17'
               Statement:
                 - Effect: Allow
                   Action:
                     - ec2:StartInstances
                     - ec2:StopInstances
                   Resource: !Sub 'arn:${AWS::Partition}:ec2:${AWS::Region}:${AWS::AccountId}:instance/*'
                   Condition:
                     StringEquals:
                       'aws:ResourceTag/Schedule': office-hours

     StopSchedule:
       Type: AWS::Scheduler::Schedule
       Properties:
         Name: !Sub '${AWS::StackName}-stop'
         Description: Stop non-production instances at the end of the working day.
         State: ENABLED
         ScheduleExpression: !Ref StopExpression
         ScheduleExpressionTimezone: !Ref ScheduleTimezone
         FlexibleTimeWindow:
           Mode: 'OFF'
         Target:
           Arn: 'arn:aws:scheduler:::aws-sdk:ec2:stopInstances'
           RoleArn: !GetAtt SchedulerRole.Arn
           RetryPolicy:
             MaximumRetryAttempts: 3
             MaximumEventAgeInSeconds: 3600
           Input: !Sub
             - '{"InstanceIds": ["${Ids}"]}'
             - Ids: !Join ['","', !Ref InstanceIds]

     StartSchedule:
       Type: AWS::Scheduler::Schedule
       Properties:
         Name: !Sub '${AWS::StackName}-start'
         Description: Start non-production instances at the beginning of the working day.
         State: ENABLED
         ScheduleExpression: !Ref StartExpression
         ScheduleExpressionTimezone: !Ref ScheduleTimezone
         FlexibleTimeWindow:
           Mode: 'OFF'
         Target:
           Arn: 'arn:aws:scheduler:::aws-sdk:ec2:startInstances'
           RoleArn: !GetAtt SchedulerRole.Arn
           RetryPolicy:
             MaximumRetryAttempts: 3
             MaximumEventAgeInSeconds: 3600
           Input: !Sub
             - '{"InstanceIds": ["${Ids}"]}'
             - Ids: !Join ['","', !Ref InstanceIds]

   Outputs:
     StopScheduleArn:
       Description: ARN of the evening stop schedule.
       Value: !GetAtt StopSchedule.Arn
     StartScheduleArn:
       Description: ARN of the morning start schedule.
       Value: !GetAtt StartSchedule.Arn
     RunningHoursPerWeek:
       Description: Billable compute hours per instance per week under this schedule.
       Value: '60'
   ```

2. Tag your target instances so the IAM condition matches. Untagged instances will be listed in the schedule input but the API call will be denied — deliberately:

   ```bash
   aws ec2 create-tags \
     --resources i-0123456789abcdef0 i-0fedcba9876543210 \
     --tags Key=Schedule,Value=office-hours Key=Environment,Value=nonprod
   ```

3. Deploy. Use a parameters file — a `List<...>` parameter passed inline through `--parameter-overrides` requires backslash-escaped commas and silently mis-parses if you get it wrong:

   ```bash
   cat > params.json <<'JSON'
   [
     {
       "ParameterKey": "InstanceIds",
       "ParameterValue": "i-0123456789abcdef0,i-0fedcba9876543210"
     }
   ]
   JSON

   aws cloudformation create-stack \
     --stack-name nonprod-office-hours \
     --template-body file://office-hours-scheduler.yaml \
     --parameters file://params.json \
     --capabilities CAPABILITY_IAM

   aws cloudformation wait stack-create-complete --stack-name nonprod-office-hours
   ```

4. Verify:

   ```bash
   aws scheduler list-schedules \
     --query 'Schedules[?starts_with(Name, `nonprod-office-hours`)].{Name:Name,State:State,Target:Target.Arn}' \
     --output table

   aws scheduler get-schedule --name nonprod-office-hours-stop \
     --query '{Expr:ScheduleExpression,TZ:ScheduleExpressionTimezone,Input:Target.Input}'
   ```

   Expected:

   ```json
   {
       "Expr": "cron(0 20 ? * MON-FRI *)",
       "TZ": "America/Argentina/Buenos_Aires",
       "Input": "{\"InstanceIds\": [\"i-0123456789abcdef0\",\"i-0fedcba9876543210\"]}"
   }
   ```

5. Model the saving for a fleet of **10 × `t3.large` development instances**, each with a **100 GiB `gp3`** root volume and an auto-assigned public IPv4 address.

   ```
   Prices: t3.large $0.0832/hr · gp3 $0.08/GiB-month · public IPv4 $0.005/hr

   BEFORE (24×7 = 730 h/month):
     compute = 10 × 0.0832 × 730
     storage = 10 × 100 × 0.08
     IPv4    = 10 × 0.005 × 730

   AFTER (60 h/week ≈ 260 h/month):
     compute = 10 × 0.0832 × 260
     storage = unchanged
     IPv4    = 10 × 0.005 × 260
   ```

6. Compute both the **compute saving %** and the **total bill saving %**, and note the difference.

### Verification questions

- **Q6.1** — Compute the before and after totals from step 5, and both saving percentages.
- **Q6.2** — Why is the total saving lower than the compute saving? Which line item is responsible, and what is the general principle about stopped EC2 instances that it illustrates?
- **Q6.3** — In step 5 the instances use auto-assigned public IPv4 addresses, so the IPv4 charge stops when the instance stops. What changes if you attach **Elastic IP** addresses instead, and why?
- **Q6.4** — The `Schedule=office-hours` tag appears in *two* places with two different jobs. Name both, and explain what happens if an engineer removes the tag from one instance.
- **Q6.5** — Which cost concept from the exam guide does this exercise demonstrate, and how does it interact with the concept from Exercise 1?
- **Q6.6** — The universal target requires an explicit list of instance IDs baked into the schedule. What operational problem does that create as the dev fleet grows, and what is a tag-driven alternative?

---

## Exercise 7 — Managed services: pricing the work you stop doing

**Objective:** compare self-managed and managed database operation on **fully loaded** cost, and see why the cheaper line item is the more expensive choice.

### Steps

1. Retrieve the managed price:

   ```bash
   aws pricing get-products \
     --region us-east-1 \
     --service-code AmazonRDS \
     --filters \
       "Type=TERM_MATCH,Field=instanceType,Value=db.m5.large" \
       "Type=TERM_MATCH,Field=regionCode,Value=us-east-1" \
       "Type=TERM_MATCH,Field=databaseEngine,Value=MySQL" \
       "Type=TERM_MATCH,Field=deploymentOption,Value=Multi-AZ" \
     --output json \
   | jq -r '.PriceList[]' \
   | jq -r '.terms.OnDemand[].priceDimensions[] | "\(.pricePerUnit.USD)  \(.description)"'
   ```

   Expected:

   ```
   0.3420000000  $0.342 per RDS db.m5.large Multi-AZ instance hour (or partial hour) running MySQL
   ```

2. Build **Option A — self-managed MySQL on EC2**, primary plus a manually configured replica:

   | Line | Calculation | $/month |
   |---|---|---:|
   | EC2 compute | 2 × $0.096 × 730 | 140.16 |
   | EBS `gp3` | 1,000 GiB × $0.08 | 80.00 |
   | Provisioned IOPS above the 3,000 free | 3,000 × $0.005 | 15.00 |
   | Backups to S3 Standard | 1,500 GiB × $0.023 | 34.50 |
   | **Infrastructure subtotal** | | **269.66** |
   | Engineering: patching, backup verification, failover drills, replication monitoring | 6 h/mo × $85/h loaded | 510.00 |
   | **Total** | | **?** |

3. Build **Option B — RDS MySQL Multi-AZ**:

   | Line | Calculation | $/month |
   |---|---|---:|
   | Multi-AZ DB instance | $0.342 × 730 | 249.66 |
   | Storage, Multi-AZ (billed on both AZs) | 500 GiB × $0.23 | 115.00 |
   | Automated backup storage ≤ 100% of provisioned | included | 0.00 |
   | **Infrastructure subtotal** | | **364.66** |
   | Engineering: review Performance Insights, approve maintenance window | 1 h/mo × $85/h | 85.00 |
   | **Total** | | **?** |

4. Compare on two axes: infrastructure only, and fully loaded.

5. Extend the reasoning to consumption-priced managed services, where the unit of billing is not an instance-hour at all:

   ```
   Aurora Serverless v2  $0.12 per ACU-hour        (capacity scales in 0.5-ACU steps)
   AWS Lambda            $0.20 per 1M requests + $0.0000166667 per GB-second
   AWS Fargate           $0.04048 per vCPU-hour + $0.004445 per GB-hour
   Amazon S3 Standard    $0.023 per GB-month
   ```

   Compute what a Lambda function billed at 512 MB that runs 2,000,000 times per month for 300 ms costs:

   ```
   requests = (2,000,000 / 1,000,000) × 0.20
   GB-sec   = 2,000,000 × 0.300 s × 0.5 GB
   compute  = GB-sec × 0.0000166667
   ```

6. Compare that against the smallest always-on instance that could host the same function: `t3.micro` at $0.0104/hr × 730.

### Verification questions

- **Q7.1** — Complete the totals in steps 2 and 3. State the percentage difference on infrastructure alone, and on fully loaded cost. Explain the sign change.
- **Q7.2** — Which Well-Architected Cost Optimization design principle does this exercise measure? State it, and name the category of work it tells you to stop paying for.
- **Q7.3** — Compute the Lambda cost in step 5 and the `t3.micro` cost in step 6. At what monthly invocation count do they break even, holding 300 ms and 512 MB constant?
- **Q7.4** — Option A's engineering estimate of 6 h/month excludes one category of cost entirely: the expected cost of the outage that happens when a manual failover goes wrong at 03:00. Why does that omission bias every self-managed-versus-managed comparison in the same direction?
- **Q7.5** — Managed services reduce operational cost but constrain you. Name two concrete capabilities you give up moving from MySQL-on-EC2 to RDS, and explain why this is still usually the right trade.
- **Q7.6** — A Compute Savings Plan covers EC2, Fargate **and** Lambda usage. Why does that materially change the calculus of a migration from EC2 to serverless, compared with an EC2 Instance Savings Plan?

---

## Exercise 8 — Governance: attribute, budget, and detect

**Objective:** make cost a queryable property of your architecture instead of a monthly surprise.

> **Meta-lesson, and it is not a joke:** the Cost Explorer API costs **$0.01 per request**. A naive dashboard polling `GetCostAndUsage` every 60 seconds across 20 accounts costs about **$8,640/month** to tell you how much you are spending. Measuring cost is not free; budget for your own observability.

### Steps

1. Enforce a tagging standard at the point of creation. Attach this policy to your CI/CD deployment role — an untagged launch is rejected:

   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Sid": "DenyRunInstancesWithoutCostAllocationTags",
         "Effect": "Deny",
         "Action": "ec2:RunInstances",
         "Resource": "arn:aws:ec2:*:*:instance/*",
         "Condition": {
           "Null": {
             "aws:RequestTag/CostCenter": "true"
           }
         }
       },
       {
         "Sid": "RequireKnownEnvironmentValues",
         "Effect": "Deny",
         "Action": "ec2:RunInstances",
         "Resource": "arn:aws:ec2:*:*:instance/*",
         "Condition": {
           "StringNotEquals": {
             "aws:RequestTag/Environment": ["prod", "staging", "dev", "sandbox"]
           }
         }
       }
     ]
   }
   ```

2. Activate the tags for billing. **A tag does not appear in Cost Explorer until it is activated as a cost allocation tag, and activation is not retroactive** — data before activation stays untagged forever:

   ```bash
   aws ce list-cost-allocation-tags --status Inactive \
     --query 'CostAllocationTags[].{Key:TagKey,Type:Type,Status:Status}' --output table

   aws ce update-cost-allocation-tags-status \
     --cost-allocation-tags-status \
        TagKey=CostCenter,Status=Active \
        TagKey=Environment,Status=Active
   ```

3. Query last month's spend, grouped by service:

   ```bash
   aws ce get-cost-and-usage \
     --time-period Start=2026-08-01,End=2026-09-01 \
     --granularity MONTHLY \
     --metrics UnblendedCost \
     --group-by Type=DIMENSION,Key=SERVICE \
     --output json \
   | jq -r '.ResultsByTime[0].Groups[]
            | [.Keys[0], (.Metrics.UnblendedCost.Amount|tonumber|.*100|round/100)]
            | @tsv' \
   | sort -k2 -gr | head -10
   ```

   Illustrative:

   ```
   Amazon Elastic Compute Cloud - Compute	3184.22
   Amazon Relational Database Service	1102.87
   Amazon Simple Storage Service	 412.55
   AmazonCloudWatch	 188.03
   EC2 - Other	 176.41
   ```

4. Re-query grouped by your tag, and note what falls into `No CostCenter$`:

   ```bash
   aws ce get-cost-and-usage \
     --time-period Start=2026-08-01,End=2026-09-01 \
     --granularity MONTHLY \
     --metrics UnblendedCost \
     --group-by Type=TAG,Key=CostCenter \
     --output table
   ```

5. Create a forecast-based budget. Budgets are the only free-ish guardrail: **the first two budgets per account are free; each additional budget costs $0.02/day.**

   ```bash
   cat > budget.json <<'JSON'
   {
     "BudgetName": "monthly-account-ceiling",
     "BudgetLimit": { "Amount": "5000", "Unit": "USD" },
     "TimeUnit": "MONTHLY",
     "BudgetType": "COST",
     "CostTypes": {
       "IncludeTax": true,
       "IncludeSubscription": true,
       "IncludeRefund": false,
       "IncludeCredit": false,
       "UseAmortized": false,
       "UseBlended": false
     }
   }
   JSON

   cat > notifications.json <<'JSON'
   [
     {
       "Notification": {
         "NotificationType": "FORECASTED",
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
         "NotificationType": "ACTUAL",
         "ComparisonOperator": "GREATER_THAN",
         "Threshold": 100,
         "ThresholdType": "PERCENTAGE"
       },
       "Subscribers": [
         { "SubscriptionType": "EMAIL", "Address": "finops@example.com" }
       ]
     }
   ]
   JSON

   ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

   aws budgets create-budget \
     --account-id "$ACCOUNT_ID" \
     --budget file://budget.json \
     --notifications-with-subscribers file://notifications.json

   aws budgets describe-budgets --account-id "$ACCOUNT_ID" \
     --query 'Budgets[].{Name:BudgetName,Limit:BudgetLimit.Amount,Actual:CalculatedSpend.ActualSpend.Amount,Forecast:CalculatedSpend.ForecastedSpend.Amount}' \
     --output table
   ```

6. Add anomaly detection, which needs no threshold because it learns your baseline:

   ```bash
   aws ce create-anomaly-monitor \
     --anomaly-monitor '{
       "MonitorName": "all-services-monitor",
       "MonitorType": "DIMENSIONAL",
       "MonitorDimension": "SERVICE"
     }'
   ```

7. Ask Cost Explorer for its own right-sizing view and reconcile it against Compute Optimizer from Exercise 4:

   ```bash
   aws ce get-rightsizing-recommendation \
     --service AmazonEC2 \
     --configuration 'RecommendationTarget=SAME_INSTANCE_FAMILY,BenefitsConsidered=true' \
     --query 'Summary.{Total:TotalRecommendationCount,Savings:EstimatedTotalMonthlySavingsAmount}' \
     --output table
   ```

### Verification questions

- **Q8.1** — Step 2 warns that cost allocation tag activation is not retroactive. What is the operational consequence if you activate `CostCenter` in September for resources tagged since March?
- **Q8.2** — Step 5's budget uses both a `FORECASTED` and an `ACTUAL` notification. What does each one buy you, and why is a budget with only `ACTUAL` notifications close to useless?
- **Q8.3** — A budget notification does not stop anything. Name the mechanism that turns a budget into an enforcement control, and give one reason to be careful with it in a production account.
- **Q8.4** — `BenefitsConsidered=true` in step 7 changes the reported savings. What does it account for, and how does it relate to Q4.4?
- **Q8.5** — `UseAmortized` vs `UseBlended` vs unblended cost. A team bought a $12,000 All Upfront 3-year RI in January. Under which of the three does January show $12,000, and which one is right for judging a team's monthly efficiency?
- **Q8.6** — The IAM policy in step 1 denies untagged `RunInstances`. List two ways cost can still enter the account entirely untagged despite this policy.

---

## Capstone — the one slide

Combine Exercises 1, 3, 4, 6 and 7 into the migration business case for the Exercise 1 platform. Fill in every cell from your own work.

| | On-premises (today) | Lift-and-shift, On-Demand | Optimized cloud |
|---|---:|---:|---:|
| Compute | | | |
| Storage | | | |
| Network / data transfer out (2 TB/mo) | | | |
| Licensing | | | |
| Facilities, power, hardware support | | 0 | 0 |
| Operations labour | | | |
| **Monthly total** | | | |
| Fixed share of cost | | | |
| Cost per *used* vCPU-month | | | |

Assumptions for the middle column: right-size 1:1 to the existing VM shapes → 37 × `m5.2xlarge` at $0.384/hr, 200 GiB `gp3` each, all On-Demand, 24×7.

Assumptions for the right column: size to measured peak + 25% headroom; 60% of the fleet on a 3-year Compute Savings Plan at 66% off; the remaining 40% On-Demand and running ~30% of hours; the same storage; 2 TB/month egress ($0.09/GB after the first 100 GB free); AWS Business Support.

### Verification questions

- **QC.1** — Complete all three columns. Which single column proves that "moving to the cloud" and "saving money" are independent events?
- **QC.2** — The lift-and-shift column comes out only marginally below the on-premises column. What are the two structural reasons, and what would you tell an executive who concludes from this that the migration is not worth doing?
- **QC.3** — List the four levers that separate the middle column from the right-hand column, and attribute each to its task-statement-1.4 concept.
- **QC.4** — Recite the six advantages of cloud computing and map each of your capstone rows to one of them.
- **QC.5** — Name the one cost line that migration does **not** eliminate and may increase, and explain why it is the line that most often sinks a migration business case.

---

## Cleanup

Run this once you are finished, or the exercises stop being free.

```bash
# Exercise 6
aws cloudformation delete-stack --stack-name nonprod-office-hours
aws cloudformation wait stack-delete-complete --stack-name nonprod-office-hours

# Exercise 5
aws license-manager delete-license-configuration \
  --license-configuration-arn "$(aws license-manager list-license-configurations \
      --query 'LicenseConfigurations[?Name==`windows-server-datacenter-cores`].LicenseConfigurationArn' \
      --output text)"

# Exercise 8
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
aws budgets delete-budget --account-id "$ACCOUNT_ID" --budget-name monthly-account-ceiling
aws ce delete-anomaly-monitor --monitor-arn "$(aws ce get-anomaly-monitors \
    --query 'AnomalyMonitors[?MonitorName==`all-services-monitor`].MonitorArn' --output text)"

# Verify nothing is left running
aws ec2 describe-instances \
  --filters Name=instance-state-name,Values=running \
  --query 'Reservations[].Instances[].{Id:InstanceId,Type:InstanceType,Launched:LaunchTime}' \
  --output table
```

Compute Optimizer enrollment (`update-enrollment-status --status Active`) incurs no charge for the standard recommendations and can be left on. Only **enhanced infrastructure metrics** is billable.

---

<details>
<summary><strong>Answers</strong> — work through the exercises before opening</summary>

### Exercise 1

**Q1.1**

```
Depreciation      = (12 × 9,200) / 60          = $1,840.00
Colocation        = 2 × 900                    = $1,800.00
Power + cooling   = 5.4 kW × 730 h × 1.6 × 0.12 = $  756.86  ( 6,307.2 kWh )
Network transit                                 = $1,200.00
Hardware support  = (110,400 × 0.10) / 12      = $  920.00
Hypervisor licensing                            = $  600.00
Platform engineering = 120,000 × 0.5 / 12      = $5,000.00
                                        TOTAL  = $12,116.86  ≈ $12,117/month
Annual = $145,402
```

Only **power and cooling** varies with load, and only partly — servers idle at roughly 40–60% of peak draw, so the truly variable slice is smaller still. Fixed = 12,117 − 757 = $11,360 = **93.8%**. Round number to remember: **~94% of an on-premises bill is fixed.**

**Q1.2**

```
per provisioned vCPU = 12,116.86 / 384 = $31.55
per used vCPU        = 31.55 / 0.22    = $143.43   (4.55×)
```

You bought 384 vCPU and you are using 84.5 of them. The other 299.5 are being depreciated, powered, cooled, insured, patched and supported at full price to do nothing. The 4.55× gap is the cost of *provisioning for a forecast* instead of *paying for consumption*. It is direct evidence for **"Stop guessing capacity"** — and, because that idle capacity was bought with a five-year cheque, for **"Trade capital expense for variable expense"** as well.

**Q1.3**

Powering off 3 of 12 servers saves only the electricity: `3 × 0.45 kW × 730 h × 1.6 × 0.12 = $189.22`, and only for the hours they are off. Nightly-only, that is roughly **$60–90/month against a $12,117 bill — about 0.6%.** The servers still depreciate, still occupy rack units you pay for, still carry support contracts and hypervisor licences.

The lesson: **on-premises, reducing usage does not reduce cost.** Capacity is purchased in advance and in indivisible units. Elasticity is not a feature you can add to a cost structure that is 94% fixed — you get it only by changing the ownership model.

**Q1.4**

- **CapEx:** the $110,400 server purchase (which appears as depreciation on the P&L, but the cash left the business on day one).
- **OpEx:** colocation, power, transit, support contract, hypervisor licensing, salaries.

An AWS bill is **100% OpEx**. There is no capital purchase, no depreciation schedule, no asset on the balance sheet, no disposal. That is the accounting content of the phrase "trade capital expense for variable expense" — and it is why cloud spend needs different financial governance than a hardware purchase: no one signs off on it once, so it must be governed continuously (Exercise 8).

**Q1.5**

The advantage is **"Stop guessing capacity."** What replaces the five-year forecast is a *daily* provisioning decision that is reversible in minutes. The economic content is that the cost of being wrong collapses: guessing wrong on-premises means either 14 months of insufficient capacity or $110,400 of idle assets, while guessing wrong in AWS means one over-sized instance until the next right-sizing review (Exercise 4).

---

### Exercise 2

**Q2.1**

```
premium/hour            = 0.188 − 0.096            = $0.092
premium/instance/month  = 0.092 × 730              = $67.16
fleet annual (50)       = 0.092 × 730 × 12 × 50    = $40,296
```

`licenseModel: No License required` means **you** are not required to supply a licence — AWS has already bought it and embedded it in the hourly rate. It is the "License Included" model. The value describes your obligation, not the absence of a cost; the cost is the $40,296 you just calculated. This is the single most-misread attribute in the Price List API.

**Q2.2**

```
(0.192 − 0.154) / 0.192 = 19.8% ≈ 20%
```

Preconditions:
1. **Your entire runtime stack must have ARM64 (`aarch64`) builds** — base image, language runtime, every native extension, every agent, every sidecar. One x86-only binary in the dependency tree blocks the migration.
2. **Your build and deployment pipeline must produce ARM64 artifacts**, in practice multi-architecture container images, and your CI must have ARM64 runners or emulation.

The price is a fact; the saving is an engineering project. That distinction is the whole of cloud economics.

**Q2.3**

There is no such thing as "our EC2 price" for an instance type. A price is the intersection of at least: `instanceType`, `regionCode`, `operatingSystem`, `tenancy` (Shared / Dedicated / Host), `preInstalledSw` (NA / SQL Std / SQL Ent / SQL Web), `capacitystatus` (Used / UnusedCapacityReservation / AllocatedCapacityReservation), `licenseModel`, and the **term** (On-Demand vs. each Reserved permutation of class, duration and payment option). A single instance type in a single region has hundreds of legitimate prices. The correct deliverable for finance is not a price list but **an actual cost report from Cost Explorer or the Cost and Usage Report** (Q2.4).

**Q2.4**

- **Price List API = pricing.** What a resource *would* cost. Forward-looking, hypothetical, identical for every customer, free to query.
- **Cost Explorer = cost.** What *you actually spent*. Backward-looking, account-specific, includes your discounts, credits, RI/SP coverage, tax and refunds.

One sentence: **pricing is a public catalogue; cost is your invoice.** You plan with the first and you govern with the second, and confusing them is how a business case gets written against list price for a fleet that is 80% covered by Savings Plans.

---

### Exercise 3

**Q3.1**

`break-even utilization = committed rate ÷ On-Demand rate`, and `hours/week = utilization × 168`.

| Option | Rate | Break-even | h/week |
|---|---:|---:|---:|
| Std RI, 1 yr, No Upfront | 0.0600 | 0.0600/0.096 = **62.5%** | 105 |
| Std RI, 3 yr, All Upfront | 0.0385 | **40.1%** | 67 |
| Compute SP, 3 yr, All Upfront | 0.0326 | **34.0%** | 57 |
| EC2 Instance SP, 3 yr, All Upfront | 0.0269 | **28.0%** | 47 |

Note the direction: **a deeper discount lowers the break-even.** A 3-year commitment is not "riskier" in utilization terms — it tolerates *more* idleness before it loses money. The risk in a 3-year commitment is architectural (will you still be running this shape in 2029?), not utilization-based.

**Q3.2**

| Workload | Hours | Recommendation |
|---|---|---|
| Production API, 168 h/wk | 100% | **3-year Savings Plan.** Far above every break-even; the only question is Compute SP vs. EC2 Instance SP, i.e. flexibility vs. ~6 points of discount. |
| Dev workstations, 60 h/wk | 35.7% | **3-year Compute SP (57 h/wk break-even) — marginally.** But apply Exercise 6 *first*: scheduling changes the number the commitment is measured against. Do not commit to capacity you are about to schedule away. A 1-year RI at 105 h/wk break-even would **lose money**. |
| Nightly ETL, 21 h/wk | 12.5% | **On-Demand, or Spot if checkpointed.** Below every break-even. Better still, this is a Lambda/Fargate/Batch workload — pay per second, not per hour. |
| CI build fleet, bursty | ~24% | **Spot**, via EC2 Auto Scaling or Fargate Spot. Builds are idempotent and re-runnable, which is exactly the workload profile Spot is designed for — up to 90% off in exchange for a 2-minute interruption notice. |

**Q3.3**

- **Below the commitment:** the unused portion of that hour is **forfeited**. Savings Plans commitments do not roll over, bank, or carry forward. An hour where you commit $10/hr and use $6/hr costs $10.
- **Above the commitment:** the excess is billed at **standard On-Demand rates**. There is no penalty and no cap — over-commitment is the expensive error, under-commitment merely leaves discount on the table.

This asymmetry is why the standard practice is to **commit to your trough, not your average**: cover the baseline that is provably always running, and let the peak float On-Demand or onto Spot.

**Q3.4**

An **EC2 Instance Savings Plan is locked to an instance family in a region** (`m5` in `us-east-1`). Migrating to `m6g` moves your usage outside the commitment's scope: you would pay the full On-Demand price for the Graviton fleet **and** continue paying the `m5` commitment for the remaining 2.5 years with no usage to apply it to. You would be paying twice, and the "saving" from Graviton would be entirely stranded.

The fix is a **Compute Savings Plan**. It applies automatically across instance family, size, region, OS, tenancy — and additionally covers **Fargate and Lambda**. It discounts a few percentage points less (up to 66% vs. up to 72%) and that difference is the premium you pay for optionality. When the architecture is in motion, buy the Compute SP. Only lock to an EC2 Instance SP for a fleet you are confident will not change shape for the full term.

**Q3.5**

Neither Savings Plans nor **Regional** RIs reserve capacity — they are billing constructs only. The two that do reserve capacity:

1. **Zonal Reserved Instances** — scoped to a specific Availability Zone, providing a capacity reservation in that AZ. Trade-off: no AZ flexibility, and no instance-size flexibility within the family.
2. **On-Demand Capacity Reservations (ODCR)** — reserve capacity in an AZ with no term commitment, created and cancelled at any time. **Billing consequence: you pay the On-Demand rate for the reserved capacity from the moment it is created, whether or not an instance occupies it.** An ODCR can be *paired* with a Savings Plan or Regional RI so the reserved capacity is billed at the discounted rate.

The distinction matters during a large-scale event — a regional failover, a Black Friday scale-out — when On-Demand capacity for a popular instance type in a popular AZ can genuinely be exhausted, and a Savings Plan will not help you.

**Q3.6**

1. **Eliminate waste** — unattached volumes, idle load balancers, forgotten NAT gateways, orphaned snapshots, unassociated Elastic IPs. Zero risk, immediate effect, and it costs nothing to do.
2. **Right-size** — match instance shape to measured demand.
3. **Modernize to managed / serverless services** — remove the instance from the equation entirely where it is not adding value.
4. **Commit** — buy Savings Plans or RIs against the fleet that survives steps 1–3.

Commit is last because **a commitment freezes your current architecture into your bill for one to three years.** Commit first and you have prepaid your waste at a discount, and every subsequent optimization strands part of the commitment (Q4.4). The one-line rule: **optimize the architecture, then commit to what remains.**

---

### Exercise 4

**Q4.1**

```
(0.768 − 0.192) × 730 = 0.576 × 730 = $420.48 / instance / month
6 instances:  $2,522.88 / month  →  $30,274.56 / year
```

**Q4.2**

EC2 metrics are collected from the **hypervisor**, which sees CPU, disk I/O and network for the instance but has no visibility inside the guest operating system. Memory utilization, filesystem free space, swap activity and per-process data are guest-level facts. To collect them you must install the **CloudWatch agent** inside the instance and publish custom metrics (`mem_used_percent`, `disk_used_percent`).

The incident this invites: a JVM, an in-memory cache, an Elasticsearch node or a database will show **5% CPU and 90% memory**. Right-sizing that from `m5.4xlarge` (64 GiB) to `m5.xlarge` (16 GiB) on CPU evidence alone cuts memory by 75% and the process OOMs on the next traffic peak — typically in production, typically after the change has been declared a success. **CPU is the metric you can see; memory is usually the metric that binds.** Install the agent before you right-size stateful workloads.

**Q4.3**

Compute Optimizer sees resource metrics. It cannot see:

1. **Headroom held deliberately for a known future event** — a quarter-end batch, an annual enrolment window, a marketing campaign, a disaster-recovery standby sized to absorb another region's traffic. To a metrics engine, a warm standby is 100% waste.
2. **Licensing or support constraints tied to the shape** — a vendor licence priced per physical core, an application certified only on a specific instance family, a workload requiring a specific network or EBS bandwidth floor that the recommended type does not meet at the same performance profile.

Also invisible: burst behaviour finer than the metric period (a 20-second CPU spike is invisible at 5-minute granularity), and any dependency on local NVMe present on the current type and absent from the recommendation. Treat Compute Optimizer's output as a **prioritized list of hypotheses to test**, never as a change to apply automatically.

**Q4.4**

**You save approximately nothing this month.** The Savings Plan is a commitment to spend a fixed dollar amount per hour for three years. Reducing usage below that commitment does not reduce the payment — the unused commitment is forfeited hour by hour (Q3.3). You have made the instances smaller and the bill has stayed the same.

If it is a **Compute** SP, the freed commitment will at least drift to cover other eligible usage elsewhere in the account (other regions, other families, Fargate, Lambda) — you recover value only to the extent that such usage exists. If it is an **EC2 Instance** SP locked to `m5` in `us-east-1`, it can only re-apply to other `m5` usage in that region.

The rule, restated: **right-size before you commit. A commitment purchased over an un-optimized fleet locks your waste in at a discount.** This is the single most common and most expensive sequencing error in cloud cost management.

**Q4.5**

```
500 GiB × $0.08/GiB-month = $40.00/month = $480.00/year, per volume
```

This category is strictly better to attack because it is **pure waste with zero performance risk**. An unattached volume serves no workload, has no owner monitoring it, and deleting it (after a snapshot, if provenance is unclear) cannot cause an outage. Right-sizing always carries a performance hypothesis that could be wrong; deleting an `available` volume carries none. Always exhaust the zero-risk category before spending engineering judgement on the risky one — that is why "eliminate waste" precedes "right-size" in Q3.6.

**Q4.6**

```
1 address  = 0.005 × 730       = $3.65 / month  = $43.80 / year
40 addresses = 3.65 × 40       = $146.00 / month = $1,752.00 / year
```

This charge, introduced 1 February 2024, applies to **every** public IPv4 address in the account: attached to running instances, attached to NAT gateways and load balancers, and idle Elastic IPs. It changed a line item that used to be free-when-attached into a fleet-wide cost, and it is a common source of the "EC2 - Other" line growing without any instance change. It is also the strongest financial argument for IPv6 and for putting workloads in private subnets behind a shared egress path.

Reference: [New AWS public IPv4 address charge](https://aws.amazon.com/blogs/aws/new-aws-public-ipv4-address-charge-public-ip-insights/)

---

### Exercise 5

**Q5.1**

```
Option A — License Included, shared tenancy:
  50 × 0.188 × 730                       = $6,862.00 / month

Option B — BYOL on Dedicated Hosts:
  2 hosts × $4.608/hr × 730              = $6,727.68 / month
  plus your own Windows Server licences  = $L
                                   total = $6,727.68 + L
```

Break-even: `6,862.00 − 6,727.68 = $134.32/month`, i.e. **$1,611.84/year**. If your existing Windows Server Datacenter entitlements for those 2 hosts (96 physical cores) cost less than roughly $134/month to hold, BYOL wins on paper; above that, License Included wins.

In practice this is close enough that the *non-price* factors decide it: BYOL forces Dedicated Host tenancy, which means you manage host capacity and placement yourself, you lose the ability to launch any instance size on demand, and you must prove entitlement compliance at audit. License Included has none of those obligations. **The reason to choose BYOL is almost never the $134 — it is that the licences are already sunk cost and cannot be resold.** That is a CapEx-recovery argument, not a cloud-economics one.

**Q5.2**

**RDS for SQL Server is License Included only.** AWS discontinued BYOL for RDS SQL Server; there is no configuration in which you supply your own SQL Server licence to an RDS instance. The licence cost is embedded in the RDS hourly rate and you cannot subtract it.

The two AWS services that do support BYOL for SQL Server:

1. **Amazon EC2 with Dedicated Hosts** (or Dedicated Instances), where you install and license SQL Server yourself, tracked in **AWS License Manager**.
2. **Amazon RDS Custom for SQL Server**, which gives you OS and database-level access on an RDS-managed instance and supports bring-your-own-media/licence models.

**Q5.3**

Microsoft's October 2019 change to its Outsourcing terms means licences purchased after 2019-10-01 without dedicated-hosted rights cannot be deployed on shared-tenancy infrastructure at AWS. Architecturally, you are forced onto **Dedicated Hosts or Dedicated Instances**.

The cloud-economics cost is that you give up the two properties that make cloud compute economically different from a rack of servers:

1. **Granular elasticity.** You now buy capacity in units of a *whole physical host*, not an instance. Scaling from 50 to 51 instances may require a second host — you are back to Exercise 1's problem of purchasing capacity in indivisible, over-sized units.
2. **Per-second billing on a shared pool.** A Dedicated Host bills continuously whether it runs one instance or forty; utilization risk moves back onto you.

In other words, BYOL on dedicated tenancy partially reimports the on-premises cost structure — fixed, lumpy, utilization-sensitive — into AWS. That is the real price of the licence, and it does not appear on any price list.

**Q5.4**

- **Prevents a breach:** an Auto Scaling group with a mis-set `MaxSize` scales a Windows fleet from 40 to 400 instances during a traffic spike. Without the hard limit you have deployed 360 unlicensed instances and created a seven-figure audit exposure discovered months later. With it, the launches are refused and you get an alert.
- **Causes an outage:** the same Auto Scaling group scales legitimately during a genuine peak, hits the entitlement ceiling, and `RunInstances` is denied. Capacity does not arrive, the service degrades, and the failure mode looks like a capacity problem rather than a licensing one — which makes it slow to diagnose at 03:00.

The mitigation is to run License Manager in **soft-limit** mode with a CloudWatch alarm on `ConsumedLicenses` approaching the entitlement, so you are warned with headroom to buy licences rather than blocked at the boundary. Reserve the hard limit for environments where a compliance breach genuinely costs more than an outage.

**Q5.5**

**Open-source software** — MySQL, PostgreSQL, MariaDB, Linux, PostgreSQL-compatible Aurora. Zero licence cost, no entitlement to track, no tenancy constraint, and Compute Optimizer/Graviton/Spot all remain available because nothing is bound to a physical core count.

It does not appear in the table because **there is no licensing decision to make** — which is precisely the point. In the table in step 2, the rows for MySQL/PostgreSQL/MariaDB read "n/a". Every hour spent on the Option A/Option B analysis in Q5.1, every Dedicated Host constraint in Q5.3, and every audit-risk trade-off in Q5.4 is a cost that the open-source row simply does not incur. When a workload's engine is genuinely negotiable, **engine choice is a larger cost lever than any purchase-option decision in Exercise 3** — and unlike a Savings Plan, it compounds by also removing the constraints on every other lever.

---

### Exercise 6

**Q6.1**

```
BEFORE (730 h/month)
  compute = 10 × 0.0832 × 730  = $607.36
  storage = 10 × 100 × 0.08    = $ 80.00
  IPv4    = 10 × 0.005 × 730   = $ 36.50
  TOTAL                        = $723.86

AFTER (60 h/week ≈ 260 h/month)
  compute = 10 × 0.0832 × 260  = $216.32
  storage = 10 × 100 × 0.08    = $ 80.00   (unchanged)
  IPv4    = 10 × 0.005 × 260   = $ 13.00
  TOTAL                        = $309.32

compute saving = (607.36 − 216.32) / 607.36 = 64.4%
total   saving = (723.86 − 309.32) / 723.86 = 57.3%
```

Sanity check on the hours: 60 running hours out of 168 in a week is 35.7%, so you avoid 64.3% of compute hours. The compute percentage matches the schedule exactly, as it must.

**Q6.2**

**EBS storage is responsible.** The general principle: **a stopped EC2 instance stops accruing compute charges immediately, but its EBS volumes continue to be billed in full.** Storage is provisioned capacity, not consumed capacity — the blocks are still allocated to you, still durable, still replicated within the AZ, whether or not anything is running on top of them.

The principle generalises beyond EBS. Every architecture has a **fixed floor** — storage, snapshots, NAT gateways ($0.045/hr each, ~$32.85/month, whether or not a byte flows), load balancer hours, Route 53 hosted zones, KMS keys, reserved commitments. Scheduling and autoscaling attack the *variable* layer above that floor. So the blended saving is always strictly less than the compute saving, and as you optimize compute the fixed floor grows as a percentage of the bill until *it* becomes the thing worth attacking. Here, storage went from 11% of the bill to 26%.

This is Exercise 1 in miniature and reversed: you have made a mostly-fixed cost structure mostly-variable, and what remains fixed is now the visible problem.

**Q6.3**

An **Elastic IP remains associated with the instance while it is stopped** — that is the entire reason to use one, since the address must survive the stop/start cycle. Because the address is allocated to you continuously, it is **billed continuously at $0.005/hour**, 730 h/month, regardless of instance state. In addition, an EIP not associated with a *running* instance has historically carried an idle-address charge.

Recompute:
```
IPv4 with EIPs = 10 × 0.005 × 730 = $36.50   (unchanged from BEFORE)
AFTER total    = 216.32 + 80.00 + 36.50 = $332.82
total saving   = (723.86 − 332.82) / 723.86 = 54.0%   (down from 57.3%)
```

Roughly $23.50/month, or $282/year, is the price of stable DNS-free addressing on a fleet that is off two-thirds of the time. The architectural fix is to stop needing a stable public address at all: put the instances in private subnets and reach them through **Systems Manager Session Manager**, which needs no public IP, no EIP, no bastion host and no inbound security group rule. That removes a cost line and an attack surface in the same change.

**Q6.4**

1. **In the IAM policy's `Condition` block** (`aws:ResourceTag/Schedule`), where it *authorizes* the action. This is the security boundary — it is what prevents the scheduler role from being able to stop production.
2. **As the operational marker of intent**, telling humans and any tag-driven tooling which instances are on the office-hours regime.

If an engineer removes the tag from an instance, the instance ID is still present in the schedule's `Input` payload, so EventBridge Scheduler still calls `StopInstances` for it — but IAM **denies** the call. Because `StopInstances` is a batch API, the denial fails the request for the affected instance; depending on how the batch is evaluated you may get a partial or total failure of that invocation.

The operationally important part: **this failure is silent by default.** The schedule fires, the target errors, the retry policy exhausts three attempts, and nobody is told. Always attach an EventBridge Scheduler **dead-letter queue** (`Target.DeadLetterConfig`) and alarm on its depth, or your cost control quietly stops working and you discover it in next month's bill.

**Q6.5**

**Automation (infrastructure as code)**, listed explicitly in task statement 1.4. The template is version-controlled, reviewable, reproducible across accounts, and deleting the stack removes the control cleanly — none of which is true of a scheduled job someone set up in a console.

The interaction with Exercise 1 is the whole point of the pair. On-premises, this automation would have saved essentially nothing (Q1.3: ~0.6%), because turning a server off does not un-buy it. In AWS the identical operational change yields **57%**, because the cost structure is variable. **The automation is not what saves the money — it is what converts a variable cost structure into a realised saving.** Elasticity is the precondition; automation is the mechanism. Neither works without the other: elasticity without automation just means nobody remembers to turn things off.

**Q6.6**

The problem: **the instance list is static and lives inside the schedule.** Every new dev instance requires a CloudFormation update to be covered, and every terminated instance leaves a stale ID in the payload that will make the API call error. In a fleet with any churn, coverage silently decays — new instances default to running 24×7, which is exactly the population most likely to be forgotten. The control appears healthy while covering a shrinking fraction of the fleet.

Tag-driven alternatives, in increasing order of capability:

- **Systems Manager Automation** with a `AWS-StopEC2Instance` runbook driven by a **Resource Group** built from a tag query, invoked by EventBridge Scheduler. Membership is evaluated at run time, so new tagged instances are covered automatically.
- **A small Lambda function** that calls `DescribeInstances` with `Filters=[{Name:'tag:Schedule',Values:['office-hours']}]` and passes the result to `StopInstances`, paginating properly. More code, full control, easy to add per-instance overrides (`Schedule=always-on`).
- **The AWS Instance Scheduler solution**, a maintained CloudFormation solution supporting multiple named schedules, cross-account and cross-region operation, and per-instance overrides via tag values.

Whichever you choose, the design rule is the same: **the control should discover its targets from tags at run time, not from a list captured at deploy time.** A cost control that requires a human to remember to extend it is a cost control that will be wrong within a quarter.

---

### Exercise 7

**Q7.1**

```
Option A — self-managed MySQL on EC2
  infrastructure                     = $  269.66
  engineering  6 h × $85             = $  510.00
  TOTAL                              = $  779.66

Option B — RDS MySQL Multi-AZ
  infrastructure                     = $  364.66
  engineering  1 h × $85             = $   85.00
  TOTAL                              = $  449.66

Infrastructure only: RDS is 35.2% MORE expensive  (364.66 / 269.66 = 1.352)
Fully loaded:        RDS is 42.3% LESS expensive  (330.00 / 779.66)
                     annual difference = $3,960
```

The sign change comes from the fact that the AWS invoice contains only one of the two cost categories. Infrastructure is metered, itemised, and lands in Cost Explorer; **engineering time is real money that never appears on the bill.** Comparing the RDS line item against the EC2 line item compares two-thirds of one option against one-third of the other. The managed service's price includes labour that the self-managed option merely relocates onto a payroll line — where it is invisible to the cost review, and where it competes with feature work.

Note also what the 5 hours/month of recovered engineering time is *worth* rather than what it *costs*: those hours go to product work, so the real figure is higher than $510.

**Q7.2**

**"Stop spending money on undifferentiated heavy lifting"** — one of the five design principles of the Cost Optimization pillar of the AWS Well-Architected Framework.

The category is **operational work that is necessary but that no customer will ever pay you more for**: OS and database patching, backup scripting and — the part everyone forgets — backup *restore verification*, replication lag monitoring, failover runbooks and drills, minor-version upgrades, storage growth management, host-level metric collection. Every organisation running MySQL does this identically. None of it differentiates your product. Task statement 1.4 lists managed services (RDS, ECS, EKS, DynamoDB) precisely because choosing them is a cost decision, not merely an operational one.

Reference: [Cost Optimization pillar](https://docs.aws.amazon.com/wellarchitected/latest/cost-optimization-pillar/welcome.html)

**Q7.3**

```
Lambda
  requests = (2,000,000 / 1,000,000) × 0.20              = $ 0.40
  GB-sec   = 2,000,000 × 0.300 × 0.5                     = 300,000 GB-s
  compute  = 300,000 × 0.0000166667                      = $ 5.00
  TOTAL                                                  = $ 5.40 / month

t3.micro always-on
  0.0104 × 730                                           = $ 7.59 / month
```

Break-even, solving for invocations `n` at 300 ms / 512 MB:

```
cost(n) = n × (0.20/1e6)  +  n × 0.15 GB-s × 0.0000166667
        = n × (0.0000002 + 0.0000025)
        = n × 0.0000027
7.59 = n × 0.0000027  →  n ≈ 2,811,000 invocations / month
```

So **around 2.8 million invocations per month**, roughly 1.08 per second sustained. Below that, Lambda is cheaper; above it, the instance is.

Three caveats that matter more than the arithmetic. First, the comparison is not like-for-like: the $7.59 buys you one instance in one AZ with no redundancy, no autoscaling, no patching and no capacity for a burst, while the $5.40 buys managed concurrency across AZs. Making the EC2 side genuinely production-equivalent means at least two instances behind a load balancer (add ~$16–22/month for an ALB), which pushes break-even far higher. Second, the AWS Free Tier for Lambda (1M requests and 400,000 GB-seconds per month) is perpetual, not 12-month. Third, Compute Savings Plans cover Lambda (Q7.6), so the discounted Lambda rate moves the crossover further still.

**Q7.4**

Because **the omitted cost is real, large, and falls entirely on one side of the comparison.** Expressed properly it is `probability of failure × cost of failure`: a manual MySQL failover performed under pressure by whoever is on call, at 03:00, against a runbook last exercised in a drill some months ago. The cost of one such event — hours of downtime, potential data loss between the last replicated transaction and the failure, customer credits, the incident review, the engineer's following day — routinely exceeds the *entire annual* difference between the two options.

The bias is directional and consistent: **the self-managed option's cost is systematically understated**, because its risk is borne as an occasional catastrophic event rather than as a recurring monthly line, and cost models are built from recurring lines. Meanwhile the managed option's mitigation of that risk *is* on the invoice — the Multi-AZ premium in the $0.342/hr rate is literally the price of automatic failover with a typical RTO of a minute or two.

The honest way to model it: assign the self-managed option an explicit expected-loss line (probability × cost) and let people argue about the probability. An argument about a number is progress; an omitted line is not.

**Q7.5**

Two concrete capabilities you give up:

1. **Operating-system and superuser access.** No `SSH` to the host, no `SUPER` privilege, no filesystem access. You cannot install an arbitrary plugin or UDF, run a custom agent, tune a kernel parameter, or use a backup tool that requires a raw data-directory copy. Only the parameters AWS exposes in a DB parameter group are tunable.
2. **Version and maintenance timing control.** RDS enforces maintenance windows and eventually forces minor-version upgrades and end-of-life major-version migrations on AWS's calendar. You cannot pin a version indefinitely, and you cannot run a version AWS does not offer.

It is still usually right because the surrendered capabilities are ones **most teams never actually exercise**, while the acquired ones — automated backups with point-in-time recovery to the second, one-checkbox Multi-AZ with automatic failover, managed patching, read replicas created in minutes, Performance Insights, encryption at rest — are ones every team needs and few build well. You trade rarely-used control for continuously-delivered reliability. When a workload genuinely needs the surrendered control, **RDS Custom** exists as the middle path, and self-managing on EC2 remains legitimate — it just has to be justified against the fully loaded number from Q7.1, not the infrastructure line.

**Q7.6**

Because a **Compute Savings Plan follows the workload across the compute services**, while an EC2 Instance Savings Plan does not.

With a Compute SP, migrating a service from EC2 to Fargate or Lambda keeps the commitment productive — the discount simply re-applies to the new usage. Modernization and commitment stop being in tension, so a 3-year commitment does not become a 3-year argument against re-architecting.

With an **EC2 Instance Savings Plan**, that same migration strands the commitment: the EC2 usage it was bought for disappears, the new Fargate/Lambda usage is ineligible, and you pay both the orphaned commitment and the undiscounted serverless bill until the term expires. The commitment becomes a financial disincentive to improve the architecture — which is exactly the outcome Q3.6 orders the steps to avoid.

The general rule this establishes: **buy the narrowest commitment whose scope you are confident will outlive its term.** Where the architecture is stable, the extra ~6 points of EC2 Instance SP discount are free money. Where it is in motion — which is most places — the Compute SP's flexibility is worth more than the discount you give up for it.

---

### Exercise 8

**Q8.1**

**All spend before the activation date remains permanently unattributed.** Cost allocation tag activation applies to billing data generated from that point forward; it does not retroactively re-tag historical line items. Your March–August costs will show under `No CostCenter$` in every report, forever, and no support request can regenerate them.

Consequences: no year-over-year comparison by cost centre for that period, no showback/chargeback for the first six months, and — most damaging — you cannot establish the *baseline* against which this year's optimization work is measured. It also means the first honest tag-based report is six months later than anyone expects.

The practical rule: **activate cost allocation tags on day one of an account's life**, before any workload is deployed, and treat the standard tag keys as part of the landing-zone definition. It costs nothing to activate a tag that is not yet in use.

**Q8.2**

- **`FORECASTED > 80%`** fires when AWS's projection of your end-of-month spend crosses the threshold. It is the **actionable** alert: it arrives while there are still days left in the month to find the cause and stop it.
- **`ACTUAL > 100%`** fires when the money is already spent. It is a **record**, not a warning.

A budget with only `ACTUAL` notifications is close to useless because by the time it fires, every dollar it was meant to protect is gone. It tells you what happened, which Cost Explorer would have told you anyway. Worse, cost data lags by up to 24 hours, so an `ACTUAL 100%` alert can arrive a day *after* the overrun.

Keep both — the forecast to act on, the actual as the backstop for when the forecast is wrong (it is unreliable on accounts less than a few months old, and it does not anticipate a step change). Add intermediate `ACTUAL` thresholds at 50% and 80% for accounts where a fast anomaly matters more than a smooth forecast.

**Q8.3**

**AWS Budgets Actions.** A budget action can, on threshold breach, automatically apply a restrictive IAM or Service Control Policy, stop targeted EC2 or RDS instances, or attach a deny policy to specified roles — either automatically or after an approval step.

Reasons for care in production:
- The obvious one: an SCP that denies `ec2:RunInstances` will block Auto Scaling from replacing an unhealthy instance, so a cost guardrail becomes an availability incident during the exact traffic surge that triggered the overspend.
- The subtler one: **billing data lags by up to 24 hours**, so an action can fire on stale information — either late, after the spend that mattered, or against a spike that has already been remediated.

The safe pattern is budget actions in **approval-required** mode in production and **automatic** mode only in sandbox and training accounts, where blocking launches is exactly the desired behaviour and no customer is affected. Sandbox accounts are where budget actions genuinely shine.

**Q8.4**

`BenefitsConsidered=true` tells Cost Explorer to compute the recommendation's savings **net of the Reserved Instance and Savings Plans coverage already applied to the resource**, rather than against list On-Demand price.

The relationship to Q4.4 is direct: it is the same fact, surfaced by the tool. With `false`, an `m5.4xlarge` covered by a 3-year SP is reported as saving the full $420.48/month, which is fiction — the commitment is still owed. With `true`, the reported saving collapses to whatever the commitment can genuinely be redeployed against, which for a locked EC2 Instance SP may be near zero.

Practical guidance: **use `BenefitsConsidered=true` for any account with meaningful commitment coverage**, or you will build a savings plan (the document kind) out of numbers that cannot be realised, and then have to explain to finance why the projected reduction never appeared in the bill.

**Q8.5**

- **Unblended cost** — the charge as it actually hit the invoice, on the day it hit. **January shows the full $12,000**; February and March show $0 for that RI.
- **Amortized cost** — upfront charges spread evenly across the commitment term. `12,000 / 36 = $333.33` appears in each of the 36 months.
- **Blended cost** — relevant only in AWS Organizations: it averages RI/SP benefit across all member accounts so each account sees the same effective rate, regardless of which account technically owned the reservation. Useful for showback fairness in a consolidated-billing family, misleading for anything else.

For judging a team's monthly efficiency, use **amortized cost**. Unblended makes January look like a catastrophe and February like a triumph, when nothing about the team's behaviour changed — it measures the *timing of payments*, not the *consumption of resources*. Amortized measures what the team actually used each month, which is the only thing they can act on. Use unblended for cash-flow and invoice reconciliation, where the timing is the point.

**Q8.6**

Two of several ways:

1. **Resources not created by `RunInstances`.** The policy covers exactly one API action on one resource type. An S3 bucket, a NAT gateway, a Load Balancer, an RDS instance, a DynamoDB table, a Lambda function, a CloudWatch log group with infinite retention, an EKS control plane — none of these are `ec2:RunInstances`, and every one of them costs money. Cost governance by per-action IAM policy is whack-a-mole; the durable form is an **AWS Organizations tag policy** plus SCPs applied at the OU level.
2. **Resources created indirectly by AWS services on your behalf.** An Auto Scaling group launches instances using its own service-linked role and a launch template — if the launch template does not carry `TagSpecifications` for `CostCenter`, every scaled-out instance is untagged, and it is the scaled-out fleet that constitutes the spike you most want attributed. The same applies to EKS managed node groups, Spot Fleet, EMR clusters, and anything spawned by CloudFormation without `--tags` propagation.

Also worth naming: **charges that have no resource at all to tag** — data transfer between AZs, public IPv4 hours, NAT gateway data processing, KMS API requests, support charges, and the Cost Explorer API calls from this exercise. A material fraction of a mature AWS bill lands in "EC2 - Other" and is untaggable by construction. Perfect attribution is not achievable; **85–90% tagged coverage with a known, explained remainder** is the realistic target, and the remainder should be allocated by a documented rule rather than left to argument.

---

### Capstone

**QC.1**

```
ON-PREMISES (from Exercise 1)
  Compute (depreciation + support + hypervisor)  1,840 + 920 + 600 = $ 3,360.00
  Storage                                        (included in servers) 0.00
  Network / transit                                                 $ 1,200.00
  Licensing (hypervisor, counted above)                                  0.00
  Facilities: colocation + power/cooling         1,800 + 757       = $ 2,556.86
  Operations labour                                                 $ 5,000.00
  TOTAL                                                             = $12,116.86
  Fixed share                                                       = 93.8%
  Cost per used vCPU-month (384 × 22% = 84.5)                       = $  143.43

LIFT-AND-SHIFT, ON-DEMAND, 24×7
  Compute   37 × 0.384 × 730                                        = $10,371.84
  Storage   37 × 200 GiB × 0.08 = 7,400 GiB                         = $   592.00
  Egress    (2,048 − 100) × 0.09                                    = $   175.32
  Licensing (Linux / open source)                                   = $     0.00
  Facilities                                                        = $     0.00
  Operations labour  (still patching 37 guest OSes; ~0.4 FTE)       = $ 4,000.00
  TOTAL                                                             = $15,139.16
  Fixed share (commitments: none; but 24×7 On-Demand is fixed in practice) ≈ 0% contractually
  Cost per used vCPU-month (296 provisioned × 22% = 65.1)           = $   232.55

OPTIMIZED CLOUD
  Sizing: peak 61% × 384 = 234 vCPU, + 25% headroom = 293 vCPU → 37 × m5.2xlarge
  Compute — baseline 22 instances, 3-yr Compute SP @ 66% off:
            22 × 0.1306 × 730                                       = $ 2,097.44
  Compute — burst 15 instances, On-Demand, ~30% of hours (219 h):
            15 × 0.384 × 219                                        = $ 1,261.44
  Storage   7,400 GiB × 0.08                                        = $   592.00
  Egress    (2,048 − 100) × 0.09                                    = $   175.32
  Licensing                                                         = $     0.00
  Facilities                                                        = $     0.00
  Operations labour (managed services + IaC; ~0.15 FTE)             = $ 1,500.00
  Subtotal before support                                           = $ 5,626.20
  Business Support (10% of first $10k of usage, ~$4,126 usage)      = $   412.62
  TOTAL                                                             = $ 6,038.82
  Fixed share (SP commitment 2,097 + storage 592 = 2,689 / 6,039)   = 44.5%
  Cost per used vCPU-month (293 provisioned, now ~60% utilized)     = $    34.35

  vs on-premises:  50.2% reduction    ($6,078/month, $72,936/year)
```

**The middle column is the proof.** A pure lift-and-shift comes out *above* the on-premises baseline — $15,139 against $12,117, a **25% increase**. Migrating to AWS and reducing cost are two separate projects that happen to share a timeline. This is not a contrived result; it is the single most common outcome of an unoptimized migration, and it is why so many cloud programmes report a cost increase in year one.

**QC.2**

Two structural reasons:

1. **You transplanted the utilization problem.** The on-premises fleet ran at 22% CPU. Sizing 1:1 to the existing VM shapes reproduces that 22% exactly — you are now renting idle capacity by the hour instead of owning it, and renting idle capacity is *more* expensive than owning it, because the hourly rate includes AWS's margin, their facilities, their operations staff and the option value of elasticity you are not using. Exercise 1's $143.43/used-vCPU becomes $232.55.
2. **You paid for elasticity and did not use it.** On-Demand pricing is the most expensive rate AWS offers, and its entire value proposition is the right to stop paying at any moment. Running On-Demand 24×7 for three years is buying an insurance policy you never claim on. You also declined every commitment discount (Exercise 3) — up to 66–72% left on the table.

What to tell the executive: **this column is not a finding about the cloud, it is a finding about the plan.** It is the correct and expected cost of the *first* milestone in a migration, not of the end state, and it exists because moving and optimizing at the same time is how migrations fail. The right-hand column is the destination and it is 50% below the baseline; the middle column is a waypoint. The genuine risk to flag is organizational rather than technical: many migrations stop at the middle column, declare completion, and the optimization work is never funded. Fund the optimization phase explicitly in the same business case, with the four levers below as named deliverables and QC.1's numbers as their targets.

**QC.3**

| Lever | Effect | Task-statement 1.4 concept |
|---|---|---|
| Size to measured peak + headroom instead of to legacy VM shapes | Removes the transplanted 78% idle capacity | **Right-sizing** |
| Run only 60% of the fleet continuously; burst the rest ~30% of hours | Converts fixed capacity into consumption | **Fixed vs. variable cost** (and the elasticity that makes it possible) |
| 3-year Compute Savings Plan on the proven baseline | 66% off the always-on portion | **Cloud cost structure** — the consumption model, applied only after the first two levers (Q3.6) |
| Managed services + IaC scheduling reduce ops from 0.5 FTE to ~0.15 FTE | $3,500/month, the largest single line reduction | **Managed AWS services** and **automation (IaC)** |

Worth naming explicitly: **the labour line is the biggest single saving in the whole model** — $5,000 → $1,500, larger than the entire storage and egress bill combined. It is also the line most often omitted from migration business cases, because it is not on any AWS invoice (Q7.1). Cloud economics is not primarily about the price of compute.

**QC.4**

1. **Trade capital expense for variable expense** — the Compute and Facilities rows. $110,400 of depreciating hardware and a five-year cheque become an hourly rate that stops when the instance stops.
2. **Benefit from massive economies of scale** — the effective per-vCPU price. AWS's aggregate purchasing across millions of customers is why $0.384/hr for 8 vCPU beats what you can achieve buying 12 servers.
3. **Stop guessing capacity** — the sizing change from 384 provisioned vCPU to 293, and the burst fleet. The 14-month hardware refresh decision (Q1.5) disappears entirely.
4. **Increase speed and agility** — not a row, and that is the point: it is the value of the 0.35 FTE released from patching to product work, plus the ability to test a new instance family in an afternoon rather than a procurement cycle.
5. **Stop spending money running and maintaining data centres** — the Facilities row going to zero: $2,556.86/month of colocation, power and cooling, plus the $920 hardware support contract, eliminated outright.
6. **Go global in minutes** — not visible in a single-region model, but it is the option value the capstone does not price. Serving a second continent means selecting a region, not signing a colocation contract in another country.

Reference: [Six advantages of cloud computing](https://docs.aws.amazon.com/whitepapers/latest/aws-overview/six-advantages-of-cloud-computing.html)

**QC.5**

**Operations labour** — and in a badly-run migration it goes *up*, not down.

The mechanism: for a period, you are running both estates. The team now operates the legacy platform *and* a new one, in a new operating model, with new tooling, new IAM, new networking, new monitoring, and a new set of failure modes nobody has seen before. Meanwhile the skills required have changed — the people who were expert at the old platform are novices at the new one, and the learning happens on the critical path. In the capstone's optimized column the line only falls to $1,500 *because* the optimized architecture uses managed services and IaC. Lift-and-shift to 37 self-managed EC2 instances (middle column) barely moves it: you are still patching 37 guest operating systems, you have just changed where they run.

Why it sinks business cases: it is the **largest** line in the model (Exercise 1: $5,000 of $12,117, 41%), the **most uncertain**, and the **only one AWS does not invoice** — so it is simultaneously the most consequential number and the easiest to assume away. A business case that projects the labour line to zero on migration day is not optimistic, it is arithmetically wrong, and when the projected saving fails to materialise the cause is almost always here rather than in the infrastructure lines that everyone spent their time modelling.

The discipline: model the labour line explicitly, in three phases — *during* migration (higher, dual-running), *after* lift-and-shift (roughly flat), *after* modernization (materially lower) — and make the third phase a funded deliverable rather than an assumption. That is the honest version of the slide, and it is the version that survives contact with the second year.

</details>

---

## Sources

All URLs verified at the time of writing.

- [AWS Certified Cloud Practitioner (CLF-C02) Exam Guide](https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf)
- [Six Advantages of Cloud Computing — Overview of Amazon Web Services](https://docs.aws.amazon.com/whitepapers/latest/aws-overview/six-advantages-of-cloud-computing.html)
- [AWS Well-Architected Framework — Cost Optimization Pillar](https://docs.aws.amazon.com/wellarchitected/latest/cost-optimization-pillar/welcome.html)
- [AWS Price List API — `GetProducts`](https://docs.aws.amazon.com/aws-cost-management/latest/APIReference/API_pricing_GetProducts.html)
- [AWS Pricing Calculator](https://calculator.aws/)
- [Amazon EC2 Reserved Instances](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-reserved-instances.html)
- [AWS Savings Plans User Guide](https://docs.aws.amazon.com/savingsplans/latest/userguide/what-is-savings-plans.html)
- [Amazon EC2 Spot Instances](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/using-spot-instances.html)
- [AWS Compute Optimizer](https://docs.aws.amazon.com/compute-optimizer/latest/ug/what-is-compute-optimizer.html)
- [Amazon RDS for Oracle licensing options](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/Oracle.Concepts.licensing.html)
- [Amazon RDS for Microsoft SQL Server](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/CHAP_SQLServer.html)
- [AWS License Manager](https://docs.aws.amazon.com/license-manager/latest/userguide/license-manager.html)
- [Amazon EventBridge Scheduler](https://docs.aws.amazon.com/scheduler/latest/UserGuide/what-is-scheduler.html)
- [Managing your costs with AWS Budgets](https://docs.aws.amazon.com/cost-management/latest/userguide/budgets-managing-costs.html)
- [AWS Cost Anomaly Detection](https://docs.aws.amazon.com/cost-management/latest/userguide/manage-ad.html)
- [Using cost allocation tags](https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/cost-alloc-tags.html)
- [AWS Cost and Usage Reports](https://docs.aws.amazon.com/cur/latest/userguide/what-is-cur.html)
- [New — AWS public IPv4 address charge and Public IP Insights](https://aws.amazon.com/blogs/aws/new-aws-public-ipv4-address-charge-public-ip-insights/)
- [AWS Cost Management pricing](https://aws.amazon.com/aws-cost-management/pricing/)
- [AWS Migration Evaluator](https://aws.amazon.com/migration-evaluator/)