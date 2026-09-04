# 4.1 — Compare AWS Pricing Models

**Certification:** AWS Certified Cloud Practitioner (CLF-C02), v1.0
**Domain 4:** Billing, Pricing, and Support — **Task 4.1**, exam weight **4.0**
**Audience profile:** Platform Architect / SRE. This material assumes you already run infrastructure and treats pricing as a *systems design constraint*, not an accounting topic.

> **Price disclaimer — read this once, apply it everywhere below.**
> Every dollar figure in this document is an **illustrative list price for `us-east-1` at time of writing**, used to make the arithmetic concrete. AWS prices change and vary by Region. The **source of truth is the AWS Price List API**, and §4 shows you how to query it. What is *stable* — and what the exam actually tests — is the **relationship** between the models: which one carries commitment risk, which one carries availability risk, which one carries neither, and what each one costs you in flexibility.

---

## 1. Motivation: the architectural problem underneath the price list

### 1.1 The real problem is not "cost", it is a commitment/elasticity mismatch

A production platform has a load curve. That curve decomposes into three layers, and **each layer has a different correct purchase option**:

```
capacity
   ▲
   │                          ╭──╮        ← LAYER 3: burst / batch / CI
   │                     ╭────╯  ╰──╮        interruptible, elastic, spiky
   │        ╭──╮    ╭────╯          ╰───╮
   │   ╭────╯  ╰────╯                   ╰─╮  ← LAYER 2: diurnal peak
   │───┴──────────────────────────────────┴─   predictable shape, not 24/7
   │████████████████████████████████████████  ← LAYER 1: steady-state floor
   │████████████████████████████████████████     runs 24/7/365
   └────────────────────────────────────────▶ time
```

The failure mode is not "we picked the expensive option." The failure mode is **applying one purchase option to the whole curve**:

| Anti-pattern | Consequence |
|---|---|
| 100% On-Demand | You pay a ~40–70% premium on the steady-state floor, forever. This is the most common Series-B cloud bill. |
| 100% Reserved / Savings Plans, sized to peak | You pay for the peak 8,760 hours a year. Utilization drops to 40–60%; the *effective* discount goes negative versus On-Demand. |
| 100% Spot | The first regional capacity squeeze takes down your control plane. Spot is a capacity market, not a discount coupon. |
| Commit sized to *today's* architecture | You buy a 3-year x86 RI, then migrate to Graviton or containers in month 8 and strand the commitment. |

**The architectural statement of task 4.1 is:** *decompose the load curve, then match each layer to the purchase option whose risk profile matches that layer's tolerance.*

### 1.2 AWS's stated pricing philosophy (exam-level framing)

AWS reduces its whole pricing story to three principles. Know these verbatim-ish:

1. **Pay-as-you-go** — no upfront capex, no long-term contract required, you pay only for what you consume, and you stop paying when you stop using it.
2. **Save when you commit** — Savings Plans and Reserved Instances trade flexibility for a discount of up to ~72%.
3. **Pay less by using more** — tiered / volume-based pricing (S3 storage tiers, data-transfer-out tiers, consolidated-billing aggregation).

### 1.3 The three fundamental cost drivers

Whatever the service, an AWS bill is dominated by three dimensions. Ask these three questions of any architecture:

| Driver | What it means | The trap |
|---|---|---|
| **Compute** | Charged per unit of time an instance/function/task is *provisioned or running*. | Time, not utilization. An idle `m6i.24xlarge` costs the same as a saturated one. |
| **Storage** | Charged per GB-month, plus *requests*, plus *retrieval*, plus *minimum duration*. | People compare only the GB-month rate and ignore the other three. |
| **Data transfer** | **Inbound to AWS is generally free. Outbound to the internet and traffic across AZ/Region boundaries is not.** | This is the line item nobody modelled, and it is architecture-determined — you cannot buy a discount for a bad topology. |

---

## 2. The compute purchase options: full technical comparison

### 2.1 The six options at a glance

| Option | Commitment | Discount vs On-Demand | Capacity guarantee | Can be interrupted by AWS | Flexibility |
|---|---|---|---|---|---|
| **On-Demand** | None | 0% (baseline) | No (best-effort) | No | Total |
| **Compute Savings Plans** | $/hr for 1 or 3 yr | up to ~66% | **No** | No | Highest of all commit options — any Region, family, size, OS, tenancy; plus Fargate and Lambda |
| **EC2 Instance Savings Plans** | $/hr for 1 or 3 yr | up to ~72% | **No** | No | Locked to one **instance family in one Region**; flexible on size, OS, tenancy, AZ |
| **Standard Reserved Instances** | Instance config for 1 or 3 yr | up to ~72% | **Yes, if zonal** | No | Lowest — cannot change family; *can* be sold on the RI Marketplace |
| **Convertible Reserved Instances** | Instance config for 1 or 3 yr | up to ~66% | No (regional only) | No | Can be exchanged for a different family/OS/tenancy of equal-or-greater value; cannot be sold |
| **Spot Instances** | None | up to **~90%** | No | **Yes — 2-minute notice** | Total, but must be interruption-tolerant |

Plus two tenancy/isolation options that are **not** discounts:

| Option | What you actually buy | Why you'd buy it |
|---|---|---|
| **Dedicated Instance** | Instances on hardware dedicated to your account. Billed per instance, **plus a per-Region, per-hour dedicated-instance fee** (≈$2/hr) charged once regardless of how many you run. | Compliance requirement for physical isolation. |
| **Dedicated Host** | A whole **physical server**, billed per host. You get visibility into **sockets, physical cores, and host ID**, plus host affinity. | **BYOL for socket-/core-bound licences** (Windows Server, SQL Server, Oracle), and regulatory rules that require a nameable physical host. |

> **Exam discriminator:** if the question mentions *"existing per-socket or per-core software licence"* or *"visibility into the physical host"* → **Dedicated Host**. If it says only *"hardware not shared with other customers"* → **Dedicated Instance**.

### 2.2 Savings Plans vs Reserved Instances — the decision that actually matters

| Dimension | Savings Plans | Reserved Instances |
|---|---|---|
| Unit of commitment | **Dollars per hour** of compute spend | **A specific instance configuration** (family, size, OS, tenancy, Region/AZ) |
| Covers EC2 | Yes | Yes |
| Covers Fargate | **Yes** (Compute SP only) | No |
| Covers Lambda | **Yes** (Compute SP only — duration/GB-s and Provisioned Concurrency; **request charges are not covered**) | No |
| Covers Dedicated Hosts | **No** — use Dedicated Host Reservations | Dedicated Host Reservations are a separate product |
| Covers Spot | **No** (Spot is already discounted) | No |
| Instance-size flexibility | Yes, inherent | Only for **Regional** RIs, Linux/UNIX, default tenancy, same family+generation |
| Region flexibility | **Compute SP: yes.** EC2 Instance SP: no | No |
| OS flexibility | Yes | No — a Linux RI never covers a RHEL or Windows instance |
| Provides a **capacity reservation** | **Never** | **Only zonal RIs.** Regional RIs give a billing discount and AZ flexibility, *not* capacity |
| Can be cancelled | **No** | **No** — but Standard RIs can be **sold on the RI Marketplace** |
| Can be modified/exchanged | No (buy an additional plan) | Standard: modify AZ/scope/size. Convertible: **exchange** for equal-or-greater value |
| Applied automatically to matching usage | Yes | Yes |

**Architect's default:** for a modern, container-heavy, actively-evolving platform, **Compute Savings Plans** are the correct default for the steady-state floor. You give up ~6 percentage points of discount versus an EC2 Instance SP and ~6 versus a Standard RI, and in exchange the commitment survives a Graviton migration, an EKS adoption, a Region addition, and a move from EC2 to Fargate. That optionality is worth far more than 6 points to anyone who has ever stranded a 3-year RI.

**Buy zonal RIs only when you need the capacity reservation itself** — a licence-bound singleton, a stateful primary that must come back in a specific AZ after a failure.

### 2.3 Payment options (this is a separate axis — do not conflate it with term)

Every commitment product has **term** (1 or 3 years) × **payment option** (All Upfront / Partial Upfront / No Upfront). They are orthogonal.

| Payment option | Cash flow | Relative discount |
|---|---|---|
| **All Upfront** | 100% paid at purchase, $0 hourly | Largest |
| **Partial Upfront** | ~50% at purchase + reduced hourly | Middle |
| **No Upfront** | $0 at purchase, full hourly rate every hour of the term | Smallest |

The spread between All Upfront and No Upfront is typically only **2–4 percentage points**. That is an implied annual return in the low single digits. Unless your organisation has genuinely idle cash, **No Upfront is usually the rational choice** — you keep the capital and lose almost nothing.

> **Critical mechanic:** with **No Upfront**, you are still billed the hourly commitment **every hour of the term, whether or not you use it**. "No Upfront" means no *lump sum*; it does not mean no obligation.

### 2.4 The break-even identity every SRE should memorise

