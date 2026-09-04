# Exercises — 4.1 Compare AWS Pricing Models

**Certification:** AWS Certified Cloud Practitioner (CLF-C02) · **Domain 4:** Billing, Pricing, and Support · **Exam weight of the domain:** 12% · **This task statement:** ~4%

**What you will be able to do when you finish:** derive any AWS price from an authoritative machine-readable source instead of a blog post; compute the break-even point of a commitment; explain *why* a workload belongs on Spot, On-Demand, a Reserved Instance, a Savings Plan, or a Dedicated Host; and separate the three billing dimensions — **compute, storage, data transfer** — that every AWS bill decomposes into.

---

## 0. Setup and safety

> **Every dollar figure printed in this document is an illustrative snapshot for `us-east-1`.** AWS changes prices, and prices differ per Region. The point of these exercises is that you never trust a memorized number — you query the Price List API and read today's value. Your outputs *will* differ from the samples; that is expected and is itself part of the lesson.

**Cost of running these exercises:** the Price List API, `describe-*` calls, Compute Optimizer, and the AWS Pricing Calculator are **free**. Two calls in Exercise 9 use the **Cost Explorer API, which is billed at $0.01 per request** — a handful of calls costs a few cents. Nothing here launches a billable resource. You will *create* one AWS Budget (the first two budgets per account are free).

### Steps

1. Verify you have AWS CLI v2:

```bash
aws --version
```

```text
aws-cli/2.31.10 Python/3.13.4 linux/6.9.0 exe/x86_64.fedora.44
```

2. Verify your identity and note your account ID — you will need it later:

```bash
aws sts get-caller-identity --output table
```

```text
------------------------------------------------------------------
|                        GetCallerIdentity                       |
+-------------+--------------------------------------------------+
|  Account    |  111122223333                                    |
|  Arn        |  arn:aws:iam::111122223333:user/pricing-lab      |
|  UserId     |  AIDAEXAMPLEUSERID                               |
+-------------+--------------------------------------------------+
```

```bash
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
```

3. Attach this **read-only** policy to the principal you are using. Nothing in it can create, modify or delete a billable resource, except `budgets:*` which is scoped to budget objects:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "PriceDiscovery",
      "Effect": "Allow",
      "Action": [
        "pricing:DescribeServices",
        "pricing:GetAttributeValues",
        "pricing:GetProducts",
        "pricing:ListPriceLists",
        "pricing:GetPriceListFileUrl",
        "savingsplans:DescribeSavingsPlansOfferings",
        "savingsplans:DescribeSavingsPlansOfferingRates",
        "savingsplans:DescribeSavingsPlans",
        "ec2:DescribeSpotPriceHistory",
        "ec2:DescribeReservedInstancesOfferings",
        "ec2:DescribeHostReservationOfferings",
        "ec2:DescribeInstanceTypes",
        "ec2:GetSpotPlacementScores",
        "compute-optimizer:GetEC2InstanceRecommendations"
      ],
      "Resource": "*"
    },
    {
      "Sid": "BillingRead",
      "Effect": "Allow",
      "Action": [
        "ce:GetCostAndUsage",
        "ce:GetSavingsPlansPurchaseRecommendation",
        "ce:GetReservationPurchaseRecommendation",
        "ce:GetSavingsPlansUtilization",
        "ce:GetReservationCoverage",
        "freetier:GetFreeTierUsage",
        "budgets:ViewBudget",
        "budgets:DescribeBudgets"
      ],
      "Resource": "*"
    },
    {
      "Sid": "BudgetGuardrail",
      "Effect": "Allow",
      "Action": ["budgets:CreateBudget", "budgets:DeleteBudget", "budgets:ModifyBudget"],
      "Resource": "arn:aws:budgets::111122223333:budget/*"
    }
  ]
}
```

4. Install `jq` (the Price List API returns JSON-encoded strings inside JSON; `jq` is not optional here):

```bash
jq --version   # jq-1.7.1
```

5. Pin the variables used throughout:

```bash
export PRICING_REGION=us-east-1        # Price List API endpoint Region
export TARGET_REGION=us-east-1         # Region whose prices we are studying
export ITYPE=m6i.large
export HOURS_MONTH=730                 # AWS's own convention: 8760 / 12
export HOURS_YEAR=8760
```

> **Endpoint gotcha:** the Price List Query API and the Free Tier API are only served from a small set of Regions (`us-east-1`, `eu-central-1`, `ap-south-1` for pricing). `--region us-east-1` in a `pricing` command selects *the endpoint*, **not** the Region whose prices you get. The Region you are pricing is a **filter** (`regionCode` / `location`).

### Checkpoint 0

1. You run `aws pricing get-products --region eu-west-1 ...` and it fails with an endpoint error, yet `--region us-east-1` works and returns Tokyo prices. Explain both facts in one sentence.
2. Which of the three billing dimensions (compute, storage, data transfer) does the IAM policy above let you *incur* a charge in? Justify.
3. Why does AWS use 730 hours per month in its own calculators instead of 720?

---

## Exercise 1 — Read a price from the source of truth

**Goal:** stop treating "the price of an m6i.large" as a single number and start treating it as a *coordinate in a multi-dimensional product space*.

### Steps

1. Confirm which services expose a price list, and how many attributes EC2 prices are keyed by:

```bash
aws pricing describe-services --service-code AmazonEC2 \
  --region "$PRICING_REGION" \
  --query 'Services[0].AttributeNames' --output json | jq 'length, .[0:12]'
```

```json
64
[
  "volumeType", "maxIopsvolume", "instanceCapacity10xlarge", "locationType",
  "instanceFamily", "operatingSystem", "clockSpeed", "LeaseContractLength",
  "ecu", "networkPerformance", "instanceType", "tenancy"
]
```

2. Ask what legal values one of those attributes takes. This is how you discover the vocabulary AWS itself uses:

```bash
aws pricing get-attribute-values --service-code AmazonEC2 \
  --attribute-name tenancy --region "$PRICING_REGION" \
  --query 'AttributeValues[].Value' --output text
```

```text
Dedicated	Host	NA	Reserved	Shared
```

3. Now pin **every** dimension until exactly one product remains. Omitting any one of these returns dozens of SKUs and is the single most common mistake when scripting against this API:

```bash
aws pricing get-products --region "$PRICING_REGION" --service-code AmazonEC2 \
  --filters \
    "Type=TERM_MATCH,Field=instanceType,Value=$ITYPE" \
    "Type=TERM_MATCH,Field=regionCode,Value=$TARGET_REGION" \
    'Type=TERM_MATCH,Field=operatingSystem,Value=Linux' \
    'Type=TERM_MATCH,Field=tenancy,Value=Shared' \
    'Type=TERM_MATCH,Field=preInstalledSw,Value=NA' \
    'Type=TERM_MATCH,Field=licenseModel,Value=No License required' \
    'Type=TERM_MATCH,Field=capacitystatus,Value=Used' \
  --output json > /tmp/m6i-large.json

jq '.PriceList | length' /tmp/m6i-large.json
```

```text
1
```

4. Extract the On-Demand rate. Note the `fromjson` — each element of `PriceList` is a *string* containing JSON:

```bash
jq -r '.PriceList[] | fromjson
       | .terms.OnDemand[].priceDimensions[]
       | "\(.pricePerUnit.USD)\t\(.unit)\t\(.description)"' /tmp/m6i-large.json
```

```text
0.0960000000	Hrs	$0.096 per On Demand Linux m6i.large Instance Hour
```

5. The *same* SKU also carries every commitment term. List them:

```bash
jq -r '.PriceList[] | fromjson | .terms.Reserved[]
       | [.termAttributes.LeaseContractLength,
          .termAttributes.OfferingClass,
          .termAttributes.PurchaseOption] | @tsv' /tmp/m6i-large.json | sort -u
```

```text
1yr	convertible	All Upfront
1yr	convertible	No Upfront
1yr	convertible	Partial Upfront
1yr	standard	All Upfront
1yr	standard	No Upfront
1yr	standard	Partial Upfront
3yr	convertible	All Upfront
3yr	convertible	No Upfront
3yr	convertible	Partial Upfront
3yr	standard	All Upfront
3yr	standard	No Upfront
3yr	standard	Partial Upfront
```

6. Normalize the price by capacity, which is what actually matters when comparing families:

```bash
aws ec2 describe-instance-types --instance-types "$ITYPE" --region "$TARGET_REGION" \
  --query 'InstanceTypes[0].{vCPU:VCpuInfo.DefaultVCpus,MemGiB:MemoryInfo.SizeInMiB,Net:NetworkInfo.NetworkPerformance}' \
  --output table
```

```text
-------------------------------------------
|          DescribeInstanceTypes          |
+---------+-----------+-------------------+
| MemGiB  |    Net    |       vCPU        |
+---------+-----------+-------------------+
|  8192   | Up to 12.5 Gigabit|  2         |
+---------+-----------+-------------------+
```

`$0.096 / 2 vCPU = $0.048 per vCPU-hour`.

7. Repeat step 3 for a second Region and diff the rate:

```bash
for r in us-east-1 eu-central-1 sa-east-1; do
  p=$(aws pricing get-products --region "$PRICING_REGION" --service-code AmazonEC2 \
    --filters "Type=TERM_MATCH,Field=instanceType,Value=$ITYPE" \
      "Type=TERM_MATCH,Field=regionCode,Value=$r" \
      'Type=TERM_MATCH,Field=operatingSystem,Value=Linux' \
      'Type=TERM_MATCH,Field=tenancy,Value=Shared' \
      'Type=TERM_MATCH,Field=preInstalledSw,Value=NA' \
      'Type=TERM_MATCH,Field=capacitystatus,Value=Used' \
    --query 'PriceList[0]' --output text \
    | jq -r '.terms.OnDemand[].priceDimensions[].pricePerUnit.USD')
  printf '%-14s %s USD/hr\n' "$r" "$p"
done
```

```text
us-east-1      0.0960000000 USD/hr
eu-central-1   0.1070000000 USD/hr
sa-east-1      0.1530000000 USD/hr
```

8. For offline or bulk analysis, pull the whole price list as a file instead of paginating the Query API:

```bash
ARN=$(aws pricing list-price-lists --service-code AmazonEC2 \
  --effective-date "$(date -u +%Y-%m-01T00:00:00Z)" \
  --currency-code USD --region-code "$TARGET_REGION" \
  --region "$PRICING_REGION" --query 'PriceLists[0].PriceListArn' --output text)

