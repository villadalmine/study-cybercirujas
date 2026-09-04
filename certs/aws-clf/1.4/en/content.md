# Topic 1.4 — Understand Concepts of Cloud Economics

**Certification:** AWS Certified Cloud Practitioner (CLF-C02) · **Domain 1: Cloud Concepts** · **Task Statement 1.4**
**Exam weight:** 6.0 · **Profile:** Principal Platform Architect / Senior SRE

---

## 1. Motivation and the Production Architectural Problem

### 1.1 Why an SRE has to care about a spreadsheet

Cloud economics is the only reliability dimension where the failure mode is *silent, cumulative, and irreversible after the fact*. A memory leak pages you. A cost leak invoices you thirty days later, after the money is spent and the usage records are frozen in an immutable billing period. There is no rollback for a closed invoice.

The architectural problem is this: **in a data center, capacity is a decision made once every three to five years by a procurement committee. In the cloud, capacity is a decision made thousands of times per day by every engineer holding an IAM role, by every Auto Scaling policy, and by every Kubernetes scheduler loop.** The control plane for spend moved from Finance to the deployment pipeline, and almost nobody moved the guardrails with it.

Concretely, here is the shape of the failure in production:

```
On-premises:   spend is a step function.   Decisions/year: ~1     Feedback latency: 3-5 years
Cloud:         spend is a continuous fn.   Decisions/day:  10^3+  Feedback latency: 8-24 hours
```

The 8–24 hour figure is not rhetorical: it is the ingestion lag of AWS Cost Explorer and the Cost and Usage Report (CUR). Until you build the machinery in section 4, your *actual* feedback latency is the invoice — 30 to 60 days. An SRE would never accept a monitoring system with a 30-day scrape interval for latency. That is exactly what most organizations accept for spend.

### 1.2 The three failure modes you will actually see

**Failure mode A — The provisioning ratchet.**
Engineers size instances for peak plus a safety margin, and nothing in the system ever ratchets them back down. On-premises this was invisible because the hardware was already paid for; a server at 12% CPU cost the same as a server at 90%. In the cloud, that same 12% utilization is a continuously metered wire transfer. Typical enterprise on-premises virtualization estates run at 12–18% average CPU utilization. Lift-and-shift that ratio into EC2 without rightsizing and you have built a machine that converts idle CPU cycles into invoices.

**Failure mode B — Untagged, unattributable spend.**
When 40% of the bill cannot be attributed to a team, product, or environment, no optimization decision can be made, because no one owns the number. This is the FinOps equivalent of running a distributed system without trace IDs. You can see that latency is bad; you cannot see *where*.

**Failure mode C — The commitment trap.**
Reserved Instances and Savings Plans are the cloud's re-introduction of CAPEX-like risk. A 3-year all-upfront RI on an instance family you refactor away in month 8 is a stranded asset with the same economics as a decommissioned server — you bought hardware, you just bought it with a JSON API call. The entire value proposition of the cloud (variable cost, elasticity) is *voluntarily surrendered* in exchange for discount, and that trade must be a deliberate, measured architectural decision, not a procurement reflex.

### 1.3 What the exam is actually testing

CLF-C02 Task Statement 1.4 tests whether you understand:

- Aspects of cloud economics — **TCO**, **OPEX vs CAPEX**, licensing strategies, **rightsizing**
- The cost savings of moving to the cloud (reduced data center footprint, reduced hardware spend)
- **Fixed vs variable** cost
- On-premises cost structure vs cloud cost structure (operational cost, hardware, labor)
- The benefits of **automation** (provisioning, Infrastructure as Code)
- The benefits of **managed AWS services** (RDS vs self-managed databases on EC2, ECS/EKS vs raw EC2, DynamoDB vs a database on EC2)

The rest of this document treats those as engineering requirements, not vocabulary.

---

## 2. The Cost Model: Formal Definitions

### 2.1 CAPEX vs OPEX — and why it is an accounting statement, not a technical one

This distinction is about *when the money leaves and how the books record it*, not about whether the technology is good.

| Dimension | CAPEX (Capital Expenditure) | OPEX (Operational Expenditure) |
|---|---|---|
| Cash outflow | Large, up front, before any workload runs | Continuous, in arrears, proportional to consumption |
| Accounting treatment | Capitalized on the balance sheet, depreciated over the asset's useful life (typically 3–5 yr for servers) | Expensed on the income statement in the period incurred |
| Effect on EBITDA | Favorable — depreciation sits below the EBITDA line | Unfavorable — the full cost hits operating expense |
| Approval path | Capital committee, annual budget cycle, months of lead time | Departmental budget, often self-service |
| Risk on demand shortfall | Total — the asset is bought regardless of whether it is used | Near zero — you stop paying when you stop consuming |
| Risk on demand surge | Total — no capacity available for weeks or months | Near zero — provisioned in minutes |
| Residual value | Non-zero but rapidly decaying; disposal has its own cost | None — nothing is owned |
| Technology refresh | Discrete, disruptive, every 3–5 years | Continuous — new instance generations are an API call away |

**The exam answer:** moving to the cloud trades CAPEX for OPEX. **The architect's answer:** it trades *capital risk* for *operational discipline*. You stop being wrong once, expensively, every five years; you start being wrong continuously, cheaply, and correctably — *if and only if* you build the feedback loop.

Note the EBITDA point, because it is the single most common reason a CFO resists the migration a platform team wants. It is a real objection, not an irrational one, and Savings Plans / RI all-upfront purchases exist partly to address it: an upfront commitment fee is prepaid expense, amortized over the term, which restores some of the CAPEX-like treatment finance is used to.

### 2.2 Fixed vs variable cost

Orthogonal to CAPEX/OPEX. A cost is **fixed** if it does not change with the volume of work performed, **variable** if it does.

| | Fixed | Variable |
|---|---|---|
| On-premises | Servers, SAN, network gear, data center lease, most licensing, most of the ops payroll | Electricity above baseline, per-incident support, bandwidth overage |
| AWS | Savings Plan / RI commitment, Reserved capacity, Support plan minimum, Direct Connect port hours, provisioned-capacity services (e.g. Provisioned IOPS, DynamoDB provisioned WCU/RCU), a `t3.micro` you never turn off | On-Demand instance hours, Spot, S3 storage-GB and requests, Lambda GB-seconds, data transfer out, DynamoDB on-demand capacity |

**The critical nuance the exam will probe:** the cloud does not make cost variable. *The cloud makes it possible for cost to be variable.* An EC2 instance running 24×7 with no autoscaling is a fixed cost that happens to be billed hourly. You have replicated the on-premises economics inside AWS and added a margin. Elasticity is an architectural property you have to build; the platform only removes the obstacle.

### 2.3 Total Cost of Ownership (TCO)

TCO is the sum of every cost attributable to running a workload over a defined horizon, **including the ones no one invoices you for**. The systematic error in every naive comparison is that the on-premises side omits the costs that are already buried in other budget lines.

```
TCO = Σ (direct infrastructure)
    + Σ (facilities: space, power, cooling, physical security)
    + Σ (software licensing and support contracts)
    + Σ (labor: fully loaded, including on-call and racking)
    + Σ (resilience: DR site, backup media, offsite storage)
    + Σ (risk-adjusted cost of over-provisioning and refresh cycles)
    - Σ (residual asset value)
```

The two terms that are almost always missing from a homemade comparison are **fully loaded labor** and **the cost of over-provisioning**. Together they usually exceed the hardware line.

---

## 3. Worked TCO Comparison — 200-VM Enterprise Estate

The following is a concrete, arithmetic-complete model. Numbers are illustrative of a mid-size estate in a colocation facility; **the method is the deliverable, not the constants.** Every AWS constant must be re-derived from the Price List API (section 5.6) for your region and date.

### 3.1 On-premises steady-state annual cost

Estate: 20 dual-socket hosts (32 physical cores, 384 GB RAM each), 200 TB usable SAN, 10 racks in colocation, ~200 production and non-production VMs.

| Cost line | Basis | Annual cost (USD) |
|---|---|---|
| Server hardware | 20 × $18,000 = $360,000, straight-line over 5 yr | 72,000 |
| Storage (SAN) | $180,000 over 5 yr | 36,000 |
| Network + security appliances | $90,000 over 5 yr | 18,000 |
| Software licensing (hypervisor, guest OS, backup) | annual subscription + SA | 85,000 |
| Colocation (space, power, cooling) | 10 racks × $1,200/mo | 144,000 |
| Hardware maintenance & vendor support | 12% of $630,000 hardware CAPEX | 75,600 |
| Labor | 3.5 FTE × $120,000 fully loaded | 420,000 |
| DR site (secondary, warm) | ~40% of primary infrastructure | 60,000 |
| **Total** | | **910,600** |

Structural observations an architect should make immediately:

- **Labor is 46% of the total.** Hardware depreciation is 8%. Any "the cloud is more expensive than servers" argument that compares an EC2 invoice to a server purchase order is comparing an 8% slice to a 100% total.
- Facilities + maintenance ($219,600) is 2.4× the hardware depreciation. The building costs more than the boxes.
- The 5-year depreciation assumes the refresh happens on schedule. In practice, hardware runs to 6–7 years with rising failure rates — a hidden reliability tax that never appears on a TCO spreadsheet but does appear in your incident review.
- Average CPU utilization on this class of estate is typically 12–18%. You are paying 100% of $910,600 for roughly 15% of the work the hardware could do.

### 3.2 AWS steady-state annual cost (post-migration, post-rightsizing)

After rightsizing (section 6) the 200 VMs collapse to 120 × `m6i.large` and 30 × `m6i.xlarge` equivalents, plus managed services replacing self-managed components.

On-Demand baseline, `us-east-1` list price as of 2025 (`m6i.large` = $0.096/hr, `m6i.xlarge` = $0.192/hr, 730 hr/month):

```
120 × 0.096 × 730 × 12 = $100,915/yr
 30 × 0.192 × 730 × 12 = $ 50,458/yr
                          ---------
On-Demand compute       = $151,373/yr
```

Applying a Compute Savings Plans commitment at ~80% coverage plus an off-hours schedule on non-production yields an effective ~45% reduction → **~$84,000/yr**.

| Cost line | Basis | Annual cost (USD) |
|---|---|---|
| EC2 compute | On-Demand $151,373 less SP + scheduling (~45%) | 84,000 |
| EBS gp3 | 90 TB provisioned × $0.08/GB-mo | 86,400 |
| EBS snapshots | 20 TB × $0.05/GB-mo | 12,000 |
| S3 Standard-IA (backup/archive) | 60 TB × $0.0125/GB-mo | 9,000 |
| Data transfer out | 8 TB/mo × $0.09/GB | 8,640 |
| NAT Gateways | 4 × $0.045/hr + 6 TB/mo processing | 4,815 |
| Managed services (RDS, ELB, AWS Backup) | measured | 36,000 |
| AWS Support (Business tier) | tiered percentage of spend | 22,000 |
| Labor | 2.0 FTE × $135,000 fully loaded | 270,000 |
| **Total steady state** | | **532,855** |

**Steady-state delta: $377,745/yr, a 41% reduction.**

### 3.3 The number the vendor slide leaves out: migration cost

One-time migration cost (discovery, refactoring, dual-running, data transfer in, training, parallel operations): ~$450,000, amortized over 3 years = **$150,000/yr for years 1–3**.

| Horizon | On-premises | AWS | Delta | Reduction |
|---|---|---|---|---|
| Years 1–3 (incl. migration amortization) | 910,600 | 682,855 | 227,745 | 25% |
| Year 4+ (steady state) | 910,600 | 532,855 | 377,745 | 41% |

Two honest conclusions:

1. **The savings are real but they are not 70%.** A 25–45% TCO reduction is a defensible, achievable engineering claim. Anything above that in a business case is either counting avoided-refresh CAPEX as savings, or assuming a labor reduction that will not happen.
2. **The savings live in labor and facilities, not in compute unit price.** AWS compute is *not* cheaper per core-hour than owning a depreciated server at high utilization. It is cheaper per *unit of delivered business capability*, because you delete the racking, the firmware patching, the SAN zoning, the DR site, and the capacity-planning committee.

### 3.4 Where the money actually goes: cost drivers by architecture decision

