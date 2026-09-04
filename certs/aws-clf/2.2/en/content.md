# 2.2 — AWS Cloud Security, Governance, and Compliance Concepts

**Certification:** AWS Certified Cloud Practitioner (CLF-C02, v1.0) · **Domain 2: Security and Compliance** · **Task Statement 2.2** · **Domain weight: 25% · this task ≈ 7.5%**

---

## 1. The production problem: governance does not scale by intention

### 1.1 The failure mode this topic exists to prevent

Consider a platform team running 180 AWS accounts. Every account is created from a Terraform module that attaches a well-reviewed IAM permission set. On a Tuesday afternoon, a data engineer in the `ml-research` account does this:

```
$ aws s3api put-bucket-policy --bucket ml-feature-store-prod \
    --policy file://allow-partner.json
```

The policy grants `s3:GetObject` to `"Principal": "*"`. The engineer has `AdministratorAccess` in that account — legitimately, because it is a sandbox. Eleven minutes later a training dataset containing customer PII is world-readable.

Nothing in the account was misconfigured relative to its own IAM model. The identity had the permission. The control that was missing is *not an identity control* — it is an **organizational invariant**: "no principal in any account, ever, may make an S3 bucket publicly readable." That invariant cannot live inside the account, because the account's administrator can remove it.

This is the central architectural insight of Domain 2.2, and it is the thing the exam actually tests underneath the service names:

> **Security in a single account is an identity problem. Security across an organization is a *policy-plane* problem.** You need controls that a compromised or careless account administrator cannot switch off, evidence that a compromised administrator cannot forge, and encryption whose keys a compromised administrator cannot exfiltrate.

Those three requirements map exactly to the three families of AWS services in this task statement:

| Requirement | Control family | Representative services |
|---|---|---|
| Invariants the account owner cannot remove | **Preventive governance** | AWS Organizations, SCPs, RCPs, declarative policies, AWS Control Tower, permissions boundaries |
| Tamper-evident record of what happened | **Detective / audit** | CloudTrail (org trail + log file validation), AWS Config, Security Hub, GuardDuty, Inspector, Macie, Detective, Audit Manager, Security Lake |
| Data unreadable even with storage access | **Cryptographic** | AWS KMS, CloudHSM, ACM, Secrets Manager, Nitro System / Nitro Enclaves |

### 1.2 Where the shared responsibility line lands for governance

Domain 2.1 teaches the shared responsibility model; 2.2 is where you *apply* it to compliance. The operationally useful phrasing:

| Layer | Who | Compliance consequence |
|---|---|---|
| Hardware, data centers, physical access, hypervisor (Nitro) | AWS | You **inherit** these controls. You do not audit the data center; you download the SOC 2 report from AWS Artifact and reference it. |
| Managed-service patching (S3, DynamoDB, Lambda runtime, RDS engine minor versions when auto-minor-upgrade is on) | AWS | Inherited or **shared** — you still own version selection and end-of-life. |
| Guest OS, application, IAM identities, network ACLs, encryption *configuration*, data classification | You | These are the controls **your** auditor tests. This is what Config rules, Security Hub standards, and Audit Manager evidence cover. |

The exam-relevant sentence: **AWS is compliant *of* the cloud; you must demonstrate compliance *in* the cloud.** An AWS PCI DSS attestation does not make your workload PCI compliant — it makes the underlying infrastructure eligible to be part of a compliant workload.

---

## 2. The governance control plane

### 2.1 AWS Organizations: the root of everything

AWS Organizations is the container that makes every other governance control possible. Key mechanics an architect must know cold:

- One **management account** (formerly "master"). It pays the bills (consolidated billing) and it is **exempt from SCPs**. This is why the management account must contain nothing but organizational tooling — no workloads, no data. A compromise of the management account is unbounded.
- **Organizational Units (OUs)** form a tree. Policies attach to the Root, an OU, or an account, and are **inherited downward**.
- **Delegated administrator**: most security services (GuardDuty, Security Hub, Config, IAM Access Analyzer, Detective, Macie, CloudTrail) can be delegated to a dedicated *Security Tooling* account, so day-to-day operation does not require management-account credentials.
- **Consolidated billing** aggregates usage for volume-tier pricing and shares Reserved Instances / Savings Plans across accounts by default.

A canonical OU layout (this is the AWS "Organizing Your AWS Environment" whitepaper structure and shows up in scenario questions):

```
Root
├── Security          (Log Archive, Security Tooling)      ← delegated admins live here
├── Infrastructure    (Network, Shared Services)
├── Workloads
│   ├── Prod
│   └── NonProd
├── Sandbox           (loose SCPs, hard billing caps, no data)
├── PolicyStaging     (test new SCPs here before Root)
└── Suspended         (deny-all SCP for decommissioned accounts)
```

### 2.2 Policy types: what actually stops the bad `put-bucket-policy`

This is the single most misunderstood area of the domain. Five distinct mechanisms constrain a request, and they compose differently.

| Mechanism | Attached to | Grants access? | Evaluated against | Beats an account admin? | Typical use |
|---|---|---|---|---|---|
| **IAM identity policy** | User / group / role | Yes | The principal | No — admin can edit it | Day-to-day permissions |
| **Resource policy** (bucket policy, key policy, SQS policy) | The resource | Yes (incl. cross-account) | The resource | No | Cross-account sharing, `aws:SecureTransport` enforcement |
| **Permissions boundary** | IAM user/role | No — caps only | The principal | No (but a boundary can be self-referentially protected by an SCP) | Safe delegation of IAM to devs |
| **SCP (Service Control Policy)** | Root / OU / account | **No — caps only** | Every principal *in the member account* | **Yes** | Org-wide invariants: region lock, deny CloudTrail deletion |
| **RCP (Resource Control Policy)** | Root / OU / account | **No — caps only** | Every request *to a resource in the account*, **including external principals** | **Yes** | "No resource in this org may be shared outside the org" |

**Effective permission = (identity policy ∩ SCP ∩ boundary ∩ RCP) ∪ applicable resource policy grants**, with any **explicit `Deny` winning unconditionally**.

Critical SCP behaviors that generate exam distractors and real 3 a.m. incidents:

- SCPs **never grant** anything. Attaching `AdministratorAccess` as an SCP gives nobody any access; it only raises the ceiling.
- SCPs **do not apply to the management account** — ever.
- SCPs **do not apply to service-linked roles** (`AWSServiceRoleFor*`).
- The default `FullAWSAccess` SCP is attached everywhere. If you attach a deny-list SCP, keep it; if you switch to an allow-list SCP, removing `FullAWSAccess` is what makes the allow-list bite — and is also how teams lock themselves out.
- **RCPs** (resource control policies) close the gap SCPs leave: an SCP constrains *your* principals, but a bucket policy granting an external account still works. RCPs constrain the resource side. At launch RCPs support Amazon S3, AWS STS, Amazon SQS, AWS KMS, and AWS Secrets Manager.
- **Declarative policies** are a newer, service-attribute–level control (initially Amazon EC2): they set a *desired configuration* — e.g. IMDSv2 required, VPC Block Public Access, allowed AMI providers — that persists even as AWS adds new APIs, rather than enumerating API actions to deny.

### 2.3 AWS Control Tower: the opinionated assembly

Control Tower is not a new control plane; it is an orchestration layer that stands up Organizations + a Log Archive account + an Audit account + an IAM Identity Center configuration + a curated control catalog, and keeps them drift-checked.

| Control type in Control Tower | Implemented as | When it fires |
|---|---|---|
| **Preventive** | SCP | Before the API call succeeds — request is denied |
| **Detective** | AWS Config rule | After the resource exists — non-compliant finding |
| **Proactive** | CloudFormation Hook | During stack deployment — before resources are created |

Trade-off table for the "how do I stand up a landing zone" decision:

| Approach | Time to first governed account | Flexibility | Drift management | Lock-in risk | Best for |
|---|---|---|---|---|---|
| Control Tower + Account Factory | Hours | Medium — curated controls, guarded regions | Built-in drift detection & re-enrollment | Medium (enrollment state is CT-owned) | Most enterprises, regulated startups |
| Control Tower + Account Factory for Terraform (AFT) | Days | High — IaC customization pipeline | CT drift + your pipeline | Medium | Terraform-native platform teams |
| Raw Organizations + your own IaC (Terraform/CDK) | Days–weeks | Total | You build it | Low | Teams with an existing, mature platform |
| Landing Zone Accelerator on AWS | Days | High, config-file driven | Solution-managed | Medium | Highly regulated (FedRAMP, DoD) |

### 2.4 Tagging as a governance primitive

Tags are the join key between security, cost, and operations. Two org-level mechanisms:

- **Tag policies** (Organizations): enforce *case and allowed values* for a tag key. They do **not** force a tag to exist on creation — that requires an SCP with `aws:RequestTag`/`aws:TagKeys` conditions, or a Config rule (`required-tags`) for detection.
- **Attribute-based access control (ABAC)**: IAM policies conditioned on `aws:PrincipalTag` vs `aws:ResourceTag`, so a single policy scales to N teams.

---

## 3. Data protection: encryption at rest and in transit

### 3.1 KMS internals — envelope encryption

You must understand *why* KMS returns two things, because it explains every KMS permission error you will ever debug.

KMS keys never leave the FIPS 140-3 validated HSM boundary. KMS therefore never encrypts your 4 TB object; it encrypts a **data key**:

