# 4.3 — Identify AWS technical resources and AWS Support options

**Certification:** AWS Certified Cloud Practitioner (CLF-C02) · **Domain 4:** Billing, Pricing and Support · **Task 4.3** · Exam weight: 4.0

> Account IDs, case IDs, ARNs and event IDs in the terminal transcripts below are synthetic. Command shapes, field names, error codes and API semantics are real and reproducible against a live account.

---

## 1. The production problem: support is a control plane, not a phone number

The way this task statement is usually taught — "memorise the five support plans" — misses what it actually decides in production. Three concrete architectural consequences hang off the support plan you buy, and none of them are recoverable at 03:00:

**1. Programmatic access to your own failure data.** The AWS Health API (`DescribeEvents`, `DescribeAffectedEntities`) and the AWS Support API (`CreateCase`, `DescribeCases`) are **gated behind Business Support or above**. If your incident-response automation calls `health:DescribeEvents` to correlate a latency spike with an AZ-level issue, that code path does not exist on a Developer plan — it raises `SubscriptionRequiredException`. You cannot write the runbook first and buy the plan later; the runbook will not run.

**2. Time-to-human is a component of your MTTR budget.** If you publish a 99.95% monthly availability SLO, you have **21.6 minutes** of error budget per month. Enterprise Support's 15-minute business-critical response target consumes 69% of that budget before an AWS engineer types a word. Business Support's 1-hour "production system down" target consumes **278%** of it — meaning for any incident whose resolution genuinely requires AWS, a 99.95% SLO is not defensible on Business Support. This is a design constraint, not a procurement preference.

**3. Quota exhaustion is the most common self-inflicted outage, and quotas are a support artifact.** A regional failover that tries to launch 400 vCPU into a region provisioned for 64 will fail with `VcpuLimitExceeded`, and the remedy — a quota increase — is a *support ticket* with a human-scale latency. Trusted Advisor's Service Limits check and Service Quotas' CloudWatch integration are the only ways to find this out *before* the failover.

The rest of this document treats AWS Support as what it is for a platform team: a set of APIs, event sources and SLAs you wire into your operational plane, with a cost model you can compute.

---

## 2. Taxonomy of the AWS resource surface

Four tiers, distinguished by cost, latency and whether a human is accountable.

| Tier | Examples | Cost | Latency | Accountability |
|---|---|---|---|---|
| **Self-service (free)** | Documentation, Whitepapers, Architecture Center, Prescriptive Guidance, Solutions Library, Well-Architected Tool, Security Bulletins, Skill Builder (free tier) | $0 | Immediate | None |
| **Community (free)** | AWS re:Post, re:Post Knowledge Center, AWS Blogs, AWS Open Source | $0 | Hours–days, best-effort | None |
| **AWS Support (subscription)** | Support cases, Trusted Advisor, Support API, TAM, Concierge, Countdown, IDR | Plan-dependent | Contractual response *target* | AWS |
| **Professional / Partner (per-engagement)** | AWS Professional Services, AWS Managed Services (AMS), AWS Partner Network, AWS IQ, AWS Marketplace | Statement of work | Contractual | AWS or Partner |

The critical exam-and-production distinction: **AWS Support response times are targets for a *first response*, not resolution SLAs, and they are not backed by service credits.** Only individual service SLAs (EC2, S3, RDS…) carry credits, and those are claimed through a support case — which is itself only openable on Developer and above.

---

## 3. AWS Support plans — the full comparison

### 3.1 Capability matrix

| Capability | Basic | Developer | Business | Enterprise On-Ramp | Enterprise |
|---|---|---|---|---|---|
| Documentation, whitepapers, re:Post | ✅ | ✅ | ✅ | ✅ | ✅ |
| AWS Health Dashboard — *Service health* (public) | ✅ | ✅ | ✅ | ✅ | ✅ |
| AWS Health Dashboard — *Your account health* | ✅ | ✅ | ✅ | ✅ | ✅ |
| **AWS Health API** (`DescribeEvents`, org view) | ❌ | ❌ | ✅ | ✅ | ✅ |
| Trusted Advisor — **core checks only** | ✅ | ✅ | — | — | — |
| Trusted Advisor — **full check set** (6 categories) | ❌ | ❌ | ✅ | ✅ | ✅ |
| **Trusted Advisor API** (`trustedadvisor:*`) | ❌ | ❌ | ✅ | ✅ | ✅ |
| **Trusted Advisor Priority** (TAM-curated) | ❌ | ❌ | ❌ | ❌ | ✅ |
| Customer service (billing/account), 24×7 | ✅ | ✅ | ✅ | ✅ | ✅ |
| **Technical support cases** | ❌ | ✅ (email, business hours) | ✅ (24×7 email/chat/phone) | ✅ | ✅ |
| **AWS Support API** (`support:CreateCase`) | ❌ | ❌ | ✅ | ✅ | ✅ |
| AWS Support App in Slack / Microsoft Teams | ❌ | ❌ | ✅ | ✅ | ✅ |
| Contacts who may open cases | — | **1** | Unlimited (IAM-controlled) | Unlimited | Unlimited |
| Third-party software support (OS, stacks) | ❌ | ❌ | ✅ | ✅ | ✅ |
| `AWSPremiumSupport-*` SSM automation runbooks | ❌ | ❌ | ✅ | ✅ | ✅ |
| **Technical Account Manager (TAM)** | ❌ | ❌ | ❌ | **Pool of TAMs** | **Designated TAM** |
| **Concierge** support team (billing experts) | ❌ | ❌ | ❌ | ✅ | ✅ |
| Well-Architected Framework Reviews (guided) | ❌ | ❌ | ❌ | ✅ (consultative) | ✅ (proactive, ongoing) |
| Operations reviews, game days, training credits | ❌ | ❌ | ❌ | Limited | ✅ |
| **AWS Countdown** (ex Infrastructure Event Mgmt) | ❌ | ❌ | Purchasable | ✅ | ✅ |
| **AWS Incident Detection and Response** (add-on) | ❌ | ❌ | ❌ | ❌ | ✅ (paid add-on) |
| AWS re:Post Private | ❌ | ❌ | ❌ | ✅ | ✅ |

**Basic Trusted Advisor core checks** (the set every account gets for free) are the ones that map to security posture and capacity:

| Check | ID | Category |
|---|---|---|
| Service Limits | `eW7HH0l7J9` | Service Limits |
| Security Groups – Specific Ports Unrestricted | `HCP4007jGY` | Security |
| IAM Use | `zXCkfM1nI3` | Security |
| MFA on Root Account | `7DAFEmoDos` | Security |
| Amazon S3 Bucket Permissions | `Pfx0RwqBli` | Security |
| Amazon EBS Public Snapshots | `ePs02jT06w` | Security |
| Amazon RDS Public Snapshots | `rSs93HQwa1` | Security |

Never hard-code these IDs from a document — enumerate them with `describe-trusted-advisor-checks` (§10.3). They are stable, but the *set available to you* is a function of your plan.

### 3.2 Response-time targets by severity

The Support API exposes severities as opaque codes; these are the values you pass to `--severity-code`.

| API code | Console name | Developer | Business | Enterprise On-Ramp | Enterprise |
|---|---|---|---|---|---|
| `low` | General guidance | < 24 **business** hours | < 24 h | < 24 h | < 24 h |
| `normal` | System impaired | < 12 **business** hours | < 12 h | < 12 h | < 12 h |
| `high` | Production system impaired | ❌ not available | < 4 h | < 4 h | < 4 h |
| `urgent` | Production system down | ❌ not available | < 1 h | < 1 h | < 1 h |
| `critical` | Business-critical system down | ❌ not available | ❌ not available | **< 30 min** | **< 15 min** |

Two traps that bite in production:

- **"Business hours" on Developer means the calendar of the customer's country, 08:00–18:00 local, weekdays.** A Saturday `normal`-severity case on Developer has no meaningful response target until Monday. Any team carrying a weekend on-call rotation on Developer Support is carrying it alone.
- **`critical` is the only severity that is plan-gated on the *write* path.** Attempting it on Business does not silently downgrade; `describe-severity-levels` simply will not list it, and `create-case` rejects it. Your automation must discover the severity set at runtime, not assume it.

### 3.3 The cost model, and the non-obvious crossover

Pricing is *the greater of* a monthly minimum or a percentage of monthly AWS usage charges. Business and Enterprise use **tiered marginal** percentages; Enterprise On-Ramp uses a **flat** 10%.

| Plan | Monthly minimum | Percentage of monthly AWS charges |
|---|---|---|
| Basic | $0 | — |
| Developer | $29 | 3% (flat) |
| Business | $100 | 10% of $0–10K · 7% of $10K–80K · 5% of $80K–250K · 3% above $250K |
| Enterprise On-Ramp | $5,500 | **10% (flat, no tiering)** |
| Enterprise | $15,000 | 10% of $0–150K · 7% of $150K–500K · 5% of $500K–1M · 3% above $1M |

Evaluating those piecewise functions gives a table that changes procurement decisions:

| Monthly AWS spend | Developer | Business | Enterprise On-Ramp | Enterprise |
|---:|---:|---:|---:|---:|
| $5,000 | $150 | $500 | $5,500 | $15,000 |
| $10,000 | $300 | $1,000 | $5,500 | $15,000 |
| $50,000 | $1,500 | $3,800 | $5,500 | $15,000 |
| $100,000 | $3,000 | $6,900 | $10,000 | $15,000 |
| **$150,000** | $4,500 | $9,400 | **$15,000** | **$15,000** |
| $250,000 | $7,500 | $14,400 | $25,000 | $22,000 |
| $500,000 | $15,000 | $21,900 | $50,000 | $39,500 |
| $1,000,000 | $30,000 | $36,900 | $100,000 | $64,500 |

