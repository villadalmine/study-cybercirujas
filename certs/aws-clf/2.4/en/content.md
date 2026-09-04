# 2.4 — Identify components and resources for security

**Certification:** AWS Certified Cloud Practitioner (CLF-C02, v1.0)
**Domain 2:** Security and Compliance (30% of the exam)
**Task statement weight:** 7.5
**Audience profile:** SRE / Platform Architect. Written assuming you already run production infrastructure and need the *mechanics*, not the marketing taxonomy.

---

## 1. The architectural problem this task statement actually encodes

The exam guide phrases task 2.4 blandly — "identify components and resources for security." The production problem underneath it is much sharper, and it is the reason the whole service list exists:

> **In a multi-account AWS Organization, no single service knows whether you are compromised.** The signal is fragmented across seven different data planes, each with its own retention, its own region scope, its own enablement switch, and its own failure mode of *silently producing nothing*.

Concretely. You run 40 accounts. Someone exfiltrates data from an S3 bucket at 03:14 UTC using long-lived static credentials leaked in a public repo. To detect that, you need:

| Question | Which plane answers it | What must have been enabled *before* the event |
|---|---|---|
| Which API calls were made, by whom, from where? | **CloudTrail** management + data events | Org trail with S3 data events (data events are **off by default** and cost money) |
| Was the caller's behaviour anomalous? | **GuardDuty** (`UnauthorizedAccess:IAMUser/InstanceCredentialExfiltration`, `Exfiltration:S3/AnomalousBehavior`) | Detector enabled **per account, per region**, with S3 Protection on |
| Did the bucket contain regulated data? | **Macie** | Sensitive data discovery job or automated discovery on that bucket |
| Was the bucket public / misconfigured? | **Config** rules + **Security Hub** FSBP controls | Configuration recorder running in that region |
| What is the blast radius of that principal? | **IAM Access Analyzer** + **Detective** | Analyzer at org scope; Detective enabled ≥ 2 weeks before, for graph history |
| Did the traffic actually leave the VPC? | **VPC Flow Logs** | Flow logs enabled on the VPC/subnet/ENI |
| Was the credential reachable at all? | **Security Groups / NACLs / WAF** | Baseline network controls |

Every row is a **pre-commitment**. Security services in AWS are almost universally *forward-looking*: enabling GuardDuty today gives you zero visibility into yesterday. This is the single most operationally important property of the whole domain, and it is why the exam keeps asking "which service would you use to…" — the answer must be chosen and enabled before the incident.

The second structural fact: **the shared responsibility model draws the line, and everything in this task statement lives on the customer's side of it.** AWS gives you the *controls*; enabling, configuring, aggregating and acting on them is yours. AWS will not turn on GuardDuty for you, will not stop you from opening `0.0.0.0/0` on port 22, and will not tell you your KMS key policy locked you out.

### 1.1 The three planes

Everything in 2.4 sorts cleanly into three planes. Learn this shape and the service list stops being memorisation:

```
                          ┌──────────────────────────────────────────┐
   PREVENT                │ IAM / SCPs / Security Groups / NACLs      │
   (block it happening)   │ WAF / Shield / Network Firewall           │
                          │ KMS / CloudHSM / ACM / Secrets Manager    │
                          └──────────────────────────────────────────┘
                                            │
                          ┌──────────────────────────────────────────┐
   DETECT                 │ GuardDuty / Inspector / Macie             │
   (know it happened)     │ Config / CloudTrail / Access Analyzer     │
                          │ Security Hub (aggregation + standards)    │
                          └──────────────────────────────────────────┘
                                            │
                          ┌──────────────────────────────────────────┐
   RESPOND                │ Detective / Security Incident Response    │
   (do something)         │ EventBridge → Lambda / SSM Automation     │
                          │ Shield Response Team (SRT) / AWS Support  │
                          └──────────────────────────────────────────┘
```

---

## 2. The detection plane: four services that are constantly confused

This is the highest-yield comparison in the entire domain. GuardDuty, Inspector, Macie and Detective answer four *different* questions, and the exam tests exactly that distinction.

| | **Amazon GuardDuty** | **Amazon Inspector** | **Amazon Macie** | **Amazon Detective** |
|---|---|---|---|---|
| **Question answered** | "Is something malicious happening *right now*?" | "Is there a known vulnerability in my software?" | "Where is my sensitive data?" | "What is the full story behind this finding?" |
| **Type** | Threat detection (behavioural / IoC) | Vulnerability management (CVE) | Data classification | Investigation / root-cause graph |
| **Primary data sources** | CloudTrail management events, VPC Flow Logs, Route 53 Resolver DNS query logs (all read *out-of-band*, no logging enablement required) | SSM Agent inventory + agentless EBS snapshot scan; ECR image layers; Lambda code & layers | S3 object contents | CloudTrail, VPC Flow Logs, GuardDuty findings, EKS audit logs |
| **Optional protection plans** | S3 Protection, EKS Audit Log Monitoring, RDS Protection, Lambda Protection, Malware Protection (EC2/EBS + S3), Runtime Monitoring (EC2/ECS-Fargate/EKS) | EC2, ECR, Lambda, **CIS benchmark scans**, code security | Automated sensitive data discovery + scheduled/one-off jobs | — |
| **Agent required?** | **No** for foundational sources. **Yes** for Runtime Monitoring (GuardDuty security agent) | SSM Agent for EC2 (or agentless mode); none for ECR/Lambda | No | No |
| **Latency to first finding** | Minutes | Minutes–hours after first inventory | Hours (job-based) | Needs ~2 weeks of ingested history to be useful |
| **Retroactive?** | ❌ No | ⚠️ Partially — scans current state, so an old-but-present CVE is found | ⚠️ Scans current objects | ❌ No — graph starts at enablement |
| **Cost driver** | Volume of events/logs analysed (per million CloudTrail events, per GB of flow/DNS logs) | Per instance / per image scan / per function per month | Per bucket evaluated + per GB classified | Per GB of data ingested into the graph |
| **Turn it off and…** | You lose *future* detection instantly | You lose scan results after a retention window | Findings persist 90 days | Graph data ages out |
| **Common wrong answer it is confused with** | Inspector | GuardDuty | Amazon Comprehend | GuardDuty |

**The one-line discriminators the exam rewards:**

- **GuardDuty** = *behaviour*. Crypto-mining, credential exfiltration, port scanning, C2 DNS lookups, Tor traffic.
- **Inspector** = *known CVEs and unintended network exposure* in EC2, ECR images and Lambda.
- **Macie** = *PII / PHI / PCI in S3*.
- **Detective** = *investigate a finding you already have*. It never generates its own findings.

### 2.1 Security Hub: the aggregation layer, and its hidden dependency

AWS Security Hub is **not a detector**. It is:

1. A **normaliser** — everything becomes AWS Security Finding Format (ASFF), a JSON schema with `SeverityLabel`, `Compliance.Status`, `Resources[]`, `ProductArn`.
2. An **aggregator** — cross-account (via Organizations delegated administrator) and cross-region (via a designated aggregation region).
3. A **compliance engine** — it *does* run its own checks against security standards:
   - AWS Foundational Security Best Practices (FSBP) v1.0.0
   - CIS AWS Foundations Benchmark v1.2.0 / v1.4.0 / v3.0.0
   - PCI DSS v3.2.1 / v4.0.1
   - NIST SP 800-53 Rev. 5
   - AWS Resource Tagging Standard

> **The trap:** the vast majority of Security Hub controls are implemented as **AWS Config managed rules**. If the AWS Config configuration recorder is not running in that account+region, those controls report `NO_DATA` and your compliance score is a lie of omission. Security Hub without Config is a dashboard of nothing.

### 2.2 The rest of the detect plane

| Service | What it is | Free? |
|---|---|---|
| **AWS CloudTrail** | API audit log. **Enabled by default** as 90-day *Event history* (management events only, per-region, not durable, not exportable at scale). A **trail** is what gives you durable multi-region delivery to S3. **CloudTrail Lake** gives SQL over immutable event stores. | Event history free; one copy of management events per trail free; **data events always cost** |
| **AWS Config** | Configuration *state* recorder + change timeline + rule evaluation + conformance packs + remediation. Answers "what did this resource look like on 12 August?" | ❌ Per configuration item + per rule evaluation |
| **IAM Access Analyzer** | Uses automated reasoning (provable security) to find resources shared **outside your zone of trust**; also **unused access** findings and **policy validation/generation** | External/unused access analyzers priced per resource; policy validation free |
| **AWS Trusted Advisor** | Best-practice checks across 6 pillars incl. **Security** (open security groups, MFA on root, exposed access keys, S3 permissions) | Core security + service-quota checks for everyone; **full check set requires Business / Enterprise On-Ramp / Enterprise Support** |
| **AWS Audit Manager** | Continuously collects evidence and maps it to frameworks (SOC 2, PCI DSS, GDPR, HIPAA) to produce auditor-ready assessment reports | ❌ Per resource assessed |
| **AWS Artifact** | Self-service portal for **AWS's own** compliance reports (SOC 1/2/3, ISO 27001, PCI AoC) and agreements (BAA, HIPAA) | ✅ Free |

> **Artifact vs Audit Manager — a classic exam pair.** Artifact = evidence about *AWS's* controls (the provider side of shared responsibility). Audit Manager = evidence about *your* controls (the customer side).

---

## 3. The network protection plane

### 3.1 Packet path and evaluation order

Knowing *where* each control sits is what makes the trade-off table meaningful.

```
Internet
  │
  ├─ AWS Shield Standard ......... always on, free, L3/L4, no config, at the edge
  │
  ├─ Amazon Route 53 ............. DNS; Shield-protected
  │
  ├─ Amazon CloudFront ........... edge PoP
  │     └─ AWS WAF (scope=CLOUDFRONT) .... L7, evaluated AT THE EDGE
  │
  ▼ ── AWS Region ────────────────────────────────────────────────────
  │
  ├─ Internet Gateway
  ├─ Route table            ◄── AWS Network Firewall inserted here, via routing
  ├─ Network ACL            ◄── STATELESS, subnet boundary, allow AND deny
  ├─ Elastic Load Balancer
  │     └─ AWS WAF (scope=REGIONAL) ...... L7, after NACL/SG of the ALB subnet
  ├─ Network ACL            ◄── app subnet
  ├─ Security Group         ◄── STATEFUL, ENI boundary, allow ONLY
  └─ Host OS firewall (yours)
```

Two consequences SREs get bitten by:

1. **WAF on an ALB cannot protect the ALB's own listener from a volumetric L3/L4 flood** — that packet never reaches the WAF evaluation stage. That is Shield's job.
2. **A NACL deny takes effect before the security group is ever consulted.** If your app is unreachable and the SG looks perfect, the NACL is the next thing to check — and specifically the *return* direction.

### 3.2 Security Groups vs Network ACLs

| | **Security Group** | **Network ACL** |
|---|---|---|
| Attaches to | ENI (instance, ALB node, RDS, Lambda-in-VPC, EFS mount target) | Subnet |
| Statefulness | **Stateful** — return traffic auto-allowed | **Stateless** — return traffic needs its own explicit rule |
| Rule types | **Allow only** (there is no deny rule) | **Allow and deny** |
| Evaluation | All rules in all attached SGs evaluated; **union**; order irrelevant | Rules evaluated **in ascending rule-number order; first match wins**; implicit `*` DENY at the end |
| Default (created with VPC) | Default SG: allow all *inbound from itself*, allow all outbound | Default NACL: **allow all in and out** |
| Default (newly created) | Deny all inbound, allow all outbound | **Deny all in and out** — a brand-new custom NACL blocks everything |
| Can reference another SG / prefix list? | ✅ Yes — `sg-xxxx` as a source is the idiomatic pattern | ❌ CIDR only |
| Max per resource | 5 SGs per ENI (adjustable to 16) | 1 NACL per subnet (a NACL may cover many subnets) |
| Typical use | Primary workload control — **use this by default** | Coarse subnet-wide deny (blocklist an abusive CIDR), regulated-environment defence in depth |
| Cost | Free | Free |