| Decision | Cost impact | Direction |
|---|---|---|
| Lift-and-shift without rightsizing | +40–70% vs rightsized | Worst common outcome |
| Rightsizing (Compute Optimizer-driven) | −20–40% of compute | Highest ROI, zero commitment risk |
| Non-production scheduling (nights/weekends off) | −65% of non-prod compute (168 → ~60 hr/wk) | High ROI, low risk |
| Compute Savings Plans, 1-yr no-upfront | up to −27% typical on covered usage | Requires stable baseline |
| Compute Savings Plans, 3-yr all-upfront | up to −66% (AWS published maximum) | High commitment risk |
| EC2 Instance Savings Plans, 3-yr all-upfront | up to −72% (AWS published maximum) | Locks family + region |
| Standard Reserved Instances, 3-yr all-upfront | up to −72% (AWS published maximum) | Locks family + region, capacity reservation optional |
| Spot Instances | up to −90% vs On-Demand | Requires interruption-tolerant architecture |
| Graviton (ARM) migration | −10–20% at equal or better performance | Requires ARM-compatible build |
| gp2 → gp3 EBS migration | −20% on storage, decoupled IOPS | Near-zero risk, frequently forgotten |
| Managed service adoption (RDS, DynamoDB, Fargate) | Higher unit price, lower labor + lower incident cost | Net-positive at almost all scales |
| Untagged resources | 0% direct, but blocks every optimization above | The silent multiplier |

---

## 4. AWS Pricing Models and the Trade-off Surface

### 4.1 The three fundamental pricing principles

AWS states three (exam-testable, and genuinely the model):

1. **Pay as you go** — pay only for what you consume, no minimum, no termination fee for On-Demand resources.
2. **Save when you commit** — Savings Plans and Reserved Instances exchange a 1- or 3-year usage commitment for a discount of up to 72%.
3. **Pay less by using more** — volume-based tiered pricing (S3 storage tiers, data transfer tiers) reduces the marginal unit price as consumption rises.

A fourth economic force sits behind all three: **AWS's own economies of scale.** AWS has reduced prices well over a hundred times since 2006 without a customer needing to renegotiate. That is a structural argument for OPEX that no owned asset can match — your depreciating server never gets cheaper.

### 4.2 Commitment instruments — full trade-off table

| | On-Demand | Spot | Compute Savings Plans | EC2 Instance Savings Plans | Standard RI | Convertible RI | Dedicated Host |
|---|---|---|---|---|---|---|---|
| Max discount vs On-Demand | — | up to 90% | up to 66% | up to 72% | up to 72% | up to 66% | varies |
| Commitment unit | none | none | $/hour | $/hour | instance count | instance count | host |
| Term | none | none | 1 or 3 yr | 1 or 3 yr | 1 or 3 yr | 1 or 3 yr | 1 or 3 yr (or On-Demand) |
| Locks instance family | no | no | **no** | **yes** | yes | changeable | yes (host type) |
| Locks region | no | no | **no** | yes | yes | yes | yes |
| Locks AZ | no | no | no | no | optional | optional | yes |
| Locks OS / tenancy | no | no | no | no | yes | changeable | n/a |
| Covers Fargate | no | no | **yes** | no | no | no | no |
| Covers Lambda | no | no | **yes** | no | no | no | no |
| Covers SageMaker | no | no | separate SageMaker SP | no | no | no | no |
| Capacity reservation | no | no | no | no | AZ-scoped RI only | AZ-scoped only | yes (physical) |
| Can be sold on Marketplace | n/a | n/a | **no** | **no** | yes (Standard only) | no | no |
| Interruption risk | none | 2-min notice | none | none | none | none | none |
| Socket/core visibility for BYOL | no | no | no | no | no | no | **yes** |
| Best fit | spiky, unproven, short-lived | batch, CI, stateless, fault-tolerant | mixed/evolving compute estate | stable, known family | legacy stable + capacity guarantee | stable but expected to evolve | core-licensed software, compliance isolation |

**Architectural guidance, in order:** rightsize first, schedule second, commit third. Committing to unrightsized usage buys a discount on waste — the single most common and most expensive FinOps error. Discount instruments are a *financial* optimization applied on top of an *architectural* one; reversing the order locks the waste in for 1–3 years.

**On Savings Plans vs RIs:** Savings Plans are the modern default. They commit to a dollars-per-hour spend rate rather than to a specific instance shape, which preserves the flexibility that is the point of the cloud. Reserved Instances retain exactly two advantages: Standard RIs can be sold on the Reserved Instance Marketplace (an exit path Savings Plans do not have), and zonal RIs provide a capacity reservation. Note also that RIs cover services Savings Plans do not — RDS, ElastiCache, OpenSearch, Redshift, and DynamoDB have their own reserved-capacity constructs.

### 4.3 Licensing strategies — BYOL vs License Included

This is explicitly named in the exam guide and it is where the largest single-line surprises hide.

| | License Included | BYOL (Bring Your Own License) |
|---|---|---|
| How you pay | Bundled into the hourly instance rate | Separately, to the software vendor |
| Cost shape | Pure variable — stops when the instance stops | Fixed — you own the entitlement regardless of usage |
| Compliance burden | AWS handles it | **Yours**, entirely |
| Tenancy requirement | Shared tenancy fine | Often requires **Dedicated Host** |
| Elasticity | Full — scale to zero, scale to 100 | Capped at the number of licenses owned |
| True-up risk | None | Audit exposure if you exceed entitlements |
| Best fit | Variable/unpredictable workloads, new deployments | Existing perpetual licenses with Software Assurance, steady-state workloads |

**The Dedicated Host mechanic — this is the part that trips people up.** Core- and socket-based licensing (Windows Server Datacenter, SQL Server, Oracle Database) requires you to prove how many *physical* cores and sockets the software runs on. On shared tenancy you cannot see the physical host, so you cannot satisfy the license terms. **Dedicated Hosts expose physical socket and core count, and provide affinity so a stopped instance restarts on the same host** — that is precisely why they exist, and why they are the mandatory landing zone for most BYOL scenarios.

Additionally, Microsoft licenses acquired **on or after 1 October 2019 without active Software Assurance cannot be deployed on dedicated hosted cloud services** (which includes AWS, Azure, Google Cloud, and Alibaba). Licenses acquired before that date are grandfathered. **License Mobility through Software Assurance** is the exception that permits certain products (SQL Server, Exchange, SharePoint) to run on default shared tenancy. Get this wrong and you have either a compliance exposure or an unnecessary Dedicated Host bill.

**AWS License Manager** is the control plane for this: it tracks entitlements, enforces hard or soft limits at instance-launch time, and produces the utilization evidence you present in an audit. **AWS OLA (Optimization and Licensing Assessment)** is a free AWS-run engagement that models your license position across BYOL and License Included options.

### 4.4 Managed services — the "undifferentiated heavy lifting" calculation

The AWS Well-Architected Cost Optimization pillar names five design principles; the fourth is **"Stop spending money on undifferentiated heavy lifting."** Here is what that means numerically.

| Workload | Self-managed on EC2 | AWS managed equivalent | The real trade |
|---|---|---|---|
| Relational DB | EC2 + EBS + your own HA, backups, patching, failover testing | **Amazon RDS / Aurora** | RDS instance-hour is ~20–35% above the equivalent raw EC2 hour. It replaces roughly 0.3–0.5 FTE of DBA/SRE toil per estate and removes an entire class of 3 a.m. failover incidents. Break-even is well below one FTE. |
| Key-value store at scale | Cassandra/MongoDB cluster on EC2 | **DynamoDB** | Eliminates cluster capacity planning, compaction tuning, and node replacement entirely. On-demand capacity mode makes cost genuinely proportional to requests. |
| Container orchestration | Self-hosted Kubernetes control plane on EC2 | **EKS / ECS**, optionally **Fargate** | EKS control plane is a flat hourly fee (~$0.10/hr per cluster). Running your own HA etcd + API server costs more in instances alone, before counting the upgrade toil. |
| Object storage | Storage servers / NAS | **S3** | 11 nines of durability, lifecycle tiering, no capacity planning. Nothing self-hosted competes on TCO. |
| Load balancing | HAProxy/NGINX fleet on EC2 | **ELB (ALB/NLB)** | Removes a stateful, availability-critical tier from your on-call surface. |

**The economic principle:** the managed service always has a higher *unit* price and a lower *total* price, because the unit price you compare against omits the labor. This is the same arithmetic error as section 3.1 — comparing the 8% slice instead of the 100% total. The counter-case is real but narrow: at very large, very stable scale with an existing specialist team, self-managing can win. Below that threshold, it does not.

### 4.5 The benefits of automation and IaC — expressed as cost

| Manual provisioning | Infrastructure as Code |
|---|---|
| Provisioning lead time: days to weeks | Minutes, in a pipeline |
| Environment drift: guaranteed, unmeasurable | Detectable (`cloudformation detect-stack-drift`, `terraform plan`) |
| Teardown of ephemeral environments: forgotten | Automatic, part of the pipeline lifecycle |
| Tagging: inconsistent, applied after the fact if at all | **Enforced at creation** — the prerequisite for all cost attribution |
| Rightsizing change: a ticket and a change window | A parameter diff and a deploy |
| Cost of a mistake | Persists until someone notices | Reverted by redeploying the previous commit |

The cost-relevant point is the fourth row. **Cost allocation tags applied by IaC at resource-creation time are the difference between a bill you can act on and a bill you can only pay.** Tags applied retroactively do not backfill historical CUR data — the past is unattributable forever.

---

## 5. Complete Infrastructure Manifests

Everything below is deployable as written. Replace the account IDs, bucket names, and email addresses.

### 5.1 CloudFormation — FinOps data foundation (CUR 2.0 export, Cost Category, S3 target)

Deploy in the **management account**, in `us-east-1` (billing APIs are global endpoints hosted there).

```yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: >
  FinOps data foundation. Creates the S3 destination and bucket policy for a
  Data Exports (CUR 2.0) delivery, plus a Cost Category that maps linked
  accounts and tags into business dimensions. Deploy in the Organizations
  management account in us-east-1.

Parameters:
  ExportBucketName:
    Type: String
    Description: Globally unique S3 bucket name for CUR 2.0 delivery.
    AllowedPattern: '^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$'
  ExportName:
    Type: String
    Default: cur2-hourly-resources
  RetentionDays:
    Type: Number
    Default: 2555          # 7 years, typical finance retention requirement
    MinValue: 90

Resources:

  # ------------------------------------------------------------------
  # Destination bucket. Versioned, encrypted, public access fully blocked.
  # ------------------------------------------------------------------
  ExportBucket:
    Type: AWS::S3::Bucket
    DeletionPolicy: Retain
    UpdateReplacePolicy: Retain
    Properties:
      BucketName: !Ref ExportBucketName
      VersioningConfiguration:
        Status: Enabled
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
      OwnershipControls:
        Rules:
          - ObjectOwnership: BucketOwnerEnforced
      LifecycleConfiguration:
        Rules:
          - Id: TierAndExpire
            Status: Enabled
            Transitions:
              - StorageClass: STANDARD_IA
                TransitionInDays: 90
              - StorageClass: GLACIER_IR
                TransitionInDays: 365
            ExpirationInDays: !Ref RetentionDays
            NoncurrentVersionExpiration:
              NoncurrentDays: 30
      Tags:
        - Key: CostCenter
          Value: PLATFORM-FINOPS
        - Key: Environment
          Value: shared
        - Key: DataClassification
          Value: confidential

  # ------------------------------------------------------------------
  # Bucket policy required by the billing service to write the export.
  # The two SourceArn/SourceAccount conditions are the confused-deputy
  # guard - do not omit them.
  # ------------------------------------------------------------------
  ExportBucketPolicy:
    Type: AWS::S3::BucketPolicy
    Properties:
      Bucket: !Ref ExportBucket
      PolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Sid: AllowBillingServiceGetBucketAcl
            Effect: Allow
            Principal:
              Service: billingreports.amazonaws.com
            Action:
              - s3:GetBucketAcl
              - s3:GetBucketPolicy
            Resource: !GetAtt ExportBucket.Arn
            Condition:
              StringEquals:
                aws:SourceAccount: !Ref AWS::AccountId
              ArnLike:
                aws:SourceArn: !Sub 'arn:${AWS::Partition}:cur:us-east-1:${AWS::AccountId}:definition/*'

          - Sid: AllowBillingServicePutObject
            Effect: Allow
            Principal:
              Service: billingreports.amazonaws.com
            Action: s3:PutObject
            Resource: !Sub '${ExportBucket.Arn}/*'
            Condition:
              StringEquals:
                aws:SourceAccount: !Ref AWS::AccountId
              ArnLike:
                aws:SourceArn: !Sub 'arn:${AWS::Partition}:cur:us-east-1:${AWS::AccountId}:definition/*'

          - Sid: AllowDataExportsService
            Effect: Allow
            Principal:
              Service: bcm-data-exports.amazonaws.com
            Action:
              - s3:PutObject
              - s3:GetBucketPolicy
talk:
            Resource:
              - !GetAtt ExportBucket.Arn
              - !Sub '${ExportBucket.Arn}/*'
            Condition:
              StringEquals:
                aws:SourceAccount: !Ref AWS::AccountId

          - Sid: DenyInsecureTransport
            Effect: Deny
            Principal: '*'
            Action: 's3:*'
            Resource:
              - !GetAtt ExportBucket.Arn
              - !Sub '${ExportBucket.Arn}/*'
            Condition:
              Bool:
                aws:SecureTransport: false

  # ------------------------------------------------------------------
  # CUR 2.0 export via the Data Exports API. Hourly granularity with
  # resource IDs is the only configuration from which rightsizing and
  # per-resource attribution can be computed. Do NOT settle for daily.
  # ------------------------------------------------------------------
  CostAndUsageExport:
    Type: AWS::BCMDataExports::Export
    DependsOn: ExportBucketPolicy
    Properties:
      Export:
        Name: !Ref ExportName
        Description: Hourly CUR 2.0 with resource IDs, Parquet, overwrite.
        DataQuery:
          TableConfigurations:
            COST_AND_USAGE_REPORT:
              TIME_GRANULARITY: HOURLY
              INCLUDE_RESOURCES: 'TRUE'
              INCLUDE_MANUAL_DISCOUNT_COMPATIBILITY: 'FALSE'
              INCLUDE_SPLIT_COST_ALLOCATION_DATA: 'TRUE'
          QueryStatement: >-
            SELECT
              bill_billing_period_start_date,
              bill_payer_account_id,
              line_item_usage_account_id,
              line_item_usage_start_date,
              line_item_line_item_type,
              line_item_product_code,
              line_item_usage_type,
              line_item_operation,
              line_item_resource_id,
              line_item_usage_amount,
              line_item_unblended_cost,
              line_item_blended_cost,
              pricing_term,
              pricing_unit,
              product,
              product_region_code,
              resource_tags,
              cost_category,
              reservation_effective_cost,
              reservation_unused_amortized_upfront_fee_for_billing_period,
              reservation_unused_recurring_fee,
              reservation_reservation_a_r_n,
              savings_plan_savings_plan_effective_cost,
              savings_plan_total_commitment_to_date,
              savings_plan_used_commitment,
              savings_plan_savings_plan_a_r_n
            FROM COST_AND_USAGE_REPORT
        DestinationConfigurations:
          S3Destination:
            S3Bucket: !Ref ExportBucket
            S3Prefix: cur2
            S3Region: !Ref AWS::Region
            S3OutputConfigurations:
              OutputType: CUSTOM
              Format: PARQUET
              Compression: PARQUET
              Overwrite: OVERWRITE_REPORT
        RefreshCadence:
          Frequency: SYNCHRONOUS

  # ------------------------------------------------------------------
  # Cost Category: a server-side dimension applied to every cost record,
  # including historical ones. This is how you attribute spend that
  # tagging missed - it works on account ID, not on resource tags.
  # ------------------------------------------------------------------
  BusinessUnitCostCategory:
    Type: AWS::CE::CostCategory
    Properties:
      Name: BusinessUnit
      RuleVersion: CostCategoryExpression.v1
      DefaultValue: UNALLOCATED
      Rules: !Sub |
        [
          {
            "Value": "PLATFORM",
            "Rule": {
              "Dimensions": {
                "Key": "LINKED_ACCOUNT",
                "Values": ["111122223333", "444455556666"],
                "MatchOptions": ["EQUALS"]
              }
            },
            "Type": "REGULAR"
          },
          {
            "Value": "PAYMENTS",
            "Rule": {
              "Tags": {
                "Key": "CostCenter",
                "Values": ["PAY-1000", "PAY-1001"],
                "MatchOptions": ["EQUALS"]
              }
            },
            "Type": "REGULAR"
          },
          {
            "Value": "SANDBOX",
            "Rule": {
              "Tags": {
                "Key": "Environment",
                "Values": ["sandbox", "dev"],
                "MatchOptions": ["EQUALS"]
              }
            },
            "Type": "REGULAR"
          }
        ]
      SplitChargeRules: !Sub |
        [
          {
            "Source": "PLATFORM",
            "Targets": ["PAYMENTS", "SANDBOX"],
            "Method": "PROPORTIONAL"
          }
        ]

Outputs:
  ExportBucketArn:
    Description: CUR 2.0 destination bucket ARN.
    Value: !GetAtt ExportBucket.Arn
    Export:
      Name: !Sub '${AWS::StackName}-ExportBucketArn'
  CostCategoryArn:
    Description: BusinessUnit Cost Category ARN.
    Value: !Ref BusinessUnitCostCategory
```

> **Correction to the manifest above:** the stray token `talk:` inside `AllowDataExportsService` is a typo — delete that line. The statement should read `Action: [s3:PutObject, s3:GetBucketPolicy]` followed directly by `Resource:`. Validate with `aws cloudformation validate-template` before deploying (section 7.1).

### 5.2 CloudFormation — Budgets, budget actions, and anomaly detection

```yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: >
  Cost guardrails: a monthly cost budget with actual and forecasted alerts,
  an automated budget action that attaches a deny policy at 100% of a
  sandbox budget, a Savings Plans coverage budget, and ML-based cost
  anomaly detection with a per-service monitor.

Parameters:
  FinOpsEmail:
    Type: String
    Default: finops@example.com
  MonthlyBudgetUsd:
    Type: Number
    Default: 45000
  SandboxBudgetUsd:
    Type: Number
    Default: 2000
  AlertTopicName:
    Type: String
    Default: finops-cost-alerts

Resources:

  CostAlertTopic:
    Type: AWS::SNS::Topic
    Properties:
      TopicName: !Ref AlertTopicName
      DisplayName: FinOps cost alerts
      KmsMasterKeyId: alias/aws/sns

  CostAlertTopicPolicy:
    Type: AWS::SNS::TopicPolicy
    Properties:
      Topics: [!Ref CostAlertTopic]
      PolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Sid: AllowBudgetsPublish
            Effect: Allow
            Principal:
              Service: budgets.amazonaws.com
            Action: sns:Publish
            Resource: !Ref CostAlertTopic
            Condition:
              StringEquals:
                aws:SourceAccount: !Ref AWS::AccountId
          - Sid: AllowCostAnomalyPublish
            Effect: Allow
            Principal:
              Service: costalerts.amazonaws.com
            Action: sns:Publish
            Resource: !Ref CostAlertTopic

  CostAlertSubscription:
    Type: AWS::SNS::Subscription
    Properties:
      TopicArn: !Ref CostAlertTopic
      Protocol: email
      Endpoint: !Ref FinOpsEmail

  # ------------------------------------------------------------------
  # Primary monthly cost budget. Note the four thresholds: three ACTUAL
  # tripwires and one FORECASTED. The forecasted alert is the only one
  # that gives you time to react; the others are post-mortems.
  # ------------------------------------------------------------------
  MonthlyCostBudget:
    Type: AWS::Budgets::Budget
    Properties:
      Budget:
        BudgetName: org-monthly-cost
        BudgetType: COST
        TimeUnit: MONTHLY
        BudgetLimit:
          Amount: !Ref MonthlyBudgetUsd
          Unit: USD
        CostTypes:
          IncludeTax: true
          IncludeSubscription: true
          UseBlended: false          # unblended: what each account actually incurred
          IncludeRefund: false
          IncludeCredit: false       # credits mask real consumption - exclude them
          IncludeUpfront: true
          IncludeRecurring: true
          IncludeOtherSubscription: true
          IncludeSupport: true
          IncludeDiscount: true
          UseAmortized: true         # amortized: spread SP/RI upfront across the term
      NotificationsWithSubscribers:
        - Notification:
            NotificationType: ACTUAL
            ComparisonOperator: GREATER_THAN
            Threshold: 60
            ThresholdType: PERCENTAGE
          Subscribers:
            - SubscriptionType: SNS
              Address: !Ref CostAlertTopic
        - Notification:
            NotificationType: ACTUAL
            ComparisonOperator: GREATER_THAN
            Threshold: 85
            ThresholdType: PERCENTAGE
          Subscribers:
            - SubscriptionType: SNS
              Address: !Ref CostAlertTopic
            - SubscriptionType: EMAIL
              Address: !Ref FinOpsEmail
        - Notification:
            NotificationType: ACTUAL
            ComparisonOperator: GREATER_THAN
            Threshold: 100
            ThresholdType: PERCENTAGE
          Subscribers:
            - SubscriptionType: SNS
              Address: !Ref CostAlertTopic
            - SubscriptionType: EMAIL
              Address: !Ref FinOpsEmail
        - Notification:
            NotificationType: FORECASTED
            ComparisonOperator: GREATER_THAN
            Threshold: 100
            ThresholdType: PERCENTAGE
          Subscribers:
            - SubscriptionType: SNS
              Address: !Ref CostAlertTopic
            - SubscriptionType: EMAIL
              Address: !Ref FinOpsEmail

  # ------------------------------------------------------------------
  # Sandbox budget scoped by cost allocation tag. This is why tagging
  # discipline matters: without the tag, this filter matches nothing
  # and the budget silently reports $0 forever.
  # ------------------------------------------------------------------
  SandboxBudget:
    Type: AWS::Budgets::Budget
    Properties:
      Budget:
        BudgetName: sandbox-monthly-cost
        BudgetType: COST
        TimeUnit: MONTHLY
        BudgetLimit:
          Amount: !Ref SandboxBudgetUsd
          Unit: USD
        CostFilters:
          TagKeyValue:
            - 'user:Environment$sandbox'
      NotificationsWithSubscribers:
        - Notification:
            NotificationType: ACTUAL
            ComparisonOperator: GREATER_THAN
            Threshold: 80
            ThresholdType: PERCENTAGE
          Subscribers:
            - SubscriptionType: SNS
              Address: !Ref CostAlertTopic

  # ------------------------------------------------------------------
  # Utilization/coverage budgets: these alert on the EFFICIENCY of
  # commitments, not on absolute dollars. A Savings Plan at 92%
  # utilization is leaking 8% of a fixed cost every hour.
  # ------------------------------------------------------------------
  SavingsPlansUtilizationBudget:
    Type: AWS::Budgets::Budget
    Properties:
      Budget:
        BudgetName: sp-utilization-floor
        BudgetType: SAVINGS_PLANS_UTILIZATION
        TimeUnit: MONTHLY
        BudgetLimit:
          Amount: 98
          Unit: PERCENTAGE
      NotificationsWithSubscribers:
        - Notification:
            NotificationType: ACTUAL
            ComparisonOperator: LESS_THAN
            Threshold: 98
            ThresholdType: PERCENTAGE
          Subscribers:
            - SubscriptionType: SNS
              Address: !Ref CostAlertTopic

  SavingsPlansCoverageBudget:
    Type: AWS::Budgets::Budget
    Properties:
      Budget:
        BudgetName: sp-coverage-floor
        BudgetType: SAVINGS_PLANS_COVERAGE
        TimeUnit: MONTHLY
        BudgetLimit:
          Amount: 70
          Unit: PERCENTAGE
      NotificationsWithSubscribers:
        - Notification:
            NotificationType: ACTUAL
            ComparisonOperator: LESS_THAN
            Threshold: 70
            ThresholdType: PERCENTAGE
          Subscribers:
            - SubscriptionType: SNS
              Address: !Ref CostAlertTopic

  # ------------------------------------------------------------------
  # Budget action: at 100% of the sandbox budget, attach a deny policy
  # to the sandbox role. ApprovalModel MANUAL means a human confirms;
  # switch to AUTOMATIC only once you trust the budget's accuracy.
  # ------------------------------------------------------------------
  BudgetActionRole:
    Type: AWS::IAM::Role
    Properties:
      RoleName: finops-budget-action-role
      AssumeRolePolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Effect: Allow
            Principal:
              Service: budgets.amazonaws.com
            Action: sts:AssumeRole
            Condition:
              StringEquals:
                aws:SourceAccount: !Ref AWS::AccountId
      Policies:
        - PolicyName: attach-restriction-policy
          PolicyDocument:
            Version: '2012-10-17'
            Statement:
              - Effect: Allow
                Action:
                  - iam:AttachRolePolicy
                  - iam:DetachRolePolicy
                Resource: !Sub 'arn:${AWS::Partition}:iam::${AWS::AccountId}:role/SandboxEngineerRole'
              - Effect: Allow
                Action:
                  - iam:GetPolicy
                  - iam:ListEntitiesForPolicy
                Resource: !Ref SandboxDenyLaunchPolicy

  SandboxDenyLaunchPolicy:
    Type: AWS::IAM::ManagedPolicy
    Properties:
      ManagedPolicyName: sandbox-budget-breach-deny-launch
      Description: Attached automatically when the sandbox budget is exhausted.
      PolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Sid: DenyExpensiveLaunches
            Effect: Deny
            Action:
              - ec2:RunInstances
              - rds:CreateDBInstance
              - rds:CreateDBCluster
              - eks:CreateCluster
              - sagemaker:CreateNotebookInstance
              - sagemaker:CreateTrainingJob
            Resource: '*'

  SandboxBudgetAction:
    Type: AWS::Budgets::BudgetsAction
    Properties:
      BudgetName: !Ref SandboxBudget
      ActionType: APPLY_IAM_POLICY
      NotificationType: ACTUAL
      ApprovalModel: MANUAL
      ExecutionRoleArn: !GetAtt BudgetActionRole.Arn
      ActionThreshold:
        Type: PERCENTAGE
        Value: 100
      Definition:
        IamActionDefinition:
          PolicyArn: !Ref SandboxDenyLaunchPolicy
          Roles:
            - SandboxEngineerRole
      Subscribers:
        - Type: SNS
          Address: !Ref CostAlertTopic
        - Type: EMAIL
          Address: !Ref FinOpsEmail

  # ------------------------------------------------------------------
  # Cost Anomaly Detection. This is ML-based and catches what a static
  # budget structurally cannot: a 300% spike in one service inside an
  # otherwise on-budget month.
  # ------------------------------------------------------------------
  ServiceAnomalyMonitor:
    Type: AWS::CE::AnomalyMonitor
    Properties:
      MonitorName: all-services-monitor
      MonitorType: DIMENSIONAL
      MonitorDimension: SERVICE

  CostCategoryAnomalyMonitor:
    Type: AWS::CE::AnomalyMonitor
    Properties:
      MonitorName: business-unit-monitor
      MonitorType: CUSTOM
      MonitorSpecification: !Sub |
        {
          "CostCategories": {
            "Key": "BusinessUnit",
            "Values": ["PLATFORM", "PAYMENTS"],
            "MatchOptions": ["EQUALS"]
          }
        }

  AnomalySubscription:
    Type: AWS::CE::AnomalySubscription
    Properties:
      SubscriptionName: finops-anomaly-immediate
      Frequency: IMMEDIATE
      MonitorArnList:
        - !Ref ServiceAnomalyMonitor
        - !Ref CostCategoryAnomalyMonitor
      Subscribers:
        - Type: SNS
          Address: !Ref CostAlertTopic
          Status: CONFIRMED
      ThresholdExpression: !Sub |
        {
          "Dimensions": {
            "Key": "ANOMALY_TOTAL_IMPACT_ABSOLUTE",
            "Values": ["250"],
            "MatchOptions": ["GREATER_THAN_OR_EQUAL"]
          }
        }

Outputs:
  AlertTopicArn:
    Value: !Ref CostAlertTopic
  BudgetActionRoleArn:
    Value: !GetAtt BudgetActionRole.Arn
```

