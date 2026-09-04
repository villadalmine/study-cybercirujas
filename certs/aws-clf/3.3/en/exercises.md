# Topic 3.3 — Identify AWS Compute Services
## Guided exercises · AWS Certified Cloud Practitioner (CLF-C02, v1.0)

**Domain 3 — Cloud Technology and Services · Task Statement 3.3 · Exam weight: 4.25%**

> Exam guide reference: <https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf>

The exam asks you to *identify* compute services — but identification without mechanics is memorization that evaporates under a reworded question. These exercises make you touch the control plane, read the actual API responses, and observe *why* each service exists as a distinct product. Every block ends with checkpoint questions; the answer key is collapsed at the bottom.

---

## Before you start

### Prerequisites

| Requirement | Check |
|---|---|
| AWS account with console + programmatic access | `aws sts get-caller-identity` |
| AWS CLI v2 (v1 lacks several flags used here) | `aws --version` → `aws-cli/2.x.x` |
| `jq` (optional, for readability) | `jq --version` |
| A region pinned for the whole session | `export AWS_REGION=us-east-1` |

### Cost guardrails — read this before running anything

Most exercises here are **describe-only** (read APIs, zero cost). Blocks that create billable resources are marked **💸 CREATES BILLABLE RESOURCES** and always end with a teardown step.

The AWS Free Tier terms have changed over time (legacy 12-month tier vs. the credit-based plan for newer accounts). **Do not assume anything is free** — verify your account's current tier at <https://aws.amazon.com/free/> and in Billing → Free Tier.

Set a budget alarm first:

```bash
export AWS_REGION=us-east-1
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

cat > /tmp/budget.json <<'JSON'
{
  "BudgetName": "clf-33-compute-lab",
  "BudgetLimit": { "Amount": "5", "Unit": "USD" },
  "TimeUnit": "MONTHLY",
  "BudgetType": "COST"
}
JSON

aws budgets create-budget \
  --account-id "$ACCOUNT_ID" \
  --budget file:///tmp/budget.json
```

Tag everything you create with `Project=clf-33-lab` so the teardown greps are reliable.

---

## Exercise 1 — Map the EC2 instance-type namespace

Amazon EC2 is the IaaS primitive: you rent a virtual machine and own everything above the hypervisor. The exam does not ask you to size instances, but it *does* ask you to match a workload description ("memory-intensive in-memory database") to a family. That mapping is machine-readable — you never have to guess.

### Steps

1. **Decode the naming convention on a real type.** Query the API for a modern Graviton instance:

   ```bash
   aws ec2 describe-instance-types \
     --instance-types m7gd.2xlarge \
     --query 'InstanceTypes[0].{
        Type:InstanceType,
        vCPU:VCpuInfo.DefaultVCpus,
        Cores:VCpuInfo.DefaultCores,
        ThreadsPerCore:VCpuInfo.DefaultThreadsPerCore,
        MemoryMiB:MemoryInfo.SizeInMiB,
        Arch:ProcessorInfo.SupportedArchitectures,
        Hypervisor:Hypervisor,
        InstanceStorage:InstanceStorageInfo.TotalSizeInGB,
        Network:NetworkInfo.NetworkPerformance}' \
     --output table
   ```

   Expected output (values are stable for this type):

   ```
   -------------------------------------------------
   |             DescribeInstanceTypes             |
   +------------------+----------------------------+
   |  Arch            |  arm64                     |
   |  Cores           |  8                         |
   |  Hypervisor      |  nitro                     |
   |  InstanceStorage |  475                       |
   |  MemoryMiB       |  32768                     |
   |  Network         |  Up to 15 Gigabit          |
   |  ThreadsPerCore  |  1                         |
   |  Type            |  m7gd.2xlarge              |
   |  vCPU            |  8                         |
   +------------------+----------------------------+
   ```

   Read the name left to right: **`m`** = general-purpose family · **`7`** = 7th generation · **`g`** = AWS Graviton processor · **`d`** = local NVMe instance store · **`2xlarge`** = size. Reference: <https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/instance-type-names.html>

2. **Compare the four workload archetypes side by side.** One representative per family category:

   ```bash
   aws ec2 describe-instance-types \
     --instance-types m7i.xlarge c7i.xlarge r7i.xlarge i4i.xlarge \
     --query 'sort_by(InstanceTypes, &InstanceType)[].{
        Type:InstanceType,
        vCPU:VCpuInfo.DefaultVCpus,
        MemGiB:MemoryInfo.SizeInMiB,
        LocalNVMeGB:InstanceStorageInfo.TotalSizeInGB}' \
     --output table
   ```

   ```
   ----------------------------------------------------------
   |                  DescribeInstanceTypes                 |
   +---------------+--------+-------------+-----------------+
   |     Type      | vCPU   |   MemGiB    |  LocalNVMeGB    |
   +---------------+--------+-------------+-----------------+
   |  c7i.xlarge   |  4     |  8192       |  None           |
   |  i4i.xlarge   |  4     |  32768      |  937            |
   |  m7i.xlarge   |  4     |  16384      |  None           |
   |  r7i.xlarge   |  4     |  32768      |  None           |
   +---------------+--------+-------------+-----------------+
   ```

   Same vCPU count, four different memory-to-vCPU ratios (2:1, 4:1, 8:1) and one with local NVMe. **The family letter is a ratio, not a speed grade.**

3. **Filter by capability rather than by name.** This is how you'd actually answer "which types are ARM and burstable?":

   ```bash
   aws ec2 describe-instance-types \
     --filters Name=processor-info.supported-architecture,Values=arm64 \
               Name=burstable-performance-supported,Values=true \
     --query 'InstanceTypes[].InstanceType' --output text | tr '\t' '\n' | sort
   ```

   ```
   t4g.2xlarge
   t4g.large
   t4g.medium
   t4g.micro
   t4g.nano
   t4g.small
   t4g.xlarge
   ```

4. **Confirm that instance types are not uniformly available.** Regional and AZ availability differs — this is a real production constraint:

   ```bash
   aws ec2 describe-instance-type-offerings \
     --location-type availability-zone \
     --filters Name=instance-type,Values=c7g.large \
     --query 'InstanceTypeOfferings[].Location' --output text
   ```

   ```
   us-east-1a	us-east-1b	us-east-1c	us-east-1d	us-east-1f
   ```

   Note the absence of `us-east-1e` — a real gap in that Region for several modern families.

5. **Find the bare-metal types** and observe that they exist at all:

   ```bash
   aws ec2 describe-instance-types \
     --filters Name=bare-metal,Values=true \
     --query 'length(InstanceTypes)'
   ```

### Checkpoint — Exercise 1

- **Q1.1** In `c6gn.8xlarge`, what does each of `c`, `6`, `g`, `n`, and `8xlarge` mean?
- **Q1.2** A workload is an in-memory analytics cache that needs 200 GiB of RAM but very little CPU. Which family category do you pick, and why is a compute-optimized instance the wrong answer even if you make it big enough?
- **Q1.3** `m7gd.2xlarge` reported `ThreadsPerCore: 1` while an equivalent Intel type reports `2`. What does "vCPU" therefore mean on Graviton versus Intel/AMD?
- **Q1.4** A student claims "bare metal instances aren't really EC2, they're a different service." Correct them.
- **Q1.5** Why does the presence of `d` in the instance name change your durability planning?

---

## Exercise 2 — Launch an instance and interrogate it from the inside

**💸 CREATES BILLABLE RESOURCES** (one `t3.micro`, a security group, a key pair). Teardown is step 9.

### Steps

1. **Resolve the current Amazon Linux 2023 AMI from SSM Parameter Store** — never hardcode an AMI ID, they are Region-specific and rotate:

   ```bash
   AMI_ID=$(aws ssm get-parameter \
     --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
     --query 'Parameter.Value' --output text)
   echo "$AMI_ID"
   ```

   ```
   ami-0abcdef1234567890
   ```

2. **Create a security group with no inbound rules.** You will not SSH in — you will use SSM Session Manager, which needs zero open ports:

   ```bash
   VPC_ID=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true \
     --query 'Vpcs[0].VpcId' --output text)

   SG_ID=$(aws ec2 create-security-group \
     --group-name clf33-nosg --description "CLF 3.3 lab, egress only" \
     --vpc-id "$VPC_ID" --query GroupId --output text)
   echo "$SG_ID"
   ```

3. **Create an instance profile that allows SSM.** (If `AmazonSSMRoleForInstancesQuickSetup` or a similar role already exists, reuse it.)

   ```bash
   cat > /tmp/trust.json <<'JSON'
   {"Version":"2012-10-17","Statement":[{"Effect":"Allow",
    "Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}
   JSON

   aws iam create-role --role-name clf33-ssm-role \
     --assume-role-policy-document file:///tmp/trust.json >/dev/null

   aws iam attach-role-policy --role-name clf33-ssm-role \
     --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore

   aws iam create-instance-profile --instance-profile-name clf33-ssm-profile >/dev/null
   aws iam add-role-to-instance-profile \
     --instance-profile-name clf33-ssm-profile --role-name clf33-ssm-role
   ```

4. **Launch with user data and IMDSv2 enforced.** User data is the bootstrap hook — this is what makes an instance reproducible instead of hand-built:

   ```bash
   cat > /tmp/userdata.sh <<'EOF'
   #!/bin/bash
   dnf install -y stress-ng >/dev/null 2>&1
   echo "bootstrapped at $(date -Is)" > /var/log/clf33-bootstrap.log
   EOF

   INSTANCE_ID=$(aws ec2 run-instances \
     --image-id "$AMI_ID" \
     --instance-type t3.micro \
     --security-group-ids "$SG_ID" \
     --iam-instance-profile Name=clf33-ssm-profile \
     --metadata-options "HttpTokens=required,HttpPutResponseHopLimit=1,HttpEndpoint=enabled" \
     --user-data file:///tmp/userdata.sh \
     --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=clf33-lab},{Key=Project,Value=clf-33-lab}]' \
     --query 'Instances[0].InstanceId' --output text)

   aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"
   echo "$INSTANCE_ID is running"
   ```

5. **Watch the lifecycle state transitions** — `pending` → `running` → (`stopping` → `stopped`) → `shutting-down` → `terminated`:

   ```bash
   aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
     --query 'Reservations[0].Instances[0].{
        State:State.Name,Type:InstanceType,AZ:Placement.AvailabilityZone,
        PrivateIp:PrivateIpAddress,Lifecycle:InstanceLifecycle,
        Hypervisor:Hypervisor,Launch:LaunchTime}' --output table
   ```

   ```
   ------------------------------------------------------
   |                  DescribeInstances                 |
   +-------------+--------------------------------------+
   |  AZ         |  us-east-1b                          |
   |  Hypervisor |  xen                                 |
   |  Launch     |  2026-09-04T13:41:08+00:00           |
   |  Lifecycle  |  None                                |
   |  PrivateIp  |  172.31.24.117                       |
   |  State      |  running                             |
   |  Type       |  t3.micro                            |
   +-------------+--------------------------------------+
   ```

   > `Hypervisor: xen` is a long-standing API reporting quirk for some Nitro-backed types; `describe-instance-types` is the authoritative source and reports `nitro` for `t3`. `Lifecycle: None` means On-Demand — a Spot instance would report `spot`.