```
GenerateDataKey(KeyId, KeySpec=AES_256)
   └─► { Plaintext:  <32 raw bytes>          ← used locally, then zeroized
         CiphertextBlob: <the same key, encrypted under the KMS key> }
```

The service (S3, EBS, RDS) encrypts your data with the plaintext data key, discards it from memory, and stores the `CiphertextBlob` alongside the ciphertext. On read it calls `kms:Decrypt` with the blob to recover the data key. Consequences:

1. **Throughput**: one KMS call per object/volume/snapshot, not per byte. S3 **Bucket Keys** reduce this further by ~99% by deriving a bucket-level key — critical when you hit the KMS request quota (default 5,500–50,000 req/s depending on Region and key spec).
2. **Access control is `kms:Decrypt`, not object-level ACLs.** Revoking a principal's `kms:Decrypt` makes the data unreadable to them even if they still have `s3:GetObject`. This is the "cryptographic shredding" pattern.
3. **Encryption context** — an AAD key/value map — is bound into the ciphertext. Mismatch on decrypt → `InvalidCiphertextException`. Services set it automatically (e.g. `aws:cloudtrail:arn`).

### 3.2 KMS key taxonomy

| Key type | Who owns the policy | Rotation | Visible in your account | Cost | Cross-account use |
|---|---|---|---|---|---|
| **AWS owned** | AWS | AWS-defined | No | $0 | No |
| **AWS managed** (`aws/s3`, `aws/ebs`, …) | AWS | Automatic, every year | Yes (read-only policy) | $0 for the key; API calls billed | No |
| **Customer managed (CMK)** | You | Optional; default 365 d, configurable 90–2560 d; on-demand rotation available | Yes | ~$1/key/month + $0.03 per 10k requests | **Yes**, via key policy |
| **Customer managed, custom key store (CloudHSM)** | You | Manual | Yes | Key + CloudHSM cluster cost | Yes |
| **Customer managed, external key store (XKS)** | You | Manual, external | Yes | Key + your HSM | Yes |
| **Multi-Region key** | You | Replica shares key material | Yes | Per-replica | Yes |

**Key policy is mandatory and primary.** Unlike almost every other AWS resource policy, an IAM policy alone cannot grant KMS access — the key policy must delegate to IAM (`"Principal": {"AWS": "arn:aws:iam::111122223333:root"}` + `kms:*`) or name the principal directly. Deleting a key is a **scheduled** operation with a 7–30 day waiting period, and it is irreversible: the ciphertext becomes permanently unreadable.

### 3.3 KMS vs CloudHSM

| Dimension | AWS KMS | AWS CloudHSM |
|---|---|---|
| Tenancy | Multi-tenant, AWS-managed HSM fleet | Single-tenant HSM cluster in your VPC |
| FIPS validation | 140-3 Level 3 (single-tenant HSM modules) | FIPS 140-3 Level 3 |
| Who can access keys | Nobody, including AWS operators | **Only you** — AWS has no credentials to your HSM |
| Interfaces | AWS API only | PKCS#11, JCE, OpenSSL dynamic engine, KMIP-adjacent tooling, plus AWS API via custom key store |
| Native AWS service integration | ~120 services | Only via KMS custom key store |
| Operational burden | None | You manage users, quorum (M-of-N), backups, cluster capacity |
| Typical driver | Default choice | Regulatory mandate for sole custody, offloading SSL, custom cryptography (e.g. issuing a private CA root, Oracle TDE with customer-held keys) |
| Cost model | Per key + per request | Per HSM-hour (substantially higher) |

**Decision rule:** use KMS unless a regulator or contract requires that no third party can physically or logically reach the key material — then CloudHSM, optionally fronted by a KMS custom key store to retain service integration.

### 3.4 Encryption in transit

- **ACM** issues and auto-renews **free public TLS certificates** for use with integrated services: CloudFront, ALB/NLB, API Gateway, App Runner, Cognito. Validation is DNS (CNAME — recommended, enables auto-renewal without human action) or email. Certificates are region-scoped; **CloudFront requires the certificate in `us-east-1`**. Public ACM certificates are not exportable by default — for EC2/on-prem termination use **AWS Private CA** or the paid exportable public certificate option.
- **AWS Private CA** issues internal certificates for mTLS, service meshes, IoT, and EKS webhooks. Priced per CA per month plus per certificate.
- Enforcing TLS is a *policy* act, not a *service* act — the `aws:SecureTransport` condition (§6.2) is how you actually make it non-optional.
- **VPC endpoints (PrivateLink / gateway endpoints)** keep traffic to AWS services off the public internet entirely; endpoint policies plus the `aws:SourceVpce`/`aws:SourceVpc` conditions turn network position into an authorization signal.

### 3.5 Secrets: Secrets Manager vs Parameter Store

| | Secrets Manager | SSM Parameter Store (SecureString) |
|---|---|---|
| Encryption | KMS, always | KMS for `SecureString` |
| **Automatic rotation** | **Yes** — managed Lambda rotation for RDS, Redshift, DocumentDB; custom Lambda for anything else | No (build it yourself with EventBridge + Lambda) |
| Cross-account / cross-Region replication | Native | No (replicate yourself) |
| Cost | ~$0.40/secret/month + ~$0.05 per 10k API calls | Standard tier free (10k params); Advanced ~$0.05/param/month |
| Size limit | 64 KB | 4 KB standard / 8 KB advanced |
| Best for | Database credentials, third-party API keys needing rotation | Config values, non-rotating settings, feature flags |

**Neither belongs in an environment variable committed to a repo.** In production, prefer the Secrets Manager–backed CSI driver (EKS) or the `secrets` integration in ECS task definitions so the value is injected at runtime and never lands in a task definition revision.

---

## 4. Detective controls and auditing

### 4.1 AWS CloudTrail — the evidentiary record

CloudTrail records API activity. Three event categories, with materially different costs and value:

| Event type | What it captures | Default | Cost |
|---|---|---|---|
| **Management events** | Control-plane calls: `RunInstances`, `PutBucketPolicy`, `AssumeRole`, `CreateKey` | On (90-day Event history, free); one free copy per trail | First copy free; additional copies billed |
| **Data events** | Data-plane calls: `s3:GetObject`, `lambda:Invoke`, `dynamodb:PutItem` | **Off** — must be enabled | Per event, high volume — scope with advanced event selectors |
| **Insights events** | Anomalous call-rate/error-rate deviations | Off | Per analyzed event |

Non-negotiable production configuration:

1. **Organization trail** created in the management account (or delegated admin) → every member account, current and future, is covered automatically and member admins cannot disable it.
2. **Log file validation on** → CloudTrail writes hourly **digest files** containing SHA-256 hashes of each log file and a hash of the previous digest, signed with a CloudTrail private key. This produces a hash chain: deleting or altering a single log file breaks validation. This is what makes the trail *evidence* rather than *telemetry*.
3. **Delivery to a bucket in a separate Log Archive account**, with Object Lock (WORM) and a bucket policy that denies deletion.
4. **SSE-KMS with a CMK** whose key policy allows CloudTrail to encrypt but does not allow workload accounts to decrypt.

**CloudTrail Lake** is the managed, immutable, SQL-queryable event data store (7-year+ retention) — the alternative to shipping logs into Athena yourself.

### 4.2 AWS Config — state, not calls

CloudTrail answers *"who called what"*. Config answers *"what did this resource look like at 14:32, and was it compliant?"* It records **configuration items (CIs)** on change, builds a configuration timeline and relationship graph, and evaluates **rules**.

- **Managed rules** (hundreds): `encrypted-volumes`, `s3-bucket-server-side-encryption-enabled`, `iam-root-access-key-check`, `rds-storage-encrypted`, `required-tags`, `restricted-ssh`.
- **Custom rules**: Lambda or Guard (policy-as-code DSL).
- **Conformance packs**: a deployable YAML bundle of rules + remediations, mapped to a framework (CIS, PCI DSS, NIST 800-53, HIPAA), deployable org-wide.
- **Remediation**: attach an SSM Automation document for auto-fix (e.g. re-enable bucket public access block).
- **Aggregator**: one multi-account, multi-Region compliance view.

Cost warning: Config bills per configuration item recorded and per rule evaluation. Recording *all* resource types in a high-churn account (autoscaling, Lambda versions) can dominate the security budget — use recording strategy exclusions deliberately.

### 4.3 The detection service matrix

This table is the highest-yield artifact in the whole task statement — the exam repeatedly asks "which service does X".

