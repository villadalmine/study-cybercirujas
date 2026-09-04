# AWS Certified Cloud Practitioner (CLF-C02)
## Domain 3, Task Statement 3.5 — Identify AWS network services
**Exam weight: 4.25 · Depth profile: SRE / Platform Architect · Language: English**

---

## 1. The production problem this task statement actually encodes

The exam guide phrases 3.5 as "identify AWS network services." That verb — *identify* — is doing a lot of quiet work. The failure mode it is protecting against is not ignorance of what a VPC is. It is the far more expensive failure mode of **picking the wrong network primitive at design time and discovering it at scale**, when the cost of change is a migration rather than an edit.

Concretely, here are four incidents that all trace back to a 3.5-level decision:

**Incident A — the /24 that ate the roadmap.** A team launches its first production VPC with `10.0.0.0/24` because "we only need a few instances." Two years later they need EKS with the VPC CNI, where **every pod consumes a VPC IP address from the subnet**. A `t3.large` supports 35 pods; 12 nodes exhaust the address space. You cannot resize a VPC CIDR downward or renumber a subnet — you can only *add* secondary CIDR blocks, and only if they do not collide with the peered/on-prem space you already advertised. The RFC1918 allocation plan is the single most irreversible decision in this task statement.

**Incident B — the $9,400 NAT bill.** An analytics fleet in private subnets pulls 60 TB/month from Amazon S3. The traffic exits through a NAT gateway to the public S3 endpoint. At roughly $0.045/GB of NAT data processing that is about **$2,700/month in NAT charges alone**, plus the hourly charge, for traffic that never needed to leave the AWS network. A **gateway VPC endpoint for S3 costs $0.00** and removes the charge entirely. The knowledge gap is one row in a route table.

**Incident C — the security group that was not the problem.** A service cannot reach its database. Three engineers spend two hours widening security groups. The actual cause is a **network ACL** on the data subnet that allows inbound `5432` but has no outbound rule for the **ephemeral port range**, because NACLs are stateless and security groups are not. This is the single most common VPC-connectivity misdiagnosis in production, and it is a direct consequence of a stateful/stateless distinction that 3.5 expects you to hold.

**Incident D — CloudFront where Global Accelerator belonged.** A team fronts a real-time UDP game server with CloudFront, discovers CloudFront is an HTTP/HTTPS cache, and rebuilds on **AWS Global Accelerator** — anycast static IPs over the AWS backbone, protocol-agnostic. Both are "edge networking." They solve different problems.

The engineering content of 3.5 is therefore a **decision table**, not a glossary. Everything below is organised so that each service is presented with the question it answers, the alternatives it competes with, and the observable signal that tells you the choice was wrong.

---

## 2. The mental model: five nested scopes

Every AWS network service lives at exactly one of five scopes. Placing a service correctly on this ladder answers most exam questions and most design questions.

```
┌──────────────────────────────────────────────────────────────────────┐
│ GLOBAL / EDGE   Route 53 · CloudFront · Global Accelerator · Shield  │
│                 WAF (on CF/ALB/API GW) · 600+ PoPs, anycast          │
│  ┌────────────────────────────────────────────────────────────────┐  │
│  │ REGION       Direct Connect location · Transit Gateway ·       │  │
│  │              Site-to-Site VPN · Cloud WAN · PrivateLink svc    │  │
│  │  ┌──────────────────────────────────────────────────────────┐  │  │
│  │  │ VPC       CIDR blocks · IGW · Egress-only IGW · DHCP opts │  │  │
│  │  │           Route 53 Resolver (.2) · Peering · Flow Logs    │  │  │
│  │  │  ┌────────────────────────────────────────────────────┐  │  │  │
│  │  │  │ SUBNET (= one AZ)  Route table · NACL · NAT GW ·   │  │  │  │
│  │  │  │                    gateway endpoint association     │  │  │  │
│  │  │  │  ┌──────────────────────────────────────────────┐  │  │  │  │
│  │  │  │  │ ENI  Security group(s) · private IP(s) ·     │  │  │  │  │
│  │  │  │  │      EIP · source/dest check · interface EP  │  │  │  │  │
│  │  │  │  └──────────────────────────────────────────────┘  │  │  │  │
│  │  │  └────────────────────────────────────────────────────┘  │  │  │
│  │  └──────────────────────────────────────────────────────────┘  │  │
│  └────────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────────┘
```

Two consequences worth internalising:

- **A subnet never spans an Availability Zone.** Therefore any construct attached to a subnet (NAT gateway, interface endpoint ENI, NLB node) is a per-AZ failure domain, and per-AZ redundancy is something *you* buy, not something you get.
- **A security group is attached to an ENI, not a subnet.** Two instances in the same subnet with different security groups have entirely different reachability. This is why "it's in the same subnet, so it must work" is a false statement.

---

## 3. Amazon VPC: the addressing and routing substrate

### 3.1 CIDR mechanics you are expected to know exactly

| Property | Rule | Practical consequence |
|---|---|---|
| VPC IPv4 CIDR size | `/16` … `/28` | `/16` = 65,536 addresses is the sane default for a production VPC |
| Secondary CIDRs | Up to 5 total (soft-adjustable) | The only remedy for under-allocation; cannot overlap existing routes |
| Primary CIDR | **Immutable** | Cannot be changed or shrunk after creation |
| Reserved IPs per subnet | **5** | `.0` network, `.1` VPC router, `.2` Route 53 Resolver, `.3` reserved, last = broadcast |
| Subnet ↔ AZ | 1 : 1 | AZ redundancy requires ≥ 2 subnets per tier |
| IPv6 | `/56` per VPC (AWS-provided or BYOIP), `/64` per subnet | IPv6 is always public-routable; privacy comes from the egress-only IGW |

Worked example on the template below, `10.42.0.0/16` split into `/20`s:

```
10.42.0.0/20   → 4096 total − 5 reserved = 4091 usable
                 10.42.0.0   network
                 10.42.0.1   VPC router (default gateway)
                 10.42.0.2   Route 53 Resolver (VPC base + 2)
                 10.42.0.3   reserved for future AWS use
                 10.42.15.255 broadcast (reserved; VPC has no broadcast)
```

The `.2` resolver address matters operationally: it is the *only* DNS server reachable by default from a private subnet, it is rate-limited to **1024 packets per second per ENI**, and that limit is a real production ceiling for chatty service-discovery workloads. There is no CloudWatch metric for it — the symptom is intermittent `SERVFAIL`/timeouts under load, and the fix is a local caching resolver or Route 53 Resolver endpoints.

### 3.2 Gateways and their exact semantics

| Component | Direction | IP family | Charged | Purpose |
|---|---|---|---|---|
| **Internet gateway (IGW)** | Bidirectional | IPv4 + IPv6 | Free (data transfer applies) | Horizontally-scaled, redundant, no bandwidth constraint; performs 1:1 NAT for IPv4 public addresses |
| **NAT gateway** | **Egress only** | IPv4 only | ~$0.045/hr + ~$0.045/GB | Managed, 45 Gbps burst, AZ-scoped, needs an EIP and a public subnet |
| **Egress-only IGW (EIGW)** | **Egress only** | **IPv6 only** | **Free** | Stateful IPv6 egress; the IPv6 analogue of a NAT gateway, at zero cost |
| **Virtual private gateway (VGW)** | Bidirectional | IPv4 + IPv6 | Free (VPN/DX charges apply) | VPC-side terminator for Site-to-Site VPN / private VIF |
| **Transit gateway (TGW)** | Bidirectional | IPv4 + IPv6 | ~$0.05/attachment-hr + ~$0.02/GB | Regional router; hub-and-spoke replacement for mesh peering |

> **Definition of "public subnet":** a subnet whose associated route table contains a route to an internet gateway. Nothing else. Not a tag, not a name, not the presence of a public IP.

### 3.3 NAT gateway vs. NAT instance vs. no NAT at all

| Dimension | NAT gateway | NAT instance (self-managed EC2) | VPC endpoints (no NAT) |
|---|---|---|---|
| Availability | Managed, redundant *within one AZ* | You build it (ASG + route failover) | Managed, multi-AZ if you deploy per-AZ |
| Bandwidth | 5 Gbps → 45 Gbps automatic | Bounded by instance type | Gateway: no limit. Interface: 10 Gbps/ENI, bursts to 40 |
| Cost @ 60 TB/mo | ~$2,700 data + ~$33 hourly | Instance + EBS + data transfer out | **$0** (S3/DynamoDB gateway) |
| Security groups | **Cannot** attach one | Yes | Yes (interface endpoints) |
| Port forwarding / bastion | No | Yes | No |
| IPv6 | Not supported (use EIGW) | Possible manually | Supported on many endpoints |
| Ops burden | Zero | Patching, monitoring, failover scripts | Zero |

**Architect's rule:** NAT gateways are for the traffic that genuinely must reach the public internet (OS package mirrors, third-party SaaS APIs). Every byte of AWS-service traffic should be on an endpoint before you size the NAT. Deploy **one NAT gateway per AZ** and route each AZ's private subnet to its local NAT — a single shared NAT is both a cross-AZ data-transfer charge and an AZ-failure blast radius.

### 3.4 Security groups vs. network ACLs — the stateful/stateless split

This is the highest-yield comparison in the entire task statement.

| | **Security group** | **Network ACL** |
|---|---|---|
| Attaches to | **ENI** (instance, endpoint, ALB node, RDS) | **Subnet** |
| State | **Stateful** — return traffic auto-allowed | **Stateless** — return traffic needs its own rule |
| Rule types | **Allow only** | **Allow and Deny** |
| Evaluation | All rules evaluated; union of allows | **Lowest rule number first**, first match wins, stop |
| Default (custom-created) | **Deny all inbound**, allow all outbound | **Deny all** in and out |
| Default (VPC default resource) | Allow from same SG, allow all outbound | **Allow all** in and out |
| Can reference | Another SG ID, a prefix list, a CIDR | CIDR only |
| Quota (default) | 5 SGs/ENI, 60 in + 60 out rules | 20 rules per direction (40 max) |
| Ephemeral ports | Never needed | **Always needed** for return traffic |
| Typical use | Primary control; per-workload identity | Coarse subnet-wide **deny** (blocklists, tier isolation) |

**Ephemeral port ranges that matter when writing NACLs:**

| Client | Range |
|---|---|
| Linux kernel (`net.ipv4.ip_local_port_range`) | 32768–60999 |
| Windows Server 2008+ | 49152–65535 |
| NAT gateway | **1024–65535** |
| AWS Lambda / ELB nodes | 1024–65535 |

Because a NAT gateway sources from 1024–65535, any NACL guarding a subnet that receives NAT-translated return traffic must allow **1024–65535 inbound**. Narrowing to 32768–60999 "because the clients are Linux" breaks the moment traffic transits NAT. This is a real, repeatable outage.

**Security-group referencing is the feature to actually use.** Instead of `10.42.4.0/22`, write "allow TCP 8080 from `sg-app`". The rule then follows workload identity rather than address space, survives re-subnetting, and cannot be satisfied by an unrelated instance that happens to land in the right CIDR.

### 3.5 VPC endpoints — gateway vs. interface (PrivateLink)

