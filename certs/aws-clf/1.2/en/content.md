# 1.2 — Identify design principles of the AWS Cloud

> **Exam context (CLF-C02).** Domain 1 "Cloud Concepts" is 24% of the exam; task statement 1.2 carries a relative weight of **6.0** in this syllabus. The exam guide scopes this task to *"identify design principles of the AWS Cloud"* — in practice, the **AWS Well-Architected Framework**: its six pillars, the design principles inside each pillar, the general design principles, and the review mechanism (the AWS Well-Architected Tool). This material treats the principles the way a Platform Architect has to treat them: as **falsifiable engineering constraints with measurable costs**, not as a poster on a wall.

---

## 1. The production problem these principles exist to solve

### 1.1 A failure narrative you have seen before

A payments API is lifted from a colocation facility into AWS. The migration is "successful": same three-tier topology, same Java monolith, same MySQL, running on EC2 instead of Dell hardware. Six weeks later:

```
02:14 UTC  us-east-1 AZ use1-az4 experiences degraded EBS I/O
02:14 UTC  app-01, app-02, app-03 (all in use1-az4) stop responding
02:15 UTC  ALB health checks fail -> 0 healthy targets -> HTTP 503 to all clients
02:15 UTC  RDS primary (single-AZ, use1-az4) unreachable
02:41 UTC  On-call finds the runbook is a Confluence page last edited 14 months ago
03:58 UTC  Manual restore from a 24h-old snapshot into use1-az1 begins
07:20 UTC  Service restored. RPO ~19 h of transactions. RTO 5 h 06 m.
```

Nothing here is an AWS defect. Every single failure mode was **designed in** by importing on-premises assumptions into an environment where those assumptions are false. The Well-Architected Framework is, at bottom, the catalogue of those invalidated assumptions.

### 1.2 The assumptions the cloud invalidates

| On-premises assumption | Why it held on-prem | Why it is false on AWS | Principle that replaces it |
|---|---|---|---|
| Hardware is scarce and slow to procure → **buy for peak, 3 years ahead** | 8–16 week lead time, capex cycle | API-provisioned capacity in seconds; you pay for what you use | *Stop guessing your capacity needs* |
| Servers are pets: named, patched in place, long-lived | Rebuilding meant a rack visit | Instances are cattle: an AMI + a launch template rebuilds one in 90 s | *Automatically recover from failure*; *make frequent, small, reversible changes* |
| Test environments are smaller than production | A second full datacenter is unaffordable | A production-scale clone costs hours of runtime, then is destroyed | *Test systems at production scale* |
| The DR plan is a document | Failover testing risked the only datacenter | Game days on real infrastructure with AWS FIS | *Test recovery procedures*; *improve through game days* |
| Vertical scaling is the scaling story | One big box was cheaper than many small ones | Horizontal scaling removes the single fault domain and the ceiling | *Scale horizontally to increase aggregate workload availability* |
| One datacenter = one failure domain, and that is that | You had one building | Multiple isolated AZs per Region, ≤ ~1 ms apart, are one API parameter away | *Design for failure*; multi-AZ as the default |
| Architecture is decided once, up front | Change meant re-procurement | Infrastructure as code makes architecture an experiment | *Allow for evolutionary architectures*; *automate to make architectural experimentation easier* |
| Cost is a fixed line item owned by Finance | Capex, amortised, invisible to engineers | Every engineer's `terraform apply` moves the bill | *Implement Cloud Financial Management*; *analyze and attribute expenditure* |

**The architect's takeaway:** a lift-and-shift is not a neutral act. It preserves the topology *and* the failure modes, while adding the cloud's cost model. The design principles exist to force the second half of the migration — the redesign — to actually happen.

---

## 2. The AWS Well-Architected Framework: structure and mechanics

### 2.1 The object model

The Framework is not prose; it is a queryable data model, which is why it can be driven from the CLI and embedded in CI.

```
Workload                      (the thing you review — an app + its infra + its people)
 └─ Lens                      (a question set: "wellarchitected" core, or serverless/SaaS/ML/…)
     └─ Pillar   × 6          (operationalExcellence, security, reliability,
     │                         performance, costOptimization, sustainability)
         └─ Question × ~58    (core lens; e.g. REL 11 "How do you design your workload
             │                 to withstand component failures?")
             └─ Best practice (choices you mark as implemented / not applicable)
                 └─ Risk      HIGH (HRI) | MEDIUM (MRI) | NONE | UNANSWERED
                             └─ Improvement Plan (links to prescriptive guidance)
Milestone                     (an immutable snapshot of all answers at a point in time)
```

**Why the milestone matters operationally:** a Well-Architected review with no milestone is an opinion. A milestone taken before and after a remediation quarter is a **measurement** — HRI count went from 14 to 3, and you can prove which questions moved.

### 2.2 The six pillars

| Pillar | Core question it answers | Primary metric an SRE owns | Signature AWS services |
|---|---|---|---|
| **Operational Excellence** | Can we run and evolve this safely and learn from it? | Change failure rate, MTTR, deployment frequency | CloudFormation, CDK, Systems Manager, CloudWatch, X-Ray, CodePipeline |
| **Security** | Can we protect data, systems and assets while delivering value? | % of privileged actions via humans, mean time to revoke, encryption coverage | IAM, IAM Identity Center, KMS, GuardDuty, Security Hub, CloudTrail, Config |
| **Reliability** | Does it do what it is supposed to, correctly and consistently, and recover? | Availability (SLO), RTO, RPO, error budget burn | Multi-AZ, Auto Scaling, Route 53, ELB, Backup, FIS, Resilience Hub |
| **Performance Efficiency** | Are we using compute resources efficiently as demand and technology change? | p99 latency, utilisation, throughput per vCPU | Graviton, Lambda, CloudFront, ElastiCache, Compute Optimizer, Aurora |
| **Cost Optimization** | Are we running at the lowest price point for the required outcome? | Unit cost ($ per 1 000 transactions), coverage of commitments, waste % | Cost Explorer, Budgets, Savings Plans, Spot, S3 Intelligent-Tiering |
| **Sustainability** | Are we minimising the environmental impact of the workload? | Utilisation, resources provisioned per unit of work | Graviton, Auto Scaling, Customer Carbon Footprint Tool, S3 lifecycle |

> **Historical note for the exam:** Sustainability was added in **December 2021** as the sixth pillar. Questions written against older material sometimes say "five pillars" — CLF-C02 uses six.

### 2.3 The six *general* design principles

These sit above the pillars and apply to the whole Framework.

| # | Principle | What it means mechanically | Anti-pattern it kills |
|---|---|---|---|
| 1 | **Stop guessing your capacity needs** | Auto Scaling driven by a real demand signal; scale in as well as out | The 3-year peak-sized fleet at 8% utilisation |
| 2 | **Test systems at production scale** | Spin up a full-size clone, run the load test, destroy it | "It worked in staging, which is 1/10th the size" |
| 3 | **Automate to make architectural experimentation easier** | IaC + pipelines, so trying a variant costs an hour, not a quarter | Snowflake environments built by hand |
| 4 | **Allow for evolutionary architectures** | Loose coupling and contracts, so a component can be replaced | The 2019 design frozen because nobody dares touch it |
| 5 | **Drive architectures using data** | CloudWatch/X-Ray/Cost Explorer decide, not seniority | "We use r5 because we always have" |
| 6 | **Improve through game days** | Scheduled, controlled fault injection against real infrastructure | The untested DR runbook |

**SRE reading:** #2 and #6 are the two that organisations skip, and they are the two that decide whether the other four are real. A "reliable" architecture that has never had an AZ removed from under it is an *untested hypothesis*.

---

## 3. The pillars, principle by principle

### 3.1 Operational Excellence

**Design principles**

1. **Organize teams around business outcomes** — the team that owns the outcome owns the pager.
2. **Implement observability for actionable insights** — metrics, logs and traces that answer *"is the customer affected, and where?"*, not just *"is CPU high?"*.
3. **Safely automate where possible** — automation with guardrails, blast-radius limits and a stop button.
4. **Make frequent, small, reversible changes** — small diffs fail smaller and roll back cleanly.
5. **Refine operations procedures frequently** — runbooks are code, reviewed and exercised.
6. **Anticipate failure** — pre-mortems and FMEA before the incident.
7. **Learn from all operational events and metrics** — blameless post-incident review; the output is a code change, not a document.
8. **Use managed services** — reduce the surface you operate.

**Trade-off: change size vs. change risk**

| Deployment strategy | Blast radius | Rollback time | Extra infra cost | Fits which principle |
|---|---|---|---|---|
| In-place, all at once | 100% of fleet | Full redeploy (minutes–hours) | 0 | none — anti-pattern |
| Rolling (`AutoScalingRollingUpdate`, `MaxBatchSize: 1`) | 1 instance | Reverse rolling update | 0 | small, reversible changes |
| Blue/green (two target groups) | 0% until cutover, then 100% | Listener flip, seconds | +100% during cutover | reversible changes |
| Canary (weighted target groups / Lambda alias) | 5–10% of traffic | Weight change, seconds | +5–10% | small **and** reversible |

**Cost of observability (order of magnitude, us-east-1 list prices — always re-check the pricing pages):** custom CloudWatch metrics ≈ **$0.30 / metric / month** for the first 10 000; ingested logs ≈ **$0.50 / GB**; X-Ray traces ≈ **$5.00 / million recorded**. A 40-instance fleet emitting 30 unnecessary custom dimensions per instance is $360/month of metrics nobody alarms on. *Observability is a Cost Optimization decision too* — see §4.

---

### 3.2 Security

**Design principles**

1. **Implement a strong identity foundation** — least privilege, centralised identity, eliminate long-lived credentials.
2. **Maintain traceability** — log and audit every action, in real time, to a place the actor cannot delete.
3. **Apply security at all layers** — defence in depth: edge, VPC, subnet, instance, OS, application, data.
4. **Automate security best practices** — controls as code (Config rules, SCPs, conformance packs), not checklists.
5. **Protect data in transit and at rest** — encryption, tokenisation, classification.
6. **Keep people away from data** — no human SSH into production; use SSM Session Manager and automation.
7. **Prepare for security events** — incident response runbooks, simulations, forensics tooling ready in advance.

**Credential model trade-offs**

| Identity mechanism | Credential lifetime | Rotation burden | Leak blast radius | Verdict |
|---|---|---|---|---|
| IAM user + long-lived access key | Until manually rotated | Human | Catastrophic; keys appear in git history | **Do not use** for workloads |
| EC2 instance profile (IMDSv2) | ~6 h, auto-rotated | None | Requires SSRF **and** `HttpTokens: required` bypass | Default for EC2 |
| IAM role for service accounts / Pod Identity (EKS) | Minutes | None | Scoped to one service account | Default for containers |
| IAM Roles Anywhere / OIDC federation (CI) | Minutes | None | Scoped to one repo/branch claim | Default for pipelines |
| IAM Identity Center + SSO for humans | Session-scoped | None | Revoke centrally | Default for people |

**"Keep people away from data" in practice:** `HttpTokens: required` (IMDSv2) plus `HttpPutResponseHopLimit: 1` closes the classic SSRF-to-credential-theft path, because a container network hop or a proxied request cannot reach the metadata service. This is two lines in a launch template, and it is in the reference implementation below.

