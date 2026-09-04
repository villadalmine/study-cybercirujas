# Topic 2.1 — Guided Exercises: The AWS Shared Responsibility Model

> **Exam context:** CLF-C02, Domain 2 (Security and Compliance), Task Statement 2.1. Domain 2 carries **30%** of the scored exam; this task statement is weighted **7.5**. It is one of the few CLF-C02 objectives that is almost never asked as a definition — it is asked as a *judgement call*: "given this scenario, who is responsible?"
>
> **What you will actually do:** instead of memorising the AWS "hamburger" diagram, you will *derive the boundary from the API surface* of a real account, pull AWS's own audit evidence, and build a responsibility matrix that survives contact with production.

---

## Before you start

### Prerequisites

| Requirement | Check | Notes |
|---|---|---|
| AWS account you may experiment in | — | Use a **sandbox / non-production** account. Several steps read account-wide security posture. |
| AWS CLI **v2** (≥ 2.15) | `aws --version` | The `aws artifact` commands in Exercise 2 do not exist in CLI v1 or in early v2 builds. |
| An IAM principal with read access + limited S3 write | — | `ReadOnlyAccess` plus `AmazonS3FullAccess` is enough for everything below. Do **not** use the root user. |
| `jq` (optional but used in outputs) | `jq --version` | Every command has a `--query` fallback. |

### Cost and blast radius

Every mandatory step in this document is either **read-only** or creates an **empty S3 bucket** (S3 charges for storage and requests; an empty bucket held for minutes costs effectively $0.00). Exercise 5 has one **optional** block that launches a `t3.micro` EC2 instance — it is clearly marked, and the teardown is mandatory if you run it.

Nothing here enables AWS Config, GuardDuty, Security Hub, Inspector, or Macie. You will *query* them to prove they are off — that is the lesson.

### Set your working variables

```bash
export AWS_PROFILE=clf-sandbox          # adjust to your profile
export AWS_REGION=us-east-1             # some steps are region-scoped; keep this consistent
export AWS_PAGER=""                     # stop the CLI from opening a pager on every call
```

---

## Exercise 0 — Establish where you are standing

The shared responsibility model is not abstract: it is a statement about *one specific account*, in *one specific region*, under *one specific agreement*. Start by pinning all three down.

### Steps

1. Confirm the identity the CLI is using.

   ```bash
   aws sts get-caller-identity
   ```

   Expected output (abridged):

   ```json
   {
       "UserId": "AIDAEXAMPLE5EXAMPLE7",
       "Account": "123456789012",
       "Arn": "arn:aws:iam::123456789012:user/clf-lab"
   }
   ```

2. Store the account ID — several later commands need it.

   ```bash
   export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
   echo "$ACCOUNT_ID"
   ```

3. Confirm you are **not** operating as root.

   ```bash
   aws sts get-caller-identity --query Arn --output text | grep -q ':root$' \
     && echo "ROOT — stop and switch to an IAM principal" \
     || echo "OK: IAM principal"
   ```

4. List the regions your account can reach, and count them.

   ```bash
   aws ec2 describe-regions --query 'length(Regions)'
   aws ec2 describe-regions \
     --query 'Regions[?OptInStatus!=`opt-in-not-required`].[RegionName,OptInStatus]' \
     --output table
   ```

   Expected output (abridged):

   ```
   17
   ------------------------------------------
   |             DescribeRegions            |
   +----------------+-----------------------+
   |  ap-east-1     |  not-opted-in         |
   |  me-south-1    |  not-opted-in         |
   |  af-south-1    |  not-opted-in         |
   +----------------+-----------------------+
   ```

### Comprehension check — Block 0

- **Q0.1** — AWS operates the physical data centres in every one of those regions. Why does the *set of regions your workloads run in* still land on the customer side of the responsibility line?
- **Q0.2** — Opt-in regions are disabled by default in new accounts. Is "which regions are enabled" a security control, and if so, whose?
- **Q0.3** — Step 3 checks that you are not root. AWS creates the root user for you and enforces that it cannot be deleted. Who is responsible for the fact that root has (or does not have) MFA?

---

## Exercise 1 — Derive the boundary from the API surface

**The heuristic:** *if an AWS API lets you change it, it is on your side of the line; if no API exposes it at all, AWS owns it end to end.* The control plane is a fairly faithful projection of the responsibility boundary. You are going to test that heuristic — including where it leaks.

### Steps

1. Ask for something on the customer side of an EC2 instance. This works:

   ```bash
   aws ec2 describe-security-groups \
     --query 'SecurityGroups[].[GroupId,GroupName,Description]' \
     --output table
   ```

   Expected output (abridged):

   ```
   ------------------------------------------------------------------
   |                     DescribeSecurityGroups                     |
   +--------------+----------+----------------------------------+
   |  sg-0a1b2c3d |  default |  default VPC security group      |
   +--------------+----------+----------------------------------+
   ```

2. Now ask for something on the AWS side. There is no such API — try to find one:

   ```bash
   aws ec2 help | grep -iE 'hypervisor|firmware|host-patch|datacenter' || echo "no such operation"
   ```

   Expected output:

   ```
   no such operation
   ```

   > `describe-hosts` exists, but it describes **Dedicated Hosts** — a billing and tenancy construct — not the hypervisor. There is no operation, in any AWS service, that returns the patch level of the Nitro hypervisor, the firmware version of the host NIC, or the physical rack of your instance.

3. Find the one place AWS deliberately leaks a *little* of its side: instance metadata about the underlying platform.

   ```bash
   aws ec2 describe-instance-types --instance-types t3.micro m7i.large \
     --query 'InstanceTypes[].[InstanceType,Hypervisor,BareMetal,NitroEnclavesSupport]' \
     --output table
   ```

   Expected output:

   ```
   -----------------------------------------------------------
   |                 DescribeInstanceTypes                   |
   +---------------+----------+-----------+------------------+
   |  t3.micro     |  nitro   |  False    |  unsupported     |
   |  m7i.large    |  nitro   |  False    |  supported       |
   +---------------+----------+-----------+------------------+
   ```

   You can *observe* `Hypervisor: nitro`. You cannot patch it, configure it, or audit it. Observability is not responsibility.

4. Test the heuristic against a service where it holds cleanly — S3 durability versus S3 access:

   ```bash
   # Access control: many APIs. Yours.
   aws s3api help | grep -cE '^\s+o (put|get|delete)-bucket-(policy|acl|encryption|versioning|logging)'

   # Durability / replication factor across AZs: zero APIs. AWS's.
   aws s3api help | grep -icE 'replication-factor|disk-array|erasure' || echo "no such operation"
   ```

### Comprehension check — Block 1

- **Q1.1** — State the "API surface" heuristic in one sentence, then give one concrete example from this exercise where it holds.
- **Q1.2** — `describe-instance-types` reports `Hypervisor: nitro`. Explain why this does **not** make hypervisor patching a shared responsibility.
- **Q1.3** — Name one case where the heuristic **leaks**: an AWS API exists, but AWS — not you — performs the underlying work. (Hint: think about a managed database engine upgrade.)
- **Q1.4** — S3 stores your objects redundantly across at least three Availability Zones in a Region, and publishes a 99.999999999% durability design target. You cannot configure that. Which of the three control categories (inherited / shared / customer-specific) does it belong to?

---

## Exercise 2 — "Security **of** the cloud": pull AWS's evidence, don't take its word