| | **Gateway endpoint** | **Interface endpoint (PrivateLink)** |
|---|---|---|
| Implementation | **Route table entry** to a managed prefix list | **ENI with a private IP** in your subnet |
| Services | **Amazon S3 and DynamoDB only** | 100+ AWS services, Marketplace, your own services |
| Cost | **Free** | ~$0.01/hr per AZ per endpoint + ~$0.01/GB |
| Security group | Not applicable | **Yes** — the primary control |
| Policy | Endpoint policy | Endpoint policy |
| DNS | Uses the public service DNS name, route diverts | **Private DNS** overrides the public name in-VPC |
| Cross-Region | No | No (use Region-local endpoints) |
| Reachable from on-prem via DX/VPN | **No** | **Yes** |
| Reachable across peering | **No** | **Yes** |

The "reachable from on-prem" row is the reason many organisations run *both* a free S3 gateway endpoint (for in-VPC traffic) and a paid S3 interface endpoint (for Direct Connect traffic). They coexist; private DNS on the interface endpoint decides which wins for in-VPC clients, so if you want the free path to win, leave private DNS **disabled** on the S3 interface endpoint and use its regional endpoint-specific DNS name from on-prem.

**PrivateLink for your own service** is the pattern for exposing a service to another VPC or another AWS account without peering, without overlapping-CIDR problems, and with a unidirectional trust model: you put an NLB (or GWLB) in front of your service, publish it as a *VPC endpoint service*, and consumers create interface endpoints. The consumer can reach you; you cannot reach the consumer. CIDRs may overlap freely, because nothing is routed — traffic is NAT'd at the endpoint.

### 3.6 Connecting VPCs and networks

| Option | Topology | Transitive? | Overlapping CIDRs OK? | Bandwidth | Typical cost driver |
|---|---|---|---|---|---|
| **VPC peering** | 1:1 mesh | **No** | **No** | No AWS-imposed limit | Cross-AZ data transfer (intra-AZ is free) |
| **Transit gateway** | Hub-and-spoke | **Yes** (route-table controlled) | No | 50 Gbps burst per VPC attachment | Attachment-hours + per-GB |
| **PrivateLink** | Service-to-consumer | N/A | **Yes** | Per NLB/ENI limits | Endpoint-hours + per-GB |
| **Site-to-Site VPN** | On-prem ↔ AWS over internet | Via VGW or TGW | No | **~1.25 Gbps per tunnel** | Per VPN-connection-hour + data out |
| **Direct Connect** | On-prem ↔ AWS, dedicated fibre | Via VGW/DX GW/TGW | No | 1 / 10 / 100 Gbps dedicated; 50 Mbps–25 Gbps hosted | Port-hours + reduced DTO rate |
| **AWS Cloud WAN** | Managed global backbone | Yes, policy-driven | No | Segment-dependent | Core network edge-hours + per-GB |

Three points that get tested and get designs wrong:

1. **Peering is non-transitive by design.** If A↔B and B↔C are peered, A cannot reach C. Full mesh of *n* VPCs needs *n(n−1)/2* connections and *n−1* routes per route table. This becomes unmanageable somewhere around 6–8 VPCs; that is the Transit Gateway inflection point.
2. **A Site-to-Site VPN connection is always two tunnels**, terminating on two distinct AWS endpoints in different AZs, for AWS-side redundancy. A single tunnel is not an HA design, and the ~1.25 Gbps ceiling is **per tunnel** — aggregate beyond it requires multiple VPN connections with ECMP on a Transit Gateway.
3. **Direct Connect is not encrypted by default.** A private VIF over DX carries plaintext. If your compliance posture requires encryption in transit over the WAN, you run **IPsec VPN over Direct Connect** (public VIF or DX public endpoint), or **MACsec** on supported dedicated connections. Also: a *single* DX connection is not resilient — the standard resilient patterns are two connections at two DX locations, and the standard on-ramp is DX + VPN backup.

---

## 4. Load balancing: the Elastic Load Balancing family

| | **ALB** | **NLB** | **GWLB** | **CLB** (legacy) |
|---|---|---|---|---|
| OSI layer | 7 | 4 | 3 (+GENEVE) | 4 / 7 |
| Protocols | HTTP, HTTPS, gRPC, WebSockets | TCP, UDP, TLS, TCP_UDP | IP (GENEVE **UDP 6081**) | TCP, SSL, HTTP, HTTPS |
| Routing on | Host, path, header, method, query, source IP | Flow hash (5-tuple, or 3-tuple for UDP) | 5-tuple flow stickiness | Port only |
| Static IP | No (use DNS name) | **Yes — one EIP per AZ** | No (via endpoint) | No |
| Preserves client IP | Via `X-Forwarded-For` header | **Yes, natively** (instance/IP targets) | Yes (encapsulated) | `X-Forwarded-For` on HTTP |
| Target types | instance, **ip**, **Lambda** | instance, ip, **ALB** | instance, ip (appliances) | instance |
| TLS termination | Yes (+ SNI, multiple certs) | Yes (TLS listener) | No (transparent) | Yes |
| WAF integration | **Yes** | No | No | No |
| Latency added | ~ms | **~100 µs** | Appliance-dependent | ~ms |
| Scale | Very high | **Millions of rps**, no pre-warm | Appliance-dependent | Needs pre-warming |
| Security groups | Yes | **Yes** (since Aug 2023) | Yes | Yes |
| PrivateLink service front-end | No | **Yes** | Yes | No |
| Pricing unit | LCU-hours | NLCU-hours | GLCU-hours | Hourly + GB |

**Decision rules:**
- Need path/host routing, OIDC auth, Lambda targets, or WAF → **ALB**.
- Need a static IP, a non-HTTP protocol, extreme throughput, true source IP without headers, or a PrivateLink front door → **NLB**.
- Need to insert a third-party firewall/IDS transparently into the packet path → **GWLB**.
- Need both L7 features *and* a static IP → **NLB with an ALB target**, or **Global Accelerator in front of an ALB**.
- **CLB** appears only in migration scenarios. Do not design new systems on it.

---

## 5. DNS: Amazon Route 53

Route 53 is a **global** service performing three distinct jobs: domain registration, authoritative DNS hosting, and health checking. Its ~100% availability SLA is unique in the AWS portfolio.

### 5.1 Routing policies

| Policy | Selection basis | Requires health check | Canonical use |
|---|---|---|---|
| **Simple** | Single record; multiple values returned in random order | No | Static mapping |
| **Weighted** | Integer weight ratio | Optional | Canary / blue-green / A-B split |
| **Latency-based** | Lowest measured network latency to the Region | Optional | Multi-Region read paths |
| **Failover** | Primary until unhealthy, then secondary | **Yes** | Active-passive DR |
| **Geolocation** | Resolver's country/continent/state | Optional | Data residency, localisation, licensing |
| **Geoproximity** | Geographic distance ± a **bias** value | Optional | Gradual traffic shift between Regions |
| **Multivalue answer** | Up to 8 healthy records, randomised | **Yes** | Cheap client-side load spreading (not a load balancer) |
| **IP-based** | CIDR blocks of the resolver | Optional | ISP-aware / carrier steering |

**Latency-based is not geolocation.** Latency routing answers "which Region is fastest from this resolver", geolocation answers "where is this resolver". They diverge constantly — a user in Canada may have lower latency to `us-east-1` than to `ca-central-1`. Choosing geolocation for a performance goal is a design error; choosing latency routing for a compliance goal is a compliance violation.

### 5.2 Alias vs. CNAME

| | **Alias (Route 53 extension)** | **CNAME (standard DNS)** |
|---|---|---|
| Zone apex (`example.com`) | **Yes** | **No** — forbidden by RFC 1034 |
| Cost per query | **Free** to AWS targets | Charged |
| Target | ELB, CloudFront, S3 website, API GW, Global Accelerator, VPC endpoint, another record in the same zone | Any DNS name |
| Health | Can evaluate target health natively | No |
| TTL | Inherited from the target | You set it |

### 5.3 Hosted zones and hybrid resolution

- **Public hosted zone** — authoritative on the internet.
- **Private hosted zone** — resolvable only from associated VPCs; requires `enableDnsSupport` **and** `enableDnsHostnames` on the VPC.
- **Route 53 Resolver endpoints** — the hybrid DNS bridge:
  - **Inbound endpoint** → on-premises resolvers query AWS-hosted zones.
  - **Outbound endpoint + forwarding rules** → VPC workloads query on-premises zones.

---

## 6. Edge and content delivery

### 6.1 Amazon CloudFront

A globally distributed CDN with 600+ points of presence and regional edge caches. Beyond caching it provides TLS termination at the edge, origin shielding, **Origin Access Control (OAC)** for private S3 origins (OAC supersedes the legacy OAI, and is required for SSE-KMS origins), signed URLs and signed cookies, field-level encryption, and native AWS Shield Standard + AWS WAF integration.

| | **CloudFront Functions** | **Lambda@Edge** |
|---|---|---|
| Runs at | 600+ edge locations | Regional edge caches |
| Runtime | JavaScript (ECMAScript 5.1-style) | Node.js, Python |
| Max duration | **< 1 ms** | 5 s (viewer), 30 s (origin) |
| Memory | 2 MB | 128 MB–10 GB |
| Triggers | viewer request/response only | all four (viewer + origin, req/resp) |
| Network access | **No** | Yes |
| Body access | No | Yes |
| Cost | ~1/6 of Lambda@Edge | Higher |
| Use for | Header manipulation, URL rewrite, A/B cookie, token check | Auth against an API, image transformation, body inspection |

### 6.2 CloudFront vs. Global Accelerator

| | **CloudFront** | **Global Accelerator** |
|---|---|---|
| Protocols | HTTP/HTTPS (+WebSockets) | **TCP and UDP**, any port |
| Caching | **Yes** — the core value | **No** — pure proxy/routing |
| Client entry | Edge PoP by DNS | **2 static anycast IPs** by BGP |
| Failover speed | DNS/origin failover, seconds–minutes | **Sub-30-second** health-based, no DNS dependency |
| Client IP preservation | `X-Forwarded-For` | Yes, to ALB/EC2 endpoints |
| Endpoints | S3, ALB, EC2, any HTTP origin | ALB, NLB, EC2, Elastic IP |
| Ideal for | Static + dynamic web content, media | Gaming, VoIP, IoT/MQTT, non-HTTP APIs, IP allowlisting |
| Why static IPs matter | — | Enterprise/partner firewalls allowlist IPs, not DNS names |

Both ride the AWS global backbone from the edge to the origin, so both improve dynamic (uncacheable) traffic. They are also composable: Global Accelerator can front an ALB that also serves as a CloudFront origin.

### 6.3 Protection services attached to the network path

| Service | Layer | Scope | Cost model |
|---|---|---|---|
| **AWS Shield Standard** | L3/L4 DDoS | Automatic, all customers | **Free** |
| **AWS Shield Advanced** | L3/L4/L7 DDoS | Opt-in per resource | Monthly subscription + DDoS cost protection + SRT access |
| **AWS WAF** | L7 | CloudFront, ALB, API Gateway, AppSync, Cognito, App Runner, Verified Access | Per web ACL, per rule, per million requests |
| **AWS Network Firewall** | L3–L7, stateful | VPC-level, Suricata-compatible rules | Endpoint-hours + per-GB |
| **AWS Firewall Manager** | Policy | Org-wide WAF/Shield/SG/Network Firewall policy | Per-policy |