| Service | Question it answers | Primary data source | Agent required | Output |
|---|---|---|---|---|
| **Amazon GuardDuty** | "Is someone acting maliciously *right now*?" | CloudTrail, VPC Flow Logs, Route 53 DNS logs, EKS audit logs, S3 data events, RDS login activity, Lambda network activity — **consumed without you enabling them** | No | Threat findings (crypto-mining, credential exfiltration to a Tor exit node, impossible-travel API calls) |
| **Amazon Inspector** | "Is my software vulnerable?" | EC2, ECR container images, Lambda functions & layers, source code repos | Uses SSM Agent for EC2 (agentless option available) | CVE findings with an Inspector risk score |
| **Amazon Macie** | "Where is my sensitive data?" | Amazon S3 objects | No | Sensitive-data findings (PII, credentials, PHI) + bucket inventory |
| **Amazon Detective** | "What is the blast radius of this finding?" | CloudTrail, VPC Flow Logs, GuardDuty, EKS audit logs → behavior graph | No | Investigation graph, entity timelines |
| **AWS Security Hub** | "What is my overall posture, in one place?" | Aggregates GuardDuty, Inspector, Macie, Config, IAM Access Analyzer, Firewall Manager, partner products | No | Normalized ASFF findings, security scores, standards compliance (AWS FSBP, CIS, PCI DSS, NIST 800-53) |
| **AWS Audit Manager** | "Can I hand my auditor evidence without a spreadsheet?" | CloudTrail, Config, Security Hub, API calls | No | Framework-mapped, time-stamped evidence and an assessment report |
| **AWS Trusted Advisor** | "Am I following AWS best practices?" | Account metadata + service APIs | No | Checks across cost optimization, performance, **security**, fault tolerance, service limits, operational excellence |
| **IAM Access Analyzer** | "Is anything reachable from outside my zone of trust? Which permissions are unused?" | Automated reasoning (provable security) over resource and identity policies | No | External-access, unused-access findings; custom policy checks in CI |
| **Amazon Security Lake** | "Can I query five years of security telemetry across accounts?" | Normalizes AWS + third-party logs to **OCSF** in your S3 | No | Queryable lake (Athena, OpenSearch, partner SIEM) |

Mnemonic pairs that disambiguate the classic distractors:

- **GuardDuty = threats (behavior)** · **Inspector = vulnerabilities (software)** · **Macie = data (content)** · **Config = configuration (state)** · **CloudTrail = actions (who)** · **Detective = investigation (why/how far)** · **Security Hub = aggregation (all of the above)**.
- **Trusted Advisor = advice**, not a security finding pipeline. **Audit Manager = evidence for auditors**, not detection.

### 4.4 Where CloudWatch fits

CloudWatch is *observability*, but two features are governance-load-bearing:

- **CloudWatch Logs metric filters + alarms** on the CloudTrail log group — the classic CIS Benchmark controls (alarm on root account usage, on IAM policy changes, on CloudTrail configuration changes).
- **EventBridge rules** on CloudTrail events for near-real-time response (e.g. `DeleteTrail` → SNS page + Lambda re-create).

---

## 5. Compliance, geography, and sovereignty

### 5.1 AWS Artifact

**AWS Artifact is the self-service portal for AWS's own compliance evidence** — this is the answer to "where do I download AWS's SOC 2 report?"

- **Artifact Reports**: SOC 1/2/3, ISO 27001/27017/27018/9001, PCI DSS AOC, FedRAMP packages, C5 (Germany), IRAP (Australia), HITRUST, and ISV third-party reports.
- **Artifact Agreements**: accept legal agreements on behalf of your account or organization — notably the **HIPAA Business Associate Addendum (BAA)** and NDAs required to access certain reports.

Access is controlled by IAM; several reports require accepting an NDA before download. Artifact does **not** produce evidence about *your* workloads — that is Audit Manager.

### 5.2 Compliance programs vary by geography and industry

| Driver | Program | Practical AWS consequence |
|---|---|---|
| US healthcare | HIPAA/HITECH | Accept the BAA in Artifact; use only HIPAA-eligible services; encrypt PHI at rest and in transit |
| Payment cards | PCI DSS Level 1 | AWS is a Level 1 Service Provider; you still scope your CDE, segment it, and produce your own AOC |
| EU personal data | GDPR | AWS offers a Data Processing Addendum; you choose the Region, control transfers, and remain the controller |
| US federal | FedRAMP / DoD SRG | Use **AWS GovCloud (US)** or approved Regions; ITAR workloads → GovCloud |
| Germany | BSI C5 | Regional attestations available in Artifact |
| Australia | IRAP | Asserted for specific Regions |
| China | CSL/MLPS | The **AWS China (Beijing/Ningxia)** partitions are operated by Chinese partners (Sinnet, NWCD), are a **separate partition** (`aws-cn`), require a separate account, and are not part of the global org |

### 5.3 Data residency and sovereignty

- **Your data stays in the Region you choose.** AWS does not replicate customer data across Regions unless you configure it (S3 CRR, DynamoDB global tables, AMI copy, backup copy). Some *service metadata* (e.g. IAM, Route 53, CloudFront, Organizations — global services) is inherently global; know which services are global vs regional.
- **Enforcement is a policy act**, not a hope. The `aws:RequestedRegion` SCP condition (§6.2) is the mechanism.
- **Sovereignty tiers**, from least to most isolated: standard Region → **Dedicated Local Zones** / **Outposts** (AWS infrastructure on your premises or in a designated facility) → **AWS European Sovereign Cloud** (operationally independent, EU-resident personnel and control plane) → **GovCloud (US)** → **AWS China partition** (separate legal entity and partition).
- **The AWS Nitro System** underpins the technical argument: the Nitro hypervisor has no interactive access mechanism, no operator SSH, and no ability to read instance memory. **Nitro Enclaves** extend this to isolated compute with no persistent storage, no interactive access, and no external networking — with cryptographic attestation that a KMS key policy can require via the `kms:RecipientAttestation` condition.

---

## 6. Complete infrastructure: a governance baseline

### 6.1 CloudFormation — organization trail, CMK, Config, Security Hub, GuardDuty

Deploy in the **Log Archive / Security Tooling** account for the bucket, and the **management account (or delegated admin)** for the organization trail. Presented as one template for readability; in production split it across stack sets.

```yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: >
  Governance baseline: tamper-evident organization CloudTrail encrypted with a
  customer managed KMS key, AWS Config recorder with core compliance rules,
  Security Hub with FSBP enabled, GuardDuty, and an alerting path for
  security-control tampering.

Parameters:
  OrganizationId:
    Type: String
    Description: AWS Organizations ID (o-xxxxxxxxxx). Used in the S3 log prefix.
    AllowedPattern: '^o-[a-z0-9]{10,32}$'
  ManagementAccountId:
    Type: String
    Description: Account ID of the Organizations management account.
    AllowedPattern: '^[0-9]{12}$'
  TrailName:
    Type: String
    Default: org-governance-trail
  SecurityContactEmail:
    Type: String
    Description: Subscribed to the security alert topic.
  LogRetentionDays:
    Type: Number
    Default: 2555          # 7 years, typical financial-services retention
    MinValue: 365

Resources:

  # ------------------------------------------------------------------
  # 1. Customer managed KMS key for the trail
  # ------------------------------------------------------------------
  TrailKmsKey:
    Type: AWS::KMS::Key
    DeletionPolicy: Retain
    UpdateReplacePolicy: Retain
    Properties:
      Description: Encrypts organization CloudTrail log files.
      EnableKeyRotation: true
      RotationPeriodInDays: 365
      PendingWindowInDays: 30
      KeyPolicy:
        Version: '2012-10-17'
        Id: trail-key-policy
        Statement:
          - Sid: EnableIamUserPermissions
            Effect: Allow
            Principal:
              AWS: !Sub 'arn:${AWS::Partition}:iam::${AWS::AccountId}:root'
            Action: 'kms:*'
            Resource: '*'

          - Sid: AllowCloudTrailToEncryptLogs
            Effect: Allow
            Principal:
              Service: cloudtrail.amazonaws.com
            Action: 'kms:GenerateDataKey*'
            Resource: '*'
            Condition:
              StringLike:
                'kms:EncryptionContext:aws:cloudtrail:arn':
                  !Sub 'arn:${AWS::Partition}:cloudtrail:*:${ManagementAccountId}:trail/*'
              StringEquals:
                'aws:SourceArn':
                  !Sub 'arn:${AWS::Partition}:cloudtrail:${AWS::Region}:${ManagementAccountId}:trail/${TrailName}'

          - Sid: AllowCloudTrailDescribeKey
            Effect: Allow
            Principal:
              Service: cloudtrail.amazonaws.com
            Action: 'kms:DescribeKey'
            Resource: '*'

          - Sid: AllowOrgMembersToDecryptTheirOwnLogs
            Effect: Allow
            Principal:
              AWS: '*'
            Action:
              - 'kms:Decrypt'
              - 'kms:ReEncryptFrom'
            Resource: '*'
            Condition:
              StringEquals:
                'aws:PrincipalOrgID': !Ref OrganizationId
              StringLike:
                'kms:EncryptionContext:aws:cloudtrail:arn':
                  !Sub 'arn:${AWS::Partition}:cloudtrail:*:${ManagementAccountId}:trail/*'

  TrailKmsKeyAlias:
    Type: AWS::KMS::Alias
    Properties:
      AliasName: alias/org-cloudtrail
      TargetKeyId: !Ref TrailKmsKey

  # ------------------------------------------------------------------
  # 2. WORM log archive bucket
  # ------------------------------------------------------------------
  TrailBucket:
    Type: AWS::S3::Bucket
    DeletionPolicy: Retain
    UpdateReplacePolicy: Retain
    Properties:
      BucketName: !Sub 'org-cloudtrail-${AWS::AccountId}-${AWS::Region}'
      ObjectLockEnabled: true
      ObjectLockConfiguration:
        ObjectLockEnabled: Enabled
        Rule:
          DefaultRetention:
            Mode: COMPLIANCE      # not even the root user can shorten this
            Days: 365
      VersioningConfiguration:
        Status: Enabled
      PublicAccessBlockConfiguration:
        BlockPublicAcls: true
        BlockPublicPolicy: true
        IgnorePublicAcls: true
        RestrictPublicBuckets: true
      BucketEncryption:
        ServerSideEncryptionConfiguration:
          - BucketKeyEnabled: true
            ServerSideEncryptionByDefault:
              SSEAlgorithm: 'aws:kms'
              KMSMasterKeyID: !Ref TrailKmsKey
      LifecycleConfiguration:
        Rules:
          - Id: tier-and-expire
            Status: Enabled
            Transitions:
              - StorageClass: STANDARD_IA
                TransitionInDays: 90
              - StorageClass: GLACIER
                TransitionInDays: 365
            ExpirationInDays: !Ref LogRetentionDays
      Tags:
        - Key: DataClassification
          Value: audit-evidence
        - Key: Compliance
          Value: 'soc2,pci-dss,iso27001'

  TrailBucketPolicy:
    Type: AWS::S3::BucketPolicy
    Properties:
      Bucket: !Ref TrailBucket
      PolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Sid: AWSCloudTrailAclCheck
            Effect: Allow
            Principal:
              Service: cloudtrail.amazonaws.com
            Action: 's3:GetBucketAcl'
            Resource: !GetAtt TrailBucket.Arn
            Condition:
              StringEquals:
                'aws:SourceArn':
                  !Sub 'arn:${AWS::Partition}:cloudtrail:${AWS::Region}:${ManagementAccountId}:trail/${TrailName}'

          - Sid: AWSCloudTrailWriteOrgLogs
            Effect: Allow
            Principal:
              Service: cloudtrail.amazonaws.com
            Action: 's3:PutObject'
            Resource:
              - !Sub '${TrailBucket.Arn}/AWSLogs/${ManagementAccountId}/*'
              - !Sub '${TrailBucket.Arn}/AWSLogs/${OrganizationId}/*'
            Condition:
              StringEquals:
                's3:x-amz-acl': 'bucket-owner-full-control'
                'aws:SourceArn':
                  !Sub 'arn:${AWS::Partition}:cloudtrail:${AWS::Region}:${ManagementAccountId}:trail/${TrailName}'

          - Sid: DenyUnencryptedTransport
            Effect: Deny
            Principal: '*'
            Action: 's3:*'
            Resource:
              - !GetAtt TrailBucket.Arn
              - !Sub '${TrailBucket.Arn}/*'
            Condition:
              Bool:
                'aws:SecureTransport': 'false'

          - Sid: DenyLogTampering
            Effect: Deny
            Principal: '*'
            Action:
              - 's3:DeleteObject'
              - 's3:DeleteObjectVersion'
              - 's3:PutObjectRetention'
              - 's3:PutLifecycleConfiguration'
            Resource: !Sub '${TrailBucket.Arn}/*'
            Condition:
              StringNotEquals:
                'aws:PrincipalArn':
                  !Sub 'arn:${AWS::Partition}:iam::${AWS::AccountId}:role/LogArchiveBreakGlass'

  # ------------------------------------------------------------------
  # 3. Organization trail  (deploy this resource in the management account)
  # ------------------------------------------------------------------
  OrganizationTrail:
    Type: AWS::CloudTrail::Trail
    DependsOn: TrailBucketPolicy
    Properties:
      TrailName: !Ref TrailName
      S3BucketName: !Ref TrailBucket
      KMSKeyId: !Ref TrailKmsKey
      IsLogging: true
      IsMultiRegionTrail: true
      IsOrganizationTrail: true
      IncludeGlobalServiceEvents: true
      EnableLogFileValidation: true         # <-- produces the signed digest chain
      CloudWatchLogsLogGroupArn: !GetAtt TrailLogGroup.Arn
      CloudWatchLogsRoleArn: !GetAtt TrailToCwlRole.Arn
      AdvancedEventSelectors:
        - Name: All management events
          FieldSelectors:
            - Field: eventCategory
              Equals: ['Management']
        - Name: S3 data events on classified buckets only
          FieldSelectors:
            - Field: eventCategory
              Equals: ['Data']
            - Field: resources.type
              Equals: ['AWS::S3::Object']
            - Field: resources.ARN
              StartsWith:
                - !Sub 'arn:${AWS::Partition}:s3:::regulated-'
      Tags:
        - Key: Purpose
          Value: audit-evidence

  TrailLogGroup:
    Type: AWS::Logs::LogGroup
    Properties:
      LogGroupName: /aws/cloudtrail/org-governance
      RetentionInDays: 365
      KmsKeyId: !GetAtt TrailKmsKey.Arn

  TrailToCwlRole:
    Type: AWS::IAM::Role
    Properties:
      AssumeRolePolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Effect: Allow
            Principal:
              Service: cloudtrail.amazonaws.com
            Action: 'sts:AssumeRole'
      Policies:
        - PolicyName: write-to-cwl
          PolicyDocument:
            Version: '2012-10-17'
            Statement:
              - Effect: Allow
                Action:
                  - 'logs:CreateLogStream'
                  - 'logs:PutLogEvents'
                Resource: !Sub '${TrailLogGroup.Arn}:log-stream:*'

  # ------------------------------------------------------------------
  # 4. AWS Config
  # ------------------------------------------------------------------
  ConfigRole:
    Type: AWS::IAM::Role
    Properties:
      AssumeRolePolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Effect: Allow
            Principal:
              Service: config.amazonaws.com
            Action: 'sts:AssumeRole'
      ManagedPolicyArns:
        - !Sub 'arn:${AWS::Partition}:iam::aws:policy/service-role/AWS_ConfigRole'
      Policies:
        - PolicyName: config-delivery
          PolicyDocument:
            Version: '2012-10-17'
            Statement:
              - Effect: Allow
                Action: 's3:PutObject'
                Resource: !Sub '${TrailBucket.Arn}/config/*'
                Condition:
                  StringEquals:
                    's3:x-amz-acl': 'bucket-owner-full-control'
              - Effect: Allow
                Action: 's3:GetBucketAcl'
                Resource: !GetAtt TrailBucket.Arn
              - Effect: Allow
                Action:
                  - 'kms:GenerateDataKey'
                  - 'kms:Decrypt'
                Resource: !GetAtt TrailKmsKey.Arn

  ConfigRecorder:
    Type: AWS::Config::ConfigurationRecorder
    Properties:
      Name: default
      RoleARN: !GetAtt ConfigRole.Arn
      RecordingGroup:
        AllSupported: true
        IncludeGlobalResourceTypes: true
      RecordingMode:
        RecordingFrequency: CONTINUOUS

  ConfigDeliveryChannel:
    Type: AWS::Config::DeliveryChannel
    Properties:
      Name: default
      S3BucketName: !Ref TrailBucket
      S3KeyPrefix: config
      S3KmsKeyArn: !GetAtt TrailKmsKey.Arn
      ConfigSnapshotDeliveryProperties:
        DeliveryFrequency: TwentyFour_Hours

  RuleCloudTrailEnabled:
    Type: AWS::Config::ConfigRule
    DependsOn: ConfigRecorder
    Properties:
      ConfigRuleName: cloudtrail-enabled
      Description: A CloudTrail trail must be enabled in this account.
      Source:
        Owner: AWS
        SourceIdentifier: CLOUD_TRAIL_ENABLED

  RuleEncryptedVolumes:
    Type: AWS::Config::ConfigRule
    DependsOn: ConfigRecorder
    Properties:
      ConfigRuleName: encrypted-volumes
      Description: All attached EBS volumes must be encrypted.
      Scope:
        ComplianceResourceTypes:
          - 'AWS::EC2::Volume'
      Source:
        Owner: AWS
        SourceIdentifier: ENCRYPTED_VOLUMES

  RuleS3PublicReadProhibited:
    Type: AWS::Config::ConfigRule
    DependsOn: ConfigRecorder
    Properties:
      ConfigRuleName: s3-bucket-public-read-prohibited
      Scope:
        ComplianceResourceTypes:
          - 'AWS::S3::Bucket'
      Source:
        Owner: AWS
        SourceIdentifier: S3_BUCKET_PUBLIC_READ_PROHIBITED

  RuleRootAccessKeyCheck:
    Type: AWS::Config::ConfigRule
    DependsOn: ConfigRecorder
    Properties:
      ConfigRuleName: iam-root-access-key-check
      MaximumExecutionFrequency: TwentyFour_Hours
      Source:
        Owner: AWS
        SourceIdentifier: IAM_ROOT_ACCESS_KEY_CHECK

  RuleRequiredTags:
    Type: AWS::Config::ConfigRule
    DependsOn: ConfigRecorder
    Properties:
      ConfigRuleName: required-tags
      Scope:
        ComplianceResourceTypes:
          - 'AWS::EC2::Instance'
          - 'AWS::S3::Bucket'
          - 'AWS::RDS::DBInstance'
      InputParameters:
        tag1Key: Owner
        tag2Key: CostCenter
        tag3Key: DataClassification
      Source:
        Owner: AWS
        SourceIdentifier: REQUIRED_TAGS

  # ------------------------------------------------------------------
  # 5. Detection services
  # ------------------------------------------------------------------
  GuardDutyDetector:
    Type: AWS::GuardDuty::Detector
    Properties:
      Enable: true
      FindingPublishingFrequency: FIFTEEN_MINUTES
      DataSources:
        S3Logs:
          Enable: true
        Kubernetes:
          AuditLogs:
            Enable: true
        MalwareProtection:
          ScanEc2InstanceWithFindings:
            EbsVolumes: true

  SecurityHub:
    Type: AWS::SecurityHub::Hub
    Properties:
      Tags:
        Purpose: posture-management

  FoundationalSecurityStandard:
    Type: AWS::SecurityHub::Standard
    DependsOn: SecurityHub
    Properties:
      StandardsArn:
        !Sub 'arn:${AWS::Partition}:securityhub:${AWS::Region}::standards/aws-foundational-security-best-practices/v/1.0.0'

  # ------------------------------------------------------------------
  # 6. Tamper alerting
  # ------------------------------------------------------------------
  SecurityAlertTopic:
    Type: AWS::SNS::Topic
    Properties:
      TopicName: security-control-tampering
      KmsMasterKeyId: alias/aws/sns
      Subscription:
        - Protocol: email
          Endpoint: !Ref SecurityContactEmail

  SecurityAlertTopicPolicy:
    Type: AWS::SNS::TopicPolicy
    Properties:
      Topics:
        - !Ref SecurityAlertTopic
      PolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Sid: AllowEventBridgePublish
            Effect: Allow
            Principal:
              Service: events.amazonaws.com
            Action: 'sns:Publish'
            Resource: !Ref SecurityAlertTopic

  ControlTamperingRule:
    Type: AWS::Events::Rule
    Properties:
      Name: detect-security-control-tampering
      Description: Fires when someone tries to disable an audit or detection control.
      EventPattern:
        source:
          - aws.cloudtrail
          - aws.config
          - aws.guardduty
          - aws.kms
        detail-type:
          - 'AWS API Call via CloudTrail'
        detail:
          eventName:
            - StopLogging
            - DeleteTrail
            - UpdateTrail
            - PutEventSelectors
            - DeleteConfigurationRecorder
            - StopConfigurationRecorder
            - DeleteDeliveryChannel
            - DeleteDetector
            - UpdateDetector
            - DisableSecurityHub
            - ScheduleKeyDeletion
            - DisableKeyRotation
      State: ENABLED
      Targets:
        - Id: notify-security
          Arn: !Ref SecurityAlertTopic
          InputTransformer:
            InputPathsMap:
              account: '$.account'
              region: '$.region'
              event: '$.detail.eventName'
              who: '$.detail.userIdentity.arn'
              time: '$.time'
            InputTemplate: >-
              "SECURITY CONTROL TAMPERING: <event> in account <account> (<region>)
              by <who> at <time>."

Outputs:
  TrailBucketName:
    Description: WORM audit-evidence bucket.
    Value: !Ref TrailBucket
    Export:
      Name: !Sub '${AWS::StackName}-TrailBucket'
  TrailKmsKeyArn:
    Description: CMK protecting audit evidence.
    Value: !GetAtt TrailKmsKey.Arn
    Export:
      Name: !Sub '${AWS::StackName}-TrailKmsKey'
  OrganizationTrailArn:
    Value: !GetAtt OrganizationTrail.Arn
```