6. **Open a shell without SSH** (wait ~60 s after `running` for the SSM agent to register):

   ```bash
   aws ssm start-session --target "$INSTANCE_ID"
   ```

7. **Inside the instance, query the Instance Metadata Service using IMDSv2.** Because you launched with `HttpTokens=required`, the unauthenticated IMDSv1 call must fail:

   ```bash
   # This MUST fail — IMDSv1 is disabled
   curl -s --max-time 3 -o /dev/null -w '%{http_code}\n' \
     http://169.254.169.254/latest/meta-data/instance-id
   ```

   ```
   401
   ```

   Now the session-oriented IMDSv2 flow:

   ```bash
   TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" \
     -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")

   for k in instance-id instance-type placement/availability-zone \
            placement/region ami-id local-ipv4 services/partition; do
     printf '%-34s %s\n' "$k" \
       "$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
          http://169.254.169.254/latest/meta-data/$k)"
   done
   ```

   ```
   instance-id                        i-0f3c9b1e2a7d45601
   instance-type                      t3.micro
   placement/availability-zone        us-east-1b
   placement/region                   us-east-1
   ami-id                             ami-0abcdef1234567890
   local-ipv4                         172.31.24.117
   services/partition                 aws
   ```

8. **Prove the burstable CPU credit model is real.** `t3` is not "a small server" — it is a server with a *CPU budget*:

   ```bash
   grep -c ^processor /proc/cpuinfo      # 2 vCPUs
   cat /var/log/clf33-bootstrap.log      # user data ran
   stress-ng --cpu 2 --timeout 120s --metrics-brief
   exit
   ```

   Back on your workstation, read the credit balance from CloudWatch:

   ```bash
   aws cloudwatch get-metric-statistics \
     --namespace AWS/EC2 --metric-name CPUCreditBalance \
     --dimensions Name=InstanceId,Value="$INSTANCE_ID" \
     --start-time "$(date -u -d '30 minutes ago' +%Y-%m-%dT%H:%M:%SZ)" \
     --end-time   "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
     --period 300 --statistics Average \
     --query 'sort_by(Datapoints,&Timestamp)[].{T:Timestamp,Credits:Average}' \
     --output table
   ```

   Also check the credit specification — `T3` defaults to **unlimited** mode, `T2` to **standard**:

   ```bash
   aws ec2 describe-instance-credit-specifications --instance-ids "$INSTANCE_ID" \
     --query 'InstanceCreditSpecifications[0]' --output table
   ```

   ```
   ---------------------------------------------
   |  InstanceCreditSpecifications             |
   +----------------+--------------------------+
   |  CpuCredits    |  unlimited               |
   |  InstanceId    |  i-0f3c9b1e2a7d45601     |
   +----------------+--------------------------+
   ```

9. **Teardown:**

   ```bash
   aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" >/dev/null
   aws ec2 wait instance-terminated --instance-ids "$INSTANCE_ID"
   aws ec2 delete-security-group --group-id "$SG_ID"
   aws iam remove-role-from-instance-profile \
     --instance-profile-name clf33-ssm-profile --role-name clf33-ssm-role
   aws iam delete-instance-profile --instance-profile-name clf33-ssm-profile
   aws iam detach-role-policy --role-name clf33-ssm-role \
     --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
   aws iam delete-role --role-name clf33-ssm-role
   ```

### Checkpoint — Exercise 2

- **Q2.1** You opened a shell on an instance whose security group has **zero** inbound rules. Explain the mechanism, and what that implies for the shared responsibility model.
- **Q2.2** The IMDSv1 call returned `401` and IMDSv2 succeeded. What class of attack does `HttpTokens=required` plus `HttpPutResponseHopLimit=1` defend against?
- **Q2.3** An instance is `stopped` for a week. Which of these do you keep paying for: vCPU/RAM, the EBS root volume, the private IPv4 address, an attached Elastic IP?
- **Q2.4** What is the difference between an **AMI** and an **EBS snapshot**, and which one is the "golden image" in a launch pipeline?
- **Q2.5** Your `t3.micro` is in `unlimited` mode and runs at 100% CPU for 10 hours. What happens to (a) performance and (b) the bill? How would `standard` mode differ?
- **Q2.6** User data ran once at first boot. Name two things you must guarantee about a user-data script for it to be safe in an Auto Scaling group.

---

## Exercise 3 — Purchasing options: the same instance, five prices

This is the highest-yield block for the exam. On CLF-C02, "compute" questions are frequently *pricing-model* questions in disguise.

### Steps

1. **Get the real On-Demand price from the Pricing API** (the Pricing API is only exposed in `us-east-1` and `ap-south-1`):

   ```bash
   aws pricing get-products --region us-east-1 \
     --service-code AmazonEC2 \
     --filters \
       'Type=TERM_MATCH,Field=instanceType,Value=m6i.large' \
       'Type=TERM_MATCH,Field=regionCode,Value=us-east-1' \
       'Type=TERM_MATCH,Field=operatingSystem,Value=Linux' \
       'Type=TERM_MATCH,Field=tenancy,Value=Shared' \
       'Type=TERM_MATCH,Field=preInstalledSw,Value=NA' \
       'Type=TERM_MATCH,Field=capacitystatus,Value=Used' \
     --max-results 1 --output json \
   | jq -r '.PriceList[0]' | jq -r '
       .terms.OnDemand | to_entries[0].value.priceDimensions
       | to_entries[0].value | "\(.pricePerUnit.USD) USD per \(.unit)"'
   ```

   ```
   0.0960000000 USD per Hrs
   ```

2. **Get the Spot price for the same type across AZs:**

   ```bash
   aws ec2 describe-spot-price-history \
     --instance-types m6i.large \
     --product-descriptions "Linux/UNIX" \
     --start-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
     --query 'sort_by(SpotPriceHistory,&AvailabilityZone)[].{AZ:AvailabilityZone,Price:SpotPrice}' \
     --output table
   ```

   ```
   ----------------------------------
   |    DescribeSpotPriceHistory    |
   +----------------+---------------+
   |       AZ       |    Price      |
   +----------------+---------------+
   |  us-east-1a    |  0.032100     |
   |  us-east-1b    |  0.029900     |
   |  us-east-1c    |  0.036500     |
   |  us-east-1d    |  0.030200     |
   +----------------+---------------+
   ```

   Compute the discount yourself: `0.0299 / 0.0960 ≈ 31%` of On-Demand — a ~69% saving *at this moment, in this AZ*. Spot prices move with spare-capacity supply.

3. **Ask AWS where Spot capacity is actually deep.** The Spot placement score is a 1–10 signal, not a price:

   ```bash
   aws ec2 get-spot-placement-scores \
     --instance-types m6i.large m6a.large m5.large \
     --target-capacity 500 \
     --target-capacity-unit-type units \
     --region-names us-east-1 us-west-2 eu-west-1 \
     --query 'SpotPlacementScores[].{Region:Region,Score:Score}' \
     --output table
   ```

   ```
   ------------------------------
   |  GetSpotPlacementScores    |
   +---------------+------------+
   |    Region     |   Score    |
   +---------------+------------+
   |  us-west-2    |  9         |
   |  us-east-1    |  7         |
   |  eu-west-1    |  6         |
   +---------------+------------+
   ```

4. **Inspect the interruption contract.** On a *running Spot instance*, the two-minute warning appears as a metadata path that returns `404` until the interruption is scheduled:

   ```bash
   # run this ON a Spot instance
   TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" \
     -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
   curl -s -o /dev/null -w '%{http_code}\n' \
     -H "X-aws-ec2-metadata-token: $TOKEN" \
     http://169.254.169.254/latest/meta-data/spot/instance-action
   ```

   ```
   404      # healthy — no interruption scheduled
   ```

   When AWS reclaims capacity it becomes `200` with a body like:

   ```json
   {"action": "terminate", "time": "2026-09-04T14:12:00Z"}
   ```

5. **Enumerate your commitment-based coverage** (empty in a fresh account — the point is to see the two distinct services):

   ```bash
   aws ec2 describe-reserved-instances \
     --query 'ReservedInstances[].{Type:InstanceType,Offering:OfferingClass,Scope:Scope,Count:InstanceCount,End:End}' \
     --output table

   aws savingsplans describe-savings-plans --region us-east-1 \
     --query 'savingsPlans[].{Type:savingsPlanType,Commit:commitment,Term:termDurationInSeconds,State:state}' \
     --output table
   ```

6. **Distinguish tenancy models:**

   ```bash
   aws ec2 describe-hosts --query 'Hosts[].{Id:HostId,Family:HostProperties.InstanceFamily,
     Sockets:HostProperties.Sockets,Cores:HostProperties.Cores,State:State}' --output table
   ```

   A **Dedicated Host** exposes sockets and physical cores — that visibility is exactly what per-socket / per-core software licensing (BYOL) requires. A **Dedicated Instance** gives you hardware isolation without that visibility.

7. **Build the comparison table yourself** before reading the answer key. Fill in: *discount ceiling · commitment · flexibility · interruption risk · typical workload.*

References:
<https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/instance-purchasing-options.html> ·
<https://docs.aws.amazon.com/savingsplans/latest/userguide/what-is-savings-plans.html> ·
<https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/using-spot-instances.html>

### Checkpoint — Exercise 3

- **Q3.1** A batch video-transcoding pipeline runs nightly, is checkpointed, and can restart any job. Which purchasing option, and what is the single architectural requirement it imposes on the application?
- **Q3.2** A company will run *some* steady compute for three years but expects to migrate from `m5` to `m7g` and from EC2 to Fargate midway. Standard RI, Convertible RI, EC2 Instance Savings Plan, or Compute Savings Plan?
- **Q3.3** What does a Spot **placement score of 9** tell you, and what does it explicitly *not* tell you?
- **Q3.4** A Savings Plan is a commitment to what unit — instance hours, or dollars per hour of usage? Why does that distinction change the flexibility story?
- **Q3.5** Your Oracle license is bound to physical CPU sockets. Dedicated Instance or Dedicated Host? Justify with what step 6 showed.
- **Q3.6** An On-Demand Capacity Reservation and a Reserved Instance are frequently confused. Which one guarantees *capacity* and which one guarantees *a price*?

---

## Exercise 4 — Elasticity: Auto Scaling and Elastic Load Balancing

**💸 CREATES BILLABLE RESOURCES** (an ALB, plus 2 instances). An ALB has an hourly charge with no free tier for most accounts. Teardown is step 8; total runtime should be well under an hour.