### 5.3 Terraform — tag governance, the prerequisite for all attribution

```hcl
terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }
}

provider "aws" {
  region = "us-east-1"          # Organizations and billing APIs are us-east-1
}

locals {
  # The canonical tag contract. Every resource in every account carries these.
  # Changing this list is a governance decision, not a code change.
  required_tags = ["CostCenter", "Environment", "Owner", "Application"]

  allowed_environments = ["prod", "staging", "dev", "sandbox"]
}

# ---------------------------------------------------------------------
# Organizations tag policy: defines the CASE and the ALLOWED VALUES of
# tags. A tag policy does NOT require a tag to exist - it only governs
# the shape of the tag when present. Requiring existence is the SCP's job.
# ---------------------------------------------------------------------
resource "aws_organizations_policy" "cost_allocation_tags" {
  name        = "cost-allocation-tag-contract"
  description = "Normalizes cost allocation tag keys and constrains Environment values."
  type        = "TAG_POLICY"

  content = jsonencode({
    tags = {
      CostCenter = {
        tag_key = { "@@assign" = "CostCenter" }
        enforced_for = {
          "@@assign" = [
            "ec2:instance",
            "ec2:volume",
            "rds:db",
            "s3:bucket",
            "lambda:function",
            "elasticloadbalancing:loadbalancer",
          ]
        }
      }
      Environment = {
        tag_key    = { "@@assign" = "Environment" }
        tag_value  = { "@@assign" = local.allowed_environments }
        enforced_for = {
          "@@assign" = [
            "ec2:instance",
            "ec2:volume",
            "rds:db",
            "s3:bucket",
            "lambda:function",
          ]
        }
      }
      Owner = {
        tag_key = { "@@assign" = "Owner" }
      }
      Application = {
        tag_key = { "@@assign" = "Application" }
      }
    }
  })
}

resource "aws_organizations_policy_attachment" "tag_policy_root" {
  policy_id = aws_organizations_policy.cost_allocation_tags.id
  target_id = data.aws_organizations_organization.this.roots[0].id
}

data "aws_organizations_organization" "this" {}

# ---------------------------------------------------------------------
# SCP: hard-deny creation of billable resources without the required
# tags. This is the enforcement point. Note the aws:RequestTag/Null
# condition - it fails the API call at creation time, which is the only
# moment at which tagging is free.
# ---------------------------------------------------------------------
resource "aws_organizations_policy" "deny_untagged_billable" {
  name        = "deny-untagged-billable-resources"
  description = "Denies creation of the highest-cost resource types without cost allocation tags."
  type        = "SERVICE_CONTROL_POLICY"

  content = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DenyRunInstancesWithoutCostTags"
        Effect = "Deny"
        Action = [
          "ec2:RunInstances",
        ]
        Resource = [
          "arn:aws:ec2:*:*:instance/*",
          "arn:aws:ec2:*:*:volume/*",
        ]
        Condition = {
          "Null" = {
            for tag in local.required_tags :
            "aws:RequestTag/${tag}" => "true"
          }
        }
      },
      {
        Sid    = "DenyManagedServiceCreationWithoutCostTags"
        Effect = "Deny"
        Action = [
          "rds:CreateDBInstance",
          "rds:CreateDBCluster",
          "eks:CreateCluster",
          "elasticache:CreateCacheCluster",
          "es:CreateDomain",
          "sagemaker:CreateNotebookInstance",
          "redshift:CreateCluster",
        ]
        Resource = "*"
        Condition = {
          "Null" = {
            "aws:RequestTag/CostCenter"  = "true"
            "aws:RequestTag/Environment" = "true"
          }
        }
      },
      {
        Sid    = "DenyTagRemoval"
        Effect = "Deny"
        Action = [
          "ec2:DeleteTags",
          "rds:RemoveTagsFromResource",
        ]
        Resource = "*"
        Condition = {
          "ForAnyValue:StringEquals" = {
            "aws:TagKeys" = local.required_tags
          }
        }
      },
    ]
  })
}

resource "aws_organizations_policy_attachment" "scp_workload_ou" {
  policy_id = aws_organizations_policy.deny_untagged_billable.id
  target_id = var.workload_ou_id
}

variable "workload_ou_id" {
  type        = string
  description = "OU containing workload accounts. Never attach to root without a tested exception path."
}

# ---------------------------------------------------------------------
# AWS Config rule: detection for what the SCP cannot cover (resources
# created before the SCP, or by services the SCP does not gate).
# ---------------------------------------------------------------------
resource "aws_config_config_rule" "required_cost_tags" {
  name        = "required-cost-allocation-tags"
  description = "Flags resources missing cost allocation tags."

  source {
    owner             = "AWS"
    source_identifier = "REQUIRED_TAGS"
  }

  input_parameters = jsonencode({
    tag1Key = "CostCenter"
    tag2Key = "Environment"
    tag3Key = "Owner"
    tag4Key = "Application"
  })

  scope {
    compliance_resource_types = [
      "AWS::EC2::Instance",
      "AWS::EC2::Volume",
      "AWS::RDS::DBInstance",
      "AWS::S3::Bucket",
      "AWS::Lambda::Function",
      "AWS::ElasticLoadBalancingV2::LoadBalancer",
    ]
  }
}

# ---------------------------------------------------------------------
# Default tags applied by the provider to every resource this stack
# manages. Belt and braces: the SCP denies, this guarantees compliance.
# ---------------------------------------------------------------------
provider "aws" {
  alias  = "tagged"
  region = "us-east-1"

  default_tags {
    tags = {
      CostCenter  = "PLATFORM-1000"
      Environment = "shared"
      Owner       = "platform-sre"
      Application = "finops-governance"
      ManagedBy   = "terraform"
    }
  }
}
```

### 5.4 EventBridge Scheduler — non-production shutdown (the highest-ROI automation)

Non-production workloads that run 24×7 are billed for 168 hours per week and used for about 45. Shutting them down outside business hours removes ~65% of non-production compute cost with zero architectural risk.

```yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: >
  Stops tagged non-production EC2 and RDS instances outside business hours.
  168 hr/week -> 60 hr/week for the tagged fleet.

Parameters:
  ScheduleTimezone:
    Type: String
    Default: America/Argentina/Buenos_Aires
  TargetTagKey:
    Type: String
    Default: Schedule
  TargetTagValue:
    Type: String
    Default: office-hours

Resources:

  SchedulerRole:
    Type: AWS::IAM::Role
    Properties:
      AssumeRolePolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Effect: Allow
            Principal:
              Service: scheduler.amazonaws.com
            Action: sts:AssumeRole
            Condition:
              StringEquals:
                aws:SourceAccount: !Ref AWS::AccountId
      Policies:
        - PolicyName: invoke-ssm-automation
          PolicyDocument:
            Version: '2012-10-17'
            Statement:
              - Effect: Allow
                Action: ssm:StartAutomationExecution
                Resource: !Sub 'arn:${AWS::Partition}:ssm:${AWS::Region}:*:automation-definition/*'
              - Effect: Allow
                Action: iam:PassRole
                Resource: !GetAtt AutomationRole.Arn

  AutomationRole:
    Type: AWS::IAM::Role
    Properties:
      AssumeRolePolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Effect: Allow
            Principal:
              Service: ssm.amazonaws.com
            Action: sts:AssumeRole
      Policies:
        - PolicyName: stop-start-tagged-instances
          PolicyDocument:
            Version: '2012-10-17'
            Statement:
              - Effect: Allow
                Action:
                  - ec2:DescribeInstances
                  - ec2:DescribeInstanceStatus
                  - rds:DescribeDBInstances
                Resource: '*'
              - Effect: Allow
                Action:
                  - ec2:StopInstances
                  - ec2:StartInstances
                Resource: '*'
                Condition:
                  StringEquals:
                    !Sub 'aws:ResourceTag/${TargetTagKey}': !Ref TargetTagValue
              - Effect: Allow
                Action:
                  - rds:StopDBInstance
                  - rds:StartDBInstance
                Resource: '*'
                Condition:
                  StringEquals:
                    !Sub 'aws:ResourceTag/${TargetTagKey}': !Ref TargetTagValue

  StopSchedule:
    Type: AWS::Scheduler::Schedule
    Properties:
      Name: nonprod-stop-evening
      Description: Stop tagged non-prod instances at 20:00 on weekdays.
      GroupName: default
      State: ENABLED
      FlexibleTimeWindow:
        Mode: FLEXIBLE
        MaximumWindowInMinutes: 15
      ScheduleExpression: 'cron(0 20 ? * MON-FRI *)'
      ScheduleExpressionTimezone: !Ref ScheduleTimezone
      Target:
        Arn: !Sub 'arn:${AWS::Partition}:scheduler:::aws-sdk:ssm:startAutomationExecution'
        RoleArn: !GetAtt SchedulerRole.Arn
        RetryPolicy:
          MaximumRetryAttempts: 3
          MaximumEventAgeInSeconds: 3600
        Input: !Sub |
          {
            "DocumentName": "AWS-StopEC2InstanceWithTags",
            "Parameters": {
              "AutomationAssumeRole": ["${AutomationRole.Arn}"],
              "TagKey": ["${TargetTagKey}"],
              "TagValue": ["${TargetTagValue}"]
            }
          }

  StartSchedule:
    Type: AWS::Scheduler::Schedule
    Properties:
      Name: nonprod-start-morning
      Description: Start tagged non-prod instances at 08:00 on weekdays.
      GroupName: default
      State: ENABLED
      FlexibleTimeWindow:
        Mode: 'OFF'
      ScheduleExpression: 'cron(0 8 ? * MON-FRI *)'
      ScheduleExpressionTimezone: !Ref ScheduleTimezone
      Target:
        Arn: !Sub 'arn:${AWS::Partition}:scheduler:::aws-sdk:ssm:startAutomationExecution'
        RoleArn: !GetAtt SchedulerRole.Arn
        RetryPolicy:
          MaximumRetryAttempts: 3
          MaximumEventAgeInSeconds: 3600
        Input: !Sub |
          {
            "DocumentName": "AWS-StartEC2InstanceWithTags",
            "Parameters": {
              "AutomationAssumeRole": ["${AutomationRole.Arn}"],
              "TagKey": ["${TargetTagKey}"],
              "TagValue": ["${TargetTagValue}"]
            }
          }
```

### 5.5 Kubernetes — Karpenter consolidation, quotas, and cost visibility

On EKS, cluster cost is dominated by *unused node capacity*, not by pods. Karpenter's consolidation is the in-cluster equivalent of rightsizing.

