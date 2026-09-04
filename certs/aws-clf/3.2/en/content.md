# 3.2 — Define the AWS Global Infrastructure

**Certification:** AWS Certified Cloud Practitioner (CLF-C02) · **Domain 3:** Cloud Technology and Services · **Task 3.2** · **Domain weight:** 4.25

> **How to read this module.** CLF-C02 tests this task at a definitional level — "what is an Availability Zone", "when do you use an Edge location". That is the floor, not the ceiling. This module teaches the topology the way a Platform Architect has to hold it: as a **failure-domain model** that determines your blast radius, your RTO/RPO, your data-transfer bill, and where your control-plane dependencies live. Section 10 distills the exam-answerable facts if you only have twenty minutes.

---

## 1. The production problem: failure domains are a design input, not a footnote

Every distributed system has a *correlated failure* problem. Two replicas only give you redundancy if they do not share a fate — the same power feed, the same top-of-rack switch, the same building, the same fiber path, the same control plane, the same deployment pipeline. Redundancy that shares fate is not redundancy; it is a more expensive single point of failure.

The AWS global infrastructure exists to give you **named, contractual failure domains** so you can reason about fate-sharing without owning the buildings. When AWS says "Availability Zone", it is making a specific promise about independent power, cooling, and physical separation. When it says "Region", it is making a much stronger promise about operational isolation. Your job is to place workload components into those domains deliberately.

Consider three real incident shapes that this module is designed to prevent:

**Incident shape A — the invisible single AZ.** A team runs an Auto Scaling group with `min=3`, feels safe, and discovers during an AZ impairment that all three instances were in `us-east-1a` because the ASG was created with a single subnet. The `DesiredCapacity` was met; the availability was not. Redundancy count was never the property that mattered — *placement diversity* was.

**Incident shape B — the cross-account AZ name.** Account A shares a subnet in `us-east-1a` with Account B via AWS Resource Access Manager. Account B launches its consumer fleet in *its* `us-east-1a`, expecting co-location, and every request now crosses an AZ boundary — adding latency, adding `$0.01/GB` in each direction, and creating a correlated failure the architecture diagram does not show. AZ **names** are randomized per account; AZ **IDs** are not. This is the single most commonly missed fact in the entire domain.

**Incident shape C — the control-plane dependency during failover.** A "multi-Region active/passive" design fails over by calling `CreateAutoScalingGroup` and `UpdateDistribution` in the standby Region — during the exact event in which control planes are degraded. The failover plan depended on the thing that was broken. The fix is **static stability**: pre-provision the standby capacity and change only data-plane state (a DNS record, a Global Accelerator traffic dial, a routing control).

All three are topology errors, not code errors. That is why this task carries weight in an exam aimed at people who are not yet writing the code.

---

## 2. The hierarchy, precisely

```
AWS Partition                       (aws | aws-cn | aws-us-gov | isolated partitions)
 └── Region                         (us-east-1, eu-central-1, sa-east-1, …)
      ├── Availability Zone         (name: us-east-1a  |  ID: use1-az4)
      │    └── one or more discrete data centers
      │         └── redundant power, cooling, networking
      ├── Local Zone                (us-west-2-lax-1a — metro extension of the Region)
      └── Wavelength Zone           (us-east-1-wl1-bos-wlz-1 — inside a carrier 5G network)

Attached to, but not inside, a Region:
      ├── AWS Outposts              (AWS-managed rack/server on your premises, anchored to a home Region)
      └── AWS Edge network          (CloudFront PoPs, Regional Edge Caches, Global Accelerator
                                     ingress, Route 53 anycast, Direct Connect locations)
```

Read that tree as a **fate-sharing gradient**: two data centers in one AZ share more fate than two AZs in one Region, which share more fate than two Regions, which share more fate than two partitions. Cost and complexity climb the same gradient. The architecture question is always *which correlated failure am I buying insurance against, and what is the premium?*

### 2.1 Partitions and why the ARN starts with one

A **partition** is the largest isolation boundary AWS publishes. Accounts, IAM principals, and the global namespace do not cross partitions. You cannot assume a role in `aws-us-gov` from an account in `aws`. This shows up syntactically in every Amazon Resource Name:

```
arn:partition:service:region:account-id:resource-type/resource-id
    ^^^^^^^^^
arn:aws:s3:::static-assets-prod
arn:aws:iam::123456789012:role/PlatformDeployer
arn:aws:ec2:eu-central-1:123456789012:subnet/subnet-0a1b2c3d4e5f67890
arn:aws-cn:s3:::static-assets-prod-cn
arn:aws-us-gov:iam::123456789012:role/PlatformDeployer
```

| Partition | Regions | Account model | Notes |
|---|---|---|---|
| `aws` | Commercial Regions worldwide | Standard AWS account | The default; everything in this module unless stated |
| `aws-cn` | `cn-north-1` (Beijing), `cn-northwest-1` (Ningxia) | Separate account, operated by Sinnet / NWCD | Separate console, separate credentials, ICP filing required for public sites |
| `aws-us-gov` | `us-gov-west-1`, `us-gov-east-1` | Separate GovCloud account, sponsored by a commercial account | ITAR / FedRAMP High workloads; vetted US-person operators |

**Practical consequence for IaC:** any IAM policy or CDK/Terraform module you intend to be portable must never hardcode `arn:aws:`. Use `arn:${AWS::Partition}:` in CloudFormation, `data.aws_partition.current.partition` in Terraform, or a wildcard `arn:*:` where the policy semantics allow.

### 2.2 Regions

A Region is a **separate geographic area containing multiple, isolated Availability Zones**. AWS designs Regions to be operationally independent: a Region-wide event should not propagate. Regions are the boundary for:

- **Data residency.** Your data stays in the Region you put it in unless *you* configure replication. This is the mechanism behind GDPR/data-sovereignty answers.
- **Service quotas.** Limits are per-account, per-Region. A quota increase in `eu-west-1` does nothing for `eu-west-2`.
- **Service availability.** Not every service exists in every Region, and new services usually launch in a subset first.
- **Pricing.** Per-hour and per-GB prices differ by Region — sometimes by 30–60% for the same instance family.
- **Most APIs.** Regional endpoints look like `https://ec2.eu-central-1.amazonaws.com`.

New Regions launch with **at least three Availability Zones**, because three is the minimum for quorum-based systems to tolerate one loss while retaining a majority.

**Region types by activation state:**

| Type | Examples | Behavior |
|---|---|---|
| Enabled by default | `us-east-1`, `us-west-2`, `eu-west-1`, `ap-southeast-2`, … | Usable immediately in every account |
| Opt-in | `af-south-1`, `ap-east-1`, `eu-south-1`, `me-central-1`, `il-central-1`, `ca-west-1`, … | Must be explicitly enabled per account; disabled by default so IAM credentials are not valid there |
| Separate partition | `cn-*`, `us-gov-*` | Requires a different account entirely |

Opt-in Regions exist because enabling a Region expands your IAM blast radius: credentials that leak become usable in one more place. Keeping unused Regions disabled is a legitimate security control, and it is enforceable at the Organization level with SCPs and the Account Management API.

> The published count of Regions, AZs, Local Zones and edge PoPs changes several times a year. Do not memorize the number — memorize where it is published (see §11) and how to query it (see §7.1).

### 2.3 Availability Zones — the part that is actually subtle

An Availability Zone is **one or more discrete data centers with redundant power, networking, and connectivity within a Region**. AWS's published design properties:

- AZs are **physically separated by a meaningful distance** — many kilometers — and located in different floodplains, on different power grids where feasible, with independent utility feeds and backup generation.
- Separation is nonetheless bounded (AWS documents "within 100 km / 60 miles") so that **inter-AZ latency stays low enough for synchronous replication**. This is the whole point: far enough apart to not share a disaster, close enough to run a synchronous quorum.
- All inter-AZ traffic within a Region traverses **redundant, high-bandwidth, low-latency AWS-owned fiber**, and is **encrypted in transit at the physical layer**.

That latency budget is why the default posture for production is **Multi-AZ, single-Region**: you get real fault isolation while still being able to run RDS Multi-AZ synchronous commit, an etcd/ZooKeeper quorum, or a Kafka `min.insync.replicas=2` cluster without redesigning consistency.

#### AZ names are per-account aliases. AZ IDs are physical.

AWS maps AZ **names** (`us-east-1a`) to physical AZs **independently per account**, to prevent everyone from piling into "the first one". The **AZ ID** (`use1-az4`) is the stable, account-independent identifier for the physical zone.

| Property | AZ name (`us-east-1a`) | AZ ID (`use1-az4`) |
|---|---|---|
| Consistent across accounts | ❌ No | ✅ Yes |
| Stable over time within one account | ✅ Yes | ✅ Yes |
| Shown in most console screens | ✅ Yes | Sometimes, in parentheses |
| Used by AWS RAM shared subnets | Displayed as the consumer's own name | ✅ The authoritative field |
| What you must use for cross-account co-location | ❌ | ✅ |
| What you must use to correlate a Health Dashboard event | ❌ | ✅ |
| What you must use for `arc-zonal-shift` | ❌ | ✅ |

Any time two AWS accounts must agree on *where* something physically is — shared VPC subnets, PrivateLink endpoint placement, cross-account cost attribution, a coordinated evacuation — the contract is the AZ ID.

### 2.4 Extending the Region: Local Zones, Wavelength, Outposts

These three exist for the same reason: some workloads cannot tolerate the physics of distance to the nearest Region, or cannot legally leave a building.

| | **Local Zone** | **Wavelength Zone** | **Outposts** |
|---|---|---|---|
| What it is | AWS-owned infrastructure in a metro area, an extension of a parent Region | AWS compute/storage embedded inside a telecom provider's 5G network | AWS-designed rack (42U) or server (1U/2U) installed in *your* data center |
| Naming | `us-west-2-lax-1a` | `us-east-1-wl1-bos-wlz-1` | Not an AZ; anchored to a home Region + AZ |
| Latency target | Single-digit ms to the metro | Single-digit ms to 5G devices, traffic never leaves the carrier network | LAN latency to your on-prem systems |
| Reached via | Extend a Region VPC with a subnet in the Local Zone | Carrier gateway (`carrier-gateway`), not an IGW | Local gateway (`local-gateway`) + service link to the home Region |
| Service catalog | Small subset (EC2, EBS, some ELB/ECS/EKS nodes) | Very small subset (EC2, EBS, EKS/ECS nodes) | Subset; some services are Outpost-native, most are not |
| Activation | Per-account opt-in of the AZ **group** | Per-account opt-in of the AZ group | Order hardware; AWS installs and manages it |
| Resilience posture | **Usually a single zone — not inherently HA.** Treat as one failure domain | Single zone | Single site; you own the building's power/cooling fate |
| Typical use | Real-time media rendering, low-latency gaming, financial trading co-location, on-prem migration staging | AR/VR on mobile, connected vehicles, industrial IoT on private 5G | Data residency in a country with no Region, regulated on-prem processing, legacy systems with a hard latency coupling |