**The ephemeral-port rule.** Because NACLs are stateless, an inbound HTTPS request needs an *outbound* allow for the ephemeral response port. Linux kernel default is `32768–60999`; ELB nodes and NAT gateways use `1024–65535`. AWS's own guidance is to allow `1024–65535` outbound, which is why a "hardened" NACL that only allows `443` outbound breaks every web tier that has ever been built.

### 3.3 WAF vs Shield vs Network Firewall vs Firewall Manager

| | **AWS WAF** | **AWS Shield Standard** | **AWS Shield Advanced** | **AWS Network Firewall** | **AWS Firewall Manager** |
|---|---|---|---|---|---|
| OSI layer | 7 (HTTP/HTTPS) | 3 / 4 | 3 / 4 / 7 (with WAF) | 3–7 (Suricata IPS) | n/a — policy manager |
| Protects against | SQLi, XSS, bad bots, scrapers, L7 floods, geo/IP abuse | Common infrastructure DDoS (SYN flood, UDP reflection) | Large/sophisticated DDoS + cost protection | Egress filtering, domain allowlists, IDS/IPS, TLS inspection | — |
| Attach points | CloudFront, ALB, API Gateway (REST), AppSync, Cognito user pool, App Runner, Verified Access | Automatic on CloudFront, Route 53, Global Accelerator, ELB, EC2 EIP | Explicitly protected resources | VPC (via routing into firewall endpoints) | Applies WAF/Shield Adv/SG/Network Firewall/DNS Firewall policies org-wide |
| Enablement | Opt-in, per Web ACL | **Always on, nothing to enable** | Subscription | Deploy endpoints + change route tables | Requires **AWS Organizations** + delegated admin |
| Key extras | Managed rule groups (AWS + Marketplace), rate-based rules, Bot Control, Fraud Control / ATP, CAPTCHA & Challenge, JA3/JA4 fingerprinting | — | 24×7 **Shield Response Team (SRT)**, **DDoS cost protection** (credits for scaling charges during an attack), health-based detection, WAF at no extra charge on protected resources | Stateful rule groups in Suricata syntax, managed domain lists | Auto-remediation of non-compliant resources; auto-applies to *new* accounts |
| Order-of-magnitude list price (us-east-1) | ~$5/Web ACL/mo + ~$1/rule/mo + ~$0.60/million requests | **$0** | **~$3,000/mo per organization**, 1-year commitment, + DTO fees | ~$0.395/endpoint/hr + ~$0.065/GB processed | ~$100/policy/region/mo |

> **Exam-level discriminators.** "Protect a web app from SQL injection" → **WAF**. "We are already protected against common DDoS at no cost" → **Shield Standard**. "We need a 24/7 response team and refunds for attack-driven scaling costs" → **Shield Advanced**. "Enforce the same WAF rules across 200 accounts automatically, including accounts created next month" → **Firewall Manager**. "Filter *outbound* traffic to only approved domains" → **Network Firewall** (or **Route 53 Resolver DNS Firewall** for the DNS-only variant).

---

## 4. The data protection plane

### 4.1 Encryption at rest vs in transit — and envelope encryption

**In transit** = TLS. Provided by **AWS Certificate Manager (ACM)** for public endpoints (free public certificates, automatic renewal — but usable *only* with integrated services: CloudFront, ALB/NLB, API Gateway, App Runner, Cognito; you cannot export a public ACM cert to an EC2 instance). **AWS Private CA** issues internal certs and is billed monthly per CA plus per certificate.

**At rest** = almost always **AWS KMS envelope encryption**. The mechanics matter because they explain the pricing, the latency and the failure modes:

```
1. Service calls kms:GenerateDataKey(KeyId=<CMK>, KeySpec=AES_256)
2. KMS returns { Plaintext: <256-bit DEK>, CiphertextBlob: <DEK encrypted under the CMK> }
3. Service encrypts the object/volume/row locally with the plaintext DEK  (fast, no KMS in the data path)
4. Service zeroises the plaintext DEK from memory and stores CiphertextBlob alongside the data
5. On read: service calls kms:Decrypt(CiphertextBlob) → plaintext DEK → decrypt data
```

The KMS key material **never leaves the FIPS 140-3 Level 3 validated HSM**. Bulk data is never sent to KMS. This is why S3 `SSE-KMS` with **S3 Bucket Keys** enabled reduces KMS request cost by up to ~99% — the bucket key amortises one `GenerateDataKey` call across many objects.

### 4.2 Comparison of key and secret stores

| | **AWS KMS** | **AWS CloudHSM** | **Secrets Manager** | **SSM Parameter Store** | **ACM** |
|---|---|---|---|---|---|
| Stores | Encryption keys (symmetric, asymmetric, HMAC) | Encryption keys | Secrets (DB creds, API keys) | Config values + secrets (`SecureString`) | X.509 certificates |
| Tenancy | Multi-tenant managed HSM fleet | **Single-tenant, dedicated HSM cluster in your VPC** | Managed | Managed | Managed |
| FIPS | 140-3 Level 3 | 140-3 Level 3 | (uses KMS) | (uses KMS) | — |
| Who controls key material | AWS operates the HSMs; you control the key policy. AWS has **no** access to your key material | **You** — AWS cannot recover your keys if you lose credentials | — | — | — |
| Built-in rotation | ✅ Automatic annual key rotation (configurable 90–2560 days) + on-demand rotation | ❌ Manual | ✅ **Yes — native, via Lambda rotation function; RDS/Redshift/DocumentDB are turnkey** | ❌ No | ✅ Automatic renewal for public certs |
| Cross-account | ✅ via key policy | Via app design | ✅ via resource policy | ✅ (advanced tier) | Limited |
| Order-of-magnitude cost | ~$1/key/mo + ~$0.03 per 10k requests | **~$1.45–$1.60/HSM/hr** (≈$1,000+/mo per HSM, min. 2 for HA) | ~$0.40/secret/mo + ~$0.05 per 10k API calls | **Standard tier free**; advanced ~$0.05/param/mo | **Public certs free**; Private CA ~$400/mo |
| Choose it when | Default for everything | Regulatory mandate for single-tenant HSM, or you need PKCS#11/JCE/CNG offload | You need **automatic rotation** | You need cheap config; secrets without rotation | TLS termination on AWS-integrated services |

> **The decision that costs money:** Secrets Manager vs Parameter Store `SecureString`. At 500 secrets that is ~$200/mo vs $0. The differentiator worth paying for is **native rotation** and **cross-account resource policies**. If a secret never rotates, Parameter Store standard tier is the correct engineering answer.

> **KMS key types on the exam:** *AWS owned keys* (invisible, free, shared across customers, no rotation control) → *AWS managed keys* (`aws/s3`, `aws/ebs`, one per service per account, free, auto-rotated, **key policy not editable**) → *Customer managed keys* (you create, you set the key policy, you can disable/schedule deletion 7–30 days, you can audit every use in CloudTrail). Only a **customer managed key** gives you the ability to *deny* AWS services or to cryptographically shred data by scheduling key deletion.

---

## 5. Complete infrastructure — organization security baseline

The following are complete, deployable artefacts. Nothing is elided.

### 5.1 `security-baseline.yaml` — CloudTrail + Config + GuardDuty + Security Hub

```yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: >-
  Security detection baseline for the delegated security/audit account:
  KMS-encrypted log archive, organization CloudTrail with log-file validation,
  AWS Config recorder, GuardDuty detector with all protection plans, and
  Security Hub with FSBP + CIS v3.0.0. Deploy once per region you operate in.

Parameters:
  OrganizationId:
    Type: String
    Description: AWS Organizations ID (o-xxxxxxxxxx) used for the org-trail S3 prefix.
    AllowedPattern: '^o-[a-z0-9]{10,32}$'
  TrailName:
    Type: String
    Default: org-security-trail
  LogRetentionDays:
    Type: Number
    Default: 400
    MinValue: 1
  SecurityContactEmail:
    Type: String
    Description: Address subscribed to CRITICAL/HIGH Security Hub findings.
    AllowedPattern: '^[^@\s]+@[^@\s]+\.[^@\s]+$'

Resources:

  # ---------------------------------------------------------------- KMS ----
  SecurityLogsKey:
    Type: AWS::KMS::Key
    DeletionPolicy: Retain
    UpdateReplacePolicy: Retain
    Properties:
      Description: CMK for the security log archive (CloudTrail + Config).
      EnableKeyRotation: true
      KeySpec: SYMMETRIC_DEFAULT
      KeyUsage: ENCRYPT_DECRYPT
      PendingWindowInDays: 30
      KeyPolicy:
        Version: '2012-10-17'
        Id: security-logs-key-policy
        Statement:
          # Without this statement the key is orphaned and unmanageable.
          - Sid: EnableIAMPoliciesInThisAccount
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
              StringEquals:
                'aws:SourceAccount': !Ref 'AWS::AccountId'
              StringLike:
                'kms:EncryptionContext:aws:cloudtrail:arn':
                  !Sub 'arn:${AWS::Partition}:cloudtrail:*:${AWS::AccountId}:trail/*'
          - Sid: AllowCloudTrailToDescribeKey
            Effect: Allow
            Principal:
              Service: cloudtrail.amazonaws.com
            Action: 'kms:DescribeKey'
            Resource: '*'
          - Sid: AllowConfigToEncryptDeliveries
            Effect: Allow
            Principal:
              Service: config.amazonaws.com
            Action:
              - 'kms:GenerateDataKey*'
              - 'kms:Decrypt'
              - 'kms:DescribeKey'
            Resource: '*'
            Condition:
              StringEquals:
                'aws:SourceAccount': !Ref 'AWS::AccountId'
          - Sid: AllowOrgMembersToDecryptTheirOwnLogs
            Effect: Allow
            Principal: '*'
            Action:
              - 'kms:Decrypt'
              - 'kms:DescribeKey'
            Resource: '*'
            Condition:
              StringEquals:
                'aws:PrincipalOrgID': !Ref OrganizationId

  SecurityLogsKeyAlias:
    Type: AWS::KMS::Alias
    Properties:
      AliasName: alias/security-logs
      TargetKeyId: !Ref SecurityLogsKey

  # ----------------------------------------------------------------- S3 ----
  SecurityLogsBucket:
    Type: AWS::S3::Bucket
    DeletionPolicy: Retain
    UpdateReplacePolicy: Retain
    Properties:
      BucketName: !Sub 'security-logs-${AWS::AccountId}-${AWS::Region}'
      BucketEncryption:
        ServerSideEncryptionConfiguration:
          - BucketKeyEnabled: true
            ServerSideEncryptionByDefault:
              SSEAlgorithm: 'aws:kms'
              KMSMasterKeyID: !GetAtt SecurityLogsKey.Arn
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
          - Id: transition-and-expire
            Status: Enabled
            Transitions:
              - StorageClass: STANDARD_IA
                TransitionInDays: 30
              - StorageClass: GLACIER_IR
                TransitionInDays: 90
            ExpirationInDays: !Ref LogRetentionDays
            NoncurrentVersionExpiration:
              NoncurrentDays: 30

  SecurityLogsBucketPolicy:
    Type: AWS::S3::BucketPolicy
    Properties:
      Bucket: !Ref SecurityLogsBucket
      PolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Sid: DenyInsecureTransport
            Effect: Deny
            Principal: '*'
            Action: 's3:*'
            Resource:
              - !GetAtt SecurityLogsBucket.Arn
              - !Sub '${SecurityLogsBucket.Arn}/*'
            Condition:
              Bool:
                'aws:SecureTransport': 'false'
          - Sid: DenyUnencryptedObjectUploads
            Effect: Deny
            Principal: '*'
            Action: 's3:PutObject'
            Resource: !Sub '${SecurityLogsBucket.Arn}/*'
            Condition:
              StringNotEquals:
                's3:x-amz-server-side-encryption': 'aws:kms'
          - Sid: AWSCloudTrailAclCheck
            Effect: Allow
            Principal:
              Service: cloudtrail.amazonaws.com
            Action: 's3:GetBucketAcl'
            Resource: !GetAtt SecurityLogsBucket.Arn
            Condition:
              StringEquals:
                'aws:SourceArn':
                  !Sub 'arn:${AWS::Partition}:cloudtrail:${AWS::Region}:${AWS::AccountId}:trail/${TrailName}'
          - Sid: AWSCloudTrailWrite
            Effect: Allow
            Principal:
              Service: cloudtrail.amazonaws.com
            Action: 's3:PutObject'
            Resource:
              # Both prefixes are required: the management account writes under its
              # own account ID, member accounts write under the organization ID.
              - !Sub '${SecurityLogsBucket.Arn}/AWSLogs/${AWS::AccountId}/*'
              - !Sub '${SecurityLogsBucket.Arn}/AWSLogs/${OrganizationId}/*'
            Condition:
              StringEquals:
                's3:x-amz-acl': 'bucket-owner-full-control'
                'aws:SourceArn':
                  !Sub 'arn:${AWS::Partition}:cloudtrail:${AWS::Region}:${AWS::AccountId}:trail/${TrailName}'
          - Sid: AWSConfigBucketPermissionsCheck
            Effect: Allow
            Principal:
              Service: config.amazonaws.com
            Action:
              - 's3:GetBucketAcl'
              - 's3:ListBucket'
            Resource: !GetAtt SecurityLogsBucket.Arn
            Condition:
              StringEquals:
                'aws:SourceAccount': !Ref 'AWS::AccountId'
          - Sid: AWSConfigBucketDelivery
            Effect: Allow
            Principal:
              Service: config.amazonaws.com
            Action: 's3:PutObject'
            Resource: !Sub '${SecurityLogsBucket.Arn}/AWSLogs/${AWS::AccountId}/Config/*'
            Condition:
              StringEquals:
                's3:x-amz-acl': 'bucket-owner-full-control'
                'aws:SourceAccount': !Ref 'AWS::AccountId'

  # ---------------------------------------------------------- CloudTrail ----
  OrganizationTrail:
    Type: AWS::CloudTrail::Trail
    DependsOn: SecurityLogsBucketPolicy
    Properties:
      TrailName: !Ref TrailName
      S3BucketName: !Ref SecurityLogsBucket
      IsLogging: true
      IsMultiRegionTrail: true
      IsOrganizationTrail: true
      IncludeGlobalServiceEvents: true
      EnableLogFileValidation: true
      KMSKeyId: !GetAtt SecurityLogsKey.Arn
      AdvancedEventSelectors:
        - Name: Log all management events
          FieldSelectors:
            - Field: eventCategory
              Equals: ['Management']
        - Name: Log S3 object-level data events
          FieldSelectors:
            - Field: eventCategory
              Equals: ['Data']
            - Field: resources.type
              Equals: ['AWS::S3::Object']
            # Exclude the log archive itself, or the trail records its own writes
            # in an unbounded feedback loop.
            - Field: resources.ARN
              NotStartsWith:
                - !Sub '${SecurityLogsBucket.Arn}/'
        - Name: Log Lambda invocation data events
          FieldSelectors:
            - Field: eventCategory
              Equals: ['Data']
            - Field: resources.type
              Equals: ['AWS::Lambda::Function']

  # -------------------------------------------------------------- Config ----
  ConfigServiceRole:
    Type: AWS::IAM::Role
    Properties:
      RoleName: !Sub 'AWSConfigRole-${AWS::Region}'
      AssumeRolePolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Effect: Allow
            Principal:
              Service: config.amazonaws.com
            Action: 'sts:AssumeRole'
            Condition:
              StringEquals:
                'aws:SourceAccount': !Ref 'AWS::AccountId'
      ManagedPolicyArns:
        - !Sub 'arn:${AWS::Partition}:iam::aws:policy/service-role/AWS_ConfigRole'
      Policies:
        - PolicyName: config-delivery
          PolicyDocument:
            Version: '2012-10-17'
            Statement:
              - Effect: Allow
                Action: 's3:PutObject'
                Resource: !Sub '${SecurityLogsBucket.Arn}/AWSLogs/${AWS::AccountId}/Config/*'
                Condition:
                  StringEquals:
                    's3:x-amz-acl': 'bucket-owner-full-control'
              - Effect: Allow
                Action: 's3:GetBucketAcl'
                Resource: !GetAtt SecurityLogsBucket.Arn
              - Effect: Allow
                Action:
                  - 'kms:GenerateDataKey'
                  - 'kms:Decrypt'
                Resource: !GetAtt SecurityLogsKey.Arn

  ConfigDeliveryChannel:
    Type: AWS::Config::DeliveryChannel
    DependsOn: SecurityLogsBucketPolicy
    Properties:
      Name: default
      S3BucketName: !Ref SecurityLogsBucket
      S3KmsKeyArn: !GetAtt SecurityLogsKey.Arn
      ConfigSnapshotDeliveryProperties:
        DeliveryFrequency: TwentyFour_Hours

  ConfigRecorder:
    Type: AWS::Config::ConfigurationRecorder
    DependsOn: ConfigDeliveryChannel
    Properties:
      Name: default
      RoleARN: !GetAtt ConfigServiceRole.Arn
      RecordingGroup:
        AllSupported: true
        IncludeGlobalResourceTypes: true
      RecordingMode:
        RecordingFrequency: CONTINUOUS

  # ----------------------------------------------------------- GuardDuty ----
  GuardDutyDetector:
    Type: AWS::GuardDuty::Detector
    Properties:
      Enable: true
      FindingPublishingFrequency: FIFTEEN_MINUTES
      Features:
        - Name: S3_DATA_EVENTS
          Status: ENABLED
        - Name: EKS_AUDIT_LOGS
          Status: ENABLED
        - Name: EBS_MALWARE_PROTECTION
          Status: ENABLED
        - Name: RDS_LOGIN_EVENTS
          Status: ENABLED
        - Name: LAMBDA_NETWORK_LOGS
          Status: ENABLED
        - Name: RUNTIME_MONITORING
          Status: ENABLED
          AdditionalConfiguration:
            - Name: EKS_ADDON_MANAGEMENT
              Status: ENABLED
            - Name: ECS_FARGATE_AGENT_MANAGEMENT
              Status: ENABLED
            - Name: EC2_AGENT_MANAGEMENT
              Status: ENABLED

  # --------------------------------------------------------- Security Hub ----
  SecurityHub:
    Type: AWS::SecurityHub::Hub
    DependsOn: ConfigRecorder
    Properties:
      EnableDefaultStandards: false
      ControlFindingGenerator: SECURITY_CONTROL
      AutoEnableControls: true
      Tags:
        Owner: platform-security

  FoundationalSecurityBestPractices:
    Type: AWS::SecurityHub::Standard
    DependsOn: SecurityHub
    Properties:
      StandardsArn:
        !Sub 'arn:${AWS::Partition}:securityhub:${AWS::Region}::standards/aws-foundational-security-best-practices/v/1.0.0'

  CISBenchmark:
    Type: AWS::SecurityHub::Standard
    DependsOn: FoundationalSecurityBestPractices
    Properties:
      StandardsArn:
        !Sub 'arn:${AWS::Partition}:securityhub:${AWS::Region}::standards/cis-aws-foundations-benchmark/v/3.0.0'

  # ------------------------------------------------------------ Alerting ----
  SecurityAlertsTopic:
    Type: AWS::SNS::Topic
    Properties:
      TopicName: security-critical-findings
      KmsMasterKeyId: !Ref SecurityLogsKey
      Subscription:
        - Protocol: email
          Endpoint: !Ref SecurityContactEmail

  SecurityAlertsTopicPolicy:
    Type: AWS::SNS::TopicPolicy
    Properties:
      Topics:
        - !Ref SecurityAlertsTopic
      PolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Sid: AllowEventBridgePublish
            Effect: Allow
            Principal:
              Service: events.amazonaws.com
            Action: 'sns:Publish'
            Resource: !Ref SecurityAlertsTopic
            Condition:
              StringEquals:
                'aws:SourceAccount': !Ref 'AWS::AccountId'

  CriticalFindingRule:
    Type: AWS::Events::Rule
    Properties:
      Name: securityhub-critical-and-high
      Description: Route new CRITICAL/HIGH Security Hub findings to the security topic.
      State: ENABLED
      EventPattern:
        source:
          - aws.securityhub
        detail-type:
          - 'Security Hub Findings - Imported'
        detail:
          findings:
            Severity:
              Label:
                - CRITICAL
                - HIGH
            Workflow:
              Status:
                - NEW
            RecordState:
              - ACTIVE
      Targets:
        - Id: security-topic
          Arn: !Ref SecurityAlertsTopic
          InputTransformer:
            InputPathsMap:
              severity: '$.detail.findings[0].Severity.Label'
              title: '$.detail.findings[0].Title'
              account: '$.detail.findings[0].AwsAccountId'
              region: '$.detail.findings[0].Region'
              resource: '$.detail.findings[0].Resources[0].Id'
              product: '$.detail.findings[0].ProductName'
            InputTemplate: |
              "[<severity>] <product>: <title>"
              "Account: <account>  Region: <region>"
              "Resource: <resource>"

Outputs:
  LogArchiveBucket:
    Description: S3 bucket holding CloudTrail and Config deliveries.
    Value: !Ref SecurityLogsBucket
    Export:
      Name: !Sub '${AWS::StackName}-LogBucket'
  LogArchiveKeyArn:
    Description: CMK protecting the log archive.
    Value: !GetAtt SecurityLogsKey.Arn
    Export:
      Name: !Sub '${AWS::StackName}-LogKeyArn'
  GuardDutyDetectorId:
    Description: Detector ID for this account/region.
    Value: !Ref GuardDutyDetector
  SecurityAlertsTopicArn:
    Value: !Ref SecurityAlertsTopic
```

### 5.2 `network-guardrails.yaml` — three-tier SGs and a stateless NACL

```yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: >-
  Three-tier network segmentation demonstrating stateful security groups
  (SG-to-SG references) alongside a stateless network ACL with the explicit
  ephemeral-port return rules that stateless filtering requires.

Parameters:
  VpcCidr:
    Type: String
    Default: 10.40.0.0/16
  AdminCidr:
    Type: String
    Default: 10.0.0.0/8
    Description: Trusted CIDR permitted to reach the bastion. Never 0.0.0.0/0.

Resources:

  Vpc:
    Type: AWS::EC2::VPC
    Properties:
      CidrBlock: !Ref VpcCidr
      EnableDnsSupport: true
      EnableDnsHostnames: true
      Tags:
        - Key: Name
          Value: prod-vpc

  PublicSubnetA:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref Vpc
      CidrBlock: !Select [0, !Cidr [!Ref VpcCidr, 6, 8]]
      AvailabilityZone: !Select [0, !GetAZs '']
      MapPublicIpOnLaunch: false
      Tags:
        - Key: Name
          Value: prod-public-a

  AppSubnetA:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref Vpc
      CidrBlock: !Select [2, !Cidr [!Ref VpcCidr, 6, 8]]
      AvailabilityZone: !Select [0, !GetAZs '']
      Tags:
        - Key: Name
          Value: prod-app-a

  DataSubnetA:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref Vpc
      CidrBlock: !Select [4, !Cidr [!Ref VpcCidr, 6, 8]]
      AvailabilityZone: !Select [0, !GetAZs '']
      Tags:
        - Key: Name
          Value: prod-data-a

  # ------------------------------------------------------ Security Groups ---
  AlbSecurityGroup:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: Public ALB - terminates TLS from the internet.
      VpcId: !Ref Vpc
      SecurityGroupIngress:
        - IpProtocol: tcp
          FromPort: 443
          ToPort: 443
          CidrIp: 0.0.0.0/0
          Description: HTTPS from the internet
      SecurityGroupEgress:
        - IpProtocol: '-1'
          CidrIp: 127.0.0.1/32
          Description: Placeholder - real egress added by AlbToAppEgress
      Tags:
        - Key: Name
          Value: sg-alb

  AppSecurityGroup:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: Application tier - reachable only from the ALB.
      VpcId: !Ref Vpc
      SecurityGroupEgress:
        - IpProtocol: tcp
          FromPort: 443
          ToPort: 443
          CidrIp: 0.0.0.0/0
          Description: Outbound HTTPS to AWS APIs and package mirrors
      Tags:
        - Key: Name
          Value: sg-app

  DataSecurityGroup:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: PostgreSQL - reachable only from the application tier.
      VpcId: !Ref Vpc
      SecurityGroupEgress:
        - IpProtocol: '-1'
          CidrIp: 127.0.0.1/32
          Description: Database initiates no outbound connections
      Tags:
        - Key: Name
          Value: sg-data

  BastionSecurityGroup:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: Break-glass bastion. Prefer SSM Session Manager over this.
      VpcId: !Ref Vpc
      SecurityGroupIngress:
        - IpProtocol: tcp
          FromPort: 22
          ToPort: 22
          CidrIp: !Ref AdminCidr
          Description: SSH from the trusted admin network only
      SecurityGroupEgress:
        - IpProtocol: tcp
          FromPort: 22
          ToPort: 22
          DestinationSecurityGroupId: !Ref AppSecurityGroup
          Description: SSH into the application tier
      Tags:
        - Key: Name
          Value: sg-bastion

  # Separate rule resources: SG-to-SG references are mutually recursive and
  # cannot be expressed inline without a circular dependency.
  AlbToAppEgress:
    Type: AWS::EC2::SecurityGroupEgress
    Properties:
      GroupId: !Ref AlbSecurityGroup
      IpProtocol: tcp
      FromPort: 8080
      ToPort: 8080
      DestinationSecurityGroupId: !Ref AppSecurityGroup
      Description: ALB to application listener

  AppFromAlbIngress:
    Type: AWS::EC2::SecurityGroupIngress
    Properties:
      GroupId: !Ref AppSecurityGroup
      IpProtocol: tcp
      FromPort: 8080
      ToPort: 8080
      SourceSecurityGroupId: !Ref AlbSecurityGroup
      Description: Application listener, ALB only

  AppFromBastionIngress:
    Type: AWS::EC2::SecurityGroupIngress
    Properties:
      GroupId: !Ref AppSecurityGroup
      IpProtocol: tcp
      FromPort: 22
      ToPort: 22
      SourceSecurityGroupId: !Ref BastionSecurityGroup
      Description: Break-glass SSH from the bastion

  AppToDataEgress:
    Type: AWS::EC2::SecurityGroupEgress
    Properties:
      GroupId: !Ref AppSecurityGroup
      IpProtocol: tcp
      FromPort: 5432
      ToPort: 5432
      DestinationSecurityGroupId: !Ref DataSecurityGroup
      Description: Application to PostgreSQL

  DataFromAppIngress:
    Type: AWS::EC2::SecurityGroupIngress
    Properties:
      GroupId: !Ref DataSecurityGroup
      IpProtocol: tcp
      FromPort: 5432
      ToPort: 5432
      SourceSecurityGroupId: !Ref AppSecurityGroup
      Description: PostgreSQL, application tier only

  # ---------------------------------------------------------- Network ACL ---
  DataTierNacl:
    Type: AWS::EC2::NetworkAcl
    Properties:
      VpcId: !Ref Vpc
      Tags:
        - Key: Name
          Value: nacl-data-tier

  DataTierNaclAssociation:
    Type: AWS::EC2::SubnetNetworkAclAssociation
    Properties:
      SubnetId: !Ref DataSubnetA
      NetworkAclId: !Ref DataTierNacl

  # Inbound: PostgreSQL from the app tier only.
  NaclInboundPostgres:
    Type: AWS::EC2::NetworkAclEntry
    Properties:
      NetworkAclId: !Ref DataTierNacl
      RuleNumber: 100
      Protocol: 6            # TCP
      RuleAction: allow
      Egress: false
      CidrBlock: !Select [2, !Cidr [!Ref VpcCidr, 6, 8]]
      PortRange:
        From: 5432
        To: 5432

  # Inbound: return traffic for connections the data tier initiates
  # (e.g. RDS reaching S3 for backups through a gateway endpoint).
  NaclInboundEphemeral:
    Type: AWS::EC2::NetworkAclEntry
    Properties:
      NetworkAclId: !Ref DataTierNacl
      RuleNumber: 110
      Protocol: 6
      RuleAction: allow
      Egress: false
      CidrBlock: !Ref VpcCidr
      PortRange:
        From: 1024
        To: 65535

  NaclInboundDenyAllOther:
    Type: AWS::EC2::NetworkAclEntry
    Properties:
      NetworkAclId: !Ref DataTierNacl
      RuleNumber: 32000
      Protocol: -1
      RuleAction: deny
      Egress: false
      CidrBlock: 0.0.0.0/0

  # Outbound: THIS is the rule people forget. A NACL is stateless, so the
  # response to an inbound :5432 request leaves from an ephemeral source port
  # and needs its own explicit allow. Linux uses 32768-60999; ELB and NAT
  # gateway use 1024-65535, so allow the wider range.
  NaclOutboundEphemeral:
    Type: AWS::EC2::NetworkAclEntry
    Properties:
      NetworkAclId: !Ref DataTierNacl
      RuleNumber: 100
      Protocol: 6
      RuleAction: allow
      Egress: true
      CidrBlock: !Ref VpcCidr
      PortRange:
        From: 1024
        To: 65535

  NaclOutboundHttps:
    Type: AWS::EC2::NetworkAclEntry
    Properties:
      NetworkAclId: !Ref DataTierNacl
      RuleNumber: 110
      Protocol: 6
      RuleAction: allow
      Egress: true
      CidrBlock: 0.0.0.0/0
      PortRange:
        From: 443
        To: 443

  NaclOutboundDenyAllOther:
    Type: AWS::EC2::NetworkAclEntry
    Properties:
      NetworkAclId: !Ref DataTierNacl
      RuleNumber: 32000
      Protocol: -1
      RuleAction: deny
      Egress: true
      CidrBlock: 0.0.0.0/0

  # ------------------------------------------------------- VPC Flow Logs ----
  FlowLogsGroup:
    Type: AWS::Logs::LogGroup
    Properties:
      LogGroupName: /aws/vpc/prod-flowlogs
      RetentionInDays: 90

  FlowLogsRole:
    Type: AWS::IAM::Role
    Properties:
      AssumeRolePolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Effect: Allow
            Principal:
              Service: vpc-flow-logs.amazonaws.com
            Action: 'sts:AssumeRole'
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
                  - 'logs:CreateLogStream'
                  - 'logs:PutLogEvents'
                  - 'logs:DescribeLogStreams'
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
      LogFormat: >-
        ${version} ${account-id} ${interface-id} ${srcaddr} ${dstaddr}
        ${srcport} ${dstport} ${protocol} ${packets} ${bytes} ${start} ${end}
        ${action} ${log-status} ${vpc-id} ${subnet-id} ${instance-id}
        ${tcp-flags} ${type} ${pkt-srcaddr} ${pkt-dstaddr} ${flow-direction}

Outputs:
  VpcId:
    Value: !Ref Vpc
  AlbSecurityGroupId:
    Value: !Ref AlbSecurityGroup
  AppSecurityGroupId:
    Value: !Ref AppSecurityGroup
  DataSecurityGroupId:
    Value: !Ref DataSecurityGroup
```

### 5.3 `waf-webacl.yaml` — a regional Web ACL with managed rules, rate limiting and logging

```yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: >-
  Regional AWS WAF Web ACL for an Application Load Balancer: AWS managed rule
  groups, IP reputation, an anonymous-IP block, a per-IP rate limit, and full
  request logging with credential redaction.

Parameters:
  LoadBalancerArn:
    Type: String
    Description: ARN of the ALB to associate the Web ACL with.
  RateLimitPer5Min:
    Type: Number
    Default: 2000
    MinValue: 10
    Description: Requests per 5-minute sliding window per source IP.

Resources:

  WafLogGroup:
    Type: AWS::Logs::LogGroup
    Properties:
      # The name MUST start with aws-waf-logs- or the LoggingConfiguration
      # is rejected with WAFInvalidParameterException.
      LogGroupName: aws-waf-logs-prod-alb
      RetentionInDays: 30

  ProdWebAcl:
    Type: AWS::WAFv2::WebACL
    Properties:
      Name: prod-alb-protection
      Scope: REGIONAL          # CLOUDFRONT would require deploying in us-east-1
      Description: Baseline L7 protection for the production ALB.
      DefaultAction:
        Allow: {}
      VisibilityConfig:
        SampledRequestsEnabled: true
        CloudWatchMetricsEnabled: true
        MetricName: prod-alb-protection
      Rules:

        # 10 - Amazon IP reputation list: known malicious sources.
        - Name: AWSManagedRulesAmazonIpReputationList
          Priority: 10
          OverrideAction:
            None: {}
          Statement:
            ManagedRuleGroupStatement:
              VendorName: AWS
              Name: AWSManagedRulesAmazonIpReputationList
          VisibilityConfig:
            SampledRequestsEnabled: true
            CloudWatchMetricsEnabled: true
            MetricName: ip-reputation

        # 20 - Core rule set (OWASP-style baseline). SizeRestrictions_BODY is
        # excluded because our upload endpoint legitimately exceeds 8 KB.
        - Name: AWSManagedRulesCommonRuleSet
          Priority: 20
          OverrideAction:
            None: {}
          Statement:
            ManagedRuleGroupStatement:
              VendorName: AWS
              Name: AWSManagedRulesCommonRuleSet
              RuleActionOverrides:
                - Name: SizeRestrictions_BODY
                  ActionToUse:
                    Count: {}
          VisibilityConfig:
            SampledRequestsEnabled: true
            CloudWatchMetricsEnabled: true
            MetricName: common-rule-set

        # 30 - Known bad inputs: Log4j (Log4JRCE), path traversal, host header injection.
        - Name: AWSManagedRulesKnownBadInputsRuleSet
          Priority: 30
          OverrideAction:
            None: {}
          Statement:
            ManagedRuleGroupStatement:
              VendorName: AWS
              Name: AWSManagedRulesKnownBadInputsRuleSet
          VisibilityConfig:
            SampledRequestsEnabled: true
            CloudWatchMetricsEnabled: true
            MetricName: known-bad-inputs

        # 40 - SQL injection, scoped to the request body and query string.
        - Name: AWSManagedRulesSQLiRuleSet
          Priority: 40
          OverrideAction:
            None: {}
          Statement:
            ManagedRuleGroupStatement:
              VendorName: AWS
              Name: AWSManagedRulesSQLiRuleSet
          VisibilityConfig:
            SampledRequestsEnabled: true
            CloudWatchMetricsEnabled: true
            MetricName: sqli

        # 50 - Anonymising infrastructure. Started in COUNT: measure before
        # you block, or you will page yourself at 02:00 for your own VPN.
        - Name: AWSManagedRulesAnonymousIpList
          Priority: 50
          OverrideAction:
            Count: {}
          Statement:
            ManagedRuleGroupStatement:
              VendorName: AWS
              Name: AWSManagedRulesAnonymousIpList
          VisibilityConfig:
            SampledRequestsEnabled: true
            CloudWatchMetricsEnabled: true
            MetricName: anonymous-ip

        # 60 - Per-IP rate limit, excluding static assets which fan out heavily.
        - Name: RateLimitPerSourceIp
          Priority: 60
          Action:
            Block:
              CustomResponse:
                ResponseCode: 429
                ResponseHeaders:
                  - Name: Retry-After
                    Value: '300'
          Statement:
            RateBasedStatement:
              Limit: !Ref RateLimitPer5Min
              AggregateKeyType: IP
              ScopeDownStatement:
                NotStatement:
                  Statement:
                    ByteMatchStatement:
                      SearchString: /static/
                      FieldToMatch:
                        UriPath: {}
                      TextTransformations:
                        - Priority: 0
                          Type: LOWERCASE
                      PositionalConstraint: STARTS_WITH
          VisibilityConfig:
            SampledRequestsEnabled: true
            CloudWatchMetricsEnabled: true
            MetricName: rate-limit-per-ip

        # 70 - Stricter rate limit on the login endpoint (credential stuffing).
        - Name: RateLimitLoginEndpoint
          Priority: 70
          Action:
            Block: {}
          Statement:
            RateBasedStatement:
              Limit: 100
              AggregateKeyType: IP
              ScopeDownStatement:
                ByteMatchStatement:
                  SearchString: /api/v1/login
                  FieldToMatch:
                    UriPath: {}
                  TextTransformations:
                    - Priority: 0
                      Type: LOWERCASE
                  PositionalConstraint: EXACTLY
          VisibilityConfig:
            SampledRequestsEnabled: true
            CloudWatchMetricsEnabled: true
            MetricName: rate-limit-login

  WebAclAssociation:
    Type: AWS::WAFv2::WebACLAssociation
    Properties:
      ResourceArn: !Ref LoadBalancerArn
      WebACLArn: !GetAtt ProdWebAcl.Arn

  WebAclLogging:
    Type: AWS::WAFv2::LoggingConfiguration
    Properties:
      ResourceArn: !GetAtt ProdWebAcl.Arn
      LogDestinationConfigs:
        - !GetAtt WafLogGroup.Arn
      RedactedFields:
        - SingleHeader:
            Name: authorization
        - SingleHeader:
            Name: cookie
        - SingleHeader:
            Name: x-api-key
      LoggingFilter:
        DefaultBehavior: DROP        # Only persist non-ALLOW outcomes
        Filters:
          - Behavior: KEEP
            Requirement: MEETS_ANY
            Conditions:
              - ActionCondition:
                  Action: BLOCK
              - ActionCondition:
                  Action: COUNT
              - ActionCondition:
                  Action: CAPTCHA

Outputs:
  WebAclArn:
    Value: !GetAtt ProdWebAcl.Arn
  WebAclId:
    Value: !GetAtt ProdWebAcl.Id
```

