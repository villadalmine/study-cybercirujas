# 2.3 — Identify AWS Access Management Capabilities

**Certification:** AWS Certified Cloud Practitioner (CLF-C02) · Domain 2: Security and Compliance · Task Statement 2.3
**Exam weight:** 7.5
**Audience profile:** SRE / Platform Architect. This module goes past "IAM has users and roles" into the request-authorization pipeline, credential lifecycles, federation topologies, and the diagnostic procedure you run at 03:00 when a production workload starts returning `AccessDenied`.

---

## 1. The production problem

Access management is the only control plane in AWS that every other control plane depends on. Networking failures are localized; a misconfigured identity is global and silent.

Consider a realistic platform: three AWS accounts (`shared-services`, `prod`, `dev`) under one AWS Organization, an EKS cluster in `prod` running 40 microservices, a CI system that deploys, a data team that queries, and a compliance auditor who must see everything and change nothing.

The failure modes that actually happen in this shape:

| Failure mode | Mechanism | Blast radius |
|---|---|---|
| Long-lived access key committed to a public repo | `AKIA...` static credential, never expires | Full permissions of the attached identity, until manually revoked |
| Root user with an access key | Root bypasses IAM identity policies entirely | Total account compromise; SCPs do not restrict the management account's root |
| `"Action": "*"` on a "temporary" debug role | Nobody removes it; Access Advisor shows it unused for 400 days | Lateral movement path |
| Cross-account role trust with `"Principal": {"AWS": "*"}` | Confused deputy; anyone on Earth can assume it | Data exfiltration from S3/DynamoDB |
| Pod inherits the EC2 node instance profile | No IRSA/Pod Identity; container reaches IMDS | Every pod on the node has the node's permissions |
| Human identities managed as IAM users per account | 3 accounts × 60 engineers = 180 identities, 180 password policies to audit | Offboarding is a manual, error-prone sweep |

Every one of these is prevented by a specific, examinable AWS capability. The architectural goal is a single statement:

> **No human and no workload should ever hold a credential that (a) does not expire, (b) is broader than the current task, or (c) cannot be traced to a named principal in CloudTrail.**

Everything below is the machinery that makes that statement enforceable rather than aspirational.

---

## 2. The identity model: principals, credentials, and the request context

### 2.1 Anatomy of an authorized request

Every AWS API call — console click, SDK call, `kubectl` against EKS, S3 `GetObject` — is an HTTPS request signed with **SigV4** and evaluated identically:

```
┌────────────────────────────────────────────────────────────────────────┐
│ 1. AUTHENTICATION                                                      │
│    Signature (SigV4) over: credential scope, canonical request, date   │
│    Resolves the caller to a PRINCIPAL:                                 │
│      arn:aws:iam::111122223333:user/alice                              │
│      arn:aws:sts::111122223333:assumed-role/payments-api/i-0abc123     │
│      arn:aws:iam::111122223333:root                                    │
├────────────────────────────────────────────────────────────────────────┤
│ 2. REQUEST CONTEXT is assembled                                        │
│    action  = s3:GetObject                                              │
│    resource= arn:aws:s3:::prod-ledger/2026/09/tx.parquet               │
│    context = aws:SourceIp, aws:PrincipalTag/team, aws:PrincipalOrgID,  │
│              aws:MultiFactorAuthPresent, aws:RequestedRegion,          │
│              aws:SecureTransport, aws:VpcSourceIp, aws:userid …        │
├────────────────────────────────────────────────────────────────────────┤
│ 3. AUTHORIZATION — policy evaluation (Section 5)                       │
├────────────────────────────────────────────────────────────────────────┤
│ 4. CloudTrail event emitted regardless of allow/deny                   │
└────────────────────────────────────────────────────────────────────────┘
```

Two consequences an SRE must internalize:

- **A deny is logged.** `AccessDenied` always produces a CloudTrail event with `errorCode`. Absence of a CloudTrail event means the request never reached AWS (DNS, proxy, network) — not that it was denied.
- **IAM is eventually consistent and global.** A policy attached in `us-east-1` propagates within seconds, but retry logic must tolerate a brief window where a fresh role is not yet assumable. Never build a deploy pipeline that creates a role and immediately assumes it without retry.

### 2.2 Credential taxonomy

| Credential | Issued to | Lifetime | Rotatable | Where it belongs |
|---|---|---|---|---|
| Root email + password | Account root user | Permanent | Manual | Locked in a break-glass vault, hardware MFA |
| Console password | IAM user | Permanent (policy-forced rotation) | Yes | Only where Identity Center is unavailable |
| Access key ID / secret (`AKIA…`) | IAM user | **Never expires** | Manual (2-key rotation) | Legacy on-prem integrations only |
| Temporary credentials (`ASIA…` + session token) | Role session (STS) | 15 min – 12 h | Automatic re-issue | **Default for everything** |
| IAM Identity Center session | Federated human | Up to 12 h role session / configurable SSO session | Automatic | All human access |
| Instance profile credentials | EC2 instance | Auto-rotated by the service | Automatic | EC2 workloads |
| IRSA / EKS Pod Identity token | Kubernetes ServiceAccount | ~15 min projected token → 1 h STS session | Automatic | Container workloads |
| Cognito identity pool credentials | End user of your app | Up to 12 h | Automatic | Mobile/web app users, **not** employees |

The `ASIA` vs `AKIA` prefix is a field-diagnostic shortcut: if a leaked key starts with `AKIA`, it is permanent and the incident is severe; `ASIA` expires on its own.

---

## 3. The root user: the one identity you cannot fix later

The root user is not "an admin with more permissions" — it is a structurally different principal:

- It is **not governed by IAM identity-based policies**. You cannot attach a policy to root to restrict it.
- In the **management account**, SCPs do not restrict the root user.
- It is the only principal that can perform a fixed set of tasks.

**Tasks that require the root user (exam-critical list):**

| Task | Why root |
|---|---|
| Change the account name, email address, or root password | Account-level attribute |
| Change or cancel the AWS Support plan | Billing-tier operation |
| Close the AWS account | Irreversible account operation |
| Restore IAM user permissions after an admin locks everyone out | Break-glass |
| Register as a Seller in the Reserved Instance Marketplace | Commercial |
| Enable MFA delete on an S3 bucket / configure S3 bucket versioning MFA delete | Root-only API path |
| Edit an S3 bucket policy or SQS policy containing an invalid/orphaned principal | Only root can repair the deadlock |
| Sign up for GovCloud | Account provisioning |

**The hardening procedure — memorize the order:**

1. Enable **MFA on the root user**, preferably a FIDO2 hardware security key. (IAM supports up to **8 MFA devices per user**, so register a primary key and a vaulted backup.)
2. **Delete all root access keys.** A root access key is an unbounded, non-expiring, non-restrictable credential. There is no legitimate architecture that requires one.
3. Set a long, unique root password stored in a physical or enterprise secrets vault.
4. Attach a monitored email alias (a distribution list, not a person who may leave).
5. Create an EventBridge rule on CloudTrail for `userIdentity.type = Root` and page on it.
6. In AWS Organizations, enable **centralized root access management** to remove root credentials from member accounts entirely, and use privileged root sessions only for the specific repair tasks that require them.