**The trade-off to internalize:** each of these buys latency or residency by *giving up* AZ-level redundancy and most of the service catalog. A Local Zone is not "a cheap extra AZ". If you put your only database in `us-west-2-lax-1a`, you have built a single-zone system with a Region-sized bill.

**The control plane always stays in the parent Region.** Outposts, Local Zones, and Wavelength Zones are *data plane* extensions. If the service link from an Outpost to its home Region is severed, running instances keep running and local traffic keeps flowing, but you cannot launch, terminate, or reconfigure. Design your on-Outpost runbooks assuming the API is unavailable.

### 2.5 The edge network — a different axis entirely

Regions and AZs are about *where your workload runs*. The edge is about *where your users enter the AWS network*. It is a separate, much denser layer with hundreds of Points of Presence in far more cities than there are Regions.

| Edge component | What it does | The mechanism | When to reach for it |
|---|---|---|---|
| **CloudFront edge locations (PoPs)** | Cache and serve HTTP(S) content close to users; terminate TLS at the edge | Caching + shortest-path ingress to the AWS backbone | Static assets, video, whole-site acceleration, API acceleration |
| **CloudFront Regional Edge Caches** | Mid-tier caches sitting between PoPs and your origin | Absorbs misses from many PoPs so the origin sees far fewer requests | Automatic; the reason a low-popularity long tail still gets good hit rates |
| **AWS Global Accelerator** | Two **static anycast IPs** that pull TCP/UDP traffic onto the AWS backbone at the nearest edge | Anycast BGP + health-checked endpoint groups + traffic dials | Non-HTTP protocols, gaming/UDP, IP allowlisting requirements, fast multi-Region failover |
| **Amazon Route 53** | Authoritative DNS on a global anycast fleet | 100% availability SLA; latency/geolocation/geoproximity/failover routing | Any DNS-based traffic steering |
| **AWS Direct Connect locations** | Physical cross-connects into the AWS network | Private fiber into an AWS-adjacent colocation facility | Predictable bandwidth/latency from on-prem; regulated data paths |
| **AWS WAF / Shield / Lambda@Edge / CloudFront Functions** | Security and compute executed at the PoP | Runs before the request reaches your origin | Bot mitigation, header rewriting, A/B routing, auth at the edge |

**CloudFront vs. Global Accelerator** is the comparison that gets asked in interviews and confused in practice:

| Dimension | CloudFront | Global Accelerator |
|---|---|---|
| Protocols | HTTP/HTTPS (and WebSocket) | Any TCP or UDP |
| Caching | Yes — that is the primary value | **No.** It is a network path optimizer, never a cache |
| Client-facing address | A distribution DNS name (`d111111abcdef8.cloudfront.net`) | Two static anycast IPv4 addresses (+ optional BYOIP, dual-stack) |
| Failover trigger | Origin group failover on origin error codes | Endpoint health checks; automatic anycast withdrawal |
| Failover speed | Seconds, per-request | Typically under a minute, and **DNS-cache-independent** — the IP does not change |
| Multi-Region steering control | Origin groups / Lambda@Edge | `TrafficDialPercentage` and endpoint weights — a data-plane API call |
| Best fit | Content and web APIs | Gaming, VoIP, IoT, MQTT, financial protocols, "our enterprise customers allowlist IPs" |

The Global Accelerator property that matters most for disaster recovery: because the client-facing IPs never change, **failover does not depend on DNS TTLs or on a client's DNS resolver behavior**. Java applications with an infinite JVM DNS cache, embedded devices that resolve once at boot, and corporate resolvers that ignore TTLs all fail over correctly. That is worth real money in a regulated or IoT context.

---

## 3. Choosing a Region: a four-factor decision, in order

The exam phrases this as "factors that influence Region selection". In production it is a decision record you will be asked to defend. Evaluate in this order, because the first two are constraints and the second two are optimizations:

| # | Factor | The question to answer | How to check it | Hard or soft? |
|---|---|---|---|---|
| 1 | **Compliance / data sovereignty** | Is this data legally permitted to be stored or processed here? Does a regulator require a specific jurisdiction? | Legal/DPO review; AWS Artifact for attestations; contractual data-residency terms | **Hard.** Non-negotiable, evaluated first |
| 2 | **Service availability** | Do *all* the services this workload needs exist in this Region, at the required feature level? | SSM global-infrastructure parameters (§7.1); the Regional Services List | **Hard.** One missing service can invalidate the whole choice |
| 3 | **Latency / proximity to users** | What is the p99 RTT from where the users actually are? | CloudWatch Internet Monitor; real-user measurement; public latency probes | Soft, but user-visible |
| 4 | **Cost** | What do compute, storage, and *egress* cost here versus the alternative? | AWS Pricing Calculator; the per-service pricing pages | Soft, but compounding |

Two secondary factors that experienced architects add:

5. **Carbon intensity / sustainability** — AWS publishes the customer carbon footprint tool, and some Regions run on a substantially cleaner grid mix. For some organizations this is now a reporting requirement, not a preference.
6. **Operational maturity and blast-radius correlation** — `us-east-1` is the largest and oldest Region and hosts the control-plane home of several global services. It is heavily used by everyone, which makes it both the best-supported Region and the one whose events have the widest industry-wide correlation. If you are building the *disaster recovery* Region for a workload, deliberately not choosing `us-east-1` is defensible.

### 3.1 The `us-east-1` gravity well — global services and where their control planes live

"Global" service does not mean "no Region". It means the *namespace* is global while the control plane is homed somewhere — almost always `us-east-1`. This is a first-class production hazard and a recurring exam distractor.

| Service | Scope of the resource | Where you must call the API / place the dependency |
|---|---|---|
| IAM (users, roles, policies) | Global (per partition) | `iam.amazonaws.com` → `us-east-1` |
| AWS Organizations | Global | `us-east-1` |
| Amazon Route 53 (hosted zones, records) | Global | `us-east-1` |
| Amazon CloudFront (distributions) | Global | `us-east-1` |
| AWS WAF for CloudFront | Global | `--scope CLOUDFRONT --region us-east-1` |
| AWS Shield Advanced | Global | `us-east-1` |
| ACM certificate **for CloudFront** | Must be issued in | **`us-east-1`, always** |
| ACM certificate **for an ALB/NLB/API Gateway** | Must be issued in | **The same Region as the load balancer** |
| Amazon S3 bucket **names** | Globally unique within a partition | Bucket *data* is regional |
| AWS Billing / Cost Explorer | Global | `us-east-1` |
| AWS STS | Has both a global and regional endpoints | **Prefer regional** — see below |

**The STS lesson.** The legacy global endpoint `sts.amazonaws.com` is served out of `us-east-1`. If your workload in `ap-southeast-2` calls it to assume a role, you have created a synchronous dependency on a Region you do not run in, added ~200 ms to every credential refresh, and coupled your availability to a place you never chose. Use regional STS endpoints:

```bash
export AWS_STS_REGIONAL_ENDPOINTS=regional
# or in ~/.aws/config
#   sts_regional_endpoints = regional
```
Modern SDK versions default to `regional`, but pinned/legacy SDKs and old container images frequently do not. Auditing this is a cheap, high-value resilience win.

---

## 4. Global vs Regional vs Zonal: classify every resource you own

Before you can reason about blast radius, you must know the scope of each resource. Mis-scoping is where the "we thought we were highly available" incidents come from.

| Scope | Meaning | Examples | Failure impact |
|---|---|---|---|
| **Zonal** | Exists in exactly one AZ. Cannot be moved, only recreated. | EC2 instance, **EBS volume**, EFS mount target, RDS instance (a single node), subnet, NAT Gateway, ElastiCache node | AZ event → resource unavailable. Must be replicated by *you* or by a Multi-AZ service |
| **Regional** | Spans the AZs of one Region; AWS handles the intra-Region redundancy | S3 bucket (in a Regional bucket), DynamoDB table, SQS queue, Lambda function, ECS/EKS **control plane**, ALB/NLB (as a service; nodes are zonal), Aurora cluster, KMS key | AZ event → usually transparent. Region event → unavailable |
| **Global** | One namespace across the whole partition | IAM, Route 53 hosted zones, CloudFront distributions, Organizations, WAF (CloudFront scope) | Highest availability; but the *control plane* has a Region home (§3.1) |

**The most consequential zonal resource is EBS.** An EBS volume lives in one AZ and can only attach to an instance in that same AZ. Every "our stateful workload didn't come back in the other AZ" incident traces to this. The correct answers are: snapshot to S3 (Regional) and restore into the new AZ, use EFS or FSx (Regional, multi-AZ mount targets), use a Regional database service, or run application-level replication.

### 4.1 Blast radius, formally

| Scope of failure | What is affected | Mitigation | Typical cost multiplier |
|---|---|---|---|
| Single instance / host | One node | Auto Scaling group, health checks, N+1 capacity | ~1.1× |
| Single **Availability Zone** | Everything zonal in that AZ | Multi-AZ: ≥3 AZs, ASG across subnets, Multi-AZ RDS, cross-zone ELB | ~1.3–1.5× |
| Single **Region** | Everything in the Region | Multi-Region: replicate data + pre-provision compute + global traffic steering | ~1.8–2.2× |
| Bad deployment / bad config | Every Region simultaneously | **This is not a topology problem.** Staged deploys, cell-based architecture, canaries, automatic rollback | Process cost |
| Account compromise | Everything in the account | Multi-account (Organizations), SCPs, disabled unused Regions | Process cost |

That fourth row is the one architects under-weight. Multi-Region protects you from AWS's bad day; it does nothing about *your* bad deploy, which is statistically far more likely. Spending 2× on Region redundancy while pushing one global deployment with no canary is optimizing the wrong risk.

---

## 5. The cost model of your topology

Topology decisions show up on the bill as data transfer. These are list prices in the `aws` partition at the time of writing — **verify against the current pricing pages before quoting them**, they change.

| Traffic path | Typical charge | Notes |
|---|---|---|
| Within one AZ, using **private** IPv4 addresses | **Free** | The reason single-AZ chatty services are cheap |
| Within one AZ, using **public** IPv4 or Elastic IPs | Charged as cross-AZ | Silently expensive; a classic misconfiguration |
| **Between AZs** in the same Region | ~$0.01/GB **in each direction** (≈$0.02/GB round trip) | The dominant hidden cost in microservice meshes |
| Between Regions | ~$0.02/GB and up, varies by source Region | Cross-Region replication, global tables, Aurora Global DB |
| Out to the internet | Tiered from ~$0.09/GB, with a monthly free allowance | Serving from CloudFront is usually cheaper than from an origin |
| Into AWS from the internet | **Free** | Ingress is not billed |
| Via a **Gateway VPC Endpoint** (S3, DynamoDB) | **Free**, no hourly charge | Always create these |
| Via an **Interface VPC Endpoint** (PrivateLink) | Hourly per-AZ ENI charge + per-GB | Cheaper than NAT for high volume, but not free |
| Via a **NAT Gateway** | Hourly per NAT + ~$0.045/GB processed | Stacks *on top of* the egress charge |