AWS's half of the model is not a promise, it is an *audited* claim. The customer-side obligation that follows from this is frequently mis-stated on the exam: you are **not** responsible for auditing AWS's data centres — you *are* responsible for **obtaining and reviewing** the audit reports for your own compliance programme. AWS Artifact is the self-service portal for exactly that.

### Steps

1. Confirm your CLI has the Artifact API.

   ```bash
   aws artifact list-reports --max-results 5 --query 'reports[].[name,series,state]' --output table
   ```

   Expected output (abridged — the catalogue changes constantly):

   ```
   ------------------------------------------------------------------------------
   |                                 ListReports                                |
   +----------------------------------------------+---------------+-------------+
   |  AWS SOC 2 Type II Report                    |  SOC 2        |  PUBLISHED  |
   |  AWS SOC 1 Type II Report                    |  SOC 1        |  PUBLISHED  |
   |  AWS ISO 27001:2022 Certification            |  ISO          |  PUBLISHED  |
   |  PCI DSS Attestation of Compliance (AOC)     |  PCI          |  PUBLISHED  |
   |  AWS FedRAMP ... Package                     |  FedRAMP      |  PUBLISHED  |
   +----------------------------------------------+---------------+-------------+
   ```

   > If you get `Invalid choice: 'artifact'`, upgrade to a current AWS CLI v2. If you get `AccessDeniedException`, your principal lacks `artifact:ListReports` — add it, or use the console at **AWS Artifact → Reports**.

2. Pick one report and read its metadata without downloading it.

   ```bash
   REPORT_ID=$(aws artifact list-reports \
     --query "reports[?contains(name, 'SOC 2')] | [0].id" --output text)
   echo "$REPORT_ID"

   aws artifact get-report-metadata --report-id "$REPORT_ID" \
     --query 'reportDetails.{name:name,version:version,period:join(`" to "`,[periodStart,periodEnd]),acceptance:acceptanceType}'
   ```

   Expected output (abridged):

   ```json
   {
       "name": "AWS SOC 2 Type II Report",
       "version": 1,
       "period": "2025-10-01T00:00:00Z to 2026-03-31T00:00:00Z",
       "acceptance": "EXPLICIT"
   }
   ```

3. Notice `acceptanceType: EXPLICIT`. That means the report is under NDA and you must accept terms **before** you can retrieve it. Retrieve the terms:

   ```bash
   aws artifact get-term-for-report --report-id "$REPORT_ID" --report-version 1 \
     --query '{term:documentPresignedUrl, token:termToken}'
   ```

   Expected output (abridged):

   ```json
   {
       "term": "https://artifact-terms-prod-us-east-1.s3.amazonaws.com/...&X-Amz-Signature=...",
       "token": "eyJ0eXAiOiJKV1QiLCJhbGciOi..."
   }
   ```

4. **Read the terms document** (open the presigned URL), then exchange the token for the report itself:

   ```bash
   TERM_TOKEN=$(aws artifact get-term-for-report --report-id "$REPORT_ID" \
     --report-version 1 --query termToken --output text)

   aws artifact get-report --report-id "$REPORT_ID" --report-version 1 \
     --term-token "$TERM_TOKEN" --query documentPresignedUrl --output text
   ```

   The returned URL is a short-lived presigned link to the PDF.

5. Now look at the *other* half of Artifact — the agreements **you** sign:

   ```bash
   aws artifact list-customer-agreements \
     --query 'customerAgreements[].[name,state,agreementType]' --output table
   ```

   Expected output (abridged):

   ```
   ---------------------------------------------------------------
   |                  ListCustomerAgreements                     |
   +----------------------------------+----------+---------------+
   |  AWS Customer Agreement          |  ACTIVE  |  DEFAULT      |
   +----------------------------------+----------+---------------+
   ```

   Artifact **Agreements** (e.g. the HIPAA Business Associate Addendum) are things the *customer* accepts. Artifact **Reports** are things AWS provides *to* the customer. Both live in one console; they sit on opposite sides of the responsibility line.

### Comprehension check — Block 2

- **Q2.1** — A regulator asks your organisation to demonstrate that the physical security of the facility hosting your data was independently assessed. Which side of the model performs the assessment, and which side is responsible for producing the evidence to the regulator?
- **Q2.2** — Your CISO asks: "Can we send our own auditors to walk the AWS data centre in `us-east-1`?" Answer, and justify it in terms of the model.
- **Q2.3** — Explain the difference between an Artifact **Report** and an Artifact **Agreement**, using the SOC 2 report and the HIPAA BAA as examples.
- **Q2.4** — A team runs a PCI-DSS-scoped payment workload on EC2. AWS's PCI AOC is available in Artifact. Does that make the workload PCI compliant? Explain using the term **inherited controls**.
- **Q2.5** — Step 3 returned `acceptanceType: EXPLICIT` and a `termToken`. What responsibility does that mechanism enforce on the customer?

---

## Exercise 3 — "Security **in** the cloud": measure your own account's posture

AWS will not fix any of the following for you. It supplies the switch; leaving it off is a customer decision with customer consequences.

### Steps

1. Check whether the **root user** has MFA. This is the single most-tested customer responsibility in the whole domain.

   ```bash
   aws iam get-account-summary --query 'SummaryMap.{RootMFA:AccountMFAEnabled,Users:Users,MFADevices:MFADevices,AccessKeysPerUserQuota:AccessKeysPerUserQuota}'
   ```

   Expected output:

   ```json
   {
       "RootMFA": 1,
       "Users": 3,
       "MFADevices": 2,
       "AccessKeysPerUserQuota": 2
   }
   ```

   `RootMFA: 0` means root has no MFA. Fix that before continuing with anything else in your own accounts.

2. Check the account password policy:

   ```bash
   aws iam get-account-password-policy
   ```

   Expected output in a fresh account:

   ```
   An error occurred (NoSuchEntity) when calling the GetAccountPasswordPolicy operation:
   Cannot find Password Policy for this AWS account.
   ```

   AWS ships **no** password policy by default. The absence is itself the finding.

3. Generate and read the IAM credential report — the authoritative list of who can authenticate and how stale their keys are.

   ```bash
   aws iam generate-credential-report
   sleep 5
   aws iam get-credential-report --query Content --output text | base64 -d > /tmp/creds.csv
   # macOS: base64 -D
   cut -d, -f1,4,8,9,14 /tmp/creds.csv | column -t -s,
   ```

   Expected output (abridged):

   ```
   user            password_enabled  access_key_1_active  access_key_1_last_rotated  mfa_active
   <root_account>  not_supported     false                N/A                        true
   clf-lab         true              true                 2025-02-11T09:14:00+00:00  true
   ci-deployer     false             true                 2024-06-02T17:40:00+00:00  false
   ```

   `ci-deployer` has an access key **over a year old** and no MFA. AWS did not rotate it, will not rotate it, and has no obligation to.

4. Look for security groups open to the world:

   ```bash
   aws ec2 describe-security-groups \
     --filters Name=ip-permission.cidr,Values=0.0.0.0/0 \
     --query 'SecurityGroups[].{Id:GroupId,Name:GroupName,Vpc:VpcId}' \
     --output table
   ```

   In a fresh account this is usually empty — the default VPC security group only allows inbound traffic from itself. Anything that *does* appear was created by a human or a pipeline in your account.

