# Topic 1.1 — Define the Benefits of the AWS Cloud
## Guided Exercises (CLF-C02, Domain 1 — weight 6.0)

---

### What you will actually do

The exam asks you to *define* the benefits. Definitions memorised from a slide evaporate under pressure. In these exercises you **measure** each benefit with the AWS CLI, so that "elasticity", "economies of scale" and "high availability" stop being vocabulary and become numbers you have personally read off a terminal.

Each of the six classical advantages of cloud computing is mapped to a lab:

| Advantage (AWS Overview whitepaper) | Exercise |
|---|---|
| Go global in minutes | 1, 7 |
| Benefit from massive economies of scale | 3, 4 |
| Trade capital expense for variable expense | 3, 8 |
| Stop guessing capacity (elasticity) | 6 |
| Increase speed and agility | 5 |
| Stop spending money running and maintaining data centers | 2, 8 |

Source: <https://docs.aws.amazon.com/whitepapers/latest/aws-overview/six-advantages-of-cloud-computing.html>
Exam guide: <https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf>

---

### Prerequisites

- **AWS CLI v2** (`aws --version` must report `aws-cli/2.x`). v1 will not have `elbv2 wait` and several `--query` behaviours used here.
- **`jq`** for parsing the Price List API (it returns JSON *inside* JSON strings).
- An AWS account where you may create and destroy resources, with an IAM principal allowed to call:
  `ec2:Describe*`, `ec2:CreateSecurityGroup`, `ec2:AuthorizeSecurityGroupIngress`, `ec2:*LaunchTemplate*`, `ssm:GetParameter*`, `pricing:*`, `savingsplans:Describe*`, `autoscaling:*`, `elasticloadbalancing:*`, `cloudformation:*`, `s3:*`, `budgets:*`, `ce:GetCostAndUsage`, `compute-optimizer:GetEnrollmentStatus`, `iam:CreateServiceLinkedRole`.
- A shell where you can keep environment variables across exercises (one terminal session, start to finish).

### Cost and safety

| Exercise | Billable resources | Approximate cost if torn down within 1 hour |
|---|---|---|
| 0 | AWS Budgets (first two budgets free) | $0.00 |
| 1, 2 | Describe/SSM calls | $0.00 |
| 3, 4 | Price List + Savings Plans APIs | $0.00 |
| 5, 6 | 2–4 × `t3.micro`, 1 × Application Load Balancer | ≈ $0.05 |
| 7 | `curl` only | $0.00 |
| 8 | 1 × Cost Explorer API request ($0.01), 1 × S3 bucket (empty) | ≈ $0.01 |

> **Free Tier caution.** AWS changed the Free Tier in July 2025: accounts created from 2025-07-15 onward get a credit-based free plan rather than the classic 12-month allowances. Do not assume your account has "750 free `t3.micro` hours". Verify at <https://aws.amazon.com/free/> and treat Exercise 0's budget as mandatory, not optional.

> **Every exercise that creates something is torn down in Exercise 9.** Do not stop before it.

---

## Exercise 0 — Establish identity and a cost guardrail

**Benefit under test:** the variable-cost model is only an advantage if you can *see* the variable. First, install the meter.

### Steps

1. Confirm which principal and which account you are operating as. Never run a lab without this.

   ```bash
   aws sts get-caller-identity
   ```

   ```json
   {
       "UserId": "AIDA************EXAMPLE",
       "Account": "123456789012",
       "Arn": "arn:aws:iam::123456789012:user/clf-lab"
   }
   ```

2. Pin the account ID and a working Region into shell variables. Every later exercise reuses them.

   ```bash
   export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
   export AWS_REGION=us-east-1
   export AWS_DEFAULT_REGION=$AWS_REGION
   echo "account=$ACCOUNT_ID region=$AWS_REGION"
   ```

3. Write a monthly cost budget definition. Replace the e-mail address with your own.

   ```bash
   cat > /tmp/budget.json <<'JSON'
   {
     "BudgetName": "clf-lab-guardrail",
     "BudgetLimit": { "Amount": "5", "Unit": "USD" },
     "TimeUnit": "MONTHLY",
     "BudgetType": "COST"
   }
   JSON

   cat > /tmp/budget-notify.json <<'JSON'
   [
     {
       "Notification": {
         "NotificationType": "ACTUAL",
         "ComparisonOperator": "GREATER_THAN",
         "Threshold": 80,
         "ThresholdType": "PERCENTAGE"
       },
       "Subscribers": [
         { "SubscriptionType": "EMAIL", "Address": "you@example.com" }
       ]
     }
   ]
   JSON
   ```

4. Create the budget.

   ```bash
   aws budgets create-budget \
     --account-id "$ACCOUNT_ID" \
     --budget file:///tmp/budget.json \
     --notifications-with-subscribers file:///tmp/budget-notify.json
   ```

   A successful call returns an empty response body (HTTP 200, no output). Verify:

   ```bash
   aws budgets describe-budgets --account-id "$ACCOUNT_ID" \
     --query 'Budgets[].[BudgetName,BudgetLimit.Amount,TimeUnit]' --output table
   ```

   ```text
   -------------------------------------------
   |             DescribeBudgets             |
   +---------------------+-------+-----------+
   |  clf-lab-guardrail  |  5.0  |  MONTHLY  |
   +---------------------+-------+-----------+
   ```

Reference: <https://docs.aws.amazon.com/cost-management/latest/userguide/budgets-managing-costs.html>

### Check your understanding — Block 0

- **Q0.1** — You set an $5 budget. At 03:00 an automated script launches 40 `m5.24xlarge` instances. Does AWS stop them when the budget is exceeded? Justify.
- **Q0.2** — In on-premises terms, what is the equivalent control to an AWS Budget, and why is it structurally weaker as a *preventive* mechanism there?
- **Q0.3** — `sts get-caller-identity` returned an ARN ending in `:user/clf-lab`. Name one reason a production platform team would consider that ARN itself a finding.

---

## Exercise 1 — Inventory the global infrastructure ("go global in minutes")

**Benefit under test:** global reach. You will enumerate AWS's footprint from the API rather than trusting a marketing page.

### Steps

1. List every Region, including the ones your account has not enabled.

   ```bash
   aws ec2 describe-regions --all-regions \
     --query 'sort_by(Regions,&RegionName)[].[RegionName,OptInStatus]' \
     --output table
   ```

   ```text
   ------------------------------------------------
   |                DescribeRegions               |
   +---------------------+------------------------+
   |  af-south-1         |  not-opted-in          |
   |  ap-east-1          |  not-opted-in          |
   |  ap-northeast-1     |  opt-in-not-required   |
   |  ap-south-1         |  opt-in-not-required   |
   |  ...                |  ...                   |
   |  us-east-1          |  opt-in-not-required   |
   |  us-west-2          |  opt-in-not-required   |
   +---------------------+------------------------+
   ```

2. Count them, and compare with the "commercial Regions" figure AWS publishes.

   ```bash
   aws ec2 describe-regions --all-regions --query 'length(Regions)'
   aws ec2 describe-regions --query 'length(Regions)'   # only the ones you can use today
   ```

   ```text
   38
   20
   ```

   > The exact count moves every few months. Never memorise it for the exam; memorise the *hierarchy*. Public figure: <https://aws.amazon.com/about-aws/global-infrastructure/>

3. Descend one level: Availability Zones inside a Region.

   ```bash
   aws ec2 describe-availability-zones --region us-east-1 \
     --query 'AvailabilityZones[].{Name:ZoneName,Id:ZoneId,State:State}' \
     --output table
   ```

   ```text
   ---------------------------------------------------
   |            DescribeAvailabilityZones            |
   +--------------+---------------+------------------+
   |      Id      |     Name      |      State       |
   +--------------+---------------+------------------+
   |  use1-az6    |  us-east-1a   |  available       |
   |  use1-az1    |  us-east-1b   |  available       |
   |  use1-az2    |  us-east-1c   |  available       |
   |  use1-az4    |  us-east-1d   |  available       |
   |  use1-az3    |  us-east-1e   |  available       |
   |  use1-az5    |  us-east-1f   |  available       |
   +--------------+---------------+------------------+
   ```

   Look carefully at that mapping: `us-east-1a` is `use1-az6`, not `use1-az1`. **The letter suffix is randomised per AWS account.** Your output will show a different pairing.

4. Query the same infrastructure through the public Systems Manager parameters — a machine-readable catalogue AWS publishes to every account, free of charge.

   ```bash
   aws ssm get-parameters-by-path \
     --path /aws/service/global-infrastructure/regions \
     --query 'Parameters[].Value' --output text | tr '\t' '\n' | sort | head -5
   ```

   ```text
   af-south-1
   ap-east-1
   ap-northeast-1
   ap-northeast-2
   ap-northeast-3
   ```

5. Ask which Regions offer a given service — the real question behind "can I go global with *this* architecture in minutes?"

   ```bash
   aws ssm get-parameters-by-path \
     --path /aws/service/global-infrastructure/services/bedrock/regions \
     --query 'Parameters[].Value' --output text | tr '\t' '\n' | sort
   ```

   ```text
   ap-northeast-1
   ap-south-1
   ap-southeast-2
   eu-central-1
   ...
   us-east-1
   us-west-2
   ```

6. Find the infrastructure that is *not* a Region or an AZ — Local Zones and Wavelength Zones.

   ```bash
   aws ec2 describe-availability-zones --all-availability-zones --region us-west-2 \
     --filters Name=zone-type,Values=local-zone \
     --query 'AvailabilityZones[].[ZoneName,ZoneId,GroupName]' --output table
   ```

   ```text
   ------------------------------------------------------------
   |                 DescribeAvailabilityZones                |
   +--------------------+------------------+------------------+
   |  us-west-2-lax-1a  |  usw2-lax1-az1   |  us-west-2-lax-1 |
   |  us-west-2-lax-1b  |  usw2-lax1-az2   |  us-west-2-lax-1 |
   +--------------------+------------------+------------------+
   ```

   ```bash
   aws ec2 describe-availability-zones --all-availability-zones --region us-east-1 \
     --filters Name=zone-type,Values=wavelength-zone \
     --query 'length(AvailabilityZones)'
   ```