Auto Scaling and ELB are two halves of one idea: **capacity that tracks demand, behind a stable endpoint.**

### Steps

1. **Create a launch template** — the modern, versioned replacement for launch configurations:

   ```bash
   AMI_ID=$(aws ssm get-parameter \
     --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
     --query 'Parameter.Value' --output text)
   VPC_ID=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)
   SUBNETS=$(aws ec2 describe-subnets --filters Name=vpc-id,Values=$VPC_ID \
     --query 'Subnets[0:2].SubnetId' --output text | tr '\t' ',')

   ALB_SG=$(aws ec2 create-security-group --group-name clf33-alb-sg \
     --description "ALB ingress 80" --vpc-id $VPC_ID --query GroupId --output text)
   aws ec2 authorize-security-group-ingress --group-id $ALB_SG \
     --protocol tcp --port 80 --cidr 0.0.0.0/0 >/dev/null

   APP_SG=$(aws ec2 create-security-group --group-name clf33-app-sg \
     --description "from ALB only" --vpc-id $VPC_ID --query GroupId --output text)
   aws ec2 authorize-security-group-ingress --group-id $APP_SG \
     --protocol tcp --port 80 --source-group $ALB_SG >/dev/null

   USERDATA=$(base64 -w0 <<'EOF'
   #!/bin/bash
   dnf install -y nginx
   TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
   ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
   AZ=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/availability-zone)
   echo "served by $ID in $AZ" > /usr/share/nginx/html/index.html
   systemctl enable --now nginx
   EOF
   )

   aws ec2 create-launch-template \
     --launch-template-name clf33-lt \
     --launch-template-data "{
       \"ImageId\":\"$AMI_ID\",
       \"InstanceType\":\"t3.micro\",
       \"SecurityGroupIds\":[\"$APP_SG\"],
       \"UserData\":\"$USERDATA\",
       \"MetadataOptions\":{\"HttpTokens\":\"required\"},
       \"TagSpecifications\":[{\"ResourceType\":\"instance\",
         \"Tags\":[{\"Key\":\"Project\",\"Value\":\"clf-33-lab\"}]}]
     }" --query 'LaunchTemplate.{Name:LaunchTemplateName,Version:LatestVersionNumber}' --output table
   ```

2. **Create the Application Load Balancer and target group:**

   ```bash
   ALB_ARN=$(aws elbv2 create-load-balancer --name clf33-alb --type application \
     --scheme internet-facing --security-groups $ALB_SG \
     --subnets $(echo $SUBNETS | tr ',' ' ') \
     --query 'LoadBalancers[0].LoadBalancerArn' --output text)

   TG_ARN=$(aws elbv2 create-target-group --name clf33-tg \
     --protocol HTTP --port 80 --vpc-id $VPC_ID --target-type instance \
     --health-check-path / --health-check-interval-seconds 15 \
     --healthy-threshold-count 2 --unhealthy-threshold-count 2 \
     --query 'TargetGroups[0].TargetGroupArn' --output text)

   aws elbv2 create-listener --load-balancer-arn $ALB_ARN \
     --protocol HTTP --port 80 \
     --default-actions Type=forward,TargetGroupArn=$TG_ARN >/dev/null
   ```

3. **Create the Auto Scaling group wired to the target group:**

   ```bash
   aws autoscaling create-auto-scaling-group \
     --auto-scaling-group-name clf33-asg \
     --launch-template LaunchTemplateName=clf33-lt,Version='$Latest' \
     --min-size 2 --max-size 4 --desired-capacity 2 \
     --vpc-zone-identifier "$SUBNETS" \
     --target-group-arns "$TG_ARN" \
     --health-check-type ELB --health-check-grace-period 90 \
     --tags "Key=Project,Value=clf-33-lab,PropagateAtLaunch=true"
   ```

4. **Attach a target-tracking scaling policy.** This is the policy type the exam expects you to recognize as "keep metric X at value Y":

   ```bash
   aws autoscaling put-scaling-policy \
     --auto-scaling-group-name clf33-asg \
     --policy-name cpu-at-50 \
     --policy-type TargetTrackingScaling \
     --target-tracking-configuration '{
       "PredefinedMetricSpecification": {"PredefinedMetricType":"ASGAverageCPUUtilization"},
       "TargetValue": 50.0
     }' --query 'PolicyARN' --output text
   ```

5. **Watch it converge:**

   ```bash
   aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names clf33-asg \
     --query 'AutoScalingGroups[0].{Min:MinSize,Max:MaxSize,Desired:DesiredCapacity,
        Instances:Instances[].{Id:InstanceId,AZ:AvailabilityZone,
        Lifecycle:LifecycleState,Health:HealthStatus}}' --output json
   ```

   ```json
   {
     "Min": 2, "Max": 4, "Desired": 2,
     "Instances": [
       {"Id":"i-01a2b3c4d5e6f7080","AZ":"us-east-1a","Lifecycle":"InService","Health":"Healthy"},
       {"Id":"i-090807060504030a2","AZ":"us-east-1b","Lifecycle":"InService","Health":"Healthy"}
     ]
   }
   ```

6. **Verify the load balancer distributes across AZs:**

   ```bash
   DNS=$(aws elbv2 describe-load-balancers --load-balancer-arns $ALB_ARN \
     --query 'LoadBalancers[0].DNSName' --output text)
   for i in $(seq 1 8); do curl -s "http://$DNS/"; done
   ```

   ```
   served by i-01a2b3c4d5e6f7080 in us-east-1a
   served by i-090807060504030a2 in us-east-1b
   served by i-01a2b3c4d5e6f7080 in us-east-1a
   served by i-090807060504030a2 in us-east-1b
   ...
   ```

7. **Prove self-healing.** Terminate one instance and watch the ASG replace it:

   ```bash
   VICTIM=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names clf33-asg \
     --query 'AutoScalingGroups[0].Instances[0].InstanceId' --output text)
   aws ec2 terminate-instances --instance-ids $VICTIM >/dev/null
   sleep 90
   aws autoscaling describe-scaling-activities --auto-scaling-group-name clf33-asg \
     --max-items 3 --query 'Activities[].{Status:StatusCode,Cause:Description}' --output table
   ```

   ```
   ---------------------------------------------------------------------
   |                    DescribeScalingActivities                      |
   +-------------+-----------------------------------------------------+
   |  Successful |  Launching a new EC2 instance: i-0aa11bb22cc33dd44   |
   |  Successful |  Terminating EC2 instance: i-01a2b3c4d5e6f7080      |
   +-------------+-----------------------------------------------------+
   ```

8. **Teardown (do this promptly):**

   ```bash
   aws autoscaling delete-auto-scaling-group --auto-scaling-group-name clf33-asg --force-delete
   sleep 60
   aws elbv2 delete-listener --listener-arn \
     $(aws elbv2 describe-listeners --load-balancer-arn $ALB_ARN --query 'Listeners[0].ListenerArn' --output text)
   aws elbv2 delete-load-balancer --load-balancer-arn $ALB_ARN
   sleep 30
   aws elbv2 delete-target-group --target-group-arn $TG_ARN
   aws ec2 delete-launch-template --launch-template-name clf33-lt
   aws ec2 delete-security-group --group-id $APP_SG
   aws ec2 delete-security-group --group-id $ALB_SG
   ```

References: <https://docs.aws.amazon.com/autoscaling/ec2/userguide/what-is-amazon-ec2-auto-scaling.html> · <https://docs.aws.amazon.com/elasticloadbalancing/latest/userguide/what-is-load-balancing.html>

### Checkpoint — Exercise 4

- **Q4.1** Name the four AWS Well-Architected benefits the ASG delivered in this exercise, and identify which one step 7 demonstrated specifically.
- **Q4.2** You set `--health-check-type ELB` instead of the default `EC2`. What failure does `EC2` health checking miss?
- **Q4.3** Match each to its OSI layer and primary use: Application Load Balancer, Network Load Balancer, Gateway Load Balancer.
- **Q4.4** Distinguish **Amazon EC2 Auto Scaling** from **AWS Auto Scaling** / Application Auto Scaling. Give one non-EC2 resource that the latter scales.
- **Q4.5** Name the four EC2 Auto Scaling policy types and give a one-line scenario for each.
- **Q4.6** Is horizontal scaling the same as vertical scaling? Which one did this exercise perform, and which one requires a restart?

---

## Exercise 5 — Containers: ECR, ECS, Fargate, EKS

**💸 CREATES BILLABLE RESOURCES** (an ECR repository, one short-lived Fargate task). Teardown is step 8.

The exam distinction is: **ECS/EKS = orchestrator** (what runs where), **Fargate/EC2 = launch type** (whose machine it runs on), **ECR = registry** (where the image lives). These are three orthogonal axes and questions routinely conflate them.

### Steps

1. **Create a private ECR repository with scan-on-push:**

   ```bash
   aws ecr create-repository --repository-name clf33/hello \
     --image-scanning-configuration scanOnPush=true \
     --image-tag-mutability IMMUTABLE \
     --query 'repository.{Uri:repositoryUri,Tag:imageTagMutability}' --output table
   ```

   ```
   ---------------------------------------------------------------------------
   |                            CreateRepository                             |
   +-----------+-------------------------------------------------------------+
   |  Tag      |  IMMUTABLE                                                  |
   |  Uri      |  111122223333.dkr.ecr.us-east-1.amazonaws.com/clf33/hello   |
   +-----------+-------------------------------------------------------------+
   ```

2. **Authenticate Docker to ECR.** Note that the credential is a short-lived token derived from your IAM identity, not a stored password:

   ```bash
   REPO_URI=$(aws ecr describe-repositories --repository-names clf33/hello \
     --query 'repositories[0].repositoryUri' --output text)

   aws ecr get-login-password --region "$AWS_REGION" \
     | docker login --username AWS --password-stdin "${REPO_URI%%/*}"
   ```

   ```
   Login Succeeded
   ```

3. **Build and push a minimal image:**

   ```bash
   mkdir -p /tmp/clf33 && cd /tmp/clf33
   cat > Dockerfile <<'EOF'
   FROM public.ecr.aws/amazonlinux/amazonlinux:2023
   CMD ["/bin/sh","-c","echo hello from $(uname -m) on Fargate; sleep 20"]
   EOF

   docker build -t "$REPO_URI:1.0.0" .
   docker push "$REPO_URI:1.0.0"

   aws ecr describe-images --repository-name clf33/hello \
     --query 'imageDetails[].{Tags:imageTags,SizeMB:imageSizeInBytes,Pushed:imagePushedAt}' \
     --output table
   ```