5. Check the region-level EBS encryption default:

   ```bash
   aws ec2 get-ebs-encryption-by-default
   ```

   Expected output:

   ```json
   {
       "EbsEncryptionByDefault": false
   }
   ```

   AWS provides the encryption; it is **off by default and set per region**. Turning it on is one API call — and you must repeat it in every region you use:

   ```bash
   # Optional, and safe: affects only volumes created after this point.
   aws ec2 enable-ebs-encryption-by-default
   ```

6. Check the **account-level** S3 Block Public Access setting:

   ```bash
   aws s3control get-public-access-block --account-id "$ACCOUNT_ID"
   ```

   Expected output in most accounts:

   ```
   An error occurred (NoSuchPublicAccessBlockConfiguration) when calling the
   GetPublicAccessBlock operation: The public access block configuration was not found
   ```

   Bucket-level BPA is on by default for new buckets (Exercise 4); the **account-level** guardrail is not configured unless you configure it.

### Comprehension check — Block 3

- **Q3.1** — Step 2 shows AWS applies no default password policy. Argue *why* that is consistent with the shared responsibility model rather than a gap in it.
- **Q3.2** — `ci-deployer` has a 15-month-old access key. Under the model, who is accountable if that key is leaked in a public Git repository and used to exfiltrate data? Does the answer change if the leak happened through a bug in an AWS service?
- **Q3.3** — Why is `EbsEncryptionByDefault` a **per-region** setting, and what operational risk does that create for a customer who believes "we turned on encryption"?
- **Q3.4** — Classify each of the following as AWS, customer, or shared: (a) the AES-256 implementation used by EBS encryption; (b) the decision to encrypt a given volume; (c) the durability of the KMS key material; (d) the KMS key policy.

---

## Exercise 4 — Inherited, shared, and customer-specific controls, seen in S3 defaults

AWS has moved several controls from "customer must remember" to "secure by default" — but **defaults are not responsibilities**. A default you can turn off is still yours. This exercise makes that concrete.

### Steps

1. Create a scratch bucket.

   ```bash
   export BUCKET="clf-srm-${ACCOUNT_ID}-$RANDOM"

   if [ "$AWS_REGION" = "us-east-1" ]; then
     aws s3api create-bucket --bucket "$BUCKET"
   else
     aws s3api create-bucket --bucket "$BUCKET" \
       --create-bucket-configuration LocationConstraint="$AWS_REGION"
   fi
   echo "$BUCKET"
   ```

2. Inspect the three defaults AWS now applies without being asked.

   ```bash
   aws s3api get-public-access-block --bucket "$BUCKET"
   aws s3api get-bucket-ownership-controls --bucket "$BUCKET"
   aws s3api get-bucket-encryption --bucket "$BUCKET"
   ```

   Expected output:

   ```json
   {
       "PublicAccessBlockConfiguration": {
           "BlockPublicAcls": true,
           "IgnorePublicAcls": true,
           "BlockPublicPolicy": true,
           "RestrictPublicBuckets": true
       }
   }
   ```
   ```json
   {
       "OwnershipControls": {
           "Rules": [
               { "ObjectOwnership": "BucketOwnerEnforced" }
           ]
       }
   }
   ```
   ```json
   {
       "ServerSideEncryptionConfiguration": {
           "Rules": [
               {
                   "ApplyServerSideEncryptionByDefault": { "SSEAlgorithm": "AES256" },
                   "BucketKeyEnabled": false
               }
           ]
       }
   }
   ```

   Since April 2023 all new buckets have Block Public Access enabled and ACLs disabled; since January 2023 all new objects are encrypted with SSE-S3 at no cost. **These are safer defaults on the customer's side of the line, not a transfer of responsibility.**

3. Prove the guardrail is real. Try to attach a world-readable bucket policy:

   ```bash
   cat > /tmp/public-policy.json <<EOF
   {
     "Version": "2012-10-17",
     "Statement": [{
       "Sid": "PublicRead",
       "Effect": "Allow",
       "Principal": "*",
       "Action": "s3:GetObject",
       "Resource": "arn:aws:s3:::${BUCKET}/*"
     }]
   }
   EOF

   aws s3api put-bucket-policy --bucket "$BUCKET" --policy file:///tmp/public-policy.json
   ```

   Expected output:

   ```
   An error occurred (AccessDenied) when calling the PutBucketPolicy operation:
   User: arn:aws:iam::123456789012:user/clf-lab is not authorized to perform:
   s3:PutBucketPolicy on resource: "arn:aws:s3:::clf-srm-123456789012-24815"
   because public policies are blocked by the BlockPublicPolicy block public access setting.
   ```

4. Now prove that the guardrail is *yours to remove*. **Do not skip step 6.**

   ```bash
   aws s3api put-public-access-block --bucket "$BUCKET" \
     --public-access-block-configuration \
     "BlockPublicAcls=false,IgnorePublicAcls=false,BlockPublicPolicy=false,RestrictPublicBuckets=false"

   aws s3api put-bucket-policy --bucket "$BUCKET" --policy file:///tmp/public-policy.json
   echo "exit=$?"
   ```

   Expected output:

   ```
   exit=0
   ```

   Two API calls, no warning, no approval, no AWS intervention. The bucket is now public. AWS did exactly what you asked, and the outcome is entirely on your side of the model.

5. Observe how S3 reports it:

   ```bash
   aws s3api get-bucket-policy-status --bucket "$BUCKET"
   ```

   Expected output:

   ```json
   {
       "PolicyStatus": {
           "IsPublic": true
       }
   }
   ```

6. **Revert immediately.**

   ```bash
   aws s3api delete-bucket-policy --bucket "$BUCKET"
   aws s3api put-public-access-block --bucket "$BUCKET" \
     --public-access-block-configuration \
     "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
   aws s3api get-public-access-block --bucket "$BUCKET" \
     --query 'PublicAccessBlockConfiguration.BlockPublicPolicy'
   ```

   Expected output:

   ```
   true
   ```

### Comprehension check — Block 4

- **Q4.1** — The bucket in step 4 became publicly readable. Under the shared responsibility model, whose responsibility is (a) that S3 *served* the objects to anonymous callers, and (b) that the objects were exposed at all?
- **Q4.2** — Objects were encrypted with SSE-S3 the whole time. Explain precisely why that encryption did **not** prevent the exposure, and what class of threat SSE-S3 does address.
- **Q4.3** — Define **inherited control**, **shared control**, and **customer-specific control**, and place each of these in the right box: physical media destruction; patch management; IAM user provisioning; data-centre power redundancy; awareness and training; zone security.
- **Q4.4** — `BucketOwnerEnforced` disables ACLs. Why does AWS changing this default *reduce customer risk* without *reducing customer responsibility*?

---

## Exercise 5 — Patch management: the canonical **shared** control

Patching is the exam's favourite shared control, because the answer changes with the service. AWS patches the infrastructure; the customer patches the guest. Where the "guest" ends depends on the abstraction level.

### Steps

1. Prove that AWS *publishes* patched artefacts. Look at the current Amazon Linux 2023 AMI pointer in SSM Parameter Store:

   ```bash
   aws ssm get-parameters-by-path \
     --path /aws/service/ami-amazon-linux-latest \
     --query "Parameters[?contains(Name,'al2023-ami-kernel-default-x86_64')].[Name,Value,LastModifiedDate]" \
     --output table
   ```

   Expected output (abridged):

   ```
   -----------------------------------------------------------------------------------------
   |  /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 | ami-0abc... |
   |  2026-08-19T18:22:41.113000+00:00                                                     |
   -----------------------------------------------------------------------------------------
   ```