Three architectural consequences:

1. **One NAT Gateway per AZ, or one shared?** One shared NAT is cheaper on the hourly line but makes every other AZ's egress a cross-AZ flow *and* makes the NAT's AZ a single point of failure for all outbound traffic. The correct production default is **one NAT Gateway per AZ**, with each private subnet routing to the NAT in its own AZ. The §6.1 template does exactly this.
2. **Gateway endpoints for S3 and DynamoDB are free and remove NAT processing charges entirely for that traffic.** Not creating them is a pure loss.
3. **Cross-AZ chatter is the tax on naive service meshes.** A service that fans out to three replicas, each in a different AZ, pays cross-AZ on two of the three calls. This is what topology-aware routing (§6.3) is for.

---

## 6. Infrastructure as code — complete, unabridged manifests

### 6.1 CloudFormation: a three-AZ VPC pinned to AZ **IDs**

The default pattern `!Select [0, !GetAZs '']` picks *your account's* first AZ name. That is fine for a single account and wrong the moment a second account has to co-locate with you. This template takes AZ **names** as parameters that you resolve from AZ IDs (see the resolver command immediately after the template), and records the intended AZ IDs in tags so the mapping is auditable.

```yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: >
  Production three-AZ VPC. Public and private subnets in three Availability Zones,
  one NAT Gateway per AZ (no cross-AZ egress, no shared failure domain), a free
  S3 gateway endpoint, and AZ-ID tagging so placement is auditable across accounts.

Parameters:
  ProjectName:
    Type: String
    Default: platform
    Description: Prefix used in Name tags and exported output names.
  VpcCidr:
    Type: String
    Default: 10.42.0.0/16
    AllowedPattern: '^(\d{1,3}\.){3}\d{1,3}/\d{1,2}$'
  AvailabilityZoneA:
    Type: AWS::EC2::AvailabilityZone::Name
    Description: AZ NAME that maps to the AZ ID given in AzIdA.
  AvailabilityZoneB:
    Type: AWS::EC2::AvailabilityZone::Name
  AvailabilityZoneC:
    Type: AWS::EC2::AvailabilityZone::Name
  AzIdA:
    Type: String
    Description: Physical AZ ID, e.g. use1-az1. Recorded in tags for cross-account audit.
  AzIdB:
    Type: String
  AzIdC:
    Type: String

Resources:

  # ---------------------------------------------------------------- VPC core
  Vpc:
    Type: AWS::EC2::VPC
    Properties:
      CidrBlock: !Ref VpcCidr
      EnableDnsSupport: true
      EnableDnsHostnames: true
      InstanceTenancy: default
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-vpc'

  InternetGateway:
    Type: AWS::EC2::InternetGateway
    Properties:
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-igw'

  InternetGatewayAttachment:
    Type: AWS::EC2::VPCGatewayAttachment
    Properties:
      VpcId: !Ref Vpc
      InternetGatewayId: !Ref InternetGateway

  # ------------------------------------------------------------ Public subnets
  PublicSubnetA:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref Vpc
      AvailabilityZone: !Ref AvailabilityZoneA
      CidrBlock: !Select [0, !Cidr [!Ref VpcCidr, 16, 12]]   # 10.42.0.0/20
      MapPublicIpOnLaunch: false
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-public-${AzIdA}'
        - Key: az-id
          Value: !Ref AzIdA
        - Key: kubernetes.io/role/elb
          Value: '1'

  PublicSubnetB:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref Vpc
      AvailabilityZone: !Ref AvailabilityZoneB
      CidrBlock: !Select [1, !Cidr [!Ref VpcCidr, 16, 12]]   # 10.42.16.0/20
      MapPublicIpOnLaunch: false
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-public-${AzIdB}'
        - Key: az-id
          Value: !Ref AzIdB
        - Key: kubernetes.io/role/elb
          Value: '1'

  PublicSubnetC:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref Vpc
      AvailabilityZone: !Ref AvailabilityZoneC
      CidrBlock: !Select [2, !Cidr [!Ref VpcCidr, 16, 12]]   # 10.42.32.0/20
      MapPublicIpOnLaunch: false
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-public-${AzIdC}'
        - Key: az-id
          Value: !Ref AzIdC
        - Key: kubernetes.io/role/elb
          Value: '1'

  # ----------------------------------------------------------- Private subnets
  PrivateSubnetA:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref Vpc
      AvailabilityZone: !Ref AvailabilityZoneA
      CidrBlock: !Select [8, !Cidr [!Ref VpcCidr, 16, 12]]   # 10.42.128.0/20
      MapPublicIpOnLaunch: false
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-private-${AzIdA}'
        - Key: az-id
          Value: !Ref AzIdA
        - Key: kubernetes.io/role/internal-elb
          Value: '1'

  PrivateSubnetB:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref Vpc
      AvailabilityZone: !Ref AvailabilityZoneB
      CidrBlock: !Select [9, !Cidr [!Ref VpcCidr, 16, 12]]   # 10.42.144.0/20
      MapPublicIpOnLaunch: false
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-private-${AzIdB}'
        - Key: az-id
          Value: !Ref AzIdB
        - Key: kubernetes.io/role/internal-elb
          Value: '1'

  PrivateSubnetC:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref Vpc
      AvailabilityZone: !Ref AvailabilityZoneC
      CidrBlock: !Select [10, !Cidr [!Ref VpcCidr, 16, 12]]  # 10.42.160.0/20
      MapPublicIpOnLaunch: false
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-private-${AzIdC}'
        - Key: az-id
          Value: !Ref AzIdC
        - Key: kubernetes.io/role/internal-elb
          Value: '1'

  # ------------------------------------------------- One NAT Gateway per AZ
  # Rationale: a single shared NAT would (a) make its AZ a single point of failure
  # for ALL outbound traffic and (b) turn every other AZ's egress into a billed
  # cross-AZ flow. Three NATs cost more per hour and less per incident.
  NatEipA:
    Type: AWS::EC2::EIP
    DependsOn: InternetGatewayAttachment
    Properties:
      Domain: vpc
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-nat-eip-${AzIdA}'

  NatEipB:
    Type: AWS::EC2::EIP
    DependsOn: InternetGatewayAttachment
    Properties:
      Domain: vpc
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-nat-eip-${AzIdB}'

  NatEipC:
    Type: AWS::EC2::EIP
    DependsOn: InternetGatewayAttachment
    Properties:
      Domain: vpc
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-nat-eip-${AzIdC}'

  NatGatewayA:
    Type: AWS::EC2::NatGateway
    Properties:
      AllocationId: !GetAtt NatEipA.AllocationId
      SubnetId: !Ref PublicSubnetA
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-nat-${AzIdA}'

  NatGatewayB:
    Type: AWS::EC2::NatGateway
    Properties:
      AllocationId: !GetAtt NatEipB.AllocationId
      SubnetId: !Ref PublicSubnetB
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-nat-${AzIdB}'

  NatGatewayC:
    Type: AWS::EC2::NatGateway
    Properties:
      AllocationId: !GetAtt NatEipC.AllocationId
      SubnetId: !Ref PublicSubnetC
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-nat-${AzIdC}'

  # -------------------------------------------------------------- Route tables
  PublicRouteTable:
    Type: AWS::EC2::RouteTable
    Properties:
      VpcId: !Ref Vpc
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-rtb-public'

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

  PublicSubnetCRouteAssoc:
    Type: AWS::EC2::SubnetRouteTableAssociation
    Properties:
      SubnetId: !Ref PublicSubnetC
      RouteTableId: !Ref PublicRouteTable

  # One private route table PER AZ, each pointing at that AZ's own NAT Gateway.
  PrivateRouteTableA:
    Type: AWS::EC2::RouteTable
    Properties:
      VpcId: !Ref Vpc
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-rtb-private-${AzIdA}'
        - Key: az-id
          Value: !Ref AzIdA

  PrivateDefaultRouteA:
    Type: AWS::EC2::Route
    Properties:
      RouteTableId: !Ref PrivateRouteTableA
      DestinationCidrBlock: 0.0.0.0/0
      NatGatewayId: !Ref NatGatewayA

  PrivateSubnetARouteAssoc:
    Type: AWS::EC2::SubnetRouteTableAssociation
    Properties:
      SubnetId: !Ref PrivateSubnetA
      RouteTableId: !Ref PrivateRouteTableA

  PrivateRouteTableB:
    Type: AWS::EC2::RouteTable
    Properties:
      VpcId: !Ref Vpc
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-rtb-private-${AzIdB}'
        - Key: az-id
          Value: !Ref AzIdB

  PrivateDefaultRouteB:
    Type: AWS::EC2::Route
    Properties:
      RouteTableId: !Ref PrivateRouteTableB
      DestinationCidrBlock: 0.0.0.0/0
      NatGatewayId: !Ref NatGatewayB

  PrivateSubnetBRouteAssoc:
    Type: AWS::EC2::SubnetRouteTableAssociation
    Properties:
      SubnetId: !Ref PrivateSubnetB
      RouteTableId: !Ref PrivateRouteTableB

  PrivateRouteTableC:
    Type: AWS::EC2::RouteTable
    Properties:
      VpcId: !Ref Vpc
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-rtb-private-${AzIdC}'
        - Key: az-id
          Value: !Ref AzIdC

  PrivateDefaultRouteC:
    Type: AWS::EC2::Route
    Properties:
      RouteTableId: !Ref PrivateRouteTableC
      DestinationCidrBlock: 0.0.0.0/0
      NatGatewayId: !Ref NatGatewayC

  PrivateSubnetCRouteAssoc:
    Type: AWS::EC2::SubnetRouteTableAssociation
    Properties:
      SubnetId: !Ref PrivateSubnetC
      RouteTableId: !Ref PrivateRouteTableC

  # ---------------------------------------- Free gateway endpoints (S3, DynamoDB)
  # Keeps S3/DynamoDB traffic off the NAT Gateways: no per-GB processing charge,
  # no internet path, and it works during an internet-facing impairment.
  S3GatewayEndpoint:
    Type: AWS::EC2::VPCEndpoint
    Properties:
      VpcId: !Ref Vpc
      ServiceName: !Sub 'com.amazonaws.${AWS::Region}.s3'
      VpcEndpointType: Gateway
      RouteTableIds:
        - !Ref PrivateRouteTableA
        - !Ref PrivateRouteTableB
        - !Ref PrivateRouteTableC

  DynamoDbGatewayEndpoint:
    Type: AWS::EC2::VPCEndpoint
    Properties:
      VpcId: !Ref Vpc
      ServiceName: !Sub 'com.amazonaws.${AWS::Region}.dynamodb'
      VpcEndpointType: Gateway
      RouteTableIds:
        - !Ref PrivateRouteTableA
        - !Ref PrivateRouteTableB
        - !Ref PrivateRouteTableC

  # --------------------------------------------------- VPC Flow Logs (az-id v4+)
  FlowLogsGroup:
    Type: AWS::Logs::LogGroup
    Properties:
      LogGroupName: !Sub '/aws/vpc/${ProjectName}/flowlogs'
      RetentionInDays: 30

  FlowLogsRole:
    Type: AWS::IAM::Role
    Properties:
      AssumeRolePolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Effect: Allow
            Principal:
              Service: vpc-flow-logs.amazonaws.com
            Action: sts:AssumeRole
      Policies:
        - PolicyName: WriteFlowLogs
          PolicyDocument:
            Version: '2012-10-17'
            Statement:
              - Effect: Allow
                Action:
                  - logs:CreateLogStream
                  - logs:PutLogEvents
                  - logs:DescribeLogStreams
                Resource: !GetAtt FlowLogsGroup.Arn

  VpcFlowLog:
    Type: AWS::EC2::FlowLog
    Properties:
      ResourceType: VPC
      ResourceId: !Ref Vpc
      TrafficType: ALL
      LogDestinationType: cloud-watch-logs
      LogGroupName: !Ref FlowLogsGroup
      DeliverLogsPermissionArn: !GetAtt FlowLogsRole.Arn
      MaxAggregationInterval: 60
      # az-id and region require flow log format version 4 or later. Without them
      # you cannot attribute cross-AZ data transfer charges to a physical zone.
      LogFormat: >-
        ${version} ${account-id} ${vpc-id} ${subnet-id} ${instance-id}
        ${interface-id} ${az-id} ${region} ${srcaddr} ${dstaddr}
        ${srcport} ${dstport} ${protocol} ${packets} ${bytes}
        ${start} ${end} ${action} ${log-status} ${flow-direction}
        ${pkt-src-aws-service} ${pkt-dst-aws-service} ${traffic-path}

Outputs:
  VpcId:
    Value: !Ref Vpc
    Export:
      Name: !Sub '${ProjectName}-vpc-id'
  PublicSubnetIds:
    Value: !Join [',', [!Ref PublicSubnetA, !Ref PublicSubnetB, !Ref PublicSubnetC]]
    Export:
      Name: !Sub '${ProjectName}-public-subnet-ids'
  PrivateSubnetIds:
    Value: !Join [',', [!Ref PrivateSubnetA, !Ref PrivateSubnetB, !Ref PrivateSubnetC]]
    Export:
      Name: !Sub '${ProjectName}-private-subnet-ids'
  AzIdMapping:
    Description: Physical AZ IDs backing this VPC, in subnet order A,B,C.
    Value: !Join [',', [!Ref AzIdA, !Ref AzIdB, !Ref AzIdC]]
    Export:
      Name: !Sub '${ProjectName}-az-ids'
```

