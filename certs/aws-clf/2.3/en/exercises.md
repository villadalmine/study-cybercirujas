# Topic 2.3 — Identify AWS Access Management Capabilities
## Guided Exercises (AWS Certified Cloud Practitioner, CLF-C02 v1.0)

**Domain 2: Security and Compliance — 30% of the exam. Task Statement 2.3 weight: 7.5%.**

> Exam guide: [AWS Certified Cloud Practitioner (CLF-C02) Exam Guide](https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf)

---

### Before you start

**Environment requirements**

| Requirement | Notes |
|---|---|
| A dedicated AWS **sandbox account** | Never run these against a production account. You will create and delete principals. |
| AWS CLI **v2** installed | `aws --version` → `aws-cli/2.x.x Python/3.x.x linux/6.x source/x86_64` |
| An administrative principal to bootstrap from | An `AdministratorAccess` role reached through IAM Identity Center is the production-correct way; a long-lived IAM admin user is acceptable in a throwaway sandbox. |
| Optional: an AWS Organizations sandbox org | Only Exercise 7 needs it. It is marked *optional*. |

**Cost**

IAM, AWS Organizations, IAM Access Analyzer (external access findings), credential reports and Access Advisor are **free**. The only billable resources in this material are the optional EC2 instance in Exercise 5 (`t3.micro`, delete it within the hour) and the optional Secrets Manager secret in Exercise 9 (≈ USD 0.40 per secret-month, prorated). Everything else costs nothing.

**Conventions**

Throughout, `111122223333` is *your* lab account and `444455556666` is a second, "partner" account. Substitute your own IDs. All ARNs, key IDs and principal IDs in expected outputs are examples — yours will differ. Sample identifiers follow the AWS documentation convention (`AKIAIOSFODNN7EXAMPLE`, `AIDA…EXAMPLE`) and are **not** valid credentials.

Set this once in every shell you use:

```bash
export AWS_REGION=us-east-1
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export LAB_BUCKET="teachplat-clf-lab-${ACCOUNT_ID}"
echo "$ACCOUNT_ID / $LAB_BUCKET"
```

---

## Exercise 1 — The four ways into AWS, and where credentials actually live

**Goal:** prove to yourself that the Console, CLI, SDK, and IaC are four *front ends onto the same API*, all gated by the same IAM authorization decision, and learn the credential provider chain the CLI/SDK walk before every call.

### Block 1.1 — One API, four front ends

1. Sign in to the AWS Management Console and open **S3 → Create bucket**. Do **not** submit the form yet. Open your browser's developer tools, **Network** tab, and filter on `Fetch/XHR`. Now submit the form.
2. Observe the request the Console fires. The Console is a JavaScript application that calls the same public service endpoint (`s3.amazonaws.com`) with a SigV4-signed request that you would produce from the CLI. Delete the bucket you just made.
3. Do the same operation from the CLI with wire-level tracing enabled:

```bash
aws s3api create-bucket --bucket "$LAB_BUCKET" --region us-east-1 --debug 2>&1 \
  | grep -E "Making request|Signature|AWS4-HMAC-SHA256" | head -5
```

Expected (abridged):

```
2026-09-04 11:02:41,908 - MainThread - botocore.hooks - DEBUG - Event request-created.s3.CreateBucket
2026-09-04 11:02:41,910 - MainThread - botocore.auth - DEBUG - Calculating signature using v4 auth.
2026-09-04 11:02:41,911 - MainThread - botocore.auth - DEBUG - CanonicalRequest:
PUT
/
...
Authorization: AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20260904/us-east-1/s3/aws4_request, SignedHeaders=host;x-amz-date, Signature=...
```

4. Now the same thing declaratively. Write `bucket.yaml`:

```yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: Topic 2.3 lab bucket, created via IaC to show the API is the same

Parameters:
  BucketName:
    Type: String
    Description: Globally unique bucket name

Resources:
  LabBucket:
    Type: AWS::S3::Bucket
    Properties:
      BucketName: !Ref BucketName
      PublicAccessBlockConfiguration:
        BlockPublicAcls: true
        BlockPublicPolicy: true
        IgnorePublicAcls: true
        RestrictPublicBuckets: true
      BucketEncryption:
        ServerSideEncryptionConfiguration:
          - ServerSideEncryptionByDefault:
              SSEAlgorithm: AES256
      VersioningConfiguration:
        Status: Enabled

Outputs:
  BucketArn:
    Description: ARN of the lab bucket
    Value: !GetAtt LabBucket.Arn
```

```bash
aws cloudformation deploy \
  --stack-name clf-lab-bucket \
  --template-file bucket.yaml \
  --parameter-overrides BucketName="${LAB_BUCKET}-iac"
```

Expected:

```
Waiting for changeset to be created..
Waiting for stack create/update to complete
Successfully created/updated stack - clf-lab-bucket
```

5. Confirm CloudFormation acted **as you**, not as some AWS super-user, by reading the CloudTrail record of the call:

```bash
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=EventName,AttributeValue=CreateBucket \
  --max-results 2 \
  --query 'Events[].{User:Username,Time:EventTime,Src:EventSource}' \
  --output table
```

> **Q1.1** — The Console, the CLI, an SDK (`boto3`, `aws-sdk-js`), and CloudFormation all created a bucket. From IAM's point of view, how many *different* authorization mechanisms were involved?
>
> **Q1.2** — Step 5 showed a `Username` in CloudTrail for the CloudFormation-driven call. Why does CloudFormation not have "its own" permissions by default, and what feature changes that?
>
> **Q1.3** — Which of the four access methods is *unavailable* to an IAM role, and why?

### Block 1.2 — The credential provider chain

6. Inspect where the CLI is currently reading credentials from:

```bash
aws configure list
```

Expected:

```
      Name                    Value             Type    Location
      ----                    -----             ----    --------
   profile                <not set>             None    None
access_key     ****************MPLE shared-credentials-file
secret_key     ****************EKEY shared-credentials-file
    region                us-east-1      config-file    ~/.aws/config
```

The `Type`/`Location` columns are the point of the whole exercise: they tell you *which link of the provider chain won*.

7. Override with environment variables and re-run. Environment variables sit **above** the shared credentials file in precedence:

```bash
AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE \
AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY \
aws configure list
```

Expected — note the `Type` column changed:

```
access_key     ****************MPLE              env
secret_key     ****************EKEY              env
```

8. Inspect the files themselves. `~/.aws/credentials` holds secrets; `~/.aws/config` holds non-secret settings and role/SSO wiring:

```bash
cat ~/.aws/config
```

```ini
[default]
region = us-east-1
output = json

[profile lab-audit]
role_arn = arn:aws:iam::111122223333:role/LabAuditRole
source_profile = default
role_session_name = clf-lab
duration_seconds = 3600
```

9. Verify file permissions. A world-readable credentials file is a finding in any audit:

```bash
ls -l ~/.aws/credentials
```

Expected: `-rw------- 1 you you 116 Sep  4 11:04 /home/you/.aws/credentials`. If it is not `600`, run `chmod 600 ~/.aws/credentials`.

> **Q1.4** — Order these from *highest* to *lowest* precedence in the AWS CLI v2 / SDK default chain: shared credentials file, EC2 instance profile (IMDS), environment variables, command-line `--profile`, ECS container credentials.
>
> **Q1.5** — In step 8, the `lab-audit` profile has no access key at all. Where do its credentials come from at call time, and how long do they last?
>
> **Q1.6** — Your teammate pastes an access key into a Lambda environment variable "so the function can reach S3". Name the AWS-native mechanism that removes the key entirely, and state the two properties that make it strictly safer.

*Sources:* [Configuration and credential file settings](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-files.html) · [Standardized credential providers](https://docs.aws.amazon.com/sdkref/latest/guide/standardized-credentials.html) · [Signing AWS API requests](https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_aws-signing.html)

---

## Exercise 2 — Root user: what it is, what only it can do, how to lock it down

**Goal:** treat the root user as what it actually is — a break-glass credential that is *not* an IAM principal and cannot be constrained by IAM policy.

### Block 2.1 — Audit the root user

1. Generate a credential report. This is an **account-wide** CSV covering every IAM user *plus* the root account:

```bash
aws iam generate-credential-report
```

Expected:

```json
{
    "State": "STARTED"
}
```

Re-run until `"State": "COMPLETE"` (a few seconds).

2. Download and decode it:

```bash
aws iam get-credential-report --query Content --output text | base64 --decode > credential-report.csv
head -2 credential-report.csv | cut -d, -f1-9
```

Expected:

```
user,arn,user_creation_time,password_enabled,password_last_used,password_last_changed,password_next_rotation,mfa_active,access_key_1_active
<root_account>,arn:aws:iam::111122223333:root,2026-08-30T14:02:11+00:00,not_supported,2026-09-03T18:44:02+00:00,not_supported,not_supported,true,false
```

3. Read the three fields that matter for the root user:

```bash
grep '^<root_account>' credential-report.csv | awk -F, '{print "mfa_active="$8, "access_key_1_active="$9, "access_key_2_active="$14}'
```

The target state is `mfa_active=true access_key_1_active=false access_key_2_active=false`.

4. Confirm the same thing through the account summary, which is what most auditors query:

```bash
aws iam get-account-summary --query 'SummaryMap.{RootMFA:AccountMFAEnabled,RootKeys:AccountAccessKeysPresent,Users:Users,MFADevices:MFADevices}'
```

Expected (good state):

```json
{
    "RootMFA": 1,
    "RootKeys": 0,
    "Users": 3,
    "MFADevices": 4
}
```

`RootMFA: 1` means root MFA is on. `RootKeys: 0` means the root user has **no access keys** — the single most important line in this output.

> **Q2.1** — `password_enabled` is `not_supported` for `<root_account>`. Why does IAM refuse to report a field that obviously exists?
>
> **Q2.2** — Your `get-account-summary` returns `"AccountAccessKeysPresent": 1`. Explain in one sentence why this is more serious than an IAM user having an active key, and state the remediation.
>
> **Q2.3** — Which AWS service consumes the credential report to *continuously* evaluate `root MFA enabled` rather than as a one-off manual check?

### Block 2.2 — Tasks only the root user can perform

5. Attempt a root-only operation with your (administrative, but non-root) principal — enabling S3 MFA Delete:

```bash
aws s3api put-bucket-versioning \
  --bucket "$LAB_BUCKET" \
  --versioning-configuration Status=Enabled,MFADelete=Enabled \
  --mfa "arn:aws:iam::${ACCOUNT_ID}:mfa/lab-token 123456"
```

Expected failure (even with `AdministratorAccess`):

```
An error occurred (AccessDenied) when calling the PutBucketVersioning operation: Access Denied
```

MFA Delete can be configured **only** by the bucket owner's root user, holding a root MFA device. `AdministratorAccess` does not help. This is the cleanest demonstration in AWS that root ≠ admin.

6. Read the canonical list rather than memorising folklore:

```bash
# Open in a browser:
# https://docs.aws.amazon.com/accounts/latest/reference/root-user-tasks.html
```

The recurring exam-relevant members of that list:

- Change the account name, root email address, or root password
- Change the AWS Support plan
- **Close the AWS account**
- Restore IAM user permissions when the last administrator has locked everyone out
- Enable **S3 MFA Delete** on a bucket
- Register as a seller in the Reserved Instance Marketplace
- Sign up for AWS GovCloud (US)
- Request removal of the EC2 port 25 (SMTP) sending limit
- Certain tax-invoice and billing-console actions

7. Harden the root user. Do these in the Console as root, then sign out and never use it again for routine work:
   1. **Account → Security credentials → Multi-factor authentication → Assign MFA device.** Prefer a **FIDO2 security key** or a hardware TOTP token over a phone-based virtual authenticator. You may register up to **8 MFA devices** per root user — register two, and store the second in a different physical location.
   2. **Delete every root access key.** If `RootKeys` was `1` in step 4, this is the fix.
   3. Set the root email to a **distribution list** monitored by more than one human, not an individual's mailbox.
   4. In an AWS Organizations setting, apply an SCP that denies all actions to the member-account root principal, and use **centralized root access management** to remove root credentials from member accounts entirely.

> **Q2.4** — Step 5 failed with `AdministratorAccess` attached. Explain the underlying reason using the words *principal* and *policy evaluation*.
>
> **Q2.5** — You are the only administrator, you deleted your own admin policy, and you are locked out. Which of the "root-only" tasks saves you, and what does this imply about deleting root's password?
>
> **Q2.6** — Why is an FIDO2 security key materially stronger than a TOTP app for the root user? Name the attack class it defeats.

*Sources:* [Tasks that require root user credentials](https://docs.aws.amazon.com/accounts/latest/reference/root-user-tasks.html) · [Getting credential reports](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_credentials_getting-report.html) · [MFA in AWS](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_credentials_mfa.html) · [Centralized root access management](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_root-user-access-management.html)

---

## Exercise 3 — Users, groups, and identity-based policies (least privilege in practice)

**Goal:** build the classic user → group → policy chain, then verify that permissions are *exactly* what you intended and no more.

### Block 3.1 — Build the chain

1. Set an account password policy first, so any console user you create inherits it:

```bash
aws iam update-account-password-policy \
  --minimum-password-length 14 \
  --require-uppercase-characters \
  --require-lowercase-characters \
  --require-numbers \
  --require-symbols \
  --allow-users-to-change-password \
  --password-reuse-prevention 24 \
  --max-password-age 365
```

Verify:

```bash
aws iam get-account-password-policy --query PasswordPolicy
```

Expected:

```json
{
    "MinimumPasswordLength": 14,
    "RequireSymbols": true,
    "RequireNumbers": true,
    "RequireUppercaseCharacters": true,
    "RequireLowercaseCharacters": true,
    "AllowUsersToChangePassword": true,
    "ExpirePasswords": true,
    "MaxPasswordAge": 365,
    "PasswordReusePrevention": 24
}
```

2. Create a group. **Attach policies to groups, never to individual users** — a group is the only IAM construct whose permission grant survives staff turnover cleanly:

```bash
aws iam create-group --group-name DataAnalysts
```

Expected:

```json
{
    "Group": {
        "Path": "/",
        "GroupName": "DataAnalysts",
        "GroupId": "AGPAEXAMPLEGROUPID01",
        "Arn": "arn:aws:iam::111122223333:group/DataAnalysts",
        "CreateDate": "2026-09-04T11:15:33+00:00"
    }
}
```

3. Author a **customer managed policy** that is genuinely least-privilege — scoped to one bucket, one prefix, read-only, and requiring TLS:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ListOnlyTheReportsPrefix",
      "Effect": "Allow",
      "Action": "s3:ListBucket",
      "Resource": "arn:aws:s3:::teachplat-clf-lab-111122223333",
      "Condition": {
        "StringLike": {
          "s3:prefix": ["reports/*", "reports/"]
        }
      }
    },
    {
      "Sid": "ReadObjectsUnderReports",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:GetObjectVersion"
      ],
      "Resource": "arn:aws:s3:::teachplat-clf-lab-111122223333/reports/*"
    },
    {
      "Sid": "DenyInsecureTransport",
      "Effect": "Deny",
      "Action": "s3:*",
      "Resource": [
        "arn:aws:s3:::teachplat-clf-lab-111122223333",
        "arn:aws:s3:::teachplat-clf-lab-111122223333/*"
      ],
      "Condition": {
        "Bool": {
          "aws:SecureTransport": "false"
        }
      }
    }
  ]
}
```

Save as `analyst-policy.json` (substituting your bucket name) and create it:

```bash
aws iam create-policy \
  --policy-name LabReportsReadOnly \
  --description "Read-only on the reports/ prefix of the CLF lab bucket" \
  --policy-document file://analyst-policy.json