A commitment bills 24/7 for the whole term. On-Demand bills only for running hours. So:

$$\text{break-even utilization} = \frac{\text{committed rate}}{\text{On-Demand rate}} = 1 - \text{discount}$$

| Discount | Minimum uptime for the commit to win | Hours/month (of 730) |
|---|---|---|
| 27% | 73% | 533 |
| 30% | 70% | 511 |
| 40% | 60% | 438 |
| 50% | 50% | 365 |
| 66% | 34% | 248 |
| 72% | 28% | 204 |

**Worked example.** `m6i.large` On-Demand = **$0.096/hr**. A 1-year No Upfront Compute Savings Plan rate ≈ **$0.0673/hr** (30% off).

```
Commitment cost per month  = 0.0673 × 730 = $49.13   (fixed, always)
On-Demand cost for H hours = 0.096  × H

Break-even: 0.096 × H = 49.13  →  H = 512 hours/month = 70% uptime
```

So a dev-environment instance running 10h × 5d = ~217 h/month (**30% uptime**) is **catastrophically wrong** for a 1-year SP at 30% — you'd pay $49.13 instead of $20.83. But the same instance under a **3-year All Upfront Compute SP at ~58%** breaks even at 42% uptime — still wrong. Dev environments belong on **schedulers + On-Demand + Spot**, never on commitments.

### 2.5 Reserved Instance size flexibility — the normalization-factor arithmetic

A **Regional** RI for **Linux/UNIX with default tenancy** applies across sizes *within the same family and generation*, using normalization factors:

| Size | Factor | Size | Factor |
|---|---|---|---|
| nano | 0.25 | 4xlarge | 32 |
| micro | 0.5 | 8xlarge | 64 |
| small | 1 | 9xlarge | 72 |
| medium | 2 | 10xlarge | 80 |
| large | 4 | 12xlarge | 96 |
| xlarge | 8 | 16xlarge | 128 |
| 2xlarge | 16 | 24xlarge | 192 |
| 3xlarge | 24 | 32xlarge | 256 |

One Regional RI for **`m6i.xlarge`** (factor 8) fully covers **any** of:

- 2 × `m6i.large` (4 + 4 = 8) ✅
- 1 × `m6i.2xlarge` at **50%** — the remaining half bills On-Demand ✅
- 8 × `m6i.small`… (does not exist in this family, but the arithmetic holds where it does)
- 1 × `m5.xlarge` ❌ — **different generation, no coverage**
- 1 × `c6i.xlarge` ❌ — **different family, no coverage**
- 1 × `m6i.xlarge` running **RHEL** ❌ — **platform mismatch**

### 2.6 Discount application order (why your bill looks "wrong")

For a given usage hour, AWS applies discounts in a fixed order. Getting this wrong causes hours of confused CUR archaeology:

```
1. Zonal Reserved Instances        (matching AZ + config)
2. Regional Reserved Instances     (matching Region + config, with size flexibility)
3. EC2 Instance Savings Plans      (matching family + Region)
4. Compute Savings Plans           (any eligible EC2/Fargate/Lambda usage)
5. Remaining usage                 → billed at On-Demand rates
```

Within Savings Plans, AWS applies the commitment to the usage with the **highest discount percentage first**, to maximise your savings automatically. You do not — and cannot — steer this.

**Consequence:** if you own RIs *and* Savings Plans for the same fleet, the RIs consume the usage first, which can strand the Savings Plan and drive its utilization below 100%. Do not layer commitments on the same workload without modelling it.

### 2.7 Spot Instances: a capacity market, not a coupon

Spot sells you EC2's **unused capacity pool** in a given AZ for a given instance type. AWS reclaims it when it needs it back.

| Mechanic | Behaviour |
|---|---|
| Price | Set by long-run supply/demand per instance type per AZ; changes **gradually**, not per-bid. You always pay the *current* Spot price, never more than your max. |
| Interruption notice | **2 minutes**, delivered via instance metadata and an EventBridge event. |
| Earlier warning | **EC2 Instance Rebalance Recommendation** — fires *before* the 2-minute notice when the instance is at elevated interruption risk. |
| Interruption behaviour | `terminate` (default), `stop`, or `hibernate`. |
| Allocation strategy | **`price-capacity-optimized` is the recommended default** — picks pools with the deepest capacity among the cheapest. `capacity-optimized` maximises pool depth; `lowest-price` maximises interruption rate; `diversified` spreads across pools. |

**Diversification is the availability mechanism.** A Spot request pinned to one instance type in one AZ is a single point of failure. A request spanning 15 types across 3 AZs is statistically robust. This is why **attribute-based instance selection** (§3.1) exists — you describe *"≥4 vCPU, ≥8 GiB, current generation"* and let EC2 pick from every matching pool.

**Fits Spot:** stateless web/API tiers behind an ALB, CI runners, batch/ETL, video encoding, ML training with checkpointing, Kubernetes worker nodes for interruption-tolerant pods.
**Never Spot:** Kubernetes control planes, stateful primaries without automated failover, licence-bound singletons, anything whose restart takes longer than 2 minutes and cannot be checkpointed.

### 2.8 Capacity products that are not discounts

| Product | What it does | Billing |
|---|---|---|
| **On-Demand Capacity Reservation (ODCR)** | Reserves capacity in a **specific AZ** with no term commitment; create and cancel any time. | Billed at On-Demand rates **whether or not you run instances in it** — but **RIs and Savings Plans do apply** to ODCR hours. |
| **Capacity Blocks for ML** | Reserve GPU/accelerator capacity for a **future date and fixed duration**. | Paid upfront at purchase. |
| **Dedicated Host Reservation** | The commitment product for Dedicated Hosts (Savings Plans do **not** apply). | 1 or 3 year, upfront options. |

> **Exam discriminator:** *"I need a discount"* → Savings Plan / RI. *"I need to be certain the capacity is there"* → zonal RI or ODCR. *"I need both"* → zonal RI, or ODCR + Savings Plan.

---

## 3. Complete infrastructure manifests

### 3.1 CloudFormation — Auto Scaling group with a mixed purchase-option policy

This is the canonical implementation of §1.1: an On-Demand base (covered by a Savings Plan) plus Spot above it, with attribute-based instance selection for pool diversity and Capacity Rebalancing enabled.

```yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: >-
  Mixed purchase-option ASG. On-Demand base capacity carries the steady-state
  floor (covered by a Compute Savings Plan); Spot carries all burst above it.
  Attribute-based instance selection maximises the number of Spot pools.

Parameters:
  VpcSubnets:
    Type: List<AWS::EC2::Subnet::Id>
    Description: Private subnets, at least three distinct Availability Zones.
  InstanceSecurityGroup:
    Type: AWS::EC2::SecurityGroup::Id
  TargetGroupArn:
    Type: String
    Description: ALB target group the ASG registers into.
  AmiId:
    Type: 'AWS::SSM::Parameter::Value<AWS::EC2::Image::Id>'
    Default: /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64
  OnDemandBase:
    Type: Number
    Default: 4
    Description: Instances always launched On-Demand. Size this to the 24/7 floor.
  OnDemandPercentAboveBase:
    Type: Number
    Default: 20
    Description: Percentage of capacity above the base that is On-Demand.

Resources:

  InstanceRole:
    Type: AWS::IAM::Role
    Properties:
      AssumeRolePolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Effect: Allow
            Principal:
              Service: ec2.amazonaws.com
            Action: sts:AssumeRole
      ManagedPolicyArns:
        - arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
        - arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy

  InstanceProfile:
    Type: AWS::IAM::InstanceProfile
    Properties:
      Roles:
        - !Ref InstanceRole

  LaunchTemplate:
    Type: AWS::EC2::LaunchTemplate
    Properties:
      LaunchTemplateName: !Sub '${AWS::StackName}-lt'
      LaunchTemplateData:
        ImageId: !Ref AmiId
        IamInstanceProfile:
          Arn: !GetAtt InstanceProfile.Arn
        SecurityGroupIds:
          - !Ref InstanceSecurityGroup
        MetadataOptions:
          HttpTokens: required
          HttpPutResponseHopLimit: 2
        Monitoring:
          Enabled: true
        BlockDeviceMappings:
          - DeviceName: /dev/xvda
            Ebs:
              VolumeSize: 30
              # gp3 decouples IOPS from capacity: 3000 IOPS and 125 MB/s are
              # included at no extra charge, unlike gp2 where IOPS scale with GB.
              VolumeType: gp3
              Iops: 3000
              Throughput: 125
              Encrypted: true
              DeleteOnTermination: true
        TagSpecifications:
          - ResourceType: instance
            Tags:
              - Key: Name
                Value: !Sub '${AWS::StackName}-node'
              # Cost allocation tags must be activated in Billing before they
              # appear in Cost Explorer or the CUR.
              - Key: cost-center
                Value: platform-core
              - Key: environment
                Value: production
        UserData:
          Fn::Base64: !Sub |
            #!/bin/bash
            set -euxo pipefail
            dnf -y install amazon-cloudwatch-agent
            # Poll IMDSv2 for the Spot interruption notice and drain gracefully.
            cat >/usr/local/bin/spot-watch.sh <<'EOF'
            #!/bin/bash
            while true; do
              TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" \
                -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
              CODE=$(curl -s -o /dev/null -w '%{http_code}' \
                -H "X-aws-ec2-metadata-token: $TOKEN" \
                http://169.254.169.254/latest/meta-data/spot/instance-action)
              if [ "$CODE" = "200" ]; then
                logger -t spot-watch "interruption notice received; draining"
                systemctl stop app.service
                exit 0
              fi
              sleep 5
            done
            EOF
            chmod +x /usr/local/bin/spot-watch.sh
            nohup /usr/local/bin/spot-watch.sh &

  AutoScalingGroup:
    Type: AWS::AutoScaling::AutoScalingGroup
    Properties:
      AutoScalingGroupName: !Sub '${AWS::StackName}-asg'
      MinSize: 4
      MaxSize: 60
      DesiredCapacity: 6
      VPCZoneIdentifier: !Ref VpcSubnets
      TargetGroupARNs:
        - !Ref TargetGroupArn
      HealthCheckType: ELB
      HealthCheckGracePeriod: 180
      # Proactively replace Spot instances that receive a rebalance
      # recommendation, before the 2-minute termination notice fires.
      CapacityRebalance: true
      MixedInstancesPolicy:
        InstancesDistribution:
          OnDemandBaseCapacity: !Ref OnDemandBase
          OnDemandPercentageAboveBaseCapacity: !Ref OnDemandPercentAboveBase
          OnDemandAllocationStrategy: lowest-price
          # price-capacity-optimized: cheapest pools among those with the
          # deepest available capacity. Lowest interruption rate per dollar.
          SpotAllocationStrategy: price-capacity-optimized
        LaunchTemplate:
          LaunchTemplateSpecification:
            LaunchTemplateId: !Ref LaunchTemplate
            Version: !GetAtt LaunchTemplate.LatestVersionNumber
          Overrides:
            # Attribute-based selection: describe the shape, let EC2 enumerate
            # every matching pool. This is the single biggest lever on Spot
            # interruption rate.
            - InstanceRequirements:
                VCpuCount:
                  Min: 4
                  Max: 8
                MemoryMiB:
                  Min: 8192
                  Max: 32768
                CpuManufacturers:
                  - intel
                  - amd
                InstanceGenerations:
                  - current
                BurstablePerformance: excluded
                BareMetal: excluded
                AcceleratorCount:
                  Max: 0
                # Reject any pool priced more than 25% above the cheapest
                # instance type that satisfies the requirements above.
                SpotMaxPricePercentageOverLowestPrice: 125
      Tags:
        - Key: cost-center
          Value: platform-core
          PropagateAtLaunch: true
        - Key: environment
          Value: production
          PropagateAtLaunch: true

  TargetTrackingPolicy:
    Type: AWS::AutoScaling::ScalingPolicy
    Properties:
      AutoScalingGroupName: !Ref AutoScalingGroup
      PolicyType: TargetTrackingScaling
      TargetTrackingConfiguration:
        PredefinedMetricSpecification:
          PredefinedMetricType: ASGAverageCPUUtilization
        TargetValue: 65.0
        DisableScaleIn: false

Outputs:
  AutoScalingGroupName:
    Value: !Ref AutoScalingGroup
  LaunchTemplateId:
    Value: !Ref LaunchTemplate
```

### 3.2 Karpenter — Kubernetes purchase-option policy as declarative config

On EKS, Karpenter expresses the same layering, with the added ability to *consolidate* nodes when pods drain — turning unused capacity back into On-Demand savings automatically.

```yaml
---
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: default
spec:
  role: KarpenterNodeRole-prod
  amiSelectorTerms:
    - alias: al2023@latest
  subnetSelectorTerms:
    - tags:
        karpenter.sh/discovery: prod
  securityGroupSelectorTerms:
    - tags:
        karpenter.sh/discovery: prod
  metadataOptions:
    httpEndpoint: enabled
    httpTokens: required
    httpPutResponseHopLimit: 1
  blockDeviceMappings:
    - deviceName: /dev/xvda
      ebs:
        volumeSize: 100Gi
        volumeType: gp3
        iops: 3000
        throughput: 125
        encrypted: true
        deleteOnTermination: true
  tags:
    cost-center: platform-core
    environment: production
    managed-by: karpenter
---
# LAYER 1+2 — On-Demand. Higher weight => Karpenter prefers this pool first.
# Sized to the steady-state floor and covered by a Compute Savings Plan.
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: on-demand-baseline
spec:
  weight: 50
  template:
    metadata:
      labels:
        workload-class: baseline
    spec:
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["on-demand"]
        - key: kubernetes.io/arch
          operator: In
          values: ["arm64"]          # Graviton: better price/performance
        - key: karpenter.k8s.aws/instance-category
          operator: In
          values: ["c", "m", "r"]
        - key: karpenter.k8s.aws/instance-generation
          operator: Gt
          values: ["5"]
        - key: karpenter.k8s.aws/instance-cpu
          operator: In
          values: ["4", "8", "16"]
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: default
      expireAfter: 720h
      terminationGracePeriod: 1h
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 5m
    budgets:
      - nodes: "10%"
      - nodes: "0"
        schedule: "0 13 * * mon-fri"   # freeze disruption during peak
        duration: 6h
  limits:
    cpu: "400"
    memory: 1600Gi
---
# LAYER 3 — Spot. Lower weight => used only after the baseline pool is full.
# Deliberately wide requirements: more pools => fewer interruptions.
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: spot-burst
spec:
  weight: 10
  template:
    metadata:
      labels:
        workload-class: interruptible
    spec:
      taints:
        - key: capacity-type
          value: spot
          effect: NoSchedule
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["spot"]
        - key: kubernetes.io/arch
          operator: In
          values: ["amd64", "arm64"]
        - key: karpenter.k8s.aws/instance-category
          operator: In
          values: ["c", "m", "r"]
        - key: karpenter.k8s.aws/instance-generation
          operator: Gt
          values: ["5"]
        - key: karpenter.k8s.aws/instance-cpu
          operator: In
          values: ["4", "8", "16", "32"]
        - key: karpenter.k8s.aws/instance-hypervisor
          operator: In
          values: ["nitro"]
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: default
      expireAfter: 168h
      terminationGracePeriod: 5m
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 1m
    budgets:
      - nodes: "20%"
  limits:
    cpu: "2000"
    memory: 8000Gi
---
# Interruptible workloads opt in with a toleration; everything else stays
# on the baseline pool by default. Fail-safe: forget the toleration and you
# land on On-Demand, not on Spot.
apiVersion: apps/v1
kind: Deployment
metadata:
  name: image-transcoder
  namespace: media
spec:
  replicas: 24
  selector:
    matchLabels:
      app: image-transcoder
  template:
    metadata:
      labels:
        app: image-transcoder
    spec:
      terminationGracePeriodSeconds: 100   # < the 120 s Spot notice
      tolerations:
        - key: capacity-type
          operator: Equal
          value: spot
          effect: NoSchedule
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels:
              app: image-transcoder
      containers:
        - name: transcoder
          image: 111122223333.dkr.ecr.us-east-1.amazonaws.com/transcoder:1.14.2
          resources:
            requests:
              cpu: "1"
              memory: 2Gi
            limits:
              memory: 2Gi
          lifecycle:
            preStop:
              exec:
                command: ["/bin/sh", "-c", "/app/drain.sh && sleep 20"]
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: image-transcoder
  namespace: media
spec:
  minAvailable: 60%
  selector:
    matchLabels:
      app: image-transcoder
```

### 3.3 Terraform — FinOps guardrails (budgets, anomaly detection, CUR)

Commitments without observability are how you discover a stranded RI eleven months late.

