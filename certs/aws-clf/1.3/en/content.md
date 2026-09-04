# 1.3 — Understand the benefits of and strategies for migration to the AWS Cloud

**Certification:** AWS Certified Cloud Practitioner (CLF-C02, v1.0)
**Domain 1 — Cloud Concepts · Task Statement 1.3 · Exam weight: 6.0**

---

## 1. The production problem: a migration is a distributed cutover, not a copy

The naive mental model of migration is `rsync` plus a DNS change. The model that survives contact with production is this:

> A migration is a **sequence of coordinated cutovers over a dependency graph you do not fully know**, executed under a **finite change window**, against **data that keeps changing while you copy it**, with a **rollback path that decays to zero the moment the target starts accepting writes**.

Every hard decision in this task statement falls out of four physical constraints.

### 1.1 Data gravity — the copy is not instantaneous

Replication competes with the application for the same egress link. The convergence condition for any continuous-replication tool (MGN, DMS CDC, DataSync scheduled runs, Storage Gateway upload buffer) is:

```
sustained_replication_bandwidth  >  daily_change_rate / seconds_per_day
```

Concretely, a 40 TB estate with a 500 GB/day change rate needs:

```
(500 × 10^9 bytes × 8 bits) / 86400 s = 46.3 Mbps  ← steady-state floor
```

...*before* the initial full sync, *before* protocol overhead, and *before* the application's own traffic. Provision ≈2× the floor or replication enters the state AWS names literally: `NOT_CONVERGING`. The initial sync of the same 40 TB over a 1 Gbps link at 80% goodput is 3.7 days of continuous transfer — which is why the "should I ship physical media" question is arithmetic, not preference (§6.4).

### 1.2 The dependency graph is undocumented

The CMDB is wrong. It is always wrong. The 12-year-old batch job that resolves a hardcoded IP, the NFS mount nobody owns, the licence server pinned to a MAC address — these are discovered by **observing traffic**, not by reading a spreadsheet. This is the entire reason AWS Application Discovery Service exists and why its output is a *network connection graph* (§4.3), not an inventory.

### 1.3 The cutover window is a hard SLO boundary

You do not get to "try again next week." The window is bounded by the business, and inside it you must: quiesce writes, drain in-flight transactions, verify the last delta landed, flip resolution, validate, and decide go/no-go. Every strategy in §3 is fundamentally a bet about **how much of that window you spend** and **how much you can undo afterwards**.

### 1.4 Rollback has an expiry

Once the target database accepts a single write that the source has not seen, "roll back to on-prem" means *losing that write* unless you built reverse replication. Serious migrations configure **bidirectional CDC** (or at least a reverse DMS task) *before* cutover, precisely so the rollback decision stays available for 24–72 h. This is the single most-skipped step in real programmes.

---

## 2. AWS Cloud Adoption Framework (CAF) — the operating model around the technology

CAF is what the exam expects you to name when the question is "how does an organisation *prepare*", as opposed to "how does an application *move*". It is deliberately not a technology framework.

### 2.1 The six perspectives

| Perspective | Owns | Representative capabilities | SRE/Platform reading |
|---|---|---|---|
| **Business** | Value realisation | Strategy management, portfolio management, product management, business insights | The business case; where the money and the risk actually are |
| **People** | Culture & skills | Culture evolution, transformational leadership, workforce transformation, training | Who runs the platform on day 2; on-call model change |
| **Governance** | Risk & control | Programme/benefits management, risk management, cloud financial management, data curation | FinOps, tagging strategy, chargeback, guardrails |
| **Platform** | Technology foundation | Platform architecture, data architecture, CI/CD, modern application development | Landing zone, network, identity, golden paths |
| **Security** | Confidentiality/integrity/availability | IAM, threat detection, vulnerability management, incident response, application security | Guardrails, detective controls, break-glass |
| **Operations** | Service delivery | Observability, event/incident/problem management, availability & continuity, performance | SLOs, alerting, runbooks, error budgets |

Mnemonic: **B-P-G-P-S-O** → *"Business People Govern Platforms Securely, Operationally."*

### 2.2 The four transformation domains

**Technology** (migrate & modernise) · **Process** (digitise & automate) · **Organization** (reorganise teams around products) · **Product** (new revenue lines).

The commonly-missed exam point: CAF explicitly says technology alone does not deliver value. A perfect rehost with the same change-advisory-board process yields cloud costs *plus* the old lead time.

### 2.3 The four phases

| Phase | Question answered | Concrete artefact |
|---|---|---|
| **Envision** | Where does cloud create business value? | Prioritised transformation opportunities mapped to perspectives |
| **Align** | What gaps and dependencies block it? | Capability gap analysis, stakeholder alignment, CAF action plan |
| **Launch** | Does it work in production, small? | Pilots in production — not proofs of concept in a lab |
| **Scale** | Can we repeat it at portfolio scale? | Expanded pilots, sustained value, migration factory |

### 2.4 The three-phase migration process (the technology-domain sub-model)

| Phase | Goal | Tooling | Exit criteria |
|---|---|---|---|
| **Assess** | Business case, readiness | Migration Evaluator, Migration Readiness Assessment (MRA), Cloud Value Framework | Signed TCO case, target operating model agreed |
| **Mobilize** | Close gaps, build the foundation | Landing zone / Control Tower, Application Discovery Service, Migration Hub, skills uplift | Landing zone live, dependency graph built, wave plan published, pilot cut over |
| **Migrate & Modernize** | Execute at scale | MGN, DMS+SCT, DataSync, Snow Family, Refactor Spaces | Waves cut over, source decommissioned, modernisation backlog opened |

> **Exam trap:** the pilot belongs to *Mobilize*, not *Migrate*. Mobilize is where the migration factory itself is built.

---

## 3. The 7 Rs — migration strategies with real trade-offs

### 3.1 Definitions

| R | What actually happens | Binary that decides it |
|---|---|---|
| **Retire** | Decommission. Turn it off. | Nobody has authenticated in 90 days |
| **Retain** | Leave it where it is (for now) | Regulatory pin, hardware dongle, imminent EOL, unresolvable dependency |
| **Rehost** | Lift-and-shift: same OS, same binaries, new hypervisor (EC2) | Source is a VM/physical server with block storage |
| **Relocate** | Move the hypervisor, not the guest (VMware-based estates → VMware on AWS) | vSphere estate, vMotion-class tooling available |
| **Repurchase** | Drop the app, buy SaaS | A commodity function exists as SaaS (CRM, email, ITSM) |
| **Replatform** | Lift-and-*reshape*: keep the code, swap a managed component | Self-managed DB/queue/LB with a managed equivalent |
| **Refactor / Re-architect** | Rewrite for cloud-native architecture | The current architecture is the constraint on the business |

### 3.2 Trade-off matrix