aws pricing get-price-list-file-url --price-list-arn "$ARN" \
  --file-format csv --region "$PRICING_REGION" --output text
```

```text
https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonEC2/20260901000000/us-east-1/index.csv
```

### Checkpoint 1

1. In step 3, what does `capacitystatus=Used` select, and which two other values exist? What would you be pricing if you chose one of them?
2. Why must you filter on `preInstalledSw` and `licenseModel` even for plain Linux? What business model do those two attributes encode?
3. The same physical instance type costs 59% more in `sa-east-1` than in `us-east-1`. Name two structural reasons AWS prices Regions differently, and state the architectural decision this fact should feed into.
4. A colleague hardcodes `0.096` in a chargeback script. Give two distinct failure modes of that script.
5. `m6i.large` has 2 vCPU at $0.096/hr. `m6i.xlarge` has 4 vCPU. Without querying, predict its On-Demand price and state the pricing principle that lets you predict it. Does the same principle hold across *families* (e.g. `m6i` vs `c6i`)?

---

## Exercise 2 — On-Demand vs Reserved Instances: the break-even calculation

**Goal:** derive, not memorize, when a commitment pays for itself.

### Steps

1. Get the live On-Demand rate into a shell variable:

```bash
OD=$(jq -r '.PriceList[] | fromjson | .terms.OnDemand[].priceDimensions[].pricePerUnit.USD' /tmp/m6i-large.json)
echo "On-Demand: $OD"
```

```text
On-Demand: 0.0960000000
```

2. Extract every 1-year **standard** term with its upfront and hourly components. A Reserved Instance has *two* price dimensions — `Quantity` (the upfront fee, unit `Quantity`) and `Hrs` (the recurring rate):

```bash
jq -r '.PriceList[] | fromjson | .terms.Reserved[]
  | select(.termAttributes.LeaseContractLength=="1yr" and .termAttributes.OfferingClass=="standard")
  | . as $t | .priceDimensions[]
  | [$t.termAttributes.PurchaseOption, .unit, .pricePerUnit.USD] | @tsv' /tmp/m6i-large.json | sort
```

```text
All Upfront	Quantity	511.0000000000
All Upfront	Hrs	0.0000000000
No Upfront	Hrs	0.0605000000
No Upfront	Quantity	0.0000000000
Partial Upfront	Quantity	253.0000000000
Partial Upfront	Hrs	0.0289000000
```

3. Confirm the same offers through the EC2 API, which is what you would actually call to *purchase*:

```bash
aws ec2 describe-reserved-instances-offerings --region "$TARGET_REGION" \
  --instance-type "$ITYPE" --product-description "Linux/UNIX" \
  --offering-class standard --offering-type "No Upfront" \
  --instance-tenancy default --no-include-marketplace \
  --filters Name=duration,Values=31536000 Name=scope,Values=Region \
  --query 'ReservedInstancesOfferings[0].{Id:ReservedInstancesOfferingId,Fixed:FixedPrice,Hourly:RecurringCharges[0].Amount,Scope:Scope,Class:OfferingClass}' \
  --output table
```

```text
------------------------------------------------------------------------------
|                       DescribeReservedInstancesOfferings                    |
+---------+---------+--------------------------------------+--------+---------+
|  Class  | Fixed   |                 Id                   | Hourly | Scope   |
+---------+---------+--------------------------------------+--------+---------+
| standard|  0.0    | 4b2293b4-5813-4cc8-9ce3-1957dcEXAMPLE |  0.0605| Region  |
+---------+---------+--------------------------------------+--------+---------+
```

4. Compute the **effective hourly rate** of each purchase option. The formula is the whole exercise:

```
effective_hourly = (upfront / hours_in_term) + recurring_hourly
```

```bash
python3 - <<'PY'
OD = 0.0960
H1, H3 = 8760, 26280
offers = [
    ("On-Demand",                    0.0,    OD,     H1),
    ("1yr std No Upfront",           0.0,    0.0605, H1),
    ("1yr std Partial Upfront",    253.0,    0.0289, H1),
    ("1yr std All Upfront",        511.0,    0.0000, H1),
    ("3yr std All Upfront",        997.0,    0.0000, H3),
    ("3yr convertible All Upfront",1180.0,   0.0000, H3),
]
print(f"{'Option':<30}{'Eff $/hr':>10}{'Disc':>8}{'$/month':>10}{'Break-even':>12}")
for name, up, hr, h in offers:
    eff = up / h + hr
    print(f"{name:<30}{eff:>10.4f}{1-eff/OD:>7.0%}{eff*730:>10.2f}{eff/OD:>11.0%}")
PY
```

```text
Option                          Eff $/hr    Disc   $/month  Break-even
On-Demand                         0.0960      0%     70.08        100%
1yr std No Upfront                0.0605     37%     44.17         63%
1yr std Partial Upfront           0.0578     40%     42.17         60%
1yr std All Upfront               0.0583     39%     42.58         61%
3yr std All Upfront               0.0379     60%     27.69         39%
3yr convertible All Upfront       0.0449     53%     32.78         47%
```

The last column is the **break-even utilization**: the fraction of the term the instance must actually run before the commitment beats paying On-Demand.

5. Model a workload that is *not* always-on — a CI fleet running 10 h/day, 22 days/month (≈ 30% utilization):

```bash
python3 - <<'PY'
hours_used = 10*22*12          # 2640 h over one year
print(f"On-Demand   : ${hours_used*0.0960:>8.2f}")
print(f"1yr NU RI   : ${8760*0.0605:>8.2f}   (billed 8760 h regardless of use)")
print(f"1yr AU RI   : ${511.0:>8.2f}   (sunk on day 1)")
PY
```

```text
On-Demand   : $  253.44
1yr NU RI   : $  529.98   (billed 8760 h regardless of use)
1yr AU RI   : $  511.00   (sunk on day 1)
```

6. Verify **instance size flexibility**. A *regional*, Linux, default-tenancy, standard RI floats across sizes in its family using normalization factors:

| Size | nano | micro | small | medium | large | xlarge | 2xlarge | 4xlarge | 8xlarge | 12xlarge | 16xlarge | 24xlarge |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Factor | 0.25 | 0.5 | 1 | 2 | **4** | 8 | 16 | 32 | 64 | 96 | 128 | 192 |

One `m6i.xlarge` RI (factor 8) fully covers two concurrent `m6i.large` instances (4 + 4 = 8).

### Checkpoint 2

1. A No Upfront RI has zero upfront cost. Why is its break-even utilization still 63% rather than 0%? What obligation did you actually sign?
2. Rank the three payment options by discount and explain the mechanism that produces that ordering.
3. Your CI fleet in step 5 runs 30% of the hours. Which pricing model should it use, and which model should the *build artifact repository* behind it use?
4. Give two concrete situations in which a **Convertible** RI is worth its smaller discount versus a Standard RI. What operation does Convertible permit that Standard does not, and what operation does Standard permit that Convertible does not?
5. What does `Scope: Region` buy you and what does it cost you, compared with `Scope: Availability Zone`?
6. You hold one `m6i.2xlarge` regional Linux RI and you are running four `m6i.large`. Is your coverage complete? Show the arithmetic. Now the workload moves to `c6i.large` — what happens to your RI?
7. Why does instance size flexibility *not* apply to a Windows RI or to a zonal RI?

---

## Exercise 3 — Savings Plans: committing to money, not to machines

**Goal:** internalize the one structural difference — an RI is a commitment to a *resource shape*; a Savings Plan is a commitment to a *dollar-per-hour of spend*.

### Steps

1. List the Savings Plan offerings available for a 1-year, No Upfront commitment:

```bash
aws savingsplans describe-savings-plans-offerings --region "$PRICING_REGION" \
  --plan-types Compute --durations 31536000 --payment-options "No Upfront" \
  --currencies USD \
  --query 'searchResults[0].{Offering:offeringId,Plan:planType,Secs:durationSeconds,Pay:paymentOption}' \
  --output table
```

```text
--------------------------------------------------------------------------
|                      DescribeSavingsPlansOfferings                     |
+-----------+--------------------------------------+------------+--------+
|   Pay     |               Offering               |    Plan    | Secs   |
+-----------+--------------------------------------+------------+--------+
| No Upfront|  87654321-abcd-4321-abcd-0123456789ab|  Compute   | 31536000|
+-----------+--------------------------------------+------------+--------+
```

```bash
OFFER=$(aws savingsplans describe-savings-plans-offerings --region "$PRICING_REGION" \
  --plan-types Compute --durations 31536000 --payment-options "No Upfront" \
  --currencies USD --query 'searchResults[0].offeringId' --output text)
```

2. Get the **discounted rate** this plan applies to our specific instance:

```bash
aws savingsplans describe-savings-plans-offering-rates --region "$PRICING_REGION" \
  --savings-plan-offering-ids "$OFFER" --service-codes AmazonEC2 \
  --filters name=instanceType,values="$ITYPE" name=region,values="$TARGET_REGION" \
           name=tenancy,values=shared name=productDescription,values="Linux/UNIX" \
  --query 'searchResults[0].{Rate:rate,Unit:unit,Usage:usageType,Op:operation}' \
  --output table
```

```text
-------------------------------------------------------------------
|              DescribeSavingsPlansOfferingRates                  |
+---------+--------------+-----------+--------------------------- +
|   Op    |    Rate      |   Unit    |          Usage             |
+---------+--------------+-----------+----------------------------+
| RunInstances|  0.0655  |   Hrs     |  BoxUsage:m6i.large        |
+---------+--------------+-----------+----------------------------+
```

3. Repeat for an **EC2 Instance Savings Plan**, which trades flexibility for a deeper discount:

```bash
EC2SP=$(aws savingsplans describe-savings-plans-offerings --region "$PRICING_REGION" \
  --plan-types EC2Instance --durations 31536000 --payment-options "No Upfront" \
  --currencies USD --filters name=instanceFamily,values=m6i name=region,values="$TARGET_REGION" \
  --query 'searchResults[0].offeringId' --output text)

aws savingsplans describe-savings-plans-offering-rates --region "$PRICING_REGION" \
  --savings-plan-offering-ids "$EC2SP" --service-codes AmazonEC2 \
  --filters name=instanceType,values="$ITYPE" name=tenancy,values=shared \
  --query 'searchResults[0].rate' --output text