```hcl
terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"   # Billing/CE/Budgets APIs are us-east-1 global endpoints
}

variable "finops_email" {
  type    = string
  default = "finops@example.com"
}

variable "monthly_budget_usd" {
  type    = number
  default = 42000
}

# ---------------------------------------------------------------------------
# 1. Cost budget with forecast + actual alerts.
#    Forecast alerts fire early enough to act; actual alerts fire too late.
# ---------------------------------------------------------------------------
resource "aws_budgets_budget" "platform_monthly" {
  name         = "platform-core-monthly"
  budget_type  = "COST"
  limit_amount = var.monthly_budget_usd
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

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
    # Amortized spreads upfront RI/SP fees across the term instead of
    # spiking the purchase month. Always use this for commitment tracking.
    use_amortized              = true
    use_blended                = false
  }

  cost_filter {
    name   = "TagKeyValue"
    values = ["user:cost-center$platform-core"]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.finops_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.finops_email]
  }
}

# ---------------------------------------------------------------------------
# 2. Savings Plans utilization budget.
#    Utilization below 100% means you are paying for commitment you do not use.
# ---------------------------------------------------------------------------
resource "aws_budgets_budget" "sp_utilization" {
  name         = "savings-plans-utilization-floor"
  budget_type  = "SAVINGS_PLANS_UTILIZATION"
  limit_amount = "99"
  limit_unit   = "PERCENTAGE"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "LESS_THAN"
    threshold                  = 99
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.finops_email]
  }
}

# ---------------------------------------------------------------------------
# 3. RI utilization budget — same logic, for the RI portfolio.
# ---------------------------------------------------------------------------
resource "aws_budgets_budget" "ri_utilization" {
  name         = "reserved-instance-utilization-floor"
  budget_type  = "RI_UTILIZATION"
  limit_amount = "95"
  limit_unit   = "PERCENTAGE"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "LESS_THAN"
    threshold                  = 95
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.finops_email]
  }
}

# ---------------------------------------------------------------------------
# 4. Cost Anomaly Detection — ML baseline per service, no threshold to tune.
# ---------------------------------------------------------------------------
resource "aws_ce_anomaly_monitor" "by_service" {
  name              = "anomaly-monitor-by-service"
  monitor_type      = "DIMENSIONAL"
  monitor_dimension = "SERVICE"
}

resource "aws_ce_anomaly_subscription" "daily_digest" {
  name      = "anomaly-subscription-daily"
  frequency = "DAILY"

  monitor_arn_list = [aws_ce_anomaly_monitor.by_service.arn]

  subscriber {
    type    = "EMAIL"
    address = var.finops_email
  }

  threshold_expression {
    dimension {
      key           = "ANOMALY_TOTAL_IMPACT_ABSOLUTE"
      values        = ["250"]
      match_options = ["GREATER_THAN_OR_EQUAL"]
    }
  }
}

# ---------------------------------------------------------------------------
# 5. Cost and Usage Report — the only dataset with per-resource, per-hour
#    unblended, amortized and effective-cost columns. Cost Explorer is a UI;
#    the CUR is the ledger.
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "cur" {
  bucket = "cur-111122223333-us-east-1"
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cur" {
  bucket = aws_s3_bucket.cur.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "cur" {
  bucket                  = aws_s3_bucket.cur.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

data "aws_iam_policy_document" "cur_bucket" {
  statement {
    sid    = "AllowBillingReportsWrite"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["billingreports.amazonaws.com"]
    }
    actions   = ["s3:GetBucketAcl", "s3:GetBucketPolicy", "s3:PutObject"]
    resources = [aws_s3_bucket.cur.arn, "${aws_s3_bucket.cur.arn}/*"]
  }
}

resource "aws_s3_bucket_policy" "cur" {
  bucket = aws_s3_bucket.cur.id
  policy = data.aws_iam_policy_document.cur_bucket.json
}

resource "aws_cur_report_definition" "hourly" {
  report_name                = "platform-cur-hourly"
  time_unit                  = "HOURLY"
  format                     = "Parquet"
  compression                = "Parquet"
  additional_schema_elements = ["RESOURCES", "SPLIT_COST_ALLOCATION_DATA"]
  s3_bucket                  = aws_s3_bucket.cur.id
  s3_prefix                  = "cur"
  s3_region                  = "us-east-1"
  additional_artifacts       = ["ATHENA"]
  report_versioning          = "OVERWRITE_REPORT"
  refresh_closed_reports     = true

  depends_on = [aws_s3_bucket_policy.cur]
}
```

---

## 4. CLI: getting real numbers instead of guessing

### 4.1 Query the Price List API for the On-Demand baseline

The Price List Query API is available only from `us-east-1`, `ap-south-1` and `eu-central-1`, but it returns prices for **every** Region via the `regionCode` filter.

```console
$ aws pricing get-products \
    --region us-east-1 \
    --service-code AmazonEC2 \
    --filters \
        'Type=TERM_MATCH,Field=instanceType,Value=m6i.large' \
        'Type=TERM_MATCH,Field=operatingSystem,Value=Linux' \
        'Type=TERM_MATCH,Field=tenancy,Value=Shared' \
        'Type=TERM_MATCH,Field=preInstalledSw,Value=NA' \
        'Type=TERM_MATCH,Field=capacitystatus,Value=Used' \
        'Type=TERM_MATCH,Field=regionCode,Value=us-east-1' \
    --output json \
  | jq -r '.PriceList[] | fromjson
           | .terms.OnDemand[].priceDimensions[]
           | "\(.pricePerUnit.USD)\t\(.unit)\t\(.description)"'
0.0960000000	Hrs	$0.096 per On Demand Linux m6i.large Instance Hour
```

> **`capacitystatus=Used` matters.** Without it you also match `UnusedCapacityReservation` and `AllocatedCapacityReservation` SKUs and get three rows with different meanings.

Compare the same instance across Regions — the single most common architectural cost lever, and one people forget exists:

```console
$ for R in us-east-1 us-west-2 eu-west-1 ap-southeast-1 sa-east-1; do
    P=$(aws pricing get-products --region us-east-1 --service-code AmazonEC2 \
      --filters "Type=TERM_MATCH,Field=instanceType,Value=m6i.large" \
                "Type=TERM_MATCH,Field=operatingSystem,Value=Linux" \
                "Type=TERM_MATCH,Field=tenancy,Value=Shared" \
                "Type=TERM_MATCH,Field=preInstalledSw,Value=NA" \
                "Type=TERM_MATCH,Field=capacitystatus,Value=Used" \
                "Type=TERM_MATCH,Field=regionCode,Value=${R}" \
      --output json \
      | jq -r '.PriceList[0] | fromjson
               | .terms.OnDemand[].priceDimensions[].pricePerUnit.USD')
    printf '%-16s %s\n' "$R" "$P"
  done
us-east-1        0.0960000000
us-west-2        0.0960000000
eu-west-1        0.1070000000
ap-southeast-1   0.1160000000
sa-east-1        0.1530000000
```

`sa-east-1` is **59% more expensive** than `us-east-1` for identical hardware. No purchase option recovers that; only topology does.

### 4.2 Compare committed rates for the same instance

```console
$ aws savingsplans describe-savings-plans-offering-rates \
    --region us-east-1 \
    --service-codes AmazonEC2 \
    --products EC2 \
    --savings-plan-types Compute EC2Instance \
    --savings-plan-payment-options "No Upfront" "All Upfront" \
    --filters name=instanceType,values=m6i.large \
              name=region,values=us-east-1 \
              name=tenancy,values=shared \
              name=productDescription,values=Linux/UNIX \
    --output json \
  | jq -r '.searchResults[]
           | [ .savingsPlanOffering.planType,
               .savingsPlanOffering.durationSeconds/31536000,
               .savingsPlanOffering.paymentOption,
               .rate ] | @tsv' | sort
Compute      1   All Upfront   0.0648000000
Compute      1   No Upfront    0.0673000000
Compute      3   All Upfront   0.0402000000
Compute      3   No Upfront    0.0433000000
EC2Instance  1   All Upfront   0.0590000000
EC2Instance  1   No Upfront    0.0614000000
EC2Instance  3   All Upfront   0.0334000000
EC2Instance  3   No Upfront    0.0353000000
```

Reading this table as an architect:

| Rate | vs On-Demand ($0.096) | Break-even uptime | Verdict |
|---|---|---|---|
| Compute 1yr No Upfront `0.0673` | −29.9% | 70% | Safe default. Survives Region/family/Fargate/Lambda changes. |
| EC2Instance 1yr No Upfront `0.0614` | −36.0% | 64% | +6 pts, but locked to `m6i` in `us-east-1`. |
| Compute 3yr No Upfront `0.0433` | −54.9% | 45% | Strong, but three years is longer than most architectures live. |
| EC2Instance 3yr All Upfront `0.0334` | −65.2% | 35% | Maximum discount, maximum lock-in. Only for a truly frozen fleet. |

The All Upfront vs No Upfront delta on the 1-year Compute plan is `0.0673 → 0.0648` = **3.7%**. That is the price of your capital for a year.

### 4.3 What does Cost Explorer recommend?

```console
$ aws ce get-savings-plans-purchase-recommendation \
    --savings-plans-type COMPUTE_SP \
    --term-in-years ONE_YEAR \
    --payment-option NO_UPFRONT \
    --lookback-period-in-days SIXTY_DAYS \
    --account-scope PAYER \
    --output json | jq '.SavingsPlansPurchaseRecommendation
        | {Summary: .SavingsPlansPurchaseRecommendationSummary}'
{
  "Summary": {
    "EstimatedROI": "42.7",
    "CurrencyCode": "USD",
    "EstimatedTotalCost": "231045.60",
    "CurrentOnDemandSpend": "329932.80",
    "EstimatedSavingsAmount": "98887.20",
    "TotalRecommendationCount": "1",
    "DailyCommitmentToPurchase": "633.00",
    "HourlyCommitmentToPurchase": "26.38",
    "EstimatedSavingsPercentage": "29.97",
    "EstimatedMonthlySavingsAmount": "8240.60",
    "EstimatedOnDemandCostWithCurrentCommitment": "329932.80"
  }
}
```

