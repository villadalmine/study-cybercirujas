# AWS Certified Cloud Practitioner (CLF-C02) — Domain 3, Task Statement 3.1

## Define methods of deploying and operating in the AWS Cloud

**Exam weight of the parent domain (Cloud Technology and Services): 34% — this task statement is scored at 4.25 in the platform's normalized weighting.**

**Source of record:** [AWS Certified Cloud Practitioner (CLF-C02) Exam Guide](https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf) — Task Statement 3.1 enumerates three knowledge areas: *different ways of provisioning and operating* (programmatic access / API / SDK / CLI, the AWS Management Console, Infrastructure as Code), *different deployment models* (cloud, hybrid, on-premises), and *connectivity options* (VPN, AWS Direct Connect, public internet).

---

## What you will actually build

These exercises are not click-throughs. You will:

1. Prove that all four provisioning interfaces converge on **one** thing — the signed HTTPS API — and observe that convergence in CloudTrail.
2. Read a real SigV4 signature off the wire and explain each of its five components.
3. Provision a stack declaratively with CloudFormation, then **change** it through a change set instead of a direct update.
4. Break the stack deliberately and diagnose the failure from `describe-stack-events` rather than the console.
5. Introduce out-of-band drift and detect it programmatically.
6. Enumerate the real edge/hybrid footprint of a Region (Local Zones, Wavelength Zones, Outposts, Direct Connect locations) with read-only API calls.
7. Build a connectivity decision matrix backed by the actual attributes the APIs return.

---

## Prerequisites and cost guardrails

**Read this block before running anything.**

| Requirement | Verification command | Notes |
|---|---|---|
| AWS CLI v2 | `aws --version` | v1 is end-of-support; `aws configure sso` behaves differently |
| An AWS account with an admin-equivalent principal | `aws sts get-caller-identity` | IAM Identity Center role strongly preferred over long-lived IAM user keys |
| Python 3.9+ and `boto3` | `python3 -c "import boto3; print(boto3.__version__)"` | for Exercise 2 |
| `jq` (optional but assumed in outputs) | `jq --version` | |

**Cost:** Exercises 1, 2, 6, 7 and 8 are **read-only or free-tier**. Exercises 3–5 create an S3 bucket, an SSM Parameter Store parameter (Standard tier — free) and a CloudFormation stack. CloudFormation itself has no charge for AWS-native resource types; you pay only for what it creates. Total expected spend if you complete the cleanup section: **under $0.01**. Nothing here creates a NAT Gateway, a Site-to-Site VPN connection ($0.05/hour), a Direct Connect port, or an Outpost.

**Set your working context once:**

```bash
export AWS_PROFILE=clf-lab
export AWS_REGION=us-east-1
export LAB_PREFIX="clf31-$(date +%s | tail -c 6)"
echo "Lab prefix: ${LAB_PREFIX}"
```

```
Lab prefix: clf31-83291
```

> Every resource you create is named with `${LAB_PREFIX}`. The cleanup section deletes exactly that set.

---

## Exercise 1 — The four interfaces are one interface

**Objective:** demonstrate that the Console, the CLI, an SDK and CloudFormation are all *clients* of the same HTTPS service API, and that CloudTrail records the difference only in metadata.

This is the single most load-bearing concept in Task Statement 3.1. The exam asks "which methods can provision resources"; production asks "which method left this resource here, and can I reproduce it".

### Steps

1. Confirm your CLI version and identity. Note the ARN shape — an `assumed-role` ARN means you are on temporary credentials; an `iam-user` ARN means long-lived keys.

   ```bash
   aws --version
   aws sts get-caller-identity
   ```

   ```
   aws-cli/2.17.42 Python/3.11.9 linux/6.5.0 exe/x86_64.fedora.41
   ```
   ```json
   {
       "UserId": "AROA4EXAMPLEID:platform-eng",
       "Account": "111122223333",
       "Arn": "arn:aws:sts::111122223333:assumed-role/AWSReservedSSO_PlatformEngineer_1a2b3c/platform-eng"
   }
   ```

2. Inspect where each element of your configuration is resolved from. The `Location` column is the whole point — the CLI merges environment variables, the shared config file, the shared credentials file and command-line flags in a defined precedence order.

   ```bash
   aws configure list
   ```

   ```
         Name                    Value             Type    Location
         ----                    -----             ----    --------
      profile                  clf-lab           manual    --profile
   access_key     ****************ABCD              sso
   secret_key     ****************wXyZ              sso
       region                 us-east-1              env    AWS_REGION
   ```

3. Create one SSM parameter through the **CLI**:

   ```bash
   aws ssm put-parameter \
     --name "/${LAB_PREFIX}/origin/cli" \
     --value "created-by-cli" \
     --type String \
     --tier Standard
   ```

   ```json
   {
       "Version": 1,
       "Tier": "Standard"
   }
   ```

4. Create a second one through an **SDK** (boto3), so the user agent differs:

   ```bash
   python3 - <<'PY'
   import os, boto3
   ssm = boto3.client("ssm")
   r = ssm.put_parameter(
       Name=f"/{os.environ['LAB_PREFIX']}/origin/sdk",
       Value="created-by-sdk",
       Type="String",
       Tier="Standard",
   )
   print(r["Version"], r["Tier"])
   PY
   ```

   ```
   1 Standard
   ```

5. Create a third one through the **AWS Management Console**: navigate to *Systems Manager → Parameter Store → Create parameter*, name it `/${LAB_PREFIX}/origin/console`, type `String`, value `created-by-console`.

6. Wait ~10–15 minutes (CloudTrail Event history is not real time), then read back the *provenance* of all three:

   ```bash
   aws cloudtrail lookup-events \
     --lookup-attributes AttributeKey=EventName,AttributeValue=PutParameter \
     --max-results 10 \
     --query 'Events[].CloudTrailEvent' \
     --output text \
   | jq -r '[.eventTime, (.requestParameters.name), .userAgent] | @tsv'
   ```

   ```
   2026-09-04T14:22:31Z    /clf31-83291/origin/console    AWS Internal
   2026-09-04T14:19:04Z    /clf31-83291/origin/sdk        Boto3/1.34.98 md/Botocore#1.34.98 ua/2.0 os/linux#6.5.0 md/arch#x86_64 lang/python#3.12.4 cfg/retry-mode#legacy Botocore/1.34.98
   2026-09-04T14:18:47Z    /clf31-83291/origin/cli        aws-cli/2.17.42 md/awscrt#0.20.11 ua/2.0 os/linux#6.5.0 md/arch#x86_64 lang/python#3.11.9 cfg/retry-mode#standard
   ```

7. Compare the `eventName`, `eventSource` and `readOnly` fields across all three records:

   ```bash
   aws cloudtrail lookup-events \
     --lookup-attributes AttributeKey=EventName,AttributeValue=PutParameter \
     --max-results 3 --query 'Events[].CloudTrailEvent' --output text \
   | jq -r '[.eventSource, .eventName, (.readOnly|tostring), .managementEvent|tostring] | @tsv'
   ```

   ```
   ssm.amazonaws.com    PutParameter    false    true
   ssm.amazonaws.com    PutParameter    false    true
   ssm.amazonaws.com    PutParameter    false    true
   ```

### Comprehension check — Block 1

- **Q1.1** — Three different interfaces produced three CloudTrail records with an *identical* `eventSource` and `eventName`. What does that tell you about the architectural relationship between the Console, the CLI and the SDK?
- **Q1.2** — The Console-originated event shows `userAgent: "AWS Internal"` rather than a browser string. Explain the mechanism that produces this, and why the browser's own user agent does not appear.
- **Q1.3** — A colleague argues that "the Console is a *different* provisioning method than the API, so it needs a separate audit strategy." Refute or support this using the output of step 7.
- **Q1.4** — Which single field in a CloudTrail record would you use to build an alert for "someone provisioned production infrastructure by hand instead of through the pipeline"? Name the field and describe the exact predicate.
- **Q1.5** — In step 2, `region` resolved from `env`. List the CLI's configuration precedence order from highest to lowest, and state where a `--region` flag sits in it.

---

## Exercise 2 — Programmatic access: the signature, the retry, the paginator

**Objective:** open the black box of "programmatic access". You cannot reason about API-based provisioning if you treat the SDK as magic.

### Steps

1. Capture the raw signed request the CLI emits. `--debug` writes the canonical request, the string-to-sign and the final `Authorization` header to stderr.

   ```bash
   aws s3api list-buckets --debug 2>&1 \
     | grep -o "AWS4-HMAC-SHA256 Credential=[^,]*, SignedHeaders=[^,]*, Signature=[0-9a-f]\{16\}" \
     | head -1
   ```

   ```
   AWS4-HMAC-SHA256 Credential=ASIA4EXAMPLEKEYID/20260904/us-east-1/s3/aws4_request, SignedHeaders=host;x-amz-content-sha256;x-amz-date;x-amz-security-token, Signature=9f2a4c1b7e0d3a55
   ```

2. Extract the credential scope on its own — the four slash-separated components after the access key ID:

   ```bash
   aws s3api list-buckets --debug 2>&1 \
     | grep -oP 'Credential=\K[^,]*' | head -1
   ```

   ```
   ASIA4EXAMPLEKEYID/20260904/us-east-1/s3/aws4_request
   ```

3. Observe that a *different service* changes the scope, proving the signature is service- and region-bound:

   ```bash
   aws ssm describe-parameters --debug 2>&1 \
     | grep -oP 'Credential=\K[^,]*' | head -1
   ```

   ```
   ASIA4EXAMPLEKEYID/20260904/us-east-1/ssm/aws4_request
   ```

4. Configure explicit retry behaviour. Append to `~/.aws/config` under your profile:

   ```ini
   [profile clf-lab]
   region     = us-east-1
   output     = json
   retry_mode = standard
   max_attempts = 5
   ```

   Then confirm the SDK reports it:

   ```bash
   aws ssm describe-parameters --debug 2>&1 | grep -i "retry" | head -3
   ```

   ```
   2026-09-04 14:31:02,118 - MainThread - botocore.retries.standard - DEBUG - Registering retry handler for operation DescribeParameters with mode standard
   2026-09-04 14:31:02,119 - MainThread - botocore.retries.standard - DEBUG - Max attempts: 5
   2026-09-04 14:31:02,556 - MainThread - botocore.retries.standard - DEBUG - Not retrying request (no retry policy matched)
   ```

5. Demonstrate pagination. Every List/Describe API in AWS is paginated; the SDK hides it only if you ask it to.

   ```bash
   python3 - <<'PY'
   import boto3
   ssm = boto3.client("ssm")

   # WRONG: single page, silently truncated at the service default
   raw = ssm.describe_parameters(MaxResults=10)
   print("single call  :", len(raw["Parameters"]), "next?", "NextToken" in raw)

   # RIGHT: paginator walks every page
   total = 0
   for page in ssm.get_paginator("describe_parameters").paginate(
           PaginationConfig={"PageSize": 10}):
       total += len(page["Parameters"])
   print("paginated    :", total)
   PY
   ```

   ```
   single call  : 10 next? True
   paginated    : 47
   ```

6. Prove the CLI does this for you unless you override it:

   ```bash
   aws ssm describe-parameters --query 'length(Parameters)'
   aws ssm describe-parameters --max-items 10 --query 'length(Parameters)'
   ```

   ```
   47
   10
   ```

### Comprehension check — Block 2