```bash
$ aws iam get-account-summary --query 'SummaryMap.{RootMFA:AccountMFAEnabled,RootKeys:AccountAccessKeysPresent}'
{
    "RootMFA": 1,
    "RootKeys": 0
}
```

`RootMFA: 1` and `RootKeys: 0` is the only acceptable output. Anything else is a P1 finding.

---

## 4. Users, groups, roles: what each one actually is

| | IAM user | IAM group | IAM role |
|---|---|---|---|
| Represents | A permanent identity with its own credentials | A **container for policy attachment** — not an identity | A set of permissions that is **assumed** temporarily |
| Has credentials? | Yes (password and/or access keys) | **No** — a group can never be a principal | No permanent credentials; STS mints temporary ones |
| Can be referenced in a `Principal` block? | Yes | **No** | Yes |
| Nesting | — | **Groups cannot be nested** | Roles can be chained (max 1 h session) |
| Limit (default) | 5,000 per account | 300 per account; 10 groups per user | 1,000 per account |
| Typical use | Legacy integrations, break-glass | Grouping humans by job function | **Everything else** |
| Lifecycle risk | Credentials outlive employment | None | Session expires automatically |

A **role** has two policies, and confusing them is the single most common IAM mistake:

- **Trust policy** (`AssumeRolePolicyDocument`) — *who may assume the role*. It is a resource-based policy on the role itself; its `Principal` element is mandatory.
- **Permissions policy** — *what the role may do once assumed*.

An `AccessDenied` on `sts:AssumeRole` is a **trust policy** problem. An `AccessDenied` on `s3:GetObject` after assuming successfully is a **permissions policy** problem. That single distinction resolves most incidents in under a minute.

**Role use cases (all examinable):**

| Use case | Trust policy principal | STS API |
|---|---|---|
| EC2 instance needs S3 access | `ec2.amazonaws.com` | Internal (instance profile) |
| Lambda function | `lambda.amazonaws.com` | Internal |
| Cross-account access | `arn:aws:iam::111122223333:root` (+ `ExternalId`) | `sts:AssumeRole` |
| Third-party SaaS vendor | Vendor account ARN + **mandatory `sts:ExternalId`** | `sts:AssumeRole` |
| Corporate SAML IdP (Okta, Entra ID, ADFS) | `arn:aws:iam::…:saml-provider/Okta` | `sts:AssumeRoleWithSAML` |
| OIDC IdP (GitHub Actions, EKS IRSA) | `arn:aws:iam::…:oidc-provider/…` | `sts:AssumeRoleWithWebIdentity` |
| Mobile/web app end users | `cognito-identity.amazonaws.com` | `sts:AssumeRoleWithWebIdentity` |
| EKS Pod Identity | `pods.eks.amazonaws.com` | `sts:AssumeRole` + `sts:TagSession` |

---

## 5. Policy types and the evaluation algorithm

### 5.1 The seven policy types

| Type | Attached to | Grants permission? | Scope |
|---|---|---|---|
| **Identity-based** (managed or inline) | User, group, role | **Yes** | What this principal may do |
| **Resource-based** (e.g. S3 bucket policy, KMS key policy, SQS/SNS policy, Lambda resource policy) | The resource | **Yes** (and enables cross-account without an identity policy in some flows) | Who may touch this resource; has a `Principal` element |
| **Permissions boundary** | User or role | **No — only limits** | Maximum permissions a principal can ever have |
| **Service control policy (SCP)** | OU or account (Organizations) | **No — only limits** | Maximum permissions for *principals* in the account |
| **Resource control policy (RCP)** | OU or account (Organizations) | **No — only limits** | Maximum permissions on *resources* in the account, regardless of who calls |
| **Session policy** | Passed at `AssumeRole` time | **No — only limits** | Narrows a single session |
| **ACL** (S3 legacy, cross-account only) | S3 bucket/object, VPC | Yes (legacy) | Avoid; use bucket policies |

The critical mental model: **only identity-based and resource-based policies grant. Everything else is a ceiling.** A permissions boundary with `AdministratorAccess` grants nothing on its own.

### 5.2 Evaluation logic

```
                      ┌─────────────────────────┐
   Request context →  │  Any EXPLICIT DENY?     │── yes ──► DENY (final)
                      └───────────┬─────────────┘
                                  │ no
                      ┌───────────▼─────────────┐
                      │  SCP allows? (if org)   │── no ──► DENY
                      └───────────┬─────────────┘
                      ┌───────────▼─────────────┐
                      │  RCP allows? (if org)   │── no ──► DENY
                      └───────────┬─────────────┘
                      ┌───────────▼─────────────┐
                      │ Resource-based policy   │── allows principal ──► ALLOW*
                      └───────────┬─────────────┘
                      ┌───────────▼─────────────┐
                      │ Permissions boundary    │── no ──► DENY
                      │   allows?               │
                      └───────────┬─────────────┘
                      ┌───────────▼─────────────┐
                      │ Session policy allows?  │── no ──► DENY
                      └───────────┬─────────────┘
                      ┌───────────▼─────────────┐
                      │ Identity-based allows?  │── no ──► DENY (implicit)
                      └───────────┬─────────────┘
                                  ▼  ALLOW

*Same account: a resource-based policy naming the principal is sufficient on its own.
 Cross account: BOTH the identity policy (caller's account) AND the resource policy
 (resource's account) must allow. Two locks, two keys.
```

Three rules that answer most exam questions:

1. **Explicit `Deny` always wins**, from any policy type, at any layer.
2. **Default is implicit deny.** Absence of an allow is a deny.
3. **Cross-account = both sides must allow.** No exceptions worth memorizing at this level.

### 5.3 Anatomy of a policy statement

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ReadLedgerObjectsFromCorpNetworkWithMFA",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:GetObjectVersion"
      ],
      "Resource": "arn:aws:s3:::prod-ledger/team/${aws:PrincipalTag/team}/*",
      "Condition": {
        "Bool":        { "aws:MultiFactorAuthPresent": "true" },
        "IpAddress":   { "aws:SourceIp": ["203.0.113.0/24", "198.51.100.0/24"] },
        "StringEquals":{ "aws:PrincipalOrgID": "o-a1b2c3d4e5" },
        "NumericLessThan": { "aws:MultiFactorAuthAge": "3600" }
      }
    }
  ]
}
```

`"Version": "2012-10-17"` is a **policy language version**, not a date you may edit. Changing it silently disables policy variables such as `${aws:PrincipalTag/team}`.

### 5.4 Managed vs inline policies

| | AWS managed | Customer managed | Inline |
|---|---|---|---|
| Authored by | AWS | You | You |
| Reusable across principals | Yes | Yes | **No — 1:1 with the identity** |
| Versioning / rollback | AWS updates them | **Up to 5 versions, rollback supported** | None |
| Deleted when the identity is deleted | No | No | **Yes** |
| Typical use | Bootstrapping, `ReadOnlyAccess`, service roles | **Production default** | Strict 1:1 coupling you never want reused |

AWS managed policies drift: AWS adds actions to them over time. `PowerUserAccess` and `ReadOnlyAccess` are convenient and imprecise; in a regulated environment, pin customer-managed policies you control.

---

## 6. Least privilege, operationally

"Least privilege" is not a policy you write once; it is a loop:

```
grant broad in dev  →  observe with Access Advisor / CloudTrail
                    →  generate a scoped policy (IAM Access Analyzer policy generation)
                    →  apply as customer-managed policy
                    →  enforce a permissions boundary so it cannot re-widen
                    →  re-audit unused access findings quarterly