**The crossover is exactly $150,000/month of AWS charges.** Below it, On-Ramp is the cheaper way to get a TAM and a sub-hour business-critical target. At exactly $150K both cost $15,000. **Above $150K/month, Enterprise Support is strictly cheaper than Enterprise On-Ramp** — and it is also strictly better (15 min vs 30 min, designated vs pooled TAM, Trusted Advisor Priority, IDR eligibility). Derivation: for `S > 150,000`, On-Ramp `= 0.10·S` and Enterprise `= 15,000 + 0.07·(S − 150,000) = 4,500 + 0.07·S`; the difference is `0.03·(S − 150,000)`, positive and growing. There is no spend level above $150K at which On-Ramp is rational.

Pricing changes. Re-derive this against the live pricing page before acting on it; the *method* is the durable part.

### 3.4 Support plans under AWS Organizations

Support is billed per account but assessed against **consolidated** usage. Under a payer account with consolidated billing, the support plan is applied across the organization — you cannot economically put one member account on Enterprise and leave the rest on Basic, and AWS treats the aggregated spend as the basis for the percentage tier. Practical consequences:

- A sandbox account inside an Enterprise organization inherits Enterprise Support and therefore inherits the Support API. Your tooling can assume it uniformly.
- Support **cases are per-account and not visible across the organization by default.** There is no `DescribeCases` org-wide view. Centralised case reporting requires assuming a role in each member account (§9.2).
- AWS Health *does* have an organizational view, enabled once from the management account (§5.2). This asymmetry — Health is org-aware, Support cases are not — drives the architecture in §9.

---

## 4. AWS Trusted Advisor

### 4.1 What it actually is

A managed, continuously-evaluated rules engine over your account's resource configuration, resource utilisation metrics and service quota consumption. Six categories:

| Category | Representative checks | Data source |
|---|---|---|
| **Cost Optimization** | Low-utilisation EC2, idle load balancers, unassociated Elastic IPs, underutilised EBS volumes, idle RDS instances, Reserved Instance/Savings Plans coverage | CloudWatch metrics (14-day lookback), Cost Explorer |
| **Performance** | Over-utilised instances, high-latency CloudFront distributions, EBS throughput-optimised mismatch, excessive security group rules | CloudWatch, config |
| **Security** | MFA on root, public snapshots, open security-group ports, S3 bucket ACLs, IAM access-key rotation, CloudTrail logging, exposed access keys | Config, IAM, CloudTrail |
| **Fault Tolerance** | Single-AZ ASGs, EBS snapshot age, RDS Multi-AZ, ELB cross-zone, Route 53 health checks, S3 versioning | Config |
| **Service Limits** | Usage ≥ 80% of quota for ~40 quotas across EC2, VPC, EBS, ELB, IAM, RDS, SES, DynamoDB, Auto Scaling, CloudFormation, Kinesis | Service Quotas + usage |
| **Operational Excellence** | CloudWatch alarm coverage, log-group retention not configured, resources missing tags | Config |

Trusted Advisor sees your resources through the **`AWSServiceRoleForTrustedAdvisor`** service-linked role (`trustedadvisor.amazonaws.com`). If a team deletes it "to clean up IAM", every check silently degrades to `not_available` — a real and under-diagnosed failure (§11.4).

### 4.2 Refresh semantics — the part that breaks automation

Checks are **not** live. Each check carries its own refresh interval, and a manual refresh is rate-limited per check.

| Concept | Behaviour |
|---|---|
| Automatic refresh | Weekly for most checks while the console is not open; more frequently for Service Limits |
| Console-triggered refresh | Refreshes on page load, subject to the per-check cooldown |
| `RefreshTrustedAdvisorCheck` | Enqueues a refresh; returns `status` ∈ `none` \| `enqueued` \| `processing` \| `success` \| `abandoned` |
| Cooldown discovery | `DescribeTrustedAdvisorCheckRefreshStatuses` returns `millisUntilNextRefreshable` — **the only correct way to pace a refresh loop** |
| Result staleness | `DescribeTrustedAdvisorCheckResult` returns `timestamp`; treat results older than the check's interval as advisory only |

Refreshing on a fixed `rate(1 hour)` schedule without reading `millisUntilNextRefreshable` produces a stream of no-op refreshes and a metric that looks fresh but is not. The scheduled Lambda in §9.1 does this correctly.

### 4.3 Trusted Advisor Priority vs. the standard service

| | Trusted Advisor (Business+) | Trusted Advisor Priority (Enterprise only) |
|---|---|---|
| Recommendation source | Automated checks | Automated checks **+ TAM-curated, account-specific risks** |
| Prioritisation | Flat list, red/yellow/green | Ranked by TAM against your architecture and roadmap |
| Lifecycle | Stateless — a finding is red or not | Stateful: `pending_response` → `in_progress` → `dismissed`/`resolved` |
| API | `trustedadvisor:ListRecommendations` | `+ UpdateRecommendationLifecycle`, `ListOrganizationRecommendations` |
| Org aggregation | Per-account | Organization-wide roll-up |

Priority's lifecycle state is what makes it usable as a governance backlog: a recommendation you deliberately accept the risk on can be `dismissed` with a reason, and it stops re-appearing. Standard Trusted Advisor has **no suppression mechanism** — you must maintain the exclusion list yourself, which is why the §9.1 Lambda carries an explicit allow-list.

---

## 5. AWS Health

Three distinct things share the name. Confusing them is the most common error in this task statement.

### 5.1 The three surfaces

| Surface | URL / API | Auth | Scope | Plan requirement |
|---|---|---|---|---|
| **AWS Health Dashboard — Service health** | `health.aws.amazon.com/health/status` | **None** (public) | All AWS regions/services, aggregated for all customers | Any (incl. no account) |
| **AWS Health Dashboard — Your account health** | Console, `health.aws.amazon.com/health/home` | Console sign-in | **Your** resources: scheduled changes, issues affecting you, account notifications | **Any plan, including Basic** |
| **AWS Health API** | `global.health.amazonaws.com` | SigV4 | Programmatic, org-wide with trusted access | **Business, Enterprise On-Ramp, Enterprise** |

The exam-relevant sentence: *personalised* health information is free (dashboard); *programmatic* access to it is not (API). EventBridge delivery of `aws.health` events is available to all accounts, which is the loophole that makes event-driven automation possible below Business — but you get pushed events only, with no ability to query history.

### 5.2 Event taxonomy

| `eventTypeCategory` | Meaning | Typical `eventTypeCode` |
|---|---|---|
| `issue` | Unplanned AWS-side degradation | `AWS_EC2_OPERATIONAL_ISSUE`, `AWS_RDS_OPERATIONAL_ISSUE` |
| `scheduledChange` | Planned maintenance affecting your resources | `AWS_RDS_PLANNED_LIFECYCLE_EVENT`, `AWS_EC2_PERSISTENT_INSTANCE_RETIREMENT_SCHEDULED` |
| `accountNotification` | Account/billing/security notice | `AWS_RISK_CREDENTIALS_EXPOSED`, `AWS_ELASTICLOADBALANCING_API_ISSUE` |
| `investigation` | AWS is investigating a potential issue | Service-specific |

`AWS_RISK_CREDENTIALS_EXPOSED` deserves special mention: AWS scans public Git hosts for leaked access keys and raises this event *plus* applies the `AWSCompromisedKeyQuarantineV3` policy to the principal. Wiring this event type to a pager is the single highest-value Health automation you can build, and it works on every plan through EventBridge.

### 5.3 Endpoint architecture and the failover trap

The Health API is a **global service with a regional failover model**:

- Primary endpoint: `global.health.amazonaws.com`, signed for **`us-east-1`**.
- If the active region moves (AWS may fail the control plane over to `us-east-2`), the *same* hostname resolves to the new region but **must be signed for that region**.
- `DescribeEventDetails` and friends therefore require your client to handle a signing-region change. The AWS SDKs handle this; hand-rolled SigV4 clients and some older CLI versions do not.

The correct discovery call is `aws health describe-event-details` failing over via the documented active-endpoint lookup; in practice, use a current SDK/CLI and do not pin the signing region in your own code.

---

## 6. Service Quotas — the operational half of Trusted Advisor

Trusted Advisor tells you a quota is at 80%. Service Quotas is where you *see* and *change* it.

| Operation | CLI | Notes |
|---|---|---|
| List quotas for a service | `aws service-quotas list-service-quotas --service-code ec2` | Applied values (account-specific) |
| List AWS defaults | `aws service-quotas list-aws-default-service-quotas --service-code ec2` | Compare to detect prior increases |
| Read one quota | `aws service-quotas get-service-quota --service-code ec2 --quota-code L-1216C47A` | `Adjustable: true/false` is the key field |
| Request an increase | `aws service-quotas request-service-quota-increase ...` | Fails with `NoSuchResourceException` if not adjustable here |
| Org-wide template | `aws service-quotas put-service-quota-increase-request-into-template ...` | Applied automatically to **new** accounts in the org |
| CloudWatch alarm | `AWS/Usage` namespace + `SERVICE_QUOTA()` metric math | The only *real-time* quota alarm mechanism |

Frequently-needed quota codes:

| Quota | Service | Code |
|---|---|---|
| Running On-Demand Standard (A,C,D,H,I,M,R,T,Z) instances (vCPU) | `ec2` | `L-1216C47A` |
| EC2-VPC Elastic IPs | `ec2` | `L-0263D0A3` |
| VPCs per Region | `vpc` | `L-F678F1CE` |
| Lambda concurrent executions | `lambda` | `L-B99A9384` |
| Rules per Network ACL | `vpc` | `L-2AEEBF1A` |

**Not every quota is adjustable through Service Quotas.** Hard limits and some service-team-owned quotas must go through a *support case* with `issueType=service-limit-increase` — which puts you back on the plan-dependent response clock. This is the mechanical link between §3 and §6, and it is exactly the scenario the exam probes.

---

## 7. Proactive and human programs