- **Q2.1** — Name the five components of the `Credential=` scope in step 2 and state what each one binds the signature to.
- **Q2.2** — The access key ID begins with `ASIA` rather than `AKIA`, and `x-amz-security-token` appears in `SignedHeaders`. What does this pair of facts prove about the credentials in use, and why is it the state you want in production?
- **Q2.3** — In step 3 the scope changed from `.../s3/aws4_request` to `.../ssm/aws4_request`. If an attacker captured the S3 request in full, could they replay the signature against SSM? Against S3 in `eu-west-1`? Against S3 in `us-east-1` tomorrow? Justify each answer.
- **Q2.4** — `retry_mode` accepts `legacy`, `standard` and `adaptive`. Which one adds client-side rate limiting, and why is it the *wrong* default for a fleet of thousands of clients hitting one throttled API?
- **Q2.5** — In step 5, the non-paginated call returned 10 items and set `NextToken`. Describe the class of production bug this produces in a resource-inventory script, and why it is particularly dangerous in a *deletion* or *compliance* script.
- **Q2.6** — Given that the CLI paginates automatically, what does `--max-items 10` actually do differently from `MaxResults=10` in the raw API?

---

## Exercise 3 — Infrastructure as Code: declarative provisioning with CloudFormation

**Objective:** replace imperative provisioning with a declared desired state, and understand what the service guarantees on your behalf (dependency ordering, rollback, idempotency, drift baseline).

### Steps

1. Write the template. Save as `clf31-stack.yaml`:

   ```yaml
   AWSTemplateFormatVersion: '2010-09-09'
   Description: >-
     CLF-C02 Task 3.1 lab. Declarative provisioning of a versioned, encrypted
     artifact bucket plus its Parameter Store pointer. Demonstrates parameters,
     conditions, intrinsic functions, deletion policies, exports and tagging.

   Metadata:
     AWS::CloudFormation::Interface:
       ParameterGroups:
         - Label:
             default: Deployment context
           Parameters:
             - EnvironmentName
             - BucketNameSuffix

   Parameters:
     EnvironmentName:
       Type: String
       Default: dev
       AllowedValues: [dev, stg, prod]
       Description: Deployment environment. Drives version retention.
     BucketNameSuffix:
       Type: String
       MinLength: 3
       MaxLength: 24
       AllowedPattern: '^[a-z0-9][a-z0-9-]*[a-z0-9]$'
       ConstraintDescription: >-
         Must be 3-24 lowercase alphanumeric characters or hyphens, and must not
         start or end with a hyphen.
       Description: Lowercase suffix appended to the generated bucket name.

   Conditions:
     IsProduction: !Equals [!Ref EnvironmentName, 'prod']

   Resources:
     ArtifactBucket:
       Type: AWS::S3::Bucket
       DeletionPolicy: Delete
       UpdateReplacePolicy: Retain
       Properties:
         BucketName: !Sub '${AWS::AccountId}-${AWS::Region}-${BucketNameSuffix}'
         VersioningConfiguration:
           Status: Enabled
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
         LifecycleConfiguration:
           Rules:
             - Id: expire-noncurrent-versions
               Status: Enabled
               NoncurrentVersionExpiration:
                 NoncurrentDays: !If [IsProduction, 365, 7]
         Tags:
           - Key: Environment
             Value: !Ref EnvironmentName
           - Key: ManagedBy
             Value: CloudFormation
           - Key: ExamObjective
             Value: CLF-C02-3.1

     ArtifactBucketPointer:
       Type: AWS::SSM::Parameter
       Properties:
         Name: !Sub '/${EnvironmentName}/${AWS::StackName}/artifact-bucket'
         Type: String
         Value: !Ref ArtifactBucket
         Description: Physical name of the artifact bucket owned by this stack.

   Outputs:
     ArtifactBucketName:
       Description: Physical name of the artifact bucket.
       Value: !Ref ArtifactBucket
       Export:
         Name: !Sub '${AWS::StackName}-ArtifactBucketName'
     ArtifactBucketArn:
       Description: ARN of the artifact bucket.
       Value: !GetAtt ArtifactBucket.Arn
     RetentionDays:
       Description: Effective non-current version retention, in days.
       Value: !If [IsProduction, '365', '7']
   ```

2. Validate the template **before** spending an API call on a stack operation. `validate-template` is a syntax and intrinsic-function check, not a semantic one:

   ```bash
   aws cloudformation validate-template --template-body file://clf31-stack.yaml
   ```

   ```json
   {
       "Parameters": [
           {
               "ParameterKey": "BucketNameSuffix",
               "NoEcho": false,
               "Description": "Lowercase suffix appended to the generated bucket name."
           },
           {
               "ParameterKey": "EnvironmentName",
               "DefaultValue": "dev",
               "NoEcho": false,
               "Description": "Deployment environment. Drives version retention."
           }
       ],
       "Description": "CLF-C02 Task 3.1 lab. Declarative provisioning of a versioned, encrypted artifact bucket plus its Parameter Store pointer. Demonstrates parameters, conditions, intrinsic functions, deletion policies, exports and tagging.",
       "Capabilities": []
   }
   ```

3. Prove that parameter constraints are enforced **client-of-the-service side**, before any resource is touched. Deliberately violate `AllowedPattern`:

   ```bash
   aws cloudformation create-stack \
     --stack-name "${LAB_PREFIX}-artifacts" \
     --template-body file://clf31-stack.yaml \
     --parameters ParameterKey=BucketNameSuffix,ParameterValue=Bad_Suffix_
   ```

   ```
   An error occurred (ValidationError) when calling the CreateStack operation:
   Parameter 'BucketNameSuffix' must match pattern ^[a-z0-9][a-z0-9-]*[a-z0-9]$
   ```

4. Create the stack for real:

   ```bash
   aws cloudformation create-stack \
     --stack-name "${LAB_PREFIX}-artifacts" \
     --template-body file://clf31-stack.yaml \
     --parameters ParameterKey=BucketNameSuffix,ParameterValue="${LAB_PREFIX}-art" \
                  ParameterKey=EnvironmentName,ParameterValue=dev \
     --tags Key=Owner,Value=platform-eng \
     --on-failure ROLLBACK
   ```

   ```json
   {
       "StackId": "arn:aws:cloudformation:us-east-1:111122223333:stack/clf31-83291-artifacts/6f1c2e80-8a3d-11f1-9e4c-0e5a1b7c9d21"
   }
   ```

5. Block until the stack settles. The waiter polls `DescribeStacks` and exits non-zero on a terminal failure state — this is what a pipeline should call, never `sleep`:

   ```bash
   time aws cloudformation wait stack-create-complete \
     --stack-name "${LAB_PREFIX}-artifacts"
   echo "exit=$?"
   ```

   ```
   real    0m34.812s
   user    0m1.204s
   sys     0m0.163s
   exit=0
   ```

6. Read the ordered event log. This is the dependency graph, resolved:

   ```bash
   aws cloudformation describe-stack-events \
     --stack-name "${LAB_PREFIX}-artifacts" \
     --query 'reverse(StackEvents[].[Timestamp,LogicalResourceId,ResourceStatus])' \
     --output table
   ```

   ```
   ------------------------------------------------------------------------------
   |                            DescribeStackEvents                             |
   +----------------------------+------------------------+----------------------+
   |  2026-09-04T14:41:02.114Z  |  clf31-83291-artifacts |  CREATE_IN_PROGRESS  |
   |  2026-09-04T14:41:06.881Z  |  ArtifactBucket        |  CREATE_IN_PROGRESS  |
   |  2026-09-04T14:41:29.402Z  |  ArtifactBucket        |  CREATE_COMPLETE     |
   |  2026-09-04T14:41:31.775Z  |  ArtifactBucketPointer |  CREATE_IN_PROGRESS  |
   |  2026-09-04T14:41:33.918Z  |  ArtifactBucketPointer |  CREATE_COMPLETE     |
   |  2026-09-04T14:41:35.220Z  |  clf31-83291-artifacts |  CREATE_COMPLETE     |
   +----------------------------+------------------------+----------------------+
   ```

7. Read the outputs, then prove idempotency by re-submitting the identical template:

   ```bash
   aws cloudformation describe-stacks \
     --stack-name "${LAB_PREFIX}-artifacts" \
     --query 'Stacks[0].Outputs' --output table

   aws cloudformation update-stack \
     --stack-name "${LAB_PREFIX}-artifacts" \
     --template-body file://clf31-stack.yaml \
     --parameters ParameterKey=BucketNameSuffix,UsePreviousValue=true \
                  ParameterKey=EnvironmentName,UsePreviousValue=true
   ```

   ```
   ---------------------------------------------------------------------------------------------------------------------
   |                                                  DescribeStacks                                                   |
   +---------------------+-----------------------------------------------+-------------------------------------------+
   |  ArtifactBucketArn  |  arn:aws:s3:::111122223333-us-east-1-clf31-83291-art  | ARN of the artifact bucket.        |
   |  ArtifactBucketName |  111122223333-us-east-1-clf31-83291-art       | Physical name of the artifact bucket.     |
   |  RetentionDays      |  7                                            | Effective non-current version retention.  |
   +---------------------+-----------------------------------------------+-------------------------------------------+
   ```
   ```
   An error occurred (ValidationError) when calling the UpdateStack operation: No updates are to be performed.
   ```

8. Confirm the pointer parameter was created by the stack, not by you:

   ```bash
   aws ssm get-parameter \
     --name "/dev/${LAB_PREFIX}-artifacts/artifact-bucket" \
     --query 'Parameter.Value' --output text
   ```

   ```
   111122223333-us-east-1-clf31-83291-art
   ```

### Comprehension check — Block 3

- **Q3.1** — In step 6 the bucket reached `CREATE_COMPLETE` *before* the SSM parameter was even started, and you never declared a `DependsOn`. What in the template produced that ordering, and what would happen to the ordering if you replaced `Value: !Ref ArtifactBucket` with a hardcoded string?
- **Q3.2** — Step 7 returned `ValidationError: No updates are to be performed`. Is this a failure? Explain what this proves about the CloudFormation execution model and how a CI pipeline must handle this specific exit condition.
- **Q3.3** — The bucket carries `DeletionPolicy: Delete` and `UpdateReplacePolicy: Retain`. Describe a concrete sequence of events where this asymmetry saves you from data loss, and a second sequence where it silently leaves an orphaned, billable resource behind.
- **Q3.4** — Step 3 was rejected in under a second with no stack events at all. At which layer was the `AllowedPattern` enforced, and why does that layer matter more than an equivalent check in your CI linter?
- **Q3.5** — `RetentionDays` is an Output computed by `!If [IsProduction, '365', '7']`, duplicating the logic already inside the lifecycle rule. Name the failure mode this duplication creates, and propose a template change that removes it.
- **Q3.6** — Explain why `Export`ing `ArtifactBucketName` makes this stack *harder* to delete, and what error you would see if another stack imported it.
- **Q3.7** — `validate-template` succeeded on a template that could still fail at deploy time. Give two distinct classes of error that `validate-template` structurally cannot catch.

---

## Exercise 4 — Operating IaC: change sets and drift

**Objective:** the "operating" half of Task Statement 3.1. Provisioning is a one-time act; operating is everything after. Change sets answer *what will this do*; drift detection answers *is reality still what I declared*.

### Steps

1. Modify the template — add a second lifecycle rule that aborts stalled multipart uploads. Insert into `LifecycleConfiguration.Rules`:

   ```yaml
             - Id: abort-incomplete-multipart
               Status: Enabled
               AbortIncompleteMultipartUpload:
                 DaysAfterInitiation: 7
   ```