2. Prove AWS supplies the patch *catalogue* too — still without applying anything:

   ```bash
   aws ssm describe-available-patches \
     --filters Key=PRODUCT,Values=AmazonLinux2023 Key=SEVERITY,Values=Critical \
     --max-results 5 \
     --query 'Patches[].[Title,Severity,ReleaseDate]' --output table
   ```

   Expected output (abridged):

   ```
   -----------------------------------------------------------------------
   |  ALAS2023-2026-1042 (openssl)          |  Critical |  2026-07-28...  |
   |  ALAS2023-2026-1019 (kernel)           |  Critical |  2026-07-11...  |
   -----------------------------------------------------------------------
   ```

3. Look at the default patch baseline — AWS authors it, you may override it:

   ```bash
   aws ssm get-default-patch-baseline --operating-system AMAZON_LINUX_2023
   ```

   Expected output:

   ```json
   {
       "BaselineId": "pb-0c10e65780EXAMPLE",
       "OperatingSystem": "AMAZON_LINUX_2023"
   }
   ```

4. Now confirm nothing is being patched, because **you have not scheduled it**:

   ```bash
   aws ssm describe-instance-patch-states --instance-ids i-000000000000EXAMPLE 2>/dev/null \
     || aws ssm describe-patch-baselines --query 'length(BaselineIdentities)'
   aws ssm describe-maintenance-windows --query 'WindowIdentities'
   ```

   Expected output in a fresh account:

   ```
   16
   []
   ```

   Sixteen AWS-managed baselines exist. Zero maintenance windows exist. AWS built the tool and left it idle.

5. **Compare against a managed database.** Here the customer's OS responsibility disappears — and a *scheduling* responsibility appears in its place.

   ```bash
   aws rds describe-db-engine-versions --engine postgres \
     --query 'DBEngineVersions[].[EngineVersion,Status]' --output table | head -20
   ```

   Expected output (abridged):

   ```
   ----------------------------------------
   |   14.12   |  deprecated              |
   |   15.7    |  available               |
   |   16.4    |  available               |
   |   17.2    |  available               |
   ----------------------------------------
   ```

   ```bash
   aws rds describe-pending-maintenance-actions
   aws rds describe-db-instances \
     --query 'DBInstances[].[DBInstanceIdentifier,EngineVersion,AutoMinorVersionUpgrade,BackupRetentionPeriod,StorageEncrypted,PubliclyAccessible]' \
     --output table
   ```

   Expected output with no RDS instances:

   ```json
   {
       "PendingMaintenanceActions": []
   }
   ```

   > On RDS you cannot SSH to the host and you never see a kernel CVE. But `Status: deprecated` is a customer-facing signal: **AWS will not silently rewrite your major version.** Staying on a deprecated engine is a customer decision with a customer-owned end date.

6. **Compare against a serverless function.** Same pattern, sharper edge:

   ```bash
   aws lambda list-functions --query 'Functions[].[FunctionName,Runtime,PackageType]' --output table
   ```

   Expected output with no functions:

   ```
   ----------------
   |ListFunctions |
   +--------------+
   ```

   AWS patches the Lambda runtime, the OS, and the firecracker microVM. It **deprecates** runtimes on a published schedule; migrating your code off `python3.9` before that date is yours. And AWS never patches a vulnerable library you bundled in your deployment package.

<details>
<summary><strong>Optional paid block (≈ $0.01, terminate when done): observe drift on a real instance</strong></summary>

```bash
AMI=$(aws ssm get-parameter \
  --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --query Parameter.Value --output text)

INSTANCE=$(aws ec2 run-instances --image-id "$AMI" --instance-type t3.micro \
  --count 1 --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=clf-srm-lab}]' \
  --query 'Instances[0].InstanceId' --output text)
echo "$INSTANCE"

# Wait ~3 minutes for the SSM Agent to register (requires an instance profile
# with AmazonSSMManagedInstanceCore; if absent, the instance will not appear).
aws ssm describe-instance-information \
  --query 'InstanceInformationList[].[InstanceId,PlatformName,PlatformVersion,AgentVersion]' \
  --output table

# MANDATORY teardown
aws ec2 terminate-instances --instance-ids "$INSTANCE" \
  --query 'TerminatingInstances[].CurrentState.Name' --output text
```

The instance launched from a fully patched AMI. From the moment it boots, every new CVE is yours until *you* run a patch operation. AWS's patched AMI does not follow the running instance.

</details>

### Comprehension check — Block 5

- **Q5.1** — For each service, say who patches the **guest operating system**: EC2, RDS, Lambda, Fargate, S3.
- **Q5.2** — Step 5 showed PostgreSQL 14.12 as `deprecated`. A customer stays on it for two more years and is breached through a known engine CVE. Whose responsibility, and why does "RDS is managed" not transfer it?
- **Q5.3** — A Lambda function bundles a vulnerable version of a JSON parsing library. AWS patches the `python3.13` runtime weekly. Is the vulnerable library patched? Justify.
- **Q5.4** — Explain why patch management is classified as a **shared control** rather than as an AWS control or a customer control, and describe what each side actually does.
- **Q5.5** — Step 4 found 16 AWS-authored patch baselines and 0 maintenance windows. What does that pair of numbers demonstrate about how AWS discharges its half of a shared control?

---

## Exercise 6 — The abstraction gradient: build the matrix yourself

The single most useful mental model for exam scenarios: **the more managed the service, the less of the stack is yours — but the data and the access to it are always yours.**

### Steps

1. Query the customer-configurable surface at each level of abstraction and count the knobs.

   ```bash
   for svc in ec2 rds lambda s3api; do
     printf "%-8s %s operations\n" "$svc" "$(aws $svc help 2>/dev/null | grep -cE '^\s+o [a-z]')"
   done
   ```

   Expected output (illustrative — counts drift as AWS ships APIs):

   ```
   ec2      620 operations
   rds      160 operations
   lambda   70 operations
   s3api    100 operations
   ```

2. Confirm that the *identity and data* layer is present at every level — this is the invariant.

   ```bash
   # Resource policies exist for all three abstraction levels:
   aws s3api  help | grep -c 'put-bucket-policy'
   aws lambda help | grep -c 'add-permission'
   aws kms    help | grep -c 'put-key-policy'
   ```

3. Confirm that the *host* layer disappears as abstraction rises:

   ```bash
   aws ec2    help | grep -c 'get-console-output'    # 1 — you can see the guest console
   aws rds    help | grep -c 'get-console-output' || echo "0 — no host access on RDS"
   aws lambda help | grep -c 'get-console-output' || echo "0 — no host access on Lambda"
   ```

4. Fill in this matrix on paper before reading the answers. Use **A** (AWS), **C** (Customer), **S** (Shared).

   | Control | EC2 | RDS | Lambda | S3 |
   |---|---|---|---|---|
   | Physical security of facility | | | | |
   | Hypervisor / microVM patching | | | | |
   | Guest OS patching | | | | |
   | Database engine minor version upgrade | | n/a | n/a | n/a |
   | Application code / dependencies | | | | |
   | Network ACLs and security groups | | | | |
   | Encryption at rest — *availability of the feature* | | | | |
   | Encryption at rest — *decision to enable* | | | | |
   | Encryption in transit — *enforcement* | | | | |
   | IAM identities and policies | | | | |
   | Data classification | | | | |
   | Backup **existence** | | | | |
   | Backup **restore testing** | | | | |