```yaml
---
# EC2NodeClass: the AWS-level shape of the nodes Karpenter provisions.
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: cost-optimized
spec:
  amiFamily: AL2023
  amiSelectorTerms:
    - alias: al2023@latest
  role: KarpenterNodeRole-prod-cluster
  subnetSelectorTerms:
    - tags:
        karpenter.sh/discovery: prod-cluster
  securityGroupSelectorTerms:
    - tags:
        karpenter.sh/discovery: prod-cluster
  # gp3 over gp2: ~20% cheaper per GB and IOPS are decoupled from size,
  # so you stop over-provisioning capacity just to buy throughput.
  blockDeviceMappings:
    - deviceName: /dev/xvda
      ebs:
        volumeSize: 60Gi
        volumeType: gp3
        iops: 3000
        throughput: 125
        encrypted: true
        deleteOnTermination: true
  metadataOptions:
    httpEndpoint: enabled
    httpProtocolIPv6: disabled
    httpPutResponseHopLimit: 1
    httpTokens: required
  # Cost allocation tags propagate to every EC2 instance and EBS volume
  # Karpenter creates. Without this the cluster's compute is unattributable.
  tags:
    CostCenter: PLATFORM-1000
    Environment: prod
    Owner: platform-sre
    Application: eks-prod-cluster
    ManagedBy: karpenter
---
# Spot-first NodePool for interruption-tolerant workloads.
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: spot-general
spec:
  template:
    metadata:
      labels:
        capacity-profile: spot-general
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: cost-optimized
      expireAfter: 168h        # forced rotation weekly: patching + drift control
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["spot"]
        - key: kubernetes.io/arch
          operator: In
          values: ["amd64", "arm64"]     # allow Graviton: ~10-20% cheaper
        - key: karpenter.k8s.aws/instance-category
          operator: In
          values: ["c", "m", "r"]
        - key: karpenter.k8s.aws/instance-generation
          operator: Gt
          values: ["5"]                  # newer generations: better price/perf
        - key: karpenter.k8s.aws/instance-cpu
          operator: In
          values: ["2", "4", "8", "16"]
      taints:
        - key: capacity-type
          value: spot
          effect: NoSchedule
  # Consolidation is the money. WhenEmptyOrUnderutilized lets Karpenter
  # replace a node with a cheaper one, or bin-pack pods onto fewer nodes.
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 1m
    budgets:
      - nodes: "10%"                     # steady-state churn cap
      - nodes: "0"                       # freeze during business hours
        schedule: "0 13 * * mon-fri"
        duration: 8h
        reasons:
          - Underutilized
  limits:
    cpu: "2000"
    memory: 8000Gi
  weight: 100                            # preferred over on-demand pool
---
# On-demand fallback for workloads that cannot tolerate interruption.
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: ondemand-critical
spec:
  template:
    metadata:
      labels:
        capacity-profile: ondemand-critical
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: cost-optimized
      expireAfter: 720h
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["on-demand"]
        - key: karpenter.k8s.aws/instance-category
          operator: In
          values: ["m", "c"]
        - key: karpenter.k8s.aws/instance-generation
          operator: Gt
          values: ["5"]
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 5m
    budgets:
      - nodes: "5%"
  limits:
    cpu: "500"
    memory: 2000Gi
  weight: 10
---
# ResourceQuota: the in-cluster budget. A namespace cannot request more
# capacity than it is funded for. This is the cluster analogue of an
# AWS Budget with a budget action.
apiVersion: v1
kind: ResourceQuota
metadata:
  name: payments-quota
  namespace: payments
spec:
  hard:
    requests.cpu: "120"
    requests.memory: 480Gi
    limits.cpu: "240"
    limits.memory: 960Gi
    requests.storage: 2Ti
    persistentvolumeclaims: "40"
    count/deployments.apps: "60"
    services.loadbalancers: "4"          # each NLB/ALB is a recurring charge
---
# LimitRange: prevents the two classic cost bugs - pods with no requests
# (unschedulable capacity accounting, node sprawl) and pods that request
# an absurd amount and pin an entire node.
apiVersion: v1
kind: LimitRange
metadata:
  name: payments-defaults
  namespace: payments
spec:
  limits:
    - type: Container
      default:
        cpu: 500m
        memory: 512Mi
      defaultRequest:
        cpu: 100m
        memory: 128Mi
      max:
        cpu: "8"
        memory: 32Gi
      min:
        cpu: 10m
        memory: 32Mi
      maxLimitRequestRatio:
        cpu: "8"
        memory: "4"
---
# VerticalPodAutoscaler in recommendation-only mode: it computes the
# rightsizing answer without acting on it. Read the recommendation,
# put it in Git, deploy it. Never let VPA mutate production silently.
apiVersion: autoscaling.k8s.io/v1
kind: VerticalPodAutoscaler
metadata:
  name: payments-api-vpa
  namespace: payments
spec:
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: payments-api
  updatePolicy:
    updateMode: "Off"
  resourcePolicy:
    containerPolicies:
      - containerName: '*'
        minAllowed:
          cpu: 50m
          memory: 64Mi
        maxAllowed:
          cpu: "4"
          memory: 8Gi
        controlledResources: ["cpu", "memory"]
---
# OpenCost: maps Kubernetes workloads back to AWS billing data, so a
# namespace's cost is a real number derived from the CUR, not an estimate.
apiVersion: v1
kind: ConfigMap
metadata:
  name: opencost-config
  namespace: opencost
data:
  # Points OpenCost at the CUR-derived pricing, not at public list price.
  CLOUD_PROVIDER_API_KEY: ""
  CLUSTER_ID: "prod-cluster"
  AWS_CLUSTER_ID: "prod-cluster"
  CONFIG_PATH: "/var/configs/"
  PROMETHEUS_SERVER_ENDPOINT: "http://prometheus-server.monitoring.svc:80"
  EMIT_POD_ANNOTATIONS_METRIC: "true"
  EMIT_NAMESPACE_ANNOTATIONS_METRIC: "true"
```

### 5.6 Athena — the amortized-cost query every FinOps practice needs

Cost Explorer answers questions; the CUR answers *arbitrary* questions. This is the canonical amortized-cost expression — it converts raw line items into the number finance actually recognizes.

```sql
-- Amortized cost by BusinessUnit cost category and service, last full month.
-- The CASE expression is the whole point: unblended cost double-counts
-- Savings Plan upfront fees and undercounts covered usage. Amortized cost
-- spreads commitments across the term they were bought for.

WITH amortized AS (
  SELECT
    line_item_usage_account_id                                  AS account_id,
    line_item_product_code                                      AS service,
    resource_tags['user_costcenter']                            AS cost_center,
    resource_tags['user_environment']                           AS environment,
    cost_category['businessunit']                               AS business_unit,
    line_item_resource_id                                       AS resource_id,
    line_item_usage_start_date                                  AS usage_start,
    CASE
      WHEN line_item_line_item_type = 'SavingsPlanCoveredUsage'
        THEN savings_plan_savings_plan_effective_cost
      WHEN line_item_line_item_type = 'SavingsPlanRecurringFee'
        THEN savings_plan_total_commitment_to_date - savings_plan_used_commitment
      WHEN line_item_line_item_type = 'SavingsPlanNegation'  THEN 0
      WHEN line_item_line_item_type = 'SavingsPlanUpfrontFee' THEN 0
      WHEN line_item_line_item_type = 'DiscountedUsage'
        THEN reservation_effective_cost
      WHEN line_item_line_item_type = 'RIFee'
        THEN reservation_unused_amortized_upfront_fee_for_billing_period
           + reservation_unused_recurring_fee
      WHEN line_item_line_item_type = 'Fee'
           AND reservation_reservation_a_r_n <> '' THEN 0
      ELSE line_item_unblended_cost
    END                                                         AS amortized_cost,
    line_item_unblended_cost                                    AS unblended_cost
  FROM cur2.cost_and_usage_report
  WHERE billing_period = DATE_FORMAT(DATE_ADD('month', -1, CURRENT_DATE), '%Y-%m')
)
SELECT
  COALESCE(business_unit, 'UNALLOCATED')                        AS business_unit,
  COALESCE(cost_center,  'UNTAGGED')                            AS cost_center,
  service,
  ROUND(SUM(amortized_cost), 2)                                 AS amortized_usd,
  ROUND(SUM(unblended_cost), 2)                                 AS unblended_usd,
  ROUND(SUM(unblended_cost) - SUM(amortized_cost), 2)           AS commitment_delta,
  COUNT(DISTINCT resource_id)                                   AS resources
FROM amortized
GROUP BY 1, 2, 3
HAVING SUM(amortized_cost) > 50
ORDER BY amortized_usd DESC
LIMIT 50;
```

```sql
-- The tag coverage metric. If this is below ~95%, every optimization
-- decision downstream is guesswork. Track it as an SLI.

SELECT
  DATE_TRUNC('day', line_item_usage_start_date)                 AS day,
  ROUND(
    100.0 * SUM(CASE WHEN resource_tags['user_costcenter'] IS NOT NULL
                      AND resource_tags['user_costcenter'] <> ''
                     THEN line_item_unblended_cost ELSE 0 END)
    / NULLIF(SUM(line_item_unblended_cost), 0), 2)              AS tagged_pct,
  ROUND(SUM(line_item_unblended_cost), 2)                       AS total_usd,
  ROUND(SUM(CASE WHEN resource_tags['user_costcenter'] IS NULL
                   OR resource_tags['user_costcenter'] = ''
                 THEN line_item_unblended_cost ELSE 0 END), 2)  AS untagged_usd
FROM cur2.cost_and_usage_report
WHERE line_item_line_item_type IN ('Usage', 'DiscountedUsage', 'SavingsPlanCoveredUsage')
  AND line_item_usage_start_date >= DATE_ADD('day', -30, CURRENT_DATE)
GROUP BY 1
ORDER BY 1 DESC;
```

---

## 6. CLI Operations — Real Commands and Expected Output

All Cost Explorer / Budgets / Pricing calls target `us-east-1` regardless of where your workloads run.

### 6.1 Baseline: what did we actually spend, by service?

```bash
$ aws ce get-cost-and-usage \
    --time-period Start=2026-08-01,End=2026-09-01 \
    --granularity MONTHLY \
    --metrics "UnblendedCost" "AmortizedCost" "UsageQuantity" \
    --group-by Type=DIMENSION,Key=SERVICE \
    --region us-east-1 \
    --query 'ResultsByTime[0].Groups[?Metrics.AmortizedCost.Amount > `1000`].[Keys[0],Metrics.AmortizedCost.Amount]' \
    --output table
```

```
-------------------------------------------------------------------
|                        GetCostAndUsage                          |
+-------------------------------------------+---------------------+
|  Amazon Elastic Compute Cloud - Compute    |  7104.3382914       |
|  Amazon Relational Database Service        |  3186.9021447       |
|  EC2 - Other                               |  8221.7743190       |
|  Amazon Simple Storage Service             |  1841.2205613       |
|  Amazon Elastic Container Service for K8s  |  1093.8000000       |
|  AWS Data Transfer                         |  1226.4471028       |
+-------------------------------------------+---------------------+
```

**Read this like an SRE, not an accountant.** `EC2 - Other` at $8,221 exceeds `EC2 - Compute` at $7,104. That line is EBS volumes, snapshots, NAT Gateway hours and processing, and Elastic IPs. **When `EC2 - Other` outweighs `EC2 - Compute`, you have a storage or a NAT Gateway problem, not a compute problem** — and it is invisible in every dashboard that only charts "EC2".

Drill into it:

```bash
$ aws ce get-cost-and-usage \
    --time-period Start=2026-08-01,End=2026-09-01 \
    --granularity MONTHLY \
    --metrics "UnblendedCost" \
    --filter '{"Dimensions":{"Key":"SERVICE","Values":["EC2 - Other"]}}' \
    --group-by Type=DIMENSION,Key=USAGE_TYPE \
    --region us-east-1 \
    --query 'ResultsByTime[0].Groups[:8].[Keys[0],Metrics.UnblendedCost.Amount]' \
    --output text
```

```
USE1-EBS:VolumeUsage.gp3        3908.16
USE1-NatGateway-Bytes           1943.55
USE1-EBS:SnapshotUsage          1204.80
USE1-NatGateway-Hours            131.40
USE1-EBS:VolumeUsage.gp2         702.11
USE1-EBS:VolumeP-IOPS.piops      196.22
USE1-EBS:VolumeUsage.io1          89.44
USE1-ElasticIP:IdleAddress        46.06
```

Three actionable findings in eight lines: $702 still on gp2 (migrate to gp3, ~20% cheaper), $1,943 of NAT Gateway data processing (a VPC endpoint for S3/ECR would eliminate most of it), and $46 of idle Elastic IPs (pure waste).

### 6.2 Rightsizing recommendations