Note the asymmetry that the exam probes: **WAF cannot attach to an NLB or to an EC2 instance directly.** If a scenario requires L7 filtering in front of a TCP service, the answer is to put an ALB (or CloudFront) in the path first.

---

## 7. Complete infrastructure — a production three-tier VPC

This CloudFormation template is complete and deployable as written. It builds a dual-stack, three-tier VPC across two AZs with per-AZ NAT, an egress-only IGW for IPv6, a free S3 gateway endpoint, the interface endpoints required for SSM-based access without any inbound SSH, a stateless NACL guarding the data tier, VPC Flow Logs with the extended field set, and an internet-facing ALB with HTTP→HTTPS redirection.

```yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: >
  Production three-tier dual-stack VPC (2 AZ): public / app / data subnets,
  per-AZ NAT gateway, egress-only IGW for IPv6, S3 gateway endpoint,
  SSM+ECR+Logs interface endpoints, data-tier NACL, extended flow logs, ALB.

Parameters:
  EnvName:
    Type: String
    Default: prod
    AllowedPattern: '^[a-z0-9-]{2,16}$'
    Description: Environment name used as a tag and resource-name prefix.

  VpcCidr:
    Type: String
    Default: 10.42.0.0/16
    AllowedPattern: '^(\d{1,3}\.){3}\d{1,3}/(1[6-9]|2[0-8])$'
    Description: Primary IPv4 CIDR. Must not overlap on-prem or peered space.

  CertificateArn:
    Type: String
    Description: ACM certificate ARN in this Region for the HTTPS listener.

  AllowedIngressCidr:
    Type: String
    Default: 0.0.0.0/0
    Description: Client CIDR permitted to reach the ALB on 80/443.

  FlowLogRetentionDays:
    Type: Number
    Default: 30
    AllowedValues: [1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365]

Resources:

  # ------------------------------------------------------------------ VPC ---
  Vpc:
    Type: AWS::EC2::VPC
    Properties:
      CidrBlock: !Ref VpcCidr
      EnableDnsSupport: true        # required for the .2 resolver
      EnableDnsHostnames: true      # required for private hosted zones + PrivateLink private DNS
      InstanceTenancy: default
      Tags:
        - Key: Name
          Value: !Sub '${EnvName}-vpc'

  Ipv6Cidr:
    Type: AWS::EC2::VPCCidrBlock
    Properties:
      VpcId: !Ref Vpc
      AmazonProvidedIpv6CidrBlock: true   # allocates a /56

  # -------------------------------------------------------------- Gateways ---
  InternetGateway:
    Type: AWS::EC2::InternetGateway
    Properties:
      Tags:
        - Key: Name
          Value: !Sub '${EnvName}-igw'

  IgwAttachment:
    Type: AWS::EC2::VPCGatewayAttachment
    Properties:
      VpcId: !Ref Vpc
      InternetGatewayId: !Ref InternetGateway

  EgressOnlyIgw:
    Type: AWS::EC2::EgressOnlyInternetGateway
    Properties:
      VpcId: !Ref Vpc

  # --------------------------------------------------------------- Subnets ---
  # IPv4: !Cidr [VpcCidr, 16, 12] carves the /16 into sixteen /20 blocks.
  # IPv6: !Cidr [<vpc /56>, 6, 64] carves six /64 blocks (64 is mandatory for IPv6).

  PublicSubnetA:
    Type: AWS::EC2::Subnet
    DependsOn: Ipv6Cidr
    Properties:
      VpcId: !Ref Vpc
      AvailabilityZone: !Select [0, !GetAZs '']
      CidrBlock: !Select [0, !Cidr [!Ref VpcCidr, 16, 12]]
      Ipv6CidrBlock: !Select [0, !Cidr [!Select [0, !GetAtt Vpc.Ipv6CidrBlocks], 6, 64]]
      MapPublicIpOnLaunch: true
      AssignIpv6AddressOnCreation: true
      Tags:
        - Key: Name
          Value: !Sub '${EnvName}-public-a'
        - Key: kubernetes.io/role/elb
          Value: '1'

  PublicSubnetB:
    Type: AWS::EC2::Subnet
    DependsOn: Ipv6Cidr
    Properties:
      VpcId: !Ref Vpc
      AvailabilityZone: !Select [1, !GetAZs '']
      CidrBlock: !Select [1, !Cidr [!Ref VpcCidr, 16, 12]]
      Ipv6CidrBlock: !Select [1, !Cidr [!Select [0, !GetAtt Vpc.Ipv6CidrBlocks], 6, 64]]
      MapPublicIpOnLaunch: true
      AssignIpv6AddressOnCreation: true
      Tags:
        - Key: Name
          Value: !Sub '${EnvName}-public-b'
        - Key: kubernetes.io/role/elb
          Value: '1'

  AppSubnetA:
    Type: AWS::EC2::Subnet
    DependsOn: Ipv6Cidr
    Properties:
      VpcId: !Ref Vpc
      AvailabilityZone: !Select [0, !GetAZs '']
      CidrBlock: !Select [4, !Cidr [!Ref VpcCidr, 16, 12]]
      Ipv6CidrBlock: !Select [2, !Cidr [!Select [0, !GetAtt Vpc.Ipv6CidrBlocks], 6, 64]]
      MapPublicIpOnLaunch: false
      AssignIpv6AddressOnCreation: true
      Tags:
        - Key: Name
          Value: !Sub '${EnvName}-app-a'
        - Key: kubernetes.io/role/internal-elb
          Value: '1'

  AppSubnetB:
    Type: AWS::EC2::Subnet
    DependsOn: Ipv6Cidr
    Properties:
      VpcId: !Ref Vpc
      AvailabilityZone: !Select [1, !GetAZs '']
      CidrBlock: !Select [5, !Cidr [!Ref VpcCidr, 16, 12]]
      Ipv6CidrBlock: !Select [3, !Cidr [!Select [0, !GetAtt Vpc.Ipv6CidrBlocks], 6, 64]]
      MapPublicIpOnLaunch: false
      AssignIpv6AddressOnCreation: true
      Tags:
        - Key: Name
          Value: !Sub '${EnvName}-app-b'
        - Key: kubernetes.io/role/internal-elb
          Value: '1'

  DataSubnetA:
    Type: AWS::EC2::Subnet
    DependsOn: Ipv6Cidr
    Properties:
      VpcId: !Ref Vpc
      AvailabilityZone: !Select [0, !GetAZs '']
      CidrBlock: !Select [8, !Cidr [!Ref VpcCidr, 16, 12]]
      Ipv6CidrBlock: !Select [4, !Cidr [!Select [0, !GetAtt Vpc.Ipv6CidrBlocks], 6, 64]]
      MapPublicIpOnLaunch: false
      AssignIpv6AddressOnCreation: false
      Tags:
        - Key: Name
          Value: !Sub '${EnvName}-data-a'

  DataSubnetB:
    Type: AWS::EC2::Subnet
    DependsOn: Ipv6Cidr
    Properties:
      VpcId: !Ref Vpc
      AvailabilityZone: !Select [1, !GetAZs '']
      CidrBlock: !Select [9, !Cidr [!Ref VpcCidr, 16, 12]]
      Ipv6CidrBlock: !Select [5, !Cidr [!Select [0, !GetAtt Vpc.Ipv6CidrBlocks], 6, 64]]
      MapPublicIpOnLaunch: false
      AssignIpv6AddressOnCreation: false
      Tags:
        - Key: Name
          Value: !Sub '${EnvName}-data-b'

  # ------------------------------------------------------------ NAT (per AZ) ---
  NatEipA:
    Type: AWS::EC2::EIP
    DependsOn: IgwAttachment
    Properties:
      Domain: vpc
      Tags:
        - Key: Name
          Value: !Sub '${EnvName}-nat-eip-a'

  NatEipB:
    Type: AWS::EC2::EIP
    DependsOn: IgwAttachment
    Properties:
      Domain: vpc
      Tags:
        - Key: Name
          Value: !Sub '${EnvName}-nat-eip-b'

  NatGatewayA:
    Type: AWS::EC2::NatGateway
    Properties:
      AllocationId: !GetAtt NatEipA.AllocationId
      SubnetId: !Ref PublicSubnetA        # MUST live in a public subnet
      ConnectivityType: public
      Tags:
        - Key: Name
          Value: !Sub '${EnvName}-nat-a'

  NatGatewayB:
    Type: AWS::EC2::NatGateway
    Properties:
      AllocationId: !GetAtt NatEipB.AllocationId
      SubnetId: !Ref PublicSubnetB
      ConnectivityType: public
      Tags:
        - Key: Name
          Value: !Sub '${EnvName}-nat-b'

  # ---------------------------------------------------------- Route tables ---
  PublicRouteTable:
    Type: AWS::EC2::RouteTable
    Properties:
      VpcId: !Ref Vpc
      Tags:
        - Key: Name
          Value: !Sub '${EnvName}-rt-public'

  PublicDefaultRouteV4:
    Type: AWS::EC2::Route
    DependsOn: IgwAttachment
    Properties:
      RouteTableId: !Ref PublicRouteTable
      DestinationCidrBlock: 0.0.0.0/0
      GatewayId: !Ref InternetGateway

  PublicDefaultRouteV6:
    Type: AWS::EC2::Route
    DependsOn: IgwAttachment
    Properties:
      RouteTableId: !Ref PublicRouteTable
      DestinationIpv6CidrBlock: ::/0
      GatewayId: !Ref InternetGateway

  PublicRtAssocA:
    Type: AWS::EC2::SubnetRouteTableAssociation
    Properties:
      SubnetId: !Ref PublicSubnetA
      RouteTableId: !Ref PublicRouteTable

  PublicRtAssocB:
    Type: AWS::EC2::SubnetRouteTableAssociation
    Properties:
      SubnetId: !Ref PublicSubnetB
      RouteTableId: !Ref PublicRouteTable

  AppRouteTableA:
    Type: AWS::EC2::RouteTable
    Properties:
      VpcId: !Ref Vpc
      Tags:
        - Key: Name
          Value: !Sub '${EnvName}-rt-app-a'

  AppDefaultRouteV4A:
    Type: AWS::EC2::Route
    Properties:
      RouteTableId: !Ref AppRouteTableA
      DestinationCidrBlock: 0.0.0.0/0
      NatGatewayId: !Ref NatGatewayA     # AZ-local NAT: no cross-AZ transfer, no shared blast radius

  AppDefaultRouteV6A:
    Type: AWS::EC2::Route
    Properties:
      RouteTableId: !Ref AppRouteTableA
      DestinationIpv6CidrBlock: ::/0
      EgressOnlyInternetGatewayId: !Ref EgressOnlyIgw

  AppRtAssocA:
    Type: AWS::EC2::SubnetRouteTableAssociation
    Properties:
      SubnetId: !Ref AppSubnetA
      RouteTableId: !Ref AppRouteTableA

  AppRouteTableB:
    Type: AWS::EC2::RouteTable
    Properties:
      VpcId: !Ref Vpc
      Tags:
        - Key: Name
          Value: !Sub '${EnvName}-rt-app-b'

  AppDefaultRouteV4B:
    Type: AWS::EC2::Route
    Properties:
      RouteTableId: !Ref AppRouteTableB
      DestinationCidrBlock: 0.0.0.0/0
      NatGatewayId: !Ref NatGatewayB

  AppDefaultRouteV6B:
    Type: AWS::EC2::Route
    Properties:
      RouteTableId: !Ref AppRouteTableB
      DestinationIpv6CidrBlock: ::/0
      EgressOnlyInternetGatewayId: !Ref EgressOnlyIgw

  AppRtAssocB:
    Type: AWS::EC2::SubnetRouteTableAssociation
    Properties:
      SubnetId: !Ref AppSubnetB
      RouteTableId: !Ref AppRouteTableB

  # Data tier: NO default route at all. Egress happens only via VPC endpoints.
  DataRouteTable:
    Type: AWS::EC2::RouteTable
    Properties:
      VpcId: !Ref Vpc
      Tags:
        - Key: Name
          Value: !Sub '${EnvName}-rt-data'

  DataRtAssocA:
    Type: AWS::EC2::SubnetRouteTableAssociation
    Properties:
      SubnetId: !Ref DataSubnetA
      RouteTableId: !Ref DataRouteTable

  DataRtAssocB:
    Type: AWS::EC2::SubnetRouteTableAssociation
    Properties:
      SubnetId: !Ref DataSubnetB
      RouteTableId: !Ref DataRouteTable

  # ------------------------------------------------------- VPC endpoints ---
  S3GatewayEndpoint:
    Type: AWS::EC2::VPCEndpoint
    Properties:
      VpcId: !Ref Vpc
      ServiceName: !Sub 'com.amazonaws.${AWS::Region}.s3'
      VpcEndpointType: Gateway
      RouteTableIds:
        - !Ref AppRouteTableA
        - !Ref AppRouteTableB
        - !Ref DataRouteTable
      PolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Sid: AllowAllWithinAccount
            Effect: Allow
            Principal: '*'
            Action: 's3:*'
            Resource: '*'
            Condition:
              StringEquals:
                'aws:PrincipalAccount': !Ref 'AWS::AccountId'

  DynamoDbGatewayEndpoint:
    Type: AWS::EC2::VPCEndpoint
    Properties:
      VpcId: !Ref Vpc
      ServiceName: !Sub 'com.amazonaws.${AWS::Region}.dynamodb'
      VpcEndpointType: Gateway
      RouteTableIds:
        - !Ref AppRouteTableA
        - !Ref AppRouteTableB
        - !Ref DataRouteTable

  EndpointSecurityGroup:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: Interface VPC endpoint ENIs - HTTPS from inside the VPC only
      VpcId: !Ref Vpc
      SecurityGroupIngress:
        - IpProtocol: tcp
          FromPort: 443
          ToPort: 443
          CidrIp: !Ref VpcCidr
          Description: HTTPS from any workload in this VPC
      SecurityGroupEgress:
        - IpProtocol: '-1'
          CidrIp: 127.0.0.1/32
          Description: Endpoint ENIs never initiate outbound traffic
      Tags:
        - Key: Name
          Value: !Sub '${EnvName}-sg-vpce'

  SsmEndpoint:
    Type: AWS::EC2::VPCEndpoint
    Properties:
      VpcId: !Ref Vpc
      ServiceName: !Sub 'com.amazonaws.${AWS::Region}.ssm'
      VpcEndpointType: Interface
      PrivateDnsEnabled: true
      SubnetIds: [!Ref AppSubnetA, !Ref AppSubnetB]
      SecurityGroupIds: [!Ref EndpointSecurityGroup]

  SsmMessagesEndpoint:
    Type: AWS::EC2::VPCEndpoint
    Properties:
      VpcId: !Ref Vpc
      ServiceName: !Sub 'com.amazonaws.${AWS::Region}.ssmmessages'
      VpcEndpointType: Interface
      PrivateDnsEnabled: true
      SubnetIds: [!Ref AppSubnetA, !Ref AppSubnetB]
      SecurityGroupIds: [!Ref EndpointSecurityGroup]

  Ec2MessagesEndpoint:
    Type: AWS::EC2::VPCEndpoint
    Properties:
      VpcId: !Ref Vpc
      ServiceName: !Sub 'com.amazonaws.${AWS::Region}.ec2messages'
      VpcEndpointType: Interface
      PrivateDnsEnabled: true
      SubnetIds: [!Ref AppSubnetA, !Ref AppSubnetB]
      SecurityGroupIds: [!Ref EndpointSecurityGroup]

  EcrApiEndpoint:
    Type: AWS::EC2::VPCEndpoint
    Properties:
      VpcId: !Ref Vpc
      ServiceName: !Sub 'com.amazonaws.${AWS::Region}.ecr.api'
      VpcEndpointType: Interface
      PrivateDnsEnabled: true
      SubnetIds: [!Ref AppSubnetA, !Ref AppSubnetB]
      SecurityGroupIds: [!Ref EndpointSecurityGroup]

  EcrDkrEndpoint:
    Type: AWS::EC2::VPCEndpoint
    Properties:
      VpcId: !Ref Vpc
      ServiceName: !Sub 'com.amazonaws.${AWS::Region}.ecr.dkr'
      VpcEndpointType: Interface
      PrivateDnsEnabled: true
      SubnetIds: [!Ref AppSubnetA, !Ref AppSubnetB]
      SecurityGroupIds: [!Ref EndpointSecurityGroup]

  LogsEndpoint:
    Type: AWS::EC2::VPCEndpoint
    Properties:
      VpcId: !Ref Vpc
      ServiceName: !Sub 'com.amazonaws.${AWS::Region}.logs'
      VpcEndpointType: Interface
      PrivateDnsEnabled: true
      SubnetIds: [!Ref AppSubnetA, !Ref AppSubnetB]
      SecurityGroupIds: [!Ref EndpointSecurityGroup]

  # --------------------------------------------------- Security groups ---
  AlbSecurityGroup:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: Internet-facing ALB
      VpcId: !Ref Vpc
      SecurityGroupIngress:
        - IpProtocol: tcp
          FromPort: 80
          ToPort: 80
          CidrIp: !Ref AllowedIngressCidr
          Description: HTTP (redirected to HTTPS at the listener)
        - IpProtocol: tcp
          FromPort: 443
          ToPort: 443
          CidrIp: !Ref AllowedIngressCidr
          Description: HTTPS
      SecurityGroupEgress:
        - IpProtocol: tcp
          FromPort: 8080
          ToPort: 8080
          CidrIp: !Ref VpcCidr
          Description: To application targets only
      Tags:
        - Key: Name
          Value: !Sub '${EnvName}-sg-alb'

  AppSecurityGroup:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: Application tier
      VpcId: !Ref Vpc
      SecurityGroupEgress:
        - IpProtocol: tcp
          FromPort: 443
          ToPort: 443
          CidrIp: 0.0.0.0/0
          Description: HTTPS to AWS endpoints and external APIs
      Tags:
        - Key: Name
          Value: !Sub '${EnvName}-sg-app'

  # Declared separately to allow SG-to-SG references without a circular dependency.
  AppIngressFromAlb:
    Type: AWS::EC2::SecurityGroupIngress
    Properties:
      GroupId: !Ref AppSecurityGroup
      IpProtocol: tcp
      FromPort: 8080
      ToPort: 8080
      SourceSecurityGroupId: !Ref AlbSecurityGroup
      Description: Only the ALB may reach the app port

  AppEgressToData:
    Type: AWS::EC2::SecurityGroupEgress
    Properties:
      GroupId: !Ref AppSecurityGroup
      IpProtocol: tcp
      FromPort: 5432
      ToPort: 5432
      DestinationSecurityGroupId: !Ref DataSecurityGroup
      Description: PostgreSQL to the data tier

  DataSecurityGroup:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: Data tier - PostgreSQL from the app tier only
      VpcId: !Ref Vpc
      SecurityGroupEgress:
        - IpProtocol: tcp
          FromPort: 443
          ToPort: 443
          CidrIp: !Ref VpcCidr
          Description: HTTPS to VPC endpoints (backups to S3, logs)
      Tags:
        - Key: Name
          Value: !Sub '${EnvName}-sg-data'

  DataIngressFromApp:
    Type: AWS::EC2::SecurityGroupIngress
    Properties:
      GroupId: !Ref DataSecurityGroup
      IpProtocol: tcp
      FromPort: 5432
      ToPort: 5432
      SourceSecurityGroupId: !Ref AppSecurityGroup
      Description: PostgreSQL from the application tier

  # ------------------------------------- Data-tier NACL (stateless!) ---
  DataNacl:
    Type: AWS::EC2::NetworkAcl
    Properties:
      VpcId: !Ref Vpc
      Tags:
        - Key: Name
          Value: !Sub '${EnvName}-nacl-data'

  DataNaclInAppA:
    Type: AWS::EC2::NetworkAclEntry
    Properties:
      NetworkAclId: !Ref DataNacl
      RuleNumber: 100
      Protocol: 6
      RuleAction: allow
      Egress: false
      CidrBlock: !Select [4, !Cidr [!Ref VpcCidr, 16, 12]]
      PortRange: {From: 5432, To: 5432}

  DataNaclInAppB:
    Type: AWS::EC2::NetworkAclEntry
    Properties:
      NetworkAclId: !Ref DataNacl
      RuleNumber: 110
      Protocol: 6
      RuleAction: allow
      Egress: false
      CidrBlock: !Select [5, !Cidr [!Ref VpcCidr, 16, 12]]
      PortRange: {From: 5432, To: 5432}

  # Return traffic from the S3 gateway endpoint and interface endpoints arrives
  # on an ephemeral port. Omitting this rule is THE classic NACL outage.
  DataNaclInEphemeral:
    Type: AWS::EC2::NetworkAclEntry
    Properties:
      NetworkAclId: !Ref DataNacl
      RuleNumber: 200
      Protocol: 6
      RuleAction: allow
      Egress: false
      CidrBlock: 0.0.0.0/0
      PortRange: {From: 1024, To: 65535}

  DataNaclOutAppA:
    Type: AWS::EC2::NetworkAclEntry
    Properties:
      NetworkAclId: !Ref DataNacl
      RuleNumber: 100
      Protocol: 6
      RuleAction: allow
      Egress: true
      CidrBlock: !Select [4, !Cidr [!Ref VpcCidr, 16, 12]]
      PortRange: {From: 1024, To: 65535}

  DataNaclOutAppB:
    Type: AWS::EC2::NetworkAclEntry
    Properties:
      NetworkAclId: !Ref DataNacl
      RuleNumber: 110
      Protocol: 6
      RuleAction: allow
      Egress: true
      CidrBlock: !Select [5, !Cidr [!Ref VpcCidr, 16, 12]]
      PortRange: {From: 1024, To: 65535}

  DataNaclOutHttps:
    Type: AWS::EC2::NetworkAclEntry
    Properties:
      NetworkAclId: !Ref DataNacl
      RuleNumber: 200
      Protocol: 6
      RuleAction: allow
      Egress: true
      CidrBlock: 0.0.0.0/0
      PortRange: {From: 443, To: 443}

  DataNaclAssocA:
    Type: AWS::EC2::SubnetNetworkAclAssociation
    Properties:
      SubnetId: !Ref DataSubnetA
      NetworkAclId: !Ref DataNacl

  DataNaclAssocB:
    Type: AWS::EC2::SubnetNetworkAclAssociation
    Properties:
      SubnetId: !Ref DataSubnetB
      NetworkAclId: !Ref DataNacl

  # ------------------------------------------------------- Flow logs ---
  FlowLogGroup:
    Type: AWS::Logs::LogGroup
    Properties:
      LogGroupName: !Sub '/aws/vpc/flowlogs/${EnvName}'
      RetentionInDays: !Ref FlowLogRetentionDays

  FlowLogRole:
    Type: AWS::IAM::Role
    Properties:
      AssumeRolePolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Effect: Allow
            Principal:
              Service: vpc-flow-logs.amazonaws.com
            Action: sts:AssumeRole
            Condition:
              StringEquals:
                'aws:SourceAccount': !Ref 'AWS::AccountId'
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
      MaxAggregationInterval: 60
      LogDestinationType: cloud-watch-logs
      LogGroupName: !Ref FlowLogGroup
      DeliverLogsPermissionArn: !GetAtt FlowLogRole.Arn
      # pkt-srcaddr / pkt-dstaddr expose the real endpoints behind NAT and load
      # balancers; flow-direction and traffic-path make egress paths auditable.
      LogFormat: >-
        ${version} ${account-id} ${interface-id} ${srcaddr} ${dstaddr}
        ${srcport} ${dstport} ${protocol} ${packets} ${bytes} ${start} ${end}
        ${action} ${log-status} ${vpc-id} ${subnet-id} ${instance-id}
        ${tcp-flags} ${type} ${pkt-srcaddr} ${pkt-dstaddr}
        ${pkt-src-aws-service} ${pkt-dst-aws-service}
        ${flow-direction} ${traffic-path}

  # ------------------------------------------------------------- ALB ---
  Alb:
    Type: AWS::ElasticLoadBalancingV2::LoadBalancer
    Properties:
      Name: !Sub '${EnvName}-alb'
      Type: application
      Scheme: internet-facing
      IpAddressType: dualstack
      Subnets: [!Ref PublicSubnetA, !Ref PublicSubnetB]
      SecurityGroups: [!Ref AlbSecurityGroup]
      LoadBalancerAttributes:
        - Key: routing.http.drop_invalid_header_fields.enabled
          Value: 'true'
        - Key: routing.http2.enabled
          Value: 'true'
        - Key: idle_timeout.timeout_seconds
          Value: '60'
        - Key: deletion_protection.enabled
          Value: 'true'

  AppTargetGroup:
    Type: AWS::ElasticLoadBalancingV2::TargetGroup
    Properties:
      Name: !Sub '${EnvName}-tg-app'
      VpcId: !Ref Vpc
      TargetType: ip
      Protocol: HTTP
      Port: 8080
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
        - Key: stickiness.enabled
          Value: 'false'

  HttpsListener:
    Type: AWS::ElasticLoadBalancingV2::Listener
    Properties:
      LoadBalancerArn: !Ref Alb
      Protocol: HTTPS
      Port: 443
      SslPolicy: ELBSecurityPolicy-TLS13-1-2-2021-06
      Certificates:
        - CertificateArn: !Ref CertificateArn
      DefaultActions:
        - Type: forward
          TargetGroupArn: !Ref AppTargetGroup

  HttpRedirectListener:
    Type: AWS::ElasticLoadBalancingV2::Listener
    Properties:
      LoadBalancerArn: !Ref Alb
      Protocol: HTTP
      Port: 80
      DefaultActions:
        - Type: redirect
          RedirectConfig:
            Protocol: HTTPS
            Port: '443'
            StatusCode: HTTP_301

Outputs:
  VpcId:
    Value: !Ref Vpc
    Export:
      Name: !Sub '${EnvName}-vpc-id'
  VpcIpv6Cidr:
    Value: !Select [0, !GetAtt Vpc.Ipv6CidrBlocks]
  AppSubnetIds:
    Value: !Join [',', [!Ref AppSubnetA, !Ref AppSubnetB]]
    Export:
      Name: !Sub '${EnvName}-app-subnets'
  DataSubnetIds:
    Value: !Join [',', [!Ref DataSubnetA, !Ref DataSubnetB]]
  AlbDnsName:
    Value: !GetAtt Alb.DNSName
  AlbHostedZoneId:
    Description: Use with a Route 53 alias record at the zone apex
    Value: !GetAtt Alb.CanonicalHostedZoneID
  NatPublicIps:
    Description: Egress IPs to give partners for allowlisting
    Value: !Join [',', [!Ref NatEipA, !Ref NatEipB]]
```