```

### 6.1 Permissions boundaries — safe delegation

The problem: you want application teams to create their own IAM roles (self-service), but a team could create a role with `AdministratorAccess` and assume it — a privilege-escalation path.

The boundary solves it: the developer role may create roles **only if** it attaches a specific boundary, and the boundary caps the effective permissions of anything they create.

Effective permissions = **identity policy ∩ permissions boundary**.

### 6.2 RBAC vs ABAC

| | RBAC (role per job function) | ABAC (attribute-based) |
|---|---|---|
| Mechanism | One role/policy per team or function | One policy using `aws:PrincipalTag` vs `aws:ResourceTag` |
| Scaling | Policy count grows with teams × environments | **Constant** — one policy covers all teams |
| New team onboarding | Create role + policy + assignment | Tag the identity and the resources; nothing to author |
| Auditability | Explicit, easy to read | Requires trusted tagging; harder to reason about |
| Prerequisite | None | **Tag governance must be enforced** (tag policies, `aws:RequestTag` conditions) |
| Failure mode | Policy sprawl, stale roles | An untagged or mistagged resource silently changes access |
| Verdict | Default for small orgs and for privileged/break-glass paths | Default for large multi-tenant platforms with mature tagging |

Canonical ABAC statement:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ABACSameTeamEC2Control",
      "Effect": "Allow",
      "Action": ["ec2:StartInstances", "ec2:StopInstances", "ec2:RebootInstances"],
      "Resource": "arn:aws:ec2:*:*:instance/*",
      "Condition": {
        "StringEquals": {
          "aws:ResourceTag/team": "${aws:PrincipalTag/team}",
          "aws:ResourceTag/env":  "${aws:PrincipalTag/env}"
        }
      }
    },
    {
      "Sid": "DenyUntaggedLaunch",
      "Effect": "Deny",
      "Action": "ec2:RunInstances",
      "Resource": "arn:aws:ec2:*:*:instance/*",
      "Condition": {
        "Null": { "aws:RequestTag/team": "true" }
      }
    }
  ]
}
```

---

## 7. Federation and IAM Identity Center

### 7.1 Why IAM users lose

With N accounts and M engineers, IAM users require N×M identities, N password policies, N offboarding steps, and N MFA enrollments. Federation makes it M identities in one directory and zero credentials in AWS.

### 7.2 Options compared

| Capability | IAM users | IAM Identity Center | SAML 2.0 federation direct to IAM | Amazon Cognito |
|---|---|---|---|---|
| Intended subject | Workloads/legacy | **Workforce (employees)** | Workforce (pre-Identity Center pattern) | **Application end users (customers)** |
| Identity source | AWS | Built-in directory, AD, or external IdP (Okta, Entra ID, Ping) | External IdP | User pools, social IdPs, SAML/OIDC |
| Credentials in AWS | Permanent | **None** — temporary only | None | None |
| Multi-account | Per-account users | **Native**, via permission sets | Per-account role + trust config | N/A |
| CLI experience | Static keys in `~/.aws/credentials` | `aws sso login` → auto-refreshing SSO session | Custom scripting | N/A |
| Scale to 10k users | Poor | Excellent | Good | Excellent (millions) |
| MFA | Per user, manual | Centrally enforced; supports passkeys/FIDO2 | Delegated to IdP | Built-in |
| Exam keyword | "long-term credentials" | "**centrally manage access to multiple AWS accounts**" | "existing corporate directory" | "**sign-up and sign-in for your web/mobile app**" |

The single highest-value exam discrimination: **Identity Center = your employees across AWS accounts. Cognito = your customers using your application.**

### 7.3 How a permission set materializes

An IAM Identity Center **permission set** is a template. When you assign `{permission set} × {account} × {group}`, Identity Center provisions an actual IAM role in that account named:

```
AWSReservedSSO_PlatformEngineer_9f0e1d2c3b4a5678
```

That role's trust policy points at the Identity Center SAML provider. This matters operationally: those role ARNs are non-deterministic, so **never hard-code them** in bucket policies or KMS key policies. Match on a path or tag instead:

```json
{
  "Sid": "AllowIdentityCenterRolesByPath",
  "Effect": "Allow",
  "Principal": { "AWS": "arn:aws:iam::111122223333:root" },
  "Action": "s3:GetObject",
  "Resource": "arn:aws:s3:::prod-ledger/*",
  "Condition": {
    "ArnLike": {
      "aws:PrincipalArn": "arn:aws:iam::111122223333:role/aws-reserved/sso.amazonaws.com/*/AWSReservedSSO_DataReader_*"
    }
  }
}
```

### 7.4 MFA capabilities

| MFA type | Phishing-resistant | Use for |
|---|---|---|
| FIDO2 security key / passkey | **Yes** | Root, break-glass, all privileged access |
| Hardware TOTP token | No | Air-gapped operators |
| Virtual MFA (authenticator app) | No | Baseline for all users |
| SMS | No (deprecated) | Do not use |

Enforce with a condition, not a policy document that merely recommends it:

```json
{
  "Sid": "DenyAllExceptSelfServiceUnlessMFA",
  "Effect": "Deny",
  "NotAction": [
    "iam:CreateVirtualMFADevice", "iam:EnableMFADevice",
    "iam:ListMFADevices", "iam:ListVirtualMFADevices",
    "iam:ResyncMFADevice", "iam:GetUser", "sts:GetSessionToken"
  ],
  "Resource": "*",
  "Condition": {
    "BoolIfExists": { "aws:MultiFactorAuthPresent": "false" }
  }
}
```

`BoolIfExists` — not `Bool` — is required, otherwise service-linked calls where the key is absent are wrongly denied.

---

## 8. Workload identity

### 8.1 EC2 instance profiles and IMDSv2

An EC2 instance never stores a key. It obtains credentials from the **Instance Metadata Service**. IMDSv1 was a plain GET, which made any SSRF vulnerability in your application a credential-theft primitive. **IMDSv2** requires a session token obtained with a `PUT` carrying a header, which SSRF cannot forge, plus a hop limit that prevents containers on the host from reaching it.

```bash
# IMDSv1 (legacy — must be disabled)
$ curl http://169.254.169.254/latest/meta-data/iam/security-credentials/
<html><body><b>401 - Unauthorized</b></body></html>

# IMDSv2
$ TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
$ curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
    http://169.254.169.254/latest/meta-data/iam/security-credentials/
payments-api-instance-role
$ curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
    http://169.254.169.254/latest/meta-data/iam/security-credentials/payments-api-instance-role
{
  "Code" : "Success",
  "LastUpdated" : "2026-09-03T04:12:07Z",
  "Type" : "AWS-HMAC",
  "AccessKeyId" : "ASIAIOSFODNN7EXAMPLE",
  "SecretAccessKey" : "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
  "Token" : "IQoJb3JpZ2luX2VjEJr//////////wEaCXVzLWVhc3QtMSJHMEUC...TRUNCATED",
  "Expiration" : "2026-09-03T10:37:44Z"
}
```

Note the `ASIA` prefix and the `Expiration` — this is the whole point.

### 8.2 The SDK credential provider chain

Order matters when diagnosing "it works on my laptop but not in prod":