```

```text
0.0605
```

4. Build the complete comparison table for one always-on instance:

```bash
python3 - <<'PY'
OD = 0.0960
rows = [
  ("On-Demand",                 OD,     "any",              "none"),
  ("Compute SP 1yr NU",         0.0655, "any family/Region/OS/tenancy + Fargate + Lambda", "$/hr for 1yr"),
  ("EC2 Instance SP 1yr NU",    0.0605, "m6i family, us-east-1, any size/OS/AZ",           "$/hr for 1yr"),
  ("Standard RI 1yr NU",        0.0605, "m6i family, us-east-1, Linux, size-flexible",     "capacity+$ for 1yr"),
  ("Compute SP 3yr AU",         0.0410, "same as Compute SP",                              "$/hr for 3yr"),
  ("Spot",                      0.0350, "interruptible only",                              "none"),
]
for n, r, flex, commit in rows:
    print(f"{n:<24}{r:>8.4f}  {1-r/OD:>4.0%}  {commit:<20} {flex}")
PY
```

```text
On-Demand                 0.0960     0%  none                 any
Compute SP 1yr NU         0.0655    32%  $/hr for 1yr         any family/Region/OS/tenancy + Fargate + Lambda
EC2 Instance SP 1yr NU    0.0605    37%  $/hr for 1yr         m6i family, us-east-1, any size/OS/AZ
Standard RI 1yr NU        0.0605    37%  capacity+$ for 1yr   m6i family, us-east-1, Linux, size-flexible
Compute SP 3yr AU         0.0410    57%  $/hr for 3yr         same as Compute SP
Spot                      0.0350    64%  interruptible only   interruptible only
```

5. Understand the **commitment arithmetic**. You do not buy "3 instances"; you buy "$0.20/hour":

```bash
python3 - <<'PY'
commit   = 0.20          # $/hr you sign up for
sp_rate  = 0.0655        # discounted rate per instance-hour
od_rate  = 0.0960
covered  = commit / sp_rate
print(f"Commitment ${commit}/hr covers {covered:.2f} m6i.large-hours per hour")
for running in (2, 3, 4):
    used   = min(running * sp_rate, commit)
    unused = commit - used
    over   = max(0, running - commit/sp_rate) * od_rate
    print(f"  running {running}: SP charge ${commit:.4f} "
          f"(wasted ${unused:.4f}) + On-Demand overflow ${over:.4f} "
          f"= ${commit+over:.4f}/hr")
PY
```

```text
Commitment $0.2/hr covers 3.05 m6i.large-hours per hour
  running 2: SP charge $0.2000 (wasted $0.0690) + On-Demand overflow $0.0000 = $0.2000/hr
  running 3: SP charge $0.2000 (wasted $0.0035) + On-Demand overflow $0.0000 = $0.2000/hr
  running 4: SP charge $0.2000 (wasted $0.0000) + On-Demand overflow $0.0911 = $0.2911/hr
```

6. Inspect any Savings Plans you already own (returns an empty list if none):

```bash
aws savingsplans describe-savings-plans --region "$PRICING_REGION" \
  --query 'savingsPlans[].{Id:savingsPlanId,Type:savingsPlanType,Commit:commitment,State:state,End:end}' \
  --output table
```

### Checkpoint 3

1. State in one sentence the difference between what an RI commits you to and what a Savings Plan commits you to.
2. A Compute Savings Plan gives 32% off and an EC2 Instance Savings Plan 37% off, for the same instance. Name three concrete changes to your architecture that the Compute plan would absorb without penalty and the EC2 Instance plan would not.
3. In step 5 with 4 instances running, why is the total $0.2911/hr and not $0.2620/hr (4 × $0.0655)?
4. Your commitment is $0.20/hr and you run only 2 instances all month. How much money is wasted per month, and what does that imply about how you should *size* a commitment?
5. Which compute services besides EC2 does a Compute Savings Plan cover? Which pricing model would you use for a Fargate-based service that runs continuously?
6. Neither RIs nor Savings Plans reduce the *price* of a running instance in the invoice sense — they apply as a billing-time discount. What operational consequence follows for a team that buys an RI in Account A of an AWS Organization while the instance runs in Account B?
7. Your workload is steady but you expect to migrate from x86 to Graviton (`m7g`) within nine months. Compare a 3-year Standard RI, a 3-year EC2 Instance Savings Plan, and a 3-year Compute Savings Plan for this case.

---

## Exercise 4 — Spot Instances: pricing the risk of interruption

### Steps

1. Pull a week of Spot price history and see how stable modern Spot pricing is:

```bash
aws ec2 describe-spot-price-history --region "$TARGET_REGION" \
  --instance-types "$ITYPE" --product-descriptions "Linux/UNIX" \
  --start-time "$(date -u -d '7 days ago' +%Y-%m-%dT%H:%M:%SZ)" \
  --query 'SpotPriceHistory[?AvailabilityZone==`us-east-1a`].[Timestamp,SpotPrice]' \
  --output text | sort | head -5
```

```text
2026-08-28T00:12:41+00:00	0.034500
2026-08-29T13:04:07+00:00	0.035100
2026-08-31T06:41:22+00:00	0.034800
2026-09-02T09:55:13+00:00	0.036200
2026-09-03T18:20:04+00:00	0.035700
```

2. Compute the current discount per Availability Zone — Spot prices are **per AZ**, and the spread is often larger than people expect:

```bash
aws ec2 describe-spot-price-history --region "$TARGET_REGION" \
  --instance-types "$ITYPE" --product-descriptions "Linux/UNIX" \
  --start-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --query 'SpotPriceHistory[].[AvailabilityZone,SpotPrice]' --output text \
| while read -r az price; do
    printf '%-14s %s  (%.0f%% off On-Demand)\n' "$az" "$price" \
      "$(python3 -c "print((1-$price/0.096)*100)")"
  done
```

```text
us-east-1a     0.035700  (63% off On-Demand)
us-east-1b     0.038900  (59% off On-Demand)
us-east-1c     0.034100  (64% off On-Demand)
us-east-1d     0.041200  (57% off On-Demand)
```

3. Ask AWS how likely it is that capacity will be available, before you design around it:

```bash
aws ec2 get-spot-placement-scores --region "$TARGET_REGION" \
  --instance-types "$ITYPE" --target-capacity 20 --target-capacity-unit-type vcpu \
  --region-names us-east-1 us-west-2 eu-west-1 \
  --query 'SpotPlacementScores[].{Region:Region,Score:Score}' --output table
```

```text
------------------------
| GetSpotPlacementScores|
+-------------+--------+
|   Region    | Score  |
+-------------+--------+
|  us-west-2  |  10    |
|  us-east-1  |   8    |
|  eu-west-1  |   6    |
+-------------+--------+
```

4. Price the *risk*, not just the rate. A batch job of 1,000 instance-hours with a 5% hourly interruption probability and a 12-minute average loss of work per interruption:

```bash
python3 - <<'PY'
hours, od, spot, p_int, rework_h = 1000, 0.0960, 0.0357, 0.05, 0.20
wasted = hours * p_int * rework_h
eff_hours = hours + wasted
print(f"On-Demand           : ${hours*od:8.2f}")
print(f"Spot (naive)        : ${hours*spot:8.2f}")
print(f"Spot + {wasted:.0f} h rework : ${eff_hours*spot:8.2f}  "
      f"-> real saving {1-eff_hours*spot/(hours*od):.0%}")
PY
```

```text
On-Demand           : $   96.00
Spot (naive)        : $   35.70
Spot + 10 h rework  : $   36.06  -> real saving 62%
```

5. Now redo the calculation with a job that **cannot checkpoint**, so an interruption forfeits the whole run so far (average 50% of a 6-hour job lost):

```bash
python3 - <<'PY'
job_h, od, spot, p_int_job = 6, 0.0960, 0.0357, 0.26   # ~26% chance over 6 h at 5%/h
expected_runs = 1/(1-p_int_job)
print(f"expected attempts: {expected_runs:.2f}")
print(f"Spot cost: ${expected_runs*job_h*spot + expected_runs*p_int_job*job_h*0.5*spot:8.2f}")
print(f"OD   cost: ${job_h*od:8.2f}")
PY
```

```text
expected attempts: 1.35
Spot cost: $    0.33
OD   cost: $    0.58
```

### Checkpoint 4

1. What notification does AWS send before reclaiming a Spot Instance, how much warning does it give, and what earlier signal exists?
2. Spot prices in step 2 vary by 21% between `us-east-1b` and `us-east-1c` at the same instant. What does that spread physically represent, and what does it tell you to do with your Auto Scaling group configuration?
3. Classify each as Spot-suitable or not, with one reason each: (a) a nightly Spark ETL with checkpointing to S3, (b) a stateful WebSocket gateway holding user sessions, (c) a Jenkins build agent pool, (d) the primary node of a self-managed PostgreSQL cluster, (e) CI-driven image rendering.
4. In step 5, Spot still wins even without checkpointing. What input would have to change for On-Demand to win, and what does that tell you about *where* to spend engineering effort?
5. Can a Savings Plan or a Reserved Instance discount apply to Spot usage? Explain why the answer follows from what each mechanism actually is.
6. A Spot Instance is interrupted. Name the three interruption behaviors AWS can apply and which one preserves the root EBS volume's data.

---

## Exercise 5 — Tenancy and licensing: Shared, Dedicated Instance, Dedicated Host

### Steps

1. Price the same instance under all three tenancies:

```bash
for t in Shared Dedicated; do
  p=$(aws pricing get-products --region "$PRICING_REGION" --service-code AmazonEC2 \
    --filters "Type=TERM_MATCH,Field=instanceType,Value=$ITYPE" \
      "Type=TERM_MATCH,Field=regionCode,Value=$TARGET_REGION" \
      'Type=TERM_MATCH,Field=operatingSystem,Value=Linux' \
      "Type=TERM_MATCH,Field=tenancy,Value=$t" \
      'Type=TERM_MATCH,Field=preInstalledSw,Value=NA' \
      'Type=TERM_MATCH,Field=capacitystatus,Value=Used' \
    --query 'PriceList[0]' --output text \
    | jq -r '.terms.OnDemand[].priceDimensions[].pricePerUnit.USD')
  printf '%-12s %s USD/hr\n' "$t" "$p"
done
```

```text
Shared       0.0960000000 USD/hr
Dedicated    0.1056000000 USD/hr
```

2. Price a **Dedicated Host**, which is billed per *host*, not per instance:

```bash
aws pricing get-products --region "$PRICING_REGION" --service-code AmazonEC2 \
  --filters 'Type=TERM_MATCH,Field=instanceType,Value=m6i.large' \
    "Type=TERM_MATCH,Field=regionCode,Value=$TARGET_REGION" \
    'Type=TERM_MATCH,Field=tenancy,Value=Host' \
    'Type=TERM_MATCH,Field=operatingSystem,Value=Linux' \
    'Type=TERM_MATCH,Field=capacitystatus,Value=Used' \
  --query 'PriceList[0]' --output text \
  | jq -r '.product.attributes | {instanceFamily, physicalCores: .physicalCores, sockets: .physicalProcessor}'