4. **Create an ECS cluster.** With Fargate, this is a pure logical grouping — no instances are created:

   ```bash
   aws ecs create-cluster --cluster-name clf33-cluster \
     --capacity-providers FARGATE FARGATE_SPOT \
     --query 'cluster.{Name:clusterName,Status:status,Instances:registeredContainerInstancesCount}' \
     --output table
   ```

   ```
   ------------------------------------------
   |              CreateCluster             |
   +-------------+--------------------------+
   |  Instances  |  0                       |
   |  Name       |  clf33-cluster           |
   |  Status     |  ACTIVE                  |
   +-------------+--------------------------+
   ```

   **`registeredContainerInstancesCount: 0` is the whole point of Fargate.** With the EC2 launch type this number would be the count of instances you patch, scale and pay for by the hour.

5. **Register a task definition** — the declarative unit ECS schedules:

   ```bash
   aws iam create-role --role-name clf33-ecs-exec \
     --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow",
       "Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
   aws iam attach-role-policy --role-name clf33-ecs-exec \
     --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy
   EXEC_ARN=$(aws iam get-role --role-name clf33-ecs-exec --query 'Role.Arn' --output text)

   aws logs create-log-group --log-group-name /ecs/clf33 2>/dev/null

   cat > /tmp/td.json <<JSON
   {
     "family": "clf33-hello",
     "networkMode": "awsvpc",
     "requiresCompatibilities": ["FARGATE"],
     "cpu": "256",
     "memory": "512",
     "runtimePlatform": { "cpuArchitecture": "X86_64", "operatingSystemFamily": "LINUX" },
     "executionRoleArn": "$EXEC_ARN",
     "containerDefinitions": [
       {
         "name": "hello",
         "image": "$REPO_URI:1.0.0",
         "essential": true,
         "logConfiguration": {
           "logDriver": "awslogs",
           "options": {
             "awslogs-group": "/ecs/clf33",
             "awslogs-region": "$AWS_REGION",
             "awslogs-stream-prefix": "hello"
           }
         }
       }
     ]
   }
   JSON

   aws ecs register-task-definition --cli-input-json file:///tmp/td.json \
     --query 'taskDefinition.{Family:family,Rev:revision,Cpu:cpu,Mem:memory}' --output table
   ```

   ```
   -------------------------------------
   |      RegisterTaskDefinition       |
   +----------+------------------------+
   |  Cpu     |  256                   |
   |  Family  |  clf33-hello           |
   |  Mem     |  512                   |
   |  Rev     |  1                     |
   +----------+------------------------+
   ```

   `cpu: 256` is 0.25 vCPU. Fargate accepts only a discrete grid of CPU/memory pairs — try `"cpu":"256","memory":"8192"` and the API rejects it. Grid: <https://docs.aws.amazon.com/AmazonECS/latest/developerguide/task-cpu-memory-error.html>

6. **Run the task on Fargate:**

   ```bash
   VPC_ID=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)
   SUBNET=$(aws ec2 describe-subnets --filters Name=vpc-id,Values=$VPC_ID --query 'Subnets[0].SubnetId' --output text)
   TASK_SG=$(aws ec2 create-security-group --group-name clf33-task-sg \
     --description "egress only" --vpc-id $VPC_ID --query GroupId --output text)

   TASK_ARN=$(aws ecs run-task --cluster clf33-cluster \
     --task-definition clf33-hello \
     --launch-type FARGATE \
     --network-configuration "awsvpcConfiguration={subnets=[$SUBNET],securityGroups=[$TASK_SG],assignPublicIp=ENABLED}" \
     --query 'tasks[0].taskArn' --output text)

   aws ecs wait tasks-stopped --cluster clf33-cluster --tasks "$TASK_ARN"

   aws ecs describe-tasks --cluster clf33-cluster --tasks "$TASK_ARN" \
     --query 'tasks[0].{LastStatus:lastStatus,StopCode:stopCode,
        Cpu:cpu,Memory:memory,Platform:platformVersion,
        Exit:containers[0].exitCode}' --output table
   ```

   ```
   -------------------------------------
   |           DescribeTasks           |
   +--------------+--------------------+
   |  Cpu         |  256               |
   |  Exit        |  0                 |
   |  LastStatus  |  STOPPED           |
   |  Memory      |  512               |
   |  Platform    |  1.4.0             |
   |  StopCode    |  EssentialContainerExited |
   +--------------+--------------------+
   ```

   ```bash
   aws logs tail /ecs/clf33 --since 10m
   ```

   ```
   2026-09-04T14:22:11 hello/hello/8f2c... hello from x86_64 on Fargate
   ```

7. **Compare the orchestrators without deploying EKS** (an EKS control plane bills per hour from creation — do not create one for this lab). Inspect what AWS offers:

   ```bash
   aws eks describe-addon-versions \
     --query 'addons[0:5].{Addon:addonName,Type:type}' --output table

   aws eks list-clusters --query 'clusters' --output text   # expect empty
   ```

   ```
   ----------------------------------------------
   |          DescribeAddonVersions             |
   +--------------------------+-----------------+
   |          Addon           |      Type       |
   +--------------------------+-----------------+
   |  vpc-cni                 |  networking     |
   |  coredns                 |  networking     |
   |  kube-proxy              |  networking     |
   |  aws-ebs-csi-driver      |  storage        |
   |  aws-efs-csi-driver      |  storage        |
   +--------------------------+-----------------+
   ```

   Those add-on names are upstream Kubernetes components. **That is the identifying signal**: EKS runs conformant, upstream Kubernetes; ECS runs an AWS-proprietary scheduler with no Kubernetes API.

8. **Teardown:**

   ```bash
   aws ecs delete-cluster --cluster clf33-cluster >/dev/null
   aws ecr delete-repository --repository-name clf33/hello --force >/dev/null
   aws logs delete-log-group --log-group-name /ecs/clf33
   aws ec2 delete-security-group --group-id $TASK_SG
   aws iam detach-role-policy --role-name clf33-ecs-exec \
     --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy
   aws iam delete-role --role-name clf33-ecs-exec
   aws ecs deregister-task-definition --task-definition clf33-hello:1 >/dev/null
   ```

References: <https://docs.aws.amazon.com/AmazonECS/latest/developerguide/Welcome.html> · <https://docs.aws.amazon.com/AmazonECS/latest/userguide/what-is-fargate.html> · <https://docs.aws.amazon.com/eks/latest/userguide/what-is-eks.html> · <https://docs.aws.amazon.com/AmazonECR/latest/userguide/what-is-ecr.html>

### Checkpoint — Exercise 5

- **Q5.1** The cluster reported `registeredContainerInstancesCount: 0` yet a container ran. Where did it run, and who patches that operating system?
- **Q5.2** Fill in the grid — for each cell, who is responsible for OS patching, capacity scaling and the billing unit:

  | | ECS | EKS |
  |---|---|---|
  | **EC2 launch type** | ? | ? |
  | **Fargate launch type** | ? | ? |

- **Q5.3** A company already runs Kubernetes on-premises with Helm charts and custom operators, and wants minimal rewrite when moving to AWS. ECS or EKS? What is the cost trade-off of that choice?
- **Q5.4** Amazon ECR is described as "a container registry." Which two other AWS compute services from this exercise *consume* it, and name one non-AWS place the same image could run.
- **Q5.5** You set `imageTagMutability: IMMUTABLE`. Why does that matter for reproducibility, and what breaks if a team uses `:latest`?
- **Q5.6** Name the two ECS capacity providers you attached in step 4 and the operational difference between them.

---

## Exercise 6 — Serverless: AWS Lambda

**💸 Negligible cost** (a handful of invocations). Teardown is step 7.

Lambda is the point where you stop provisioning capacity entirely. The exam wants you to recognize its identifying traits: **event-driven, no server management, sub-second billing granularity, hard execution ceiling.**

### Steps

1. **Create the execution role:**

   ```bash
   aws iam create-role --role-name clf33-lambda-role \
     --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow",
       "Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
   aws iam attach-role-policy --role-name clf33-lambda-role \
     --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
   LAMBDA_ROLE=$(aws iam get-role --role-name clf33-lambda-role --query 'Role.Arn' --output text)
   sleep 10   # IAM is eventually consistent
   ```

2. **Write a function that reports its own runtime environment:**

   ```bash
   mkdir -p /tmp/clf33-fn && cd /tmp/clf33-fn
   cat > lambda_function.py <<'PY'
   import json, os, time, multiprocessing

   COLD = True

   def lambda_handler(event, context):
       global COLD
       was_cold, COLD = COLD, False
       burn = int(event.get("burn_ms", 0))
       t0 = time.time()
       while (time.time() - t0) * 1000 < burn:
           pass
       return {
           "cold_start": was_cold,
           "memory_limit_mb": context.memory_limit_in_mb,
           "vcpus_visible": multiprocessing.cpu_count(),
           "remaining_ms": context.get_remaining_time_in_millis(),
           "region": os.environ["AWS_REGION"],
           "runtime": os.environ["AWS_EXECUTION_ENV"],
           "log_stream": context.log_stream_name,
       }
   PY
   zip -q function.zip lambda_function.py
   ```

3. **Deploy it at 128 MB:**

   ```bash
   aws lambda create-function --function-name clf33-introspect \
     --runtime python3.12 --handler lambda_function.lambda_handler \
     --role "$LAMBDA_ROLE" --zip-file fileb://function.zip \
     --memory-size 128 --timeout 30 --architectures arm64 \
     --query '{Name:FunctionName,Mem:MemorySize,Timeout:Timeout,Arch:Architectures,State:State}' \
     --output table
   ```

   ```
   -----------------------------------------
   |             CreateFunction            |
   +-----------+---------------------------+
   |  Arch     |  arm64                    |
   |  Mem      |  128                      |
   |  Name     |  clf33-introspect         |
   |  State    |  Pending                  |
   |  Timeout  |  30                       |
   +-----------+---------------------------+
   ```

4. **Invoke twice and observe the cold/warm distinction:**

   ```bash
   aws lambda wait function-active-v2 --function-name clf33-introspect

   for i in 1 2; do
     aws lambda invoke --function-name clf33-introspect \
       --payload '{"burn_ms":0}' --cli-binary-format raw-in-base64-out \
       --log-type Tail --query 'LogResult' --output text /tmp/out.json | base64 -d | grep REPORT
     cat /tmp/out.json | jq -c '{cold_start,memory_limit_mb,vcpus_visible}'
   done
   ```

   ```
   REPORT RequestId: 3f0e... Duration: 1.42 ms  Billed Duration: 2 ms  Memory Size: 128 MB  Max Memory Used: 39 MB  Init Duration: 118.44 ms
   {"cold_start":true,"memory_limit_mb":128,"vcpus_visible":2}
   REPORT RequestId: a91c... Duration: 0.98 ms  Billed Duration: 1 ms  Memory Size: 128 MB  Max Memory Used: 39 MB
   {"cold_start":false,"memory_limit_mb":128,"vcpus_visible":2}
   ```

   The second invocation has **no `Init Duration`** — the execution environment was reused. That is the cold-start phenomenon, empirically.

