# 2.1 — Understand the AWS Shared Responsibility Model

**Certification:** AWS Certified Cloud Practitioner (CLF-C02) · **Domain 2 — Security and Compliance** · **Topic weight: 7.5**

**Task statement coverage (CLF-C02 exam guide):** recognize the components of the shared responsibility model; describe customer responsibilities and how they *shift* depending on the service consumed (EC2 vs. RDS vs. Lambda); describe AWS responsibilities; describe shared controls.

---

## 1. Motivation: the architectural problem this model exists to solve

### 1.1 The failure that has no owner

Take a real production topology: an internet-facing ALB, an Auto Scaling group of `m6i.large` instances running Amazon Linux 2023, an Aurora PostgreSQL cluster, and an S3 bucket holding customer exports. Now enumerate everything that must be patched, configured, monitored, encrypted, backed up and audited for that stack to be *safe*:

| Layer | Example artifact | Who fixes a CVE here? |
|---|---|---|
| Datacenter power / physical access | UPS, biometric mantrap | AWS |
| Server firmware / BMC | Nitro card firmware | AWS |
| Hypervisor / Nitro hypervisor | VM escape class bug | AWS |
| Guest OS kernel | `CVE-2024-XXXX` in `kernel-6.1` | **You** |
| Language runtime on the instance | OpenSSL, glibc, JVM | **You** |
| Application dependencies | `log4j`, `requests`, `openssl-sys` | **You** |
| Aurora storage layer | Replication bug across the 6 copies | AWS |
| PostgreSQL engine binary | Engine minor version patch | AWS (applied in **your** maintenance window) |
| Database schema, roles, `pg_hba`-equivalent | `GRANT ALL TO PUBLIC` | **You** |
| S3 durability | Disk failure, bit rot | AWS |
| S3 bucket policy / Block Public Access | Public `GetObject` to `*` | **You** |
| IAM role trust policy | `sts:AssumeRole` from `"AWS": "*"` | **You** |

Every row above is a plausible incident. Only some of them page *you*. The shared responsibility model is the **contractual and operational boundary function** that tells you, before the incident, which pager fires and which evidence you are allowed to collect.

An SRE-grade restatement:

> The shared responsibility model is not a security poster. It is a **partition of the control plane**. AWS owns everything below its published API surface; you own every state transition you can express *through* that API. Where the API exposes a knob, the knob is yours — including its default.

### 1.2 Why "the default is yours" is the expensive half

The dominant class of cloud breach is not a hypervisor escape. It is a customer-side misconfiguration reachable through a perfectly healthy AWS API:

- An IAM role attached to an EC2 instance with `s3:*` on `*`, plus an SSRF-able application → Instance Metadata Service v1 credential exfiltration → bulk object read. Every AWS component behaved to spec.
- A bucket policy with `"Principal": "*"` on a bucket exempted from Block Public Access.
- A security group opened to `0.0.0.0/0:22` "temporarily" during an incident and never closed.
- A Lambda function with a three-year-old vendored dependency. AWS patched the runtime OS and the Python interpreter; nobody patched your `site-packages`.

None of these are AWS failures, and — critically — **AWS will not stop you**. The API accepts the call, CloudTrail records it, and the resource enters an insecure state. Your job as a platform architect is to convert the model from prose into **enforced, verifiable code**: SCPs that make the bad state unrepresentable, Config rules that detect drift, and Security Hub/Inspector to close the loop.

### 1.3 The asymmetry of evidence

There is a second, less obvious consequence. Responsibility and *verifiability* are not the same thing:

| | Your half | AWS's half |
|---|---|---|
| Can you observe it directly? | Yes — CloudTrail, Config, VPC Flow Logs, CloudWatch, Inspector | **No** — you cannot audit a Region |
| Verification mechanism | Continuous telemetry, point-in-time queries | **Third-party attestation** (SOC 1/2/3, ISO 27001/27017/27018, PCI DSS AOC, FedRAMP) retrieved from **AWS Artifact** |
| Failure detection latency | Seconds to minutes | Report cadence (typically annual/semi-annual) + **AWS Health** for operational events |
| Remediation actor | You (SSM, IaC, pipeline) | AWS SRE, opaque to you |

This is why AWS Artifact exists and why it is examinable: on AWS's side of the line, **auditing is replaced by consuming attestation**. Your auditor does not inspect an AWS datacenter; your auditor reads the SOC 2 Type II report you downloaded and scopes it *out* of your assessment. That is called **control inheritance**.

---

## 2. The formal model

### 2.1 The two halves

```
                    ┌──────────────────────────────────────────────────┐
                    │  CUSTOMER DATA                                   │
                    ├──────────────────────────────────────────────────┤
  SECURITY  ★IN★    │  PLATFORM, APPLICATIONS, IAM                     │
  THE CLOUD         ├──────────────────────────────────────────────────┤
  (CUSTOMER)        │  OS, NETWORK & FIREWALL CONFIGURATION            │
                    ├───────────────┬───────────────┬──────────────────┤
                    │ CLIENT-SIDE   │ SERVER-SIDE   │ NETWORKING       │
                    │ ENCRYPTION &  │ ENCRYPTION    │ TRAFFIC          │
                    │ DATA          │ (FILE SYSTEM  │ PROTECTION       │
                    │ INTEGRITY     │  AND/OR DATA) │ (ENCRYPTION,     │
                    │ AUTHENTICATION│               │  INTEGRITY,      │
                    │               │               │  IDENTITY)       │
╔═══════════════════╪═══════════════╧═══════════════╧══════════════════╡
║                   │  SOFTWARE                                        │
║  SECURITY ★OF★    ├──────────┬──────────┬──────────┬─────────────────┤
║  THE CLOUD        │ COMPUTE  │ STORAGE  │ DATABASE │ NETWORKING      │
║  (AWS)            ├──────────┴──────────┴──────────┴─────────────────┤
║                   │  HARDWARE / AWS GLOBAL INFRASTRUCTURE            │
║                   ├──────────────┬─────────────────┬─────────────────┤
║                   │   REGIONS    │ AVAILABILITY    │ EDGE LOCATIONS  │
║                   │              │ ZONES           │                 │
╚═══════════════════╧══════════════╧═════════════════╧═════════════════╡
```

**AWS — "Security *of* the Cloud":** the global infrastructure (Regions, Availability Zones, Edge Locations), the physical facilities and their environmental controls, the host hardware and firmware, the Nitro hypervisor and Nitro cards, the physical network fabric, the decommissioning and media destruction process (NIST 800-88), and the software of managed services (the S3 control plane, the Aurora storage layer, the Lambda execution environment, the EKS control plane).

**Customer — "Security *in* the Cloud":** your data and its classification; identity and access management (IAM users, roles, policies, federation, MFA, root account custody); guest operating systems and their patching; application code and dependencies; network configuration (VPC design, subnets, route tables, security groups, NACLs, Network Firewall rules); encryption choices (which data, which key, client- or server-side); and the resilience architecture you build on top of the AZ primitives AWS provides.

### 2.2 The three control classes (frequently examined)

| Control class | Definition | Concrete examples | Who acts |
|---|---|---|---|
| **Inherited controls** | Controls the customer fully inherits from AWS; the customer does nothing and claims them in an audit via Artifact | Physical and environmental controls: datacenter access, fire suppression, power redundancy, media destruction | AWS only |
| **Shared controls** | The control applies to *both* infrastructure and customer layers; **same control objective, different implementation, two separate executions** | **Patch management** (AWS patches host/hypervisor/managed-service software; you patch guest OS and apps) · **Configuration management** (AWS configures infrastructure devices; you configure your OS, DBs, apps) · **Awareness & training** (AWS trains AWS staff; you train your staff) | Both, independently |
| **Customer-specific controls** | Controls entirely on the customer side, driven by the workload's data classification and regulatory scope | Zone security / data-zone segmentation, application-level authorization, tokenization, routing customer PII to specific Regions for data residency | Customer only |

> **Exam trap:** "shared control" does **not** mean "AWS and the customer collaborate on one instance of the control." It means the control objective exists on both sides and each party executes its own copy. AWS patching the Nitro hypervisor does nothing for your unpatched `openssl`.

### 2.3 What is *never* shared

Two items are permanently and exclusively customer-owned, regardless of service:

1. **Your data.** AWS does not classify it, does not decide its retention, and does not decide who may read it.
2. **Identity.** The root user credentials, MFA device custody, IAM principal design, and every `Allow` you write.