> **Scaling note:** the six interface endpoints are written out explicitly for clarity. In a real estate, add `Transform: 'AWS::LanguageExtensions'` and generate them with `Fn::ForEach` over a service-name list to avoid the copy-paste drift that eventually leaves one endpoint in a single AZ.

### 7.1 Route 53 records for this stack

```yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: Public DNS for the ALB, with a latency-based multi-Region shape.

Parameters:
  HostedZoneId:
    Type: AWS::Route53::HostedZone::Id
  DomainName:
    Type: String
    Default: app.example.com
  AlbDnsName:
    Type: String
  AlbHostedZoneId:
    Type: String

Resources:
  # Alias at the zone apex - a CNAME is illegal here, and alias queries are free.
  ApexAlias:
    Type: AWS::Route53::RecordSet
    Properties:
      HostedZoneId: !Ref HostedZoneId
      Name: !Ref DomainName
      Type: A
      AliasTarget:
        DNSName: !Ref AlbDnsName
        HostedZoneId: !Ref AlbHostedZoneId
        EvaluateTargetHealth: true

  ApexAliasV6:
    Type: AWS::Route53::RecordSet
    Properties:
      HostedZoneId: !Ref HostedZoneId
      Name: !Ref DomainName
      Type: AAAA
      AliasTarget:
        DNSName: !Ref AlbDnsName
        HostedZoneId: !Ref AlbHostedZoneId
        EvaluateTargetHealth: true

  # Latency policy: one record per Region, same name, distinct SetIdentifier.
  LatencyPrimaryRegion:
    Type: AWS::Route53::RecordSet
    Properties:
      HostedZoneId: !Ref HostedZoneId
      Name: !Sub 'api.${DomainName}'
      Type: A
      SetIdentifier: !Sub 'latency-${AWS::Region}'
      Region: !Ref 'AWS::Region'
      AliasTarget:
        DNSName: !Ref AlbDnsName
        HostedZoneId: !Ref AlbHostedZoneId
        EvaluateTargetHealth: true

  # Weighted canary: 5% of traffic to the new stack, 95% to the current one.
  CanaryHealthCheck:
    Type: AWS::Route53::HealthCheck
    Properties:
      HealthCheckConfig:
        Type: HTTPS
        FullyQualifiedDomainName: !Ref AlbDnsName
        ResourcePath: /healthz
        Port: 443
        RequestInterval: 10
        FailureThreshold: 2
        MeasureLatency: true
      HealthCheckTags:
        - Key: Name
          Value: canary-healthcheck
```

