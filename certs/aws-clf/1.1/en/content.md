# 1.1 — Define the Benefits of the AWS Cloud

**Certification:** AWS Certified Cloud Practitioner (CLF-C02) · Domain 1: Cloud Concepts (24% of the exam) · Objective weight in this course: **6.0**

**Audience level:** Platform Architect / SRE. This objective is scored at Practitioner level, but the *reason* each benefit exists is an architecture argument. Below, every claim the exam wants you to recognize is backed by the mechanism that produces it, the trade-off it imposes, deployable infrastructure that demonstrates it, and the CLI you use to prove it in a live account.

> **On numbers.** Region/AZ counts, prices and SLA percentages change. Every figure in this document is marked with the command or URL that returns the authoritative value. Never memorize the number; memorize the query.

---

## 1. The production problem this objective answers

### 1.1 The capacity-planning trap

Before elastic infrastructure, the sequence for a capacity change was:

```
demand forecast  →  budget approval  →  PO to vendor  →  lead time
   (± 60% error)      (2–8 weeks)        (1–2 weeks)     (6–16 weeks)
   →  rack / cable / burn-in  →  OS + config  →  in service
        (1–3 weeks)                (days)          T + 3 to 7 months
```

Three structural consequences follow, and they are exactly what the "benefits of AWS" list is a response to:

1. **The forecast horizon exceeds the product's planning horizon.** You must commit capital to a demand curve you will only observe after the hardware is depreciating. The error is asymmetric: under-provision and you drop revenue; over-provision and you carry idle capital for 3–5 years.
2. **The unit of purchase is enormous relative to the unit of demand.** You buy a rack; the workload needs 0.4 of a server. Utilization in traditional enterprise data centers is routinely reported in the 10–20% band for x86 fleets sized to peak.
3. **Failure domains are inherited, not chosen.** One building, one power feed, one core switch pair. The blast radius is a property of the lease, not of the architecture.

An SRE reading of the classical "six advantages of cloud computing" is that each one converts a **fixed, slow, coarse-grained** decision into a **variable, fast, fine-grained** one.

### 1.2 The six advantages, restated as engineering properties

| AWS's phrasing (exam wording) | Mechanism that delivers it | Engineering property | Metric you would actually track |
|---|---|---|---|
| Trade fixed expense for variable expense | Metered per-second/per-request billing; no minimum term | Cost is a *function of load*, not of forecast | $ / 1k requests; cost per unit of business work |
| Benefit from massive economies of scale | Aggregated demand across millions of customers; custom silicon (Nitro, Graviton); >100 published price reductions | Unit price falls without you renegotiating | $/vCPU-hour trend over time; Savings Plans coverage % |
| Stop guessing capacity | Auto Scaling, serverless, API-driven provisioning | Provisioning latency drops from months to seconds | Time-to-capacity (p50/p99); headroom % |
| Increase speed and agility | Self-service API for every resource type | Cost of an experiment ≈ 0; failed experiments are cheap | Lead time for change; environments per engineer |
| Stop spending money running and maintaining data centers | Shared Responsibility Model — AWS owns "security *of* the cloud" | Engineering effort moves up the stack | % of engineer-hours on undifferentiated lifting |
| Go global in minutes | 30+ Regions, 100+ AZs, 400+ edge PoPs, all API-addressable | Geography becomes a deployment parameter | p99 RTT per user population; RTO/RPO per Region |

**Exam trap:** "Economies of scale" is about *AWS's* purchasing power lowering *your* price. It is **not** the same as "elasticity" (matching capacity to demand) and **not** the same as "agility" (speed of change). CLF-C02 distinguishes these three explicitly.

---

## 2. Global infrastructure: the failure-domain hierarchy

You cannot reason about high availability without the physical containment model. AWS exposes it as a strict hierarchy, and each level is a distinct fault-isolation boundary.

| Level | What it physically is | Isolation guarantee | Latency between peers | Data transfer cost (typical) | API-addressable? |
|---|---|---|---|---|---|
| **Region** | A geographic cluster of AZs | Full isolation: separate power grids, separate control planes, no automatic data replication between Regions | 10–250 ms inter-Region | Inter-Region transfer, per-GB, per-pair | Yes — `--region` on every call |
| **Availability Zone (AZ)** | One *or more* discrete data centers, own power, cooling, physical security | Independent failure: a single AZ loss should not take a peer AZ | Typically **single-digit ms RTT** (often < 1–2 ms); AZs meaningfully separated (tens of km) | ~$0.01/GB **per direction** for EC2 cross-AZ | Yes — `AvailabilityZone` / `AvailabilityZoneId` |
| **Local Zone** | Compute/storage extension of a Region placed in a metro | Attached to a parent Region; not an independent HA tier | Single-digit ms to the metro's users | Region-dependent | Yes (opt-in) |
| **Wavelength Zone** | Infrastructure inside a telco 5G network | Same — an extension, not an HA tier | Ultra-low to mobile users | Region-dependent | Yes (opt-in) |
| **Outpost** | AWS-managed rack in *your* facility | Your building is the failure domain | LAN-local | N/A | Yes |
| **Edge location / PoP** | CloudFront + Route 53 + Global Accelerator points of presence | Cache/anycast tier, not a compute HA tier | 1–30 ms to end user | CloudFront egress pricing | Indirectly |

### 2.1 The single most important production detail in this objective: AZ **name** vs AZ **ID**

`us-east-1a` is **not** a physical location. AWS randomizes the mapping of AZ *names* to physical AZs **per AWS account**, specifically to prevent all customers from concentrating in "the first one." `us-east-1a` in account A and `us-east-1a` in account B are, with high probability, different buildings.

The stable, physical identifier is the **AZ ID**: `use1-az1`, `use1-az2`, `usw2-az3`, …