```

3. List Dedicated Host **reservation** offerings — the commitment mechanism that exists specifically for host tenancy:

```bash
aws ec2 describe-host-reservation-offerings --region "$TARGET_REGION" \
  --filter Name=instance-family,Values=m6i \
  --query 'OfferingSet[?PaymentOption==`NoUpfront` && Duration==`31536000`].{Id:OfferingId,Hourly:HourlyPrice,Upfront:UpfrontPrice,Pay:PaymentOption}' \
  --output table
```

```text
--------------------------------------------------------------------
|                  DescribeHostReservationOfferings                |
+------------+--------------------------------------+-----+--------+
|  Hourly    |                  Id                  | Pay | Upfront|
+------------+--------------------------------------+-----+--------+
|  2.5220    | hro-03f707bf363b6b324                |NoUpfront| 0.00|
+------------+--------------------------------------+-----+--------+
```

4. Compare the total cost of 20 `m6i.large` on shared tenancy versus one Dedicated Host that fits them:

```bash
python3 - <<'PY'
shared_each, host_hourly, n = 0.0960, 2.5220, 20
print(f"20x shared      : ${shared_each*n*730:8.2f}/month")
print(f"1x ded. host    : ${host_hourly*730:8.2f}/month  (fixed, regardless of instances placed)")
print(f"break-even at   : {host_hourly/shared_each:.1f} instances")
PY
```

```text
20x shared      : $ 1401.60/month
1x ded. host    : $ 1841.06/month  (fixed, regardless of instances placed)
break-even at   : 26.3 instances
```

### Checkpoint 5

1. Dedicated Instance tenancy costs 10% more than Shared for the same instance. What are you buying with that 10%, and what are you *not* buying that a Dedicated Host would give you?
2. Dedicated Host billing is per host-hour and does not change when you start or stop instances on it. Which pricing dimension has effectively been converted into which other one, and what does that do to your incentive structure?
3. Your organization has an Oracle Database license bound to physical CPU sockets. Which tenancy model is mandatory, and why is the answer not "Dedicated Instances"?
4. Which commitment mechanism reduces the cost of Dedicated Host usage — Standard RIs, Convertible RIs, Compute Savings Plans, or something else?
5. A compliance requirement says "no other tenant's workload may run on the same hardware." A second requirement says "we must report the physical socket and core count to the auditor." Which requirement forces which choice?
6. Distinguish an **On-Demand Capacity Reservation** from a zonal Reserved Instance in terms of (a) what it guarantees and (b) how it is billed.

---

## Exercise 6 — Consumption pricing: Lambda and S3 storage classes

**Goal:** see that serverless and storage pricing are the *same* three dimensions, expressed in different units.

### Steps

1. Pull Lambda's unit prices from the same API:

```bash
aws pricing get-products --region "$PRICING_REGION" --service-code AWSLambda \
  --filters "Type=TERM_MATCH,Field=regionCode,Value=$TARGET_REGION" \
    'Type=TERM_MATCH,Field=group,Value=AWS-Lambda-Requests' \
  --query 'PriceList[0]' --output text \
  | jq -r '.terms.OnDemand[].priceDimensions[] | "\(.pricePerUnit.USD)\t\(.unit)\t\(.description)"'
```

```text
0.0000002000	Requests	$0.20 per 1M requests
```

```bash
aws pricing get-products --region "$PRICING_REGION" --service-code AWSLambda \
  --filters "Type=TERM_MATCH,Field=regionCode,Value=$TARGET_REGION" \
    'Type=TERM_MATCH,Field=group,Value=AWS-Lambda-Duration' \
  --query 'PriceList[0]' --output text \
  | jq -r '.terms.OnDemand[].priceDimensions[] | "\(.pricePerUnit.USD)\t\(.unit)"'
```

```text
0.0000166667	Second   (per GB-second)
```

2. Compute the monthly cost of a real API: 5 M invocations, 512 MB memory, 300 ms average duration:

```bash
python3 - <<'PY'
inv, mem_gb, dur_s = 5_000_000, 0.5, 0.300
REQ_PRICE, GBS_PRICE = 0.20/1_000_000, 0.0000166667
FREE_REQ, FREE_GBS = 1_000_000, 400_000        # always-free tier

gbs = inv * dur_s * mem_gb
req_cost = max(0, inv - FREE_REQ) * REQ_PRICE
gbs_cost = max(0, gbs - FREE_GBS) * GBS_PRICE
print(f"GB-seconds consumed : {gbs:,.0f}")
print(f"Request charge      : ${req_cost:7.2f}")
print(f"Duration charge     : ${gbs_cost:7.2f}")
print(f"TOTAL               : ${req_cost+gbs_cost:7.2f}/month")
PY
```

```text
GB-seconds consumed : 750,000
Request charge      : $   0.80
Duration charge     : $   5.83
TOTAL               : $   6.63/month
```

3. Find the crossover point against an always-on EC2 instance serving the same API:

```bash
python3 - <<'PY'
ec2_month = 0.0960*730           # one m6i.large On-Demand
REQ, GBS = 0.20/1e6, 0.0000166667
mem, dur = 0.5, 0.300
per_inv = REQ + dur*mem*GBS
print(f"m6i.large On-Demand   : ${ec2_month:6.2f}/month")
print(f"cost per invocation   : ${per_inv:.9f}")
print(f"crossover             : {ec2_month/per_inv:,.0f} invocations/month")
PY
```

```text
m6i.large On-Demand   : $ 70.08/month
cost per invocation   : $0.000002700
crossover             : 25,955,556 invocations/month
```

4. Now the storage dimension. Extract S3 storage-class prices for the first tier:

```bash
aws pricing get-products --region "$PRICING_REGION" --service-code AmazonS3 \
  --filters "Type=TERM_MATCH,Field=regionCode,Value=$TARGET_REGION" \
    'Type=TERM_MATCH,Field=productFamily,Value=Storage' \
  --output json \
| jq -r '.PriceList[] | fromjson
  | . as $p | .terms.OnDemand[].priceDimensions[]
  | select(.beginRange=="0")
  | "\($p.product.attributes.storageClass)\t\(.pricePerUnit.USD)\t\(.unit)"' | sort -u
```

```text
Archive	                0.0036000000	GB-Mo
Deep Archive	        0.0009900000	GB-Mo
General Purpose	        0.0230000000	GB-Mo
Infrequent Access	0.0125000000	GB-Mo
Non-Critical Data	0.0100000000	GB-Mo
```

5. Model 10 TB of data under three lifecycle strategies, including retrieval and minimum-duration penalties:

```bash
python3 - <<'PY'
TB = 10 * 1024                     # GB
plans = {
 "All S3 Standard":        (TB*0.023, 0),
 "Standard-IA (5% read/mo)": (TB*0.0125, TB*0.05*0.01),
 "Glacier Flexible (1% read/mo)": (TB*0.0036, TB*0.01*0.01),
 "Deep Archive (0.1% read/mo)": (TB*0.00099, TB*0.001*0.02),
}
for name,(store,retr) in plans.items():
    print(f"{name:<32} storage ${store:8.2f} + retrieval ${retr:6.2f} = ${store+retr:8.2f}/mo")
PY
```

```text
All S3 Standard                  storage $  235.52 + retrieval $  0.00 = $  235.52/mo
Standard-IA (5% read/mo)         storage $  128.00 + retrieval $  5.12 = $  133.12/mo
Glacier Flexible (1% read/mo)    storage $   36.86 + retrieval $  1.02 = $   37.88/mo
Deep Archive (0.1% read/mo)      storage $   10.14 + retrieval $  0.20 = $   10.34/mo
```

6. Add the hidden constraints that turn a good spreadsheet into a bad bill — minimum billable object size and minimum storage duration:

| Class | Min. billable size | Min. storage duration | Retrieval fee | Retrieval latency |
|---|---|---|---|---|
| S3 Standard | — | — | none | ms |
| S3 Intelligent-Tiering | — | — | none | ms (+ per-object monitoring fee) |
| S3 Standard-IA | 128 KB | 30 days | per GB | ms |
| S3 One Zone-IA | 128 KB | 30 days | per GB | ms (single AZ) |
| S3 Glacier Instant Retrieval | 128 KB | 90 days | per GB (higher) | ms |
| S3 Glacier Flexible Retrieval | 40 KB | 90 days | per GB | minutes–hours |
| S3 Glacier Deep Archive | 40 KB | 180 days | per GB | hours |

```bash
python3 - <<'PY'
n, real_kb = 4_000_000, 20        # 4M objects of 20 KB each
real_gb    = n*real_kb/1024/1024
billed_gb  = n*128/1024/1024      # 128 KB minimum in Standard-IA
print(f"actual data : {real_gb:8.2f} GB -> ${real_gb*0.0125:6.2f}/mo at IA rate")
print(f"billed data : {billed_gb:8.2f} GB -> ${billed_gb*0.0125:6.2f}/mo  <-- what you pay")
print(f"S3 Standard : {real_gb:8.2f} GB -> ${real_gb*0.023:6.2f}/mo  <-- cheaper!")
PY
```

```text
actual data :    76.29 GB -> $  0.95/mo at IA rate
billed data :   488.28 GB -> $  6.10/mo  <-- what you pay
S3 Standard :    76.29 GB -> $  1.75/mo  <-- cheaper!
```

### Checkpoint 6

1. Lambda has two price dimensions. Name them and state which one a developer changes by tuning the memory setting — and why raising memory sometimes *lowers* the bill.
2. The crossover in step 3 is ~26 M invocations/month. List three cost factors this comparison ignores that would move the crossover in Lambda's favor.
3. In step 6, moving 4 M small objects to Standard-IA made them **3.5× more expensive**. Explain the mechanism, and name the S3 feature designed to avoid exactly this mistake automatically.
4. You lifecycle an object to Glacier Flexible Retrieval and delete it 20 days later. What are you billed?
5. S3 One Zone-IA is 20% cheaper than Standard-IA. What durability property are you selling, and name one data set for which that trade is correct.
6. Which of these is a *storage* charge and which is a *request* charge: `PutObject` of a 1 GB file; keeping that file for a month; `ListObjectsV2` over 10,000 keys?

---

## Exercise 7 — Data transfer: the dimension nobody models

### Steps

1. Enumerate the data-transfer SKUs for your Region:

```bash
aws pricing get-products --region "$PRICING_REGION" --service-code AWSDataTransfer \
  --filters "Type=TERM_MATCH,Field=fromLocation,Value=US East (N. Virginia)" \
    'Type=TERM_MATCH,Field=transferType,Value=AWS Outbound' \
  --output json \