> **Do not buy this number blind.** Cost Explorer recommends against your *historical* usage over the lookback window. It has no knowledge of the Graviton migration in your next quarter's roadmap, the Region you are about to decommission, or the EKS consolidation that will cut node count by 30%. **A common practice is to commit to ~70–80% of the recommendation** and top up later; you can always buy another Savings Plan, but you can never cancel one.

### 4.4 Verify what you already own

```console
$ aws savingsplans describe-savings-plans \
    --states active \
    --output table \
    --query 'savingsPlans[].[savingsPlanType,paymentOption,commitment,
                             ec2InstanceFamily,region,start,end]'
------------------------------------------------------------------------------------------------------
|                                        DescribeSavingsPlans                                        |
+-------------+-------------+---------+---------+-------------+------------------------+-------------+
|  Compute    |  No Upfront |  18.00  |  None   |  None       |  2026-02-01T00:00:00Z  | 2027-02-01T00:00:00Z |
|  EC2Instance|  All Upfront|   6.50  |  m6i    |  us-east-1  |  2025-11-15T00:00:00Z  | 2026-11-15T00:00:00Z |
+-------------+-------------+---------+---------+-------------+------------------------+-------------+
```

```console
$ aws ec2 describe-reserved-instances \
    --filters Name=state,Values=active \
    --query 'ReservedInstances[].[ReservedInstancesId,InstanceType,Scope,
             AvailabilityZone,ProductDescription,InstanceCount,OfferingClass,End]' \
    --output table
--------------------------------------------------------------------------------------------------------------
|                                          DescribeReservedInstances                                         |
+--------------------------------------+--------------+----------+-------------+--------------+----+--------+
|  aaaaaaaa-1111-2222-3333-444444444444 | m6i.xlarge   | Region   | None        | Linux/UNIX   | 8  | standard | 2027-03-01T00:00:00Z |
|  bbbbbbbb-5555-6666-7777-888888888888 | r6i.2xlarge  | Availability Zone | us-east-1b | Linux/UNIX | 2 | standard | 2026-10-12T00:00:00Z |
|  cccccccc-9999-aaaa-bbbb-cccccccccccc | m5.large     | Region   | None        | Red Hat Enterprise Linux | 4 | convertible | 2026-09-30T00:00:00Z |
+--------------------------------------+--------------+----------+-------------+--------------+----+--------+
```

Three things an architect reads off that table immediately:
- Row 1 is **Regional + Linux + standard** → size-flexible across the whole `m6i` family, 8 × factor-8 = **64 normalized units**.
- Row 2 is **zonal in `us-east-1b`** → it carries a capacity reservation, but zero AZ or size flexibility. If those instances move to `1c`, coverage drops to **0%**.
- Row 3 is **RHEL** → it will never cover an Amazon Linux instance, and it expires in 26 days.

### 4.5 Spot: measure the market before you design for it

```console
$ aws ec2 describe-spot-price-history \
    --instance-types m6i.large m6a.large m5.large c6i.large r6i.large \
    --product-descriptions "Linux/UNIX" \
    --start-time "$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)" \
    --query 'sort_by(SpotPriceHistory,&SpotPrice)[].[InstanceType,AvailabilityZone,SpotPrice]' \
    --output table
------------------------------------------
|         DescribeSpotPriceHistory        |
+--------------+---------------+----------+
|  m6a.large   |  us-east-1d   |  0.0289  |
|  m5.large    |  us-east-1c   |  0.0312  |
|  m6i.large   |  us-east-1b   |  0.0341  |
|  c6i.large   |  us-east-1a   |  0.0358  |
|  m6i.large   |  us-east-1a   |  0.0373  |
|  r6i.large   |  us-east-1f   |  0.0489  |
+--------------+---------------+----------+
```

`m6i.large` Spot at `$0.0341` is **64% below On-Demand** and still **below the best 1-year committed rate** — with zero commitment, at the price of interruptibility.

Before you plan a large Spot fleet, ask EC2 whether the capacity exists:

```console
$ aws ec2 get-spot-placement-scores \
    --instance-requirements-with-metadata '{
      "ArchitectureTypes": ["x86_64", "arm64"],
      "VirtualizationTypes": ["hvm"],
      "InstanceRequirements": {
        "VCpuCount": {"Min": 4, "Max": 16},
        "MemoryMiB": {"Min": 8192, "Max": 65536},
        "InstanceGenerations": ["current"],
        "BurstablePerformance": "excluded",
        "BareMetal": "excluded"
      }
    }' \
    --target-capacity 500 \
    --target-capacity-unit-type units \
    --single-availability-zone \
    --region-names us-east-1 us-west-2 eu-west-1 \
    --output table
--------------------------------------
|      GetSpotPlacementScores        |
+---------------------+-------+------+
|  us-east-1a         |   9   |      |
|  us-west-2b         |   9   |      |
|  us-west-2c         |   8   |      |
|  eu-west-1a         |   7   |      |
|  us-east-1e         |   4   |      |
+---------------------+-------+------+
```

Score is **1–10**; it is a *relative likelihood of fulfilment without interruption*, not a guarantee and not a price signal. Anything ≤5 for a 500-unit target means: widen the requirements or shrink the target.

### 4.6 Rightsizing — the discount you get before buying any discount

**Never commit to a fleet you have not rightsized.** A Savings Plan on an over-provisioned fleet locks in the waste for a year.

```console
$ aws compute-optimizer get-ec2-instance-recommendations \
    --filters name=Finding,values=Overprovisioned \
    --output json \
  | jq -r '.instanceRecommendations[]
      | [ .instanceName,
          .currentInstanceType,
          .finding,
          (.utilizationMetrics[] | select(.name=="CPU") | .value | floor),
          .recommendationOptions[0].instanceType,
          .recommendationOptions[0].estimatedMonthlySavings.value ] | @tsv' \
  | column -t -N NAME,CURRENT,FINDING,CPU_MAX,RECOMMENDED,SAVINGS_USD
NAME              CURRENT       FINDING          CPU_MAX  RECOMMENDED   SAVINGS_USD
api-prod-07       m6i.4xlarge   Overprovisioned  11       m6i.xlarge    418.32
api-prod-08       m6i.4xlarge   Overprovisioned  9        m6i.xlarge    418.32
worker-batch-02   r6i.8xlarge   Overprovisioned  17       r6i.2xlarge   1102.94
etl-staging-01    c6i.2xlarge   Overprovisioned  4        c6i.large     186.15
```

That is **$2,125/month** recovered before a single commitment is purchased — and it is a larger discount than the difference between any two purchase options in §4.2.

### 4.7 Purchasing a Savings Plan

```console
$ OFFERING_ID=$(aws savingsplans describe-savings-plans-offerings \
    --plan-types Compute \
    --durations 31536000 \
    --payment-options "No Upfront" \
    --currencies USD \
    --query 'searchResults[0].offeringId' --output text)

$ echo "$OFFERING_ID"
b1a2c3d4-5e6f-7890-abcd-ef1234567890

$ aws savingsplans create-savings-plan \
    --savings-plan-offering-id "$OFFERING_ID" \
    --commitment "20.00" \
    --client-token "sp-2026-09-04-platform-core-01" \
    --tags Key=cost-center,Value=platform-core Key=purchased-by,Value=platform-team
{
    "savingsPlanId": "sp-0f1e2d3c4b5a69788"
}
```

> **This is irreversible.** `--commitment "20.00"` obligates **$20/hour × 8,760 hours = $175,200** over the term. There is no cancel, no refund, and no Savings Plan marketplace. The `--client-token` is your idempotency guard — reuse the same token if the call times out, so a retry does not buy a second plan.

---

## 5. Verification and failure diagnosis

### 5.1 The four-metric health model

Commitment health is **two independent metrics**, and confusing them is the single most common FinOps analysis error:

| Metric | Question it answers | Fix when low |
|---|---|---|
| **Utilization** | Of the commitment I bought, how much did I actually consume? | You **over-committed**, or the workload moved. |
| **Coverage** | Of my eligible usage, how much was covered by a commitment? | You **under-committed**. Buy more. |

The four quadrants:

| | High coverage | Low coverage |
|---|---|---|
| **High utilization** | ✅ Healthy and optimised | ⚠️ Under-committed — money left on the table, but no waste |
| **Low utilization** | ⚠️ Rare; usually a mismatch (§5.3) | 🔴 Both wrong — usually a stranded commit after a migration |

### 5.2 Diagnosing low Savings Plan utilization

```console
$ aws ce get-savings-plans-utilization \
    --time-period Start=2026-08-01,End=2026-09-01 \
    --granularity MONTHLY --output json | jq '.Total'
{
  "Utilization": {
    "TotalCommitment": "13392.00",
    "UsedCommitment": "10981.44",
    "UnusedCommitment": "2410.56",
    "UtilizationPercentage": "82.00"
  },
  "Savings": {
    "NetSavings": "2274.14",
    "OnDemandCostEquivalent": "15666.14"
  },
  "AmortizedCommitment": {
    "AmortizedRecurringCommitment": "13392.00",
    "AmortizedUpfrontCommitment": "0",
    "TotalAmortizedCommitment": "13392.00"
  }
}
```