---

## 8. Command line: real invocations and expected output

### 8.1 Inventory the topology

```
$ aws ec2 describe-vpcs --filters Name=tag:Name,Values=prod-vpc \
    --query 'Vpcs[].{Id:VpcId,Cidr:CidrBlock,V6:Ipv6CidrBlockAssociationSet[0].Ipv6CidrBlock,Default:IsDefault}' \
    --output table
------------------------------------------------------------------------------
|                                DescribeVpcs                                |
+---------+----------------+-----------------------+-------------------------+
| Default |     Cidr       |          Id           |           V6            |
+---------+----------------+-----------------------+-------------------------+
|  False  |  10.42.0.0/16  |  vpc-0a3f9c2e7b1d4508a|  2600:1f18:2c4a:e600::/56|
+---------+----------------+-----------------------+-------------------------+
```

```
$ aws ec2 describe-subnets --filters Name=vpc-id,Values=vpc-0a3f9c2e7b1d4508a \
    --query 'sort_by(Subnets,&CidrBlock)[].{Name:Tags[?Key==`Name`]|[0].Value,Id:SubnetId,AZ:AvailabilityZone,Cidr:CidrBlock,Free:AvailableIpAddressCount,PubIP:MapPublicIpOnLaunch}' \
    --output table
---------------------------------------------------------------------------------------------
|                                      DescribeSubnets                                      |
+--------------+--------+----------------+-------+----------------+---------------+---------+
|      AZ      |  Cidr  |      Free      | Name  |      Id        |     PubIP     |         |
+--------------+--------+----------------+-------+----------------+---------------+---------+
|  us-east-1a  | 10.42.0.0/20  | 4088  | prod-public-a | subnet-01c8...  | True  |
|  us-east-1b  | 10.42.16.0/20 | 4090  | prod-public-b | subnet-0f22...  | True  |
|  us-east-1a  | 10.42.64.0/20 | 3612  | prod-app-a    | subnet-09ab...  | False |
|  us-east-1b  | 10.42.80.0/20 | 3644  | prod-app-b    | subnet-0d71...  | False |
|  us-east-1a  | 10.42.128.0/20| 4089  | prod-data-a   | subnet-0e40...  | False |
|  us-east-1b  | 10.42.144.0/20| 4089  | prod-data-b   | subnet-0b93...  | False |
+--------------+--------+----------------+-------+----------------+---------------+---------+
```

`AvailableIpAddressCount` is the metric to alarm on for any EKS cluster: `4096 − 5 reserved − allocated`. A subnet trending toward zero produces `InsufficientFreeAddressesInSubnet` and pods stuck in `ContainerCreating`, with no message anywhere that mentions IP exhaustion directly.

### 8.2 Prove which subnets are public

```
$ aws ec2 describe-route-tables --filters Name=vpc-id,Values=vpc-0a3f9c2e7b1d4508a \
    --query 'RouteTables[].{RT:RouteTableId,Name:Tags[?Key==`Name`]|[0].Value,Routes:Routes[].[DestinationCidrBlock||DestinationIpv6CidrBlock||DestinationPrefixListId,GatewayId||NatGatewayId||EgressOnlyInternetGatewayId]}' \
    --output json
[
  {
    "RT": "rtb-05e1a7c9d3b6f2401",
    "Name": "prod-rt-public",
    "Routes": [
      ["10.42.0.0/16", "local"],
      ["2600:1f18:2c4a:e600::/56", "local"],
      ["0.0.0.0/0", "igw-0c94b1f7e2a83d5b6"],
      ["::/0", "igw-0c94b1f7e2a83d5b6"]
    ]
  },
  {
    "RT": "rtb-0b74f3d18ea9c25de",
    "Name": "prod-rt-app-a",
    "Routes": [
      ["10.42.0.0/16", "local"],
      ["0.0.0.0/0", "nat-0918c4e7b2f3d6a51"],
      ["::/0", "eigw-0aa41c9d7e5b83f20"],
      ["pl-63a5400a", null]
    ]
  },
  {
    "RT": "rtb-0f2c9e84a1b7d3506",
    "Name": "prod-rt-data",
    "Routes": [
      ["10.42.0.0/16", "local"],
      ["pl-63a5400a", null],
      ["pl-02cd2c6b", null]
    ]
  }
]
```