### 6.2 Service Control Policy — the invariants

`scp-baseline-guardrails.json`, attached to the **Workloads** OU:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DenyLeavingTheOrganization",
      "Effect": "Deny",
      "Action": [
        "organizations:LeaveOrganization",
        "organizations:DeleteOrganization"
      ],
      "Resource": "*"
    },
    {
      "Sid": "ProtectAuditAndDetectionControls",
      "Effect": "Deny",
      "Action": [
        "cloudtrail:StopLogging",
        "cloudtrail:DeleteTrail",
        "cloudtrail:UpdateTrail",
        "cloudtrail:PutEventSelectors",
        "config:DeleteConfigurationRecorder",
        "config:StopConfigurationRecorder",
        "config:DeleteDeliveryChannel",
        "config:DeleteConfigRule",
        "guardduty:DeleteDetector",
        "guardduty:DisassociateFromMasterAccount",
        "guardduty:UpdateDetector",
        "securityhub:DisableSecurityHub",
        "securityhub:DeleteMembers",
        "macie2:DisableMacie",
        "access-analyzer:DeleteAnalyzer"
      ],
      "Resource": "*",
      "Condition": {
        "ArnNotLike": {
          "aws:PrincipalArn": [
            "arn:aws:iam::*:role/AWSControlTowerExecution",
            "arn:aws:iam::*:role/OrgSecurityAutomation"
          ]
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
      "Sid": "RegionLockForDataResidency",
      "Effect": "Deny",
      "NotAction": [
        "iam:*",
        "organizations:*",
        "sts:*",
        "route53:*",
        "cloudfront:*",
        "support:*",
        "budgets:*",
        "waf:*",
        "wafv2:*",
        "shield:*",
        "health:*",
        "trustedadvisor:*",
        "artifact:*",
        "account:*",
        "ce:*",
        "cur:*"
      ],
      "Resource": "*",
      "Condition": {
        "StringNotEquals": {
          "aws:RequestedRegion": [
            "eu-central-1",
            "eu-west-1"
          ]
        }
      }
    },
    {
      "Sid": "RequireEncryptionAtRestOnEbsAndRds",
      "Effect": "Deny",
      "Action": [
        "ec2:CreateVolume",
        "rds:CreateDBInstance",
        "rds:CreateDBCluster"
      ],
      "Resource": "*",
      "Condition": {
        "Bool": {
          "ec2:Encrypted": "false"
        }
      }
    },
    {
      "Sid": "RequireImdsV2OnLaunch",
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
      "Sid": "ProtectKmsKeyMaterial",
      "Effect": "Deny",
      "Action": [
        "kms:ScheduleKeyDeletion",
        "kms:DisableKeyRotation",
        "kms:DisableKey",
        "kms:PutKeyPolicy"
      ],
      "Resource": "arn:aws:kms:*:*:key/*",
      "Condition": {
        "ArnNotLike": {
          "aws:PrincipalArn": "arn:aws:iam::*:role/KmsKeyAdministrator"
        }
      }
    },
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
          "aws:PrincipalArn": "arn:aws:iam::*:role/OrgSecurityAutomation"
        }
      }
    }
  ]
}
```

> **Note on `DenyRootUserActions`:** SCPs do not apply to the management account, and certain tasks genuinely require root (closing an account, changing the account root email, some S3 MFA-delete operations). Scope this statement carefully and keep a documented, alarmed break-glass procedure.

### 6.3 Resource Control Policy — closing the external-sharing gap

`rcp-no-external-sharing.json`, attached to the **Workloads** OU. This denies *any* access to S3, STS, SQS, KMS, and Secrets Manager resources in those accounts from principals outside the organization, regardless of what a bucket policy says:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "EnforceOrgIdentityPerimeter",
      "Effect": "Deny",
      "Principal": "*",
      "Action": [
        "s3:*",
        "sts:AssumeRole",
        "sqs:*",
        "kms:*",
        "secretsmanager:*"
      ],
      "Resource": "*",
      "Condition": {
        "StringNotEqualsIfExists": {
          "aws:PrincipalOrgID": "o-a1b2c3d4e5"
        },
        "BoolIfExists": {
          "aws:PrincipalIsAWSService": "false"
        }
      }
    },
    {
      "Sid": "EnforceTlsOnAllDataResources",
      "Effect": "Deny",
      "Principal": "*",
      "Action": [
        "s3:*",
        "sqs:*",
        "secretsmanager:*"
      ],
      "Resource": "*",
      "Condition": {
        "BoolIfExists": {
          "aws:SecureTransport": "false"
        }
      }
    }
  ]
}
```

### 6.4 Tag policy

`tag-policy-cost-and-classification.json`:

```json
{
  "tags": {
    "DataClassification": {
      "tag_key": { "@@assign": "DataClassification" },
      "tag_value": {
        "@@assign": ["public", "internal", "confidential", "restricted"]
      },
      "enforced_for": {
        "@@assign": ["s3:bucket", "rds:db", "dynamodb:table", "ec2:volume"]
      }
    },
    "CostCenter": {
      "tag_key": { "@@assign": "CostCenter" },
      "enforced_for": { "@@assign": ["ec2:instance", "rds:db"] }
    },
    "Owner": {
      "tag_key": { "@@assign": "Owner" }
    }
  }
}
```

### 6.5 Terraform — attaching the policies org-wide

```hcl
terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.60" }
  }
}

provider "aws" {
  region = "eu-central-1"
  # Runs with management-account credentials.
}

data "aws_organizations_organization" "this" {}

resource "aws_organizations_organizational_unit" "workloads" {
  name      = "Workloads"
  parent_id = data.aws_organizations_organization.this.roots[0].id
}

resource "aws_organizations_policy" "baseline_guardrails" {
  name        = "baseline-guardrails"
  description = "Org invariants: no leaving, no control tampering, region lock, encryption required."
  type        = "SERVICE_CONTROL_POLICY"
  content     = file("${path.module}/policies/scp-baseline-guardrails.json")
}

resource "aws_organizations_policy_attachment" "baseline_to_workloads" {
  policy_id = aws_organizations_policy.baseline_guardrails.id
  target_id = aws_organizations_organizational_unit.workloads.id
}

resource "aws_organizations_policy" "identity_perimeter" {
  name    = "no-external-sharing"
  type    = "RESOURCE_CONTROL_POLICY"
  content = file("${path.module}/policies/rcp-no-external-sharing.json")
}

resource "aws_organizations_policy_attachment" "rcp_to_workloads" {
  policy_id = aws_organizations_policy.identity_perimeter.id
  target_id = aws_organizations_organizational_unit.workloads.id
}

resource "aws_organizations_policy" "tagging" {
  name    = "cost-and-classification-tags"
  type    = "TAG_POLICY"
  content = file("${path.module}/policies/tag-policy-cost-and-classification.json")
}

resource "aws_organizations_policy_attachment" "tags_to_root" {
  policy_id = aws_organizations_policy.tagging.id
  target_id = data.aws_organizations_organization.this.roots[0].id
}

# Delegate security service administration out of the management account.
resource "aws_organizations_delegated_administrator" "guardduty" {
  account_id        = var.security_tooling_account_id
  service_principal = "guardduty.amazonaws.com"
}

resource "aws_organizations_delegated_administrator" "securityhub" {
  account_id        = var.security_tooling_account_id
  service_principal = "securityhub.amazonaws.com"
}

resource "aws_organizations_delegated_administrator" "config" {
  account_id        = var.security_tooling_account_id
  service_principal = "config.amazonaws.com"
}

variable "security_tooling_account_id" {
  type        = string
  description = "Account ID of the Security Tooling account."
}
```