| Program | Plan | What it is | When it earns its cost |
|---|---|---|---|
| **Technical Account Manager (TAM)** | On-Ramp (pool) / Enterprise (designated) | Named AWS engineer who knows your architecture; runs Well-Architected reviews, escalates cases, gives roadmap guidance under NDA | Multi-account platforms with recurring launches; escalation path shortens tail latency on hard cases |
| **Concierge** | On-Ramp, Enterprise | Billing and account specialists (not technical) | Consolidated billing, RI/SP portfolio management, payment/tax disputes |
| **AWS Incident Detection and Response (IDR)** | Enterprise, **paid add-on** | Workloads are onboarded and monitored by AWS; AWS engages within **5 minutes** on a detected critical incident, with a pre-agreed runbook | Tier-0 workloads where detection latency dominates MTTR |
| **AWS Countdown** (ex Infrastructure Event Management) | On-Ramp, Enterprise (purchasable on Business) | Engineered support for a bounded event: migration, launch, Black Friday. Capacity planning, quota pre-provisioning, on-call AWS staff during the window | Anything with a hard date and a spike |
| **Well-Architected Framework Review** | On-Ramp, Enterprise (TAM-led); tool is free for everyone | Structured review against the six pillars, producing a prioritised improvement plan | Before, not after, a platform freeze |
| **AWS re:Post Private** | On-Ramp, Enterprise | Private, curated knowledge community for your org, seeded with your AWS content | Large orgs where tribal knowledge is the bottleneck |
| **AWS Managed Services (AMS)** | Requires Enterprise Support | AWS operates your infrastructure to ITIL practice — patching, monitoring, incident and change management. AMS Accelerate (bring your own accounts) / AMS Advanced (AWS-built landing zone) | You need AWS-run operations, not AWS-advised operations |
| **AWS Professional Services** | Any (paid SOW) | AWS's own consulting org, delivery-focused | Migrations, greenfield platform builds |
| **AWS Partner Network (APN)** | Any | Software, Services, Hardware, Training and Distribution paths; Select / Advanced / Premier tiers; Competencies and Service Delivery designations | Regional or vertical expertise AWS itself does not staff |
| **AWS IQ** | Any (US) | Marketplace for short engagements with AWS Certified freelancers, billed through your AWS account | Small, bounded, expert tasks |
| **AWS Marketplace** | Any | Curated third-party software with consolidated billing; Private Offers, Private Marketplace, EULA standardisation | Procurement velocity; spend counts toward EDP commitments |

**Trade-off worth stating plainly:** AMS, ProServe, Partners and IQ are all "someone else does the work". They differ in *who is accountable* and *how the contract is shaped* — AMS is an ongoing operational service with SLAs, ProServe and Partners are project engagements, IQ is a task marketplace. On the exam, "we want AWS to run our infrastructure day to day" → AMS; "we need help designing a migration" → ProServe or a Partner; "we need one certified expert for a week" → IQ.

---

## 8. Free technical resources you are expected to name

| Resource | URL | What it is for |
|---|---|---|
| AWS Documentation | `docs.aws.amazon.com` | Service guides, API references, CLI reference |
| AWS Whitepapers & Guides | `aws.amazon.com/whitepapers/` | Long-form technical papers (Well-Architected, Overview of AWS, Security Pillar) |
| AWS Architecture Center | `aws.amazon.com/architecture/` | Reference architectures, diagrams, decision guides |
| AWS Prescriptive Guidance | `aws.amazon.com/prescriptive-guidance/` | Patterns, strategies and migration playbooks from AWS field teams |
| AWS Solutions Library | `aws.amazon.com/solutions/` | Deployable CloudFormation-based solutions |
| AWS Well-Architected Tool | Console (free) | Self-service workload review against six pillars + lenses |
| AWS re:Post | `repost.aws` | Community Q&A; replaced AWS Forums |
| AWS Knowledge Center | `repost.aws/knowledge-center` | Curated answers to the most common support questions |
| AWS Blogs | `aws.amazon.com/blogs/` | Launch details and deep dives, per service and per discipline |
| AWS Skill Builder | `skillbuilder.aws` | Training, labs, exam prep |
| AWS Artifact | Console | On-demand compliance reports (SOC, PCI, ISO) and agreements |
| AWS Security Bulletins | `aws.amazon.com/security/security-bulletins/` | CVE and security advisories affecting AWS services |
| AWS Trust & Safety (abuse) | `support.aws.amazon.com/#/contacts/report-abuse` | Report abuse **originating from** AWS resources |
| AWS Service Health status page | `health.aws.amazon.com/health/status` | Public, unauthenticated regional status |

**The Well-Architected six pillars** (asked directly): Operational Excellence, Security, Reliability, Performance Efficiency, Cost Optimization, Sustainability.

---

## 9. Infrastructure: wiring the support plane into your operations

### 9.1 CloudFormation — Health-driven case automation, Trusted Advisor metrics, quota alarms

Deploy in `us-east-1`. The Support and Trusted Advisor APIs are only served from `us-east-1`; the Health API is global but signed there.

```yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: >
  Support control plane: AWS Health -> EventBridge -> auto Support case,
  Trusted Advisor red-check metric emission, and service quota alarms.
  MUST be deployed in us-east-1 (support/trustedadvisor endpoints are us-east-1 only).

Parameters:
  NotificationEmail:
    Type: String
    Description: Address subscribed to the support-events SNS topic.
    AllowedPattern: '^[^@\s]+@[^@\s]+\.[^@\s]+$'

  AutoCaseSeverity:
    Type: String
    Description: Severity used for auto-opened cases. 'critical' requires Enterprise/On-Ramp.
    Default: high
    AllowedValues: [low, normal, high, urgent, critical]

  TrustedAdvisorCheckIds:
    Type: CommaDelimitedList
    Description: Trusted Advisor check IDs to refresh and publish as metrics.
    Default: 'eW7HH0l7J9,HCP4007jGY,7DAFEmoDos,Pfx0RwqBli'

  MonitoredHealthServices:
    Type: CommaDelimitedList
    Description: AWS Health 'service' values that justify an automatic case.
    Default: 'EC2,RDS,ELASTICLOADBALANCING,EKS,LAMBDA,DYNAMODB'

Conditions:
  # Guard: refuse to build the case-opening path outside us-east-1.
  IsSupportRegion: !Equals [!Ref 'AWS::Region', 'us-east-1']

Resources:

  ############################################################
  # Notification fan-out
  ############################################################
  SupportEventsTopic:
    Type: AWS::SNS::Topic
    Properties:
      TopicName: support-control-plane-events
      DisplayName: AWS Support & Health events
      KmsMasterKeyId: alias/aws/sns

  SupportEventsTopicPolicy:
    Type: AWS::SNS::TopicPolicy
    Properties:
      Topics:
        - !Ref SupportEventsTopic
      PolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Sid: AllowEventBridgePublish
            Effect: Allow
            Principal:
              Service: events.amazonaws.com
            Action: 'sns:Publish'
            Resource: !Ref SupportEventsTopic
            Condition:
              StringEquals:
                'aws:SourceAccount': !Ref 'AWS::AccountId'

  SupportEventsSubscription:
    Type: AWS::SNS::Subscription
    Properties:
      TopicArn: !Ref SupportEventsTopic
      Protocol: email
      Endpoint: !Ref NotificationEmail

  ############################################################
  # 1. Every AWS Health event -> SNS (audit trail, all plans)
  ############################################################
  HealthAllEventsRule:
    Type: AWS::Events::Rule
    Properties:
      Name: aws-health-all-events
      Description: Fan out every AWS Health event for the account.
      EventPattern:
        source:
          - aws.health
      State: ENABLED
      Targets:
        - Id: sns
          Arn: !Ref SupportEventsTopic
          InputTransformer:
            InputPathsMap:
              service: '$.detail.service'
              category: '$.detail.eventTypeCategory'
              code: '$.detail.eventTypeCode'
              region: '$.detail.eventRegion'
              time: '$.time'
            InputTemplate: |
              "[AWS Health] <service> / <category>"
              "code:   <code>"
              "region: <region>"
              "time:   <time>"

  ############################################################
  # 2. Credential exposure -> immediate, unconditional page
  ############################################################
  HealthCredentialsExposedRule:
    Type: AWS::Events::Rule
    Properties:
      Name: aws-health-credentials-exposed
      Description: AWS detected exposed credentials for this account.
      EventPattern:
        source:
          - aws.health
        detail-type:
          - 'AWS Health Event'
        detail:
          eventTypeCode:
            - AWS_RISK_CREDENTIALS_EXPOSED
            - AWS_RISK_CREDENTIALS_COMPROMISED
      State: ENABLED
      Targets:
        - Id: sns
          Arn: !Ref SupportEventsTopic

  ############################################################
  # 3. Operational issues on monitored services -> Support case
  ############################################################
  AutoCaseFunctionRole:
    Type: AWS::IAM::Role
    Condition: IsSupportRegion
    Properties:
      AssumeRolePolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Effect: Allow
            Principal:
              Service: lambda.amazonaws.com
            Action: 'sts:AssumeRole'
      ManagedPolicyArns:
        - arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
      Policies:
        - PolicyName: support-write
          PolicyDocument:
            Version: '2012-10-17'
            Statement:
              # The AWS Support API does NOT support resource-level
              # permissions. Resource must be '*'; scope with conditions
              # on the calling principal instead.
              - Effect: Allow
                Action:
                  - 'support:CreateCase'
                  - 'support:AddCommunicationToCase'
                  - 'support:DescribeCases'
                  - 'support:DescribeSeverityLevels'
                  - 'support:DescribeServices'
                Resource: '*'
              - Effect: Allow
                Action: 'sns:Publish'
                Resource: !Ref SupportEventsTopic

  AutoCaseFunction:
    Type: AWS::Lambda::Function
    Condition: IsSupportRegion
    Properties:
      FunctionName: health-event-to-support-case
      Runtime: python3.12
      Handler: index.handler
      Timeout: 60
      MemorySize: 256
      Role: !GetAtt AutoCaseFunctionRole.Arn
      Environment:
        Variables:
          SEVERITY: !Ref AutoCaseSeverity
          TOPIC_ARN: !Ref SupportEventsTopic
          MONITORED: !Join [',', !Ref MonitoredHealthServices]
      Code:
        # NOTE: inline ZipFile is capped at 4096 characters by CloudFormation.
        ZipFile: |
          import json, os, boto3

          # support/trustedadvisor are served ONLY from us-east-1.
          support = boto3.client("support", region_name="us-east-1")
          sns = boto3.client("sns")

          MONITORED = {s.strip().upper() for s in os.environ["MONITORED"].split(",")}
          SEVERITY = os.environ["SEVERITY"]
          TOPIC = os.environ["TOPIC_ARN"]

          def allowed_severity(requested):
              """Never assume a severity exists; the plan decides."""
              levels = [l["code"] for l in
                        support.describe_severity_levels(language="en")["severityLevels"]]
              if requested in levels:
                  return requested
              for fallback in ("urgent", "high", "normal", "low"):
                  if fallback in levels:
                      return fallback
              raise RuntimeError("no usable severity level: %s" % levels)

          def handler(event, context):
              d = event.get("detail", {})
              service = (d.get("service") or "").upper()
              category = d.get("eventTypeCategory")

              if category != "issue" or service not in MONITORED:
                  return {"skipped": True, "service": service, "category": category}

              desc = "\n".join(
                  x.get("latestDescription", "")
                  for x in d.get("eventDescription", [])
              )
              entities = d.get("affectedEntities", [])
              body = (
                  "Automatically opened from an AWS Health event.\n\n"
                  f"eventTypeCode: {d.get('eventTypeCode')}\n"
                  f"eventRegion:   {d.get('eventRegion')}\n"
                  f"startTime:     {d.get('startTime')}\n"
                  f"affected:      {len(entities)} entities\n\n"
                  f"{desc}\n"
              )

              case = support.create_case(
                  subject=f"[auto] {service} issue: {d.get('eventTypeCode')}",
                  serviceCode="general-info",
                  categoryCode="using-aws",
                  severityCode=allowed_severity(SEVERITY),
                  communicationBody=body[:8000],
                  language="en",
                  issueType="technical",
              )
              sns.publish(
                  TopicArn=TOPIC,
                  Subject=f"Support case opened: {service}",
                  Message=json.dumps({"caseId": case["caseId"], "detail": d}, default=str),
              )
              return case

  HealthIssueRule:
    Type: AWS::Events::Rule
    Condition: IsSupportRegion
    Properties:
      Name: aws-health-issue-to-case
      Description: Open a Support case for AWS-side operational issues.
      EventPattern:
        source:
          - aws.health
        detail:
          eventTypeCategory:
            - issue
      State: ENABLED
      Targets:
        - Id: lambda
          Arn: !GetAtt AutoCaseFunction.Arn

  HealthIssueRulePermission:
    Type: AWS::Lambda::Permission
    Condition: IsSupportRegion
    Properties:
      FunctionName: !GetAtt AutoCaseFunction.Arn
      Action: 'lambda:InvokeFunction'
      Principal: events.amazonaws.com
      SourceArn: !GetAtt HealthIssueRule.Arn

  ############################################################
  # 4. Trusted Advisor: refresh respecting cooldown, emit metrics
  ############################################################
  TrustedAdvisorFunctionRole:
    Type: AWS::IAM::Role
    Condition: IsSupportRegion
    Properties:
      AssumeRolePolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Effect: Allow
            Principal:
              Service: lambda.amazonaws.com
            Action: 'sts:AssumeRole'
      ManagedPolicyArns:
        - arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
      Policies:
        - PolicyName: trusted-advisor-read
          PolicyDocument:
            Version: '2012-10-17'
            Statement:
              - Effect: Allow
                Action:
                  - 'support:DescribeTrustedAdvisorChecks'
                  - 'support:DescribeTrustedAdvisorCheckResult'
                  - 'support:DescribeTrustedAdvisorCheckRefreshStatuses'
                  - 'support:RefreshTrustedAdvisorCheck'
                Resource: '*'
              - Effect: Allow
                Action: 'cloudwatch:PutMetricData'
                Resource: '*'
                Condition:
                  StringEquals:
                    'cloudwatch:namespace': 'Custom/TrustedAdvisor'

  TrustedAdvisorFunction:
    Type: AWS::Lambda::Function
    Condition: IsSupportRegion
    Properties:
      FunctionName: trusted-advisor-metrics
      Runtime: python3.12
      Handler: index.handler
      Timeout: 300
      MemorySize: 256
      Role: !GetAtt TrustedAdvisorFunctionRole.Arn
      Environment:
        Variables:
          CHECK_IDS: !Join [',', !Ref TrustedAdvisorCheckIds]
      Code:
        ZipFile: |
          import os, boto3

          support = boto3.client("support", region_name="us-east-1")
          cw = boto3.client("cloudwatch")

          CHECKS = [c.strip() for c in os.environ["CHECK_IDS"].split(",") if c.strip()]

          def handler(event, context):
              # Only refresh checks that are actually off cooldown.
              statuses = support.describe_trusted_advisor_check_refresh_statuses(
                  checkIds=CHECKS)["statuses"]
              cooldown = {s["checkId"]: s["millisUntilNextRefreshable"] for s in statuses}

              refreshed = []
              for cid in CHECKS:
                  if cooldown.get(cid, 0) == 0:
                      support.refresh_trusted_advisor_check(checkId=cid)
                      refreshed.append(cid)

              metrics, report = [], {}
              for cid in CHECKS:
                  r = support.describe_trusted_advisor_check_result(
                      checkId=cid, language="en")["result"]
                  summary = r["resourcesSummary"]
                  report[cid] = {
                      "status": r["status"],
                      "flagged": summary["resourcesFlagged"],
                      "timestamp": r["timestamp"],
                  }
                  for name, value in (
                      ("FlaggedResources", summary["resourcesFlagged"]),
                      ("SuppressedResources", summary["resourcesSuppressed"]),
                      ("IsRed", 1 if r["status"] == "error" else 0),
                      ("IsYellow", 1 if r["status"] == "warning" else 0),
                  ):
                      metrics.append({
                          "MetricName": name,
                          "Dimensions": [{"Name": "CheckId", "Value": cid}],
                          "Value": float(value),
                          "Unit": "Count",
                      })

              for i in range(0, len(metrics), 20):
                  cw.put_metric_data(Namespace="Custom/TrustedAdvisor",
                                     MetricData=metrics[i:i + 20])

              return {"refreshed": refreshed, "cooldown_ms": cooldown, "results": report}

  TrustedAdvisorSchedule:
    Type: AWS::Events::Rule
    Condition: IsSupportRegion
    Properties:
      Name: trusted-advisor-metrics-schedule
      Description: Refresh (when permitted) and publish Trusted Advisor metrics.
      ScheduleExpression: 'rate(6 hours)'
      State: ENABLED
      Targets:
        - Id: lambda
          Arn: !GetAtt TrustedAdvisorFunction.Arn

  TrustedAdvisorSchedulePermission:
    Type: AWS::Lambda::Permission
    Condition: IsSupportRegion
    Properties:
      FunctionName: !GetAtt TrustedAdvisorFunction.Arn
      Action: 'lambda:InvokeFunction'
      Principal: events.amazonaws.com
      SourceArn: !GetAtt TrustedAdvisorSchedule.Arn

  TrustedAdvisorRedAlarm:
    Type: AWS::CloudWatch::Alarm
    Condition: IsSupportRegion
    Properties:
      AlarmName: trusted-advisor-service-limits-red
      AlarmDescription: Service Limits check is red (a quota is at or over 80%).
      Namespace: Custom/TrustedAdvisor
      MetricName: IsRed
      Dimensions:
        - Name: CheckId
          Value: eW7HH0l7J9
      Statistic: Maximum
      Period: 21600
      EvaluationPeriods: 1
      Threshold: 0
      ComparisonOperator: GreaterThanThreshold
      TreatMissingData: breaching
      AlarmActions:
        - !Ref SupportEventsTopic
      OKActions:
        - !Ref SupportEventsTopic

  ############################################################
  # 5. Real-time quota alarm via SERVICE_QUOTA() metric math
  ############################################################
  Ec2VcpuQuotaAlarm:
    Type: AWS::CloudWatch::Alarm
    Properties:
      AlarmName: ec2-standard-vcpu-quota-80pct
      AlarmDescription: >
        On-Demand Standard vCPU usage is above 80% of the account quota.
        Uses AWS/Usage + SERVICE_QUOTA() so it does not depend on
        Trusted Advisor's refresh interval.
      ComparisonOperator: GreaterThanThreshold
      EvaluationPeriods: 1
      Threshold: 80
      TreatMissingData: notBreaching
      AlarmActions:
        - !Ref SupportEventsTopic
      Metrics:
        - Id: usage
          ReturnData: false
          MetricStat:
            Metric:
              Namespace: AWS/Usage
              MetricName: ResourceCount
              Dimensions:
                - Name: Service
                  Value: EC2
                - Name: Class
                  Value: Standard/OnDemand
                - Name: Type
                  Value: Resource
                - Name: Resource
                  Value: vCPU
            Period: 300
            Stat: Maximum
        - Id: quota
          ReturnData: false
          Expression: 'SERVICE_QUOTA(usage)'
        - Id: pct
          ReturnData: true
          Label: vCPU quota utilisation (%)
          Expression: '(usage / quota) * 100'

Outputs:
  TopicArn:
    Description: SNS topic carrying all support-plane events.
    Value: !Ref SupportEventsTopic
    Export:
      Name: !Sub '${AWS::StackName}-topic-arn'

  AutoCaseFunctionName:
    Condition: IsSupportRegion
    Description: Lambda that opens Support cases from AWS Health issues.
    Value: !Ref AutoCaseFunction

  SupportApiNote:
    Description: Reminder about plan gating.
    Value: >-
      support:* and health:Describe* require Business, Enterprise On-Ramp or
      Enterprise Support. On Basic/Developer these calls fail with
      SubscriptionRequiredException and the case-opening path is inert.
```

### 9.2 Terraform — organization-wide health aggregation and quota templates

Applied from the **management account**. Establishes trusted access, a central event bus that member accounts forward Health events to, and a quota-increase template that pre-provisions every future account.