Read this carefully — it is the whole architecture in one output:
- `prod-rt-public` has `0.0.0.0/0 → igw-…`. **That, and only that, makes a subnet public.**
- `prod-rt-app-a` egresses IPv4 through NAT and IPv6 through the egress-only IGW at zero cost.
- `prod-rt-data` has **no default route at all**. `pl-63a5400a` (S3) and `pl-02cd2c6b` (DynamoDB) are the gateway-endpoint prefix lists. The data tier can reach S3 and DynamoDB and *nothing else* — a routing-layer control that no misconfigured security group can undo.
- The `local` route is implicit, cannot be deleted, and always wins because VPC routing is longest-prefix-match with `local` treated as most specific.

### 8.3 NAT gateway state and cost signal

```
$ aws ec2 describe-nat-gateways --filter Name=vpc-id,Values=vpc-0a3f9c2e7b1d4508a \
    --query 'NatGateways[].{Id:NatGatewayId,AZ:SubnetId,State:State,Public:NatGatewayAddresses[0].PublicIp,Private:NatGatewayAddresses[0].PrivateIp}' \
    --output table
-------------------------------------------------------------------------------------
|                              DescribeNatGateways                                  |
+---------------------+---------------------------+-----------+---------------------+
|         AZ          |            Id             |  Private  |       Public        |
+---------------------+---------------------------+-----------+---------------------+
|  subnet-01c8...     |  nat-0918c4e7b2f3d6a51    | 10.42.3.71| 54.221.18.203       |
|  subnet-0f22...     |  nat-0a52d7f1c8b394e07    | 10.42.19.8| 3.219.44.87         |
+---------------------+---------------------------+-----------+---------------------+
```

```
$ aws cloudwatch get-metric-statistics \
    --namespace AWS/NATGateway --metric-name BytesOutToDestination \
    --dimensions Name=NatGatewayId,Value=nat-0918c4e7b2f3d6a51 \
    --start-time 2026-09-01T00:00:00Z --end-time 2026-09-04T00:00:00Z \
    --period 86400 --statistics Sum --output table
------------------------------------------------
|            GetMetricStatistics               |
+---------------------+------------------+-----+
|      Timestamp      |       Sum        |Unit |
+---------------------+------------------+-----+
| 2026-09-01T00:00:00Z|  482913774592.0  |Bytes|
| 2026-09-02T00:00:00Z|  511208441856.0  |Bytes|
| 2026-09-03T00:00:00Z|  497660219392.0  |Bytes|
+---------------------+------------------+-----+
```

About 483 GB/day out of one NAT gateway. At ~$0.045/GB processed that is roughly **$22/day per gateway** in NAT charges alone, before internet data-transfer-out. The next question is always: *how much of that is AWS-service traffic that belongs on an endpoint?* Answer it with `pkt-dst-aws-service` in the flow logs (§8.6).

### 8.4 Verify security groups actually reference each other

```
$ aws ec2 describe-security-groups --group-ids sg-0d41e9c72b8a35f60 \
    --query 'SecurityGroups[0].IpPermissions[].{Proto:IpProtocol,From:FromPort,To:ToPort,Cidrs:IpRanges[].CidrIp,SGs:UserIdGroupPairs[].GroupId}' \
    --output json
[
  {
    "Proto": "tcp",
    "From": 5432,
    "To": 5432,
    "Cidrs": [],
    "SGs": ["sg-07b2f9d4e1c86a305"]
  }
]
```

Empty `Cidrs` and a populated `SGs` is the shape you want in an audit: reachability bound to workload identity, not to address space.

### 8.5 Interface endpoints and DNS override

```
$ aws ec2 describe-vpc-endpoints --filters Name=vpc-id,Values=vpc-0a3f9c2e7b1d4508a \
    --query 'VpcEndpoints[].{Service:ServiceName,Type:VpcEndpointType,State:State,PrivDNS:PrivateDnsEnabled,AZs:length(SubnetIds)}' \
    --output table
-----------------------------------------------------------------------------------
|                             DescribeVpcEndpoints                                |
+-----+---------+-----------------------------------------+-----------+-----------+
| AZs | PrivDNS |                 Service                 |   State   |   Type    |
+-----+---------+-----------------------------------------+-----------+-----------+
|  0  |  None   |  com.amazonaws.us-east-1.s3             | available |  Gateway  |
|  0  |  None   |  com.amazonaws.us-east-1.dynamodb       | available |  Gateway  |
|  2  |  True   |  com.amazonaws.us-east-1.ssm            | available | Interface |
|  2  |  True   |  com.amazonaws.us-east-1.ssmmessages    | available | Interface |
|  2  |  True   |  com.amazonaws.us-east-1.ec2messages    | available | Interface |
|  2  |  True   |  com.amazonaws.us-east-1.ecr.api        | available | Interface |
|  2  |  True   |  com.amazonaws.us-east-1.ecr.dkr        | available | Interface |
|  2  |  True   |  com.amazonaws.us-east-1.logs           | available | Interface |
+-----+---------+-----------------------------------------+-----------+-----------+
```

From an instance inside the VPC, private DNS is what makes the endpoint transparent:

```
$ dig +short ssm.us-east-1.amazonaws.com
10.42.68.204
10.42.85.117
```

RFC1918 answers for a public AWS endpoint name prove that private DNS is working and that the SDK will hit the ENI. If you instead see a public address:

```
$ dig +short ssm.us-east-1.amazonaws.com
52.46.132.19
```

then either `enableDnsHostnames` is off on the VPC, `PrivateDnsEnabled` is false on the endpoint, or the instance is using a DNS server other than the `.2` resolver. All three are silent misconfigurations that "work" through NAT while quietly costing money and leaving the private path unverified.

Gateway endpoints behave differently — DNS still returns a public S3 address, and the *route table* diverts the packet:

```
$ dig +short s3.us-east-1.amazonaws.com
52.216.221.8

$ curl -s -o /dev/null -w '%{http_code} %{remote_ip} %{time_total}s\n' \
    https://prod-artifacts.s3.us-east-1.amazonaws.com/healthcheck.txt
200 52.216.221.8 0.031s
```

The public IP is expected and correct. Confirm the path with flow logs (`traffic-path` / `pkt-dst-aws-service`), not with `dig`.

### 8.6 Flow logs: find the traffic that should not be on NAT

```
$ aws logs start-query \
    --log-group-name /aws/vpc/flowlogs/prod \
    --start-time $(date -d '24 hours ago' +%s) --end-time $(date +%s) \
    --query-string 'fields @timestamp, srcaddr, pkt_dst_aws_service, bytes
      | filter traffic_path = 4 and pkt_dst_aws_service != "-"
      | stats sum(bytes)/1024/1024/1024 as gb by pkt_dst_aws_service
      | sort gb desc | limit 10'
{
    "queryId": "9f4c1a2e-70bd-4a55-b2f1-6d83e0c47915"
}

$ aws logs get-query-results --query-id 9f4c1a2e-70bd-4a55-b2f1-6d83e0c47915 \
    --query 'results[].[field,value]' --output text
pkt_dst_aws_service     S3
gb                      1183.44
pkt_dst_aws_service     DYNAMODB
gb                      212.07
pkt_dst_aws_service     ECR
gb                      88.61
pkt_dst_aws_service     CLOUDWATCH
gb                      19.30
```

`traffic_path = 4` means "through a NAT gateway". 1,183 GB/day of S3 traffic on that path is roughly **$53/day** of pure waste that a free gateway endpoint eliminates. The ECR and CloudWatch volumes justify their interface endpoints on cost alone ($0.01/GB beats $0.045/GB, plus the internet DTO you stop paying).

`traffic-path` values worth memorising: `1` in-VPC, `2` internet gateway or gateway VPC endpoint, `3` virtual private gateway, `4` **NAT gateway**, `5` VPC peering, `6` transit gateway, `7` Local Gateway, `8` Local Zone gateway, `9` inter-Region peering.

Rejected traffic, the first query in any connectivity incident:

```
$ aws logs start-query --log-group-name /aws/vpc/flowlogs/prod \
    --start-time $(date -d '30 minutes ago' +%s) --end-time $(date +%s) \
    --query-string 'fields @timestamp, srcaddr, dstaddr, dstport, protocol, action
      | filter action = "REJECT" and dstport = 5432
      | sort @timestamp desc | limit 20'
```

```
@timestamp                srcaddr      dstaddr       dstport  protocol  action
2026-09-04 14:02:11.000   10.42.68.31  10.42.131.14  5432     6         REJECT
2026-09-04 14:02:10.000   10.42.68.31  10.42.131.14  5432     6         REJECT
```

`REJECT` on the **inbound** direction at the destination ENI means a security group or NACL dropped it. **Absence of any record for the return flow** — you see the inbound `ACCEPT` but never the reply — points instead at a missing NACL egress rule, because the SG would have permitted the return statefully.

### 8.7 Load balancer target health

```
$ aws elbv2 describe-target-health --target-group-arn \
    arn:aws:elasticloadbalancing:us-east-1:111122223333:targetgroup/prod-tg-app/6d21a4f0b8c93e57 \
    --query 'TargetHealthDescriptions[].{Target:Target.Id,Port:Target.Port,AZ:Target.AvailabilityZone,State:TargetHealth.State,Reason:TargetHealth.Reason,Desc:TargetHealth.Description}' \
    --output table
-----------------------------------------------------------------------------------------------------------
|                                        DescribeTargetHealth                                             |
+------------+---------------------------+------+----------------------------------------+----------------+
|     AZ     |          Reason           | Port |                 Desc                   |     State      |
+------------+---------------------------+------+----------------------------------------+----------------+
| us-east-1a |  None                     | 8080 |  None                                  |  healthy       |
| us-east-1a |  None                     | 8080 |  None                                  |  healthy       |
| us-east-1b |  Target.Timeout           | 8080 |  Request timed out                     |  unhealthy     |
| us-east-1b |  Target.FailedHealthChecks|  8080|  Health checks failed with these codes:| unhealthy      |
|            |                           |      |  [404]                                 |                |
+------------+---------------------------+------+----------------------------------------+----------------+
```

The two reasons mean opposite things and get conflated constantly:

| Reason | Meaning | Where the fault is |
|---|---|---|
| `Target.Timeout` | Packet never returned | **Network**: SG on the target does not allow the ALB SG on the health-check port, or a NACL blocks it |
| `Target.FailedHealthChecks` + HTTP code | Target answered | **Application**: wrong path, wrong matcher, app returning 404/503 |
| `Target.NotInUse` | Target group not attached to a listener | Configuration |
| `Elb.RegistrationInProgress` | Still registering | Wait |
| `Target.ResponseCodeMismatch` | Answered outside the matcher range | Matcher configuration |

A timeout is a network problem; a status code is an application problem. That single distinction routes the incident to the right team in seconds.

### 8.8 Reachability Analyzer — proving a path without sending a packet

This is the tool that ends most VPC connectivity arguments, because it evaluates route tables, security groups, NACLs, and gateways as configuration rather than by probing.

```
$ aws ec2 create-network-insights-path \
    --source i-0af31c7e9b2d5406a \
    --destination i-04e7b2c1f9a83d650 \
    --destination-port 5432 --protocol tcp \
    --query 'NetworkInsightsPath.NetworkInsightsPathId' --output text
nip-0c93b7f2a184e6d05

$ aws ec2 start-network-insights-analysis \
    --network-insights-path-id nip-0c93b7f2a184e6d05 \
    --query 'NetworkInsightsAnalysis.NetworkInsightsAnalysisId' --output text
nia-0b71e4d style8c26f39a

$ aws ec2 describe-network-insights-analyses \
    --network-insights-analysis-ids nia-0b71e4d8c26f39a \
    --query 'NetworkInsightsAnalyses[0].{Status:Status,Reachable:NetworkPathFound,Explanations:Explanations[].[ExplanationCode,Acl.Id,SecurityGroup.Id]}' \
    --output json
{
    "Status": "succeeded",
    "Reachable": false,
    "Explanations": [
        [
            "ENI_SG_RULES_MISMATCH",
            null,
            "sg-0d41e9c72b8a35f60"
        ]
    ]
}
```