**$2,410.56 of pure waste in one month.** Now find which hours:

```console
$ aws ce get-savings-plans-utilization \
    --time-period Start=2026-08-24,End=2026-08-31 \
    --granularity DAILY --output json \
  | jq -r '.SavingsPlansUtilizationsByTime[]
      | [ .TimePeriod.Start,
          .Utilization.UtilizationPercentage,
          .Utilization.UnusedCommitment ] | @tsv' \
  | column -t -N DATE,UTIL_PCT,UNUSED_USD
DATE        UTIL_PCT  UNUSED_USD
2026-08-24  99.10     4.32
2026-08-25  98.70     6.24
2026-08-26  99.40     2.88
2026-08-27  61.20     186.05
2026-08-28  58.90     197.09
2026-08-29  41.30     281.57
2026-08-30  39.80     288.77
2026-08-31  40.10     287.33
```

The cliff is **2026-08-27**. Correlate it against what changed:

```console
$ aws ce get-cost-and-usage \
    --time-period Start=2026-08-24,End=2026-09-01 \
    --granularity DAILY \
    --metrics UnblendedCost \
    --group-by Type=DIMENSION,Key=PURCHASE_TYPE \
    --filter '{"Dimensions":{"Key":"SERVICE","Values":["Amazon Elastic Compute Cloud - Compute"]}}' \
    --output json \
  | jq -r '.ResultsByTime[]
      | .TimePeriod.Start as $d
      | .Groups[] | [$d, .Keys[0], .Metrics.UnblendedCost.Amount] | @tsv' \
  | column -t -N DATE,PURCHASE_TYPE,USD
DATE        PURCHASE_TYPE           USD
2026-08-26  On Demand Instances     121.44
2026-08-26  Savings Plan Covered    438.10
2026-08-26  Spot Instances           31.02
2026-08-30  On Demand Instances      18.90
2026-08-30  Savings Plan Covered    173.31
2026-08-30  Spot Instances          277.60
```

**Root cause found:** on 2026-08-27 someone raised the Spot percentage in the ASG. Spot usage is **not eligible for Savings Plan coverage**, so the workload migrated out from under the commitment. Total spend went down, but $288/day of commitment now evaporates unused.

**Complete catalogue of low-SP-utilization causes:**

| Cause | Signal | Remediation |
|---|---|---|
| Shifted On-Demand → Spot | `PURCHASE_TYPE` breakdown flips (above) | Reduce Spot ratio back toward the commitment floor, or let the plan run out |
| Graviton / rightsizing migration | Total normalized units drop; instance families change | Expected. Model the reduction *before* the migration, not after |
| Workload moved to another Region | Region dimension shifts | Only fatal for an **EC2 Instance SP** — a Compute SP follows it |
| An RI was purchased for the same fleet | RI utilization rises as SP utilization falls | §2.6 — RIs apply first. Stop layering |
| Consolidated billing sharing disabled | Utilization low in payer, coverage low in members | Enable RI/SP sharing on the management account |
| Genuine over-purchase | Utilization was never 100%, even on day one | Nothing to do. Let the term expire; do not repeat |

### 5.3 Diagnosing an RI at 0% utilization

```console
$ aws ce get-reservation-utilization \
    --time-period Start=2026-08-01,End=2026-09-01 \
    --granularity MONTHLY \
    --group-by Type=DIMENSION,Key=SUBSCRIPTION_ID \
    --output json \
  | jq -r '.UtilizationsByTime[].Groups[]
      | [ .Attributes.subscriptionId,
          .Attributes.instanceType,
          .Attributes.availabilityZone // "regional",
          .Attributes.platform,
          .Utilization.UtilizationPercentage,
          .Utilization.UnusedHours ] | @tsv' \
  | column -t -N SUB_ID,TYPE,AZ,PLATFORM,UTIL_PCT,UNUSED_HRS
SUB_ID     TYPE          AZ           PLATFORM                  UTIL_PCT  UNUSED_HRS
884471023  m6i.xlarge    regional     Linux/UNIX                100.00    0.0
884471088  r6i.2xlarge   us-east-1b   Linux/UNIX                 0.00     1488.0
884471142  m5.large      regional     Red Hat Enterprise Linux   0.00     2976.0
```

An RI at exactly **0.00%** is never a capacity problem — it is always an **attribute mismatch**. Walk this checklist in order; the first mismatch you find is the answer:

| # | Attribute | How to check | Note |
|---|---|---|---|
| 1 | **Availability Zone** | Zonal RI's AZ vs where the instances actually run | The #1 cause. Zonal RIs have **no** AZ flexibility |
| 2 | **Platform / OS** | `Linux/UNIX` vs `Red Hat Enterprise Linux` vs `Windows` vs `SUSE` | A Linux RI never covers RHEL, and vice versa |
| 3 | **Instance family** | `m6i` vs `c6i` | Standard RIs cannot change family. Convertible can be *exchanged*, not auto-applied |
| 4 | **Generation** | `m5` vs `m6i` | Size flexibility does **not** cross generations |
| 5 | **Tenancy** | `default` vs `dedicated` vs `host` | Must match exactly |
| 6 | **Scope** | Zonal RIs get no size flexibility at all | Convert to Regional if you don't need the capacity guarantee |
| 7 | **Account sharing** | Is RI sharing enabled in the Organization? | Off by default in some configurations |

Confirm the AZ hypothesis directly:

```console
$ aws ec2 describe-instances \
    --filters Name=instance-type,Values=r6i.2xlarge \
              Name=instance-state-name,Values=running \
    --query 'Reservations[].Instances[].[InstanceId,Placement.AvailabilityZone,Platform]' \
    --output text
i-0a1b2c3d4e5f60718   us-east-1c   None
i-0a1b2c3d4e5f60719   us-east-1c   None
```

The RI is scoped to `us-east-1b`; the instances run in `us-east-1c`. **Fix:** modify the RI's scope to Regional (free, and it gains size + AZ flexibility, at the cost of the capacity reservation):

```console
$ aws ec2 modify-reserved-instances \
    --reserved-instances-ids bbbbbbbb-5555-6666-7777-888888888888 \
    --target-configurations Scope=Region,InstanceCount=2,InstanceType=r6i.2xlarge
{
    "ReservedInstancesModificationId": "rimod-0123456789abcdef0"
}

$ aws ec2 describe-reserved-instances-modifications \
    --reserved-instances-modification-ids rimod-0123456789abcdef0 \
    --query 'ReservedInstancesModifications[0].Status' --output text
processing
```

### 5.4 Blended vs Unblended vs Amortized — reading the ledger correctly

Every CUR analysis depends on picking the right cost column. Pick wrong and your conclusion is wrong.

| Column | Definition | Use it for |
|---|---|---|
| **Unblended cost** | What was charged, to that account, at the moment it happened. Upfront fees land as one spike in the purchase month. | Reconciling against the invoice |
| **Blended cost** | Usage costed at the *average* rate across the whole Organization for that usage type. | Almost nothing. It is an Organization-level artefact and it lies about single-account economics |
| **Amortized cost** | Upfront RI/SP fees spread evenly across every hour of the term. | **Showback/chargeback, unit economics, trend analysis** — this is the default an architect should use |
| **Net amortized cost** | Amortized, minus private-rate/EDP discounts. | Enterprise agreements |
| **`SavingsPlanEffectiveCost` / `ReservationEffectiveCost`** | The per-line-item cost after commitment discount. | Per-resource unit cost of a covered instance |

Coverage query against the CUR in Athena:

```sql
-- Purchase-option mix and effective hourly rate, by instance family.
-- Amortized effective cost, so a purchase month does not distort the result.
SELECT
    product_instance_type_family                      AS family,
    line_item_usage_account_id                        AS account,
    SUM(CASE WHEN line_item_line_item_type = 'SavingsPlanCoveredUsage'
             THEN line_item_usage_amount ELSE 0 END)  AS sp_hours,
    SUM(CASE WHEN line_item_line_item_type = 'DiscountedUsage'
             THEN line_item_usage_amount ELSE 0 END)  AS ri_hours,
    SUM(CASE WHEN line_item_line_item_type = 'Usage'
              AND line_item_usage_type LIKE '%SpotUsage%'
             THEN line_item_usage_amount ELSE 0 END)  AS spot_hours,
    SUM(CASE WHEN line_item_line_item_type = 'Usage'
              AND line_item_usage_type NOT LIKE '%SpotUsage%'
             THEN line_item_usage_amount ELSE 0 END)  AS ondemand_hours,
    ROUND(
        SUM(COALESCE(savings_plan_savings_plan_effective_cost, 0)
          + COALESCE(reservation_effective_cost, 0)
          + CASE WHEN line_item_line_item_type = 'Usage'
                 THEN line_item_unblended_cost ELSE 0 END)
      / NULLIF(SUM(line_item_usage_amount), 0), 5)    AS effective_hourly_usd
FROM   cur.platform_cur_hourly
WHERE  line_item_product_code   = 'AmazonEC2'
  AND  line_item_usage_start_date >= TIMESTAMP '2026-08-01 00:00:00'
  AND  line_item_usage_start_date <  TIMESTAMP '2026-09-01 00:00:00'
  AND  product_instance_type_family IS NOT NULL
GROUP  BY 1, 2
ORDER  BY effective_hourly_usd DESC;
```