### 5.4 `scp-protect-security-services.json` — a Service Control Policy

An SCP is the only mechanism that stops an *account administrator* from disabling your detection plane. Attach it to the organizational unit containing workload accounts.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DenyDisablingSecurityServices",
      "Effect": "Deny",
      "Action": [
        "guardduty:DeleteDetector",
        "guardduty:DisassociateFromMasterAccount",
        "guardduty:DisassociateMembers",
        "guardduty:UpdateDetector",
        "guardduty:StopMonitoringMembers",
        "securityhub:DisableSecurityHub",
        "securityhub:DisassociateFromMasterAccount",
        "securityhub:DeleteMembers",
        "securityhub:BatchDisableStandards",
        "config:DeleteConfigurationRecorder",
        "config:DeleteDeliveryChannel",
        "config:StopConfigurationRecorder",
        "config:DeleteConfigRule",
        "config:PutConfigurationRecorder",
        "config:PutDeliveryChannel",
        "cloudtrail:StopLogging",
        "cloudtrail:DeleteTrail",
        "cloudtrail:UpdateTrail",
        "cloudtrail:PutEventSelectors",
        "macie2:DisableMacie",
        "macie2:DisassociateFromAdministratorAccount",
        "inspector2:Disable",
        "inspector2:DisassociateMember",
        "detective:DeleteGraph",
        "access-analyzer:DeleteAnalyzer"
      ],
      "Resource": "*",
      "Condition": {
        "ArnNotLike": {
          "aws:PrincipalARN": [
            "arn:aws:iam::*:role/OrganizationAccountAccessRole",
            "arn:aws:iam::*:role/SecurityBreakGlassRole",
            "arn:aws:iam::*:role/aws-service-role/*"
          ]
        }
      }
    },
    {
      "Sid": "DenyTamperingWithTheLogArchive",
      "Effect": "Deny",
      "Action": [
        "s3:DeleteBucket",
        "s3:DeleteBucketPolicy",
        "s3:PutBucketPolicy",
        "s3:PutLifecycleConfiguration",
        "s3:PutBucketVersioning",
        "s3:DeleteObject",
        "s3:DeleteObjectVersion"
      ],
      "Resource": [
        "arn:aws:s3:::security-logs-*",
        "arn:aws:s3:::security-logs-*/*"
      ],
      "Condition": {
        "ArnNotLike": {
          "aws:PrincipalARN": "arn:aws:iam::*:role/SecurityBreakGlassRole"
        }
      }
    },
    {
      "Sid": "DenyDisablingOrDeletingTheLogArchiveKey",
      "Effect": "Deny",
      "Action": [
        "kms:ScheduleKeyDeletion",
        "kms:DisableKey",
        "kms:DisableKeyRotation",
        "kms:PutKeyPolicy"
      ],
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "aws:ResourceTag/Purpose": "security-log-archive"
        }
      }
    },
    {
      "Sid": "RequireEncryptionInTransitForS3",
      "Effect": "Deny",
      "Action": "s3:*",
      "Resource": "*",
      "Condition": {
        "Bool": {
          "aws:SecureTransport": "false"
        }
      }
    },
    {
      "Sid": "DenyUnencryptedEbsVolumeCreation",
      "Effect": "Deny",
      "Action": "ec2:CreateVolume",
      "Resource": "*",
      "Condition": {
        "Bool": {
          "ec2:Encrypted": "false"
        }
      }
    }
  ]
}
```

> **SCPs never grant permission.** They set the maximum available permission for accounts in the OU. An action is allowed only if it is permitted by *both* the SCP and an identity/resource policy. SCPs do not apply to the **management account** — which is the architectural reason you run no workloads there.

---

## 6. CLI walkthrough

### 6.1 Deploy and confirm the baseline

```console
$ aws cloudformation deploy \
    --template-file security-baseline.yaml \
    --stack-name security-baseline \
    --capabilities CAPABILITY_NAMED_IAM \
    --parameter-overrides \
        OrganizationId=o-a1b2c3d4e5 \
        SecurityContactEmail=secops@example.com \
    --region us-east-1

Waiting for changeset to be created..
Waiting for stack create/update to complete
Successfully created/updated stack - security-baseline
```

```console
$ aws cloudformation describe-stacks \
    --stack-name security-baseline \
    --query 'Stacks[0].Outputs[].{Key:OutputKey,Value:OutputValue}' \
    --output table

--------------------------------------------------------------------------------
|                               DescribeStacks                                 |
+-----------------------+------------------------------------------------------+
|          Key          |                        Value                         |
+-----------------------+------------------------------------------------------+
|  LogArchiveBucket     |  security-logs-111122223333-us-east-1                |
|  LogArchiveKeyArn     |  arn:aws:kms:us-east-1:111122223333:key/3f2c8e1a-... |
|  GuardDutyDetectorId  |  d4bc1a2f9e8746d3b0f5c7a19e2d4b60                    |
|  SecurityAlertsTopic  |  arn:aws:sns:us-east-1:111122223333:security-crit... |
+-----------------------+------------------------------------------------------+
```

### 6.2 CloudTrail — is it actually logging, and is the archive intact?

```console
$ aws cloudtrail get-trail-status --name org-security-trail \
    --query '{Logging:IsLogging,LastDelivery:LatestDeliveryTime,DeliveryError:LatestDeliveryError,DigestDelivery:LatestDigestDeliveryTime}'
{
    "Logging": true,
    "LastDelivery": "2026-09-04T14:18:07.412000+00:00",
    "DeliveryError": null,
    "DigestDelivery": "2026-09-04T14:00:11.883000+00:00"
}
```

`DeliveryError` is the field that matters. A trail with `IsLogging: true` and a non-null `LatestDeliveryError` is producing **nothing** — almost always an S3 bucket policy or KMS key policy problem.

Verify cryptographic integrity of the archive (this requires `EnableLogFileValidation: true` at trail creation — it cannot be applied retroactively):

```console
$ aws cloudtrail validate-logs \
    --trail-arn arn:aws:cloudtrail:us-east-1:111122223333:trail/org-security-trail \
    --start-time 2026-09-01T00:00:00Z \
    --region us-east-1

Validating log files for trail arn:aws:cloudtrail:us-east-1:111122223333:trail/org-security-trail between 2026-09-01T00:00:00Z and 2026-09-04T14:22:31Z

Results requested for 2026-09-01T00:00:00Z to 2026-09-04T14:22:31Z
Results found for 2026-09-01T00:00:00Z to 2026-09-04T14:22:31Z:

3/3 digest files valid
412/412 log files valid
```

Look up who deleted a bucket, straight from Event history:

```console
$ aws cloudtrail lookup-events \
    --lookup-attributes AttributeKey=EventName,AttributeValue=DeleteBucket \
    --start-time 2026-09-03T00:00:00Z \
    --max-results 5 \
    --query 'Events[].{Time:EventTime,User:Username,Resource:Resources[0].ResourceName}' \
    --output table

------------------------------------------------------------------------------
|                                LookupEvents                                |
+----------------------------+----------------+------------------------------+
|            Time            |      User      |          Resource            |
+----------------------------+----------------+------------------------------+
|  2026-09-03T09:41:22+00:00 |  ci-deployer   |  legacy-artifacts-staging    |
+----------------------------+----------------+------------------------------+
```

### 6.3 GuardDuty — enablement, coverage, findings

```console
$ aws guardduty list-detectors
{
    "DetectorIds": [
        "d4bc1a2f9e8746d3b0f5c7a19e2d4b60"
    ]
}

$ aws guardduty get-detector --detector-id d4bc1a2f9e8746d3b0f5c7a19e2d4b60 \
    --query '{Status:Status,Frequency:FindingPublishingFrequency,Features:Features[].{Name:Name,Status:Status}}'
{
    "Status": "ENABLED",
    "Frequency": "FIFTEEN_MINUTES",
    "Features": [
        { "Name": "S3_DATA_EVENTS",         "Status": "ENABLED" },
        { "Name": "EKS_AUDIT_LOGS",         "Status": "ENABLED" },
        { "Name": "EBS_MALWARE_PROTECTION", "Status": "ENABLED" },
        { "Name": "RDS_LOGIN_EVENTS",       "Status": "ENABLED" },
        { "Name": "LAMBDA_NETWORK_LOGS",    "Status": "ENABLED" },
        { "Name": "RUNTIME_MONITORING",     "Status": "ENABLED" }
    ]
}
```

Generate sample findings to validate the whole alerting chain **before** a real incident:

```console
$ aws guardduty create-sample-findings \
    --detector-id d4bc1a2f9e8746d3b0f5c7a19e2d4b60 \
    --finding-types \
        UnauthorizedAccess:EC2/SSHBruteForce \
        CryptoCurrency:EC2/BitcoinTool.B!DNS \
        Exfiltration:S3/AnomalousBehavior
```

```console
$ aws guardduty list-findings \
    --detector-id d4bc1a2f9e8746d3b0f5c7a19e2d4b60 \
    --finding-criteria '{"Criterion":{"severity":{"Gte":7},"service.archived":{"Eq":["false"]}}}' \
    --query 'FindingIds' --output text | tr '\t' '\n' | head -3
1cc4a1e2f0b93d7a5e8c6b4f2a91d073
7ab3f9c5d2e1408b6c3a7f9e5d1b2c48
0e5d8a4b7c2f316d9a0e4b8c5f7a2d19

$ aws guardduty get-findings \
    --detector-id d4bc1a2f9e8746d3b0f5c7a19e2d4b60 \
    --finding-ids 1cc4a1e2f0b93d7a5e8c6b4f2a91d073 \
    --query 'Findings[0].{Type:Type,Severity:Severity,Count:Service.Count,Resource:Resource.ResourceType,Instance:Resource.InstanceDetails.InstanceId,Actor:Service.Action.NetworkConnectionAction.RemoteIpDetails.IpAddressV4,Country:Service.Action.NetworkConnectionAction.RemoteIpDetails.Country.CountryName,First:Service.EventFirstSeen,Last:Service.EventLastSeen}'
{
    "Type": "UnauthorizedAccess:EC2/SSHBruteForce",
    "Severity": 8,
    "Count": 47,
    "Resource": "Instance",
    "Instance": "i-0a1b2c3d4e5f60718",
    "Actor": "198.51.100.77",
    "Country": "Netherlands",
    "First": "2026-09-04T13:02:41.000Z",
    "Last": "2026-09-04T14:31:09.000Z"
}
```

Check organization-wide coverage — the answer to "are all 40 accounts actually protected?":

```console
$ aws guardduty list-members --detector-id d4bc1a2f9e8746d3b0f5c7a19e2d4b60 \
    --query 'Members[].{Account:AccountId,Status:RelationshipStatus,Email:Email}' --output table \
    | head -12