References: <https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/using-regions-availability-zones.html> · <https://docs.aws.amazon.com/systems-manager/latest/userguide/parameter-store-public-parameters-global-infrastructure.html> · <https://docs.aws.amazon.com/ram/latest/userguide/working-with-az-ids.html>

### Check your understanding — Block 1

- **Q1.1** — Define, in one sentence each and without overlap: Region, Availability Zone, Local Zone, Edge Location (Point of Presence).
- **Q1.2** — Why does AWS randomise the mapping between `us-east-1a` and `use1-azN` per account? What concrete failure would a fixed mapping cause?
- **Q1.3** — Two AWS accounts in the same organisation want to place resources in the *same physical* AZ for low-latency cross-account traffic. Which identifier must they exchange, and which must they ignore?
- **Q1.4** — Step 2 showed 38 Regions total but only 20 usable. What must an administrator do to use the others, and what is the business rationale for AWS making them opt-in?
- **Q1.5** — A latency-sensitive mobile game needs sub-10 ms to users in Los Angeles. Which of the four infrastructure constructs from Q1.1 is the correct answer, and why is "an Edge Location in LA" wrong for the game's compute?

---

## Exercise 2 — Read the boundary of the shared responsibility model

**Benefit under test:** "stop spending money running and maintaining data centers." The saving is not just money; it is a set of tasks that disappear from your backlog. You will locate the line.

### Steps

1. Ask AWS what it operates on your behalf for a managed database, without creating one. Inspect the *shape* of the control surface:

   ```bash
   aws rds describe-db-engine-versions --engine postgres \
     --query 'DBEngineVersions[-1].[Engine,EngineVersion,SupportsReadReplica,ValidUpgradeTarget[0].EngineVersion]' \
     --output table
   ```

   ```text
   ------------------------------------------------
   |          DescribeDBEngineVersions            |
   +-----------+--------+---------+---------------+
   |  postgres |  17.4  |  True   |  17.5         |
   +-----------+--------+---------+---------------+
   ```

   Note what is *absent* from every RDS API: there is no call to patch the guest OS, replace a failed disk, or re-cable a rack. Those tasks are not delegated — they are not exposed at all.

2. Contrast with EC2, where the OS is yours:

   ```bash
   aws ssm get-parameter \
     --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
     --query 'Parameter.Value' --output text
   ```

   ```text
   ami-0abcdef1234567890
   ```

   That AMI ID changes when AWS publishes a new build — but *applying* it to your running fleet is your job.

3. Enumerate one concrete AWS-side undifferentiated task you no longer perform: hardware capacity planning per instance family.

   ```bash
   aws ec2 describe-instance-type-offerings --location-type availability-zone \
     --filters Name=instance-type,Values=m5.large \
     --region us-east-1 \
     --query 'InstanceTypeOfferings[].Location' --output text
   ```

   ```text
   us-east-1a	us-east-1b	us-east-1c	us-east-1d	us-east-1f
   ```

   Read that as: five distinct data-centre clusters already hold `m5.large` capacity that you did not buy, rack, power or cool.

Reference: <https://aws.amazon.com/compliance/shared-responsibility-model/>

### Check your understanding — Block 2

- **Q2.1** — State the shared responsibility model in the two canonical halves, then classify each of these: (a) encrypting an S3 object; (b) destroying a failed SSD; (c) patching the Linux kernel on an EC2 instance; (d) patching the Linux kernel under an RDS instance; (e) configuring a security group.
- **Q2.2** — Step 3 showed `m5.large` offered in 5 of the 6 AZs of `us-east-1`. What operational assumption should you *not* make from that output when designing a multi-AZ deployment?
- **Q2.3** — A CFO asks: "We still pay for staff. Where is the saving from not running a data centre?" Give three cost lines that genuinely disappear and one that does not.

---

## Exercise 3 — Price a server: CapEx → OpEx, and economies of scale

**Benefit under test:** trading capital expense for variable expense, and massive economies of scale. You will pull real published prices from the Price List Query API.

> The Price List API has endpoints only in `us-east-1`, `eu-central-1` and `ap-south-1`. Always pass `--region us-east-1` regardless of which Region you are pricing.

### Steps

1. Retrieve the On-Demand hourly price of an `m5.large`, Linux, shared tenancy, in N. Virginia.

   ```bash
   price_of () {
     local itype="$1" location="$2"
     aws pricing get-products \
       --region us-east-1 \
       --service-code AmazonEC2 \
       --filters \
         "Type=TERM_MATCH,Field=instanceType,Value=${itype}" \
         "Type=TERM_MATCH,Field=location,Value=${location}" \
         "Type=TERM_MATCH,Field=operatingSystem,Value=Linux" \
         "Type=TERM_MATCH,Field=tenancy,Value=Shared" \
         "Type=TERM_MATCH,Field=preInstalledSw,Value=NA" \
         "Type=TERM_MATCH,Field=capacitystatus,Value=Used" \
         "Type=TERM_MATCH,Field=marketoption,Value=OnDemand" \
       --max-results 1 --output json \
     | jq -r '.PriceList[] | fromjson
              | .terms.OnDemand[].priceDimensions[].pricePerUnit.USD'
   }

   price_of m5.large "US East (N. Virginia)"
   ```

   ```text
   0.0960000000
   ```

2. Convert that into the number the finance department understands, and compare it with a three-year capital purchase.

   ```bash
   HOURLY=$(price_of m5.large "US East (N. Virginia)")
   python3 - <<PY
   h = float("$HOURLY")
   print(f"hourly        : \${h:.4f}")
   print(f"monthly (730h): \${h*730:,.2f}")
   print(f"3-year 24x7   : \${h*24*365*3:,.2f}")
   print(f"3-year, 8h/day weekdays only: \${h*8*260*3:,.2f}")
   PY
   ```

   ```text
   hourly        : $0.0960
   monthly (730h): $70.08
   3-year 24x7   : $2,523.31
   3-year, 8h/day weekdays only: $599.04
   ```

   The last two lines are the entire CapEx→OpEx argument in numeric form: identical capability, **4.2× difference in spend**, decided purely by *when you stop paying*. A purchased server cannot be un-bought on Friday evening.

3. Now measure economies of scale geographically. Price the same instance in four Regions.

   ```bash
   for loc in "US East (N. Virginia)" "EU (Ireland)" "Asia Pacific (Sydney)" "South America (Sao Paulo)"; do
     printf '%-28s %s\n' "$loc" "$(price_of m5.large "$loc")"
   done
   ```

   ```text
   US East (N. Virginia)        0.0960000000
   EU (Ireland)                 0.1070000000
   Asia Pacific (Sydney)        0.1200000000
   South America (Sao Paulo)    0.1530000000
   ```

   *(Your figures will differ; AWS changes prices and these are illustrative.)*

4. Confirm the valid `location` strings if a filter returns nothing:

   ```bash
   aws pricing get-attribute-values --region us-east-1 \
     --service-code AmazonEC2 --attribute-name location \
     --query 'AttributeValues[].Value' --output text | tr '\t' '\n' | grep -i "frankfurt\|sao"
   ```

References: <https://docs.aws.amazon.com/aws-cost-management/latest/APIReference/API_pricing_GetProducts.html> · <https://aws.amazon.com/ec2/pricing/on-demand/>

### Check your understanding — Block 3

- **Q3.1** — Explain the difference between capital expenditure and operational expenditure, and identify which one a 3-year On-Demand EC2 run actually is.
- **Q3.2** — Step 2 produced $2,523 (24×7) vs $599 (business hours). Which cloud characteristic makes the second number reachable, and what *architectural* work is required to actually realise it?
- **Q3.3** — São Paulo costs ~59 % more than N. Virginia for the identical instance type. Give two structural reasons. Does this contradict "economies of scale"?
- **Q3.4** — Define "economies of scale" as AWS uses the term, and explain the direction of the feedback loop between AWS's customer count and your bill.
- **Q3.5** — Why does the Price List API require `capacitystatus=Used` and `preInstalledSw=NA` in the filter set? What would happen without them?

---

## Exercise 4 — Quantify the commitment discount curve

**Benefit under test:** economies of scale passed to you as pricing models. You will read the actual discount for committing to spend.

### Steps

1. Find a Compute Savings Plan offering: 1 year, No Upfront.

   ```bash
   aws savingsplans describe-savings-plans-offerings \
     --region us-east-1 \
     --plan-types Compute \
     --durations 31536000 \
     --payment-options "No Upfront" \
     --query 'searchResults[0].[offeringId,planType,durationSeconds,paymentOption]' \
     --output table
   ```

   ```text
   ---------------------------------------------------------------------------
   |                       DescribeSavingsPlansOfferings                      |
   +----------------------------------------+----------+------------+--------+
   |  87654321-4321-4321-4321-210987654321  |  Compute |  31536000  | No Upfront |
   +----------------------------------------+----------+------------+--------+
   ```

2. Capture the offering ID and read the effective rate for `m5.large`.

   ```bash
   SP_OFFER=$(aws savingsplans describe-savings-plans-offerings \
     --region us-east-1 --plan-types Compute --durations 31536000 \
     --payment-options "No Upfront" \
     --query 'searchResults[0].offeringId' --output text)

   aws savingsplans describe-savings-plans-offering-rates \
     --region us-east-1 \
     --savings-plan-offering-ids "$SP_OFFER" \
     --service-codes AmazonEC2 \
     --filters name=region,values=us-east-1 \
               name=instanceType,values=m5.large \
               name=tenancy,values=shared \
               name=productDescription,values="Linux/UNIX" \
     --query 'searchResults[0].[rate,unit,usageType]' --output table
   ```

   ```text
   -----------------------------------------------
   |     DescribeSavingsPlansOfferingRates       |
   +----------+--------+-------------------------+
   |  0.0679  |  Hrs   |  BoxUsage:m5.large      |
   +----------+--------+-------------------------+
   ```

   > If the result is empty, relax the filters one at a time (`productDescription` first) — the accepted values vary by service code.