| jq -r '.PriceList[] | fromjson | . as $p | .terms.OnDemand[].priceDimensions[]
  | "\(.beginRange)-\(.endRange) GB\t\(.pricePerUnit.USD)\t\($p.product.attributes.toLocation)"' \
  | sort -u | head
```

```text
0-10240 GB	0.0900000000	External
10240-51200 GB	0.0850000000	External
51200-153600 GB	0.0700000000	External
153600-Inf GB	0.0500000000	External
```

2. Internalize the rule set that the exam and your bill both depend on:

| Path | Charge (typical) |
|---|---|
| Internet → AWS (data in) | **$0.00** |
| AWS → Internet (data out) | Tiered; **first 100 GB/month free** across the account |
| Between AZs in the same Region | Charged **both directions** (~$0.01/GB each way) |
| Within one AZ, via private IPv4 | **$0.00** |
| Within one AZ, via public IP or Elastic IP | **Charged** |
| Between Regions | Charged, rate depends on the pair |
| AWS origin → Amazon CloudFront | **$0.00** |
| CloudFront → Internet | Charged, but lower than direct egress; **1 TB/month free tier** |
| Via S3/DynamoDB **Gateway** VPC endpoint | **$0.00** for the endpoint |
| Via **Interface** VPC endpoint (PrivateLink) | Hourly per-ENI charge **+** per-GB |

3. Cost the same 50 TB/month of egress three ways:

```bash
python3 - <<'PY'
GB = 50*1024
def tiered(gb, tiers):
    free, cost, rem = 100, 0.0, gb
    rem -= min(rem, free)
    for size, rate in tiers:
        take = min(rem, size); cost += take*rate; rem -= take
        if rem <= 0: break
    return cost
ec2 = tiered(GB, [(10*1024,0.09),(40*1024,0.085),(100*1024,0.07),(1e9,0.05)])
cf  = tiered(GB, [(10*1024,0.085),(40*1024,0.080),(100*1024,0.060),(1e9,0.040)])
print(f"Direct from EC2/ALB : ${ec2:9,.2f}/month")
print(f"Behind CloudFront   : ${cf:9,.2f}/month  (origin fetch is free)")
print(f"Delta               : ${ec2-cf:9,.2f}/month")
PY
```

```text
Direct from EC2/ALB : $ 4,282.65/month
Behind CloudFront   : $ 4,024.00/month  (origin fetch is free)
Delta               : $   258.65/month
```

4. Cost a cross-AZ chattiness problem — a microservice mesh moving 8 TB/day between AZs:

```bash
python3 - <<'PY'
gb_day, rate_each_way = 8*1024, 0.01
print(f"per month: {gb_day*30:,} GB x ${rate_each_way} x 2 directions = "
      f"${gb_day*30*rate_each_way*2:,.2f}")
PY
```

```text
per month: 245,760 GB x $0.01 x 2 directions = $4,915.20
```

5. Cost the NAT Gateway path, a classic invisible line item — hourly charge **plus** per-GB processing, *on top of* any egress:

```bash
aws pricing get-products --region "$PRICING_REGION" --service-code AmazonEC2 \
  --filters "Type=TERM_MATCH,Field=regionCode,Value=$TARGET_REGION" \
    'Type=TERM_MATCH,Field=productFamily,Value=NAT Gateway' \
  --output json \
| jq -r '.PriceList[] | fromjson | .terms.OnDemand[].priceDimensions[]
  | "\(.pricePerUnit.USD)\t\(.unit)\t\(.description)"' | sort -u
```

```text
0.0450000000	GB	  $0.045 per GB Data Processed by NAT Gateways
0.0450000000	Hrs	  $0.045 per NAT Gateway Hour
```

### Checkpoint 7

1. Data *in* from the internet is free while data *out* is expensive. What business behavior is that asymmetry designed to produce, and what is the architectural implication for a data-lake design?
2. Your app pulls 30 TB/month from S3 to EC2 **in the same Region**, through a NAT Gateway. Compute the NAT processing charge and name the one free change that eliminates it entirely.
3. Two EC2 instances in the same AZ communicate. Give one configuration in which that traffic is free and one in which it is billed. What is the single difference?
4. Cross-AZ traffic is charged in both directions. What does that do to the true cost of a "highly available" multi-AZ deployment, and how do you decide it is still worth it?
5. Why is origin→CloudFront transfer free? What is AWS's incentive?
6. An architect proposes a multi-Region active-active deployment for latency. Which pricing dimension will dominate the incremental bill, and which AWS tool would you use *before* building to quantify it?

---

## Exercise 8 — Free Tier and the guardrails around it

### Steps

1. Query your actual Free Tier consumption. The API returns the **three categories the exam tests**, labeled:

```bash
aws freetier get-free-tier-usage --region us-east-1 \
  --query 'freeTierUsages[].{Svc:service,Type:freeTierType,Used:actualUsageAmount,Fcst:forecastedUsageAmount,Limit:limit,Unit:unit}' \
  --output table
```

```text
------------------------------------------------------------------------------------
|                               GetFreeTierUsage                                   |
+-------+---------------+--------+--------+---------+-----------------------------+
| Fcst  |    Limit      | Svc    | Unit   |  Used   |            Type             |
+-------+---------------+--------+--------+---------+-----------------------------+
| 750.0 |  750.0        | AmazonEC2| Hrs  |  612.0  |  12 Months Free             |
| 5.0   |  5.0          | AmazonS3| GB-Mo |   3.1   |  12 Months Free             |
| 1.2E6 |  1.0E6        | AWSLambda| Requests| 940000|  Always Free               |
| 25.0  |  25.0         | AmazonDynamoDB| GB-Mo| 11.4 |  Always Free               |
| 15.0  |  15.0         | AmazonInspector| Days| 9.0  |  Free Trial                |
+-------+---------------+--------+--------+---------+-----------------------------+
```

2. Filter to only what is forecast to **exceed** its limit — the actionable subset:

```bash
aws freetier get-free-tier-usage --region us-east-1 --output json \
| jq -r '.freeTierUsages[]
   | select(.forecastedUsageAmount > .limit)
   | "OVERRUN  \(.service)\t\(.forecastedUsageAmount) / \(.limit) \(.unit)\t[\(.freeTierType)]"'
```

```text
OVERRUN  AWSLambda	1200000 / 1000000 Requests	[Always Free]
```

3. Create a **zero-spend budget** so that the first cent of unexpected charge notifies you:

```bash
cat > /tmp/budget.json <<EOF
{
  "BudgetName": "clf-4-1-zero-spend",
  "BudgetLimit": { "Amount": "1", "Unit": "USD" },
  "TimeUnit": "MONTHLY",
  "BudgetType": "COST",
  "CostTypes": {
    "IncludeCredit": false,
    "IncludeRefund": false,
    "IncludeDiscount": true,
    "IncludeSubscription": true,
    "IncludeSupport": true,
    "IncludeTax": true,
    "IncludeUpfront": true,
    "IncludeRecurring": true,
    "IncludeOtherSubscription": true,
    "UseAmortized": false,
    "UseBlended": false
  }
}
EOF

cat > /tmp/notify.json <<'EOF'
[{
  "Notification": {
    "NotificationType": "ACTUAL",
    "ComparisonOperator": "GREATER_THAN",
    "Threshold": 0.01,
    "ThresholdType": "ABSOLUTE_VALUE"
  },
  "Subscribers": [{ "SubscriptionType": "EMAIL", "Address": "you@example.com" }]
}]
EOF

aws budgets create-budget --account-id "$ACCOUNT_ID" \
  --budget file:///tmp/budget.json \
  --notifications-with-subscribers file:///tmp/notify.json
```

4. Confirm it exists:

```bash
aws budgets describe-budgets --account-id "$ACCOUNT_ID" \
  --query 'Budgets[].{Name:BudgetName,Limit:BudgetLimit.Amount,Spent:CalculatedSpend.ActualSpend.Amount}' \
  --output table
```

```text
-------------------------------------------------
|               DescribeBudgets                 |
+---------------------+---------+---------------+
|        Name         |  Limit  |     Spent     |
+---------------------+---------+---------------+
|  clf-4-1-zero-spend |  1      |  0.0000000000 |
+---------------------+---------+---------------+
```

> **Account-plan note:** AWS revised the Free Tier offering in 2025 — newer accounts may be enrolled in a credit-based *Free Plan* (signup credits plus activity credits) rather than the classic 12-month model, while the **Always Free** offers continue for everyone. `aws freetier get-account-plan-state` (recent CLI versions) reports which plan you are on. The CLF-C02 exam still tests the three categories the API labels above. Confirm at <https://aws.amazon.com/free/>.

### Checkpoint 8

1. Name the three Free Tier categories and give one service example of each from your own output.
2. `AmazonEC2 750 Hrs` is under "12 Months Free". What happens on day 366 if nothing changes, and what does *750 hours* actually mean for someone running two instances?
3. The budget in step 3 sets `IncludeCredit: false`. Why is that the correct setting for a guardrail budget, and what would you see if it were `true`?
4. Why is a Budget an *alert* and not a *cap*? What would you have to add to make anything actually stop?
5. Your Lambda "Always Free" allowance is forecast to be exceeded by 20%. What is the actual dollar consequence? Compute it.
6. Which is free and which is billed: the first two AWS Budgets, the Cost Explorer console, the Cost Explorer API, the AWS Pricing Calculator?

---

## Exercise 9 — Let your own usage choose the model

> **These two commands are billed at $0.01 each.**

### Steps

1. Break last month's spend down by purchase type — the single most informative billing query there is:

```bash
aws ce get-cost-and-usage --region "$PRICING_REGION" \
  --time-period Start=$(date -u -d 'last month' +%Y-%m-01),End=$(date -u +%Y-%m-01) \
  --granularity MONTHLY --metrics "UnblendedCost" \
  --group-by Type=DIMENSION,Key=PURCHASE_TYPE \
  --query 'ResultsByTime[0].Groups[].{Type:Keys[0],Cost:Metrics.UnblendedCost.Amount}' \
  --output table