```hcl
terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.40"
    }
  }
}

# Support, Trusted Advisor and Health signing all live in us-east-1.
provider "aws" {
  region = "us-east-1"
}

data "aws_caller_identity" "current" {}
data "aws_organizations_organization" "this" {}

############################################################
# 1. Trusted access: enables the organizational view of
#    AWS Health and org-wide Trusted Advisor recommendations.
############################################################
resource "aws_organizations_organization" "this" {
  feature_set = "ALL"

  aws_service_access_principals = [
    "health.amazonaws.com",          # AWS Health organizational view
    "reporting.trustedadvisor.amazonaws.com", # Trusted Advisor org reporting
    "servicequotas.amazonaws.com",   # Service Quotas request templates
    "cloudtrail.amazonaws.com",
    "config.amazonaws.com",
  ]

  enabled_policy_types = ["SERVICE_CONTROL_POLICY"]

  lifecycle {
    # The org already exists; never let Terraform try to recreate it.
    prevent_destroy = true
  }
}

############################################################
# 2. Central event bus for AWS Health events from members.
############################################################
resource "aws_cloudwatch_event_bus" "support" {
  name = "org-support-plane"
}

resource "aws_cloudwatch_event_bus_policy" "support" {
  event_bus_name = aws_cloudwatch_event_bus.support.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowOrgMembersToPutHealthEvents"
        Effect    = "Allow"
        Principal = "*"
        Action    = "events:PutEvents"
        Resource  = aws_cloudwatch_event_bus.support.arn
        Condition = {
          StringEquals = {
            "aws:PrincipalOrgID" = data.aws_organizations_organization.this.id
          }
        }
      }
    ]
  })
}

resource "aws_cloudwatch_event_rule" "org_health" {
  name           = "org-health-issues"
  description    = "AWS Health issue and scheduledChange events from all member accounts."
  event_bus_name = aws_cloudwatch_event_bus.support.name

  event_pattern = jsonencode({
    source = ["aws.health"]
    detail = {
      eventTypeCategory = ["issue", "scheduledChange", "accountNotification"]
    }
  })
}

resource "aws_sns_topic" "org_health" {
  name              = "org-health-events"
  kms_master_key_id = "alias/aws/sns"
}

resource "aws_sns_topic_policy" "org_health" {
  arn = aws_sns_topic.org_health.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowEventBridgePublish"
        Effect    = "Allow"
        Principal = { Service = "events.amazonaws.com" }
        Action    = "sns:Publish"
        Resource  = aws_sns_topic.org_health.arn
        Condition = {
          StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
        }
      }
    ]
  })
}

resource "aws_cloudwatch_event_target" "org_health_sns" {
  rule           = aws_cloudwatch_event_rule.org_health.name
  event_bus_name = aws_cloudwatch_event_bus.support.name
  target_id      = "sns"
  arn            = aws_sns_topic.org_health.arn

  input_transformer {
    input_paths = {
      account = "$.account"
      service = "$.detail.service"
      code    = "$.detail.eventTypeCode"
      region  = "$.detail.eventRegion"
    }
    input_template = <<-EOT
      "[org-health] account=<account> service=<service>"
      "code=<code> region=<region>"
    EOT
  }
}

############################################################
# 3. Quota increase template — applied to NEW org accounts.
############################################################
resource "aws_servicequotas_template_association" "org" {
  depends_on = [aws_organizations_organization.this]
}

locals {
  quota_template = {
    ec2_standard_vcpu = {
      service_code = "ec2"
      quota_code   = "L-1216C47A" # Running On-Demand Standard instances (vCPU)
      value        = 512
    }
    vpcs_per_region = {
      service_code = "vpc"
      quota_code   = "L-F678F1CE" # VPCs per Region
      value        = 20
    }
    elastic_ips = {
      service_code = "ec2"
      quota_code   = "L-0263D0A3" # EC2-VPC Elastic IPs
      value        = 20
    }
    lambda_concurrency = {
      service_code = "lambda"
      quota_code   = "L-B99A9384" # Concurrent executions
      value        = 3000
    }
  }
}

resource "aws_servicequotas_template" "defaults" {
  for_each = local.quota_template

  region       = "us-east-1"
  service_code = each.value.service_code
  quota_code   = each.value.quota_code
  value        = each.value.value
}

############################################################
# 4. Explicit, adjustable quota in THIS account (not a template).
############################################################
resource "aws_servicequotas_service_quota" "ec2_vcpu" {
  service_code = "ec2"
  quota_code   = "L-1216C47A"
  value        = 512
}

############################################################
# 5. Read-only support role for on-call engineers.
############################################################
resource "aws_iam_role" "oncall_support" {
  name = "oncall-support-reader"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action    = "sts:AssumeRole"
        Condition = {
          Bool = { "aws:MultiFactorAuthPresent" = "true" }
        }
      }
    ]
  })
}

# AWSSupportAccess is the AWS-managed policy that grants full Support API
# access. It cannot be scoped by resource -- the Support API has no
# resource-level permissions. Scope by principal and MFA instead.
resource "aws_iam_role_policy_attachment" "oncall_support" {
  role       = aws_iam_role.oncall_support.name
  policy_arn = "arn:aws:iam::aws:policy/AWSSupportAccess"
}

resource "aws_iam_role_policy" "oncall_health_ta" {
  name = "health-and-trusted-advisor-read"
  role = aws_iam_role.oncall_support.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "health:DescribeEvents",
          "health:DescribeEventDetails",
          "health:DescribeAffectedEntities",
          "health:DescribeEventAggregates",
          "health:DescribeEventTypes",
          "health:DescribeEventsForOrganization",
          "health:DescribeAffectedAccountsForOrganization",
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "trustedadvisor:ListChecks",
          "trustedadvisor:ListRecommendations",
          "trustedadvisor:GetRecommendation",
          "trustedadvisor:ListRecommendationResources",
          "trustedadvisor:ListOrganizationRecommendations",
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "servicequotas:GetServiceQuota",
          "servicequotas:ListServiceQuotas",
          "servicequotas:ListAWSDefaultServiceQuotas",
          "servicequotas:ListRequestedServiceQuotaChangeHistory",
        ]
        Resource = "*"
      }
    ]
  })
}

output "org_health_topic_arn" {
  value       = aws_sns_topic.org_health.arn
  description = "SNS topic carrying org-wide AWS Health events."
}

output "support_plan_prerequisite" {
  value = join(" ", [
    "health:Describe* and support:* require Business, Enterprise On-Ramp",
    "or Enterprise Support. On Basic/Developer these policies are valid but",
    "every call returns SubscriptionRequiredException.",
  ])
}
```

### 9.3 Declarative escalation policy (operational artifact)

The mapping from your internal severity to an AWS severity code should be a reviewed artifact, not a value someone types into the console at 03:00.

```yaml
# ops/aws-support-escalation.yaml
# Maps internal incident severity to AWS Support case parameters.
# Validated in CI against `aws support describe-severity-levels`.
apiVersion: ops.internal/v1
kind: SupportEscalationPolicy
metadata:
  name: production-escalation
  supportPlan: enterprise           # basic | developer | business | enterprise-onramp | enterprise
  supportApiRegion: us-east-1       # non-negotiable: only endpoint that exists

spec:
  # AWS response-time targets for THIS plan. CI asserts these still match
  # describe-severity-levels output; drift means the plan changed.
  severities:
    - internal: SEV1
      awsSeverityCode: critical
      awsSeverityName: Business-critical system down
      targetFirstResponse: 15m
      criteria: >-
        Customer-facing revenue path is fully unavailable in all regions,
        or data loss is in progress.
      requiredBefore:
        - Incident commander assigned
        - Status page updated
        - TAM paged out of band via the Enterprise escalation number
      openVia: [console, support-api, support-app-slack, phone]

    - internal: SEV2
      awsSeverityCode: urgent
      awsSeverityName: Production system down
      targetFirstResponse: 1h
      criteria: Production workload down in one region; failover available.
      openVia: [console, support-api, support-app-slack]

    - internal: SEV3
      awsSeverityCode: high
      awsSeverityName: Production system impaired
      targetFirstResponse: 4h
      criteria: Production degraded; SLO burn rate above 2x.
      openVia: [console, support-api]

    - internal: SEV4
      awsSeverityCode: normal
      awsSeverityName: System impaired
      targetFirstResponse: 12h
      criteria: Non-production impaired, or production with a workaround.
      openVia: [console, support-api]

    - internal: SEV5
      awsSeverityCode: low
      awsSeverityName: General guidance
      targetFirstResponse: 24h
      criteria: Questions, quota increases, architectural guidance.
      openVia: [console, support-api]

  # Quota increases follow a different path than incidents.
  quotaIncrease:
    preferredPath: service-quotas-api
    fallbackPath: support-case
    fallbackCaseParams:
      issueType: service-limit-increase
      severityCode: low
      leadTimeAssumption: 48h        # NEVER assume same-day
    preflight:
      - aws service-quotas get-service-quota --service-code {svc} --quota-code {code}
      - assert .Quota.Adjustable == true

  proactive:
    trustedAdvisorReviewCadence: weekly
    wellArchitectedReviewCadence: quarterly
    countdownRequestLeadTime: 6w     # AWS Countdown needs advance notice
    idrOnboardedWorkloads:
      - checkout-api
      - payments-ledger
```

---

## 10. CLI walkthrough with real output shapes

### 10.1 Establish which plan you are actually on

There is no `aws support get-plan` API. The load-bearing probe is `describe-severity-levels`: it succeeds only on Business and above, and the severities it returns identify the tier.

```console
$ aws support describe-severity-levels --language en --region us-east-1
{
    "severityLevels": [
        {
            "code": "low",
            "name": "General guidance"
        },
        {
            "code": "normal",
            "name": "System impaired"
        },
        {
            "code": "high",
            "name": "Production system impaired"
        },
        {
            "code": "urgent",
            "name": "Production system down"
        },
        {
            "code": "critical",
            "name": "Business-critical system down"
        }
    ]
}
```

`critical` present ⇒ Enterprise On-Ramp or Enterprise. Absent but `urgent` present ⇒ Business. Whole call fails ⇒ Basic or Developer:

```console
$ aws support describe-severity-levels --language en --region us-east-1

An error occurred (SubscriptionRequiredException) when calling the
DescribeSeverityLevels operation: Amazon Web Services Premium Support
Subscription is required to use this service.
```

A one-liner that classifies the account:

```console
$ aws support describe-severity-levels --region us-east-1 --language en \
    --query 'severityLevels[].code' --output text 2>/dev/null \
  | awk '{ if ($0 ~ /critical/) print "enterprise-or-onramp";
           else if ($0 ~ /urgent/) print "business";
           else print "unknown" }' \
  || echo "basic-or-developer"
enterprise-or-onramp
```

### 10.2 Open, inspect and resolve a case

```console
$ aws support describe-services --language en --region us-east-1 \
    --query 'services[?contains(name, `Elastic Compute`)]'
[
    {
        "code": "amazon-elastic-compute-cloud-linux",
        "name": "Amazon Elastic Compute Cloud (Linux)",
        "categories": [
            { "code": "apis",              "name": "APIs" },
            { "code": "instance-issue",    "name": "Instance Issue" },
            { "code": "networking",        "name": "Networking" },
            { "code": "performance",       "name": "Performance" },
            { "code": "using-aws",         "name": "General Guidance" }
        ]
    }
]
```

```console
$ aws support create-case \
    --region us-east-1 \
    --subject "us-east-1a: 12 m6i instances stuck in 'pending' since 14:02 UTC" \
    --service-code amazon-elastic-compute-cloud-linux \
    --category-code instance-issue \
    --severity-code urgent \
    --issue-type technical \
    --language en \
    --cc-email-addresses platform-oncall@example.com \
    --communication-body "$(cat <<'EOF'
Impact: checkout-api autoscaling cannot add capacity in us-east-1.
Started: 2026-09-04T14:02Z. Ongoing.

Symptom: RunInstances succeeds, instances remain in 'pending' > 15 min,
then transition to 'terminated' with StateReason
"Server.InternalError: Internal error on launch".

Scope: us-east-1a only. us-east-1b and us-east-1c launch normally.
Instance type: m6i.2xlarge. AMI: ami-0abcdef1234567890.
Subnet: subnet-0123456789abcdef0 (172.31.16.0/20, 3891 free IPs).
Quota check: 412/512 vCPU used, not quota-bound.

Sample instance IDs:
i-0aa11bb22cc33dd44, i-0ee55ff66aa77bb88, i-0cc99dd00ee11ff22

Requested: confirm whether there is an AZ-level capacity or control-plane
issue in use-east-1a, and whether we should shift the ASG to 1b/1c.
EOF
)"
{
    "caseId": "case-111122223333-muen-2026-9c1a4f7b2d3e8a05"
}
```

```console
$ aws support describe-cases --region us-east-1 \
    --case-id-list case-111122223333-muen-2026-9c1a4f7b2d3e8a05 \
    --include-communications \
    --query 'cases[0].{id:displayId,status:status,sev:severityCode,svc:serviceCode,submitted:timeCreated,msgs:length(recentCommunications.communications)}'
{
    "id": "9876543210",
    "status": "work-in-progress",
    "sev": "urgent",
    "svc": "amazon-elastic-compute-cloud-linux",
    "submitted": "2026-09-04T14:19:07.000Z",
    "msgs": 3
}
```

```console
$ aws support add-communication-to-case --region us-east-1 \
    --case-id case-111122223333-muen-2026-9c1a4f7b2d3e8a05 \
    --communication-body "Mitigated by draining us-east-1a from the ASG at 14:41Z.
Leaving the case open to confirm root cause before we re-enable the AZ."
{
    "result": true
}
```

```console
$ aws support resolve-case --region us-east-1 \
    --case-id case-111122223333-muen-2026-9c1a4f7b2d3e8a05
{
    "initialCaseStatus": "work-in-progress",
    "finalCaseStatus": "resolved"
}
```

Attachments (logs, `describe-instances` output) go through an attachment set, which **expires one hour after creation**, holds at most 3 files, 5 MB each:

```console
$ aws support add-attachments-to-set --region us-east-1 \
    --attachments fileName=ec2-describe.json,data=fileb://ec2-describe.json
{
    "attachmentSetId": "as-2f3g4h5j6k7l8m9n0p1q2r3s",
    "expiryTime": "2026-09-04T15:31:44.000Z"
}
```

### 10.3 Trusted Advisor from the CLI

```console
$ aws support describe-trusted-advisor-checks --language en --region us-east-1 \
    --query 'checks[?category==`service_limits`].{id:id,name:name}' --output table
------------------------------------------------
|         DescribeTrustedAdvisorChecks          |
+--------------+-------------------------------+
|      id      |             name              |
+--------------+-------------------------------+
|  eW7HH0l7J9  |  Service Limits               |
+--------------+-------------------------------+
```

```console
$ aws support describe-trusted-advisor-checks --language en --region us-east-1 \
    --query 'length(checks)'
234
```

On Basic/Developer that same call returns the core subset only — the count is the fastest way to tell whether you have the full check set.

```console
$ aws support describe-trusted-advisor-check-refresh-statuses \
    --region us-east-1 --check-ids eW7HH0l7J9 HCP4007jGY
{
    "statuses": [
        {
            "checkId": "eW7HH0l7J9",
            "status": "none",
            "millisUntilNextRefreshable": 0
        },
        {
            "checkId": "HCP4007jGY",
            "status": "success",
            "millisUntilNextRefreshable": 2843117
        }
    ]
}
```

`millisUntilNextRefreshable: 2843117` ≈ 47 minutes. Calling `refresh-trusted-advisor-check` before that elapses is accepted but does nothing.

```console
$ aws support refresh-trusted-advisor-check --region us-east-1 --check-id eW7HH0l7J9
{
    "status": {
        "checkId": "eW7HH0l7J9",
        "status": "enqueued",
        "millisUntilNextRefreshable": 3600000
    }
}
```

```console
$ aws support describe-trusted-advisor-check-result \
    --region us-east-1 --check-id eW7HH0l7J9 --language en \
    --query 'result.{status:status,ts:timestamp,summary:resourcesSummary}'
{
    "status": "warning",
    "ts": "2026-09-04T14:52:11Z",
    "summary": {
        "resourcesProcessed": 187,
        "resourcesFlagged": 3,
        "resourcesIgnored": 0,
        "resourcesSuppressed": 1
    }
}
```

```console
$ aws support describe-trusted-advisor-check-result \
    --region us-east-1 --check-id eW7HH0l7J9 --language en \
    --query 'result.flaggedResources[?status!=`ok`].metadata' --output table
------------------------------------------------------------------------------------
|                      DescribeTrustedAdvisorCheckResult                            |
+-------------+--------+-----------------------------+---------+---------+----------+
|  us-east-1  |  EC2   |  Running On-Demand Standard |  512    |  438    |  Yellow  |
|  us-east-1  |  VPC   |  VPCs                       |  5      |  5      |  Red     |
|  eu-west-1  |  EC2   |  EC2-VPC Elastic IPs        |  5      |  4      |  Yellow  |
+-------------+--------+-----------------------------+---------+---------+----------+
```

The metadata array is positional: `[Region, Service, Limit Name, Limit Amount, Current Usage, Status]`. Yellow at ≥80%, Red at 100%.

The newer Trusted Advisor API (Business+) returns the same data in a modern, paginated shape:

```console
$ aws trustedadvisor list-recommendations --region us-east-1 \
    --pillar security --status error \
    --query 'recommendationSummaries[].{name:name,status:status,src:source,resources:resourcesAggregates.errorCount}'
[
    {
        "name": "MFA on Root Account",
        "status": "error",
        "src": "ta_check",
        "resources": 1
    },
    {
        "name": "Amazon S3 Bucket Permissions",
        "status": "error",
        "src": "ta_check",
        "resources": 2
    }
]
```

### 10.4 AWS Health

```console
$ aws health describe-events --region us-east-1 \
    --filter 'eventTypeCategories=issue,eventStatusCodes=open,startTimes=[{from=2026-09-01T00:00:00Z}]' \
    --query 'events[].{svc:service,code:eventTypeCode,region:region,status:statusCode,start:startTime}'
[
    {
        "svc": "EC2",
        "code": "AWS_EC2_OPERATIONAL_ISSUE",
        "region": "us-east-1",
        "status": "open",
        "start": "2026-09-04T14:05:00-00:00"
    }
]
```

```console
$ aws health describe-affected-entities --region us-east-1 \
    --filter 'eventArns=arn:aws:health:us-east-1::event/EC2/AWS_EC2_OPERATIONAL_ISSUE/AWS_EC2_OPERATIONAL_ISSUE_7F3A9C2E' \
    --query 'entities[].{id:entityValue,status:statusCode}' --output table
-------------------------------------------------
|          DescribeAffectedEntities              |
+--------------------------+---------------------+
|            id            |       status        |
+--------------------------+---------------------+
|  i-0aa11bb22cc33dd44     |  IMPAIRED           |
|  i-0ee55ff66aa77bb88     |  IMPAIRED           |
|  i-0cc99dd00ee11ff22     |  IMPAIRED           |
+--------------------------+---------------------+
```

Organizational view, from the management account after enabling trusted access:

```console
$ aws health enable-health-service-access-for-organization --region us-east-1

$ aws health describe-health-service-status-for-organization --region us-east-1
{
    "healthServiceAccessStatusForOrganization": "ENABLED"
}

$ aws health describe-events-for-organization --region us-east-1 \
    --filter 'eventTypeCategories=scheduledChange' \
    --query 'events[].{code:eventTypeCode,svc:service,end:endTime}' --output table
--------------------------------------------------------------------------------
|                        DescribeEventsForOrganization                          |
+------------------------------------------------+---------+-------------------+
|                      code                      |   svc   |        end        |
+------------------------------------------------+---------+-------------------+
|  AWS_RDS_PLANNED_LIFECYCLE_EVENT               |  RDS    |  2026-10-15T06:00Z|
|  AWS_EC2_PERSISTENT_INSTANCE_RETIREMENT_...    |  EC2    |  2026-09-22T04:00Z|
+------------------------------------------------+---------+-------------------+

$ aws health describe-affected-accounts-for-organization --region us-east-1 \
    --event-arn arn:aws:health:global::event/RDS/AWS_RDS_PLANNED_LIFECYCLE_EVENT/AWS_RDS_PLANNED_LIFECYCLE_EVENT_B2C4D6E8
{
    "affectedAccounts": [
        "111122223333",
        "444455556666",
        "777788889999"
    ],
    "eventScopeCode": "ACCOUNT_SPECIFIC"
}
```