2. Create a change set instead of updating directly. Nothing is mutated yet:

   ```bash
   aws cloudformation create-change-set \
     --stack-name "${LAB_PREFIX}-artifacts" \
     --change-set-name "add-mpu-abort" \
     --template-body file://clf31-stack.yaml \
     --parameters ParameterKey=BucketNameSuffix,UsePreviousValue=true \
                  ParameterKey=EnvironmentName,UsePreviousValue=true

   aws cloudformation wait change-set-create-complete \
     --stack-name "${LAB_PREFIX}-artifacts" --change-set-name "add-mpu-abort"
   ```

   ```json
   {
       "Id": "arn:aws:cloudformation:us-east-1:111122223333:changeSet/add-mpu-abort/1d0f7a3c-...",
       "StackId": "arn:aws:cloudformation:us-east-1:111122223333:stack/clf31-83291-artifacts/6f1c2e80-..."
   }
   ```

3. Read the plan. `Replacement` is the field that decides whether this is a config change or a rebuild:

   ```bash
   aws cloudformation describe-change-set \
     --stack-name "${LAB_PREFIX}-artifacts" --change-set-name "add-mpu-abort" \
     --query 'Changes[].ResourceChange.[Action,LogicalResourceId,ResourceType,Replacement,join(`,`,Scope)]' \
     --output table
   ```

   ```
   -------------------------------------------------------------------------------
   |                             DescribeChangeSet                               |
   +----------+------------------+---------------------+-------------+-----------+
   |  Modify  |  ArtifactBucket  |  AWS::S3::Bucket    |  False      | Properties|
   +----------+------------------+---------------------+-------------+-----------+
   ```

4. Now create a **second, dangerous** change set to see what a replacement looks like. Change only the parameter value:

   ```bash
   aws cloudformation create-change-set \
     --stack-name "${LAB_PREFIX}-artifacts" \
     --change-set-name "rename-bucket" \
     --use-previous-template \
     --parameters ParameterKey=BucketNameSuffix,ParameterValue="${LAB_PREFIX}-new" \
                  ParameterKey=EnvironmentName,UsePreviousValue=true

   aws cloudformation wait change-set-create-complete \
     --stack-name "${LAB_PREFIX}-artifacts" --change-set-name "rename-bucket"

   aws cloudformation describe-change-set \
     --stack-name "${LAB_PREFIX}-artifacts" --change-set-name "rename-bucket" \
     --query 'Changes[].ResourceChange.[Action,LogicalResourceId,Replacement,join(`,`,Details[].Target.RequiresRecreation)]' \
     --output table
   ```

   ```
   ------------------------------------------------------------------------
   |                          DescribeChangeSet                           |
   +----------+------------------------+------------+--------------------+
   |  Modify  |  ArtifactBucket        |  True      |  Always            |
   |  Modify  |  ArtifactBucketPointer |  False     |  Never             |
   +----------+------------------------+------------+--------------------+
   ```

5. **Discard** the dangerous change set and execute only the safe one:

   ```bash
   aws cloudformation delete-change-set \
     --stack-name "${LAB_PREFIX}-artifacts" --change-set-name "rename-bucket"

   aws cloudformation execute-change-set \
     --stack-name "${LAB_PREFIX}-artifacts" --change-set-name "add-mpu-abort"

   aws cloudformation wait stack-update-complete --stack-name "${LAB_PREFIX}-artifacts"
   echo "exit=$?"
   ```

   ```
   exit=0
   ```

6. Now introduce **drift** — mutate the resource outside CloudFormation, exactly as an on-call engineer would at 3 a.m.:

   ```bash
   BUCKET=$(aws cloudformation describe-stacks \
     --stack-name "${LAB_PREFIX}-artifacts" \
     --query 'Stacks[0].Outputs[?OutputKey==`ArtifactBucketName`].OutputValue' --output text)

   aws s3api put-bucket-tagging --bucket "${BUCKET}" --tagging \
     'TagSet=[{Key=Environment,Value=dev},{Key=ManagedBy,Value=human-at-3am},{Key=ExamObjective,Value=CLF-C02-3.1}]'
   ```

7. Detect the drift. Note that detection is **asynchronous** — you get a token, not a result:

   ```bash
   DID=$(aws cloudformation detect-stack-drift \
     --stack-name "${LAB_PREFIX}-artifacts" \
     --query StackDriftDetectionId --output text)

   until [ "$(aws cloudformation describe-stack-drift-detection-status \
           --stack-drift-detection-id "$DID" \
           --query DetectionStatus --output text)" != "DETECTION_IN_PROGRESS" ]; do
     sleep 3
   done

   aws cloudformation describe-stack-drift-detection-status \
     --stack-drift-detection-id "$DID"
   ```

   ```json
   {
       "StackId": "arn:aws:cloudformation:us-east-1:111122223333:stack/clf31-83291-artifacts/6f1c2e80-...",
       "StackDriftDetectionId": "b4e9f012-8a41-11f1-a7d2-0e5a1b7c9d21",
       "StackDriftStatus": "DRIFTED",
       "DetectionStatus": "DETECTION_COMPLETE",
       "DriftedStackResourceCount": 1,
       "Timestamp": "2026-09-04T15:03:44.117Z"
   }
   ```

8. Get the property-level diff:

   ```bash
   aws cloudformation describe-stack-resource-drifts \
     --stack-name "${LAB_PREFIX}-artifacts" \
     --stack-resource-drift-status-filters MODIFIED \
     --query 'StackResourceDrifts[].PropertyDifferences[].[PropertyPath,ExpectedValue,ActualValue,DifferenceType]' \
     --output table
   ```

   ```
   ---------------------------------------------------------------------------------
   |                        DescribeStackResourceDrifts                            |
   +-------------------+------------------+-------------------+------------------+
   |  /Tags/1/Value    |  CloudFormation  |  human-at-3am     |  NOT_EQUAL       |
   +-------------------+------------------+-------------------+------------------+
   ```

9. Remediate by re-asserting the declared state:

   ```bash
   aws cloudformation update-stack \
     --stack-name "${LAB_PREFIX}-artifacts" --use-previous-template \
     --parameters ParameterKey=BucketNameSuffix,UsePreviousValue=true \
                  ParameterKey=EnvironmentName,UsePreviousValue=true
   ```

   ```
   An error occurred (ValidationError) when calling the UpdateStack operation: No updates are to be performed.
   ```

### Comprehension check — Block 4

- **Q4.1** — In step 4, changing `BucketNameSuffix` produced `Replacement: True` with `RequiresRecreation: Always` on the bucket, but `Replacement: False` on the SSM parameter that *references* it. Explain both results.
- **Q4.2** — What would executing the `rename-bucket` change set have done to the data in the original bucket, given the `DeletionPolicy`/`UpdateReplacePolicy` pair from Exercise 3? Trace it precisely.
- **Q4.3** — Step 9 refused to remediate the drift with `No updates are to be performed`. Explain why CloudFormation considers the stack already up to date despite `StackDriftStatus: DRIFTED`, and give two working remediation strategies.
- **Q4.4** — Drift detection reported `DriftedStackResourceCount: 1`. You changed one tag on one bucket. What does CloudFormation *not* look at when computing drift, and name one category of out-of-band change it will report as `IN_SYNC` anyway.
- **Q4.5** — Why is `detect-stack-drift` asynchronous and token-based rather than returning the answer inline? What does that imply about running it on a 400-resource stack in a pipeline?
- **Q4.6** — Your organization mandates "no direct `update-stack` in production; change sets only." Name the two concrete risks this policy eliminates, using evidence from steps 3 and 4.

---

## Exercise 5 — Failure modes and diagnostics

**Objective:** an engineer who can only read green stacks cannot operate. You will deliberately break a stack and diagnose it from the API.

### Steps

1. Append a deliberately invalid resource to `clf31-stack.yaml`. S3 bucket names may not contain underscores:

   ```yaml
     BrokenBucket:
       Type: AWS::S3::Bucket
       Properties:
         BucketName: !Sub '${AWS::StackName}_invalid_name'
   ```

2. Attempt the update and let it fail:

   ```bash
   aws cloudformation update-stack \
     --stack-name "${LAB_PREFIX}-artifacts" \
     --template-body file://clf31-stack.yaml \
     --parameters ParameterKey=BucketNameSuffix,UsePreviousValue=true \
                  ParameterKey=EnvironmentName,UsePreviousValue=true

   aws cloudformation wait stack-update-complete --stack-name "${LAB_PREFIX}-artifacts"
   echo "waiter exit=$?"
   ```

   ```
   Waiter StackUpdateComplete failed: Waiter encountered a terminal failure state:
   For expression "Stacks[].StackStatus" we matched expected path: "UPDATE_ROLLBACK_COMPLETE" at least once
   waiter exit=255
   ```

3. Find the *first* failure — not the last. The last event is almost always a cascade symptom:

   ```bash
   aws cloudformation describe-stack-events \
     --stack-name "${LAB_PREFIX}-artifacts" \
     --query 'reverse(StackEvents[?ResourceStatus==`CREATE_FAILED` || ResourceStatus==`UPDATE_FAILED`].[Timestamp,LogicalResourceId,ResourceStatusReason])' \
     --output text | head -1
   ```

   ```
   2026-09-04T15:19:08.442Z	BrokenBucket	Resource handler returned message: "Bucket name should not contain '_'" (RequestToken: 3c9f..., HandlerErrorCode: InvalidRequest)
   ```

4. Confirm the stack rolled back to a *working* state, and that your good resources survived:

   ```bash
   aws cloudformation describe-stacks --stack-name "${LAB_PREFIX}-artifacts" \
     --query 'Stacks[0].[StackStatus,StackStatusReason]' --output text

   aws cloudformation list-stack-resources --stack-name "${LAB_PREFIX}-artifacts" \
     --query 'StackResourceSummaries[].[LogicalResourceId,ResourceStatus]' --output table
   ```

   ```
   UPDATE_ROLLBACK_COMPLETE	The following resource(s) failed to create: [BrokenBucket]. Rollback requested by user.
   ```
   ```
   --------------------------------------------------------
   |                 ListStackResources                   |
   +--------------------------+---------------------------+
   |  ArtifactBucket          |  UPDATE_COMPLETE          |
   |  ArtifactBucketPointer   |  UPDATE_COMPLETE          |
   +--------------------------+---------------------------+
   ```

5. Repeat the failure with rollback disabled, so the failed resource stays for inspection:

   ```bash
   aws cloudformation update-stack \
     --stack-name "${LAB_PREFIX}-artifacts" \
     --template-body file://clf31-stack.yaml \
     --disable-rollback \
     --parameters ParameterKey=BucketNameSuffix,UsePreviousValue=true \
                  ParameterKey=EnvironmentName,UsePreviousValue=true

   aws cloudformation describe-stacks --stack-name "${LAB_PREFIX}-artifacts" \
     --query 'Stacks[0].StackStatus' --output text
   ```

   ```
   UPDATE_FAILED
   ```

6. Recover from `UPDATE_FAILED` and return the stack to a stable state:

   ```bash
   aws cloudformation rollback-stack --stack-name "${LAB_PREFIX}-artifacts"
   aws cloudformation wait stack-rollback-complete --stack-name "${LAB_PREFIX}-artifacts"
   aws cloudformation describe-stacks --stack-name "${LAB_PREFIX}-artifacts" \
     --query 'Stacks[0].StackStatus' --output text
   ```

   ```
   UPDATE_ROLLBACK_COMPLETE
   ```

