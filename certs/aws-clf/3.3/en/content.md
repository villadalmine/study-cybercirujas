# 3.3 — Identify AWS Compute Services

**Certification:** AWS Certified Cloud Practitioner (CLF-C02, v1.0)
**Domain 3:** Cloud Technology and Services
**Task statement 3.3:** Identify AWS compute services
**Exam weight:** 4.25

---

## 1. The architectural problem

Every workload you run needs three things: a place for the process to execute, a way for that place to appear and disappear on demand, and a way for traffic to find it. "Compute" is the answer to the first, but the interesting engineering is in the second and third.

Consider a concrete production incident shape that recurs across organisations:

> A payments API runs on 12 long-lived virtual machines behind a load balancer. Traffic is bimodal: ~400 req/s for 20 hours a day, ~6,000 req/s during a 90-minute settlement window. The fleet is sized for the peak. For 22.5 hours a day, 92% of the purchased CPU is idle. When a host dies at 03:00, a human is paged to replace it. When the settlement window grows by 15%, someone must remember to raise the fleet size, and someone must remember to lower it again.

Every failure in that description is a failure of *elasticity coupling* — the capacity you pay for is coupled to the peak, not to the demand, and the recovery of a failed unit is coupled to a human. AWS compute services are best understood not as "kinds of servers" but as **points on a spectrum of how much of the undifferentiated work you hand over**, and each hand-over trades control for elasticity.

The four questions that decide where on that spectrum a workload belongs:

1. **What is the unit of failure and replacement?** A host? A container? A single invocation?
2. **What is the granularity of billing?** Hours? Seconds? Milliseconds of GB-second?
3. **Who patches the OS?** You, or AWS?
4. **How long does one unit of work run, and does it need to hold state between units?**

A Cloud Practitioner is expected to *identify* the services. A Platform Architect is expected to answer those four questions before choosing one. This material does both.

---

## 2. The compute spectrum — one axis, five stops

```
  MORE CONTROL                                                 LESS OPERATIONAL WORK
  ◄────────────────────────────────────────────────────────────────────────────────►

  Outposts /      EC2            ECS/EKS on EC2   ECS/EKS on      Lambda
  Dedicated       (VM)           (containers on   Fargate         (function)
  Hosts                           your VMs)       (containers,     App Runner
  (hardware)                                       no VMs)         Beanstalk*

  You own:        You own:        You own:         You own:        You own:
  hardware        OS, patching,   OS, patching,    container       code
  placement,      capacity,       cluster nodes,   image,          + config
  licensing       scaling         container image  task size
                  policy

  Billed:         Billed:         Billed:          Billed:         Billed:
  per host        per second      per second       per second      per request
  (3yr)           (min 60s)       (min 60s) of     of vCPU/GB      + GB-second
                                  the underlying   requested       consumed
                                  EC2 fleet
```

\* Elastic Beanstalk is a *provisioning and lifecycle layer* over EC2/ASG/ELB — the EC2 instances are in your account and you can SSH into them. It reduces work without removing control.

### 2.1 The shared responsibility line, made concrete

| Layer | EC2 | ECS/EKS on EC2 | Fargate | Lambda |
|---|---|---|---|---|
| Physical host, hypervisor | AWS | AWS | AWS | AWS |
| Guest OS + kernel patching | **You** | **You** | AWS | AWS |
| Container runtime / agent | n/a | **You** (via AMI) | AWS | AWS |
| Language runtime | **You** | **You** (image) | **You** (image) | AWS (managed runtimes) |
| Application code | **You** | **You** | **You** | **You** |
| Capacity/scaling policy | **You** | **You** | **You** (task count) | AWS (concurrency) |
| Network isolation (SG/subnet) | **You** | **You** | **You** | **You** (if in VPC) |

The exam phrasing for this: *"Which service requires the customer to patch the guest operating system?"* → EC2 (and ECS/EKS **on EC2**, because the nodes are EC2). Fargate and Lambda do not.

---

## 3. Amazon EC2 — the substrate

Amazon Elastic Compute Cloud provides resizable virtual machines ("instances") launched from an Amazon Machine Image (AMI) into a subnet of your VPC.

### 3.1 The Nitro System — why modern instance behaviour differs

Since the C5/M5 generation, EC2 runs on the **AWS Nitro System**: the virtualization stack (network, storage, security, monitoring) is offloaded from the main CPU onto dedicated Nitro Cards, and the hypervisor is a thin KVM-based component. Three consequences that matter operationally:

- **Near bare-metal performance.** Practically all host CPU and memory is available to guests; there is no "dom0 tax" to budget for.
- **EBS volumes are NVMe block devices.** Device names inside the guest are `/dev/nvme0n1`, `/dev/nvme1n1`… **not** the `/dev/sdf` you specified in the block device mapping. Scripts that hardcode `/dev/xvdf` break on Nitro — you must resolve the mapping with `lsblk`/`nvme id-ctrl`.
- **`.metal` instance types exist**, giving your OS direct access to the processor for workloads that need their own hypervisor or bare-metal licensing.

**Nitro Enclaves** carve an isolated, hardened compute environment out of an instance's own CPU and memory, with no persistent storage, no interactive access and no external network — used for processing highly sensitive data (PII, keys) with cryptographic attestation.

### 3.2 Instance families — reading the name

The type name is a grammar, not an opaque label:

```
        m 7 g d n . 2xlarge
        │ │ │ │ │      │
        │ │ │ │ │      └── size (vCPU/memory scale)
        │ │ │ │ └───────── n = network/EBS-optimized (higher bandwidth)
        │ │ │ └─────────── d = local NVMe instance store attached
        │ │ └───────────── processor: g = AWS Graviton (arm64), a = AMD EPYC,
        │ │                           i = Intel, (none) = generation default
        │ └─────────────── generation (7 = current gen at time of writing)
        └───────────────── family: workload class
```

Other suffixes you will meet: `e` (extra memory/storage), `z` (high CPU frequency), `b` (block-storage optimized), `q` (Qualcomm, inference), `flex` (e.g. `m7i-flex` — cheaper, reaches full CPU 95% of the time).

| Family class | Letters | Ratio / characteristic | Representative production use |
|---|---|---|---|
| General purpose | M, T, Mac | Balanced ~4 GB per vCPU | Web tier, app servers, small DBs, CI agents |
| Compute optimized | C | ~2 GB per vCPU, high clock | Ad serving, batch encoding, game servers, HPC front-ends |
| Memory optimized | R, X, U, z1d | 8–32+ GB per vCPU | In-memory caches, SAP HANA, large relational DBs, Spark executors |
| Storage optimized | I, D, H | Local NVMe / dense HDD, very high IOPS | Elasticsearch/OpenSearch data nodes, ClickHouse, NoSQL, data warehouses |
| Accelerated computing | P, G, Trn, Inf, F, VT | GPU / AWS Trainium / Inferentia / FPGA | Model training, inference, transcoding, genomics |
| HPC | Hpc6a, Hpc7g | High per-core perf + EFA networking | CFD, weather, molecular dynamics |

**Graviton (arm64)** is the default architecture choice for new stateless workloads: AWS publishes up to **40% better price-performance** versus comparable x86 instances for supported workloads. The cost of adoption is your build pipeline — you need arm64 container images and any native dependencies compiled for arm64.

### 3.3 The T family and the credit economy — a classic 3 a.m. incident

Burstable instances (T2/T3/T3a/T4g) do **not** give you the full vCPU continuously. They deliver a **baseline** fraction and accumulate **CPU credits** while below it; each credit buys one vCPU-minute at 100%.

| Type | vCPU | Baseline per vCPU | Credits earned/hour | Max banked credits |
|---|---|---|---|---|
| t3.nano | 2 | 5% | 6 | 144 |
| t3.micro | 2 | 10% | 12 | 288 |
| t3.small | 2 | 20% | 24 | 576 |
| t3.medium | 2 | 20% | 24 | 576 |
| t3.large | 2 | 30% | 36 | 864 |
| t3.xlarge | 4 | 40% | 96 | 2304 |
| t3.2xlarge | 8 | 40% | 192 | 4608 |

Two modes:

- **Standard** — when credits reach zero, the instance is *throttled* to baseline. Cheap, and catastrophic for latency. This is the T2 default.
- **Unlimited** — the instance keeps bursting and you are billed a surplus rate per vCPU-hour. This is the **T3/T3a/T4g default**.

> **Failure signature:** p99 latency rises from 40 ms to 3,000 ms over ~2 hours with no traffic change and no code deploy. `CPUUtilization` is pinned at exactly the baseline (e.g. 20%) and `CPUCreditBalance` is 0. The instance is not "slow" — it is being throttled by design. Fix: switch to unlimited mode, or move to a fixed-performance family (M/C).

### 3.4 Purchasing options — the cost lever

| Option | Commitment | Typical discount | Interruptible? | Best fit |
|---|---|---|---|---|
| **On-Demand** | none | 0% (baseline) | No | Spiky/unknown demand, dev, short tests |
| **Savings Plans — Compute** | 1 or 3 yr, $/hour | up to **66%** | No | Steady baseline; applies across EC2 **and Fargate and Lambda**, any region, any family |
| **Savings Plans — EC2 Instance** | 1 or 3 yr, $/hour | up to **72%** | No | Steady baseline locked to a family + region |
| **Reserved Instances — Standard** | 1 or 3 yr, capacity | up to **72%** | No | Very stable, known instance type |
| **Reserved Instances — Convertible** | 1 or 3 yr | up to **66%** | No | Stable spend, expected family changes |
| **Spot Instances** | none | up to **90%** | **Yes — 2-min notice** | Stateless, fault-tolerant, checkpointable: CI, batch, rendering, big-data, stateless web behind an ASG |
| **Dedicated Instances** | none / RI | premium | No | Hardware isolated from other AWS accounts |
| **Dedicated Hosts** | none / RI / SP | premium | No | **BYOL** socket/core-bound licences (Windows Server, Oracle, SQL Server), physical-server visibility, compliance |
| **On-Demand Capacity Reservations (ODCR)** | none, billed while held | 0% (combinable with SP/RI) | No | Guaranteeing capacity in an AZ for DR failover or a launch event |

Critical distinctions the exam probes:

- **Savings Plans and RIs are billing constructs, not capacity guarantees** — except *zonal* RIs, which do include a capacity reservation in a specific AZ. Regional RIs do **not** reserve capacity.
- **Only Dedicated Hosts give you visibility of sockets/cores and support most BYOL models.** Dedicated *Instances* give isolation but not host affinity or licensing visibility.
- **Spot is not "cheap On-Demand"** — it is spare capacity that AWS reclaims with a 2-minute warning. Design for it or do not use it.

Spot interruption handling — the instance polls its own metadata:

```bash
$ TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
$ curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
    http://169.254.169.254/latest/meta-data/spot/instance-action
{"action":"terminate","time":"2026-09-04T14:22:31Z"}
```

Before the terminate notice, AWS may emit an **EC2 Instance Rebalance Recommendation** — an earlier, softer signal that this instance is at elevated risk. Auto Scaling with **Capacity Rebalancing** enabled launches a replacement on that signal instead of waiting for the 2-minute notice.

### 3.5 Placement groups — controlling physical topology

| Type | Placement | Hard limit | Use for |
|---|---|---|---|
| **Cluster** | Packed into one rack, one AZ | — (capacity-bound) | Lowest latency, highest per-flow throughput: HPC, tightly-coupled MPI |
| **Spread** | Each instance on distinct hardware | **7 running instances per AZ per group** | Small numbers of critical, independent instances (e.g. 3 quorum members) |
| **Partition** | Groups of racks that share nothing | **7 partitions per AZ**, many instances each | Rack-aware distributed systems: HDFS, Cassandra, Kafka |

Cluster placement groups maximise performance and *minimise* fault isolation — a rack-level event takes the whole group. That is the trade-off; state it explicitly in a design review.

### 3.6 Instance store vs EBS

| | Instance store (`d` types) | Amazon EBS |
|---|---|---|
| Attachment | Physically on the host | Network-attached |
| Lifetime | **Lost on stop, hibernate, or host failure** | Persists independently of the instance |
| Performance | Highest IOPS, lowest latency | High, but network-bound (io2 Block Express up to 256,000 IOPS) |
| Snapshot | Not possible | To Amazon S3 |
| Use | Scratch, cache, buffers, shuffle space, replicated DB nodes | Root volumes, durable data |

### 3.7 Auto Scaling groups — where elasticity actually lives

An **Auto Scaling group (ASG)** maintains a desired count of instances across AZs, replaces unhealthy ones, and adjusts capacity from policies. It is the component that fixes both failures in the opening incident.

Scaling policy types:

| Policy | Mechanism | When to use |
|---|---|---|
| **Target tracking** | Keep a metric at a target (e.g. `ALBRequestCountPerTarget = 1000`) | Default choice — simplest correct answer |
| **Step scaling** | CloudWatch alarm → add/remove N by breach magnitude | Non-linear response needed |
| **Simple scaling** | Alarm → single adjustment + cooldown | Legacy; avoid |
| **Scheduled** | Change min/max/desired at a time | Known windows (the 90-minute settlement) |
| **Predictive** | ML forecast from history, pre-scales | Recurring daily/weekly patterns with slow-booting instances |

Health check types: **EC2** (hypervisor/instance status checks) and **ELB** (target group health). If you only use EC2 health checks, an instance whose *application* has hung but whose *kernel* is fine will stay in service forever. Always attach ELB health checks for a load-balanced tier.

**Warm pools** keep pre-initialised, stopped instances ready so scale-out latency is seconds rather than the full boot + bootstrap time.

---

## 4. Elastic Load Balancing — the traffic front door

| Type | OSI layer | Protocols | Key capability | Typical use |
|---|---|---|---|---|
| **Application Load Balancer (ALB)** | 7 | HTTP, HTTPS, gRPC, WebSocket | Host/path/header/query routing, OIDC auth, WAF integration, Lambda targets | Microservices, containers, web APIs |
| **Network Load Balancer (NLB)** | 4 | TCP, UDP, TLS | Millions of req/s, ultra-low latency, **static IP per AZ / Elastic IP**, preserves source IP | Non-HTTP, gaming, IoT, endpoints for PrivateLink |
| **Gateway Load Balancer (GWLB)** | 3 (gateway) | IP / GENEVE | Transparent insertion of third-party virtual appliances | Inline firewalls, IDS/IPS, deep packet inspection |
| **Classic Load Balancer (CLB)** | 4 & 7 | TCP, SSL, HTTP(S) | Legacy (EC2-Classic era) | Migrate away |

Exam trap: *"needs a static IP address"* → **NLB**. *"route `/api/v2/*` to a different target group"* → **ALB**.

---

## 5. Containers on AWS

### 5.1 The three orthogonal choices

Container decisions on AWS are three independent axes, and conflating them is the most common source of confusion:

1. **Registry** — where images live: **Amazon ECR** (private or public).
2. **Orchestrator** — what decides where containers run: **Amazon ECS** (AWS-native) or **Amazon EKS** (upstream-conformant Kubernetes).
3. **Launch type / compute** — what the containers run *on*: **EC2** instances you manage, or **AWS Fargate** (serverless).

You can combine any orchestrator with either launch type.

### 5.2 ECS vs EKS

| | Amazon ECS | Amazon EKS |
|---|---|---|
| API | Proprietary AWS (task definitions, services, clusters) | Upstream Kubernetes API, CNCF-conformant |
| Control plane cost | **Free** | Per-cluster hourly charge |
| Learning curve | Low — IAM, ALB, CloudWatch as you already know them | High — Kubernetes primitives + AWS integration (IRSA, VPC CNI, controllers) |
| Portability | AWS-only (ECS Anywhere extends to on-prem) | Portable across clouds and on-prem (EKS Anywhere, EKS Distro) |
| Ecosystem | AWS-native | Helm, Operators, Argo, Istio, Karpenter, Prometheus |
| Networking | `awsvpc` mode gives each task its own ENI + SG | VPC CNI gives each pod a VPC IP |
| Upgrade burden | Nearly none | Kubernetes minor version every ~4 months |
| Best for | Teams that want containers without owning a scheduler | Teams with Kubernetes skills, portability or ecosystem requirements |

### 5.3 EC2 launch type vs Fargate

| | ECS/EKS on EC2 | AWS Fargate |
|---|---|---|
| You manage | AMI, patching, node scaling, bin-packing, daemon containers | Nothing below the container |
| Billing unit | The EC2 instances (running or idle) | vCPU-seconds + GB-seconds **requested by the task**, min 1 minute |
| Density | You control it — can pack many small tasks per host | One task = one micro-VM; no over-subscription |
| GPU / special hardware | Yes | Limited (no GPU for Fargate) |
| Privileged containers, host networking, DaemonSets | Yes | **No** |
| Persistent local disk | Instance store / EBS | 20 GB ephemeral by default, configurable to **200 GB**; EFS for shared persistence |
| Startup latency | Fast if a node has room; slow if a node must launch | Tens of seconds, consistent |
| Cost profile | Cheaper at high, steady utilisation (>~70%) | Cheaper for spiky, low-density, or many-small-services workloads |

**Fargate task sizing is a fixed matrix.** You cannot request arbitrary combinations:

| vCPU | Valid memory |
|---|---|
| 0.25 | 0.5, 1, 2 GB |
| 0.5 | 1–4 GB (1 GB steps) |
| 1 | 2–8 GB (1 GB steps) |
| 2 | 4–16 GB (1 GB steps) |
| 4 | 8–30 GB (1 GB steps) |
| 8 | 16–60 GB (4 GB steps) |
| 16 | 32–120 GB (8 GB steps) |

**FARGATE_SPOT** applies the Spot model to Fargate tasks (Linux/X86) at a substantial discount, with a 2-minute `SIGTERM` before reclaim.

---

## 6. AWS Lambda — event-driven functions

Lambda runs your code in response to events, with no server or container for you to provision. You are billed per **request** and per **GB-second** of memory-time consumed, rounded to the millisecond.

### 6.1 The execution model — and why cold starts exist

```
 EVENT ──► [ Lambda service ]
              │
              ├─ warm execution environment available? ──► INVOKE handler ──► response
              │                                              (Duration)
              └─ none available ──► DOWNLOAD code/image
                                 ──► START runtime (micro-VM: Firecracker)
                                 ──► RUN init code (outside the handler)   ◄── InitDuration
                                 ──► INVOKE handler
```

The `InitDuration` phase runs **once per execution environment**, not once per invocation. Everything you place outside the handler — SDK clients, DB connection pools, config parsing — is paid for at init and reused across subsequent invocations on the same environment. This is the single highest-leverage Lambda optimisation.

Mitigations for cold-start-sensitive paths:
- **Provisioned Concurrency** — keep N environments initialised and warm; billed per hour.
- **SnapStart** — snapshot the post-init environment and restore from it (Java, Python, .NET). Beware: entropy and unique IDs generated at init are cloned across restores; use the runtime hooks to re-seed.

### 6.2 Hard quotas you must design around

| Quota | Value |
|---|---|
| Maximum execution timeout | **900 s (15 minutes)** |
| Memory | 128 MB – **10,240 MB** (1 MB increments) |
| vCPU allocation | Proportional to memory; ~1,769 MB ≈ 1 full vCPU, up to 6 vCPU |
| `/tmp` ephemeral storage | 512 MB – 10,240 MB |
| Deployment package (zip, direct upload) | 50 MB |
| Deployment package (unzipped, incl. layers) | 250 MB |
| Container image | 10 GB |
| Layers per function | 5 |
| Synchronous request/response payload | 6 MB |
| Asynchronous event payload | 256 KB |
| Environment variables (total) | 4 KB |
| Default concurrent executions per account/region | 1,000 (soft — raisable) |

**Memory is your only performance dial.** Because CPU scales with memory, a CPU-bound function at 1,024 MB may finish in half the time at 2,048 MB — costing the *same* GB-seconds while halving latency. Never tune Lambda memory by intuition; measure.

### 6.3 Concurrency vocabulary

- **Unreserved / account concurrency** — the shared pool (default 1,000).
- **Reserved concurrency** — a ceiling *and* a guarantee for one function. It carves capacity out of the shared pool. Setting it to `0` is the emergency stop-the-world switch for a misbehaving function.
- **Provisioned concurrency** — pre-initialised environments, drawn from the function's reserved (or unreserved) capacity.

### 6.4 Where Lambda is the wrong answer