```

```text
-------------------------------------------------------
|                 GetCostAndUsage                     |
+---------------+-------------------------------------+
|     Cost      |               Type                  |
+---------------+-------------------------------------+
|  412.88       |  On Demand Instances                |
|  180.44       |  Savings Plan Covered Usage         |
|   96.10       |  Standard Reserved Instances        |
|   22.71       |  Spot Instances                     |
+---------------+-------------------------------------+
```

2. Ask AWS what commitment your own usage justifies:

```bash
aws ce get-savings-plans-purchase-recommendation --region "$PRICING_REGION" \
  --savings-plans-type COMPUTE_SP --term-in-years ONE_YEAR \
  --payment-option NO_UPFRONT --lookback-period-in-days SIXTY_DAYS \
  --query 'SavingsPlansPurchaseRecommendation.SavingsPlansPurchaseRecommendationSummary' \
  --output json
```

```json
{
  "EstimatedROI": "312.4",
  "CurrencyCode": "USD",
  "EstimatedTotalCost": "3420.55",
  "CurrentOnDemandSpend": "4980.10",
  "EstimatedSavingsAmount": "1559.55",
  "TotalRecommendationCount": "1",
  "DailyCommitmentToPurchase": "4.62",
  "HourlyCommitmentToPurchase": "0.1925",
  "EstimatedSavingsPercentage": "31.3",
  "EstimatedMonthlySavingsAmount": "129.96"
}
```

3. Check how well existing commitments are being used — an unused commitment is a pure loss:

```bash
aws ce get-savings-plans-utilization --region "$PRICING_REGION" \
  --time-period Start=$(date -u -d 'last month' +%Y-%m-01),End=$(date -u +%Y-%m-01) \
  --granularity MONTHLY \
  --query 'Total.{Used:UtilizationPercentage,Unused:UnusedCommitment,Net:NetSavings}' \
  --output table
```

```text
------------------------------------------
|      GetSavingsPlansUtilization         |
+---------+-----------+-------------------+
|  Net    |  Unused   |       Used        |
+---------+-----------+-------------------+
| 118.72  |  6.41     |  96.4             |
+---------+-----------+-------------------+
```

4. Before committing to *anything*, check whether the instance should be smaller (free):

```bash
aws compute-optimizer get-ec2-instance-recommendations --region "$TARGET_REGION" \
  --query 'instanceRecommendations[?finding==`OVER_PROVISIONED`].{Arn:instanceArn,Now:currentInstanceType,Rec:recommendationOptions[0].instanceType,Save:recommendationOptions[0].savingsOpportunity.estimatedMonthlySavings.value}' \
  --output table