7. Remove the `BrokenBucket` block from the template before continuing.

### Comprehension check — Block 5

- **Q5.1** — Step 2's waiter exited `255`, not `0` and not `1`. Why does a pipeline that runs `aws cloudformation update-stack` *without* a waiter appear to succeed even when the deployment fails?
- **Q5.2** — Step 3 sorted events and took the **first** failure. Explain, in terms of how CloudFormation propagates failure, why the chronologically last `*_FAILED` event is usually useless for diagnosis.
- **Q5.3** — Contrast `ROLLBACK_COMPLETE` (from a failed `create-stack`) with `UPDATE_ROLLBACK_COMPLETE` (from a failed `update-stack`). One of these two states cannot be updated — which one, and what is the only legal operation on it?
- **Q5.4** — Give a concrete scenario where `--disable-rollback` is the correct production choice, and one where it is a serious mistake.
- **Q5.5** — In step 4, `ArtifactBucket` shows `UPDATE_COMPLETE` after a *failed* update. What guarantee does CloudFormation provide about the state of untouched resources during a rollback, and what is the well-known exception to it (hint: think about a resource whose rollback itself fails)?
- **Q5.6** — Your stack is stuck in `UPDATE_ROLLBACK_FAILED`. Name the specific API operation designed for this state and the flag it accepts to skip resources that cannot be rolled back.

---

## Exercise 6 — Deployment models: cloud, hybrid, on-premises

**Objective:** map the three deployment models named in the exam guide onto the concrete AWS services that implement each, then verify the edge footprint of a Region with read-only calls.

### Steps

1. Enumerate every zone type in a Region. `availability-zone` is classic in-Region; anything else is an edge/hybrid construct:

   ```bash
   aws ec2 describe-availability-zones --all-availability-zones \
     --region us-east-1 \
     --query "AvailabilityZones[].[ZoneName,ZoneType,ParentZoneName,OptInStatus]" \
     --output table
   ```

   ```
   ----------------------------------------------------------------------------------
   |                          DescribeAvailabilityZones                             |
   +-------------------+---------------------+---------------+--------------------+
   |  us-east-1a       |  availability-zone   |  None         |  opt-in-not-required|
   |  us-east-1b       |  availability-zone   |  None         |  opt-in-not-required|
   |  us-east-1c       |  availability-zone   |  None         |  opt-in-not-required|
   |  us-east-1d       |  availability-zone   |  None         |  opt-in-not-required|
   |  us-east-1e       |  availability-zone   |  None         |  opt-in-not-required|
   |  us-east-1f       |  availability-zone   |  None         |  opt-in-not-required|
   |  us-east-1-atl-1a |  local-zone          |  us-east-1    |  not-opted-in      |
   |  us-east-1-bos-1a |  local-zone          |  us-east-1    |  not-opted-in      |
   |  us-east-1-chi-2a |  local-zone          |  us-east-1    |  not-opted-in      |
   |  us-east-1-dfw-2a |  local-zone          |  us-east-1    |  not-opted-in      |
   |  us-east-1-mia-1a |  local-zone          |  us-east-1    |  not-opted-in      |
   |  us-east-1-nyc-1a |  local-zone          |  us-east-1    |  not-opted-in      |
   |  us-east-1-wl1-atl-wlz-1 |  wavelength-zone |  us-east-1 |  not-opted-in      |
   |  us-east-1-wl1-bos-wlz-1 |  wavelength-zone |  us-east-1 |  not-opted-in      |
   |  us-east-1-wl1-nyc-wlz-1 |  wavelength-zone |  us-east-1 |  not-opted-in      |
   +-------------------+---------------------+---------------+--------------------+
   ```

2. Count each type, so the ratio is explicit:

   ```bash
   aws ec2 describe-availability-zones --all-availability-zones --region us-east-1 \
     --query "AvailabilityZones[].ZoneType" --output text | tr '\t' '\n' | sort | uniq -c
   ```

   ```
        6 availability-zone
        6 local-zone
        3 wavelength-zone
   ```

3. Check whether any Outposts are registered to this account (an Outpost is on-premises hardware running the AWS control plane):

   ```bash
   aws outposts list-outposts --region us-east-1
   ```

   ```json
   {
       "Outposts": []
   }
   ```

4. Inspect the on-premises data-movement services that make a hybrid model real. `describe-locations` is free and shows where you could physically cross-connect:

   ```bash
   aws datasync list-locations --region us-east-1 --query 'Locations[].LocationUri'
   aws storagegateway list-gateways --region us-east-1 --query 'Gateways[].[GatewayName,GatewayType,GatewayOperationalState]' --output table
   ```

   ```json
   []
   ```
   ```
   ---------------------------------------------
   |               ListGateways                |
   +-------------------------------------------+
   ```

5. Build the model↔service map yourself before reading the answers. Fill in this table:

   | Deployment model | Where the workload runs | Where the AWS control plane runs | Representative services |
   |---|---|---|---|
   | Cloud (cloud-native) | ? | ? | ? |
   | Hybrid | ? | ? | ? |
   | On-premises (private cloud) | ? | ? | ? |

### Comprehension check — Block 6

- **Q6.1** — A Local Zone and a Wavelength Zone both appear in `describe-availability-zones` with `ParentZoneName: us-east-1`. What does that parent relationship mean operationally, and what is the single primary differentiator between the two zone types in terms of *who the traffic comes from*?
- **Q6.2** — Every non-`availability-zone` entry shows `OptInStatus: not-opted-in`. What does opting in actually change, and why did AWS make it opt-in rather than default-on?
- **Q6.3** — A regulator requires that a specific dataset never physically leaves your Frankfurt datacenter, but the team wants to use the same EC2 API, the same IAM policies and the same CloudFormation templates as the rest of the estate. Which deployment model and which specific service satisfies this? What is the one thing you must still provision yourself?
- **Q6.4** — Classify each of the following as cloud, hybrid, or on-premises, and justify: (a) a Storage Gateway File Gateway appliance in a branch office caching to S3; (b) an EKS cluster with all nodes in `us-east-1`; (c) EKS Anywhere on your own vSphere; (d) an application on EC2 in `us-east-1` reading a database over Direct Connect from your own datacenter.
- **Q6.5** — Why does an Outpost still require a reliable network link back to its parent Region, and what specifically degrades if that link is severed for six hours?

---

## Exercise 7 — Connectivity: public internet, VPN, Direct Connect

**Objective:** the third knowledge area of Task Statement 3.1. Build the decision matrix from data the APIs actually return, not from marketing pages.

### Steps

1. List Direct Connect locations — these are the physical colocation facilities where a cross-connect is possible:

   ```bash
   aws directconnect describe-locations --region us-east-1 \
     --query 'locations[0:6].[locationCode,locationName,availablePortSpeeds[*]|join(`,`,@)]' \
     --output table
   ```

   ```
   -----------------------------------------------------------------------------------------------
   |                                     DescribeLocations                                       |
   +--------------+--------------------------------------------------+-------------------------+
   |  EqDC2       |  Equinix DC2/DC11, Ashburn, VA                    |  1Gbps,10Gbps,100Gbps   |
   |  CSDC1       |  CoreSite DC1, Washington, DC                     |  1Gbps,10Gbps           |
   |  EqNY5       |  Equinix NY5, Secaucus, NJ                        |  1Gbps,10Gbps,100Gbps   |
   |  DA1         |  Digital Realty ATL, Atlanta, GA                  |  1Gbps,10Gbps           |
   |  TerreNAP    |  TierPoint Miami, Miami, FL                       |  1Gbps,10Gbps           |
   |  EqCH2       |  Equinix CH2, Chicago, IL                         |  1Gbps,10Gbps,100Gbps   |
   +--------------+--------------------------------------------------+-------------------------+
   ```

2. Confirm you have no existing Direct Connect or VPN infrastructure (all read-only, all free):

   ```bash
   aws directconnect describe-connections --query 'connections[].[connectionId,connectionState,bandwidth]' --output table
   aws directconnect describe-virtual-interfaces --query 'virtualInterfaces[].[virtualInterfaceId,virtualInterfaceType,virtualInterfaceState]' --output table
   aws ec2 describe-vpn-connections --query 'VpnConnections[].[VpnConnectionId,State,Type]' --output table
   aws ec2 describe-vpn-gateways --query 'VpnGateways[].[VpnGatewayId,State,AmazonSideAsn]' --output table
   ```

   ```
   ------------------
   |DescribeConnections|
   +----------------+
   ```

3. Create a **Customer Gateway** — the AWS-side representation of *your* on-premises router. This resource is free; the VPN connection that would consume it is not, so we stop here:

   ```bash
   aws ec2 create-customer-gateway \
     --type ipsec.1 \
     --bgp-asn 65001 \
     --ip-address 203.0.113.12 \
     --tag-specifications "ResourceType=customer-gateway,Tags=[{Key=Name,Value=${LAB_PREFIX}-cgw}]" \
     --query 'CustomerGateway.[CustomerGatewayId,Type,BgpAsn,IpAddress,State]' --output table
   ```

   ```
   ---------------------------------------------------------------------
   |                      CreateCustomerGateway                        |
   +---------------------+----------+---------+----------------+-------+
   |  cgw-0a1b2c3d4e5f6a7b8 | ipsec.1 |  65001 |  203.0.113.12  | available |
   +---------------------+----------+---------+----------------+-------+
   ```

4. Observe what the CGW does **not** contain — no encryption keys, no tunnel endpoints, no routes. Those materialize only when a VPN connection is created:

   ```bash
   aws ec2 describe-customer-gateways \
     --filters "Name=tag:Name,Values=${LAB_PREFIX}-cgw" \
     --query 'CustomerGateways[0]'
   ```

   ```json
   {
       "BgpAsn": "65001",
       "CustomerGatewayId": "cgw-0a1b2c3d4e5f6a7b8",
       "IpAddress": "203.0.113.12",
       "State": "available",
       "Type": "ipsec.1",
       "Tags": [
           { "Key": "Name", "Value": "clf31-83291-cgw" }
       ]
   }
   ```

5. Measure the *public internet* path for comparison. A regional S3 endpoint is a fair proxy for internet-sourced latency and its variance:

   ```bash
   for i in 1 2 3 4 5; do
     curl -o /dev/null -s -w "attempt %{http_code}  dns=%{time_namelookup}s  tls=%{time_appconnect}s  total=%{time_total}s\n" \
       https://s3.us-east-1.amazonaws.com/
   done
   ```

   ```
   attempt 307  dns=0.021s  tls=0.118s  total=0.142s
   attempt 307  dns=0.001s  tls=0.094s  total=0.109s
   attempt 307  dns=0.001s  tls=0.221s  total=0.243s
   attempt 307  dns=0.001s  tls=0.097s  total=0.112s
   attempt 307  dns=0.001s  tls=0.089s  total=0.104s
   ```

6. Complete this matrix from what you observed and from the cited documentation:

   | Attribute | Public internet | Site-to-Site VPN | Direct Connect |
   |---|---|---|---|
   | Underlying transport | ? | ? | ? |
   | Encryption in transit | ? | ? | ? |
   | Latency consistency | ? | ? | ? |
   | Provisioning lead time | ? | ? | ? |
   | Typical bandwidth ceiling per link | ? | ? | ? |
   | Cost model | ? | ? | ? |
   | Failure domain / HA pattern | ? | ? | ? |