And one is permanently AWS-owned: **the physical layer**. You cannot inspect it, and no service model ever transfers it — with the single documented exception discussed in §4.7 (Outposts, where *site* security returns to you while the *hardware* stays AWS's).

---

## 3. The abstraction gradient: responsibility shifts with the service

This is the highest-yield concept in the topic. The CLF-C02 guide explicitly calls out "how the customer's responsibilities may shift depending on the service used (for example, with RDS, Lambda, EC2)."

AWS's own security taxonomy splits services into three families:

| Family | Definition | Examples | You manage | AWS manages |
|---|---|---|---|---|
| **Infrastructure services** (IaaS) | You get raw compute/storage/network primitives and full OS control | EC2, EBS, VPC, Auto Scaling, Elastic Load Balancing (data plane you configure) | Guest OS, patching, agents, firewall rules, encryption of EBS/instance store, IAM, application | Hypervisor, host, physical network, storage media, facility |
| **Container services** (PaaS-like; *not* Docker) | A managed platform runs a well-known engine; you never log into the OS | RDS, Aurora, ElastiCache, EMR, Elastic Beanstalk, OpenSearch Service | Engine configuration (parameter/option groups), users & schemas, network placement, encryption *choice*, backups retention policy, major version upgrades | OS, engine binaries, minor patching, replication, host, facility |
| **Abstracted services** (serverless / fully managed) | You interact only with a service API endpoint; no host concept at all | S3, DynamoDB, SQS, SNS, Lambda, Athena, Glue, Kinesis | Data, IAM/resource policies, encryption key selection, your code and its dependencies | Everything below the API: OS, runtime, scaling, durability, multi-AZ placement |

### 3.1 Responsibility matrix across compute models

| Responsibility | EC2 | ECS on EC2 | ECS/EKS on Fargate | EKS (control plane) | Lambda | RDS/Aurora | S3 |
|---|---|---|---|---|---|---|---|
| Physical / facility | AWS | AWS | AWS | AWS | AWS | AWS | AWS |
| Hypervisor / Nitro | AWS | AWS | AWS | AWS | AWS | AWS | AWS |
| Host OS kernel | AWS | AWS | AWS | AWS | AWS | AWS | AWS |
| **Guest OS / node AMI patching** | **You** | **You** | AWS (platform version) | n/a (control plane) | AWS | AWS (in your window) | AWS |
| **Node reboot / drain to apply patch** | **You** | **You** | **You** (redeploy task) | AWS | AWS | **You** (window choice) | AWS |
| Container runtime (`containerd`) | **You** | **You** | AWS | n/a | AWS | n/a | n/a |
| Kubernetes control plane (`etcd`, apiserver) | n/a | n/a | n/a | AWS | n/a | n/a | n/a |
| **Kubernetes version upgrade trigger** | n/a | n/a | n/a | **You** | n/a | n/a | n/a |
| Container image contents / base image CVEs | **You** | **You** | **You** | **You** | **You** | n/a | n/a |
| Application code | **You** | **You** | **You** | **You** | **You** | n/a | n/a |
| Application dependencies | **You** | **You** | **You** | **You** | **You** | n/a | n/a |
| Language runtime / interpreter | **You** | **You** | **You** | **You** | AWS | n/a | n/a |
| **Runtime deprecation migration** | **You** | **You** | **You** | **You** | **You** | **You** (major version) | n/a |
| Network segmentation (SG/NACL/NetworkPolicy) | **You** | **You** | **You** | **You** | **You** (VPC config) | **You** | **You** (policy/VPCE) |
| IAM / resource policy | **You** | **You** | **You** | **You** | **You** | **You** | **You** |
| Kubernetes RBAC / admission | n/a | n/a | n/a | **You** | n/a | n/a | n/a |
| Encryption at rest — *enablement* | **You** | **You** | **You** | **You** (secrets) | AWS default + **you** (CMK) | **You** (at creation) | AWS default + **you** (CMK) |
| Encryption in transit — *enforcement* | **You** | **You** | **You** | **You** | **You** | **You** (`rds.force_ssl`) | **You** (`aws:SecureTransport`) |
| Durability of stored bytes | AWS (EBS) | AWS | AWS | AWS | AWS | AWS | AWS |
| **Backup / point-in-time recovery policy** | **You** | **You** | **You** | **You** | **You** | **You** (retention) | **You** (versioning) |
| Multi-AZ / multi-Region topology | **You** | **You** | **You** | AWS (CP) / **you** (nodes) | AWS | **You** (Multi-AZ flag) | AWS (within Region) |

Read this matrix as a **derivative**: as you move right, your surface area shrinks but never reaches zero. There is no AWS service for which you have no responsibility, because the two permanent customer items — **data** and **identity** — are present in every column.

### 3.2 Trade-off analysis: what you buy by moving right

| Dimension | EC2 (IaaS) | RDS (managed platform) | Lambda / S3 (abstracted) |
|---|---|---|---|
| Operational burden | Highest: AMI pipeline, patch windows, agents, config management | Medium: version strategy, parameter groups, failover testing | Lowest: IAM + code |
| Control / flexibility | Total: any kernel, any daemon, any tuning | Bounded: only exposed parameters; no `sudo`, no OS access | Minimal: runtime and limits only |
| Blast radius of *your* mistake | Whole instance and everything it can reach | Database contents and connectivity | Scoped to the function/bucket + its role |
| Blast radius of *AWS's* mistake | Host/AZ-level, mitigated by your ASG | AZ-level, mitigated by Multi-AZ | Absorbed by AWS internally |
| Compliance evidence you must produce | OS hardening (CIS), patch compliance reports, vuln scans, AV/EDR if required | Engine config, encryption, access logs, backup evidence | IAM policy review, key policy, access logs |
| Time-to-remediate a critical CVE | Hours–days (rebuild AMI, roll ASG) | Minutes–hours (AWS ships patch; you choose window) | AWS-side is invisible; **your dependency** is still hours–days |
| Cost model | Reserved capacity; you pay for idle | Instance-hours + storage | Per-request/per-GB; near-zero idle |
| **Portability / lock-in** | Highest portability | Medium (engine-compatible) | Lowest portability |
| Where the residual risk concentrates | Guest OS drift | Version upgrade debt (majors EOL) | **Dependency supply chain** |

**Architect's judgment:** moving right does not reduce total risk; it **relocates** it. Teams that migrate EC2 → Lambda and then never scan dependencies have traded a well-understood, tooled risk (OS patching, which Patch Manager and Inspector solve) for a poorly-instrumented one (transitive package CVEs). Instrument the new half before you decommission the old one.

---

## 4. Service-by-service boundary deep dives

### 4.1 EC2 — the reference case for IaaS

The line sits at the **virtual hardware interface**. AWS delivers a booted virtual machine with virtual CPU, memory, NICs and block devices, plus the metadata service at `169.254.169.254`. Everything from the boot loader upward is yours.

Modern AWS instances run on the **Nitro System**: dedicated hardware cards offload networking, EBS and storage, and the Nitro Security Chip locks down firmware. AWS's documented design property is that there is **no interactive operator access to Nitro hosts** — a key control you *inherit* and reference in audits, and one you can only verify through attestation, never directly.

Your non-negotiable EC2 responsibilities:

- Guest OS patching (see §6.2 — Patch Manager).
- **IMDSv2 enforcement** (`HttpTokens: required`). IMDSv1's simple GET is the pivot in the SSRF→credential-theft chain. This is 100% your side of the line; AWS ships the capability, you must require it.
- EBS encryption. Enable **account-level EBS encryption by default** per Region — it is off unless you turn it on.
- Security groups and NACLs.
- Agents: SSM Agent (bundled in Amazon Linux/recent Ubuntu AMIs, but the **IAM role is yours**), CloudWatch Agent, EDR.
- **Third-party and community AMIs**: vetting a Marketplace or public AMI is entirely yours. AWS does not audit the contents of a community AMI.

### 4.2 ECS / EKS / Fargate — three different lines in one product family

- **ECS on EC2 / EKS self-managed or managed node groups:** the nodes are EC2 instances. You own the AMI, the kernel, `containerd`, and the node lifecycle. EKS *managed* node groups automate the rolling replacement, but **you must initiate it**.
- **Fargate:** AWS owns the host and the runtime. The subtlety that catches SREs: a **Fargate platform version update does not retroactively patch a running task**. Existing tasks keep the platform version they launched with. You must force a new deployment to pick up the patched platform. AWS patched; you must redeploy. That is a shared control in its purest form.
- **EKS control plane:** AWS runs and patches `kube-apiserver`, `etcd`, the scheduler and controller manager across multiple AZs. You own **Kubernetes RBAC**, Pod Security Admission, admission webhooks, `NetworkPolicy`, secrets encryption (KMS envelope encryption for `etcd` secrets), IRSA/Pod Identity role design, and — critically — **triggering the Kubernetes minor version upgrade** before your version leaves standard support.

### 4.3 RDS / Aurora — the managed-platform boundary

AWS gives you: OS management, engine binary installation, **minor** version patching, automated backup mechanics, Multi-AZ failover automation, and the Aurora distributed storage layer (six copies across three AZs).

You keep, and are commonly caught missing:

| Item | Reality |
|---|---|
| Encryption at rest | **Must be chosen at cluster/instance creation.** You cannot toggle it on an existing unencrypted instance — you restore a snapshot into a new encrypted instance. |
| Encryption in transit | Not enforced by default on most engines. You set `rds.force_ssl=1` (PostgreSQL) / `require_secure_transport=ON` (MySQL) in a **custom parameter group** — the default parameter group is not editable. |
| Maintenance window | AWS *has* the patch; **you** decide when it lands. Deferring indefinitely is your risk. |
| Minor version auto-upgrade | A flag (`AutoMinorVersionUpgrade`) you set. |
| **Major version upgrade** | Entirely yours. An engine reaching end-of-standard-support and rolling into paid extended support is a customer failure, not an AWS one. |
| Database users, roles, `GRANT`s | Yours. AWS creates only the master user you name. |
| Network exposure | `PubliclyAccessible`, subnet group, security groups — all yours. |
| Backup retention & PITR window | Yours. Retention `0` disables automated backups. |
| Deletion protection | Yours. |

### 4.4 Lambda — abstracted, but not responsibility-free

AWS owns: the Firecracker microVM, the host, the execution environment OS, the **managed runtime** (interpreter/JVM), scaling, and multi-AZ placement.

You own:

- **Your code and every dependency you package.** AWS patches Python 3.12; AWS does not patch your vendored `urllib3`. Amazon Inspector supports Lambda code and package scanning precisely because this gap is real.
- **Runtime deprecation.** When a runtime reaches end of support, migration is your work.
- The **execution role** — the single most abused Lambda control. `AdministratorAccess` on a function is a customer-side critical.
- VPC attachment, subnets, security groups when the function needs private access.
- Environment variable secrets: Lambda encrypts them at rest with a KMS key, but putting a plaintext credential where any `lambda:GetFunctionConfiguration` caller can read it is yours.
- Concurrency limits (a DoS/cost control), timeouts, and dead-letter/on-failure destinations.

### 4.5 S3 — where defaults changed, and why it still matters

AWS provides 99.999999999% (11 nines) design durability, automatic replication across ≥3 AZs in the Region, and, since January 2023, **SSE-S3 encryption applied by default to all new objects**. Since April 2023, new buckets have **S3 Block Public Access enabled** and **ACLs disabled** (Object Ownership = *Bucket owner enforced*) by default.

You still own:

- **Turning those defaults off.** They are defaults, not guardrails. An SCP is the guardrail (§6.4).
- Bucket policies and access points.
- **Versioning, MFA Delete, Object Lock** — because durability is not the same as *undelete*. AWS will faithfully and durably store the result of your `DeleteObject`. Protection against your own delete is a customer control.
- Choosing SSE-KMS with a customer managed key when you need key-policy-level access control and CloudTrail visibility of key usage.
- Enforcing TLS (`aws:SecureTransport`) and restricting network path (VPC endpoints, `aws:SourceVpce`).
- Lifecycle policies and cross-Region replication for your RTO/RPO — not AWS's.

### 4.6 KMS — key material vs. key policy

AWS operates FIPS-validated HSMs, guarantees that plaintext key material for AWS-managed and customer-managed KMS keys never leaves the HSM boundary unencrypted, and handles HSM durability and multi-AZ availability.

You own: **the key policy** (the only mandatory authorization document for a KMS key — an IAM policy alone cannot grant access unless the key policy delegates to IAM), grants, aliases, rotation configuration, deletion scheduling (the 7–30 day waiting period is your last line of defence), and multi-Region key topology.

### 4.7 Outposts, Local Zones, Wavelength — the boundary moves

**AWS Outposts** is the one place the physical layer partially returns to you:

| Item | Owner |
|---|---|
| Rack hardware, firmware, break/fix, capacity | AWS (AWS technicians visit your site) |
| **Physical site security, access control to the rack** | **You** |
| Power, cooling, floor space | **You** |
| Network connectivity to the parent Region (service link) | **You** (the circuit) / AWS (the tunnel) |
| Data on the Outpost | **You** |
| Encryption: the Nitro Security Key | **You** must retain it; removing it renders local data unreadable |

For **Local Zones** and **Wavelength Zones**, AWS remains responsible for physical security even though the equipment sits in a colocation or telecom carrier facility.

---

## 5. Shared responsibility for resilience and availability

AWS publishes a parallel model for resiliency. It is examinable in disguise: questions phrased as "the application went down when an AZ failed — who is responsible?"

| Concern | AWS responsibility | Customer responsibility |
|---|---|---|
| AZ independence (power, cooling, network, flood plain) | **AWS** | — |
| Region and AZ availability | **AWS** | — |
| Managed-service internal redundancy (S3, DynamoDB, Lambda, Aurora storage) | **AWS** | — |
| **Deploying across ≥2 AZs** | Provides the primitive | **You** must architect for it |
| Multi-Region DR | Provides the primitives (Route 53, Global Tables, CRR) | **You** design RTO/RPO |
| Health checks and failover configuration | — | **You** |
| Backups and restore *testing* | Runs the backup machinery you enable | **You** enable, retain, **and test the restore** |
| Capacity / service quotas | Publishes quotas | **You** monitor and request increases |
| Graceful degradation, retries, exponential backoff, idempotency | — | **You** |

Two hard truths for architects:

1. **An SLA is a billing instrument, not an availability guarantee.** The Amazon Compute SLA offers 99.99% monthly uptime at the *Region level* (multi-AZ) but only 99.5% at the *instance level*; S3 Standard's SLA is 99.9%. Breaching it yields **service credits**, tiered by severity. A 100% credit on a $4,000 monthly bill does not compensate a revenue-bearing outage. Availability is engineered by you; the SLA merely prices AWS's miss.
2. **A single-AZ deployment that dies with its AZ is a customer failure**, even though the AZ failure was AWS's. AWS met its obligation by offering three or more independent AZs; you declined to use them.

---

## 6. Encoding the boundary as infrastructure

Prose does not enforce anything. Below are complete, deployable artifacts that implement the customer half.

### 6.1 Hardened data plane — S3 + KMS (`shared-responsibility-data-plane.yaml`)

```yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: >
  Customer-side controls for the "security IN the cloud" half of the shared
  responsibility model: customer managed KMS key, encrypted and versioned data
  bucket with Object Lock, dedicated server access log bucket, and a resource
  policy enforcing TLS and the intended KMS key.

Parameters:
  DataClassification:
    Type: String
    Default: confidential
    AllowedValues: [public, internal, confidential, restricted]
    Description: Drives retention and is stamped on every resource as a tag.
  RetentionDays:
    Type: Number
    Default: 30
    MinValue: 1
    MaxValue: 3650
    Description: Default Object Lock retention in GOVERNANCE mode.
  LogRetentionDays:
    Type: Number
    Default: 400
    MinValue: 1
    MaxValue: 3650
  AllowedVpcEndpointId:
    Type: String
    Default: ''
    Description: >
      Optional VPC endpoint id (vpce-xxxx). When provided, all access to the
      data bucket is restricted to that endpoint.

Conditions:
  RestrictToVpce: !Not [!Equals [!Ref AllowedVpcEndpointId, '']]

Resources:

  ##########################################################################
  # Customer managed key. AWS owns the HSM; the key POLICY below is ours.
  ##########################################################################
  DataKey:
    Type: AWS::KMS::Key
    DeletionPolicy: Retain
    UpdateReplacePolicy: Retain
    Properties:
      Description: !Sub 'CMK for ${AWS::StackName} ${DataClassification} data at rest'
      Enabled: true
      EnableKeyRotation: true
      KeySpec: SYMMETRIC_DEFAULT
      KeyUsage: ENCRYPT_DECRYPT
      MultiRegion: false
      PendingWindowInDays: 30
      KeyPolicy:
        Version: '2012-10-17'
        Id: data-key-policy
        Statement:
          - Sid: EnableIAMPolicyDelegation
            Effect: Allow
            Principal:
              AWS: !Sub 'arn:${AWS::Partition}:iam::${AWS::AccountId}:root'
            Action: 'kms:*'
            Resource: '*'
          - Sid: AllowS3ServiceUseWithinThisAccount
            Effect: Allow
            Principal:
              Service: s3.amazonaws.com
            Action:
              - kms:Decrypt
              - kms:GenerateDataKey
              - kms:DescribeKey
            Resource: '*'
            Condition:
              StringEquals:
                'kms:CallerAccount': !Ref AWS::AccountId
                'kms:ViaService': !Sub 's3.${AWS::Region}.amazonaws.com'
          - Sid: DenyKeyDeletionOutsideBreakGlass
            Effect: Deny
            Principal: '*'
            Action:
              - kms:ScheduleKeyDeletion
              - kms:DisableKey
            Resource: '*'
            Condition:
              StringNotLike:
                'aws:PrincipalArn': !Sub 'arn:${AWS::Partition}:iam::${AWS::AccountId}:role/BreakGlassAdmin'
      Tags:
        - Key: DataClassification
          Value: !Ref DataClassification
        - Key: ResponsibilityBoundary
          Value: customer

  DataKeyAlias:
    Type: AWS::KMS::Alias
    Properties:
      AliasName: !Sub 'alias/${AWS::StackName}-data'
      TargetKeyId: !Ref DataKey

  ##########################################################################
  # Server access log bucket. Must exist before the data bucket references it.
  ##########################################################################
  AccessLogBucket:
    Type: AWS::S3::Bucket
    DeletionPolicy: Retain
    UpdateReplacePolicy: Retain
    Properties:
      BucketName: !Sub '${AWS::StackName}-access-logs-${AWS::AccountId}-${AWS::Region}'
      # S3 server access logging cannot write to an SSE-KMS bucket; SSE-S3 only.
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
      VersioningConfiguration:
        Status: Enabled
      LifecycleConfiguration:
        Rules:
          - Id: expire-access-logs
            Status: Enabled
            ExpirationInDays: !Ref LogRetentionDays
            NoncurrentVersionExpiration:
              NoncurrentDays: 30
          - Id: abort-incomplete-mpu
            Status: Enabled
            AbortIncompleteMultipartUpload:
              DaysAfterInitiation: 7
      Tags:
        - Key: ResponsibilityBoundary
          Value: customer

  AccessLogBucketPolicy:
    Type: AWS::S3::BucketPolicy
    Properties:
      Bucket: !Ref AccessLogBucket
      PolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Sid: AllowS3ServerAccessLogging
            Effect: Allow
            Principal:
              Service: logging.s3.amazonaws.com
            Action: 's3:PutObject'
            Resource: !Sub '${AccessLogBucket.Arn}/s3-access/*'
            Condition:
              StringEquals:
                'aws:SourceAccount': !Ref AWS::AccountId
          - Sid: DenyInsecureTransport
            Effect: Deny
            Principal: '*'
            Action: 's3:*'
            Resource:
              - !GetAtt AccessLogBucket.Arn
              - !Sub '${AccessLogBucket.Arn}/*'
            Condition:
              Bool:
                'aws:SecureTransport': 'false'

  ##########################################################################
  # Data bucket.
  ##########################################################################
  DataBucket:
    Type: AWS::S3::Bucket
    DeletionPolicy: Retain
    UpdateReplacePolicy: Retain
    DependsOn: AccessLogBucketPolicy
    Properties:
      BucketName: !Sub '${AWS::StackName}-data-${AWS::AccountId}-${AWS::Region}'
      BucketEncryption:
        ServerSideEncryptionConfiguration:
          - ServerSideEncryptionByDefault:
              SSEAlgorithm: 'aws:kms'
              KMSMasterKeyID: !GetAtt DataKey.Arn
            # S3 Bucket Keys cut KMS API calls (and cost) by ~99%.
            BucketKeyEnabled: true
      PublicAccessBlockConfiguration:
        BlockPublicAcls: true
        BlockPublicPolicy: true
        IgnorePublicAcls: true
        RestrictPublicBuckets: true
      OwnershipControls:
        Rules:
          - ObjectOwnership: BucketOwnerEnforced
      # Object Lock requires versioning to be enabled at creation time.
      VersioningConfiguration:
        Status: Enabled
      ObjectLockEnabled: true
      ObjectLockConfiguration:
        ObjectLockEnabled: Enabled
        Rule:
          DefaultRetention:
            Mode: GOVERNANCE
            Days: !Ref RetentionDays
      LoggingConfiguration:
        DestinationBucketName: !Ref AccessLogBucket
        LogFilePrefix: 's3-access/'
      LifecycleConfiguration:
        Rules:
          - Id: transition-cold
            Status: Enabled
            Transitions:
              - StorageClass: INTELLIGENT_TIERING
                TransitionInDays: 30
            NoncurrentVersionTransitions:
              - StorageClass: GLACIER_IR
                TransitionInDays: 30
          - Id: abort-incomplete-mpu
            Status: Enabled
            AbortIncompleteMultipartUpload:
              DaysAfterInitiation: 7
      Tags:
        - Key: DataClassification
          Value: !Ref DataClassification
        - Key: ResponsibilityBoundary
          Value: customer

  DataBucketPolicy:
    Type: AWS::S3::BucketPolicy
    Properties:
      Bucket: !Ref DataBucket
      PolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Sid: DenyInsecureTransport
            Effect: Deny
            Principal: '*'
            Action: 's3:*'
            Resource:
              - !GetAtt DataBucket.Arn
              - !Sub '${DataBucket.Arn}/*'
            Condition:
              Bool:
                'aws:SecureTransport': 'false'
          - Sid: DenyOutdatedTLS
            Effect: Deny
            Principal: '*'
            Action: 's3:*'
            Resource:
              - !GetAtt DataBucket.Arn
              - !Sub '${DataBucket.Arn}/*'
            Condition:
              NumericLessThan:
                's3:TlsVersion': '1.2'
          # NOTE: we deny only an EXPLICIT WRONG key, never a MISSING header.
          # Bucket default encryption is applied AFTER policy evaluation, so a
          # StringNotEquals on s3:x-amz-server-side-encryption would reject
          # perfectly valid header-less PUTs. See the diagnostics section.
          - Sid: DenyWrongKmsKey
            Effect: Deny
            Principal: '*'
            Action: 's3:PutObject'
            Resource: !Sub '${DataBucket.Arn}/*'
            Condition:
              StringNotEqualsIfExists:
                's3:x-amz-server-side-encryption-aws-kms-key-id': !GetAtt DataKey.Arn
              'Null':
                's3:x-amz-server-side-encryption-aws-kms-key-id': 'false'
          - !If
            - RestrictToVpce
            - Sid: RestrictToNamedVpcEndpoint
              Effect: Deny
              Principal: '*'
              Action: 's3:*'
              Resource:
                - !GetAtt DataBucket.Arn
                - !Sub '${DataBucket.Arn}/*'
              Condition:
                StringNotEquals:
                  'aws:SourceVpce': !Ref AllowedVpcEndpointId
                ArnNotLike:
                  'aws:PrincipalArn': !Sub 'arn:${AWS::Partition}:iam::${AWS::AccountId}:role/BreakGlassAdmin'
            - !Ref AWS::NoValue

Outputs:
  DataBucketName:
    Description: Bucket holding customer data (customer responsibility).
    Value: !Ref DataBucket
    Export:
      Name: !Sub '${AWS::StackName}-DataBucketName'
  DataBucketArn:
    Value: !GetAtt DataBucket.Arn
  AccessLogBucketName:
    Value: !Ref AccessLogBucket
  DataKeyArn:
    Description: CMK ARN. AWS operates the HSM; we own this key policy.
    Value: !GetAtt DataKey.Arn
    Export:
      Name: !Sub '${AWS::StackName}-DataKeyArn'
  DataKeyAliasName:
    Value: !Ref DataKeyAlias
```

### 6.2 The shared control made concrete — Patch Manager (`shared-responsibility-patching.yaml`)

Patch management is *the* canonical shared control. AWS patches the hypervisor; this template patches your half, on a schedule, with compliance reporting.

```yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: >
  Customer half of the "patch management" shared control: a custom patch
  baseline, a patch group, a maintenance window that runs AWS-RunPatchBaseline,
  an instance profile with the SSM managed policy, and Config rules that prove
  the control is working.

Parameters:
  PatchGroupName:
    Type: String
    Default: prod-linux
  ApproveAfterDays:
    Type: Number
    Default: 7
    MinValue: 0
    MaxValue: 100
    Description: Soak period before an approved patch is installed.
  MaintenanceCron:
    Type: String
    Default: 'cron(0 3 ? * SUN *)'
    Description: UTC schedule for the patching window.
  MaintenanceDurationHours:
    Type: Number
    Default: 4
  MaintenanceCutoffHours:
    Type: Number
    Default: 1
  MaxConcurrency:
    Type: String
    Default: '20%'
  MaxErrors:
    Type: String
    Default: '5%'
  RebootOption:
    Type: String
    Default: RebootIfNeeded
    AllowedValues: [RebootIfNeeded, NoReboot]

Resources:

  ##########################################################################
  # Where patch logs land. Retained as audit evidence for the shared control.
  ##########################################################################
  PatchLogBucket:
    Type: AWS::S3::Bucket
    DeletionPolicy: Retain
    UpdateReplacePolicy: Retain
    Properties:
      BucketName: !Sub '${AWS::StackName}-patch-logs-${AWS::AccountId}-${AWS::Region}'
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
      VersioningConfiguration:
        Status: Enabled
      LifecycleConfiguration:
        Rules:
          - Id: retain-patch-evidence
            Status: Enabled
            ExpirationInDays: 400

  ##########################################################################
  # Custom patch baseline. The DEFAULT AWS baseline auto-approves security
  # updates with 0 days soak; production usually wants a soak period.
  ##########################################################################
  LinuxPatchBaseline:
    Type: AWS::SSM::PatchBaseline
    Properties:
      Name: !Sub '${AWS::StackName}-al2023-baseline'
      Description: Amazon Linux 2023 security + bugfix baseline with soak period.
      OperatingSystem: AMAZON_LINUX_2023
      ApprovedPatchesComplianceLevel: CRITICAL
      ApprovedPatchesEnableNonSecurity: false
      RejectedPatchesAction: BLOCK
      RejectedPatches:
        # Example: a kernel build known to break a vendor driver. Documented,
        # time-boxed exceptions only - this is technical debt with a CVE.
        - 'kernel-6.1.72-96.166.amzn2023'
      ApprovalRules:
        PatchRules:
          - ComplianceLevel: CRITICAL
            ApproveAfterDays: 0
            EnableNonSecurity: false
            PatchFilterGroup:
              PatchFilters:
                - Key: CLASSIFICATION
                  Values: ['Security']
                - Key: SEVERITY
                  Values: ['Critical']
          - ComplianceLevel: HIGH
            ApproveAfterDays: !Ref ApproveAfterDays
            EnableNonSecurity: false
            PatchFilterGroup:
              PatchFilters:
                - Key: CLASSIFICATION
                  Values: ['Security']
                - Key: SEVERITY
                  Values: ['Important', 'Medium']
          - ComplianceLevel: MEDIUM
            ApproveAfterDays: 30
            EnableNonSecurity: true
            PatchFilterGroup:
              PatchFilters:
                - Key: CLASSIFICATION
                  Values: ['Bugfix']
      PatchGroups:
        - !Ref PatchGroupName
      Tags:
        - Key: ResponsibilityBoundary
          Value: customer-shared-control

  ##########################################################################
  # Instance profile: without this role, SSM cannot reach the instance and
  # your half of the patch control silently does not run.
  ##########################################################################
  ManagedInstanceRole:
    Type: AWS::IAM::Role
    Properties:
      RoleName: !Sub '${AWS::StackName}-managed-instance'
      AssumeRolePolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Effect: Allow
            Principal:
              Service: ec2.amazonaws.com
            Action: 'sts:AssumeRole'
      ManagedPolicyArns:
        - !Sub 'arn:${AWS::Partition}:iam::aws:policy/AmazonSSMManagedInstanceCore'
      Policies:
        - PolicyName: patch-log-write
          PolicyDocument:
            Version: '2012-10-17'
            Statement:
              - Effect: Allow
                Action:
                  - 's3:PutObject'
                  - 's3:PutObjectAcl'
                Resource: !Sub '${PatchLogBucket.Arn}/*'
              - Effect: Allow
                Action: 's3:GetEncryptionConfiguration'
                Resource: !GetAtt PatchLogBucket.Arn

  ManagedInstanceProfile:
    Type: AWS::IAM::InstanceProfile
    Properties:
      InstanceProfileName: !Sub '${AWS::StackName}-managed-instance'
      Roles:
        - !Ref ManagedInstanceRole

  ##########################################################################
  # Maintenance window.
  ##########################################################################
  MaintenanceWindowRole:
    Type: AWS::IAM::Role
    Properties:
      RoleName: !Sub '${AWS::StackName}-maintenance-window'
      AssumeRolePolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Effect: Allow
            Principal:
              Service: ssm.amazonaws.com
            Action: 'sts:AssumeRole'
      ManagedPolicyArns:
        - !Sub 'arn:${AWS::Partition}:iam::aws:policy/service-role/AmazonSSMMaintenanceWindowRole'

  PatchWindow:
    Type: AWS::SSM::MaintenanceWindow
    Properties:
      Name: !Sub '${AWS::StackName}-patch-window'
      Description: Weekly guest OS patching - customer side of the shared control.
      Schedule: !Ref MaintenanceCron
      ScheduleTimezone: 'UTC'
      Duration: !Ref MaintenanceDurationHours
      Cutoff: !Ref MaintenanceCutoffHours
      AllowUnassociatedTargets: false

  PatchWindowTarget:
    Type: AWS::SSM::MaintenanceWindowTarget
    Properties:
      Name: !Sub '${AWS::StackName}-patch-target'
      WindowId: !Ref PatchWindow
      ResourceType: INSTANCE
      Targets:
        - Key: 'tag:Patch Group'
          Values:
            - !Ref PatchGroupName

  PatchWindowTask:
    Type: AWS::SSM::MaintenanceWindowTask
    Properties:
      Name: !Sub '${AWS::StackName}-run-patch-baseline'
      WindowId: !Ref PatchWindow
      TaskType: RUN_COMMAND
      TaskArn: 'AWS-RunPatchBaseline'
      Priority: 1
      ServiceRoleArn: !GetAtt MaintenanceWindowRole.Arn
      MaxConcurrency: !Ref MaxConcurrency
      MaxErrors: !Ref MaxErrors
      CutoffBehavior: CANCEL_TASK
      Targets:
        - Key: WindowTargetIds
          Values:
            - !Ref PatchWindowTarget
      TaskInvocationParameters:
        MaintenanceWindowRunCommandParameters:
          Comment: 'Weekly AL2023 patching'
          TimeoutSeconds: 3600
          OutputS3BucketName: !Ref PatchLogBucket
          OutputS3KeyPrefix: 'patch-runs/'
          Parameters:
            Operation:
              - Install
            RebootOption:
              - !Ref RebootOption

  ##########################################################################
  # Proof that the control ran. These Config rules require an active
  # configuration recorder + delivery channel in this Region.
  ##########################################################################
  RuleInstancesManagedBySsm:
    Type: AWS::Config::ConfigRule
    Properties:
      ConfigRuleName: ec2-instance-managed-by-ssm
      Description: EC2 instances must be managed by Systems Manager.
      Scope:
        ComplianceResourceTypes:
          - 'AWS::EC2::Instance'
          - 'AWS::SSM::ManagedInstanceInventory'
      Source:
        Owner: AWS
        SourceIdentifier: EC2_INSTANCE_MANAGED_BY_SSM

  RulePatchCompliance:
    Type: AWS::Config::ConfigRule
    Properties:
      ConfigRuleName: ec2-managedinstance-patch-compliance-status-check
      Description: Managed instances must report COMPLIANT patch status.
      Scope:
        ComplianceResourceTypes:
          - 'AWS::SSM::PatchCompliance'
      Source:
        Owner: AWS
        SourceIdentifier: EC2_MANAGEDINSTANCE_PATCH_COMPLIANCE_STATUS_CHECK

  RuleImdsV2:
    Type: AWS::Config::ConfigRule
    Properties:
      ConfigRuleName: ec2-imdsv2-check
      Description: Instances must require IMDSv2 tokens.
      Scope:
        ComplianceResourceTypes:
          - 'AWS::EC2::Instance'
      Source:
        Owner: AWS
        SourceIdentifier: EC2_IMDSV2_CHECK

  RuleEncryptedVolumes:
    Type: AWS::Config::ConfigRule
    Properties:
      ConfigRuleName: encrypted-volumes
      Scope:
        ComplianceResourceTypes:
          - 'AWS::EC2::Volume'
      Source:
        Owner: AWS
        SourceIdentifier: ENCRYPTED_VOLUMES

  RuleRootMfa:
    Type: AWS::Config::ConfigRule
    Properties:
      ConfigRuleName: root-account-mfa-enabled
      Description: Root user custody is a permanent customer responsibility.
      MaximumExecutionFrequency: TwentyFour_Hours
      Source:
        Owner: AWS
        SourceIdentifier: ROOT_ACCOUNT_MFA_ENABLED

Outputs:
  PatchBaselineId:
    Value: !Ref LinuxPatchBaseline
  PatchGroup:
    Description: Tag instances with `Patch Group` = this value.
    Value: !Ref PatchGroupName
  MaintenanceWindowId:
    Value: !Ref PatchWindow
  InstanceProfileName:
    Value: !Ref ManagedInstanceProfile
  PatchLogBucketName:
    Value: !Ref PatchLogBucket
```

### 6.3 Launch template — closing the IMDS and encryption gaps

```yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: >
  EC2 launch template encoding the guest-side controls the customer owns:
  IMDSv2 required, hop limit 1, encrypted EBS with a CMK, Nitro Enclaves off,
  detailed monitoring on, and the Patch Group tag that binds the instance to
  the maintenance window.

Parameters:
  PatchGroupName:
    Type: String
    Default: prod-linux
  InstanceProfileName:
    Type: String
    Description: Output InstanceProfileName from the patching stack.
  KmsKeyArn:
    Type: String
    Description: CMK ARN used to encrypt the root volume.
  InstanceType:
    Type: String
    Default: m6i.large
  AmiId:
    Type: AWS::SSM::Parameter::Value<AWS::EC2::Image::Id>
    Default: '/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-6.1-x86_64'
    Description: Resolved from the AWS-published SSM public parameter.
  SecurityGroupId:
    Type: AWS::EC2::SecurityGroup::Id

Resources:
  HardenedLaunchTemplate:
    Type: AWS::EC2::LaunchTemplate
    Properties:
      LaunchTemplateName: !Sub '${AWS::StackName}-hardened'
      LaunchTemplateData:
        ImageId: !Ref AmiId
        InstanceType: !Ref InstanceType
        IamInstanceProfile:
          Name: !Ref InstanceProfileName
        SecurityGroupIds:
          - !Ref SecurityGroupId
        # IMDSv2 required. This single block removes the SSRF -> credential
        # exfiltration path that IMDSv1 leaves open. 100% customer side.
        MetadataOptions:
          HttpTokens: required
          HttpPutResponseHopLimit: 1
          HttpEndpoint: enabled
          InstanceMetadataTags: enabled
        Monitoring:
          Enabled: true
        EnclaveOptions:
          Enabled: false
        BlockDeviceMappings:
          - DeviceName: /dev/xvda
            Ebs:
              VolumeType: gp3
              VolumeSize: 30
              Iops: 3000
              Throughput: 125
              Encrypted: true
              KmsKeyId: !Ref KmsKeyArn
              DeleteOnTermination: true
        TagSpecifications:
          - ResourceType: instance
            Tags:
              - Key: 'Patch Group'
                Value: !Ref PatchGroupName
              - Key: ResponsibilityBoundary
                Value: customer
          - ResourceType: volume
            Tags:
              - Key: 'Patch Group'
                Value: !Ref PatchGroupName
        UserData:
          Fn::Base64: !Sub |
            #!/bin/bash
            set -euo pipefail
            # Fail fast if SSM Agent is absent: without it, the customer half
            # of the patch shared control cannot execute.
            systemctl enable --now amazon-ssm-agent
            systemctl is-active --quiet amazon-ssm-agent || {
              echo "FATAL: amazon-ssm-agent not running" >&2
              exit 1
            }
            dnf -y install amazon-cloudwatch-agent
            # Prove IMDSv1 is refused before the app ever starts.
            if curl -s -f --max-time 2 http://169.254.169.254/latest/meta-data/ ; then
              echo "FATAL: IMDSv1 is answering; launch template not applied" >&2
              exit 1
            fi

Outputs:
  LaunchTemplateId:
    Value: !Ref HardenedLaunchTemplate
  LaunchTemplateLatestVersion:
    Value: !GetAtt HardenedLaunchTemplate.LatestVersionNumber
```

### 6.4 Making the bad state unrepresentable — Service Control Policy

Config rules *detect*. SCPs *prevent*. An SCP is the strongest expression of "we accept this responsibility and refuse to allow drift."

```yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: >
  Organization-level guardrails. Deploy in the management account with
  SERVICE_CONTROL_POLICY enabled. SCPs set the permission CEILING; they never
  grant. An SCP cannot restrict the management account's root user.

Parameters:
  TargetOuId:
    Type: String
    Description: OU id (ou-xxxx-xxxxxxxx) to attach the policy to.
  HomeRegions:
    Type: CommaDelimitedList
    Default: 'eu-west-1,us-east-1'
    Description: Regions permitted for regional services (data residency).

Resources:
  ResponsibilityGuardrails:
    Type: AWS::Organizations::Policy
    Properties:
      Name: !Sub '${AWS::StackName}-responsibility-guardrails'
      Description: Prevents drift on customer-owned security controls.
      Type: SERVICE_CONTROL_POLICY
      TargetIds:
        - !Ref TargetOuId
      Content: !Sub
        - |
          {
            "Version": "2012-10-17",
            "Statement": [
              {
                "Sid": "DenyDisablingS3BlockPublicAccess",
                "Effect": "Deny",
                "Action": [
                  "s3:PutAccountPublicAccessBlock",
                  "s3:PutBucketPublicAccessBlock"
                ],
                "Resource": "*",
                "Condition": {
                  "ArnNotLike": {
                    "aws:PrincipalArn": "arn:aws:iam::*:role/BreakGlassAdmin"
                  }
                }
              },
              {
                "Sid": "DenyUnencryptedEbsVolumeCreation",
                "Effect": "Deny",
                "Action": "ec2:CreateVolume",
                "Resource": "*",
                "Condition": {
                  "Bool": { "ec2:Encrypted": "false" }
                }
              },
              {
                "Sid": "DenyRunInstancesWithoutImdsV2",
                "Effect": "Deny",
                "Action": "ec2:RunInstances",
                "Resource": "arn:aws:ec2:*:*:instance/*",
                "Condition": {
                  "StringNotEquals": {
                    "ec2:MetadataHttpTokens": "required"
                  }
                }
              },
              {
                "Sid": "DenyUnencryptedRdsCreation",
                "Effect": "Deny",
                "Action": [
                  "rds:CreateDBInstance",
                  "rds:CreateDBCluster"
                ],
                "Resource": "*",
                "Condition": {
                  "Bool": { "rds:StorageEncrypted": "false" }
                }
              },
              {
                "Sid": "DenyTurningOffAuditTelemetry",
                "Effect": "Deny",
                "Action": [
                  "cloudtrail:StopLogging",
                  "cloudtrail:DeleteTrail",
                  "cloudtrail:UpdateTrail",
                  "config:DeleteConfigurationRecorder",
                  "config:StopConfigurationRecorder",
                  "config:DeleteDeliveryChannel",
                  "config:DeleteConfigRule",
                  "guardduty:DeleteDetector",
                  "guardduty:DisassociateFromMasterAccount",
                  "securityhub:DisableSecurityHub",
                  "securityhub:DeleteMembers"
                ],
                "Resource": "*",
                "Condition": {
                  "ArnNotLike": {
                    "aws:PrincipalArn": "arn:aws:iam::*:role/SecurityAdmin"
                  }
                }
              },
              {
                "Sid": "DenyRootUserActions",
                "Effect": "Deny",
                "Action": "*",
                "Resource": "*",
                "Condition": {
                  "StringLike": {
                    "aws:PrincipalArn": "arn:aws:iam::*:root"
                  }
                }
              },
              {
                "Sid": "DenyKmsKeyDeletion",
                "Effect": "Deny",
                "Action": [
                  "kms:ScheduleKeyDeletion",
                  "kms:DisableKeyRotation"
                ],
                "Resource": "*",
                "Condition": {
                  "ArnNotLike": {
                    "aws:PrincipalArn": "arn:aws:iam::*:role/BreakGlassAdmin"
                  }
                }
              },
              {
                "Sid": "DenyOutsideHomeRegions",
                "Effect": "Deny",
                "NotAction": [
                  "iam:*",
                  "organizations:*",
                  "sts:*",
                  "route53:*",
                  "cloudfront:*",
                  "waf:*",
                  "wafv2:*",
                  "shield:*",
                  "support:*",
                  "budgets:*",
                  "ce:*",
                  "health:*",
                  "artifact:*"
                ],
                "Resource": "*",
                "Condition": {
                  "StringNotEquals": {
                    "aws:RequestedRegion": [ ${RegionList} ]
                  }
                }
              }
            ]
          }
        - RegionList: !Join
            - ', '
            - - !Sub ['"${R}"', {R: !Select [0, !Ref HomeRegions]}]
              - !Sub ['"${R}"', {R: !Select [1, !Ref HomeRegions]}]

Outputs:
  PolicyId:
    Value: !Ref ResponsibilityGuardrails
```

### 6.5 The customer half on EKS (`eks-customer-controls.yaml`)

AWS runs the control plane. Everything below is yours — and none of it is created for you.

```yaml
---
# Namespace with Pod Security Admission enforced at the "restricted" profile.
# AWS does not set this. An EKS cluster with no PSA labels admits privileged
# pods by default.
apiVersion: v1
kind: Namespace
metadata:
  name: payments
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: latest
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/audit-version: latest
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/warn-version: latest
    responsibility-boundary: customer
---
# Default-deny ingress AND egress. Requires the VPC CNI network policy agent
# (enableNetworkPolicy=true on the aws-node add-on) or Calico; without a policy
# engine installed this object is silently inert.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: payments
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-ingress-from-gateway-and-dns-egress
  namespace: payments
spec:
  podSelector:
    matchLabels:
      app: payments-api
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: ingress-nginx
          podSelector:
            matchLabels:
              app.kubernetes.io/name: ingress-nginx
      ports:
        - protocol: TCP
          port: 8080
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
    # RDS in the VPC. Egress to the wider internet stays denied.
    - to:
        - ipBlock:
            cidr: 10.42.0.0/16
      ports:
        - protocol: TCP
          port: 5432
---
# IRSA: the pod assumes an IAM role scoped to exactly what it needs.
# The trust policy on the IAM side must pin sub == this ServiceAccount.
apiVersion: v1
kind: ServiceAccount
metadata:
  name: payments-api
  namespace: payments
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::111122223333:role/payments-api-irsa
    eks.amazonaws.com/sts-regional-endpoints: "true"
automountServiceAccountToken: true
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payments-api
  namespace: payments
  labels:
    app: payments-api
spec:
  replicas: 3
  selector:
    matchLabels:
      app: payments-api
  template:
    metadata:
      labels:
        app: payments-api
    spec:
      serviceAccountName: payments-api
      automountServiceAccountToken: true
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        fsGroup: 10001
        seccompProfile:
          type: RuntimeDefault
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app: payments-api
      containers:
        - name: api
          # Digest-pinned. Tag-pinning is not supply-chain control.
          image: 111122223333.dkr.ecr.eu-west-1.amazonaws.com/payments-api@sha256:3f8b1c2d4e5a6b7c8d9e0f1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 8080
              protocol: TCP
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            privileged: false
            capabilities:
              drop:
                - ALL
          resources:
            requests:
              cpu: "250m"
              memory: "256Mi"
            limits:
              cpu: "1000m"
              memory: "512Mi"
          livenessProbe:
            httpGet:
              path: /healthz
              port: http
            initialDelaySeconds: 10
            periodSeconds: 10
          readinessProbe:
            httpGet:
              path: /readyz
              port: http
            initialDelaySeconds: 5
            periodSeconds: 5
          volumeMounts:
            - name: tmp
              mountPath: /tmp
            - name: cache
              mountPath: /var/cache/app
      volumes:
        - name: tmp
          emptyDir:
            sizeLimit: 64Mi
        - name: cache
          emptyDir:
            sizeLimit: 256Mi
---
apiVersion: v1
kind: Service
metadata:
  name: payments-api
  namespace: payments
spec:
  type: ClusterIP
  selector:
    app: payments-api
  ports:
    - name: http
      port: 8080
      targetPort: http
      protocol: TCP
```

---

## 7. Verification: proving each side of the line

### 7.1 Establish the principal and the account

```console
$ aws sts get-caller-identity --output json
{
    "UserId": "AROA2XYZEXAMPLE7QF4:platform-sre",
    "Account": "111122223333",
    "Arn": "arn:aws:sts::111122223333:assumed-role/PlatformSRE/platform-sre"
}
```

### 7.2 Confirm where the AWS boundary actually sits (Nitro)

`describe-instances` reports `Hypervisor: xen` even on Nitro hosts for API backwards compatibility. Query the *instance type* instead:

```console
$ aws ec2 describe-instance-types --instance-types m6i.large \
    --query 'InstanceTypes[].{Type:InstanceType,Hypervisor:Hypervisor,Nitro:NitroEnclavesSupport,BareMetal:BareMetal}' \
    --output table
-------------------------------------------------------------
|                   DescribeInstanceTypes                   |
+------------+-------------+-------------+------------------+
| BareMetal  | Hypervisor  |   Nitro     |      Type        |
+------------+-------------+-------------+------------------+
|  False     |  nitro      |  supported  |  m6i.large       |
+------------+-------------+-------------+------------------+
```

`Hypervisor: nitro` is the machine-readable statement that everything below the guest kernel is AWS's.

### 7.3 See AWS acting on its side of the line

AWS-initiated maintenance surfaces as instance events. These are AWS exercising *its* responsibility while requiring *your* cooperation:

```console
$ aws ec2 describe-instance-status --include-all-instances \
    --query 'InstanceStatuses[?Events].{Id:InstanceId,Event:Events[0].Code,Desc:Events[0].Description,NotBefore:Events[0].NotBefore}' \
    --output table
-------------------------------------------------------------------------------------------------------------
|                                          DescribeInstanceStatus                                           |
+------------------------------------------+---------------------+----------------------+-------------------+
|                   Desc                   |        Event        |          Id          |     NotBefore     |
+------------------------------------------+---------------------+----------------------+-------------------+
|  The instance is running on degraded ...  |  instance-retirement |  i-0a1b2c3d4e5f6a7b8 | 2026-09-17T00:00Z |
|  Scheduled reboot for host maintenance   |  system-reboot       |  i-09f8e7d6c5b4a3210 | 2026-09-10T02:00Z |
+------------------------------------------+---------------------+----------------------+-------------------+
```

Fleet-wide AWS-side events (Business/Enterprise Support, global endpoint in `us-east-1`):

```console
$ aws health describe-events --region us-east-1 \
    --filter eventTypeCategories=scheduledChange,issue eventStatusCodes=open,upcoming \
    --query 'events[].{Arn:arn,Service:service,Category:eventTypeCategory,Region:region,Start:startTime}' \
    --output table
--------------------------------------------------------------------------------------------------------
|                                          DescribeEvents                                              |
+------------------+---------------------------------------------------+-----------+---------+---------+
|     Category     |                        Arn                        |  Region   | Service |  Start  |
+------------------+---------------------------------------------------+-----------+---------+---------+
| scheduledChange  | arn:aws:health:eu-west-1::event/EC2/AWS_EC2_...    | eu-west-1 | EC2     | ...     |
+------------------+---------------------------------------------------+-----------+---------+---------+
```

### 7.4 Prove your half of the patch shared control

```console
$ aws ssm describe-instance-information \
    --query 'InstanceInformationList[].{Id:InstanceId,Ping:PingStatus,Agent:AgentVersion,Platform:PlatformName,Ver:PlatformVersion}' \
    --output table
--------------------------------------------------------------------------------------------
|                              DescribeInstanceInformation                                 |
+------------+----------------------+-----------+-------------------------+----------------+
|   Agent    |         Id           |   Ping    |        Platform         |      Ver       |
+------------+----------------------+-----------+-------------------------+----------------+
|  3.3.1345.0|  i-0a1b2c3d4e5f6a7b8 |  Online   |  Amazon Linux           |  2023          |
|  3.3.1345.0|  i-09f8e7d6c5b4a3210 |  Online   |  Amazon Linux           |  2023          |
|  3.2.2086.0|  i-0c0ffee1234567890 | ConnectionLost | Amazon Linux       |  2023          |
+------------+----------------------+-----------+-------------------------+----------------+
```

`ConnectionLost` means your patch control is **not running** on that instance — a silent compliance hole.

```console
$ aws ssm describe-instance-patch-states --instance-ids i-0a1b2c3d4e5f6a7b8 --output json
{
    "InstancePatchStates": [
        {
            "InstanceId": "i-0a1b2c3d4e5f6a7b8",
            "PatchGroup": "prod-linux",
            "BaselineId": "pb-0f1e2d3c4b5a69788",
            "SnapshotId": "9d4e2b1a-6c7f-4a3b-8e1d-2f5a7c9b0e34",
            "OperationStartTime": "2026-08-30T03:00:11.412000+00:00",
            "OperationEndTime": "2026-08-30T03:07:52.908000+00:00",
            "Operation": "Install",
            "RebootOption": "RebootIfNeeded",
            "InstalledCount": 41,
            "InstalledOtherCount": 226,
            "InstalledPendingRebootCount": 0,
            "InstalledRejectedCount": 1,
            "MissingCount": 0,
            "FailedCount": 0,
            "NotApplicableCount": 812,
            "UnreportedNotApplicableCount": 799,
            "CriticalNonCompliantCount": 0,
            "SecurityNonCompliantCount": 0,
            "OtherNonCompliantCount": 3
        }
    ]
}
```

Fleet roll-up:

```console
$ aws ssm describe-instance-patch-states-for-patch-group --patch-group prod-linux \
    --query 'InstancePatchStates[].{Id:InstanceId,Missing:MissingCount,Failed:FailedCount,CritNC:CriticalNonCompliantCount,SecNC:SecurityNonCompliantCount}' \
    --output table
----------------------------------------------------------------------------
|                DescribeInstancePatchStatesForPatchGroup                   |
+---------+----------+----------------------+-----------+------------------+
| CritNC  | Failed   |         Id           |  Missing  |      SecNC       |
+---------+----------+----------------------+-----------+------------------+
|  0      |  0       |  i-0a1b2c3d4e5f6a7b8 |  0        |  0               |
|  2      |  1       |  i-09f8e7d6c5b4a3210 |  7        |  5               |
+---------+----------+----------------------+-----------+------------------+
```

### 7.5 Prove the encryption and exposure controls

```console
$ aws s3api get-public-access-block --bucket shared-resp-data-111122223333-eu-west-1
{
    "PublicAccessBlockConfiguration": {
        "BlockPublicAcls": true,
        "IgnorePublicAcls": true,
        "BlockPublicPolicy": true,
        "RestrictPublicBuckets": true
    }
}

$ aws s3api get-bucket-encryption --bucket shared-resp-data-111122223333-eu-west-1 \
    --query 'ServerSideEncryptionConfiguration.Rules[0]'
{
    "ApplyServerSideEncryptionByDefault": {
        "SSEAlgorithm": "aws:kms",
        "KMSMasterKeyID": "arn:aws:kms:eu-west-1:111122223333:key/8f2c1a3b-5d6e-47f8-9a0b-1c2d3e4f5a6b"
    },
    "BucketKeyEnabled": true
}

$ aws s3api get-object-lock-configuration --bucket shared-resp-data-111122223333-eu-west-1
{
    "ObjectLockConfiguration": {
        "ObjectLockEnabled": "Enabled",
        "Rule": {
            "DefaultRetention": { "Mode": "GOVERNANCE", "Days": 30 }
        }
    }
}

$ aws kms get-key-rotation-status --key-id alias/shared-resp-data
{
    "KeyId": "arn:aws:kms:eu-west-1:111122223333:key/8f2c1a3b-5d6e-47f8-9a0b-1c2d3e4f5a6b",
    "KeyRotationEnabled": true,
    "RotationPeriodInDays": 365,
    "NextRotationDate": "2027-02-14T09:12:44.000000+00:00"
}

$ aws ec2 get-ebs-encryption-by-default --region eu-west-1
{
    "EbsEncryptionByDefault": true
}
```

RDS — the customer-owned knobs on a managed platform:

```console
$ aws rds describe-db-instances --db-instance-identifier payments-prod \
    --query 'DBInstances[0].{Engine:Engine,Version:EngineVersion,Encrypted:StorageEncrypted,Kms:KmsKeyId,MultiAZ:MultiAZ,Public:PubliclyAccessible,Backup:BackupRetentionPeriod,Window:PreferredMaintenanceWindow,AutoMinor:AutoMinorVersionUpgrade,DelProt:DeletionProtection}' \
    --output json
{
    "Engine": "postgres",
    "Version": "16.4",
    "Encrypted": true,
    "Kms": "arn:aws:kms:eu-west-1:111122223333:key/2b7d9e10-4c6a-4f83-9d21-70e5c8ab4419",
    "MultiAZ": true,
    "Public": false,
    "Backup": 14,
    "Window": "sun:03:00-sun:04:00",
    "AutoMinor": true,
    "DelProt": true
}

$ aws rds describe-db-parameters --db-parameter-group-name payments-pg16-hardened \
    --query "Parameters[?ParameterName=='rds.force_ssl'].{Name:ParameterName,Value:ParameterValue,Applied:ApplyType}" \
    --output table
--------------------------------------------------
|             DescribeDBParameters               |
+-----------+------------------+-----------------+
|  Applied  |      Name        |     Value       |
+-----------+------------------+-----------------+
|  static   |  rds.force_ssl   |  1              |
+-----------+------------------+-----------------+
```

Lambda — AWS owns the runtime, you own the role and the code:

```console
$ aws lambda get-function-configuration --function-name payments-settlement \
    --query '{Runtime:Runtime,Role:Role,Timeout:Timeout,Memory:MemorySize,Vpc:VpcConfig.SubnetIds,Kms:KMSKeyArn,Arch:Architectures}' \
    --output json
{
    "Runtime": "python3.12",
    "Role": "arn:aws:iam::111122223333:role/payments-settlement-exec",
    "Timeout": 30,
    "Memory": 1024,
    "Vpc": ["subnet-0a1b2c3d", "subnet-04e5f6a7"],
    "Kms": "arn:aws:kms:eu-west-1:111122223333:key/2b7d9e10-4c6a-4f83-9d21-70e5c8ab4419",
    "Arch": ["arm64"]
}
```

Your dependency CVEs, which AWS will never patch:

```console
$ aws inspector2 list-findings \
    --filter-criteria '{"resourceType":[{"comparison":"EQUALS","value":"AWS_LAMBDA_FUNCTION"}],"severity":[{"comparison":"EQUALS","value":"CRITICAL"}]}' \
    --query 'findings[].{Title:title,Pkg:packageVulnerabilityDetails.vulnerablePackages[0].name,Ver:packageVulnerabilityDetails.vulnerablePackages[0].version,Fix:packageVulnerabilityDetails.vulnerablePackages[0].fixedInVersion,Res:resources[0].id}' \
    --output table
------------------------------------------------------------------------------------------------------------
|                                              ListFindings                                                |
+----------+---------------+------------+--------------------------------------------------+--------------+
|   Fix    |     Pkg       |    Ver     |                       Res                        |    Title     |
+----------+---------------+------------+--------------------------------------------------+--------------+
| 2.32.4   |  requests     |  2.28.1    | arn:aws:lambda:eu-west-1:111122223333:function...| CVE-2024-... |
+----------+---------------+------------+--------------------------------------------------+--------------+
```

### 7.6 Consume AWS's attestation (control inheritance)

```console
$ aws artifact list-reports --region us-east-1 \
    --query 'reports[?contains(name, `SOC 2`)].{Id:id,Name:name,Series:series,State:state,Version:version,Period:periodEnd}' \
    --output table
------------------------------------------------------------------------------------------------------
|                                            ListReports                                             |
+-------------------------+------------------------------------+-----------+----------+-------------+
|           Id            |               Name                 |  Period   |  State   |   Version   |
+-------------------------+------------------------------------+-----------+----------+-------------+
| report-a1b2c3d4e5f6g7h8 | AWS SOC 2 Type II Report            | 2026-06-30| PUBLISHED|  14         |
+-------------------------+------------------------------------+-----------+----------+-------------+

$ aws artifact get-report --report-id report-a1b2c3d4e5f6g7h8 --report-version 14 \
    --term-token "$(aws artifact get-term-for-report --report-id report-a1b2c3d4e5f6g7h8 \
        --report-version 14 --query termToken --output text)" \
    --query documentPresignedUrl --output text
https://artifact-reports-prod.s3.us-east-1.amazonaws.com/soc2-type2-2026H1.pdf?X-Amz-Algorithm=...
```

That PDF is the *entirety* of your ability to verify AWS's half. Attach it to the audit; scope the inherited controls out of your own assessment.

### 7.7 Continuous compliance posture

```console
$ aws configservice describe-compliance-by-config-rule \
    --config-rule-names ec2-instance-managed-by-ssm ec2-managedinstance-patch-compliance-status-check ec2-imdsv2-check encrypted-volumes root-account-mfa-enabled \
    --query 'ComplianceByConfigRules[].{Rule:ConfigRuleName,State:Compliance.ComplianceType,NonCompliant:Compliance.ComplianceContributorCount.CappedCount}' \
    --output table
--------------------------------------------------------------------------------------------
|                            DescribeComplianceByConfigRule                                |
+----------------+----------------------------------------------------+--------------------+
|  NonCompliant  |                       Rule                         |      State         |
+----------------+----------------------------------------------------+--------------------+
|  None          |  root-account-mfa-enabled                          |  COMPLIANT         |
|  1             |  ec2-instance-managed-by-ssm                       |  NON_COMPLIANT     |
|  1             |  ec2-managedinstance-patch-compliance-status-check |  NON_COMPLIANT     |
|  3             |  ec2-imdsv2-check                                  |  NON_COMPLIANT     |
|  None          |  encrypted-volumes                                 |  COMPLIANT         |
+----------------+----------------------------------------------------+--------------------+

$ aws securityhub get-findings \
    --filters '{"ComplianceStatus":[{"Value":"FAILED","Comparison":"EQUALS"}],"SeverityLabel":[{"Value":"CRITICAL","Comparison":"EQUALS"}],"RecordState":[{"Value":"ACTIVE","Comparison":"EQUALS"}]}' \
    --max-results 5 \
    --query 'Findings[].{Ctl:ProductFields."ControlId",Title:Title,Res:Resources[0].Id}' \
    --output table
-------------------------------------------------------------------------------------------------
|                                          GetFindings                                          |
+-----------+---------------------------------------------------+-------------------------------+
|    Ctl    |                       Res                         |            Title              |
+-----------+---------------------------------------------------+-------------------------------+
|  IAM.6    |  AWS::::Account:111122223333                      | Hardware MFA should be enab...|
|  EC2.8    |  arn:aws:ec2:eu-west-1:111122223333:instance/i-0c..| EC2 instances should use IM...|
+-----------+---------------------------------------------------+-------------------------------+
```

Core Trusted Advisor checks are free; the full set requires Business/Enterprise Support, and the Support API only answers in `us-east-1`:

```console
$ aws support describe-trusted-advisor-checks --language en --region us-east-1 \
    --query 'checks[?category==`security`].{Id:id,Name:name}' --output table
-----------------------------------------------------------------------
|                    DescribeTrustedAdvisorChecks                     |
+--------------------------+------------------------------------------+
|            Id            |                  Name                    |
+--------------------------+------------------------------------------+
|  Pfx0RwqBli               |  Security Groups - Specific Ports Unre... |
|  HCP4007jGY               |  Security Groups - Unrestricted Access    |
|  DqdJqYeRm5               |  IAM Use                                  |
|  7DAFEmoDos               |  MFA on Root Account                      |
+--------------------------+------------------------------------------+
```

If you lack Business Support:

```console
$ aws support describe-trusted-advisor-checks --language en --region us-east-1

An error occurred (SubscriptionRequiredException) when calling the
DescribeTrustedAdvisorChecks operation: Amazon Web Services Premium Support
Subscription is required to use this service.
```

---

## 8. Failure diagnosis: which side of the line is this?

### 8.1 The triage algorithm

```
Symptom observed
   │
   ├─ Does an AWS API call return an error code? ────────────────────► YOUR side (auth/config/quota)
   │     AccessDenied / UnauthorizedOperation → IAM, SCP, resource policy, KMS key policy
   │     LimitExceeded / RequestLimitExceeded → service quota (you request the increase)
   │
   ├─ Does the API succeed but the resource behaves wrongly? ────────► YOUR side (config/app)
   │
   ├─ Is the control plane itself unreachable / erroring 5xx
   │  across many principals and resources? ─────────────────────────► Check AWS Health + Service Health
   │     Event present → AWS side. Your job: failover, comms, credits.
   │     No event      → still YOUR side until proven otherwise.
   │
   ├─ Did a host/instance die with a scheduled event attached? ──────► AWS side hardware, YOUR side resilience
   │
   └─ Is data missing/corrupt?
         Deleted by an API call in CloudTrail?  → YOUR side (restore from versioning/backup)
         No such call, checksum mismatch?       → AWS side (open a support case; extremely rare)
```

**The default assumption is that the fault is yours.** Statistically it is, and starting from "it's AWS" wastes the first 30 minutes of every incident.

### 8.2 Symptom → root cause table

| Symptom | Likely owner | Diagnostic command | Root cause |
|---|---|---|---|
| `AccessDenied` on `s3:PutObject` even though the caller has `s3:*` | You | `aws s3api get-bucket-policy --bucket X` | Explicit `Deny` in bucket policy, SCP, or the `s3:x-amz-server-side-encryption` trap (§8.3) |
| `KMS.NotFoundException` / `AccessDeniedException` decrypting S3 objects | You | `aws kms get-key-policy --key-id X --policy-name default` | Key policy does not delegate to IAM; IAM `Allow` alone is insufficient for KMS |
| Instance shows `ConnectionLost` in SSM; patches never install | You | `aws ssm describe-instance-information` | Missing instance profile, no route to SSM endpoints (no NAT/VPC endpoints), or agent stopped |
| Patch Manager reports `Missing: 7` after a successful run | You | `aws ssm describe-instance-patch-states` | `RebootOption: NoReboot`, or patches blocked by `RejectedPatches` |
| Application on Fargate still vulnerable after AWS published a platform update | You | `aws ecs describe-tasks --query 'tasks[].platformVersion'` | Running tasks keep their launch-time platform version; force a new deployment |
| EKS `NetworkPolicy` objects exist but traffic flows freely | You | `aws eks describe-addon --cluster-name X --addon-name vpc-cni` | Network policy enforcement not enabled on the CNI add-on |
| Instance terminated overnight; app down | AWS (hardware) + **you** (resilience) | `aws ec2 describe-instance-status --include-all-instances` | `instance-retirement` event; single-AZ/single-instance design |
| RDS failed over at 03:12 with a brief connection drop | AWS (executed) + **you** (client) | `aws rds describe-events --source-identifier X --source-type db-instance` | Multi-AZ failover during maintenance; app lacks retry/reconnect logic |
| Database reachable from the internet | You | `... --query 'DBInstances[0].PubliclyAccessible'` | `PubliclyAccessible: true` + permissive SG |
| Objects gone, no restore possible | You | `aws cloudtrail lookup-events --lookup-attributes AttributeKey=EventName,AttributeValue=DeleteObject` | Versioning disabled. S3 durability protects against *disk* loss, not against *your* `DELETE` |
| Lambda flagged CRITICAL by Inspector; runtime is current | You | `aws inspector2 list-findings` | Vulnerable packaged dependency — AWS patches the runtime, not your `site-packages` |
| Console/API returns 503 across services in one Region | AWS | `aws health describe-events --region us-east-1` + Service Health Dashboard | Regional service event; execute your DR runbook |
| Global 4xx spike after an SCP rollout | You | `aws cloudtrail lookup-events` → `errorCode: AccessDenied`, `errorMessage` naming the SCP | SCP ceiling now excludes a legitimate action |

### 8.3 Worked diagnostic — the encryption-policy deadlock

**Symptom.** Uploads from a properly-permissioned role start failing right after the bucket policy ships.

```console
$ aws s3 cp report.parquet s3://shared-resp-data-111122223333-eu-west-1/exports/report.parquet
upload failed: ./report.parquet to s3://shared-resp-data-111122223333-eu-west-1/exports/report.parquet
An error occurred (AccessDenied) when calling the PutObject operation:
User: arn:aws:sts::111122223333:assumed-role/etl-writer/etl is not authorized to
perform: s3:PutObject on resource "arn:aws:s3:::shared-resp-data-.../exports/report.parquet"
with an explicit deny in a resource-based policy
```

**Step 1 — read the error's last clause.** "explicit deny in a **resource-based policy**" localizes the fault to the bucket policy, not to IAM and not to an SCP (an SCP denial says *"with an explicit deny in a service control policy"*).

**Step 2 — reproduce the evaluation.**

```console
$ aws iam simulate-principal-policy \
    --policy-source-arn arn:aws:iam::111122223333:role/etl-writer \
    --action-names s3:PutObject \
    --resource-arns 'arn:aws:s3:::shared-resp-data-111122223333-eu-west-1/exports/report.parquet' \
    --query 'EvaluationResults[].{Action:EvalActionName,Decision:EvalDecision,By:MatchedStatements[].SourcePolicyId}' \
    --output json
[
    {
        "Action": "s3:PutObject",
        "Decision": "explicitDeny",
        "By": ["DenyUnEncryptedObjectUploads"]
    }
]
```

**Step 3 — the root cause.** The offending statement was:

```json
{
  "Sid": "DenyUnEncryptedObjectUploads",
  "Effect": "Deny",
  "Principal": "*",
  "Action": "s3:PutObject",
  "Resource": "arn:aws:s3:::shared-resp-data-.../*",
  "Condition": {
    "StringNotEquals": { "s3:x-amz-server-side-encryption": "aws:kms" }
  }
}
```

In IAM, a `StringNotEquals` condition on a key **absent from the request** evaluates to **true**. The AWS CLI sends no `x-amz-server-side-encryption` header, because the bucket's default encryption will apply it. But **bucket default encryption is applied after policy evaluation**. Result: the object *would have been* SSE-KMS encrypted, yet the policy denies it. Your control fought AWS's default and won — incorrectly.

**Step 4 — the correct pattern**, as used in §6.1: rely on bucket default encryption for *application*, and use `StringNotEqualsIfExists` (plus a `Null` guard) only to reject an explicitly-wrong key, never a missing header. Then let a Config rule (`S3_DEFAULT_ENCRYPTION_KMS`) prove the state rather than a policy that guesses at the request.

**Step 5 — verify the fix at the object, not the policy.**

```console
$ aws s3api head-object --bucket shared-resp-data-111122223333-eu-west-1 \
    --key exports/report.parquet \
    --query '{SSE:ServerSideEncryption,Key:SSEKMSKeyId,BucketKey:BucketKeyEnabled}'
{
    "SSE": "aws:kms",
    "Key": "arn:aws:kms:eu-west-1:111122223333:key/8f2c1a3b-5d6e-47f8-9a0b-1c2d3e4f5a6b",
    "BucketKey": true
}
```

**The lesson, in shared-responsibility terms:** AWS gave you a safe default. You added a control that *assumed* the default did not exist. Both halves were individually correct; the seam between them was not. Always verify the resulting **state**, never the intent of the policy.

### 8.4 Attributing an incident with CloudTrail

Customer-side actions carry an IAM principal; AWS-side automation does not:

```console
$ aws cloudtrail lookup-events \
    --lookup-attributes AttributeKey=EventName,AttributeValue=PutBucketPublicAccessBlock \
    --start-time 2026-09-01T00:00:00Z \
    --query 'Events[].{Time:EventTime,User:Username,Src:CloudTrailEvent}' --max-results 1 \
    --output text | head -c 400
2026-09-02T14:22:07+00:00  platform-sre  {"eventVersion":"1.09","userIdentity":{"type":"AssumedRole",
"principalId":"AROA2XYZEXAMPLE7QF4:platform-sre","arn":"arn:aws:sts::111122223333:assumed-role/
PlatformSRE/platform-sre","accountId":"111122223333","sessionContext":{...}},"eventTime":
"2026-09-02T14:22:07Z","eventSource":"s3.amazonaws.com","eventName":"PutBucketPublicAccessBlock",
```

Rule of thumb: `userIdentity.type` ∈ {`IAMUser`, `AssumedRole`, `Root`, `FederatedUser`} → **your side**. `userIdentity.type == "AWSService"` → an AWS service acting on your behalf under a role **you** granted; the grant is still yours. **AWS's own internal operations on its infrastructure never appear in your trail at all** — which is precisely why Artifact and AWS Health exist.

---

## 9. Exam-focused distillation

Common CLF-C02 discriminators, stated as decision rules:

| Prompt pattern | Correct answer |
|---|---|
| "Patching the guest operating system on EC2" | Customer |
| "Patching the hypervisor / host" | AWS |
| "Patching the database engine on Amazon RDS" | AWS |
| "Choosing the RDS maintenance window; performing a major version upgrade" | Customer |
| "Patching the Lambda runtime" | AWS |
| "Patching the libraries inside a Lambda deployment package" | Customer |
| "Physical security of a Region" | AWS |
| "Physical security of the facility hosting an AWS Outposts rack" | Customer |
| "Configuring security groups and NACLs" | Customer |
| "Securing the physical network infrastructure and cabling" | AWS |
| "Encrypting data at rest" | Customer decides & configures; AWS provides the mechanism (KMS/service integration) |
| "Managing IAM users, groups, roles and MFA" | Customer |
| "Managing the physical HSMs behind AWS KMS" | AWS |
| "Classifying your data" | Customer — always |
| "Decommissioning and destroying storage media" | AWS |
| "Patch management" as a *category* | **Shared control** |
| "Configuration management" as a *category* | **Shared control** |
| "Awareness and training" as a *category* | **Shared control** |
| "Where do I get the SOC 2 / ISO 27001 / PCI report?" | AWS Artifact |
| "Which service checks my account against security best practices?" | Trusted Advisor (broad) / Security Hub (standards) / Config (rules) |
| "The application was down because a single AZ failed" | Customer — architect across AZs |

**Three sentences worth memorizing verbatim:**

1. AWS is responsible for **security *of* the cloud**; the customer is responsible for **security *in* the cloud**.
2. Customer responsibility **increases** as you move toward IaaS (EC2) and **decreases** as you move toward abstracted services (S3, Lambda) — but **never reaches zero**, because data and identity are always yours.
3. **Shared controls** mean the same control objective is implemented **twice, independently** — once by AWS on the infrastructure, once by you on your layer.

---

## 10. References

**Primary — exam scope**
- AWS Certified Cloud Practitioner (CLF-C02) Exam Guide — https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf
- AWS Certified Cloud Practitioner — certification page — https://aws.amazon.com/certification/certified-cloud-practitioner/

**The model itself**
- AWS Shared Responsibility Model — https://aws.amazon.com/compliance/shared-responsibility-model/
- Shared Responsibility Model — AWS Well-Architected Framework, Security Pillar — https://docs.aws.amazon.com/wellarchitected/latest/security-pillar/shared-responsibility.html
- Shared Responsibility Model for Resiliency — AWS Well-Architected Framework, Reliability Pillar — https://docs.aws.amazon.com/wellarchitected/latest/reliability-pillar/shared-responsibility-model-for-resiliency.html
- Security in AWS Outposts (shared responsibility for Outposts) — https://docs.aws.amazon.com/outposts/latest/userguide/security.html

**Compliance and attestation**
- AWS Artifact User Guide — https://docs.aws.amazon.com/artifact/latest/ug/what-is-aws-artifact.html
- AWS Artifact API Reference — https://docs.aws.amazon.com/artifact/latest/APIReference/Welcome.html
- AWS Compliance Programs — https://aws.amazon.com/compliance/programs/
- AWS Customer Compliance Center — https://aws.amazon.com/compliance/customer-compliance-center/

**Service-specific boundaries**
- Infrastructure security in Amazon EC2 — https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/infrastructure-security.html
- The AWS Nitro System — https://docs.aws.amazon.com/whitepapers/latest/security-design-of-aws-nitro-system/security-design-of-aws-nitro-system.html
- Use IMDSv2 — https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/configuring-instance-metadata-service.html
- Security in Amazon RDS — https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/UsingWithRDS.html
- Encrypting Amazon RDS resources — https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/Overview.Encryption.html
- Security in AWS Lambda — https://docs.aws.amazon.com/lambda/latest/dg/lambda-security.html
- Lambda runtimes and deprecation policy — https://docs.aws.amazon.com/lambda/latest/dg/lambda-runtimes.html
- Amazon EKS security — https://docs.aws.amazon.com/eks/latest/userguide/security.html
- Amazon EKS Best Practices Guide for Security — https://docs.aws.amazon.com/eks/latest/best-practices/security.html
- AWS Fargate platform versions — https://docs.aws.amazon.com/AmazonECS/latest/developerguide/platform_versions.html
- Security best practices for Amazon S3 — https://docs.aws.amazon.com/AmazonS3/latest/userguide/security-best-practices.html
- Blocking public access to your Amazon S3 storage — https://docs.aws.amazon.com/AmazonS3/latest/userguide/access-control-block-public-access.html
- Setting default server-side encryption behavior for S3 buckets — https://docs.aws.amazon.com/AmazonS3/latest/userguide/bucket-encryption.html
- S3 Object Lock — https://docs.aws.amazon.com/AmazonS3/latest/userguide/object-lock.html
- AWS KMS key policies — https://docs.aws.amazon.com/kms/latest/developerguide/key-policies.html

**Governance, detection and remediation**
- Service control policies (SCPs) — https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_scps.html
- AWS Config Managed Rules — https://docs.aws.amazon.com/config/latest/developerguide/managed-rules-by-aws-config.html
- AWS Systems Manager Patch Manager — https://docs.aws.amazon.com/systems-manager/latest/userguide/systems-manager-patch.html
- About patch baselines — https://docs.aws.amazon.com/systems-manager/latest/userguide/patch-manager-patch-baselines.html
- AWS Security Hub standards and controls — https://docs.aws.amazon.com/securityhub/latest/userguide/standards-reference.html
- Amazon Inspector — https://docs.aws.amazon.com/inspector/latest/user/what-is-inspector.html
- AWS Trusted Advisor check reference — https://docs.aws.amazon.com/awssupport/latest/user/trusted-advisor-check-reference.html
- AWS Health User Guide — https://docs.aws.amazon.com/health/latest/ug/what-is-aws-health.html
- Logging IAM and AWS STS API calls with CloudTrail — https://docs.aws.amazon.com/IAM/latest/UserGuide/cloudtrail-integration.html
- IAM policy evaluation logic — https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_evaluation-logic.html

**Service level agreements (versioned documents — always read the current revision)**
- AWS Service Level Agreements index — https://aws.amazon.com/legal/service-level-agreements/
- Amazon Compute Service Level Agreement — https://aws.amazon.com/compute/sla/
- Amazon S3 Service Level Agreement — https://aws.amazon.com/s3/sla/