--------------------------------------------------------------------
|                           ListMembers                            |
+---------------+--------------+-----------------------------------+
|    Account    |    Status    |              Email                |
+---------------+--------------+-----------------------------------+
|  444455556666 |  Enabled     |  aws+prod-web@example.com         |
|  555566667777 |  Enabled     |  aws+prod-data@example.com        |
|  666677778888 |  Disabled    |  aws+sandbox-ml@example.com       |
+---------------+--------------+-----------------------------------+
```

`Disabled` on account `666677778888` is a real gap. `auto-enable-organization-members` closes it for future accounts:

```console
$ aws guardduty update-organization-configuration \
    --detector-id d4bc1a2f9e8746d3b0f5c7a19e2d4b60 \
    --auto-enable-organization-members ALL
```

### 6.4 Security Hub — compliance posture in one command

```console
$ aws securityhub get-enabled-standards \
    --query 'StandardsSubscriptions[].{Standard:StandardsArn,Status:StandardsStatus}' --output table

-----------------------------------------------------------------------------------------------
|                                    GetEnabledStandards                                      |
+-------------------------------------------------------------------------+-------------------+
|                                Standard                                 |      Status       |
+-------------------------------------------------------------------------+-------------------+
|  arn:aws:securityhub:us-east-1::standards/aws-foundational-security-...  |  READY            |
|  arn:aws:securityhub:us-east-1::standards/cis-aws-foundations-bench...   |  READY            |
+-------------------------------------------------------------------------+-------------------+
```

```console
$ aws securityhub get-findings \
    --filters '{
        "SeverityLabel":[{"Value":"CRITICAL","Comparison":"EQUALS"}],
        "RecordState":[{"Value":"ACTIVE","Comparison":"EQUALS"}],
        "WorkflowStatus":[{"Value":"NEW","Comparison":"EQUALS"}]
      }' \
    --max-results 5 \
    --query 'Findings[].{Account:AwsAccountId,Product:ProductName,Title:Title,Resource:Resources[0].Id}' \
    --output table

------------------------------------------------------------------------------------------------------
|                                            GetFindings                                             |
+--------------+---------------+--------------------------------------+------------------------------+
|   Account    |    Product    |                Title                 |          Resource            |
+--------------+---------------+--------------------------------------+------------------------------+
| 666677778888 | Security Hub  | S3 general purpose buckets should    | arn:aws:s3:::ml-scratch-2024 |
|              |               | block public read access             |                              |
| 444455556666 | Security Hub  | IAM root user access key should not  | AWS::::Account:444455556666  |
|              |               | exist                                |                              |
| 555566667777 | GuardDuty     | Credentials for the EC2 instance     | arn:aws:ec2:us-east-1:5555.. |
|              |               | role were used from a remote AWS acc.| ..:instance/i-0f3a9c...      |
+--------------+---------------+--------------------------------------+------------------------------+
```

The single most useful posture query — controls that are failing across the whole standard:

```console
$ aws securityhub describe-standards-controls \
    --standards-subscription-arn 'arn:aws:securityhub:us-east-1:111122223333:subscription/aws-foundational-security-best-practices/v/1.0.0' \
    --query 'Controls[?ControlStatus==`ENABLED`].{Id:ControlId,Severity:SeverityRating,Title:Title}' \
    --output text | wc -l
318
```

### 6.5 Network controls — SGs, NACLs and Reachability Analyzer

Find every security group open to the internet on a management port. This is the check Trusted Advisor and FSBP `EC2.19` run for you, but doing it by hand teaches the shape:

```console
$ aws ec2 describe-security-groups \
    --filters Name=ip-permission.cidr,Values=0.0.0.0/0 \
    --query 'SecurityGroups[].{Id:GroupId,Name:GroupName,Vpc:VpcId,Ports:IpPermissions[?contains(IpRanges[].CidrIp,`0.0.0.0/0`)].{From:FromPort,To:ToPort,Proto:IpProtocol}}' \
    --output json

[
    {
        "Id": "sg-0c9d2e1f8a7b34506",
        "Name": "sg-alb",
        "Vpc": "vpc-08f1a2b3c4d5e6f70",
        "Ports": [ { "From": 443, "To": 443, "Proto": "tcp" } ]
    },
    {
        "Id": "sg-04e7f1a9b2c8d3065",
        "Name": "legacy-jumpbox",
        "Vpc": "vpc-08f1a2b3c4d5e6f70",
        "Ports": [ { "From": 22, "To": 22, "Proto": "tcp" },
                   { "From": 3389, "To": 3389, "Proto": "tcp" } ]
    }
]
```

`sg-04e7f1a9b2c8d3065` is the finding: SSH and RDP open to the world.

Prove a path is blocked without generating traffic — **VPC Reachability Analyzer** does symbolic analysis of routes, NACLs and SGs:

```console
$ aws ec2 create-network-insights-path \
    --source i-0a1b2c3d4e5f60718 \
    --destination i-0f3a9c8b7d6e5f402 \
    --protocol tcp --destination-port 5432 \
    --query 'NetworkInsightsPath.NetworkInsightsPathId' --output text
nip-0d8c1a2b3e4f5a6b7

$ aws ec2 start-network-insights-analysis \
    --network-insights-path-id nip-0d8c1a2b3e4f5a6b7 \
    --query 'NetworkInsightsAnalysis.NetworkInsightsAnalysisId' --output text
nia-071e2f3a4b5c6d7e8

$ aws ec2 describe-network-insights-analyses \
    --network-insights-analysis-ids nia-071e2f3a4b5c6d7e8 \
    --query 'NetworkInsightsAnalyses[0].{Status:Status,Reachable:NetworkPathFound,Blocker:Explanations[0].ExplanationCode,Component:Explanations[0].Acl.Id}'
{
    "Status": "succeeded",
    "Reachable": false,
    "Blocker": "ACL_RULE_DENY",
    "Component": "acl-06b2c3d4e5f7a8091"
}
```

`ACL_RULE_DENY` — the NACL, not the security group. Exactly the failure the stateless/stateful distinction predicts.

### 6.6 WAF — is the Web ACL attached, and what is it actually blocking?

```console
$ aws wafv2 list-web-acls --scope REGIONAL \
    --query 'WebACLs[].{Name:Name,Id:Id,Capacity:null}' --output table

------------------------------------------------------------------
|                          ListWebACLs                           |
+----------------------+-----------------------------------------+
|         Name         |                   Id                    |
+----------------------+-----------------------------------------+
|  prod-alb-protection |  6c1f2a3b-4d5e-6f70-8192-a3b4c5d6e7f8   |
+----------------------+-----------------------------------------+

$ aws wafv2 get-web-acl-for-resource \
    --resource-arn arn:aws:elasticloadbalancing:us-east-1:111122223333:loadbalancer/app/prod-alb/9f8e7d6c5b4a3210 \
    --query 'WebACL.Name' --output text
prod-alb-protection
```

If that last command returns nothing, the Web ACL exists but **protects nothing** — the association resource is the piece people forget.

Inspect what a rule caught, without waiting for logs to land:

```console
$ aws wafv2 get-sampled-requests \
    --web-acl-arn arn:aws:wafv2:us-east-1:111122223333:regional/webacl/prod-alb-protection/6c1f2a3b-4d5e-6f70-8192-a3b4c5d6e7f8 \
    --rule-metric-name sqli \
    --scope REGIONAL \
    --time-window StartTime=2026-09-04T13:00:00Z,EndTime=2026-09-04T14:00:00Z \
    --max-items 2 \
    --query 'SampledRequests[].{Action:Action,URI:Request.URI,IP:Request.ClientIP,Country:Request.Country,Rule:RuleNameWithinRuleGroup}'

[
    {
        "Action": "BLOCK",
        "URI": "/api/v1/search",
        "IP": "203.0.113.44",
        "Country": "RU",
        "Rule": "SQLi_QUERYARGUMENTS"
    },
    {
        "Action": "BLOCK",
        "URI": "/api/v1/products",
        "IP": "203.0.113.44",
        "Country": "RU",
        "Rule": "SQLi_BODY"
    }
]
```

### 6.7 KMS — envelope encryption end to end

```console
$ aws kms describe-key --key-id alias/security-logs \
    --query 'KeyMetadata.{Id:KeyId,State:KeyState,Manager:KeyManager,Spec:KeySpec,Usage:KeyUsage,Origin:Origin,MultiRegion:MultiRegion}'
{
    "Id": "3f2c8e1a-7b94-4d05-a2c6-1e8f0b3d9a47",
    "State": "Enabled",
    "Manager": "CUSTOMER",
    "Spec": "SYMMETRIC_DEFAULT",
    "Usage": "ENCRYPT_DECRYPT",
    "Origin": "AWS_KMS",
    "MultiRegion": false
}

$ aws kms get-key-rotation-status --key-id alias/security-logs
{
    "KeyRotationEnabled": true,
    "KeyId": "arn:aws:kms:us-east-1:111122223333:key/3f2c8e1a-7b94-4d05-a2c6-1e8f0b3d9a47",
    "RotationPeriodInDays": 365,
    "NextRotationDate": "2027-06-14T09:11:52.000000+00:00"
}
```

The envelope, by hand:

```console
$ aws kms generate-data-key --key-id alias/security-logs --key-spec AES_256 \
    --query '{Plaintext:Plaintext,Ciphertext:CiphertextBlob}' --output json > dek.json

$ jq -r .Plaintext dek.json | base64 -d > /dev/shm/dek.bin
$ ls -l /dev/shm/dek.bin
-rw-------. 1 sre sre 32 Sep  4 14:41 /dev/shm/dek.bin      # 32 bytes = AES-256

$ openssl enc -aes-256-cbc -pbkdf2 -in report.pdf -out report.pdf.enc \
    -pass file:/dev/shm/dek.bin
$ shred -u /dev/shm/dek.bin        # the plaintext DEK must not survive

# Later, to read it back — only the encrypted DEK was ever stored:
$ jq -r .Ciphertext dek.json | base64 -d > dek.enc
$ aws kms decrypt --ciphertext-blob fileb://dek.enc \
    --key-id alias/security-logs \
    --query Plaintext --output text | base64 -d > /dev/shm/dek.bin
$ openssl enc -d -aes-256-cbc -pbkdf2 -in report.pdf.enc -out report.pdf \
    -pass file:/dev/shm/dek.bin
```

Note that `report.pdf` never went to AWS. Only the 32-byte key did.

### 6.8 Inspector, Macie and Access Analyzer

```console
$ aws inspector2 batch-get-account-status \
    --query 'accounts[0].resourceState.{EC2:ec2.status,ECR:ecr.status,Lambda:lambda.status,LambdaCode:lambdaCode.status}'
{
    "EC2": "ENABLED",
    "ECR": "ENABLED",
    "Lambda": "ENABLED",
    "LambdaCode": "ENABLED"
}

$ aws inspector2 list-findings \
    --filter-criteria '{"severity":[{"comparison":"EQUALS","value":"CRITICAL"}],"findingStatus":[{"comparison":"EQUALS","value":"ACTIVE"}]}' \
    --max-results 3 \
    --query 'findings[].{CVE:packageVulnerabilityDetails.vulnerabilityId,Score:inspectorScore,Resource:resources[0].id,Package:packageVulnerabilityDetails.vulnerablePackages[0].name,Fixed:packageVulnerabilityDetails.vulnerablePackages[0].fixedInVersion}' \
    --output table

------------------------------------------------------------------------------------------
|                                      ListFindings                                      |
+----------------+-------+----------------------------+-----------------+----------------+
|      CVE       | Score |          Resource          |     Package     |     Fixed      |
+----------------+-------+----------------------------+-----------------+----------------+
| CVE-2021-44228 |  10.0 | i-0a1b2c3d4e5f60718        | log4j-core      | 2.17.1         |
| CVE-2024-3094  |  10.0 | i-0f3a9c8b7d6e5f402        | xz-libs         | 5.4.6-1.el9_4  |
| CVE-2023-44487 |   7.5 | sha256:9f2a1b0c3d4e5f6a... | nghttp2         | 1.55.1         |
+----------------+-------+----------------------------+-----------------+----------------+
```

```console
$ aws macie2 get-macie-session --query '{Status:status,Frequency:findingPublishingFrequency}'
{
    "Status": "ENABLED",
    "Frequency": "FIFTEEN_MINUTES"
}