**Resolving AZ IDs to this account's AZ names, then deploying:**

```bash
$ REGION=us-east-1
$ aws ec2 describe-availability-zones \
    --region "$REGION" \
    --filters Name=zone-type,Values=availability-zone \
    --query 'AvailabilityZones[?ZoneId==`use1-az1`||ZoneId==`use1-az2`||ZoneId==`use1-az4`].{Name:ZoneName,Id:ZoneId}' \
    --output table
-----------------------------
|DescribeAvailabilityZones  |
+-----------+---------------+
|    Id     |     Name      |
+-----------+---------------+
|  use1-az4 |  us-east-1a   |
|  use1-az1 |  us-east-1c   |
|  use1-az2 |  us-east-1d   |
+-----------+---------------+
```

Note what just happened: in this account, `use1-az1` is **not** `us-east-1a`. Any other account will very likely disagree.

```bash
$ aws cloudformation deploy \
    --region us-east-1 \
    --stack-name platform-network \
    --template-file vpc-3az.yaml \
    --capabilities CAPABILITY_IAM \
    --parameter-overrides \
        ProjectName=platform \
        VpcCidr=10.42.0.0/16 \
        AvailabilityZoneA=us-east-1a AzIdA=use1-az4 \
        AvailabilityZoneB=us-east-1c AzIdB=use1-az1 \
        AvailabilityZoneC=us-east-1d AzIdC=use1-az2

Waiting for changeset to be created..
Waiting for stack create/update to complete
Successfully created/updated stack - platform-network
```

### 6.2 Terraform: two Regions behind one Global Accelerator

This is the canonical **static stability** multi-Region pattern: both Regions are always running, both are healthy, and failover is a *data-plane* change (a traffic dial or an automatic health-check withdrawal), never a `Create*` API call.

```hcl
terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }
}

# ---------------------------------------------------------------- Providers
# Global Accelerator's control plane lives in us-west-2. This is a hard API
# requirement, exactly like CloudFront/WAF-CLOUDFRONT living in us-east-1.
provider "aws" {
  alias  = "global"
  region = "us-west-2"
}

provider "aws" {
  alias  = "primary"
  region = var.primary_region
}

provider "aws" {
  alias  = "secondary"
  region = var.secondary_region
}

variable "primary_region" {
  type    = string
  default = "us-east-1"
}

variable "secondary_region" {
  type    = string
  default = "eu-west-1"
}

variable "project" {
  type    = string
  default = "platform"
}

# ------------------------------------------------- Discover partition + AZ IDs
data "aws_partition" "current" {}

data "aws_availability_zones" "primary" {
  provider = aws.primary
  state    = "available"
  filter {
    name   = "zone-type"
    values = ["availability-zone"] # exclude Local Zones and Wavelength Zones
  }
}

data "aws_availability_zones" "secondary" {
  provider = aws.secondary
  state    = "available"
  filter {
    name   = "zone-type"
    values = ["availability-zone"]
  }
}

# A hard failure is better than silently building a 2-AZ "highly available" stack.
locals {
  primary_azs   = slice(data.aws_availability_zones.primary.names, 0, 3)
  secondary_azs = slice(data.aws_availability_zones.secondary.names, 0, 3)
}

resource "terraform_data" "az_count_guard" {
  lifecycle {
    precondition {
      condition = (
        length(data.aws_availability_zones.primary.names) >= 3 &&
        length(data.aws_availability_zones.secondary.names) >= 3
      )
      error_message = "Both Regions must expose at least 3 Availability Zones."
    }
  }
}

# ------------------------------------------------------ Per-Region VPC + ALB
module "network_primary" {
  source    = "./modules/vpc-3az"
  providers = { aws = aws.primary }

  name               = "${var.project}-${var.primary_region}"
  cidr               = "10.42.0.0/16"
  availability_zones = local.primary_azs
}

module "network_secondary" {
  source    = "./modules/vpc-3az"
  providers = { aws = aws.secondary }

  name               = "${var.project}-${var.secondary_region}"
  cidr               = "10.43.0.0/16"
  availability_zones = local.secondary_azs
}

resource "aws_lb" "primary" {
  provider = aws.primary

  name                             = "${var.project}-primary"
  load_balancer_type               = "application"
  internal                         = false
  subnets                          = module.network_primary.public_subnet_ids
  security_groups                  = [module.network_primary.alb_security_group_id]
  enable_cross_zone_load_balancing = true
  enable_deletion_protection       = true
  idle_timeout                     = 60
  drop_invalid_header_fields       = true

  tags = {
    Project = var.project
    Role    = "ingress"
  }
}

resource "aws_lb" "secondary" {
  provider = aws.secondary

  name                             = "${var.project}-secondary"
  load_balancer_type               = "application"
  internal                         = false
  subnets                          = module.network_secondary.public_subnet_ids
  security_groups                  = [module.network_secondary.alb_security_group_id]
  enable_cross_zone_load_balancing = true
  enable_deletion_protection       = true
  idle_timeout                     = 60
  drop_invalid_header_fields       = true

  tags = {
    Project = var.project
    Role    = "ingress"
  }
}

# -------------------------------------------------------- Global Accelerator
resource "aws_globalaccelerator_accelerator" "this" {
  provider = aws.global

  name            = "${var.project}-gax"
  ip_address_type = "DUAL_STACK"
  enabled         = true

  attributes {
    flow_logs_enabled   = true
    flow_logs_s3_bucket = aws_s3_bucket.gax_flow_logs.bucket
    flow_logs_s3_prefix = "gax/"
  }

  tags = {
    Project = var.project
  }
}

resource "aws_s3_bucket" "gax_flow_logs" {
  provider = aws.global
  bucket   = "${var.project}-gax-flow-logs-${data.aws_caller_identity.global.account_id}"
}

data "aws_caller_identity" "global" {
  provider = aws.global
}

resource "aws_globalaccelerator_listener" "https" {
  provider = aws.global

  accelerator_arn = aws_globalaccelerator_accelerator.this.id
  protocol        = "TCP"
  # SOURCE_IP gives client-IP affinity — required for stateful protocols.
  # Use NONE for stateless HTTP APIs to get an even spread.
  client_affinity = "NONE"

  port_range {
    from_port = 443
    to_port   = 443
  }
}

resource "aws_globalaccelerator_endpoint_group" "primary" {
  provider = aws.global

  listener_arn                  = aws_globalaccelerator_listener.https.id
  endpoint_group_region         = var.primary_region
  traffic_dial_percentage       = 100
  health_check_protocol         = "HTTPS"
  health_check_path             = "/healthz"
  health_check_port             = 443
  health_check_interval_seconds = 10
  threshold_count               = 3

  endpoint_configuration {
    endpoint_id                    = aws_lb.primary.arn
    weight                         = 128
    client_ip_preservation_enabled = true
  }
}

resource "aws_globalaccelerator_endpoint_group" "secondary" {
  provider = aws.global

  listener_arn                  = aws_globalaccelerator_listener.https.id
  endpoint_group_region         = var.secondary_region
  traffic_dial_percentage       = 100
  health_check_protocol         = "HTTPS"
  health_check_path             = "/healthz"
  health_check_port             = 443
  health_check_interval_seconds = 10
  threshold_count               = 3

  endpoint_configuration {
    endpoint_id                    = aws_lb.secondary.arn
    weight                         = 128
    client_ip_preservation_enabled = true
  }
}

# -------------------------------------------------------------------- Outputs
output "static_anycast_ips" {
  description = "Stable ingress IPs. Publish these to customers for allowlisting; they survive Region failover."
  value       = aws_globalaccelerator_accelerator.this.ip_sets[0].ip_addresses
}

output "accelerator_dns_name" {
  value = aws_globalaccelerator_accelerator.this.dns_name
}

output "primary_az_ids" {
  value = data.aws_availability_zones.primary.zone_ids
}

output "secondary_az_ids" {
  value = data.aws_availability_zones.secondary.zone_ids
}
```