| Strategy | Migration effort | Cutover risk | Time to value | Ongoing TCO | Cloud-native benefit | Rollback ease | Typical unit cost driver |
|---|---|---|---|---|---|---|---|
| Retire | Very low | Very low | Immediate | **Negative (savings)** | n/a | n/a | Decommission labour only |
| Retain | None | None | None | Unchanged | None | n/a | Continued DC cost |
| Relocate | Low | Low | Days–weeks | Moderate | Very low | High (vMotion back) | Host-based licensing |
| Rehost | Low | Low–medium | Weeks | Moderate (EC2 + EBS, same waste) | Low | High (source kept warm) | Right-sizing debt |
| Repurchase | Medium (data + integration) | Medium | Weeks–months | Predictable subscription | High (someone else's problem) | **Low** (data migrated out of your model) | Per-seat licence |
| Replatform | Medium | Medium | Weeks–months | **Good** (managed ops absorbed) | Medium–high | Medium (needs reverse CDC) | Managed-service instance sizing |
| Refactor | **Very high** | High | Months–quarters | Best long-run, worst short-run | Highest | **Very low** | Engineering time |

### 3.3 The economics of *not* refactoring first

The failure mode of ambitious programmes is refactoring during migration. Two independent risks are then coupled: "did the move work?" and "did the rewrite work?" A failed cutover cannot be attributed. AWS's own prescriptive guidance is blunt about the sequencing:

**Rehost/Replatform to get out of the datacenter → stabilise → refactor with the datacenter deadline off the critical path.**

The counter-argument that survives: refactor *first* when the application cannot run on EC2 at all (32-bit-only, exotic hardware, unsupported OS), or when the workload is so bursty that lift-and-shift costs more than on-prem (rehosting a peak-provisioned estate 1:1 reproduces the peak-provisioning waste on a metered bill).

### 3.4 Decision tree

```
                          ┌─ Still used?  ── no ──▶ RETIRE
                          │
                          ├─ Must stay (regulatory / hardware / EOL soon)? ── yes ──▶ RETAIN
                          │
   Application ───────────┼─ Commodity function with a SaaS equivalent? ── yes ──▶ REPURCHASE
                          │
                          ├─ Whole vSphere estate, deadline-driven, no time? ── yes ──▶ RELOCATE
                          │
                          ├─ Architecture itself blocks the business
                          │  AND budget/time exist?                  ── yes ──▶ REFACTOR
                          │
                          ├─ Self-managed DB / queue / LB / web tier
                          │  with a managed equivalent?              ── yes ──▶ REPLATFORM
                          │
                          └─ Otherwise                                       ──▶ REHOST
```

### 3.5 Replatform: the highest-yield move per unit of risk

The canonical replatform set, and what each buys:

| From | To | Operational burden removed | Residual work |
|---|---|---|---|
| Self-managed MySQL/PostgreSQL on EC2 | Amazon RDS / Aurora | Patching, backups, failover, minor-version upgrades | Connection string, parameter-group parity, no OS access |
| Apache/NGINX reverse proxy fleet | ALB / NLB | LB patching, HA of the LB tier | Health-check semantics, sticky sessions |
| Self-managed RabbitMQ / ActiveMQ | Amazon MQ | Broker ops, clustering | Protocol version parity |
| Cron on a pet server | EventBridge Scheduler + Lambda/ECS | The pet server | Idempotency, timeout limits |
| NFS filer | Amazon EFS / FSx | Filer hardware, capacity planning | POSIX semantics, latency profile |
| Self-managed Kubernetes | Amazon EKS | Control-plane ops, etcd | CNI/CSI re-plumbing, IRSA |

---

## 4. Assess & Mobilize: building the wave plan from evidence

### 4.1 Set the Migration Hub home region (do this first — it is one-way per account)

```console
$ aws migrationhub-config create-home-region-control \
    --home-region eu-west-1 \
    --target Type=ACCOUNT,Id=123456789012
{
    "HomeRegionControl": {
        "ControlId": "hrc-0a4f27c9b1e6d3852",
        "HomeRegion": "eu-west-1",
        "Target": {
            "Type": "ACCOUNT",
            "Id": "123456789012"
        },
        "RequestedTime": "2026-09-03T09:14:07.412000+00:00"
    }
}

$ aws migrationhub-config get-home-region
{
    "HomeRegion": "eu-west-1"
}
```

> The home region is where Migration Hub stores discovery and migration-tracking data. Migrations themselves can target any region; the *metadata* is pinned. Choosing it wrongly means a support case, not a CLI flag.

### 4.2 Discovery: agentless vs agent-based

| | **Agentless Collector** (OVA in vCenter) | **Discovery Agent** (installed per host) |
|---|---|---|
| Deployment | One OVA per vCenter | Package on every Linux/Windows server |
| Sees | VM inventory, CPU/RAM/disk utilisation, VM-level network throughput | Per-process CPU/RAM/disk/network, **TCP connections with ports and PIDs**, installed packages |
| Builds a dependency graph? | **No** (utilisation only) | **Yes** — this is the point |
| Also collects | Database inventory (DMS Fleet Advisor module) | — |
| Cost of deployment | Very low | High (change control × N hosts) |
| Guest OS access needed | No | Yes |
| Use when | Sizing/TCO for a vSphere estate | You need wave planning and blast-radius analysis |

**Practical pattern:** agentless everywhere for the business case; agents on the ~15% of hosts that are integration hubs, shared services, and anything you cannot explain.

```console
$ aws discovery describe-agents --max-results 5 \
    --query 'agentsInfo[].[agentId,hostName,agentType,health,version]' --output text
o-0f1c2d3e4a5b6c7d8   ora-prd-01        AWS_LINUX_AGENT   HEALTHY     2.3.1214.0
o-0a9b8c7d6e5f4a3b2   app-prd-04        AWS_LINUX_AGENT   HEALTHY     2.3.1214.0
o-0c3d4e5f6a7b8c9d0   app-prd-05        AWS_LINUX_AGENT   HEALTHY     2.3.1214.0
o-0e5f6a7b8c9d0e1f2   win-batch-02      AWS_WINDOWS_AGENT  UNHEALTHY  2.3.1214.0
o-0b2c3d4e5f6a7b8c9   nfs-filer-01      AWS_LINUX_AGENT   SHUTDOWN    2.3.1214.0

$ aws discovery start-continuous-export
{
    "exportId": "export-0d8e7f6a5b4c3d2e1",
    "s3Bucket": "aws-application-discovery-service-a1b2c3d4",
    "schemaStorageConfig": {
        "databaseName": "application_discovery_service_database"
    },
    "startTime": "2026-09-03T09:31:44.008000+00:00",
    "dataSource": "AGENT"
}
```

### 4.3 Turning connection data into waves (Athena over the discovery export)

Continuous export lands agent data in S3 and registers Glue tables. The dependency graph is one query away:

```sql
-- Cross-server TCP dependency edges observed in the last 14 days,
-- excluding ephemeral client ports and loopback.
WITH edges AS (
    SELECT
        src.host_name              AS source_host,
        dst.host_name              AS destination_host,
        o.destination_port         AS port,
        COUNT(*)                   AS observations
    FROM   outbound_connection_agent o
    JOIN   os_info_agent            src ON src.agent_id = o.agent_id
    JOIN   network_interface_agent  ni  ON ni.ip_address = o.destination_ip
    JOIN   os_info_agent            dst ON dst.agent_id = ni.agent_id
    WHERE  o.destination_ip NOT LIKE '127.%'
      AND  o.destination_port < 32768
      AND  from_iso8601_timestamp(o.agent_assigned_process_id) IS NOT NULL
    GROUP  BY 1, 2, 3
)
SELECT   source_host, destination_host, port, observations
FROM     edges
WHERE    source_host <> destination_host
ORDER BY observations DESC
LIMIT    200;
```

**Wave-planning rules that come out of this graph:**

1. A **wave is a connected component** of the graph, not a team's list of servers. If A talks to B, A and B move together or you accept cross-datacenter latency for the interval between them.
2. **Shared services move first** (DNS, LDAP/AD, NTP, licence servers, monitoring, artifact repos) — or every later wave has a hybrid dependency.
3. **Cross-wave edges become explicit risks** with a named mitigation: hybrid link, temporary reverse proxy, or "accept +8 ms RTT for 6 days."
4. **Wave size is bounded by rollback capacity**, not by ambition. If your team can validate 12 applications in a 6-hour window, the wave is 12 applications.

### 4.4 Migration Evaluator vs Migration Hub — the distinction the exam tests

| Service | Answers | Output | Cost |
|---|---|---|---|
| **Migration Evaluator** | *Should we? What will it cost?* | Directional/detailed business case, right-sized EC2/RDS projections, on-prem vs AWS TCO comparison, BYOL vs licence-included | Free (AWS-run engagement) |
| **AWS Application Discovery Service** | *What do we have and how is it wired?* | Server inventory, utilisation, network dependency data | Free (S3/Athena storage billed) |
| **AWS Migration Hub** | *Where is everything in the process?* | Single pane of migration status across MGN, DMS and partner tools; application grouping; Strategy Recommendations | Free (underlying services billed) |

---

## 5. Complete infrastructure — MGN staging environment (CloudFormation)

This is the foundation every rehost wave lands on. It is intentionally complete: VPC, staging subnets, the data-plane security groups, VPC endpoints so control-plane traffic avoids the internet, the replication configuration template new source servers inherit, and the launch template that governs the target instances.

```yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: >-
  Rehost staging environment for AWS Application Migration Service (MGN).
  Creates the staging-area VPC, the replication-server subnets, the data-plane
  security groups (TCP 1500 from source servers), VPC endpoints that keep the
  MGN/EC2/S3 control plane off the public internet, and the replication +
  launch configuration templates inherited by every newly registered
  source server. Deploy ONCE per target region, BEFORE installing any agent.

Parameters:

  ProjectTag:
    Type: String
    Default: dc-exit-2026
    Description: Value applied as the "migration-wave-project" tag on every resource.

  VpcCidr:
    Type: String
    Default: 10.60.0.0/16
    AllowedPattern: '^(\d{1,3}\.){3}\d{1,3}/\d{1,2}$'
    Description: CIDR of the staging VPC. MUST NOT overlap the on-premises estate.

  StagingSubnetCidrA:
    Type: String
    Default: 10.60.0.0/22

  StagingSubnetCidrB:
    Type: String
    Default: 10.60.4.0/22

  EgressSubnetCidrA:
    Type: String
    Default: 10.60.240.0/24

  OnPremisesCidr:
    Type: String
    Default: 172.20.0.0/14
    Description: >-
      Aggregate CIDR of the source servers. Only these addresses may open the
      TCP 1500 replication data plane. Reached over Direct Connect or VPN.

  ReplicationServerInstanceType:
    Type: String
    Default: t3.small
    AllowedValues: [t3.small, t3.medium, t3.large, m5.large, m5.xlarge]
    Description: >-
      One replication server serves up to 15 source-server disks. t3.small is
      the AWS default and is adequate below ~120 Mbps aggregate ingest.

  BandwidthThrottlingMbps:
    Type: Number
    Default: 0
    MinValue: 0
    MaxValue: 10000
    Description: >-
      Per-source-server ceiling in Mbps. 0 disables throttling. Set this
      deliberately: uncapped initial sync will saturate the Direct Connect VIF
      and page the network team.

  DefaultLargeStagingDiskType:
    Type: String
    Default: GP3
    AllowedValues: [GP2, GP3, ST1]
    Description: >-
      Volume type for staging disks larger than 500 GiB. ST1 is cheapest but
      throughput-optimised for sequential I/O; GP3 gives predictable IOPS for
      snapshot creation. Use ST1 only for cold, very large volumes.

  StagingVolumeKmsKeyArn:
    Type: String
    Default: ''
    Description: >-
      Optional customer-managed KMS key ARN for staging EBS volumes. Empty
      string uses the EBS default key.

Conditions:

  UseCustomKmsKey: !Not [!Equals [!Ref StagingVolumeKmsKeyArn, '']]
  ThrottleEnabled:  !Not [!Equals [!Ref BandwidthThrottlingMbps, 0]]

Resources:

  # ------------------------------------------------------------------ network

  StagingVpc:
    Type: AWS::EC2::VPC
    Properties:
      CidrBlock: !Ref VpcCidr
      EnableDnsSupport: true
      EnableDnsHostnames: true
      Tags:
        - Key: Name
          Value: !Sub '${ProjectTag}-mgn-staging-vpc'
        - Key: migration-wave-project
          Value: !Ref ProjectTag

  InternetGateway:
    Type: AWS::EC2::InternetGateway
    Properties:
      Tags:
        - Key: Name
          Value: !Sub '${ProjectTag}-mgn-igw'

  IgwAttachment:
    Type: AWS::EC2::VPCGatewayAttachment
    Properties:
      VpcId: !Ref StagingVpc
      InternetGatewayId: !Ref InternetGateway

  EgressSubnetA:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref StagingVpc
      CidrBlock: !Ref EgressSubnetCidrA
      AvailabilityZone: !Select [0, !GetAZs '']
      MapPublicIpOnLaunch: false
      Tags:
        - Key: Name
          Value: !Sub '${ProjectTag}-egress-a'

  StagingSubnetA:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref StagingVpc
      CidrBlock: !Ref StagingSubnetCidrA
      AvailabilityZone: !Select [0, !GetAZs '']
      MapPublicIpOnLaunch: false
      Tags:
        - Key: Name
          Value: !Sub '${ProjectTag}-mgn-staging-a'
        - Key: migration-wave-project
          Value: !Ref ProjectTag

  StagingSubnetB:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref StagingVpc
      CidrBlock: !Ref StagingSubnetCidrB
      AvailabilityZone: !Select [1, !GetAZs '']
      MapPublicIpOnLaunch: false
      Tags:
        - Key: Name
          Value: !Sub '${ProjectTag}-mgn-staging-b'

  NatEip:
    Type: AWS::EC2::EIP
    DependsOn: IgwAttachment
    Properties:
      Domain: vpc
      Tags:
        - Key: Name
          Value: !Sub '${ProjectTag}-mgn-nat-eip'

  NatGateway:
    Type: AWS::EC2::NatGateway
    Properties:
      AllocationId: !GetAtt NatEip.AllocationId
      SubnetId: !Ref EgressSubnetA
      Tags:
        - Key: Name
          Value: !Sub '${ProjectTag}-mgn-nat'

  PublicRouteTable:
    Type: AWS::EC2::RouteTable
    Properties:
      VpcId: !Ref StagingVpc
      Tags:
        - Key: Name
          Value: !Sub '${ProjectTag}-rt-egress'

  DefaultPublicRoute:
    Type: AWS::EC2::Route
    DependsOn: IgwAttachment
    Properties:
      RouteTableId: !Ref PublicRouteTable
      DestinationCidrBlock: 0.0.0.0/0
      GatewayId: !Ref InternetGateway

  EgressSubnetARouteAssoc:
    Type: AWS::EC2::SubnetRouteTableAssociation
    Properties:
      SubnetId: !Ref EgressSubnetA
      RouteTableId: !Ref PublicRouteTable

  StagingRouteTable:
    Type: AWS::EC2::RouteTable
    Properties:
      VpcId: !Ref StagingVpc
      Tags:
        - Key: Name
          Value: !Sub '${ProjectTag}-rt-staging'

  StagingDefaultRoute:
    Type: AWS::EC2::Route
    Properties:
      RouteTableId: !Ref StagingRouteTable
      DestinationCidrBlock: 0.0.0.0/0
      NatGatewayId: !Ref NatGateway

  StagingSubnetARouteAssoc:
    Type: AWS::EC2::SubnetRouteTableAssociation
    Properties:
      SubnetId: !Ref StagingSubnetA
      RouteTableId: !Ref StagingRouteTable

  StagingSubnetBRouteAssoc:
    Type: AWS::EC2::SubnetRouteTableAssociation
    Properties:
      SubnetId: !Ref StagingSubnetB
      RouteTableId: !Ref StagingRouteTable

  # ------------------------------------------------------------ VPC endpoints
  # Keeps agent -> service control-plane traffic inside the AWS network when
  # DataPlaneRouting is PRIVATE_IP. The S3 gateway endpoint is mandatory in
  # practice: the replication server downloads its software from S3.

  EndpointSecurityGroup:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: HTTPS from the staging VPC to interface VPC endpoints
      VpcId: !Ref StagingVpc
      SecurityGroupIngress:
        - IpProtocol: tcp
          FromPort: 443
          ToPort: 443
          CidrIp: !Ref VpcCidr
          Description: HTTPS from staging subnets
        - IpProtocol: tcp
          FromPort: 443
          ToPort: 443
          CidrIp: !Ref OnPremisesCidr
          Description: HTTPS from source servers over DX/VPN
      SecurityGroupEgress:
        - IpProtocol: '-1'
          CidrIp: 0.0.0.0/0
          Description: Unrestricted egress
      Tags:
        - Key: Name
          Value: !Sub '${ProjectTag}-vpce-sg'

  S3GatewayEndpoint:
    Type: AWS::EC2::VPCEndpoint
    Properties:
      VpcId: !Ref StagingVpc
      ServiceName: !Sub 'com.amazonaws.${AWS::Region}.s3'
      VpcEndpointType: Gateway
      RouteTableIds:
        - !Ref StagingRouteTable

  MgnInterfaceEndpoint:
    Type: AWS::EC2::VPCEndpoint
    Properties:
      VpcId: !Ref StagingVpc
      ServiceName: !Sub 'com.amazonaws.${AWS::Region}.mgn'
      VpcEndpointType: Interface
      PrivateDnsEnabled: true
      SubnetIds:
        - !Ref StagingSubnetA
        - !Ref StagingSubnetB
      SecurityGroupIds:
        - !Ref EndpointSecurityGroup

  Ec2InterfaceEndpoint:
    Type: AWS::EC2::VPCEndpoint
    Properties:
      VpcId: !Ref StagingVpc
      ServiceName: !Sub 'com.amazonaws.${AWS::Region}.ec2'
      VpcEndpointType: Interface
      PrivateDnsEnabled: true
      SubnetIds:
        - !Ref StagingSubnetA
        - !Ref StagingSubnetB
      SecurityGroupIds:
        - !Ref EndpointSecurityGroup

  # ----------------------------------------------------------- security groups
  # MGN data plane:
  #   source server  --TCP 1500-->  replication server   (block-level replica)
  #   replication srv --TCP 443-->  mgn + s3 endpoints   (control plane)

  ReplicationServerSecurityGroup:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: >-
        MGN replication servers. Ingress TCP 1500 from source servers only.
      VpcId: !Ref StagingVpc
      SecurityGroupIngress:
        - IpProtocol: tcp
          FromPort: 1500
          ToPort: 1500
          CidrIp: !Ref OnPremisesCidr
          Description: AWS Replication Agent block-level data plane
      SecurityGroupEgress:
        - IpProtocol: tcp
          FromPort: 443
          ToPort: 443
          CidrIp: 0.0.0.0/0
          Description: MGN and S3 control plane
        - IpProtocol: tcp
          FromPort: 1500
          ToPort: 1500
          CidrIp: !Ref VpcCidr
          Description: Replication server to replication server
      Tags:
        - Key: Name
          Value: !Sub '${ProjectTag}-mgn-replication-sg'
        - Key: migration-wave-project
          Value: !Ref ProjectTag

  # Self-referencing rule added separately: a security group cannot reference
  # itself inside its own SecurityGroupIngress block.
  ReplicationServerSelfIngress:
    Type: AWS::EC2::SecurityGroupIngress
    Properties:
      GroupId: !Ref ReplicationServerSecurityGroup
      IpProtocol: tcp
      FromPort: 1500
      ToPort: 1500
      SourceSecurityGroupId: !Ref ReplicationServerSecurityGroup
      Description: Replication server mesh

  TestInstanceSecurityGroup:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: >-
        Launched test instances. Deliberately isolated from production:
        no ingress from on-premises, egress restricted to HTTPS.
      VpcId: !Ref StagingVpc
      SecurityGroupIngress:
        - IpProtocol: tcp
          FromPort: 22
          ToPort: 22
          CidrIp: !Ref VpcCidr
          Description: SSH from within the staging VPC only
      SecurityGroupEgress:
        - IpProtocol: tcp
          FromPort: 443
          ToPort: 443
          CidrIp: 0.0.0.0/0
          Description: SSM / package repos
      Tags:
        - Key: Name
          Value: !Sub '${ProjectTag}-mgn-test-sg'

  # ------------------------------------------------------------------ IAM
  # Credentials used by the AWS Replication Agent installer on source servers.
  # Scope: agent registration only. Rotate after each wave; never reuse across
  # accounts. Prefer IAM Roles Anywhere or SSM hybrid activations where the
  # source estate supports it.

  ReplicationAgentInstallUser:
    Type: AWS::IAM::User
    Properties:
      UserName: !Sub '${ProjectTag}-mgn-agent-installer'
      ManagedPolicyArns:
        - arn:aws:iam::aws:policy/AWSApplicationMigrationAgentPolicy
      Tags:
        - Key: migration-wave-project
          Value: !Ref ProjectTag

  LaunchInstanceRole:
    Type: AWS::IAM::Role
    Properties:
      RoleName: !Sub '${ProjectTag}-mgn-launched-instance-role'
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

  LaunchInstanceProfile:
    Type: AWS::IAM::InstanceProfile
    Properties:
      InstanceProfileName: !Sub '${ProjectTag}-mgn-launched-instance-profile'
      Roles:
        - !Ref LaunchInstanceRole

  # ------------------------------------------------- MGN replication template
  # Inherited by EVERY source server registered in this region after the
  # template exists. Changing it does not retroactively change already
  # registered servers - those keep their own replication settings.

  ReplicationConfigurationTemplate:
    Type: AWS::MGN::ReplicationConfigurationTemplate
    Properties:
      AssociateDefaultSecurityGroup: false
      BandwidthThrottling: !Ref BandwidthThrottlingMbps
      CreatePublicIP: false
      DataPlaneRouting: PRIVATE_IP
      DefaultLargeStagingDiskType: !Ref DefaultLargeStagingDiskType
      EbsEncryption: !If [UseCustomKmsKey, CUSTOM, DEFAULT]
      EbsEncryptionKeyArn: !If
        - UseCustomKmsKey
        - !Ref StagingVolumeKmsKeyArn
        - !Ref AWS::NoValue
      ReplicationServerInstanceType: !Ref ReplicationServerInstanceType
      ReplicationServersSecurityGroupsIDs:
        - !Ref ReplicationServerSecurityGroup
      StagingAreaSubnetId: !Ref StagingSubnetA
      StagingAreaTags:
        Name: !Sub '${ProjectTag}-mgn-staging-resource'
        migration-wave-project: !Ref ProjectTag
        cost-center: platform-migration
      UseDedicatedReplicationServer: false
      Tags:
        migration-wave-project: !Ref ProjectTag

  # ------------------------------------------------------ MGN launch template
  # Governs what the TEST and CUTOVER instances look like.

  LaunchConfigurationTemplate:
    Type: AWS::MGN::LaunchConfigurationTemplate
    Properties:
      AssociatePublicIpAddress: false
      BootMode: LEGACY_BIOS
      CopyPrivateIp: false
      CopyTags: true
      EnableMapAutoTagging: true
      MapAutoTaggingMpeID: MPE-1234567890
      LaunchDisposition: STOPPED
      TargetInstanceTypeRightSizingMethod: BASIC
      Licensing:
        OsByol: false
      SmallVolumeMaxSize: 500
      SmallVolumeConf:
        VolumeType: gp3
        Iops: 3000
        Throughput: 125
      LargeVolumeConf:
        VolumeType: gp3
        Iops: 6000
        Throughput: 250
      PostLaunchActions:
        Deployment: TEST_AND_CUTOVER
        S3LogBucket: !Sub 'aws-mgn-postlaunch-logs-${AWS::AccountId}-${AWS::Region}'
        S3OutputKeyPrefix: !Sub '${ProjectTag}/post-launch/'
        SsmDocuments:
          - ActionName: install-cloudwatch-agent
            SsmDocumentName: AWSMigration-InstallCloudWatchAgent
            TimeoutSeconds: 900
            MustSucceedForCutover: false
          - ActionName: validate-disk-space
            SsmDocumentName: AWSMigration-ValidateDiskSpace
            TimeoutSeconds: 300
            MustSucceedForCutover: true
      Tags:
        migration-wave-project: !Ref ProjectTag

Outputs:

  StagingVpcId:
    Description: Staging VPC ID
    Value: !Ref StagingVpc
    Export:
      Name: !Sub '${AWS::StackName}-StagingVpcId'

  StagingSubnetAId:
    Description: Subnet the MGN replication servers launch into
    Value: !Ref StagingSubnetA
    Export:
      Name: !Sub '${AWS::StackName}-StagingSubnetAId'

  ReplicationSecurityGroupId:
    Description: Security group attached to MGN replication servers
    Value: !Ref ReplicationServerSecurityGroup
    Export:
      Name: !Sub '${AWS::StackName}-ReplicationSecurityGroupId'

  AgentInstallUserName:
    Description: >-
      IAM user whose access keys the AWS Replication Agent installer consumes.
      Create the keys out of band; never place them in the template.
    Value: !Ref ReplicationAgentInstallUser

  ReplicationTemplateId:
    Description: MGN replication configuration template ID
    Value: !Ref ReplicationConfigurationTemplate
```

### 5.1 Deploying and installing agents

```console
$ aws cloudformation deploy \
    --template-file mgn-staging.yaml \
    --stack-name dc-exit-2026-mgn-staging \
    --parameter-overrides \
        ProjectTag=dc-exit-2026 \
        OnPremisesCidr=172.20.0.0/14 \
        BandwidthThrottlingMbps=400 \
    --capabilities CAPABILITY_NAMED_IAM \
    --region eu-west-1

Waiting for changeset to be created..
Waiting for stack create/update to complete
Successfully created/updated stack - dc-exit-2026-mgn-staging

$ aws cloudformation describe-stacks \
    --stack-name dc-exit-2026-mgn-staging \
    --query 'Stacks[0].Outputs[].[OutputKey,OutputValue]' --output text
AgentInstallUserName          dc-exit-2026-mgn-agent-installer
ReplicationSecurityGroupId    sg-0f3a91c7d5e42b806
ReplicationTemplateId         mgn-replication-template-0c9d8e7f6a5b4c3d2
StagingSubnetAId              subnet-0a7b6c5d4e3f2a1b0
StagingVpcId                  vpc-093f2a71c8b6d5e40
```

On a source server (Linux):

```console
[root@ora-prd-01 ~]# wget -O ./aws-replication-installer-init \
      https://aws-application-migration-service-eu-west-1.s3.eu-west-1.amazonaws.com/latest/linux/aws-replication-installer-init
[root@ora-prd-01 ~]# chmod +x ./aws-replication-installer-init
[root@ora-prd-01 ~]# ./aws-replication-installer-init \
      --region eu-west-1 \
      --aws-access-key-id AKIAIOSFODNN7EXAMPLE \
      --aws-secret-access-key <redacted> \
      --no-prompt
The installation of the AWS Replication Agent has started.
Identifying volumes for replication.
Identified volume for replication: /dev/sda of size 100 GiB
Identified volume for replication: /dev/sdb of size 2000 GiB
All volumes for replication were successfully identified.
Downloading the AWS Replication Agent onto the source server... Finished.
Installing the AWS Replication Agent onto the source server... Finished.
Syncing the source server with the AWS Application Migration Service Console...
Finished.
The following is the source server ID: s-0b4c8e2f9a1d73650.
You now have 1 active source server out of your 10000 licenses.
Learn more about using the AWS Application Migration Service Console
in the following URL:
https://eu-west-1.console.aws.amazon.com/mgn/home?region=eu-west-1#/sourceServers
```

> **Note the two identified volumes.** MGN replicates *whole block devices*. A 2 TiB `/dev/sdb` that is 4% used still transfers 2 TiB of blocks on initial sync unless the filesystem supports the agent's sparse-region detection. Shrink or exclude fat volumes *before* the wave, not during it.

---

## 6. Data-movement services: choosing the right pipe

### 6.1 Comparison matrix

| Service | Moves | Protocol at source | Continuous? | Ceiling | Best for | Not for |
|---|---|---|---|---|---|---|
| **AWS Application Migration Service (MGN)** | Whole servers (block level) | Agent → TCP 1500 | Yes (CDC at block level) | Link-bound | Rehost of VMs/physical servers | Databases you intend to replatform |
| **AWS DMS** | Database rows | Native DB protocol | Yes (CDC) | Instance + link bound | Homogeneous & heterogeneous DB migration with near-zero downtime | Bulk unstructured files |
| **AWS DataSync** | Files & objects | NFS, SMB, HDFS, S3-compatible object | Scheduled, incremental | ~10 Gbps per task | Repeated file-set sync, on-prem NAS → EFS/FSx/S3 | Live block devices |
| **AWS Transfer Family** | Files pushed *by partners* | SFTP / FTPS / FTP / AS2 | On demand | Per-connection | Replacing a managed-file-transfer estate | Bulk internal migration |
| **AWS Storage Gateway** | Hybrid access, not a one-shot move | NFS/SMB (File GW), iSCSI (Volume GW), iSCSI VTL (Tape GW) | Continuous cache-and-upload | Link + cache bound | Keeping on-prem access while data lives in AWS; tape replacement | Anything where you want the source gone tomorrow |
| **AWS Snow Family** | Bulk offline | Local S3-compatible endpoint / NFS | No | Physical shipment | Petabyte-scale, thin/absent links, disconnected/edge sites | Anything under a few TB with a good link |

### 6.2 Storage Gateway variants

| Variant | On-prem protocol | Backed by | Local cache holds | Canonical use |
|---|---|---|---|---|
| **S3 File Gateway** | NFS v3/v4.1, SMB v2/v3 | S3 objects (1 file = 1 object) | Recently used files | Migrate a NAS while keeping the file interface |
| **FSx File Gateway** | SMB | Amazon FSx for Windows File Server | Recently used files | Branch-office access to a central Windows share |
| **Volume Gateway — cached** | iSCSI | S3, with EBS snapshots | Hot blocks | Primary data in AWS, low-latency local reads |
| **Volume Gateway — stored** | iSCSI | Local disk is primary; async backup to S3 | Full dataset local | Keep all data local, get offsite DR |
| **Tape Gateway (VTL)** | iSCSI VTL | S3 → S3 Glacier Flexible/Deep Archive | Recently written virtual tapes | Retire a physical tape library without changing the backup software |

### 6.3 Snow Family

| Device | Usable capacity (order of magnitude) | Compute | Typical role |
|---|---|---|---|
| **Snowcone / Snowcone SSD** | ~8 TB HDD / ~14 TB SSD | Small (EC2-compatible) | Edge/rugged, space-constrained, can ship or use DataSync |
| **Snowball Edge Storage Optimized** | Tens of TB up to ~210 TB | Yes | Bulk data transfer, the workhorse |
| **Snowball Edge Compute Optimized** | Tens of TB | Larger, optional GPU | Disconnected edge compute + ML inference |
| **Snowmobile** | Exabyte-class shipping container | n/a | Historic: 100 PB-scale datacenter evacuation |

> **Currency warning:** AWS narrowed the Snow line-up during 2024–2025 — Snowmobile is no longer offered and individual device options have changed. The CLF-C02 exam guide still references the family generically, so know the *concepts*. Before making a real design decision, confirm current device availability in the Snow Family FAQ (see References).

### 6.4 The ship-or-stream calculation

Transfer time for a full copy at 80% goodput:

```
days = (TB × 8 × 10^12 bits) / (link_bps × 0.8) / 86400
```

| Dataset | 100 Mbps | 500 Mbps | 1 Gbps | 10 Gbps |
|---|---|---|---|---|
| 10 TB | 11.6 d | 2.3 d | 1.2 d | 2.8 h |
| 50 TB | 57.9 d | 11.6 d | 5.8 d | 13.9 h |
| 100 TB | 115.7 d | 23.1 d | **11.6 d** | 1.2 d |
| 500 TB | 578.7 d | 115.7 d | 57.9 d | **5.8 d** |
| 1 PB | — | 231.5 d | 115.7 d | 11.6 d |

**Rule of thumb, and where it comes from:** if the wire copy exceeds roughly one week, order Snow devices. A Snowball round trip is ~1 week of shipping regardless of size, so it dominates below that threshold and wins above it. Second-order effects that push you to Snow earlier: the link is shared with production, the WAN is billed per GB, or the source site is bandwidth-starved by construction (ship, oil rig, remote plant).

**Second-order effect that pushes you the other way:** Snow gives you a *point-in-time* copy. Everything written during shipping must still be caught up over the wire. Snow is almost always the *seed*, with DataSync or DMS CDC doing the delta.

### 6.5 Snowball job lifecycle

```console
$ aws snowball create-job \
    --job-type IMPORT \
    --snowball-type EDGE_S \
    --shipping-option SECOND_DAY \
    --address-id ADID-0f2e1d3c4b5a69780 \
    --role-arn arn:aws:iam::123456789012:role/SnowballImportRole \
    --kms-key-arn arn:aws:kms:eu-west-1:123456789012:key/8f1c2b3a-4d5e-6f70-8192-a3b4c5d6e7f8 \
    --description 'dc-exit-2026 archive tier seed' \
    --resources '{
        "S3Resources": [
            {
                "BucketArn": "arn:aws:s3:::dc-exit-2026-archive-eu-west-1",
                "KeyRange": {"BeginMarker": "", "EndMarker": ""}
            }
        ]
    }'
{
    "JobId": "JID-0d7c6b5a4e3f21908"
}

$ aws snowball describe-job --job-id JID-0d7c6b5a4e3f21908 \
    --query 'JobMetadata.{state:JobState,type:SnowballType,created:CreationDate,tracking:ShippingDetails.OutboundShipment.TrackingNumber}'
{
    "state": "InTransitToCustomer",
    "type": "EDGE_S",
    "created": "2026-09-03T10:22:51.883000+00:00",
    "tracking": "1Z999AA10123456784"
}
```

On arrival, unlock the device and use the local S3-compatible endpoint:

```console
$ snowballEdge unlock-device \
    --endpoint https://10.14.7.31 \
    --manifest-file JID-0d7c6b5a4e3f21908_manifest.bin \
    --unlock-code a1b2c-3d4e5-f6a7b-8c9d0-e1f2a
Unlock device returned: Device Unlocking

$ snowballEdge describe-device --endpoint https://10.14.7.31 \
    --manifest-file JID-0d7c6b5a4e3f21908_manifest.bin \
    --unlock-code a1b2c-3d4e5-f6a7b-8c9d0-e1f2a
{
  "DeviceId" : "JID-0d7c6b5a4e3f21908",
  "UnlockStatus" : { "State" : "UNLOCKED" },
  "ActiveNetworkInterface" : { "IpAddress" : "10.14.7.31" },
  "PhysicalNetworkInterfaces" : [ {
    "PhysicalNetworkInterfaceId" : "s.ni-8a1b2c3d4e5f60718",
    "PhysicalConnectorType" : "QSFP",
    "IpAddressAssignment" : "STATIC",
    "IpAddress" : "10.14.7.31",
    "Netmask" : "255.255.255.0",
    "DefaultGateway" : "10.14.7.1",
    "MacAddress" : "00:1e:67:aa:bb:cc"
  } ]
}

$ aws s3 cp /srv/archive/2019/ s3://dc-exit-2026-archive-eu-west-1/2019/ \
    --recursive \
    --endpoint http://10.14.7.31:8080 \
    --profile snowballEdge
upload: ../../srv/archive/2019/q1/ledger-000001.parquet to s3://dc-exit-2026-archive-eu-west-1/2019/q1/ledger-000001.parquet
upload: ../../srv/archive/2019/q1/ledger-000002.parquet to s3://dc-exit-2026-archive-eu-west-1/2019/q1/ledger-000002.parquet
...
Completed 41.8 TiB/41.8 TiB (612.4 MiB/s) with 0 file(s) remaining
```

---

## 7. Database migration: DMS + SCT, complete stack

### 7.1 Homogeneous vs heterogeneous

| | Homogeneous (Oracle → Oracle on RDS, MySQL → Aurora MySQL) | Heterogeneous (Oracle → Aurora PostgreSQL, SQL Server → Aurora MySQL) |
|---|---|---|
| Schema conversion | Not needed | **AWS SCT / DMS Schema Conversion** required |
| Application code | Usually unchanged | Stored procedures, embedded SQL, driver, dialect all change |
| Risk | Low | High — this is a refactor in disguise |
| DMS role | Full load + CDC | Full load + CDC, *after* schema conversion |
| Typical elapsed | Weeks | Months |
| Licence saving | Partial | **Full** — the usual business driver |

**Division of labour, precisely:** SCT converts **schema and code objects** (tables, views, procedures, functions, triggers), and produces an assessment report listing what it could not convert and the estimated manual effort. DMS moves **data**. DMS does *not* migrate secondary indexes, sequences, procedures, triggers or foreign keys by itself — it creates a minimal target schema sufficient to land rows. Assuming otherwise is the most common DMS surprise.

### 7.2 Source prerequisites for CDC (the ones that actually bite)

| Source engine | Required configuration | Symptom if missing |
|---|---|---|
| Oracle | `ALTER DATABASE ADD SUPPLEMENTAL LOG DATA;` plus per-table `ALL COLUMNS`; ARCHIVELOG mode; LogMiner or Binary Reader access | Full load succeeds, CDC starts, then updates silently apply to the wrong rows or the task errors on `ORA-01291` |
| MySQL / MariaDB | `binlog_format=ROW`, `binlog_row_image=FULL`, `binlog_checksum=NONE` (older versions), retention ≥ 24 h | CDC fails to start, or applies statement-level changes non-deterministically |
| PostgreSQL | `wal_level=logical`, `max_replication_slots` ≥ tasks+1, `max_wal_senders` ≥ tasks+1, `pglogical` or the native plugin | Task cannot create a replication slot; or a *stale slot pins WAL and fills the source disk* |
| SQL Server | Full recovery model or bulk-logged; CDC or MS-REPLICATION enabled | CDC cannot read the transaction log |
| **All** | **Every replicated table needs a primary key or unique index** | Updates/deletes during CDC become full-table scans or fail outright |

> The PostgreSQL row is a production incident waiting to happen: an abandoned DMS task leaves a replication slot behind, the source stops recycling WAL, and the *source* database — the one still serving customers — runs out of disk. Always `aws dms delete-replication-task` and then verify `pg_replication_slots` is empty.

### 7.3 Complete DMS CloudFormation stack

```yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: >-
  Heterogeneous database migration: Oracle 19c on-premises -> Aurora
  PostgreSQL, using AWS DMS with full-load + CDC and inline data validation.
  Assumes the schema has ALREADY been converted with AWS SCT / DMS Schema
  Conversion and applied to the target - DMS moves rows, not DDL.
  Assumes the account-level roles dms-vpc-role and dms-cloudwatch-logs-role
  exist (created once per account by the DMS console or the CLI).

Parameters:

  ProjectTag:
    Type: String
    Default: dc-exit-2026

  VpcId:
    Type: AWS::EC2::VPC::Id
    Description: VPC hosting the replication instance and the Aurora cluster.

  PrivateSubnetIds:
    Type: List<AWS::EC2::Subnet::Id>
    Description: >-
      At least two subnets in different AZs. Multi-AZ replication instances
      require this; single-AZ still requires a subnet group of two.

  OnPremOracleHost:
    Type: String
    Default: ora-prd-01.corp.internal
    Description: Resolvable over Direct Connect / VPN from the replication instance.

  OnPremOraclePort:
    Type: Number
    Default: 1521

  OnPremOracleServiceName:
    Type: String
    Default: ERPPRD

  OracleSecretArn:
    Type: String
    Description: >-
      Secrets Manager secret holding {"username":"...","password":"..."} for
      the Oracle CDC user. DMS reads it directly - no plaintext in the stack.

  AuroraSecretArn:
    Type: String
    Description: Secrets Manager secret for the Aurora PostgreSQL target user.

  AuroraWriterEndpoint:
    Type: String
    Description: Aurora PostgreSQL cluster WRITER endpoint (not the reader).

  AuroraDatabaseName:
    Type: String
    Default: erpprd

  ReplicationInstanceClass:
    Type: String
    Default: dms.c5.2xlarge
    AllowedValues:
      - dms.t3.medium
      - dms.t3.large
      - dms.c5.large
      - dms.c5.xlarge
      - dms.c5.2xlarge
      - dms.r5.2xlarge
    Description: >-
      c5 for CPU-bound transformation-heavy loads; r5 when CDC changes must be
      cached in memory to avoid spilling to disk (watch CDCChangesDiskTarget).
      t3 only for proofs of concept - burst credits exhaust mid-full-load.

  ReplicationInstanceStorageGiB:
    Type: Number
    Default: 200
    MinValue: 50
    MaxValue: 6144
    Description: >-
      Holds task logs and cached CDC changes that spill from memory. Undersizing
      this stalls CDC when the target cannot keep up with the source.

  MultiAz:
    Type: String
    Default: 'true'
    AllowedValues: ['true', 'false']

  EnableValidation:
    Type: String
    Default: 'true'
    AllowedValues: ['true', 'false']
    Description: >-
      Row-by-row comparison of source and target after load. Roughly doubles
      the load on both sides. Leave enabled for the rehearsal; consider
      disabling for the final cutover run if the rehearsal was clean.

Conditions:
  IsMultiAz: !Equals [!Ref MultiAz, 'true']

Resources:

  # -------------------------------------------------------------- networking

  DmsSecurityGroup:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: DMS replication instance - egress to source and target only
      VpcId: !Ref VpcId
      SecurityGroupEgress:
        - IpProtocol: tcp
          FromPort: !Ref OnPremOraclePort
          ToPort: !Ref OnPremOraclePort
          CidrIp: 172.20.0.0/14
          Description: Oracle TNS listener on premises
        - IpProtocol: tcp
          FromPort: 5432
          ToPort: 5432
          CidrIp: 10.60.0.0/16
          Description: Aurora PostgreSQL target
        - IpProtocol: tcp
          FromPort: 443
          ToPort: 443
          CidrIp: 0.0.0.0/0
          Description: Secrets Manager, CloudWatch Logs, KMS
      Tags:
        - Key: Name
          Value: !Sub '${ProjectTag}-dms-sg'
        - Key: migration-wave-project
          Value: !Ref ProjectTag

  # --------------------------------------------------- replication instance

  ReplicationSubnetGroup:
    Type: AWS::DMS::ReplicationSubnetGroup
    Properties:
      ReplicationSubnetGroupIdentifier: !Sub '${ProjectTag}-dms-subnet-group'
      ReplicationSubnetGroupDescription: Private subnets for the DMS replication instance
      SubnetIds: !Ref PrivateSubnetIds
      Tags:
        - Key: migration-wave-project
          Value: !Ref ProjectTag

  ReplicationInstance:
    Type: AWS::DMS::ReplicationInstance
    Properties:
      ReplicationInstanceIdentifier: !Sub '${ProjectTag}-erp-ri'
      ReplicationInstanceClass: !Ref ReplicationInstanceClass
      AllocatedStorage: !Ref ReplicationInstanceStorageGiB
      MultiAZ: !If [IsMultiAz, true, false]
      PubliclyAccessible: false
      AutoMinorVersionUpgrade: true
      PreferredMaintenanceWindow: sun:02:00-sun:03:00
      ReplicationSubnetGroupIdentifier: !Ref ReplicationSubnetGroup
      VpcSecurityGroupIds:
        - !Ref DmsSecurityGroup
      Tags:
        - Key: Name
          Value: !Sub '${ProjectTag}-erp-ri'
        - Key: migration-wave-project
          Value: !Ref ProjectTag

  # ------------------------------------------------------------- endpoints

  OracleSourceEndpoint:
    Type: AWS::DMS::Endpoint
    Properties:
      EndpointIdentifier: !Sub '${ProjectTag}-erp-oracle-source'
      EndpointType: source
      EngineName: oracle
      ServerName: !Ref OnPremOracleHost
      Port: !Ref OnPremOraclePort
      DatabaseName: !Ref OnPremOracleServiceName
      SslMode: require
      # Credentials resolved at runtime from Secrets Manager.
      OracleSettings:
        SecretsManagerSecretId: !Ref OracleSecretArn
        SecretsManagerAccessRoleArn: !GetAtt DmsSecretsAccessRole.Arn
      ExtraConnectionAttributes: >-
        useLogminerReader=N;useBfile=Y;
        addSupplementalLogging=N;
        archivedLogDestId=1;
        numberDataTypeScale=-2;
        failTasksOnLobTruncation=true
      Tags:
        - Key: migration-wave-project
          Value: !Ref ProjectTag

  AuroraTargetEndpoint:
    Type: AWS::DMS::Endpoint
    Properties:
      EndpointIdentifier: !Sub '${ProjectTag}-erp-aurora-target'
      EndpointType: target
      EngineName: aurora-postgresql
      ServerName: !Ref AuroraWriterEndpoint
      Port: 5432
      DatabaseName: !Ref AuroraDatabaseName
      SslMode: require
      PostgreSqlSettings:
        SecretsManagerSecretId: !Ref AuroraSecretArn
        SecretsManagerAccessRoleArn: !GetAtt DmsSecretsAccessRole.Arn
      ExtraConnectionAttributes: >-
        executeTimeout=180;
        maxFileSize=32768;
        heartbeatEnable=true;
        heartbeatFrequency=5
      Tags:
        - Key: migration-wave-project
          Value: !Ref ProjectTag

  DmsSecretsAccessRole:
    Type: AWS::IAM::Role
    Properties:
      RoleName: !Sub '${ProjectTag}-dms-secrets-access'
      AssumeRolePolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Effect: Allow
            Principal:
              Service: !Sub 'dms.${AWS::Region}.amazonaws.com'
            Action: sts:AssumeRole
            Condition:
              StringEquals:
                aws:SourceAccount: !Ref AWS::AccountId
      Policies:
        - PolicyName: read-migration-secrets
          PolicyDocument:
            Version: '2012-10-17'
            Statement:
              - Effect: Allow
                Action:
                  - secretsmanager:GetSecretValue
                  - secretsmanager:DescribeSecret
                Resource:
                  - !Ref OracleSecretArn
                  - !Ref AuroraSecretArn

  # ---------------------------------------------------------------- task

  ErpReplicationTask:
    Type: AWS::DMS::ReplicationTask
    Properties:
      ReplicationTaskIdentifier: !Sub '${ProjectTag}-erp-fullload-cdc'
      MigrationType: full-load-and-cdc
      ReplicationInstanceArn: !Ref ReplicationInstance
      SourceEndpointArn: !Ref OracleSourceEndpoint
      TargetEndpointArn: !Ref AuroraTargetEndpoint

      # ---- selection and transformation rules -------------------------------
      # Oracle stores identifiers upper-case; PostgreSQL folds to lower-case.
      # Without the rename rules every object arrives quoted and upper-cased,
      # and the application's unquoted lower-case SQL cannot see it. This is
      # the single most common heterogeneous-migration failure.
      TableMappings: |
        {
          "rules": [
            {
              "rule-type": "selection",
              "rule-id": "1",
              "rule-name": "include-erp-core",
              "object-locator": {
                "schema-name": "ERP",
                "table-name": "%"
              },
              "rule-action": "include",
              "filters": []
            },
            {
              "rule-type": "selection",
              "rule-id": "2",
              "rule-name": "exclude-audit-and-temp",
              "object-locator": {
                "schema-name": "ERP",
                "table-name": "AUD$%"
              },
              "rule-action": "exclude",
              "filters": []
            },
            {
              "rule-type": "selection",
              "rule-id": "3",
              "rule-name": "exclude-interim-tables",
              "object-locator": {
                "schema-name": "ERP",
                "table-name": "%_TMP"
              },
              "rule-action": "exclude",
              "filters": []
            },
            {
              "rule-type": "selection",
              "rule-id": "4",
              "rule-name": "archive-recent-only",
              "object-locator": {
                "schema-name": "ERP",
                "table-name": "GL_JOURNAL_ARCHIVE"
              },
              "rule-action": "include",
              "filters": [
                {
                  "filter-type": "source",
                  "column-name": "POSTING_DATE",
                  "filter-conditions": [
                    {
                      "filter-operator": "gte",
                      "value": "2019-01-01"
                    }
                  ]
                }
              ]
            },
            {
              "rule-type": "transformation",
              "rule-id": "5",
              "rule-name": "schema-to-lower",
              "rule-target": "schema",
              "object-locator": { "schema-name": "ERP" },
              "rule-action": "convert-lowercase",
              "value": null,
              "old-value": null
            },
            {
              "rule-type": "transformation",
              "rule-id": "6",
              "rule-name": "table-to-lower",
              "rule-target": "table",
              "object-locator": { "schema-name": "ERP", "table-name": "%" },
              "rule-action": "convert-lowercase",
              "value": null,
              "old-value": null
            },
            {
              "rule-type": "transformation",
              "rule-id": "7",
              "rule-name": "column-to-lower",
              "rule-target": "column",
              "object-locator": {
                "schema-name": "ERP",
                "table-name": "%",
                "column-name": "%"
              },
              "rule-action": "convert-lowercase",
              "value": null,
              "old-value": null
            },
            {
              "rule-type": "transformation",
              "rule-id": "8",
              "rule-name": "drop-oracle-rowid-shadow",
              "rule-target": "column",
              "object-locator": {
                "schema-name": "ERP",
                "table-name": "%",
                "column-name": "ORA_ROWSCN"
              },
              "rule-action": "remove-column"
            }
          ]
        }

      # ---- task settings ----------------------------------------------------
      ReplicationTaskSettings: !Sub |
        {
          "TargetMetadata": {
            "TargetSchema": "",
            "SupportLobs": true,
            "FullLobMode": false,
            "LobChunkSize": 64,
            "LimitedSizeLobMode": true,
            "LobMaxSize": 65536,
            "InlineLobMaxSize": 0,
            "LoadMaxFileSize": 0,
            "ParallelLoadThreads": 8,
            "ParallelLoadBufferSize": 500,
            "ParallelApplyThreads": 8,
            "ParallelApplyBufferSize": 500,
            "ParallelApplyQueuesPerThread": 4,
            "BatchApplyEnabled": true,
            "TaskRecoveryTableEnabled": false
          },
          "FullLoadSettings": {
            "TargetTablePrepMode": "TRUNCATE_BEFORE_LOAD",
            "CreatePkAfterFullLoad": false,
            "StopTaskCachedChangesApplied": false,
            "StopTaskCachedChangesNotApplied": false,
            "MaxFullLoadSubTasks": 8,
            "TransactionConsistencyTimeout": 600,
            "CommitRate": 10000
          },
          "Logging": {
            "EnableLogging": true,
            "LogComponents": [
              { "Id": "SOURCE_UNLOAD",  "Severity": "LOGGER_SEVERITY_DEFAULT" },
              { "Id": "SOURCE_CAPTURE", "Severity": "LOGGER_SEVERITY_DEBUG"   },
              { "Id": "TARGET_LOAD",    "Severity": "LOGGER_SEVERITY_DEFAULT" },
              { "Id": "TARGET_APPLY",   "Severity": "LOGGER_SEVERITY_DEBUG"   },
              { "Id": "TASK_MANAGER",   "Severity": "LOGGER_SEVERITY_DEFAULT" }
            ]
          },
          "ControlTablesSettings": {
            "ControlSchema": "dms_control",
            "HistoryTimeslotInMinutes": 5,
            "HistoryTableEnabled": true,
            "SuspendedTablesTableEnabled": true,
            "StatusTableEnabled": true
          },
          "ErrorBehavior": {
            "DataErrorPolicy": "LOG_ERROR",
            "DataTruncationErrorPolicy": "STOP_TASK",
            "DataErrorEscalationPolicy": "SUSPEND_TABLE",
            "DataErrorEscalationCount": 50,
            "TableErrorPolicy": "SUSPEND_TABLE",
            "TableErrorEscalationPolicy": "STOP_TASK",
            "TableErrorEscalationCount": 3,
            "RecoverableErrorCount": -1,
            "RecoverableErrorInterval": 5,
            "RecoverableErrorThrottling": true,
            "RecoverableErrorThrottlingMax": 1800,
            "ApplyErrorDeletePolicy": "IGNORE_RECORD",
            "ApplyErrorInsertPolicy": "LOG_ERROR",
            "ApplyErrorUpdatePolicy": "LOG_ERROR",
            "ApplyErrorEscalationPolicy": "LOG_ERROR",
            "ApplyErrorEscalationCount": 0,
            "FullLoadIgnoreConflicts": true
          },
          "ValidationSettings": {
            "EnableValidation": ${EnableValidation},
            "ValidationMode": "ROW_LEVEL",
            "ThreadCount": 5,
            "PartitionSize": 10000,
            "FailureMaxCount": 10000,
            "RecordFailureDelayInMinutes": 5,
            "RecordSuspendDelayInMinutes": 30,
            "HandleCollationDiff": true,
            "ValidationPartialLobSize": 0,
            "SkipLobColumns": false,
            "TableFailureMaxCount": 1000,
            "ValidationOnly": false
          },
          "ChangeProcessingTuning": {
            "BatchApplyPreserveTransaction": true,
            "BatchApplyTimeoutMin": 1,
            "BatchApplyTimeoutMax": 30,
            "BatchApplyMemoryLimit": 500,
            "BatchSplitSize": 0,
            "MinTransactionSize": 1000,
            "CommitTimeout": 1,
            "MemoryLimitTotal": 1024,
            "MemoryKeepTime": 60,
            "StatementCacheSize": 50
          },
          "ChangeProcessingDdlHandlingPolicy": {
            "HandleSourceTableDropped": true,
            "HandleSourceTableTruncated": true,
            "HandleSourceTableAltered": true
          },
          "StreamBufferSettings": {
            "StreamBufferCount": 3,
            "StreamBufferSizeInMB": 8,
            "CtrlStreamBufferSizeInMB": 5
          }
        }

      Tags:
        - Key: migration-wave-project
          Value: !Ref ProjectTag

  # ------------------------------------------------------------ observability

  CdcTargetLatencyAlarm:
    Type: AWS::CloudWatch::Alarm
    Properties:
      AlarmName: !Sub '${ProjectTag}-erp-cdc-target-latency'
      AlarmDescription: >-
        CDCLatencyTarget is the delta between a change being read from the
        source log and committed on the target. Sustained growth means the
        target cannot keep up - the cutover window will not close.
      Namespace: AWS/DMS
      MetricName: CDCLatencyTarget
      Dimensions:
        - Name: ReplicationInstanceIdentifier
          Value: !Sub '${ProjectTag}-erp-ri'
        - Name: ReplicationTaskIdentifier
          Value: !Sub '${ProjectTag}-erp-fullload-cdc'
      Statistic: Maximum
      Period: 60
      EvaluationPeriods: 5
      Threshold: 300
      ComparisonOperator: GreaterThanThreshold
      TreatMissingData: breaching

  CdcSourceLatencyAlarm:
    Type: AWS::CloudWatch::Alarm
    Properties:
      AlarmName: !Sub '${ProjectTag}-erp-cdc-source-latency'
      AlarmDescription: >-
        CDCLatencySource growing while CDCLatencyTarget is flat points at the
        SOURCE side - log mining throughput, archive log destination, or
        network - not at the target.
      Namespace: AWS/DMS
      MetricName: CDCLatencySource
      Dimensions:
        - Name: ReplicationInstanceIdentifier
          Value: !Sub '${ProjectTag}-erp-ri'
        - Name: ReplicationTaskIdentifier
          Value: !Sub '${ProjectTag}-erp-fullload-cdc'
      Statistic: Maximum
      Period: 60
      EvaluationPeriods: 5
      Threshold: 300
      ComparisonOperator: GreaterThanThreshold
      TreatMissingData: breaching

  ReplicationInstanceStorageAlarm:
    Type: AWS::CloudWatch::Alarm
    Properties:
      AlarmName: !Sub '${ProjectTag}-erp-ri-free-storage'
      AlarmDescription: >-
        Replication-instance storage holds spilled CDC changes and task logs.
        Exhaustion stops the task with no clean resume point.
      Namespace: AWS/DMS
      MetricName: FreeStorageSpace
      Dimensions:
        - Name: ReplicationInstanceIdentifier
          Value: !Sub '${ProjectTag}-erp-ri'
      Statistic: Minimum
      Period: 300
      EvaluationPeriods: 2
      Threshold: 21474836480   # 20 GiB
      ComparisonOperator: LessThanThreshold
      TreatMissingData: breaching

Outputs:

  ReplicationInstanceArn:
    Value: !Ref ReplicationInstance
    Export:
      Name: !Sub '${AWS::StackName}-ReplicationInstanceArn'

  ReplicationTaskArn:
    Value: !Ref ErpReplicationTask
    Export:
      Name: !Sub '${AWS::StackName}-ReplicationTaskArn'

  SourceEndpointArn:
    Value: !Ref OracleSourceEndpoint

  TargetEndpointArn:
    Value: !Ref AuroraTargetEndpoint
```

### 7.4 DMS operational commands

```console
$ TASK_ARN=$(aws cloudformation describe-stacks \
    --stack-name dc-exit-2026-dms-erp \
    --query 'Stacks[0].Outputs[?OutputKey==`ReplicationTaskArn`].OutputValue' \
    --output text)

$ aws dms test-connection \
    --replication-instance-arn "$RI_ARN" \
    --endpoint-arn "$SRC_ARN"
{
    "Connection": {
        "ReplicationInstanceArn": "arn:aws:dms:eu-west-1:123456789012:rep:VZ7XK4M2QJ5NRWBTLC3HYP6ADQ",
        "EndpointArn": "arn:aws:dms:eu-west-1:123456789012:endpoint:H3TQK9WXLZ2VN8MYRBC5PDAF7U",
        "Status": "testing",
        "EndpointIdentifier": "dc-exit-2026-erp-oracle-source",
        "ReplicationInstanceIdentifier": "dc-exit-2026-erp-ri"
    }
}

$ aws dms describe-connections \
    --filters Name=endpoint-arn,Values="$SRC_ARN" \
    --query 'Connections[0].[Status,LastFailureMessage]' --output text
successful     None

$ aws dms start-replication-task \
    --replication-task-arn "$TASK_ARN" \
    --start-replication-task-type start-replication
{
    "ReplicationTask": {
        "ReplicationTaskIdentifier": "dc-exit-2026-erp-fullload-cdc",
        "MigrationType": "full-load-and-cdc",
        "Status": "starting",
        "ReplicationTaskCreationDate": "2026-09-03T11:02:18.400000+00:00",
        "ReplicationTaskStartDate": "2026-09-03T11:47:03.918000+00:00"
    }
}
```

Progress:

```console
$ aws dms describe-replication-tasks \
    --filters Name=replication-task-arn,Values="$TASK_ARN" \
    --query 'ReplicationTasks[0].{status:Status,pct:ReplicationTaskStats.FullLoadProgressPercent,loaded:ReplicationTaskStats.TablesLoaded,loading:ReplicationTaskStats.TablesLoading,queued:ReplicationTaskStats.TablesQueued,errored:ReplicationTaskStats.TablesErrored}'
{
    "status": "running",
    "pct": 87,
    "loaded": 812,
    "loading": 8,
    "queued": 114,
    "errored": 2
}
```

Two tables errored. Find them:

```console
$ aws dms describe-table-statistics \
    --replication-task-arn "$TASK_ARN" \
    --filters Name=table-state,Values="Table error" \
    --query 'TableStatistics[].[SchemaName,TableName,TableState,FullLoadErrorRows,FullLoadCondtnlChkFailedRows,ValidationState]' \
    --output text
erp     gl_journal_line     Table error     0      148213    Not enabled
erp     doc_attachment      Table error     37     0         Not enabled

$ aws logs filter-log-events \
    --log-group-name dms-tasks-dc-exit-2026-erp-ri \
    --log-stream-names dms-task-VZ7XK4M2QJ5NRWBTLC3HYP6ADQ \
    --filter-pattern 'doc_attachment' \
    --query 'events[0:3].message' --output text
2026-09-03T13:11:04 [TARGET_APPLY  ]E: RetCode: SQL_ERROR SqlState: 22001 NativeError: 1 Message: ERROR: value too long for type character varying(4000); Error while executing the query [1022502] (ar_odbc_stmt.c:2736)
2026-09-03T13:11:04 [TARGET_APPLY  ]E: Failed to load table 'erp'.'doc_attachment' [1022502] (streamcomponent.c:1969)
2026-09-03T13:11:04 [TASK_MANAGER  ]W: Table 'erp'.'doc_attachment' (subtask 5 thread 3) is suspended (replicationtask.c:2617)
```

Diagnosis: `LobMaxSize: 65536` with `LimitedSizeLobMode: true` truncates LOBs beyond 64 KB, and the target column cannot hold the value. Either raise `LobMaxSize`, switch that table to `FullLobMode` in a **separate task** (full LOB mode is slow — never mix it with the bulk task), or widen the target column to `text`.

Validation results once the load finishes:

```console
$ aws dms describe-table-statistics \
    --replication-task-arn "$TASK_ARN" \
    --query 'TableStatistics[?ValidationFailedRecords>`0`].[SchemaName,TableName,FullLoadRows,ValidationPendingRecords,ValidationFailedRecords,ValidationSuspendedRecords,ValidationState]' \
    --output text
erp     fx_rate_daily     1204877     0     41     0     Mismatched records

$ aws dms describe-replication-task-assessment-results \
    --replication-task-arn "$TASK_ARN" \
    --query 'ReplicationTaskAssessmentResults[0].[AssessmentStatus,AssessmentResultsFile]' --output text
"No issues found"    dc-exit-2026-erp-fullload-cdc-2026-09-03-11-02
```

> 41 mismatches in `fx_rate_daily` on an Oracle `NUMBER` column is the classic `numberDataTypeScale` artefact: Oracle `NUMBER` with unspecified precision maps to a PostgreSQL type that rounds. This is a **data-correctness defect**, not a DMS bug — the extra connection attribute `numberDataTypeScale=-2` in the endpoint above maps it to `varchar` for exact preservation, which then needs an explicit cast in the application. It is a real trade-off, and it must be decided before cutover, not discovered after.

---

## 8. MGN execution: test, cutover, verify

### 8.1 Replication health across the wave

```console
$ aws mgn describe-source-servers --region eu-west-1 \
    --filters isArchived=false \
    --query 'items[].[sourceProperties.identificationHints.hostname,
                      sourceServerID,
                      lifeCycle.state,
                      dataReplicationInfo.dataReplicationState,
                      dataReplicationInfo.lagDuration,
                      dataReplicationInfo.etaDateTime]' \
    --output text | column -t
app-prd-04   s-0a1b2c3d4e5f60718  READY_FOR_CUTOVER  CONTINUOUS   PT0S       None
app-prd-05   s-0b2c3d4e5f6a71829  READY_FOR_CUTOVER  CONTINUOUS   PT0S       None
app-prd-06   s-0c3d4e5f6a7b8293a  READY_FOR_TEST     CONTINUOUS   PT4M12S    None
ora-prd-01   s-0d4e5f6a7b8c93a4b  NOT_READY          INITIAL_SYNC PT0S       2026-09-05T02:41:00Z
win-batch-02 s-0e5f6a7b8c9da4b5c  NOT_READY          STALLED      PT9H17M    None
```

`win-batch-02` is stalled with a 9 h lag. Get the reason:

```console
$ aws mgn describe-source-servers \
    --filters sourceServerIDs=s-0e5f6a7b8c9da4b5c \
    --query 'items[0].dataReplicationInfo.{state:dataReplicationState,
                                           err:dataReplicationError,
                                           init:dataReplicationInitiation.steps[-3:],
                                           disks:replicatedDisks}'
{
    "state": "STALLED",
    "err": {
        "error": "FAILED_TO_CONNECT_AGENT_TO_REPLICATION_SERVER",
        "rawError": "Agent could not establish a connection to the replication server on TCP 1500"
    },
    "init": [
        {
            "name": "LAUNCH_REPLICATION_SERVER",
            "status": "SUCCEEDED"
        },
        {
            "name": "BOOT_REPLICATION_SERVER",
            "status": "SUCCEEDED"
        },
        {
            "name": "AUTHENTICATE_WITH_SERVICE",
            "status": "FAILED"
        }
    ],
    "disks": [
        {
            "deviceName": "/dev/sda1",
            "totalStorageBytes": 107374182400,
            "replicatedStorageBytes": 107374182400,
            "backloggedStorageBytes": 0,
            "rescannedStorageBytes": 0
        },
        {
            "deviceName": "/dev/sdb",
            "totalStorageBytes": 2147483648000,
            "replicatedStorageBytes": 1683219644416,
            "backloggedStorageBytes": 41231548416,
            "rescannedStorageBytes": 0
        }
    ]
}
```

### 8.2 Test launch — mandatory before cutover

```console
$ aws mgn start-test --source-server-ids s-0a1b2c3d4e5f60718 s-0b2c3d4e5f6a71829
{
    "job": {
        "jobID": "mgnjob-0f1e2d3c4b5a69788",
        "arn": "arn:aws:mgn:eu-west-1:123456789012:job/mgnjob-0f1e2d3c4b5a69788",
        "type": "LAUNCH",
        "initiatedBy": "START_TEST",
        "status": "PENDING",
        "creationDateTime": "2026-09-03T14:02:11Z",
        "participatingServers": [
            { "sourceServerID": "s-0a1b2c3d4e5f60718", "launchStatus": "PENDING" },
            { "sourceServerID": "s-0b2c3d4e5f6a71829", "launchStatus": "PENDING" }
        ]
    }
}

$ aws mgn describe-jobs --filters jobIDs=mgnjob-0f1e2d3c4b5a69788 \
    --query 'items[0].{status:status,servers:participatingServers[].{s:sourceServerID,st:launchStatus,i:launchedEc2InstanceID}}'
{
    "status": "COMPLETED",
    "servers": [
        { "s": "s-0a1b2c3d4e5f60718", "st": "LAUNCHED", "i": "i-04c8f2a71b6d3e590" },
        { "s": "s-0b2c3d4e5f6a71829", "st": "LAUNCHED", "i": "i-0b7e3d9a24c15f806" }
    ]
}
```

**Non-negotiable test validations** before marking the test successful:

| Check | Command / method | Pass condition |
|---|---|---|
| Instance boots to OS | `aws ec2 get-console-output --instance-id i-04c8f2a71b6d3e590 --latest --output text` | Login prompt / `Reached target Multi-User System` |
| All disks mounted | `df -h` inside via SSM | Every source mount point present with correct size |
| Application starts | Service-specific | Health endpoint 200 |
| Licences valid | Vendor tool | New instance ID / MAC accepted |
| Outbound dependencies reachable | `ss -tnp`, targeted `curl` | No connection to on-prem IPs that will be firewalled |
| No hardcoded source IPs | `grep -rn '172\.20\.' /etc /opt` | Empty, or every hit is understood |
| Time sync | `chronyc sources` / `w32tm /query /status` | Synced to Amazon Time Sync (169.254.169.123) |

```console
$ aws mgn finalize-cutover --source-server-id s-0a1b2c3d4e5f60718
# (run only AFTER the real cutover, not after a test)
```

### 8.3 Cutover runbook

```
T-14d   Wave scoped. Dependency edges resolved or explicitly accepted.
T-7d    Test launch executed and validated for every server in the wave.
T-72h   DNS TTL for every affected record lowered to 60 s. VERIFY with dig
        from an external resolver, not from the authoritative server.
T-48h   Reverse replication path confirmed (DMS reverse task created and
        tested; MGN source servers left intact, NOT decommissioned).
T-24h   Change freeze on source. Replication lag confirmed at PT0S.
        Go/no-go with named decision owner.
T-0     1. Stop the application on the source. Confirm zero writes:
           Oracle : SELECT COUNT(*) FROM v$transaction;      -- must be 0
           MySQL  : SHOW PROCESSLIST;                        -- no writers
           Postgres: SELECT * FROM pg_stat_activity
                     WHERE state='active' AND query NOT LIKE '%pg_stat%';
        2. Wait for lag to reach zero on every replication stream.
        3. aws mgn start-cutover --source-server-ids <ids>
        4. Wait for launchStatus LAUNCHED on all participating servers.
        5. Run the smoke suite against the target directly (bypass DNS,
           use /etc/hosts or the instance IP).
        6. Flip DNS / Route 53 weighted record to the target.
        7. Watch error rate and latency for the full observation window.
T+2h    Go/no-go on rollback. After this point rollback means data loss.
T+24h   aws mgn finalize-cutover  (releases staging resources)
        DMS task stopped and DELETED - verify the replication slot is gone.
T+7d    Source servers powered off but NOT wiped.
T+30d   Source decommissioned. Datacenter asset record updated.
```

Zero-lag verification, the gate on step 2:

```console
$ aws mgn describe-source-servers --filters sourceServerIDs=s-0a1b2c3d4e5f60718 \
    --query 'items[0].dataReplicationInfo.{lag:lagDuration,state:dataReplicationState,snap:lastSnapshotDateTime}'
{
    "lag": "PT0S",
    "state": "CONTINUOUS",
    "snap": "2026-09-03T22:58:04Z"
}

$ aws dms describe-replication-tasks --filters Name=replication-task-arn,Values="$TASK_ARN" \
    --query 'ReplicationTasks[0].{status:Status,stopReason:StopReason}'
{
    "status": "running",
    "stopReason": null
}

$ aws cloudwatch get-metric-statistics \
    --namespace AWS/DMS --metric-name CDCLatencyTarget \
    --dimensions Name=ReplicationInstanceIdentifier,Value=dc-exit-2026-erp-ri \
                 Name=ReplicationTaskIdentifier,Value=dc-exit-2026-erp-fullload-cdc \
    --start-time 2026-09-03T22:45:00Z --end-time 2026-09-03T23:00:00Z \
    --period 60 --statistics Maximum \
    --query 'sort_by(Datapoints,&Timestamp)[].[Timestamp,Maximum]' --output text
2026-09-03T22:45:00+00:00   4.0
2026-09-03T22:50:00+00:00   2.0
2026-09-03T22:55:00+00:00   0.0
```

---

## 9. DataSync: complete file-tier migration stack

```yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: >-
  On-premises NFS filer -> Amazon S3 migration with AWS DataSync.
  Includes the location pair, the task with explicit transfer semantics, a
  nightly schedule for the incremental delta, CloudWatch logging, and an alarm
  on execution failure. The DataSync agent VM must already be deployed on
  premises and activated - the agent ARN is a parameter, not a resource,
  because activation requires network access to the appliance.

Parameters:

  ProjectTag:
    Type: String
    Default: dc-exit-2026

  AgentArn:
    Type: String
    Description: >-
      ARN of the activated DataSync agent, e.g.
      arn:aws:datasync:eu-west-1:123456789012:agent/agent-0a1b2c3d4e5f60718

  NfsServerHostname:
    Type: String
    Default: nfs-filer-01.corp.internal
    Description: Must be resolvable and reachable FROM THE AGENT, not from AWS.

  NfsSubdirectory:
    Type: String
    Default: /export/finance-archive
    Description: Must be an exported path with the agent's IP permitted in /etc/exports.

  DestinationBucketName:
    Type: String
    Default: dc-exit-2026-finance-archive-eu-west-1

  DestinationPrefix:
    Type: String
    Default: /finance-archive

  BytesPerSecondLimit:
    Type: Number
    Default: -1
    Description: >-
      Bandwidth ceiling in bytes/s. -1 means unlimited, which will saturate the
      WAN link. 125000000 = 1 Gbps. Set this to protect production traffic.

Resources:

  ArchiveBucket:
    Type: AWS::S3::Bucket
    DeletionPolicy: Retain
    UpdateReplacePolicy: Retain
    Properties:
      BucketName: !Ref DestinationBucketName
      VersioningConfiguration:
        Status: Enabled
      BucketEncryption:
        ServerSideEncryptionConfiguration:
          - ServerSideEncryptionByDefault:
              SSEAlgorithm: aws:kms
            BucketKeyEnabled: true
      PublicAccessBlockConfiguration:
        BlockPublicAcls: true
        BlockPublicPolicy: true
        IgnorePublicAcls: true
        RestrictPublicBuckets: true
      LifecycleConfiguration:
        Rules:
          - Id: archive-cold-objects
            Status: Enabled
            Transitions:
              - StorageClass: STANDARD_IA
                TransitionInDays: 30
              - StorageClass: GLACIER_IR
                TransitionInDays: 90
              - StorageClass: DEEP_ARCHIVE
                TransitionInDays: 365
            NoncurrentVersionExpiration:
              NoncurrentDays: 90
      Tags:
        - Key: migration-wave-project
          Value: !Ref ProjectTag

  DataSyncS3AccessRole:
    Type: AWS::IAM::Role
    Properties:
      RoleName: !Sub '${ProjectTag}-datasync-s3-access'
      AssumeRolePolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Effect: Allow
            Principal:
              Service: datasync.amazonaws.com
            Action: sts:AssumeRole
            Condition:
              StringEquals:
                aws:SourceAccount: !Ref AWS::AccountId
      Policies:
        - PolicyName: datasync-bucket-access
          PolicyDocument:
            Version: '2012-10-17'
            Statement:
              - Effect: Allow
                Action:
                  - s3:GetBucketLocation
                  - s3:ListBucket
                  - s3:ListBucketMultipartUploads
                  - s3:HeadBucket
                Resource: !GetAtt ArchiveBucket.Arn
              - Effect: Allow
                Action:
                  - s3:AbortMultipartUpload
                  - s3:DeleteObject
                  - s3:GetObject
                  - s3:GetObjectTagging
                  - s3:GetObjectVersion
                  - s3:ListMultipartUploadParts
                  - s3:PutObject
                  - s3:PutObjectTagging
                Resource: !Sub '${ArchiveBucket.Arn}/*'

  DataSyncLogGroup:
    Type: AWS::Logs::LogGroup
    Properties:
      LogGroupName: !Sub '/aws/datasync/${ProjectTag}-finance-archive'
      RetentionInDays: 90

  DataSyncLogResourcePolicy:
    Type: AWS::Logs::ResourcePolicy
    Properties:
      PolicyName: !Sub '${ProjectTag}-datasync-logs'
      PolicyDocument: !Sub |
        {
          "Version": "2012-10-17",
          "Statement": [
            {
              "Sid": "DataSyncLogsToCloudWatch",
              "Effect": "Allow",
              "Principal": { "Service": "datasync.amazonaws.com" },
              "Action": ["logs:PutLogEvents", "logs:CreateLogStream"],
              "Resource": "arn:aws:logs:${AWS::Region}:${AWS::AccountId}:log-group:/aws/datasync/*:*"
            }
          ]
        }

  NfsSourceLocation:
    Type: AWS::DataSync::LocationNFS
    Properties:
      ServerHostname: !Ref NfsServerHostname
      Subdirectory: !Ref NfsSubdirectory
      OnPremConfig:
        AgentArns:
          - !Ref AgentArn
      MountOptions:
        Version: NFS4_1
      Tags:
        - Key: Name
          Value: !Sub '${ProjectTag}-nfs-source'

  S3DestinationLocation:
    Type: AWS::DataSync::LocationS3
    Properties:
      S3BucketArn: !GetAtt ArchiveBucket.Arn
      Subdirectory: !Ref DestinationPrefix
      S3StorageClass: STANDARD
      S3Config:
        BucketAccessRoleArn: !GetAtt DataSyncS3AccessRole.Arn
      Tags:
        - Key: Name
          Value: !Sub '${ProjectTag}-s3-destination'

  ArchiveSyncTask:
    Type: AWS::DataSync::Task
    Properties:
      Name: !Sub '${ProjectTag}-finance-archive-sync'
      SourceLocationArn: !Ref NfsSourceLocation
      DestinationLocationArn: !Ref S3DestinationLocation
      CloudWatchLogGroupArn: !GetAtt DataSyncLogGroup.Arn
      Schedule:
        # 01:00 UTC nightly - the incremental delta, not the seed.
        ScheduleExpression: 'cron(0 1 * * ? *)'
      Options:
        # TransferMode CHANGED compares metadata and moves only differences.
        # ALL re-reads everything - correct only for the first run or after a
        # suspected corruption event.
        TransferMode: CHANGED
        # POINT_IN_TIME_CONSISTENT verifies the whole dataset at the end.
        # ONLY_FILES_TRANSFERRED is far cheaper and sufficient for incrementals.
        VerifyMode: POINT_IN_TIME_CONSISTENT
        OverwriteMode: ALWAYS
        # PRESERVE keeps files in S3 that were deleted on the source. Set to
        # REMOVE only when S3 must be an exact mirror - it deletes data.
        PreserveDeletedFiles: PRESERVE
        PreserveDevices: NONE
        PosixPermissions: PRESERVE
        Uid: INT_VALUE
        Gid: INT_VALUE
        # Atime BEST_EFFORT requires Mtime PRESERVE - the API rejects any
        # other combination.
        Atime: BEST_EFFORT
        Mtime: PRESERVE
        ObjectTags: PRESERVE
        BytesPerSecond: !Ref BytesPerSecondLimit
        TaskQueueing: ENABLED
        LogLevel: TRANSFER
      Excludes:
        - FilterType: SIMPLE_PATTERN
          Value: '/*/.snapshot/*|/*/lost+found/*|*.tmp'
      Tags:
        - Key: migration-wave-project
          Value: !Ref ProjectTag

  TaskFailureAlarm:
    Type: AWS::CloudWatch::Alarm
    Properties:
      AlarmName: !Sub '${ProjectTag}-datasync-files-failed'
      AlarmDescription: DataSync reported files it could not transfer or verify.
      Namespace: AWS/DataSync
      MetricName: FilesFailedToTransfer
      Dimensions:
        - Name: TaskId
          Value: !GetAtt ArchiveSyncTask.TaskArn
      Statistic: Sum
      Period: 3600
      EvaluationPeriods: 1
      Threshold: 0
      ComparisonOperator: GreaterThanThreshold
      TreatMissingData: notBreaching

Outputs:
  TaskArn:
    Value: !Ref ArchiveSyncTask
  SourceLocationArn:
    Value: !Ref NfsSourceLocation
  DestinationLocationArn:
    Value: !Ref S3DestinationLocation
```

```console
$ aws datasync start-task-execution \
    --task-arn arn:aws:datasync:eu-west-1:123456789012:task/task-0a9b8c7d6e5f40312
{
    "TaskExecutionArn": "arn:aws:datasync:eu-west-1:123456789012:task/task-0a9b8c7d6e5f40312/execution/exec-0f8e7d6c5b4a39281"
}

$ aws datasync describe-task-execution \
    --task-execution-arn arn:aws:datasync:eu-west-1:123456789012:task/task-0a9b8c7d6e5f40312/execution/exec-0f8e7d6c5b4a39281
{
    "TaskExecutionArn": "arn:aws:datasync:eu-west-1:123456789012:task/task-0a9b8c7d6e5f40312/execution/exec-0f8e7d6c5b4a39281",
    "Status": "SUCCESS",
    "Options": {
        "VerifyMode": "POINT_IN_TIME_CONSISTENT",
        "OverwriteMode": "ALWAYS",
        "Atime": "BEST_EFFORT",
        "Mtime": "PRESERVE",
        "Uid": "INT_VALUE",
        "Gid": "INT_VALUE",
        "PreserveDeletedFiles": "PRESERVE",
        "PreserveDevices": "NONE",
        "PosixPermissions": "PRESERVE",
        "BytesPerSecond": -1,
        "TaskQueueing": "ENABLED",
        "LogLevel": "TRANSFER",
        "TransferMode": "CHANGED",
        "ObjectTags": "PRESERVE"
    },
    "StartTime": "2026-09-03T01:00:03.117000+00:00",
    "EstimatedFilesToTransfer": 1842991,
    "EstimatedBytesToTransfer": 4193847610368,
    "FilesTransferred": 1842991,
    "BytesWritten": 4193847610368,
    "BytesTransferred": 3114208477184,
    "Result": {
        "PrepareDuration": 412883,
        "PrepareStatus": "SUCCESS",
        "TotalDuration": 34718402,
        "TransferDuration": 31904118,
        "TransferStatus": "SUCCESS",
        "VerifyDuration": 2401401,
        "VerifyStatus": "SUCCESS"
    }
}
```

> `BytesTransferred` (3.11 TB) < `BytesWritten` (4.19 TB) is DataSync's in-flight compression working — 26% saved on the wire. This is the metric to quote when the network team asks what the link is carrying.

---

## 10. Verification and failure diagnosis

### 10.1 MGN failure catalogue

| `dataReplicationError.error` | Real cause | Diagnostic | Fix |
|---|---|---|---|
| `AGENT_NOT_SEEN` | Agent service stopped, host powered off, or outbound 443 blocked | `systemctl status aws-replication-agent`; `curl -v https://mgn.<region>.amazonaws.com` from source | Restart agent; open 443 egress to the MGN endpoint |
| `FAILED_TO_CONNECT_AGENT_TO_REPLICATION_SERVER` | TCP 1500 blocked by firewall/NACL/SG between source CIDR and staging subnet | `nc -vz <replication-server-private-ip> 1500` from the source host | Fix the SG ingress rule, the NACL, and the on-prem egress ACL — all three |
| `FAILED_TO_LAUNCH_REPLICATION_SERVER` | Instance-type unavailable in the AZ, EC2 quota exhausted, subnet out of IPs | `aws service-quotas get-service-quota --service-code ec2 --quota-code L-1216C47A`; check subnet free IPs | Raise quota, change instance type, widen the subnet |
| `FAILED_TO_CREATE_STAGING_DISKS` | EBS volume quota, or KMS key policy denies the MGN service-linked role | CloudTrail `CreateVolume` events with `AccessDenied` | Grant `kms:CreateGrant`/`Decrypt` to `AWSServiceRoleForApplicationMigrationService` |
| `FAILED_TO_AUTHENTICATE_WITH_SERVICE` | Agent credentials revoked/rotated, or clock skew > 5 min | Check IAM user key status; `timedatectl` on source | Reinstall agent with fresh keys; fix NTP |
| `NOT_CONVERGING` | Daily change rate exceeds available replication bandwidth (§1.1) | Compare `backloggedStorageBytes` trend over 24 h — if it grows, you will never converge | Raise bandwidth, remove the throttle, seed with Snow, or exclude the churning volume |
| `UNSTABLE_NETWORK` | Packet loss / MTU black hole on the DX or VPN path | `mtr --tcp --port 1500 <replication-server-ip>`; test PMTUD with `ping -M do -s 1472` | Clamp MSS on the tunnel; fix the MTU mismatch |
| `SNAPSHOTS_FAILURE` | EBS snapshot quota, or KMS denial on snapshot copy | CloudTrail `CreateSnapshot` | Raise the concurrent-snapshot quota |

### 10.2 DMS failure catalogue

| Symptom | Likely cause | Verification | Fix |
|---|---|---|---|
| Task status `failed` immediately | Endpoint connectivity | `aws dms test-connection` then `describe-connections` → `LastFailureMessage` | SG egress, on-prem firewall, DNS resolution from the replication instance |
| CDC never starts after full load | Missing supplemental logging / binlog config (§7.2) | Task log `SOURCE_CAPTURE` at DEBUG | Enable at the source; **the task must be restarted from scratch** |
| `CDCLatencySource` rising, target flat | Source log-mining throughput or archive-log destination | CloudWatch `CDCLatencySource` vs `CDCLatencyTarget` | Switch Oracle to Binary Reader; move archive logs to faster storage |
| `CDCLatencyTarget` rising, source flat | Target cannot apply fast enough | `CDCChangesDiskTarget` > 0 means memory buffer overflowed to disk | Enable `BatchApplyEnabled`, raise `ParallelApplyThreads`, scale the target |
| Table suspended mid-load | Data error crossed `DataErrorEscalationCount` | `describe-table-statistics` → `TableState` = `Table error` | Read the `TARGET_APPLY` log; usually LOB truncation or type mismatch |
| Validation mismatches on numerics | Oracle `NUMBER` precision loss | `ValidationFailedRecords` > 0 on numeric-heavy tables | `numberDataTypeScale` endpoint attribute; decide precision policy |
| Source disk filling up | Orphaned PostgreSQL replication slot / Oracle archive logs not purged | `SELECT slot_name, active, pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) FROM pg_replication_slots;` | Delete the dead task, then `pg_drop_replication_slot()` |
| Rows silently missing after cutover | Table lacked a primary key; CDC updates could not be applied | Compare `COUNT(*)` and a checksum per table | Add PKs *before* migrating; re-run full load for affected tables |

### 10.3 Independent verification — never trust one signal

Tool-reported success is necessary, not sufficient. Verify on three independent axes:

```console
# 1. Row counts, source vs target - computed independently of DMS
$ psql -h erp-aurora.cluster-abc123.eu-west-1.rds.amazonaws.com -U migrator -d erpprd -Atc \
  "SELECT relname, n_live_tup FROM pg_stat_user_tables
    WHERE schemaname='erp' ORDER BY relname" > /tmp/target_counts.txt

$ sqlplus -s migrator/@ERPPRD <<'SQL' > /tmp/source_counts.txt
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF
SELECT LOWER(table_name)||'|'||num_rows FROM all_tables
 WHERE owner='ERP' ORDER BY table_name;
SQL

$ diff <(sort /tmp/source_counts.txt) <(sort /tmp/target_counts.txt) | head
< gl_journal_line|41827311
> gl_journal_line|41827248

# 2. Content checksum on a business-critical table (not just the count)
$ psql -Atc "SELECT md5(string_agg(t::text, '|' ORDER BY id))
             FROM (SELECT id, amount, currency FROM erp.fx_rate_daily
                   WHERE rate_date >= '2026-01-01') t"
b7c1e94a2f60d5138ae2c93704f6a1d8

# 3. Application-level: run the reconciliation report the business already trusts
$ curl -s https://erp-target.internal/api/v1/reports/trial-balance?period=2026-08 \
    | jq -r '.total_debit, .total_credit, .variance'
884_192_337.44
884_192_337.44
0.00
```

> The 63-row shortfall in `gl_journal_line` is inside the noise of Oracle's `num_rows` (a *statistics estimate*, not a count) — which is exactly why axis 1 alone proves nothing. `COUNT(*)` on both sides, or the checksum, is the real signal. Every migration verification plan should state which of its checks are exact and which are estimates.

### 10.4 Cost verification post-migration

Migration budgets fail on staging resources nobody deleted:

```console
$ aws ce get-cost-and-usage \
    --time-period Start=2026-08-01,End=2026-09-01 \
    --granularity MONTHLY --metrics UnblendedCost \
    --filter '{"Tags":{"Key":"migration-wave-project","Values":["dc-exit-2026"]}}' \
    --group-by Type=DIMENSION,Key=SERVICE \
    --query 'ResultsByTime[0].Groups[].[Keys[0],Metrics.UnblendedCost.Amount]' --output text
AWS Database Migration Service        3184.77
Amazon Elastic Block Store            9412.03
Amazon Elastic Compute Cloud - Compute 6620.18
Amazon Simple Storage Service          741.92
AWS DataSync                           118.40

$ aws ec2 describe-volumes \
    --filters Name=status,Values=available Name=tag:migration-wave-project,Values=dc-exit-2026 \
    --query 'Volumes[].[VolumeId,Size,VolumeType,CreateTime]' --output text | wc -l
187
```

187 unattached staging volumes — the residue of completed cutovers where `finalize-cutover` was never run. `aws mgn finalize-cutover` is what releases them.

---

## 11. The benefits, and how to measure them

The exam guide asks you to *understand the benefits*. Naming them is not enough at this level — each maps to a measurable quantity.

### 11.1 AWS Cloud Value Framework pillars

| Pillar | Claim | Metric that proves it | Common failure to realise it |
|---|---|---|---|
| **Cost savings** | Lower TCO | $/workload/month vs the fully-loaded on-prem cost (hardware amortisation, DC space, power, cooling, network, staff) | Rehosting peak-sized VMs 1:1 — no right-sizing, no scheduling, no Savings Plans |
| **Staff productivity** | Engineers do less undifferentiated heavy lifting | Hours/month on patching, backups, capacity planning, hardware RMA | Keeping self-managed everything on EC2 |
| **Operational resilience** | Fewer and shorter outages | Availability, MTTR, unplanned-downtime hours, RTO/RPO actually tested | Single-AZ deployment because the source was single-datacenter |
| **Business agility** | Faster delivery | Lead time for change, deployment frequency, time-to-provision an environment | Same change-advisory board, now on AWS |
| **Sustainability** | Lower carbon per unit of work | Customer Carbon Footprint Tool; workload energy per transaction | Never measured, so never improved |

### 11.2 The four benefits named by the CLF-C02 task statement

| Benefit | Mechanism | Concrete example |
|---|---|---|
| **Reduced business risk** | Multi-AZ/multi-Region resilience; tested DR; managed patching; AWS compliance inheritance | RPO drops from "yesterday's tape" to seconds with cross-Region CDC |
| **Improved ESG performance** | Higher utilisation, more efficient hardware and cooling, renewable-energy commitments | Retiring 4 racks at 12% average utilisation removes their whole draw, not 12% of it |
| **Increased revenue** | New capability, faster experimentation, global reach in minutes | Launching in a new geography = a new Region, not a new datacenter lease |
| **Increased operational efficiency** | Automation, managed services, elasticity | Environments provisioned by CloudFormation in minutes rather than a 6-week procurement |

### 11.3 The Migration Acceleration Program (MAP)

MAP is AWS's funded, three-phase programme (Assess → Mobilize → Migrate & Modernize) that wraps tooling, partner services, and AWS credits around a migration. The exam-relevant fact is the mapping: **MAP's phases *are* the three migration phases in §2.4**, and MAP tagging (`map-migrated`) is what attributes migrated resources for credit purposes — which is what the `EnableMapAutoTagging` / `MapAutoTaggingMpeID` properties in the MGN launch template (§5) exist for.

---

## 12. Exam-focused distillation

| If the question mentions… | The answer is |
|---|---|
| Move a server as-is, minimal change | **Rehost** (AWS Application Migration Service / MGN) |
| Move VMware VMs at hypervisor level | **Relocate** |
| Move to a managed database, no code rewrite | **Replatform** |
| Abandon the app, buy a subscription | **Repurchase** |
| Break a monolith into microservices | **Refactor / Re-architect** |
| Nobody uses it | **Retire** |
| Cannot move yet — regulation, dependency | **Retain** |
| Convert an Oracle schema to PostgreSQL | **AWS SCT** / DMS Schema Conversion |
| Move the rows with minimal downtime | **AWS DMS** (full-load + CDC) |
| Understand which servers talk to which | **AWS Application Discovery Service** |
| Track migration progress in one place | **AWS Migration Hub** |
| Build the business case / TCO | **Migration Evaluator** |
| 500 TB, poor connectivity | **AWS Snow Family** |
| Recurring NFS/SMB → S3/EFS/FSx transfer | **AWS DataSync** |
| Partners upload files over SFTP | **AWS Transfer Family** |
| Keep on-prem file/tape access, store in AWS | **AWS Storage Gateway** |
| Organisational readiness, six perspectives | **AWS Cloud Adoption Framework (CAF)** |
| Funded migration programme with credits | **Migration Acceleration Program (MAP)** |
| Six pillars, design-level best practices | **AWS Well-Architected Framework** (not CAF) |

**The distinction most often missed:** CAF is about **organisational** readiness (business, people, governance, platform, security, operations). Well-Architected is about **workload** design (operational excellence, security, reliability, performance efficiency, cost optimization, sustainability). A question about *executive alignment and skills* is CAF; a question about *how to design this workload* is Well-Architected.

---

## Referencias

**Exam**
- AWS Certified Cloud Practitioner (CLF-C02) Exam Guide — https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf

**Frameworks and strategy**
- AWS Cloud Adoption Framework (overview whitepaper) — https://docs.aws.amazon.com/whitepapers/latest/overview-aws-cloud-adoption-framework/welcome.html
- AWS Well-Architected Framework — https://docs.aws.amazon.com/wellarchitected/latest/framework/welcome.html
- AWS Prescriptive Guidance — Migration strategies — https://docs.aws.amazon.com/prescriptive-guidance/latest/large-migration-migration-strategies/welcome.html
- AWS Prescriptive Guidance — Large migration guide — https://docs.aws.amazon.com/prescriptive-guidance/latest/large-migration-guide/welcome.html
- "Seven strategies to accelerate your application migration to AWS" (AWS Enterprise Strategy Blog) — https://aws.amazon.com/blogs/enterprise-strategy/new-possibilities-seven-strategies-to-accelerate-your-application-migration-to-aws/
- AWS Cloud Migration — https://aws.amazon.com/cloud-migration/
- AWS Migration Acceleration Program (MAP) — https://aws.amazon.com/migration-acceleration-program/

**Assess and track**
- AWS Migration Hub User Guide — https://docs.aws.amazon.com/migrationhub/latest/ug/whatishub.html
- AWS Application Discovery Service User Guide — https://docs.aws.amazon.com/application-discovery/latest/userguide/what-is-appdiscovery.html
- Data Exploration in Amazon Athena (discovery export schema) — https://docs.aws.amazon.com/application-discovery/latest/userguide/explore-data.html
- Migration Evaluator — https://aws.amazon.com/migration-evaluator/
- AWS Migration Hub Refactor Spaces — https://docs.aws.amazon.com/migrationhub-refactor-spaces/latest/userguide/what-is-mhub-refactor-spaces.html

**Server migration (rehost)**
- AWS Application Migration Service User Guide — https://docs.aws.amazon.com/mgn/latest/ug/what-is-application-migration-service.html
- MGN network requirements — https://docs.aws.amazon.com/mgn/latest/ug/Network-Requirements.html
- MGN troubleshooting — https://docs.aws.amazon.com/mgn/latest/ug/troubleshooting-summary.html
- AWS CLI reference — `mgn` — https://docs.aws.amazon.com/cli/latest/reference/mgn/
- CloudFormation `AWS::MGN::ReplicationConfigurationTemplate` — https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-resource-mgn-replicationconfigurationtemplate.html
- CloudFormation `AWS::MGN::LaunchConfigurationTemplate` — https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-resource-mgn-launchconfigurationtemplate.html

**Database migration**
- AWS Database Migration Service User Guide — https://docs.aws.amazon.com/dms/latest/userguide/Welcome.html
- DMS task settings reference — https://docs.aws.amazon.com/dms/latest/userguide/CHAP_Tasks.CustomizingTasks.TaskSettings.html
- DMS table mapping with JSON — https://docs.aws.amazon.com/dms/latest/userguide/CHAP_Tasks.CustomizingTasks.TableMapping.html
- DMS monitoring and CloudWatch metrics — https://docs.aws.amazon.com/dms/latest/userguide/CHAP_Monitoring.html
- DMS data validation — https://docs.aws.amazon.com/dms/latest/userguide/CHAP_Validating.html
- DMS Fleet Advisor — https://docs.aws.amazon.com/dms/latest/userguide/CHAP_FleetAdvisor.html
- AWS Schema Conversion Tool User Guide — https://docs.aws.amazon.com/SchemaConversionTool/latest/userguide/CHAP_Welcome.html
- CloudFormation `AWS::DMS::ReplicationTask` — https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-resource-dms-replicationtask.html

**Data transfer**
- AWS DataSync User Guide — https://docs.aws.amazon.com/datasync/latest/userguide/what-is-datasync.html
- CloudFormation `AWS::DataSync::Task` — https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-resource-datasync-task.html
- AWS Snowball Edge Developer Guide — https://docs.aws.amazon.com/snowball/latest/developer-guide/whatisedge.html
- AWS Snow Family (product page and FAQ — check current device availability here) — https://aws.amazon.com/snow/
- AWS Storage Gateway User Guide — https://docs.aws.amazon.com/storagegateway/latest/userguide/WhatIsStorageGateway.html
- AWS Transfer Family User Guide — https://docs.aws.amazon.com/transfer/latest/userguide/what-is-aws-transfer-family.html

**Cost and sustainability**
- AWS Cost Explorer API — `get-cost-and-usage` — https://docs.aws.amazon.com/aws-cost-management/latest/APIReference/API_GetCostAndUsage.html
- AWS Customer Carbon Footprint Tool — https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/what-is-ccft.html