- Work that exceeds 15 minutes → **AWS Batch**, ECS/Fargate task, or Step Functions orchestrating chunks.
- Sustained, predictable, high-throughput compute → EC2/Fargate is cheaper per unit of work.
- Workloads requiring a persistent local filesystem larger than 10 GB or shared state → Fargate + EFS, or EC2.
- Anything needing a long-lived listening socket (a database, a stateful gateway).

---

## 7. The higher-abstraction and specialised services

| Service | What it is | Choose it when |
|---|---|---|
| **AWS Elastic Beanstalk** | PaaS that provisions and manages EC2 + ASG + ELB + CloudWatch from your uploaded code. Supports Java, .NET, PHP, Node.js, Python, Ruby, Go, Docker. | You want a full environment without writing infrastructure, but still want EC2-level access. Beanstalk itself is **free** — you pay for the resources it creates. |
| **AWS App Runner** | Fully managed: point it at a container image in ECR or a source repo; it builds, deploys, load-balances and auto-scales an HTTPS service. | A single containerised web service/API with no desire to see a VPC, load balancer or cluster. |
| **Amazon Lightsail** | Bundled VPS: instance + storage + transfer at a fixed, predictable monthly price. Also databases, containers, load balancers. | Simple websites, WordPress, dev sandboxes, users who want a fixed bill. |
| **AWS Batch** | Managed batch scheduling: job queues, job definitions, compute environments on EC2 (incl. Spot), Fargate or EKS. Handles array jobs and dependency graphs. | Thousands of independent jobs — genomics, risk simulation, media transcode — where you want optimal instance selection and Spot economics. |
| **AWS Outposts** | AWS-designed racks/servers installed in **your** data centre, running native AWS APIs, managed by AWS. | Low-latency to on-prem systems, or data-residency requirements that forbid the Region. |
| **AWS Local Zones** | AWS infrastructure placed in a metropolitan area close to large populations. | Single-digit-millisecond latency to end users in a specific city (media, gaming, remote workstations). |
| **AWS Wavelength** | Compute embedded in telecom providers' 5G networks. | Ultra-low latency to mobile devices — AR/VR, connected vehicles, live video. |
| **AWS Snowball Edge (Compute Optimized)** | Ruggedised device with local EC2-compatible compute and storage. | Disconnected, remote or harsh environments: ships, mines, disaster response. |
| **Lambda@Edge / CloudFront Functions** | Code executed at CloudFront edge locations. CloudFront Functions: sub-millisecond, JS, header/URL manipulation. Lambda@Edge: heavier, full Lambda runtime. | Request/response manipulation, A/B routing, auth at the edge. |
| **AWS Compute Optimizer** | Analyses CloudWatch metrics and recommends right-sized EC2, ASG, EBS, Lambda and ECS-on-Fargate configurations. | Cost optimisation reviews. |

---

## 8. Decision matrix — the one table to internalise

| Requirement in the question stem | Correct service |
|---|---|
| Full control over OS, install custom kernel modules | **EC2** |
| Need macOS build agents for iOS | **EC2 Mac instances** |
| Bring your own Windows/Oracle licence bound to physical cores | **EC2 Dedicated Hosts** |
| Physical isolation from other AWS customers, no licence needs | **EC2 Dedicated Instances** |
| Fault-tolerant, stateless batch, minimise cost, tolerate interruption | **EC2 Spot Instances** |
| Steady-state usage for 1–3 years, want maximum discount across EC2 + Fargate + Lambda | **Compute Savings Plans** |
| Run Docker containers, AWS-native orchestrator, no control-plane fee | **Amazon ECS** |
| Run Kubernetes, keep portability and the CNCF ecosystem | **Amazon EKS** |
| Run containers without managing any servers | **AWS Fargate** |
| Store and scan container images | **Amazon ECR** |
| Run code in response to an S3 upload / SQS message, pay per invocation | **AWS Lambda** |
| Job runs 45 minutes and processes a large dataset | **AWS Batch** (or Fargate/ECS task) — *not* Lambda |
| Deploy an application without configuring infrastructure, but keep EC2 access | **AWS Elastic Beanstalk** |
| Deploy a single container as a web service with zero infrastructure config | **AWS App Runner** |
| Simple, fixed monthly price VPS for a small website | **Amazon Lightsail** |
| Run AWS services physically inside my own data centre | **AWS Outposts** |
| Single-digit-ms latency to users in a specific city | **AWS Local Zones** |
| Ultra-low latency to 5G mobile users | **AWS Wavelength** |
| Automatically replace unhealthy instances and match capacity to demand | **EC2 Auto Scaling** |
| Route HTTPS traffic by URL path to different services | **Application Load Balancer** |
| Millions of TCP connections with a static IP | **Network Load Balancer** |
| Recommend right-sized instances from real utilisation | **AWS Compute Optimizer** |

---

## 9. Complete infrastructure — CloudFormation

A production-shaped EC2 tier: IMDSv2 enforced, Graviton with x86 fallback via a mixed-instances policy, Spot for a share of capacity, ALB target tracking, SSM Session Manager instead of SSH, encrypted EBS, instance refresh on template change.

```yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: >-
  Reference EC2 compute tier for CLF-C02 topic 3.3 — Auto Scaling group with a
  mixed-instances policy (Graviton on-demand baseline + Spot burst) behind an
  Application Load Balancer, IMDSv2 enforced, access via SSM Session Manager.

Parameters:
  VpcId:
    Type: AWS::EC2::VPC::Id
    Description: VPC that already contains the public and private subnets below.

  PublicSubnetIds:
    Type: List<AWS::EC2::Subnet::Id>
    Description: At least two public subnets in distinct AZs, for the ALB.

  PrivateSubnetIds:
    Type: List<AWS::EC2::Subnet::Id>
    Description: At least two private subnets in distinct AZs, for the instances.

  LatestArm64AmiId:
    Type: AWS::SSM::Parameter::Value<AWS::EC2::Image::Id>
    Default: /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64
    Description: >-
      Resolved at stack create/update time from the AWS-published SSM public
      parameter. Never hardcode an AMI ID — they are region-specific and go stale.

  OnDemandBaseCapacity:
    Type: Number
    Default: 2
    Description: Instances always served by On-Demand before Spot is used.

  OnDemandPercentageAboveBase:
    Type: Number
    Default: 25
    Description: Percentage of capacity above the base that is On-Demand.

  MinSize:
    Type: Number
    Default: 2

  MaxSize:
    Type: Number
    Default: 20

Resources:

  # ------------------------------------------------------------------
  # Security groups
  # ------------------------------------------------------------------
  AlbSecurityGroup:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: Ingress for the public Application Load Balancer
      VpcId: !Ref VpcId
      SecurityGroupIngress:
        - IpProtocol: tcp
          FromPort: 443
          ToPort: 443
          CidrIp: 0.0.0.0/0
          Description: Public HTTPS
      Tags:
        - Key: Name
          Value: !Sub '${AWS::StackName}-alb-sg'

  InstanceSecurityGroup:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: Application instances — only the ALB may reach them
      VpcId: !Ref VpcId
      SecurityGroupIngress:
        - IpProtocol: tcp
          FromPort: 8080
          ToPort: 8080
          SourceSecurityGroupId: !Ref AlbSecurityGroup
          Description: Application port from the ALB only
      Tags:
        - Key: Name
          Value: !Sub '${AWS::StackName}-instance-sg'

  # ------------------------------------------------------------------
  # Instance identity: no SSH keys, no long-lived credentials
  # ------------------------------------------------------------------
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

  # ------------------------------------------------------------------
  # Launch template
  # ------------------------------------------------------------------
  LaunchTemplate:
    Type: AWS::EC2::LaunchTemplate
    Properties:
      LaunchTemplateName: !Sub '${AWS::StackName}-lt'
      LaunchTemplateData:
        ImageId: !Ref LatestArm64AmiId
        IamInstanceProfile:
          Arn: !GetAtt InstanceProfile.Arn
        SecurityGroupIds:
          - !Ref InstanceSecurityGroup
        MetadataOptions:
          HttpTokens: required          # IMDSv2 only — blocks SSRF credential theft
          HttpPutResponseHopLimit: 1    # raise to 2 only if containers need IMDS
          HttpEndpoint: enabled
        Monitoring:
          Enabled: true                 # 1-minute CloudWatch metrics
        BlockDeviceMappings:
          - DeviceName: /dev/xvda
            Ebs:
              VolumeSize: 30
              VolumeType: gp3
              Iops: 3000
              Throughput: 125
              Encrypted: true
              DeleteOnTermination: true
        TagSpecifications:
          - ResourceType: instance
            Tags:
              - Key: Name
                Value: !Sub '${AWS::StackName}-app'
              - Key: Environment
                Value: production
        UserData:
          Fn::Base64: !Sub |
            #!/bin/bash
            set -euxo pipefail

            dnf -y update
            dnf -y install python3.12 amazon-cloudwatch-agent

            # Minimal health-serving application so the target group can pass.
            cat >/opt/app.py <<'PYEOF'
            from http.server import BaseHTTPRequestHandler, HTTPServer

            class Handler(BaseHTTPRequestHandler):
                def do_GET(self):
                    if self.path == "/healthz":
                        self.send_response(200)
                        self.send_header("Content-Type", "text/plain")
                        self.end_headers()
                        self.wfile.write(b"ok\n")
                    else:
                        self.send_response(200)
                        self.send_header("Content-Type", "text/plain")
                        self.end_headers()
                        self.wfile.write(b"hello from the compute tier\n")

                def log_message(self, fmt, *args):
                    pass

            HTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
            PYEOF

            cat >/etc/systemd/system/app.service <<'UNITEOF'
            [Unit]
            Description=Demo application
            After=network-online.target
            Wants=network-online.target

            [Service]
            ExecStart=/usr/bin/python3.12 /opt/app.py
            Restart=always
            RestartSec=2

            [Install]
            WantedBy=multi-user.target
            UNITEOF

            systemctl daemon-reload
            systemctl enable --now app.service

            # Handle Spot interruption: drain before the 2-minute deadline expires.
            cat >/opt/spot-watch.sh <<'SPOTEOF'
            #!/bin/bash
            while true; do
              TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" \
                -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
              CODE=$(curl -s -o /dev/null -w "%{http_code}" \
                -H "X-aws-ec2-metadata-token: $TOKEN" \
                http://169.254.169.254/latest/meta-data/spot/instance-action)
              if [ "$CODE" = "200" ]; then
                logger -t spot-watch "interruption notice received; stopping app"
                systemctl stop app.service   # fail health checks -> ALB deregisters
                sleep 120
              fi
              sleep 5
            done
            SPOTEOF
            chmod +x /opt/spot-watch.sh

            cat >/etc/systemd/system/spot-watch.service <<'SWEOF'
            [Unit]
            Description=Spot interruption watcher

            [Service]
            ExecStart=/opt/spot-watch.sh
            Restart=always

            [Install]
            WantedBy=multi-user.target
            SWEOF

            systemctl daemon-reload
            systemctl enable --now spot-watch.service

  # ------------------------------------------------------------------
  # Load balancer
  # ------------------------------------------------------------------
  LoadBalancer:
    Type: AWS::ElasticLoadBalancingV2::LoadBalancer
    Properties:
      Name: !Sub '${AWS::StackName}-alb'
      Type: application
      Scheme: internet-facing
      IpAddressType: ipv4
      Subnets: !Ref PublicSubnetIds
      SecurityGroups:
        - !Ref AlbSecurityGroup
      LoadBalancerAttributes:
        - Key: routing.http.drop_invalid_header_fields.enabled
          Value: 'true'
        - Key: deletion_protection.enabled
          Value: 'true'

  TargetGroup:
    Type: AWS::ElasticLoadBalancingV2::TargetGroup
    Properties:
      Name: !Sub '${AWS::StackName}-tg'
      VpcId: !Ref VpcId
      Port: 8080
      Protocol: HTTP
      TargetType: instance
      HealthCheckPath: /healthz
      HealthCheckProtocol: HTTP
      HealthCheckIntervalSeconds: 15
      HealthCheckTimeoutSeconds: 5
      HealthyThresholdCount: 2
      UnhealthyThresholdCount: 3
      Matcher:
        HttpCode: '200'
      TargetGroupAttributes:
        - Key: deregistration_delay.timeout_seconds
          Value: '30'
        - Key: load_balancing.algorithm.type
          Value: least_outstanding_requests

  HttpsListener:
    Type: AWS::ElasticLoadBalancingV2::Listener
    Properties:
      LoadBalancerArn: !Ref LoadBalancer
      Port: 443
      Protocol: HTTPS
      SslPolicy: ELBSecurityPolicy-TLS13-1-2-2021-06
      Certificates:
        - CertificateArn: !Ref AcmCertificateArn
      DefaultActions:
        - Type: forward
          TargetGroupArn: !Ref TargetGroup

  # ------------------------------------------------------------------
  # Auto Scaling group — the elasticity and self-healing layer
  # ------------------------------------------------------------------
  AutoScalingGroup:
    Type: AWS::AutoScaling::AutoScalingGroup
    UpdatePolicy:
      AutoScalingRollingUpdate:
        MinInstancesInService: !Ref MinSize
        MaxBatchSize: 2
        PauseTime: PT5M
        WaitOnResourceSignals: false
        SuspendProcesses:
          - HealthCheck
          - ReplaceUnhealthy
          - AZRebalance
          - AlarmNotification
          - ScheduledActions
    Properties:
      AutoScalingGroupName: !Sub '${AWS::StackName}-asg'
      VPCZoneIdentifier: !Ref PrivateSubnetIds
      MinSize: !Ref MinSize
      MaxSize: !Ref MaxSize
      DesiredCapacity: !Ref MinSize
      HealthCheckType: ELB              # application health, not just kernel health
      HealthCheckGracePeriod: 180       # must exceed boot + bootstrap time
      CapacityRebalance: true           # act on Spot rebalance recommendations
      TargetGroupARNs:
        - !Ref TargetGroup
      MetricsCollection:
        - Granularity: 1Minute
      MixedInstancesPolicy:
        InstancesDistribution:
          OnDemandBaseCapacity: !Ref OnDemandBaseCapacity
          OnDemandPercentageAboveBaseCapacity: !Ref OnDemandPercentageAboveBase
          SpotAllocationStrategy: price-capacity-optimized
          OnDemandAllocationStrategy: lowest-price
        LaunchTemplate:
          LaunchTemplateSpecification:
            LaunchTemplateId: !Ref LaunchTemplate
            Version: !GetAtt LaunchTemplate.LatestVersionNumber
          Overrides:
            # Multiple types = multiple Spot capacity pools = fewer interruptions
            # and a real answer to InsufficientInstanceCapacity.
            - InstanceType: m7g.large
            - InstanceType: m6g.large
            - InstanceType: c7g.large
            - InstanceType: c6g.large
            - InstanceType: r7g.large
      Tags:
        - Key: Name
          Value: !Sub '${AWS::StackName}-app'
          PropagateAtLaunch: true

  ScaleOnRequestCount:
    Type: AWS::AutoScaling::ScalingPolicy
    Properties:
      AutoScalingGroupName: !Ref AutoScalingGroup
      PolicyType: TargetTrackingScaling
      EstimatedInstanceWarmup: 180
      TargetTrackingConfiguration:
        TargetValue: 1000
        PredefinedMetricSpecification:
          PredefinedMetricType: ALBRequestCountPerTarget
          ResourceLabel: !Join
            - '/'
            - - !GetAtt LoadBalancer.LoadBalancerFullName
              - !GetAtt TargetGroup.TargetGroupFullName

  # Deterministic pre-scale for the known settlement window (UTC).
  ScheduledSettlementScaleOut:
    Type: AWS::AutoScaling::ScheduledAction
    Properties:
      AutoScalingGroupName: !Ref AutoScalingGroup
      Recurrence: '45 21 * * *'
      MinSize: 12
      DesiredCapacity: 12
      MaxSize: !Ref MaxSize
      TimeZone: UTC

  ScheduledSettlementScaleIn:
    Type: AWS::AutoScaling::ScheduledAction
    Properties:
      AutoScalingGroupName: !Ref AutoScalingGroup
      Recurrence: '30 23 * * *'
      MinSize: !Ref MinSize
      DesiredCapacity: !Ref MinSize
      MaxSize: !Ref MaxSize
      TimeZone: UTC

Outputs:
  LoadBalancerDnsName:
    Description: Public DNS name of the ALB
    Value: !GetAtt LoadBalancer.DNSName
    Export:
      Name: !Sub '${AWS::StackName}-alb-dns'

  AutoScalingGroupName:
    Description: Name of the Auto Scaling group
    Value: !Ref AutoScalingGroup

  TargetGroupArn:
    Description: ARN of the target group
    Value: !Ref TargetGroup
```

> The template references a parameter `AcmCertificateArn` used by `HttpsListener`. Add it to `Parameters` as `Type: String` with a description "ARN of an ACM certificate in this Region for the ALB listener" before deploying — CloudFormation validates parameter references at template parse time and will reject the stack otherwise.

---

## 10. Containers — full ECS on Fargate definition

### 10.1 Task definition (register directly with the CLI)

`task-definition.json`:

```json
{
  "family": "payments-api",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "1024",
  "memory": "2048",
  "runtimePlatform": {
    "cpuArchitecture": "ARM64",
    "operatingSystemFamily": "LINUX"
  },
  "ephemeralStorage": {
    "sizeInGiB": 21
  },
  "executionRoleArn": "arn:aws:iam::111122223333:role/ecsTaskExecutionRole",
  "taskRoleArn": "arn:aws:iam::111122223333:role/paymentsApiTaskRole",
  "containerDefinitions": [
    {
      "name": "api",
      "image": "111122223333.dkr.ecr.eu-west-1.amazonaws.com/payments-api:2026.09.04-a1b2c3d",
      "essential": true,
      "cpu": 896,
      "memoryReservation": 1536,
      "portMappings": [
        {
          "name": "http",
          "containerPort": 8080,
          "protocol": "tcp",
          "appProtocol": "http"
        }
      ],
      "environment": [
        { "name": "LOG_LEVEL", "value": "info" },
        { "name": "AWS_REGION", "value": "eu-west-1" }
      ],
      "secrets": [
        {
          "name": "DB_PASSWORD",
          "valueFrom": "arn:aws:secretsmanager:eu-west-1:111122223333:secret:prod/payments/db-AbCdEf"
        }
      ],
      "healthCheck": {
        "command": ["CMD-SHELL", "curl -fsS http://localhost:8080/healthz || exit 1"],
        "interval": 15,
        "timeout": 5,
        "retries": 3,
        "startPeriod": 30
      },
      "ulimits": [
        { "name": "nofile", "softLimit": 65536, "hardLimit": 65536 }
      ],
      "stopTimeout": 30,
      "readonlyRootFilesystem": true,
      "linuxParameters": {
        "initProcessEnabled": true
      },
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/payments-api",
          "awslogs-region": "eu-west-1",
          "awslogs-stream-prefix": "api",
          "awslogs-create-group": "true",
          "mode": "non-blocking",
          "max-buffer-size": "4m"
        }
      }
    },
    {
      "name": "otel-collector",
      "image": "public.ecr.aws/aws-observability/aws-otel-collector:latest",
      "essential": false,
      "cpu": 128,
      "memoryReservation": 512,
      "command": ["--config=/etc/ecs/ecs-default-config.yaml"],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/payments-api",
          "awslogs-region": "eu-west-1",
          "awslogs-stream-prefix": "otel",
          "awslogs-create-group": "true"
        }
      }
    }
  ]
}
```

Note the container-level `cpu` values (896 + 128 = 1024) sum to the task-level `cpu`. `readonlyRootFilesystem: true` and `initProcessEnabled: true` (reaps zombie processes) are production defaults, not optional polish.

### 10.2 The ECS service, in CloudFormation

```yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: ECS service on Fargate with a Spot-weighted capacity provider strategy.

Parameters:
  ClusterName:
    Type: String
  TaskDefinitionArn:
    Type: String
  TargetGroupArn:
    Type: String
  PrivateSubnetIds:
    Type: List<AWS::EC2::Subnet::Id>
  ServiceSecurityGroupId:
    Type: AWS::EC2::SecurityGroup::Id

Resources:
  Service:
    Type: AWS::ECS::Service
    Properties:
      ServiceName: payments-api
      Cluster: !Ref ClusterName
      TaskDefinition: !Ref TaskDefinitionArn
      DesiredCount: 6
      PropagateTags: SERVICE
      EnableExecuteCommand: true        # `aws ecs execute-command` shell, no bastion
      HealthCheckGracePeriodSeconds: 60

      # Two On-Demand tasks always; everything above that is 3:1 Spot:On-Demand.
      CapacityProviderStrategy:
        - CapacityProvider: FARGATE
          Base: 2
          Weight: 1
        - CapacityProvider: FARGATE_SPOT
          Base: 0
          Weight: 3

      NetworkConfiguration:
        AwsvpcConfiguration:
          Subnets: !Ref PrivateSubnetIds
          SecurityGroups:
            - !Ref ServiceSecurityGroupId
          AssignPublicIp: DISABLED      # requires NAT GW or ECR/S3/Logs VPC endpoints

      LoadBalancers:
        - ContainerName: api
          ContainerPort: 8080
          TargetGroupArn: !Ref TargetGroupArn

      DeploymentConfiguration:
        MaximumPercent: 200
        MinimumHealthyPercent: 100
        DeploymentCircuitBreaker:
          Enable: true
          Rollback: true                # auto-revert a deployment that never stabilises

  ScalableTarget:
    Type: AWS::ApplicationAutoScaling::ScalableTarget
    Properties:
      ServiceNamespace: ecs
      ScalableDimension: ecs:service:DesiredCount
      ResourceId: !Sub 'service/${ClusterName}/payments-api'
      MinCapacity: 6
      MaxCapacity: 60
      RoleARN: !Sub 'arn:aws:iam::${AWS::AccountId}:role/aws-service-role/ecs.application-autoscaling.amazonaws.com/AWSServiceRoleForApplicationAutoScaling_ECSService'
    DependsOn: Service

  ScalingPolicy:
    Type: AWS::ApplicationAutoScaling::ScalingPolicy
    Properties:
      PolicyName: payments-api-cpu-target
      PolicyType: TargetTrackingScaling
      ScalingTargetId: !Ref ScalableTarget
      TargetTrackingScalingPolicyConfiguration:
        TargetValue: 60.0
        PredefinedMetricSpecification:
          PredefinedMetricType: ECSServiceAverageCPUUtilization
        ScaleInCooldown: 300
        ScaleOutCooldown: 60
```

### 10.3 The same workload on EKS

```yaml
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: payments-api
  namespace: payments
  annotations:
    # IRSA: the pod assumes this IAM role via an OIDC-federated web identity.
    eks.amazonaws.com/role-arn: arn:aws:iam::111122223333:role/paymentsApiPodRole
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payments-api
  namespace: payments
  labels:
    app.kubernetes.io/name: payments-api
spec:
  replicas: 6
  revisionHistoryLimit: 5
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 0
      maxSurge: 2
  selector:
    matchLabels:
      app.kubernetes.io/name: payments-api
  template:
    metadata:
      labels:
        app.kubernetes.io/name: payments-api
    spec:
      serviceAccountName: payments-api
      terminationGracePeriodSeconds: 45
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        fsGroup: 10001
        seccompProfile:
          type: RuntimeDefault
      # Spread across AZs so one AZ event cannot take a majority of replicas.
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: payments-api
      containers:
        - name: api
          image: 111122223333.dkr.ecr.eu-west-1.amazonaws.com/payments-api:2026.09.04-a1b2c3d
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 8080
          env:
            - name: LOG_LEVEL
              value: info
          resources:
            # requests == limits for memory (no overcommit on a non-compressible
            # resource). CPU limit omitted deliberately: CFS throttling at the
            # limit hurts p99 more than a noisy neighbour does.
            requests:
              cpu: 500m
              memory: 1Gi
            limits:
              memory: 1Gi
          startupProbe:
            httpGet: { path: /healthz, port: http }
            periodSeconds: 3
            failureThreshold: 30
          readinessProbe:
            httpGet: { path: /healthz, port: http }
            periodSeconds: 5
            timeoutSeconds: 2
            failureThreshold: 3
          livenessProbe:
            httpGet: { path: /livez, port: http }
            periodSeconds: 10
            timeoutSeconds: 2
            failureThreshold: 5
          lifecycle:
            preStop:
              exec:
                # Let the ALB deregister before the process dies.
                command: ["/bin/sh", "-c", "sleep 15"]
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: tmp
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: payments-api
  namespace: payments
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: payments-api
  ports:
    - name: http
      port: 80
      targetPort: http
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: payments-api
  namespace: payments
spec:
  minAvailable: 80%
  selector:
    matchLabels:
      app.kubernetes.io/name: payments-api
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: payments-api
  namespace: payments
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: payments-api
  minReplicas: 6
  maxReplicas: 60
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 60
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 0
      policies:
        - type: Percent
          value: 100
          periodSeconds: 30
    scaleDown:
      stabilizationWindowSeconds: 300
      policies:
        - type: Percent
          value: 25
          periodSeconds: 60
---
# Run this namespace's pods on Fargate — no worker nodes to patch.
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig
metadata:
  name: payments-prod
  region: eu-west-1
fargateProfiles:
  - name: payments
    selectors:
      - namespace: payments
        labels:
          app.kubernetes.io/name: payments-api
    subnets:
      - subnet-0a1b2c3d4e5f60718
      - subnet-0b2c3d4e5f6071829
```

---

## 11. Serverless — a complete AWS SAM template

```yaml
AWSTemplateFormatVersion: '2010-09-09'
Transform: AWS::Serverless-2016-10-31
Description: >-
  Event-driven settlement processor: SQS -> Lambda -> DynamoDB, with a
  dead-letter queue, reserved concurrency and X-Ray tracing.

Globals:
  Function:
    Runtime: python3.12
    Architectures: [arm64]        # ~20% cheaper per GB-second than x86_64
    Timeout: 60
    MemorySize: 1024
    Tracing: Active
    LoggingConfig:
      LogFormat: JSON
      ApplicationLogLevel: INFO
      SystemLogLevel: WARN
    Environment:
      Variables:
        POWERTOOLS_SERVICE_NAME: settlement
        TABLE_NAME: !Ref SettlementTable

Resources:

  SettlementQueue:
    Type: AWS::SQS::Queue
    Properties:
      QueueName: settlement-events
      VisibilityTimeout: 360        # >= 6 x function timeout, per AWS guidance
      MessageRetentionPeriod: 345600
      RedrivePolicy:
        deadLetterTargetArn: !GetAtt SettlementDlq.Arn
        maxReceiveCount: 3

  SettlementDlq:
    Type: AWS::SQS::Queue
    Properties:
      QueueName: settlement-events-dlq
      MessageRetentionPeriod: 1209600   # 14 days, the maximum

  SettlementTable:
    Type: AWS::DynamoDB::Table
    Properties:
      TableName: settlement-records
      BillingMode: PAY_PER_REQUEST
      AttributeDefinitions:
        - AttributeName: pk
          AttributeType: S
        - AttributeName: sk
          AttributeType: S
      KeySchema:
        - AttributeName: pk
          KeyType: HASH
        - AttributeName: sk
          KeyType: RANGE
      PointInTimeRecoverySpecification:
        PointInTimeRecoveryEnabled: true
      SSESpecification:
        SSEEnabled: true

  SettlementFunction:
    Type: AWS::Serverless::Function
    Properties:
      FunctionName: settlement-processor
      CodeUri: src/settlement/
      Handler: app.lambda_handler
      # Ceiling AND floor: caps blast radius on a poison-pill storm and
      # guarantees this function is never starved by a noisy neighbour.
      ReservedConcurrentExecutions: 100
      ProvisionedConcurrencyConfig:
        ProvisionedConcurrentExecutions: 10
      AutoPublishAlias: live
      DeploymentPreference:
        Type: Canary10Percent5Minutes
        Alarms:
          - !Ref FunctionErrorAlarm
      Policies:
        - DynamoDBCrudPolicy:
            TableName: !Ref SettlementTable
        - SQSPollerPolicy:
            QueueName: !GetAtt SettlementQueue.QueueName
      Events:
        SqsBatch:
          Type: SQS
          Properties:
            Queue: !GetAtt SettlementQueue.Arn
            BatchSize: 10
            MaximumBatchingWindowInSeconds: 5
            FunctionResponseTypes:
              - ReportBatchItemFailures   # partial batch failure, not all-or-nothing
            ScalingConfig:
              MaximumConcurrency: 50

  FunctionErrorAlarm:
    Type: AWS::CloudWatch::Alarm
    Properties:
      AlarmName: settlement-processor-errors
      Namespace: AWS/Lambda
      MetricName: Errors
      Dimensions:
        - Name: FunctionName
          Value: !Ref SettlementFunction
      Statistic: Sum
      Period: 60
      EvaluationPeriods: 2
      Threshold: 5
      ComparisonOperator: GreaterThanOrEqualToThreshold
      TreatMissingData: notBreaching

  ThrottleAlarm:
    Type: AWS::CloudWatch::Alarm
    Properties:
      AlarmName: settlement-processor-throttles
      Namespace: AWS/Lambda
      MetricName: Throttles
      Dimensions:
        - Name: FunctionName
          Value: !Ref SettlementFunction
      Statistic: Sum
      Period: 60
      EvaluationPeriods: 1
      Threshold: 1
      ComparisonOperator: GreaterThanOrEqualToThreshold
      TreatMissingData: notBreaching

Outputs:
  QueueUrl:
    Value: !Ref SettlementQueue
  FunctionArn:
    Value: !GetAtt SettlementFunction.Arn
```

---

## 12. CLI verification lab — real commands and outputs

### 12.1 Discover instance types by attribute, not by memory of the catalogue

```bash
$ aws ec2 describe-instance-types \
    --filters "Name=processor-info.supported-architecture,Values=arm64" \
              "Name=vcpu-info.default-vcpus,Values=2" \
              "Name=memory-info.size-in-mib,Values=8192" \
              "Name=current-generation,Values=true" \
    --query 'InstanceTypes[].{Type:InstanceType,vCPU:VCpuInfo.DefaultVCpus,MiB:MemoryInfo.SizeInMiB,Net:NetworkInfo.NetworkPerformance,Nitro:HypervisorType}' \
    --output table
--------------------------------------------------------------------
|                      DescribeInstanceTypes                        |
+-------+-------------+---------------------------+--------+--------+
| MiB   | Net         | Nitro                     | Type   | vCPU   |
+-------+-------------+---------------------------+--------+--------+
| 8192  | Up to 12.5  | nitro                     | m7g.lar| 2      |
| 8192  | Up to 12.5  | nitro                     | m6g.lar| 2      |
| 8192  | Up to 12.5  | nitro                     | m7gd.la| 2      |
+-------+-------------+---------------------------+--------+--------+
```