This matters the moment you do any of the following:
- Correlate a multi-account outage ("is this the same AZ?")
- Share subnets via AWS RAM (the shared subnet's AZ ID is what both accounts see consistently)
- Read an AWS Health event, which reports the AZ ID
- Place latency-sensitive workloads in the *same* physical AZ across accounts (cluster placement, cross-account VPC peering hot paths)
- Perform a zonal shift (the API takes an AZ **ID**)

```bash
$ aws ec2 describe-availability-zones \
    --region us-east-1 \
    --query 'AvailabilityZones[].[ZoneName,ZoneId,ZoneType,State,NetworkBorderGroup]' \
    --output table
------------------------------------------------------------------------
|                       DescribeAvailabilityZones                       |
+--------------+-------------+---------------------+-----------+--------+
|  us-east-1a  |  use1-az6   |  availability-zone  |  available|us-east-1|
|  us-east-1b  |  use1-az1   |  availability-zone  |  available|us-east-1|
|  us-east-1c  |  use1-az2   |  availability-zone  |  available|us-east-1|
|  us-east-1d  |  use1-az4   |  availability-zone  |  available|us-east-1|
|  us-east-1e  |  use1-az3   |  availability-zone  |  available|us-east-1|
|  us-east-1f  |  use1-az5   |  availability-zone  |  available|us-east-1|
+--------------+-------------+---------------------+-----------+--------+
```

Read that table again: in this account `us-east-1a` is physically `use1-az6`. Any runbook that says "fail away from us-east-1a" is ambiguous across accounts. Runbooks must say `use1-az6`.

Include Local Zones and Wavelength Zones in the enumeration (they are hidden by default):

```bash
$ aws ec2 describe-availability-zones --region us-west-2 --all-availability-zones \
    --query 'AvailabilityZones[?ZoneType!=`availability-zone`].[ZoneName,ZoneId,ZoneType,ParentZoneName,OptInStatus]' \
    --output table
--------------------------------------------------------------------------------------------
|                                DescribeAvailabilityZones                                  |
+--------------------------+---------------+----------------+---------------+---------------+
|  us-west-2-lax-1a        |  usw2-lax1-az1|  local-zone    |  us-west-2    |  not-opted-in |
|  us-west-2-lax-1b        |  usw2-lax1-az2|  local-zone    |  us-west-2    |  not-opted-in |
|  us-west-2-phx-1a        |  usw2-phx1-az1|  local-zone    |  us-west-2    |  not-opted-in |
|  us-west-2-wl1-den-wlz-1 |  usw2-den-wlz1|  wavelength-zone| us-west-2    |  not-opted-in |
+--------------------------+---------------+----------------+---------------+---------------+
```

### 2.2 Enumerating global infrastructure without an EC2 permission

The canonical, credential-light source is the **SSM Parameter Store public parameters** under `/aws/service/global-infrastructure`. This is the machine-readable version of the marketing page, and it is what you should script against.

```bash
$ aws ssm get-parameters-by-path \
    --path /aws/service/global-infrastructure/regions \
    --query 'length(Parameters)' --output text
36

$ aws ssm get-parameters-by-path \
    --path /aws/service/global-infrastructure/regions \
    --query 'Parameters[].Value' --output text | tr '\t' '\n' | sort | head -12
af-south-1
ap-east-1
ap-northeast-1
ap-northeast-2
ap-northeast-3
ap-south-1
ap-south-2
ap-southeast-1
ap-southeast-2
ap-southeast-3
ap-southeast-4
ca-central-1

# Human-readable long name of a Region
$ aws ssm get-parameter \
    --name /aws/service/global-infrastructure/regions/eu-south-2/longName \
    --query 'Parameter.Value' --output text
Europe (Spain)

# Is a given service available in a given Region? (the "go global" feasibility check)
$ aws ssm get-parameters-by-path \
    --path /aws/service/global-infrastructure/regions/eu-south-2/services \
    --query 'Parameters[].Value' --output text | tr '\t' '\n' | grep -E '^(eks|lambda|rds|bedrock)$'
eks
lambda
rds
```

That last query is the real-world form of the exam concept "not every service is in every Region." A multi-Region rollout plan begins with exactly this diff:

```bash
$ svc() { aws ssm get-parameters-by-path --path "/aws/service/global-infrastructure/regions/$1/services" \
      --query 'Parameters[].Value' --output text | tr '\t' '\n' | sort; }
$ comm -23 <(svc us-east-1) <(svc eu-south-2) | wc -l
94
```
94 services present in `us-east-1` and absent in `eu-south-2`. That number, not a slide, is your Region-selection input.

### 2.3 Instance types are not uniformly available *within* a Region

A subtler production fact, and a frequent cause of "the ASG only scales in two of my three AZs":

```bash
$ aws ec2 describe-instance-type-offerings \
    --location-type availability-zone-id \
    --filters Name=instance-type,Values=m7i.large \
    --region us-east-1 \
    --query 'sort_by(InstanceTypeOfferings,&Location)[].Location' --output text
use1-az1        use1-az2        use1-az4        use1-az5        use1-az6
```
`use1-az3` does not offer `m7i.large`. If your third subnet lives there, that AZ can never satisfy a scale-out for that type. This is the mechanical reason production ASGs use a `MixedInstancesPolicy` with several families — see §5.

---

## 3. High availability: the arithmetic, then the architecture

### 3.1 Availability budget table

| Availability | Downtime / year | Downtime / 30-day month | Downtime / week | Typical architecture |
|---|---|---|---|---|
| 99% ("two nines") | 3 d 15 h 36 m | 7 h 18 m | 1 h 41 m | Single instance, best effort |
| 99.9% | 8 h 45 m | 43 m 12 s | 10 m 5 s | Single AZ, redundant instances |
| 99.95% | 4 h 22 m | 21 m 36 s | 5 m 2 s | Multi-AZ with manual failover |
| 99.99% | 52 m 34 s | 4 m 19 s | 1 m 0 s | Multi-AZ, automated failover, stateless tier |
| 99.999% | 5 m 15 s | 25.9 s | 6.0 s | Multi-Region active/active, cell-based |

### 3.2 Composition rules

**Serial (dependency chain)** — every component must work:

$$A_{\text{system}} = \prod_{i=1}^{n} A_i$$

Four components at 99.99% each: `0.9999^4 = 0.99960` → **99.96%**, i.e. 3.5 h/year. Adding dependencies *costs* availability, always. This is why "reduce the number of things in the request path" is a reliability action, not a performance one.

**Parallel (redundant, independent)** — one of *n* suffices:

$$A_{\text{system}} = 1 - \prod_{i=1}^{n}(1 - A_i)$$

Two independent AZs at 99.9% each: `1 - 0.001^2 = 0.999999` → **99.9999%** *in theory*.

**Why you never actually get that number:** the redundancy is bounded by the least-independent shared dependency. The load balancer, the regional control plane, the shared database, the shared deployment pipeline, and the shared configuration are all *serial* in front of your *parallel* compute. The real model is:

$$A_{\text{real}} = A_{\text{shared}} \times \left[1 - \prod (1 - A_{\text{zone}})\right]$$

With an ALB at 99.99% in front of infinitely redundant compute, your ceiling is 99.99%. **Redundancy below a serial choke point cannot exceed the choke point.** Memorize that sentence; it is the entire reliability pillar in one line.

### 3.3 Redundancy models and their cost

| Model | Instances for capacity *C* across 3 AZs | Survives 1 AZ loss? | Steady-state utilization | Cost multiplier |
|---|---|---|---|---|
| **N** (no redundancy) | C | No — capacity brownout | ~100% | 1.0× |
| **N+1** | C + 1 unit | Yes, if 1 unit ≥ 1 AZ's share | ~high | ~1.1–1.3× |
| **2N** | 2C | Yes, fully | 50% | 2.0× |
| **3 AZ, "lose one and serve"** | 1.5C (each AZ holds 50% of C) | Yes, at full capacity | 67% | 1.5× |
| **2 AZ, "lose one and serve"** | 2C (each AZ holds 100% of C) | Yes, at full capacity | 50% | 2.0× |

**This is the concrete reason three AZs is the production default and two is not.** With two AZs, surviving one AZ loss at full capacity requires 100% headroom. With three AZs it requires 50%. The step from 2→3 AZs cuts your redundancy tax by half. AWS Regions ship with a minimum of three AZs for exactly this reason.

### 3.4 Published SLAs you should look up, never recall

| Service | Commitment shape | Where to verify |
|---|---|---|
| Amazon EC2 | Region-level and instance-level monthly uptime percentages, distinct numbers | `https://aws.amazon.com/compute/sla/` |
| Elastic Load Balancing | Monthly uptime percentage | `https://aws.amazon.com/elasticloadbalancing/sla/` |
| Amazon S3 | Monthly uptime percentage per storage class | `https://aws.amazon.com/s3/sla/` |
| Amazon RDS | Multi-AZ vs Single-AZ differ | `https://aws.amazon.com/rds/sla/` |
| Amazon DynamoDB | Standard vs Global Tables differ | `https://aws.amazon.com/dynamodb/sla/` |
| Amazon Route 53 | Highest published commitment of the portfolio | `https://aws.amazon.com/route53/sla/` |

**Exam and production trap:** an SLA is a *billing credit* contract, not an availability guarantee, and not a design target. Your design target must be stricter than your SLO, which must be stricter than your customer promise. AWS's SLA tells you what AWS will refund, not what your users will experience.

---

## 4. Elasticity vs scalability vs agility

These three are separate exam answers and separate engineering properties.

| Term | Definition | Direction | Time scale | AWS primitive |
|---|---|---|---|---|
| **Scalability** | The system can handle a larger load by adding resources | Up/out only, usually planned | Design-time to hours | Larger instance types; sharding; read replicas |
| **Elasticity** | Capacity automatically *tracks* demand, both up and down | Bidirectional, automatic | Seconds to minutes | Auto Scaling, Lambda concurrency, Aurora Serverless v2 |
| **Agility** | Time and cost to make *any* change, including a new idea | N/A | Minutes | The API itself; IaC; ephemeral environments |

**Vertical vs horizontal:**

| | Vertical (scale up) | Horizontal (scale out) |
|---|---|---|
| Mechanism | Bigger instance type | More instances |
| Downtime | Usually requires stop/start | None |
| Ceiling | Largest instance in the family | Practically unbounded (quota-bound) |
| Failure domain | Unchanged — still one node | Improves with spread |
| Fits | Stateful monoliths, RDBMS primaries | Stateless tiers, workers, web |
| Cost granularity | Coarse (2× jumps) | Fine (1 unit) |

### 4.1 The elasticity latency budget — the table that decides your architecture

Elasticity is only useful if capacity arrives **before** the demand curve outruns your headroom. Measure it:

| Mechanism | Time to usable capacity (typical) | Scaling unit | Notes |
|---|---|---|---|
| Lambda, warm concurrency | ~milliseconds | 1 request | Per-request elasticity; the theoretical limit |
| Lambda, cold start | ~100 ms – 2 s (runtime & VPC dependent) | 1 execution env | SnapStart / provisioned concurrency reduce this |
| Fargate task | ~30–60 s | 1 task | No node management |
| EC2 from ASG, warm pool `Stopped` | ~20–45 s | 1 instance | Bootstrap already done |
| EC2 from ASG, baked AMI | ~90–180 s | 1 instance | AMI contains the app |
| EC2 from ASG, boot-time config (cloud-init pulls artifacts) | ~3–8 min | 1 instance | The common anti-pattern |
| EKS node via Karpenter | ~40–90 s | 1 node | Then + pod start |
| Aurora Serverless v2 ACU change | seconds | 0.5 ACU | In-place, no failover |
| DynamoDB on-demand | immediate, with adaptive ramp | 1 request | Sudden >2× spikes may throttle until it adapts |

**The design rule:** let *T* be time-to-capacity and *D* be the time for demand to consume your headroom. If `T > D`, autoscaling cannot save you — you need pre-provisioned headroom, a warm pool, a request-level primitive (Lambda/Fargate), or a queue that absorbs the burst. Autoscaling is not a substitute for headroom; it is a mechanism for *reclaiming* headroom during the trough.

### 4.2 Scaling-policy selection

| Policy type | Signal | Best for | Failure mode |
|---|---|---|---|
| **Target tracking** | Keep a metric at a setpoint (`ASGAverageCPUUtilization`, `ALBRequestCountPerTarget`) | 90% of workloads; default choice | Wrong metric → oscillation; CPU is a poor proxy for I/O-bound apps |
| **Step scaling** | Alarm breach magnitude → discrete adjustments | Known, quantized load steps | Tuning burden; slow to react to smooth ramps |
| **Simple scaling** | One alarm → one adjustment + cooldown | Legacy; avoid | Cooldown blocks further action during a real surge |
| **Scheduled** | Wall-clock | Deterministic patterns (market open, batch window) | Silent breakage when the pattern shifts |
| **Predictive** | ML forecast on ≥24 h history, provisions *ahead* | Daily/weekly cyclic traffic with slow launch times | Forecast miss on anomalous days; pair with target tracking |

Production combination: **predictive scaling for the known cycle + target tracking for the residual**, with `ALBRequestCountPerTarget` (a demand signal) rather than CPU (a symptom signal).

---

## 5. Reference infrastructure — proof by construction

The following CloudFormation template is complete and deployable. It builds the topology that *is* the answer to this objective: three AZs, per-AZ egress, an ALB spanning all three, an ASG that diversifies across instance types and purchase options, and zonal-shift-aware health behavior.

### 5.1 `clf-1-1-multi-az.yaml`

```yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: >-
  CLF-C02 objective 1.1 reference topology. Demonstrates "go global in minutes",
  elasticity and multi-AZ high availability as deployable infrastructure:
  3 AZs, per-AZ NAT egress, ALB across all zones, ASG with a mixed instances
  policy and AZ-impairment handling.

Parameters:
  ProjectName:
    Type: String
    Default: clf-benefits
    Description: Prefix applied to every resource name tag.

  VpcCidr:
    Type: String
    Default: 10.42.0.0/16
    AllowedPattern: '^(\d{1,3}\.){3}\d{1,3}/(1[6-9]|2[0-4])$'
    Description: IPv4 CIDR for the VPC. Must be /16 to /24.

  LatestAmiId:
    # Public SSM parameter: always resolves to the current AL2023 x86_64 AMI in
    # THIS Region. This is what makes the template Region-portable with no
    # AMI mappings - the "go global in minutes" property, mechanically.
    Type: 'AWS::SSM::Parameter::Value<AWS::EC2::Image::Id>'
    Default: /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64

  AsgMinSize:
    Type: Number
    Default: 3
    MinValue: 3
    Description: >-
      Minimum 3 so every AZ holds at least one instance at rest. An ASG whose
      minimum is below the AZ count cannot be zone-balanced.

  AsgMaxSize:
    Type: Number
    Default: 12

  RequestsPerTargetTarget:
    Type: Number
    Default: 800
    Description: Target-tracking setpoint, requests per target per minute.

  PerAzNatGateway:
    Type: String
    Default: 'true'
    AllowedValues: ['true', 'false']
    Description: >-
      true  = one NAT Gateway per AZ. AZ-independent egress, ~3x NAT hourly cost,
              no cross-AZ NAT data charges.
      false = a single NAT Gateway in AZ A. Cheaper, but an AZ A failure removes
              egress for ALL private subnets. Never 'false' in production.

Conditions:
  MultiAzNat: !Equals [!Ref PerAzNatGateway, 'true']

Resources:

  # ---------------------------------------------------------------- networking
  Vpc:
    Type: AWS::EC2::VPC
    Properties:
      CidrBlock: !Ref VpcCidr
      EnableDnsSupport: true
      EnableDnsHostnames: true
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-vpc'

  InternetGateway:
    Type: AWS::EC2::InternetGateway
    Properties:
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-igw'

  IgwAttachment:
    Type: AWS::EC2::VPCGatewayAttachment
    Properties:
      VpcId: !Ref Vpc
      InternetGatewayId: !Ref InternetGateway

  # Fn::GetAZs returns the AZ NAMES available to THIS account in THIS Region,
  # in an account-specific order. The physical placement is therefore
  # account-specific: see the AZ name vs AZ ID discussion. The Outputs section
  # below emits the resolved AZ IDs so the deployment is auditable.
  PublicSubnetA:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref Vpc
      AvailabilityZone: !Select [0, !GetAZs '']
      CidrBlock: !Select [0, !Cidr [!Ref VpcCidr, 6, 8]]
      MapPublicIpOnLaunch: true
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-public-a'
        - Key: kubernetes.io/role/elb
          Value: '1'

  PublicSubnetB:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref Vpc
      AvailabilityZone: !Select [1, !GetAZs '']
      CidrBlock: !Select [1, !Cidr [!Ref VpcCidr, 6, 8]]
      MapPublicIpOnLaunch: true
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-public-b'
        - Key: kubernetes.io/role/elb
          Value: '1'

  PublicSubnetC:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref Vpc
      AvailabilityZone: !Select [2, !GetAZs '']
      CidrBlock: !Select [2, !Cidr [!Ref VpcCidr, 6, 8]]
      MapPublicIpOnLaunch: true
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-public-c'
        - Key: kubernetes.io/role/elb
          Value: '1'

  PrivateSubnetA:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref Vpc
      AvailabilityZone: !Select [0, !GetAZs '']
      CidrBlock: !Select [3, !Cidr [!Ref VpcCidr, 6, 8]]
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-private-a'
        - Key: kubernetes.io/role/internal-elb
          Value: '1'

  PrivateSubnetB:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref Vpc
      AvailabilityZone: !Select [1, !GetAZs '']
      CidrBlock: !Select [4, !Cidr [!Ref VpcCidr, 6, 8]]
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-private-b'
        - Key: kubernetes.io/role/internal-elb
          Value: '1'

  PrivateSubnetC:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref Vpc
      AvailabilityZone: !Select [2, !GetAZs '']
      CidrBlock: !Select [5, !Cidr [!Ref VpcCidr, 6, 8]]
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-private-c'
        - Key: kubernetes.io/role/internal-elb
          Value: '1'

  PublicRouteTable:
    Type: AWS::EC2::RouteTable
    Properties:
      VpcId: !Ref Vpc
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-rtb-public'

  PublicDefaultRoute:
    Type: AWS::EC2::Route
    DependsOn: IgwAttachment
    Properties:
      RouteTableId: !Ref PublicRouteTable
      DestinationCidrBlock: 0.0.0.0/0
      GatewayId: !Ref InternetGateway

  PublicSubnetAAssoc:
    Type: AWS::EC2::SubnetRouteTableAssociation
    Properties:
      SubnetId: !Ref PublicSubnetA
      RouteTableId: !Ref PublicRouteTable

  PublicSubnetBAssoc:
    Type: AWS::EC2::SubnetRouteTableAssociation
    Properties:
      SubnetId: !Ref PublicSubnetB
      RouteTableId: !Ref PublicRouteTable

  PublicSubnetCAssoc:
    Type: AWS::EC2::SubnetRouteTableAssociation
    Properties:
      SubnetId: !Ref PublicSubnetC
      RouteTableId: !Ref PublicRouteTable

  # ------------------------------------------------------------ per-AZ egress
  NatEipA:
    Type: AWS::EC2::EIP
    DependsOn: IgwAttachment
    Properties:
      Domain: vpc
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-nat-eip-a'

  NatEipB:
    Type: AWS::EC2::EIP
    Condition: MultiAzNat
    DependsOn: IgwAttachment
    Properties:
      Domain: vpc
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-nat-eip-b'

  NatEipC:
    Type: AWS::EC2::EIP
    Condition: MultiAzNat
    DependsOn: IgwAttachment
    Properties:
      Domain: vpc
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-nat-eip-c'

  NatGatewayA:
    Type: AWS::EC2::NatGateway
    Properties:
      AllocationId: !GetAtt NatEipA.AllocationId
      SubnetId: !Ref PublicSubnetA
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-nat-a'

  NatGatewayB:
    Type: AWS::EC2::NatGateway
    Condition: MultiAzNat
    Properties:
      AllocationId: !GetAtt NatEipB.AllocationId
      SubnetId: !Ref PublicSubnetB
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-nat-b'

  NatGatewayC:
    Type: AWS::EC2::NatGateway
    Condition: MultiAzNat
    Properties:
      AllocationId: !GetAtt NatEipC.AllocationId
      SubnetId: !Ref PublicSubnetC
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-nat-c'

  PrivateRouteTableA:
    Type: AWS::EC2::RouteTable
    Properties:
      VpcId: !Ref Vpc
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-rtb-private-a'

  PrivateRouteTableB:
    Type: AWS::EC2::RouteTable
    Properties:
      VpcId: !Ref Vpc
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-rtb-private-b'

  PrivateRouteTableC:
    Type: AWS::EC2::RouteTable
    Properties:
      VpcId: !Ref Vpc
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-rtb-private-c'

  PrivateDefaultRouteA:
    Type: AWS::EC2::Route
    Properties:
      RouteTableId: !Ref PrivateRouteTableA
      DestinationCidrBlock: 0.0.0.0/0
      NatGatewayId: !Ref NatGatewayA

  PrivateDefaultRouteB:
    Type: AWS::EC2::Route
    Properties:
      RouteTableId: !Ref PrivateRouteTableB
      DestinationCidrBlock: 0.0.0.0/0
      NatGatewayId: !If [MultiAzNat, !Ref NatGatewayB, !Ref NatGatewayA]

  PrivateDefaultRouteC:
    Type: AWS::EC2::Route
    Properties:
      RouteTableId: !Ref PrivateRouteTableC
      DestinationCidrBlock: 0.0.0.0/0
      NatGatewayId: !If [MultiAzNat, !Ref NatGatewayC, !Ref NatGatewayA]

  PrivateSubnetAAssoc:
    Type: AWS::EC2::SubnetRouteTableAssociation
    Properties:
      SubnetId: !Ref PrivateSubnetA
      RouteTableId: !Ref PrivateRouteTableA

  PrivateSubnetBAssoc:
    Type: AWS::EC2::SubnetRouteTableAssociation
    Properties:
      SubnetId: !Ref PrivateSubnetB
      RouteTableId: !Ref PrivateRouteTableB

  PrivateSubnetCAssoc:
    Type: AWS::EC2::SubnetRouteTableAssociation
    Properties:
      SubnetId: !Ref PrivateSubnetC
      RouteTableId: !Ref PrivateRouteTableC

  # ------------------------------------------------------------ security groups
  AlbSecurityGroup:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: Ingress from the internet to the ALB
      VpcId: !Ref Vpc
      SecurityGroupIngress:
        - IpProtocol: tcp
          FromPort: 80
          ToPort: 80
          CidrIp: 0.0.0.0/0
          Description: HTTP from anywhere (demo only; terminate TLS in production)
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-sg-alb'

  AppSecurityGroup:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: Ingress from the ALB only
      VpcId: !Ref Vpc
      SecurityGroupIngress:
        - IpProtocol: tcp
          FromPort: 8080
          ToPort: 8080
          SourceSecurityGroupId: !Ref AlbSecurityGroup
          Description: Application port, ALB only
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-sg-app'

  # ------------------------------------------------------------- load balancer
  Alb:
    Type: AWS::ElasticLoadBalancingV2::LoadBalancer
    Properties:
      Name: !Sub '${ProjectName}-alb'
      Type: application
      Scheme: internet-facing
      IpAddressType: ipv4
      SecurityGroups:
        - !Ref AlbSecurityGroup
      # An ALB REQUIRES subnets in at least two AZs. Three is the production
      # default: it is what makes "lose one AZ and keep full capacity" cost
      # 1.5x instead of 2x.
      Subnets:
        - !Ref PublicSubnetA
        - !Ref PublicSubnetB
        - !Ref PublicSubnetC
      LoadBalancerAttributes:
        - Key: idle_timeout.timeout_seconds
          Value: '60'
        - Key: routing.http.drop_invalid_header_fields.enabled
          Value: 'true'
        - Key: deletion_protection.enabled
          Value: 'false'
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-alb'

  TargetGroup:
    Type: AWS::ElasticLoadBalancingV2::TargetGroup
    Properties:
      Name: !Sub '${ProjectName}-tg'
      VpcId: !Ref Vpc
      Protocol: HTTP
      Port: 8080
      TargetType: instance
      HealthCheckEnabled: true
      HealthCheckProtocol: HTTP
      HealthCheckPath: /healthz
      HealthCheckIntervalSeconds: 10
      HealthCheckTimeoutSeconds: 5
      HealthyThresholdCount: 2
      UnhealthyThresholdCount: 3
      Matcher:
        HttpCode: '200'
      TargetGroupAttributes:
        - Key: deregistration_delay.timeout_seconds
          Value: '30'
        # ALB cross-zone load balancing is ON by default and free within a
        # Region. Turning it off makes traffic distribution proportional to the
        # ALB nodes per AZ, not to targets per AZ - a classic imbalance bug.
        - Key: load_balancing.cross_zone.enabled
          Value: 'true'
        - Key: load_balancing.algorithm.type
          Value: least_outstanding_requests
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-tg'

  Listener:
    Type: AWS::ElasticLoadBalancingV2::Listener
    Properties:
      LoadBalancerArn: !Ref Alb
      Protocol: HTTP
      Port: 80
      DefaultActions:
        - Type: forward
          TargetGroupArn: !Ref TargetGroup

  # ------------------------------------------------------------ compute fleet
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
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-instance-role'

  InstanceProfile:
    Type: AWS::IAM::InstanceProfile
    Properties:
      Roles:
        - !Ref InstanceRole

  LaunchTemplate:
    Type: AWS::EC2::LaunchTemplate
    Properties:
      LaunchTemplateName: !Sub '${ProjectName}-lt'
      LaunchTemplateData:
        ImageId: !Ref LatestAmiId
        IamInstanceProfile:
          Arn: !GetAtt InstanceProfile.Arn
        SecurityGroupIds:
          - !Ref AppSecurityGroup
        MetadataOptions:
          HttpTokens: required          # IMDSv2 only
          HttpPutResponseHopLimit: 1
        Monitoring:
          Enabled: true                 # 1-minute metrics: required for fast scaling
        BlockDeviceMappings:
          - DeviceName: /dev/xvda
            Ebs:
              VolumeSize: 20
              VolumeType: gp3
              Encrypted: true
              DeleteOnTermination: true
        TagSpecifications:
          - ResourceType: instance
            Tags:
              - Key: Name
                Value: !Sub '${ProjectName}-app'
        UserData:
          Fn::Base64: !Sub |
            #!/bin/bash
            set -euxo pipefail
            dnf -y install python3
            AZ=$(curl -sf -H "X-aws-ec2-metadata-token: $(curl -sf -X PUT \
                 'http://169.254.169.254/latest/api/token' \
                 -H 'X-aws-ec2-metadata-token-ttl-seconds: 300')" \
                 http://169.254.169.254/latest/meta-data/placement/availability-zone)
            AZID=$(curl -sf -H "X-aws-ec2-metadata-token: $(curl -sf -X PUT \
                 'http://169.254.169.254/latest/api/token' \
                 -H 'X-aws-ec2-metadata-token-ttl-seconds: 300')" \
                 http://169.254.169.254/latest/meta-data/placement/availability-zone-id)
            mkdir -p /srv/app
            printf 'OK\n' > /srv/app/healthz
            printf 'zone=%s zone_id=%s\n' "$AZ" "$AZID" > /srv/app/index.html
            cat >/etc/systemd/system/app.service <<'UNIT'
            [Unit]
            Description=CLF 1.1 demo app
            After=network-online.target
            [Service]
            WorkingDirectory=/srv/app
            ExecStart=/usr/bin/python3 -m http.server 8080
            Restart=always
            [Install]
            WantedBy=multi-user.target
            UNIT
            systemctl daemon-reload
            systemctl enable --now app.service

  AutoScalingGroup:
    Type: AWS::AutoScaling::AutoScalingGroup
    Properties:
      AutoScalingGroupName: !Sub '${ProjectName}-asg'
      MinSize: !Ref AsgMinSize
      MaxSize: !Ref AsgMaxSize
      DesiredCapacity: !Ref AsgMinSize
      VPCZoneIdentifier:
        - !Ref PrivateSubnetA
        - !Ref PrivateSubnetB
        - !Ref PrivateSubnetC
      TargetGroupARNs:
        - !Ref TargetGroup
      HealthCheckType: ELB
      HealthCheckGracePeriod: 120
      # Capacity diversification: this is the practical answer to
      # InsufficientInstanceCapacity in a single type/AZ combination.
      # NOTE: every override MUST match the AMI architecture. LatestAmiId is
      # x86_64, so all overrides are x86_64. Mixing in Graviton (m7g/m6g) here
      # would launch instances that never boot.
      MixedInstancesPolicy:
        InstancesDistribution:
          OnDemandBaseCapacity: 3
          OnDemandPercentageAboveBaseCapacity: 25
          OnDemandAllocationStrategy: prioritized
          SpotAllocationStrategy: price-capacity-optimized
        LaunchTemplate:
          LaunchTemplateSpecification:
            LaunchTemplateId: !Ref LaunchTemplate
            Version: !GetAtt LaunchTemplate.LatestVersionNumber
          Overrides:
            - InstanceType: m7i.large
            - InstanceType: m6i.large
            - InstanceType: m5.large
            - InstanceType: m5a.large
            - InstanceType: m5n.large
      # Keep capacity evenly spread; do not sacrifice balance for convenience.
      AvailabilityZoneDistribution:
        CapacityDistributionStrategy: balanced-best-effort
      # When an AZ is impaired, do NOT replace instances there (that would burn
      # capacity trying to launch into a broken zone). Requires a recent ASG API.
      AvailabilityZoneImpairmentPolicy:
        ZonalShiftEnabled: true
        ImpairedZoneHealthCheckBehavior: IgnoreUnhealthy
      MetricsCollection:
        - Granularity: 1Minute
          Metrics:
            - GroupInServiceInstances
            - GroupDesiredCapacity
            - GroupPendingInstances
            - GroupTerminatingInstances
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-app'
          PropagateAtLaunch: true
    UpdatePolicy:
      AutoScalingRollingUpdate:
        MinInstancesInService: !Ref AsgMinSize
        MaxBatchSize: 1
        PauseTime: PT5M
        WaitOnResourceSignals: false
        SuspendProcesses:
          - AZRebalance

  # Demand-proportional signal. CPU is a symptom; request rate is the cause.
  RequestScalingPolicy:
    Type: AWS::AutoScaling::ScalingPolicy
    Properties:
      AutoScalingGroupName: !Ref AutoScalingGroup
      PolicyType: TargetTrackingScaling
      EstimatedInstanceWarmup: 120
      TargetTrackingConfiguration:
        TargetValue: !Ref RequestsPerTargetTarget
        PredefinedMetricSpecification:
          PredefinedMetricType: ALBRequestCountPerTarget
          # ResourceLabel format: <alb-full-name>/<tg-full-name>
          ResourceLabel: !Join
            - '/'
            - - !GetAtt Alb.LoadBalancerFullName
              - !GetAtt TargetGroup.TargetGroupFullName

  # Second-line guard for CPU-bound regressions.
  CpuScalingPolicy:
    Type: AWS::AutoScaling::ScalingPolicy
    Properties:
      AutoScalingGroupName: !Ref AutoScalingGroup
      PolicyType: TargetTrackingScaling
      EstimatedInstanceWarmup: 120
      TargetTrackingConfiguration:
        TargetValue: 60
        PredefinedMetricSpecification:
          PredefinedMetricType: ASGAverageCPUUtilization

  # ----------------------------------------------------------------- observability
  UnhealthyHostsAlarm:
    Type: AWS::CloudWatch::Alarm
    Properties:
      AlarmName: !Sub '${ProjectName}-unhealthy-hosts'
      AlarmDescription: Any unhealthy target for 2 consecutive minutes.
      Namespace: AWS/ApplicationELB
      MetricName: UnHealthyHostCount
      Statistic: Maximum
      Period: 60
      EvaluationPeriods: 2
      Threshold: 0
      ComparisonOperator: GreaterThanThreshold
      TreatMissingData: notBreaching
      Dimensions:
        - Name: LoadBalancer
          Value: !GetAtt Alb.LoadBalancerFullName
        - Name: TargetGroup
          Value: !GetAtt TargetGroup.TargetGroupFullName

  Elb5xxAlarm:
    Type: AWS::CloudWatch::Alarm
    Properties:
      AlarmName: !Sub '${ProjectName}-elb-5xx'
      AlarmDescription: >-
        ALB-generated 5xx. This is the stop condition for the AZ fault
        injection experiment: if the multi-AZ claim is false, this fires.
      Namespace: AWS/ApplicationELB
      MetricName: HTTPCode_ELB_5XX_Count
      Statistic: Sum
      Period: 60
      EvaluationPeriods: 1
      Threshold: 10
      ComparisonOperator: GreaterThanThreshold
      TreatMissingData: notBreaching
      Dimensions:
        - Name: LoadBalancer
          Value: !GetAtt Alb.LoadBalancerFullName

Outputs:
  AlbDnsName:
    Description: Public endpoint
    Value: !Sub 'http://${Alb.DNSName}'

  ZoneAName:
    Description: AZ name used for subnet A (account-specific label)
    Value: !GetAtt PrivateSubnetA.AvailabilityZone

  ZoneAId:
    Description: >-
      PHYSICAL AZ identifier for subnet A. Use THIS value in runbooks,
      zonal shifts and cross-account correlation - never the AZ name.
    Value: !GetAtt PrivateSubnetA.AvailabilityZoneId

  ZoneBId:
    Value: !GetAtt PrivateSubnetB.AvailabilityZoneId

  ZoneCId:
    Value: !GetAtt PrivateSubnetC.AvailabilityZoneId

  AutoScalingGroupName:
    Value: !Ref AutoScalingGroup

  Elb5xxAlarmArn:
    Description: Stop condition ARN for the FIS experiment
    Value: !GetAtt Elb5xxAlarm.Arn
```

### 5.2 Warm pool — the elasticity accelerator, and its constraint

A warm pool cuts time-to-capacity from minutes to tens of seconds by pre-bootstrapping instances and leaving them stopped. **Warm pools do not support Spot Instances**, so this resource belongs to an On-Demand-only ASG, not to the `MixedInstancesPolicy` group above.

```yaml
  # Attach to an On-Demand-only ASG. Not compatible with Spot in the
  # mixed instances policy.
  WarmPool:
    Type: AWS::AutoScaling::WarmPool
    Properties:
      AutoScalingGroupName: !Ref OnDemandAutoScalingGroup
      PoolState: Stopped        # Stopped = cheapest (EBS only, no compute charge)
                                # Running = fastest, full instance charge
                                # Hibernated = fast + warm page cache, EBS charge
      MinSize: 3
      MaxGroupPreparedCapacity: 12
      InstanceReusePolicy:
        ReuseOnScaleIn: true    # returning scaled-in instances to the pool
                                # avoids paying the bootstrap cost twice
```

| Pool state | Cost while idle | Time to in-service | Use when |
|---|---|---|---|
| `Stopped` | EBS storage only | ~20–45 s | Default; bootstrap is the slow part |
| `Hibernated` | EBS storage (incl. RAM image) | ~15–30 s | Large in-memory caches / JIT warm-up |
| `Running` | Full instance price | ~5–15 s | Sub-minute demand doubling, high revenue-per-second |

### 5.3 Terraform equivalent of the AZ-selection logic

```hcl
terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

provider "aws" {
  region = var.region
}

variable "region"       { type = string, default = "us-east-1" }
variable "vpc_cidr"     { type = string, default = "10.42.0.0/16" }
variable "instance_type" { type = string, default = "m7i.large" }

# Only AZs that are BOTH available AND actually offer the instance type we
# intend to launch. Filtering on availability alone is the bug that produces
# a permanently unbalanced ASG.
data "aws_availability_zones" "available" {
  state = "available"
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]   # excludes Local/Wavelength zones
  }
}

data "aws_ec2_instance_type_offerings" "usable" {
  filter {
    name   = "instance-type"
    values = [var.instance_type]
  }
  filter {
    name   = "location"
    values = data.aws_availability_zones.available.names
  }
  location_type = "availability-zone"
}

locals {
  usable_azs = sort(data.aws_ec2_instance_type_offerings.usable.locations)
  azs        = slice(local.usable_azs, 0, min(3, length(local.usable_azs)))
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = { Name = "clf-benefits-vpc" }
}

resource "aws_subnet" "private" {
  for_each = { for idx, az in local.azs : az => idx }

  vpc_id            = aws_vpc.main.id
  availability_zone = each.key
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, each.value + 3)

  tags = {
    Name = "clf-benefits-private-${each.key}"
    # Record the PHYSICAL zone as a tag so an audit does not have to
    # re-resolve the account-specific name mapping.
    AvailabilityZoneId = data.aws_availability_zones.available.zone_ids[
      index(data.aws_availability_zones.available.names, each.key)
    ]
  }
}

output "az_name_to_id" {
  description = "The account-specific mapping. Put this in the runbook."
  value = zipmap(
    data.aws_availability_zones.available.names,
    data.aws_availability_zones.available.zone_ids,
  )
}

output "selected_azs" {
  value = local.azs
}
```

### 5.4 The same property in Kubernetes (EKS) — AZ spread is not automatic

Running on EKS does not give you AZ redundancy for free. The scheduler will happily place every replica on one node in one AZ. You must declare the constraint:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: checkout
  namespace: shop
spec:
  replicas: 6
  selector:
    matchLabels:
      app: checkout
  template:
    metadata:
      labels:
        app: checkout
    spec:
      # Hard requirement: replicas differ by at most 1 across AZs. If the
      # constraint cannot be met, the pod stays Pending rather than silently
      # collapsing the failure domain.
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app: checkout
          matchLabelKeys:
            - pod-template-hash          # spread per-revision, not across revisions
        # Soft requirement: also spread across nodes within a zone, so a single
        # node loss is not a zone-sized event.
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels:
              app: checkout
      containers:
        - name: checkout
          image: public.ecr.aws/nginx/nginx:1.27
          ports:
            - containerPort: 80
          resources:
            requests: { cpu: 250m, memory: 256Mi }
            limits:   { memory: 512Mi }
          readinessProbe:
            httpGet: { path: /healthz, port: 80 }
            periodSeconds: 5
---
# A PDB caps voluntary disruption. Without it, a node drain during an AZ event
# can remove the surviving capacity you were counting on.
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: checkout-pdb
  namespace: shop
spec:
  minAvailable: 4          # 6 replicas, 3 AZs -> lose one AZ (2 pods) and still serve
  selector:
    matchLabels:
      app: checkout
```

---

## 6. Economies of scale, made measurable

### 6.1 Purchase options — the actual trade-off table

| Option | Discount vs On-Demand (order of magnitude) | Commitment | Flexibility | Interruption risk | Fits |
|---|---|---|---|---|---|
| **On-Demand** | baseline | none | total | none | Spiky, unpredictable, short-lived, dev |
| **Spot** | up to ~90% | none | any type/AZ | Yes — **2-minute** interruption notice | Stateless, fault-tolerant, batch, CI, big data |
| **Compute Savings Plan** | up to ~66% | 1 or 3 yr, $/hr | Any instance family, size, Region, OS, tenancy; also Fargate and Lambda | none | Default commitment vehicle |
| **EC2 Instance Savings Plan** | up to ~72% | 1 or 3 yr, $/hr | Locked to family + Region; size/OS/AZ flexible | none | Stable family choice |
| **Standard Reserved Instance** | up to ~72% | 1 or 3 yr, capacity-shaped | Size-flexible within family/Region | none | Legacy; Savings Plans generally supersede |
| **Convertible RI** | up to ~66% | 1 or 3 yr | Exchangeable for other families | none | Uncertain long-term family |
| **On-Demand Capacity Reservation** | none (you pay to *hold* capacity) | none (or with a discount instrument) | Zonal | none | Guaranteed capacity in a specific AZ |
| **Dedicated Host** | varies | optional | Host-level | none | BYOL licensing bound to sockets/cores |

**The layering that a mature account actually runs:** Savings Plans cover the *always-on floor*; On-Demand covers the *predictable variable band*; Spot covers the *interruptible surplus*. Coverage targets of 70–80% Savings Plan coverage on the floor are common; committing to 100% removes the option value that made the cloud attractive in the first place.

**Spot's real contract:** you get a 2-minute interruption notice via instance metadata and EventBridge. Handle it or lose in-flight work:

```bash
$ TOKEN=$(curl -sX PUT http://169.254.169.254/latest/api/token \
      -H 'X-aws-ec2-metadata-token-ttl-seconds: 21600')
$ curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
      -w '%{http_code}\n' -o /dev/null \
      http://169.254.169.254/latest/meta-data/spot/instance-action
404          # 404 = no interruption pending. 200 = you have ~120 seconds.
```

### 6.2 Query real prices instead of quoting a slide

The Price List API is the authoritative source. Note it is only served from a few Regions (`us-east-1`, `ap-south-1`, `eu-central-1`) regardless of which Region you are pricing.

```bash
$ aws pricing get-products \
    --region us-east-1 \
    --service-code AmazonEC2 \
    --filters \
        'Type=TERM_MATCH,Field=instanceType,Value=m7i.large' \
        'Type=TERM_MATCH,Field=regionCode,Value=us-east-1' \
        'Type=TERM_MATCH,Field=operatingSystem,Value=Linux' \
        'Type=TERM_MATCH,Field=tenancy,Value=Shared' \
        'Type=TERM_MATCH,Field=preInstalledSw,Value=NA' \
        'Type=TERM_MATCH,Field=capacitystatus,Value=Used' \
    --output json \
  | jq -r '.PriceList[] | fromjson
           | .terms.OnDemand[].priceDimensions[]
           | "\(.pricePerUnit.USD) USD per \(.unit) - \(.description)"'
0.1008000000 USD per Hrs - $0.1008 per On Demand Linux m7i.large Instance Hour
```

Compare the same shape on Graviton to see the price/performance argument as a number, not a claim:

```bash
$ for t in m7i.large m7g.large; do
    p=$(aws pricing get-products --region us-east-1 --service-code AmazonEC2 \
        --filters "Type=TERM_MATCH,Field=instanceType,Value=$t" \
                  'Type=TERM_MATCH,Field=regionCode,Value=us-east-1' \
                  'Type=TERM_MATCH,Field=operatingSystem,Value=Linux' \
                  'Type=TERM_MATCH,Field=tenancy,Value=Shared' \
                  'Type=TERM_MATCH,Field=preInstalledSw,Value=NA' \
                  'Type=TERM_MATCH,Field=capacitystatus,Value=Used' \
        --output json | jq -r '.PriceList[0] | fromjson
                               | .terms.OnDemand[].priceDimensions[].pricePerUnit.USD')
    printf '%-12s %s USD/hr\n' "$t" "$p"
  done
m7i.large    0.1008000000 USD/hr
m7g.large    0.0816000000 USD/hr
```

Spot's current discount, live:

```bash
$ aws ec2 describe-spot-price-history \
    --instance-types m7i.large \
    --product-descriptions "Linux/UNIX" \
    --region us-east-1 \
    --start-time "$(date -u -d '-1 hour' +%Y-%m-%dT%H:%M:%SZ)" \
    --query 'sort_by(SpotPriceHistory,&AvailabilityZone)[].[AvailabilityZone,SpotPrice]' \
    --output table
--------------------------------
|  DescribeSpotPriceHistory    |
+---------------+--------------+
|  us-east-1a   |  0.036200    |
|  us-east-1b   |  0.034900    |
|  us-east-1c   |  0.041100    |
|  us-east-1d   |  0.033700    |
|  us-east-1f   |  0.038400    |
+---------------+--------------+
```

Note the price *varies by AZ* — capacity is a zonal resource, and so is its price. `price-capacity-optimized` in the ASG uses exactly this signal.

### 6.3 The cost that surprises people: cross-AZ data transfer

Three-AZ redundancy is not free at the network layer. EC2 traffic crossing AZ boundaries in the same Region is billed **per direction** (roughly $0.01/GB each way; verify on the pricing page). Traffic within one AZ over private IPv4 is free.

A chatty microservice mesh spread across 3 AZs sends ~2/3 of its internal traffic across a zone boundary by construction. Find it:

```bash
# Cost Explorer: the usage type for cross-AZ traffic is *-DataTransfer-Regional-Bytes
$ aws ce get-cost-and-usage \
    --time-period Start=2026-08-01,End=2026-09-01 \
    --granularity MONTHLY \
    --metrics UnblendedCost UsageQuantity \
    --filter '{"Dimensions":{"Key":"USAGE_TYPE_GROUP","Values":["EC2: Data Transfer - Region to Region"]}}' \
    --group-by Type=DIMENSION,Key=USAGE_TYPE \
    --output json | jq -r '.ResultsByTime[].Groups[]
        | "\(.Keys[0])  \(.Metrics.UsageQuantity.Amount|tonumber|floor) GB  $\(.Metrics.UnblendedCost.Amount)"'
USE1-DataTransfer-Regional-Bytes  41822 GB  $836.44
```

VPC Flow Logs v5 carry an `az-id` field; that is how you attribute the bytes to a *pair* of zones and find the offending service. The trade-off is explicit and must be made consciously:

| Choice | Availability | Cross-AZ $ | When |
|---|---|---|---|
| Spread service + spread callers, random routing | Best | Highest | Default; the money buys AZ independence |
| Zonal affinity (caller prefers same-AZ target, falls back cross-AZ) | Good, if fallback is real | Low | High-volume east-west; requires the fallback to be *tested* |
| Pin to one AZ | Poor | Zero | Never for production request paths |

**Warning on zonal affinity:** it silently converts your multi-AZ deployment into three single-AZ deployments *if the fallback path is untested*. Verify the fallback with fault injection (§8), not with a design review.

---

## 7. "Go global in minutes" — the deployment property

The claim is that geography is a parameter. Demonstrate it:

```bash
$ TAG=clf-benefits
$ for R in us-east-1 eu-west-1 ap-southeast-2; do
    aws cloudformation deploy \
      --region "$R" \
      --stack-name "$TAG" \
      --template-file clf-1-1-multi-az.yaml \
      --capabilities CAPABILITY_IAM \
      --parameter-overrides ProjectName="$TAG" VpcCidr=10.42.0.0/16 &
  done; wait

Waiting for changeset to be created..
Waiting for stack create/update to complete
Successfully created/updated stack - clf-benefits
Waiting for changeset to be created..
Waiting for stack create/update to complete
Successfully created/updated stack - clf-benefits
Waiting for changeset to be created..
Waiting for stack create/update to complete
Successfully created/updated stack - clf-benefits
```

Three continents, one template, no AMI mapping — because `LatestAmiId` resolves per Region from a public SSM parameter and `Fn::GetAZs` resolves per Region/account.

```bash
$ for R in us-east-1 eu-west-1 ap-southeast-2; do
    printf '%-16s ' "$R"
    aws cloudformation describe-stacks --region "$R" --stack-name clf-benefits \
      --query "Stacks[0].Outputs[?OutputKey=='AlbDnsName'].OutputValue" --output text
  done
us-east-1        http://clf-benefits-alb-1043928471.us-east-1.elb.amazonaws.com
eu-west-1        http://clf-benefits-alb-0418772315.eu-west-1.elb.amazonaws.com
ap-southeast-2   http://clf-benefits-alb-1877340296.ap-southeast-2.elb.amazonaws.com
```

### 7.1 What "global" actually buys, per mechanism

| Mechanism | What it reduces | Failover time | Data plane | Use when |
|---|---|---|---|---|
| **CloudFront** | Latency for cacheable content; TLS handshake RTT at the edge | N/A (origin failover groups: seconds) | Anycast edge PoPs | Static assets, API acceleration, DDoS absorption at the edge |
| **Route 53 latency routing** | Latency by steering DNS to the closest healthy Region | DNS TTL-bound: **60 s + client cache** | Client-resolved | Multi-Region active/active with tolerant clients |
| **Route 53 failover routing** | Regional outage exposure | DNS TTL-bound | Client-resolved | Active/passive DR |
| **Global Accelerator** | Latency *and* failover, via anycast static IPs on the AWS backbone | **Seconds**, no DNS dependency | AWS global network | Non-HTTP protocols, sticky clients, DNS-cache-hostile clients |
| **Aurora Global Database** | RPO for cross-Region data | RPO typically ~1 s; RTO typically < 1 min on managed failover | Storage-layer replication | Regional DR for relational data |
| **DynamoDB Global Tables** | RPO/RTO for key-value data | Multi-active; sub-second replication typical | Multi-Region multi-active | Write-anywhere workloads |
| **S3 Cross-Region Replication** | Object durability/locality across Regions | Asynchronous; S3 RTC offers a replication SLA | Object copy | Compliance, DR, data locality |

**The DNS trap, stated plainly:** Route 53 health-check failover is bounded below by client DNS caching, and a meaningful fraction of clients ignore TTLs. If your RTO is measured in seconds rather than minutes, you need Global Accelerator (anycast, no DNS re-resolution) — not a shorter TTL.

Illustrative RTTs (measure your own; these are the shape, not the value):

| Path | Typical RTT |
|---|---|
| Same AZ, private IP | < 1 ms |
| Cross-AZ, same Region | ~0.5–2 ms |
| us-east-1 ↔ us-west-2 | ~60–75 ms |
| us-east-1 ↔ eu-west-1 | ~70–90 ms |
| us-east-1 ↔ ap-southeast-2 | ~200–240 ms |
| End user ↔ nearest CloudFront PoP | ~5–30 ms |

**Consequence for architecture:** synchronous cross-Region writes are not viable for interactive request paths — at 80 ms RTT, a two-phase commit costs 160 ms *before* any work. This is why RDS Multi-AZ is synchronous (single-digit ms) and Aurora Global Database is asynchronous. The physics of the latency table *is* the reason the Region is the isolation boundary and the AZ is the redundancy boundary.

---

## 8. Verification and failure diagnosis

Everything above is a claim until you verify it in the account. This section is the runbook.

### 8.1 Verification ladder

**Step 1 — Confirm the physical spread (not the labels).**

```bash
$ aws ec2 describe-subnets \
    --filters "Name=tag:Name,Values=clf-benefits-private-*" \
    --query 'sort_by(Subnets,&AvailabilityZoneId)[].[SubnetId,AvailabilityZone,AvailabilityZoneId,CidrBlock,AvailableIpAddressCount]' \
    --output table
------------------------------------------------------------------------------------------
|                                    DescribeSubnets                                      |
+---------------------+--------------+------------+------------------+------------------+
|  subnet-0a3f81c22e  |  us-east-1b  |  use1-az1  |  10.42.4.0/24    |  251             |
|  subnet-07b9d4e610  |  us-east-1c  |  use1-az2  |  10.42.5.0/24    |  251             |
|  subnet-0c1e77a934  |  us-east-1a  |  use1-az6  |  10.42.3.0/24    |  251             |
+---------------------+--------------+------------+------------------+------------------+
```
**Pass criterion:** three *distinct* `AvailabilityZoneId` values. Distinct AZ *names* prove nothing on their own — but distinct IDs do, and here they are `use1-az1/az2/az6`.

**Step 2 — Confirm the ALB actually spans them.**

```bash
$ aws elbv2 describe-load-balancers --names clf-benefits-alb \
    --query 'LoadBalancers[0].AvailabilityZones[].[ZoneName,SubnetId]' --output table
-----------------------------------------
|        DescribeLoadBalancers          |
+--------------+------------------------+
|  us-east-1a  |  subnet-0d2c99f781     |
|  us-east-1b  |  subnet-0b8e13a746     |
|  us-east-1c  |  subnet-06fa2e5c30     |
+-----------------------------------------
```

**Step 3 — Confirm capacity is balanced *and healthy* per zone.** Unbalanced-but-InService is the silent killer: the console shows green while one AZ carries 60% of traffic.

```bash
$ aws autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names clf-benefits-asg \
    --query 'AutoScalingGroups[0].Instances[].[AvailabilityZone,InstanceId,LifecycleState,HealthStatus,InstanceType]' \
    --output text | sort | awk '{print} {c[$1]++} END {print "---"; for (z in c) printf "%s: %d\n", z, c[z]}'
us-east-1a      i-0a4c81de2f31b9077     InService       Healthy m7i.large
us-east-1a      i-0f1b6d0c93aa5e412     InService       Healthy m5.large
us-east-1b      i-02d7e94a1c8f3b650     InService       Healthy m7i.large
us-east-1b      i-0be3517fa2069cd84     InService       Healthy m6i.large
us-east-1c      i-064a2fbb7e91d3c05     InService       Healthy m7i.large
us-east-1c      i-09e8c31d05b7fa246     InService       Healthy m5a.large
---
us-east-1a: 2
us-east-1b: 2
us-east-1c: 2
```

**Step 4 — Confirm target health per zone at the load balancer.**

```bash
$ TG=$(aws elbv2 describe-target-groups --names clf-benefits-tg \
       --query 'TargetGroups[0].TargetGroupArn' --output text)
$ aws elbv2 describe-target-health --target-group-arn "$TG" \
    --query 'TargetHealthDescriptions[].[Target.Id,Target.AvailabilityZone,TargetHealth.State,TargetHealth.Reason]' \
    --output table
-------------------------------------------------------------------------
|                         DescribeTargetHealth                           |
+-----------------------+--------------+----------+---------------------+
|  i-0a4c81de2f31b9077  |  us-east-1a  |  healthy |  None               |
|  i-0f1b6d0c93aa5e412  |  us-east-1a  |  healthy |  None               |
|  i-02d7e94a1c8f3b650  |  us-east-1b  |  healthy |  None               |
|  i-0be3517fa2069cd84  |  us-east-1b  |  healthy |  None               |
|  i-064a2fbb7e91d3c05  |  us-east-1c  |  healthy |  None               |
|  i-09e8c31d05b7fa246  |  us-east-1c  |  healthy |  None               |
+-----------------------+--------------+----------+---------------------+
```

**Step 5 — Confirm the endpoint returns from all three zones.**

```bash
$ URL=$(aws cloudformation describe-stacks --stack-name clf-benefits \
        --query "Stacks[0].Outputs[?OutputKey=='AlbDnsName'].OutputValue" --output text)
$ for i in $(seq 1 30); do curl -s "$URL/index.html"; done | sort | uniq -c
     10 zone=us-east-1a zone_id=use1-az6
     10 zone=us-east-1b zone_id=use1-az1
     10 zone=us-east-1c zone_id=use1-az2
```
Even distribution across three *physical* zones. **That is the multi-AZ claim, verified.**

### 8.2 Prove it by breaking it — AWS Fault Injection Service

A design review does not prove AZ independence. A controlled failure does.

```yaml
  FisRole:
    Type: AWS::IAM::Role
    Properties:
      AssumeRolePolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Effect: Allow
            Principal:
              Service: fis.amazonaws.com
            Action: sts:AssumeRole
      Policies:
        - PolicyName: fis-network-disruption
          PolicyDocument:
            Version: '2012-10-17'
            Statement:
              - Effect: Allow
                Action:
                  - ec2:DescribeSubnets
                  - ec2:DescribeVpcs
                  - ec2:DescribeRouteTables
                  - ec2:DescribeNetworkAcls
                  - ec2:CreateNetworkAcl
                  - ec2:CreateNetworkAclEntry
                  - ec2:CreateTags
                  - ec2:DeleteNetworkAcl
                  - ec2:ReplaceNetworkAclAssociation
                Resource: '*'
              - Effect: Allow
                Action: cloudwatch:DescribeAlarms
                Resource: '*'

  AzDisruptionExperiment:
    Type: AWS::FIS::ExperimentTemplate
    Properties:
      Description: >-
        Sever connectivity for one AZ's private subnet and assert that the ALB
        continues to serve from the surviving two zones with zero ELB 5xx.
      RoleArn: !GetAtt FisRole.Arn
      StopConditions:
        # If the multi-AZ claim is FALSE, this alarm fires and the experiment
        # halts automatically. The stop condition IS the hypothesis.
        - Source: aws:cloudwatch:alarm
          Value: !GetAtt Elb5xxAlarm.Arn
      Targets:
        TargetSubnet:
          ResourceType: aws:ec2:subnet
          SelectionMode: ALL
          ResourceArns:
            - !Sub 'arn:${AWS::Partition}:ec2:${AWS::Region}:${AWS::AccountId}:subnet/${PrivateSubnetC}'
      Actions:
        DisruptZone:
          ActionId: 'aws:network:disrupt-connectivity'
          Description: Block all traffic in the target subnet for 10 minutes
          Parameters:
            scope: all
            duration: PT10M
          Targets:
            Subnets: TargetSubnet
      Tags:
        Name: clf-1-1-az-disruption
        Hypothesis: 'Losing one AZ produces zero customer-visible errors'
```

Run it and watch:

```bash
$ EXP_ID=$(aws fis list-experiment-templates \
    --query "experimentTemplates[?tags.Name=='clf-1-1-az-disruption'].id" --output text)
$ aws fis start-experiment --experiment-template-id "$EXP_ID" \
    --query 'experiment.{Id:id,State:state.status}' --output json
{
    "Id": "EXPzT7pB4Qm9YkR2",
    "State": "initiating"
}

$ aws fis get-experiment --id EXPzT7pB4Qm9YkR2 \
    --query 'experiment.{State:state.status,Reason:state.reason}' --output json
{
    "State": "running",
    "Reason": "Experiment is running."
}

# The observable: traffic redistributes to the two surviving zones.
$ for i in $(seq 1 30); do curl -s --max-time 3 "$URL/index.html"; done | sort | uniq -c
     15 zone=us-east-1a zone_id=use1-az6
     15 zone=us-east-1b zone_id=use1-az1
```

**Pass criterion:** zero non-200 responses, and the impaired zone drops out of the rotation. If you see `503 Service Temporarily Unavailable`, the multi-AZ claim was false and you have found out in a controlled window rather than at 03:00.

### 8.3 The operator's mitigation: zonal shift

Zonal shift moves traffic *away* from a physical AZ in seconds, without a deployment, without a DNS change.

```bash
$ ALB_ARN=$(aws elbv2 describe-load-balancers --names clf-benefits-alb \
            --query 'LoadBalancers[0].LoadBalancerArn' --output text)

$ aws arc-zonal-shift list-managed-resources \
    --query "items[?name=='clf-benefits-alb'].[arn,appliedWeights]" --output json
[
    [
        "arn:aws:elasticloadbalancing:us-east-1:111122223333:loadbalancer/app/clf-benefits-alb/1a2b3c4d5e6f7890",
        {}
    ]
]

# NOTE: --away-from takes the AZ *ID*, not the AZ name. This is why §2.1 matters.
$ aws arc-zonal-shift start-zonal-shift \
    --resource-identifier "$ALB_ARN" \
    --away-from use1-az2 \
    --expires-in 6h \
    --comment "INC-4471: elevated p99 and connection resets isolated to use1-az2"
{
    "zonalShiftId": "9f13c0b8-7a44-4d2e-9c31-5b0e21a7d6f2",
    "resourceIdentifier": "arn:aws:elasticloadbalancing:us-east-1:111122223333:loadbalancer/app/clf-benefits-alb/1a2b3c4d5e6f7890",
    "awayFrom": "use1-az2",
    "expiryTime": "2026-09-03T20:11:47+00:00",
    "startTime": "2026-09-03T14:11:47+00:00",
    "status": "ACTIVE",
    "comment": "INC-4471: elevated p99 and connection resets isolated to use1-az2"
}

$ aws arc-zonal-shift cancel-zonal-shift --zonal-shift-id 9f13c0b8-7a44-4d2e-9c31-5b0e21a7d6f2
```

**The precondition nobody checks until it is too late:** a zonal shift only works if the surviving zones have capacity to absorb the shifted load. With three AZs at 100% utilization, shifting away from one puts 150% of capacity demand on the remaining two. **Pre-scaled headroom is what makes zonal shift a mitigation rather than a way to convert a partial outage into a total one.**

### 8.4 Failure signature reference

| Symptom | Root cause | Diagnostic command | Remediation |
|---|---|---|---|
| `InsufficientInstanceCapacity` on launch | AWS has no capacity for *that type* in *that AZ* right now. **Not** a quota issue. | `aws autoscaling describe-scaling-activities --auto-scaling-group-name <asg> --max-items 5` | Add instance types to `MixedInstancesPolicy` overrides; add AZs; use ODCR or Capacity Blocks for guaranteed capacity |
| `VcpuLimitExceeded` / `InstanceLimitExceeded` | Your **service quota**, not AWS capacity | `aws service-quotas get-service-quota --service-code ec2 --quota-code L-1216C47A` | Request an increase; quotas are per-Region |
| ASG only launches in 2 of 3 AZs | Third subnet's AZ does not offer any instance type in the overrides | `aws ec2 describe-instance-type-offerings --location-type availability-zone-id --filters Name=location,Values=use1-az3` | Change the AZ or broaden the type list |
| Instances launch but never become `InService` | Health check grace period shorter than boot+bootstrap; or app not on the health-check port | `aws elbv2 describe-target-health --target-group-arn <tg>` → look at `TargetHealth.Reason` | Raise `HealthCheckGracePeriod`; verify SG allows ALB→app port |
| `Target.FailedHealthChecks` | App returns non-matching status, wrong path, or is bound to `127.0.0.1` | From the instance: `curl -sv localhost:8080/healthz` via SSM Session Manager | Fix bind address / path / `Matcher.HttpCode` |
| `Elb.InternalError` in target health | ALB-side issue; frequently subnet with too few free IPs | `aws ec2 describe-subnets --query 'Subnets[].[SubnetId,AvailableIpAddressCount]'` | ALB needs ≥8 free IPs per subnet to scale; use /27 or larger, /24 recommended |
| Traffic heavily skewed to one AZ | Cross-zone load balancing disabled on the target group; or unbalanced target counts | `aws elbv2 describe-target-group-attributes --target-group-arn <tg>` | Set `load_balancing.cross_zone.enabled=true`; rebalance the ASG |
| **All** targets unhealthy → users still get responses | ALB **fail-open**: when every target in every AZ is unhealthy, the ALB routes to all targets rather than serving nothing | `HealthyHostCount` = 0 while `RequestCount` > 0 | Do not rely on it — treat `HealthyHostCount == 0` as a page-worthy alarm |
| Instances in one AZ lose internet egress | Single NAT Gateway; its AZ failed | `aws ec2 describe-route-tables --query 'RouteTables[].Routes[?NatGatewayId!=null]'` | `PerAzNatGateway=true` — one NAT per AZ, per-AZ private route table |
| Sudden cross-AZ transfer cost spike | New chatty service deployed without zonal affinity; or a client library that ignores AZ hints | Cost Explorer on `*-DataTransfer-Regional-Bytes`; VPC Flow Logs grouped by `az-id` | Evaluate zonal affinity **with a tested cross-AZ fallback** |
| CloudFormation `CREATE_FAILED: The number of AZs is less than requested` | Region has fewer usable AZs than the template's `Fn::Select` index | `aws ec2 describe-availability-zones --region <r> --query 'length(AvailabilityZones)'` | Parameterize AZ count; do not hard-code three |
| Spot instances churn constantly | Poor instance-type diversification; allocation strategy is `lowest-price` | `aws ec2 describe-spot-price-history`; ASG activity log | Switch to `price-capacity-optimized`; add 6–10 type/AZ combinations |
| Instance launches but fails immediately, no console output | Architecture mismatch: `arm64` type override against an `x86_64` AMI | Compare `aws ec2 describe-images --image-ids <ami> --query 'Images[0].Architecture'` with the override list | Keep one architecture per launch template, or use per-override `LaunchTemplateSpecification` |

### 8.5 Quota check — because "unlimited capacity" is a marketing statement

Elasticity is bounded by *your* quotas long before it is bounded by AWS's capacity.

```bash
$ aws service-quotas get-service-quota \
    --service-code ec2 \
    --quota-code L-1216C47A \
    --query 'Quota.{Name:QuotaName,Value:Value,Adjustable:Adjustable,Unit:Unit}' --output json
{
    "Name": "Running On-Demand Standard (A, C, D, H, I, M, R, T, Z) instances",
    "Value": 640.0,
    "Adjustable": true,
    "Unit": "None"
}
```
That is **640 vCPUs**, not 640 instances — so an `m7i.large` (2 vCPU) fleet caps at 320 instances. A `MaxSize` above the quota is a scaling failure waiting for a traffic spike.

```bash
# Track headroom as a first-class metric: CloudWatch usage metrics vs the quota.
$ aws cloudwatch get-metric-statistics \
    --namespace AWS/Usage \
    --metric-name ResourceCount \
    --dimensions Name=Service,Value=EC2 Name=Type,Value=Resource \
                 Name=Resource,Value=vCPU Name=Class,Value=Standard/OnDemand \
    --start-time "$(date -u -d '-1 hour' +%Y-%m-%dT%H:%M:%SZ)" \
    --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --period 300 --statistics Maximum \
    --query 'sort_by(Datapoints,&Timestamp)[-1].Maximum' --output text
188.0
```
188 of 640 vCPUs in use — 29% of quota. Alarm at 70%, not at 100%.

### 8.6 Verify the Region-selection decision

Region choice is the exam's "benefits" question in disguise: **latency, compliance/data residency, service availability, and cost** — in that priority order for most workloads.

```bash
$ for R in us-east-1 us-west-2 eu-west-1 sa-east-1; do
    printf '%-14s ' "$R"
    curl -s -o /dev/null -w '%{time_connect}\n' "https://ec2.${R}.amazonaws.com" 
  done
us-east-1      0.021483
us-west-2      0.071204
eu-west-1      0.089771
sa-east-1      0.148392

# Cost differential for the identical shape, same command as 6.2
$ for R in us-east-1 sa-east-1; do
    printf '%-12s ' "$R"
    aws pricing get-products --region us-east-1 --service-code AmazonEC2 \
      --filters 'Type=TERM_MATCH,Field=instanceType,Value=m7i.large' \
                "Type=TERM_MATCH,Field=regionCode,Value=$R" \
                'Type=TERM_MATCH,Field=operatingSystem,Value=Linux' \
                'Type=TERM_MATCH,Field=tenancy,Value=Shared' \
                'Type=TERM_MATCH,Field=preInstalledSw,Value=NA' \
                'Type=TERM_MATCH,Field=capacitystatus,Value=Used' \
      --output json | jq -r '.PriceList[0] | fromjson
                             | .terms.OnDemand[].priceDimensions[].pricePerUnit.USD'
  done
us-east-1    0.1008000000
sa-east-1    0.1710000000
```
Same instance, ~70% more in São Paulo. If your users are in Brazil, the latency win is usually worth it; if they are not, this is a pure cost leak. **Region price varies; that is a benefit-analysis input, not a footnote.**

---

## 9. On-premises vs AWS — the honest comparison

| Dimension | Traditional data center | AWS Cloud | Where AWS is *not* automatically better |
|---|---|---|---|
| Capital model | CapEx, 3–5 yr depreciation | OpEx, per-second metering | Steady, flat, fully-utilized workloads with a 5+ yr horizon can be cheaper on-prem |
| Time to capacity | Weeks to months | Seconds to minutes | Specialized hardware with long AWS lead times or limited Regional availability |
| Utilization | Typically 10–20% (sized to peak) | Matches demand | Only if you actually implement autoscaling and rightsizing |
| Failure domains | Inherited from the facility | Chosen: AZ, Region, cell | You must *design* for them; a lift-and-shift single instance is less reliable than nothing changed |
| Undifferentiated work | Power, cooling, racking, hardware RMA, firmware | AWS's responsibility | New undifferentiated work appears: IAM, tagging, cost governance, quota management |
| Cost predictability | High (fixed) | Variable — requires active governance | Uncontrolled cloud spend is a real failure mode; Budgets/Anomaly Detection are mandatory, not optional |
| Compliance | You attest everything | Inherit AWS's certifications for infrastructure controls | You still own everything above the hypervisor line |
| Scale ceiling | Your purchase order | Quota + AWS capacity | Not infinite; see §8.5 |
| Egress cost | Flat-rate transit | Per-GB, and it adds up | Data-egress-heavy businesses must model this explicitly |

**The Shared Responsibility line is what "stop maintaining data centers" actually means:** AWS is responsible for security **of** the cloud (hardware, facilities, the virtualization layer, managed-service internals); you are responsible for security **in** the cloud (your data, IAM, OS patching on EC2, network configuration, encryption choices). The boundary shifts with the service model — for Lambda and S3 AWS owns much more of the stack than for EC2. That shift is precisely the "move up the value chain" benefit.

**Migration benefits the exam names:** the 7 Rs — Rehost, Replatform, Repurchase, Refactor, Retire, Retain, Relocate — and the AWS Cloud Adoption Framework (CAF) perspectives: Business, People, Governance, Platform, Security, Operations. CLF-C02 expects recognition of these terms, not application of them.

---

## 10. Distillation for the exam

**Recognize these mappings instantly:**

| Scenario phrase in a question | Correct concept |
|---|---|
| "Pay only for what you use, no upfront hardware" | Trade fixed expense for variable expense |
| "AWS's purchasing power gives lower prices than we could get" | Economies of scale |
| "Automatically add and remove capacity as traffic changes" | Elasticity |
| "Handle more load by adding resources" | Scalability |
| "Deploy to a new country in minutes" | Global reach / go global in minutes |
| "Keep running when one data center fails" | High availability (Multi-AZ) |
| "Recover in another geography after a regional disaster" | Disaster recovery (Multi-Region) |
| "Try an idea this afternoon and delete it tomorrow" | Agility |
| "Stop racking servers and patching firmware" | Stop spending money running data centers |
| "Reduce the time it takes to get new resources" | Agility / speed |

**Boundary facts most often missed:**
- An AZ is **one or more** discrete data centers — not exactly one.
- Data is **not** automatically replicated across Regions; you must configure it.
- AZ **names** are randomized per account; AZ **IDs** are physical.
- **Every Region has a minimum of three AZs.**
- **Not every service is available in every Region.**
- Elasticity ≠ scalability ≠ agility ≠ economies of scale — four distinct answers.
- An SLA is a service-credit contract, not a design target.
- Edge locations serve CloudFront/Route 53/Global Accelerator; they are **not** an AZ substitute for compute HA.
- Capacity is not infinite: **service quotas** bound it, and quotas are per-Region.

---

## 11. References

**Certification and exam**
- AWS Certified Cloud Practitioner (CLF-C02) Exam Guide — https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf
- AWS Certified Cloud Practitioner — https://aws.amazon.com/certification/certified-cloud-practitioner/

**Cloud value proposition and adoption**
- Overview of Amazon Web Services (AWS Whitepaper) — https://docs.aws.amazon.com/whitepapers/latest/aws-overview/introduction.html
- AWS Cloud Adoption Framework (AWS CAF) — https://docs.aws.amazon.com/whitepapers/latest/overview-aws-cloud-adoption-framework/welcome.html
- How AWS Pricing Works — https://docs.aws.amazon.com/whitepapers/latest/how-aws-pricing-works/welcome.html
- Shared Responsibility Model — https://aws.amazon.com/compliance/shared-responsibility-model/

**Global infrastructure**
- AWS Global Infrastructure — https://aws.amazon.com/about-aws/global-infrastructure/
- Regions and Availability Zones — https://aws.amazon.com/about-aws/global-infrastructure/regions_az/
- Regions, Availability Zones, Local Zones (EC2 User Guide) — https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/using-regions-availability-zones.html
- AZ IDs for your resources — https://docs.aws.amazon.com/ram/latest/userguide/working-with-az-ids.html
- Global infrastructure public parameters in Parameter Store — https://docs.aws.amazon.com/systems-manager/latest/userguide/parameter-store-public-parameters-global-infrastructure.html
- AWS Local Zones — https://docs.aws.amazon.com/local-zones/latest/ug/what-is-aws-local-zones.html
- AWS Outposts — https://docs.aws.amazon.com/outposts/latest/userguide/what-is-outposts.html

**Reliability, HA and elasticity**
- AWS Well-Architected Framework — https://docs.aws.amazon.com/wellarchitected/latest/framework/welcome.html
- Reliability Pillar — https://docs.aws.amazon.com/wellarchitected/latest/reliability-pillar/welcome.html
- Amazon EC2 Auto Scaling User Guide — https://docs.aws.amazon.com/autoscaling/ec2/userguide/what-is-amazon-ec2-auto-scaling.html
- Target tracking scaling policies — https://docs.aws.amazon.com/autoscaling/ec2/userguide/as-scaling-target-tracking.html
- Predictive scaling — https://docs.aws.amazon.com/autoscaling/ec2/userguide/ec2-auto-scaling-predictive-scaling.html
- Warm pools for Amazon EC2 Auto Scaling — https://docs.aws.amazon.com/autoscaling/ec2/userguide/ec2-auto-scaling-warm-pools.html
- Auto Scaling groups with multiple instance types and purchase options — https://docs.aws.amazon.com/autoscaling/ec2/userguide/ec2-auto-scaling-mixed-instances-groups.html
- Application Load Balancer — https://docs.aws.amazon.com/elasticloadbalancing/latest/application/introduction.html
- Cross-zone load balancing — https://docs.aws.amazon.com/elasticloadbalancing/latest/userguide/how-elastic-load-balancing-works.html
- Amazon Application Recovery Controller — zonal shift — https://docs.aws.amazon.com/r53recovery/latest/dg/arc-zonal-shift.html
- Zonal shift in Amazon EC2 Auto Scaling — https://docs.aws.amazon.com/autoscaling/ec2/userguide/ec2-auto-scaling-zonal-shift.html
- AWS Fault Injection Service — https://docs.aws.amazon.com/fis/latest/userguide/what-is.html

**Cost and economies of scale**
- Amazon EC2 On-Demand pricing — https://aws.amazon.com/ec2/pricing/on-demand/
- Compute Savings Plans pricing — https://aws.amazon.com/savingsplans/compute-pricing/
- Amazon EC2 Spot Instances — https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/using-spot-instances.html
- Spot Instance interruption notices — https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/spot-instance-termination-notices.html
- AWS Price List API — https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/price-changes.html
- AWS Cost Explorer — https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/ce-what-is.html
- Amazon VPC pricing (data transfer) — https://aws.amazon.com/vpc/pricing/
- NAT Gateway pricing and design — https://docs.aws.amazon.com/vpc/latest/userguide/vpc-nat-gateway.html

**Service levels and quotas**
- AWS Compute SLA (EC2, ECS, EKS, Fargate, Lambda) — https://aws.amazon.com/compute/sla/
- Elastic Load Balancing SLA — https://aws.amazon.com/elasticloadbalancing/sla/
- All AWS Service Level Agreements — https://aws.amazon.com/legal/service-level-agreements/
- Service Quotas User Guide — https://docs.aws.amazon.com/servicequotas/latest/userguide/intro.html
- Troubleshoot instance launch issues (InsufficientInstanceCapacity) — https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/troubleshooting-launch.html

**Global delivery**
- Amazon CloudFront Developer Guide — https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/Introduction.html
- AWS Global Accelerator — https://docs.aws.amazon.com/global-accelerator/latest/dg/what-is-global-accelerator.html
- Amazon Route 53 routing policies — https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/routing-policy.html
- Aurora Global Database — https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/aurora-global-database.html
- DynamoDB Global Tables — https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/GlobalTables.html

**Infrastructure as code and Kubernetes**
- AWS CloudFormation template reference — https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/template-reference.html
- `Fn::Cidr` intrinsic function — https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/intrinsic-function-reference-cidr.html
- Terraform AWS provider — `aws_availability_zones` — https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/availability_zones
- Kubernetes Pod Topology Spread Constraints — https://kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints/
- Kubernetes Pod Disruption Budgets — https://kubernetes.io/docs/concepts/workloads/pods/disruptions/