3. Compute the discount you just discovered.

   ```bash
   python3 - <<'PY'
   od, sp = 0.096, 0.0679
   print(f"on-demand : ${od:.4f}/h  -> ${od*730:,.2f}/mo")
   print(f"1yr NoUp  : ${sp:.4f}/h  -> ${sp*730:,.2f}/mo")
   print(f"discount  : {(1-sp/od)*100:.1f}%")
   print(f"break-even utilisation: {sp/od*100:.1f}% of the hours")
   PY
   ```

   ```text
   on-demand : $0.0960/h  -> $70.08/mo
   1yr NoUp  : $0.0679/h  -> $49.57/mo
   discount  : 29.3%
   break-even utilisation: 70.7% of the hours
   ```

   That last line is the decision rule: the commitment only wins if you will genuinely consume more than ~71 % of the committed hours.

Reference: <https://docs.aws.amazon.com/savingsplans/latest/userguide/what-is-savings-plans.html>

### Check your understanding — Block 4

- **Q4.1** — A Savings Plan is a commitment to spend, expressed in $/hour. What are you *not* committing to, and why does that distinction matter versus a Standard Reserved Instance?
- **Q4.2** — The break-even was ~71 % utilisation. A workload runs 8 h/day, 5 days/week. Compute its utilisation and state whether a 1-year Compute Savings Plan is justified.
- **Q4.3** — Is a commitment discount an example of "trade CapEx for variable expense", or does it partially reverse that benefit? Argue both sides in two sentences.
- **Q4.4** — Rank these four EC2 purchase options by typical discount, and name the one that can be reclaimed by AWS with a 2-minute notice: On-Demand, Spot, Savings Plans, Dedicated Host On-Demand.

---

## Exercise 5 — Measure agility: time-to-provision

**Benefit under test:** speed and agility. You will time the creation of infrastructure and compare it with a hardware procurement cycle.

### Steps

1. Write a minimal CloudFormation template.

   ```bash
   cat > /tmp/agility.yaml <<'YAML'
   AWSTemplateFormatVersion: '2010-09-09'
   Description: CLF 1.1 - agility measurement stack

   Resources:
     LabBucket:
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
         VersioningConfiguration:
           Status: Enabled

   Outputs:
     BucketName:
       Description: Name of the provisioned bucket
       Value: !Ref LabBucket
   YAML
   ```

2. Validate before deploying — free, and it catches syntax errors without consuming a stack operation.

   ```bash
   aws cloudformation validate-template --template-body file:///tmp/agility.yaml \
     --query '[Description,Parameters]' --output json
   ```

   ```json
   [
       "CLF 1.1 - agility measurement stack",
       []
   ]
   ```

3. Deploy and time it end to end.

   ```bash
   START=$(date -u +%s)
   aws cloudformation create-stack \
     --stack-name clf-agility \
     --template-body file:///tmp/agility.yaml \
     --query 'StackId' --output text

   aws cloudformation wait stack-create-complete --stack-name clf-agility
   END=$(date -u +%s)
   echo "provisioned in $((END-START)) seconds"
   ```

   ```text
   arn:aws:cloudformation:us-east-1:123456789012:stack/clf-agility/0f2c...
   provisioned in 24 seconds
   ```

4. Read the audit trail — every state transition is timestamped.

   ```bash
   aws cloudformation describe-stack-events --stack-name clf-agility \
     --query 'reverse(StackEvents[].[Timestamp,LogicalResourceId,ResourceStatus])' \
     --output table
   ```

   ```text
   ---------------------------------------------------------------------------
   |                          DescribeStackEvents                            |
   +-------------------------------+----------------+------------------------+
   |  2026-09-03T14:02:11.482000Z  |  clf-agility   |  CREATE_IN_PROGRESS    |
   |  2026-09-03T14:02:14.117000Z  |  LabBucket     |  CREATE_IN_PROGRESS    |
   |  2026-09-03T14:02:33.905000Z  |  LabBucket     |  CREATE_COMPLETE       |
   |  2026-09-03T14:02:35.220000Z  |  clf-agility   |  CREATE_COMPLETE       |
   +-------------------------------+----------------+------------------------+
   ```

5. Read the output value the stack exported.

   ```bash
   aws cloudformation describe-stacks --stack-name clf-agility \
     --query 'Stacks[0].Outputs[?OutputKey==`BucketName`].OutputValue' --output text
   ```

   ```text
   clf-agility-labbucket-1a2b3c4d5e6f
   ```

Reference: <https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/Welcome.html>

### Check your understanding — Block 5

- **Q5.1** — You provisioned an encrypted, versioned, private object store in ~24 seconds. Write the equivalent on-premises task list and estimate its lead time. Which single line dominates?
- **Q5.2** — "Agility" in the exam sense is not just speed. Name the second component, and explain why a *fast tear-down* is as much a business benefit as a fast build.
- **Q5.3** — Distinguish "agility" from "elasticity". Give one example of a system that is elastic but not agile.
- **Q5.4** — Why did Step 2 (`validate-template`) not require any AWS resource to exist? What class of error does it still fail to catch?

---

## Exercise 6 — High availability: survive the loss of an Availability Zone

**Benefit under test:** high availability and fault isolation. You will build a two-AZ fleet behind a load balancer, then destroy half of it and watch AWS rebuild.

> This block creates billable resources. Exercise 9 removes them.

### Steps

1. Resolve the default VPC and two subnets in **different** AZs.

   ```bash
   export VPC_ID=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true \
     --query 'Vpcs[0].VpcId' --output text)

   read -r SUBNET_A AZ_A <<<"$(aws ec2 describe-subnets \
     --filters Name=vpc-id,Values=$VPC_ID Name=default-for-az,Values=true \
     --query 'Subnets[0].[SubnetId,AvailabilityZone]' --output text)"
   read -r SUBNET_B AZ_B <<<"$(aws ec2 describe-subnets \
     --filters Name=vpc-id,Values=$VPC_ID Name=default-for-az,Values=true \
     --query 'Subnets[1].[SubnetId,AvailabilityZone]' --output text)"

   export SUBNET_A SUBNET_B AZ_A AZ_B
   echo "vpc=$VPC_ID  A=$SUBNET_A($AZ_A)  B=$SUBNET_B($AZ_B)"
   ```

   ```text
   vpc=vpc-0a1b2c3d  A=subnet-0aaa111(us-east-1a)  B=subnet-0bbb222(us-east-1b)
   ```

2. Create a security group that allows HTTP only from your own public address.

   ```bash
   export MY_IP=$(curl -s https://checkip.amazonaws.com)/32
   export SG_ID=$(aws ec2 create-security-group \
     --group-name clf-ha-sg --description "CLF 1.1 HA lab" \
     --vpc-id "$VPC_ID" --query 'GroupId' --output text)

   aws ec2 authorize-security-group-ingress --group-id "$SG_ID" \
     --protocol tcp --port 80 --cidr "$MY_IP" >/dev/null
   echo "sg=$SG_ID open to $MY_IP"
   ```

3. Build user data that makes each instance announce which AZ it is in.

   ```bash
   cat > /tmp/user-data.sh <<'SH'
   #!/bin/bash
   dnf install -y httpd >/dev/null 2>&1
   TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" \
     -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
   AZ=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
     http://169.254.169.254/latest/meta-data/placement/availability-zone)
   ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
     http://169.254.169.254/latest/meta-data/instance-id)
   echo "instance=${ID} az=${AZ}" > /var/www/html/index.html
   systemctl enable --now httpd
   SH
   export UD=$(base64 -w0 /tmp/user-data.sh)
   ```

   Note the two-step IMDSv2 token flow — session-oriented metadata access is the current default and the only form you should ever write.

4. Create a launch template.

   ```bash
   export AMI_ID=$(aws ssm get-parameter \
     --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
     --query 'Parameter.Value' --output text)

   aws ec2 create-launch-template \
     --launch-template-name clf-ha-lt \
     --launch-template-data "$(cat <<JSON
   {
     "ImageId": "$AMI_ID",
     "InstanceType": "t3.micro",
     "SecurityGroupIds": ["$SG_ID"],
     "UserData": "$UD",
     "CreditSpecification": { "CpuCredits": "standard" },
     "MetadataOptions": { "HttpTokens": "required", "HttpEndpoint": "enabled" },
     "TagSpecifications": [
       { "ResourceType": "instance", "Tags": [{ "Key": "Name", "Value": "clf-ha" }] }
     ]
   }
   JSON
   )" --query 'LaunchTemplate.[LaunchTemplateName,LatestVersionNumber]' --output text
   ```

   ```text
   clf-ha-lt	1
   ```

5. Create the target group and an internet-facing Application Load Balancer spanning both AZs.

   ```bash
   export TG_ARN=$(aws elbv2 create-target-group \
     --name clf-ha-tg --protocol HTTP --port 80 --vpc-id "$VPC_ID" \
     --target-type instance --health-check-path / \
     --health-check-interval-seconds 15 --healthy-threshold-count 2 \
     --unhealthy-threshold-count 2 \
     --query 'TargetGroups[0].TargetGroupArn' --output text)

   export ALB_ARN=$(aws elbv2 create-load-balancer \
     --name clf-ha-alb --type application --scheme internet-facing \
     --subnets "$SUBNET_A" "$SUBNET_B" --security-groups "$SG_ID" \
     --query 'LoadBalancers[0].LoadBalancerArn' --output text)

   export LISTENER_ARN=$(aws elbv2 create-listener \
     --load-balancer-arn "$ALB_ARN" --protocol HTTP --port 80 \
     --default-actions Type=forward,TargetGroupArn="$TG_ARN" \
     --query 'Listeners[0].ListenerArn' --output text)

   export ALB_DNS=$(aws elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" \
     --query 'LoadBalancers[0].DNSName' --output text)
   echo "http://$ALB_DNS"
   ```

6. Create the Auto Scaling group across both AZs, with ELB health checks.

   ```bash
   aws autoscaling create-auto-scaling-group \
     --auto-scaling-group-name clf-ha-asg \
     --launch-template LaunchTemplateName=clf-ha-lt,Version='$Latest' \
     --min-size 2 --max-size 4 --desired-capacity 2 \
     --vpc-zone-identifier "$SUBNET_A,$SUBNET_B" \
     --target-group-arns "$TG_ARN" \
     --health-check-type ELB --health-check-grace-period 180 \
     --default-instance-warmup 120

   aws elbv2 wait load-balancer-available --load-balancer-arns "$ALB_ARN"
   ```