---

## 7. CLI operations

### 7.1 Inspecting the organization and its policies

```console
$ aws organizations describe-organization --query 'Organization.[Id,MasterAccountId,FeatureSet]' --output text
o-a1b2c3d4e5    111122223333    ALL

$ aws organizations list-roots --query 'Roots[0].PolicyTypes'
[
    {
        "Type": "SERVICE_CONTROL_POLICY",
        "Status": "ENABLED"
    },
    {
        "Type": "RESOURCE_CONTROL_POLICY",
        "Status": "ENABLED"
    },
    {
        "Type": "TAG_POLICY",
        "Status": "ENABLED"
    }
]

$ aws organizations list-policies-for-target \
    --target-id ou-ab12-3cdefgh4 \
    --filter SERVICE_CONTROL_POLICY \
    --output table
-------------------------------------------------------------------------------
|                          ListPoliciesForTarget                              |
+-------------+---------------------------+----------------+------------------+
|     Arn     |        Description        |      Id        |      Name        |
+-------------+---------------------------+----------------+------------------+
| arn:aws:... | Allows access to every... | p-FullAWSAccess| FullAWSAccess    |
| arn:aws:... | Org invariants: no lea... | p-8x2k9m4q     | baseline-guard.. |
+-------------+---------------------------+----------------+------------------+
```

### 7.2 What a blocked request actually looks like

```console
$ aws ec2 run-instances --image-id ami-0abcdef1234567890 \
    --instance-type t3.micro --region us-west-2

An error occurred (UnauthorizedOperation) when calling the RunInstances operation:
You are not authorized to perform this operation. User:
arn:aws:sts::444455556666:assumed-role/PlatformEngineer/alex is not authorized to
perform: ec2:RunInstances with an explicit deny in a service control policy.
```

The phrase **"with an explicit deny in a service control policy"** is the diagnostic signal — the identity policy is irrelevant; go read the SCP chain. Compare with the RCP form:

```console
$ aws s3api get-object --bucket regulated-eu-features \
    --key train.parquet /tmp/train.parquet --profile partner-account

An error occurred (AccessDenied) when calling the GetObject operation: User:
arn:aws:iam::999988887777:user/partner-etl is not authorized to perform:
s3:GetObject on resource: "arn:aws:s3:::regulated-eu-features/train.parquet"
with an explicit deny in a resource control policy.
```

### 7.3 Proving the audit trail is intact

```console
$ aws cloudtrail get-trail-status --name org-governance-trail \
    --query '[IsLogging,LatestDeliveryTime,LatestDeliveryError]' --output text
True    2026-09-03T11:04:18+00:00    None

$ aws cloudtrail describe-trails --trail-name-list org-governance-trail \
    --query 'trailList[0].[IsOrganizationTrail,LogFileValidationEnabled,KmsKeyId]' \
    --output text
True    True    arn:aws:kms:eu-central-1:222233334444:key/1a2b3c4d-5e6f-7890-abcd-ef1234567890

$ aws cloudtrail validate-logs \
    --trail-arn arn:aws:cloudtrail:eu-central-1:111122223333:trail/org-governance-trail \
    --start-time 2026-09-01T00:00:00Z \
    --end-time   2026-09-03T00:00:00Z

Validating log files for trail arn:aws:cloudtrail:eu-central-1:111122223333:trail/org-governance-trail
between 2026-09-01T00:00:00Z and 2026-09-03T00:00:00Z

Results requested for 2026-09-01T00:00:00Z to 2026-09-03T00:00:00Z
Results found for 2026-09-01T00:00:00Z to 2026-09-03T00:00:00Z:

48/48 digest files valid
1,204/1,204 log files valid
```

A tampered archive fails loudly and names the file:

```console
$ aws cloudtrail validate-logs --trail-arn arn:aws:cloudtrail:...:trail/org-governance-trail \
    --start-time 2026-08-28T00:00:00Z

Log file  s3://org-cloudtrail-222233334444-eu-central-1/AWSLogs/o-a1b2c3d4e5/444455556666/CloudTrail/eu-central-1/2026/08/28/444455556666_CloudTrail_eu-central-1_20260828T1420Z_kQ2mR9.json.gz
INVALID: hash value doesn't match

24/25 digest files valid
611/612 log files valid
```

### 7.4 Config compliance queries

```console
$ aws configservice describe-configuration-recorder-status \
    --query 'ConfigurationRecordersStatus[0].[name,recording,lastStatus]' --output text
default True    SUCCESS

$ aws configservice describe-compliance-by-config-rule \
    --config-rule-names encrypted-volumes s3-bucket-public-read-prohibited \
    --output table
------------------------------------------------------------------
|                  DescribeComplianceByConfigRule                 |
+------------------------------------+----------------------------+
|            ConfigRuleName          |      ComplianceType        |
+------------------------------------+----------------------------+
|  encrypted-volumes                 |  NON_COMPLIANT             |
|  s3-bucket-public-read-prohibited  |  COMPLIANT                 |
+------------------------------------+----------------------------+

$ aws configservice get-compliance-details-by-config-rule \
    --config-rule-name encrypted-volumes \
    --compliance-types NON_COMPLIANT \
    --query 'EvaluationResults[].EvaluationResultIdentifier.EvaluationResultQualifier.ResourceId' \
    --output text
vol-0f2a91c4e8b7d3a10    vol-04c81b9de77f2a3b5

$ aws configservice select-resource-config \
    --expression "SELECT resourceId, resourceName, tags WHERE resourceType = 'AWS::S3::Bucket' AND tags.key = 'DataClassification' AND tags.value = 'restricted'"
{
    "Results": [
        "{\"resourceId\":\"regulated-eu-features\",\"resourceName\":\"regulated-eu-features\",\"tags\":[{\"key\":\"DataClassification\",\"value\":\"restricted\"}]}"
    ]
}
```

### 7.5 KMS

```console
$ aws kms describe-key --key-id alias/org-cloudtrail \
    --query 'KeyMetadata.[KeyId,KeyState,KeyManager,KeySpec,MultiRegion]' --output text
1a2b3c4d-5e6f-7890-abcd-ef1234567890    Enabled    CUSTOMER    SYMMETRIC_DEFAULT    False

$ aws kms get-key-rotation-status --key-id alias/org-cloudtrail
{
    "KeyRotationEnabled": true,
    "KeyId": "arn:aws:kms:eu-central-1:222233334444:key/1a2b3c4d-5e6f-7890-abcd-ef1234567890",
    "RotationPeriodInDays": 365,
    "NextRotationDate": "2027-02-14T09:31:02+00:00"
}

# Envelope encryption, by hand — this is exactly what S3 and EBS do for you.
$ aws kms generate-data-key --key-id alias/app-data --key-spec AES_256 \
    --encryption-context tenant=acme,env=prod \
    --query '[Plaintext,CiphertextBlob]' --output text
wEXAMPLEplaintextkeybase64...=    AQIDAHjRYlEXAMPLEciphertextblob...==

$ aws kms decrypt --ciphertext-blob fileb://key.enc \
    --encryption-context tenant=acme,env=prod \
    --query Plaintext --output text | base64 -d > /dev/shm/dek.bin
```

A wrong encryption context is a hard failure — this is the single most common KMS support case:

```console
$ aws kms decrypt --ciphertext-blob fileb://key.enc --encryption-context tenant=acme

An error occurred (InvalidCiphertextException) when calling the Decrypt operation:
```

### 7.6 Detection services and Artifact