---

### 3.3 Reliability

**Design principles**

1. **Automatically recover from failure** — KPIs trigger automation, not humans.
2. **Test recovery procedures** — inject the failure; do not merely test the happy path.
3. **Scale horizontally to increase aggregate workload availability** — many small fault domains beat one big one.
4. **Stop guessing capacity** — monitor demand and automate the supply.
5. **Manage change through automation** — infrastructure changes go through the same pipeline as code.

**The arithmetic behind "scale horizontally"**

If a single instance has availability *a*, and *N* independent instances are behind a load balancer needing *k* healthy to serve peak:

| Topology | Per-node availability | Needs | Resulting availability | Annual downtime |
|---|---|---|---|---|
| 1 × m7g.4xlarge, 1 AZ | 0.99 | 1 of 1 | 0.99 | ~3 d 15 h |
| 2 × m7g.2xlarge, 1 AZ | 0.99 | 1 of 2 | 0.9999 | ~53 min |
| 2 × m7g.2xlarge, 2 AZ | 0.99 | 1 of 2 | 0.9999 **and survives an AZ event** | ~53 min |
| 4 × m7g.xlarge, 2 AZ (N+2) | 0.99 | 2 of 4 | 0.999999 | ~31 s |

The vertical option costs the same as the horizontal one and buys two orders of magnitude less availability. That is the whole argument, and it is why "scale horizontally" is a *reliability* principle, not a performance one.

**Recovery objective trade-offs (a table you will use in real design reviews)**

| Strategy | RTO | RPO | Steady-state cost vs. primary | When it is the right answer |
|---|---|---|---|---|
| Backup & restore | Hours | Hours | ~5% (storage only) | Tier-3 internal apps |
| Pilot light | 10s of minutes | Minutes | ~15% (data replicated, compute off) | Tier-2, cost-sensitive |
| Warm standby | Minutes | Seconds | ~50% (scaled-down live copy) | Tier-1 regional DR |
| Multi-site active/active | Near zero | Near zero | ~200% | Regulated / revenue-critical |

**Do not skip:** every row above is worthless until principle #2 (*test recovery procedures*) has been executed against it. §6.3 shows the game day.

---

### 3.4 Performance Efficiency

**Design principles**

1. **Democratize advanced technologies** — consume ML, media transcoding, and databases as managed services instead of building expertise you do not need.
2. **Go global in minutes** — deploy to additional Regions/edge locations to cut latency.
3. **Use serverless architectures** — remove the server-management tier entirely.
4. **Experiment more often** — comparative A/B tests on instance types, storage classes, and configurations are cheap.
5. **Consider mechanical sympathy** — pick the technology that matches the access pattern.

**Mechanical sympathy: storage selection**

| Access pattern | Wrong choice (and why it hurts) | Right choice | Notes |
|---|---|---|---|
| Random 4 KB reads, 20k IOPS, low latency | S3 (per-object latency ~10s of ms) | io2 Block Express / gp3 with provisioned IOPS | gp3 baseline 3 000 IOPS, tunable to 16 000 independent of size |
| Sequential large-object reads, unbounded volume | EBS (capacity ceiling, per-AZ) | S3 | 11 nines durability, unlimited |
| Shared POSIX across many instances/AZs | EBS Multi-Attach (io1/io2 only, same AZ, needs cluster FS) | EFS | Multi-AZ, elastic |
| Key/value at single-digit ms, huge scale | RDS with an index on a hot key | DynamoDB | Watch the partition-key cardinality |
| Sub-ms repeated reads of the same object | Any database | ElastiCache | Cache-aside, with a TTL and a stampede guard |

**Compute selection under "experiment more often"**

| Option | us-east-1 on-demand list ($/h) | Relative price/perf on typical web workloads | Migration cost |
|---|---|---|---|
| `m7i.large` (x86, Intel) | ~0.1008 | baseline | none |
| `m7a.large` (x86, AMD) | ~0.1159 | ~1.0–1.2× | none |
| `m7g.large` (Graviton3, arm64) | ~0.0816 | ~1.2–1.4× | recompile / multi-arch image |
| Lambda (arm64) | $0.0000133334 / GB-s | n/a — pay per request | re-architect |

Graviton is ~19% cheaper *and* faster on most interpreted/compiled server workloads. The barrier is an arm64 build, which is a one-line change in a modern CI. This is a **Performance Efficiency, Cost Optimization and Sustainability** decision simultaneously — one of the rare places where the pillars do not conflict.

---

### 3.5 Cost Optimization

**Design principles**

1. **Implement Cloud Financial Management** — a real function with owners, budgets and a cadence (FinOps).
2. **Adopt a consumption model** — pay for what you use; turn off what you do not.
3. **Measure overall efficiency** — track **unit cost** (cost per business outcome), not just total spend.
4. **Stop spending money on undifferentiated heavy lifting** — let AWS run the racks, the patching, the DB failover.
5. **Analyze and attribute expenditure** — tagging + Cost Explorer, so every dollar has an owner.

**Purchase-option trade-offs**

| Option | Discount vs on-demand | Commitment | Interruption risk | Right workload |
|---|---|---|---|---|
| On-Demand | 0% | none | none | Spiky, unpredictable, short |
| Savings Plans (Compute, 1y, no upfront) | ~up to 27% | 1 y $/h | none | Steady baseline, flexible across EC2/Fargate/Lambda |
| Savings Plans (Compute, 3y, all upfront) | ~up to 66% | 3 y $/h | none | Proven long-lived baseline |
| Reserved Instances (Standard, 3y) | ~up to 72% | 3 y, instance family/Region | none | Very stable, family-locked (e.g. RDS) |
| Spot Instances | ~up to 90% | none | 2-minute interruption notice | Stateless, fault-tolerant, checkpointed, batch |

**Unit cost is the metric that survives growth.** Total spend rising 40% while unit cost falls 15% is a *healthy* business. Total spend flat while unit cost rises is a workload rotting. This is why principle #3 is worded as "overall efficiency" and why the reference template tags everything.

---

### 3.6 Sustainability

**Design principles**

1. **Understand your impact** — measure it (Customer Carbon Footprint Tool) and establish a baseline.
2. **Establish sustainability goals** — set targets per unit of work, and expect them to drive design.
3. **Maximize utilization** — an instance at 10% CPU wastes ~the same embodied and idle energy as one at 90%.
4. **Anticipate and adopt new, more efficient hardware and software offerings** — Graviton, newer instance generations, more efficient runtimes.
5. **Use managed services** — shared, high-utilisation infrastructure beats your idle fleet.
6. **Reduce the downstream impact of your cloud workloads** — smaller payloads, fewer retries, less client compute, longer device lifetimes.

**Sustainability and Cost Optimization are ~80% the same actions** (right-size, scale in, delete cold data, use Graviton, use serverless). Where they diverge: sustainability also cares about **data gravity and retention** — a 400 TB S3 bucket of logs nobody queries is both a bill and a footprint, and lifecycle policies fix both.

---

## 4. Where the pillars pull against each other

The Framework's real value is that it makes trade-offs **explicit and owned**, rather than accidental. There is no configuration that maximises all six.