7. Wait ~3 minutes, then confirm both targets are healthy and in different AZs.

   ```bash
   aws elbv2 describe-target-health --target-group-arn "$TG_ARN" \
     --query 'TargetHealthDescriptions[].[Target.Id,Target.AvailabilityZone,TargetHealth.State]' \
     --output table
   ```

   ```text
   -------------------------------------------------------------
   |                   DescribeTargetHealth                    |
   +-----------------------+---------------+-------------------+
   |  i-0aaa111222333444a  |  us-east-1a   |  healthy          |
   |  i-0bbb555666777888b  |  us-east-1b   |  healthy          |
   +-----------------------+---------------+-------------------+
   ```

8. Prove traffic is distributed across zones.

   ```bash
   for i in $(seq 1 8); do curl -s "http://$ALB_DNS/"; done | sort | uniq -c
   ```

   ```text
         4 instance=i-0aaa111222333444a az=us-east-1a
         4 instance=i-0bbb555666777888b az=us-east-1b
   ```

9. **Simulate the loss of one Availability Zone.** Terminate the instance in `$AZ_A` without reducing desired capacity.

   ```bash
   VICTIM=$(aws autoscaling describe-auto-scaling-instances \
     --query "AutoScalingInstances[?AutoScalingGroupName=='clf-ha-asg' && AvailabilityZone=='$AZ_A'].InstanceId | [0]" \
     --output text)
   echo "terminating $VICTIM in $AZ_A"

   aws autoscaling terminate-instance-in-auto-scaling-group \
     --instance-id "$VICTIM" --no-should-decrement-desired-capacity \
     --query 'Activity.[StatusCode,Cause]' --output text
   ```

10. Keep serving traffic while the replacement builds. Run this immediately:

    ```bash
    for i in $(seq 1 20); do
      printf '%s ' "$(date +%T)"; curl -s --max-time 3 "http://$ALB_DNS/" || echo "FAILED"
      sleep 5
    done
    ```

    ```text
    14:31:02 instance=i-0bbb555666777888b az=us-east-1b
    14:31:07 instance=i-0bbb555666777888b az=us-east-1b
    ...
    14:33:12 instance=i-0ccc999000111222c az=us-east-1a
    ```

    Zero failed requests: the surviving AZ absorbed 100 % of traffic while a new instance was built in the failed one.

11. Read the self-healing record.

    ```bash
    aws autoscaling describe-scaling-activities \
      --auto-scaling-group-name clf-ha-asg --max-items 4 \
      --query 'Activities[].[StartTime,StatusCode,Description]' --output table
    ```

    ```text
    -----------------------------------------------------------------------------------------
    |                              DescribeScalingActivities                                |
    +----------------------------+------------+---------------------------------------------+
    |  2026-09-03T14:31:44+00:00 |  Successful|  Launching a new EC2 instance: i-0ccc999...  |
    |  2026-09-03T14:31:05+00:00 |  Successful|  Terminating EC2 instance: i-0aaa111...      |
    +----------------------------+------------+---------------------------------------------+
    ```

References: <https://docs.aws.amazon.com/elasticloadbalancing/latest/application/introduction.html> · <https://docs.aws.amazon.com/autoscaling/ec2/userguide/ec2-auto-scaling-health-checks.html> · <https://docs.aws.amazon.com/wellarchitected/latest/reliability-pillar/welcome.html>

### Check your understanding — Block 6

- **Q6.1** — Define high availability and fault tolerance, and say which one this lab demonstrated. Justify with an observation from Step 10.
- **Q6.2** — Assume a single AZ deployment achieves 99.9 % availability and AZ failures are independent. Compute the theoretical availability of the two-AZ design. Then give two reasons the real number is lower.
- **Q6.3** — In Step 6 the health check type was set to `ELB` rather than the default `EC2`. Describe a failure that `EC2` health checks miss and `ELB` health checks catch.
- **Q6.4** — Why must `--min-size` be 2 rather than 1 for this design to genuinely survive an AZ loss without a capacity drop?
- **Q6.5** — The launch template pinned `HttpTokens: required` and `CpuCredits: standard`. Explain each choice in one sentence.

---

## Exercise 7 — Elasticity: stop guessing capacity

**Benefit under test:** elasticity. You will attach a target-tracking policy, generate load, and watch capacity follow demand without human intervention.

### Steps

1. Attach a target-tracking scaling policy at 40 % average CPU.

   ```bash
   aws autoscaling put-scaling-policy \
     --auto-scaling-group-name clf-ha-asg \
     --policy-name cpu-target-40 \
     --policy-type TargetTrackingScaling \
     --target-tracking-configuration '{
       "TargetValue": 40.0,
       "PredefinedMetricSpecification": {
         "PredefinedMetricType": "ASGAverageCPUUtilization"
       },
       "DisableScaleIn": false
     }' \
     --query '[PolicyARN,Alarms[].AlarmName]' --output json
   ```

   ```json
   [
       "arn:aws:autoscaling:us-east-1:123456789012:scalingPolicy:...:policyName/cpu-target-40",
       [
           "TargetTracking-clf-ha-asg-AlarmHigh-0f6b...",
           "TargetTracking-clf-ha-asg-AlarmLow-3d21..."
       ]
   ]
   ```

   Note what AWS created for you: **two CloudWatch alarms you never wrote.** That is the managed-service benefit in miniature.

2. Inspect one of those alarms to see the control loop AWS synthesised.

   ```bash
   aws cloudwatch describe-alarms --alarm-name-prefix "TargetTracking-clf-ha-asg-AlarmHigh" \
     --query 'MetricAlarms[0].[MetricName,Statistic,Threshold,ComparisonOperator,EvaluationPeriods,Period]' \
     --output table
   ```

   ```text
   ---------------------------------------------------------------------------------
   |                                DescribeAlarms                                 |
   +---------------+---------+------+----------------------------+-----+-----------+
   |  CPUUtilization| Average |  40.0| GreaterThanThreshold       |  3  |  60       |
   +---------------+---------+------+----------------------------+-----+-----------+
   ```

3. Record the starting capacity.

   ```bash
   aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names clf-ha-asg \
     --query 'AutoScalingGroups[0].[MinSize,MaxSize,DesiredCapacity,length(Instances)]' \
     --output text
   ```

   ```text
   2	4	2	2
   ```