```console
$ aws guardduty list-detectors --query DetectorIds --output text
d4c2f19a83b7e05d61ff3a9c8e77b214

$ aws guardduty get-findings-statistics --detector-id d4c2f19a83b7e05d61ff3a9c8e77b214 \
    --finding-statistic-types COUNT_BY_SEVERITY
{
    "FindingStatistics": {
        "CountBySeverity": {
            "2": 41,
            "5": 7,
            "8": 2
        }
    }
}

$ aws securityhub get-findings \
    --filters '{"SeverityLabel":[{"Value":"CRITICAL","Comparison":"EQUALS"}],"RecordState":[{"Value":"ACTIVE","Comparison":"EQUALS"}]}' \
    --max-results 3 \
    --query 'Findings[].[ProductName,Title,Resources[0].Id]' --output text
GuardDuty   UnauthorizedAccess:EC2/MaliciousIPCaller.Custom   arn:aws:ec2:eu-central-1:444455556666:instance/i-0d91ac2f7b8e4c530
Inspector   CVE-2026-21894 - openssl                          arn:aws:ecr:eu-central-1:444455556666:repository/api/sha256:9f3c...
Security Hub  S3.8 S3 Block Public Access should be enabled   arn:aws:s3:::ml-feature-store-prod

$ aws securityhub get-enabled-standards \
    --query 'StandardsSubscriptions[].[StandardsArn,StandardsStatus]' --output text
arn:aws:securityhub:eu-central-1::standards/aws-foundational-security-best-practices/v/1.0.0   READY
arn:aws:securityhub:::ruleset/cis-aws-foundations-benchmark/v/1.4.0                            READY

$ aws artifact list-reports --query 'reports[?contains(name, `SOC 2`)].[id,name,version]' --output text
report-a1b2c3d4e5f6   SOC 2 Type II Report   18
report-b2c3d4e5f6a7   SOC 2 Type II Bridge Letter   4

$ aws artifact get-report --report-id report-a1b2c3d4e5f6 --report-version 18 \
    --term-token $(aws artifact get-term-for-report --report-id report-a1b2c3d4e5f6 \
                     --report-version 18 --query termToken --output text) \
    --query documentPresignedUrl --output text
https://artifact-reports-prod.s3.amazonaws.com/soc2-type2-v18.pdf?X-Amz-Algorithm=...
```

### 7.7 IAM Access Analyzer — finding the external exposure before an auditor does

```console
$ aws accessanalyzer create-analyzer --analyzer-name org-external-access \
    --type ORGANIZATION --query arn --output text
arn:aws:access-analyzer:eu-central-1:222233334444:analyzer/org-external-access

$ aws accessanalyzer list-findings \
    --analyzer-arn arn:aws:access-analyzer:eu-central-1:222233334444:analyzer/org-external-access \
    --filter '{"status":{"eq":["ACTIVE"]}}' \
    --query 'findings[].[resourceType,resource,principal,isPublic]' --output text
AWS::S3::Bucket    arn:aws:s3:::ml-feature-store-prod    {"AWS":"*"}    True
AWS::IAM::Role     arn:aws:iam::444455556666:role/PartnerIngest    {"AWS":"999988887777"}    False
```

---

## 8. Verification and failure diagnosis

### 8.1 The governance pre-flight check

Run this before declaring a landing zone production-ready. Every line must pass.

```bash
#!/usr/bin/env bash
# governance-preflight.sh — verify the Domain 2.2 baseline is actually in effect.
set -euo pipefail

fail() { printf '  [FAIL] %s\n' "$1"; RC=1; }
ok()   { printf '  [ OK ] %s\n' "$1"; }
RC=0

echo "== 1. Organization trail =="
TRAIL=$(aws cloudtrail describe-trails --output json)
echo "$TRAIL" | jq -e '.trailList[] | select(.IsOrganizationTrail == true)' >/dev/null \
  && ok "organization trail exists" || fail "no organization trail"
echo "$TRAIL" | jq -e '.trailList[] | select(.LogFileValidationEnabled == true)' >/dev/null \
  && ok "log file validation enabled" || fail "log file validation OFF - logs are not evidence"
echo "$TRAIL" | jq -e '.trailList[] | select(.KmsKeyId != null)' >/dev/null \
  && ok "trail encrypted with a CMK" || fail "trail using default encryption"

echo "== 2. Config recorder =="
aws configservice describe-configuration-recorder-status \
  --query 'ConfigurationRecordersStatus[0].recording' --output text | grep -q True \
  && ok "config recorder running" || fail "config recorder stopped"

echo "== 3. Detection services =="
[ -n "$(aws guardduty list-detectors --query 'DetectorIds[0]' --output text)" ] \
  && ok "GuardDuty enabled" || fail "GuardDuty not enabled"
aws securityhub get-enabled-standards >/dev/null 2>&1 \
  && ok "Security Hub enabled" || fail "Security Hub not enabled"

echo "== 4. Account-level S3 public access block =="
aws s3control get-public-access-block --account-id "$(aws sts get-caller-identity --query Account --output text)" \
  --query 'PublicAccessBlockConfiguration' --output json \
  | jq -e 'all(.[]; . == true)' >/dev/null \
  && ok "account-level BPA fully on" || fail "account-level Block Public Access incomplete"

echo "== 5. Root user has no access keys =="
aws iam get-account-summary --query 'SummaryMap.AccountAccessKeysPresent' --output text | grep -q '^0$' \
  && ok "no root access keys" || fail "root access keys exist - delete them now"

echo "== 6. KMS rotation on every customer managed key =="
for k in $(aws kms list-keys --query 'Keys[].KeyId' --output text); do
  mgr=$(aws kms describe-key --key-id "$k" --query 'KeyMetadata.KeyManager' --output text)
  [ "$mgr" = "CUSTOMER" ] || continue
  aws kms get-key-rotation-status --key-id "$k" --query KeyRotationEnabled --output text \
    | grep -q True || fail "rotation disabled on key $k"
done
ok "KMS rotation audit complete"

exit $RC
```

### 8.2 Failure diagnosis matrix

| Symptom | Most likely cause | How to confirm | Fix |
|---|---|---|---|
| `AccessDenied … with an explicit deny in a service control policy` while the principal has `AdministratorAccess` | SCP on an ancestor OU denies the action | `aws organizations list-policies-for-target --target-id <account-id> --filter SERVICE_CONTROL_POLICY`, then read each policy | Add a scoped exception (condition on `aws:PrincipalArn`) or move the account to a different OU. **Never** widen the SCP globally. |
| An allow-list SCP locked everyone out of an account | `FullAWSAccess` was detached and the allow-list is incomplete | You cannot fix this from the member account | Detach/replace the SCP from the **management account** (it is exempt). This is why `PolicyStaging` OU exists. |
| SCP appears to have no effect | Target is the management account, or the principal is a service-linked role | `aws sts get-caller-identity` → compare with `Organization.MasterAccountId` | Move workloads out of the management account. Permanently. |
| `kms:Decrypt` denied although the IAM policy allows it | Key policy does not delegate to IAM and does not name the principal | `aws kms get-key-policy --key-id <k> --policy-name default` | Add the account root delegation statement or a direct principal statement to the **key policy** |
| Cross-account KMS access fails, both policies look right | Cross-account requires allow in **both** the key policy *and* the caller's IAM policy; plus `kms:ViaService` may exclude the caller | `aws kms decrypt` from the caller and read the full error ARN | Grant on both sides; check `kms:ViaService` and `kms:CallerAccount` conditions |
| `InvalidCiphertextException` on decrypt | Encryption context mismatch, or ciphertext produced by a different key | Compare the context used at encrypt and decrypt time | Pass the identical context map; context is order-independent but case-sensitive |
| Data permanently unreadable after cleanup | KMS key deletion completed after the 7–30 day pending window | `aws kms describe-key` → `KeyState: PendingDeletion` (recoverable) vs key not found (unrecoverable) | Recoverable only *before* the window elapses: `aws kms cancel-key-deletion`. Prevent with the `ProtectKmsKeyMaterial` SCP. |
| Config rule shows `NOT_APPLICABLE` for everything | Recorder is not recording that resource type, or the rule's scope is wrong | `aws configservice describe-configuration-recorders` → check `recordingGroup` | Enable the resource type; re-check the rule `Scope` |
| Config recorder stopped with `insufficientPermissions` | The service role lost `s3:PutObject` on the delivery bucket, or `kms:GenerateDataKey` on the bucket CMK | `describe-delivery-channel-status` shows the last delivery error | Restore the role policy; if the bucket is cross-account, fix the bucket policy too |
| CloudTrail `LatestDeliveryError: InsufficientEncryptionPolicyException` | The trail's KMS key policy lacks the `cloudtrail.amazonaws.com` `GenerateDataKey*` statement or the `aws:SourceArn` condition does not match | `aws cloudtrail get-trail-status --name <t>` | Correct the key policy `EncryptionContext`/`SourceArn` conditions (§6.1) |
| `validate-logs` reports `INVALID: hash value doesn't match` | Log file altered or truncated in the bucket | Compare object versions: `aws s3api list-object-versions --bucket … --prefix …` | Treat as a **security incident**. Restore the prior version; enable Object Lock COMPLIANCE mode; audit who had `s3:PutObject` |
| `validate-logs` reports missing digest files | Trail was stopped during that window | Search CloudTrail for `StopLogging` events | Gap must be documented for the auditor; deploy the `ProtectAuditAndDetectionControls` SCP |
| ACM certificate stuck in `PENDING_VALIDATION` | The DNS CNAME validation record was never published, or was published in the wrong hosted zone | `aws acm describe-certificate --certificate-arn <arn> --query 'Certificate.DomainValidationOptions'` | Create the exact CNAME name/value in the authoritative zone; validation completes within minutes to hours |
| ACM certificate not selectable on a CloudFront distribution | Certificate is not in `us-east-1` | `aws acm list-certificates --region us-east-1` | Re-issue in `us-east-1` |
| A workload broke right after `aws:SecureTransport` deny was added | A client is still using HTTP, or an S3 **gateway** VPC endpoint path is being used with an old SDK | CloudTrail `errorCode: AccessDenied` + `tlsDetails` field in the event | Upgrade clients to TLS 1.2+; the `tlsDetails` block in CloudTrail events tells you the negotiated version and cipher |
| GuardDuty produces no findings in a member account | Member never accepted the invitation, or auto-enable for new accounts is off | `aws guardduty list-members --detector-id <id> --query 'Members[].[AccountId,RelationshipStatus]'` | Enable `auto-enable` in the delegated administrator; re-invite |
| Security Hub score dropped overnight with no change | A new standard version or new controls were auto-enabled | `aws securityhub describe-standards-control-associations` | Expected behavior; triage the new controls or disable with a documented justification |
| AWS Config bill exploded | `AllSupported: true` in a high-churn account records every Lambda version, ASG change and ENI | Cost Explorer filtered to `AWSConfig`, grouped by usage type | Use recording exclusions or a per-resource-type recording strategy; move to daily periodic rules where continuous is not required |