### 10.5 Service Quotas

```console
$ aws service-quotas get-service-quota \
    --service-code ec2 --quota-code L-1216C47A --region us-east-1
{
    "Quota": {
        "ServiceCode": "ec2",
        "ServiceName": "Amazon Elastic Compute Cloud (Amazon EC2)",
        "QuotaArn": "arn:aws:servicequotas:us-east-1:111122223333:ec2/L-1216C47A",
        "QuotaCode": "L-1216C47A",
        "QuotaName": "Running On-Demand Standard (A, C, D, H, I, M, R, T, Z) instances",
        "Value": 512.0,
        "Unit": "None",
        "Adjustable": true,
        "GlobalQuota": false,
        "UsageMetric": {
            "MetricNamespace": "AWS/Usage",
            "MetricName": "ResourceCount",
            "MetricDimensions": {
                "Class": "Standard/OnDemand",
                "Resource": "vCPU",
                "Service": "EC2",
                "Type": "Resource"
            },
            "MetricStatisticRecommendation": "Maximum"
        }
    }
}
```

`Adjustable: true` is the branch point. If it were `false`, the increase must go through a support case.

```console
$ aws service-quotas request-service-quota-increase \
    --service-code ec2 --quota-code L-1216C47A --desired-value 1024 --region us-east-1
{
    "RequestedQuota": {
        "Id": "a1b2c3d4e5f67890a1b2c3d4e5f67890",
        "CaseId": "9876543211",
        "ServiceCode": "ec2",
        "QuotaCode": "L-1216C47A",
        "DesiredValue": 1024.0,
        "Status": "PENDING",
        "Created": "2026-09-04T15:10:22.481000-03:00",
        "Requester": "{\"accountId\":\"111122223333\",\"callerArn\":\"arn:aws:sts::111122223333:assumed-role/platform-admin/dalmine\"}",
        "QuotaArn": "arn:aws:servicequotas:us-east-1:111122223333:ec2/L-1216C47A"
    }
}
```

Note `CaseId` — Service Quotas opens a Support case on your behalf. The request inherits your plan's response times.

```console
$ aws service-quotas list-requested-service-quota-change-history \
    --service-code ec2 --region us-east-1 \
    --query 'RequestedQuotas[].{q:QuotaName,want:DesiredValue,status:Status,case:CaseId}' --output table
---------------------------------------------------------------------------------
|              ListRequestedServiceQuotaChangeHistory                            |
+-----------------------------------------+---------+-----------+----------------+
|                    q                    |  want   |  status   |     case       |
+-----------------------------------------+---------+-----------+----------------+
|  Running On-Demand Standard instances   |  1024.0 |  PENDING  |  9876543211    |
|  VPCs per Region                        |  20.0   |  APPROVED |  9876543190    |
+-----------------------------------------+---------+-----------+----------------+
```

### 10.6 Support Automation Workflows (SSM runbooks)

Business+ unlocks the `AWSPremiumSupport-*` document family. These are AWS Support's own diagnostic runbooks, executable by you.

```console
$ aws ssm list-documents \
    --filters Key=Owner,Values=Amazon Key=Name,Values=AWSPremiumSupport \
    --query 'DocumentIdentifiers[].Name' --output text | tr '\t' '\n' | head -8
AWSPremiumSupport-DDoSResiliencyAssessment
AWSPremiumSupport-DiagnoseEC2Connectivity
AWSPremiumSupport-ManageRDSPerformanceInsights
AWSPremiumSupport-TroubleshootEKSCluster
AWSPremiumSupport-TroubleshootRDSIOPS
AWSPremiumSupport-TroubleshootS3PublicRead
```

```console
$ aws ssm start-automation-execution \
    --document-name AWSSupport-TroubleshootConnectivityToRDS \
    --parameters 'SourceType=EC2Instance,SourceIdentifier=i-0aa11bb22cc33dd44,DestinationIdentifier=prod-ledger-db'
{
    "AutomationExecutionId": "5f8e2a11-9b3c-4d7e-8a01-2c4b6d8e0f13"
}

$ aws ssm get-automation-execution \
    --automation-execution-id 5f8e2a11-9b3c-4d7e-8a01-2c4b6d8e0f13 \
    --query 'AutomationExecution.{status:AutomationExecutionStatus,out:Outputs}'
{
    "status": "Success",
    "out": {
        "evaluateSecurityGroups.Result": [
            "FAIL: sg-0f1e2d3c4b5a69788 attached to prod-ledger-db does not allow inbound tcp/5432 from sg-0987654321fedcba0"
        ]
    }
}
```

---

## 11. Verification and failure diagnosis

### 11.1 Decision table for the common errors

| Symptom | Root cause | Verification | Fix |
|---|---|---|---|
| `SubscriptionRequiredException` on any `support:*` or `health:Describe*` call | Account is on Basic or Developer | `aws support describe-services --region us-east-1` — same error | Upgrade to Business+; there is no IAM workaround |
| `Could not connect to the endpoint URL: "https://support.sa-east-1.amazonaws.com/"` | Support API is **us-east-1 only** | `aws support describe-services` with and without `--region us-east-1` | Always pass `--region us-east-1`, or set `AWS_REGION=us-east-1` for support tooling |
| `AccessDeniedException: User ... is not authorized to perform: support:CreateCase on resource: *` | IAM policy scoped the resource | `aws iam simulate-principal-policy --action-names support:CreateCase` | Support has **no resource-level permissions** — `Resource: "*"` is mandatory; constrain with conditions/principal instead |
| `InvalidParameterValueException` on `--severity-code critical` | `critical` requires Enterprise/On-Ramp | `aws support describe-severity-levels` | Discover severities at runtime; never hard-code |
| Trusted Advisor checks all `not_available` | `AWSServiceRoleForTrustedAdvisor` SLR deleted or denied by an SCP | `aws iam get-role --role-name AWSServiceRoleForTrustedAdvisor` | Recreate the SLR; audit SCPs for `iam:CreateServiceLinkedRole` denials |
| Trusted Advisor result timestamp is days old despite refreshing | Refresh cooldown not respected | `describe-trusted-advisor-check-refresh-statuses` → `millisUntilNextRefreshable > 0` | Gate refreshes on the cooldown value (see §9.1) |
| `NoSuchResourceException` from `request-service-quota-increase` | Quota is not adjustable through Service Quotas | `get-service-quota` → `"Adjustable": false` | Open a support case with `issueType=service-limit-increase` |
| `describe-cases` returns nothing for a case you know exists | Default window is **30 days**, and resolved cases are excluded | Add `--include-resolved --after-time 2026-01-01T00:00:00Z` | Always pass an explicit `--after-time` in reporting jobs |
| `SERVICE_QUOTA()` alarm shows `INSUFFICIENT_DATA` | The quota has no `UsageMetric`, or usage is genuinely zero | `get-service-quota --query 'Quota.UsageMetric'` returns `null` | Not all quotas publish to `AWS/Usage`; fall back to the Trusted Advisor Service Limits check |
| Org-wide `describe-events-for-organization` returns empty | Trusted access not enabled, or called from a member account | `aws health describe-health-service-status-for-organization` | `enable-health-service-access-for-organization` **from the management account**; allow propagation time |
| CloudFormation: `Template format error: ... ZipFile ... exceeds 4096 characters` | Inline Lambda source too long | `wc -c` on the extracted code block | Move to an S3-backed `Code.S3Bucket`/`S3Key` or a container image |
| Health events arrive in EventBridge but the org bus is empty | Member accounts have no forwarding rule to the central bus | Check for a rule with the central bus as target in the member account | Deploy the forwarding rule via StackSets to every member |

### 11.2 A preflight script

Run this before you rely on any support automation. It fails loudly rather than degrading silently.

```bash
#!/usr/bin/env bash
# preflight-support-plane.sh — verify the support control plane is usable.
set -euo pipefail

export AWS_REGION=us-east-1
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
echo "account: ${ACCOUNT}"

fail() { echo "FAIL: $*" >&2; exit 1; }

# 1. Support API reachable and plan sufficient.
if ! SEV=$(aws support describe-severity-levels --language en \
             --query 'severityLevels[].code' --output text 2>/dev/null); then
  fail "support API unavailable — account is on Basic or Developer"
fi
echo "severities: ${SEV}"
case "${SEV}" in
  *critical*) PLAN="enterprise|enterprise-onramp" ;;
  *urgent*)   PLAN="business" ;;
  *)          fail "unexpected severity set: ${SEV}" ;;
esac
echo "plan: ${PLAN}"

# 2. Health API reachable.
aws health describe-event-aggregates \
    --aggregate-field eventTypeCategory \
    --query 'eventAggregates' --output json >/dev/null \
  || fail "health API unavailable"
echo "health API: ok"

# 3. Full Trusted Advisor check set present.
N=$(aws support describe-trusted-advisor-checks --language en \
      --query 'length(checks)' --output text)
[ "${N}" -gt 50 ] || fail "only ${N} Trusted Advisor checks visible — core set only"
echo "trusted advisor checks: ${N}"

# 4. Service Limits check is not red.
ST=$(aws support describe-trusted-advisor-check-result \
       --check-id eW7HH0l7J9 --language en \
       --query 'result.status' --output text)
echo "service limits check: ${ST}"
[ "${ST}" != "error" ] || echo "WARN: a service quota is at 100%"

# 5. Service-linked roles present.
for ROLE in AWSServiceRoleForTrustedAdvisor AWSServiceRoleForSupport; do
  aws iam get-role --role-name "${ROLE}" >/dev/null 2>&1 \
    || fail "missing service-linked role ${ROLE}"
  echo "SLR ${ROLE}: ok"
done

echo "PASS: support control plane is operational"
```