```

```text
----------------------------------------------------------------------
|                 GetEC2InstanceRecommendations                      |
+---------------------------+-------------+-------------+------------+
|            Arn            |     Now     |     Rec     |    Save    |
+---------------------------+-------------+-------------+------------+
|  arn:aws:ec2:...:i-0abc12 |  m6i.2xlarge|  m6i.large  |   210.24   |
+---------------------------+-------------+-------------+------------+
```

### Checkpoint 9

1. Step 1 shows $412.88 of On-Demand spend. Is that automatically waste? What further question must you ask before recommending a commitment?
2. Savings Plans utilization is 96.4% with $6.41 unused. Is that good? What utilization figure would make you *reduce* the next commitment, and why is 100% not necessarily the goal either?
3. Compute Optimizer says an instance is over-provisioned and could save $210/month. Explain why running this **before** buying a Savings Plan is not optional.
4. Order these four actions correctly for a cost-optimization program, and justify the order: buy commitments, right-size instances, eliminate idle resources, move eligible workloads to Spot.
5. The recommendation says commit to $0.1925/hour, not $0.25 even though current On-Demand spend is higher. What conservatism is AWS's algorithm applying, and would you commit to *more* or *less* than it suggests? Give the reasoning for each direction.

---

## Capstone — Build the decision matrix

### Steps

1. Model this system in the **AWS Pricing Calculator** at <https://calculator.aws/#/>, one estimate per component:

| # | Component | Shape |
|---|---|---|
| 1 | Public API tier | 3 × `m6i.large`, 24/7, 3-year horizon, must not be interrupted |
| 2 | Nightly ETL | 400 instance-hours/month, fault-tolerant, checkpoints to S3 |
| 3 | Analytics warehouse | Steady but the team may migrate it from EC2 to Fargate in 8 months |
| 4 | Webhook receiver | 40 M invocations/month, 128 MB, 80 ms |
| 5 | Raw event archive | 40 TB, read < 1×/year, restore may take hours |
| 6 | Compliance database | Oracle, socket-bound license, auditor requires physical core reporting |
| 7 | Egress to customers | 25 TB/month of static assets |

2. For each component, write down: chosen pricing model, the *one* property of the workload that forces that choice, and the estimated monthly cost.

3. Export the estimate (**Share** → public link, or **Export** → CSV) and reconcile at least two line items against the Price List API values you queried in Exercises 1–7. Investigate any difference over 5%.

4. Write a three-sentence justification for the riskiest commitment in your matrix, stating explicitly what would have to change for the decision to become wrong.

### Checkpoint — Capstone

1. Fill in the model for each of the seven components.
2. Component 3 is steady-state but is migrating from EC2 to Fargate. Which single pricing model survives that migration with its discount intact? What would a 3-year EC2 Instance Savings Plan have cost you?
3. Component 7 is 25 TB/month of egress. Where does it sit in the tiered pricing table, and what is the first architectural change you would propose?
4. Which two components could share one Compute Savings Plan commitment? Which one could not participate at all?
5. State the general rule that maps a workload's *time profile* to its pricing model, in one sentence.

---

## Cleanup

```bash
aws budgets delete-budget --account-id "$ACCOUNT_ID" --budget-name clf-4-1-zero-spend
rm -f /tmp/m6i-large.json /tmp/budget.json /tmp/notify.json
```

```bash
aws budgets describe-budgets --account-id "$ACCOUNT_ID" --query 'length(Budgets)'
```

```text
0
```

Nothing else created a billable resource. If you want to keep one artifact, keep the budget — a zero-spend alert is the cheapest insurance in AWS.

---

## Sources

- AWS Certified Cloud Practitioner (CLF-C02) Exam Guide — <https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf>
- Using the AWS Price List API — <https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/price-changes.html>
- Amazon EC2 Instance Purchasing Options — <https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/instance-purchasing-options.html>
- Reserved Instances (EC2 User Guide) — <https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-reserved-instances.html>
- Savings Plans User Guide — <https://docs.aws.amazon.com/savingsplans/latest/userguide/what-is-savings-plans.html>
- Spot Instances (EC2 User Guide) — <https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/using-spot-instances.html>
- Dedicated Hosts — <https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/dedicated-hosts-overview.html>
- Amazon S3 storage classes — <https://docs.aws.amazon.com/AmazonS3/latest/userguide/storage-class-intro.html>
- AWS Lambda pricing — <https://aws.amazon.com/lambda/pricing/>
- Amazon EC2 On-Demand pricing (incl. data transfer) — <https://aws.amazon.com/ec2/pricing/on-demand/>
- AWS Cost Explorer — <https://docs.aws.amazon.com/cost-management/latest/userguide/ce-what-is.html>
- AWS Budgets — <https://docs.aws.amazon.com/cost-management/latest/userguide/budgets-managing-costs.html>
- AWS Free Tier — <https://aws.amazon.com/free/> · Free Tier API — <https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/checkfreetier.html>
- AWS Pricing Calculator — <https://calculator.aws/>
- AWS Compute Optimizer — <https://docs.aws.amazon.com/compute-optimizer/latest/ug/what-is-compute-optimizer.html>

---

<details>
<summary><strong>Answers</strong> — open only after attempting every checkpoint</summary>

### Checkpoint 0

1. `--region` on a `pricing` command selects the **API endpoint**, and the Price List Query API is only served from a few Regions (`us-east-1`, `eu-central-1`, `ap-south-1`), so `eu-west-1` has no endpoint to talk to; the Region whose prices you retrieve is a **filter** (`regionCode` / `location`) inside the request, which is why one endpoint returns prices for every Region.
2. None of the three, in practice. Every action is read-only except `budgets:CreateBudget`, and the first two budgets per account carry no charge. The only genuinely metered calls are the Cost Explorer `ce:Get*` actions, billed per request ($0.01) — an API-request charge, not a compute/storage/transfer charge.
3. 730 = 8,760 ÷ 12, the average month across a year. Using 720 (30 days) would systematically under-state the bill for 31-day months, and monthly comparisons of a 24/7 workload must be consistent, not calendar-accurate.

### Checkpoint 1

1. `capacitystatus` distinguishes what the SKU is charging for. `Used` = an instance actually running. `UnusedCapacityReservation` = an On-Demand Capacity Reservation you are paying for with nothing running in it. `AllocatedCapacityReservation` = capacity allocated to a reservation. If you filtered on the wrong one, you would be pricing *reserved-but-idle* capacity, not running instances — a different product with a different rate, which is exactly how naive scripts return "surprising" numbers.
2. `preInstalledSw` covers commercial software baked into the AMI (SQL Server Standard/Enterprise/Web) whose license is billed through the instance-hour. `licenseModel` distinguishes `No License required` from `Bring your own license`. Together they encode AWS's software-licensing pass-through: the same hardware carries several prices depending on what is licensed on it, so leaving them unfiltered returns SQL Server SKUs alongside plain Linux.
3. Structural drivers: local cost of power, land, construction, labour and taxes; import duties and currency/regulatory overhead; scale and maturity of the Region (a newer or smaller Region amortizes fixed cost over fewer customers); local network/transit costs. Architectural implication: **Region selection is a cost decision as much as a latency/compliance decision** — if data residency and latency permit it, placing batch or non-latency-sensitive workloads in a cheaper Region is a legitimate lever, but it must be weighed against inter-Region data-transfer charges, which can erase the compute saving.
4. (a) AWS changes the price — historically almost always downward — and your chargeback over-bills internal teams forever, silently. (b) The script is reused for another Region, OS, or tenancy where $0.096 was never the rate, producing wrong numbers with no error. A third: it silently ignores any RI/SP coverage, so it reports list price rather than what the company actually paid.
5. ~$0.192/hr — double. **Within a family and generation, On-Demand price scales linearly with size** (this linearity is exactly what makes RI normalization factors work). It does **not** hold across families: `c6i.large` and `m6i.large` have the same vCPU count but different memory-to-vCPU ratios and different prices, because you are buying a different resource mix, not more of the same one.

### Checkpoint 2

1. Because a No Upfront RI is a **billing commitment, not a usage-based discount**: for all 8,760 hours of the term AWS bills you $0.0605/hr whether or not an instance is running. You did not avoid the commitment, you only changed *when* you pay it. Break-even = RI effective hourly ÷ On-Demand hourly = 0.0605/0.096 = 63%.
2. All Upfront > Partial Upfront > No Upfront. The mechanism is the **time value of money and counterparty risk**: paying AWS the whole term up front transfers cash immediately and removes any risk of non-payment, so AWS shares part of that value back as a deeper discount. Note in the sample data that Partial Upfront can compute to a *marginally* better effective rate than All Upfront; always compute rather than assume the ordering is strict.
3. The CI fleet (~30% utilization, interruptible builds) belongs on **Spot**, in a mixed-instances Auto Scaling group with On-Demand as fallback. The artifact repository behind it is always-on, stateful and latency-sensitive — that belongs on a **commitment** (Savings Plan or RI), and its storage on S3 with a lifecycle policy.
4. Convertible is worth it when (a) you expect to change instance **family** during the term — a hardware-generation refresh, a move from `m` to `c`/`r`, or an x86→Graviton migration — since Convertible RIs can be **exchanged** for a different configuration of equal or greater value; and (b) your workload's shape is genuinely uncertain over a 3-year horizon and you are buying optionality. Standard permits something Convertible does not: **selling the RI on the Reserved Instance Marketplace** to exit early.
5. Regional scope buys **flexibility**: the discount floats across every AZ in the Region and, for Linux/default-tenancy, across sizes in the family. It costs you the **capacity reservation** — regional RIs do not guarantee capacity in any specific AZ. Zonal scope gives you a guaranteed slot in one AZ but pins the discount there.
6. Complete. `m6i.2xlarge` = factor 16; four `m6i.large` = 4 × 4 = 16. Exactly covered. If the workload moves to `c6i.large`, the RI **stops applying entirely** — size flexibility works within a family, never across families — and you would pay full On-Demand for the `c6i` while continuing to pay the `m6i` RI. This is precisely the scenario a Compute Savings Plan absorbs.
7. Instance size flexibility applies only to **regional, Linux/UNIX, default-tenancy** Standard RIs. Windows (and other OSes with per-instance license charges such as RHEL/SUSE) is excluded because the license component does not scale linearly with instance size, so normalization would mis-price it. Zonal RIs are excluded because their value is a capacity reservation for a *specific* configuration in a *specific* AZ — floating it would make the guarantee meaningless.

### Checkpoint 3

1. An RI commits you to a **resource configuration** (family, Region, OS, tenancy, optionally AZ) for a term; a Savings Plan commits you to a **dollar amount of compute spend per hour** for a term, and AWS applies the discounted rate to whatever eligible usage fills it.
2. Absorbed by Compute but not by EC2 Instance SP: (a) changing instance **family** (`m6i` → `c7g`), (b) moving the workload to a **different Region**, (c) re-platforming from EC2 to **Fargate or Lambda**. Also changing **tenancy** and changing **OS**. The EC2 Instance plan is locked to one family in one Region.
3. The Savings Plan applies the discounted rate only up to the commitment. $0.20/hr ÷ $0.0655 = 3.05 instance-hours of coverage; the 4th instance is **not covered at all** and bills at the full On-Demand rate of $0.0960, not at the SP rate. Uncovered usage never gets a partial discount — $0.20 + $0.0911 (the uncovered fraction) = $0.2911.
4. Coverage costs $0.1310/hr (2 × $0.0655) against a $0.20/hr commitment → $0.069/hr wasted → **$50.37/month burned for nothing**. Implication: **size the commitment to your usage floor (the trough), not the average or the peak.** Usage above the commitment simply falls back to On-Demand, which is a small penalty; commitment above usage is a total loss.
5. AWS Fargate and AWS Lambda (plus EC2 across all families/Regions/OSes/tenancies), and SageMaker is covered by its own separate SageMaker Savings Plan. A continuously running Fargate service should use a **Compute Savings Plan** — Fargate has no RI equivalent.
6. Both are applied as a **billing-time discount** against matching usage, not as a property of the instance itself. In an AWS Organization with consolidated billing, discounts are shared across accounts by default (RI sharing / Savings Plans sharing at the payer level), so the RI bought in Account A *can* discount Account B's instance — but only if sharing is enabled for those accounts. Turning sharing off, or a mismatch in linked-account settings, silently strands the discount.
7. **3-year Standard RI** — worst: locked to `m6i`, and the only exit is selling on the RI Marketplace. **3-year EC2 Instance SP** — also bad: locked to the `m6i` family in one Region; the Graviton move strands it. **3-year Compute SP** — correct: `m7g` usage draws down the same commitment automatically, since the plan is denominated in dollars and covers every family. The deeper nominal discount of the first two is worthless if the discount stops applying in month nine.

### Checkpoint 4

1. A **Spot Instance interruption notice**, delivered via instance metadata and EventBridge, giving a **two-minute** warning. The earlier signal is the **EC2 instance rebalance recommendation**, which arrives before the interruption notice when Spot capacity is at elevated risk, giving you more time to drain connections or launch a replacement.
2. Spot price is set per **instance type, per OS, per Availability Zone**, and reflects the real-time supply/demand balance for *that pool*. A 21% spread means the pools are independent and unevenly loaded. Configuration consequence: use an ASG with a **mixed instances policy** spanning several instance types **and all AZs**, with the `price-capacity-optimized` allocation strategy — never pin a Spot fleet to one type in one AZ.
3. (a) **Yes** — checkpointed, restartable, no user waiting. (b) **No** — interrupting it drops live sessions; state is in memory and cannot be reconstructed. (c) **Yes** — a lost build is re-runnable and the cost of re-running is bounded. (d) **No** — a primary database node losing its host is a data-availability incident, not an inconvenience. (e) **Yes** — embarrassingly parallel, per-frame work is naturally checkpointed.
4. Spot loses when the expected rework cost exceeds the discount — i.e. when the interruption probability is high, the job is long, **and** progress cannot be saved. Raise `p_int_job` toward 1, or lengthen the job, and the expected-attempts multiplier grows without bound. The lesson: **engineering effort spent on checkpointing converts a risky Spot workload into a safe one**, and that investment usually pays back far more than switching to On-Demand does.
5. **No.** Spot pricing is already a market-clearing discount on unused capacity — the two mechanisms are alternative ways of buying the *same* capacity, and stacking them is not offered. Structurally: RIs and Savings Plans are payments for *commitment/predictability*, and Spot is priced precisely by the *absence* of any guarantee. There is nothing left to discount.
6. **Terminate** (default), **Stop**, and **Hibernate**. Stop and Hibernate both preserve the root EBS volume (hibernate additionally writes RAM to it); with Terminate, the root volume is deleted unless `DeleteOnTermination` was set to `false`. Note that with Stop/Hibernate you continue to pay for the EBS storage while the instance is not running.

### Checkpoint 5

1. Dedicated Instance tenancy buys **physical isolation from other AWS accounts** — your instances run on hardware dedicated to your account. It does **not** buy visibility into or control over the underlying host: no socket/core count reporting, no control over instance placement across host reboots, and no ability to satisfy a per-socket or per-core software license. Dedicated Hosts provide those.
2. **Compute has been converted from a variable cost into a fixed cost.** The host bills per hour whether it holds zero instances or its full capacity, so the marginal cost of placing one more instance on an already-paid-for host is zero. The incentive inverts: with shared tenancy you are rewarded for shutting instances down; with a Dedicated Host you are rewarded for **packing it as densely as possible**, and an under-utilized host is pure waste.
3. **Dedicated Hosts.** The license is bound to physical sockets/cores, so you must be able to *see and report* the host's socket and core counts and pin instances to a specific host — capabilities only Dedicated Hosts expose. Dedicated Instances give isolation but no host-level visibility or affinity, so a socket-based license cannot be legally attested. Dedicated Hosts are also the vehicle for BYOL on Windows Server and SQL Server.
4. **Dedicated Host Reservations** — a distinct commitment mechanism, with its own 1- or 3-year terms and No/Partial/All Upfront options, purchased against a host, not an instance. EC2 RIs and Savings Plans cover instance usage (including Dedicated Instance tenancy); Dedicated Host usage is billed as a host and is covered by Host Reservations. Verify current coverage rules in the Savings Plans FAQ before committing money.
5. The **isolation** requirement is satisfied by either Dedicated Instances or Dedicated Hosts. The **physical socket/core reporting** requirement is what forces **Dedicated Hosts** — it is the only option that surfaces that information. Whenever both appear, the reporting/licensing requirement is the deciding one.
6. (a) An **On-Demand Capacity Reservation** guarantees capacity in a specific AZ for a specific instance configuration, with **no term commitment** — you can create and cancel it at any time. A **zonal RI** guarantees capacity *and* carries a 1- or 3-year billing commitment. (b) A Capacity Reservation is billed at the **On-Demand rate for as long as it exists**, whether or not an instance occupies it (`capacitystatus=UnusedCapacityReservation` in Exercise 1); a zonal RI is billed per its purchase option. The two compose: a Savings Plan or regional RI discount can apply to the usage that fills a Capacity Reservation, which is the standard way to get *both* guaranteed capacity and a discount.

### Checkpoint 6

1. **Requests** ($ per invocation) and **duration** ($ per GB-second, i.e. memory × time). Tuning memory changes the GB-second dimension directly — but Lambda allocates CPU proportionally to memory, so doubling memory can more than halve execution time on CPU-bound work, reducing total GB-seconds *and* latency. This is why AWS Lambda Power Tuning exists: the cheapest memory setting is frequently not the smallest.
2. (a) EC2 requires **redundancy for availability** — you would need at least two instances across AZs, doubling the EC2 side. (b) EC2 needs a **load balancer**, which has its own hourly and LCU charges. (c) EC2 carries **operational cost** — patching, AMI management, scaling configuration — that never appears in the price comparison but is real money. Also: bursty traffic means the EC2 instance must be sized for peak and paid for at trough, whereas Lambda bills only actual execution.
3. **S3 Standard-IA bills a minimum of 128 KB per object.** Objects of 20 KB are billed as 128 KB — a 6.4× inflation that swamps the 46% per-GB discount. The feature designed to prevent this is **S3 Intelligent-Tiering**, which moves objects between access tiers automatically based on observed access patterns, charges no retrieval fees, and **does not auto-tier objects smaller than 128 KB** (they stay in the frequent-access tier at Standard pricing). The general rule: IA and archive classes are for *large, cold* objects.
4. You pay **30 days of Glacier Flexible Retrieval storage** (the 90-day minimum is prorated: you are charged an early-deletion fee equivalent to the remaining 70 days) **plus** the lifecycle transition request charge **plus** any retrieval fee. Deleting early does not refund the transition — which is why lifecycle policies must be modelled against real object lifetimes, not aspirational ones.
5. You are selling **multi-AZ redundancy**: One Zone-IA stores data in a single Availability Zone, so an AZ loss destroys it. Correct for data that is **reproducible** — secondary copies of an on-premises backup, derived/transcoded media, cached analytics extracts, CI artifacts — anything you could regenerate rather than restore.
6. `PutObject` of a 1 GB file → a **request** charge (PUT requests are priced per 1,000, and a multipart upload counts each part). Keeping it for a month → a **storage** charge (GB-month). `ListObjectsV2` over 10,000 keys → a **request** charge (LIST is priced with PUT-class requests, the more expensive tier). Note that reading that 1 GB back out to the internet adds a **data transfer** charge — three dimensions, one object.

### Checkpoint 7

1. It makes ingesting data into AWS frictionless and moving it out expensive — the economics favour keeping data, and the compute that processes it, inside AWS. Architectural implication for a data lake: **move compute to the data, not data to the compute.** Do aggregation, filtering and format conversion (Athena, EMR, Glue) inside the Region and export only results; never design a pipeline whose steady state is bulk-exporting raw objects.
2. 30 TB = 30,720 GB × $0.045/GB = **$1,382.40/month** in NAT processing alone (plus ~$32.85/month in NAT hourly charges), for traffic that never leaves the Region. The free fix is an **S3 Gateway VPC Endpoint**: it routes S3 traffic over the VPC's private path, costs nothing for the endpoint or the data, and removes S3 traffic from the NAT Gateway entirely. (The same applies to DynamoDB.)
3. Free if they communicate over **private IPv4 addresses** within the same AZ; billed if the traffic traverses a **public IPv4 address, an Elastic IP, or a load balancer/NAT in the path**. The single difference is which address the traffic is sent to — the packets may take a similar path, but AWS bills based on the addressing, which is why using a public DNS name for an internal service is a silent recurring charge.
4. It adds a real, usage-proportional cost to HA — in the step-4 example, ~$4,915/month purely for crossing AZ boundaries. You decide it is worth it by comparing that number against the **cost of the outage it prevents**: expected downtime × revenue or SLA penalty per hour. You also reduce it architecturally — AZ-aware routing/topology hints so a service prefers same-AZ replicas, keeping cross-AZ traffic for replication and failover rather than for every request.
5. CloudFront caches at the edge, so free origin fetches cost AWS relatively little while the cache absorbs most requests; AWS's incentive is to move egress onto a network it controls end-to-end, which is cheaper for AWS to serve and stickier for the customer. The customer-visible result is that CloudFront is nearly always cheaper than direct egress for cacheable content, in addition to being faster.
6. **Data transfer** — specifically inter-Region transfer for replication (databases, S3 CRR, config/state sync), which recurs continuously and is easy to under-estimate because it scales with write volume rather than with user traffic. Quantify it before building with the **AWS Pricing Calculator**, modelling replication volume explicitly as its own line item, and validate the assumption afterwards with Cost Explorer grouped by usage type.

### Checkpoint 8

1. **Always Free** — no expiry, e.g. AWS Lambda's 1 M requests + 400,000 GB-seconds per month, DynamoDB's 25 GB. **12 Months Free** — from account creation, e.g. 750 hours/month of `t2.micro`/`t3.micro`, 5 GB of S3 Standard. **Free Trial** — a short fixed window from first use of that specific service, e.g. Amazon Inspector's 15 days.
2. On day 366 the allowance disappears and the same instance bills at the full On-Demand rate, with **no notification and no interruption of service** — the first sign is the invoice, which is exactly why the budget in step 3 matters. 750 hours ≈ one instance running continuously for a month (730 h); **two** instances consume it in about 15 days, because the allowance is measured in instance-hours, not instances.
3. A guardrail budget must alert on **real usage**, and promotional or signup credits mask usage by zeroing the charged amount — with `IncludeCredit: true` you would see $0.00 while burning through the credit balance, then get a sudden real bill the moment the credits ran out. Excluding credits makes the budget report what the account is actually consuming.
4. AWS Budgets is a **notification and reporting** mechanism; it observes cost and usage but has no authority over the services generating them. To make something stop you must add **Budget Actions**, which can apply a restrictive IAM/SCP policy, or stop EC2/RDS instances, when a threshold is crossed — either automatically or after manual approval. Even then, "stopping" is an explicit action you configured, not a cap AWS enforces on your behalf.
5. 20% over 1 M requests = 200,000 extra requests × $0.20/1M = **$0.04**. The point is the asymmetry: the *request* overrun is trivial, while an equivalent 20% overrun on the 400,000 GB-second duration allowance (80,000 GB-s × $0.0000166667 ≈ $1.33) costs 33× more. Free Tier overruns are worth understanding by dimension, not by percentage.
6. **Free:** the first two AWS Budgets, the Cost Explorer **console**, and the AWS Pricing Calculator (which needs no AWS account at all). **Billed:** the Cost Explorer **API**, at $0.01 per request — which is why scripted polling of `ce:GetCostAndUsage` in a loop is a genuine, if small, self-inflicted cost.

### Checkpoint 9

1. No. On-Demand spend is only waste if it is **steady and predictable**. Before recommending a commitment you must ask: *what does the hourly usage floor look like over the last 60–90 days?* Spend that is spiky, seasonal, or belongs to a workload scheduled for decommissioning or re-platforming should stay On-Demand — committing to it converts a variable cost into a fixed one at exactly the wrong moment.
2. 96.4% is healthy — the $6.41 unused is a small insurance premium against usage dipping. You would reduce the next commitment when utilization sits persistently **below ~95%**, because the unused portion is money for which you received nothing. But 100% is not the target either: it means the commitment sits entirely below your usage floor and you are almost certainly leaving discount on the table — the right response to sustained 100% utilization is to *increase* coverage, typically layering an additional commitment.
3. Because a commitment locks in **today's consumption level for one to three years**. Buying a Savings Plan sized to an over-provisioned fleet freezes the waste into the contract: you would be committed to paying for `m6i.2xlarge`-scale spend, and right-sizing afterwards leaves the commitment stranded and under-utilized. **Right-size first, then commit to the corrected baseline.** Compute Optimizer is free, so there is no reason to skip it.
4. (1) **Eliminate idle resources** — nothing is cheaper than not running it. (2) **Right-size** what remains — establish the true baseline. (3) **Move eligible workloads to Spot** — this removes them from the commitment-eligible baseline entirely. (4) **Buy commitments** for the steady remainder. The rule: every earlier step changes the baseline the next step measures, and only the last step is contractually irreversible.
5. AWS recommends a commitment near the observed **usage floor**, not the average, because uncovered usage falls back to On-Demand (a small, recoverable penalty) whereas over-commitment is unrecoverable loss. Commit **more** than recommended only if you have concrete knowledge the algorithm lacks — a migration bringing new steady workloads on, or a confirmed growth plan. Commit **less** if you know something it lacks in the other direction — a planned re-platforming, a contract ending, a Region exit. In the absence of such knowledge, take the recommendation and layer additional commitments later as usage proves itself; **laddering** small commitments over time is strictly safer than one large one.

### Capstone

1. Component-by-component:

| # | Component | Model | Forcing property |
|---|---|---|---|
| 1 | Public API, 3 × `m6i.large` 24/7 | **Savings Plan (Compute or EC2 Instance) 3yr**, or Standard RI | 100% utilization over a long, known horizon — the break-even is passed many times over |
| 2 | Nightly ETL, 400 h/mo, checkpointed | **Spot** (mixed-instances ASG, multi-AZ) | Fault-tolerant and restartable; interruption costs only rework |
| 3 | Warehouse migrating EC2 → Fargate | **Compute Savings Plan** | Steady spend, but the *resource shape* will change |
| 4 | 40 M invocations, 128 MB, 80 ms | **Lambda on-demand** (consumption); Compute SP if the floor is provable | Event-driven, sub-second, no idle baseline to pay for |
| 5 | 40 TB archive, read < 1×/yr, hours OK | **S3 Glacier Deep Archive** + lifecycle policy | Retrieval latency of hours is acceptable, and 180-day minimum is far below the retention period |
| 6 | Oracle, socket-bound license, core reporting | **Dedicated Host** (+ Dedicated Host Reservation) | Physical socket/core visibility and BYOL — nothing else satisfies it |
| 7 | 25 TB/month egress | **CloudFront** in front of the origin | Static, cacheable content; lower egress rate and free origin fetch |

2. Only a **Compute Savings Plan** survives the EC2 → Fargate migration with its discount intact, because it is denominated in dollars per hour and covers EC2, Fargate and Lambda alike. A 3-year EC2 Instance Savings Plan would have been locked to one instance family in one Region: from the migration date onward you would pay the commitment in full *and* pay for Fargate at on-demand rates — roughly a 28-month double charge.

3. 25 TB sits in the **10–50 TB tier** (the first 100 GB is free, the first 10 TB at the top rate, the remainder at the next). The first architectural change is putting **CloudFront** in front of it: origin fetches become free, the per-GB egress rate is lower, the 1 TB/month CloudFront free tier applies, and cache hits at the edge collapse the origin traffic — with the added benefit of lower latency. Second change: verify the assets are actually cacheable (correct `Cache-Control`), because an un-cacheable CDN is just a more expensive proxy.

4. Components **1 and 3** can share one Compute Savings Plan commitment — both are steady EC2/Fargate compute, and the plan applies to whichever usage draws it down; component 4 (Lambda) could join as well if its floor is stable. Component **6 cannot participate at all**: Dedicated Host usage is billed as a host and is covered by Dedicated Host Reservations, not by Savings Plans. Component 2 (Spot) and component 5 (S3) are also outside compute-commitment scope — Spot is a separate discount mechanism, and S3 is a storage dimension entirely.

5. **Match the commitment to the shape of the demand curve: pay On-Demand for the unpredictable, commit (RI or Savings Plan) for the floor that is always there, bid Spot for the work that can be interrupted and retried, and pay per-consumption for what has no floor at all** — then choose *which* commitment by how much the resource shape is likely to change before the term ends.

</details>