| Tension | Pillar A wants | Pillar B wants | How to resolve it |
|---|---|---|---|
| Multi-AZ NAT Gateways | **Reliability**: one NAT per AZ (an AZ failure must not kill the other AZ's egress) | **Cost**: one NAT total (~$32/mo + data each) | Multi-NAT in prod, single NAT in dev; encode via a CFN Condition on `Environment` |
| Full-fidelity tracing | **Operational Excellence**: 100% sampling for debuggability | **Cost**: $5/M traces + log ingestion | Adaptive sampling: 100% of errors and slow requests, 5% baseline |
| Encryption everywhere with CMKs | **Security**: customer-managed KMS keys, per-workload isolation | **Cost / Performance**: $1/key/month + $0.03 per 10 000 requests, plus KMS latency | AWS-managed keys for low-sensitivity data, CMK where a key policy or audit boundary is genuinely required |
| Aggressive scale-in | **Cost / Sustainability**: cut capacity fast when demand drops | **Reliability / Performance**: thrash, cold caches, latency spikes | Asymmetric policy: fast scale-out, slow scale-in with a long cooldown |
| Spot for the whole fleet | **Cost**: up to −90% | **Reliability**: correlated interruptions | Mixed instances policy: on-demand base for the SLO floor, Spot for the surge |
| Synchronous, strongly consistent calls | **Reliability** (some readings): simple, no lag | **Reliability** (availability) / **Performance**: coupled failure and latency | Queue the write (SQS), acknowledge fast, reconcile asynchronously |

**Worked example — the price of a nine.** For the reference workload in §5 (2 AZ, 4 × m7g.large, ALB, Aurora):

| Target | Topology delta | Approx. monthly delta | Downtime budget |
|---|---|---|---|
| 99.9% | 2 AZ, single-AZ database, backups | baseline | 43 m 50 s / month |
| 99.95% | + Multi-AZ database | +100% of DB instance cost | 21 m 55 s / month |
| 99.99% | + 3rd AZ, N+2 capacity, Multi-AZ cluster w/ reader | +~60% of total | 4 m 23 s / month |
| 99.999% | + active/active second Region, global database, Route 53 ARC | +~130% of total | 26 s / month |

Take that table to the product owner **before** committing to an SLO. "Design for failure" does not mean "design for every failure at any price"; it means *choose the failures you will survive, and prove it*.

---

## 5. Reference implementation — complete and deployable

The following CloudFormation template is a single-file implementation of the design principles above. It is annotated so every resource traces back to a principle. It is complete: no elisions, no `# ...` placeholders.

**What it demonstrates**

| Principle | Where |
|---|---|
| Scale horizontally / stop guessing capacity | ASG across 2 AZs + target-tracking policy |
| Automatically recover from failure | `HealthCheckType: ELB`, ASG replacement, per-AZ NAT |
| Manage change through automation | Whole stack is IaC; `UpdatePolicy` rolling update |
| Make frequent, small, reversible changes | `MaxBatchSize: 1`, `MinSuccessfulInstancesPercent` |
| Protect data in transit and at rest | Encrypted gp3, SQS SSE, S3 encryption, optional HTTPS listener with HTTP→HTTPS redirect |
| Keep people away from data | SSM Session Manager only; **no SSH key, no port 22** |
| Implement a strong identity foundation | Instance profile, IMDSv2 required, hop limit 1 |
| Maintain traceability | VPC Flow Logs to CloudWatch Logs |
| Apply security at all layers | SG chaining (ALB→app only), private subnets, S3 public-access block |
| Anticipate failure | SQS + DLQ, alarms on 5xx / unhealthy hosts / DLQ depth |
| Analyze and attribute expenditure | Mandatory tags propagated at launch + a tag-filtered Budget |
| Maximize utilization / adopt efficient hardware | Graviton (`arm64`) instances, target-tracking at 55% CPU |
| Reduce downstream impact / consumption model | S3 lifecycle to Intelligent-Tiering, noncurrent-version expiry, S3 Gateway Endpoint (removes NAT data charges) |

```yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: >-
  Well-Architected reference workload for AWS CLF-C02 task 1.2.
  Two-AZ, horizontally scaled, self-healing, loosely coupled, tagged and
  budgeted. Every resource is annotated with the design principle it implements.

Metadata:
  AWS::CloudFormation::Interface:
    ParameterGroups:
      - Label: {default: Workload identity (Cost Optimization - attribute expenditure)}
        Parameters: [WorkloadName, Environment, CostCenter, OperatorEmail]
      - Label: {default: Network (Reliability - multiple fault domains)}
        Parameters: [VpcCidr]
      - Label: {default: Compute (Performance Efficiency / Sustainability)}
        Parameters: [InstanceType, LatestAmiId, MinSize, MaxSize, TargetCpuUtilization]
      - Label: {default: Edge (Security - protect data in transit)}
        Parameters: [CertificateArn, IngressCidr]
      - Label: {default: Cost guardrails}
        Parameters: [MonthlyBudgetUSD]

Parameters:

  WorkloadName:
    Type: String
    Default: wa-reference
    AllowedPattern: '^[a-z][a-z0-9-]{2,28}$'
    Description: Lowercase workload identifier; becomes the cost-allocation tag value.

  Environment:
    Type: String
    Default: prod
    AllowedValues: [dev, stage, prod]
    Description: >-
      Drives the Reliability/Cost trade-off: prod gets one NAT Gateway per AZ,
      dev/stage share a single NAT Gateway.

  CostCenter:
    Type: String
    Default: platform-engineering
    Description: Cost-allocation tag value. Must be activated in Billing to filter on it.

  OperatorEmail:
    Type: String
    AllowedPattern: '^[^@\s]+@[^@\s]+\.[^@\s]+$'
    Description: Destination for alarm and budget notifications.

  VpcCidr:
    Type: String
    Default: 10.42.0.0/16
    AllowedPattern: '^(\d{1,3}\.){3}\d{1,3}/(1[6-9]|2[0-4])$'

  InstanceType:
    Type: String
    Default: m7g.large
    AllowedValues: [t4g.small, t4g.medium, m7g.medium, m7g.large, m7g.xlarge, c7g.large]
    Description: Graviton (arm64) only - Performance Efficiency + Sustainability.

  LatestAmiId:
    Type: AWS::SSM::Parameter::Value<AWS::EC2::Image::Id>
    Default: /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64
    Description: >-
      Resolved from the SSM Public Parameter Store at deploy time, so a stack
      update always picks up the current patched AMI (Operational Excellence).

  MinSize:
    Type: Number
    Default: 2
    MinValue: 2
    Description: Never below 2 - one instance is a single point of failure.

  MaxSize:
    Type: Number
    Default: 12

  TargetCpuUtilization:
    Type: Number
    Default: 55
    MinValue: 20
    MaxValue: 90
    Description: Sustainability - maximize utilization without starving headroom.

  CertificateArn:
    Type: String
    Default: ''
    Description: >-
      Optional ACM certificate ARN. If supplied, :80 redirects to :443 and TLS
      terminates at the ALB (Security - protect data in transit).

  IngressCidr:
    Type: String
    Default: 0.0.0.0/0
    Description: Narrow this for internal workloads (Security - least privilege at the edge).

  MonthlyBudgetUSD:
    Type: Number
    Default: 250
    MinValue: 10

Conditions:

  HasTlsCertificate: !Not [!Equals [!Ref CertificateArn, '']]
  IsProduction:      !Equals [!Ref Environment, prod]

Resources:

  # ------------------------------------------------------------------
  # NETWORK - Reliability: two independent Availability Zones.
  # An AZ is a distinct set of datacenters with independent power,
  # cooling and networking. Spanning two of them is the cheapest
  # reliability improvement available in the cloud.
  # ------------------------------------------------------------------

  Vpc:
    Type: AWS::EC2::VPC
    Properties:
      CidrBlock: !Ref VpcCidr
      EnableDnsSupport: true
      EnableDnsHostnames: true
      Tags:
        - {Key: Name,       Value: !Sub '${WorkloadName}-${Environment}-vpc'}
        - {Key: workload,   Value: !Ref WorkloadName}
        - {Key: environment, Value: !Ref Environment}
        - {Key: costcenter, Value: !Ref CostCenter}

  InternetGateway:
    Type: AWS::EC2::InternetGateway
    Properties:
      Tags:
        - {Key: Name, Value: !Sub '${WorkloadName}-${Environment}-igw'}

  InternetGatewayAttachment:
    Type: AWS::EC2::VPCGatewayAttachment
    Properties:
      VpcId: !Ref Vpc
      InternetGatewayId: !Ref InternetGateway

  PublicSubnetA:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref Vpc
      AvailabilityZone: !Select [0, !GetAZs '']
      CidrBlock: !Select [0, !Cidr [!Ref VpcCidr, 8, 8]]
      MapPublicIpOnLaunch: true
      Tags:
        - {Key: Name, Value: !Sub '${WorkloadName}-${Environment}-public-a'}
        - {Key: tier, Value: public}

  PublicSubnetB:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref Vpc
      AvailabilityZone: !Select [1, !GetAZs '']
      CidrBlock: !Select [1, !Cidr [!Ref VpcCidr, 8, 8]]
      MapPublicIpOnLaunch: true
      Tags:
        - {Key: Name, Value: !Sub '${WorkloadName}-${Environment}-public-b'}
        - {Key: tier, Value: public}

  PrivateSubnetA:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref Vpc
      AvailabilityZone: !Select [0, !GetAZs '']
      CidrBlock: !Select [2, !Cidr [!Ref VpcCidr, 8, 8]]
      MapPublicIpOnLaunch: false
      Tags:
        - {Key: Name, Value: !Sub '${WorkloadName}-${Environment}-private-a'}
        - {Key: tier, Value: private}

  PrivateSubnetB:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref Vpc
      AvailabilityZone: !Select [1, !GetAZs '']
      CidrBlock: !Select [3, !Cidr [!Ref VpcCidr, 8, 8]]
      MapPublicIpOnLaunch: false
      Tags:
        - {Key: Name, Value: !Sub '${WorkloadName}-${Environment}-private-b'}
        - {Key: tier, Value: private}

  # NAT Gateways. In prod there is one per AZ so that losing AZ-a does not
  # sever egress for the instances still running in AZ-b. In dev the second
  # NAT is not created - an explicit, documented Cost/Reliability trade-off.

  NatEipA:
    Type: AWS::EC2::EIP
    DependsOn: InternetGatewayAttachment
    Properties:
      Domain: vpc
      Tags:
        - {Key: Name, Value: !Sub '${WorkloadName}-${Environment}-nat-eip-a'}

  NatEipB:
    Type: AWS::EC2::EIP
    Condition: IsProduction
    DependsOn: InternetGatewayAttachment
    Properties:
      Domain: vpc
      Tags:
        - {Key: Name, Value: !Sub '${WorkloadName}-${Environment}-nat-eip-b'}

  NatGatewayA:
    Type: AWS::EC2::NatGateway
    Properties:
      AllocationId: !GetAtt NatEipA.AllocationId
      SubnetId: !Ref PublicSubnetA
      Tags:
        - {Key: Name, Value: !Sub '${WorkloadName}-${Environment}-nat-a'}

  NatGatewayB:
    Type: AWS::EC2::NatGateway
    Condition: IsProduction
    Properties:
      AllocationId: !GetAtt NatEipB.AllocationId
      SubnetId: !Ref PublicSubnetB
      Tags:
        - {Key: Name, Value: !Sub '${WorkloadName}-${Environment}-nat-b'}

  PublicRouteTable:
    Type: AWS::EC2::RouteTable
    Properties:
      VpcId: !Ref Vpc
      Tags:
        - {Key: Name, Value: !Sub '${WorkloadName}-${Environment}-rtb-public'}

  PublicDefaultRoute:
    Type: AWS::EC2::Route
    DependsOn: InternetGatewayAttachment
    Properties:
      RouteTableId: !Ref PublicRouteTable
      DestinationCidrBlock: 0.0.0.0/0
      GatewayId: !Ref InternetGateway

  PublicSubnetARouteAssoc:
    Type: AWS::EC2::SubnetRouteTableAssociation
    Properties:
      SubnetId: !Ref PublicSubnetA
      RouteTableId: !Ref PublicRouteTable

  PublicSubnetBRouteAssoc:
    Type: AWS::EC2::SubnetRouteTableAssociation
    Properties:
      SubnetId: !Ref PublicSubnetB
      RouteTableId: !Ref PublicRouteTable

  PrivateRouteTableA:
    Type: AWS::EC2::RouteTable
    Properties:
      VpcId: !Ref Vpc
      Tags:
        - {Key: Name, Value: !Sub '${WorkloadName}-${Environment}-rtb-private-a'}

  PrivateRouteTableB:
    Type: AWS::EC2::RouteTable
    Properties:
      VpcId: !Ref Vpc
      Tags:
        - {Key: Name, Value: !Sub '${WorkloadName}-${Environment}-rtb-private-b'}

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
      NatGatewayId: !If [IsProduction, !Ref NatGatewayB, !Ref NatGatewayA]

  PrivateSubnetARouteAssoc:
    Type: AWS::EC2::SubnetRouteTableAssociation
    Properties:
      SubnetId: !Ref PrivateSubnetA
      RouteTableId: !Ref PrivateRouteTableA

  PrivateSubnetBRouteAssoc:
    Type: AWS::EC2::SubnetRouteTableAssociation
    Properties:
      SubnetId: !Ref PrivateSubnetB
      RouteTableId: !Ref PrivateRouteTableB

  # S3 Gateway Endpoint: S3 traffic leaves via the VPC route table instead of
  # the NAT Gateway. Cost (no $0.045/GB NAT processing), Security (traffic
  # never touches the public internet) and Performance at once. It is free.

  S3GatewayEndpoint:
    Type: AWS::EC2::VPCEndpoint
    Properties:
      VpcId: !Ref Vpc
      ServiceName: !Sub 'com.amazonaws.${AWS::Region}.s3'
      VpcEndpointType: Gateway
      RouteTableIds:
        - !Ref PrivateRouteTableA
        - !Ref PrivateRouteTableB

  # ------------------------------------------------------------------
  # TRACEABILITY - Security: "maintain traceability".
  # Flow Logs capture accepted and rejected traffic metadata for forensics.
  # ------------------------------------------------------------------

  FlowLogGroup:
    Type: AWS::Logs::LogGroup
    Properties:
      LogGroupName: !Sub '/aws/vpc/${WorkloadName}-${Environment}/flowlogs'
      RetentionInDays: 90

  FlowLogRole:
    Type: AWS::IAM::Role
    Properties:
      AssumeRolePolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Effect: Allow
            Principal: {Service: vpc-flow-logs.amazonaws.com}
            Action: sts:AssumeRole
      Policies:
        - PolicyName: publish-flow-logs
          PolicyDocument:
            Version: '2012-10-17'
            Statement:
              - Effect: Allow
                Action:
                  - logs:CreateLogStream
                  - logs:PutLogEvents
                  - logs:DescribeLogStreams
                Resource: !GetAtt FlowLogGroup.Arn

  VpcFlowLog:
    Type: AWS::EC2::FlowLog
    Properties:
      ResourceId: !Ref Vpc
      ResourceType: VPC
      TrafficType: ALL
      LogDestinationType: cloud-watch-logs
      LogGroupName: !Ref FlowLogGroup
      DeliverLogsPermissionArn: !GetAtt FlowLogRole.Arn
      MaxAggregationInterval: 60

  # ------------------------------------------------------------------
  # EDGE - Security: apply security at all layers (SG chaining).
  # ------------------------------------------------------------------

  AlbSecurityGroup:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: !Sub 'Public ingress for ${WorkloadName}-${Environment} ALB'
      VpcId: !Ref Vpc
      SecurityGroupIngress:
        - IpProtocol: tcp
          FromPort: 80
          ToPort: 80
          CidrIp: !Ref IngressCidr
          Description: HTTP (redirected to HTTPS when a certificate is present)
        - IpProtocol: tcp
          FromPort: 443
          ToPort: 443
          CidrIp: !Ref IngressCidr
          Description: HTTPS
      SecurityGroupEgress:
        - IpProtocol: tcp
          FromPort: 8080
          ToPort: 8080
          CidrIp: !Ref VpcCidr
          Description: Forward only to the application tier inside the VPC
      Tags:
        - {Key: Name, Value: !Sub '${WorkloadName}-${Environment}-alb-sg'}

  # No port 22 anywhere. Human access is SSM Session Manager only
  # (Security - "keep people away from data").
  AppSecurityGroup:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: !Sub 'Application tier for ${WorkloadName}-${Environment}'
      VpcId: !Ref Vpc
      SecurityGroupEgress:
        - IpProtocol: -1
          CidrIp: 0.0.0.0/0
          Description: Outbound for package updates, SSM and AWS APIs
      Tags:
        - {Key: Name, Value: !Sub '${WorkloadName}-${Environment}-app-sg'}

  AppIngressFromAlb:
    Type: AWS::EC2::SecurityGroupIngress
    Properties:
      GroupId: !Ref AppSecurityGroup
      IpProtocol: tcp
      FromPort: 8080
      ToPort: 8080
      SourceSecurityGroupId: !Ref AlbSecurityGroup
      Description: Only the ALB may reach the application port

  LoadBalancer:
    Type: AWS::ElasticLoadBalancingV2::LoadBalancer
    Properties:
      Name: !Sub '${WorkloadName}-${Environment}-alb'
      Type: application
      Scheme: internet-facing
      IpAddressType: ipv4
      SecurityGroups: [!Ref AlbSecurityGroup]
      Subnets:
        - !Ref PublicSubnetA
        - !Ref PublicSubnetB
      LoadBalancerAttributes:
        - {Key: idle_timeout.timeout_seconds, Value: '60'}
        - {Key: routing.http.drop_invalid_header_fields.enabled, Value: 'true'}
        - {Key: routing.http2.enabled, Value: 'true'}
        - {Key: deletion_protection.enabled, Value: 'false'}
      Tags:
        - {Key: workload,    Value: !Ref WorkloadName}
        - {Key: environment, Value: !Ref Environment}
        - {Key: costcenter,  Value: !Ref CostCenter}

  TargetGroup:
    Type: AWS::ElasticLoadBalancingV2::TargetGroup
    Properties:
      Name: !Sub '${WorkloadName}-${Environment}-tg'
      VpcId: !Ref Vpc
      Protocol: HTTP
      Port: 8080
      TargetType: instance
      # Reliability: an unhealthy target is removed from rotation in 30 s
      # (2 checks x 15 s) and the ASG then replaces the instance entirely.
      HealthCheckEnabled: true
      HealthCheckProtocol: HTTP
      HealthCheckPath: /healthz
      HealthCheckIntervalSeconds: 15
      HealthCheckTimeoutSeconds: 5
      HealthyThresholdCount: 2
      UnhealthyThresholdCount: 2
      Matcher: {HttpCode: '200'}
      TargetGroupAttributes:
        - {Key: deregistration_delay.timeout_seconds, Value: '30'}
        - {Key: stickiness.enabled, Value: 'false'}
        - {Key: load_balancing.algorithm.type, Value: least_outstanding_requests}

  HttpListener:
    Type: AWS::ElasticLoadBalancingV2::Listener
    Properties:
      LoadBalancerArn: !Ref LoadBalancer
      Protocol: HTTP
      Port: 80
      DefaultActions:
        - !If
          - HasTlsCertificate
          - Type: redirect
            RedirectConfig:
              Protocol: HTTPS
              Port: '443'
              StatusCode: HTTP_301
          - Type: forward
            TargetGroupArn: !Ref TargetGroup

  HttpsListener:
    Type: AWS::ElasticLoadBalancingV2::Listener
    Condition: HasTlsCertificate
    Properties:
      LoadBalancerArn: !Ref LoadBalancer
      Protocol: HTTPS
      Port: 443
      SslPolicy: ELBSecurityPolicy-TLS13-1-2-2021-06
      Certificates:
        - CertificateArn: !Ref CertificateArn
      DefaultActions:
        - Type: forward
          TargetGroupArn: !Ref TargetGroup

  # ------------------------------------------------------------------
  # LOOSE COUPLING - Reliability + evolutionary architecture.
  # The API accepts work and enqueues it; the worker fails independently.
  # The DLQ is the "anticipate failure" mechanism: poison messages are
  # quarantined after 5 attempts instead of blocking the queue forever.
  # ------------------------------------------------------------------

  JobDeadLetterQueue:
    Type: AWS::SQS::Queue
    Properties:
      QueueName: !Sub '${WorkloadName}-${Environment}-jobs-dlq'
      MessageRetentionPeriod: 1209600   # 14 days - maximum, for forensics
      SqsManagedSseEnabled: true        # encryption at rest

  JobQueue:
    Type: AWS::SQS::Queue
    Properties:
      QueueName: !Sub '${WorkloadName}-${Environment}-jobs'
      VisibilityTimeout: 120
      MessageRetentionPeriod: 345600    # 4 days
      SqsManagedSseEnabled: true
      RedrivePolicy:
        deadLetterTargetArn: !GetAtt JobDeadLetterQueue.Arn
        maxReceiveCount: 5

  # ------------------------------------------------------------------
  # DATA - Cost Optimization + Sustainability + Security.
  # ------------------------------------------------------------------

  ArtifactBucket:
    Type: AWS::S3::Bucket
    DeletionPolicy: Retain
    UpdateReplacePolicy: Retain
    Properties:
      BucketName: !Sub '${WorkloadName}-${Environment}-artifacts-${AWS::AccountId}-${AWS::Region}'
      PublicAccessBlockConfiguration:
        BlockPublicAcls: true
        BlockPublicPolicy: true
        IgnorePublicAcls: true
        RestrictPublicBuckets: true
      BucketEncryption:
        ServerSideEncryptionConfiguration:
          - ServerSideEncryptionByDefault: {SSEAlgorithm: AES256}
            BucketKeyEnabled: true
      VersioningConfiguration: {Status: Enabled}
      OwnershipControls:
        Rules:
          - ObjectOwnership: BucketOwnerEnforced
      LifecycleConfiguration:
        Rules:
          - Id: tier-cold-objects
            Status: Enabled
            Transitions:
              - {StorageClass: INTELLIGENT_TIERING, TransitionInDays: 0}
          - Id: expire-old-versions
            Status: Enabled
            NoncurrentVersionExpiration: {NoncurrentDays: 30}
          - Id: abort-incomplete-uploads
            Status: Enabled
            AbortIncompleteMultipartUpload: {DaysAfterInitiation: 7}
      Tags:
        - {Key: workload,    Value: !Ref WorkloadName}
        - {Key: environment, Value: !Ref Environment}
        - {Key: costcenter,  Value: !Ref CostCenter}

  # ------------------------------------------------------------------
  # IDENTITY - Security: strong identity foundation, no static credentials.
  # ------------------------------------------------------------------

  InstanceRole:
    Type: AWS::IAM::Role
    Properties:
      AssumeRolePolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Effect: Allow
            Principal: {Service: ec2.amazonaws.com}
            Action: sts:AssumeRole
      ManagedPolicyArns:
        - arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
        - arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy
      Policies:
        - PolicyName: workload-least-privilege
          PolicyDocument:
            Version: '2012-10-17'
            Statement:
              - Sid: ConsumeJobQueue
                Effect: Allow
                Action:
                  - sqs:ReceiveMessage
                  - sqs:DeleteMessage
                  - sqs:GetQueueAttributes
                  - sqs:ChangeMessageVisibility
                Resource: !GetAtt JobQueue.Arn
              - Sid: ReadWriteOwnArtifactsOnly
                Effect: Allow
                Action:
                  - s3:GetObject
                  - s3:PutObject
                Resource: !Sub '${ArtifactBucket.Arn}/*'
              - Sid: ListOwnBucketOnly
                Effect: Allow
                Action: s3:ListBucket
                Resource: !GetAtt ArtifactBucket.Arn
      Tags:
        - {Key: workload, Value: !Ref WorkloadName}

  InstanceProfile:
    Type: AWS::IAM::InstanceProfile
    Properties:
      Roles: [!Ref InstanceRole]

  # ------------------------------------------------------------------
  # COMPUTE - Reliability (horizontal, multi-AZ, self-healing)
  #           Performance Efficiency / Sustainability (Graviton, utilization)
  # ------------------------------------------------------------------

  LaunchTemplate:
    Type: AWS::EC2::LaunchTemplate
    Properties:
      LaunchTemplateName: !Sub '${WorkloadName}-${Environment}-lt'
      LaunchTemplateData:
        ImageId: !Ref LatestAmiId
        InstanceType: !Ref InstanceType
        IamInstanceProfile: {Arn: !GetAtt InstanceProfile.Arn}
        SecurityGroupIds: [!Ref AppSecurityGroup]
        # IMDSv2 required + hop limit 1: closes the classic SSRF-to-credential
        # theft path (Security - keep people and processes away from creds).
        MetadataOptions:
          HttpTokens: required
          HttpPutResponseHopLimit: 1
          HttpEndpoint: enabled
          InstanceMetadataTags: enabled
        Monitoring: {Enabled: true}     # 1-minute metrics: drive decisions with data
        BlockDeviceMappings:
          - DeviceName: /dev/xvda
            Ebs:
              VolumeSize: 20
              VolumeType: gp3
              Iops: 3000
              Throughput: 125
              Encrypted: true           # Security - protect data at rest
              DeleteOnTermination: true
        TagSpecifications:
          - ResourceType: instance
            Tags:
              - {Key: Name,        Value: !Sub '${WorkloadName}-${Environment}'}
              - {Key: workload,    Value: !Ref WorkloadName}
              - {Key: environment, Value: !Ref Environment}
              - {Key: costcenter,  Value: !Ref CostCenter}
          - ResourceType: volume
            Tags:
              - {Key: workload,    Value: !Ref WorkloadName}
              - {Key: environment, Value: !Ref Environment}
              - {Key: costcenter,  Value: !Ref CostCenter}
        UserData:
          Fn::Base64: !Sub |
            #!/bin/bash
            set -euo pipefail
            dnf -y update
            dnf -y install nginx amazon-cloudwatch-agent

            AZ=$(TOKEN=$(curl -sX PUT http://169.254.169.254/latest/api/token \
                  -H "X-aws-ec2-metadata-token-ttl-seconds: 60") && \
                 curl -s -H "X-aws-ec2-metadata-token: ${!TOKEN}" \
                  http://169.254.169.254/latest/meta-data/placement/availability-zone)
            IID=$(TOKEN=$(curl -sX PUT http://169.254.169.254/latest/api/token \
                  -H "X-aws-ec2-metadata-token-ttl-seconds: 60") && \
                 curl -s -H "X-aws-ec2-metadata-token: ${!TOKEN}" \
                  http://169.254.169.254/latest/meta-data/instance-id)

            cat >/etc/nginx/conf.d/app.conf <<NGINX
            server {
              listen 8080 default_server;
              # Shallow health check: proves the process is up and can serve.
              # Deep checks that call the database turn one DB blip into a
              # fleet-wide termination storm - deliberately avoided.
              location = /healthz {
                access_log off;
                add_header Content-Type text/plain;
                return 200 "ok\n";
              }
              location / {
                add_header Content-Type text/plain;
                return 200 "workload=${WorkloadName} env=${Environment} az=${!AZ} id=${!IID}\n";
              }
            }
            NGINX

            rm -f /etc/nginx/conf.d/default.conf || true
            systemctl enable --now nginx
            systemctl enable --now amazon-ssm-agent

  AutoScalingGroup:
    Type: AWS::AutoScaling::AutoScalingGroup
    Properties:
      AutoScalingGroupName: !Sub '${WorkloadName}-${Environment}-asg'
      MinSize: !Ref MinSize
      MaxSize: !Ref MaxSize
      DesiredCapacity: !Ref MinSize
      # Two subnets in two AZs. The ASG rebalances automatically, so an AZ
      # event is absorbed by launching replacements in the surviving AZ.
      VPCZoneIdentifier:
        - !Ref PrivateSubnetA
        - !Ref PrivateSubnetB
      LaunchTemplate:
        LaunchTemplateId: !Ref LaunchTemplate
        Version: !GetAtt LaunchTemplate.LatestVersionNumber
      TargetGroupARNs: [!Ref TargetGroup]
      # ELB health checks, not EC2: an instance whose process is wedged but
      # whose hypervisor is fine must still be replaced.
      HealthCheckType: ELB
      HealthCheckGracePeriod: 180
      DefaultInstanceWarmup: 120
      MetricsCollection:
        - Granularity: 1Minute
      Tags:
        - {Key: Name,        Value: !Sub '${WorkloadName}-${Environment}', PropagateAtLaunch: true}
        - {Key: workload,    Value: !Ref WorkloadName,  PropagateAtLaunch: true}
        - {Key: environment, Value: !Ref Environment,   PropagateAtLaunch: true}
        - {Key: costcenter,  Value: !Ref CostCenter,    PropagateAtLaunch: true}
    # Operational Excellence: frequent, small, REVERSIBLE changes.
    # One instance at a time; if the batch does not come back healthy the
    # stack update fails and CloudFormation rolls the change back.
    UpdatePolicy:
      AutoScalingRollingUpdate:
        MaxBatchSize: 1
        MinInstancesInService: !Ref MinSize
        MinSuccessfulInstancesPercent: 100
        PauseTime: PT5M
        WaitOnResourceSignals: false
        SuspendProcesses:
          - HealthCheck
          - ReplaceUnhealthy
          - AZRebalance
          - AlarmNotification
          - ScheduledActions

  # "Stop guessing capacity": supply follows demand automatically.
  # Target tracking is preferred over step scaling because it needs one
  # number (the target) rather than a hand-tuned ladder of thresholds.
  CpuTargetTrackingPolicy:
    Type: AWS::AutoScaling::ScalingPolicy
    Properties:
      AutoScalingGroupName: !Ref AutoScalingGroup
      PolicyType: TargetTrackingScaling
      EstimatedInstanceWarmup: 120
      TargetTrackingConfiguration:
        PredefinedMetricSpecification:
          PredefinedMetricType: ASGAverageCPUUtilization
        TargetValue: !Ref TargetCpuUtilization
        DisableScaleIn: false

  # ------------------------------------------------------------------
  # OBSERVABILITY AND ALARMS - Operational Excellence: actionable insight.
  # Each alarm below corresponds to a customer-visible symptom, not to a
  # resource statistic that nobody can act on.
  # ------------------------------------------------------------------

  AlarmTopic:
    Type: AWS::SNS::Topic
    Properties:
      TopicName: !Sub '${WorkloadName}-${Environment}-alarms'
      DisplayName: !Sub '${WorkloadName} ${Environment} alarms'

  AlarmTopicSubscription:
    Type: AWS::SNS::Subscription
    Properties:
      TopicArn: !Ref AlarmTopic
      Protocol: email
      Endpoint: !Ref OperatorEmail

  UnhealthyHostsAlarm:
    Type: AWS::CloudWatch::Alarm
    Properties:
      AlarmName: !Sub '${WorkloadName}-${Environment}-unhealthy-hosts'
      AlarmDescription: >-
        One or more targets are failing health checks. Expected briefly during
        a rolling update; sustained means the ASG cannot bring capacity back.
      Namespace: AWS/ApplicationELB
      MetricName: UnHealthyHostCount
      Dimensions:
        - {Name: TargetGroup,  Value: !GetAtt TargetGroup.TargetGroupFullName}
        - {Name: LoadBalancer, Value: !GetAtt LoadBalancer.LoadBalancerFullName}
      Statistic: Maximum
      Period: 60
      EvaluationPeriods: 5
      Threshold: 0
      ComparisonOperator: GreaterThanThreshold
      TreatMissingData: notBreaching
      AlarmActions: [!Ref AlarmTopic]
      OKActions: [!Ref AlarmTopic]

  Elb5xxAlarm:
    Type: AWS::CloudWatch::Alarm
    Properties:
      AlarmName: !Sub '${WorkloadName}-${Environment}-elb-5xx'
      AlarmDescription: >-
        The load balancer itself returned 5xx - typically zero healthy targets.
        This is the customer-visible outage signal.
      Namespace: AWS/ApplicationELB
      MetricName: HTTPCode_ELB_5XX_Count
      Dimensions:
        - {Name: LoadBalancer, Value: !GetAtt LoadBalancer.LoadBalancerFullName}
      Statistic: Sum
      Period: 60
      EvaluationPeriods: 2
      Threshold: 5
      ComparisonOperator: GreaterThanThreshold
      TreatMissingData: notBreaching
      AlarmActions: [!Ref AlarmTopic]

  LatencyP99Alarm:
    Type: AWS::CloudWatch::Alarm
    Properties:
      AlarmName: !Sub '${WorkloadName}-${Environment}-p99-latency'
      AlarmDescription: p99 target response time above the 1.5 s SLO.
      Namespace: AWS/ApplicationELB
      MetricName: TargetResponseTime
      Dimensions:
        - {Name: TargetGroup,  Value: !GetAtt TargetGroup.TargetGroupFullName}
        - {Name: LoadBalancer, Value: !GetAtt LoadBalancer.LoadBalancerFullName}
      ExtendedStatistic: p99
      Period: 60
      EvaluationPeriods: 5
      Threshold: 1.5
      ComparisonOperator: GreaterThanThreshold
      TreatMissingData: notBreaching
      AlarmActions: [!Ref AlarmTopic]

  DeadLetterQueueAlarm:
    Type: AWS::CloudWatch::Alarm
    Properties:
      AlarmName: !Sub '${WorkloadName}-${Environment}-dlq-not-empty'
      AlarmDescription: >-
        Messages reached the dead-letter queue: work is being silently dropped.
        A DLQ with no alarm on it is a data-loss mechanism, not a safety net.
      Namespace: AWS/SQS
      MetricName: ApproximateNumberOfMessagesVisible
      Dimensions:
        - {Name: QueueName, Value: !GetAtt JobDeadLetterQueue.QueueName}
      Statistic: Maximum
      Period: 300
      EvaluationPeriods: 1
      Threshold: 0
      ComparisonOperator: GreaterThanThreshold
      TreatMissingData: notBreaching
      AlarmActions: [!Ref AlarmTopic]

  SingleAzCapacityAlarm:
    Type: AWS::CloudWatch::Alarm
    Properties:
      AlarmName: !Sub '${WorkloadName}-${Environment}-az-capacity-floor'
      AlarmDescription: >-
        In-service capacity has dropped to the minimum. The workload is one
        instance failure away from an outage.
      Namespace: AWS/AutoScaling
      MetricName: GroupInServiceInstances
      Dimensions:
        - {Name: AutoScalingGroupName, Value: !Ref AutoScalingGroup}
      Statistic: Minimum
      Period: 60
      EvaluationPeriods: 3
      Threshold: !Ref MinSize
      ComparisonOperator: LessThanThreshold
      TreatMissingData: breaching
      AlarmActions: [!Ref AlarmTopic]

  # ------------------------------------------------------------------
  # COST GUARDRAIL - Cost Optimization: Cloud Financial Management.
  # FORECASTED, not ACTUAL: an alert that fires after the money is spent
  # is a receipt, not a control.
  # ------------------------------------------------------------------

  WorkloadBudget:
    Type: AWS::Budgets::Budget
    Properties:
      Budget:
        BudgetName: !Sub '${WorkloadName}-${Environment}-monthly'
        BudgetType: COST
        TimeUnit: MONTHLY
        BudgetLimit:
          Amount: !Ref MonthlyBudgetUSD
          Unit: USD
        CostFilters:
          TagKeyValue:
            - !Join ['', ['user:workload$', !Ref WorkloadName]]
      NotificationsWithSubscribers:
        - Notification:
            NotificationType: FORECASTED
            ComparisonOperator: GREATER_THAN
            Threshold: 100
            ThresholdType: PERCENTAGE
          Subscribers:
            - {SubscriptionType: EMAIL, Address: !Ref OperatorEmail}
        - Notification:
            NotificationType: ACTUAL
            ComparisonOperator: GREATER_THAN
            Threshold: 80
            ThresholdType: PERCENTAGE
          Subscribers:
            - {SubscriptionType: EMAIL, Address: !Ref OperatorEmail}

Outputs:

  ServiceUrl:
    Description: Public entry point for the workload.
    Value: !If
      - HasTlsCertificate
      - !Sub 'https://${LoadBalancer.DNSName}'
      - !Sub 'http://${LoadBalancer.DNSName}'
    Export:
      Name: !Sub '${AWS::StackName}-ServiceUrl'

  AutoScalingGroupName:
    Description: ASG name - use it as the FIS target and in verification commands.
    Value: !Ref AutoScalingGroup
    Export:
      Name: !Sub '${AWS::StackName}-AsgName'

  TargetGroupArn:
    Description: Target group ARN for describe-target-health.
    Value: !Ref TargetGroup
    Export:
      Name: !Sub '${AWS::StackName}-TargetGroupArn'

  JobQueueUrl:
    Description: SQS queue that decouples the API from the worker.
    Value: !Ref JobQueue

  DeadLetterQueueUrl:
    Description: Quarantine for poison messages.
    Value: !Ref JobDeadLetterQueue

  ArtifactBucketName:
    Description: Versioned, encrypted, lifecycle-managed artifact store.
    Value: !Ref ArtifactBucket

  AvailabilityZones:
    Description: The two fault domains this workload spans.
    Value: !Join [', ', [!GetAtt PublicSubnetA.AvailabilityZone, !GetAtt PublicSubnetB.AvailabilityZone]]
```

### 5.1 Deployment

```console
$ aws --version
aws-cli/2.17.42 Python/3.11.9 linux/6.5.0 exe/x86_64.fedora.41

$ aws sts get-caller-identity
{
    "UserId": "AROA4KJH2XQ7ZLPMN3EXAMPLE:platform-architect",
    "Account": "123456789012",
    "Arn": "arn:aws:sts::123456789012:assumed-role/PlatformAdmin/platform-architect"
}

$ aws cloudformation validate-template \
    --template-body file://wa-reference.yaml \
    --query 'Parameters[].ParameterKey' --output text
WorkloadName    Environment     CostCenter      OperatorEmail   VpcCidr
InstanceType    LatestAmiId     MinSize MaxSize TargetCpuUtilization
CertificateArn  IngressCidr     MonthlyBudgetUSD

$ aws cloudformation deploy \
    --stack-name wa-reference-prod \
    --template-file wa-reference.yaml \
    --capabilities CAPABILITY_IAM \
    --parameter-overrides \
        WorkloadName=wa-reference \
        Environment=prod \
        CostCenter=platform-engineering \
        OperatorEmail=sre-oncall@example.com \
        MonthlyBudgetUSD=250 \
    --tags workload=wa-reference environment=prod costcenter=platform-engineering

Waiting for changeset to be created..
Waiting for stack create/update to complete
Successfully created/updated stack - wa-reference-prod

$ aws cloudformation describe-stacks --stack-name wa-reference-prod \
    --query 'Stacks[0].Outputs[].[OutputKey,OutputValue]' --output table
------------------------------------------------------------------------------------------
|                                     DescribeStacks                                     |
+-----------------------+----------------------------------------------------------------+
|  ServiceUrl           |  http://wa-reference-prod-alb-1042783661.us-east-1.elb.amazonaws.com |
|  AutoScalingGroupName |  wa-reference-prod-asg                                         |
|  TargetGroupArn       |  arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/wa-reference-prod-tg/6d0ecf831eec9f09 |
|  JobQueueUrl          |  https://sqs.us-east-1.amazonaws.com/123456789012/wa-reference-prod-jobs |
|  DeadLetterQueueUrl   |  https://sqs.us-east-1.amazonaws.com/123456789012/wa-reference-prod-jobs-dlq |
|  ArtifactBucketName   |  wa-reference-prod-artifacts-123456789012-us-east-1            |
|  AvailabilityZones    |  us-east-1a, us-east-1b                                        |
+-----------------------+----------------------------------------------------------------+
```

---

## 6. Verification: proving the principles actually hold

A principle you have not verified is a belief. Each check below produces a machine-readable answer you can put in CI.

### 6.1 Reliability — is capacity genuinely spread across fault domains?

```console
$ ALB=$(aws cloudformation describe-stacks --stack-name wa-reference-prod \
        --query "Stacks[0].Outputs[?OutputKey=='ServiceUrl'].OutputValue" --output text)

$ aws autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names wa-reference-prod-asg \
    --query 'AutoScalingGroups[0].Instances[].[InstanceId,AvailabilityZone,LifecycleState,HealthStatus]' \
    --output table
--------------------------------------------------------------------
|                    DescribeAutoScalingGroups                     |
+----------------------+-------------+------------+----------------+
|  i-0a3f9c17d2b884e51 |  us-east-1a |  InService |  Healthy       |
|  i-04c81ae59f7b6d033 |  us-east-1b |  InService |  Healthy       |
+----------------------+-------------+------------+----------------+

# The one-line assertion you put in CI: capacity must span >= 2 AZs.
$ aws autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names wa-reference-prod-asg \
    --query 'length(AutoScalingGroups[0].Instances[?LifecycleState==`InService`].AvailabilityZone | sort(@) | [])' \
    --output text
2
```

If that number is `1`, you do not have a multi-AZ workload — you have two subnets and one AZ's worth of instances. This is the single most common false-positive in "we're multi-AZ" claims.

```console
$ TG=$(aws cloudformation describe-stacks --stack-name wa-reference-prod \
       --query "Stacks[0].Outputs[?OutputKey=='TargetGroupArn'].OutputValue" --output text)

$ aws elbv2 describe-target-health --target-group-arn "$TG" \
    --query 'TargetHealthDescriptions[].[Target.Id,TargetHealth.State,TargetHealth.Reason]' \
    --output table
--------------------------------------------------------
|                 DescribeTargetHealth                 |
+----------------------+----------+--------------------+
|  i-0a3f9c17d2b884e51 |  healthy |  None              |
|  i-04c81ae59f7b6d033 |  healthy |  None              |
+----------------------+----------+--------------------+

$ for i in 1 2 3 4; do curl -s "$ALB/"; done
workload=wa-reference env=prod az=us-east-1a id=i-0a3f9c17d2b884e51
workload=wa-reference env=prod az=us-east-1b id=i-04c81ae59f7b6d033
workload=wa-reference env=prod az=us-east-1a id=i-0a3f9c17d2b884e51
workload=wa-reference env=prod az=us-east-1b id=i-04c81ae59f7b6d033
```

### 6.2 Security — are the identity and encryption principles enforced?

```console
# IMDSv2 required on every instance ("keep people away from data").
$ aws ec2 describe-instances \
    --filters "Name=tag:workload,Values=wa-reference" "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[].[InstanceId,MetadataOptions.HttpTokens,MetadataOptions.HttpPutResponseHopLimit]' \
    --output text
i-0a3f9c17d2b884e51     required        1
i-04c81ae59f7b6d033     required        1

# No long-lived credentials on the instances - only the assumed role.
$ aws ec2 describe-instances \
    --filters "Name=tag:workload,Values=wa-reference" \
    --query 'Reservations[].Instances[].IamInstanceProfile.Arn' --output text
arn:aws:iam::123456789012:instance-profile/wa-reference-prod-InstanceProfile-1QY8XKZ4LMN2P
arn:aws:iam::123456789012:instance-profile/wa-reference-prod-InstanceProfile-1QY8XKZ4LMN2P

# Every attached volume encrypted at rest.
$ aws ec2 describe-volumes \
    --filters "Name=tag:workload,Values=wa-reference" \
    --query 'Volumes[].[VolumeId,Encrypted,VolumeType,Size]' --output text
vol-0f14b8a92c7d3e650    True    gp3     20
vol-09e2c7d41ba8f3d17    True    gp3     20

# No ingress on 22 anywhere in the workload's security groups.
$ aws ec2 describe-security-groups \
    --filters "Name=vpc-id,Values=$(aws ec2 describe-vpcs \
        --filters 'Name=tag:workload,Values=wa-reference' --query 'Vpcs[0].VpcId' --output text)" \
    --query 'SecurityGroups[].IpPermissions[?FromPort==`22`]' --output text
# (empty - correct)

# Human access path is Session Manager, audited in CloudTrail.
$ aws ssm start-session --target i-0a3f9c17d2b884e51
Starting session with SessionId: platform-architect-0d9b41c7a2f6e5830
sh-5.2$ exit
Exiting session with sessionId: platform-architect-0d9b41c7a2f6e5830.
```

### 6.3 Game day — *test recovery procedures* with AWS Fault Injection Service

This is the step that converts "we are resilient" from a claim into evidence. Save as `az-failure-experiment.json`:

```json
{
  "description": "Game day: simulate the loss of all workload capacity in one AZ",
  "roleArn": "arn:aws:iam::123456789012:role/FISExperimentRole",
  "tags": {
    "workload": "wa-reference",
    "environment": "prod",
    "purpose": "well-architected-reliability-REL12"
  },
  "stopConditions": [
    {
      "source": "aws:cloudwatch:alarm",
      "value": "arn:aws:cloudwatch:us-east-1:123456789012:alarm:wa-reference-prod-elb-5xx"
    }
  ],
  "targets": {
    "instancesInOneAz": {
      "resourceType": "aws:ec2:instance",
      "resourceTags": {
        "workload": "wa-reference",
        "environment": "prod"
      },
      "filters": [
        {
          "path": "State.Name",
          "values": ["running"]
        },
        {
          "path": "Placement.AvailabilityZone",
          "values": ["us-east-1a"]
        }
      ],
      "selectionMode": "ALL"
    }
  },
  "actions": {
    "stopAzA": {
      "actionId": "aws:ec2:stop-instances",
      "description": "Stop every workload instance in us-east-1a",
      "parameters": {
        "startInstancesAfterDuration": "PT10M"
      },
      "targets": {
        "Instances": "instancesInOneAz"
      }
    }
  },
  "experimentOptions": {
    "accountTargeting": "single-account",
    "emptyTargetResolutionMode": "fail"
  }
}
```

> The `stopConditions` block is the *"safely automate where possible"* principle made concrete: if the experiment causes real customer-visible 5xx, FIS halts it automatically. A game day without a stop condition is an outage you scheduled.
> For a stronger AZ simulation that also severs network paths rather than stopping instances, use the `aws:network:disrupt-connectivity` action scoped to the subnets in the target AZ.

```console
$ aws fis create-experiment-template --cli-input-json file://az-failure-experiment.json \
    --query 'experimentTemplate.[id,description]' --output text
EXTa7Kd93mQ2LpZv    Game day: simulate the loss of all workload capacity in one AZ

$ aws fis start-experiment --experiment-template-id EXTa7Kd93mQ2LpZv \
    --query 'experiment.[id,state.status]' --output text
EXPb2Nf81rW4TgYc    initiating

# Watch what the customer sees while the AZ is "gone".
$ while true; do
>   printf '%s ' "$(date -u +%H:%M:%S)"
>   curl -s -o /dev/null -w '%{http_code} %{time_total}s\n' "$ALB/"
>   sleep 5
> done
14:02:10 200 0.041s
14:02:15 200 0.038s
14:02:20 200 0.043s     <-- experiment starts, us-east-1a instances stopping
14:02:25 200 0.040s
14:02:30 200 0.039s     <-- ALB has already drained the failing target
14:02:35 200 0.042s
14:03:40 200 0.044s     <-- ASG launching a replacement in us-east-1b
14:05:15 200 0.037s

$ aws elbv2 describe-target-health --target-group-arn "$TG" \
    --query 'TargetHealthDescriptions[].[Target.Id,TargetHealth.State,TargetHealth.Reason]' --output table
------------------------------------------------------------------------------
|                            DescribeTargetHealth                            |
+----------------------+-----------+-------------------------------------------+
|  i-0a3f9c17d2b884e51 |  unused   |  Target.NotInUse                          |
|  i-04c81ae59f7b6d033 |  healthy  |  None                                     |
|  i-07b5e0d3a91cf2846 |  initial  |  Elb.RegistrationInProgress               |
+----------------------+-----------+-------------------------------------------+

$ aws fis get-experiment --id EXPb2Nf81rW4TgYc \
    --query 'experiment.[state.status,state.reason]' --output text
completed       Experiment completed.
```

**The game day report — the actual deliverable:**

| Observation | Value | Verdict |
|---|---|---|
| Customer-visible 5xx during the event | 0 | Pass |
| p99 latency delta | +6 ms | Pass |
| Time to remove failed target from rotation | ~30 s (2 × 15 s health checks) | Pass |
| Time to restore full capacity | 3 m 25 s | Pass |
| Alarm that fired first | `wa-reference-prod-az-capacity-floor` | Pass — the right one |
| Runbook accuracy | Step 4 referenced a deleted dashboard | **Fail → fix committed** |

That last row is the value of the exercise. Documentation rots silently; only an exercise finds it.

### 6.4 Cost Optimization and Sustainability — is attribution real?

```console
# Cost-allocation tags must be ACTIVATED in Billing or the Budget filter matches nothing.
$ aws ce list-cost-allocation-tags --status Active \
    --query 'CostAllocationTags[].[TagKey,Type,Status]' --output table
------------------------------------------------
|          ListCostAllocationTags              |
+---------------+------------+-----------------+
|  workload     |  UserDefined |  Active       |
|  environment  |  UserDefined |  Active       |
|  costcenter   |  UserDefined |  Active       |
+---------------+------------+-----------------+

$ aws ce get-cost-and-usage \
    --time-period Start=2026-08-01,End=2026-09-01 \
    --granularity MONTHLY \
    --metrics UnblendedCost \
    --group-by Type=TAG,Key=workload \
    --query 'ResultsByTime[0].Groups[].[Keys[0],Metrics.UnblendedCost.Amount]' --output table
------------------------------------------------
|              GetCostAndUsage                 |
+----------------------------+-----------------+
|  workload$wa-reference     |  187.4400000000 |
|  workload$                 |  41.2900000000  |   <-- untagged: attribution gap
+----------------------------+-----------------+
```

**Interpretation:** a non-empty `workload$` (empty value) row means resources escaping attribution — usually console-created or from a module that forgot `PropagateAtLaunch`. Principle *"analyze and attribute expenditure"* is violated until that row is zero.

```console
# "Anticipate and adopt more efficient offerings" + right-sizing, from data.
$ aws compute-optimizer get-ec2-instance-recommendations \
    --filters name=Finding,values=Overprovisioned \
    --query 'instanceRecommendations[].[instanceName,currentInstanceType,finding,recommendationOptions[0].instanceType,recommendationOptions[0].savingsOpportunity.estimatedMonthlySavings.value]' \
    --output table
-------------------------------------------------------------------------------------
|                    GetEC2InstanceRecommendations                                  |
+-------------------+---------------+-----------------+-------------+---------------+
|  legacy-batch-01  |  m5.4xlarge   |  OVER_PROVISIONED |  m7g.xlarge |  312.55      |
|  legacy-batch-02  |  m5.4xlarge   |  OVER_PROVISIONED |  m7g.xlarge |  312.55      |
+-------------------+---------------+-----------------+-------------+---------------+
```

### 6.5 The review itself — driving the Well-Architected Tool from the CLI

```console
$ aws wellarchitected list-lenses --lens-type AWS_OFFICIAL \
    --query 'LensSummaries[].[LensAlias,LensName]' --output table
-----------------------------------------------------------------
|                          ListLenses                           |
+---------------------------+-----------------------------------+
|  wellarchitected          |  AWS Well-Architected Framework   |
|  serverless               |  Serverless Lens                  |
|  softwareasaservice       |  SaaS Lens                        |
|  foundationaltechnicalreview |  FTR Lens                      |
+---------------------------+-----------------------------------+

$ aws wellarchitected create-workload \
    --workload-name wa-reference-prod \
    --description "Payments API reference workload - CLF task 1.2" \
    --environment PRODUCTION \
    --aws-regions us-east-1 \
    --lenses wellarchitected \
    --review-owner sre-oncall@example.com \
    --query '[WorkloadId,WorkloadArn]' --output text
9c1f4a7be0d2358af61b0c4d5e7a9382    arn:aws:wellarchitected:us-east-1:123456789012:workload/9c1f4a7be0d2358af61b0c4d5e7a9382

$ WID=9c1f4a7be0d2358af61b0c4d5e7a9382

$ aws wellarchitected get-lens-review --workload-id "$WID" --lens-alias wellarchitected \
    --query 'LensReview.PillarReviewSummaries[].[PillarName,RiskCounts.HIGH,RiskCounts.MEDIUM,RiskCounts.NONE,RiskCounts.UNANSWERED]' \
    --output table
---------------------------------------------------------------------
|                          GetLensReview                            |
+--------------------------+------+--------+-------+----------------+
|  Operational Excellence  |  0   |   0    |   0   |      11        |
|  Security                |  0   |   0    |   0   |      11        |
|  Reliability             |  0   |   0    |   0   |      12        |
|  Performance Efficiency  |  0   |   0    |   0   |       8        |
|  Cost Optimization       |  0   |   0    |   0   |      11        |
|  Sustainability          |  0   |   0    |   0   |       6        |
+--------------------------+------+--------+-------+----------------+

# After the team answers the questions:
$ aws wellarchitected list-lens-review-improvements \
    --workload-id "$WID" --lens-alias wellarchitected \
    --query 'ImprovementSummaries[?Risk==`HIGH`].[PillarId,QuestionId,Risk,QuestionTitle]' \
    --output table
--------------------------------------------------------------------------------------------------
|                              ListLensReviewImprovements                                        |
+--------------------+-----------------+--------+------------------------------------------------+
|  reliability       |  REL_13         |  HIGH  |  How do you plan for disaster recovery (DR)?   |
|  security          |  SEC_10         |  HIGH  |  How do you anticipate, respond to, and        |
|                    |                 |        |  recover from incidents?                       |
|  costOptimization  |  COST_02        |  HIGH  |  How do you govern usage?                      |
+--------------------+-----------------+--------+------------------------------------------------+

# The milestone is what makes the next review a MEASUREMENT rather than an opinion.
$ aws wellarchitected create-milestone \
    --workload-id "$WID" --milestone-name "2026-Q3 baseline" \
    --query '[WorkloadId,MilestoneNumber]' --output text
9c1f4a7be0d2358af61b0c4d5e7a9382    1
```

---

## 7. Failure diagnosis playbook

### 7.1 Symptom → cause → command

| Symptom | Most likely cause | Diagnostic command | Fix |
|---|---|---|---|
| ALB returns `503 Service Unavailable`, no target IDs in the log | Zero healthy targets in the target group | `aws elbv2 describe-target-health --target-group-arn "$TG"` | See §7.2 |
| ALB returns `502 Bad Gateway` | Target accepted the TCP connection then sent a malformed/empty response, or app crashed mid-request | `aws logs tail /aws/vpc/... --follow`; check app logs | Fix the app; ensure keep-alive idle timeout > ALB's 60 s |
| ASG launches instances that immediately terminate (loop) | `HealthCheckGracePeriod` shorter than boot + app start | `aws autoscaling describe-scaling-activities --auto-scaling-group-name ... --max-items 10` | Raise grace period; make the health check shallow |
| Scaling never triggers under load | Detailed monitoring off (5-min metrics), or the metric chosen is not the bottleneck | `aws cloudwatch get-metric-statistics --namespace AWS/AutoScaling ...` | Enable 1-minute metrics; target-track on `ALBRequestCountPerTarget` if latency-bound, not CPU |
| Fleet thrashes (scale out/in every few minutes) | Symmetric, too-aggressive policy; no warmup | `describe-scaling-activities` shows alternating Launch/Terminate | Set `DefaultInstanceWarmup`; slow scale-in |
| Instances have no internet, `dnf` hangs | Private subnet routed to a NAT in a failed AZ, or missing route | `aws ec2 describe-route-tables --filters Name=association.subnet-id,Values=...` | Restore per-AZ NAT (the prod path in the template) |
| App gets `AccessDenied` calling AWS APIs | IMDSv2 required but SDK/agent too old, or hop limit blocks a container | `curl` IMDS with and without a token from the instance | Update SDK; for containers use task roles, not IMDS |
| Budget alert never fires | Cost allocation tags never activated in Billing | `aws ce list-cost-allocation-tags --status Active` | Activate the tag; wait up to 24 h for backfill |
| DLQ filling silently | `maxReceiveCount` reached; poison message or a downstream outage | `aws sqs get-queue-attributes --attribute-names ApproximateNumberOfMessages` | Alarm on the DLQ (template does), then redrive |
| Stack update hangs at `UPDATE_IN_PROGRESS` on the ASG | Rolling update waiting on instances that never become healthy | `describe-scaling-activities` + `describe-target-health` | `PauseTime` expiry triggers rollback; fix the AMI/app |

### 7.2 Deep dive: `503` with zero healthy targets

```console
$ curl -s -o /dev/null -w '%{http_code}\n' "$ALB/"
503

$ aws elbv2 describe-target-health --target-group-arn "$TG" --output json
{
    "TargetHealthDescriptions": [
        {
            "Target": {"Id": "i-0a3f9c17d2b884e51", "Port": 8080},
            "HealthCheckPort": "8080",
            "TargetHealth": {
                "State": "unhealthy",
                "Reason": "Target.Timeout",
                "Description": "Request timed out"
            }
        },
        {
            "Target": {"Id": "i-04c81ae59f7b6d033", "Port": 8080},
            "HealthCheckPort": "8080",
            "TargetHealth": {
                "State": "unhealthy",
                "Reason": "Target.Timeout",
                "Description": "Request timed out"
            }
        }
    ]
}
```

Decision tree, driven by `TargetHealth.Reason`:

| Reason | Meaning | Where the fault is |
|---|---|---|
| `Target.Timeout` | No TCP/HTTP response before the health-check timeout | Security group does not allow ALB→8080, **or** the process is not listening, **or** it is too slow (blocked on a dependency) |
| `Target.FailedHealthChecks` | Responded, but not with a code in `Matcher` | Wrong `HealthCheckPath`, or the app returns 302/404 there |
| `Target.ResponseCodeMismatch` | Responded with an unmatched status | Align `Matcher.HttpCode` with reality |
| `Target.NotRegistered` | Instance is not in the target group | ASG `TargetGroupARNs` missing, or the instance was detached |
| `Target.NotInUse` / `unused` | Not in service (stopped, or ASG state is not `InService`) | Look at the ASG, not the ALB |
| `Elb.InternalError` | ALB-side problem | Check Health Dashboard; rare |

Confirm the SG path is not the cause:

```console
$ aws ec2 describe-security-groups --group-ids sg-0b7c14e829d3f6a05 \
    --query 'SecurityGroups[0].IpPermissions[].[FromPort,ToPort,UserIdGroupPairs[0].GroupId]' --output text
8080    8080    sg-0e93a1f7c25b8d640

$ aws ec2 describe-instances --instance-ids i-0a3f9c17d2b884e51 \
    --query 'Reservations[0].Instances[0].SecurityGroups[].GroupId' --output text
sg-0b7c14e829d3f6a05
```

The chain is correct, so the fault is on the instance. Go in through Session Manager — **not SSH**:

```console
$ aws ssm start-session --target i-0a3f9c17d2b884e51
Starting session with SessionId: platform-architect-4b8e0f1c96d5a2371

sh-5.2$ sudo ss -lntp | grep 8080
sh-5.2$ sudo systemctl status nginx --no-pager
× nginx.service - The nginx HTTP and reverse proxy server
     Loaded: loaded (/usr/lib/systemd/system/nginx.service; enabled)
     Active: failed (Result: exit-code) since Wed 2026-09-02 22:11:04 UTC; 18min ago
    Process: 1471 ExecStartPre=/usr/sbin/nginx -t (code=exited, status=1/FAILURE)

sh-5.2$ sudo nginx -t
nginx: [emerg] duplicate default server for 0.0.0.0:8080 in /etc/nginx/conf.d/app.conf:2
nginx: configuration file /etc/nginx/nginx.conf test failed
```

**Root cause:** an AMI update reintroduced a default server block that collides with the workload's. **What the Framework says to do about it:**

- *Learn from all operational events* → the fix is a code change (remove the stale conf in UserData / bake it into the AMI), not a manual `rm` on two instances.
- *Make frequent, small, reversible changes* → had this shipped as a canary rather than a full AMI roll, one instance would have failed and the target group would still have had healthy capacity.
- *Anticipate failure* → the `MinSuccessfulInstancesPercent: 100` in the `UpdatePolicy` is exactly the guardrail that turns this into a **failed, rolled-back stack update** instead of an outage. Verify it is actually engaged:

```console
$ aws cloudformation describe-stack-events --stack-name wa-reference-prod \
    --query 'StackEvents[0:4].[Timestamp,LogicalResourceId,ResourceStatus,ResourceStatusReason]' \
    --output text
2026-09-02T22:29:41Z  wa-reference-prod  UPDATE_ROLLBACK_COMPLETE  None
2026-09-02T22:24:18Z  AutoScalingGroup   UPDATE_FAILED  Received 0 SUCCESS signal(s) out of 1. Rolling back.
2026-09-02T22:19:02Z  AutoScalingGroup   UPDATE_IN_PROGRESS  Rolling update initiated
2026-09-02T22:18:55Z  wa-reference-prod  UPDATE_IN_PROGRESS  User Initiated
```

### 7.3 The failure the free checks cannot catch

Everything above verifies *structure*. None of it verifies that the workload is **correct** — a fleet can be perfectly multi-AZ, auto-healing, encrypted, tagged and budgeted while computing the wrong answer. That is why *"drive architectures using data"* pairs with business-level metrics (orders completed, payments settled) and not just infrastructure metrics. An SLO on `HTTPCode_Target_2XX_Count` is satisfied by a service returning `200 OK` with an empty body.

---

## 8. Exam-focused summary

### 8.1 Mapping principle → pillar (the most-tested association)

| If the question mentions… | The pillar is |
|---|---|
| Runbooks, deployments, IaC, small reversible changes, post-incident review | Operational Excellence |
| Least privilege, encryption, traceability, defence in depth, IAM | Security |
| Multi-AZ, Auto Scaling for availability, backups, RTO/RPO, testing recovery | Reliability |
| Right-sizing, serverless, global reach, caching, selecting the right resource type | Performance Efficiency |
| Savings Plans, Spot, tagging for chargeback, unit cost, turning things off | Cost Optimization |
| Carbon footprint, utilisation, efficient hardware, minimising provisioned resources | Sustainability |

### 8.2 Principles that are easy to confuse

| Similar-sounding pair | The distinction |
|---|---|
| *Stop guessing capacity* (Reliability) vs *Adopt a consumption model* (Cost) | Reliability worries about **too little** capacity at peak; Cost worries about **too much** at trough. Auto Scaling serves both. |
| *Use managed services* (Operational Excellence, Sustainability) vs *Stop spending on undifferentiated heavy lifting* (Cost) | Same action, three motives: less to operate, higher shared utilisation, less money on racking. |
| *Automatically recover from failure* (Reliability) vs *Anticipate failure* (Operational Excellence) | Reliability is the **automated response**; Operational Excellence is the **pre-mortem and the exercise** that made the response exist. |
| *Test systems at production scale* (general) vs *Test recovery procedures* (Reliability) | The first tests the happy path at real size; the second injects the failure. |
| Well-Architected **Framework** vs Well-Architected **Tool** vs **Trusted Advisor** | Framework = the guidance. Tool = the free self-service review that produces HRIs and milestones. Trusted Advisor = automated checks against your live account (full check set with Business/Enterprise Support). |
| Well-Architected **lens** vs **pillar** | A pillar is a dimension of quality; a lens is a domain-specific question set (Serverless, SaaS, ML) layered on top. |

### 8.3 Distractors the exam uses

- **"The Well-Architected Framework guarantees your workload is secure/highly available."** No. It is guidance and a review mechanism; it produces risk findings, not guarantees.
- **"The Well-Architected Tool costs money."** No — the Tool is free. What costs money is remediating what it finds, and (separately) the full Trusted Advisor check set requires a Business/Enterprise Support plan.
- **"Design for failure means buying more reliable hardware."** No — it means assuming components will fail and architecting so that their failure is not the workload's failure.
- **"There are five pillars."** Six, since December 2021.
- **"Scaling vertically is the cloud approach to scale."** The principle is explicitly *scale horizontally*; vertical scaling preserves a single point of failure and hits a ceiling.
- **"Loose coupling means microservices."** Loose coupling is about failure and change isolation (queues, load balancers, well-defined interfaces). A well-designed monolith behind an ALB is more loosely coupled from its clients than a chatty, synchronously-chained microservice mesh.

### 8.4 Ten-line self-check

1. Name the six pillars, in any order.
2. Give the six general design principles.
3. Which pillar owns "keep people away from data"?
4. Which pillar owns "consider mechanical sympathy"?
5. What is the difference between an HRI and an MRI in the Well-Architected Tool?
6. Why does a milestone matter?
7. Give one concrete AWS mechanism for "improve through game days".
8. Name two pillars that pull against each other on NAT Gateway count, and say how you would resolve it.
9. Why is `HealthCheckType: ELB` more aligned with "automatically recover from failure" than `EC2`?
10. Which principle is violated by an untagged resource, and what does it break downstream?

---

## 9. Referencias

**Certification and exam scope**
- AWS Certified Cloud Practitioner (CLF-C02) — Exam Guide: https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf
- AWS Certified Cloud Practitioner — certification page: https://aws.amazon.com/certification/certified-cloud-practitioner/

**AWS Well-Architected Framework**
- Framework overview: https://aws.amazon.com/architecture/well-architected/
- Framework documentation (welcome): https://docs.aws.amazon.com/wellarchitected/latest/framework/welcome.html
- General design principles: https://docs.aws.amazon.com/wellarchitected/latest/framework/general-design-principles.html
- Operational Excellence pillar: https://docs.aws.amazon.com/wellarchitected/latest/operational-excellence-pillar/welcome.html
- Security pillar: https://docs.aws.amazon.com/wellarchitected/latest/security-pillar/welcome.html
- Reliability pillar: https://docs.aws.amazon.com/wellarchitected/latest/reliability-pillar/welcome.html
- Performance Efficiency pillar: https://docs.aws.amazon.com/wellarchitected/latest/performance-efficiency-pillar/welcome.html
- Cost Optimization pillar: https://docs.aws.amazon.com/wellarchitected/latest/cost-optimization-pillar/welcome.html
- Sustainability pillar: https://docs.aws.amazon.com/wellarchitected/latest/sustainability-pillar/welcome.html
- AWS Well-Architected Tool user guide: https://docs.aws.amazon.com/wellarchitected/latest/userguide/intro.html
- Lenses: https://docs.aws.amazon.com/wellarchitected/latest/userguide/lenses.html
- `aws wellarchitected` CLI reference: https://docs.aws.amazon.com/cli/latest/reference/wellarchitected/

**Reliability and resilience mechanics**
- Regions and Availability Zones: https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/using-regions-availability-zones.html
- Global infrastructure: https://aws.amazon.com/about-aws/global-infrastructure/
- Amazon EC2 Auto Scaling user guide: https://docs.aws.amazon.com/autoscaling/ec2/userguide/what-is-amazon-ec2-auto-scaling.html
- Target tracking scaling policies: https://docs.aws.amazon.com/autoscaling/ec2/userguide/as-scaling-target-tracking.html
- Application Load Balancer health checks: https://docs.aws.amazon.com/elasticloadbalancing/latest/application/target-group-health-checks.html
- AWS Fault Injection Service: https://docs.aws.amazon.com/fis/latest/userguide/what-is.html
- AWS Resilience Hub: https://docs.aws.amazon.com/resilience-hub/latest/userguide/what-is.html
- Disaster recovery options in the cloud: https://docs.aws.amazon.com/whitepapers/latest/disaster-recovery-workloads-on-aws/disaster-recovery-options-in-the-cloud.html

**Security mechanics**
- Shared Responsibility Model: https://aws.amazon.com/compliance/shared-responsibility-model/
- IAM best practices: https://docs.aws.amazon.com/IAM/latest/UserGuide/best-practices.html
- Instance metadata service (IMDSv2): https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/configuring-instance-metadata-service.html
- AWS Systems Manager Session Manager: https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager.html
- VPC Flow Logs: https://docs.aws.amazon.com/vpc/latest/userguide/flow-logs.html

**Operational Excellence and infrastructure as code**
- AWS CloudFormation user guide: https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/Welcome.html
- `UpdatePolicy` attribute: https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-attribute-updatepolicy.html
- CloudFormation intrinsic functions: https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/intrinsic-function-reference.html
- Amazon CloudWatch user guide: https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/WhatIsCloudWatch.html
- AWS Trusted Advisor: https://docs.aws.amazon.com/awssupport/latest/user/trusted-advisor.html

**Cost Optimization and Sustainability mechanics**
- AWS Cost Explorer: https://docs.aws.amazon.com/cost-management/latest/userguide/ce-what-is.html
- AWS Budgets: https://docs.aws.amazon.com/cost-management/latest/userguide/budgets-managing-costs.html
- Cost allocation tags: https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/cost-alloc-tags.html
- Savings Plans: https://docs.aws.amazon.com/savingsplans/latest/userguide/what-is-savings-plans.html
- Amazon EC2 Spot Instances: https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/using-spot-instances.html
- AWS Compute Optimizer: https://docs.aws.amazon.com/compute-optimizer/latest/ug/what-is-compute-optimizer.html
- S3 Lifecycle configuration: https://docs.aws.amazon.com/AmazonS3/latest/userguide/object-lifecycle-mgmt.html
- AWS Graviton: https://aws.amazon.com/ec2/graviton/
- Customer Carbon Footprint Tool: https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/ccft-overview.html

**Pricing (verify current figures before quoting them)**
- Amazon EC2 pricing: https://aws.amazon.com/ec2/pricing/
- Elastic Load Balancing pricing: https://aws.amazon.com/elasticloadbalancing/pricing/
- Amazon VPC pricing (NAT Gateway): https://aws.amazon.com/vpc/pricing/
- Amazon CloudWatch pricing: https://aws.amazon.com/cloudwatch/pricing/
- AWS Pricing Calculator: https://calculator.aws/