```console
$ ./preflight-support-plane.sh
account: 111122223333
severities: low     normal  high    urgent  critical
plan: enterprise|enterprise-onramp
health API: ok
trusted advisor checks: 234
service limits check: warning
SLR AWSServiceRoleForTrustedAdvisor: ok
SLR AWSServiceRoleForSupport: ok
PASS: support control plane is operational
```

On a Developer-plan account:

```console
$ ./preflight-support-plane.sh
account: 555566667777
FAIL: support API unavailable — account is on Basic or Developer
```

### 11.3 Verifying the EventBridge path without waiting for a real outage

Health events cannot be injected — `aws.health` is a locked AWS source. Test the *downstream* half by publishing a synthetic event on a custom source and temporarily widening the rule pattern:

```console
$ aws events put-events --entries '[{
    "Source": "test.health",
    "DetailType": "AWS Health Event",
    "Detail": "{\"service\":\"EC2\",\"eventTypeCategory\":\"issue\",\"eventTypeCode\":\"SYNTHETIC_TEST\",\"eventRegion\":\"us-east-1\",\"eventDescription\":[{\"latestDescription\":\"synthetic drill\"}],\"affectedEntities\":[]}"
  }]'
{
    "FailedEntryCount": 0,
    "Entries": [
        { "EventId": "d3b07384-d9a0-4c9b-9c1e-7a5f2e8b4c06" }
    ]
}
```

Then confirm the target actually fired, rather than trusting the `FailedEntryCount`:

```console
$ aws cloudwatch get-metric-statistics \
    --namespace AWS/Events --metric-name TriggeredRules \
    --dimensions Name=RuleName,Value=aws-health-issue-to-case \
    --start-time "$(date -u -d '15 minutes ago' +%FT%TZ)" \
    --end-time "$(date -u +%FT%TZ)" \
    --period 300 --statistics Sum \
    --query 'Datapoints[].Sum'
[
    1.0
]
```

`FailedEntryCount: 0` means EventBridge accepted the event, **not** that a rule matched it. `TriggeredRules` and the target's `Invocations`/`FailedInvocations` are the real evidence. Restore the production event pattern immediately after the drill.

### 11.4 The silent failures worth alarming on

| Failure | Why it is silent | Detection |
|---|---|---|
| Trusted Advisor SLR deleted | Checks report `not_available`, dashboards show green-ish emptiness | Alarm on `Custom/TrustedAdvisor` metric *absence* (`TreatMissingData: breaching`, as in §9.1) |
| Support plan downgraded at renewal | Automation starts throwing `SubscriptionRequiredException` into logs nobody reads | Run the §11.2 preflight on a schedule; alarm on Lambda `Errors` |
| EventBridge rule disabled during unrelated work | No events, no errors | Alarm on `TriggeredRules` `Sum < 1` over a long period, or use AWS Config rule for rule state |
| Quota template silently not applied to a new account | The account launches, hits the default quota under load | Assert applied quotas against `list-aws-default-service-quotas` in account-baseline CI |
| Case auto-opened at the wrong severity | Response arrives 4 hours late instead of 15 minutes | Log the resolved severity from `allowed_severity()` and alarm when it differs from the requested one |

---

## 12. Exam-facing distinctions

These are the pairs the CLF-C02 item writers use.

| Confusion | Resolution |
|---|---|
| AWS Health Dashboard vs AWS Health API | Dashboard (both views) is free on every plan; the **API** requires Business+ |
| *Service health* vs *Your account health* | Service health is public and global; account health is personalised to your resources |
| Trusted Advisor core checks vs full checks | Basic/Developer get core (service limits + a security subset); Business+ get all six categories |
| Trusted Advisor vs Trusted Advisor Priority | Priority adds TAM-curated, ranked, lifecycle-tracked recommendations and is **Enterprise only** |
| Trusted Advisor vs AWS Config | Trusted Advisor = AWS-authored best-practice checks; Config = your own rules + configuration history |
| Trusted Advisor vs Well-Architected Tool | Trusted Advisor is automated and continuous; WA Tool is a human self-assessment producing an improvement plan |
| Concierge vs TAM | Concierge = **billing/account** experts; TAM = **technical** advisor. Both start at Enterprise On-Ramp |
| Enterprise On-Ramp vs Enterprise | 30 min vs **15 min** business-critical; **pool of TAMs** vs **designated TAM**; Priority and IDR are Enterprise only |
| AWS Support vs AWS Managed Services | Support advises; AMS **operates** your infrastructure and requires Enterprise Support |
| AWS ProServe vs APN Partner vs AWS IQ | AWS's own consultants vs a partner company vs an individual certified freelancer (US) |
| AWS Countdown vs IDR | Countdown = engineered support for a **planned event**; IDR = continuous monitoring with 5-minute engagement on **unplanned** critical incidents |
| Service Quotas vs Trusted Advisor Service Limits | Service Quotas is the system of record and the change mechanism; Trusted Advisor is the 80% *warning* built on top of it |
| re:Post vs Support case | re:Post is free community Q&A with no SLA; a case is a contracted response target |
| Abuse team vs Support | Report abuse **originating from AWS** to Trust & Safety, not through a technical support case |
| Developer plan contacts | Exactly **one** primary contact may open cases; Business+ is unlimited and IAM-governed |

Two numbers worth memorising outright: **Business = 1 hour** for "production system down"; **Enterprise = 15 minutes** for "business-critical system down". Everything else can be derived from the table in §3.2.

---

## Referencias

**Exam and certification**
- AWS Certified Cloud Practitioner (CLF-C02) Exam Guide — https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf
- AWS Certified Cloud Practitioner — https://aws.amazon.com/certification/certified-cloud-practitioner/
- AWS Skill Builder — https://skillbuilder.aws/

**AWS Support**
- AWS Support plans comparison — https://aws.amazon.com/premiumsupport/plans/
- AWS Support pricing — https://aws.amazon.com/premiumsupport/pricing/
- AWS Support User Guide — https://docs.aws.amazon.com/awssupport/latest/user/what-is-aws-support.html
- Case severity and response times — https://docs.aws.amazon.com/awssupport/latest/user/case-management.html#choosing-severity
- AWS Support API Reference — https://docs.aws.amazon.com/awssupport/latest/APIReference/Welcome.html
- `aws support` CLI reference — https://docs.aws.amazon.com/cli/latest/reference/support/
- AWS Support App in Slack — https://docs.aws.amazon.com/awssupport/latest/user/aws-support-app-for-slack.html
- Support Automation Workflows (SSM runbooks) — https://docs.aws.amazon.com/systems-manager-automation-runbooks/latest/userguide/automation-awssupport.html

**Trusted Advisor**
- AWS Trusted Advisor — https://aws.amazon.com/premiumsupport/technology/trusted-advisor/
- Trusted Advisor check reference — https://docs.aws.amazon.com/awssupport/latest/user/trusted-advisor-check-reference.html
- Trusted Advisor Priority — https://docs.aws.amazon.com/awssupport/latest/user/trustedadvisor-priority.html
- Trusted Advisor API Reference — https://docs.aws.amazon.com/trustedadvisor/latest/APIReference/Welcome.html

**AWS Health**
- AWS Health User Guide — https://docs.aws.amazon.com/health/latest/ug/what-is-aws-health.html
- AWS Health Dashboard (public service health) — https://health.aws.amazon.com/health/status
- AWS Health API Reference — https://docs.aws.amazon.com/health/latest/APIReference/Welcome.html
- Monitoring AWS Health events with EventBridge — https://docs.aws.amazon.com/health/latest/ug/cloudwatch-events-health.html
- Aggregating AWS Health across an organization — https://docs.aws.amazon.com/health/latest/ug/aggregate-events.html

**Service Quotas**
- Service Quotas User Guide — https://docs.aws.amazon.com/servicequotas/latest/userguide/intro.html
- AWS service quotas (per-service reference) — https://docs.aws.amazon.com/general/latest/gr/aws_service_limits.html
- Quota request templates for Organizations — https://docs.aws.amazon.com/servicequotas/latest/userguide/organization-templates.html
- CloudWatch metric math `SERVICE_QUOTA()` — https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/using-metric-math.html

**Proactive and professional programs**
- AWS Incident Detection and Response — https://docs.aws.amazon.com/awssupport/latest/user/incident-detection-and-response.html
- AWS Countdown — https://docs.aws.amazon.com/awssupport/latest/user/aws-countdown.html
- AWS Managed Services (AMS) — https://docs.aws.amazon.com/managedservices/latest/userguide/what-is-ams.html
- AWS Professional Services — https://aws.amazon.com/professional-services/
- AWS Partner Network — https://aws.amazon.com/partners/
- AWS IQ — https://aws.amazon.com/iq/
- AWS Marketplace — https://aws.amazon.com/marketplace/

**Technical resources**
- AWS Documentation — https://docs.aws.amazon.com/
- AWS Whitepapers & Guides — https://aws.amazon.com/whitepapers/
- AWS Architecture Center — https://aws.amazon.com/architecture/
- AWS Prescriptive Guidance — https://aws.amazon.com/prescriptive-guidance/
- AWS Solutions Library — https://aws.amazon.com/solutions/
- AWS Well-Architected Framework — https://docs.aws.amazon.com/wellarchitected/latest/framework/welcome.html
- AWS Well-Architected Tool — https://docs.aws.amazon.com/wellarchitected/latest/userguide/intro.html
- AWS re:Post — https://repost.aws/
- AWS re:Post Knowledge Center — https://repost.aws/knowledge-center
- AWS Blogs — https://aws.amazon.com/blogs/
- AWS Artifact — https://docs.aws.amazon.com/artifact/latest/ug/what-is-aws-artifact.html
- AWS Security Bulletins — https://aws.amazon.com/security/security-bulletins/
- Report AWS abuse — https://support.aws.amazon.com/#/contacts/report-abuse