5. **Demonstrate that memory is the CPU dial.** In Lambda, CPU is allocated proportionally to memory — you cannot buy them separately:

   ```bash
   for MEM in 128 512 1769 3008; do
     aws lambda update-function-configuration --function-name clf33-introspect \
       --memory-size $MEM >/dev/null
     aws lambda wait function-updated-v2 --function-name clf33-introspect
     printf "MEM=%-5s " "$MEM"
     aws lambda invoke --function-name clf33-introspect \
       --payload '{"burn_ms":2000}' --cli-binary-format raw-in-base64-out \
       --log-type Tail --query 'LogResult' --output text /dev/null \
       | base64 -d | grep -o 'Billed Duration: [0-9]* ms'
   done
   ```

   ```
   MEM=128   Billed Duration: 2001 ms
   MEM=512   Billed Duration: 2001 ms
   MEM=1769  Billed Duration: 2001 ms
   MEM=3008  Billed Duration: 2001 ms
   ```

   A wall-clock busy-loop is memory-independent by design. Now replace the payload with real work (`burn_ms` → a CPU-bound hash) and the durations diverge sharply. At **1,769 MB the function gets exactly one full vCPU**; below that it gets a time-sliced fraction. Reference: <https://docs.aws.amazon.com/lambda/latest/dg/configuration-function-common.html>

6. **Hit the boundaries deliberately.** Each rejection teaches a limit that appears on the exam:

   ```bash
   # a) memory ceiling
   aws lambda update-function-configuration --function-name clf33-introspect --memory-size 10241
   # b) timeout ceiling
   aws lambda update-function-configuration --function-name clf33-introspect --timeout 901
   ```

   ```
   An error occurred (InvalidParameterValueException) when calling the
   UpdateFunctionConfiguration operation: 'memorySize' failed to satisfy constraint:
   Member must have value less than or equal to 10240

   An error occurred (InvalidParameterValueException) when calling the
   UpdateFunctionConfiguration operation: 'timeout' failed to satisfy constraint:
   Member must have value less than or equal to 900
   ```

   And check the concurrency ceiling on the account:

   ```bash
   aws lambda get-account-settings \
     --query 'AccountLimit.{ConcurrentExecutions:ConcurrentExecutions,
       CodeSizeZipped:CodeSizeZipped,CodeSizeUnzipped:CodeSizeUnzipped,
       TotalCodeSizeMB:TotalCodeSize}' --output table
   ```

   ```
   ------------------------------------------------
   |             GetAccountSettings               |
   +------------------------+---------------------+
   |  CodeSizeUnzipped      |  262144000          |
   |  CodeSizeZipped        |  52428800           |
   |  ConcurrentExecutions  |  1000               |
   |  TotalCodeSizeMB       |  80530636800        |
   +------------------------+---------------------+
   ```

7. **Teardown:**

   ```bash
   aws lambda delete-function --function-name clf33-introspect
   aws logs delete-log-group --log-group-name /aws/lambda/clf33-introspect 2>/dev/null
   aws iam detach-role-policy --role-name clf33-lambda-role \
     --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
   aws iam delete-role --role-name clf33-lambda-role
   ```

### Checkpoint — Exercise 6

- **Q6.1** From step 6's error messages, state Lambda's maximum memory, maximum timeout, and default per-Region concurrency limit.
- **Q6.2** A job takes 40 minutes of continuous CPU. Explain why Lambda is architecturally wrong for it and name two AWS compute services that fit.
- **Q6.3** The first invocation showed `Init Duration: 118 ms`, the second showed none. Name the phenomenon and one AWS feature that mitigates it.
- **Q6.4** In Lambda you configure memory but never CPU. Why? What is the significance of the 1,769 MB figure?
- **Q6.5** Lambda bills per GB-second at 1 ms granularity; EC2 bills per second with a 60-second minimum. For a workload receiving 40 requests per day, each 200 ms, which is cheaper and by roughly what order of magnitude?
- **Q6.6** "Serverless means there are no servers." Correct this statement precisely.

---

## Exercise 7 — The managed-abstraction tier

**Describe-only — no billable resources created.**

Between "rent a VM" and "hand AWS a function" sits a band of services that trade control for operational simplicity. The exam tests whether you can pick the *right level of abstraction* for a described team.

### Steps

1. **AWS Elastic Beanstalk — PaaS over EC2 you can still see.** List the runtimes it manages for you:

   ```bash
   aws elasticbeanstalk list-available-solution-stacks \
     --query 'SolutionStacks[?contains(@,`Python`) || contains(@,`Docker`)]' \
     --output text | tr '\t' '\n' | head -8
   ```

   ```
   64bit Amazon Linux 2023 v4.x.x running Python 3.12
   64bit Amazon Linux 2023 v4.x.x running Python 3.11
   64bit Amazon Linux 2023 v4.x.x running Docker
   ...
   ```

   Beanstalk provisions EC2, an ASG, an ELB and CloudWatch alarms *for* you, but leaves them in your account, visible and tunable. **The service itself has no charge — you pay for the resources it creates.**

2. **Amazon Lightsail — bundled VPS pricing.** Compare the mental model to raw EC2:

   ```bash
   aws lightsail get-bundles --region us-east-1 \
     --query 'bundles[?isActive][].{Id:bundleId,USDmo:price,vCPU:cpuCount,
        RamGB:ramSizeInGb,DiskGB:diskSizeInGb,TransferGB:transferPerMonthInGb}' \
     --output table | head -14
   ```

   ```
   --------------------------------------------------------------------------
   |                              GetBundles                                |
   +---------------+--------+--------+---------+----------+-----------------+
   |      Id       | USDmo  | vCPU   | RamGB   | DiskGB   |  TransferGB     |
   +---------------+--------+--------+---------+----------+-----------------+
   |  nano_3_0     |  5.0   |  2     |  0.5    |  20      |  1024           |
   |  micro_3_0    |  7.0   |  2     |  1.0    |  40      |  2048           |
   |  small_3_0    |  12.0  |  2     |  2.0    |  60      |  3072           |
   +---------------+--------+--------+---------+----------+-----------------+
   ```

   **One fixed monthly number** that already includes compute, SSD, a static IP and data transfer. That predictability *is* the product.

3. **AWS Batch — managed batch scheduling.** Inspect the three-object model:

   ```bash
   aws batch describe-compute-environments --query 'computeEnvironments' --output text
   aws batch describe-job-queues            --query 'jobQueues' --output text
   aws batch describe-job-definitions --status ACTIVE --query 'jobDefinitions[].jobDefinitionName' --output text
   ```

   All empty in a fresh account. Read the model rather than build it: a **compute environment** (EC2 On-Demand, EC2 Spot, or Fargate) supplies capacity; a **job queue** holds work with a priority; a **job definition** is the container + resources template. Batch scales the environment from zero to the queue depth and back to zero. Reference: <https://docs.aws.amazon.com/batch/latest/userguide/what-is-batch.html>

4. **AWS App Runner — source or container to HTTPS URL:**

   ```bash
   aws apprunner list-services --region us-east-1 \
     --query 'ServiceSummaryList[].{Name:ServiceName,Status:Status,Url:ServiceUrl}' --output table
   ```

   App Runner takes an ECR image or a GitHub repo and returns a load-balanced, auto-scaling, TLS-terminated HTTPS endpoint. You configure no VPC, no ALB, no ASG, no cluster.

5. **Edge and hybrid compute — where the compute physically sits.** Query the extension points:

   ```bash
   # Local Zones and Wavelength Zones surfaced as special AZ types
   aws ec2 describe-availability-zones --all-availability-zones \
     --query 'AvailabilityZones[?ZoneType!=`availability-zone`].{
        Name:ZoneName,Type:ZoneType,Group:GroupName,Parent:ParentZoneName,
        Opt:OptInStatus}' --output table | head -20
   ```

   ```
   ---------------------------------------------------------------------------------
   |                          DescribeAvailabilityZones                            |
   +-------------------+-------------------+-------------+-----------+-------------+
   |       Name        |       Type        |    Group    |  Parent   |     Opt     |
   +-------------------+-------------------+-------------+-----------+-------------+
   |  us-east-1-atl-1a |  local-zone       |  us-east-1-atl-1 | us-east-1e | not-opted-in |
   |  us-east-1-bos-1a |  local-zone       |  us-east-1-bos-1 | us-east-1a | not-opted-in |
   |  us-east-1-wl1-atl-wlz-1 | wavelength-zone | us-east-1-wl1-atl-1 | us-east-1a | not-opted-in |
   ...
   ```

   ```bash
   aws outposts list-outposts --query 'Outposts[].{Id:OutpostId,Site:SiteId,AZ:AvailabilityZone}' --output table
   ```

   ```
   An error occurred (AccessDeniedException) ... or an empty list — you have no Outposts.
   ```

   The three, precisely:

   | Service | Where the hardware is | Identifying scenario |
   |---|---|---|
   | **AWS Outposts** | Your own data center / colo, AWS-owned racks | Data residency or single-digit-ms to on-prem systems; same APIs |
   | **AWS Local Zones** | AWS metro facility near a population center | Latency-sensitive apps (media, gaming, EDA) in a city with no Region |
   | **AWS Wavelength** | Inside a telecom carrier's 5G network | Mobile-device traffic that must not traverse the internet |

6. **Compute on the Snow Family** — compute that travels:

   ```bash
   aws snowball describe-addresses --query 'Addresses' --output text
   aws snowball list-jobs --query 'JobListEntries[].{Id:JobId,Type:JobType,State:JobState}' --output table
   ```

   Snowball Edge Compute Optimized runs EC2-compatible instances and Lambda functions **disconnected** — on a ship, at a drill site, in a field hospital.

References: <https://docs.aws.amazon.com/elasticbeanstalk/latest/dg/Welcome.html> · <https://docs.aws.amazon.com/lightsail/latest/userguide/what-is-amazon-lightsail.html> · <https://docs.aws.amazon.com/apprunner/latest/dg/what-is-apprunner.html> · <https://docs.aws.amazon.com/outposts/latest/userguide/what-is-outposts.html> · <https://docs.aws.amazon.com/local-zones/latest/ug/what-is-aws-local-zones.html> · <https://docs.aws.amazon.com/wavelength/latest/developerguide/what-is-wavelength.html>

### Checkpoint — Exercise 7

- **Q7.1** Elastic Beanstalk and App Runner both "deploy your app without managing servers." Give the sharpest distinguishing question you'd ask to choose between them.
- **Q7.2** A three-person startup wants a WordPress site for a predictable $10/month with no AWS expertise. Lightsail, EC2, or Elastic Beanstalk? What do they give up?
- **Q7.3** Name AWS Batch's three core objects and explain what "scales to zero" means for the bill.
- **Q7.4** A hospital must keep patient-processing compute physically inside its own building but wants the EC2 and EBS APIs. Which service, and why is a Local Zone the wrong answer?
- **Q7.5** In step 5, why did every Local Zone show `not-opted-in`, and what does that imply about default resource placement?
- **Q7.6** Rank these five by *decreasing* customer control over the OS: Lambda, EC2, Fargate, Lightsail, Elastic Beanstalk.