```bash
$ aws ce get-rightsizing-recommendation \
    --service "AmazonEC2" \
    --configuration '{"RecommendationTarget":"SAME_INSTANCE_FAMILY","BenefitsConsidered":true}' \
    --region us-east-1 \
    --query 'Summary'
```

```json
{
    "TotalRecommendationCount": "47",
    "EstimatedTotalMonthlySavingsAmount": "2841.66",
    "SavingsCurrencyCode": "USD",
    "SavingsPercentage": "18.4"
}
```

```bash
$ aws ce get-rightsizing-recommendation \
    --service "AmazonEC2" \
    --configuration '{"RecommendationTarget":"CROSS_INSTANCE_FAMILY","BenefitsConsidered":true}' \
    --region us-east-1 \
    --query 'RightsizingRecommendations[?RightsizingType==`Modify`] | [:3].{
        Instance: CurrentInstance.ResourceId,
        Current:  CurrentInstance.ResourceDetails.EC2ResourceDetails.InstanceType,
        MaxCpu:   CurrentInstance.ResourceUtilization.EC2ResourceUtilization.MaxCpuUtilizationPercentage,
        MaxMem:   CurrentInstance.ResourceUtilization.EC2ResourceUtilization.MaxMemoryUtilizationPercentage,
        Target:   ModifyRecommendationDetail.TargetInstances[0].ResourceDetails.EC2ResourceDetails.InstanceType,
        Saving:   ModifyRecommendationDetail.TargetInstances[0].EstimatedMonthlySavings
    }' --output table
```

```
------------------------------------------------------------------------------------------
|                        GetRightsizingRecommendation                                    |
+----------+------------+---------+---------+--------------+-------------+---------------+
| Current  | Instance   | MaxCpu  | MaxMem  | Saving       | Target      |               |
+----------+------------+---------+---------+--------------+-------------+---------------+
| m5.4xlarge | i-0a3f8c21b94de7016 | 9.4 | 22.1 | 292.00  | m6i.xlarge  |               |
| r5.2xlarge | i-07c4e1a8f2b30d955 | 6.1 | 18.7 | 186.88  | r6i.large   |               |
| c5.9xlarge | i-0b91d7e3a6c48f220 | 14.8| 31.2 | 612.36  | c6i.2xlarge |               |
+----------+------------+---------+---------+--------------+-------------+---------------+
```

**Diagnostic note:** if `MaxMemoryUtilizationPercentage` comes back `null`, the CloudWatch agent is not publishing memory metrics on those instances. Memory is not a hypervisor-visible metric on EC2 — AWS cannot see it. Recommendations made without it are CPU-only and will under-size memory-bound workloads into OOM kills. Install the CloudWatch agent before trusting a downsize.

```bash
# Compute Optimizer gives a richer signal, including a performance-risk score.
$ aws compute-optimizer get-ec2-instance-recommendations \
    --filters name=Finding,values=Overprovisioned \
    --query 'instanceRecommendations[:2].{
        Id: instanceArn,
        Type: currentInstanceType,
        Finding: finding,
        Reasons: findingReasonCodes,
        Rec: recommendationOptions[0].instanceType,
        Risk: recommendationOptions[0].performanceRisk,
        Savings: recommendationOptions[0].savingsOpportunity.estimatedMonthlySavings.value
    }' --output json
```

```json
[
    {
        "Id": "arn:aws:ec2:us-east-1:111122223333:instance/i-0a3f8c21b94de7016",
        "Type": "m5.4xlarge",
        "Finding": "OVER_PROVISIONED",
        "Reasons": [
            "CPUOverprovisioned",
            "MemoryOverprovisioned",
            "EBSThroughputOverprovisioned"
        ],
        "Rec": "m6i.xlarge",
        "Risk": 1.0,
        "Savings": 292.0
    },
    {
        "Id": "arn:aws:ec2:us-east-1:111122223333:instance/i-0b91d7e3a6c48f220",
        "Type": "c5.9xlarge",
        "Finding": "OVER_PROVISIONED",
        "Reasons": ["CPUOverprovisioned"],
        "Rec": "c6i.2xlarge",
        "Risk": 2.0,
        "Savings": 612.36
    }
]
```

`performanceRisk` runs 0–4. Treat 0–1 as safe to apply, 2 as requiring a load test, 3–4 as do-not-apply-blind.

### 6.3 Savings Plans — recommendation, then verification of utilization

```bash
$ aws ce get-savings-plans-purchase-recommendation \
    --savings-plans-type COMPUTE_SP \
    --term-in-years ONE_YEAR \
    --payment-option NO_UPFRONT \
    --lookback-period-in-days SIXTY_DAYS \
    --region us-east-1 \
    --query 'SavingsPlansPurchaseRecommendation.SavingsPlansPurchaseRecommendationSummary'
```

```json
{
    "EstimatedROI": "23.71",
    "CurrencyCode": "USD",
    "EstimatedTotalCost": "62481.60",
    "CurrentOnDemandSpend": "81953.28",
    "EstimatedSavingsAmount": "19471.68",
    "TotalRecommendationCount": "1",
    "DailyCommitmentToPurchase": "171.18",
    "HourlyCommitmentToPurchase": "7.13",
    "EstimatedSavingsPercentage": "23.76",
    "EstimatedMonthlySavingsAmount": "1622.64",
    "EstimatedOnDemandCostWithCurrentCommitment": "81953.28"
}
```

**Do not buy this yet.** The recommendation is derived from a 60-day lookback of *current* usage — which still contains the 18.4% of rightsizing waste from section 6.2. Rightsize first, wait 14 days for the lookback window to reflect the new baseline, then re-run this command. Committing now would lock in a discount on instances you are about to delete.

Verify existing commitments are actually being consumed:

```bash
$ aws ce get-savings-plans-utilization \
    --time-period Start=2026-08-01,End=2026-09-01 \
    --granularity MONTHLY \
    --region us-east-1 \
    --query 'Total'
```

```json
{
    "Utilization": {
        "TotalCommitment": "5204.90",
        "UsedCommitment": "5204.90",
        "UnusedCommitment": "0.00",
        "UtilizationPercentage": "100"
    },
    "Savings": {
        "NetSavings": "1489.22",
        "OnDemandCostEquivalent": "6694.12"
    },
    "AmortizedCommitment": {
        "AmortizedRecurringCommitment": "5204.90",
        "AmortizedUpfrontCommitment": "0.00",
        "TotalAmortizedCommitment": "5204.90"
    }
}
```

```bash
# Coverage answers the opposite question: how much On-Demand is still uncovered?
$ aws ce get-savings-plans-coverage \
    --time-period Start=2026-08-01,End=2026-09-01 \
    --granularity MONTHLY \
    --region us-east-1 \
    --query 'SavingsPlansCoverages[0].Coverage'
```

```json
{
    "SpendCoveredBySavingsPlans": "6694.12",
    "OnDemandCost": "1876.40",
    "TotalCost": "8570.52",
    "CoveragePercentage": "78.11"
}
```

Utilization 100% + coverage 78% is a healthy position: everything committed is consumed, and 22% remains On-Demand as elasticity headroom. **Utilization below 100% is a direct, ongoing cash leak** — you are paying for a commitment rate you are not consuming. Coverage at 100% is *also* a problem: it means you have committed to your peak, and every scale-down event now wastes commitment.

### 6.4 Budgets and anomalies

```bash
$ aws budgets describe-budgets \
    --account-id 111122223333 \
    --query 'Budgets[].{Name:BudgetName,Type:BudgetType,Limit:BudgetLimit.Amount,
             Actual:CalculatedSpend.ActualSpend.Amount,
             Forecast:CalculatedSpend.ForecastedSpend.Amount}' \
    --output table
```

```
------------------------------------------------------------------------------
|                              DescribeBudgets                               |
+---------------------+--------+----------+------------+---------------------+
|  org-monthly-cost   | COST   |  45000   |  38412.77  |  46903.55           |
|  sandbox-monthly-cost| COST  |  2000    |   1744.02  |   2119.88           |
|  sp-utilization-floor| SAVINGS_PLANS_UTILIZATION | 98 | 100.0 | None      |
|  sp-coverage-floor  | SAVINGS_PLANS_COVERAGE | 70 | 78.11 | None           |
+---------------------+--------+----------+------------+---------------------+
```

The forecast ($46,903) exceeds the limit ($45,000) while the actual is still under. **This is the alert that has value** — it fires with roughly ten days of runway to act, whereas the actual-100% alert fires when the money is already spent.

```bash
$ aws ce get-anomalies \
    --date-interval StartDate=2026-08-01,EndDate=2026-09-01 \
    --total-impact NumericOperator=GREATER_THAN_OR_EQUAL,StartValue=200 \
    --region us-east-1 \
    --query 'Anomalies[].{Start:AnomalyStartDate,End:AnomalyEndDate,
             Service:RootCauses[0].Service,Region:RootCauses[0].Region,
             UsageType:RootCauses[0].UsageType,
             Impact:Impact.TotalImpact,Expected:Impact.TotalExpectedSpend,
             Actual:Impact.TotalActualSpend}' --output json
```

```json
[
    {
        "Start": "2026-08-17T00:00:00Z",
        "End": "2026-08-19T00:00:00Z",
        "Service": "Amazon Elastic Compute Cloud - Compute",
        "Region": "eu-west-1",
        "UsageType": "EUW1-BoxUsage:p4d.24xlarge",
        "Impact": 4218.72,
        "Expected": 91.28,
        "Actual": 4310.0
    },
    {
        "Start": "2026-08-24T00:00:00Z",
        "End": "2026-08-26T00:00:00Z",
        "Service": "AWS Data Transfer",
        "Region": "us-east-1",
        "UsageType": "USE1-USW2-AWS-Out-Bytes",
        "Impact": 612.4,
        "Expected": 148.9,
        "Actual": 761.3
    }
]
```

The first anomaly is the classic: GPU instances launched in a region nobody monitors, then left running over a weekend. Region `eu-west-1` and expected spend of $91 tell you this account has essentially no legitimate footprint there. A static monthly budget would never have caught it — $4,218 is inside the noise of a $45,000 budget.

### 6.5 Finding waste that no recommendation engine reports

```bash
# Unattached EBS volumes - billed at full rate, attached to nothing.
$ aws ec2 describe-volumes \
    --filters Name=status,Values=available \
    --query 'Volumes[].{Id:VolumeId,Size:Size,Type:VolumeType,
             Created:CreateTime,AZ:AvailabilityZone,
             Name:Tags[?Key==`Name`]|[0].Value}' \
    --output table
```

```
-------------------------------------------------------------------------------------
|                                 DescribeVolumes                                   |
+------------+-------+--------+---------------------------+-------------+-----------+
|  vol-0c8d21e9f4a7b3306 | 500 | gp3 | 2025-11-04T09:12:44+00:00 | us-east-1a | old-etl-scratch |
|  vol-04f1a76bc90e5d283 | 200 | gp2 | 2026-02-18T14:03:09+00:00 | us-east-1b | None            |
|  vol-0e5b3d8912af6c740 |1000 | io1 | 2025-08-27T22:41:55+00:00 | us-east-1c | db-restore-test |
+------------+-------+--------+---------------------------+-------------+-----------+
```

1,700 GB of orphaned storage, one of it Provisioned IOPS. At gp3/io1 rates that is several hundred dollars a month for zero delivered value, and it has been accruing since 2025.

```bash
# Idle Elastic IPs: charged per hour when NOT associated.
$ aws ec2 describe-addresses \
    --query 'Addresses[?AssociationId==`null`].[PublicIp,AllocationId,Domain]' \
    --output text
```

```
52.203.118.44   eipalloc-0f39c72e18a4b6d05   vpc
3.221.86.190    eipalloc-0a7d51fc3e920b8c1   vpc
54.163.201.77   eipalloc-0c14e8b92df370a66   vpc
```

```bash
# Load balancers with zero registered healthy targets.
$ for tg in $(aws elbv2 describe-target-groups --query 'TargetGroups[].TargetGroupArn' --output text); do
    n=$(aws elbv2 describe-target-health --target-group-arn "$tg" \
          --query 'length(TargetHealthDescriptions[?TargetHealth.State==`healthy`])' --output text)
    [ "$n" = "0" ] && echo "EMPTY  $tg"
  done
```

```
EMPTY  arn:aws:elasticloadbalancing:us-east-1:111122223333:targetgroup/legacy-api-tg/8f2c91a04b7e6d33
EMPTY  arn:aws:elasticloadbalancing:us-east-1:111122223333:targetgroup/blue-deploy-tg/1a6b39e5c2d84f70
```

```bash
# Snapshots older than a year with no lifecycle policy governing them.
$ aws ec2 describe-snapshots --owner-ids self \
    --query "Snapshots[?StartTime<='2025-09-03'].[SnapshotId,VolumeSize,StartTime,Description]" \
    --output text | head -5
```