```bash
$ terraform apply -auto-approve
...
Apply complete! Resources: 47 added, 0 changed, 0 destroyed.

Outputs:

accelerator_dns_name = "a1b2c3d4e5f6a7b8.awsglobalaccelerator.com"
primary_az_ids = tolist([
  "use1-az1",
  "use1-az2",
  "use1-az4",
  "use1-az5",
  "use1-az6",
])
secondary_az_ids = tolist([
  "euw1-az1",
  "euw1-az2",
  "euw1-az3",
])
static_anycast_ips = tolist([
  "75.2.83.117",
  "99.83.190.42",
])
```

**Failing over is now one data-plane call — no resource creation, no DNS propagation:**

```bash
$ aws globalaccelerator update-endpoint-group \
    --region us-west-2 \
    --endpoint-group-arn "arn:aws:globalaccelerator::123456789012:accelerator/9c1b0a3e-.../listener/1f2e3d4c/endpoint-group/5a6b7c8d" \
    --traffic-dial-percentage 0 \
    --query 'EndpointGroup.{Region:EndpointGroupRegion,Dial:TrafficDialPercentage}'
{
    "Region": "us-east-1",
    "Dial": 0.0
}
```

### 6.3 Kubernetes on EKS: making the zone topology explicit

An EKS cluster's control plane is Regional and multi-AZ by design. The **nodes and the storage are not** — that part is yours. These four manifests are the minimum set that makes a Deployment genuinely AZ-fault-tolerant.

```yaml
---
# 1. StorageClass — EBS is ZONAL. WaitForFirstConsumer is not optional.
#    With Immediate binding, the volume is provisioned in a zone chosen before
#    the scheduler knows where the Pod can run, and you get the classic
#    "volume node affinity conflict" Pending loop.
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3-zonal
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: ebs.csi.aws.com
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
reclaimPolicy: Delete
parameters:
  type: gp3
  iops: "3000"
  throughput: "125"
  encrypted: "true"
  kmsKeyId: arn:aws:kms:us-east-1:123456789012:key/8f1c2d3e-4a5b-6c7d-8e9f-0a1b2c3d4e5f
---
# 2. Stateless Deployment — spread hard across zones, softly across nodes.
apiVersion: apps/v1
kind: Deployment
metadata:
  name: checkout-api
  namespace: commerce
  labels:
    app.kubernetes.io/name: checkout-api
spec:
  replicas: 6
  revisionHistoryLimit: 3
  selector:
    matchLabels:
      app.kubernetes.io/name: checkout-api
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 1
      maxSurge: 2
  template:
    metadata:
      labels:
        app.kubernetes.io/name: checkout-api
    spec:
      terminationGracePeriodSeconds: 45
      topologySpreadConstraints:
        # Hard constraint: never let one zone hold 2 more replicas than another.
        # DoNotSchedule means we would rather run degraded than run concentrated.
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: checkout-api
          matchLabelKeys:
            - pod-template-hash
        # Soft constraint: also prefer distinct nodes inside each zone, so a
        # single EC2 instance failure does not take a whole zone's share.
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: checkout-api
      containers:
        - name: api
          image: 123456789012.dkr.ecr.us-east-1.amazonaws.com/checkout-api:1.14.2
          ports:
            - name: http
              containerPort: 8080
          env:
            # Expose the physical zone to the app for logging and metrics.
            - name: AWS_STS_REGIONAL_ENDPOINTS
              value: regional
            - name: NODE_ZONE
              valueFrom:
                fieldRef:
                  fieldPath: metadata.annotations['topology.kubernetes.io/zone']
          resources:
            requests:
              cpu: 250m
              memory: 512Mi
            limits:
              memory: 512Mi
          readinessProbe:
            httpGet:
              path: /readyz
              port: http
            periodSeconds: 5
            failureThreshold: 3
          livenessProbe:
            httpGet:
              path: /healthz
              port: http
            periodSeconds: 10
            failureThreshold: 5
          lifecycle:
            preStop:
              exec:
                command: ["/bin/sh", "-c", "sleep 15"]
---
# 3. PodDisruptionBudget — survives a full-zone drain during an AZ evacuation.
#    With 6 replicas over 3 zones, losing one zone removes 2. minAvailable: 4
#    is exactly the floor that permits that eviction and blocks a second one.
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: checkout-api
  namespace: commerce
spec:
  minAvailable: 4
  selector:
    matchLabels:
      app.kubernetes.io/name: checkout-api
---
# 4. Service with topology-aware routing — keeps traffic inside the zone when
#    there is enough local capacity, cutting cross-AZ data transfer charges.
#    It automatically falls back to cross-zone routing when a zone is unhealthy.
apiVersion: v1
kind: Service
metadata:
  name: checkout-api
  namespace: commerce
  annotations:
    service.kubernetes.io/topology-mode: Auto
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: checkout-api
  ports:
    - name: http
      port: 80
      targetPort: http
      protocol: TCP
  trafficDistribution: PreferClose
```

```bash
$ kubectl get pods -n commerce -l app.kubernetes.io/name=checkout-api \
    -o custom-columns='NAME:.metadata.name,NODE:.spec.nodeName,ZONE:.metadata.annotations.topology\.kubernetes\.io/zone'
NAME                            NODE                          ZONE
checkout-api-7d9f4c8b6d-2xk9p   ip-10-42-131-14.ec2.internal  us-east-1a
checkout-api-7d9f4c8b6d-4mq7t   ip-10-42-149-88.ec2.internal  us-east-1c
checkout-api-7d9f4c8b6d-8vn2j   ip-10-42-166-31.ec2.internal  us-east-1d
checkout-api-7d9f4c8b6d-h6rl4   ip-10-42-132-207.ec2.internal us-east-1a
checkout-api-7d9f4c8b6d-p3wc9   ip-10-42-151-73.ec2.internal  us-east-1c
checkout-api-7d9f4c8b6d-zt8bf   ip-10-42-168-19.ec2.internal  us-east-1d
```

Two per zone, six nodes, no concentration. Now map the *names* back to the *IDs*, which is what AWS will use when it tells you a zone is impaired:

```bash
$ kubectl get nodes -L topology.kubernetes.io/zone,topology.k8s.aws/zone-id
NAME                            STATUS   ROLES    AGE   VERSION   ZONE         ZONE-ID
ip-10-42-131-14.ec2.internal    Ready    <none>   6d    v1.30.4   us-east-1a   use1-az4
ip-10-42-132-207.ec2.internal   Ready    <none>   6d    v1.30.4   us-east-1a   use1-az4
ip-10-42-149-88.ec2.internal    Ready    <none>   6d    v1.30.4   us-east-1c   use1-az1
ip-10-42-151-73.ec2.internal    Ready    <none>   6d    v1.30.4   us-east-1c   use1-az1
ip-10-42-166-31.ec2.internal    Ready    <none>   6d    v1.30.4   us-east-1d   use1-az2
ip-10-42-168-19.ec2.internal    Ready    <none>   6d    v1.30.4   us-east-1d   use1-az2
```

### 6.4 Route 53: latency-based routing with health-checked failover

DNS is the other global steering mechanism. This change batch creates latency records in two Regions, each guarded by a health check, so resolvers get the closest *healthy* Region.

```bash
$ cat > /tmp/health-checks.sh <<'EOF'
set -euo pipefail
for pair in "us-east-1:api-use1.example.com" "eu-west-1:api-euw1.example.com"; do
  region="${pair%%:*}"; fqdn="${pair##*:}"
  aws route53 create-health-check \
    --caller-reference "hc-${region}-$(date +%s)" \
    --health-check-config "{
        \"Type\": \"HTTPS\",
        \"FullyQualifiedDomainName\": \"${fqdn}\",
        \"Port\": 443,
        \"ResourcePath\": \"/healthz\",
        \"RequestInterval\": 10,
        \"FailureThreshold\": 2,
        \"MeasureLatency\": true,
        \"EnableSNI\": true
      }" \
    --query 'HealthCheck.{Id:Id,Target:HealthCheckConfig.FullyQualifiedDomainName}' \
    --output text
done
EOF
$ bash /tmp/health-checks.sh
9f2c1a44-3b7e-4e1a-9c8d-2a5f6b7c8d90    api-use1.example.com
c7d3e2b5-8f1a-4d6c-b3e9-1f4a5c6d7e80    api-euw1.example.com
```

```json
{
  "Comment": "Latency-based routing with per-Region health checks for api.example.com",
  "Changes": [
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "api.example.com.",
        "Type": "A",
        "SetIdentifier": "us-east-1-primary",
        "Region": "us-east-1",
        "HealthCheckId": "9f2c1a44-3b7e-4e1a-9c8d-2a5f6b7c8d90",
        "AliasTarget": {
          "HostedZoneId": "Z35SXDOTRQ7X7K",
          "DNSName": "dualstack.platform-primary-1234567890.us-east-1.elb.amazonaws.com.",
          "EvaluateTargetHealth": true
        }
      }
    },
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "api.example.com.",
        "Type": "A",
        "SetIdentifier": "eu-west-1-secondary",
        "Region": "eu-west-1",
        "HealthCheckId": "c7d3e2b5-8f1a-4d6c-b3e9-1f4a5c6d7e80",
        "AliasTarget": {
          "HostedZoneId": "Z32O12XQLNTSW2",
          "DNSName": "dualstack.platform-secondary-0987654321.eu-west-1.elb.amazonaws.com.",
          "EvaluateTargetHealth": true
        }
      }
    }
  ]
}
```

```bash
$ aws route53 change-resource-record-sets \
    --hosted-zone-id Z0123456789ABCDEFGHIJ \
    --change-batch file:///tmp/latency-records.json \
    --query 'ChangeInfo.{Id:Id,Status:Status}'
{
    "Id": "/change/C0987654321ZYXWVUTSRQ",
    "Status": "PENDING"
}

$ aws route53 wait resource-record-sets-changed --id /change/C0987654321ZYXWVUTSRQ && echo INSYNC
INSYNC
```

**The trade-off versus §6.2:** Route 53 latency routing is cheap, works for any protocol, and gives you geographic control — but failover is bounded by DNS TTLs and by client resolvers that ignore them. Global Accelerator costs more (fixed hourly + per-GB) but fails over with no client-side DNS involvement at all. Pick per workload; many production stacks use both — Route 53 for the human-facing web tier, Global Accelerator for the device/API tier.

---

## 7. Working the infrastructure from the CLI

### 7.1 The free service-availability database nobody uses

AWS publishes the entire global infrastructure catalogue as **public SSM Parameter Store parameters**. No special permissions beyond `ssm:GetParametersByPath`, no scraping a web page, and it is machine-readable — which makes it the correct thing to put in a CI gate.