### 12.2 Compare Spot to On-Demand before committing to a strategy

```bash
$ aws ec2 describe-spot-price-history \
    --instance-types m7g.large \
    --product-descriptions "Linux/UNIX" \
    --start-time "$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)" \
    --query 'SpotPriceHistory[].{AZ:AvailabilityZone,Price:SpotPrice,When:Timestamp}' \
    --output table
------------------------------------------------------------
|                 DescribeSpotPriceHistory                  |
+---------------+----------+-------------------------------+
|      AZ       |  Price   |             When              |
+---------------+----------+-------------------------------+
|  eu-west-1a   |  0.026500|  2026-09-04T13:52:14+00:00    |
|  eu-west-1b   |  0.024800|  2026-09-04T13:52:14+00:00    |
|  eu-west-1c   |  0.031200|  2026-09-04T13:52:14+00:00    |
+---------------+----------+-------------------------------+
```

Against an On-Demand rate of roughly `$0.0856/hr` for `m7g.large` in this Region, `eu-west-1b` is ~71% cheaper. Also inspect the *interruption* risk, not just price:

```bash
$ aws ec2 describe-spot-placement-scores \
    --instance-types m7g.large m6g.large c7g.large \
    --target-capacity 40 \
    --target-capacity-unit-type units \
    --region-names eu-west-1 \
    --query 'SpotPlacementScores[].{Region:Region,Score:Score}' \
    --output table
-------------------------------
| DescribeSpotPlacementScores |
+-------------+---------------+
|   Region    |     Score     |
+-------------+---------------+
|  eu-west-1  |  9            |
+-------------+---------------+
```

Scores run 1–10; 9 means this diversified request is very likely to be fulfilled without interruption.

### 12.3 Deploy and verify the compute tier

```bash
$ aws cloudformation deploy \
    --template-file compute-tier.yaml \
    --stack-name payments-compute \
    --capabilities CAPABILITY_IAM \
    --parameter-overrides \
        VpcId=vpc-0aa11bb22cc33dd44 \
        PublicSubnetIds=subnet-0111,subnet-0222 \
        PrivateSubnetIds=subnet-0333,subnet-0444 \
        AcmCertificateArn=arn:aws:acm:eu-west-1:111122223333:certificate/1a2b3c4d-...

Waiting for changeset to be created..
Waiting for stack create/update to complete
Successfully created/updated stack - payments-compute
```

```bash
$ aws autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names payments-compute-asg \
    --query 'AutoScalingGroups[0].{Desired:DesiredCapacity,Min:MinSize,Max:MaxSize,
             Instances:Instances[].{Id:InstanceId,AZ:AvailabilityZone,
             Lifecycle:LifecycleState,Health:HealthStatus,
             Type:InstanceType,Market:InstanceLifecycle}}' \
    --output json
{
    "Desired": 4,
    "Min": 2,
    "Max": 20,
    "Instances": [
        {
            "Id": "i-0f3c9a1b2d4e5f607",
            "AZ": "eu-west-1a",
            "Lifecycle": "InService",
            "Health": "Healthy",
            "Type": "m7g.large",
            "Market": null
        },
        {
            "Id": "i-0a7b8c9d0e1f2a3b4",
            "AZ": "eu-west-1b",
            "Lifecycle": "InService",
            "Health": "Healthy",
            "Type": "m7g.large",
            "Market": null
        },
        {
            "Id": "i-01c2d3e4f5a6b7c8d",
            "AZ": "eu-west-1b",
            "Lifecycle": "InService",
            "Health": "Healthy",
            "Type": "c7g.large",
            "Market": "spot"
        },
        {
            "Id": "i-09e8d7c6b5a4f3e21",
            "AZ": "eu-west-1c",
            "Lifecycle": "InService",
            "Health": "Healthy",
            "Type": "m6g.large",
            "Market": "spot"
        }
    ]
}
```

`Market: null` means On-Demand; `Market: "spot"` confirms the mixed-instances policy is honouring `OnDemandBaseCapacity: 2` and diversifying Spot across three types and three AZs.

```bash
$ aws elbv2 describe-target-health \
    --target-group-arn arn:aws:elasticloadbalancing:eu-west-1:111122223333:targetgroup/payments-compute-tg/6d0ecf831eec9f09 \
    --query 'TargetHealthDescriptions[].{Id:Target.Id,Port:Target.Port,State:TargetHealth.State,Reason:TargetHealth.Reason}' \
    --output table
-----------------------------------------------------------------------
|                        DescribeTargetHealth                          |
+----------------------+-------+--------+------------------------------+
|          Id          | Port  | State  |            Reason            |
+----------------------+-------+--------+------------------------------+
| i-0f3c9a1b2d4e5f607  | 8080  |healthy |  None                        |
| i-0a7b8c9d0e1f2a3b4  | 8080  |healthy |  None                        |
| i-01c2d3e4f5a6b7c8d  | 8080  |healthy |  None                        |
| i-09e8d7c6b5a4f3e21  | 8080  |initial |  Elb.RegistrationInProgress   |
+----------------------+-------+--------+------------------------------+
```

Shell into an instance with **no SSH key, no bastion, no inbound port 22**:

```bash
$ aws ssm start-session --target i-0f3c9a1b2d4e5f607

Starting session with SessionId: platform-eng-0b1c2d3e4f5a6b7c8
sh-5.2$ systemctl is-active app.service
active
sh-5.2$ curl -s localhost:8080/healthz
ok
sh-5.2$ exit
Exiting session with sessionId: platform-eng-0b1c2d3e4f5a6b7c8.
```

### 12.4 Register and run the ECS task

```bash
$ aws ecs register-task-definition --cli-input-json file://task-definition.json \
    --query 'taskDefinition.{Family:family,Rev:revision,Cpu:cpu,Mem:memory,Arch:runtimePlatform.cpuArchitecture,Status:status}' \
    --output table
------------------------------------------------------------
|                 RegisterTaskDefinition                    |
+--------+--------+---------------+--------+-------+--------+
|  Arch  |  Cpu   |    Family     |  Mem   |  Rev  | Status |
+--------+--------+---------------+--------+-------+--------+
| ARM64  | 1024   | payments-api  | 2048   | 17    | ACTIVE |
+--------+--------+---------------+--------+-------+--------+
```

```bash
$ aws ecs describe-services --cluster payments-prod --services payments-api \
    --query 'services[0].{Running:runningCount,Desired:desiredCount,Pending:pendingCount,
             Status:status,Deployments:deployments[].{Id:id,Status:status,
             Running:runningCount,Rollout:rolloutState,Reason:rolloutStateReason}}' \
    --output json
{
    "Running": 6,
    "Desired": 6,
    "Pending": 0,
    "Status": "ACTIVE",
    "Deployments": [
        {
            "Id": "ecs-svc/9223370461234567890",
            "Status": "PRIMARY",
            "Running": 6,
            "Rollout": "COMPLETED",
            "Reason": "ECS deployment ecs-svc/9223370461234567890 completed."
        }
    ]
}
```

Confirm the Spot/On-Demand split actually materialised:

```bash
$ aws ecs list-tasks --cluster payments-prod --service-name payments-api --query 'taskArns' --output text \
  | xargs aws ecs describe-tasks --cluster payments-prod --tasks \
  | jq -r '.tasks[] | "\(.taskArn | split("/")[-1])  \(.capacityProviderName)  \(.availabilityZone)  \(.lastStatus)"'
3f9a1b2c4d5e6f708192a3b4c5d6e7f8  FARGATE       eu-west-1a  RUNNING
4a0b2c3d5e6f7081  92a3b4c5d6e7f809  FARGATE       eu-west-1b  RUNNING
5b1c3d4e6f708192  a3b4c5d6e7f80a1b  FARGATE_SPOT  eu-west-1a  RUNNING
6c2d4e5f70819    2a3b4c5d6e7f80a1c  FARGATE_SPOT  eu-west-1b  RUNNING
7d3e5f6081929    3b4c5d6e7f80a1b2d  FARGATE_SPOT  eu-west-1c  RUNNING
8e4f60719203     a4c5d6e7f80a1b2c3e FARGATE_SPOT  eu-west-1c  RUNNING
```

Base 2 On-Demand + 4 Spot — exactly the declared strategy.

Interactive shell into a Fargate task with no SSH and no bastion:

```bash
$ aws ecs execute-command --cluster payments-prod \
    --task 3f9a1b2c4d5e6f708192a3b4c5d6e7f8 \
    --container api --interactive --command "/bin/sh"

The Session Manager plugin was installed successfully.
Starting session with SessionId: ecs-execute-command-0a1b2c3d4e5f6a7b8
/ $ cat /proc/self/cgroup | head -1
0::/
/ $ nproc
2
/ $ exit
```

### 12.5 Lambda verification

```bash
$ aws lambda get-function-configuration --function-name settlement-processor \
    --query '{Runtime:Runtime,Arch:Architectures[0],Mem:MemorySize,Timeout:Timeout,
              Concurrency:ReservedConcurrentExecutions,Tmp:EphemeralStorage.Size,
              State:State,LastUpdate:LastUpdateStatus}' --output table
-------------------------------------------------------------------------
|                       GetFunctionConfiguration                         |
+-------+-------------+------+---------------+------+--------+-----+-----+
| Arch  | Concurrency | Mem  |  LastUpdate   | Run..| State  |Time.| Tmp |
+-------+-------------+------+---------------+------+--------+-----+-----+
| arm64 | 100         | 1024 | Successful    |pyth..| Active | 60  | 512 |
+-------+-------------+------+---------------+------+--------+-----+-----+
```

Invoke and read the billing line — every Lambda invocation ends with a `REPORT` record that is your primary cost and cold-start telemetry:

```bash
$ aws lambda invoke --function-name settlement-processor \
    --payload '{"Records":[{"body":"{\"txId\":\"tx-8812\"}","messageId":"m-1"}]}' \
    --cli-binary-format raw-in-base64-out \
    --log-type Tail \
    /tmp/out.json \
    --query 'LogResult' --output text | base64 -d
START RequestId: 6b1f0a44-5e3c-4a7d-9f21-0c8e2a4b6d10 Version: 12
{"level":"INFO","service":"settlement","message":"processed 1 record","tx":"tx-8812"}
END RequestId: 6b1f0a44-5e3c-4a7d-9f21-0c8e2a4b6d10
REPORT RequestId: 6b1f0a44-5e3c-4a7d-9f21-0c8e2a4b6d10	Duration: 41.83 ms	Billed Duration: 42 ms	Memory Size: 1024 MB	Max Memory Used: 96 MB	Init Duration: 412.77 ms	XRAY TraceId: 1-68b95c1a-0f3a2b4c5d6e7f8091a2b3c4	SegmentId: 2d3e4f5a6b7c8d9e	Sampled: true
```

Read it as an SRE:

- `Init Duration: 412.77 ms` — a cold start occurred. It is **not** in `Billed Duration` for standard invocations, but it *is* in the user's latency.
- `Max Memory Used: 96 MB` of `1024 MB` — the function is over-provisioned on memory *if* it is I/O-bound. If it is CPU-bound, the 1,024 MB is buying CPU, not memory, and dropping it will slow the function. Measure both before changing.
- `Billed Duration: 42 ms` × `1 GB` = 0.042 GB-seconds. At the published arm64 rate of `$0.0000133334` per GB-second plus `$0.20` per million requests, one million such invocations costs roughly `0.042 × 1e6 × 0.0000133334 + 0.20 ≈ $0.76`.

Tail logs live during an incident:

```bash
$ aws logs tail /aws/lambda/settlement-processor --follow --since 5m --format short
2026-09-04T14:03:11 INIT_START Runtime Version: python:3.12.v41
2026-09-04T14:03:12 START RequestId: 9c2d... Version: 12
2026-09-04T14:03:12 {"level":"ERROR","service":"settlement","message":"DynamoDB ProvisionedThroughputExceeded","tx":"tx-8813"}
2026-09-04T14:03:12 END RequestId: 9c2d...
2026-09-04T14:03:12 REPORT RequestId: 9c2d... Duration: 1204.11 ms Billed Duration: 1205 ms Memory Size: 1024 MB Max Memory Used: 102 MB
```

### 12.6 Ask AWS what it thinks your fleet should be

```bash
$ aws compute-optimizer get-ec2-instance-recommendations \
    --query 'instanceRecommendations[].{Id:instanceArn,Current:currentInstanceType,
             Finding:finding,Best:recommendationOptions[0].instanceType,
             Saving:recommendationOptions[0].savingsOpportunity.estimatedMonthlySavings.value}' \
    --output table
---------------------------------------------------------------------------
|                  GetEC2InstanceRecommendations                           |
+--------------+-------------+---------------+---------------+-------------+
|    Best      |   Current   |    Finding    |      Id       |   Saving    |
+--------------+-------------+---------------+---------------+-------------+
|  m7g.large   |  m5.2xlarge |  OVER_PROVIS..| arn:...i-0f3c |  187.42     |
|  c7g.xlarge  |  c5.2xlarge |  OVER_PROVIS..| arn:...i-0a7b |  142.08     |
|  r7g.large   |  r5.large   |  OPTIMIZED    | arn:...i-01c2 |  21.33      |
+--------------+-------------+---------------+---------------+-------------+
```

---

## 13. Diagnosis runbook — real failure signatures

### 13.1 `InsufficientInstanceCapacity` — the ASG cannot launch

```bash
$ aws autoscaling describe-scaling-activities \
    --auto-scaling-group-name payments-compute-asg --max-items 3 \
    --query 'Activities[].{Time:StartTime,Status:StatusCode,Cause:StatusMessage}' --output json
[
    {
        "Time": "2026-09-04T14:11:03.442000+00:00",
        "Status": "Failed",
        "Cause": "Launching a new EC2 instance. Status Reason: We currently do not have sufficient m7g.large capacity in the Availability Zone you requested (eu-west-1a). Our system will be working on provisioning additional capacity. Launching EC2 instance failed."
    }
]
```

| Cause | Remediation, in order of preference |
|---|---|
| Single instance type, single AZ | Add `Overrides` with 4–6 compatible types and span all AZs — this is what the mixed-instances policy is for |
| Genuinely scarce family (GPU, `.metal`) | Buy an **On-Demand Capacity Reservation** in advance for the AZ you need |
| Spot pool exhausted | `SpotAllocationStrategy: price-capacity-optimized` + more pools; enable `CapacityRebalance` |
| Structural | Use **attribute-based instance type selection** (`InstanceRequirements`) so the ASG picks any type meeting vCPU/memory bounds |

### 13.2 ASG launch/terminate loop — instances never reach `InService`

```
Launching a new EC2 instance: i-0abc...      (InProgress)
Terminating EC2 instance: i-0abc...
  Cause: At 2026-09-04T14:20:11Z an instance was taken out of service in
  response to an ELB system health check failure.
```

The bootstrap has not finished before the target group declares failure. Check, in order:

1. **`HealthCheckGracePeriod` shorter than boot + `UserData` time.** With `dnf update` in `UserData`, 180 s can be too short. Measure it, then set the grace period to 2× that.
2. **Security group** — the instance SG must allow the target group port *from the ALB SG*.
3. **The health check path is wrong** or returns something outside `Matcher.HttpCode`.
4. **`UserData` failed.** It runs as root, once, and its output goes to a log — read it on the instance:

```bash
$ aws ssm start-session --target i-0abc123def456789
sh-5.2$ sudo tail -20 /var/log/cloud-init-output.log
+ dnf -y install python3.12 amazon-cloudwatch-agent
Error: Unable to find a match: amazon-cloudwatch-agent
+ exit 1
sh-5.2$ sudo systemctl status app.service
● app.service - Demo application
     Loaded: loaded (/etc/systemd/system/app.service; disabled)
     Active: inactive (dead)
```

`set -euxo pipefail` in `UserData` is what makes this diagnosable instead of silent. Without `-e`, cloud-init reports success while the app never starts.

### 13.3 ECS task will not start — read `stoppedReason` first, always

```bash
$ aws ecs describe-tasks --cluster payments-prod --tasks 3f9a1b2c4d5e6f708192a3b4c5d6e7f8 \
    --query 'tasks[0].{Last:lastStatus,Desired:desiredStatus,Stopped:stoppedReason,
             Containers:containers[].{Name:name,Reason:reason,Exit:exitCode}}' --output json
{
    "Last": "STOPPED",
    "Desired": "STOPPED",
    "Stopped": "ResourceInitializationError: unable to pull secrets or registry auth: execution resource retrieval failed: unable to retrieve ecr registry auth: service call has been retried 3 time(s): RequestError: send request failed caused by: Post \"https://api.ecr.eu-west-1.amazonaws.com/\": dial tcp 10.0.3.14:443: i/o timeout",
    "Containers": [
        { "Name": "api", "Reason": null, "Exit": null }
    ]
}
```

| `stoppedReason` / signature | Root cause | Fix |
|---|---|---|
| `ResourceInitializationError … dial tcp … i/o timeout` | Fargate task in a private subnet with `AssignPublicIp: DISABLED` and **no route to ECR/Secrets Manager/CloudWatch Logs** | Add a NAT gateway, or (cheaper, more secure) VPC interface endpoints for `ecr.api`, `ecr.dkr`, `secretsmanager`, `logs` plus an S3 **gateway** endpoint for the ECR layer store |
| `CannotPullContainerError: … 403 Forbidden` | Task **execution** role lacks `ecr:GetAuthorizationToken` / `ecr:BatchGetImage` | Attach `AmazonECSTaskExecutionRolePolicy` to the execution role |
| `CannotPullContainerError: manifest unknown` | Tag does not exist, or wrong architecture (arm64 task, amd64-only image) | Verify with `aws ecr describe-images`; build a multi-arch manifest |
| Container `Exit: 137` | `SIGKILL` — the container exceeded its memory limit (OOM) | Raise task/container memory, or fix the leak; correlate with `MemoryUtilization` |
| Container `Exit: 139` | `SIGSEGV` in the process | Application bug or a native-library/architecture mismatch |
| `Task failed ELB health checks` | App slower to start than the grace period | Raise `HealthCheckGracePeriodSeconds` and add a container `startPeriod` |
| `RESOURCE:ENI` in service events | The task subnets have run out of free IP addresses | `awsvpc` gives every task an ENI with a VPC IP — use larger subnets, or fewer/larger tasks |
| Service events say `unable to place a task because no container instance met all of its requirements` | **EC2 launch type only** — no node has enough free CPU/memory/ports | Scale the ASG / use an ECS capacity provider with managed scaling, or reduce the task reservation |

Always read the service event stream — it is the most information-dense place in ECS:

```bash
$ aws ecs describe-services --cluster payments-prod --services payments-api \
    --query 'services[0].events[:5].[createdAt,message]' --output text
2026-09-04T14:22:41+00:00	(service payments-api) has reached a steady state.
2026-09-04T14:21:55+00:00	(service payments-api) registered 2 targets in (target-group arn:aws:elasticloadbalancing:...)
2026-09-04T14:20:12+00:00	(service payments-api) has started 2 tasks: (task 5b1c3d4e...) (task 6c2d4e5f...).
2026-09-04T14:19:03+00:00	(service payments-api) was unable to place a task because no container instance met all of its requirements. The closest matching container-instance i-0cc... has insufficient memory available.
```

### 13.4 Lambda throttling

```bash
$ aws cloudwatch get-metric-statistics \
    --namespace AWS/Lambda --metric-name Throttles \
    --dimensions Name=FunctionName,Value=settlement-processor \
    --start-time "$(date -u -d '30 min ago' +%Y-%m-%dT%H:%M:%SZ)" \
    --end-time   "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --period 60 --statistics Sum \
    --query 'sort_by(Datapoints,&Timestamp)[-5:].{T:Timestamp,Throttles:Sum}' --output table
--------------------------------------------
|          GetMetricStatistics              |
+------------+------------------------------+
| Throttles  |             T                |
+------------+------------------------------+
|  0.0       |  2026-09-04T14:00:00+00:00   |
|  412.0     |  2026-09-04T14:01:00+00:00   |
|  1893.0    |  2026-09-04T14:02:00+00:00   |
|  2044.0    |  2026-09-04T14:03:00+00:00   |
+------------+------------------------------+
```