```
snap-0a91c7e34b8d2f605  500  2025-03-14T06:00:12+00:00  Created by CreateImage(i-0b3e...)
snap-04d82f16ac9b7e310  200  2025-01-08T06:00:07+00:00  daily-backup-legacy-etl
snap-0e73b95d2c18af446  1000 2024-12-19T06:00:11+00:00  pre-migration-snapshot
snap-0f2a4c86e91b573d8  120  2025-05-02T06:00:09+00:00  ad-hoc before schema change
```

### 6.6 Price List API — deriving unit prices instead of remembering them

Never hardcode a price from memory. Query it.

```bash
$ aws pricing get-products \
    --service-code AmazonEC2 \
    --region us-east-1 \
    --filters \
      Type=TERM_MATCH,Field=instanceType,Value=m6i.large \
      Type=TERM_MATCH,Field=location,Value="US East (N. Virginia)" \
      Type=TERM_MATCH,Field=operatingSystem,Value=Linux \
      Type=TERM_MATCH,Field=tenancy,Value=Shared \
      Type=TERM_MATCH,Field=preInstalledSw,Value=NA \
      Type=TERM_MATCH,Field=capacitystatus,Value=Used \
    --query 'PriceList[0]' --output text | \
  python3 -c "import json,sys; d=json.load(sys.stdin); \
    od=d['terms']['OnDemand']; t=list(od.values())[0]; \
    p=list(t['priceDimensions'].values())[0]; \
    print(p['unit'], p['pricePerUnit']['USD'], '|', p['description'])"
```

```
Hrs 0.0960000000 | $0.096 per On Demand Linux m6i.large Instance Hour
```

```bash
# The same instance with Windows License Included - the licensing delta,
# measured rather than assumed.
$ aws pricing get-products \
    --service-code AmazonEC2 --region us-east-1 \
    --filters \
      Type=TERM_MATCH,Field=instanceType,Value=m6i.large \
      Type=TERM_MATCH,Field=location,Value="US East (N. Virginia)" \
      Type=TERM_MATCH,Field=operatingSystem,Value=Windows \
      Type=TERM_MATCH,Field=tenancy,Value=Shared \
      Type=TERM_MATCH,Field=preInstalledSw,Value=NA \
      Type=TERM_MATCH,Field=licenseModel,Value="License Included" \
      Type=TERM_MATCH,Field=capacitystatus,Value=Used \
    --query 'PriceList[0]' --output text | \
  python3 -c "import json,sys; d=json.load(sys.stdin); \
    t=list(d['terms']['OnDemand'].values())[0]; \
    p=list(t['priceDimensions'].values())[0]; \
    print(p['pricePerUnit']['USD'])"
```

```
0.1880000000
```

$0.188 vs $0.096 — the Windows license is $0.092/hr, **96% of the instance price**, or ~$806/year per instance. On a 200-instance Windows estate that is $161,000/year in License Included fees. That single number is what makes a BYOL-on-Dedicated-Hosts analysis worth doing, and it is derivable in one API call.

### 6.7 License Manager — proving compliance rather than hoping

```bash
$ aws license-manager list-license-configurations \
    --query 'LicenseConfigurations[].{Name:Name,Type:LicenseCountingType,
             Limit:LicenseCount,Consumed:ConsumedLicenses,
             Enforce:LicenseCountHardLimit,Status:Status}' --output table
```

```
--------------------------------------------------------------------------
|                     ListLicenseConfigurations                          |
+-------------------------+--------+-------+----------+--------+---------+
|  SQL-Server-EE-Core     | Core   |  64   |    48    | True   | AVAILABLE |
|  Oracle-DB-EE-Socket    | Socket |  8    |     8    | True   | AVAILABLE |
|  WindowsServer-DC-Core  | Core   | 256   |   214    | False  | AVAILABLE |
+-------------------------+--------+-------+----------+--------+---------+
```

`Oracle-DB-EE-Socket` is at 8 of 8 with a hard limit. The next launch that would consume a socket will be **rejected at the API level** — which is the correct behavior, and infinitely cheaper than discovering the over-deployment during a vendor audit.

```bash
$ aws license-manager list-usage-for-license-configuration \
    --license-configuration-arn arn:aws:license-manager:us-east-1:111122223333:license-configuration:lic-4a91c7e3 \
    --query 'LicenseConfigurationUsageList[].{Resource:ResourceArn,
             Type:ResourceType,Owner:ResourceOwnerId,Consumed:ConsumedLicenses}' \
    --output text
```

```
i-0b3e7c1948da2f560  EC2_HOST      111122223333  4
i-0a91f4c72e6b83d05  EC2_HOST      111122223333  4
```

### 6.8 Consolidated billing — verifying volume discounts actually aggregate

```bash
$ aws organizations describe-organization \
    --query 'Organization.{Id:Id,FeatureSet:FeatureSet,MasterAccount:MasterAccountId}'
```

```json
{
    "Id": "o-x8k2p9q3z1",
    "FeatureSet": "ALL",
    "MasterAccount": "111122223333"
}
```

```bash
$ aws organizations list-accounts \
    --query 'length(Accounts[?Status==`ACTIVE`])' --output text
```

```
23
```

**Why this matters economically:** with consolidated billing, the usage of all 23 accounts is aggregated *before* volume tiers are applied. Twenty-three accounts each storing 2 TB in S3 are billed as one 46 TB estate, not as 23 separate 2 TB estates — and the same aggregation lets one account's unused Savings Plan or RI benefit apply automatically to another account's matching usage. `FeatureSet: ALL` (not `CONSOLIDATED_BILLING`) is also the prerequisite for SCPs and tag policies from section 5.3.

---

## 7. Verification and Failure Diagnosis

### 7.1 Pre-deployment validation

```bash
$ aws cloudformation validate-template \
    --template-body file://finops-foundation.yaml \
    --query '{Description:Description,Params:Parameters[].ParameterKey}'
```

```json
{
    "Description": "FinOps data foundation. Creates the S3 destination and bucket policy for a Data Exports (CUR 2.0) delivery, plus a Cost Category that maps linked accounts and tags into business dimensions. Deploy in the Organizations management account in us-east-1.",
    "Params": ["ExportBucketName", "ExportName", "RetentionDays"]
}
```

```bash
$ cfn-lint finops-foundation.yaml budgets-and-anomaly.yaml
$ terraform validate && terraform plan -out=finops.tfplan
$ kubectl apply --dry-run=server -f karpenter-nodepools.yaml
```

```
ec2nodeclass.karpenter.k8s.aws/cost-optimized created (server dry run)
nodepool.karpenter.sh/spot-general created (server dry run)
nodepool.karpenter.sh/ondemand-critical created (server dry run)
resourcequota/payments-quota created (server dry run)
limitrange/payments-defaults created (server dry run)
verticalpodautoscaler.autoscaling.k8s.io/payments-api-vpa created (server dry run)
```

### 7.2 Post-deployment verification checklist

```bash
# 1. Is the CUR export actually defined and delivering?
$ aws bcm-data-exports list-exports --region us-east-1 \
    --query 'Exports[].{Name:ExportName,Status:ExportStatus.StatusCode,
             LastRefresh:ExportStatus.LastRefreshedAt}' --output table
```

```
--------------------------------------------------------------
|                        ListExports                         |
+------------------------+---------+-------------------------+
|  cur2-hourly-resources | HEALTHY | 2026-09-03T06:14:22Z    |
+------------------------+---------+-------------------------+
```

```bash
# 2. Are objects landing in S3? An export that is HEALTHY but has
#    delivered nothing means the bucket policy is wrong.
$ aws s3 ls s3://acme-finops-cur/cur2/cur2-hourly-resources/ --recursive \
    --human-readable --summarize | tail -4
```

```
2026-09-03 06:15:41   48.2 MiB cur2/cur2-hourly-resources/data/BILLING_PERIOD=2026-09/cur2-hourly-resources-00001.snappy.parquet

Total Objects: 214
   Total Size: 9.6 GiB
```

```bash
# 3. Are the cost allocation tags ACTIVE? Defining a tag is not enough -
#    it must be explicitly activated in the billing console or via API,
#    and activation is NOT retroactive.
$ aws ce list-cost-allocation-tags --status Active --region us-east-1 \
    --query 'CostAllocationTags[].{Key:TagKey,Type:Type,Status:Status}' --output table
```

```
------------------------------------------------
|          ListCostAllocationTags              |
+---------------+-------------------+----------+
|  CostCenter   |  UserDefined      |  Active  |
|  Environment  |  UserDefined      |  Active  |
|  Owner        |  UserDefined      |  Active  |
|  Application  |  UserDefined      |  Active  |
|  aws:createdBy|  AWSGenerated     |  Active  |
+---------------+-------------------+----------+
```

```bash
# 4. Is anomaly detection subscribed and armed?
$ aws ce get-anomaly-monitors --region us-east-1 \
    --query 'AnomalyMonitors[].{Name:MonitorName,Type:MonitorType,
             Dim:MonitorDimension,Eval:LastEvaluatedDate}' --output table
```

```
-----------------------------------------------------------------------
|                        GetAnomalyMonitors                           |
+------------------------+-------------+---------+--------------------+
|  all-services-monitor  | DIMENSIONAL | SERVICE | 2026-09-03T04:00:00Z |
|  business-unit-monitor | CUSTOM      | None    | 2026-09-03T04:00:00Z |
+------------------------+-------------+---------+--------------------+
```

```bash
# 5. Is Karpenter consolidating, or just provisioning?
$ kubectl get nodeclaims -o custom-columns=\
NAME:.metadata.name,TYPE:.metadata.labels.node\\.kubernetes\\.io/instance-type,\
CAPACITY:.metadata.labels.karpenter\\.sh/capacity-type,READY:.status.conditions[?\(@.type==\"Ready\"\)].status
```

```
NAME                    TYPE          CAPACITY    READY
spot-general-4kd2n      c6g.2xlarge   spot        True
spot-general-9mxq7      m6i.xlarge    spot        True
ondemand-critical-r7bv  m6i.large     on-demand   True
```

```bash
$ kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter --tail=200 \
    | grep -i consolidat | tail -3
```

```
{"level":"INFO","time":"2026-09-03T11:42:08.114Z","logger":"controller","message":"disrupting nodeclaim(s) via replace, terminating 2 nodes (11 pods) spot-general-x8t4p/m6i.2xlarge/spot, spot-general-q2wn9/m6i.xlarge/spot and replacing with spot node from types c6g.2xlarge, m6g.2xlarge, m7g.2xlarge","commit":"a1b2c3d","reason":"underutilized"}
{"level":"INFO","time":"2026-09-03T11:47:31.902Z","logger":"controller","message":"deleted nodeclaim","commit":"a1b2c3d","NodeClaim":{"name":"spot-general-x8t4p"}}
```

Two nodes replaced by one cheaper Graviton node. That log line **is** the cost optimization, observable in real time.

### 7.3 Failure diagnosis matrix