---

## Exercise 8 — Synthesis: the selection decision

**Paper exercise — no commands.** This is the shape of the exam question.

### Steps

1. **Reconstruct the decision tree from memory**, then check it against your notes. Start from: *Is it event-driven and under 15 minutes?*

2. **Map each scenario to exactly one service and one purchasing/launch mode.** Write your answer before opening the key.

   | # | Scenario |
   |---|---|
   | **S1** | Thumbnail generation triggered by each S3 upload; bursty, ~300 ms per image, thousands per hour |
   | **S2** | A 15-year-old Windows Server ERP with a per-physical-core license, running 24×7 for at least 3 years |
   | **S3** | Genomics pipeline: 4,000 independent jobs, 20 min each, checkpointed, must finish by Monday, cost is the priority |
   | **S4** | Existing on-premises Kubernetes platform with Helm and custom CRDs, lifting to AWS with minimal rewrite |
   | **S5** | A Java Spring Boot app; a two-developer team that wants Git-push deploys and no infrastructure work, but needs to SSH into the servers when things break |
   | **S6** | A microservice packaged as a container image; no Kubernetes expertise on the team; must run 24×7 behind an ALB with zero instance management |
   | **S7** | An autonomous-vehicle inference workload requiring under 10 ms latency to devices on a 5G carrier network |
   | **S8** | An in-memory graph database needing 1 TiB of RAM, steady load, 1-year commitment acceptable, willing to stay on one instance family |
   | **S9** | A marketing site with a fixed, predictable $5/month budget and no elasticity requirement |
   | **S10** | Nightly ML training on GPUs, 6 hours, restartable, and the team wants job queuing rather than cluster management |

3. **For each of S1–S10, also state the shared-responsibility line**: name the highest layer AWS manages.

4. **Self-test the anti-patterns.** For each pairing below, name the disqualifying constraint:
   - Lambda for S3
   - EC2 On-Demand for S8
   - Fargate for S2
   - Spot for a stateful production database

### Checkpoint — Exercise 8

- **Q8.1** Give your service + mode for each of S1–S10.
- **Q8.2** Answer step 4's four anti-patterns.
- **Q8.3** State the one-sentence rule you would use on exam day to separate EC2 / containers / serverless when a question gives you no other signal.

---

## Full cleanup verification

Run this before closing the lab. Anything returned here is still billing you.

```bash
echo "== EC2 =="
aws ec2 describe-instances \
  --filters Name=instance-state-name,Values=pending,running,stopping,stopped \
  --query 'Reservations[].Instances[].{Id:InstanceId,Type:InstanceType,State:State.Name}' --output table

echo "== Load balancers =="
aws elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerName' --output text

echo "== Auto Scaling groups =="
aws autoscaling describe-auto-scaling-groups --query 'AutoScalingGroups[].AutoScalingGroupName' --output text

echo "== ECS clusters =="
aws ecs list-clusters --query 'clusterArns' --output text

echo "== EKS clusters =="
aws eks list-clusters --query 'clusters' --output text

echo "== Lambda functions =="
aws lambda list-functions --query 'Functions[].FunctionName' --output text

echo "== ECR repositories =="
aws ecr describe-repositories --query 'repositories[].repositoryName' --output text

echo "== Unattached EBS volumes =="
aws ec2 describe-volumes --filters Name=status,Values=available \
  --query 'Volumes[].{Id:VolumeId,GiB:Size}' --output table

echo "== Unassociated Elastic IPs (billable!) =="
aws ec2 describe-addresses --query 'Addresses[?AssociationId==`null`].PublicIp' --output text
```

---

<details>
<summary><b>📋 Answer key — click to expand</b></summary>

### Exercise 1 — Instance-type namespace

**A1.1** `c` = compute-optimized family (high vCPU-to-memory ratio, ~2 GiB per vCPU) · `6` = 6th generation · `g` = AWS Graviton (ARM64) processor · `n` = network- and EBS-optimized variant with substantially higher bandwidth · `8xlarge` = the size, 32 vCPUs. Read as: *family + generation + processor/capability attributes + size*. (<https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/instance-type-names.html>)

**A1.2** Memory-optimized — the **R** family, or **X**/High Memory for extreme footprints. Compute-optimized is wrong because the family letter encodes a *ratio*, not a quality tier: to reach 200 GiB of RAM on `c7i` you must scale up to roughly `c7i.24xlarge` (96 vCPUs, 192 GiB), buying ~90 vCPUs you will never use. `r7i.8xlarge` delivers 256 GiB with 32 vCPUs at far lower cost. **Right-sizing means matching the ratio, not maximizing one dimension.**

**A1.3** On Graviton, `ThreadsPerCore: 1` — one vCPU is one **physical core**; there is no SMT. On Intel/AMD with `ThreadsPerCore: 2`, one vCPU is one **hyperthread**, i.e. half a physical core. Consequence: an 8-vCPU Graviton instance has 8 real cores while an 8-vCPU Intel instance has 4 — vCPU counts are not directly comparable across architectures, which is why Graviton benchmarks often beat their nominal-vCPU peers.

**A1.4** Wrong — bare metal types (`*.metal`, e.g. `m7i.metal-24xl`) are ordinary EC2 instances launched with the same `RunInstances` API, AMIs, EBS volumes, security groups, VPC and IAM. The difference is that your OS runs directly on the hardware with no hypervisor, which is what nested-virtualization workloads and hardware-feature-dependent or licensing-sensitive software require. Same service, same shared responsibility model.

**A1.5** `d` means **local NVMe instance store**: physically attached to the host, very fast, and **ephemeral**. Its data is lost on stop, hibernate, termination, or host hardware failure — it survives only a guest OS reboot. It is therefore valid for caches, scratch space, temp tables and shuffle data, and never for anything that must be durable. Durable state belongs on EBS (AZ-replicated) or S3 (11 nines).

---

### Exercise 2 — Instance introspection

**A2.1** SSM Session Manager works **outbound**: the SSM Agent on the instance opens an HTTPS connection to the Systems Manager endpoints, and your session is tunneled back over it. No inbound port, no key pair, no bastion host is needed — which is why the instance had zero inbound rules. Shared responsibility: AWS operates the Session Manager control plane and the tunnel; **you** remain responsible for the IAM role scoping who may connect, for the agent's presence, and for session logging to S3/CloudWatch. Reducing the attack surface from "SSH open to the world" to "IAM-authorized outbound tunnel" is a customer-side decision.

**A2.2** **SSRF-based credential theft.** If an application on the instance can be tricked into fetching an attacker-supplied URL, IMDSv1's plain `GET` would return the instance profile's temporary IAM credentials. IMDSv2 requires a `PUT` to obtain a session token first — a request shape most SSRF vectors cannot produce — and `HttpPutResponseHopLimit=1` sets the response packet's IP TTL to 1, so the token cannot be forwarded off the instance (e.g. out of a container with its own network namespace, or through a misconfigured reverse proxy). (<https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/configuring-instance-metadata-service.html>)

**A2.3**

| Resource | Billed while stopped? |
|---|---|
| vCPU / RAM (instance hours) | **No** |
| EBS root volume | **Yes** — provisioned GiB-months, regardless of instance state |
| Private IPv4 address | **No** (retained, no charge) |
| Elastic IP | **Yes** — AWS charges for public IPv4 addresses, and an EIP not associated with a *running* instance has long been billed |

The classic surprise bill is a fleet of stopped instances with large gp3 volumes and orphaned EIPs.

**A2.4** An **EBS snapshot** is a point-in-time, incremental, block-level backup of a single volume, stored in S3-backed storage. An **AMI** is a launch template for a whole machine: it *references* one or more snapshots and adds the metadata EC2 needs to boot — root device mapping, virtualization type, architecture, kernel, ENA/SR-IOV support, and launch permissions. You can restore a volume from a snapshot; you can only launch an instance from an AMI. The **AMI is the golden image** — the artifact your pipeline (EC2 Image Builder, Packer) produces, versions and hands to launch templates.

**A2.5** (a) Performance: sustained 100% CPU on both vCPUs for the full 10 hours — `unlimited` mode never throttles. (b) Bill: the credit balance is drained within the first minutes, then every CPU-hour consumed beyond the baseline (10% per vCPU for `t3.micro`) is charged as **surplus credits** at a published per-vCPU-hour rate, on top of the instance's hourly price. Over 10 hours this can exceed the cost of a same-size `m6i` — the anti-pattern of running a sustained CPU workload on a burstable family. In `standard` mode the instance would instead be **throttled down to its 10% baseline** once credits hit zero: no surprise charge, but severe and often invisible performance collapse. Neither mode is "safe" for sustained load; the correct fix is a non-burstable family.

**A2.6** (1) **Idempotency** — the ASG can launch the instance at any time; the script must produce the same result whether the AMI is fresh or partially baked. (2) **Non-interactivity and fail-fast behavior** — it runs as root with no TTY, so any prompt hangs the boot; it must also signal failure (or the instance must fail its ELB health check) rather than come up half-configured and be marked `InService`. Additionally: it must not embed secrets (use Secrets Manager / Parameter Store via the instance profile) and it should be short, because it runs on **every** scale-out event and directly extends time-to-healthy.

---

### Exercise 3 — Purchasing options

**A3.1** **Spot Instances** — up to ~90% off On-Demand, and the workload's own description (nightly, checkpointed, restartable) matches the model exactly. The architectural requirement: the application must be **interruption-tolerant** — it must handle the 2-minute termination notice from `/latest/meta-data/spot/instance-action` (and ideally the earlier EC2 instance rebalance recommendation) by checkpointing and draining, and it must be able to resume elsewhere without losing work. Any state on local instance store must be treated as disposable.

**A3.2** **Compute Savings Plan.** It is a commitment to a dollar amount per hour of compute usage and applies automatically across instance family, size, OS, tenancy, **Region**, and across EC2, Fargate **and** Lambda. Every stated change — `m5`→`m7g`, EC2→Fargate — is absorbed with no exchange, no re-purchase and no gap in coverage. A Standard RI is locked to family/Region (highest discount, least flexible); a Convertible RI allows exchanges but is a manual, friction-laden process; an EC2 Instance Savings Plan is locked to instance family + Region and covers **no** Fargate or Lambda usage.

**A3.3** A score of **9** means AWS predicts a high likelihood that a Spot request of *that specific size, for those specific instance types, in that Region/AZ, right now* can be fulfilled without immediate interruption. It explicitly does **not** tell you: the price, that capacity is reserved for you, or that the score will still hold in an hour. It is a capacity-availability forecast, not a guarantee and not a price signal — and it is only meaningful relative to the target capacity you supplied.