$ aws macie2 list-findings \
    --finding-criteria '{"criterion":{"severity.description":{"eq":["High"]},"archived":{"eq":["false"]}}}' \
    --max-results 2 --query 'findingIds' --output text
2b7e1a9c4f0d38e5a6b7c8d9e0f1a2b3	8d4c3b2a1f0e9d8c7b6a5e4f3d2c1b0a

$ aws macie2 get-findings --finding-ids 2b7e1a9c4f0d38e5a6b7c8d9e0f1a2b3 \
    --query 'findings[0].{Type:type,Bucket:resourcesAffected.s3Bucket.name,Object:resourcesAffected.s3Object.key,Public:resourcesAffected.s3Bucket.publicAccess.effectivePermission,Data:classificationDetails.result.sensitiveData[].category}'
{
    "Type": "SensitiveData:S3Object/Personal",
    "Bucket": "ml-scratch-2024",
    "Object": "exports/customers_full_dump.csv",
    "Public": "PUBLIC",
    "Data": [ "PERSONAL_INFORMATION", "FINANCIAL_INFORMATION" ]
}
```

That single output is a reportable data breach: sensitive data plus `PUBLIC` effective permission.

```console
$ aws accessanalyzer list-findings \
    --analyzer-arn arn:aws:access-analyzer:us-east-1:111122223333:analyzer/org-external-access \
    --filter '{"status":{"eq":["ACTIVE"]},"isPublic":{"eq":["true"]}}' \
    --query 'findings[].{Resource:resource,Type:resourceType,Principal:principal,Actions:action}' \
    --output table

-----------------------------------------------------------------------------------------
|                                     ListFindings                                      |
+-------------------------------+-----------------+-------------+-----------------------+
|           Resource            |      Type       |  Principal  |        Actions        |
+-------------------------------+-----------------+-------------+-----------------------+
| arn:aws:s3:::ml-scratch-2024  | AWS::S3::Bucket | {"AWS":"*"} | s3:GetObject          |
+-------------------------------+-----------------+-------------+-----------------------+
```

---

## 7. Verification and failure diagnosis

### 7.1 The pre-flight checklist

Run this before declaring the baseline "done". It is a single script; each line is a claim you can prove.

```bash
#!/usr/bin/env bash
# verify-security-baseline.sh — exits non-zero if any control is not effective.
set -uo pipefail
FAIL=0
REGION="${AWS_REGION:-us-east-1}"
note() { printf '%-46s %s\n' "$1" "$2"; }
bad()  { note "$1" "FAIL: $2"; FAIL=1; }

# 1. CloudTrail is logging AND delivering.
read -r LOGGING ERR < <(aws cloudtrail get-trail-status --name org-security-trail \
  --query '[IsLogging, LatestDeliveryError]' --output text 2>/dev/null)
[[ "$LOGGING" == "True" ]] || bad "cloudtrail.logging" "IsLogging=$LOGGING"
[[ "$ERR" == "None" ]]     || bad "cloudtrail.delivery" "$ERR"
[[ "$LOGGING" == "True" && "$ERR" == "None" ]] && note "cloudtrail.logging+delivery" "OK"

# 2. The trail is multi-region and org-wide, with log-file validation.
read -r MR ORG LFV < <(aws cloudtrail describe-trails --trail-name-list org-security-trail \
  --query 'trailList[0].[IsMultiRegionTrail,IsOrganizationTrail,LogFileValidationEnabled]' --output text)
[[ "$MR$ORG$LFV" == "TrueTrueTrue" ]] \
  && note "cloudtrail.scope+validation" "OK" \
  || bad "cloudtrail.scope+validation" "multiregion=$MR org=$ORG validation=$LFV"

# 3. Config is RECORDING, not merely configured.
REC=$(aws configservice describe-configuration-recorder-status \
  --query 'ConfigurationRecordersStatus[0].recording' --output text 2>/dev/null)
[[ "$REC" == "True" ]] && note "config.recording" "OK" || bad "config.recording" "recording=$REC"

# 4. GuardDuty detector exists and is enabled.
DET=$(aws guardduty list-detectors --query 'DetectorIds[0]' --output text)
if [[ "$DET" == "None" || -z "$DET" ]]; then
  bad "guardduty.detector" "no detector in $REGION"
else
  ST=$(aws guardduty get-detector --detector-id "$DET" --query Status --output text)
  [[ "$ST" == "ENABLED" ]] && note "guardduty.detector" "OK ($DET)" || bad "guardduty.detector" "$ST"
fi

# 5. Security Hub is on and has at least one READY standard.
RDY=$(aws securityhub get-enabled-standards \
  --query 'length(StandardsSubscriptions[?StandardsStatus==`READY`])' --output text 2>/dev/null)
[[ "${RDY:-0}" -ge 1 ]] && note "securityhub.standards" "OK ($RDY ready)" \
                        || bad "securityhub.standards" "ready=${RDY:-0}"

# 6. No security group exposes SSH or RDP to the internet.
OPEN=$(aws ec2 describe-security-groups \
  --filters Name=ip-permission.cidr,Values=0.0.0.0/0 \
  --query 'length(SecurityGroups[?IpPermissions[?(FromPort==`22`||FromPort==`3389`) && contains(IpRanges[].CidrIp,`0.0.0.0/0`)]])' \
  --output text)
[[ "$OPEN" == "0" ]] && note "ec2.no-open-admin-ports" "OK" \
                     || bad "ec2.no-open-admin-ports" "$OPEN group(s) open"

# 7. The root user has no access keys (CIS 1.4 / FSBP IAM.4).
KEYS=$(aws iam get-account-summary --query 'SummaryMap.AccountAccessKeysPresent' --output text)
[[ "$KEYS" == "0" ]] && note "iam.root-no-access-keys" "OK" || bad "iam.root-no-access-keys" "present"

# 8. EBS encryption by default is on for this region.
EBS=$(aws ec2 get-ebs-encryption-by-default --query EbsEncryptionByDefault --output text)
[[ "$EBS" == "True" ]] && note "ec2.ebs-default-encryption" "OK" || bad "ec2.ebs-default-encryption" "off"