Callers see `429 TooManyRequestsException` with `Rate Exceeded`. Three distinct causes, three different fixes:

1. **Account concurrency limit reached (default 1,000).** Check headroom:
   ```bash
   $ aws lambda get-account-settings --query 'AccountLimit.{Concurrent:ConcurrentExecutions,Unreserved:UnreservedConcurrentExecutions}'
   { "Concurrent": 1000, "Unreserved": 300 }
   ```
   Only 300 unreserved remain — another function has reserved 700. Request a quota increase in Service Quotas, or rebalance reservations.
2. **This function's own `ReservedConcurrentExecutions` is the ceiling.** By design; raise it or accept the backpressure.
3. **Burst rate exceeded.** Lambda scales at a bounded rate; an instantaneous 0→5,000 concurrency step throttles the overflow even with quota available. Buffer with SQS, or use provisioned concurrency for the known step.

Distinguish a timeout from an error — the log is unambiguous:

```
2026-09-04T14:05:22 END RequestId: a1b2...
2026-09-04T14:05:22 REPORT RequestId: a1b2... Duration: 60000.00 ms Billed Duration: 60000 ms Memory Size: 1024 MB Max Memory Used: 108 MB
2026-09-04T14:05:22 2026-09-04T14:05:22.881Z a1b2... Task timed out after 60.00 seconds
```

`Duration` exactly equal to the configured `Timeout` is the signature. Investigate the downstream call the function is blocked on — and check that the SQS `VisibilityTimeout` is at least 6× the function timeout, or the same message will be redelivered while the first invocation is still running.

### 13.5 IMDSv2 enforcement broke something

```bash
$ curl -s http://169.254.169.254/latest/meta-data/instance-id
<?xml version="1.0" encoding="iso-8859-1"?>
<html><head><title>401 - Unauthorized</title></head>
<body><h1>401 - Unauthorized</h1></body></html>
```

Expected — `HttpTokens: required` rejects the unauthenticated IMDSv1 call. Any agent or SDK older than the IMDSv2 rollout must be upgraded. A subtler variant: a **container** on that instance gets a network timeout instead of a 401, because the default `HttpPutResponseHopLimit: 1` drops the packet after one hop out of the container network namespace. Set the hop limit to `2` — and only `2`, since higher values widen SSRF exposure.

### 13.6 Bill spiked with no traffic change

```bash
$ aws ce get-cost-and-usage \
    --time-period Start=2026-08-01,End=2026-09-01 \
    --granularity MONTHLY --metrics UnblendedCost \
    --group-by Type=DIMENSION,Key=USAGE_TYPE \
    --filter '{"Dimensions":{"Key":"SERVICE","Values":["Amazon Elastic Compute Cloud - Compute"]}}' \
    --query 'ResultsByTime[0].Groups[?to_number(Metrics.UnblendedCost.Amount)>`50`].[Keys[0],Metrics.UnblendedCost.Amount]' \
    --output text
EUW1-BoxUsage:m7g.large      1842.11
EUW1-CPUCredits:t3           612.40
EUW1-SpotUsage:c7g.large      203.77
EUW1-NatGateway-Bytes         488.02
```

`EUW1-CPUCredits:t3` at $612 is a T3 fleet in **unlimited mode** running permanently above baseline — you are paying a surplus rate to pretend a burstable instance is a fixed-performance one. Move that tier to M-family; the fixed instance is cheaper than the surplus.

---

## 14. Exam-focused summary

**Memorise these as reflexes:**

- The three container pieces: **ECR** (registry) → **ECS/EKS** (orchestrator) → **EC2 or Fargate** (compute).
- **Fargate = serverless containers. Lambda = serverless functions.** Both remove OS patching from your responsibilities.
- **Lambda's hard ceiling is 15 minutes.** Any question mentioning a longer job is not a Lambda question.
- **Spot = up to 90% off, interruptible with a 2-minute warning**, only for fault-tolerant workloads.
- **Savings Plans/RIs = commitment for discount, not capacity.** **Dedicated Hosts = BYOL and physical-server visibility.** **Capacity Reservations = guaranteed capacity, no discount by themselves.**
- **Auto Scaling = elasticity + self-healing.** ELB = distribution. They are different services solving different problems and almost always appear together.
- **ALB = layer 7 / HTTP routing. NLB = layer 4 / static IP / extreme throughput.**
- **Beanstalk deploys your app onto EC2 you can still see. App Runner and Lambda hide everything. Lightsail is a fixed-price bundle.**
- Beanstalk, Auto Scaling, CloudFormation and Compute Optimizer are **free**; you pay for the resources they create or measure.
- Edge/hybrid ladder: **Outposts** (your data centre) → **Local Zones** (your city) → **Wavelength** (5G network) → **Snowball Edge** (disconnected).

**Trap questions and their answers:**

| Stem | Wrong-looking attractor | Correct answer |
|---|---|---|
| "…without managing servers, running containers" | Lambda | **Fargate** |
| "…run for 3 hours per job, thousands of jobs, minimise cost" | Lambda | **AWS Batch** (with Spot) |
| "…must not be interrupted, runs 24/7 for 3 years" | Spot | **Reserved Instances / Savings Plans** |
| "…needs a static IP for a firewall allowlist" | ALB | **NLB** |
| "…must satisfy a per-physical-core software licence" | Dedicated Instances | **Dedicated Hosts** |
| "…deploy code without configuring infrastructure, but the team still needs OS access" | App Runner | **Elastic Beanstalk** |
| "…single-digit-millisecond latency to users in one city" | CloudFront | **AWS Local Zones** |
| "…replace failed instances automatically" | ELB | **EC2 Auto Scaling** |

---

## References

Primary source for this task statement:

- AWS Certified Cloud Practitioner (CLF-C02) Exam Guide — https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf

Official AWS documentation used to build the technical content above:

- Amazon EC2 User Guide — https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/concepts.html
- Amazon EC2 instance types — https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/instance-types.html
- Burstable performance instances and CPU credits — https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/burstable-performance-instances.html
- Amazon EC2 instance purchasing options — https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/instance-purchasing-options.html
- Amazon EC2 Spot Instances — https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/using-spot-instances.html
- Spot Instance interruption notices — https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/spot-interruptions.html
- Amazon EC2 Dedicated Hosts — https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/dedicated-hosts-overview.html
- Placement groups — https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/placement-groups.html
- Instance metadata service (IMDSv2) — https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/configuring-instance-metadata-service.html
- AWS Nitro System — https://aws.amazon.com/ec2/nitro/
- AWS Nitro Enclaves — https://docs.aws.amazon.com/enclaves/latest/user/nitro-enclave.html
- AWS Graviton — https://aws.amazon.com/ec2/graviton/
- Amazon EC2 Auto Scaling User Guide — https://docs.aws.amazon.com/autoscaling/ec2/userguide/what-is-amazon-ec2-auto-scaling.html
- Auto Scaling groups with multiple instance types and purchase options — https://docs.aws.amazon.com/autoscaling/ec2/userguide/ec2-auto-scaling-mixed-instances-groups.html
- Elastic Load Balancing — https://docs.aws.amazon.com/elasticloadbalancing/latest/userguide/what-is-load-balancing.html
- Amazon ECS Developer Guide — https://docs.aws.amazon.com/AmazonECS/latest/developerguide/Welcome.html
- Amazon ECS task definition parameters — https://docs.aws.amazon.com/AmazonECS/latest/developerguide/task_definition_parameters.html
- AWS Fargate for Amazon ECS — https://docs.aws.amazon.com/AmazonECS/latest/developerguide/AWS_Fargate.html
- Amazon ECS stopped task error messages — https://docs.aws.amazon.com/AmazonECS/latest/developerguide/stopped-task-error-codes.html
- Amazon EKS User Guide — https://docs.aws.amazon.com/eks/latest/userguide/what-is-eks.html
- AWS Fargate for Amazon EKS — https://docs.aws.amazon.com/eks/latest/userguide/fargate.html
- Amazon ECR User Guide — https://docs.aws.amazon.com/AmazonECR/latest/userguide/what-is-ecr.html
- AWS Lambda Developer Guide — https://docs.aws.amazon.com/lambda/latest/dg/welcome.html
- Lambda quotas — https://docs.aws.amazon.com/lambda/latest/dg/gettingstarted-limits.html
- Lambda function scaling and concurrency — https://docs.aws.amazon.com/lambda/latest/dg/lambda-concurrency.html
- Improving startup performance with Lambda SnapStart — https://docs.aws.amazon.com/lambda/latest/dg/snapstart.html
- AWS Batch User Guide — https://docs.aws.amazon.com/batch/latest/userguide/what-is-batch.html
- AWS Elastic Beanstalk Developer Guide — https://docs.aws.amazon.com/elasticbeanstalk/latest/dg/Welcome.html
- AWS App Runner Developer Guide — https://docs.aws.amazon.com/apprunner/latest/dg/what-is-apprunner.html
- Amazon Lightsail — https://docs.aws.amazon.com/lightsail/latest/userguide/what-is-amazon-lightsail.html
- AWS Outposts — https://docs.aws.amazon.com/outposts/latest/userguide/what-is-outposts.html
- AWS Local Zones — https://docs.aws.amazon.com/local-zones/latest/ug/what-is-aws-local-zones.html
- AWS Wavelength — https://docs.aws.amazon.com/wavelength/latest/developerguide/what-is-wavelength.html
- AWS Compute Optimizer — https://docs.aws.amazon.com/compute-optimizer/latest/ug/what-is-compute-optimizer.html
- AWS Savings Plans User Guide — https://docs.aws.amazon.com/savingsplans/latest/userguide/what-is-savings-plans.html
- AWS Serverless Application Model (SAM) specification — https://docs.aws.amazon.com/serverless-application-model/latest/developerguide/what-is-sam.html
- AWS CloudFormation resource reference — https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-template-resource-type-ref.html
- AWS Shared Responsibility Model — https://aws.amazon.com/compliance/shared-responsibility-model/

> Prices and quotas quoted in this material reflect published `us-east-1`/`eu-west-1` figures and are illustrative for reasoning about trade-offs. Verify current values against the AWS Pricing Calculator (https://calculator.aws/) and the Service Quotas console before making a commitment decision.