```

Expected:

```json
{
    "Policy": {
        "PolicyName": "LabReportsReadOnly",
        "PolicyId": "ANPAEXAMPLEPOLICYID1",
        "Arn": "arn:aws:iam::111122223333:policy/LabReportsReadOnly",
        "DefaultVersionId": "v1",
        "AttachmentCount": 0,
        "IsAttachable": true,
        "CreateDate": "2026-09-04T11:18:02+00:00"
    }
}
```

4. Attach the policy to the group, create a user, and put the user in the group:

```bash
aws iam attach-group-policy \
  --group-name DataAnalysts \
  --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/LabReportsReadOnly"

aws iam create-user --user-name lab-analyst --tags Key=Department,Value=Analytics Key=CostCenter,Value=CC-4471

aws iam add-user-to-group --user-name lab-analyst --group-name DataAnalysts
```

5. Confirm the user has **no directly attached policies** and **no inline policies** — all permissions arrive through the group:

```bash
aws iam list-attached-user-policies --user-name lab-analyst
aws iam list-user-policies --user-name lab-analyst
aws iam list-groups-for-user --user-name lab-analyst --query 'Groups[].GroupName'
```

Expected:

```json
{ "AttachedPolicies": [] }
{ "PolicyNames": [] }
[ "DataAnalysts" ]
```

> **Q3.1** — A group has a `GroupId` and an ARN. Can a group be named as the `Principal` in an S3 bucket policy? Justify your answer.
>
> **Q3.2** — In the policy above, why are there **two** separate `Allow` statements with different `Resource` values, rather than one statement listing both actions against `arn:aws:s3:::bucket/*`?
>
> **Q3.3** — The `DenyInsecureTransport` statement uses `aws:SecureTransport`. Name the policy element it lives in, and explain why a `Deny` with a condition is the correct construct here rather than narrowing the `Allow`.
>
> **Q3.4** — Distinguish *managed policy* (AWS managed vs customer managed) from *inline policy* in one sentence each, and give the operational reason to prefer managed.

### Block 3.2 — Verify the grant without waiting for an incident

6. Use the **policy simulator API** — this evaluates the real policy graph without performing any action:

```bash
aws iam simulate-principal-policy \
  --policy-source-arn "arn:aws:iam::${ACCOUNT_ID}:user/lab-analyst" \
  --action-names s3:GetObject s3:PutObject s3:DeleteBucket \
  --resource-arns "arn:aws:s3:::${LAB_BUCKET}/reports/q3.csv" \
  --query 'EvaluationResults[].{Action:EvalActionName,Decision:EvalDecision}' \
  --output table
```

Expected:

```
------------------------------------
|    SimulatePrincipalPolicy       |
+-----------------+----------------+
|     Action      |    Decision    |
+-----------------+----------------+
|  s3:GetObject   |  allowed       |
|  s3:PutObject   |  implicitDeny  |
|  s3:DeleteBucket|  implicitDeny  |
+-----------------+----------------+
```

7. Now test it live. Create access keys for the user *only for this lab*, and register a named profile:

```bash
aws iam create-access-key --user-name lab-analyst
```

```json
{
    "AccessKey": {
        "UserName": "lab-analyst",
        "AccessKeyId": "AKIAIOSFODNN7EXAMPLE",
        "Status": "Active",
        "SecretAccessKey": "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
        "CreateDate": "2026-09-04T11:22:47+00:00"
    }
}
```

```bash
aws configure set aws_access_key_id     AKIAIOSFODNN7EXAMPLE --profile analyst
aws configure set aws_secret_access_key wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY --profile analyst
aws configure set region us-east-1 --profile analyst
```

8. Seed an object as admin, then read it as the analyst:

```bash
echo "region,revenue
us-east-1,120000" > q3.csv
aws s3 cp q3.csv "s3://${LAB_BUCKET}/reports/q3.csv"

aws --profile analyst s3 cp "s3://${LAB_BUCKET}/reports/q3.csv" -
```

Expected: the CSV contents print to stdout.

9. Confirm the boundary of the grant — three denials, each with a *different* reason:

```bash
aws --profile analyst s3 cp q3.csv "s3://${LAB_BUCKET}/reports/upload.csv"
aws --profile analyst s3 cp "s3://${LAB_BUCKET}/secrets/keys.txt" -
aws --profile analyst iam list-users
```

Expected:

```
upload failed: ./q3.csv to s3://teachplat-clf-lab-111122223333/reports/upload.csv An error occurred (AccessDenied) when calling the PutObject operation: User: arn:aws:iam::111122223333:user/lab-analyst is not authorized to perform: s3:PutObject on resource: "arn:aws:s3:::teachplat-clf-lab-111122223333/reports/upload.csv" because no identity-based policy allows the s3:PutObject action

fatal error: An error occurred (AccessDenied) when calling the GetObject operation: Access Denied

An error occurred (AccessDenied) when calling the ListUsers operation: User: arn:aws:iam::111122223333:user/lab-analyst is not authorized to perform: iam:ListUsers on resource: arn:aws:iam::111122223333:user/ because no identity-based policy allows the iam:ListUsers action
```

Read the tail of each message. The phrase **"because no identity-based policy allows"** is IAM telling you this was an *implicit* deny — nothing denied it, nothing allowed it either.

10. Check the key's age, because rotation is the other half of key hygiene:

```bash
aws iam list-access-keys --user-name lab-analyst \
  --query 'AccessKeyMetadata[].{Id:AccessKeyId,Status:Status,Created:CreateDate}' --output table
aws iam get-access-key-last-used --access-key-id AKIAIOSFODNN7EXAMPLE \
  --query 'AccessKeyLastUsed.{When:LastUsedDate,Service:ServiceName,Region:Region}'
```

> **Q3.5** — Step 6 returned `implicitDeny` for `s3:PutObject`, but Exercise 4 will show `explicitDeny`. What is the operational difference, and which one can never be overridden by adding another `Allow`?
>
> **Q3.6** — Why did `s3:GetObject` on `secrets/keys.txt` fail with a bare `Access Denied` and no explanatory clause, while `iam:ListUsers` produced a detailed message?
>
> **Q3.7** — You created a long-lived access key in step 7. State the production-correct alternative for (a) a human analyst and (b) an application running on EC2.
>
> **Q3.8** — `get-access-key-last-used` returns `LastUsedDate` absent. Give two distinct interpretations of that result and how you would tell them apart.

*Sources:* [IAM security best practices](https://docs.aws.amazon.com/IAM/latest/UserGuide/best-practices.html) · [Identity-based vs resource-based policies](https://docs.aws.amazon.com/IAM/latest/UserGuide/access_policies_identity-vs-resource.html) · [Testing policies with the IAM policy simulator](https://docs.aws.amazon.com/IAM/latest/UserGuide/access_policies_testing-policies.html)

---

## Exercise 4 — Policy evaluation logic: explicit deny always wins

**Goal:** internalise the single most-tested rule in Domain 2 by making it fail in front of you.

### Block 4.1 — Layer an Allow and a Deny on the same action

1. Attach `AmazonS3FullAccess` — a very broad AWS managed policy — directly to `lab-analyst`:

```bash
aws iam attach-user-policy \
  --user-name lab-analyst \
  --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess
```

2. Confirm the analyst can now write:

```bash
aws --profile analyst s3 cp q3.csv "s3://${LAB_BUCKET}/reports/upload.csv"
```

Expected: `upload: ./q3.csv to s3://teachplat-clf-lab-111122223333/reports/upload.csv`

3. Now add a narrowly targeted explicit `Deny` as an **inline** policy on the same user. Save as `deny-delete.json`:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "NeverDeleteBucketsOrVersions",
      "Effect": "Deny",
      "Action": [
        "s3:DeleteBucket",
        "s3:DeleteObjectVersion",
        "s3:PutBucketPolicy"
      ],
      "Resource": "*"
    }
  ]
}
```

```bash
aws iam put-user-policy \
  --user-name lab-analyst \
  --policy-name GuardrailNoDestructiveS3 \
  --policy-document file://deny-delete.json
```

4. Prove the Deny beats the `*:*`-shaped Allow that is still attached:

```bash
aws --profile analyst s3api delete-bucket --bucket "$LAB_BUCKET"
```

Expected:

```
An error occurred (AccessDenied) when calling the DeleteBucket operation: User: arn:aws:iam::111122223333:user/lab-analyst is not authorized to perform: s3:DeleteBucket on resource: "arn:aws:s3:::teachplat-clf-lab-111122223333" with an explicit deny in an identity-based policy
```

Compare the tail of this message to step 9 of Exercise 3: **"with an explicit deny in an identity-based policy"** vs **"because no identity-based policy allows"**. AWS names the exact evaluation outcome for you.

5. Confirm the same conclusion through the simulator, which also tells you *which statement* matched:

```bash
aws iam simulate-principal-policy \
  --policy-source-arn "arn:aws:iam::${ACCOUNT_ID}:user/lab-analyst" \
  --action-names s3:DeleteBucket s3:PutObject \
  --resource-arns "arn:aws:s3:::${LAB_BUCKET}" \
  --query 'EvaluationResults[].{Action:EvalActionName,Decision:EvalDecision,Matched:MatchedStatements[0].SourcePolicyId}' \
  --output table
```

Expected:

```
------------------------------------------------------------------
|                    SimulatePrincipalPolicy                     |
+------------------+----------------+----------------------------+
|      Action      |    Decision    |          Matched           |
+------------------+----------------+----------------------------+
|  s3:DeleteBucket |  explicitDeny  |  GuardrailNoDestructiveS3  |
|  s3:PutObject    |  allowed       |  AmazonS3FullAccess        |
+------------------+----------------+----------------------------+
```

> **Q4.1** — Write the full evaluation order AWS applies to a single API request, from the first thing checked to the last, including SCPs, permissions boundaries, session policies, identity-based and resource-based policies.
>
> **Q4.2** — `AmazonS3FullAccess` allows `s3:*` on `*`. You need to permanently prevent bucket deletion for 400 principals across 12 accounts. Which single construct achieves that with one policy document, and at which layer does it evaluate?
>
> **Q4.3** — A request is made by a principal in account A against a bucket in account B. State the rule for how many `Allow` statements are needed and where they must live.
>
> **Q4.4** — Someone proposes "we'll just remove `AmazonS3FullAccess` instead of adding the Deny." Give one security argument *for* the Deny and one operational argument *against* relying on it alone.

*Sources:* [Policy evaluation logic](https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_evaluation-logic.html) · [Cross-account resource access in IAM](https://docs.aws.amazon.com/IAM/latest/UserGuide/access_policies-cross-account-resource-access.html)

---

## Exercise 5 — IAM roles and temporary credentials (AWS STS)

**Goal:** replace a long-lived key with a role, and *see* the expiry timestamp on the credentials you get back.

### Block 5.1 — A role your IAM user can assume

1. Write the **trust policy** — the `AssumeRolePolicyDocument`. This is the role's answer to "*who* may become me", and it is a resource-based policy attached to the role itself. Save as `trust.json`:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowLabAnalystToAssumeWithMFA",
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::111122223333:user/lab-analyst"
      },
      "Action": "sts:AssumeRole",
      "Condition": {
        "NumericLessThan": {
          "aws:MultiFactorAuthAge": "3600"
        }
      }
    }
  ]
}
```

For a lab without an MFA device on `lab-analyst`, drop the `Condition` block — but understand that in production it is the whole point.

2. Create the role and give it a *different* permission set from the user's:

```bash
aws iam create-role \
  --role-name LabAuditRole \
  --description "Read-only audit role, assumed by analysts" \
  --assume-role-policy-document file://trust.json \
  --max-session-duration 3600
```

Expected (abridged):

```json
{
    "Role": {
        "RoleName": "LabAuditRole",
        "RoleId": "AROAEXAMPLEROLEID001",
        "Arn": "arn:aws:iam::111122223333:role/LabAuditRole",
        "CreateDate": "2026-09-04T11:41:09+00:00",
        "MaxSessionDuration": 3600
    }
}
```

```bash
aws iam attach-role-policy \
  --role-name LabAuditRole \
  --policy-arn arn:aws:iam::aws:policy/SecurityAudit
```

3. Grant `lab-analyst` permission to *call* `sts:AssumeRole` on that role. **Both sides must agree** — the trust policy alone is not enough for an IAM user principal. Save as `allow-assume.json`:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowAssumingTheAuditRole",
      "Effect": "Allow",
      "Action": "sts:AssumeRole",
      "Resource": "arn:aws:iam::111122223333:role/LabAuditRole"
    }
  ]
}
```

```bash
aws iam put-user-policy \
  --user-name lab-analyst \
  --policy-name AllowAssumeLabAuditRole \
  --policy-document file://allow-assume.json
```

4. Assume it and inspect the credentials:

```bash
aws --profile analyst sts assume-role \
  --role-arn "arn:aws:iam::${ACCOUNT_ID}:role/LabAuditRole" \
  --role-session-name clf-lab-session
```

Expected:

```json
{
    "Credentials": {
        "AccessKeyId": "ASIAIOSFODNN7EXAMPLE",
        "SecretAccessKey": "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
        "SessionToken": "IQoJb3JpZ2luX2VjEJr//////////wEaCXVzLWVhc3QtMSJHMEUCIQ...TRUNCATED",
        "Expiration": "2026-09-04T12:44:31+00:00"
    },
    "AssumedRoleUser": {
        "AssumedRoleId": "AROAEXAMPLEROLEID001:clf-lab-session",
        "Arn": "arn:aws:sts::111122223333:assumed-role/LabAuditRole/clf-lab-session"
    }
}
```

Three things to notice: the access key ID starts with **`ASIA`** (temporary) rather than `AKIA` (long-lived); there is a **`SessionToken`**; and there is a hard **`Expiration`**.

5. Rather than exporting those by hand, let the CLI do it. Add the profile to `~/.aws/config`:

```ini
[profile lab-audit]
role_arn = arn:aws:iam::111122223333:role/LabAuditRole
source_profile = analyst
role_session_name = clf-lab-session
duration_seconds = 3600
```

```bash
aws --profile lab-audit sts get-caller-identity
```

Expected:

```json
{
    "UserId": "AROAEXAMPLEROLEID001:clf-lab-session",
    "Account": "111122223333",
    "Arn": "arn:aws:sts::111122223333:assumed-role/LabAuditRole/clf-lab-session"
}
```

6. Confirm the session carries the **role's** permissions, not the user's:

```bash
aws --profile lab-audit iam list-users --query 'Users[].UserName'     # SecurityAudit allows this
aws --profile analyst   iam list-users --query 'Users[].UserName'     # the user alone cannot
```

Expected: the first prints a JSON array of user names; the second fails with `AccessDenied … iam:ListUsers`.

> **Q5.1** — Name the three things a role has that an IAM user does not have, or has differently: identify the trust policy, credential lifetime, and credential type.
>
> **Q5.2** — In step 3 you had to write a policy on the *user* even though the role already trusted that user. Is this symmetric requirement always true? Contrast the same-account IAM-user case with an EC2 service-linked assumption.
>
> **Q5.3** — `MaxSessionDuration` is 3600 s. A colleague sets it to 43200 s "so nobody gets interrupted". Argue the security case against, in terms of blast radius.
>
> **Q5.4** — What does `sts:ExternalId` protect against, and in which specific scenario is it mandatory?

### Block 5.2 — Roles for services: EC2 instance profiles and IMDSv2 *(optional, incurs cost)*

7. Create a role that **EC2** — not a human — can assume. The trust policy names a *service principal*:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "ec2.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
```

```bash
aws iam create-role --role-name LabInstanceRole --assume-role-policy-document file://ec2-trust.json
aws iam attach-role-policy --role-name LabInstanceRole --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
aws iam create-instance-profile --instance-profile-name LabInstanceProfile
aws iam add-role-to-instance-profile --instance-profile-name LabInstanceProfile --role-name LabInstanceRole
```

8. Launch a `t3.micro` with **IMDSv2 required** and the profile attached:

```bash
aws ec2 run-instances \
  --image-id resolve:ssm:/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --instance-type t3.micro \
  --iam-instance-profile Name=LabInstanceProfile \
  --metadata-options "HttpTokens=required,HttpPutResponseHopLimit=1,HttpEndpoint=enabled" \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=clf-lab}]' \
  --query 'Instances[0].InstanceId' --output text
```

9. Connect with Session Manager (no SSH key, no open port 22 — itself an access-management win) and read the metadata service:

```bash
aws ssm start-session --target i-0abcd1234efgh5678
```

Inside the session:

```bash
TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/iam/security-credentials/
```

Expected: `LabInstanceRole`

```bash
curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/iam/security-credentials/LabInstanceRole
```

Expected:

```json
{
  "Code" : "Success",
  "LastUpdated" : "2026-09-04T11:52:14Z",
  "Type" : "AWS-HMAC",
  "AccessKeyId" : "ASIAIOSFODNN7EXAMPLE",
  "SecretAccessKey" : "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
  "Token" : "IQoJb3JpZ2luX2VjE...TRUNCATED",
  "Expiration" : "2026-09-04T18:11:47Z"
}
```

10. Prove IMDSv1 is blocked — this is the mitigation for the SSRF-to-credential-theft class of attack:

```bash
curl -s --max-time 3 http://169.254.169.254/latest/meta-data/iam/security-credentials/ ; echo "exit=$?"
```

Expected: an empty body and `exit=0` with HTTP 401 (or a timeout), because no token was presented.

11. **Terminate the instance immediately** when done:

```bash
aws ec2 terminate-instances --instance-ids i-0abcd1234efgh5678
```

> **Q5.5** — The credentials in step 9 expire in ~6 hours. Who rotates them, and what does the application have to do to keep working?
>
> **Q5.6** — Explain `HttpPutResponseHopLimit=1` in terms of containers on that host, and why `HttpTokens=required` is the setting that actually matters for SSRF.
>
> **Q5.7** — An *instance profile* and a *role* are different objects. Describe the relationship and the cardinality between them.

*Sources:* [IAM roles](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles.html) · [AssumeRole API](https://docs.aws.amazon.com/STS/latest/APIReference/API_AssumeRole.html) · [Using instance metadata service version 2](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/configuring-instance-metadata-service.html) · [External ID for third-party access](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_create_for-user_externalid.html)

---

## Exercise 6 — Resource-based policies and cross-account access

**Goal:** see the second kind of policy — the one attached to the *resource* — and understand why cross-account access needs both kinds.

### Block 6.1 — A bucket policy

1. Confirm S3 Block Public Access is on at the account level *before* you touch any bucket policy:

```bash
aws s3control get-public-access-block --account-id "$ACCOUNT_ID" \
  --query PublicAccessBlockConfiguration
```

Expected:

```json
{
    "BlockPublicAcls": true,
    "IgnorePublicAcls": true,
    "BlockPublicPolicy": true,
    "RestrictPublicBuckets": true
}
```

If any value is `false`, fix it now:

```bash
aws s3control put-public-access-block --account-id "$ACCOUNT_ID" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
```

2. Write a bucket policy granting a principal in a **different account** read access to one prefix. Note the `Principal` element — identity-based policies never have one; resource-based policies always do. Save as `bucket-policy.json`:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowPartnerAccountReadReports",
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::444455556666:role/PartnerReaderRole"
      },
      "Action": [
        "s3:GetObject",
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::teachplat-clf-lab-111122223333",
        "arn:aws:s3:::teachplat-clf-lab-111122223333/reports/*"
      ],
      "Condition": {
        "StringEquals": {
          "aws:PrincipalOrgID": "o-exampleorgid"
        }
      }
    },
    {
      "Sid": "DenyUnencryptedTransport",
      "Effect": "Deny",
      "Principal": "*",
      "Action": "s3:*",
      "Resource": [
        "arn:aws:s3:::teachplat-clf-lab-111122223333",
        "arn:aws:s3:::teachplat-clf-lab-111122223333/*"
      ],
      "Condition": {
        "Bool": { "aws:SecureTransport": "false" }
      }
    }
  ]
}
```

```bash
aws s3api put-bucket-policy --bucket "$LAB_BUCKET" --policy file://bucket-policy.json
aws s3api get-bucket-policy --bucket "$LAB_BUCKET" --query Policy --output text | python3 -m json.tool
```

3. Attempt a deliberately public policy and watch Block Public Access refuse it:

```bash
cat > public.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "PublicRead",
    "Effect": "Allow",
    "Principal": "*",
    "Action": "s3:GetObject",
    "Resource": "arn:aws:s3:::${LAB_BUCKET}/*"
  }]
}
EOF
aws s3api put-bucket-policy --bucket "$LAB_BUCKET" --policy file://public.json
```

Expected:

```
An error occurred (AccessDenied) when calling the PutBucketPolicy operation: Access Denied
```

This is `BlockPublicPolicy=true` doing its job — the policy is rejected at write time, not silently applied and then ignored.

> **Q6.1** — List three AWS services besides S3 that support resource-based policies, and one that conspicuously does not (so cross-account access must be role-based).
>
> **Q6.2** — `aws:PrincipalOrgID` was added as a condition. What class of mistake does it defend against that naming the account ID alone does not?
>
> **Q6.3** — For the partner in `444455556666` to actually read the object, what must exist *in their account*? Name the policy type and the principal it attaches to.
>
> **Q6.4** — Block Public Access exists at two scopes. Name both, and state which one an application team cannot override.

*Sources:* [Bucket policies](https://docs.aws.amazon.com/AmazonS3/latest/userguide/bucket-policies.html) · [Blocking public access to S3 storage](https://docs.aws.amazon.com/AmazonS3/latest/userguide/access-control-block-public-access.html) · [AWS global condition context keys](https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_condition-keys.html)

---

## Exercise 7 — Guardrails: SCPs and permissions boundaries

**Goal:** distinguish the two constructs that *limit* maximum permissions from the ones that *grant* them. This distinction is a reliable exam discriminator.

### Block 7.1 — Permissions boundary (any account)

1. A boundary is an ordinary policy document used in a special slot. Save as `boundary.json`:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "BoundaryMaxScope",
      "Effect": "Allow",
      "Action": [
        "s3:*",
        "cloudwatch:*",
        "logs:*"
      ],
      "Resource": "*"
    },
    {
      "Sid": "BoundaryDenyPrivilegeEscalation",
      "Effect": "Deny",
      "Action": [
        "iam:CreateUser",
        "iam:CreateRole",
        "iam:AttachUserPolicy",
        "iam:AttachRolePolicy",
        "iam:PutUserPolicy",
        "iam:PutRolePolicy",
        "iam:DeleteUserPermissionsBoundary",
        "iam:DeleteRolePermissionsBoundary"
      ],
      "Resource": "*"
    }
  ]
}
```

```bash
aws iam create-policy --policy-name LabDeveloperBoundary --policy-document file://boundary.json
aws iam create-user --user-name lab-developer \
  --permissions-boundary "arn:aws:iam::${ACCOUNT_ID}:policy/LabDeveloperBoundary"
aws iam attach-user-policy --user-name lab-developer \
  --policy-arn arn:aws:iam::aws:policy/AdministratorAccess
```

2. `lab-developer` now has `AdministratorAccess` attached *and* a boundary. Simulate:

```bash
aws iam simulate-principal-policy \
  --policy-source-arn "arn:aws:iam::${ACCOUNT_ID}:user/lab-developer" \
  --action-names s3:PutObject ec2:RunInstances iam:CreateUser \
  --query 'EvaluationResults[].{Action:EvalActionName,Decision:EvalDecision}' \
  --output table
```

Expected:

```
-------------------------------------
|     SimulatePrincipalPolicy       |
+-------------------+---------------+
|      Action       |   Decision    |
+-------------------+---------------+
|  s3:PutObject     |  allowed      |
|  ec2:RunInstances |  implicitDeny |
|  iam:CreateUser   |  explicitDeny |
+-------------------+---------------+
```

Read this carefully. `AdministratorAccess` allows all three. `s3:PutObject` survives because the boundary also allows it. `ec2:RunInstances` is denied *implicitly* — the boundary simply never mentions EC2. `iam:CreateUser` is denied *explicitly* by the boundary's second statement.

3. Verify the boundary is really attached:

```bash
aws iam get-user --user-name lab-developer --query 'User.PermissionsBoundary'
```

Expected:

```json
{
    "PermissionsBoundaryType": "Policy",
    "PermissionsBoundaryArn": "arn:aws:iam::111122223333:policy/LabDeveloperBoundary"
}
```

> **Q7.1** — A permissions boundary contains `"Effect": "Allow", "Action": "s3:*"`. Does that grant the user S3 access? Explain precisely what a boundary does to the effective permission set.
>
> **Q7.2** — The boundary denies `iam:DeleteUserPermissionsBoundary`. What attack does that specific line prevent?
>
> **Q7.3** — Permissions boundaries can be attached to which principal types? Name the one they cannot be attached to.

### Block 7.2 — Service control policies *(optional — requires an Organizations management account)*

4. Confirm you are in the management account and that SCPs are enabled:

```bash
aws organizations describe-organization \
  --query 'Organization.{Id:Id,Master:MasterAccountId,FeatureSet:FeatureSet}'
aws organizations list-roots --query 'Roots[].{Id:Id,Policies:PolicyTypes}'
```

Expected:

```json
{ "Id": "o-exampleorgid", "Master": "111122223333", "FeatureSet": "ALL" }
```
```json
[ { "Id": "r-exam", "Policies": [ { "Type": "SERVICE_CONTROL_POLICY", "Status": "ENABLED" } ] } ]
```

`FeatureSet` must be `ALL`; consolidated billing only does not support SCPs.

5. Create a region-restriction SCP — one of the most common real guardrails:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DenyOutsideApprovedRegions",
      "Effect": "Deny",
      "NotAction": [
        "iam:*",
        "organizations:*",
        "sts:*",
        "cloudfront:*",
        "route53:*",
        "support:*",
        "budgets:*",
        "waf:*"
      ],
      "Resource": "*",
      "Condition": {
        "StringNotEquals": {
          "aws:RequestedRegion": ["us-east-1", "eu-west-1"]
        }
      }
    }
  ]
}
```

```bash
aws organizations create-policy \
  --name DenyOutsideApprovedRegions \
  --description "Allow API calls only in us-east-1 and eu-west-1" \
  --type SERVICE_CONTROL_POLICY \
  --content file://scp-regions.json

aws organizations attach-policy --policy-id p-examplescpid --target-id ou-exam-sandboxou
```

6. From a **member** account in that OU, test:

```bash
aws ec2 describe-instances --region ap-south-1
```

Expected:

```
An error occurred (UnauthorizedOperation) when calling the DescribeInstances operation: You are not authorized to perform this operation. ... with an explicit deny in a service control policy
```

7. Inspect what is effectively in force on an account:

```bash
aws organizations list-policies-for-target --target-id 444455556666 --filter SERVICE_CONTROL_POLICY \
  --query 'Policies[].{Name:Name,Id:Id,AwsManaged:AwsManaged}' --output table
```

> **Q7.4** — An SCP contains `"Effect": "Allow", "Action": "*"` (the `FullAWSAccess` default). A user in the account has no IAM policy at all. What can they do, and why?
>
> **Q7.5** — SCPs do not apply to one principal in the organization. Which one, and what is the operational consequence for break-glass procedures?
>
> **Q7.6** — Contrast SCP and permissions boundary along three axes: where it attaches, who typically owns it, and what happens when neither exists.
>
> **Q7.7** — The SCP above uses `NotAction` rather than `Action`. Explain why global services had to be excluded, and what would break if `iam:*` were not in that list.

*Sources:* [Service control policies](https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_scps.html) · [Permissions boundaries for IAM entities](https://docs.aws.amazon.com/IAM/latest/UserGuide/access_policies_boundaries.html)

---

## Exercise 8 — Attribute-based access control (ABAC) with tags

**Goal:** scale authorization without writing a new policy per team, using tags on both the principal and the resource.

1. Tag the principal:

```bash
aws iam tag-user --user-name lab-analyst --tags Key=Project,Value=apollo
aws iam list-user-tags --user-name lab-analyst --query 'Tags' --output table
```

2. Write one ABAC policy that works for *every* project, present and future. Save as `abac.json`:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "StartStopOnlyMyProjectInstances",
      "Effect": "Allow",
      "Action": [
        "ec2:StartInstances",
        "ec2:StopInstances"
      ],
      "Resource": "arn:aws:ec2:*:*:instance/*",
      "Condition": {
        "StringEquals": {
          "aws:ResourceTag/Project": "${aws:PrincipalTag/Project}"
        }
      }
    },
    {
      "Sid": "AllowDescribeForConsoleUsability",
      "Effect": "Allow",
      "Action": "ec2:Describe*",
      "Resource": "*"
    },
    {
      "Sid": "RequireProjectTagOnCreation",
      "Effect": "Allow",
      "Action": "ec2:CreateTags",
      "Resource": "arn:aws:ec2:*:*:instance/*",
      "Condition": {
        "StringEquals": {
          "aws:RequestTag/Project": "${aws:PrincipalTag/Project}"
        }
      }
    }
  ]
}
```

```bash
aws iam create-policy --policy-name AbacProjectInstanceControl --policy-document file://abac.json
aws iam attach-user-policy --user-name lab-analyst \
  --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/AbacProjectInstanceControl"
```

3. Simulate against two differently tagged instances. The simulator lets you supply the resource's tag as a context entry:

```bash
aws iam simulate-principal-policy \
  --policy-source-arn "arn:aws:iam::${ACCOUNT_ID}:user/lab-analyst" \
  --action-names ec2:StopInstances \
  --resource-arns "arn:aws:ec2:us-east-1:${ACCOUNT_ID}:instance/i-0apollo000000001" \
  --context-entries 'ContextKeyName=aws:ResourceTag/Project,ContextKeyType=string,ContextKeyValues=apollo' \
  --query 'EvaluationResults[].EvalDecision' --output text
```

Expected: `allowed`

```bash
aws iam simulate-principal-policy \
  --policy-source-arn "arn:aws:iam::${ACCOUNT_ID}:user/lab-analyst" \
  --action-names ec2:StopInstances \
  --resource-arns "arn:aws:ec2:us-east-1:${ACCOUNT_ID}:instance/i-0gemini00000001" \
  --context-entries 'ContextKeyName=aws:ResourceTag/Project,ContextKeyType=string,ContextKeyValues=gemini' \
  --query 'EvaluationResults[].EvalDecision' --output text
```

Expected: `implicitDeny`

> **Q8.1** — In one sentence each, contrast RBAC and ABAC as AWS implements them, and state the specific scaling property that makes ABAC attractive at 200 teams.
>
> **Q8.2** — `${aws:PrincipalTag/Project}` is a policy *variable*. What happens to the evaluation if the principal has no `Project` tag at all?
>
> **Q8.3** — The third statement (`RequireProjectTagOnCreation`) exists for a security reason, not convenience. What escalation does it block?
>
> **Q8.4** — Where do the principal tags come from when the principal is a federated IAM Identity Center user rather than an IAM user?

*Sources:* [ABAC for AWS](https://docs.aws.amazon.com/IAM/latest/UserGuide/introduction_attribute-based-access-control.html) · [IAM policy elements: variables and tags](https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_variables.html)

---

## Exercise 9 — Federation, IAM Identity Center, and the end of long-lived keys

**Goal:** understand the identity model AWS actually recommends for humans, and where machine secrets belong.

### Block 9.1 — Human access via IAM Identity Center

1. Check whether Identity Center is enabled in the organization:

```bash
aws sso-admin list-instances --query 'Instances[].{Arn:InstanceArn,Store:IdentityStoreId,Status:Status}'
```

Expected when enabled:

```json
[
    {
        "Arn": "arn:aws:sso:::instance/ssoins-exampleinstanceid",
        "Store": "d-9067example",
        "Status": "ACTIVE"
    }
]
```

2. Inspect the permission sets — Identity Center's unit of "what you can do", which materialises as an IAM role in each assigned account:

```bash
INSTANCE_ARN=$(aws sso-admin list-instances --query 'Instances[0].InstanceArn' --output text)
for ps in $(aws sso-admin list-permission-sets --instance-arn "$INSTANCE_ARN" --query 'PermissionSets[]' --output text); do
  aws sso-admin describe-permission-set --instance-arn "$INSTANCE_ARN" --permission-set-arn "$ps" \
    --query 'PermissionSet.{Name:Name,Session:SessionDuration}' --output text
done
```

Expected:

```
AdministratorAccess	PT1H
ReadOnlyAccess	PT8H
BillingViewer	PT2H
```

3. Configure the CLI to use it. This is the modern replacement for `aws configure` with an access key:

```bash
aws configure sso
```

Interactive prompts and expected shape of the result in `~/.aws/config`:

```ini
[sso-session teachplat]
sso_start_url = https://d-9067example.awsapps.com/start
sso_region = us-east-1
sso_registration_scopes = sso:account:access

[profile prod-readonly]
sso_session = teachplat
sso_account_id = 444455556666
sso_role_name = ReadOnlyAccess
region = eu-west-1
output = json
```

4. Log in and confirm the resulting identity is a **role session**, not a user:

```bash
aws sso login --sso-session teachplat
aws --profile prod-readonly sts get-caller-identity
```

Expected:

```json
{
    "UserId": "AROAEXAMPLEROLEID9:alice@example.com",
    "Account": "444455556666",
    "Arn": "arn:aws:sts::444455556666:assumed-role/AWSReservedSSO_ReadOnlyAccess_a1b2c3d4e5f6/alice@example.com"
}
```

5. Confirm no secret was written to disk in a long-lived form:

```bash
grep -c aws_secret_access_key ~/.aws/credentials 2>/dev/null || echo "no credentials file"
ls -l ~/.aws/sso/cache/
```

The `sso/cache` directory holds a short-lived OIDC token, not an AWS secret key.

> **Q9.1** — An Identity Center user signs in with corporate credentials and reaches three accounts. How many IAM users were created? Explain what actually exists in each account.
>
> **Q9.2** — Identity Center supports three identity source options. Name them, and state which one you would choose for a company already running Microsoft Entra ID.
>
> **Q9.3** — Name the three properties of Identity Center access that an IAM user with an access key cannot match.

### Block 9.2 — Application and customer identity, and machine secrets

6. Amazon **Cognito** is the answer for *your application's end users* — not IAM. Sketch the distinction with a user pool:

```bash
aws cognito-idp list-user-pools --max-results 10 --query 'UserPools[].{Name:Name,Id:Id}' --output table
```

7. Machine secrets that genuinely cannot be replaced by a role (a third-party API key, a database password) belong in **Secrets Manager** or **Parameter Store**, never in code or environment variables:

```bash
aws secretsmanager create-secret \
  --name clf-lab/partner-api-key \
  --description "Third-party key, rotated every 30 days" \
  --secret-string '{"api_key":"EXAMPLEKEYVALUE"}'
```

Expected:

```json
{
    "ARN": "arn:aws:secretsmanager:us-east-1:111122223333:secret:clf-lab/partner-api-key-AbCdEf",
    "Name": "clf-lab/partner-api-key",
    "VersionId": "EXAMPLE1-90ab-cdef-fedc-ba987EXAMPLE"
}
```

```bash
aws secretsmanager get-secret-value --secret-id clf-lab/partner-api-key --query SecretString --output text
```

Delete it right away so it stops accruing:

```bash
aws secretsmanager delete-secret --secret-id clf-lab/partner-api-key --force-delete-without-recovery
```

> **Q9.4** — Place each in the right box — IAM users, IAM Identity Center, Amazon Cognito: (a) 40 000 mobile-app customers, (b) 300 employees needing console access across 25 accounts, (c) a legacy on-prem batch job that cannot use a role.
>
> **Q9.5** — Both Secrets Manager and Systems Manager Parameter Store (SecureString) store secrets encrypted with KMS. Give the one capability Secrets Manager has that Parameter Store does not, and the one reason you might still choose Parameter Store.
>
> **Q9.6** — A secret in Secrets Manager is protected by *two* policy layers. Name them and explain what each controls.

*Sources:* [What is IAM Identity Center](https://docs.aws.amazon.com/singlesignon/latest/userguide/what-is.html) · [Identity providers and federation](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_providers.html) · [What is Amazon Cognito](https://docs.aws.amazon.com/cognito/latest/developerguide/what-is-amazon-cognito.html) · [AWS Secrets Manager](https://docs.aws.amazon.com/secretsmanager/latest/userguide/intro.html)

---

## Exercise 10 — Right-sizing permissions with evidence

**Goal:** close the loop. Least privilege is not achieved at design time; it is *measured* and tightened afterwards.

1. Ask IAM what a principal has actually used, via Access Advisor (service last accessed data). This is a two-call, asynchronous API:

```bash
JOB_ID=$(aws iam generate-service-last-accessed-details \
  --arn "arn:aws:iam::${ACCOUNT_ID}:user/lab-analyst" \
  --query JobId --output text)
echo "$JOB_ID"
sleep 5
aws iam get-service-last-accessed-details --job-id "$JOB_ID" \
  --query 'ServicesLastAccessed[?TotalAuthenticatedEntities>`0`].{Service:ServiceName,Last:LastAuthenticated,Calls:TotalAuthenticatedEntities}' \
  --output table
```

Expected:

```
--------------------------------------------------------------------
|                 GetServiceLastAccessedDetails                    |
+---------------------+----------------------------+---------------+
|       Service       |            Last            |     Calls     |
+---------------------+----------------------------+---------------+
|  Amazon S3          |  2026-09-04T11:26:00+00:00 |  1            |
+---------------------+----------------------------+---------------+
```

`AmazonS3FullAccess` grants `s3:*`; the evidence shows only `s3:GetObject` was ever exercised. That gap *is* the remediation ticket.

2. Enable IAM Access Analyzer to find resources reachable from outside your trust zone:

```bash
aws accessanalyzer create-analyzer \
  --analyzer-name clf-lab-external \
  --type ACCOUNT

aws accessanalyzer list-findings \
  --analyzer-arn "arn:aws:access-analyzer:us-east-1:${ACCOUNT_ID}:analyzer/clf-lab-external" \
  --query 'findings[].{Resource:resource,Type:resourceType,Principal:principal,Status:status}' \
  --output table
```

Expected — your Exercise 6 bucket policy shows up:

```
------------------------------------------------------------------------------------------------
|                                         ListFindings                                         |
+------------------------------------------------+---------------+---------------------+------+
|                    Resource                    |     Type      |      Principal      |Status|
+------------------------------------------------+---------------+---------------------+------+
| arn:aws:s3:::teachplat-clf-lab-111122223333    | AWS::S3::Bucket| {"AWS":"444455556666"}|ACTIVE|
+------------------------------------------------+---------------+---------------------+------+
```

3. Validate a policy *before* deploying it — Access Analyzer includes over 100 checks:

```bash
aws accessanalyzer validate-policy \
  --policy-document file://analyst-policy.json \
  --policy-type IDENTITY_POLICY \
  --query 'findings[].{Type:findingType,Issue:issueCode,Detail:findingDetails}' \
  --output table
```

Expected on a clean policy: `{ "findings": [] }`. Introduce a typo (`"s3:GetObjectt"`) and re-run to see:

```
ERROR  INVALID_ACTION  The action s3:GetObjectt does not exist.
```

4. Cross-check the whole account against a published baseline:

```bash
aws securityhub get-enabled-standards \
  --query 'StandardsSubscriptions[].StandardsArn' --output text
```

The CIS AWS Foundations Benchmark controls in Security Hub encode exactly what you did by hand in Exercise 2: root MFA, no root access keys, key rotation, password policy, MFA for console users.

> **Q10.1** — Access Advisor showed only S3 was used in 90 days. Give the exact remediation, and one reason you would *not* blindly automate it.
>
> **Q10.2** — IAM Access Analyzer has an **external access** analyzer and an **unused access** analyzer. Match each to a scenario, and state which one is free.
>
> **Q10.3** — The finding in step 2 is `ACTIVE`, not a security failure. Describe what you do with a finding that represents intentional access.
>
> **Q10.4** — Where does the **shared responsibility model** draw the line for access management? State AWS's side and the customer's side, using IAM specifically.

*Sources:* [Refining permissions using last accessed information](https://docs.aws.amazon.com/IAM/latest/UserGuide/access_policies_access-advisor.html) · [What is IAM Access Analyzer](https://docs.aws.amazon.com/IAM/latest/UserGuide/what-is-access-analyzer.html) · [Shared responsibility model](https://aws.amazon.com/compliance/shared-responsibility-model/)

---

## Cleanup

Run this in full. IAM objects are free but they are also permanent attack surface.

```bash
# Detach and delete users
for U in lab-analyst lab-developer; do
  for P in $(aws iam list-attached-user-policies --user-name $U --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null); do
    aws iam detach-user-policy --user-name $U --policy-arn $P
  done
  for P in $(aws iam list-user-policies --user-name $U --query 'PolicyNames[]' --output text 2>/dev/null); do
    aws iam delete-user-policy --user-name $U --policy-name $P
  done
  for G in $(aws iam list-groups-for-user --user-name $U --query 'Groups[].GroupName' --output text 2>/dev/null); do
    aws iam remove-user-from-group --user-name $U --group-name $G
  done
  for K in $(aws iam list-access-keys --user-name $U --query 'AccessKeyMetadata[].AccessKeyId' --output text 2>/dev/null); do
    aws iam delete-access-key --user-name $U --access-key-id $K
  done
  aws iam delete-user --user-name $U 2>/dev/null
done

# Group
aws iam detach-group-policy --group-name DataAnalysts \
  --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/LabReportsReadOnly" 2>/dev/null
aws iam delete-group --group-name DataAnalysts 2>/dev/null

# Roles and instance profile
aws iam detach-role-policy --role-name LabAuditRole --policy-arn arn:aws:iam::aws:policy/SecurityAudit 2>/dev/null
aws iam delete-role --role-name LabAuditRole 2>/dev/null
aws iam remove-role-from-instance-profile --instance-profile-name LabInstanceProfile --role-name LabInstanceRole 2>/dev/null
aws iam delete-instance-profile --instance-profile-name LabInstanceProfile 2>/dev/null
aws iam detach-role-policy --role-name LabInstanceRole --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore 2>/dev/null
aws iam delete-role --role-name LabInstanceRole 2>/dev/null

# Customer managed policies
for N in LabReportsReadOnly LabDeveloperBoundary AbacProjectInstanceControl; do
  aws iam delete-policy --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${N}" 2>/dev/null
done

# Buckets and stack
aws s3 rm "s3://${LAB_BUCKET}" --recursive 2>/dev/null
aws s3api delete-bucket --bucket "$LAB_BUCKET" 2>/dev/null
aws cloudformation delete-stack --stack-name clf-lab-bucket 2>/dev/null

# Access Analyzer (free, but tidy)
aws accessanalyzer delete-analyzer --analyzer-name clf-lab-external 2>/dev/null

echo "Cleanup pass complete. Verify:"
aws iam list-users --query 'Users[].UserName'
aws ec2 describe-instances --filters Name=tag:Name,Values=clf-lab Name=instance-state-name,Values=running \
  --query 'Reservations[].Instances[].InstanceId'
```

The last two commands must return an empty list (or only your own admin identity). Do not skip them — a forgotten `t3.micro` is the most common lab bill.

---

<details>
<summary><strong>Answers</strong> — attempt every question before opening</summary>

### Exercise 1 — Access methods and the credential chain

**A1.1** — **One.** The Console, CLI, SDKs and CloudFormation are all clients of the same public service API. Every one of them ultimately issues a SigV4-signed HTTPS request that IAM evaluates with identical policy evaluation logic. There is no "console-only" permission and no way to allow an action from the CLI but deny it from the Console (you can *approximate* it with condition keys such as `aws:ViaAWSService` or `aws:CalledVia`, but that is a condition on the request, not a separate authorization mechanism). The practical consequence: hardening an identity-based policy hardens all four paths at once, and conversely, restricting the Console UI protects nothing.

**A1.2** — By default CloudFormation acts **on behalf of the calling principal**, using *your* permissions for every resource it creates; CloudTrail therefore records your username. That is why a stack you deploy can never create something you could not have created by hand. The feature that changes this is a **CloudFormation service role** (`--role-arn`): the stack then assumes that role and operates with the role's permissions, which lets a low-privilege operator deploy a stack that needs high-privilege actions, without granting those actions to the operator directly. StackSets extend the same idea across accounts.

**A1.3** — The **AWS Management Console** — not because a role cannot be used in the Console, but because a role has no password and cannot *sign in*. A role must be **assumed** by an already-authenticated principal (an IAM user, a federated identity, or an AWS service). In practice you switch roles in the Console *after* signing in, or you land in one directly through federation, where the identity provider authenticates you and STS mints the role session. The distinction that matters for the exam: **roles have no long-term credentials of any kind** — no password, no access key.

**A1.4** — Highest to lowest:
1. Command-line options (`--profile`, `--region`)
2. Environment variables (`AWS_ACCESS_KEY_ID`, `AWS_SESSION_TOKEN`, …)
3. Assume-role / web-identity configuration in the shared config file
4. IAM Identity Center (SSO) token
5. Shared credentials file (`~/.aws/credentials`)
6. Shared config file (`~/.aws/config`)
7. ECS container credentials (`AWS_CONTAINER_CREDENTIALS_RELATIVE_URI`)
8. EC2 instance profile via IMDS

The instance profile is **last** deliberately: it is the fallback of last resort, so any explicitly configured credential wins over the ambient machine identity. This is also the single most common cause of "it works on my laptop but the EC2 instance uses the wrong identity" — a stale environment variable is shadowing the instance role.

**A1.5** — The profile resolves `source_profile = default`, uses those credentials to call `sts:AssumeRole` against `LabAuditRole`, and receives **temporary credentials** (an `ASIA…` access key, a secret, and a session token) valid for `duration_seconds` — 3600 s here, capped by the role's `MaxSessionDuration`. The CLI caches them under `~/.aws/cli/cache/` and refreshes automatically when they expire. No secret for the role itself is ever stored.

**A1.6** — A **Lambda execution role**. Two properties make it strictly safer: (1) the credentials are **temporary and automatically rotated** by the Lambda service — there is nothing durable to leak, and a stolen credential expires on its own; (2) there is **no secret material at rest** — nothing in the deployment package, environment, repository, or CI system to accidentally commit or log. A third, often decisive in audits: the role's permissions are visible and auditable in IAM, whereas a pasted key's true scope is invisible from the function.

### Exercise 2 — Root user

**A2.1** — Because the credential report schema is defined for **IAM users**, and the root user is not an IAM user — it is the account itself, identified by `arn:aws:iam::111122223333:root`. Fields that describe IAM-user-specific state (`password_enabled`, `password_last_changed`, `password_next_rotation`) have no meaning for root: root always has a password, that password is not governed by the IAM account password policy, and it cannot be disabled. IAM returns `not_supported` rather than a misleading `true`/`false`. Note the deeper point this reveals: the account password policy you set in Exercise 3 does **not** apply to root.

**A2.2** — A root access key is unconstrainable. An IAM user's key is bounded by that user's policies, any permissions boundary, and any SCP, and you can revoke it or narrow it in seconds. A root key is subject to **none** of those — SCPs do not apply to the management account's root user, IAM policies cannot be attached to root, and there is no boundary slot. A leaked root key is total, immediate, irrecoverable account compromise, including the ability to close the account. Remediation: sign in as root, go to **Account → Security credentials → Access keys**, and **delete** it. There is no legitimate reason for one to exist — every root-only task in A2.5's list is performed through the Console, not the API.

**A2.3** — **AWS Security Hub** (via the CIS AWS Foundations Benchmark and AWS Foundational Security Best Practices standards), backed by **AWS Config** managed rules such as `root-account-mfa-enabled` and `iam-root-access-key-check`, which read exactly this data. That turns a manual quarterly check into a continuous control with a finding you can route to a ticket. **AWS Trusted Advisor** also reports root MFA in its security checks.

**A2.4** — `AdministratorAccess` grants the *IAM principal* `arn:aws:iam::111122223333:user/you` a very wide set of actions, but S3 MFA Delete is not gated on an IAM action at all — the S3 service checks whether the request was signed by the **bucket owner's root credentials** carrying a root MFA code, before any IAM policy evaluation is relevant. The request's principal is simply the wrong *kind* of principal; no policy can supply what is missing, because the check is not policy-based. This is the cleanest available proof that root is not "the admin user with more permissions" but a structurally different principal.

**A2.5** — **"Restore IAM user permissions"** — the root user is the only principal that can reattach an administrative policy when the last administrator has removed their own. This is why root's password must **never** be deleted or lost: root is the account's only break-glass path out of a self-inflicted lockout, and AWS's account-recovery process for a lost root credential is slow, identity-verification-heavy, and depends on the root email and phone number still being reachable. Store the root password and a backup MFA device in a physical safe or an offline password vault with two-person control, and verify the root email is a monitored distribution list.

**A2.6** — A FIDO2/WebAuthn security key performs **origin-bound cryptographic authentication**: the key checks the domain requesting the assertion and refuses to respond to anything other than the real AWS sign-in origin, and the response cannot be replayed. It therefore defeats **phishing and adversary-in-the-middle (AitM) proxy attacks** — the attack class that TOTP does not stop, because a six-digit code typed into a convincing fake page can be relayed to the real site inside its validity window. TOTP still protects against a stolen-password-only attack; it just does not protect against the attacker being on the wire.

### Exercise 3 — Users, groups, identity-based policies

**A3.1** — **No.** An IAM group cannot be a `Principal` in a resource-based policy. A group is purely an **identity-management convenience** for attaching policies to a set of IAM users; it is not an identity that can authenticate or be granted access from the resource side. It has an ARN and an ID, but AWS explicitly rejects it in the `Principal` element. The correct construct when a resource needs to grant access to "a set of people" is a **role** that those people can assume — the role's ARN *is* a valid principal. Related facts worth knowing: groups cannot be nested, a user can belong to multiple groups, and a group cannot be a member of another group.

**A3.2** — Because the two actions operate on **different resource types**, and their ARNs differ in shape. `s3:ListBucket` is a *bucket-level* operation — its resource is `arn:aws:s3:::bucket`, with no trailing `/*`. `s3:GetObject` is an *object-level* operation — its resource is `arn:aws:s3:::bucket/key`. A single statement listing both actions against `bucket/*` would silently grant nothing for `ListBucket`, because that ARN never matches a bucket resource. This is the single most common S3 policy bug, and it manifests as "I can download a file if I already know its name, but `aws s3 ls` returns `AccessDenied`." Separating the statements also lets the `s3:prefix` condition apply only where it makes sense.

**A3.3** — The condition lives in the **`Condition`** element of the statement, keyed on the AWS global condition key `aws:SecureTransport`. A `Deny` is correct rather than a narrowed `Allow` for two reasons. First, **completeness**: a `Deny` on `s3:*` covers every S3 action, including ones granted by *other* policies attached now or in the future, whereas narrowing this policy's `Allow` protects only the actions this document happens to mention. Second, **precedence**: an explicit `Deny` cannot be overridden by any later `Allow`, so it survives someone attaching `AmazonS3FullAccess` next quarter. This is the general design rule — express *invariants* as conditional denies, express *grants* as narrow allows.

**A3.4** —
- **AWS managed policy**: created and maintained by AWS (`arn:aws:iam::aws:policy/…`), reusable, versioned by AWS, and automatically updated when a new service action appears. You cannot edit it.
- **Customer managed policy**: created by you in your account (`arn:aws:iam::111122223333:policy/…`), attachable to many principals, and versioned — up to five versions with rollback.
- **Inline policy**: embedded directly in a single user, group, or role, with a strict one-to-one lifecycle — delete the principal and the policy vanishes with it.

Prefer managed for the operational reason that it is **reusable, independently versioned, centrally auditable, and rollback-capable**: you can answer "who has this permission?" with one `list-entities-for-policy` call, and you can revert a bad change. Inline policies fragment that answer across every principal and cannot be rolled back. Inline remains legitimately useful for a strict one-to-one guardrail where you *want* the policy to be impossible to accidentally reuse elsewhere.

**A3.5** — An **implicit deny** is the default outcome: no statement allowed the action, and none denied it either. It is *permissive-by-addition* — attach any policy with a matching `Allow` and the action becomes allowed. An **explicit deny** comes from a statement with `"Effect": "Deny"` that matched. It is **final**: no `Allow` anywhere — identity-based, resource-based, session policy, or otherwise — can override it. Only removing or narrowing the denying statement changes the outcome.

**A3.6** — The detailed "because no identity-based policy allows…" message is produced when the service can safely describe the failure. For `s3:GetObject` on an object the caller cannot even confirm exists, S3 deliberately returns a **bare `Access Denied`** to avoid leaking information: a distinguishable "no such key" versus "denied" response would let an unauthorized caller enumerate the bucket's contents by probing key names. This is intentional information-hiding, and it is why S3 also returns `403` rather than `404` for objects you lack `ListBucket` on. Practically: when debugging S3 denials, do not expect a helpful message — use CloudTrail, which records the full authorization context, or the policy simulator.

**A3.7** —
(a) **A human analyst**: AWS IAM Identity Center with a permission set, authenticated against the corporate IdP, yielding short-lived role-session credentials via `aws sso login`. No key exists to leak or rotate. If Identity Center is unavailable, the fallback is an IAM user with **MFA-enforced role assumption** — never a bare key.
(b) **An application on EC2**: an **IAM role attached via an instance profile**, with IMDSv2 required. The SDK fetches and auto-refreshes temporary credentials with no configuration.

The general principle from the IAM best practices document: *require workloads and human users to use temporary credentials with an identity provider*; long-lived access keys are the exception requiring justification, not the default.

**A3.8** — Two readings: (1) the key was created but has **never been used** — genuinely dormant, and a strong candidate for deletion; or (2) the key **has** been used, but only more than **400 days ago**, which is the horizon of the tracking data — or the usage occurred before the region/service began reporting. Distinguish them by comparing the key's `CreateDate` against the tracking window and by querying **CloudTrail** (or CloudTrail Lake / an Athena table over an S3 trail) for `userIdentity.accessKeyId` matching the key. If CloudTrail retention is shorter than the key's age, you cannot prove disuse from logs alone — in that case the safe procedure is to **deactivate** the key (`update-access-key --status Inactive`), wait a full business cycle, and delete only if nothing breaks. Deactivation is instantly reversible; deletion is not.

### Exercise 4 — Policy evaluation logic

**A4.1** — For a single request, AWS evaluates in this order, and any **explicit `Deny`** encountered at any point terminates evaluation immediately with a denial:
1. **Explicit deny** — checked across all applicable policy types; wins unconditionally.
2. **Service control policies (SCPs)** — for accounts in an organization, the action must be allowed by the SCPs on every node from the root down to the account. An SCP grants nothing; it only bounds.
3. **Resource control policies (RCPs)** — organization-level bounds on what resource-based policies may grant.
4. **Session policies** — if the credentials came from `AssumeRole` with a `--policy` argument, the action must be within that policy.
5. **Permissions boundaries** — if the principal has one, the action must be allowed by it.
6. **Identity-based and resource-based policies** — at least one must explicitly `Allow`.
7. If nothing allowed it → **implicit deny** (the default).

The compressed exam form: *explicit deny > explicit allow > implicit deny (default)*, with SCPs, boundaries and session policies acting as **filters that can only subtract**.

**A4.2** — A **service control policy** with an explicit `Deny` on `s3:DeleteBucket`, attached to the organizational unit containing those 12 accounts. It evaluates at the **organization layer**, above and independent of every IAM policy in every member account — so no account administrator, however privileged, can grant the action back. One document, one attachment, 400 principals covered, and new principals covered automatically the moment they are created. (A permissions boundary would require attaching to each of the 400 principals individually and would not survive an administrator detaching it.)

**A4.3** — Cross-account access requires **two** `Allow`s: one in an **identity-based policy** on the principal in account A (permitting the action on the resource in B), and one in the **resource-based policy** on the resource in account B (naming the principal from A). Neither alone suffices — there is no implicit trust between accounts. This contrasts with the **same-account** case, where an `Allow` in *either* the identity-based policy *or* the resource-based policy is sufficient. The exception worth knowing: for **IAM roles**, the role's trust policy plays the resource-policy part, and cross-account `sts:AssumeRole` follows the same both-sides rule.

**A4.4** — **For the Deny**: it is *defence in depth*. Permissions drift — someone attaches a broad managed policy in an emergency, an automation grants `s3:*`, a new team copies an old policy. An explicit `Deny` on the destructive actions holds regardless of what anyone attaches later, and it cannot be overridden. It expresses the invariant "we never delete buckets" independently of who has what.

**Against relying on it alone**: an explicit `Deny` is a *symptom-suppressor*, not a fix. `AmazonS3FullAccess` is still attached, so the principal retains every other over-broad permission the Deny does not enumerate — and the Deny only lists the actions someone thought of. It also makes the effective permission set hard to reason about: reading the attached policies no longer tells you what the principal can do. The correct posture is **both** — narrow the grant *and* keep the guardrail — with the Deny at the organizational layer (SCP) where it cannot be detached, not inline on one user where it can.

### Exercise 6 — Resource-based policies

**A6.1** — Services supporting resource-based policies include **Amazon S3** (bucket policies), **AWS KMS** (key policies — notably *mandatory*, a KMS key always has one), **Amazon SQS** (queue policies), **Amazon SNS** (topic policies), **AWS Lambda** (function resource policies), **Amazon EventBridge** (event bus policies), **Secrets Manager**, **API Gateway**, **ECR**, **EFS**, and **IAM roles** themselves (the trust policy). Conspicuously **without** one: **Amazon EC2** — there is no "instance policy", so cross-account EC2 access must be granted by a role in the owning account that the external principal assumes. **Amazon RDS** (the control plane) and **DynamoDB** are also commonly cited examples that rely on IAM identity policies and roles rather than resource policies.

**A6.2** — `aws:PrincipalOrgID` binds the grant to *membership in your organization* rather than to a specific account ID. It defends against the **stale-account and account-transfer problem**: an account ID hard-coded in a bucket policy keeps working after that account leaves your organization, is sold, or is decommissioned and its ID reused in a different trust context. It also removes an entire class of maintenance error — you no longer need to edit dozens of bucket policies each time an account joins or leaves. Related keys with the same flavour: `aws:PrincipalOrgPaths` (scope to a specific OU) and `aws:SourceOrgID`.

**A6.3** — An **identity-based policy** attached to `PartnerReaderRole` in account `444455556666`, allowing `s3:GetObject` and `s3:ListBucket` on the same ARNs. This is the both-sides rule from A4.3: the bucket policy is the resource-owner's half of the agreement, and the partner's IAM policy is the caller's half. The partner's administrator controls their half — you cannot grant permissions inside their account from your bucket policy, only permit them.

**A6.4** — The two scopes are (1) **the bucket** — `PublicAccessBlockConfiguration` on an individual bucket, and (2) **the account** — via the S3 Control API (`s3control put-public-access-block`), which applies to every bucket in the account, present and future. The **account-level** setting is the one an application team cannot override: it takes precedence, so even a bucket owner who sets the bucket-level flags to `false` still cannot make the bucket public. In an organization, an SCP denying `s3:PutAccountPublicAccessBlock` and `s3:PutBucketPublicAccessBlock` locks that in permanently. Note also that these four settings have been **on by default for all new buckets since April 2023**.

### Exercise 7 — Guardrails

**A7.1** — **No, it grants nothing.** A permissions boundary is a **ceiling, not a grant**. The principal's effective permissions are the **intersection** of (a) what its identity-based policies allow and (b) what the boundary allows — and an explicit `Deny` in either one still wins outright. With only a boundary and no attached policy, the principal can do nothing at all. The mental model that survives the exam: identity policies say *what you may do*; the boundary says *the most you could ever be allowed to do*.

**A7.2** — It prevents the **boundary-removal privilege escalation**. Without that line, a principal holding `AdministratorAccess` *within* the boundary could call `iam:DeleteUserPermissionsBoundary` on itself, dissolving the ceiling and instantly becoming a genuine account administrator. The same reasoning covers `iam:PutUserPolicy`, `iam:AttachUserPolicy`, `iam:CreateUser` and `iam:CreateRole` in that Deny list: each is a route to minting or granting privileges the boundary was meant to withhold. The general design rule for delegated administration: **a boundary must deny the IAM actions that could modify the boundary or create an unbounded principal.** The safe alternative when developers legitimately need to create roles is to require, via condition, that any role they create carries the same boundary (`iam:PermissionsBoundary` condition key).

**A7.3** — Permissions boundaries attach to **IAM users** and **IAM roles**. They **cannot** be attached to **IAM groups** — nor to an account or organizational unit, which is the SCP's job. (Consistent with A3.1: a group is not an identity, so it has no permission ceiling of its own; the boundary lives on the users in it.)

**A7.4** — They can do **nothing**. This is the definitional property of an SCP: it **never grants permissions**, it only defines the maximum set of permissions that IAM policies in the account are *allowed to* grant. `FullAWSAccess` merely declines to restrict anything; the actual grant must still come from an IAM identity-based policy (or a resource-based policy) inside the account. The corollary that trips people up: attaching a *permissive* SCP to fix an access problem never works — the missing piece is always an IAM policy.

**A7.5** — SCPs do not apply to the **management account's root user** — and more broadly, no SCP restricts the management account at all, regardless of which principal in it makes the call. The operational consequence is twofold. First, the management account is your **break-glass path**: if an SCP misfires and locks every workload account out of something critical, you detach it from the management account, which no SCP can prevent. Second, and more important, the management account must therefore be treated as the **highest-value target in the organization** — it should host no workloads, have almost no principals, have root MFA'd with hardware keys and no access keys, and be monitored aggressively. Everything else in the organization is defended by SCPs; the management account is defended only by its own hygiene. (Note also that SCPs do not affect service-linked roles.)

**A7.6** —

| Axis | Service control policy | Permissions boundary |
|---|---|---|
| **Attaches to** | Organization root, OU, or member account | An individual IAM user or role |
| **Typically owned by** | The central security / cloud-platform team, in the management account — out of reach of account admins | The account or delegated administrator who creates the principal |
| **When absent** | Nothing is restricted at the org layer; IAM policies alone decide | No ceiling; the principal's identity-based policies alone decide |

Both are **filters, not grants**, and both can only subtract from what IAM policies allow. The practical division of labour: SCPs express **organization-wide invariants** ("no one, anywhere, may disable CloudTrail" / "only these regions"); boundaries express **delegation limits** ("this team may create roles, but nothing more powerful than this").

**A7.7** — `NotAction` means "every action *except* these", so the `Deny` applies to all services *other than* the listed ones. The listed services are **global**: IAM, Organizations, STS, CloudFront, Route 53, Support, Budgets and WAF have endpoints that resolve to `us-east-1` (or are region-agnostic), and their API calls carry `aws:RequestedRegion` values that a naive region-restriction would reject. Excluding them prevents the guardrail from breaking essential control-plane operations.

If `iam:*` were **not** excluded, every IAM call made from outside `us-east-1`/`eu-west-1` would be denied — including `iam:CreateServiceLinkedRole`, which many services invoke implicitly. Console operations in restricted regions would fail in confusing ways, service-linked role creation would break on first use of numerous services, and, in the worst case, an administrator working from a restricted region could lock themselves out of IAM management entirely. The general lesson: **region-restriction SCPs must always carve out global services**, and should be tested in a sandbox OU before being attached anywhere near production.

### Exercise 8 — ABAC

**A8.1** — **RBAC** grants permissions by naming resources (or resource ARN patterns) explicitly in policies attached to roles/groups: one policy per team, listing that team's resources. **ABAC** grants permissions by **comparing attributes** — tags on the principal against tags on the resource — so one policy expresses the rule for everyone.

The scaling property: with RBAC, adding the 201st team means writing and attaching a 201st policy, and adding a resource means editing a policy. With ABAC, **the policy count stays at one** — you onboard a team by tagging its principals and its resources, which is an ordinary provisioning action rather than a security change. This also keeps you clear of the IAM quotas on managed policies per principal and policy document size, which RBAC hits first in large organizations.

**A8.2** — The policy variable `${aws:PrincipalTag/Project}` has **no value to resolve**, so the condition cannot match and the statement does not apply — the result is an **implicit deny**. It does *not* fail open, and it does not match "any project". This is the correct and safe failure mode, but it makes ABAC's usability depend entirely on **tag hygiene**: an untagged principal silently loses access, and the error message will not say why. Production ABAC therefore pairs the policy with enforcement — an SCP requiring `Project` on principal creation, or tags mapped automatically from IdP attributes so they cannot be omitted.

**A8.3** — It blocks **tag-based privilege escalation via re-tagging**. Without a constraint on `ec2:CreateTags`, a principal tagged `Project=apollo` could simply retag a `gemini` instance to `Project=apollo` and then legitimately stop it — the ABAC rule would happily grant access to a resource the principal just made "theirs". The `aws:RequestTag/Project` condition forces any tag the principal writes to match their own project tag, so they cannot mint access to someone else's resources. The same reasoning requires guarding **`ec2:DeleteTags`** (removing a tag can also change the outcome) — a real production version of this policy would include a `Deny` on `ec2:DeleteTags` for the `Project` key via `aws:TagKeys`. **In any ABAC design, the tagging APIs are part of the security perimeter.**

**A8.4** — From the **session tags** on the role session. When a user federates through IAM Identity Center or a SAML/OIDC IdP, attributes from the directory (department, cost centre, project) are mapped into the assume-role call — via `sts:TagSession` and the SAML attribute `https://aws.amazon.com/SAML/Attributes/PrincipalTag:Project`, or in Identity Center via **attributes for access control**, configured in the Identity Center console and sourced from the identity store or the external IdP. Those become `aws:PrincipalTag/*` for the duration of the session. This is what makes ABAC genuinely powerful: the authorization attribute is maintained in the corporate directory by HR/IT processes, so a person moving teams changes their AWS access automatically at next sign-in, with no IAM change at all.

### Exercise 9 — Federation, Identity Center, secrets

**A9.1** — **Zero IAM users.** What exists in each of the three accounts is an IAM **role**, provisioned and managed by IAM Identity Center, with a name of the form `AWSReservedSSO_<PermissionSetName>_<hash>`. The user authenticates once against the identity source; Identity Center then federates them into the selected account by having them assume the corresponding role, and STS issues a short-lived session. The user's identity lives in exactly one place — the identity store or the external IdP — and deprovisioning there removes access to all accounts at once. Compare this to the IAM-user model, where offboarding means hunting for user objects in every account.

**A9.2** — The three identity sources are: (1) the built-in **Identity Center directory**, (2) **Active Directory** — either AWS Managed Microsoft AD or an on-premises domain reached through AD Connector, and (3) an **external identity provider** via SAML 2.0/OIDC, with SCIM for automatic user and group provisioning.

For a company already on **Microsoft Entra ID**, choose the **external identity provider** option: connect Entra ID as the SAML IdP and enable **SCIM provisioning** so users and groups synchronise automatically. This keeps a single authoritative directory, inherits the organization's existing MFA and conditional-access policies, and makes offboarding in HR propagate to AWS without a separate step.

**A9.3** — (1) **Credentials are temporary and automatically expiring** — the session ends at `SessionDuration`, so there is no durable secret to steal, rotate, or find in a Git history. (2) **Centralised lifecycle across every account** — one assignment grants or revokes access to many accounts at once, and disabling the user in the IdP is instant and total; IAM users must be created, audited and deleted account by account. (3) **The corporate IdP's authentication controls apply** — enterprise MFA, conditional access, device posture, session revocation, and the existing joiner/mover/leaver process, none of which an IAM access key participates in. (A fourth, often decisive in audits: sign-in is attributable to a **named human** in the directory, and permission sets are managed as reusable, versioned objects rather than per-account policy copies.)

**A9.4** —
- **(a) 40 000 mobile-app customers → Amazon Cognito.** These are *your application's* end users, not people who need AWS API access. A Cognito **user pool** provides the sign-up/sign-in directory, hosted UI, social and enterprise federation, and MFA; a Cognito **identity pool** can additionally exchange a verified token for scoped temporary AWS credentials when the app must reach AWS services directly. IAM users are categorically wrong here — there is a hard quota on IAM users per account (5,000), and IAM is not a customer-identity system.
- **(b) 300 employees, 25 accounts → AWS IAM Identity Center.** Exactly the problem it exists to solve: one identity, permission sets assigned to groups, temporary credentials, central deprovisioning.
- **(c) Legacy on-prem batch job → an IAM user with an access key**, as the documented exception — but first check whether **IAM Roles Anywhere** applies: it lets on-premises workloads use X.509 certificates from your PKI to obtain temporary credentials, eliminating the long-lived key. If a static key is genuinely unavoidable, scope it to a minimal policy, add condition keys restricting `aws:SourceIp` to the data centre's egress range, monitor `get-access-key-last-used`, and rotate on a schedule.

**A9.5** — Secrets Manager's distinguishing capability is **built-in automatic rotation**: it invokes a Lambda rotation function on a schedule and, for supported targets (RDS, Aurora, Redshift, DocumentDB), ships ready-made rotation logic that changes the credential on both the secret and the database, with staged versions (`AWSCURRENT`/`AWSPENDING`) so in-flight clients are not broken. Parameter Store has no rotation engine. Secrets Manager also supports **cross-region replication** of secrets and **resource-based policies** on the secret.

You might still choose **Parameter Store** because standard-tier parameters are **free** (Secrets Manager charges roughly USD 0.40 per secret per month plus API charges), it integrates naturally with configuration data that is not secret, and it is the right home for the large volume of non-rotating settings that sit alongside a handful of true secrets. A common production pattern: Parameter Store for configuration and static SecureStrings, Secrets Manager for anything that must rotate.

**A9.6** — (1) The **IAM identity-based policy** on the calling principal, which must allow `secretsmanager:GetSecretValue` on the secret's ARN — this controls *who may ask*. (2) The **resource-based policy on the secret itself**, which controls *who the secret will answer*, and is what enables cross-account access. There is effectively a third layer: the **KMS key policy** for the customer managed key encrypting the secret — the principal also needs `kms:Decrypt`, so a KMS key policy can independently deny access even when both Secrets Manager policies allow it. That KMS layer is a frequent and easily-missed cause of "AccessDenied" on an otherwise correct cross-account secret share.

### Exercise 10 — Right-sizing

**A10.1** — The remediation is to **replace `AmazonS3FullAccess` with a scoped policy** granting only the actions and resources actually exercised — here, `s3:GetObject` (and `s3:ListBucket`) on the specific bucket and prefix — and to remove the other unused service permissions entirely. IAM Access Analyzer's **policy generation** feature can draft that policy directly from CloudTrail history, which is faster and less error-prone than hand-writing it.

You would not automate this blindly because **absence of use is not absence of need**. A quarter-end reconciliation job, an annual compliance export, a disaster-recovery runbook, or a rarely-triggered incident-response path may legitimately not appear in a 90-day window. Access Advisor's tracking horizon is also finite. The safe procedure is the same as for access keys: shrink the policy, but **stage the change** — announce it, apply it in a non-production account first, keep the old policy version for one-click rollback (customer managed policies keep five versions), and monitor CloudTrail for new `AccessDenied` events attributable to the change over at least one full business cycle.

**A10.2** — The **external access** analyzer answers *"is anything in my account reachable by a principal outside my trust zone?"* — it uses automated reasoning over resource-based policies (S3 buckets, KMS keys, IAM roles, Lambda functions, SQS queues, Secrets Manager secrets, and more) to find shares with other accounts, organizations, or the public internet. Scenario: a quarterly review confirming no bucket or role has quietly become externally accessible.

The **unused access** analyzer answers *"which permissions, roles, users and access keys have not been used?"* — it drives least-privilege remediation. Scenario: the Exercise 10 cleanup, at scale, across an organization.

**The external access analyzer is free.** The unused access analyzer is charged per IAM role and IAM user analysed per month. (Policy validation via `validate-policy` and policy generation are also free.)

**A10.3** — You **archive** it, ideally by creating an **archive rule** rather than dismissing it one finding at a time. An archive rule matches on criteria — resource ARN, principal account, resource type, condition key — and automatically archives current and future findings that fit, so the intentional share stops appearing in the active queue while remaining visible in the archived list for audit. The operational value is signal-to-noise: once every *known* external share is archived with a documented rule, any **new** `ACTIVE` finding is by construction something nobody has approved, which makes it worth alerting on. Findings should be archived with a recorded justification (ticket, owner, review date), and the archive rules themselves reviewed periodically — an archive rule is a standing exception, and standing exceptions rot.

**A10.4** — Under the shared responsibility model, access management sits on the customer side of the line, with AWS responsible for the mechanism:

- **AWS** — "security **of** the cloud": AWS operates the IAM service itself, guaranteeing its availability, correctness and durability; it authenticates and authorises every API request against the policies you configure; it protects the underlying infrastructure, the global IAM data plane, the signature verification, and the physical security of the facilities.
- **The customer** — "security **in** the cloud": *everything about the configuration*. Which principals exist; what policies grant; enforcing least privilege; enabling and enforcing MFA; protecting and not using the root user; rotating or eliminating credentials; choosing federation over long-lived keys; setting SCPs and boundaries; reviewing Access Analyzer findings and Access Advisor data; and monitoring CloudTrail for misuse.

The sharp version: **AWS guarantees your policies are enforced exactly as written. AWS does not guarantee they are written correctly.** An over-permissive policy is entirely a customer failure, and it is the single most common root cause in real AWS security incidents. Note also that this split shifts by service model — for a managed service like Lambda or S3 the customer's share is smaller (no OS to patch) but the IAM configuration responsibility is **identical across every service**, which is precisely why access management is the highest-leverage control a customer owns.

</details>

---

## Consolidated source list

- AWS Certified Cloud Practitioner (CLF-C02) Exam Guide — https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf
- Security best practices in IAM — https://docs.aws.amazon.com/IAM/latest/UserGuide/best-practices.html
- Policy evaluation logic — https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_evaluation-logic.html
- Tasks that require root user credentials — https://docs.aws.amazon.com/accounts/latest/reference/root-user-tasks.html
- Centralized root access management — https://docs.aws.amazon.com/IAM/latest/UserGuide/id_root-user-access-management.html
- Getting credential reports for your AWS account — https://docs.aws.amazon.com/IAM/latest/UserGuide/id_credentials_getting-report.html
- Using MFA in AWS — https://docs.aws.amazon.com/IAM/latest/UserGuide/id_credentials_mfa.html
- IAM roles — https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles.html
- AWS STS `AssumeRole` API reference — https://docs.aws.amazon.com/STS/latest/APIReference/API_AssumeRole.html
- Identity providers and federation — https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_providers.html
- Permissions boundaries for IAM entities — https://docs.aws.amazon.com/IAM/latest/UserGuide/access_policies_boundaries.html
- Service control policies (SCPs) — https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_scps.html
- Attribute-based access control (ABAC) for AWS — https://docs.aws.amazon.com/IAM/latest/UserGuide/introduction_attribute-based-access-control.html
- IAM policy elements: variables and tags — https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_variables.html
- AWS global condition context keys — https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_condition-keys.html
- Identity-based policies and resource-based policies — https://docs.aws.amazon.com/IAM/latest/UserGuide/access_policies_identity-vs-resource.html
- Cross-account resource access in IAM — https://docs.aws.amazon.com/IAM/latest/UserGuide/access_policies-cross-account-resource-access.html
- Using bucket policies — https://docs.aws.amazon.com/AmazonS3/latest/userguide/bucket-policies.html
- Blocking public access to your Amazon S3 storage — https://docs.aws.amazon.com/AmazonS3/latest/userguide/access-control-block-public-access.html
- Configuring the instance metadata service (IMDSv2) — https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/configuring-instance-metadata-service.html
- What is IAM Access Analyzer — https://docs.aws.amazon.com/IAM/latest/UserGuide/what-is-access-analyzer.html
- Refining permissions using last accessed information — https://docs.aws.amazon.com/IAM/latest/UserGuide/access_policies_access-advisor.html
- What is AWS IAM Identity Center — https://docs.aws.amazon.com/singlesignon/latest/userguide/what-is.html
- What is Amazon Cognito — https://docs.aws.amazon.com/cognito/latest/developerguide/what-is-amazon-cognito.html
- AWS Secrets Manager User Guide — https://docs.aws.amazon.com/secretsmanager/latest/userguide/intro.html
- Configuration and credential file settings (AWS CLI) — https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-files.html
- Standardized credential providers (AWS SDKs) — https://docs.aws.amazon.com/sdkref/latest/guide/standardized-credentials.html
- Shared Responsibility Model — https://aws.amazon.com/compliance/shared-responsibility-model/