```
 family | account      | sp_hours | ri_hours | spot_hours | ondemand_hours | effective_hourly_usd
--------+--------------+----------+----------+------------+----------------+----------------------
 r6i    | 111122223333 |   1204.0 |      0.0 |        0.0 |         2882.0 |              0.42117
 m6i    | 111122223333 |  38410.0 |   5952.0 |    11208.0 |          944.0 |              0.05918
 c6i    | 444455556666 |   9120.0 |      0.0 |    24660.0 |           88.0 |              0.03104
```

Row 1 is the finding: `r6i` is **70% On-Demand**. Row 3 is the model working — `c6i` sits at a **$0.031** effective hourly rate because most of it runs on Spot.

### 5.5 The costs that no purchase option can fix

Savings Plans and RIs cover **compute**. They do not cover EBS, S3, data transfer, NAT Gateways, load balancers, or Marketplace software. These are architecture problems.

| Cost | Typical rate | Why it surprises people | Fix |
|---|---|---|---|
| **NAT Gateway** | ~$0.045/hr **+ ~$0.045/GB processed** | The per-GB processing charge applies **even to traffic to S3 in the same Region** | **Gateway VPC endpoints for S3 and DynamoDB are free.** Add them. Then interface endpoints for the chatty services |
| **Cross-AZ traffic** | ~$0.01/GB **out + $0.01/GB in** = **$0.02/GB round-trip** | A service mesh with no topology awareness sprays every request across 3 AZs | Topology-aware routing; AZ-local read replicas |
| **Data transfer out to internet** | First 100 GB/month free, then ~$0.09/GB tiering down | Egress-heavy products discover this at scale, not at launch | CloudFront (lower per-GB rate, and **origin fetches from AWS origins are free**) |
| **Unattached EBS volumes** | gp3 ~$0.08/GB-month | They survive instance termination when `DeleteOnTermination: false` | Lifecycle policy + a Trusted Advisor / Config rule |
| **Unassociated Elastic IPs** | Hourly charge when not attached to a running instance | The classic "I stopped the instance to save money" trap | Release them |
| **Idle load balancers** | Hourly + LCU charges | Left behind by deleted stacks | Tag-driven reaping |
| **S3 Intelligent-Tiering monitoring** | ~$0.0025 per 1,000 objects/month | With 500M tiny objects that is **$1,250/month in monitoring alone**, possibly exceeding the storage saving | Do not use Intelligent-Tiering for large counts of small objects |
| **S3 early-delete / minimum duration** | Standard-IA & One Zone-IA: 30 days. Glacier IR & Flexible: 90. Deep Archive: 180 | Deleting a Deep Archive object on day 10 still bills 180 days | Model object lifetime *before* writing the lifecycle rule |
| **S3 lifecycle transition requests** | Per-1,000-objects charge on each transition | Transitioning 100M small objects can cost more than the storage saved | Transition by size threshold, not blindly by age |

Audit the three cheapest wins in one pass:

```console
$ aws ec2 describe-volumes --filters Name=status,Values=available \
    --query 'sort_by(Volumes,&Size)[].[VolumeId,Size,VolumeType,CreateTime]' \
    --output table
--------------------------------------------------------------------
|                          DescribeVolumes                         |
+------------------------+------+-------+---------------------------+
|  vol-0aa11bb22cc33dd44 |  100 |  gp3  |  2025-11-02T09:14:11+00:00 |
|  vol-0ee55ff66aa77bb88 |  500 |  gp2  |  2026-01-19T22:03:47+00:00 |
|  vol-0cc99dd88ee77ff66 | 2000 |  io1  |  2024-07-30T13:55:02+00:00 |
+------------------------+------+-------+---------------------------+

$ aws ec2 describe-addresses \
    --query 'Addresses[?AssociationId==null].[PublicIp,AllocationId]' \
    --output text
52.204.11.87    eipalloc-0123456789abcdef0
34.229.44.190   eipalloc-0abcdef1234567890

$ aws ec2 describe-vpc-endpoints \
    --filters Name=vpc-id,Values=vpc-0abc123def456789a \
    --query 'VpcEndpoints[].[ServiceName,VpcEndpointType,State]' --output text
com.amazonaws.us-east-1.ssm        Interface   available
com.amazonaws.us-east-1.ec2messages Interface  available
# No com.amazonaws.us-east-1.s3 gateway endpoint => every byte to S3 is
# paying NAT Gateway data-processing charges for nothing.
```

---

## 6. Storage, serverless and database pricing models

### 6.1 S3 storage classes — four billing dimensions, not one

| Class | Storage $/GB-mo | Min duration | Min billable size | Retrieval fee | Retrieval time | Design point |
|---|---|---|---|---|---|---|
| **S3 Standard** | ~0.023 | none | none | none | ms | Active, unpredictable access |
| **S3 Intelligent-Tiering** | Standard-rate tier down to archive rates, **+ ~$0.0025 per 1,000 objects/mo monitoring** | none | 128 KB for auto-tiering | **none** | ms (archive tiers slower) | Unknown or changing access patterns |
| **S3 Standard-IA** | ~0.0125 | **30 days** | **128 KB** | per-GB | ms | Known-infrequent, needs instant access |
| **S3 One Zone-IA** | ~0.010 | **30 days** | **128 KB** | per-GB | ms | Re-creatable data; **single AZ — lower durability posture** |
| **S3 Glacier Instant Retrieval** | ~0.004 | **90 days** | **128 KB** | per-GB (higher) | ms | Archives that must still be instant |
| **S3 Glacier Flexible Retrieval** | ~0.0036 | **90 days** | 40 KB | per-GB, by speed tier | minutes–12 h | Backups, compliance |
| **S3 Glacier Deep Archive** | ~0.00099 | **180 days** | 40 KB | per-GB (lowest) | **12–48 h** | Regulatory retention you hope never to read |

**The trap the exam and reality both set:** Standard-IA is 46% cheaper per GB-month than Standard, but adds a per-GB **retrieval** fee. Break-even is roughly *"read less than once or twice a month."* Data read weekly costs **more** on Standard-IA than on Standard.

### 6.2 EBS volume types

| Type | $/GB-mo | Performance model | Note |
|---|---|---|---|
| **gp3** | ~0.080 | **3,000 IOPS + 125 MB/s included**, provisioned independently of size | ~20% cheaper than gp2 and faster at small sizes. **gp2 → gp3 is a free, online, near-universal win** |
| **gp2** | ~0.100 | 3 IOPS/GB, burst | Legacy. Migrate |
| **io2 Block Express** | ~0.125 + per-IOPS | Provisioned IOPS, highest durability | Only when you genuinely need >16k IOPS or 99.999% durability |
| **st1** | ~0.045 | Throughput-optimised HDD | Big sequential scans, logs |
| **sc1** | ~0.015 | Cold HDD | Rarely accessed sequential |
| **Snapshots** | ~0.05 (standard) / ~0.0125 (archive tier) | Incremental | Archive tier has a **90-day minimum** and a restore fee |

### 6.3 Serverless and consumption models

| Service | Billing dimensions | Commit coverage |
|---|---|---|
| **AWS Lambda** | Requests + **duration × memory (GB-seconds)**, billed per millisecond. Memory allocation also scales CPU — a bigger function can be *cheaper* if it finishes proportionally faster. **arm64/Graviton is ~20% cheaper per GB-second than x86.** | **Compute Savings Plans cover duration and Provisioned Concurrency**; request charges are not covered |
| **AWS Fargate** | vCPU-hours + GB-hours of memory, per second with a 1-minute minimum. **Fargate Spot** offers a deep discount with a 2-minute interruption notice | Compute SP covers Fargate **on-demand**; it does **not** cover Fargate Spot |
| **Amazon DynamoDB** | **On-demand:** per read/write request unit, zero capacity planning. **Provisioned:** per RCU/WCU-hour, with auto-scaling, and **reserved capacity** available for a further discount | Reserved capacity is DynamoDB-specific; Savings Plans do not apply |
| **Amazon S3** | Storage + requests + retrieval + transfer | Not applicable |

**DynamoDB is the clearest illustration of the whole domain:** on-demand mode is the pay-as-you-go model (spiky, unpredictable, no planning); provisioned + reserved capacity is the save-when-you-commit model (steady, predictable). Same table, same data, same choice as EC2 On-Demand vs Savings Plans.