4. Generate CPU load on every running instance via SSM Run Command. *(Skip to Step 5's manual alternative if your instances have no SSM instance profile.)*

   ```bash
   IDS=$(aws autoscaling describe-auto-scaling-instances \
     --query "AutoScalingInstances[?AutoScalingGroupName=='clf-ha-asg'].InstanceId" \
     --output text)

   aws ssm send-command --instance-ids $IDS \
     --document-name "AWS-RunShellScript" \
     --parameters 'commands=["for i in $(seq 1 $(nproc)); do timeout 600 sh -c \"while :; do :; done\" & done; exit 0"]' \
     --query 'Command.CommandId' --output text
   ```

5. **Manual alternative** — force the capacity change directly and observe the mechanics, which is the part that matters for CLF-C02:

   ```bash
   aws autoscaling set-desired-capacity \
     --auto-scaling-group-name clf-ha-asg --desired-capacity 4 --honor-cooldown
   ```

6. Poll capacity every 30 s for 6 minutes.

   ```bash
   for i in $(seq 1 12); do
     printf '%s ' "$(date +%T)"
     aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names clf-ha-asg \
       --query 'AutoScalingGroups[0].[DesiredCapacity,length(Instances[?LifecycleState==`InService`])]' \
       --output text
     sleep 30
   done
   ```

   ```text
   14:45:03 4	2
   14:45:34 4	2
   14:46:05 4	3
   14:46:36 4	4
   ...
   ```

7. Scale back in and watch the *asymmetry*.

   ```bash
   aws autoscaling set-desired-capacity \
     --auto-scaling-group-name clf-ha-asg --desired-capacity 2
   sleep 60
   aws autoscaling describe-scaling-activities --auto-scaling-group-name clf-ha-asg \
     --max-items 6 --query 'Activities[].[StatusCode,Description]' --output text
   ```

   ```text
   Successful	Terminating EC2 instance: i-0ddd...
   Successful	Terminating EC2 instance: i-0ccc...
   Successful	Launching a new EC2 instance: i-0ddd...
   Successful	Launching a new EC2 instance: i-0ccc...
   ```

8. Confirm the policy is still armed and would act on real load.

   ```bash
   aws autoscaling describe-policies --auto-scaling-group-name clf-ha-asg \
     --query 'ScalingPolicies[].[PolicyName,PolicyType,TargetTrackingConfiguration.TargetValue,Enabled]' \
     --output table
   ```

References: <https://docs.aws.amazon.com/autoscaling/ec2/userguide/as-scaling-target-tracking.html> · <https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/burstable-performance-instances.html>

### Check your understanding — Block 7

- **Q7.1** — Define elasticity and scalability, and explain why "we can add servers" is scalability but not elasticity.
- **Q7.2** — Target tracking scaled *out* on a 3-minute alarm but the group has a warm-up of 120 s. Explain what problem the warm-up prevents.
- **Q7.3** — The instances are `t3.micro` with `CpuCredits: standard`. Explain precisely why CPU-based target tracking on burstable instances is a trap in production, and name a better predefined metric for a web tier behind an ALB.
- **Q7.4** — "Stop guessing capacity" — describe the two symmetric failure modes of capacity guessing on-premises, and give the financial name for each.
- **Q7.5** — Why is scaling *in* generally more dangerous than scaling *out*, and which two ASG features exist to make it safer?

---

## Exercise 8 — Measure the global footprint from where you sit

**Benefit under test:** global reach. You will measure real network distance to AWS Regions.

### Steps

1. Measure TCP connect time to a set of regional service endpoints, taking the best of three samples.

   ```bash
   for r in us-east-1 us-west-2 eu-west-1 eu-central-1 sa-east-1 ap-northeast-1 ap-southeast-2; do
     best=9
     for n in 1 2 3; do
       t=$(curl -s -o /dev/null --max-time 5 -w '%{time_connect}' "https://ec2.${r}.amazonaws.com" 2>/dev/null) || t=9
       awk -v a="$t" -v b="$best" 'BEGIN{exit !(a<b)}' && best=$t
     done
     printf '%-16s %6.0f ms\n' "$r" "$(awk -v x="$best" 'BEGIN{print x*1000}')"
   done
   ```

   ```text
   us-east-1           118 ms
   us-west-2           176 ms
   eu-west-1            32 ms
   eu-central-1         24 ms
   sa-east-1           212 ms
   ap-northeast-1      241 ms
   ap-southeast-2      298 ms
   ```

   *(Values depend entirely on where you are. Read the shape, not the numbers.)*

2. Compare against an edge-delivered, anycast endpoint — the same content served from the nearest Point of Presence rather than a Region.

   ```bash
   for n in 1 2 3; do
     curl -s -o /dev/null -w 'cloudfront connect: %{time_connect}s  ttfb: %{time_starttransfer}s\n' \
       https://d1.awsstatic.com/webteam/architecture-center/AWS-Architecture_Icon.png
   done
   ```

   ```text
   cloudfront connect: 0.009s  ttfb: 0.031s
   cloudfront connect: 0.008s  ttfb: 0.022s
   cloudfront connect: 0.008s  ttfb: 0.021s
   ```

3. Confirm the edge served it, and from which POP.

   ```bash
   curl -sI https://d1.awsstatic.com/webteam/architecture-center/AWS-Architecture_Icon.png \
     | grep -iE 'x-cache|x-amz-cf-pop|via'
   ```

   ```text
   via: 1.1 8f3a2b1c4d5e6f7a8b9c0d1e2f3a4b5c.cloudfront.net (CloudFront)
   x-amz-cf-pop: MAD53-P2
   x-cache: Hit from cloudfront
   ```

4. Turn the measurement into a design decision.

   ```bash
   python3 - <<'PY'
   # Round-trips matter more than bandwidth for chatty protocols.
   for name, rtt in [("nearest Region", 0.024), ("distant Region", 0.241), ("edge PoP", 0.008)]:
       for rts in (1, 5, 10):
           print(f"{name:16s} {rts:2d} round-trips -> {rtt*rts*1000:6.0f} ms")
       print()
   PY
   ```

   ```text
   nearest Region    1 round-trips ->     24 ms
   nearest Region    5 round-trips ->    120 ms
   nearest Region   10 round-trips ->    240 ms

   distant Region    1 round-trips ->    241 ms
   distant Region    5 round-trips ->   1205 ms
   distant Region   10 round-trips ->   2410 ms
   ...
   ```

Reference: <https://aws.amazon.com/cloudfront/features/> · <https://aws.amazon.com/about-aws/global-infrastructure/regions_az/>

### Check your understanding — Block 8

- **Q8.1** — Why is "deploy to the Region closest to your users" a benefit that on-premises hosting can rarely match, in *cost* terms rather than technical terms?
- **Q8.2** — The edge PoP answered in ~8 ms and a Region in ~24 ms. Why can you not simply "run the application at the edge" for all workloads? Name what edge locations do and do not host.
- **Q8.3** — Step 4 shows latency multiplied by round-trips. What is the architectural lesson for a service placed in a distant Region, and which benefit of the AWS Cloud lets you fix it in minutes?
- **Q8.4** — Your users are in Madrid and Sydney. Sketch, in three lines, the AWS constructs that give both good latency, and state what new problem you have introduced.

---

## Exercise 9 — Close the loop: see the variable expense you generated

**Benefit under test:** the OpEx feedback loop. Consumption you can measure is consumption you can optimise — the mechanism has no on-premises equivalent.

> Step 2 calls the Cost Explorer API, billed at **$0.01 per request**. Call it once.

### Steps

1. Check your enrolment in the free right-sizing service.

   ```bash
   aws compute-optimizer get-enrollment-status --region "$AWS_REGION" \
     --query '[status,memberAccountsEnrolled]' --output text
   ```

   ```text
   Inactive	False
   ```

2. Pull the last month of spend grouped by service.

   ```bash
   aws ce get-cost-and-usage --region us-east-1 \
     --time-period Start=$(date -u -d '30 days ago' +%F),End=$(date -u +%F) \
     --granularity MONTHLY --metrics UnblendedCost \
     --group-by Type=DIMENSION,Key=SERVICE \
     --query 'ResultsByTime[].Groups[?Metrics.UnblendedCost.Amount!=`0`].[Keys[0],Metrics.UnblendedCost.Amount]' \
     --output text | sort -k2 -gr | head -10
   ```

   ```text
   EC2 - Other	0.0412000000
   Amazon Elastic Compute Cloud - Compute	0.0312000000
   Amazon Elastic Load Balancing	0.0169000000
   AWS Cost Explorer	0.0100000000
   Amazon Simple Storage Service	0.0000004000
   ```

   > Cost data lags by up to 24 hours. If the lab charges are absent, that is expected — re-run tomorrow.

3. Read the current state of the guardrail you built in Exercise 0.

   ```bash
   aws budgets describe-budget --account-id "$ACCOUNT_ID" --budget-name clf-lab-guardrail \
     --query 'Budget.[BudgetLimit.Amount,CalculatedSpend.ActualSpend.Amount]' --output text
   ```

   ```text
   5.0	0.09
   ```

4. Name the number. The entire multi-AZ, load-balanced, self-healing, auto-scaling deployment you built and destroyed cost less than ten cents, and required zero procurement approval.

References: <https://docs.aws.amazon.com/aws-cost-management/latest/APIReference/API_GetCostAndUsage.html> · <https://docs.aws.amazon.com/compute-optimizer/latest/ug/what-is-compute-optimizer.html>

### Check your understanding — Block 9

- **Q9.1** — Line "EC2 - Other" is larger than EC2 compute itself. Name two charges that typically land there, and state which of them the lab incurred.
- **Q9.2** — The Cost Explorer request itself appears in the bill. What is the design principle being illustrated, and name one other AWS API that is billed per call.
- **Q9.3** — Explain how the ability to *see* consumption per service, per hour, per tag, changes the engineering conversation compared with an annual data-centre depreciation line.

---

## Exercise 10 — Teardown (mandatory)

### Steps

1. Delete the Auto Scaling group; `--force-delete` terminates its instances.

   ```bash
   aws autoscaling delete-auto-scaling-group \
     --auto-scaling-group-name clf-ha-asg --force-delete
   ```

2. Delete load balancing resources in dependency order.

   ```bash
   aws elbv2 delete-listener      --listener-arn "$LISTENER_ARN"
   aws elbv2 delete-load-balancer --load-balancer-arn "$ALB_ARN"
   aws elbv2 wait load-balancers-deleted --load-balancer-arns "$ALB_ARN"
   aws elbv2 delete-target-group  --target-group-arn "$TG_ARN"
   ```

3. Delete the launch template.

   ```bash
   aws ec2 delete-launch-template --launch-template-name clf-ha-lt \
     --query 'LaunchTemplate.LaunchTemplateName' --output text
   ```

4. Delete the security group. It will fail while ENIs still reference it — retry until it succeeds.

   ```bash
   for i in $(seq 1 12); do
     if aws ec2 delete-security-group --group-id "$SG_ID" 2>/dev/null; then
       echo "sg deleted"; break
     fi
     echo "waiting for ENI release..."; sleep 20
   done
   ```

5. Empty and delete the CloudFormation stack. Versioning is on, so all versions must go.

   ```bash
   BUCKET=$(aws cloudformation describe-stacks --stack-name clf-agility \
     --query 'Stacks[0].Outputs[?OutputKey==`BucketName`].OutputValue' --output text)

   aws s3api delete-objects --bucket "$BUCKET" --delete "$(aws s3api list-object-versions \
     --bucket "$BUCKET" --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' \
     --output json)" 2>/dev/null || true

   aws cloudformation delete-stack --stack-name clf-agility
   aws cloudformation wait stack-delete-complete --stack-name clf-agility
   ```

6. **Verify nothing survived.** Never trust a delete command; verify the absence.

   ```bash
   echo "--- running instances tagged clf-ha ---"
   aws ec2 describe-instances \
     --filters Name=tag:Name,Values=clf-ha \
               Name=instance-state-name,Values=pending,running,stopping,stopped \
     --query 'length(Reservations[].Instances[])'

   echo "--- load balancers ---"
   aws elbv2 describe-load-balancers --query "length(LoadBalancers[?LoadBalancerName=='clf-ha-alb'])"

   echo "--- auto scaling groups ---"
   aws autoscaling describe-auto-scaling-groups \
     --query "length(AutoScalingGroups[?AutoScalingGroupName=='clf-ha-asg'])"

   echo "--- stacks ---"
   aws cloudformation describe-stacks --stack-name clf-agility 2>&1 | grep -c "does not exist"
   ```

   ```text
   --- running instances tagged clf-ha ---
   0
   --- load balancers ---
   0
   --- auto scaling groups ---
   0
   --- stacks ---
   1
   ```

7. Optionally remove the budget (keep it if you will continue studying).

   ```bash
   aws budgets delete-budget --account-id "$ACCOUNT_ID" --budget-name clf-lab-guardrail
   ```

### Check your understanding — Block 10

- **Q10.1** — Step 4 needed a retry loop for the security group. Explain the underlying dependency and what it teaches about deleting cloud resources in general.
- **Q10.2** — Which of the resources you created in this lab would have kept billing you indefinitely if you had walked away after Exercise 7? Rank them by hourly cost.
- **Q10.3** — Step 6 verifies deletion rather than assuming it. Name the AWS-native mechanism that would have made this entire teardown a single command, and why it did not apply to the ALB/ASG stack as built.

---

## Answers

<details>
<summary><strong>Click to expand — full answer key with reasoning</strong></summary>

### Block 0

**A0.1 — No.** AWS Budgets is a **monitoring and notification** service, not a spending cap. Exceeding a budget threshold sends an SNS/e-mail notification; it does not throttle or terminate anything. To actually stop spend you need **budget actions** (a separate configuration that can apply a restrictive IAM policy, stop EC2/RDS instances, or attach an SCP), or preventive controls such as Service Control Policies and IAM condition keys limiting instance types. This is the single most common misunderstanding on the exam: *budgets alert, SCPs prevent.*

**A0.2** — The on-premises equivalent is the capital purchase-order approval process. It is a *preventive* control by accident of latency: you cannot spend without a signature, and hardware takes weeks to arrive. But it is structurally weaker as a *management* control because it operates only at acquisition time — once the hardware exists, incremental use is invisible and free at the margin, so nobody measures it. The cloud inverts this: acquisition is instant (so preventive controls must be explicit) but consumption is continuously metered (so detective controls become genuinely useful).

**A0.3** — The ARN is an **IAM user** — a long-lived static credential. A production platform team would flag it because it implies access keys that do not rotate automatically. The current guidance is federated access via IAM Identity Center or an assumed role (`arn:aws:sts::...:assumed-role/...`), which issues short-lived credentials. This is Domain 2 material but appears here because identity is the substrate every other benefit rests on.

---

### Block 1

**A1.1**
- **Region** — a named, physically separate geographic area (e.g. `eu-west-1`) containing multiple Availability Zones; it is the primary unit of data residency and service scope. Data does not leave a Region unless you explicitly move it.
- **Availability Zone** — one or more discrete data centres within a Region, with independent power, cooling and physical security, connected to the other AZs by high-bandwidth, low-latency (typically single-digit millisecond) private links. It is the unit of **fault isolation**.
- **Local Zone** — an extension of a Region placed in a metropolitan area, offering a *subset* of services with single-digit-millisecond latency to that metro. It is a unit of **proximity for compute**.
- **Edge Location / Point of Presence** — a CloudFront/Route 53/Global Accelerator site used to cache content and terminate connections close to users. It is a unit of **proximity for delivery**, not general compute.

**A1.2** — If `us-east-1a` meant the same physical zone in every account, then every customer defaulting to "a" would concentrate load, and hot-spotting would defeat the entire point of zonal distribution. Randomising per account statistically balances usage across the physical zones. The concrete failure: without randomisation, the busiest physical AZ in `us-east-1` would carry a disproportionate share of all customer capacity, and a failure there would have outsized blast radius.

**A1.3** — They must exchange the **AZ ID** (`use1-az2`), which is consistent across all accounts. They must ignore the **AZ name** (`us-east-1c`), which is account-scoped and therefore meaningless as a shared coordinate. This matters in practice for cross-AZ data-transfer charges and for services shared via AWS RAM.

**A1.4** — An administrator enables an opt-in Region at the account/organisation level (Account settings, or `account enable-region`). AWS makes newer Regions opt-in so that: (a) accounts are not implicitly exposed to jurisdictions they have not evaluated for compliance/data-residency; (b) the IAM and STS blast radius stays smaller by default; (c) credentials issued by the global STS endpoint are not automatically valid in Regions the customer has never considered. It is a secure-by-default posture.

**A1.5** — A **Local Zone** (e.g. `us-west-2-lax-1a`) is correct: it runs EC2, EBS and other compute-plane services within single-digit milliseconds of Los Angeles. An Edge Location is wrong for the *game server* because Edge Locations host content delivery and edge functions — caching, TLS termination, lightweight compute — not general-purpose stateful game workloads. (For a *stateless* latency-critical entry point, AWS Global Accelerator over edge networking would complement, not replace, the Local Zone.)

---

### Block 2

**A2.1** — AWS is responsible for **security *of* the cloud** (hardware, the global infrastructure, the virtualisation layer, physical facilities, and the managed-service software stack). The customer is responsible for **security *in* the cloud** (data, identity and access, OS and network configuration where exposed, encryption choices, application code).
- (a) encrypting an S3 object → **customer** (AWS provides the mechanism; choosing and configuring it is yours)
- (b) destroying a failed SSD → **AWS**
- (c) patching the Linux kernel on EC2 → **customer**
- (d) patching the Linux kernel under RDS → **AWS**
- (e) configuring a security group → **customer**

The (c)/(d) pair is the whole point: the *same task* changes owner depending on the service model. Moving up the abstraction ladder (EC2 → RDS → Aurora Serverless → Lambda) transfers responsibility to AWS.

**A2.2** — Do not assume the offering is *durable* or *unlimited*. `describe-instance-type-offerings` tells you an instance type is **offered** in an AZ; it says nothing about currently available capacity, and On-Demand capacity is not guaranteed without a Capacity Reservation. Also do not assume your account's `us-east-1a` is the same physical zone as another account's — see A1.3. Production designs use Capacity Reservations, multiple instance types in a mixed-instances policy, or ASG instance-type flexibility rather than betting on a single type.

**A2.3** — Genuinely disappear: (1) capital hardware purchase and its 3–5-year refresh cycle; (2) facility costs — floor space, power, cooling, physical security, the diesel generator, the UPS; (3) the low-level operations labour: racking, cabling, RMA of failed disks, firmware, capacity forecasting for hardware procurement.
Does **not** disappear: engineering staff. The work shifts upward — from replacing disks to designing for failure, from capacity planning to cost optimisation, from patching hypervisors to managing IAM. Headcount is often flat; what changes is what those people do. Presenting cloud as a headcount reduction is the classic way these business cases fail post-migration.

---

### Block 3

**A3.1** — **CapEx** is an up-front purchase of an asset, depreciated over its useful life, requiring approval before the value is proven, and sunk once spent. **OpEx** is a recurring operating cost incurred as consumed, expensed in the period, and stoppable.
A 3-year On-Demand EC2 run is **OpEx** in accounting terms — but *economically* it is the worst of both worlds: you pay the flexibility premium of On-Demand while exhibiting the consumption pattern of a purchased asset. That gap is precisely the arbitrage Savings Plans and Reserved Instances exist to close (Exercise 4).

**A3.2** — **Elasticity** makes the $599 number reachable: capacity can be reduced to zero outside business hours. The architectural work required is real, and this is the part that is skipped in every naive business case: the workload must be **stateless or externally stateful** (state in RDS/DynamoDB/S3, not on instance disks), start-up must be automated (no manual configuration step), the shutdown must be safe (connection draining, no in-flight jobs), and something must schedule it (an EventBridge rule, an ASG scheduled action, or an Instance Scheduler solution). Elasticity is a *capability of the platform*; realising the saving is a *property of your architecture*.

**A3.3** — Two structural reasons: (1) **local input costs** — electricity, land, construction, staffing, taxes and import duties differ dramatically by country, and Brazil in particular carries high hardware import taxation; (2) **scale of the Region** — N. Virginia is AWS's oldest and largest Region with six AZs and enormous aggregate volume, so its fixed costs are amortised across far more usage than a smaller Region's.
It does **not** contradict economies of scale — it *demonstrates* them. Economies of scale mean unit cost falls as volume rises; the price differential between the largest Region and a smaller one is that relationship made visible. The benefit is not "the same price everywhere", it is "prices that fall over time as volume grows, without you renegotiating anything."

**A3.4** — Economies of scale: because AWS aggregates the demand of millions of customers, it purchases hardware, power and bandwidth at volumes no individual customer could reach, and amortises fixed engineering costs across an enormous base. The feedback loop runs: **more customers → higher aggregate volume → lower unit cost to AWS → AWS lowers prices → more customers.** AWS has publicly reduced prices well over a hundred times. The benefit to you is *passive*: your bill falls without any action on your part, which is impossible with owned hardware, where unit cost is fixed at the moment of purchase and only rises as the asset ages.

**A3.5** — Without those filters the query matches multiple SKUs that are not comparable:
- `capacitystatus` distinguishes ordinary usage (`Used`) from Capacity Reservation SKUs (`AllocatedCapacityReservation`, `UnusedCapacityReservation`), which have different price rows for the same instance type.
- `preInstalledSw=NA` excludes SKUs bundled with licensed software (e.g. SQL Server), which cost several times more.
Without them, `get-products` returns several price rows and `--max-results 1` would silently pick an arbitrary one — you would get *a* number, confidently wrong. This is a general lesson about the Price List API: it is a product catalogue, and under-specified filters return the wrong product, not an error.

---

### Block 4

**A4.1** — A Savings Plan commits you to a **dollar amount of compute spend per hour** for 1 or 3 years. You are **not** committing to an instance type, size, family (for Compute SP), Region, operating system, tenancy, or even the service — a Compute Savings Plan covers EC2, Fargate and Lambda.
A **Standard Reserved Instance** is bound to instance family and Region (and optionally AZ), so changing your architecture strands the commitment. This matters because the flexible commitment preserves most of the agility benefit while capturing most of the discount — it is a deliberately designed compromise between the two, whereas a Standard RI trades agility away almost entirely.

**A4.2** — 8 h × 5 d = 40 h/week out of 168 → **23.8 % utilisation**. That is far below the ~71 % break-even, so a 1-year Compute Savings Plan for this workload is **not justified**; you would pay for roughly three times the compute you consume. The correct strategy is elasticity (scale to zero outside hours) plus, if the workload is interruption-tolerant, Spot capacity. Savings Plans are for the *baseline* — the floor of always-on consumption — not for the peaks. In a mature account you size the commitment to the 24×7 baseline and let On-Demand/Spot absorb everything above it.

**A4.3** — *Reverses it partially:* you have re-created a fixed, unavoidable obligation for 1–3 years — economically a lease, and if your usage collapses you keep paying, which is exactly the rigidity CapEx imposed.
*Preserves it:* the commitment is to a dollar rate, not to a physical asset — it can be applied to any instance family, Region or compute service, it never becomes obsolete hardware, it can be sold on the Reserved Instance Marketplace (for Standard RIs), and it can be sized to only the portion of demand you are genuinely certain about while the volatile remainder stays fully elastic. The benefit is not eliminated; it is *priced*, and you choose how much of it to sell back for a discount.

**A4.4** — Typical discount, lowest to highest: **Dedicated Host On-Demand** (a premium *above* shared On-Demand — you pay for a whole physical server) → **On-Demand** (baseline, 0 %) → **Savings Plans / Reserved Instances** (up to ~72 % for 3-year all-upfront) → **Spot** (up to ~90 %).
**Spot** is the one AWS reclaims, with a **2-minute interruption notice** delivered via instance metadata and an EventBridge event. It is unbeatable for fault-tolerant, checkpointable, stateless work (batch, CI, rendering, big-data) and disqualified for anything that cannot survive an abrupt termination.

---

### Block 5

**A5.1** — On-premises equivalent: specify storage capacity → obtain budget approval → issue purchase order → wait for vendor delivery → rack and cable → install and configure the storage OS → configure RAID/erasure coding → configure encryption at rest and key management → configure snapshots/versioning → configure access control → hand over to the requesting team. Realistic lead time: **4 to 16 weeks**.
The dominating line is **procurement** — budget approval plus vendor delivery — which is measured in weeks and is almost entirely *waiting*, not working. This is why "agility" is a business benefit rather than a technical one: the bottleneck being removed was never the engineering, it was the organisational latency attached to spending capital.

**A5.2** — The second component is **the ability to experiment cheaply and reverse decisions.** Fast tear-down matters because it collapses the cost of being wrong. When provisioning takes 12 weeks and costs $40,000, every proposal must be defended in advance, so only safe ideas get funded and architecture calcifies around the first guess. When it takes 24 seconds and costs $0.09, you test the idea instead of arguing about it, and you delete it without ceremony when it fails. Agility is *failure becoming cheap*, and that changes which decisions get made, not just how fast.

**A5.3** — **Agility** is the speed at which you can create, change and discard infrastructure and ship new capability. **Elasticity** is the automatic matching of provisioned capacity to current demand, in both directions.
A system that is **elastic but not agile**: a mainframe or a large on-premises virtualisation cluster with dynamic resource allocation. It reallocates CPU and memory to workloads automatically as demand shifts (elastic within its fixed envelope), yet adding a new service, a new environment, or a new geography still requires a hardware purchase and weeks of change control (not agile). The converse also exists — a manually-scaled but instantly-provisioned VM is agile but not elastic.

**A5.4** — `validate-template` is a **syntactic and structural** check: it parses the JSON/YAML, verifies the template anatomy (`Resources`, `Parameters`, intrinsic function usage) and returns the declared parameters and capabilities. It does not create anything, so it needs no resources to exist.
It still fails to catch: invalid property values for a specific resource type, references to resources that do not exist outside the template, IAM permission failures, service quota exhaustion, naming collisions (an S3 bucket name already taken globally), and any logical error in your architecture. Those only surface during the actual stack operation — which is why **change sets** exist as the intermediate step between validation and execution.

---

### Block 6

**A6.1** — **High availability** means the system minimises downtime and recovers automatically from component failure, accepting brief degradation or a short interruption. **Fault tolerance** means the system continues operating with *no* loss of service and *no* loss of capacity when a component fails — which requires enough redundancy that a failure is invisible.
This lab demonstrated **high availability**. Evidence from Step 10: zero requests failed (good), but for roughly two minutes the fleet ran on a **single** instance in one AZ — capacity was halved and the system had no remaining redundancy. A fault-tolerant design would have kept full capacity through the failure, which here would mean `min-size 4` across two AZs so that losing one AZ still leaves the two instances needed to serve peak load (the "N+1 per AZ" or "50 % headroom" pattern). Fault tolerance costs roughly double; high availability is the pragmatic default.

**A6.2** — With independent AZs at 99.9 % each, the probability that *both* fail simultaneously is 0.001 × 0.001 = 10⁻⁶, so theoretical availability is **99.9999 %** (≈ 32 seconds of downtime per year).
Real availability is lower because:
1. **Failures are not independent.** Shared regional control planes, a bad configuration or code deployment pushed to both AZs, a DNS error, an expired certificate, or a correlated traffic surge take down both simultaneously. Correlated failure is the dominant term in practice.
2. **The composite system has more components than the AZs.** The ALB, the target group health check, the ASG control plane, your application, and the database each have their own availability, and availabilities multiply in series. A 99.99 % ALB in front of a 99.9999 % compute layer yields at best 99.99 %.
The engineering lesson: past two AZs, adding redundancy stops helping and the limiting factor becomes change management and blast-radius control.

**A6.3** — With `--health-check-type EC2`, the ASG considers an instance healthy as long as the **EC2 instance status checks** pass — the hypervisor sees it running and the network reachable. It therefore misses every **application-level** failure: httpd crashed, the application deadlocked, the disk filled and the process cannot write, the app returns HTTP 500 to every request. The instance stays "healthy" and the ALB keeps a broken target in rotation (or, worse with `EC2` checks only, the ASG never replaces it).
`ELB` health checks delegate the judgement to the load balancer's HTTP probe against your actual endpoint, so an application that stops serving is marked unhealthy, removed from rotation *and* replaced by the ASG. **Always use `ELB` health checks for anything behind a load balancer** — and make the health-check path a real readiness check, not a static file that responds even when the app is dead.

**A6.4** — With `--min-size 1`, the ASG's *contract* is "at least one instance". After an AZ loss it would be satisfied by the single surviving instance and would have no obligation to maintain two. More importantly, `desired-capacity` can drift down to 1 through scale-in, at which point the entire service sits in one AZ and an AZ failure is a **total outage**, not a degradation. `--min-size 2` combined with a multi-AZ `--vpc-zone-identifier` makes the ASG's AZ-balancing behaviour keep one instance in each zone, so no single AZ failure can take the service to zero. The general rule: **minimum size must be at least the number of AZs you are protecting against losing, times the per-AZ capacity you need.**

**A6.5**
- **`HttpTokens: required`** enforces **IMDSv2**, the session-oriented instance metadata service. It requires a `PUT` to obtain a token before any metadata read, which structurally defeats server-side request forgery attacks — an SSRF vulnerability in your application cannot be used to read instance credentials, because the attacker cannot issue the `PUT` with the required header through a naive request-forwarding bug. There is no reason to run IMDSv1 in new work.
- **`CpuCredits: standard`** puts the burstable `t3` instances in standard mode rather than unlimited mode. In `unlimited` mode, an instance that exhausts its CPU credits keeps running at full speed and **bills you a surcharge** for surplus credits — a silent cost leak during exactly the load spike this lab generates. `standard` mode throttles instead of billing, which for a lab is the correct trade. (In production the choice is workload-dependent: `unlimited` is usually right for spiky user-facing services where throttling is worse than a small bill, and this decision should be explicit rather than inherited from the default.)

---

### Block 7

**A7.1** — **Scalability** is the ability of a system to handle increased load by adding resources — vertically (a bigger instance) or horizontally (more instances). It is a property of the architecture and it says nothing about *when* or *by whom* the resources are added.
**Elasticity** is the ability to add *and remove* those resources **automatically and rapidly, in response to actual demand**, so provisioned capacity tracks consumed capacity over time.
"We can add servers" is scalability: it establishes that the architecture *can* grow. It is not elasticity because it lacks all three of the defining properties — automatic, bidirectional, and demand-triggered. The bidirectional part is where the money is: a system that only scales out is just a slower way to over-provision.

**A7.2** — The **warm-up** (`--default-instance-warmup`) tells the ASG to exclude newly launched instances from the group's aggregated metric until they have been running for that period, and to not count them as contributing capacity yet.
Without it, a booting instance reports either no CPU metric or an unrepresentative one (near 0 % while it installs packages, or near 100 % during boot). The average CPU of the group is therefore distorted immediately after a scale-out, which causes the classic pathology: the policy sees a still-high average, launches *more* instances, sees the average drop as they all finish booting, then scales in aggressively — **oscillation**, also called thrashing or flapping. The warm-up damps the control loop by ignoring the transient. Note that `--estimated-instance-warmup` on the *policy* is the deprecated form; `--default-instance-warmup` on the *group* is the current one and applies to every policy and lifecycle activity uniformly.

**A7.3** — Burstable instances decouple observed CPU utilisation from available performance. A `t3.micro` in `standard` mode earns CPU credits at a fixed rate and can only sustain a baseline (~10 % of a vCPU) once credits are exhausted. When credits run out, the instance is **throttled to baseline** — and a throttled instance sits pinned at "100 % CPU utilisation" while doing almost no work. Target tracking on `ASGAverageCPUUtilization` therefore scales out based on a metric that no longer means "busy", and every replacement instance starts with its own credit balance and repeats the cycle. In `unlimited` mode the failure mode is financial instead: the fleet never appears saturated and silently accrues surplus-credit charges.
Better metric for a web tier behind an ALB: **`ALBRequestCountPerTarget`** — it measures the actual work arriving per instance, is independent of instance-level CPU accounting quirks, and maps directly to a capacity model you can reason about ("each instance handles N requests/second"). For queue-driven workers, the equivalent is a custom metric of backlog-per-instance (`ApproximateNumberOfMessagesVisible` ÷ in-service instances).

**A7.4** — The two symmetric failure modes:
1. **Over-provisioning** — buying for peak. The financial name is **wasted capital / low asset utilisation**; typical on-premises utilisation is 10–20 %, meaning 80–90 % of the purchase is idle depreciation. It is expensive but invisible, which is why it persists.
2. **Under-provisioning** — buying for average. The financial name is **opportunity cost**, realised as lost revenue, breached SLAs, and customer churn during the peaks you failed to serve.
The trap is that both are consequences of the same act: making a capacity decision *in advance* on incomplete information, then being unable to revise it for years. Elasticity does not make you better at forecasting; it removes the requirement to forecast.

**A7.5** — Scaling **in** is more dangerous because it is **destructive and asymmetric in consequence**. A wrong scale-out costs money for a few minutes; a wrong scale-in terminates instances that were serving traffic, drops in-flight requests, discards local state and caches (causing a cold-start latency spike as the remaining instances take the load), and can cascade — the reduced fleet becomes overloaded, its health checks fail, and the group loses further capacity.
Two ASG features that make it safer:
1. **Connection draining / deregistration delay** on the target group, combined with **lifecycle hooks** (`autoscaling:EC2_INSTANCE_TERMINATING`), which hold the instance in a `Terminating:Wait` state so in-flight requests complete and cleanup runs before termination.
2. **Cooldown periods and scale-in protection** — cooldowns prevent successive scale-in actions before the previous one's effect is measurable, and instance scale-in protection (or `DisableScaleIn: true` on the target-tracking policy, delegating scale-in to a separate, more conservative policy) shields specific instances or the whole group from automatic removal.

---

### Block 8

**A8.1** — On-premises, serving users in a new geography means **acquiring a physical presence there**: leasing colocation space, shipping and installing hardware, arranging local connectivity and power, meeting local regulatory requirements, and staffing or contracting hands-on support. That is a capital commitment of tens to hundreds of thousands of dollars per site, plus a multi-month lead time, incurred *before* you know whether the market is worth serving. The economics force you to concentrate in one or two locations and accept bad latency everywhere else.
On AWS the same expansion is a deployment into another Region: no capital, no lead time, and **the cost scales with usage from zero**. You can serve Sydney badly-and-cheaply today, discover demand, and deploy locally tomorrow — and shut it down next month if you were wrong. The benefit is not that AWS is closer to your users; it is that **testing whether closeness is worth paying for costs nothing.**

**A8.2** — Edge locations are optimised for **content delivery and connection termination**, not general compute. They host: CloudFront cache storage and TLS termination, Route 53 DNS resolution, AWS Global Accelerator anycast ingress, AWS WAF and Shield inspection, and constrained edge compute (CloudFront Functions — sub-millisecond, JavaScript, header/URL manipulation only; Lambda@Edge — larger, with real limits on runtime, memory and package size).
They do **not** host: your database, persistent state, long-running processes, arbitrary containers, or anything requiring VPC connectivity. There are hundreds of PoPs precisely *because* they are small and stateless — replicating a full Region's service catalogue and durability guarantees to every metro is not economically or physically possible. So the pattern is: terminate and cache at the edge, compute and persist in a Region.

**A8.3** — The lesson is that **latency multiplies with chattiness**, and the fix is protocol design, not bandwidth. A design that makes 10 sequential round-trips to render a page is unnoticeable at 8 ms (80 ms) and unusable at 241 ms (2.4 seconds) — same code, same bandwidth, different geography. Mitigations are batching requests, eliminating sequential dependencies, caching at the edge, and moving the chatty conversation to the server side so only one round-trip crosses the ocean.
The benefit that lets you fix it in minutes is **global reach combined with agility**: you deploy a second Region, or place a CloudFront distribution in front, without buying anything. On-premises, the same realisation would begin a procurement cycle.

**A8.4** — Three lines:
1. Deploy the stack in **`eu-west-1`/`eu-south-2`** and **`ap-southeast-2`** (multi-AZ within each, as in Exercise 6).
2. Put **Route 53 latency-based** or **geolocation routing** — or **Global Accelerator** for TCP/UDP anycast ingress — in front, so each user reaches the nearer Region automatically, with health checks for failover.
3. Serve static and cacheable content through **CloudFront**, so most requests never traverse an ocean at all.
The new problem is **state**. You now have two active Regions and must decide how data is replicated: a globally-distributed store (DynamoDB global tables, Aurora Global Database, S3 Cross-Region Replication), and with it the consistency model — last-writer-wins conflicts, replication lag, and which Region is authoritative during a partition. You have also doubled the operational surface: two deployments, two sets of alarms, two failure domains, and a compliance question about which user data may legally cross which border. Global reach is *provisioned* in minutes; global **consistency** is a permanent architectural decision.

---

### Block 9

**A9.1** — "EC2 - Other" is a billing bucket for EC2-adjacent charges that are not instance-hours. It typically contains: **EBS volumes and snapshots**, **data transfer** (notably inter-AZ and NAT Gateway processing), **Elastic IP addresses** not attached to a running instance, and **NAT Gateway hourly charges**.
This lab incurred primarily **EBS root volumes** — every instance the ASG launched carried an 8 GiB gp3 root volume billed by the GiB-month for as long as it existed — plus a small amount of **cross-AZ data transfer**, since the ALB in one AZ forwards some requests to targets in the other. Both are charges people forget when estimating "the cost of an EC2 instance", and EBS in particular keeps billing after an instance is stopped.

**A9.2** — The principle is that **the metering system is itself a metered service** — AWS applies its own consumption model consistently rather than exempting its management plane. Practically it means cost tooling must be used deliberately: a dashboard polling `GetCostAndUsage` every minute generates a real bill, and this genuinely happens. Cost Explorer requests are $0.01 each; use Cost and Usage Reports (delivered to S3) for high-frequency analysis instead.
Other per-call-billed APIs include **AWS Config** rule evaluations and configuration items, **CloudTrail data events** and **Insights**, **KMS** API requests (including every decrypt), and **Secrets Manager** `GetSecretValue`. The KMS one is the classic surprise: an application decrypting a secret on every request generates a per-request KMS charge.

**A9.3** — It changes the conversation from **allocation argument** to **measurement**. With an annual data-centre depreciation line, cost is a single opaque number apportioned to teams by negotiated percentages, so engineers cannot see the cost of their own decisions and have no feedback loop; optimisation is a once-a-year finance exercise disconnected from the people who could act on it.
With per-service, per-hour, per-tag visibility, cost becomes an **engineering metric like latency or error rate**. A team can see that a particular query pattern added $400/month, or that a NAT Gateway is costing more than the workload behind it, and can act within a sprint rather than a budget cycle. This is the foundation of FinOps and of the Well-Architected **Cost Optimization** pillar: the expenditure signal is fine-grained enough and fast enough to close the loop with the person who wrote the code. That feedback loop, not the unit price, is the durable financial benefit of the cloud.

---

### Block 10

**A10.1** — A security group cannot be deleted while any **elastic network interface** still references it. When you delete an ASG or a load balancer, the API returns success as soon as the *deletion has been initiated* — the underlying instances are still terminating and the ALB's ENIs still exist, sometimes for several minutes after the resource disappears from the console.
The general lesson: **cloud resource deletion is asynchronous and dependency-ordered.** A successful API response means "accepted", not "completed". Correct teardown therefore requires waiting on terminal state (`aws ... wait ...`), deleting in reverse dependency order, and retrying dependent deletions rather than treating the first failure as fatal. This is exactly why declarative infrastructure-as-code exists — CloudFormation and Terraform build the dependency graph and walk it in reverse for you, which is why the teardown of Exercise 5's stack was a single command and this one was six.

**A10.2** — Ranked by approximate hourly cost, highest first:
1. **Application Load Balancer** — ~$0.0225/hour plus LCU charges, billed continuously **whether or not any traffic flows**. This is the classic forgotten resource: it looks idle and costs ~$16/month doing nothing.
2. **EC2 instances** — 2–4 × `t3.micro` at ~$0.0104/hour each, so $0.021–$0.042/hour.
3. **EBS root volumes** — ~8 GiB gp3 per instance, roughly $0.0009/hour each. Small, but note these **survive instance termination if `DeleteOnTermination` is false**, and orphaned volumes are the single most common source of accumulated waste in real accounts.
4. **S3 bucket** — empty, so effectively $0.00.
5. **Auto Scaling group, launch template, target group, security group, budget** — $0.00; these are control-plane objects, not billable resources. (Budgets beyond the first two are $0.02/day.)
Total if abandoned: roughly **$0.06/hour ≈ $43/month** for a lab that served no users.

**A10.3** — The mechanism is **CloudFormation** (or CDK/Terraform): `delete-stack` removes every resource in the stack in correct dependency order, in one command, with no possibility of orphaning something you forgot to list.
It did not apply to the ALB/ASG stack because that stack was built **imperatively**, resource by resource through individual CLI calls. Nothing recorded the relationships between the security group, launch template, target group, load balancer, listener and Auto Scaling group, so the teardown had to reconstruct that dependency graph by hand — which is precisely where resources get orphaned in real accounts. The exercise was built imperatively on purpose, so that each API call and its cost were visible; **production infrastructure should not be.** The rule: if a resource is billable and long-lived, it belongs in a stack, because the value of infrastructure-as-code shows up as much at deletion time as at creation time.

</details>

---

## References

- AWS Certified Cloud Practitioner (CLF-C02) Exam Guide — <https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf>
- Six Advantages of Cloud Computing — <https://docs.aws.amazon.com/whitepapers/latest/aws-overview/six-advantages-of-cloud-computing.html>
- AWS Global Infrastructure — <https://aws.amazon.com/about-aws/global-infrastructure/>
- Regions and Availability Zones (EC2 User Guide) — <https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/using-regions-availability-zones.html>
- Availability Zone IDs — <https://docs.aws.amazon.com/ram/latest/userguide/working-with-az-ids.html>
- Public parameters for global infrastructure — <https://docs.aws.amazon.com/systems-manager/latest/userguide/parameter-store-public-parameters-global-infrastructure.html>
- Shared Responsibility Model — <https://aws.amazon.com/compliance/shared-responsibility-model/>
- Price List Query API (`GetProducts`) — <https://docs.aws.amazon.com/aws-cost-management/latest/APIReference/API_pricing_GetProducts.html>
- Savings Plans User Guide — <https://docs.aws.amazon.com/savingsplans/latest/userguide/what-is-savings-plans.html>
- Target tracking scaling policies — <https://docs.aws.amazon.com/autoscaling/ec2/userguide/as-scaling-target-tracking.html>
- Auto Scaling health checks — <https://docs.aws.amazon.com/autoscaling/ec2/userguide/ec2-auto-scaling-health-checks.html>
- Burstable performance instances — <https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/burstable-performance-instances.html>
- Application Load Balancer — <https://docs.aws.amazon.com/elasticloadbalancing/latest/application/introduction.html>
- Instance Metadata Service v2 — <https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/configuring-instance-metadata-service.html>
- AWS CloudFormation User Guide — <https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/Welcome.html>
- Managing costs with AWS Budgets — <https://docs.aws.amazon.com/cost-management/latest/userguide/budgets-managing-costs.html>
- Cost Explorer `GetCostAndUsage` — <https://docs.aws.amazon.com/aws-cost-management/latest/APIReference/API_GetCostAndUsage.html>
- AWS Compute Optimizer — <https://docs.aws.amazon.com/compute-optimizer/latest/ug/what-is-compute-optimizer.html>
- Well-Architected Framework, Reliability Pillar — <https://docs.aws.amazon.com/wellarchitected/latest/reliability-pillar/welcome.html>
- Amazon CloudFront features (edge network) — <https://aws.amazon.com/cloudfront/features/>
- AWS Free Tier — <https://aws.amazon.com/free/>