```bash
# Every Region code AWS publishes
$ aws ssm get-parameters-by-path \
    --path /aws/service/global-infrastructure/regions \
    --query 'Parameters[].Value' --output text | tr '\t' '\n' | sort | head -20
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
ca-west-1
eu-central-1
eu-central-2
eu-north-1
eu-south-1
eu-south-2
eu-west-1
eu-west-2

# The human-readable name of a Region
$ aws ssm get-parameter \
    --name /aws/service/global-infrastructure/regions/eu-central-1/longName \
    --query 'Parameter.Value' --output text
Europe (Frankfurt)

# THE question: is this service in this Region? Gate your deployments on it.
$ aws ssm get-parameters-by-path \
    --path /aws/service/global-infrastructure/services/bedrock/regions \
    --query 'Parameters[].Value' --output text | tr '\t' '\n' | sort
ap-northeast-1
ap-south-1
ap-southeast-1
ap-southeast-2
ca-central-1
eu-central-1
eu-west-1
eu-west-2
eu-west-3
sa-east-1
us-east-1
us-east-2
us-west-2

# Inverted: everything available in a candidate Region
$ aws ssm get-parameters-by-path \
    --path /aws/service/global-infrastructure/regions/il-central-1/services \
    --query 'Parameters[].Value' --output text | tr '\t' '\n' | wc -l
147
```

A five-line CI check that would have prevented several of my worst Region-selection meetings:

```bash
$ cat > check-region-services.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
REGION="$1"; shift
missing=()
for svc in "$@"; do
  if ! aws ssm get-parameter \
        --name "/aws/service/global-infrastructure/regions/${REGION}/services/${svc}" \
        >/dev/null 2>&1; then
    missing+=("$svc")
  fi
done
if (( ${#missing[@]} )); then
  printf 'FAIL: %s does not offer: %s\n' "$REGION" "${missing[*]}" >&2
  exit 1
fi
printf 'OK: %s offers all %d required services\n' "$REGION" "$#"
EOF
$ chmod +x check-region-services.sh
$ ./check-region-services.sh eu-south-2 lambda dynamodb eks kms secretsmanager
OK: eu-south-2 offers all 5 required services
$ ./check-region-services.sh eu-south-2 lambda bedrock outposts
FAIL: eu-south-2 does not offer: bedrock outposts
```

### 7.2 Enumerating Regions and their opt-in state

```bash
$ aws ec2 describe-regions --all-regions \
    --query 'sort_by(Regions,&RegionName)[?OptInStatus!=`opt-in-not-required`].[RegionName,OptInStatus]' \
    --output table
------------------------------------
|          DescribeRegions         |
+-----------------+----------------+
|  af-south-1     |  not-opted-in  |
|  ap-east-1      |  not-opted-in  |
|  ap-south-2     |  not-opted-in  |
|  ap-southeast-3 |  opted-in      |
|  ap-southeast-4 |  not-opted-in  |
|  ca-west-1      |  not-opted-in  |
|  eu-central-2   |  not-opted-in  |
|  eu-south-1     |  opted-in      |
|  eu-south-2     |  not-opted-in  |
|  il-central-1   |  not-opted-in  |
|  me-central-1   |  not-opted-in  |
|  me-south-1     |  not-opted-in  |
+-----------------+----------------+
```

Enabling one (this is asynchronous and can take several minutes):

```bash
$ aws account enable-region --region-name eu-south-2
$ aws account get-region-opt-status --region-name eu-south-2
{
    "RegionName": "eu-south-2",
    "RegionOptStatus": "ENABLING"
}

# ...a few minutes later
$ aws account get-region-opt-status --region-name eu-south-2
{
    "RegionName": "eu-south-2",
    "RegionOptStatus": "ENABLED"
}

# From the Organizations management account, for a member account:
$ aws account enable-region \
    --account-id 210987654321 \
    --region-name eu-south-2
```

### 7.3 Availability Zones, Local Zones, Wavelength Zones

```bash
$ aws ec2 describe-availability-zones --region us-west-2 \
    --query 'AvailabilityZones[].[ZoneName,ZoneId,ZoneType,OptInStatus,NetworkBorderGroup]' \
    --output table
--------------------------------------------------------------------------------------------------------
|                                       DescribeAvailabilityZones                                      |
+--------------------------+-------------------+--------------------+---------------+------------------+
|  us-west-2a              |  usw2-az1         |  availability-zone |opt-in-not-required| us-west-2     |
|  us-west-2b              |  usw2-az2         |  availability-zone |opt-in-not-required| us-west-2     |
|  us-west-2c              |  usw2-az3         |  availability-zone |opt-in-not-required| us-west-2     |
|  us-west-2d              |  usw2-az4         |  availability-zone |opt-in-not-required| us-west-2     |
+--------------------------+-------------------+--------------------+---------------+------------------+
```

Local Zones and Wavelength Zones are hidden unless you ask for all zones:

```bash
$ aws ec2 describe-availability-zones --region us-west-2 --all-availability-zones \
    --filters Name=zone-type,Values=local-zone \
    --query 'AvailabilityZones[].[ZoneName,ZoneId,GroupName,ParentZoneName,OptInStatus]' \
    --output table
------------------------------------------------------------------------------------------
|                               DescribeAvailabilityZones                                |
+---------------------+------------------+-------------------+--------------+------------+
|  us-west-2-lax-1a   |  usw2-lax1-az1   |  us-west-2-lax-1  |  us-west-2   |not-opted-in|
|  us-west-2-lax-1b   |  usw2-lax1-az2   |  us-west-2-lax-1  |  us-west-2   |not-opted-in|
|  us-west-2-den-1a   |  usw2-den1-az1   |  us-west-2-den-1  |  us-west-2   |not-opted-in|
|  us-west-2-phx-2a   |  usw2-phx2-az1   |  us-west-2-phx-2  |  us-west-2   |not-opted-in|
+---------------------+------------------+-------------------+--------------+------------+

$ aws ec2 modify-availability-zone-group \
    --group-name us-west-2-lax-1 \
    --opt-in-status opted-in
{
    "Return": true
}

$ aws ec2 describe-availability-zones --region us-east-1 --all-availability-zones \
    --filters Name=zone-type,Values=wavelength-zone \
    --query 'AvailabilityZones[:3].[ZoneName,ZoneId,GroupName,ParentZoneName]' \
    --output table
-------------------------------------------------------------------------------------------------
|                                  DescribeAvailabilityZones                                    |
+-------------------------------+------------------+----------------------------+---------------+
|  us-east-1-wl1-bos-wlz-1      |  use1-wl1-bos-wlz1 |  us-east-1-wl1-bos-wlz-1 |  us-east-1    |
|  us-east-1-wl1-nyc-wlz-1      |  use1-wl1-nyc-wlz1 |  us-east-1-wl1-nyc-wlz-1 |  us-east-1    |
|  us-east-1-wl1-was-wlz-1      |  use1-wl1-was-wlz1 |  us-east-1-wl1-was-wlz-1 |  us-east-1    |
+-------------------------------+------------------+----------------------------+---------------+
```

### 7.4 Measuring the AZ latency budget for yourself

The "synchronous replication is viable across AZs" claim is testable. Two `c7g.large` instances, one in `use1-az1` and one in `use1-az2`, same VPC, private IPs:

```bash
# Same AZ (baseline)
$ sockperf ping-pong -i 10.42.131.14 -p 11111 -t 20 --pps=max
sockperf: === latency histogram (usec) ===
sockperf: Summary: Round trip is 84.117 usec
sockperf: Total 237914 observations
sockperf: ---> percentile 99.999 = 402.115
sockperf: ---> percentile 99.900 =  198.442
sockperf: ---> percentile 99.000 =  131.207
sockperf: ---> percentile 50.000 =   81.664

# Cross-AZ, same Region
$ sockperf ping-pong -i 10.42.149.88 -p 11111 -t 20 --pps=max
sockperf: === latency histogram (usec) ===
sockperf: Summary: Round trip is 731.408 usec
sockperf: Total 27346 observations
sockperf: ---> percentile 99.999 = 2841.330
sockperf: ---> percentile 99.900 = 1104.219
sockperf: ---> percentile 99.000 =  918.774
sockperf: ---> percentile 50.000 =  724.032

$ iperf3 -c 10.42.149.88 -t 10 -P 4 | tail -4
[SUM]   0.00-10.00  sec  11.6 GBytes  9.94 Gbits/sec  1421   sender
[SUM]   0.00-10.00  sec  11.6 GBytes  9.93 Gbits/sec         receiver
iperf Done.
```

Read the numbers as an engineering budget, not a benchmark. Sub-millisecond cross-AZ RTT with ~10 Gbit/s of bandwidth means a synchronous commit costs you *hundreds of microseconds*, which for almost every OLTP workload is invisible. That is precisely why AWS bounds AZ separation. Compare to cross-Region:

```bash
$ sockperf ping-pong -i 10.43.140.22 -p 11111 -t 20   # eu-west-1 target from us-east-1
sockperf: Summary: Round trip is 74812.531 usec
```

~75 ms RTT. Any design that puts a synchronous quorum across those two Regions has just made every write take 75 ms. This single measurement is the entire argument for **asynchronous** cross-Region replication (Aurora Global Database, DynamoDB global tables, S3 CRR) and for accepting a non-zero RPO.

### 7.5 Evacuating an AZ on purpose

Route 53 Application Recovery Controller **zonal shift** lets you pull an AZ out of rotation for a load balancer without touching your application, your ASG, or your DNS. Note the resource identifier is the **AZ ID**.

```bash
$ aws arc-zonal-shift list-managed-resources \
    --query 'items[].{Name:name,Arn:arn,Zones:availabilityZones}' --output json
[
    {
        "Name": "platform-primary",
        "Arn": "arn:aws:elasticloadbalancing:us-east-1:123456789012:loadbalancer/app/platform-primary/1234567890abcdef",
        "Zones": ["use1-az1", "use1-az2", "use1-az4"]
    }
]

$ aws arc-zonal-shift start-zonal-shift \
    --resource-identifier "arn:aws:elasticloadbalancing:us-east-1:123456789012:loadbalancer/app/platform-primary/1234567890abcdef" \
    --away-from use1-az2 \
    --expires-in 6h \
    --comment "INC-4471: elevated 5xx isolated to use1-az2, evacuating while we investigate"
{
    "zonalShiftId": "3f8a1c9d-6b2e-4a7f-9c1d-8e5b3a2f7c40",
    "resourceIdentifier": "arn:aws:elasticloadbalancing:us-east-1:123456789012:loadbalancer/app/platform-primary/1234567890abcdef",
    "awayFrom": "use1-az2",
    "expiryTime": "2026-09-04T20:14:07+00:00",
    "startTime": "2026-09-04T14:14:07+00:00",
    "status": "ACTIVE",
    "comment": "INC-4471: elevated 5xx isolated to use1-az2, evacuating while we investigate"
}

$ aws arc-zonal-shift cancel-zonal-shift --zonal-shift-id 3f8a1c9d-6b2e-4a7f-9c1d-8e5b3a2f7c40
{
    "zonalShiftId": "3f8a1c9d-6b2e-4a7f-9c1d-8e5b3a2f7c40",
    "status": "CANCELED"
}
```