### Comprehension check — Block 6

- **Q6.1** — Complete the matrix above.
- **Q6.2** — Two rows in the matrix are `C` in **every** column. Which two, and what principle does that express?
- **Q6.3** — RDS takes automated backups when `BackupRetentionPeriod > 0`. A customer sets it to `0` to save cost, then loses data. Is the loss AWS's responsibility because "RDS does backups"? Explain the trap.
- **Q6.4** — A team argues: "we moved from EC2 to Fargate, so security is now AWS's problem." Give the two-sentence correction an SRE should make.

---

## Exercise 7 — Detective controls are opt-in, and that is deliberate

AWS provides world-class detection services. It enables **none** of them for you, and this is a direct consequence of the model: AWS does not inspect your workloads unless you ask it to.

### Steps

1. Prove nothing is watching.

   ```bash
   echo -n "GuardDuty detectors: ";   aws guardduty list-detectors --query 'length(DetectorIds)'
   echo -n "Config recorders:    ";   aws configservice describe-configuration-recorders --query 'length(ConfigurationRecorders)'
   echo -n "Security Hub:        ";   aws securityhub describe-hub 2>&1 | head -1
   echo -n "Access Analyzer:     ";   aws accessanalyzer list-analyzers --query 'length(analyzers)'
   ```

   Expected output in a fresh account:

   ```
   GuardDuty detectors: 0
   Config recorders:    0
   Security Hub:        An error occurred (InvalidAccessException) when calling the DescribeHub operation: Account 123456789012 is not subscribed to AWS Security Hub
   Access Analyzer:     0
   ```

2. Now confirm the one thing AWS **does** turn on for you, in every account, at no charge:

   ```bash
   aws cloudtrail describe-trails --query 'trailList[].[Name,IsMultiRegionTrail,S3BucketName]' --output table
   aws cloudtrail lookup-events --max-results 3 \
     --query 'Events[].[EventTime,EventName,Username]' --output table
   ```

   Expected output:

   ```
   ---------------------------------------
   |           DescribeTrails            |
   +-------------------------------------+
   ```
   ```
   ------------------------------------------------------------------
   |                         LookupEvents                           |
   +---------------------------+--------------------+---------------+
   |  2026-09-03T14:02:11+00:00|  PutBucketPolicy   |  clf-lab      |
   |  2026-09-03T14:01:47+00:00|  PutPublicAccessBlock | clf-lab    |
   |  2026-09-03T13:58:02+00:00|  CreateBucket      |  clf-lab      |
   +---------------------------+--------------------+---------------+
   ```

   **No trail exists, yet events are there.** CloudTrail **Event history** is on by default, free, and retains 90 days of management events per region. Retention beyond 90 days, multi-region aggregation, data events, and log-file integrity validation all require a trail *you* create.

   > Notice that your own step-4 mistake from Exercise 4 is in that list. Attribution of customer actions is a control AWS provides; *reviewing* it is not.

3. Check the free Trusted Advisor security checks (available on all support plans):

   ```bash
   aws support describe-trusted-advisor-checks --language en \
     --query "checks[?category=='security'].[name]" --output table 2>&1 | head -12
   ```

   Expected output on Basic/Developer support:

   ```
   An error occurred (SubscriptionRequiredException) when calling the
   DescribeTrustedAdvisorChecks operation: AWS Premium Support Subscription is required
   ```

   The **API** requires Business/Enterprise support; the core security checks are still visible in the console on any plan. This is a support-plan boundary, not a responsibility boundary — worth knowing for Domain 4.

### Comprehension check — Block 7

- **Q7.1** — CloudTrail Event history worked with zero configuration; GuardDuty returned zero detectors. Reconcile these two facts with the shared responsibility model.
- **Q7.2** — Name the three limits of CloudTrail Event history that a customer must create a trail to overcome.
- **Q7.3** — An attacker uses stolen credentials to call `GetObject` on 4 TB of your data over six hours. GuardDuty was never enabled. Was AWS obliged to notice? Was AWS obliged to *record* it?
- **Q7.4** — Why is it consistent with the model — not a shortcoming — that AWS does not scan the contents of your S3 buckets or EBS volumes by default?

---

## Exercise 8 — The contractual edge: agreements, acceptable use, and penetration testing

Some responsibilities are not expressed in an API at all. They are in the agreement you accepted in Exercise 2.

### Steps

1. Re-read what you are bound by:

   ```bash
   aws artifact list-customer-agreements \
     --query 'customerAgreements[].[name,agreementType,state,effectiveStart]' --output table
   ```

2. Open the two governing documents and skim them (no CLI — these are the sources):

   - AWS Customer Agreement — <https://aws.amazon.com/agreement/>
   - AWS Acceptable Use Policy — <https://aws.amazon.com/aup/>
   - AWS Customer Support Policy for Penetration Testing — <https://aws.amazon.com/security/penetration-testing/>

3. Answer, from the penetration testing policy, without guessing: which activities may a customer perform against **their own** resources without prior AWS approval, and which are **prohibited outright**?