**A3.4** A Savings Plan commits you to **spending a fixed dollar amount per hour on compute** (e.g. "$10/hour for 3 years"), not to any particular instance. Usage up to that dollar rate is billed at the discounted rate; usage beyond it falls to On-Demand. Because the unit is money rather than an instance-hour SKU, the discount follows your workload wherever it goes — that is precisely why Compute Savings Plans survive re-architecture while Reserved Instances (which attach a discount to a described instance configuration) do not.

**A3.5** **Dedicated Host.** Step 6 showed that `describe-hosts` exposes `Sockets` and `Cores` — visibility into the *physical* server. Per-socket and per-core licenses (Oracle, Microsoft SQL Server, Windows Server BYOL) require you to know and control the physical topology and to keep instances affined to the same host. A Dedicated *Instance* guarantees that no other AWS account's instances share your hardware, but gives you no socket/core visibility and no host affinity, so it cannot satisfy the license audit.

**A3.6** An **On-Demand Capacity Reservation** guarantees **capacity** — it reserves physical capacity in a specific AZ for a specific instance type, and you pay the On-Demand rate whether or not you run instances in it. It has no term commitment and no discount. A **Reserved Instance** or **Savings Plan** guarantees a **price** — a billing discount in exchange for a 1- or 3-year commitment — with no capacity guarantee (a *zonal* RI is the exception: it does carry a capacity reservation). The two are complementary and are often combined for disaster-recovery capacity.

---

### Exercise 4 — Elasticity

**A4.1** **Availability** (instances spread across multiple AZs), **elasticity/cost optimization** (capacity tracks demand instead of being provisioned for peak), **fault tolerance / self-healing** (unhealthy instances are replaced automatically), and **decoupling of clients from instances** (the ALB DNS name is stable while instances come and go). Step 7 demonstrated the third: terminating an instance produced an automatic replacement launch with no human intervention.

**A4.2** `EC2` health checking only asks the hypervisor whether the instance is *running* and passing EC2 status checks. It cannot see that nginx crashed, that the app is returning HTTP 500, that a deadlock has frozen the request loop, or that a disk filled. `ELB` health checking uses the target group's application-layer probe (`GET /` here), so a process-level failure on a perfectly healthy VM is detected and the instance is replaced. This is why `health-check-type ELB` plus a meaningful health-check path is the production default — and why `--health-check-grace-period` must exceed the bootstrap time, or instances get killed mid-boot in a loop.

**A4.3**

| Load balancer | Layer | Primary use |
|---|---|---|
| **Application Load Balancer (ALB)** | Layer 7 (HTTP/HTTPS) | Content-based routing on host/path/header/query, HTTP/2 and gRPC, WebSockets, native targets of EC2 / IP / Lambda / containers, TLS termination, WAF integration |
| **Network Load Balancer (NLB)** | Layer 4 (TCP/UDP/TLS) | Extreme throughput and ultra-low latency, millions of req/s, static IP per AZ and Elastic IP support, source-IP preservation, non-HTTP protocols |
| **Gateway Load Balancer (GWLB)** | Layer 3 gateway + Layer 4 | Transparently inserting third-party virtual appliances (firewalls, IDS/IPS, deep packet inspection) into the traffic path using GENEVE encapsulation |

(The Classic Load Balancer is the previous-generation option, retained for EC2-Classic-era workloads.)

**A4.4** **Amazon EC2 Auto Scaling** scales one thing: the number of EC2 instances in an Auto Scaling group. **AWS Auto Scaling / Application Auto Scaling** is the broader service that applies scaling policies to *other* resource types. Non-EC2 examples: ECS service desired count, DynamoDB table read/write capacity, Aurora Replica count, Lambda provisioned concurrency, SageMaker endpoint variants, Spot Fleet capacity. Exam signal: if the question scales "instances," it is EC2 Auto Scaling; if it scales a database's throughput or a container service's task count, it is Application Auto Scaling.

**A4.5**
1. **Target tracking** — "keep average CPU at 50%." The default choice; you name a metric and a target and AWS computes the arithmetic. (Used in step 4.)
2. **Step scaling** — "add 2 instances if CPU > 60%, add 4 more if CPU > 85%." Graduated response tied to CloudWatch alarm breach magnitude.
3. **Simple scaling** — "add 1 instance when the alarm fires," then wait out a cooldown before acting again. The legacy option; superseded by step scaling in nearly every case.
4. **Scheduled scaling** — "scale to 20 instances at 08:00 on weekdays." For demand you know in advance by the clock (market open, business hours, a scheduled batch window).
   (**Predictive scaling** is a fifth mechanism: it uses machine learning on historical CloudWatch data to provision *ahead* of forecast demand, and is typically combined with target tracking as a safety net.)

**A4.6** No. **Horizontal scaling** (scaling out/in) changes the *number* of instances; **vertical scaling** (scaling up/down) changes the *size* of one instance. This exercise performed horizontal scaling. Vertical scaling on EC2 requires a stop → `modify-instance-attribute --instance-type` → start cycle, which means downtime and a single point of failure that horizontal scaling avoids — the reason cloud-native architectures prefer scaling out.

---

### Exercise 5 — Containers

**A5.1** It ran on **AWS Fargate** — AWS-managed compute capacity that you never see as an instance in your account. **AWS patches** the underlying host operating system, the container runtime, and the Fargate agent; you remain responsible for what is *inside* your image: the base image's OS packages, your runtime, your libraries and your code. Fargate moves the OS boundary of the shared responsibility model up, but not the image boundary.

**A5.2**

| | **ECS** | **EKS** |
|---|---|---|
| **EC2 launch type** | You patch the container-instance OS, you scale the ASG, you pay per **EC2 instance-hour** (whether or not tasks fill it). ECS control plane is free. | You patch the worker-node OS (or use managed node groups / Karpenter to help), you scale nodes, you pay per **EC2 instance-hour** *plus* the **EKS control-plane hourly charge per cluster**. |
| **Fargate launch type** | AWS patches the host; capacity appears per task; you pay per **task vCPU-second and GB-second**. No idle capacity to pay for. | AWS patches the host; pods land on Fargate capacity; you pay per **pod vCPU/GB** *plus* the **EKS control-plane hourly charge**. |

The invariant: **the orchestrator column decides which API you write against; the launch-type row decides who owns the operating system and what unit you are billed in.**