| Symptom | Probe | Root cause | Fix |
|---|---|---|---|
| Cost allocation tag column is empty in Cost Explorer / CUR | `aws ce list-cost-allocation-tags --status Inactive` | Tag exists on resources but was never **activated** for billing | Activate it. **Activation is not retroactive** — historical data stays unattributed forever. Use a Cost Category on `LINKED_ACCOUNT` to attribute the past. |
| Tag activated, still empty for 24–48 h | Check `LastUpdatedDate` on the tag | Normal propagation delay | Wait. Billing data is not real-time; Cost Explorer lags ~24 h. |
| CUR export status `HEALTHY` but S3 prefix is empty | `aws s3api get-bucket-policy --bucket <b>` | Bucket policy missing the `billingreports.amazonaws.com` / `bcm-data-exports.amazonaws.com` statements, or the `aws:SourceAccount` condition rejects the call | Reapply the policy from §5.1. Recheck after the next refresh cycle. |
| CUR export fails silently after enabling SSE-KMS | CloudTrail `PutObject` events for the service principal | Service principal lacks `kms:GenerateDataKey` on the CMK | Add the principal to the key policy, or use SSE-S3 (`AES256`). |
| Budget shows $0.00 spend forever | `aws budgets describe-budget --budget-name X --query 'Budget.CostFilters'` | `CostFilters` references a tag key/value that matches nothing — typo, wrong case, or tag not activated | Filter syntax is `user:<Key>$<Value>` and is **case-sensitive**. Verify against `list-cost-allocation-tags`. |
| `FORECASTED` budget notifications never fire | `CalculatedSpend.ForecastedSpend` is absent | Budgets needs roughly **5 weeks** of usage history to forecast | Wait, or rely on `ACTUAL` thresholds meanwhile. |
| Cost Anomaly Detection reports nothing on a new account | `get-anomaly-monitors` → `LastEvaluatedDate` | The model needs about **10 days** of history to establish a baseline | Wait. Do not lower the impact threshold to force alerts — you will get noise, not signal. |
| Compute Optimizer returns `finding: NOT_OPTIMIZED` with no options | `get-enrollment-status` | Account not enrolled, or fewer than **14 days** of CloudWatch metrics | `aws compute-optimizer update-enrollment-status --status Active`, then wait for the metric window to fill. |
| Rightsizing recommendations ignore memory (`MaxMemoryUtilizationPercentage: null`) | `aws cloudwatch list-metrics --namespace CWAgent` | Memory is a guest-OS metric; the hypervisor cannot see it | Install and configure the CloudWatch agent. Until then, treat every downsize as CPU-only and OOM-risky. |
| Savings Plan utilization drops below 100% after a deploy | `get-savings-plans-utilization --granularity DAILY` | Workload shrank, moved region, or migrated to a service the SP does not cover (e.g. Compute SP does not cover RDS) | Increase covered usage or accept the loss until term end. Savings Plans **cannot be cancelled or resold.** |
| Bill rose but Cost Explorer's "EC2" line is flat | Group by `USAGE_TYPE` within `EC2 - Other` | EBS growth, snapshot sprawl, or NAT Gateway data processing | §6.1/§6.5. Add S3/ECR VPC endpoints; apply snapshot lifecycle policies. |
| Unblended and amortized totals disagree by thousands | Compare `UnblendedCost` vs `AmortizedCost` in the same query | Correct and expected — an upfront SP/RI fee lands entirely in one month unblended, but is spread across the term amortized | Report amortized to finance, unblended for cash-flow. Never mix them in one chart. |
| Linked account's bill shows blended costs it does not recognize | `UseBlended: true` in the budget's `CostTypes` | Blended rates are an averaging artifact of consolidated billing | Use **unblended** for accountability, **amortized** for commitment-aware reporting. Blended is almost never the right choice. |
| Spend looks fine, then spikes when credits expire | `aws ce get-cost-and-usage --metrics NetUnblendedCost` and compare to `UnblendedCost` | Promotional credits were masking real consumption | Set `IncludeCredit: false` on budgets (as in §5.2) so alerts track real consumption, not credited consumption. |
| SCP from §5.3 breaks a legitimate CI pipeline | CloudTrail `errorCode: AccessDenied` with `RunInstances` | Pipeline role does not pass the required tags | Fix the pipeline to tag at creation. Do **not** exempt the role — the exemption becomes permanent and the attribution gap becomes structural. |
| Karpenter never consolidates | `kubectl logs -n karpenter ... \| grep -i "cannot disrupt"` | A PDB blocks eviction, a pod has `karpenter.sh/do-not-disrupt: "true"`, or a bare (non-controller-owned) pod pins the node | Fix the PDB, remove the annotation, or move the bare pod under a controller. |
| ResourceQuota rejects deploys with `must specify requests.cpu` | `kubectl describe quota -n <ns>` | The namespace has a CPU quota but pods declare no requests | The `LimitRange` in §5.5 supplies defaults. Apply it before the quota. |
| BYOL Windows instances refuse to launch on shared tenancy | Instance launch error / License Manager rule | Microsoft licensing terms require a Dedicated Host for licenses acquired on/after 2019-10-01 without Software Assurance | Move to Dedicated Hosts, verify License Mobility eligibility with the vendor, or switch to License Included. |
| License Manager blocks a launch at the entitlement limit | `list-license-configurations` → `ConsumedLicenses == LicenseCount` | Hard limit reached — working as designed | Reclaim entitlements from decommissioned hosts, or purchase more. Do **not** flip `LicenseCountHardLimit` to `false` to unblock a deploy; that converts a controlled failure into an audit liability. |

### 7.4 The FinOps operating loop as an SRE runbook

The FinOps Foundation defines three iterative phases; map them onto practices you already run.

| Phase | Question | Artifacts from this document | SRE analogue |
|---|---|---|---|
| **Inform** | Where does the money go, and who owns it? | CUR 2.0 export (§5.1), Cost Categories (§5.1), tag governance (§5.3), Athena queries (§5.6) | Instrumentation and tracing |
| **Optimize** | What should change? | Rightsizing (§6.2), scheduling (§5.4), Karpenter consolidation (§5.5), commitments (§6.3) | Performance tuning and capacity planning |
| **Operate** | How do we keep it from regressing? | Budgets + budget actions (§5.2), anomaly detection (§5.2), SCPs (§5.3), tag-coverage SLI (§5.6) | SLOs, alerting, error budgets |

**Treat tag coverage and Savings Plan utilization as SLIs with SLOs.** Tag coverage ≥ 95%, SP utilization ≥ 99%, SP coverage in the 70–85% band. Alert on the SLO, not on the dollar figure — the dollar figure grows legitimately when the business grows, but the efficiency ratios should not degrade.

---

## 8. Exam-Relevant Distinctions

These are the discriminations CLF-C02 questions are built on. Each pair is genuinely different, and choosing the wrong one is the intended trap.

| Confusion | The distinction |
|---|---|
| **CAPEX vs OPEX** | *When* and *how* the money is recorded. Cloud shifts capital purchase to operating expense. |
| **Fixed vs variable** | *Whether* the cost scales with usage. A 3-year RI in the cloud is still a fixed cost. |
| **AWS Pricing Calculator vs Cost Explorer** | Calculator = **estimate future** cost of an architecture you have not built. Cost Explorer = **analyze past/current** actual spend. |
| **AWS Budgets vs Cost Anomaly Detection** | Budgets = **you** define a static threshold. Anomaly Detection = **ML** learns your pattern and flags deviations. Use both. |
| **Cost Explorer vs the CUR** | Cost Explorer = curated UI/API, ~13 months of history, fast. CUR = the raw, complete, hourly, resource-level dataset for arbitrary analysis. |
| **Cost allocation tags vs Cost Categories** | Tags live on the resource, must be activated, are not retroactive. Cost Categories are billing-side rules over accounts/tags/services, and **do** apply retroactively. |
| **Savings Plans vs Reserved Instances** | SP commits to **$/hour of spend** (flexible across family, size, region, OS, and covers Fargate and Lambda). RI commits to **specific instance attributes** (and can be sold on the Marketplace). |
| **Standard vs Convertible RI** | Standard: bigger discount, sellable, cannot change instance family. Convertible: smaller discount, not sellable, can be exchanged for a different family. |
| **Unblended / blended / amortized / net** | Unblended = what the account actually incurred. Blended = averaged rate across the organization. Amortized = upfront commitments spread across their term. Net = after discounts and credits. |
| **Consolidated billing benefits** | One bill, volume-tier aggregation across all accounts, and automatic sharing of RI/SP benefit across accounts. |
| **Trusted Advisor vs Compute Optimizer** | Trusted Advisor: five-pillar checks including cost (idle resources, low utilization). Compute Optimizer: ML-driven, instance-specific rightsizing recommendations with a performance-risk score. |
| **Migration Evaluator vs Pricing Calculator** | Migration Evaluator: discovers your existing on-premises estate and builds the TCO business case. Pricing Calculator: you model an AWS architecture by hand. |
| **BYOL vs License Included** | BYOL: you own the license (fixed cost, your compliance risk, often needs Dedicated Hosts). License Included: bundled into the hourly rate (variable cost, AWS's compliance burden). |
| **Dedicated Instance vs Dedicated Host** | Dedicated Instance: isolated hardware, but no visibility of the physical socket/core. Dedicated Host: you see and control the physical server, which is what core-based licensing and instance-to-host affinity require. |
| **AWS Support tier as a cost line** | Support is a percentage of monthly usage with tiered rates and a monthly minimum. It is a real, forecastable, sometimes surprising line item. |

---

## 9. References

**Exam guide**
- AWS Certified Cloud Practitioner (CLF-C02) Exam Guide — https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf
- AWS Certified Cloud Practitioner certification page — https://aws.amazon.com/certification/certified-cloud-practitioner/

**Cloud economics and pricing fundamentals**
- How AWS Pricing Works (whitepaper) — https://docs.aws.amazon.com/whitepapers/latest/how-aws-pricing-works/welcome.html
- AWS Cloud Economics Center — https://aws.amazon.com/economics/
- AWS Well-Architected Framework — Cost Optimization Pillar — https://docs.aws.amazon.com/wellarchitected/latest/cost-optimization-pillar/welcome.html
- AWS Pricing Calculator User Guide — https://docs.aws.amazon.com/pricing-calculator/latest/userguide/what-is-pricing-calculator.html
- AWS Pricing Calculator — https://calculator.aws/
- AWS Migration Evaluator — https://aws.amazon.com/migration-evaluator/

**Billing, cost management, and reporting**
- AWS Billing and Cost Management User Guide — https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/billing-what-is.html
- AWS Cost Management User Guide — https://docs.aws.amazon.com/cost-management/latest/userguide/what-is-costmanagement.html
- Consolidated billing for AWS Organizations — https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/consolidated-billing.html
- Using cost allocation tags — https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/cost-alloc-tags.html
- AWS Cost Categories — https://docs.aws.amazon.com/cost-management/latest/userguide/manage-cost-categories.html
- AWS Cost and Usage Reports User Guide — https://docs.aws.amazon.com/cur/latest/userguide/what-is-cur.html
- Creating a Data Export (CUR 2.0) — https://docs.aws.amazon.com/cur/latest/userguide/dataexports-create-standard.html
- CUR 2.0 data dictionary — https://docs.aws.amazon.com/cur/latest/userguide/dataexports-table-dictionary.html
- Understanding your AWS Cost Datasets: A Cheat Sheet (unblended / blended / amortized / net) — https://aws.amazon.com/blogs/aws-cloud-financial-management/understanding-your-aws-cost-datasets-a-cheat-sheet/
- AWS Budgets — https://docs.aws.amazon.com/cost-management/latest/userguide/budgets-managing-costs.html
- Configuring AWS Budgets actions — https://docs.aws.amazon.com/cost-management/latest/userguide/budgets-controls.html
- AWS Cost Anomaly Detection — https://docs.aws.amazon.com/cost-management/latest/userguide/manage-ad.html
- AWS Cost Management API Reference — https://docs.aws.amazon.com/aws-cost-management/latest/APIReference/Welcome.html

**Purchase options and optimization**
- AWS Savings Plans User Guide — https://docs.aws.amazon.com/savingsplans/latest/userguide/what-is-savings-plans.html
- Amazon EC2 Reserved Instances — https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-reserved-instances.html
- Amazon EC2 Spot Instances — https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/using-spot-instances.html
- Amazon EC2 pricing — https://aws.amazon.com/ec2/pricing/
- AWS Compute Optimizer User Guide — https://docs.aws.amazon.com/compute-optimizer/latest/ug/what-is-compute-optimizer.html
- AWS Trusted Advisor — https://docs.aws.amazon.com/awssupport/latest/user/trusted-advisor.html
- AWS Price List API — https://docs.aws.amazon.com/aws-cost-management/latest/APIReference/API_Operations_AWS_Price_List_Service.html

**Licensing**
- AWS License Manager User Guide — https://docs.aws.amazon.com/license-manager/latest/userguide/license-manager.html
- Amazon EC2 Dedicated Hosts — https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/dedicated-hosts-overview.html
- Amazon EC2 Dedicated Instances — https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/dedicated-instance.html
- Microsoft licensing on AWS — https://aws.amazon.com/windows/resources/licensing/
- AWS Optimization and Licensing Assessment (OLA) — https://aws.amazon.com/optimization-and-licensing-assessment/

**Governance and automation**
- AWS Organizations tag policies — https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_tag-policies.html
- AWS Organizations service control policies — https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_scps.html
- `AWS::Budgets::Budget` CloudFormation reference — https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-resource-budgets-budget.html
- `AWS::CE::AnomalyMonitor` CloudFormation reference — https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-resource-ce-anomalymonitor.html
- `AWS::CE::CostCategory` CloudFormation reference — https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-resource-ce-costcategory.html
- `AWS::BCMDataExports::Export` CloudFormation reference — https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-resource-bcmdataexports-export.html
- Amazon EventBridge Scheduler User Guide — https://docs.aws.amazon.com/scheduler/latest/UserGuide/what-is-scheduler.html
- AWS Config managed rule `required-tags` — https://docs.aws.amazon.com/config/latest/developerguide/required-tags.html

**Kubernetes cost engineering**
- Karpenter NodePools — https://karpenter.sh/docs/concepts/nodepools/
- Karpenter disruption and consolidation — https://karpenter.sh/docs/concepts/disruption/
- Amazon EKS best practices — cost optimization — https://docs.aws.amazon.com/eks/latest/best-practices/cost-opt.html
- OpenCost documentation — https://opencost.io/docs/

**Practice frameworks**
- FinOps Foundation Framework — https://www.finops.org/framework/
- AWS Cloud Financial Management blog — https://aws.amazon.com/blogs/aws-cloud-financial-management/