### 6.4 The AWS Free Tier

Classically three categories — know these for the exam:

| Type | Meaning | Examples |
|---|---|---|
| **12-month free** | Free for 12 months from account creation | 750 hours/month of a `t2.micro`/`t3.micro`, 30 GB EBS, 5 GB S3 Standard |
| **Always free** | No expiry, within monthly limits | Lambda 1M requests + 400,000 GB-seconds/month, DynamoDB 25 GB, 25 GB of CloudWatch/SNS-style allowances |
| **Trials** | Free for a short period after activating a specific service | Short evaluation windows on individual services |

> **Currency note:** AWS restructured new-account free-tier onboarding in 2025 toward a credit-based model. The three categories above are what CLF-C02 exam questions are written against; for real accounts, confirm current terms on the free tier page before budgeting.

### 6.5 Support plans — a pricing model expressed as a percentage of spend

Task 4.3 owns support in depth, but the *pricing structure* belongs here because it is the one place your bill scales with your bill:

| Plan | Cost model |
|---|---|
| **Basic** | Free |
| **Developer** | Greater of a small monthly minimum (~$29) **or ~3% of monthly AWS usage** |
| **Business** | Greater of ~$100/month **or a tiered percentage of usage** (~10% / 7% / 5% / 3% by spend band) |
| **Enterprise On-Ramp** | Greater of ~$5,500/month **or a tiered percentage** |
| **Enterprise** | Greater of ~$15,000/month **or a tiered percentage** |

Every dollar you remove through rightsizing and commitments also reduces the support fee — the saving compounds.

---

## 7. Putting it together: the decision procedure

```
For each workload:

  1. RIGHTSIZE FIRST.
     Compute Optimizer / CloudWatch. Never commit to waste.

  2. Can it survive a 2-minute termination notice?
       YES → Spot (diversified pools, price-capacity-optimized,
                   capacity rebalancing). Up to ~90% off, zero commitment.
       NO  → continue.

  3. What is its monthly uptime?
       < (1 - available discount)  → On-Demand + a scheduler. Do not commit.
       ≥ (1 - available discount)  → continue.

  4. Does it need a guaranteed slot in a specific AZ?
       YES → zonal Reserved Instance, or ODCR + a Savings Plan.
       NO  → continue.

  5. Is the fleet architecture frozen for the term?
       YES, and it's one family in one Region → EC2 Instance Savings Plan.
       NO, it will evolve                     → Compute Savings Plan.
                                                (the correct default)

  6. Is there a socket-/core-bound BYOL licence, or a physical-host
     compliance requirement?
       YES → Dedicated Host (+ Dedicated Host Reservation).
       Hardware isolation only, no licence → Dedicated Instance.

  7. Commit to ~70-80% of the Cost Explorer recommendation, never 100%.
     You can always buy more. You can never cancel.

  8. Instrument: SP/RI utilization budgets, coverage dashboards,
     anomaly detection, hourly CUR with RESOURCES.
```

### 7.1 Exam traps, condensed

| Claim | Truth |
|---|---|
| "Reserved Instances guarantee capacity." | **Only zonal RIs.** Regional RIs give a discount and AZ flexibility, not capacity. |
| "Savings Plans reserve capacity." | **Never.** Use a zonal RI or an ODCR. |
| "You can cancel a Savings Plan." | No. Standard RIs can be **sold on the RI Marketplace**; Savings Plans and Convertible RIs cannot be sold. |
| "Spot is just a cheaper On-Demand." | Spot is **reclaimable with 2 minutes' notice**. It is a different availability contract. |
| "Convertible RIs give the biggest discount." | **Standard** RIs discount more; Convertible trades ~6 points for exchangeability. |
| "Savings Plans cover everything compute." | Not Spot, not Dedicated Hosts, not Lambda *request* charges, not Marketplace software. |
| "Dedicated Instances let me use my socket-based licence." | You need a **Dedicated Host** for socket/core visibility and BYOL. |
| "Data transfer into AWS costs money." | Inbound from the internet is generally **free**. Outbound, cross-AZ and cross-Region are not. |
| "No Upfront means no obligation." | It means no lump sum. You are billed hourly for the **entire term** regardless of usage. |
| "Glacier Deep Archive is always cheapest." | Not for data you might delete early — **180-day minimum billing duration**, plus 12–48 h retrieval. |
| "Stopping an EC2 instance stops all its charges." | The **EBS volumes and any Elastic IP keep billing**. |

---

## References

**Exam and certification**
- AWS Certified Cloud Practitioner (CLF-C02) Exam Guide — https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf
- AWS Certified Cloud Practitioner — https://aws.amazon.com/certification/certified-cloud-practitioner/

**Pricing fundamentals**
- How AWS Pricing Works (whitepaper) — https://docs.aws.amazon.com/whitepapers/latest/how-aws-pricing-works/welcome.html
- AWS Pricing — https://aws.amazon.com/pricing/
- AWS Pricing Calculator — https://calculator.aws/
- AWS Free Tier — https://aws.amazon.com/free/
- AWS Price List API — https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/price-changes.html

**EC2 purchase options**
- Instance purchasing options — https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/instance-purchasing-options.html
- Amazon EC2 pricing — https://aws.amazon.com/ec2/pricing/
- Reserved Instances — https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-reserved-instances.html
- Reserved Instance size flexibility — https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/apply_ri.html
- Selling on the Reserved Instance Marketplace — https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ri-market-general.html
- Spot Instances — https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/using-spot-instances.html
- Spot Instance interruptions — https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/spot-interruptions.html
- Spot placement score — https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/spot-placement-score.html
- Dedicated Hosts — https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/dedicated-hosts-overview.html
- Dedicated Instances — https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/dedicated-instance.html
- On-Demand Capacity Reservations — https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-capacity-reservations.html

**Savings Plans**
- Savings Plans User Guide — https://docs.aws.amazon.com/savingsplans/latest/userguide/what-is-savings-plans.html
- Savings Plans pricing — https://aws.amazon.com/savingsplans/pricing/
- How Savings Plans apply to usage — https://docs.aws.amazon.com/savingsplans/latest/userguide/sp-applying.html
- Savings Plans compared with Reserved Instances — https://docs.aws.amazon.com/savingsplans/latest/userguide/sp-overview.html

**Storage and data transfer**
- Amazon S3 pricing — https://aws.amazon.com/s3/pricing/
- Using Amazon S3 storage classes — https://docs.aws.amazon.com/AmazonS3/latest/userguide/storage-class-intro.html
- Amazon EBS pricing — https://aws.amazon.com/ebs/pricing/
- Overview of data transfer costs for common architectures — https://aws.amazon.com/blogs/architecture/overview-of-data-transfer-costs-for-common-architectures/
- VPC endpoints — https://docs.aws.amazon.com/vpc/latest/privatelink/concepts.html
- NAT gateway pricing — https://docs.aws.amazon.com/vpc/latest/userguide/vpc-nat-gateway.html#nat-gateway-pricing

**Serverless and databases**
- AWS Lambda pricing — https://aws.amazon.com/lambda/pricing/
- AWS Fargate pricing — https://aws.amazon.com/fargate/pricing/
- Amazon DynamoDB read/write capacity modes — https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/HowItWorks.ReadWriteCapacityMode.html

**Cost management tooling**
- AWS Cost Explorer — https://docs.aws.amazon.com/cost-management/latest/userguide/ce-what-is.html
- AWS Budgets — https://docs.aws.amazon.com/cost-management/latest/userguide/budgets-managing-costs.html
- AWS Cost and Usage Reports — https://docs.aws.amazon.com/cur/latest/userguide/what-is-cur.html
- CUR data dictionary — https://docs.aws.amazon.com/cur/latest/userguide/data-dictionary.html
- AWS Cost Anomaly Detection — https://docs.aws.amazon.com/cost-management/latest/userguide/manage-ad.html
- AWS Compute Optimizer — https://docs.aws.amazon.com/compute-optimizer/latest/ug/what-is-compute-optimizer.html
- AWS Trusted Advisor — https://docs.aws.amazon.com/awssupport/latest/user/trusted-advisor.html
- AWS Support Plans pricing — https://aws.amazon.com/premiumsupport/pricing/

**Infrastructure as code**
- `AWS::AutoScaling::AutoScalingGroup` MixedInstancesPolicy — https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-properties-autoscaling-autoscalinggroup-mixedinstancespolicy.html
- Attribute-based instance type selection — https://docs.aws.amazon.com/autoscaling/ec2/userguide/create-mixed-instances-group-attribute-based-instance-type-selection.html
- Capacity Rebalancing in Auto Scaling — https://docs.aws.amazon.com/autoscaling/ec2/userguide/ec2-auto-scaling-capacity-rebalancing.html
- Karpenter NodePool API — https://karpenter.sh/docs/concepts/nodepools/
- Karpenter EC2NodeClass API — https://karpenter.sh/docs/concepts/nodeclasses/