**A5.3** **Amazon EKS** — it runs upstream, CNCF-conformant Kubernetes, so existing Helm charts, custom resource definitions, operators and `kubectl` workflows transfer essentially unchanged, and the same manifests still run on-premises. The trade-off is cost and complexity: EKS charges a per-cluster, per-hour control-plane fee (ECS's control plane is free), and you inherit the full Kubernetes operational surface — version upgrades, add-on lifecycle, CNI and IAM-to-service-account plumbing. ECS is cheaper and simpler but is an AWS-only API, so the migration would be a rewrite.

**A5.4** **Amazon ECS** and **Amazon EKS** both pull images from ECR (as do **AWS Lambda** for container-image functions, **AWS App Runner** and **AWS Batch**). Because ECR stores standard OCI images, the exact same image runs on any OCI-compatible runtime — a developer's laptop under Docker or Podman, an on-premises Kubernetes cluster, or another cloud. **Portability is a property of the image format, not of ECR.**

**A5.5** Immutable tags mean `clf33/hello:1.0.0` can never be overwritten to point at different bytes. A deployment referencing that tag is therefore **exactly reproducible** — rollback, audit and incident forensics all work, and a vulnerability scan result stays bound to the artifact it scanned. With `:latest`, the tag is a moving pointer: two instances launched an hour apart can run different code, a rollback may "roll back" to something new, and an ASG scale-out event silently introduces an untested version into a running fleet. Use immutable, semantically versioned tags (or content digests) in anything that reaches production.

**A5.6** **FARGATE** and **FARGATE_SPOT**. `FARGATE` is on-demand serverless capacity with no interruption. `FARGATE_SPOT` runs on AWS's spare capacity at a substantial discount but **can be reclaimed with a 2-minute SIGTERM warning** — appropriate for fault-tolerant, stateless or queue-driven tasks, and inappropriate for anything that cannot be killed mid-flight. A capacity provider strategy can blend them (e.g. a base of `FARGATE` for the always-on floor plus `FARGATE_SPOT` for the elastic remainder).

---

### Exercise 6 — Lambda

**A6.1** Maximum memory **10,240 MB (10 GB)**, maximum timeout **900 seconds (15 minutes)**, default account concurrency **1,000 concurrent executions per Region** (adjustable by quota request). The output also gave the deployment package limits: **50 MB zipped** direct upload / **250 MB unzipped** (container images go to 10 GB). (<https://docs.aws.amazon.com/lambda/latest/dg/gettingstarted-limits.html>)

**A6.2** Lambda's hard 15-minute execution ceiling makes a 40-minute continuous run impossible — the invocation is terminated at 900 s regardless of progress, and there is no extension mechanism. Fitting choices: **AWS Batch** (managed job queuing over EC2/Spot/Fargate, purpose-built for long-running batch), **Amazon ECS/Fargate tasks** (a task has no execution time limit), or plain **EC2** (Spot if the job is checkpointed). A less-good but common alternative is decomposing the work into sub-15-minute Lambda steps orchestrated by **AWS Step Functions** — valid only if the work is genuinely partitionable.

**A6.3** **Cold start.** The `Init Duration` is Lambda creating a new execution environment: downloading the code, starting the runtime and executing module-level initialization before the handler runs. Mitigations: **Provisioned Concurrency** (keeps a set number of environments initialized and warm, eliminating cold starts for that capacity, at a charge for the reserved environments), and **Lambda SnapStart** (snapshots the initialized environment and restores from it — available for Java, Python and .NET runtimes). Architectural mitigations: smaller deployment packages, moving heavy work out of the init phase, and avoiding cold-start-sensitive Lambdas on synchronous user-facing paths.

**A6.4** Memory is the **only** resource dial Lambda exposes; CPU, network bandwidth and disk I/O are allocated **proportionally** to the configured memory. You cannot buy CPU independently. **1,769 MB is the point at which a function receives one full vCPU**; below it the function gets a proportional time slice of a core, above it additional vCPUs are allocated (up to 6 vCPUs at 10,240 MB). This produces the counterintuitive but frequently observed result that raising memory *lowers* total cost for CPU-bound functions: the function finishes proportionally faster, and price is GB-seconds, so a 2× memory increase that halves the duration is cost-neutral — and anything better than that is a saving. Note it does *not* help wall-clock-bound work like the busy loop in step 5, or I/O-bound waits.

**A6.5** **Lambda, by roughly three to four orders of magnitude.** Lambda: 40 × 200 ms = 8 seconds of execution per day ≈ 240 s/month, billed as GB-seconds plus 1,200 requests — effectively cents or less, and covered by the perpetual Lambda free tier (1M requests and 400,000 GB-seconds per month). EC2: even the smallest instance runs 730 hours/month regardless of the 240 seconds of actual work, at several dollars per month plus the EBS volume. **When utilization is a rounding error, per-request billing wins overwhelmingly; the crossover comes when the workload approaches continuous utilization**, where EC2 or Fargate with a Savings Plan becomes cheaper.

**A6.6** There are servers — AWS owns, provisions, patches, scales and secures them, and you neither see nor manage them. "Serverless" is a statement about the **operational and billing model**, not about physics. Its defining properties are: no server provisioning or management, automatic scaling from zero to peak driven by events, pay only for what you consume with no charge for idle capacity, and built-in availability and fault tolerance.

---

### Exercise 7 — Managed abstractions

**A7.1** *"Do you need to see, log into, or tune the underlying EC2 instances, VPC and load balancer?"* If **yes** → **Elastic Beanstalk**: it provisions standard EC2, ASG, ELB and CloudWatch resources **into your account**, where you can SSH in, modify configuration via `.ebextensions`, and take over any component. If **no** → **App Runner**: it hides all infrastructure completely, exposing only a service configuration and an HTTPS URL, with automatic scaling to zero-ish and no VPC to design. Secondary discriminator: App Runner is container/source-oriented and web-request-shaped; Beanstalk supports a broader set of platforms including worker environments consuming SQS.

**A7.2** **Amazon Lightsail.** It is designed exactly for this: a fixed monthly bundle price covering compute, SSD, static IP and a generous data-transfer allowance, a simplified console, and one-click WordPress blueprints. What they give up: fine-grained control (limited instance types, restricted VPC features — Lightsail lives in a separate VPC that must be peered to reach a standard VPC), the full breadth of AWS integrations, and elasticity — Lightsail does not auto-scale, so a traffic spike means a manual resize or an outage. The escape hatch is real, though: a Lightsail instance can be exported to an EC2 AMI when the workload outgrows it.

**A7.3** (1) **Compute environment** — the pool that supplies capacity, backed by EC2 On-Demand, EC2 Spot, or Fargate, with a min/max vCPU range. (2) **Job queue** — an ordered, prioritized holding area for submitted jobs, bound to one or more compute environments. (3) **Job definition** — the reusable template describing the container image, vCPU/memory, IAM role, retry strategy and environment. "Scales to zero" means that when the queue is empty, Batch terminates the compute environment's instances and **the compute charge goes to zero**; you pay only for the minutes during which jobs are actually running. Combined with a Spot compute environment, this is the cheapest way to run large intermittent batch workloads on AWS.

**A7.4** **AWS Outposts.** It places AWS-owned, AWS-managed racks physically inside the customer's own data center, running the same EC2, EBS, ECS, EKS and S3-on-Outposts APIs as a Region, connected back to a parent Region. It is the only option that satisfies "compute physically inside our building." A **Local Zone** is the wrong answer because a Local Zone is AWS-owned infrastructure in an **AWS metro facility** — near the hospital, perhaps in the same city, but not on the hospital's premises. Local Zones solve *latency*; Outposts solve *physical location and data residency*.

**A7.5** Local Zones, Wavelength Zones and most non-home Regions are **opt-in**: you must explicitly enable a zone group before you can launch resources there. This is a deliberate safety default — it prevents an ASG, a Spot fleet or a misconfigured automation from silently placing workloads (and their data) in a geography you never intended, which matters for both cost and data-residency compliance. Default placement stays within the standard Availability Zones of the Region you selected.

**A7.6** Most control → least control:
1. **EC2** — full root on the OS; you choose the AMI, patch it, and configure everything.
2. **Lightsail** — a real VM with root access, but a constrained, pre-bundled configuration and limited networking.
3. **Elastic Beanstalk** — AWS provisions and manages the platform, but the EC2 instances are yours to inspect, SSH into and customize.
4. **Fargate** — you own the container image (its packages and runtime); you have no access to the host OS at all.
5. **Lambda** — you supply only a function (or an image); AWS owns the entire runtime environment and its lifecycle.

*(App Runner sits between Fargate and Lambda: you supply a container or source, and AWS manages the build, host, scaling, load balancing and TLS.)*

---

### Exercise 8 — Synthesis

**A8.1**

| # | Service + mode | Reasoning | Highest layer AWS manages |
|---|---|---|---|
| **S1** | **AWS Lambda**, event source mapping from S3 | Event-driven, short duration, bursty and spiky, idle most of the time — the canonical serverless profile. Per-request billing makes idle free. | Runtime and everything below |
| **S2** | **EC2 on a Dedicated Host**, 3-year **Standard RI** or EC2 Instance Savings Plan | Per-physical-core licensing needs socket/core visibility and host affinity (only Dedicated Hosts provide it); a legacy Windows ERP needs full OS control; 24×7 for 3+ years justifies the deepest commitment discount. | Hardware/hypervisor only |
| **S3** | **AWS Batch** with an **EC2 Spot** compute environment | Thousands of independent, checkpointed, restartable jobs with cost as the priority and a deadline — Batch handles the queuing and scale-to-zero, Spot supplies ~70–90% savings, and restartability satisfies Spot's interruption contract. | OS and orchestration (Batch manages the instances) |
| **S4** | **Amazon EKS** (managed node groups or Fargate) | Upstream Kubernetes conformance is the requirement; Helm charts and CRDs transfer unchanged. | Kubernetes control plane (+ host OS if on Fargate) |
| **S5** | **AWS Elastic Beanstalk** | Git-push deploys and zero infrastructure work, **but** the explicit need to SSH into servers rules out Fargate/App Runner/Lambda. Beanstalk leaves real EC2 instances in the account. | Platform/runtime; instances remain customer-visible |
| **S6** | **Amazon ECS on AWS Fargate**, behind an ALB | Containerized, no Kubernetes skills (so ECS over EKS, and no EKS control-plane fee), zero instance management (so Fargate over EC2 launch type), 24×7 with a load balancer. | Host OS and below |
| **S7** | **AWS Wavelength** | Sub-10 ms to devices on a 5G carrier network requires compute inside the carrier's network so traffic never traverses the public internet. A Local Zone is not close enough; a Region is far too distant. | Hardware/hypervisor (EC2 semantics at the edge) |
| **S8** | **EC2 memory-optimized** (`r`/`x`/High Memory) with a **1-year EC2 Instance Savings Plan** | 1 TiB RAM demands a memory-optimized family; steady 24×7 load plus willingness to stay in one family makes the EC2 Instance Savings Plan the deepest-discount fit (a Compute SP would trade some discount for flexibility they said they don't need). | Hardware/hypervisor only |
| **S9** | **Amazon Lightsail** | Fixed, predictable monthly price is stated as the requirement; no elasticity needed; bundled transfer avoids bill surprises. | Hardware/hypervisor, with a simplified management plane |
| **S10** | **AWS Batch** with a GPU-enabled **EC2 Spot** compute environment | "Job queuing rather than cluster management" is the explicit Batch signal; restartable + nightly + 6 hours is a textbook Spot profile; GPU instances (`p`/`g` families) supply the accelerators. | OS and orchestration |

**A8.2**
- **Lambda for S3** — 20-minute jobs exceed Lambda's hard **900-second** ceiling. Disqualified on execution duration.
- **EC2 On-Demand for S8** — not *wrong*, just wasteful: a workload that is steady 24×7 with an accepted 1-year commitment leaves roughly 40–72% on the table by not taking a Savings Plan or RI. Disqualified on cost optimization.
- **Fargate for S2** — Fargate gives no access to the host, no socket/core visibility and no host affinity, so per-physical-core BYOL licensing cannot be satisfied; it also does not run a 15-year-old Windows ERP that expects full OS control. Disqualified on licensing and OS control.
- **Spot for a stateful production database** — Spot capacity can be reclaimed with only a 2-minute warning at any time. A stateful primary database cannot tolerate arbitrary termination without risking data loss or an availability incident. Disqualified on interruption tolerance.

**A8.3** **Ask who must own the operating system, and how long a single unit of work runs.** If you need control of the OS (licensing, kernel modules, legacy software, specialized hardware) → **EC2**. If the app is already containerized and you want portability and scheduling without owning instances → **ECS/EKS on Fargate**. If the work is event-driven, stateless, and completes in under 15 minutes → **Lambda**. Then layer the cost model on top: steady and predictable → Savings Plan or RI; interruptible → Spot; spiky and unpredictable → On-Demand or per-request serverless.

</details>

---

## Official sources

- **CLF-C02 Exam Guide** — <https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf>
- Amazon EC2 User Guide — <https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/concepts.html>
- EC2 instance type naming — <https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/instance-type-names.html>
- EC2 instance purchasing options — <https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/instance-purchasing-options.html>
- Spot Instances — <https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/using-spot-instances.html>
- Instance metadata service (IMDSv2) — <https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/configuring-instance-metadata-service.html>
- Burstable performance instances — <https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/burstable-performance-instances.html>
- AWS Savings Plans — <https://docs.aws.amazon.com/savingsplans/latest/userguide/what-is-savings-plans.html>
- Amazon EC2 Auto Scaling — <https://docs.aws.amazon.com/autoscaling/ec2/userguide/what-is-amazon-ec2-auto-scaling.html>
- Elastic Load Balancing — <https://docs.aws.amazon.com/elasticloadbalancing/latest/userguide/what-is-load-balancing.html>
- Amazon ECS — <https://docs.aws.amazon.com/AmazonECS/latest/developerguide/Welcome.html>
- AWS Fargate — <https://docs.aws.amazon.com/AmazonECS/latest/userguide/what-is-fargate.html>
- Amazon EKS — <https://docs.aws.amazon.com/eks/latest/userguide/what-is-eks.html>
- Amazon ECR — <https://docs.aws.amazon.com/AmazonECR/latest/userguide/what-is-ecr.html>
- AWS Lambda — <https://docs.aws.amazon.com/lambda/latest/dg/welcome.html>
- Lambda quotas — <https://docs.aws.amazon.com/lambda/latest/dg/gettingstarted-limits.html>
- AWS Batch — <https://docs.aws.amazon.com/batch/latest/userguide/what-is-batch.html>
- AWS Elastic Beanstalk — <https://docs.aws.amazon.com/elasticbeanstalk/latest/dg/Welcome.html>
- Amazon Lightsail — <https://docs.aws.amazon.com/lightsail/latest/userguide/what-is-amazon-lightsail.html>
- AWS App Runner — <https://docs.aws.amazon.com/apprunner/latest/dg/what-is-apprunner.html>
- AWS Outposts — <https://docs.aws.amazon.com/outposts/latest/userguide/what-is-outposts.html>
- AWS Local Zones — <https://docs.aws.amazon.com/local-zones/latest/ug/what-is-aws-local-zones.html>
- AWS Wavelength — <https://docs.aws.amazon.com/wavelength/latest/developerguide/what-is-wavelength.html>