exit "$FAIL"
```

```console
$ ./verify-security-baseline.sh
cloudtrail.logging+delivery                    OK
cloudtrail.scope+validation                    OK
config.recording                               OK
guardduty.detector                             OK (d4bc1a2f9e8746d3b0f5c7a19e2d4b60)
securityhub.standards                          OK (2 ready)
ec2.no-open-admin-ports                        FAIL: 1 group(s) open
iam.root-no-access-keys                        OK
ec2.ebs-default-encryption                     FAIL: off
$ echo $?
1
```

### 7.2 Failure catalogue

| # | Symptom | Root cause | Diagnosis | Fix |
|---|---|---|---|---|
| 1 | Security Hub shows a high compliance score but almost no controls evaluated | Config recorder not running in that region → controls return `NO_DATA`, which is excluded from the score denominator | `aws configservice describe-configuration-recorder-status` → `recording: false` | Start the recorder; deploy the Config StackSet to every enabled region |
| 2 | Trail says `IsLogging: true` but S3 prefix is empty | Bucket policy missing the org-ID prefix (`AWSLogs/o-xxxx/*`) or the `aws:SourceArn` condition doesn't match the trail ARN | `get-trail-status` → `LatestDeliveryError: "InsufficientBucketPolicy"` | Add both `AWSLogs/${AccountId}/*` and `AWSLogs/${OrgId}/*` resources |
| 3 | Same as #2 but the error is `KMS.KMSInvalidStateException` / `AccessDenied` | KMS key policy lacks the `kms:GenerateDataKey*` grant to `cloudtrail.amazonaws.com`, or the encryption-context condition doesn't match | Read `LatestDeliveryError` verbatim | Add the `AllowCloudTrailToEncryptLogs` statement with the `kms:EncryptionContext:aws:cloudtrail:arn` condition |
| 4 | Nobody can use a KMS key, including the account administrator | Key policy has no statement granting `kms:*` to the account root, so IAM policies cannot delegate | `aws kms get-key-policy --policy-name default` shows no root principal | **You cannot fix this yourself.** Open an AWS Support case. Prevent it: always include `EnableIAMPoliciesInThisAccount` |
| 5 | App is unreachable; security groups look correct | NACL is stateless and the ephemeral-port *return* rule is missing | Reachability Analyzer → `ACL_RULE_DENY`; flow logs show `REJECT` on high source ports | Allow `1024–65535` in the return direction |
| 6 | WAF Web ACL exists, blocks nothing | `AWS::WAFv2::WebACLAssociation` was never created, or the Web ACL was created with `Scope: REGIONAL` for a CloudFront distribution | `aws wafv2 get-web-acl-for-resource --resource-arn ...` returns empty | Create the association; for CloudFront use `Scope: CLOUDFRONT` **in us-east-1** |
| 7 | WAF logs show `COUNT`, never `BLOCK`, for a managed rule group | The rule group's `OverrideAction` is `Count: {}` — the count override applies to *every* rule inside the group | `get-web-acl` → `OverrideAction: {"Count":{}}` | Change to `OverrideAction: {"None":{}}` once you have validated the false-positive rate |
| 8 | GuardDuty is "on" but produced nothing during a real incident | Detector enabled only in one region; the attack hit another | `for r in $(aws ec2 describe-regions --query 'Regions[].RegionName' --output text); do aws guardduty list-detectors --region $r; done` | Enable org-wide with `--auto-enable-organization-members ALL` in **every** region, including unused ones |
| 9 | New accounts join the org with no security services | `auto-enable` was not configured for GuardDuty / Security Hub / Config / Firewall Manager | Compare `list-members` against `organizations list-accounts` | Set auto-enable on each service, plus a Control Tower / StackSet baseline |
| 10 | Inspector reports zero EC2 findings on running instances | SSM Agent not running, or the instance profile lacks `AmazonSSMManagedInstanceCore`, so the instance is not a managed node | `aws ssm describe-instance-information` — the instance is absent | Attach the managed policy, ensure the agent runs, or enable agentless scanning |
| 11 | An account admin turned off CloudTrail before doing damage | No SCP protecting the detection plane | `cloudtrail:StopLogging` appears in the org trail (recorded by the org trail before it stopped) | Apply the SCP in §5.4; keep the log archive in a separate account with S3 Object Lock |
| 12 | Shield Advanced is subscribed but a resource was still hit hard | The resource was never added to a protection; Shield Advanced is per-protected-resource | `aws shield list-protections` | `aws shield create-protection`, or use Firewall Manager to auto-protect by tag |
| 13 | Secrets Manager rotation "succeeds" but the app breaks | Rotation advanced `AWSCURRENT` while the app cached the old value; no support for the four-stage rotation contract | Application logs show auth failures ~1 rotation interval after a healthy period | Fetch secrets at connect time, honour `AWSPENDING`/`AWSPREVIOUS`, test with `rotate-secret --rotate-immediately` |

### 7.3 Region sweep — the gap that catches everyone

```console
$ for R in $(aws ec2 describe-regions --query 'Regions[].RegionName' --output text); do
>   D=$(aws guardduty list-detectors --region "$R" --query 'DetectorIds[0]' --output text 2>/dev/null)
>   printf '%-16s %s\n' "$R" "${D:-none}"
> done | grep -E 'None|none'

ap-northeast-3   None
ap-south-2       None
eu-south-2       None
```

Three regions with no detector. An attacker who assumes a role in your account can spin resources up in *any* enabled region. **Either enable detection everywhere, or disable the regions you do not use** (Account settings → Regions, or an SCP with `aws:RequestedRegion`).

---

## 8. Where to find AWS security information

This is an explicitly examinable part of task 2.4 — the exam asks *where you look*, not only *which service you use*.

| Resource | What it gives you | When to reach for it |
|---|---|---|
| **AWS Trust Center** (`aws.amazon.com/trust-center/`) | Central hub for AWS security, privacy and compliance posture; supersedes the old Cloud Security page | Answering a customer/auditor questionnaire |
| **AWS Security Bulletins** (`aws.amazon.com/security/security-bulletins/`) | CVE advisories affecting AWS services, with AWS's assessment and required customer action | A CVE lands and you must know if you are affected |
| **AWS Security Blog** (`aws.amazon.com/blogs/security/`) | Deep-dive technical posts, new feature announcements, reference patterns | Designing a control; learning a new service |
| **AWS Knowledge Center** (`repost.aws/knowledge-center`) | Curated answers to the most common support questions | "Why does my CloudTrail say InsufficientBucketPolicy?" |
| **AWS re:Post** (`repost.aws`) | AWS-managed Q&A community | Peer/AWS-employee answers when docs fall short |
| **AWS Artifact** (console) | On-demand download of AWS's audit reports (SOC 1/2/3, ISO 27001/27017/27018, PCI DSS AoC, FedRAMP) and legal agreements (BAA, NDA-gated reports) | An auditor asks for evidence of *AWS's* controls |
| **AWS Compliance Programs** (`aws.amazon.com/compliance/programs/`) | Which certifications AWS holds, per region and per service | Scoping a regulated workload |
| **AWS Security Reference Architecture (SRA)** (`docs.aws.amazon.com/prescriptive-guidance/latest/security-reference-architecture/`) | The canonical multi-account security account structure, with deployable code | Greenfield landing-zone design |
| **AWS Well-Architected Framework — Security Pillar** | Design principles and a review process | Formal architecture review |
| **AWS Marketplace** (`aws.amazon.com/marketplace`) | **Third-party** security products: next-gen firewalls, WAF managed rule groups, CSPM, SIEM, EDR, vulnerability scanners. Billed on your AWS invoice, deployable as AMIs, containers, SaaS or Professional Services; supports private offers and Enterprise Discount Program spend retirement | You need a vendor control AWS does not provide, and want it on one bill |
| **AWS Customer Support / Shield Response Team (SRT)** | SRT is 24×7 DDoS engineering assistance, **Shield Advanced only** | Under active DDoS attack |
| **AWS Security Incident Response** (service) | Managed 24×7 incident response with the AWS Customer Incident Response Team (CIRT), automated triage of GuardDuty/Security Hub findings, case management | You lack an in-house IR team |
| **AWS Abuse team** (`abuse@amazonaws.com`, or the report form) | Report AWS resources being used to attack you: spam, port scans, DDoS, hosted malware, intrusion attempts | An EC2 instance you do not own is attacking you |
| **AWS vulnerability reporting** (`aws-security@amazon.com`) | Report a vulnerability **in AWS itself** | You found a flaw in an AWS service |
| **AWS Customer Support Policy for Penetration Testing** | Lists the 8+ service categories you may pentest **without prior approval**; other testing, and **all simulated DDoS / stress testing**, requires prior authorisation | Before running a red-team exercise |

> **The abuse-vs-vulnerability distinction is examinable.** Abuse = someone is misusing AWS resources *against* you → AWS Trust & Safety / abuse team. Vulnerability = a security flaw *in AWS* → `aws-security@amazon.com`. A flaw in *your own* application is entirely yours under the shared responsibility model.

---

## 9. Rapid-recall matrix

| If the question says… | The answer is |
|---|---|
| "Continuously monitor for malicious activity and unauthorized behavior" | **Amazon GuardDuty** |
| "Scan EC2 instances and container images for software vulnerabilities (CVEs)" | **Amazon Inspector** |
| "Discover and classify sensitive data such as PII in S3" | **Amazon Macie** |
| "Analyze and investigate the root cause of a security finding" | **Amazon Detective** |
| "Single pane of glass; aggregate findings and check compliance against CIS/PCI" | **AWS Security Hub** |
| "Record a full history of configuration changes; evaluate against rules" | **AWS Config** |
| "Who made this API call, when, and from which IP?" | **AWS CloudTrail** |
| "Protect a web application against SQL injection and cross-site scripting" | **AWS WAF** |
| "Automatic, no-cost protection from common network/transport-layer DDoS" | **AWS Shield Standard** |
| "24/7 DDoS response team and refunds for attack-driven scaling costs" | **AWS Shield Advanced** |
| "Stateful firewall and IDS/IPS for traffic entering and leaving a VPC" | **AWS Network Firewall** |
| "Centrally configure WAF/Shield/SG rules across all accounts in the organization" | **AWS Firewall Manager** |
| "Stateful, instance-level virtual firewall" | **Security group** |
| "Stateless, subnet-level filter that supports explicit deny" | **Network ACL** |
| "Create and control encryption keys; integrated with most AWS services" | **AWS KMS** |
| "Dedicated single-tenant hardware security module under my sole control" | **AWS CloudHSM** |
| "Provision, manage and auto-renew public TLS certificates at no cost" | **AWS Certificate Manager** |
| "Store database credentials with automatic rotation" | **AWS Secrets Manager** |
| "Store configuration parameters and secrets, no rotation, low cost" | **SSM Parameter Store** |
| "Which resources are shared outside my account/organization?" | **IAM Access Analyzer** |
| "Best-practice checks including security, cost and service quotas" | **AWS Trusted Advisor** |
| "Download AWS's SOC 2 report or sign a BAA" | **AWS Artifact** |
| "Continuously collect evidence and map it to a compliance framework" | **AWS Audit Manager** |
| "Buy a third-party firewall or SIEM billed through AWS" | **AWS Marketplace** |
| "Report an EC2 instance attacking my network" | **AWS Abuse / Trust & Safety** |
| "Prevent any account in the OU from disabling CloudTrail" | **Service Control Policy (SCP)** |

---

## 10. Cost note

Every dollar figure in this document is a **rounded us-east-1 list price at time of writing**, given only for order-of-magnitude reasoning. AWS pricing changes, is tiered, and varies by region. Validate against `https://aws.amazon.com/<service>/pricing/` and the AWS Pricing Calculator before committing to any of it. The two figures worth internalising because they change architecture decisions:

- **Shield Advanced is ~$3,000/month per organization with a 1-year commitment.** It is not something you enable casually.
- **CloudTrail data events and GuardDuty S3 Protection scale with request volume, not with resource count.** A single chatty application can move both from tens of dollars to thousands.

---

## Referencias

**Exam and certification**
- AWS Certified Cloud Practitioner (CLF-C02) Exam Guide — https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf
- AWS Certified Cloud Practitioner — https://aws.amazon.com/certification/certified-cloud-practitioner/

**Detection and posture management**
- Amazon GuardDuty User Guide — https://docs.aws.amazon.com/guardduty/latest/ug/what-is-guardduty.html
- GuardDuty finding types — https://docs.aws.amazon.com/guardduty/latest/ug/guardduty_finding-types-active.html
- Amazon Inspector User Guide — https://docs.aws.amazon.com/inspector/latest/user/what-is-inspector.html
- Amazon Macie User Guide — https://docs.aws.amazon.com/macie/latest/user/what-is-macie.html
- Amazon Detective Administration Guide — https://docs.aws.amazon.com/detective/latest/adminguide/what-is-detective.html
- AWS Security Hub User Guide — https://docs.aws.amazon.com/securityhub/latest/userguide/what-is-securityhub.html
- AWS Foundational Security Best Practices standard — https://docs.aws.amazon.com/securityhub/latest/userguide/fsbp-standard.html
- AWS Security Finding Format (ASFF) — https://docs.aws.amazon.com/securityhub/latest/userguide/securityhub-findings-format.html

**Audit, configuration and governance**
- AWS CloudTrail User Guide — https://docs.aws.amazon.com/awscloudtrail/latest/userguide/cloudtrail-user-guide.html
- Validating CloudTrail log file integrity — https://docs.aws.amazon.com/awscloudtrail/latest/userguide/cloudtrail-log-file-validation-intro.html
- AWS Config Developer Guide — https://docs.aws.amazon.com/config/latest/developerguide/WhatIsConfig.html
- AWS Trusted Advisor — https://docs.aws.amazon.com/awssupport/latest/user/trusted-advisor.html
- AWS Audit Manager User Guide — https://docs.aws.amazon.com/audit-manager/latest/userguide/what-is.html
- AWS Artifact User Guide — https://docs.aws.amazon.com/artifact/latest/ug/what-is-aws-artifact.html
- Service Control Policies — https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_scps.html

**Network protection**
- Security groups for your VPC — https://docs.aws.amazon.com/vpc/latest/userguide/vpc-security-groups.html
- Control subnet traffic with network ACLs — https://docs.aws.amazon.com/vpc/latest/userguide/vpc-network-acls.html
- AWS WAF Developer Guide — https://docs.aws.amazon.com/waf/latest/developerguide/waf-chapter.html
- AWS Managed Rules rule groups — https://docs.aws.amazon.com/waf/latest/developerguide/aws-managed-rule-groups-list.html
- AWS Shield Developer Guide — https://docs.aws.amazon.com/waf/latest/developerguide/shield-chapter.html
- AWS Network Firewall Developer Guide — https://docs.aws.amazon.com/network-firewall/latest/developerguide/what-is-aws-network-firewall.html
- AWS Firewall Manager — https://docs.aws.amazon.com/waf/latest/developerguide/fms-chapter.html
- VPC Reachability Analyzer — https://docs.aws.amazon.com/vpc/latest/reachability/what-is-reachability-analyzer.html
- VPC Flow Logs — https://docs.aws.amazon.com/vpc/latest/userguide/flow-logs.html

**Data protection**
- AWS KMS Developer Guide — https://docs.aws.amazon.com/kms/latest/developerguide/overview.html
- KMS envelope encryption — https://docs.aws.amazon.com/kms/latest/developerguide/concepts.html#enveloping
- KMS key policies — https://docs.aws.amazon.com/kms/latest/developerguide/key-policies.html
- AWS CloudHSM User Guide — https://docs.aws.amazon.com/cloudhsm/latest/userguide/introduction.html
- AWS Certificate Manager User Guide — https://docs.aws.amazon.com/acm/latest/userguide/acm-overview.html
- AWS Secrets Manager User Guide — https://docs.aws.amazon.com/secretsmanager/latest/userguide/intro.html
- SSM Parameter Store — https://docs.aws.amazon.com/systems-manager/latest/userguide/systems-manager-parameter-store.html
- IAM Access Analyzer — https://docs.aws.amazon.com/IAM/latest/UserGuide/what-is-access-analyzer.html

**Security information and response**
- AWS Trust Center — https://aws.amazon.com/trust-center/
- AWS Security Bulletins — https://aws.amazon.com/security/security-bulletins/
- AWS Security Blog — https://aws.amazon.com/blogs/security/
- AWS Knowledge Center (re:Post) — https://repost.aws/knowledge-center
- AWS Security Reference Architecture — https://docs.aws.amazon.com/prescriptive-guidance/latest/security-reference-architecture/welcome.html
- AWS Well-Architected Security Pillar — https://docs.aws.amazon.com/wellarchitected/latest/security-pillar/welcome.html
- AWS Compliance Programs — https://aws.amazon.com/compliance/programs/
- Shared Responsibility Model — https://aws.amazon.com/compliance/shared-responsibility-model/
- AWS Security Incident Response — https://docs.aws.amazon.com/security-ir/latest/userguide/what-is-security-ir.html
- Customer Support Policy for Penetration Testing — https://aws.amazon.com/security/penetration-testing/
- Reporting abuse of AWS resources — https://support.aws.amazon.com/#/contacts/report-abuse
- Vulnerability reporting — https://aws.amazon.com/security/vulnerability-reporting/
- AWS Marketplace security category — https://aws.amazon.com/marketplace/solutions/security

**Infrastructure as code references**
- `AWS::GuardDuty::Detector` — https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-resource-guardduty-detector.html
- `AWS::SecurityHub::Hub` — https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-resource-securityhub-hub.html
- `AWS::CloudTrail::Trail` — https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-resource-cloudtrail-trail.html
- `AWS::Config::ConfigurationRecorder` — https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-resource-config-configurationrecorder.html
- `AWS::WAFv2::WebACL` — https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-resource-wafv2-webacl.html
- `AWS::EC2::NetworkAclEntry` — https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-resource-ec2-networkaclentry.html