7. Clean up the Customer Gateway:

   ```bash
   CGW=$(aws ec2 describe-customer-gateways \
     --filters "Name=tag:Name,Values=${LAB_PREFIX}-cgw" "Name=state,Values=available" \
     --query 'CustomerGateways[0].CustomerGatewayId' --output text)
   aws ec2 delete-customer-gateway --customer-gateway-id "$CGW"
   ```

### Comprehension check — Block 7

- **Q7.1** — In step 5, `time_total` ranged from 0.104 s to 0.243 s — a 2.3× spread over five identical requests on an idle link. Which specific property of the public internet produces that spread, and which of the three connectivity options is purchased specifically to eliminate it?
- **Q7.2** — The Customer Gateway in step 4 has no encryption material at all. Where do the IPsec pre-shared keys and the two tunnel outside-IP addresses come from, and how many tunnels does a single AWS Site-to-Site VPN connection provide by default?
- **Q7.3** — You provisioned a single 10 Gbps Direct Connect at `EqDC2`. Your architecture review rejects it. What is the failure domain that reviewer is worried about, and what is the minimum change that addresses it while keeping the same total bandwidth?
- **Q7.4** — Direct Connect is frequently described as "private". Is a Direct Connect connection *encrypted* by default? What is the standard remedy, and what does it cost you architecturally?
- **Q7.5** — A team needs 40 TB moved from a datacenter to S3 within one week, and has a 200 Mbps internet link with no Direct Connect. Compute the raw transfer time at 100% utilization, then name the AWS service designed for exactly this situation and the model it belongs to.
- **Q7.6** — Rank public internet, VPN and Direct Connect by *time to first packet* (how fast you can go from zero to a working link). Explain why this ranking is often the deciding factor in a migration, and how the two slower options are commonly combined during the gap.

---

## Exercise 8 — Choosing the operating abstraction

**Objective:** "methods of operating" is not only IaC. It is the choice of how much of the stack you agree to run yourself. Task Statement 3.1 expects you to place the managed deployment services on that spectrum.

### Steps

1. Enumerate the Elastic Beanstalk platforms available — each one is a fully managed provisioning + operating bundle:

   ```bash
   aws elasticbeanstalk list-platform-versions \
     --filters 'Type=PlatformStatus,Operator==,Values=Ready' \
     --query 'PlatformSummaryList[0:8].[PlatformBranchName,PlatformVersion,OperatingSystemName]' \
     --output table
   ```

   ```
   ----------------------------------------------------------------------------
   |                        ListPlatformVersions                              |
   +----------------------------------+-----------+---------------------------+
   |  Python 3.12 running on 64bit AL2023 |  4.3.1 |  Amazon Linux             |
   |  Docker running on 64bit AL2023      |  4.3.1 |  Amazon Linux             |
   |  Corretto 21 running on 64bit AL2023 |  4.3.1 |  Amazon Linux             |
   |  Node.js 20 running on 64bit AL2023  |  6.4.2 |  Amazon Linux             |
   |  .NET 8 running on 64bit AL2023      |  3.1.4 |  Amazon Linux             |
   |  PHP 8.3 running on 64bit AL2023     |  4.3.1 |  Amazon Linux             |
   |  Go 1 running on 64bit AL2023        |  4.3.1 |  Amazon Linux             |
   |  Ruby 3.3 running on 64bit AL2023    |  4.3.1 |  Amazon Linux             |
   +----------------------------------+-----------+---------------------------+
   ```

2. Note that Beanstalk is itself a CloudFormation client — inspect what it would create. List the resource types it manages for a load-balanced web tier:

   ```bash
   aws elasticbeanstalk describe-configuration-options \
     --solution-stack-name "64bit Amazon Linux 2023 v4.3.1 running Python 3.12" \
     --query 'Options[?Namespace==`aws:autoscaling:asg`].[Name,DefaultValue]' \
     --output table
   ```

   ```
   -------------------------------------------------
   |         DescribeConfigurationOptions          |
   +-------------------------+---------------------+
   |  Availability Zones     |  Any                |
   |  Cooldown               |  360                |
   |  Custom Availability Zones |  None            |
   |  MaxSize                |  4                  |
   |  MinSize                |  1                  |
   +-------------------------+---------------------+
   ```

3. Confirm that Systems Manager is the *operating* plane once resources exist — list what it offers without launching anything:

   ```bash
   aws ssm describe-instance-information \
     --query 'InstanceInformationList[].[InstanceId,PingStatus,PlatformName,AgentVersion]' --output table

   aws ssm list-documents \
     --filters "Key=Owner,Values=Amazon" "Key=DocumentType,Values=Command" \
     --query 'DocumentIdentifiers[?starts_with(Name, `AWS-Run`)].Name' --output text | tr '\t' '\n' | head -6
   ```

   ```
   -----------------------------
   |DescribeInstanceInformation|
   +---------------------------+
   ```
   ```
   AWS-RunPatchBaseline
   AWS-RunPatchBaselineAssociation
   AWS-RunPatchBaselineWithHooks
   AWS-RunPowerShellScript
   AWS-RunRemoteScript
   AWS-RunShellScript
   ```

4. Place each of these on the abstraction spectrum, from "you operate everything" to "you operate nothing":

   `EC2 with a shell script` · `EC2 + Systems Manager` · `CloudFormation` · `Elastic Beanstalk` · `ECS on EC2` · `ECS on Fargate` · `Lambda`

### Comprehension check — Block 8

- **Q8.1** — Elastic Beanstalk provisions your environment *by generating a CloudFormation stack*. Given that, what does Beanstalk add that raw CloudFormation does not, and what does it take away?
- **Q8.2** — Order the seven items in step 4 by decreasing operational responsibility on your side. For each adjacent pair, name the one specific responsibility that transfers to AWS at that step.
- **Q8.3** — `AWS-RunShellScript` lets you execute arbitrary commands on an instance with no SSH port, no bastion and no key pair. Name the three components that make this possible and explain why this is an *operating method* improvement rather than just a convenience.
- **Q8.4** — A team proposes running `AWS-RunShellScript` across the fleet to apply a config change. You object. State the objection in terms of the concepts from Exercise 4, and name the correct mechanism.
- **Q8.5** — Beanstalk's default `MaxSize` is 4 and `MinSize` is 1. What does it mean, in shared-responsibility terms, that AWS chose those defaults for you — and what is the risk of accepting a managed service's defaults in production?

---

## Cleanup

Run this in order. Verify each step; do not assume.

```bash
# 1. Empty the versioned bucket (a versioned bucket cannot be deleted while objects
#    or delete markers remain, and CloudFormation will not empty it for you).
BUCKET=$(aws cloudformation describe-stacks --stack-name "${LAB_PREFIX}-artifacts" \
  --query 'Stacks[0].Outputs[?OutputKey==`ArtifactBucketName`].OutputValue' --output text)
aws s3api delete-objects --bucket "$BUCKET" --delete "$(aws s3api list-object-versions \
  --bucket "$BUCKET" --query '{Objects: [].{Key:Key,VersionId:VersionId}}' \
  --output json)" 2>/dev/null || echo "bucket already empty"

# 2. Delete the stack (removes bucket + SSM pointer).
aws cloudformation delete-stack --stack-name "${LAB_PREFIX}-artifacts"
aws cloudformation wait stack-delete-complete --stack-name "${LAB_PREFIX}-artifacts"
echo "stack delete exit=$?"

# 3. Delete the three hand-made SSM parameters from Exercise 1.
aws ssm delete-parameters --names \
  "/${LAB_PREFIX}/origin/cli" "/${LAB_PREFIX}/origin/sdk" "/${LAB_PREFIX}/origin/console"

# 4. Confirm nothing is left.
aws cloudformation describe-stacks --stack-name "${LAB_PREFIX}-artifacts" 2>&1 | tail -1
aws ssm get-parameters-by-path --path "/${LAB_PREFIX}" --recursive --query 'length(Parameters)'
aws ec2 describe-customer-gateways \
  --filters "Name=tag:Name,Values=${LAB_PREFIX}-cgw" "Name=state,Values=available" \
  --query 'length(CustomerGateways)'
```

```
stack delete exit=0
An error occurred (ValidationError) when calling the DescribeStacks operation: Stack with id clf31-83291-artifacts does not exist
0
0
```

> Note: a deleted Customer Gateway remains visible with `State: deleted` for a period. Filtering on `state=available` is what makes step 4's check meaningful.

---

<details>
<summary><strong>Answers</strong></summary>

### Block 1 — The four interfaces are one interface

**A1.1** — There is no architectural distinction. The Console, the CLI and every SDK are all HTTPS clients of the same public service API; none of them has a private channel. The Console is a web application that calls `ssm:PutParameter` on your behalf; the CLI is `botocore` wrapping the same call; boto3 is that same `botocore`. Because the service API is the only entry point, `eventSource` and `eventName` are necessarily identical. The practical consequence is that **every** permission model, quota, throttle and audit hook applies uniformly — an IAM `Deny` on `ssm:PutParameter` blocks the Console exactly as it blocks a script, because there is nothing else to block.

**A1.2** — Your browser does not talk to `ssm.amazonaws.com`. It talks to the Console's own web tier, which then assumes/uses your session's credentials and issues the SigV4-signed API call from AWS-managed infrastructure. CloudTrail records the user agent of the process that actually made the signed call, which is that Console backend — hence `AWS Internal` (older records may show `console.amazonaws.com` or `signin.amazonaws.com` for related events). Your browser's user agent never reaches the SSM service, so it cannot appear.

**A1.3** — Refute it. Step 7 shows identical `eventSource`, `eventName`, `readOnly` and `managementEvent` for all three. A CloudTrail-based audit strategy that covers the API covers the Console by construction, because the Console *is* an API client. What differs is only metadata (`userAgent`, `sessionContext`), which is exactly what you'd use to *distinguish* the origin — not a reason to build a second audit pipeline. The colleague's mental model would lead to the dangerous inverse error: believing that blocking Console access blocks the action.

**A1.4** — `userAgent`. The predicate is roughly: alert when `eventName` is a mutating production action **AND** `userAgent` does **not** match your automation's signature — i.e. is neither `cloudformation.amazonaws.com` (the change came through IaC) nor your pipeline's configured user-agent string. A hand-made Console change surfaces as `AWS Internal`; an engineer's laptop surfaces as `aws-cli/...`. Harden it by pairing with `sessionContext.sessionIssuer.userName` so a compromised pipeline role cannot simply spoof the string. Note that `userAgent` is client-supplied and therefore advisory — treat it as a drift signal, not a security control.

**A1.5** — Highest to lowest: (1) command-line flags such as `--region` / `--profile`; (2) environment variables (`AWS_REGION`, `AWS_DEFAULT_REGION`, `AWS_ACCESS_KEY_ID`, …); (3) the CLI credentials file `~/.aws/credentials`; (4) the CLI config file `~/.aws/config`; (5) container credentials (ECS/EKS task role); (6) instance metadata (IMDS / EC2 instance profile). A `--region` flag sits at the very top and overrides everything, which is why `aws configure list` showed `Type: env` — no flag was passed, so the environment variable won.

### Block 2 — Programmatic access

**A2.1** — `ASIA4EXAMPLEKEYID/20260904/us-east-1/s3/aws4_request`:
1. **Access key ID** — identifies the principal whose secret derived the signing key.
2. **Date (`YYYYMMDD`, UTC)** — binds the signature to a single UTC day; combined with the mandatory `x-amz-date` header and the service's ±5-minute clock skew tolerance, this bounds replay.
3. **Region** — binds it to `us-east-1`.
4. **Service** — binds it to `s3`.
5. **`aws4_request`** — a fixed terminator string identifying the SigV4 signing scheme version.
The signing key is derived by chained HMAC over exactly these components, so a signature is unusable outside its scope.