**The prerequisite that bites people:** zonal shift only actually removes the zone if **cross-zone load balancing is disabled** on the load balancer. With cross-zone enabled, the remaining zones' nodes keep forwarding into the impaired zone's targets and the shift accomplishes nothing. It is also why the evacuation only works if the *other* two zones have pre-provisioned headroom for 100% of traffic — static stability again. If your ASG has to scale up to absorb the shift, you have made your recovery depend on the EC2 control plane during an event.

---

## 8. Resilience patterns and what each one actually buys

### 8.1 Multi-AZ vs Multi-Region

| | **Multi-AZ (single Region)** | **Multi-Region** |
|---|---|---|
| Protects against | Data-center / zone-level failure: power, cooling, flood, fiber cut, network partition | Region-wide event, regional regulatory shutdown, targeted geographic outage |
| Data replication | **Synchronous** is viable (sub-ms RTT) | **Asynchronous** in practice (tens of ms RTT) |
| RPO | ~0 | Seconds to minutes |
| RTO | Seconds to a couple of minutes | Minutes to hours, depending on strategy |
| Managed-service support | Extensive and mostly a checkbox: RDS Multi-AZ, ELB, ASG, EFS, DynamoDB, S3 | Explicit configuration required: CRR, global tables, Aurora Global DB, GA/Route 53 |
| Application changes | Usually none | Frequently substantial: idempotency, conflict resolution, ID generation, session state |
| Data transfer cost | ~$0.01/GB each way | ~$0.02/GB+, and you replicate continuously |
| Compute cost | ~1.3–1.5× | ~1.8–2.2× for warm/active-active |
| Operational burden | Low | High — two of everything to patch, deploy, monitor, and drill |
| **When it is the right answer** | **The default for essentially all production workloads** | Regulatory mandate, contractual RTO the Region cannot meet, or genuinely global latency requirements |

Do not skip to multi-Region. A correctly built Multi-AZ system is the 90% answer, and most organizations that "have multi-Region" have an untested standby that would not come up.

### 8.2 The four disaster-recovery strategies

From the AWS Well-Architected disaster-recovery guidance, ordered by cost:

| Strategy | RPO | RTO | What runs in the second Region | Cost | Failover mechanism |
|---|---|---|---|---|---|
| **Backup & restore** | Hours | Hours (up to 24h+) | Nothing. Backups replicated (S3 CRR, AWS Backup cross-Region copy) | $ | Deploy the stack from IaC, restore data, repoint DNS |
| **Pilot light** | Minutes | Tens of minutes | Data replicated live; core infra (VPC, DB replica) exists but **compute is off** | $$ | Scale up compute, promote the replica, repoint DNS |
| **Warm standby** | Seconds | Minutes | A **scaled-down but fully functional** copy of the whole stack, always serving nothing or a trickle | $$$ | Scale out, repoint traffic |
| **Multi-site active/active** | Near zero | Near zero | A full-size copy actively serving real users | $$$$ | Withdraw traffic (GA dial, Route 53 health check) — often automatic |

**The decision rule:** pick the cheapest strategy whose RTO/RPO meets a number your business has actually written down. If nobody has written the number down, that is the first deliverable, not the architecture.

**The rule that overrides all of them:** *a DR plan that has never been executed does not exist.* Schedule the game day. Fail over for real. Measure the actual RTO, not the design RTO. Every organization I have seen discover a broken DR plan discovered it during the incident, and the cause was almost always the same class of thing — an unreplicated secret, a hardcoded Region string, an ACM certificate that only existed in the primary, a quota in the standby Region that was never raised because nothing had ever run there.

### 8.3 Static stability, stated plainly

> A statically stable system continues to operate correctly **without needing to make control-plane changes** in response to a failure.

Control planes (the APIs that create and modify resources) are inherently more complex and less available than data planes (the systems that serve your traffic). During a large event, control planes degrade first and recover last. Therefore:

| Anti-pattern (dynamic) | Statically stable equivalent |
|---|---|
| Scale the ASG up when an AZ fails | Pre-provision 150% capacity across 3 AZs so 2 AZs already carry 100% |
| Launch the DR stack from CloudFormation during the event | Keep it deployed and idle; change only a traffic dial |
| Update a Route 53 record via the API during the event | Use ARC routing controls (a highly available *data-plane* API with 5 independent regional endpoints), or Global Accelerator health checks |
| Fetch a secret from the primary Region at failover time | Replicate the secret to the standby Region continuously |
| Have the standby Region assume a role via the global STS endpoint | Regional STS endpoints everywhere |

The over-provisioning is not waste. It is the premium on the insurance policy, and it is cheaper than the alternative — a recovery plan that calls an API which is, at that exact moment, returning `RequestLimitExceeded`.

---

## 9. Verification and failure diagnosis

### 9.1 A pre-production topology checklist

```bash
#!/usr/bin/env bash
# verify-topology.sh — run before declaring a stack "highly available"
set -euo pipefail
REGION="${1:?usage: verify-topology.sh <region> <asg-name>}"
ASG="${2:?}"
fail=0

echo "== 1. Region enabled and reachable =========================="
aws ec2 describe-regions --region-names "$REGION" \
  --query 'Regions[0].{Region:RegionName,OptIn:OptInStatus}' --output text

echo "== 2. AZ name -> AZ ID mapping (record this) ================"
aws ec2 describe-availability-zones --region "$REGION" \
  --filters Name=zone-type,Values=availability-zone \
  --query 'AvailabilityZones[].[ZoneName,ZoneId,State]' --output table

echo "== 3. ASG spans >= 3 distinct AZs ==========================="
az_count=$(aws autoscaling describe-auto-scaling-groups \
  --region "$REGION" --auto-scaling-group-names "$ASG" \
  --query 'length(AutoScalingGroups[0].AvailabilityZones)' --output text)
echo "AZs configured on $ASG: $az_count"
[ "$az_count" -ge 3 ] || { echo "  FAIL: fewer than 3 AZs"; fail=1; }

echo "== 4. Instances ACTUALLY distributed, not just configured ==="
aws autoscaling describe-auto-scaling-groups \
  --region "$REGION" --auto-scaling-group-names "$ASG" \
  --query 'AutoScalingGroups[0].Instances[].AvailabilityZone' --output text \
  | tr '\t' '\n' | sort | uniq -c

echo "== 5. Every private route table has its OWN AZ's NAT ========"
aws ec2 describe-route-tables --region "$REGION" \
  --filters "Name=tag:Name,Values=*private*" \
  --query 'RouteTables[].{RTB:RouteTableId,Nat:Routes[?DestinationCidrBlock==`0.0.0.0/0`].NatGatewayId|[0]}' \
  --output table

echo "== 6. Service quotas exist in THIS Region (they are per-Region)"
aws service-quotas get-service-quota --region "$REGION" \
  --service-code ec2 --quota-code L-1216C47A \
  --query 'Quota.{Name:QuotaName,Value:Value,Adjustable:Adjustable}' --output table

exit "$fail"
```

```bash
$ ./verify-topology.sh us-east-1 platform-api-asg
== 1. Region enabled and reachable ==========================
us-east-1       opt-in-not-required
== 2. AZ name -> AZ ID mapping (record this) ================
-----------------------------------------
|      DescribeAvailabilityZones        |
+---------------+------------+----------+
|  us-east-1a   | use1-az4   |available |
|  us-east-1b   | use1-az6   |available |
|  us-east-1c   | use1-az1   |available |
|  us-east-1d   | use1-az2   |available |
|  us-east-1e   | use1-az3   |available |
|  us-east-1f   | use1-az5   |available |
+---------------+------------+----------+
== 3. ASG spans >= 3 distinct AZs ===========================
AZs configured on platform-api-asg: 3
== 4. Instances ACTUALLY distributed, not just configured ===
      2 us-east-1a
      2 us-east-1c
      2 us-east-1d
== 5. Every private route table has its OWN AZ's NAT ========
--------------------------------------------------
|              DescribeRouteTables               |
+-------------------------+----------------------+
|          RTB            |         Nat          |
+-------------------------+----------------------+
|  rtb-0a1b2c3d4e5f60001  |  nat-0f1e2d3c4b5a001 |
|  rtb-0a1b2c3d4e5f60002  |  nat-0f1e2d3c4b5a002 |
|  rtb-0a1b2c3d4e5f60003  |  nat-0f1e2d3c4b5a003 |
+-------------------------+----------------------+
== 6. Service quotas exist in THIS Region (they are per-Region)
------------------------------------------------------------------------
|                            GetServiceQuota                           |
+--------------------------------------------------+---------+---------+
|                       Name                       |  Value  |Adjustable|
+--------------------------------------------------+---------+---------+
|  Running On-Demand Standard instances            |  512.0  |  True   |
+--------------------------------------------------+---------+---------+
```

Step 4 is the one that catches incident shape A. Step 3 checks *configuration*; step 4 checks *reality*. They diverge more often than you would like.

### 9.2 Symptom → cause → fix