Common `ExplanationCode` values and their meaning:

| Code | Meaning |
|---|---|
| `ENI_SG_RULES_MISMATCH` | No security-group rule permits this flow |
| `ACL_RULES_MISMATCH` | A NACL entry denies it (check **both** directions) |
| `NO_ROUTE_TO_DESTINATION` | Route table has no matching route |
| `MISSING_INTERNET_GATEWAY` | Public path attempted with no IGW route |
| `NO_PUBLIC_IP` / `ELASTIC_NETWORK_INTERFACE_NO_PUBLIC_IP` | Instance has no public/elastic IP |
| `SUBNET_HAS_NO_ROUTE_TABLE_ASSOCIATION` | Subnet fell back to the main route table |

Reachability Analyzer costs a few cents per analysis and is the correct first step for any "cannot connect" ticket — cheaper than an engineer-hour by three orders of magnitude.

### 8.9 Hybrid connectivity status

```
$ aws directconnect describe-connections \
    --query 'connections[].{Id:connectionId,Name:connectionName,State:connectionState,Bw:bandwidth,Loc:location,Vlan:vlan,Macsec:macSecCapable,Encr:encryptionMode}' \
    --output table
------------------------------------------------------------------------------------------
|                                  DescribeConnections                                   |
+---------+--------+-------------------+------+---------+----------+---------+-----------+
|   Bw    |  Encr  |        Id         | Loc  | Macsec  |   Name   |  State  |   Vlan    |
+---------+--------+-------------------+------+---------+----------+---------+-----------+
| 10Gbps  |should_encrypt| dxcon-fh2k9x1p | EqDC2 | True | dc-primary | available | 4093 |
| 10Gbps  |no_encrypt    | dxcon-fg7m4b3q | CS1  | False| dc-backup  | available | 4094 |
+---------+--------+-------------------+------+---------+----------+---------+-----------+
```

```
$ aws ec2 describe-vpn-connections \
    --query 'VpnConnections[].{Id:VpnConnectionId,State:State,Tunnels:VgwTelemetry[].[OutsideIpAddress,Status,AcceptedRouteCount]}' \
    --output json
[
  {
    "Id": "vpn-0e83c1a7b2f94d605",
    "State": "available",
    "Tunnels": [
      ["34.201.77.14",  "UP",   42],
      ["52.90.163.201", "DOWN",  0]
    ]
  }
]
```

One tunnel `UP` is a **degraded** state, not a healthy one. Both tunnels should be `UP` and both should show a non-zero `AcceptedRouteCount`; a tunnel that is `UP` with zero accepted routes is a BGP session that established but is advertising nothing — traffic will not use it during failover, and you will discover that during the failover.

### 8.10 Path and MTU diagnostics from inside an instance

```
$ ip -br addr show dev ens5
ens5  UP  10.42.68.31/20 metric 1024 2600:1f18:2c4a:e602:8c1f:...

$ ip route get 10.42.131.14
10.42.131.14 via 10.42.64.1 dev ens5 src 10.42.68.31 uid 1000

$ curl -s -o /dev/null -w 'dns=%{time_namelookup} tcp=%{time_connect} tls=%{time_appconnect} ttfb=%{time_starttransfer} total=%{time_total}\n' \
    https://api.example.com/healthz
dns=0.004 tcp=0.009 tls=0.041 ttfb=0.058 total=0.059
```

Reading the curl timings is a diagnostic in itself: a large `time_namelookup` implicates the `.2` resolver, a large `time_connect` implicates the network path or a SYN being dropped, a large `time_appconnect` implicates TLS/certificate handling, and a large gap between `appconnect` and `starttransfer` is the application.

MTU verification — the failure that looks like "large requests hang":

```
$ ping -M do -s 8972 10.42.131.14 -c 2
PING 10.42.131.14 (10.42.131.14) 8972(9000) bytes of data.
8980 bytes from 10.42.131.14: icmp_seq=1 ttl=255 time=0.412 ms
8980 bytes from 10.42.131.14: icmp_seq=2 ttl=255 time=0.389 ms

$ ping -M do -s 1472 -c 2 example.com
PING example.com (93.184.216.34) 1472(1500) bytes of data.
1480 bytes from 93.184.216.34: icmp_seq=1 ttl=52 time=11.7 ms

$ ping -M do -s 8972 -c 2 203.0.113.40   # over Site-to-Site VPN
PING 203.0.113.40 (203.0.113.40) 8972(9000) bytes of data.
ping: local error: message too long, mtu=1500
```

| Path | MTU |
|---|---|
| Within a VPC, same AZ or across AZs | **9001** (jumbo frames) |
| Through an internet gateway to the internet | **1500** |
| Over a Site-to-Site VPN | **1500** minus IPsec overhead (≈1436 usable; clamp MSS to 1379) |
| Direct Connect private / transit VIF | 9001 / 8500 |
| Through a VPC peering connection (same Region) | 9001 |
| Inter-Region VPC peering | 1500 |

When ICMP "fragmentation needed" is blocked by a NACL or an on-prem firewall, Path MTU Discovery breaks silently: the TCP handshake succeeds (small packets), then the first full-size data segment is black-holed. The symptom is "connection established, then hangs" — and the fix is MSS clamping, not a security-group change.

---

## 9. Verification and failure-diagnosis guide

### 9.1 The connectivity ladder — always run it in this order

Each rung is cheaper than the one after it. Do not skip.

**1. Does DNS resolve, and to the address you expect?**
```
$ dig +short api.internal.example.com
10.42.68.204
```
Public answer where a private one belongs → check `enableDnsHostnames`, private hosted zone VPC association, `PrivateDnsEnabled`. `NXDOMAIN` from a private subnet → the instance is not using the `.2` resolver (check DHCP option set).

**2. Is the destination in the local VPC, or does it need a route?**
```
$ aws ec2 describe-route-tables --filters Name=association.subnet-id,Values=subnet-09ab... \
    --query 'RouteTables[0].Routes[].[DestinationCidrBlock,GatewayId,NatGatewayId,State]' --output text
10.42.0.0/16   local   None   active
0.0.0.0/0      None    nat-0918c4e7b2f3d6a51   active
```
No output at all → **the subnet has no explicit association and silently inherited the main route table**. This is a top-three cause of "my new subnet has no internet."
`State: blackhole` → the route's target (NAT gateway, ENI, peering connection) has been deleted. The route survives its target; nothing alerts you.

**3. For public reachability, is there a public IP *and* an IGW route?** Both are required. An instance with a public IP in a subnet without an IGW route is unreachable; an instance in a public subnet without a public IP is equally unreachable. A private IP with a NAT route gives you outbound only.

**4. Security group, egress side (source).** Default SGs allow all egress; hardened ones frequently do not.

**5. Security group, ingress side (destination).** Verify with the SG ID, not by reading names.

**6. NACL, both directions, both subnets.** Four checks: source-subnet egress, destination-subnet ingress, destination-subnet egress (**ephemeral**), source-subnet ingress (**ephemeral**). Remember rules are evaluated lowest-number-first and stop at the first match — a `DENY` at rule 90 makes an `ALLOW` at rule 100 unreachable.

**7. Is the process actually listening, on the right address?**
```
$ ss -lntp
State   Recv-Q  Send-Q  Local Address:Port   Peer Address:Port  Process
LISTEN  0       4096        127.0.0.1:8080         0.0.0.0:*      users:(("app",pid=1841,fd=7))
```
Bound to `127.0.0.1` — no amount of VPC configuration will fix this. Must be `0.0.0.0:8080` or `[::]:8080`.

**8. MTU / PMTUD.** See §8.10. Reach this rung only when the handshake succeeds and bulk transfer stalls.

### 9.2 Symptom → cause lookup table

| Symptom | Most likely cause | Verification command |
|---|---|---|
| `Connection timed out` on a new instance | Security group ingress missing | `aws ec2 describe-security-groups` |
| Handshake OK, transfer hangs on large payloads | PMTUD black hole | `ping -M do -s 1472` |
| Works one way, fails the other | NACL missing ephemeral-port rule | `aws ec2 describe-network-acls` |
| Instance loses internet after a change | Route now `blackhole` (NAT deleted) | `describe-route-tables` → `State` |
| Pods stuck in `ContainerCreating` | Subnet IP exhaustion | `describe-subnets` → `AvailableIpAddressCount` |
| S3 works, DynamoDB does not, from data tier | Gateway endpoint not associated with that route table | `describe-vpc-endpoints` → `RouteTableIds` |
| SDK calls slow, occasional `SERVFAIL` | `.2` resolver 1024 pps limit | Local caching resolver; Route 53 Resolver endpoint |
| ALB targets `unhealthy`, reason `Target.Timeout` | Target SG does not allow the ALB SG | `describe-target-health` |
| ALB `503 Service Unavailable` | Zero healthy targets in the group | `describe-target-health` |
| ALB `502 Bad Gateway` | Target closed the connection / bad response / TLS mismatch | Target application logs + ALB access logs |
| ALB `504 Gateway Timeout` | Target slower than the idle timeout | ALB `TargetResponseTime` metric |
| Intermittent cross-AZ latency after a NAT change | Private subnet routed to a NAT in another AZ | `describe-route-tables` per AZ |
| VPN drops every ~8 hours | IKE rekey mismatch / no DPD | `describe-vpn-connections` → `VgwTelemetry` |
| Peered VPC unreachable beyond one hop | Peering is non-transitive | Use Transit Gateway |
| CloudFront serves stale content | Cache TTL / no invalidation | `aws cloudfront create-invalidation` |
| CloudFront `403` from an S3 origin | OAC misconfigured or bucket policy missing | Bucket policy + OAC signing behaviour |

### 9.3 Continuous verification, not point-in-time checks

| Tool | Question answered | Cost |
|---|---|---|
| **VPC Reachability Analyzer** | *Can* A reach B, per configuration? | Per analysis (cents) |
| **Network Access Analyzer** | Does *any* unintended path to the internet exist? | Per analysis |
| **VPC Flow Logs** | What traffic actually happened, accepted and rejected? | Ingestion + storage |
| **CloudWatch Internet Monitor** | Is degradation ours, or the client's ISP? | Per monitored city-network |
| **CloudWatch Network Monitor** | Is the hybrid (DX/VPN) path degrading? | Per probe |
| **AWS Config** rules | Is a security group open to `0.0.0.0/0` on port 22? | Per evaluation |
| **Route 53 health checks** | Is the endpoint healthy from multiple global vantage points? | Per health check/month |

Baseline recommendation for any production VPC: flow logs on with the extended format, a Network Access Analyzer scope for unintended internet paths evaluated on a schedule, Config rules for open security groups, and CloudWatch alarms on `AvailableIpAddressCount`, NAT `ErrorPortAllocation`, and ALB `HealthyHostCount`.

---

## 10. Cost model — the network line items that actually appear on the bill