**A2.2** — `ASIA` is the prefix for a temporary STS access key, and `x-amz-security-token` carries the accompanying session token; a permanent IAM user key would be `AKIA` with no session token. Together they prove the caller is on **short-lived, automatically-rotating credentials** — from IAM Identity Center, an assumed role, or an instance/task profile. This is the production target state because the blast radius of a leak is bounded by the session lifetime (typically 1–12 hours) rather than being indefinite, and there is no static secret to store, rotate or accidentally commit.

**A2.3** — All three replays fail.
- *Against SSM*: no. The service is inside the credential scope; the signing key derived for `s3` cannot validate a request to `ssm`.
- *Against S3 in `eu-west-1`*: no. The Region is inside the scope.
- *Against S3 in `us-east-1` tomorrow*: no, on two independent grounds — the date is inside the scope, and `x-amz-date` must be within the service's clock-skew window (about 5 minutes), so the request is rejected as expired long before the day rolls over.
Note that within scope and within the skew window, a captured request *is* replayable verbatim — which is precisely why the whole exchange runs over TLS and why the credentials are short-lived.

**A2.4** — `adaptive`. It adds a client-side rate limiter that learns from throttling responses and slows the client down pre-emptively. It is the wrong default at fleet scale because each client learns *independently* from its own observations, with no coordination: a shared, throttled API gets N uncoordinated limiters that can converge badly, and one client's backoff creates headroom that another client immediately consumes. `adaptive` is designed for a small number of high-volume clients that dominate a quota, not for a wide fleet. `standard` — bounded exponential backoff with jitter and a fixed attempt cap — is the correct fleet default.

**A2.5** — It produces **silent truncation**: the script returns a syntactically valid, plausible-looking result that is simply incomplete, with no error, no warning and no non-zero exit. In an inventory or compliance script this means "I checked everything and found no violations" when you checked the first page. In a deletion script it is worse in the opposite direction — you delete only the first page and report success, leaving billable orphans; or, if the script re-runs to convergence, you get an infinite loop. The pathology is that correctness degrades exactly when the environment grows past the page size, so it works perfectly in dev and fails in production.

**A2.6** — `MaxResults` is a **server-side page size**: it tells the service how many items to put in one response, and the service returns a `NextToken` for the rest. `--max-items` is a **client-side total cap**: the CLI keeps paginating internally but stops handing you items once the total is reached, and emits a `NextToken` in its output for you to resume. They can be combined — `--page-size` maps to the server-side `MaxResults`, `--max-items` caps the aggregate. Using `--max-items` does not reduce the number of API calls per item retrieved; `--page-size` does.

### Block 3 — Infrastructure as Code

**A3.1** — `!Ref ArtifactBucket` inside `ArtifactBucketPointer` creates an **implicit dependency**. CloudFormation builds a directed acyclic graph from every intrinsic function reference (`Ref`, `GetAtt`, `Sub` with a resource token, `DependsOn`) and orders creation topologically; it cannot resolve `!Ref ArtifactBucket` into a physical bucket name until the bucket exists, so the parameter necessarily waits. Replacing it with a hardcoded string would sever the edge, the two resources would become independent nodes, and CloudFormation would create them **in parallel** — which is precisely how you get a Parameter Store entry pointing at a bucket name that does not exist yet, or that a failed rollback never created.

**A3.2** — Not a failure — it is the proof of **idempotency**. CloudFormation compares the submitted template plus resolved parameters against the stack's current template; identical input means the desired state is already satisfied, so there is nothing to do. The trap is that the CLI signals this with a non-zero exit and a `ValidationError`, indistinguishable at the shell level from a genuine error. A CI pipeline must special-case it: capture stderr, and if it matches `No updates are to be performed`, treat the step as success and skip the waiter (there is no stack event to wait for). Using `aws cloudformation deploy` instead of `create-stack`/`update-stack` handles this natively — it exits 0 on a no-op — which is the better answer.

**A3.3** — *Saves you*: someone submits a change to `BucketNameSuffix`. `UpdateReplacePolicy: Retain` means CloudFormation creates the new bucket, updates the stack to point at it, and **leaves the old bucket and all its objects in place**. Your data survives an accidental rename.
*Costs you*: that same event leaves a bucket that no stack owns, that no template describes, that drift detection will never look at, and that you keep paying for — invisible until someone audits S3 by hand. The asymmetry is a deliberate trade of *cost and tidiness* for *data safety*; it is the right default for stateful resources, but it obliges you to run an orphan-detection sweep (e.g. Config, or a tag-based inventory) as a compensating control.

**A3.4** — At the **CloudFormation service layer**, before the stack transaction opened — hence sub-second, no `StackId`, no events. This matters more than a CI linter because it is unbypassable: it applies to a Console deploy, a manual CLI call, a StackSet rollout and a third-party tool alike, whereas a CI check protects exactly one code path and any engineer with the right IAM permission can go around it. Constraints belong in the artifact, not in the pipeline that happens to ship it.

**A3.5** — The failure mode is **divergence between the declared behaviour and the reported behaviour**. Someone edits the lifecycle rule to `!If [IsProduction, 730, 7]` and forgets the Output; the stack now retains versions for 730 days while every dashboard, runbook and downstream stack that reads `RetentionDays` reports 365. Nothing fails, nothing drifts — the *description* of the system silently becomes a lie.
Fix: introduce a `Mappings` block keyed by environment, reference it once from each place, and let both the resource and the Output resolve from the same source:
```yaml
Mappings:
  RetentionByEnv:
    dev:  { NoncurrentDays: 7 }
    stg:  { NoncurrentDays: 30 }
    prod: { NoncurrentDays: 365 }
```
then `NoncurrentDays: !FindInMap [RetentionByEnv, !Ref EnvironmentName, NoncurrentDays]` in both locations. The literal is now stated once.

**A3.6** — An `Export` publishes a value into the Region's account-wide export namespace. CloudFormation refuses to delete a stack, or to modify an exported output, while **any** other stack holds a live `Fn::ImportValue` on it — this is a hard dependency lock, not a warning. Attempting the delete yields:
```
An error occurred (ValidationError) when calling the DeleteStack operation:
Export clf31-83291-artifacts-ArtifactBucketName cannot be deleted as it is in use by consumer-stack
```
You must delete or update the consumer first. This is why cross-stack references at scale are often built on SSM Parameter Store lookups instead — they give you the same indirection without the deletion lock, at the cost of losing the safety the lock provides.

**A3.7** — Two distinct classes:
1. **Semantic / resource-property errors.** `validate-template` checks YAML/JSON well-formedness, template structure and intrinsic-function syntax. It does not evaluate resource property schemas — the `BrokenBucket` from Exercise 5, with an underscore in a bucket name, validates cleanly and fails only when the S3 resource handler rejects it at create time.
2. **Runtime and environment errors.** Insufficient IAM permissions for the deploying role, a globally-taken S3 bucket name, an exhausted service quota, an unavailable instance type in the chosen AZ, a `!GetAtt` on an attribute the resource does not expose in that Region. None of these are knowable from the template alone.
(Use `cfn-lint` to close most of gap 1, and a change set plus a non-production account to close gap 2.)

### Block 4 — Change sets and drift

**A4.1** — `BucketName` is an **immutable, create-only property**: the S3 API offers no rename. CloudFormation's resource schema marks it `createOnlyProperty`, so any change to it maps to `RequiresRecreation: Always` — delete-and-recreate, surfaced as `Replacement: True`.
The SSM parameter shows `Replacement: False` because its own properties are all mutable. It *is* affected — its `Value` will change to the new bucket name — but changing an SSM parameter's value is an in-place `PutParameter`. CloudFormation correctly propagates the *value* change through the dependency graph without propagating the *replacement*.

**A4.2** — Precisely: CloudFormation would create the **new** bucket `...-clf31-83291-new`, update `ArtifactBucketPointer` to reference it, and then evaluate the old bucket's disposition. Because replacement is governed by `UpdateReplacePolicy` — which is `Retain` — the old bucket `...-clf31-83291-art` is **not deleted**. Its objects and versions are intact and still billed. `DeletionPolicy: Delete` is irrelevant here; it applies only when the *stack* is deleted, not when a resource is replaced. Net result: no data loss, one orphaned billable bucket outside IaC management, and any consumer still holding the old name silently reading a stale bucket. Had `UpdateReplacePolicy` been `Delete` (or absent — the default is to follow `DeletionPolicy`, effectively `Delete`), the same change set would have destroyed the data.

**A4.3** — CloudFormation's update engine compares the **submitted template + parameters** against the **stored template + parameters**. It does not compare against the live resource. Both templates are identical, so the diff is empty and there is nothing to submit — drift status is computed by a separate service and does not feed the update path. Two working remediations:
1. **Force a no-op-plus-one update**: change something trivial and reversible in the template (e.g. bump the `Description`, or add and later remove a metadata key). CloudFormation then re-submits the full desired state for the resource, overwriting the out-of-band tag.
2. **Import / re-baseline**: for larger or riskier divergence, remove the resource from the stack with `DeletionPolicy: Retain` and re-import it via `create-change-set --change-set-type IMPORT`, re-establishing the baseline explicitly.
The blunt third option — delete and recreate the stack — is correct only for stateless resources. Longer term, prevent the class entirely with a stack policy plus an SCP denying direct mutation of CloudFormation-managed resources.

**A4.4** — Drift detection compares only the properties **explicitly declared in your template** (plus a defined set of resource attributes) for **resource types that support drift detection**. It does not evaluate: properties you left to the service default; resource types with no drift support; the *contents* of resources (objects in the bucket, rows in a table); and anything outside the stack entirely. A concrete `IN_SYNC` false negative: deleting the bucket's lifecycle configuration is caught (you declared it), but attaching a **bucket policy** that grants public read is reported `IN_SYNC`, because your template never declared `BucketPolicy` — CloudFormation has no expectation to compare against. This is the single most important limitation to internalize: drift detection tells you "what I declared still matches", never "nothing has changed".

**A4.5** — Detection makes a live `Describe`/`Get` API call per resource against each owning service, subject to that service's own latency and throttling. On a large stack this is minutes of fan-out, far past any synchronous request timeout, so the API returns a `StackDriftDetectionId` immediately and you poll `describe-stack-drift-detection-status`. For a 400-resource stack this implies: (a) budget minutes, not seconds, and never `sleep`-and-hope — poll on `DetectionStatus`; (b) expect `DETECTION_FAILED` on individual resources whose service throttles you, and handle partial results; (c) do not put it in the hot path of every deploy — run it on a schedule (or via AWS Config rules, which do this continuously) and gate on the report, not on a synchronous check.

**A4.6** — Two risks, both visible above:
1. **Unreviewed replacement of stateful resources.** Step 4 showed a one-word parameter change producing `Replacement: True` on the bucket. A direct `update-stack` would have executed that immediately, with the destructive step visible only in hindsight in the event log. The change set turned an irreversible action into a reviewable artifact.
2. **Unbounded blast radius from an unintended diff.** A change set enumerates *every* affected resource — step 4 revealed that the SSM parameter was also in scope, which the author of a one-line parameter change would not necessarily have predicted. Direct updates give you no such enumeration before the fact.
The policy converts deployment from an imperative act into a reviewed plan — the same reason `terraform plan` exists.