### 8.3 Control-selection decision tree

```
Need to stop an action before it happens, org-wide, even from an account admin?
├── Constrains YOUR principals ──────────────► SCP
├── Constrains access TO your resources
│      (including external principals) ──────► RCP
├── A service attribute you want to persist
│      (IMDSv2, VPC BPA, allowed AMIs) ──────► Declarative policy
├── Delegating IAM to developers safely ─────► Permissions boundary
└── Should block at deploy time,
       inside CloudFormation ────────────────► Proactive control / CFN Hook

Need to know something happened?
├── Who made the API call ───────────────────► CloudTrail
├── What the resource looked like / drift ───► AWS Config
├── Malicious behavior ──────────────────────► GuardDuty
├── Vulnerable software ─────────────────────► Inspector
├── Sensitive data in S3 ────────────────────► Macie
├── One aggregated view + benchmarks ────────► Security Hub
├── Investigate scope of a finding ──────────► Detective
└── Long-term multi-source query ────────────► Security Lake / CloudTrail Lake

Need to satisfy an auditor?
├── Evidence about AWS's controls ───────────► AWS Artifact
├── Evidence about YOUR workloads ───────────► Audit Manager
└── Best-practice advisory checks ───────────► Trusted Advisor
```

---

## 9. Exam-focused distillation

One line per service — the discriminating fact that answers the question:

| Service | The one thing |
|---|---|
| **AWS Organizations** | Central management + consolidated billing; SCPs live here; management account is exempt from SCPs |
| **SCP** | Sets the *maximum* permissions; grants nothing |
| **AWS Control Tower** | Automated, opinionated multi-account landing zone with preventive/detective/proactive controls |
| **AWS Artifact** | Download **AWS's** compliance reports (SOC, ISO, PCI) and accept agreements (HIPAA BAA) |
| **AWS Audit Manager** | Continuously collects evidence about **your** workloads, mapped to frameworks |
| **AWS Config** | Resource configuration history + compliance rules |
| **AWS CloudTrail** | API call history; enable log file validation for tamper evidence |
| **Amazon GuardDuty** | Intelligent threat detection; no agents; consumes logs you don't have to enable |
| **Amazon Inspector** | Automated vulnerability (CVE) scanning of EC2, ECR images, Lambda |
| **Amazon Macie** | Discovers and classifies sensitive data in S3 |
| **Amazon Detective** | Investigates the root cause and scope of a finding |
| **AWS Security Hub** | Single pane of glass; aggregates findings; runs CIS/PCI/FSBP standards |
| **AWS Trusted Advisor** | Best-practice checks across cost, performance, security, fault tolerance, service limits, operational excellence |
| **AWS KMS** | Managed keys, integrated with ~all AWS services; you never touch key material |
| **AWS CloudHSM** | Single-tenant, FIPS 140-3 Level 3 HSM; **AWS cannot access your keys** |
| **AWS Certificate Manager** | Free public TLS certificates with automatic renewal for integrated services |
| **AWS Secrets Manager** | Secrets with **built-in automatic rotation** |
| **AWS Systems Manager Parameter Store** | Config and secrets storage; no built-in rotation; free standard tier |
| **IAM Access Analyzer** | Finds resources shared outside your zone of trust; unused-access findings |
| **AWS Firewall Manager** | Centrally applies WAF/Shield/security group rules across the organization |

Three sentences worth memorizing verbatim:

1. **"Encryption at rest and in transit is the customer's responsibility to configure; AWS's responsibility is to provide the capability."**
2. **"AWS Artifact gives you AWS's compliance documents; it does not assess your workloads."**
3. **"An SCP cannot grant permissions — it can only restrict what an IAM policy is otherwise able to allow, and an explicit deny anywhere always wins."**

---

## 10. References

**Exam and certification**
- AWS Certified Cloud Practitioner (CLF-C02) Exam Guide — https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf
- AWS Certified Cloud Practitioner — https://aws.amazon.com/certification/certified-cloud-practitioner/

**Governance and Organizations**
- AWS Organizations User Guide — https://docs.aws.amazon.com/organizations/latest/userguide/orgs_introduction.html
- Service control policies (SCPs) — https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_scps.html
- Resource control policies (RCPs) — https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_rcps.html
- Declarative policies — https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_declarative.html
- Tag policies — https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_tag-policies.html
- Policy evaluation logic — https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_evaluation-logic.html
- AWS Control Tower User Guide — https://docs.aws.amazon.com/controltower/latest/userguide/what-is-control-tower.html
- Controls reference (preventive / detective / proactive) — https://docs.aws.amazon.com/controltower/latest/controlreference/controls.html
- Organizing Your AWS Environment Using Multiple Accounts — https://docs.aws.amazon.com/whitepapers/latest/organizing-your-aws-environment/organizing-your-aws-environment.html

**Encryption and key management**
- AWS KMS Developer Guide — https://docs.aws.amazon.com/kms/latest/developerguide/overview.html
- KMS key policies — https://docs.aws.amazon.com/kms/latest/developerguide/key-policies.html
- Rotating AWS KMS keys — https://docs.aws.amazon.com/kms/latest/developerguide/rotate-keys.html
- Encryption context — https://docs.aws.amazon.com/kms/latest/developerguide/concepts.html#encrypt_context
- AWS KMS Cryptographic Details — https://docs.aws.amazon.com/kms/latest/cryptographic-details/intro.html
- AWS CloudHSM User Guide — https://docs.aws.amazon.com/cloudhsm/latest/userguide/introduction.html
- AWS Certificate Manager User Guide — https://docs.aws.amazon.com/acm/latest/userguide/acm-overview.html
- AWS Secrets Manager User Guide — https://docs.aws.amazon.com/secretsmanager/latest/userguide/intro.html
- The Security Design of the AWS Nitro System — https://docs.aws.amazon.com/whitepapers/latest/security-design-of-aws-nitro-system/security-design-of-aws-nitro-system.html

**Audit and detection**
- AWS CloudTrail User Guide — https://docs.aws.amazon.com/awscloudtrail/latest/userguide/cloudtrail-user-guide.html
- Validating CloudTrail log file integrity — https://docs.aws.amazon.com/awscloudtrail/latest/userguide/cloudtrail-log-file-validation-intro.html
- Creating a trail for an organization — https://docs.aws.amazon.com/awscloudtrail/latest/userguide/creating-trail-organization.html
- AWS Config Developer Guide — https://docs.aws.amazon.com/config/latest/developerguide/WhatIsConfig.html
- AWS Config managed rules — https://docs.aws.amazon.com/config/latest/developerguide/managed-rules-by-aws-config.html
- Conformance packs — https://docs.aws.amazon.com/config/latest/developerguide/conformance-packs.html
- Amazon GuardDuty User Guide — https://docs.aws.amazon.com/guardduty/latest/ug/what-is-guardduty.html
- Amazon Inspector User Guide — https://docs.aws.amazon.com/inspector/latest/user/what-is-inspector.html
- Amazon Macie User Guide — https://docs.aws.amazon.com/macie/latest/user/what-is-macie.html
- Amazon Detective User Guide — https://docs.aws.amazon.com/detective/latest/userguide/what-is-detective.html
- AWS Security Hub User Guide — https://docs.aws.amazon.com/securityhub/latest/userguide/what-is-securityhub.html
- AWS Audit Manager User Guide — https://docs.aws.amazon.com/audit-manager/latest/userguide/what-is.html
- Amazon Security Lake User Guide — https://docs.aws.amazon.com/security-lake/latest/userguide/what-is-security-lake.html
- IAM Access Analyzer — https://docs.aws.amazon.com/IAM/latest/UserGuide/what-is-access-analyzer.html
- AWS Trusted Advisor — https://docs.aws.amazon.com/awssupport/latest/user/trusted-advisor.html

**Compliance and sovereignty**
- AWS Cloud Compliance — https://aws.amazon.com/compliance/
- AWS Compliance Programs — https://aws.amazon.com/compliance/programs/
- AWS Artifact User Guide — https://docs.aws.amazon.com/artifact/latest/ug/what-is-aws-artifact.html
- Shared Responsibility Model — https://aws.amazon.com/compliance/shared-responsibility-model/
- AWS Digital Sovereignty — https://aws.amazon.com/compliance/digital-sovereignty/
- Data Privacy FAQ (data residency) — https://aws.amazon.com/compliance/data-privacy-faq/
- AWS GovCloud (US) User Guide — https://docs.aws.amazon.com/govcloud-us/latest/UserGuide/whatis.html
- AWS Well-Architected Framework — Security Pillar — https://docs.aws.amazon.com/wellarchitected/latest/security-pillar/welcome.html
- AWS Security Reference Architecture (AWS SRA) — https://docs.aws.amazon.com/prescriptive-guidance/latest/security-reference-architecture/welcome.html