4. Confirm the data-ownership position stated in the agreement and the Data Privacy FAQ (<https://aws.amazon.com/compliance/data-privacy-faq/>): AWS does not access customer content except as required to provide the services or comply with law, and the customer retains ownership and control.

5. Test the practical consequence of "you own the data" — deletion is final:

   ```bash
   # Versioning is OFF by default. Confirm on your scratch bucket:
   aws s3api get-bucket-versioning --bucket "$BUCKET"
   ```

   Expected output:

   ```json
   {}
   ```

   An empty object means versioning was never enabled. Delete an object in that bucket and **no AWS process, support case, or backup will bring it back.** Enabling versioning and MFA Delete is a customer control:

   ```bash
   aws s3api put-bucket-versioning --bucket "$BUCKET" \
     --versioning-configuration Status=Enabled
   aws s3api get-bucket-versioning --bucket "$BUCKET"
   ```

   ```json
   {
       "Status": "Enabled"
   }
   ```

### Comprehension check — Block 8

- **Q8.1** — Under the AWS Customer Agreement and the Data Privacy FAQ, who owns customer content, and what does that ownership imply about deletion?
- **Q8.2** — Your security team wants to run a port scan and a credential-stuffing simulation against your own EC2 instances, and a volumetric DDoS test against your own ALB to validate Shield. Which of these are permitted, which require approval, and which are prohibited?
- **Q8.3** — A developer runs a crypto-mining container on Fargate in your account. AWS suspends the account. Which document governs that outcome, and on which side of the model is the violation?
- **Q8.4** — S3 versioning is off by default and 11-nines durability is on by default. Explain, in responsibility terms, why durability does not protect against `aws s3 rm`.

---

## Exercise 9 — Capstone: incident triage

For each scenario, write (a) the responsible party, (b) the *specific* control that failed, and (c) the AWS-native control that would have prevented or detected it. Use only what you exercised above.

### Steps

1. **Scenario A** — An S3 bucket containing customer PII is found indexed by a search engine. CloudTrail shows `PutPublicAccessBlock` followed by `PutBucketPolicy`, both by an IAM role attached to a CI pipeline, 40 days ago.

2. **Scenario B** — An EC2 instance running Amazon Linux 2023, launched 14 months ago from a then-current AMI, is compromised through an unpatched OpenSSH CVE published 9 months ago. The instance had `AmazonSSMManagedInstanceCore` attached but no maintenance window existed.

3. **Scenario C** — A Nitro hypervisor vulnerability is disclosed. AWS publishes a security bulletin stating all fleets were remediated before disclosure, with no customer action required and no instance reboots.

4. **Scenario D** — An RDS PostgreSQL instance is deleted by an engineer using a role with `rds:DeleteDBInstance`. `SkipFinalSnapshot` was `true` and `DeletionProtection` was `false`. Backup retention was 7 days; automated backups were removed with the instance.

5. **Scenario E** — A Lambda function processing payments logs the full card PAN to CloudWatch Logs. The log group has no retention policy and is not encrypted with a customer-managed KMS key.

6. **Scenario F** — An entire Availability Zone loses power. A single-AZ RDS instance is unavailable for 4 hours. A Multi-AZ instance in the same account fails over in 90 seconds.

### Comprehension check — Block 9

- **Q9.1** — Complete the triage table for Scenarios A–F.
- **Q9.2** — Which single scenario is unambiguously **AWS's** responsibility, and what evidence in the scenario tells you?
- **Q9.3** — Scenario F contains both an AWS responsibility and a customer responsibility. Separate them precisely.
- **Q9.4** — Formulate a one-sentence rule you could apply to any unseen CLF-C02 scenario question about responsibility.

---

## Teardown

```bash
# Remove the scratch bucket (versioning is now on, so purge versions first)
aws s3api list-object-versions --bucket "$BUCKET" \
  --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' > /tmp/vers.json 2>/dev/null
[ -s /tmp/vers.json ] && aws s3api delete-objects --bucket "$BUCKET" --delete file:///tmp/vers.json

aws s3api delete-bucket --bucket "$BUCKET"
aws s3api head-bucket --bucket "$BUCKET" 2>&1 | head -1

# If you ran the optional EC2 block, confirm the instance is gone:
aws ec2 describe-instances --filters Name=tag:Name,Values=clf-srm-lab \
  --query 'Reservations[].Instances[].[InstanceId,State.Name]' --output table

rm -f /tmp/public-policy.json /tmp/creds.csv /tmp/vers.json
```

Expected output:

```
An error occurred (404) when calling the HeadBucket operation: Not Found
```

> **Leave `enable-ebs-encryption-by-default` and root MFA on.** They cost nothing and they are the right default.

---

## Answers

<details>
<summary><strong>Click to reveal all answers (Blocks 0–9)</strong></summary>

### Block 0

**A0.1** — AWS is responsible for the security *of* every region equally, but **which** regions your data resides in is a customer choice with legal and contractual consequences (data residency, GDPR transfers, sector regulation, latency). AWS will never move your data between regions on its own; region selection is a customer-configured control that AWS deliberately does not make for you.

**A0.2** — Yes, and it is the customer's. Disabled opt-in regions shrink the attack surface: a stolen credential cannot spin up resources in a region you never enabled and never monitor. AWS ships them disabled as a safer default, but enabling/disabling them (via AWS Organizations or account settings) is a customer action.

**A0.3** — Entirely the customer's. AWS creates and protects the *authentication infrastructure* (the IAM/sign-in service, its availability, its cryptography). Whether the root user has MFA, what its password is, and whether it has access keys are customer-specific controls. This is the most common single finding in real account audits and a recurring CLF-C02 answer.

---

### Block 1

**A1.1** — *If an AWS API lets you change it, it is your responsibility; if no API exposes it, AWS owns it end to end.* Example: `put-bucket-policy` exists, so who can read your bucket is yours; no API exposes S3's cross-AZ replication factor, so durability is AWS's.

**A1.2** — Responsibility follows **control**, not visibility. `Hypervisor: nitro` is a read-only attribute describing the platform you are buying. There is no operation to inspect its patch level, change its configuration, or schedule its maintenance. You cannot be responsible for a system you cannot act on — and AWS accepts that responsibility contractually and demonstrates it through the audits in Artifact.

**A1.3** — RDS engine version upgrades. `modify-db-instance --engine-version` and `AutoMinorVersionUpgrade` are customer-facing APIs, but AWS performs the upgrade on hosts you never touch. The customer owns the **decision and the timing**; AWS owns the **execution**. Same pattern for `apply-pending-maintenance-action`. The heuristic tells you where the decision sits, not always where the work happens.

**A1.4** — **Inherited control.** The customer inherits S3's durability and multi-AZ redundancy fully from AWS, with no configuration surface and no customer obligation beyond choosing S3.

---

### Block 2

**A2.1** — AWS engages the independent auditors and undergoes the assessment (security *of* the cloud). The **customer** is responsible for obtaining the resulting report from AWS Artifact and presenting it to their regulator as part of *their own* compliance evidence package. AWS does not talk to your regulator on your behalf.

**A2.2** — No. AWS does not permit customer audits of its data centres — it would not scale and would itself be a security risk (thousands of customers touring facilities). The model resolves this by substituting **third-party attestation for direct inspection**: AWS is audited once by accredited auditors, and every customer inherits the result via Artifact under NDA. This is the mechanism that makes "security of the cloud" verifiable without being individually auditable.

**A2.3** — A **Report** (SOC 2) flows *from AWS to you*: it is AWS's evidence that it discharged its half. An **Agreement** (HIPAA BAA) flows *from you to AWS*: it is a contract you accept that changes your obligations and enables regulated workloads. Reports are downloads; agreements are acceptances.

**A2.4** — No. The AOC covers AWS's infrastructure only. The customer **inherits** the physical, environmental, and infrastructure controls and does **not** need to re-audit them — that is the value of inherited controls, and it genuinely shrinks the audit scope. But the customer must still implement and evidence everything above the line: network segmentation, key management, cardholder data encryption, access control, logging, and vulnerability management. Compliance is inherited *in part*, never *in whole*.

**A2.5** — It enforces that the customer explicitly accepts the confidentiality terms (NDA) before receiving AWS's audit evidence. Protecting that document once you have it — not redistributing it, storing it appropriately — is a customer responsibility that begins the moment the token is exchanged.

---

### Block 3

**A3.1** — Password complexity, rotation, and reuse rules are policy decisions driven by the customer's own regulatory regime, risk appetite, and workforce. A default imposed by AWS would be wrong for many customers and would create false assurance for the rest. Consistent with the model, AWS supplies the *capability* (`update-account-password-policy`) with full fidelity and leaves the *policy* to the party that knows the requirements. Note that AWS does enforce a non-negotiable minimum on root and IAM passwords — the floor is AWS's, the policy is yours.

**A3.2** — The customer, in both halves of the question. Credential lifecycle — creation, rotation, scoping, revocation — is a customer-specific control; AWS provides IAM Access Analyzer, credential reports, and last-used timestamps to make it manageable. If the leak were caused by a **defect in an AWS service** (e.g. a service logging your key material in plaintext), that would be a failure of security *of* the cloud and AWS's responsibility — but a key committed to Git by a developer is not that.

**A3.3** — EBS is a regional service and the default-encryption flag is a property of the EC2 service in a single region. It is a common and serious operational trap: a team enables it in `us-east-1`, an autoscaling group or a DR pipeline creates volumes in `eu-west-1`, and those are unencrypted. The mitigation is a customer control too — enforce it with an SCP or AWS Config rule across all regions rather than trusting a per-region toggle.

**A3.4** — (a) **AWS** — the cryptographic implementation and its correctness are AWS's, validated under FIPS 140-3 for KMS HSMs. (b) **Customer** — enabling encryption on a volume is a customer decision. (c) **AWS** — durability and physical protection of KMS key material in the HSM fleet is inherited. (d) **Customer** — who may `Decrypt` with the key is written by you in the key policy.

---

### Block 4

**A4.1** — (a) **AWS's responsibility to serve it, and AWS discharged it correctly** — S3 executed an explicit, authenticated, authorised customer instruction. Serving those objects *was* the correct behaviour. (b) **Entirely the customer's.** The exposure originated in two deliberate customer API calls. The exam phrasing for this is: *misconfiguration of a customer-controlled resource is never AWS's responsibility.*

**A4.2** — SSE-S3 protects data **at rest on AWS's storage media**: it defends against physical media compromise and against an attacker reading the underlying disks. It is applied and removed transparently by S3 for any caller that passes authorisation. A public bucket policy grants that authorisation to `Principal: "*"`, so S3 decrypts and serves cheerfully. Encryption at rest is orthogonal to access control — conflating them is a classic exam distractor.

**A4.3** —
- **Inherited controls** — fully controlled and operated by AWS; the customer receives the benefit with no configuration and no obligation. → *physical media destruction, data-centre power redundancy, zone security.*
- **Shared controls** — the control applies to both the infrastructure layer and the customer layer, with each side executing its own instance of it. → *patch management, configuration management, awareness and training.*
- **Customer-specific controls** — no AWS counterpart; they exist only because of what the customer built. → *IAM user provisioning* (and e.g. service-and-communications protection, zone security within the customer's own application).

*Note:* "awareness and training" is shared because AWS trains its employees and you must train yours; "zone security" appears on both sides in AWS's published table for the same reason.

**A4.4** — It reduces risk because ACLs are a legacy, per-object, easily-misunderstood mechanism, and eliminating them removes an entire class of accidental exposure. It does not reduce responsibility because the customer can re-enable ACLs with one API call (`put-bucket-ownership-controls`), and because bucket policies — a far more powerful exposure vector — remain fully under customer control. **A safer default narrows the failure modes; it does not move the line.**

---

### Block 5

**A5.1** —
| Service | Guest OS patched by |
|---|---|
| EC2 | **Customer** (AWS supplies patched AMIs and the SSM Patch Manager tooling) |
| RDS | **AWS** (customer schedules/approves the maintenance and owns engine version choice) |
| Lambda | **AWS** (customer owns function code, dependencies, and migrating off deprecated runtimes) |
| Fargate | **AWS** (customer owns the container image contents, including its OS packages) |
| S3 | **AWS** — there is no guest OS; the concept does not exist for the customer |

**A5.2** — The **customer's**. "Managed" means AWS performs the mechanics of the upgrade, not that AWS decides when your production database changes major version — doing so unilaterally would break applications. AWS discharges its half by publishing the version lifecycle, marking versions `deprecated`, emailing deprecation notices, and eventually force-upgrading at a published deadline. Ignoring a published deprecation is a customer risk decision.

**A5.3** — No. AWS patches the managed runtime — the Python interpreter, the OS packages in the execution environment, the microVM. Anything you ship inside your deployment package or layer is **your code** as far as the model is concerned. This is why dependency scanning (Amazon Inspector for Lambda, or your own SCA in CI) is a customer control.

**A5.4** — Because the *same named control* must be implemented independently at two layers that neither party can reach into. AWS patches the hypervisor, host firmware, host OS, network devices, and the managed-service substrate — invisibly, on its own schedule. The customer patches guest OSes, container images, application runtimes, and libraries. Neither can do the other's half, and a failure at either layer compromises the workload. That two-layer structure is exactly what "shared control" means — it is not "we split the work on one task."

**A5.5** — It shows AWS's half of a shared control is discharged by **supplying complete, ready-to-use capability** — patch catalogues, severity metadata, curated baselines, an agent, an orchestrator — and then stopping at the point where an action would affect customer workloads. AWS builds the machine; pressing the button is a customer act with customer blast radius.

---

### Block 6

**A6.1** —

| Control | EC2 | RDS | Lambda | S3 |
|---|---|---|---|---|
| Physical security of facility | A | A | A | A |
| Hypervisor / microVM patching | A | A | A | A |
| Guest OS patching | **C** | A | A | A |
| DB engine minor version upgrade | — | **S** | — | — |
| Application code / dependencies | C | C | **C** | C¹ |
| Network ACLs and security groups | C | C | C² | C³ |
| Encryption at rest — feature availability | A | A | A | A |
| Encryption at rest — decision to enable | C | C | C⁴ | C⁴ |
| Encryption in transit — enforcement | C | C | C | C |
| IAM identities and policies | C | C | C | C |
| Data classification | C | C | C | C |
| Backup existence | C | **S** | C⁵ | C |
| Backup restore testing | C | C | C | C |

¹ the application that writes to S3. ² VPC config if the function is VPC-attached; otherwise IAM/resource policy. ³ bucket policy, VPC endpoint policy, Access Points. ⁴ SSE-S3 / Lambda env-var encryption are on by default, but choosing SSE-KMS with a customer-managed key and its policy is yours. ⁵ AWS retains function versions; your source of truth is your repository.

**A6.2** — **Data classification** and **IAM identities and policies** (backup restore testing is also `C` throughout). The principle: *the customer always owns their data and always owns who may reach it, at every level of abstraction, no matter how managed the service is.* This is the invariant to fall back on for any unseen scenario.

**A6.3** — No — this is the trap. RDS provides the *capability* for automated backups and enables a default retention period, but retention is a customer-configured parameter with `0` as a legal value meaning "disabled." Choosing `0` is an explicit customer decision to accept the risk, exactly like disabling Block Public Access in Exercise 4. AWS operated the service correctly by honouring the setting.

**A6.4** — "Fargate removes our responsibility for patching the host OS and the container runtime — that genuinely moved to AWS. It removes nothing about our container image contents, our IAM task roles, our security groups, our secrets handling, or our data — and those are where breaches actually happen."

---

### Block 7

**A7.1** — CloudTrail management-event history is part of AWS providing an **accountable, attributable platform**: AWS records what was done to *its* control plane, in every account, unconditionally and for free. GuardDuty analyses the *content and behaviour* of customer workloads — inspecting your DNS queries, VPC flow logs, and API patterns. AWS will not perform that analysis without consent, because it is inspection of customer data. The line is: *AWS always records its own control plane; AWS never inspects your workload uninvited.*

**A7.2** — (1) **Retention** — Event history keeps 90 days; a trail delivering to S3 keeps data indefinitely. (2) **Scope** — Event history covers management events only, per region; a trail can capture **data events** (S3 object-level, Lambda invocations) and aggregate multi-region and organisation-wide. (3) **Integrity and downstream use** — only a trail gives log-file integrity validation (digest files), delivery to S3/CloudWatch Logs, SSE-KMS encryption, and machine-readable input for Security Hub, Athena, or a SIEM.

**A7.3** — AWS was **not obliged to notice**: detecting anomalous access patterns in your account is precisely what GuardDuty does, and you did not enable it. AWS **was obliged to record it** — every `GetObject` is a data event, which means it is captured only if you configured a trail with S3 data events; the *management* API activity of those credentials would appear in Event history. The uncomfortable, exam-relevant conclusion: with default settings, the object-level reads may not be recoverable at all, and that gap is the customer's.

**A7.4** — Because AWS's contractual and privacy position — stated in the Customer Agreement and the Data Privacy FAQ — is that it does not access customer content except as necessary to provide the service or to comply with law. Automatic content inspection would violate that commitment and would be unacceptable to regulated customers. Opt-in detection (GuardDuty, Macie, Inspector) is the model working correctly: the capability is offered, the consent is required, the responsibility to consent is yours.

---

### Block 8

**A8.1** — The **customer** owns their content and controls where it is stored, how it is secured, and who may access it. AWS acts as a processor of that content on the customer's instructions. The implication for deletion is blunt: a delete issued by an authorised customer principal is an instruction AWS carries out, and AWS maintains no shadow copy to restore from. Protection against accidental or malicious deletion — versioning, MFA Delete, Object Lock, AWS Backup, cross-account/cross-region copies, `DeletionProtection` — is a set of customer controls that must be enabled *before* the incident.

**A8.2** — Port scanning and credential-stuffing simulation against your own EC2 instances fall within the **permitted services** list and require **no prior approval**, provided they stay inside your own resources and within the policy's limits. Any **denial-of-service or DDoS simulation, including volumetric testing against your own ALB, is prohibited without explicit prior authorisation** through AWS's simulated-events process — because the traffic traverses shared AWS infrastructure and affects other tenants. The governing rule: *the policy protects the shared substrate, not just you.*

**A8.3** — The **AWS Acceptable Use Policy**, incorporated into the AWS Customer Agreement. The violation is entirely on the **customer** side: you are responsible for what runs in your account, including what a compromised or careless developer runs. AWS's enforcement action is a contractual remedy, not a security failure on AWS's part — and note that the underlying enabling failure (over-permissive IAM, no GuardDuty CryptoCurrency finding enabled) is also customer-side.

**A8.4** — Durability answers "will AWS lose your object?" — the 11-nines figure describes resistance to **hardware and facility failure**, and it is an inherited control. `aws s3 rm` is not a failure; it is an **authenticated, authorised instruction** that S3 executes faithfully across all its replicas at once. High durability makes AWS's deletion of your data essentially impossible while making *your* deletion of your data instantaneous and permanent. Protecting against the second is a customer control (versioning + MFA Delete, or Object Lock in compliance mode).

---

### Block 9

**A9.1** —

| # | Responsible | Control that failed | Prevention / detection |
|---|---|---|---|
| **A** | **Customer** | S3 Block Public Access disabled and a public bucket policy applied by an over-permissioned CI role; no review of CloudTrail for 40 days | Account-level BPA (`s3control put-public-access-block`); SCP denying `s3:PutBucketPolicy` with public principals; least-privilege CI role; IAM Access Analyzer; AWS Config rule `s3-bucket-public-read-prohibited`; GuardDuty `Policy:S3/BucketAnonymousAccessGranted` |
| **B** | **Customer** | Guest OS patching — the AMI was current at launch and drifted for 14 months; SSM was available but no patch schedule existed | SSM Patch Manager with a maintenance window and the AWS-provided baseline; immutable/golden-AMI re-bake pipeline; Amazon Inspector for CVE detection |
| **C** | **AWS** | Nothing on the customer side; AWS remediated its own layer | None required — this is an **inherited control** working as designed |
| **D** | **Customer** | Deletion protection off, final snapshot skipped, and no backup outside the instance's lifecycle | `DeletionProtection=true`; `SkipFinalSnapshot=false`; AWS Backup vault (independent lifecycle, separate account) with Vault Lock; IAM/SCP restricting `rds:DeleteDBInstance` |
| **E** | **Customer** | Application code (data classification and handling) plus log configuration; both above the line at every abstraction level | Code review / SAST; CloudWatch Logs retention policy and SSE-KMS with a CMK; Amazon Macie or a log-scrubbing layer; PCI-DSS scope control |
| **F** | **Both — see A9.3** | Single-AZ architecture chosen by the customer | Multi-AZ deployment; the second instance in the scenario is the proof it works |

**A9.2** — **Scenario C.** Three tells: the failure is in a layer with no customer API (the hypervisor), the remediation happened without customer action, and AWS's public statement is the evidence mechanism the model relies on for security *of* the cloud. Note the absence of reboots — that is Nitro live-update, entirely inside AWS's half.

**A9.3** — **AWS's half:** the AZ lost power, and AWS is responsible for data-centre power, cooling, and physical resilience; AWS also delivered on its Multi-AZ commitment by failing the second instance over in 90 seconds without customer intervention. **The customer's half:** AWS publishes an SLA and an availability design in which *a single AZ can fail*, and provides Multi-AZ as the mitigation. Choosing single-AZ for a workload that cannot tolerate 4 hours of downtime is a customer architecture decision. AWS is responsible for the **resilience of the infrastructure**; the customer is responsible for the **resilience of the architecture built on it**.

**A9.4** — *If the failure is in something you could have configured, deployed, encrypted, patched, permissioned, deleted, or architected differently through an AWS API, it is yours; if it is in the physical facility, the hypervisor, the network fabric, or the managed-service substrate you cannot reach, it is AWS's — and your data and who can access it are yours in every single case.*

</details>

---

## Sources

- AWS Certified Cloud Practitioner (CLF-C02) Exam Guide — <https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf>
- Shared Responsibility Model — <https://aws.amazon.com/compliance/shared-responsibility-model/>
- What is AWS Artifact — <https://docs.aws.amazon.com/artifact/latest/ug/what-is-aws-artifact.html>
- Blocking public access to your Amazon S3 storage — <https://docs.aws.amazon.com/AmazonS3/latest/userguide/access-control-block-public-access.html>
- Controlling ownership of objects and disabling ACLs — <https://docs.aws.amazon.com/AmazonS3/latest/userguide/about-object-ownership.html>
- Setting default server-side encryption behavior for S3 buckets — <https://docs.aws.amazon.com/AmazonS3/latest/userguide/bucket-encryption.html>
- Using versioning in S3 buckets — <https://docs.aws.amazon.com/AmazonS3/latest/userguide/Versioning.html>
- AWS Systems Manager Patch Manager — <https://docs.aws.amazon.com/systems-manager/latest/userguide/patch-manager.html>
- Amazon EBS encryption (encryption by default) — <https://docs.aws.amazon.com/ebs/latest/userguide/ebs-encryption.html>
- Amazon RDS maintenance and engine version lifecycle — <https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_UpgradeDBInstance.Maintenance.html>
- AWS Lambda runtimes and runtime deprecation — <https://docs.aws.amazon.com/lambda/latest/dg/lambda-runtimes.html>
- Getting credential reports for your AWS account — <https://docs.aws.amazon.com/IAM/latest/UserGuide/id_credentials_getting-report.html>
- Working with CloudTrail Event history — <https://docs.aws.amazon.com/awscloudtrail/latest/userguide/view-cloudtrail-events.html>
- Amazon GuardDuty — <https://docs.aws.amazon.com/guardduty/latest/ug/what-is-guardduty.html>
- AWS Customer Agreement — <https://aws.amazon.com/agreement/>
- AWS Acceptable Use Policy — <https://aws.amazon.com/aup/>
- AWS Customer Support Policy for Penetration Testing — <https://aws.amazon.com/security/penetration-testing/>
- AWS Data Privacy FAQ — <https://aws.amazon.com/compliance/data-privacy-faq/>