### Block 5 — Failure modes and diagnostics

**A5.1** — Because `update-stack` is **asynchronous**. It validates the request, opens the stack transaction, returns a `StackId` and exits **0** — the deployment has been *accepted*, not *completed*. All the actual work, and therefore all the possible failure, happens afterward. A pipeline that stops at `update-stack` reports green for a deployment that rolled back minutes later. The waiter is what converts async acceptance into a synchronous pass/fail: it polls `DescribeStacks` and exits non-zero (255 for a terminal failure state, 255 on timeout) when the stack lands anywhere other than the expected success state. **`update-stack` without a waiter is not a deployment step; it is a submission step.**

**A5.2** — CloudFormation's failure propagation is fan-out. One resource fails; CloudFormation cancels every in-flight sibling, marks them with generic reasons like `Resource creation cancelled`, then rolls back each completed resource, generating a `*_FAILED` or `DELETE_*` event for each. All of that is chronologically *after* the real fault. So the last `*_FAILED` event is almost always a cancellation artifact or a rollback step with a reason like `Resource creation cancelled` — true, and completely uninformative. The **first** failure by timestamp carries the actual `ResourceStatusReason` from the resource handler, which is the one line that tells you what is wrong. Hence `reverse(StackEvents[...])` and `head -1`: `describe-stack-events` returns newest-first, so reversing gives oldest-first, and the first match is the root cause.

**A5.3** — `ROLLBACK_COMPLETE` is reached when a stack fails during its **initial creation**. Nothing was ever successfully created, so there is no prior good state to update to — the stack is a shell holding only its own identity. It **cannot be updated**; the only legal operation is `delete-stack`, after which you fix the template and create it again. (This is what `--on-failure DELETE` automates.)
`UPDATE_ROLLBACK_COMPLETE` follows a failed **update** of an already-healthy stack. The stack was successfully returned to its last known-good template, so it is a fully operational stack and can be updated normally.
The exam-relevant distinction: `ROLLBACK_COMPLETE` is a dead end; `UPDATE_ROLLBACK_COMPLETE` is a healthy stack.

**A5.4** — *Correct*: a resource fails for a reason the `ResourceStatusReason` does not explain — an EC2 instance whose `cfn-init` bootstrap fails, an ECS task that crash-loops, a Lambda whose custom resource never signals. Rollback would delete the very thing you need to inspect (the instance, its logs, its state), destroying the evidence. `--disable-rollback` preserves the wreckage for a post-mortem, in a non-production account.
*Mistake*: in an automated production pipeline. It leaves the stack in `UPDATE_FAILED` — a non-terminal, non-operational state where the deployed infrastructure is a half-applied mixture of old and new. The stack cannot be updated until someone manually calls `rollback-stack` or `continue-update-rollback`. You have converted an automatic, bounded failure into an outage requiring human intervention, at the worst possible moment.

**A5.5** — CloudFormation's guarantee is **transactional at the stack level**: an update either fully applies or the stack is returned to its last known-good template, with resources it did not need to touch left untouched. `ArtifactBucket` shows `UPDATE_COMPLETE` because its (successful) update was applied, and the rollback found nothing to revert for it.
The well-known exception is **`UPDATE_ROLLBACK_FAILED`**: if the rollback *itself* cannot complete — the previous version of a resource can no longer be recreated, an out-of-band change made the old state unreachable, an IAM permission was revoked mid-flight — the stack is stranded in a genuinely inconsistent state that CloudFormation cannot repair on its own. The transactional guarantee holds only as far as the rollback path is executable.

**A5.6** — `aws cloudformation continue-update-rollback --stack-name <name>`. It accepts `--resources-to-skip` (a list of logical resource IDs, or `NestedStackName.LogicalId` for nested stacks) to skip resources whose rollback keeps failing. Two cautions: skipping a resource makes the stack's stored template **knowingly diverge** from reality for that resource — you must import or repair it afterwards; and the operation requires the stack to be in `UPDATE_ROLLBACK_FAILED`, so diagnose the underlying cause (usually a revoked permission or an out-of-band deletion) before reaching for `--resources-to-skip`.

### Block 6 — Deployment models

**A6.1** — `ParentZoneName` means the zone is an **extension of the parent Region's control plane and network**, not an independent Region: you address it with the same account, the same IAM, the same VPC (via a subnet placed in that zone), and the same API endpoints. There is no separate Region to opt into, no separate credentials, no cross-Region data transfer semantics for the parent link.
The differentiator is **whose traffic arrives**:
- A **Local Zone** sits in a metropolitan area and is reached over the **public internet or Direct Connect**. It serves latency-sensitive workloads for users and on-premises systems in that metro — real-time gaming, media rendering, ML inference near an office.
- A **Wavelength Zone** is embedded **inside a telecom carrier's 5G network**. Traffic from a mobile device reaches it without ever leaving the carrier network and traversing the internet. It serves mobile-edge workloads — connected vehicles, AR/VR on handsets, industrial IoT over 5G.
Same architectural pattern (a Region extension), different last mile.

**A6.2** — Opting in makes the zone **usable by your account**: it becomes selectable when creating a subnet, and its (deliberately narrower) menu of instance types and services becomes available. AWS made it opt-in for several reasons: these zones offer a *subset* of Region services and instance families, so silently including them would let `Availability Zones: Any` place workloads somewhere with different capabilities; pricing differs from the parent Region; and blast-radius/compliance assumptions built on "my Region has 6 AZs" would change under you. Opt-in makes the expanded footprint an explicit architectural decision rather than a surprise. Note the same opt-in mechanism governs newer *Regions* (e.g. `af-south-1`), for the same reason.

**A6.3** — **On-premises deployment model, via AWS Outposts** — physical AWS-designed and AWS-managed racks (or 1U/2U servers) installed in *your* datacenter, running the same EC2, EBS, S3-on-Outposts, ECS/EKS and VPC APIs, managed through the same Console, CLI, IAM and CloudFormation. Data on an Outpost stays on the Outpost. AWS delivers, installs, monitors, patches and services the hardware.
What you must still provision yourself: the **facility and its service link**. Specifically — floor space, power (redundant feeds meeting the published requirements), cooling, physical security, and the network: uplinks to your local network plus a reliable, redundant **service link** back to the parent Region. AWS operates the rack; you operate the room and the pipes.

**A6.4** —
(a) **Hybrid.** The appliance runs on your infrastructure and presents a local NFS/SMB interface to on-premises clients, while the authoritative data lives in S3. Both halves are load-bearing and continuously coupled.
(b) **Cloud.** Control plane and data plane are entirely in-Region. Nothing runs on your hardware.
(c) **On-premises.** EKS Anywhere runs the full Kubernetes cluster on your own vSphere infrastructure, on your hardware, under your operation. It can be air-gapped. Unlike an Outpost, AWS does not own or operate the hardware and the AWS control plane is not extended to it — it is AWS-*distributed* software, not an AWS-*managed* footprint.
(d) **Hybrid.** The compute tier is cloud-native, the data tier is on-premises, and the architecture depends on both plus the private link between them. This is the most common real-world hybrid shape during a migration.

**A6.5** — An Outpost runs the *data plane* locally, but its **control plane lives in the parent Region**. Every mutating API call — `RunInstances`, `CreateVolume`, `AuthorizeSecurityGroupIngress` — is made against a regional endpoint, authenticated by regional IAM, and dispatched to the rack over the service link. That link is also how AWS monitors hardware health, delivers patches and firmware, and how metrics and logs reach CloudWatch.
Over a six-hour outage: **already-running instances keep running** and local VPC traffic keeps flowing — existing workloads do not stop. What degrades is everything that requires the control plane: you cannot launch, terminate, resize or reconfigure instances; you cannot create volumes or modify security groups; Auto Scaling cannot replace a failed instance; CloudWatch metrics and CloudTrail events buffer or are lost; AWS loses hardware telemetry. In effect the Outpost becomes a frozen, unmanageable snapshot of itself — it survives, but it cannot heal or change. This is why redundant, diverse service-link paths are a design requirement, not an optimization.

### Block 7 — Connectivity

**A7.1** — **Variable queueing delay across uncontrolled intermediate networks.** Your packets traverse a series of third-party autonomous systems whose routing, congestion and buffer occupancy you neither observe nor influence; a transient at any hop adds queueing delay, and BGP may reroute you onto a different path between requests. The result is high **jitter** — an unstable p99 even when the mean is fine — and no contractual latency guarantee.
**AWS Direct Connect** is purchased specifically to eliminate this: a dedicated physical circuit from your router to an AWS router at a Direct Connect location, bypassing the public internet entirely, giving consistent latency, predictable bandwidth and a defined path. You buy Direct Connect for the *variance*, not the *mean* — that is the distinction the exam tests. (A Site-to-Site VPN improves confidentiality and gives you private addressing, but rides the same public internet and therefore inherits the same jitter.)

**A7.2** — Both are generated by AWS when you create the **VPN connection** (`ec2 create-vpn-connection`), which binds a Customer Gateway to a Virtual Private Gateway or a Transit Gateway. The Customer Gateway alone is inert metadata — your router's public IP, its BGP ASN, and the tunnel protocol — which is exactly why creating it is free and instantaneous. Only the VPN connection allocates real infrastructure.
A single AWS Site-to-Site VPN connection provides **two tunnels by default**, terminating on two independent AWS-side endpoints in two different Availability Zones, each with its own outside IP address and its own pre-shared key (or certificate). Both are active; AWS may take one down for maintenance at any time. You retrieve the full configuration — including the PSKs and a vendor-specific config template — from `describe-vpn-connections`, whose `CustomerGatewayConfiguration` field returns it as XML. **You must configure both tunnels on your router**; a single-tunnel configuration is a self-inflicted single point of failure and forfeits the connection's SLA.

**A7.3** — The reviewer is worried that a single connection concentrates **four** independent single points of failure: the AWS device terminating your circuit, the cross-connect and patch panel inside `EqDC2`, the colocation facility itself (power, cooling, fire suppression), and your own router and its uplink. Any one of those takes you fully offline. A single circuit also has no maintenance window — AWS device maintenance is an outage.
Minimum change for the same total bandwidth: **two 10 Gbps connections terminating at two *different* Direct Connect locations** (e.g. `EqDC2` and `CSDC1`), each on a separate AWS device, ideally on separate customer routers and diversely-routed fiber. This is AWS's *maximum resiliency* pattern; two connections in the *same* location on different devices is the lesser "high resiliency" pattern that removes the device SPOF but not the facility SPOF. Standard practice adds a Site-to-Site VPN as a cheap tertiary backup path over the internet, accepting degraded performance during a total Direct Connect failure. Then test failover — an untested backup path is a hypothesis, not a control.

**A7.4** — **No.** Direct Connect is *private* in the sense of being a dedicated Layer 2 circuit that does not traverse the public internet — but the traffic on it is **not encrypted** by AWS. Anyone with physical or logical access to the path (the colocation provider, a compromised carrier, an insider at any point in the cross-connect) sees plaintext. "Private" and "encrypted" are orthogonal properties, and conflating them is a classic audit finding.
The standard remedies are **MACsec** (IEEE 802.1AE, Layer 2 encryption available on supported dedicated connections at specific locations and port speeds) or running an **IPsec VPN over the Direct Connect public virtual interface**, or using AWS Direct Connect with a **Site-to-Site VPN over a Transit VIF**.
The architectural cost: IPsec-over-DX adds encryption/decryption overhead and a tunnel MTU reduction, caps throughput at what the VPN termination can sustain (a single Site-to-Site VPN tunnel tops out well below 10 Gbps — you need ECMP across multiple tunnels or a Transit Gateway to scale past it), and adds a second failure domain and a second set of keys to operate. You are trading raw throughput and simplicity for confidentiality, which is usually the right trade but is never free.