| Symptom / error | Root cause | Diagnosis | Fix |
|---|---|---|---|
| `InvalidVolume.ZoneMismatch: The volume 'vol-…' is not in the same availability zone as instance 'i-…'` | EBS is zonal; you tried to attach across AZs | `aws ec2 describe-volumes --volume-ids vol-… --query 'Volumes[0].AvailabilityZone'` | Snapshot → create a volume from the snapshot **in the target AZ**. Long-term: EFS/FSx, or a Regional database |
| Pod stuck `Pending` with `0/6 nodes are available: 3 node(s) had volume node affinity conflict` | PV was provisioned in a zone with no schedulable node for that Pod | `kubectl get pv <pv> -o jsonpath='{.spec.nodeAffinity}'` | Set `volumeBindingMode: WaitForFirstConsumer` on the StorageClass (§6.3) and recreate the PVC |
| Pod stuck `Pending` with `didn't match pod topology spread constraints` | Hard `DoNotSchedule` spread cannot be satisfied — a zone has no capacity | `kubectl get nodes -L topology.kubernetes.io/zone` | Add node capacity in the starved zone, or relax to `ScheduleAnyway` for non-critical workloads. **Do not blanket-relax it** — that reintroduces concentration |
| `AuthFailure: AWS was not able to validate the provided access credentials` in one Region only | The Region is opt-in and not enabled for the account | `aws account get-region-opt-status --region-name <region>` | `aws account enable-region --region-name <region>`, then wait for `ENABLED` |
| `Could not connect to the endpoint URL: "https://<service>.<region>.amazonaws.com/"` | The service does not exist in that Region (or the Region code is typo'd) | `aws ssm get-parameter --name /aws/service/global-infrastructure/regions/<region>/services/<svc>` | Choose a supported Region, or use a supported alternative service. Add the §7.1 CI gate |
| CloudFront rejects a custom domain: certificate not found | ACM certificate was issued outside `us-east-1` | `aws acm list-certificates --region us-east-1` | Re-request/import the certificate **in `us-east-1`**. For ALB it is the opposite: same Region as the ALB |
| `WAFNonexistentItemException` when associating a Web ACL with a CloudFront distribution | Web ACL created with `--scope REGIONAL` | `aws wafv2 list-web-acls --scope CLOUDFRONT --region us-east-1` | Recreate with `--scope CLOUDFRONT --region us-east-1` |
| Two accounts believe they are co-located but latency and cost say otherwise | AZ **names** were used instead of AZ **IDs** across accounts | Compare `ZoneId` in both accounts for the same `ZoneName` | Re-place resources by AZ ID. Add `az-id` tags (§6.1) so this is auditable |
| Application keeps hitting the old endpoint minutes after an RDS Multi-AZ failover | Client-side DNS caching (classically a JVM with `networkaddress.cache.ttl=-1`) | `dig +short <rds-endpoint>` from the host vs. what the app resolved | Set `networkaddress.cache.ttl=5` (or lower); use RDS Proxy; use a connection pool that re-resolves |
| Data-transfer line item grew ~40% with no traffic increase | New cross-AZ chatter from a deploy that spread services differently | Cost Explorer, group by *Usage Type*, filter `*DataTransfer-Regional-Bytes` | Confirm with flow logs (below), then apply topology-aware routing (§6.3) or co-locate the chatty pair |
| Global Accelerator zonal/regional failover did not remove traffic | Health check path returns 200 even when the app is broken; or endpoint weight not zeroed | `aws globalaccelerator describe-endpoint-group --endpoint-group-arn …` and inspect `HealthState` | Make `/healthz` a real dependency check. Verify the health check actually flips in a game day |
| Zonal shift ran but the impaired AZ still receives traffic | Cross-zone load balancing is enabled on the ELB | `aws elbv2 describe-load-balancer-attributes --load-balancer-arn …` | Disable cross-zone load balancing on load balancers you intend to evacuate zonally |

### 9.3 Attributing cross-AZ data transfer to a physical zone

The bill tells you *how much*; flow logs with `az-id` tell you *who*. First confirm the charge exists:

```bash
$ aws ce get-cost-and-usage \
    --time-period Start=2026-08-01,End=2026-09-01 \
    --granularity MONTHLY \
    --metrics UnblendedCost UsageQuantity \
    --filter '{"Dimensions":{"Key":"USAGE_TYPE_GROUP","Values":["EC2: Data Transfer - Region to Region"]}}' \
    --group-by Type=DIMENSION,Key=USAGE_TYPE \
    --query 'ResultsByTime[0].Groups[].{Usage:Keys[0],GB:Metrics.UsageQuantity.Amount,USD:Metrics.UnblendedCost.Amount}' \
    --output table
--------------------------------------------------------------------------
|                          GetCostAndUsage                               |
+-------------------------------------------+-------------+--------------+
|                   Usage                   |     GB      |     USD      |
+-------------------------------------------+-------------+--------------+
|  USE1-DataTransfer-Regional-Bytes         |  41827.3341 |  418.2733    |
+-------------------------------------------+-------------+--------------+
```

Then find the talkers, using the `az-id` field that the §6.1 flow-log format enables:

```sql
-- Athena over VPC Flow Logs partitioned by date
SELECT
  src.az_id                          AS src_az,
  dst.az_id                          AS dst_az,
  src.srcaddr,
  src.dstaddr,
  SUM(src.bytes) / 1024.0 / 1024 / 1024 AS gb
FROM   vpc_flow_logs src
JOIN   eni_az_map    dst ON src.dstaddr = dst.private_ip
WHERE  src.dt      BETWEEN '2026/08/01' AND '2026/08/31'
  AND  src.action  =  'ACCEPT'
  AND  src.az_id  <>  dst.az_id          -- the whole point: cross-AZ only
GROUP  BY src.az_id, dst.az_id, src.srcaddr, src.dstaddr
ORDER  BY gb DESC
LIMIT  15;
```

```
    src_az   |   dst_az   |   srcaddr    |   dstaddr    |    gb
-------------+------------+--------------+--------------+-----------
 use1-az4    | use1-az1   | 10.42.131.14 | 10.42.149.88 |  9214.771
 use1-az4    | use1-az2   | 10.42.131.14 | 10.42.166.31 |  8903.442
 use1-az1    | use1-az2   | 10.42.151.73 | 10.42.168.19 |  6188.019
 use1-az2    | use1-az4   | 10.42.166.31 | 10.42.132.20 |  5771.336
...
```

Three flows account for ~24 TB of the 41 TB. In this case they were a cache tier fanning out across all zones on every read — solved by `trafficDistribution: PreferClose` (§6.3), which cut the line item by roughly two-thirds without changing a line of application code.

---

## 10. Exam-focused distillation

The facts CLF-C02 is most likely to test on task 3.2:

1. **Region** = a geographic area with **multiple, isolated Availability Zones** (minimum three for new Regions). Regions are isolated from each other.
2. **Availability Zone** = one or more **discrete data centers** with redundant power, networking, and connectivity, physically separated by a meaningful distance (**within 100 km / 60 miles**) and connected by low-latency AWS fiber.
3. **Edge location / PoP** = where CloudFront caches content and Route 53/Global Accelerator terminate traffic close to users. There are **far more edge locations than Regions**.
4. **Regional Edge Cache** = CloudFront's mid-tier cache between PoPs and the origin.
5. **Local Zone** = an extension of a Region into a metro area for single-digit-millisecond latency.
6. **Wavelength Zone** = AWS infrastructure inside a **5G carrier network**, for mobile edge applications.
7. **Outposts** = AWS-managed hardware **in your own data center**, for on-premises and data-residency needs.
8. **Region selection factors**: **compliance/data governance**, **proximity/latency to users**, **service availability in the Region**, **pricing**. (Sustainability is a common fifth.)
9. **Global services**: IAM, Route 53, CloudFront, WAF (for CloudFront), Organizations, Shield.
10. **High availability within a Region** = deploy across **multiple AZs**. That is the answer to "how do I survive a data-center failure."
11. **Disaster recovery across Regions** = multi-Region, chosen from backup&restore / pilot light / warm standby / multi-site active-active.
12. **AWS Global Accelerator** = static anycast IPs and improved network performance; **CloudFront** = caching content at the edge. GA does not cache.

Traps that appear as distractors:

- "Availability Zone" is **not** a single data center; it is one *or more*.
- **Multi-AZ ≠ multi-Region.** Multi-AZ protects against a data-center failure; only multi-Region protects against a Region-wide event.
- An **edge location is not a Region** and does not run your EC2 instances.
- **Deploying to more AZs does not improve latency for global users** — that is what edge locations, Local Zones, or a second Region are for.
- **Data does not leave a Region automatically.** Cross-Region replication is something *you* enable.
- **Quotas and pricing are per Region**, not per account globally.
- A **Local Zone is generally a single zone** — it is not automatically highly available.

---

## 11. References

**Exam and curriculum**
- AWS Certified Cloud Practitioner (CLF-C02) Exam Guide — https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf
- AWS Certified Cloud Practitioner certification page — https://aws.amazon.com/certification/certified-cloud-practitioner/

**Global infrastructure (authoritative, updated continuously)**
- AWS Global Infrastructure — https://aws.amazon.com/about-aws/global-infrastructure/
- Regions and Availability Zones — https://aws.amazon.com/about-aws/global-infrastructure/regions_az/
- AWS Services by Region (Regional Services List) — https://aws.amazon.com/about-aws/global-infrastructure/regional-product-services/
- AWS Local Zones — https://aws.amazon.com/about-aws/global-infrastructure/localzones/
- AWS Wavelength — https://aws.amazon.com/wavelength/
- AWS Outposts — https://aws.amazon.com/outposts/
- Amazon CloudFront global edge network — https://aws.amazon.com/cloudfront/features/
- AWS GovCloud (US) — https://aws.amazon.com/govcloud-us/
- Amazon Web Services in China — https://www.amazonaws.cn/en/about-aws/china/

**Service documentation**
- Regions, Availability Zones, Local Zones and Wavelength Zones (EC2 User Guide) — https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/using-regions-availability-zones.html
- `describe-availability-zones` (AWS CLI reference) — https://docs.aws.amazon.com/cli/latest/reference/ec2/describe-availability-zones.html
- Specifying which Regions your account can use (Account Management) — https://docs.aws.amazon.com/accounts/latest/reference/manage-acct-regions.html
- Calling AWS Regional endpoints / AWS service endpoints — https://docs.aws.amazon.com/general/latest/gr/rande.html
- Managing AWS STS in an AWS Region (regional endpoints) — https://docs.aws.amazon.com/IAM/latest/UserGuide/id_credentials_temp_enable-regions.html
- Amazon Resource Names (ARNs) and AWS partitions — https://docs.aws.amazon.com/IAM/latest/UserGuide/reference-arns.html
- Calling global-infrastructure public parameters (Systems Manager) — https://docs.aws.amazon.com/systems-manager/latest/userguide/parameter-store-public-parameters-global-infrastructure.html
- VPC Flow Logs records (including `az-id`) — https://docs.aws.amazon.com/vpc/latest/userguide/flow-log-records.html
- AWS Global Accelerator Developer Guide — https://docs.aws.amazon.com/global-accelerator/latest/dg/what-is-global-accelerator.html
- Amazon Route 53 routing policies — https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/routing-policy.html
- Route 53 Application Recovery Controller — zonal shift — https://docs.aws.amazon.com/r53recovery/latest/dg/arc-zonal-shift.html
- Amazon EKS and AZ topology / EBS CSI zonal volumes — https://docs.aws.amazon.com/eks/latest/userguide/ebs-csi.html
- Kubernetes Pod Topology Spread Constraints — https://kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints/

**Architecture guidance**
- AWS Well-Architected Framework — Reliability Pillar — https://docs.aws.amazon.com/wellarchitected/latest/reliability-pillar/welcome.html
- Disaster Recovery of Workloads on AWS: Recovery in the Cloud — https://docs.aws.amazon.com/whitepapers/latest/disaster-recovery-workloads-on-aws/disaster-recovery-workloads-on-aws.html
- Static stability using Availability Zones (Amazon Builders' Library) — https://aws.amazon.com/builders-library/static-stability-using-availability-zones/
- Avoiding overload in distributed systems by putting the smaller service in control — https://aws.amazon.com/builders-library/
- AWS Fault Isolation Boundaries (AWS Whitepaper) — https://docs.aws.amazon.com/whitepapers/latest/aws-fault-isolation-boundaries/abstract-and-introduction.html

**Pricing (verify before quoting any figure)**
- Amazon EC2 On-Demand and data transfer pricing — https://aws.amazon.com/ec2/pricing/on-demand/
- Amazon VPC pricing (NAT Gateway, PrivateLink) — https://aws.amazon.com/vpc/pricing/
- AWS Pricing Calculator — https://calculator.aws/