*Approximate `us-east-1` list prices, for order-of-magnitude reasoning only. Always confirm against the live pricing pages.*

| Item | Approximate charge | Notes |
|---|---|---|
| Data transfer **in** from internet | **$0.00** | Ingress is free |
| Data transfer **out** to internet | ~$0.09/GB (tiered, 100 GB/mo free) | The dominant line item at scale |
| Data transfer **out via CloudFront** | ~$0.085/GB | Cheaper than EC2 DTO; **origin→CloudFront is free** |
| Cross-AZ, same Region | ~$0.01/GB **each direction** | Charged on both sides |
| Cross-Region | $0.02–$0.15/GB | Region-pair dependent |
| Same-AZ, private IPv4 | **$0.00** | Use private IPs; public IPs re-route via the IGW and get charged |
| **Public IPv4 address** | **~$0.005/hr each** (~$3.65/mo) | Since 2024-02-01 charged **whether attached or not** |
| NAT gateway | ~$0.045/hr + ~$0.045/GB | Both charges apply; endpoints remove the second |
| Gateway VPC endpoint | **$0.00** | S3 and DynamoDB |
| Interface VPC endpoint | ~$0.01/hr/AZ + ~$0.01/GB | 2 AZs ≈ $14.60/mo per endpoint |
| Transit Gateway | ~$0.05/attachment-hr + ~$0.02/GB | Attachment count drives base cost |
| VPC peering (intra-AZ) | **$0.00** | Cross-AZ billed at standard rates |
| Site-to-Site VPN | ~$0.05/hr per connection + DTO | Per connection, not per tunnel |
| Direct Connect | Port-hours + reduced DTO (~$0.02/GB) | Breaks even against internet DTO at sustained volume |
| ALB / NLB | Hourly + LCU/NLCU-hours | LCU = max of new conns, active conns, bandwidth, rule evals |
| Route 53 hosted zone | ~$0.50/zone/mo | Queries ~$0.40/million; **alias to AWS targets is free** |
| Global Accelerator | ~$0.025/hr per accelerator + data transfer premium | Fixed hourly regardless of traffic |

**The three highest-leverage cost actions**, in order: (1) put S3/DynamoDB traffic on free gateway endpoints; (2) release unattached Elastic IPs — they now cost money while idle; (3) keep chatty service-to-service traffic AZ-local, since cross-AZ is billed in both directions and quietly doubles.

---

## 11. Exam-discrimination table

CLF-C02 tests recognition under scenario framing. These are the pairs that separate a pass from a miss.

| Scenario keyword | Correct service | Common wrong answer |
|---|---|---|
| "Isolated virtual network, my own IP range" | **Amazon VPC** | Direct Connect |
| "Dedicated private physical connection to on-prem" | **AWS Direct Connect** | Site-to-Site VPN |
| "Encrypted connection to on-prem, quick to set up, over the internet" | **AWS Site-to-Site VPN** | Direct Connect |
| "Individual remote employees connect securely to the VPC" | **AWS Client VPN** | Site-to-Site VPN |
| "Connect hundreds of VPCs and on-prem through one hub" | **AWS Transit Gateway** | VPC peering |
| "Two VPCs, private traffic, simple" | **VPC peering** | Transit Gateway |
| "Reach an AWS service privately, no internet gateway" | **VPC endpoint / AWS PrivateLink** | NAT gateway |
| "Free private access to S3 from a private subnet" | **Gateway endpoint** | Interface endpoint |
| "Expose my own service to another VPC/account privately" | **AWS PrivateLink** | VPC peering |
| "DNS, domain registration, health-check failover" | **Amazon Route 53** | CloudFront |
| "Cache static and dynamic content close to users" | **Amazon CloudFront** | Global Accelerator |
| "Static IP addresses, UDP/TCP, fast regional failover" | **AWS Global Accelerator** | CloudFront |
| "Route HTTP requests by URL path to microservices" | **Application Load Balancer** | Network Load Balancer |
| "Millions of TCP connections, static IP, ultra-low latency" | **Network Load Balancer** | ALB |
| "Insert third-party firewall appliances transparently" | **Gateway Load Balancer** | Network Firewall |
| "Block SQL injection and cross-site scripting" | **AWS WAF** | Security groups |
| "DDoS protection, automatic and free" | **AWS Shield Standard** | Shield Advanced |
| "Managed IDS/IPS filtering at the VPC level" | **AWS Network Firewall** | WAF |
| "Record accepted and rejected IP traffic metadata" | **VPC Flow Logs** | CloudTrail |
| "Instance-level firewall, stateful" | **Security group** | Network ACL |
| "Subnet-level firewall, allows explicit DENY" | **Network ACL** | Security group |
| "Move 100 TB where the network is impractical" | **AWS Snowball Edge** | Direct Connect |
| "Physically bring AWS infrastructure into my data centre" | **AWS Outposts** | Local Zones |
| "Single-digit-millisecond latency to a specific metro" | **AWS Local Zones** | Edge locations |
| "5G edge compute inside a carrier network" | **AWS Wavelength** | Local Zones |

---

## 12. Referencias

**Official exam material**
- AWS Certified Cloud Practitioner (CLF-C02) Exam Guide — https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf
- AWS Certified Cloud Practitioner certification page — https://aws.amazon.com/certification/certified-cloud-practitioner/

**Amazon VPC**
- Amazon VPC User Guide — https://docs.aws.amazon.com/vpc/latest/userguide/what-is-amazon-vpc.html
- VPC CIDR blocks and subnet sizing — https://docs.aws.amazon.com/vpc/latest/userguide/vpc-cidr-blocks.html
- Subnets and reserved IP addresses — https://docs.aws.amazon.com/vpc/latest/userguide/subnet-sizing.html
- Route tables — https://docs.aws.amazon.com/vpc/latest/userguide/VPC_Route_Tables.html
- Internet gateways — https://docs.aws.amazon.com/vpc/latest/userguide/VPC_Internet_Gateway.html
- NAT gateways — https://docs.aws.amazon.com/vpc/latest/userguide/vpc-nat-gateway.html
- Egress-only internet gateways — https://docs.aws.amazon.com/vpc/latest/userguide/egress-only-internet-gateway.html
- Security groups — https://docs.aws.amazon.com/vpc/latest/userguide/vpc-security-groups.html
- Network ACLs (including ephemeral ports) — https://docs.aws.amazon.com/vpc/latest/userguide/vpc-network-acls.html
- VPC Flow Logs and record fields — https://docs.aws.amazon.com/vpc/latest/userguide/flow-logs-records-examples.html
- Network MTU for EC2 instances — https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/network_mtu.html
- Amazon VPC quotas — https://docs.aws.amazon.com/vpc/latest/userguide/amazon-vpc-limits.html

**Endpoints, peering and hybrid**
- AWS PrivateLink and VPC endpoints — https://docs.aws.amazon.com/vpc/latest/privatelink/what-is-privatelink.html
- Gateway endpoints — https://docs.aws.amazon.com/vpc/latest/privatelink/gateway-endpoints.html
- VPC peering — https://docs.aws.amazon.com/vpc/latest/peering/what-is-vpc-peering.html
- AWS Transit Gateway — https://docs.aws.amazon.com/vpc/latest/tgw/what-is-transit-gateway.html
- AWS Site-to-Site VPN — https://docs.aws.amazon.com/vpn/latest/s2svpn/VPC_VPN.html
- AWS Client VPN — https://docs.aws.amazon.com/vpn/latest/clientvpn-admin/what-is.html
- AWS Direct Connect — https://docs.aws.amazon.com/directconnect/latest/UserGuide/Welcome.html
- Direct Connect resiliency recommendations — https://docs.aws.amazon.com/directconnect/latest/UserGuide/high_resiliency_selection.html
- AWS Cloud WAN — https://docs.aws.amazon.com/network-manager/latest/cloudwan/what-is-cloudwan.html

**Load balancing**
- Elastic Load Balancing features comparison — https://aws.amazon.com/elasticloadbalancing/features/
- Application Load Balancer — https://docs.aws.amazon.com/elasticloadbalancing/latest/application/introduction.html
- Network Load Balancer — https://docs.aws.amazon.com/elasticloadbalancing/latest/network/introduction.html
- Gateway Load Balancer — https://docs.aws.amazon.com/elasticloadbalancing/latest/gateway/introduction.html
- ALB target health reasons — https://docs.aws.amazon.com/elasticloadbalancing/latest/application/target-group-health-checks.html

**DNS and edge**
- Amazon Route 53 Developer Guide — https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/Welcome.html
- Route 53 routing policies — https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/routing-policy.html
- Choosing between alias and non-alias records — https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/resource-record-sets-choosing-alias-non-alias.html
- Route 53 Resolver for hybrid DNS — https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/resolver.html
- Amazon CloudFront Developer Guide — https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/Introduction.html
- Origin Access Control for S3 origins — https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/private-content-restricting-access-to-s3.html
- CloudFront Functions vs. Lambda@Edge — https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/edge-functions-choosing.html
- AWS Global Accelerator Developer Guide — https://docs.aws.amazon.com/global-accelerator/latest/dg/what-is-global-accelerator.html

**Network security and observability**
- AWS WAF Developer Guide — https://docs.aws.amazon.com/waf/latest/developerguide/waf-chapter.html
- AWS Shield Standard and Advanced — https://docs.aws.amazon.com/waf/latest/developerguide/shield-chapter.html
- AWS Network Firewall — https://docs.aws.amazon.com/network-firewall/latest/developerguide/what-is-aws-network-firewall.html
- VPC Reachability Analyzer — https://docs.aws.amazon.com/vpc/latest/reachability/what-is-reachability-analyzer.html
- Network Access Analyzer — https://docs.aws.amazon.com/vpc/latest/network-access-analyzer/what-is-network-access-analyzer.html
- Amazon CloudWatch Internet Monitor — https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/CloudWatch-InternetMonitor.html

**Pricing and cost**
- Amazon VPC pricing (NAT gateway, endpoints, IPv4) — https://aws.amazon.com/vpc/pricing/
- EC2 data transfer pricing — https://aws.amazon.com/ec2/pricing/on-demand/#Data_Transfer
- Public IPv4 address charge — https://aws.amazon.com/blogs/aws/new-aws-public-ipv4-address-charge-public-ip-insights/
- Elastic Load Balancing pricing — https://aws.amazon.com/elasticloadbalancing/pricing/
- Amazon Route 53 pricing — https://aws.amazon.com/route53/pricing/
- Amazon CloudFront pricing — https://aws.amazon.com/cloudfront/pricing/
- AWS Direct Connect pricing — https://aws.amazon.com/directconnect/pricing/

**Reference architectures**
- AWS Well-Architected Framework — https://docs.aws.amazon.com/wellarchitected/latest/framework/welcome.html
- AWS Architecture Center — networking — https://aws.amazon.com/architecture/networking-content-delivery/
- AWS Whitepaper: Building a Scalable and Secure Multi-VPC AWS Network Infrastructure — https://docs.aws.amazon.com/whitepapers/latest/building-scalable-secure-multi-vpc-network-infrastructure/welcome.html
- CloudFormation `AWS::EC2::VPC` resource reference — https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-resource-ec2-vpc.html
- CloudFormation `Fn::Cidr` intrinsic function — https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/intrinsic-function-reference-cidr.html