**A7.5** — 40 TB at 200 Mbps, at a theoretically perfect 100% utilization:
`40 TB = 40 × 8 = 320 Tbit = 320,000,000 Mbit`; `320,000,000 / 200 = 1,600,000 s ≈ 444 hours ≈ 18.5 days`.
That already exceeds the one-week deadline by 2.6×, and it assumes the link is 100% saturated for the entire period — meaning no business traffic at all, and no TCP inefficiency, retransmission or protocol overhead. Realistically, at a sustainable 50% utilization, this is **over a month**.
The service is **AWS Snowball Edge** (the AWS Snow Family). AWS ships you a ruggedized, encrypted physical appliance; you copy the data locally at LAN speed and ship it back for ingest into S3. Turnaround is typically under a week including transit. It belongs to the **hybrid** deployment model — physical hardware operating in your facility as a deliberate bridge into the cloud — and it is the canonical answer to "the network is the bottleneck". The general rule the exam wants: past roughly 10 TB over a constrained link, compute the transfer time before assuming the network is the answer. (For ongoing, incremental transfer over an adequate link, the answer would instead be AWS DataSync.)

**A7.6** — Fastest to slowest **time to first packet**:
1. **Public internet** — minutes. It already exists; you need only an internet gateway and a route. Zero procurement.
2. **Site-to-Site VPN** — minutes to hours. Entirely software-defined on the AWS side: create the Customer Gateway and VPN connection via API, download the config, apply it to your router. The only gate is your own network team's change window.
3. **Direct Connect** — **weeks to months**. It requires physical provisioning: a LOA-CFA from AWS, a cross-connect ordered and installed by the colocation provider, possibly a new circuit from a carrier to reach the facility, contracts, and physical work by humans in a building.
This ranking frequently decides migrations because business timelines do not wait for a cross-connect. The standard pattern is therefore to **start on a Site-to-Site VPN on day one** — it is available immediately, gives you private addressing and encryption, and lets migration begin — while the Direct Connect order proceeds in parallel. When the circuit lands, you attach it and shift traffic, then **keep the VPN as the encrypted backup path** rather than decommissioning it. You get immediate progress, and the eventual architecture is more resilient than either option alone.

### Block 8 — Operating abstractions

**A8.1** — **Adds**: an opinionated, complete application platform from a single artifact. You hand it a code bundle; it selects and provisions the EC2 fleet, Auto Scaling group, load balancer, security groups and CloudWatch alarms, installs and configures the language runtime, and — critically — gives you **application-lifecycle** operations that CloudFormation has no concept of: versioned application revisions, rolling and immutable deployment policies, blue/green via environment URL swap, one-command rollback to a previous version, and health reporting that understands your application rather than just the instance. It also patches the managed platform for you.
**Takes away**: control and transparency. The generated CloudFormation stack is Beanstalk's, not yours — editing it directly puts you in conflict with the service. You are constrained to supported platform branches and to the extension points Beanstalk exposes (`.ebextensions`, `.platform` hooks, configuration option namespaces); anything outside them is awkward or impossible. And you inherit a managed platform's upgrade cadence and deprecation schedule.
The general shape: Beanstalk trades *expressiveness* for *time-to-running-application*, and CloudFormation is the escape hatch underneath when the trade stops paying.

**A8.2** — Decreasing operational responsibility, with the responsibility that transfers at each step:

1. **EC2 with a shell script** — you own everything: provisioning, configuration, patching, scaling, recovery, and the correctness of the script.
   ↓ *transfers: remote access, patch orchestration, inventory and configuration compliance* (and you stop maintaining bastions and SSH keys)
2. **EC2 + Systems Manager** — AWS provides the operating tooling; you still own what it does and the OS itself.
   ↓ *transfers: the reproducibility of provisioning — dependency ordering, rollback, drift baseline, idempotency*
3. **CloudFormation** — infrastructure is declared and reproducible; you still own the OS, runtime and application lifecycle.
   ↓ *transfers: the platform layer — runtime installation, load balancer and Auto Scaling wiring, application deployment strategy and rollback*
4. **Elastic Beanstalk** — AWS runs the application platform; you still own the underlying EC2 instances (they are in your account, and you can still SSH to them).
   ↓ *transfers: container orchestration — scheduling, placement, health-based replacement, service discovery*
5. **ECS on EC2** — AWS schedules containers; you still own, patch and scale the EC2 container instances.
   ↓ *transfers: the host layer entirely — no instances to patch, size, scale or secure*
6. **ECS on Fargate** — you own the container image and its resource sizing; there is no host in your account.
   ↓ *transfers: the container runtime, capacity management and idle cost — scale-to-zero, per-invocation billing*
7. **Lambda** — you own only your function code and its configuration.

Two caveats worth stating: this is a spectrum of *responsibility*, not a ranking of *quality* — Lambda is not "better" than EC2, it is a different trade of control for operational load. And the trade is real in both directions: each step down surrenders a control surface you may later need, and moving back up is expensive.

**A8.3** — Three components:
1. The **SSM Agent** installed on the instance (pre-installed on Amazon Linux 2023, recent Ubuntu and Windows AMIs).
2. An **IAM instance profile** granting the instance permission to talk to Systems Manager — typically the `AmazonSSMManagedInstanceCore` managed policy.
3. **Network egress to the SSM service endpoints** — via an internet/NAT path, or, better, VPC interface endpoints (`ssm`, `ssmmessages`, `ec2messages`) so the traffic never leaves the AWS network.
The agent **polls outbound** to the service and executes what it is given; the service never initiates an inbound connection.
This is an *operating method* improvement, not a convenience, because it removes an entire class of attack surface and operational burden at once: **no inbound port 22/3389 in any security group**, no bastion host to run and patch, no SSH key pairs to distribute, rotate, revoke or lose, and no separate access-control system. Authorization becomes **IAM** — the same policies, the same conditions, the same principals as everything else in the account — and every command is authenticated, authorized against IAM, logged to CloudTrail, and optionally recorded keystroke-by-keystroke to S3 or CloudWatch Logs. It converts remote access from a parallel security domain into a normal AWS API call. That is a structural change in the security model, not a nicer UX.

**A8.4** — The objection is **drift**. A `Run Command` sweep mutates instances out-of-band, exactly like the manual tag change in Exercise 4 step 6. The change is invisible to the declared desired state; it survives until the next instance replacement and then silently vanishes, so a scaled-out or auto-healed instance comes up *without* it. You now have a fleet that is non-uniform in a way no template describes and no diff will show — and, per A4.4, drift detection will not necessarily catch it, since it only compares properties you declared. This is the "human-at-3am" failure institutionalized as a procedure.
The correct mechanism, in ascending order of rigour:
- **State Manager** (Systems Manager) — associate a document with a target set and let SSM *continuously re-apply* it on a schedule. The change becomes declared and self-healing rather than one-shot.
- **A new AMI, built with EC2 Image Builder**, rolled out by updating the launch template through CloudFormation — immutable infrastructure, where the config change is baked in and replacement is the deployment mechanism.
The general principle: `Run Command` is for **investigation and one-time remediation**, not for **configuration**. If you want it to still be true tomorrow, it must be declared somewhere.

**A8.5** — In shared-responsibility terms, accepting a managed service's defaults means AWS has made a **capacity and availability decision on your behalf** — and that decision is squarely on *your* side of the line. AWS operates the Auto Scaling group correctly; whether `MinSize: 1` / `MaxSize: 4` matches your traffic is entirely your responsibility. The service will faithfully do exactly what those numbers say, including failing.
Concretely, `MinSize: 1` means **no redundancy**: a single instance, in a single AZ, whose loss is a full outage until a replacement launches and passes health checks — minutes of downtime for a service you may have believed was highly available because "it's on AWS and it has an ELB". And `MaxSize: 4` is a hard ceiling: your traffic can grow past it and the environment will simply saturate and degrade, with no error that says "you hit your own limit".
The general risk: a managed service's defaults are chosen to be **cheap, safe and demo-friendly for the median new user** — never to match your availability target, your traffic profile or your cost envelope. The abstraction moves the *work*, not the *accountability*. Every default a managed service picks is still a decision you own; production means reviewing each one deliberately, at minimum `MinSize ≥ 2` across at least two Availability Zones, with `MaxSize` derived from measured peak plus headroom.

</details>

---

## Sources

All exercises are original. Verify behaviour and current API surface against the official documentation:

- **Exam guide (authoritative scope for Task 3.1):** https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf
- AWS CLI v2 User Guide — https://docs.aws.amazon.com/cli/latest/userguide/cli-chap-welcome.html
- Configuration and credential precedence — https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-quickstart.html
- Signing AWS API requests (SigV4) — https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_aws-signing.html
- AWS SDKs and Tools reference — retry behavior — https://docs.aws.amazon.com/sdkref/latest/guide/feature-retry-behavior.html
- Boto3 paginators — https://boto3.amazonaws.com/v1/documentation/api/latest/guide/paginators.html
- AWS CloudFormation User Guide — https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/Welcome.html
- Updating stacks using change sets — https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/using-cfn-updating-stacks-changesets.html
- Detecting unmanaged configuration changes (drift) — https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/using-cfn-stack-drift.html
- `DeletionPolicy` attribute — https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-attribute-deletionpolicy.html
- `UpdateReplacePolicy` attribute — https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-attribute-updatereplacepolicy.html
- Troubleshooting CloudFormation — https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/troubleshooting.html
- AWS CloudTrail User Guide — https://docs.aws.amazon.com/awscloudtrail/latest/userguide/cloudtrail-user-guide.html
- AWS Outposts — https://docs.aws.amazon.com/outposts/latest/userguide/what-is-outposts.html
- AWS Local Zones — https://docs.aws.amazon.com/local-zones/latest/ug/what-is-aws-local-zones.html
- AWS Wavelength — https://docs.aws.amazon.com/wavelength/latest/developerguide/what-is-wavelength.html
- AWS Direct Connect User Guide — https://docs.aws.amazon.com/directconnect/latest/UserGuide/Welcome.html
- AWS Site-to-Site VPN User Guide — https://docs.aws.amazon.com/vpn/latest/s2svpn/VPC_VPN.html
- Amazon VPC connectivity options (whitepaper) — https://docs.aws.amazon.com/whitepapers/latest/aws-vpc-connectivity-options/welcome.html
- AWS DataSync — https://docs.aws.amazon.com/datasync/latest/userguide/what-is-datasync.html
- AWS Storage Gateway — https://docs.aws.amazon.com/storagegateway/latest/vgw/WhatIsStorageGateway.html
- AWS Snowball Edge — https://docs.aws.amazon.com/snowball/latest/developer-guide/whatisedge.html
- AWS Elastic Beanstalk Developer Guide — https://docs.aws.amazon.com/elasticbeanstalk/latest/dg/Welcome.html
- AWS Systems Manager Session Manager — https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager.html
- AWS Systems Manager State Manager — https://docs.aws.amazon.com/systems-manager/latest/userguide/systems-manager-state.html
- AWS Cloud Development Kit (CDK) v2 — https://docs.aws.amazon.com/cdk/v2/guide/home.html