1. Explicit code parameters
2. Environment variables (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`)
3. Web identity token file (`AWS_WEB_IDENTITY_TOKEN_FILE` — **this is IRSA**)
4. Shared config/credentials files (`~/.aws/credentials`, `~/.aws/config`, including `sso_session` profiles)
5. Container credentials (`AWS_CONTAINER_CREDENTIALS_FULL_URI` — **ECS task roles and EKS Pod Identity**)
6. EC2 instance profile via IMDS

A stale `AWS_ACCESS_KEY_ID` in a Deployment's env block silently outranks IRSA. Check step 2 first, always.

### 8.3 EKS: IRSA vs Pod Identity

| | IRSA (IAM Roles for Service Accounts) | EKS Pod Identity |
|---|---|---|
| Mechanism | OIDC provider + `sts:AssumeRoleWithWebIdentity` | `eks-pod-identity-agent` DaemonSet + `sts:AssumeRole` |
| Trust policy principal | `arn:aws:iam::…:oidc-provider/oidc.eks.<region>.amazonaws.com/id/<ID>` | `pods.eks.amazonaws.com` |
| Per-cluster IAM setup | **One OIDC provider per cluster** | None — reusable across clusters |
| Cross-account | Native | Supported via role chaining |
| Role reuse across clusters | Requires editing the trust policy per cluster | **Trust policy is cluster-agnostic** |
| Session tags | No | **Yes** — cluster/namespace/SA available for ABAC |
| Where the mapping lives | ServiceAccount annotation (in-cluster) | EKS API association (in AWS) |
| Verdict | Existing clusters, cross-cloud OIDC parity | **Default for new clusters** — fewer IAM objects, scales linearly |

Both eliminate the anti-pattern of pods inheriting the node role. Enforce that with a hop limit of 1 on the node's IMDS configuration.

---

## 9. Complete infrastructure: CloudFormation

A deployable, syntactically valid template covering the identity primitives of this task statement.

```yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: >
  Baseline access-management stack for CLF-C02 Task 2.3.
  Creates: a delegated-admin permissions boundary, a self-service developer role,
  a cross-account auditor role with ExternalId, an EC2 instance profile scoped by
  tag, an EKS IRSA role, and an Access Analyzer. No IAM users are created.

Parameters:
  OrgId:
    Type: String
    Description: AWS Organizations ID used to fence principals.
    AllowedPattern: '^o-[a-z0-9]{10,32}$'
    Default: o-a1b2c3d4e5
  AuditorAccountId:
    Type: String
    Description: Account ID of the third-party auditor.
    AllowedPattern: '^[0-9]{12}$'
    Default: '444455556666'
  AuditorExternalId:
    Type: String
    NoEcho: true
    Description: Shared secret that defeats the confused-deputy problem.
    MinLength: 16
  EksOidcProviderUrl:
    Type: String
    Description: EKS cluster OIDC issuer WITHOUT the https:// scheme.
    Default: oidc.eks.us-east-1.amazonaws.com/id/EXAMPLED539D4633E53DE1B716D3041E
  DataBucketName:
    Type: String
    Default: prod-ledger-111122223333

Resources:

  ##########################################################################
  # 1. Permissions boundary — the ceiling for every self-service identity
  ##########################################################################
  DeveloperPermissionsBoundary:
    Type: AWS::IAM::ManagedPolicy
    Properties:
      ManagedPolicyName: platform-developer-boundary
      Description: Maximum permissions any self-service created principal may hold.
      PolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Sid: AllowedServiceSurface
            Effect: Allow
            Action:
              - 's3:*'
              - 'dynamodb:*'
              - 'logs:*'
              - 'sqs:*'
              - 'lambda:*'
              - 'ec2:Describe*'
              - 'cloudwatch:*'
              - 'xray:*'
            Resource: '*'
          - Sid: DenyPrivilegeEscalationPaths
            Effect: Deny
            Action:
              - 'iam:CreateUser'
              - 'iam:CreateAccessKey'
              - 'iam:DeleteRolePermissionsBoundary'
              - 'iam:PutUserPermissionsBoundary'
              - 'iam:AttachUserPolicy'
              - 'organizations:*'
              - 'account:*'
            Resource: '*'
          - Sid: DenyBoundaryTampering
            Effect: Deny
            Action:
              - 'iam:DeleteRolePolicy'
              - 'iam:DetachRolePolicy'
              - 'iam:PutRolePolicy'
            Resource: !Sub 'arn:${AWS::Partition}:iam::${AWS::AccountId}:policy/platform-developer-boundary'
          - Sid: RegionFence
            Effect: Deny
            NotAction:
              - 'iam:*'
              - 'sts:*'
              - 'cloudfront:*'
              - 'route53:*'
              - 'support:*'
            Resource: '*'
            Condition:
              StringNotEquals:
                'aws:RequestedRegion':
                  - us-east-1
                  - eu-west-1

  ##########################################################################
  # 2. Self-service role creation, fenced by the boundary above
  ##########################################################################
  DelegatedRoleCreationPolicy:
    Type: AWS::IAM::ManagedPolicy
    Properties:
      ManagedPolicyName: platform-delegated-role-creation
      PolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Sid: CreateRolesOnlyUnderBoundaryAndPath
            Effect: Allow
            Action:
              - 'iam:CreateRole'
              - 'iam:PutRolePolicy'
              - 'iam:AttachRolePolicy'
            Resource: !Sub 'arn:${AWS::Partition}:iam::${AWS::AccountId}:role/app/*'
            Condition:
              StringEquals:
                'iam:PermissionsBoundary': !Ref DeveloperPermissionsBoundary
          - Sid: ReadOnlyIamIntrospection
            Effect: Allow
            Action:
              - 'iam:Get*'
              - 'iam:List*'
              - 'iam:SimulatePrincipalPolicy'
            Resource: '*'

  DeveloperRole:
    Type: AWS::IAM::Role
    Properties:
      RoleName: platform-developer
      Path: /platform/
      MaxSessionDuration: 3600
      PermissionsBoundary: !Ref DeveloperPermissionsBoundary
      AssumeRolePolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Effect: Allow
            Principal:
              AWS: !Sub 'arn:${AWS::Partition}:iam::${AWS::AccountId}:root'
            Action:
              - 'sts:AssumeRole'
              - 'sts:TagSession'
            Condition:
              StringEquals:
                'aws:PrincipalOrgID': !Ref OrgId
              Bool:
                'aws:MultiFactorAuthPresent': 'true'
              NumericLessThan:
                'aws:MultiFactorAuthAge': '3600'
      ManagedPolicyArns:
        - !Ref DelegatedRoleCreationPolicy
      Tags:
        - Key: team
          Value: platform
        - Key: env
          Value: prod

  ##########################################################################
  # 3. Cross-account auditor — read-only, ExternalId mandatory
  ##########################################################################
  ThirdPartyAuditorRole:
    Type: AWS::IAM::Role
    Properties:
      RoleName: third-party-auditor
      MaxSessionDuration: 3600
      Description: Read-only access for the external audit firm. Confused-deputy safe.
      AssumeRolePolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Effect: Allow
            Principal:
              AWS: !Sub 'arn:${AWS::Partition}:iam::${AuditorAccountId}:root'
            Action: 'sts:AssumeRole'
            Condition:
              StringEquals:
                'sts:ExternalId': !Ref AuditorExternalId
              Bool:
                'aws:SecureTransport': 'true'
      ManagedPolicyArns:
        - !Sub 'arn:${AWS::Partition}:iam::aws:policy/SecurityAudit'
        - !Sub 'arn:${AWS::Partition}:iam::aws:policy/job-function/ViewOnlyAccess'
      Policies:
        - PolicyName: deny-data-plane-reads
          PolicyDocument:
            Version: '2012-10-17'
            Statement:
              - Sid: MetadataOnlyNeverObjectContents
                Effect: Deny
                Action:
                  - 's3:GetObject'
                  - 'dynamodb:GetItem'
                  - 'dynamodb:Query'
                  - 'dynamodb:Scan'
                  - 'kms:Decrypt'
                Resource: '*'

  ##########################################################################
  # 4. EC2 workload identity — no keys, tag-scoped, instance profile
  ##########################################################################
  PaymentsApiRole:
    Type: AWS::IAM::Role
    Properties:
      RoleName: payments-api-instance-role
      AssumeRolePolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Effect: Allow
            Principal:
              Service: ec2.amazonaws.com
            Action: 'sts:AssumeRole'
      Policies:
        - PolicyName: payments-api-least-privilege
          PolicyDocument:
            Version: '2012-10-17'
            Statement:
              - Sid: ReadOwnPrefixOnly
                Effect: Allow
                Action:
                  - 's3:GetObject'
                  - 's3:ListBucket'
                Resource:
                  - !Sub 'arn:${AWS::Partition}:s3:::${DataBucketName}'
                  - !Sub 'arn:${AWS::Partition}:s3:::${DataBucketName}/payments/*'
                Condition:
                  Bool:
                    'aws:SecureTransport': 'true'
              - Sid: WriteOwnLogs
                Effect: Allow
                Action:
                  - 'logs:CreateLogStream'
                  - 'logs:PutLogEvents'
                Resource: !Sub 'arn:${AWS::Partition}:logs:${AWS::Region}:${AWS::AccountId}:log-group:/aws/payments-api:*'
      Tags:
        - Key: team
          Value: payments

  PaymentsApiInstanceProfile:
    Type: AWS::IAM::InstanceProfile
    Properties:
      InstanceProfileName: payments-api-instance-profile
      Roles:
        - !Ref PaymentsApiRole

  ##########################################################################
  # 5. Kubernetes workload identity (IRSA)
  ##########################################################################
  EksOidcProvider:
    Type: AWS::IAM::OIDCProvider
    Properties:
      Url: !Sub 'https://${EksOidcProviderUrl}'
      ClientIdList:
        - sts.amazonaws.com
      ThumbprintList:
        - 9e99a48a9960b14926bb7f3b02e22da2b0ab7280

  LedgerWriterIrsaRole:
    Type: AWS::IAM::Role
    Properties:
      RoleName: eks-ledger-writer
      AssumeRolePolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Effect: Allow
            Principal:
              Federated: !Sub 'arn:${AWS::Partition}:iam::${AWS::AccountId}:oidc-provider/${EksOidcProviderUrl}'
            Action: 'sts:AssumeRoleWithWebIdentity'
            Condition:
              StringEquals:
                # BOTH conditions are required. Omitting :sub lets ANY
                # ServiceAccount in the cluster assume this role.
                !Sub '${EksOidcProviderUrl}:aud': 'sts.amazonaws.com'
                !Sub '${EksOidcProviderUrl}:sub': 'system:serviceaccount:ledger:ledger-writer'
      Policies:
        - PolicyName: ledger-write
          PolicyDocument:
            Version: '2012-10-17'
            Statement:
              - Effect: Allow
                Action:
                  - 's3:PutObject'
                  - 's3:AbortMultipartUpload'
                Resource: !Sub 'arn:${AWS::Partition}:s3:::${DataBucketName}/ledger/*'

  ##########################################################################
  # 6. Continuous verification
  ##########################################################################
  ExternalAccessAnalyzer:
    Type: AWS::AccessAnalyzer::Analyzer
    Properties:
      AnalyzerName: org-external-access
      Type: ACCOUNT
      Tags:
        - Key: purpose
          Value: least-privilege

Outputs:
  DeveloperRoleArn:
    Description: Assume this with aws sts assume-role (MFA required).
    Value: !GetAtt DeveloperRole.Arn
  AuditorRoleArn:
    Description: Hand this ARN plus the ExternalId to the audit firm.
    Value: !GetAtt ThirdPartyAuditorRole.Arn
  IrsaRoleArn:
    Description: Annotate the Kubernetes ServiceAccount with this ARN.
    Value: !GetAtt LedgerWriterIrsaRole.Arn
  BoundaryArn:
    Value: !Ref DeveloperPermissionsBoundary
```

**Gotcha worth noting:** there is no native CloudFormation resource for the account password policy. It must be set via CLI/API or a custom resource:

```bash
$ aws iam update-account-password-policy \
    --minimum-password-length 16 \
    --require-symbols --require-numbers \
    --require-uppercase-characters --require-lowercase-characters \
    --allow-users-to-change-password \
    --max-password-age 90 \
    --password-reuse-prevention 24
```
(no output on success — verify with `get-account-password-policy`)

### 9.1 The Kubernetes side of IRSA

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ledger-writer
  namespace: ledger
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::111122223333:role/eks-ledger-writer
    # Optional: shorten the STS session from the default 1h
    eks.amazonaws.com/token-expiration: "1800"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ledger-writer
  namespace: ledger
spec:
  replicas: 3
  selector:
    matchLabels:
      app: ledger-writer
  template:
    metadata:
      labels:
        app: ledger-writer
    spec:
      serviceAccountName: ledger-writer
      automountServiceAccountToken: true
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        fsGroup: 10001
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: writer
          image: 111122223333.dkr.ecr.us-east-1.amazonaws.com/ledger-writer:1.14.2
          env:
            - name: AWS_REGION
              value: us-east-1
            # STS regional endpoint: avoids the global us-east-1 dependency
            - name: AWS_STS_REGIONAL_ENDPOINTS
              value: regional
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          resources:
            requests: { cpu: "100m", memory: "128Mi" }
            limits:   { memory: "256Mi" }
```

The webhook injects `AWS_ROLE_ARN`, `AWS_WEB_IDENTITY_TOKEN_FILE`, and a projected token volume automatically. If those variables are absent inside the pod, the ServiceAccount annotation is wrong or the pod was created before the annotation existed — the webhook only mutates at admission time, so **the pod must be recreated**.

---

## 10. Application users and secrets

### 10.1 Amazon Cognito

| Component | Purpose | Output |
|---|---|---|
| **User pool** | Authentication directory for your app's users; sign-up, sign-in, MFA, password reset, hosted UI, social/SAML/OIDC federation | JWTs (ID, access, refresh tokens) |
| **Identity pool** (federated identities) | **Authorization** — exchanges a token for temporary AWS credentials via STS | `ASIA…` credentials scoped to an IAM role |

The distinction is examinable: a user pool proves *who* the user is; an identity pool grants *AWS API access* to that user. A mobile app that only calls your own API Gateway needs the user pool alone.

### 10.2 Where credentials live when a credential is unavoidable

| | AWS Secrets Manager | SSM Parameter Store (SecureString) |
|---|---|---|
| Automatic rotation | **Yes**, native Lambda rotation for RDS/Redshift/DocumentDB, custom for others | No (build it yourself with EventBridge) |
| Cross-account access | Resource-based policy on the secret | Advanced tier + resource sharing patterns |
| Cost | Per secret per month + per 10k API calls | **Standard tier free**; advanced tier charged |
| Size limit | 64 KB | 4 KB standard / 8 KB advanced |
| Encryption | KMS, mandatory | KMS for SecureString, optional |
| Replication | Multi-Region secret replication | Manual |
| Use when | Database credentials, third-party API keys, anything rotating | Config values, non-rotating tokens, cost-sensitive |

Neither is a substitute for a role. If a workload can use a role, it should — a secret you never store cannot leak.

---

## 11. CLI runbook

### 11.1 Assume a role with MFA and use it

```bash
$ aws sts get-caller-identity
{
    "UserId": "AIDACKCEVSQ6C2EXAMPLE",
    "Account": "111122223333",
    "Arn": "arn:aws:iam::111122223333:user/alice"
}

$ aws sts assume-role \
    --role-arn arn:aws:iam::111122223333:role/platform/platform-developer \
    --role-session-name alice-ticket-4471 \
    --serial-number arn:aws:iam::111122223333:mfa/alice-yubikey \
    --token-code 492013 \
    --duration-seconds 3600
{
    "Credentials": {
        "AccessKeyId": "ASIAIOSFODNN7EXAMPLE",
        "SecretAccessKey": "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
        "SessionToken": "IQoJb3JpZ2luX2VjEJr//////////wEaCXVzLWVhc3QtMSJHMEUCIQ...TRUNCATED",
        "Expiration": "2026-09-03T11:42:18+00:00"
    },
    "AssumedRoleUser": {
        "AssumedRoleId": "AROA3XFRBF535PLBIFPI4:alice-ticket-4471",
        "Arn": "arn:aws:sts::111122223333:assumed-role/platform-developer/alice-ticket-4471"
    }
}
```

The `--role-session-name` becomes part of the ARN and appears in every CloudTrail event. Put the ticket number there; future-you will thank present-you during the incident review.

### 11.2 Identity Center session (the way humans should actually work)

```bash
$ cat ~/.aws/config
[sso-session corp]
sso_start_url = https://d-9067abc123.awsapps.com/start
sso_region = us-east-1
sso_registration_scopes = sso:account:access

[profile prod-admin]
sso_session = corp
sso_account_id = 111122223333
sso_role_name = PlatformEngineer
region = us-east-1
output = json

$ aws sso login --sso-session corp
Attempting to automatically open the SSO authorization page in your default browser.
If the browser does not open, open the following URL:

https://oidc.us-east-1.amazonaws.com/authorize?...

Then enter the code:

FTQR-VXBK
Successfully logged into Start URL: https://d-9067abc123.awsapps.com/start

$ aws sts get-caller-identity --profile prod-admin
{
    "UserId": "AROA3XFRBF535PLBIFPI4:alice@example.com",
    "Account": "111122223333",
    "Arn": "arn:aws:sts::111122223333:assumed-role/AWSReservedSSO_PlatformEngineer_9f0e1d2c3b4a5678/alice@example.com"
}
```

No secret ever touches disk in a form that outlives the session.

### 11.3 The credential report — your quarterly audit in one command

```bash
$ aws iam generate-credential-report
{
    "State": "STARTED",
    "Description": "No report exists. Starting a new report generation task"
}

$ aws iam get-credential-report --query Content --output text | base64 -d | \
    awk -F, 'NR==1 || $4=="true" || $9=="true" {print $1","$4","$8","$9","$10","$12}' | column -s, -t
user                              password_enabled  access_key_1_active  access_key_1_last_rotated
<root_account>                    not_supported     false                N/A
legacy-backup-agent               false             true                 2023-11-02T09:14:00+00:00
ci-deploy-bot                     false             true                 2026-08-30T02:00:11+00:00
```

`legacy-backup-agent` has a key that has not rotated in nearly three years. That is the finding.

### 11.4 Access Advisor — evidence-driven privilege reduction

```bash
$ JOB=$(aws iam generate-service-last-accessed-details \
    --arn arn:aws:iam::111122223333:role/payments-api-instance-role \
    --query JobId --output text)

$ aws iam get-service-last-accessed-details --job-id "$JOB" \
    --query 'ServicesLastAccessed[?TotalAuthenticatedEntities>`0`].[ServiceNamespace,LastAuthenticated]' \
    --output table
------------------------------------------------
|        GetServiceLastAccessedDetails          |
+-----------+----------------------------------+
|  s3       |  2026-09-03T09:58:12+00:00       |
|  logs     |  2026-09-03T09:59:40+00:00       |
+-----------+----------------------------------+
```

Any service granted but absent from this table for 90+ days is a candidate for removal.

### 11.5 IAM Access Analyzer — external and unused access

```bash
$ aws accessanalyzer list-findings --analyzer-arn "$ANALYZER_ARN" \
    --filter '{"status":{"eq":["ACTIVE"]}}' \
    --query 'findings[].{Resource:resource,Type:resourceType,External:principal,Public:isPublic}' \
    --output table
--------------------------------------------------------------------------------------
|                                    ListFindings                                     |
+--------+----------------------------------------+-------------------+---------------+
| Public | Resource                               | Type              | External      |
+--------+----------------------------------------+-------------------+---------------+
| True   | arn:aws:s3:::prod-ledger-backups       | AWS::S3::Bucket   | {"AWS":"*"}   |
| False  | arn:aws:iam::111122223333:role/vendor  | AWS::IAM::Role    | 999988887777  |
+--------+----------------------------------------+-------------------+---------------+
```

Row one is a public bucket — an outage-grade finding. Row two is expected only if `999988887777` is a known vendor; if it is not in your inventory, it is an intrusion.

Validate a policy **before** you ship it:

```bash
$ aws accessanalyzer validate-policy \
    --policy-type IDENTITY_POLICY \
    --policy-document file://payments-policy.json \
    --query 'findings[].{Type:findingType,Issue:issueCode,Detail:findingDetails}' --output table
------------------------------------------------------------------------------------------
|                                     ValidatePolicy                                      |
+-----------+--------------------------+--------------------------------------------------+
| Type      | Issue                    | Detail                                           |
+-----------+--------------------------+--------------------------------------------------+
| SECURITY_ | PASS_ROLE_WITH_STAR_IN_  | Using the iam:PassRole action with wildcards     |
| WARNING   | RESOURCE                 | in the resource can be overly permissive.        |
| WARNING   | MISSING_TAG_KEY          | Condition key aws:ResourceTag/ has no tag key.   |
+-----------+--------------------------+--------------------------------------------------+
```

---

## 12. Verification and failure diagnosis

### 12.1 The `AccessDenied` decision tree

```
AccessDenied received
   │
   ├─ Does the message name sts:AssumeRole?
   │     └─ YES → TRUST POLICY problem.
   │              Check: Principal ARN, ExternalId, MFA condition,
   │              aws:PrincipalOrgID, and whether the caller's identity
   │              policy allows sts:AssumeRole on that role ARN.
   │
   ├─ Message says "with an explicit deny in a service control policy"?
   │     └─ SCP. Check the OU chain from root down. RegionFence and
   │        service-restriction SCPs are the usual culprits.
   │
   ├─ Message says "with an explicit deny in a resource control policy"?
   │     └─ RCP on the resource's account.
   │
   ├─ Message says "with an explicit deny in a permissions boundary"?
   │     └─ Boundary is narrower than the identity policy. Effective = intersection.
   │
   ├─ Message says "because no identity-based policy allows"?
   │     └─ IMPLICIT deny. Nothing granted it. Add the action/resource.
   │
   ├─ Message says "because no session policy allows"?
   │     └─ The --policy passed at AssumeRole time is too narrow.
   │
   ├─ Message mentions KMS / "not authorized to perform kms:Decrypt"?
   │     └─ TWO policies: the IAM policy AND the KMS KEY POLICY.
   │        A key policy without your principal denies you regardless of IAM.
   │
   ├─ Cross-account S3/SQS/SNS?
   │     └─ BOTH sides required. Also check the S3 Block Public Access
   │        settings and the bucket's Object Ownership setting.
   │
   └─ Encoded message present (EC2/ASG/RunInstances)?
         └─ Decode it (12.3).
```

### 12.2 Simulate before you deploy

```bash
$ aws iam simulate-principal-policy \
    --policy-source-arn arn:aws:iam::111122223333:role/payments-api-instance-role \
    --action-names s3:GetObject s3:DeleteObject \
    --resource-arns arn:aws:s3:::prod-ledger-111122223333/payments/2026/09/tx.parquet \
    --query 'EvaluationResults[].{Action:EvalActionName,Decision:EvalDecision,MatchedBy:MatchedStatements[0].SourcePolicyId}' \
    --output table
------------------------------------------------------------------------
|                       SimulatePrincipalPolicy                         |
+-------------------+------------------------+--------------------------+
|      Action       |       Decision         |        MatchedBy         |
+-------------------+------------------------+--------------------------+
|  s3:GetObject     |  allowed               |  payments-api-least-priv |
|  s3:DeleteObject  |  implicitDeny          |  None                    |
+-------------------+------------------------+--------------------------+
```

`implicitDeny` = no statement matched. `explicitDeny` = something actively denied it. The simulator evaluates identity policies, boundaries, and SCPs, but **does not evaluate resource-based policies for the resource owner's account in every case** — always confirm cross-account paths with a real call.

### 12.3 Decode an authorization failure message

```bash
$ aws ec2 run-instances --image-id ami-0abcdef1234567890 --instance-type m6i.large

An error occurred (UnauthorizedOperation) when calling the RunInstances operation:
You are not authorized to perform this operation.
User: arn:aws:sts::111122223333:assumed-role/platform-developer/alice-ticket-4471
is not authorized to perform: ec2:RunInstances on resource:
arn:aws:ec2:us-east-1:111122223333:instance/*.
Encoded authorization failure message: 8f3Kd9x2QpL...TRUNCATED

$ aws sts decode-authorization-message \
    --encoded-message '8f3Kd9x2QpL...TRUNCATED' \
    --query DecodedMessage --output text | python3 -m json.tool
{
    "allowed": false,
    "explicitDeny": true,
    "matchedStatements": {
        "items": [
            {
                "statementId": "RegionFence",
                "effect": "DENY",
                "principals":  { "items": [{ "value": "AROA3XFRBF535PLBIFPI4" }] },
                "resources":   { "items": [{ "value": "*" }] },
                "conditions":  { "items": [
                    { "key": "aws:RequestedRegion", "values": { "items": [{ "value": "us-east-1" }] } }
                ]}
            }
        ]
    },
    "failures": { "items": [] },
    "context": {
        "principal": { "id": "AROA3XFRBF535PLBIFPI4:alice-ticket-4471",
                       "arn": "arn:aws:sts::111122223333:assumed-role/platform-developer/alice-ticket-4471" },
        "action": "ec2:RunInstances",
        "resource": "arn:aws:ec2:us-east-1:111122223333:instance/*"
    }
}
```

`statementId: RegionFence` names the exact statement. This is the fastest path from symptom to cause in the entire IAM toolchain, and it requires `sts:DecodeAuthorizationMessage` in the caller's policy — grant it to every operator role.

### 12.4 CloudTrail: find the denial you did not catch live

```bash
$ aws cloudtrail lookup-events \
    --lookup-attributes AttributeKey=EventName,AttributeValue=AssumeRole \
    --start-time 2026-09-03T08:00:00Z --end-time 2026-09-03T10:00:00Z \
    --max-results 50 \
    --query 'Events[].CloudTrailEvent' --output text | \
  python3 -c 'import sys,json
for l in sys.stdin.read().split("\n"):
    if not l.strip(): continue
    e=json.loads(l)
    if e.get("errorCode"):
        print(e["eventTime"], e.get("errorCode"),
              e["userIdentity"].get("arn","-"),
              e.get("requestParameters",{}).get("roleArn","-"))'
2026-09-03T09:14:22Z AccessDenied arn:aws:iam::111122223333:user/ci-deploy-bot arn:aws:iam::555566667777:role/deployer
2026-09-03T09:14:52Z AccessDenied arn:aws:iam::111122223333:user/ci-deploy-bot arn:aws:iam::555566667777:role/deployer
```

Repeated `AssumeRole` denials from a bot to a cross-account role = missing or drifted trust policy in `555566667777`, not a permissions problem in `111122223333`.

### 12.5 IRSA-specific triage

```bash
$ kubectl -n ledger exec deploy/ledger-writer -- env | grep AWS_
AWS_REGION=us-east-1
AWS_DEFAULT_REGION=us-east-1
AWS_ROLE_ARN=arn:aws:iam::111122223333:role/eks-ledger-writer
AWS_WEB_IDENTITY_TOKEN_FILE=/var/run/secrets/eks.amazonaws.com/serviceaccount/token
AWS_STS_REGIONAL_ENDPOINTS=regional

$ kubectl -n ledger exec deploy/ledger-writer -- \
    aws sts get-caller-identity
{
    "UserId": "AROAZZ7EXAMPLE4KDXQ:botocore-session-1788436092",
    "Account": "111122223333",
    "Arn": "arn:aws:sts::111122223333:assumed-role/eks-ledger-writer/botocore-session-1788436092"
}
```

If `AWS_ROLE_ARN` is missing: the ServiceAccount annotation is absent, or the pod predates it — delete the pod. If `get-caller-identity` returns the **node** role ARN instead: the SDK fell through to IMDS, meaning the projected token is not mounted. If it returns `InvalidIdentityToken`: the trust policy's `:sub` condition does not match `system:serviceaccount:<namespace>:<serviceaccount>` exactly.

### 12.6 Verification checklist (run as a scheduled job)

| Check | Command | Pass criterion |
|---|---|---|
| Root MFA on, no root keys | `aws iam get-account-summary` | `AccountMFAEnabled=1`, `AccountAccessKeysPresent=0` |
| No access keys older than 90 days | credential report, column `access_key_1_last_rotated` | none older than 90d |
| No IAM users with console access | `aws iam list-users` + credential report | zero, outside break-glass |
| Password policy meets standard | `aws iam get-account-password-policy` | ≥14 chars, reuse prevention on |
| No policy grants `Action:*` on `Resource:*` | `aws accessanalyzer validate-policy` in CI | zero `SECURITY_WARNING` |
| No externally shared resources | `aws accessanalyzer list-findings` | zero unreviewed ACTIVE findings |
| No unused roles/permissions | unused-access analyzer | zero over the tracking period |
| IMDSv2 enforced everywhere | `aws ec2 describe-instances --query 'Reservations[].Instances[?MetadataOptions.HttpTokens!=\`required\`].InstanceId'` | empty list |
| CloudTrail organization trail is on and immutable | `aws cloudtrail describe-trails` | `IsOrganizationTrail=true`, log-file validation enabled |

---

## 13. Exam-level discriminations

These are the pairs that decide questions:

| If the question says… | The answer is… | Not… |
|---|---|---|
| "centrally manage user access to **multiple AWS accounts**" | **IAM Identity Center** | IAM users/groups |
| "sign-up and sign-in for a **mobile/web application's users**" | **Amazon Cognito** | IAM Identity Center |
| "grant an **EC2 instance** access to S3" | **IAM role + instance profile** | Access keys on the instance |
| "**temporary**, limited-privilege credentials" | **AWS STS** | IAM access keys |
| "reduce the **maximum** permissions available to an OU" | **SCP** | IAM policy |
| "restrict who can access **a resource**, org-wide" | **RCP** | SCP |
| "a **third-party vendor** needs access to your account" | **Cross-account role with ExternalId** | An IAM user for the vendor |
| "which tasks **require the root user**" | Close account, change support plan, change root email/password | Anything routine |
| "identify **unused** permissions or **externally shared** resources" | **IAM Access Analyzer** | Trusted Advisor (partial overlap only) |
| "list **when each service was last used** by a principal" | **Access Advisor / service last accessed** | CloudWatch |
| "report of **all users and their credential status**" | **IAM credential report** | Config |
| "automatically **rotate a database password**" | **AWS Secrets Manager** | Parameter Store |
| "record **who did what** in the account" | **AWS CloudTrail** | CloudWatch Logs |
| "IAM is …" | **Global, free of charge** | Regional, billed |

Facts that get tested verbatim:
- IAM is a **global** service and is offered at **no additional charge**.
- **Groups cannot be nested**, cannot contain roles, and cannot be a `Principal`.
- A user can belong to **up to 10 groups**.
- **Explicit deny always overrides any allow.**
- Everything is **implicitly denied** by default.
- **New IAM users have no permissions** until a policy is attached.
- **Roles have no permanent credentials.**
- Enabling MFA on the root user is the **first** recommended action on a new account.
- The **AWS shared responsibility model** places IAM configuration — users, roles, policies, MFA — squarely in the **customer's** half.

---

## 14. Referencias

**Official exam material**
- AWS Certified Cloud Practitioner (CLF-C02) Exam Guide — https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf
- AWS Certified Cloud Practitioner certification page — https://aws.amazon.com/certification/certified-cloud-practitioner/

**IAM core**
- AWS Identity and Access Management User Guide — https://docs.aws.amazon.com/IAM/latest/UserGuide/introduction.html
- Security best practices in IAM — https://docs.aws.amazon.com/IAM/latest/UserGuide/best-practices.html
- Policy evaluation logic — https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_evaluation-logic.html
- Policies and permissions in IAM — https://docs.aws.amazon.com/IAM/latest/UserGuide/access_policies.html
- Permissions boundaries for IAM entities — https://docs.aws.amazon.com/IAM/latest/UserGuide/access_policies_boundaries.html
- IAM JSON policy elements reference — https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_elements.html
- Global condition context keys — https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_condition-keys.html
- IAM roles — https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles.html
- Attribute-based access control (ABAC) — https://docs.aws.amazon.com/IAM/latest/UserGuide/introduction_attribute-based-access-control.html
- IAM and AWS STS quotas — https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_iam-quotas.html

**Root user**
- AWS account root user — https://docs.aws.amazon.com/IAM/latest/UserGuide/id_root-user.html
- Tasks that require root user credentials — https://docs.aws.amazon.com/accounts/latest/reference/root-user-tasks.html
- Centralized root access for member accounts — https://docs.aws.amazon.com/IAM/latest/UserGuide/id_root-user-access-management.html

**MFA and credentials**
- Multi-factor authentication in IAM — https://docs.aws.amazon.com/IAM/latest/UserGuide/id_credentials_mfa.html
- Managing access keys for IAM users — https://docs.aws.amazon.com/IAM/latest/UserGuide/id_credentials_access-keys.html
- Getting credential reports — https://docs.aws.amazon.com/IAM/latest/UserGuide/id_credentials_getting-report.html
- Refining permissions using last accessed information — https://docs.aws.amazon.com/IAM/latest/UserGuide/access_policies_access-advisor.html

**STS and federation**
- AWS Security Token Service API Reference — https://docs.aws.amazon.com/STS/latest/APIReference/welcome.html
- Temporary security credentials in IAM — https://docs.aws.amazon.com/IAM/latest/UserGuide/id_credentials_temp.html
- The confused deputy problem — https://docs.aws.amazon.com/IAM/latest/UserGuide/confused-deputy.html
- Identity providers and federation — https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_providers.html

**IAM Identity Center**
- AWS IAM Identity Center User Guide — https://docs.aws.amazon.com/singlesignon/latest/userguide/what-is.html
- Permission sets — https://docs.aws.amazon.com/singlesignon/latest/userguide/permissionsetsconcept.html
- ABAC with IAM Identity Center — https://docs.aws.amazon.com/singlesignon/latest/userguide/abac.html

**Organizations**
- Service control policies (SCPs) — https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_scps.html
- Resource control policies (RCPs) — https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_rcps.html

**Workload identity**
- IAM roles for Amazon EC2 — https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/iam-roles-for-amazon-ec2.html
- Use IMDSv2 — https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/configuring-instance-metadata-service.html
- IAM roles for service accounts (EKS) — https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html
- EKS Pod Identity — https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html

**Verification tooling**
- IAM Access Analyzer — https://docs.aws.amazon.com/IAM/latest/UserGuide/what-is-access-analyzer.html
- IAM policy simulator — https://docs.aws.amazon.com/IAM/latest/UserGuide/access_policies_testing-policies.html
- AWS CloudTrail User Guide — https://docs.aws.amazon.com/awscloudtrail/latest/userguide/cloudtrail-user-guide.html

**Application identity and secrets**
- Amazon Cognito Developer Guide — https://docs.aws.amazon.com/cognito/latest/developerguide/what-is-amazon-cognito.html
- AWS Secrets Manager User Guide — https://docs.aws.amazon.com/secretsmanager/latest/userguide/intro.html
- AWS Systems Manager Parameter Store — https://docs.aws.amazon.com/systems-manager/latest/userguide/systems-manager-parameter-store.html

**Model and reference architecture**
- AWS Shared Responsibility Model — https://aws.amazon.com/compliance/shared-responsibility-model/
- AWS Well-Architected Framework — Security Pillar — https://docs.aws.amazon.com/wellarchitected/latest/security-pillar/welcome.html
- AWS Security Reference Architecture (AWS SRA) — https://docs.aws.amazon.com/prescriptive-guidance/latest/security-reference-architecture/welcome.html
- AWS::IAM resource type reference (CloudFormation) — https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/AWS_IAM.html