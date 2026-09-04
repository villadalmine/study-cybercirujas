# Topic 2.2 — Guided Exercises
## Understand AWS Cloud security, governance, and compliance concepts
**Certification:** AWS Certified Cloud Practitioner (CLF-C02) · **Domain 2: Security and Compliance** · **Task statement 2.2** · **Domain weight: 30% (this task statement ≈ 7.5%)**

---

## How to use this material

Every exercise is a block of numbered steps you execute yourself, followed by verification questions. Do not read the answers until you have run the block and looked at the real output — the exam tests whether you can tell **which service produces which evidence**, and that distinction only becomes obvious when you have seen the JSON.

### Prerequisites

| Requirement | Check |
|---|---|
| AWS account you are allowed to modify (sandbox, **not** production) | — |
| IAM principal with administrative permissions | `aws sts get-caller-identity` |
| AWS CLI v2 (≥ 2.15) | `aws --version` |
| `jq`, `openssl`, `base64` | `jq --version` |
| An AWS Organizations management account **only for Exercise 2, Block C** (optional) | `aws organizations describe-organization` |

### Cost and safety notice

Most of this material runs inside the AWS Free Tier or costs cents. Three services are **not** free and are explicitly marked:

- **AWS Config** — charged per configuration item recorded and per rule evaluation.
- **AWS Security Hub** — charged per finding ingested and per compliance check.
- **Amazon GuardDuty / Inspector / Macie** — free for the first 30 days per account, then billed.

Exercise 9 tears everything down. **Run it.** Leaving a Config recorder running in a forgotten account is the single most common way a lab produces a surprise invoice.

Throughout, `111122223333` is the placeholder account ID and `eu-west-1` the placeholder Region. Substitute your own.

---

## Exercise 0 — Establish the identity and Region baseline

Every governance control you will build is evaluated against **who** made the call and **where** it was made. Pin both down before touching anything else.

### Steps

1. Confirm the CLI version. Several commands below (`aws artifact`, `aws account list-regions`) do not exist in CLI v1.

   ```bash
   aws --version
   ```

   ```
   aws-cli/2.19.4 Python/3.12.6 Linux/6.11.0 exe/x86_64.fedora.41
   ```

2. Resolve the calling identity. This is the principal every CloudTrail event in this lab will be attributed to.

   ```bash
   aws sts get-caller-identity
   ```

   ```json
   {
       "UserId": "AIDASAMPLEUSERID123456",
       "Account": "111122223333",
       "Arn": "arn:aws:iam::111122223333:user/lab-admin"
   }
   ```

3. Export the values you will reuse. The `LAB_SUFFIX` keeps S3 bucket names globally unique.

   ```bash
   export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
   export AWS_REGION=eu-west-1
   export LAB_SUFFIX="${AWS_ACCOUNT_ID}-clf22"
   export EVIDENCE_BUCKET="clf-lab-evidence-${LAB_SUFFIX}"
   export TRAIL_BUCKET="clf-lab-trail-${LAB_SUFFIX}"
   echo "$AWS_ACCOUNT_ID / $AWS_REGION / $EVIDENCE_BUCKET"
   ```

   ```
   111122223333 / eu-west-1 / clf-lab-evidence-111122223333-clf22
   ```

4. List the Regions this account can currently use. Note the two distinct opt-in states.

   ```bash
   aws account list-regions \
     --region-opt-status-contains ENABLED ENABLED_BY_DEFAULT \
     --query 'Regions[].[RegionName,RegionOptStatus]' \
     --output table
   ```

   ```
   -------------------------------------------
   |               ListRegions               |
   +------------------+----------------------+
   |  eu-central-1    |  ENABLED_BY_DEFAULT  |
   |  eu-north-1      |  ENABLED_BY_DEFAULT  |
   |  eu-west-1       |  ENABLED_BY_DEFAULT  |
   |  eu-west-2       |  ENABLED_BY_DEFAULT  |
   |  eu-west-3       |  ENABLED_BY_DEFAULT  |
   |  sa-east-1       |  ENABLED_BY_DEFAULT  |
   |  us-east-1       |  ENABLED_BY_DEFAULT  |
   |  us-east-2       |  ENABLED_BY_DEFAULT  |
   |  us-west-1       |  ENABLED_BY_DEFAULT  |
   |  us-west-2       |  ENABLED_BY_DEFAULT  |
   +------------------+----------------------+
   ```

5. Now list the Regions that exist but are **not** enabled.

   ```bash
   aws account list-regions \
     --region-opt-status-contains DISABLED \
     --query 'Regions[].RegionName' --output text
   ```

   ```
   af-south-1  ap-east-1  ap-south-2  ap-southeast-3  ap-southeast-4  ca-west-1
   eu-central-2  eu-south-1  eu-south-2  il-central-1  me-central-1  me-south-1
   ```

### Verification questions — Block 0

- **Q0.1** — Two Regions in your account report `ENABLED_BY_DEFAULT` and a dozen report `DISABLED`. What is the security significance of an opt-in Region being disabled, and why is this considered a *governance* control rather than merely an availability setting?
- **Q0.2** — The `Arn` returned by `get-caller-identity` is an IAM user. Under the AWS shared responsibility model, who is responsible for rotating that user's access key, and who is responsible for patching the STS service that answered the call?
- **Q0.3** — You ran `aws account list-regions` without specifying `--region`. Which Region did the request actually go to, and why does that matter when you later write a policy that restricts Regions?

---

## Exercise 1 — Retrieve compliance evidence with AWS Artifact

**AWS Artifact is the answer to "where do I get AWS's audit reports?"** — SOC 1/2/3, ISO 27001, PCI DSS AOC, FedRAMP packages, and the agreements (BAA, GDPR DPA) you accept on behalf of your organization. It is a *self-service portal for AWS's own third-party attestations*. It tells you nothing about your workload's compliance; it tells you about the compliance of the infrastructure underneath it.

### Steps

1. List the reports available to your account. This is a **read-only, no-cost** API.

   ```bash
   aws artifact list-reports --max-results 10 \
     --query 'reports[].[name,series,state,periodStart,periodEnd]' \
     --output table
   ```

   ```
   ----------------------------------------------------------------------------------------------------------
   |                                              ListReports                                               |
   +-------------------------------------+---------+------------+---------------------+---------------------+
   |  AWS SOC 2 Type II Report           |  SOC    | PUBLISHED  | 2025-04-01T00:00:00Z| 2026-03-31T00:00:00Z|
   |  AWS SOC 3 Report                   |  SOC    | PUBLISHED  | 2025-04-01T00:00:00Z| 2026-03-31T00:00:00Z|
   |  ISO 27001:2022 Certification       |  ISO    | PUBLISHED  | 2025-01-01T00:00:00Z| 2027-12-31T00:00:00Z|
   |  PCI DSS v4.0 Attestation of Compl. |  PCI    | PUBLISHED  | 2025-10-01T00:00:00Z| 2026-09-30T00:00:00Z|
   |  AWS CSA STAR Level 2 Certification |  CSA    | PUBLISHED  | 2025-06-15T00:00:00Z| 2026-06-14T00:00:00Z|
   +-------------------------------------+---------+------------+---------------------+---------------------+
   ```

2. Capture the identifier of one report so you can fetch it.

   ```bash
   export REPORT_ID=$(aws artifact list-reports \
     --query "reports[?series=='SOC'] | [0].id" --output text)
   export REPORT_VERSION=$(aws artifact list-reports \
     --query "reports[?series=='SOC'] | [0].version" --output text)
   echo "$REPORT_ID v$REPORT_VERSION"
   ```

   ```
   report-bqRoZ7QhTVaXXXXX v3
   ```

3. Inspect the metadata **before** downloading. Note `acceptanceType` — this is the field that tells you the report is under NDA.

   ```bash
   aws artifact get-report-metadata \
     --report-id "$REPORT_ID" --report-version "$REPORT_VERSION"
   ```

   ```json
   {
       "reportDetails": {
           "id": "report-bqRoZ7QhTVaXXXXX",
           "name": "AWS SOC 2 Type II Report",
           "description": "Report on the AWS System and the Suitability of the Design and Operating Effectiveness of Controls",
           "periodStart": "2025-04-01T00:00:00+00:00",
           "periodEnd": "2026-03-31T00:00:00+00:00",
           "createdAt": "2026-05-15T14:02:11+00:00",
           "series": "SOC",
           "category": "Certifications And Attestations",
           "companyName": "Amazon Web Services, Inc.",
           "productName": "AWS",
           "termArn": "arn:aws:artifact:::term/term-4wRoZ7QhTVaXXXXX",
           "version": 3,
           "acceptanceType": "EXPLICIT",
           "state": "PUBLISHED",
           "arn": "arn:aws:artifact:::report/report-bqRoZ7QhTVaXXXXX"
       }
   }
   ```

4. Because `acceptanceType` is `EXPLICIT`, you must retrieve and accept the NDA term first. This returns a **term token**, which is the machine-readable proof of acceptance.

   ```bash
   aws artifact get-term-for-report \
     --report-id "$REPORT_ID" --report-version "$REPORT_VERSION" \
     --query 'termToken' --output text
   ```

   ```
   eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9.SAMPLE-TERM-TOKEN-VALUE.4nQxYw
   ```

5. Exchange the term token for a pre-signed download URL. The URL is short-lived.

   ```bash
   export TERM_TOKEN=$(aws artifact get-term-for-report \
     --report-id "$REPORT_ID" --report-version "$REPORT_VERSION" \
     --query 'termToken' --output text)

   aws artifact get-report \
     --report-id "$REPORT_ID" --report-version "$REPORT_VERSION" \
     --term-token "$TERM_TOKEN" \
     --query 'documentPresignedUrl' --output text | cut -c1-90
   ```

   ```
   https://artifact-reports-prod-eu-west-1.s3.eu-west-1.amazonaws.com/report-bqRoZ7QhT
   ```

6. Confirm the CLI will **not** hand you the document without the term token — this is the NDA enforcement point.

   ```bash
   aws artifact get-report \
     --report-id "$REPORT_ID" --report-version "$REPORT_VERSION" \
     --term-token "invalid-token"
   ```

   ```
   An error occurred (ValidationException) when calling the GetReport operation:
   The provided term token is not valid for this report version.
   ```

### Verification questions — Block 1

- **Q1.1** — Your auditor asks for evidence that the encryption of the S3 bucket holding customer records has been continuously enforced for the last 12 months. Can AWS Artifact provide that? If not, which AWS service can, and why is the distinction a shared-responsibility boundary?
- **Q1.2** — The SOC 2 Type II report has `acceptanceType: EXPLICIT` while the SOC 3 report does not. What is the practical difference between those two documents, and which one can you publish on your company website?
- **Q1.3** — A colleague suggests scripting a nightly download of all Artifact reports into a public S3 bucket "so the team always has them". Identify the compliance violation.
- **Q1.4** — Beyond reports, AWS Artifact hosts *agreements*. Name the agreement you would need to accept before processing US healthcare data on AWS, and state whether accepting it makes your workload HIPAA compliant.

---

## Exercise 2 — Data residency, Region scope, and cross-Region transfer

The exam repeatedly probes one fact: **AWS never moves your data out of the Region you put it in unless you configure it to.** This block proves that empirically, then builds the guardrail that keeps it true.

### Block A — Prove that storage is Region-scoped

1. Create a bucket in your chosen Region and lock it down immediately.

   ```bash
   aws s3api create-bucket \
     --bucket "$EVIDENCE_BUCKET" \
     --region "$AWS_REGION" \
     --create-bucket-configuration LocationConstraint="$AWS_REGION"
   ```

   ```json
   {
       "Location": "http://clf-lab-evidence-111122223333-clf22.s3.amazonaws.com/"
   }
   ```

   ```bash
   aws s3api put-public-access-block \
     --bucket "$EVIDENCE_BUCKET" \
     --public-access-block-configuration \
     "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
   ```

2. Ask AWS where the data physically lives.

   ```bash
   aws s3api get-bucket-location --bucket "$EVIDENCE_BUCKET"
   ```

   ```json
   {
       "LocationConstraint": "eu-west-1"
   }
   ```

3. Ask whether anything is configured to copy that data elsewhere. The **error is the evidence**.

   ```bash
   aws s3api get-bucket-replication --bucket "$EVIDENCE_BUCKET"
   ```

   ```
   An error occurred (ReplicationConfigurationNotFoundError) when calling the
   GetBucketReplication operation: The replication configuration was not found
   ```

4. Confirm the bucket is invisible from a different Region's endpoint only in the sense of *addressing*, not storage — the data itself never left `eu-west-1`.

   ```bash
   aws s3api head-bucket --bucket "$EVIDENCE_BUCKET" --region us-east-1 ; echo "exit=$?"
   ```

   ```
   exit=0
   ```

   (The request is redirected to the bucket's home Region. The control plane is global-ish; the **data plane is not**.)

### Verification questions — Block 2A

- **Q2.1** — Step 4 succeeded when addressed through `us-east-1`. Explain, precisely, why this does **not** mean the object data was transferred to the United States.
- **Q2.2** — Which single AWS S3 feature would cause bytes from this bucket to be written into another Region, and what does the fact that it must be explicitly configured imply for a GDPR data-residency assessment?
- **Q2.3** — An Availability Zone in `eu-west-1` fails. Does S3 lose your object? Which durability mechanism answers this, and is it a customer or an AWS responsibility?

### Block B — Build the data-residency guardrail (policy authoring, no Organizations required)

You can write and validate this policy without an organization. Applying it is Block C.

5. Write a Service Control Policy that denies every API call made outside an approved Region list.

   ```bash
   cat > /tmp/scp-region-lock.json <<'JSON'
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Sid": "DenyAllOutsideApprovedRegions",
         "Effect": "Deny",
         "NotAction": [
           "a4b:*",
           "acm:*",
           "artifact:*",
           "aws-marketplace:*",
           "aws-portal:*",
           "budgets:*",
           "ce:*",
           "chime:*",
           "cloudfront:*",
           "config:*",
           "cur:*",
           "globalaccelerator:*",
           "health:*",
           "iam:*",
           "importexport:*",
           "kms:*",
           "organizations:*",
           "pricing:*",
           "route53:*",
           "route53domains:*",
           "s3:GetAccountPublicAccessBlock",
           "s3:ListAllMyBuckets",
           "s3:PutAccountPublicAccessBlock",
           "shield:*",
           "sts:*",
           "support:*",
           "trustedadvisor:*",
           "waf-regional:*",
           "waf:*",
           "wafv2:*"
         ],
         "Resource": "*",
         "Condition": {
           "StringNotEquals": {
             "aws:RequestedRegion": [
               "eu-west-1",
               "eu-central-1"
             ]
           },
           "ArnNotLike": {
             "aws:PrincipalARN": [
               "arn:aws:iam::*:role/OrgBreakGlassAdmin"
             ]
           }
         }
       }
     ]
   }
   JSON
   ```

6. Validate the JSON is syntactically well-formed before AWS ever sees it.

   ```bash
   jq -e 'type == "object" and .Version == "2012-10-17"' /tmp/scp-region-lock.json >/dev/null \
     && echo "policy document: valid JSON, correct policy language version"
   ```

   ```
   policy document: valid JSON, correct policy language version
   ```

7. Measure the policy against the SCP size limit (5,120 bytes). This is a real operational constraint — region-lock SCPs grow until they no longer fit.

   ```bash
   jq -c . /tmp/scp-region-lock.json | wc -c
   ```

   ```
   831
   ```

### Verification questions — Block 2B

- **Q2.4** — The statement uses `NotAction` with a long allow-list of services rather than `Action: "*"`. What breaks if you remove `iam:*` and `sts:*` from that list?
- **Q2.5** — `cloudfront`, `route53` and `iam` are "global" services. In which Region does the AWS control plane record their API calls, and what does that mean for the `aws:RequestedRegion` condition key?
- **Q2.6** — This SCP has `"Effect": "Deny"`. If an IAM policy attached to a user explicitly allows `ec2:RunInstances` in `us-east-1`, can that user launch the instance? State the evaluation rule you applied.
- **Q2.7** — Does this SCP restrict actions taken by the **management account** of the organization? What is the operational consequence of that answer?

### Block C — Apply the guardrail *(optional; requires an AWS Organizations management account with all-features mode)*

> **Warning:** an incorrectly scoped region-lock SCP can lock your own operators out of an account. Test on a dedicated sandbox OU, never on the root.

8. Confirm you are in the management account and that SCPs are enabled.

   ```bash
   aws organizations describe-organization \
     --query 'Organization.[Id,MasterAccountId,FeatureSet]' --output text
   ```

   ```
   o-a1b2c3d4e5  111122223333  ALL
   ```

   ```bash
   aws organizations list-roots \
     --query 'Roots[].PolicyTypes[?Type==`SERVICE_CONTROL_POLICY`].Status' --output text
   ```

   ```
   ENABLED
   ```

9. Create the policy.

   ```bash
   aws organizations create-policy \
     --name "clf-lab-region-lock" \
     --description "Data residency guardrail: EU Regions only" \
     --type SERVICE_CONTROL_POLICY \
     --content file:///tmp/scp-region-lock.json \
     --query 'Policy.PolicySummary.[Id,Name,Type]' --output text
   ```

   ```
   p-x9y8z7w6  clf-lab-region-lock  SERVICE_CONTROL_POLICY
   ```

10. Attach it to a **sandbox OU only**.

    ```bash
    export OU_ID=ou-a1b2-sandbox01     # replace with your sandbox OU
    aws organizations attach-policy --policy-id p-x9y8z7w6 --target-id "$OU_ID"
    ```

11. From a member account inside that OU, prove the guardrail fires.

    ```bash
    aws ec2 describe-vpcs --region us-east-1
    ```

    ```
    An error occurred (UnauthorizedOperation) when calling the DescribeVpcs operation:
    You are not authorized to perform this operation. User:
    arn:aws:iam::444455556666:user/dev-alice is not authorized to perform:
    ec2:DescribeVpcs with an explicit deny in a service control policy
    ```

### Verification questions — Block 2C

- **Q2.8** — The error string contains the phrase `explicit deny in a service control policy`. Why is this diagnostic detail operationally valuable, and which service would you query to see *who else* has been hitting this deny?
- **Q2.9** — SCPs are described as "guardrails, not permissions". Restate that as a precise technical statement about what an SCP does to an IAM principal's effective permissions.

---

## Exercise 3 — Encryption at rest: KMS envelope encryption and S3 SSE-KMS

The single most-tested mechanic in this task statement. You will do envelope encryption **by hand** so the abstraction stops being a diagram.

### Block A — The KMS key and its policy

1. Create a customer managed key (CMK). Note that no key material ever leaves KMS.

   ```bash
   aws kms create-key \
     --description "CLF-C02 lab CMK for S3 SSE-KMS" \
     --key-usage ENCRYPT_DECRYPT \
     --key-spec SYMMETRIC_DEFAULT \
     --origin AWS_KMS \
     --tags TagKey=Purpose,TagValue=clf-c02-lab
   ```

   ```json
   {
       "KeyMetadata": {
           "AWSAccountId": "111122223333",
           "KeyId": "1234abcd-12ab-34cd-56ef-1234567890ab",
           "Arn": "arn:aws:kms:eu-west-1:111122223333:key/1234abcd-12ab-34cd-56ef-1234567890ab",
           "CreationDate": "2026-09-03T10:14:22.881000+00:00",
           "Enabled": true,
           "Description": "CLF-C02 lab CMK for S3 SSE-KMS",
           "KeyUsage": "ENCRYPT_DECRYPT",
           "KeyState": "Enabled",
           "Origin": "AWS_KMS",
           "KeyManager": "CUSTOMER",
           "CustomerMasterKeySpec": "SYMMETRIC_DEFAULT",
           "KeySpec": "SYMMETRIC_DEFAULT",
           "EncryptionAlgorithms": [
               "SYMMETRIC_DEFAULT"
           ],
           "MultiRegion": false
       }
   }
   ```

2. Give it a human-usable alias and enable automatic annual rotation.

   ```bash
   export KEY_ID=1234abcd-12ab-34cd-56ef-1234567890ab
   aws kms create-alias --alias-name alias/clf-lab-s3 --target-key-id "$KEY_ID"
   aws kms enable-key-rotation --key-id "$KEY_ID" --rotation-period-in-days 365
   aws kms get-key-rotation-status --key-id "$KEY_ID"
   ```

   ```json
   {
       "KeyRotationEnabled": true,
       "KeyId": "1234abcd-12ab-34cd-56ef-1234567890ab",
       "NextRotationDate": "2027-09-03T10:14:22.881000+00:00",
       "RotationPeriodInDays": 365
   }
   ```

3. Read the default key policy. This is the most important object in KMS and the most commonly misread.

   ```bash
   aws kms get-key-policy --key-id "$KEY_ID" --policy-name default \
     --output text --query Policy | jq .
   ```

   ```json
   {
     "Version": "2012-10-17",
     "Id": "key-default-1",
     "Statement": [
       {
         "Sid": "Enable IAM User Permissions",
         "Effect": "Allow",
         "Principal": {
           "AWS": "arn:aws:iam::111122223333:root"
         },
         "Action": "kms:*",
         "Resource": "*"
       }
     ]
   }
   ```

### Verification questions — Block 3A

- **Q3.1** — The default key policy grants `kms:*` to `arn:aws:iam::111122223333:root`. Does this mean only the root user can use the key? Explain what that principal actually denotes in a KMS key policy.
- **Q3.2** — Compare a *customer managed key* (`KeyManager: CUSTOMER`) with an *AWS managed key* (`aws/s3`). Name two capabilities you gain with the former and one cost you incur.
- **Q3.3** — Rotation is enabled with a 365-day period. After rotation occurs, can KMS still decrypt an object encrypted last month? What does KMS retain to make that true?

### Block B — Envelope encryption, performed manually

4. Ask KMS for a data key. You get the **same key twice**: once in plaintext, once wrapped by the CMK.

   ```bash
   aws kms generate-data-key --key-id alias/clf-lab-s3 --key-spec AES_256 \
     > /tmp/datakey.json
   jq '{KeyId, PlaintextLen: (.Plaintext|length), CiphertextLen: (.CiphertextBlob|length)}' /tmp/datakey.json
   ```

   ```json
   {
     "KeyId": "arn:aws:kms:eu-west-1:111122223333:key/1234abcd-12ab-34cd-56ef-1234567890ab",
     "PlaintextLen": 44,
     "CiphertextLen": 240
   }
   ```

5. Use the plaintext data key to encrypt a local file with AES-256 — this is the step KMS never performs for you on bulk data.

   ```bash
   echo "patient_id,diagnosis_code
   4471,E11.9
   4472,I10" > /tmp/records.csv

   jq -r .Plaintext /tmp/datakey.json | base64 -d > /tmp/dk.bin
   openssl enc -aes-256-cbc -pbkdf2 -in /tmp/records.csv -out /tmp/records.csv.enc \
     -pass file:/tmp/dk.bin
   ls -l /tmp/records.csv /tmp/records.csv.enc
   ```

   ```
   -rw-r--r--. 1 user user  46 Sep  3 10:22 /tmp/records.csv
   -rw-r--r--. 1 user user  64 Sep  3 10:22 /tmp/records.csv.enc
   ```

6. **Destroy the plaintext data key.** Keep only the wrapped copy. This is the whole point of the pattern.

   ```bash
   shred -u /tmp/dk.bin
   jq -r .CiphertextBlob /tmp/datakey.json > /tmp/wrapped-dk.b64
   ls /tmp/dk.bin 2>&1
   ```

   ```
   ls: cannot access '/tmp/dk.bin': No such file or directory
   ```

7. Recover the data key by asking KMS to unwrap it. Observe that you did **not** pass a key ID — the CMK identity is embedded in the ciphertext blob.

   ```bash
   aws kms decrypt \
     --ciphertext-blob "fileb://<(base64 -d /tmp/wrapped-dk.b64)" \
     --query Plaintext --output text 2>/dev/null \
   || { base64 -d /tmp/wrapped-dk.b64 > /tmp/wrapped-dk.bin
        aws kms decrypt --ciphertext-blob fileb:///tmp/wrapped-dk.bin \
          --query '[KeyId,EncryptionAlgorithm]' --output text ; }
   ```

   ```
   arn:aws:kms:eu-west-1:111122223333:key/1234abcd-12ab-34cd-56ef-1234567890ab   SYMMETRIC_DEFAULT
   ```

8. Complete the round trip: unwrap, decrypt, compare.

   ```bash
   aws kms decrypt --ciphertext-blob fileb:///tmp/wrapped-dk.bin \
     --query Plaintext --output text | base64 -d > /tmp/dk.bin
   openssl enc -d -aes-256-cbc -pbkdf2 -in /tmp/records.csv.enc \
     -pass file:/tmp/dk.bin | diff - /tmp/records.csv && echo "ROUND TRIP OK"
   shred -u /tmp/dk.bin
   ```

   ```
   ROUND TRIP OK
   ```

### Verification questions — Block 3B

- **Q3.4** — You encrypted a 46-byte file. Suppose it had been 400 GB. How many bytes would have crossed the network to the KMS API, and why is that the architectural argument for envelope encryption?
- **Q3.5** — In step 7 you called `kms:Decrypt` without naming a key. What does this imply about the structure of a KMS ciphertext blob, and what security property does it give you when auditing which key protected which object?
- **Q3.6** — If an attacker steals `/tmp/records.csv.enc` **and** `/tmp/wrapped-dk.b64` from your laptop, what do they still need to read the data? Which AWS control decides whether they get it?

### Block C — Let S3 do it for you (SSE-KMS + S3 Bucket Keys)

9. Attach the CMK as the bucket's default encryption, and enable S3 Bucket Keys.

   ```bash
   aws s3api put-bucket-encryption \
     --bucket "$EVIDENCE_BUCKET" \
     --server-side-encryption-configuration "$(cat <<JSON
   {
     "Rules": [
       {
         "ApplyServerSideEncryptionByDefault": {
           "SSEAlgorithm": "aws:kms",
           "KMSMasterKeyID": "arn:aws:kms:${AWS_REGION}:${AWS_ACCOUNT_ID}:alias/clf-lab-s3"
         },
         "BucketKeyEnabled": true
       }
     ]
   }
   JSON
   )"
   ```

10. Read the configuration back.

    ```bash
    aws s3api get-bucket-encryption --bucket "$EVIDENCE_BUCKET" | jq .
    ```

    ```json
    {
      "ServerSideEncryptionConfiguration": {
        "Rules": [
          {
            "ApplyServerSideEncryptionByDefault": {
              "SSEAlgorithm": "aws:kms",
              "KMSMasterKeyID": "arn:aws:kms:eu-west-1:111122223333:alias/clf-lab-s3"
            },
            "BucketKeyEnabled": true
          }
        ]
      }
    }
    ```

11. Upload the **plaintext** file and let S3 encrypt it server-side.

    ```bash
    aws s3api put-object \
      --bucket "$EVIDENCE_BUCKET" --key records.csv \
      --body /tmp/records.csv \
      --query '[ServerSideEncryption,SSEKMSKeyId,BucketKeyEnabled]' --output text
    ```

    ```
    aws:kms   arn:aws:kms:eu-west-1:111122223333:key/1234abcd-12ab-34cd-56ef-1234567890ab   True
    ```

12. Verify on the object itself — this is the evidence an auditor asks for.

    ```bash
    aws s3api head-object --bucket "$EVIDENCE_BUCKET" --key records.csv \
      | jq '{ServerSideEncryption, SSEKMSKeyId, BucketKeyEnabled, ContentLength}'
    ```

    ```json
    {
      "ServerSideEncryption": "aws:kms",
      "SSEKMSKeyId": "arn:aws:kms:eu-west-1:111122223333:key/1234abcd-12ab-34cd-56ef-1234567890ab",
      "BucketKeyEnabled": true,
      "ContentLength": 46
    }
    ```

13. Prove that the encryption is transparent to an authorized caller.

    ```bash
    aws s3 cp "s3://${EVIDENCE_BUCKET}/records.csv" - 
    ```

    ```
    patient_id,diagnosis_code
    4471,E11.9
    4472,I10
    ```

### Verification questions — Block 3C

- **Q3.7** — Step 13 returned plaintext with no decryption flag. Which two permissions did your principal need for that single command to succeed, and in which two different policy documents do they live?
- **Q3.8** — `BucketKeyEnabled: true` reduces KMS request charges by up to 99%. Describe the mechanism that achieves that reduction.
- **Q3.9** — Your CISO asks: "Is the data encrypted at rest?" and then "Can I prove AWS staff cannot read it?" Answer both, and identify which claim rests on AWS Artifact evidence rather than on your own configuration.
- **Q3.10** — Contrast SSE-S3 (`AES256`), SSE-KMS (`aws:kms`), and DSSE-KMS. When would a regulator's requirement force you off SSE-S3?

---

## Exercise 4 — Encryption in transit: TLS enforcement, ACM, and CloudHSM

Encryption at rest protects the disk. Encryption in transit protects the wire. **The exam expects you to know that neither is on by default for every path, and that you enforce transit encryption with policy, not with hope.**

### Steps

1. Observe that, by default, S3 will accept a plaintext HTTP request. Force the CLI onto an HTTP endpoint.

   ```bash
   aws s3api head-object \
     --bucket "$EVIDENCE_BUCKET" --key records.csv \
     --endpoint-url "http://s3.${AWS_REGION}.amazonaws.com" \
     --query 'ServerSideEncryption' --output text
   ```

   ```
   aws:kms
   ```

   The object is encrypted at rest, and your credentials just traversed an unencrypted channel to ask about it.

2. Write a bucket policy that denies non-TLS access **and** denies obsolete TLS versions.

   ```bash
   cat > /tmp/bucket-transit-policy.json <<JSON
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Sid": "DenyUnencryptedTransport",
         "Effect": "Deny",
         "Principal": "*",
         "Action": "s3:*",
         "Resource": [
           "arn:aws:s3:::${EVIDENCE_BUCKET}",
           "arn:aws:s3:::${EVIDENCE_BUCKET}/*"
         ],
         "Condition": {
           "Bool": {
             "aws:SecureTransport": "false"
           }
         }
       },
       {
         "Sid": "DenyOutdatedTlsVersions",
         "Effect": "Deny",
         "Principal": "*",
         "Action": "s3:*",
         "Resource": [
           "arn:aws:s3:::${EVIDENCE_BUCKET}",
           "arn:aws:s3:::${EVIDENCE_BUCKET}/*"
         ],
         "Condition": {
           "NumericLessThan": {
             "s3:TlsVersion": "1.2"
           }
         }
       },
       {
         "Sid": "DenyUnencryptedObjectUploads",
         "Effect": "Deny",
         "Principal": "*",
         "Action": "s3:PutObject",
         "Resource": "arn:aws:s3:::${EVIDENCE_BUCKET}/*",
         "Condition": {
           "StringNotEquals": {
             "s3:x-amz-server-side-encryption": "aws:kms"
           }
         }
       }
     ]
   }
   JSON

   aws s3api put-bucket-policy \
     --bucket "$EVIDENCE_BUCKET" \
     --policy file:///tmp/bucket-transit-policy.json
   ```

3. Re-run the plaintext request. It must now fail.

   ```bash
   aws s3api head-object \
     --bucket "$EVIDENCE_BUCKET" --key records.csv \
     --endpoint-url "http://s3.${AWS_REGION}.amazonaws.com"
   ```

   ```
   An error occurred (403) when calling the HeadObject operation: Forbidden
   ```

4. Confirm the HTTPS path still works.

   ```bash
   aws s3api head-object --bucket "$EVIDENCE_BUCKET" --key records.csv \
     --query 'ContentLength' --output text
   ```

   ```
   46
   ```

5. Inspect the actual TLS negotiation with the S3 endpoint. Read the protocol, cipher, and certificate chain.

   ```bash
   openssl s_client -connect "s3.${AWS_REGION}.amazonaws.com:443" \
     -servername "s3.${AWS_REGION}.amazonaws.com" </dev/null 2>/dev/null \
     | grep -E 'Protocol|Cipher|subject=|issuer='
   ```

   ```
   subject=CN=s3.eu-west-1.amazonaws.com
   issuer=C=US, O=Amazon, CN=Amazon RSA 2048 M03
   Protocol  : TLSv1.3
   Cipher    : TLS_AES_128_GCM_SHA256
   ```

6. List the certificates AWS Certificate Manager manages for you. ACM is how *your* endpoints get free, auto-renewing TLS certificates.

   ```bash
   aws acm list-certificates \
     --query 'CertificateSummaryList[].[DomainName,Status,Type,NotAfter]' --output table
   ```

   ```
   -------------------------------------------------------------------------
   |                           ListCertificates                            |
   +-------------------+-----------+------------------+--------------------+
   |  study.example.io |  ISSUED   |  AMAZON_ISSUED   | 2027-04-11T12:00:00|
   +-------------------+-----------+------------------+--------------------+
   ```

   (An empty list is a valid result if you have never requested one.)

7. Confirm that no CloudHSM cluster exists — and understand what its absence means.

   ```bash
   aws cloudhsmv2 describe-clusters --query 'Clusters[].[ClusterId,State,HsmType]' --output text
   ```

   ```
   (empty output — no clusters)
   ```

### Verification questions — Block 4

- **Q4.1** — In step 1 the object was encrypted at rest yet the request was insecure. Write, in one sentence each, what "encryption at rest" and "encryption in transit" each protect against, and name the specific attack that step 1 was exposed to.
- **Q4.2** — The `DenyUnencryptedTransport` statement uses `"Principal": "*"` with `Effect: Deny`. Why is a wildcard principal safe — indeed required — here, whereas it would be dangerous in an `Allow` statement?
- **Q4.3** — Step 5 shows `Amazon RSA 2048 M03` as the issuer. Who is responsible for renewing that certificate: you, or AWS? Now answer the same question for the certificate in step 6.
- **Q4.4** — Your organization's regulator requires that key material be stored in a **single-tenant, FIPS 140-3 Level 3 validated HSM that you exclusively control, and that AWS cannot access**. Which service satisfies this, and what operational responsibility does choosing it transfer to you?
- **Q4.5** — Rank these three for a team that wants TLS on a public web endpoint with zero renewal toil: ACM, CloudHSM, KMS. Justify why the other two are the wrong answer.

---

## Exercise 5 — Auditing the control plane with AWS CloudTrail

**CloudTrail answers "who did what, when, from where".** It is the evidentiary backbone of every AWS audit. This block builds a trail with cryptographic log-file validation, then proves tamper-evidence.

### Steps

1. Create a dedicated bucket for the logs and apply the CloudTrail service policy.

   ```bash
   aws s3api create-bucket --bucket "$TRAIL_BUCKET" --region "$AWS_REGION" \
     --create-bucket-configuration LocationConstraint="$AWS_REGION" >/dev/null

   aws s3api put-public-access-block --bucket "$TRAIL_BUCKET" \
     --public-access-block-configuration \
     "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

   cat > /tmp/trail-bucket-policy.json <<JSON
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Sid": "AWSCloudTrailAclCheck",
         "Effect": "Allow",
         "Principal": { "Service": "cloudtrail.amazonaws.com" },
         "Action": "s3:GetBucketAcl",
         "Resource": "arn:aws:s3:::${TRAIL_BUCKET}",
         "Condition": {
           "StringEquals": {
             "aws:SourceArn": "arn:aws:cloudtrail:${AWS_REGION}:${AWS_ACCOUNT_ID}:trail/clf-lab-trail"
           }
         }
       },
       {
         "Sid": "AWSCloudTrailWrite",
         "Effect": "Allow",
         "Principal": { "Service": "cloudtrail.amazonaws.com" },
         "Action": "s3:PutObject",
         "Resource": "arn:aws:s3:::${TRAIL_BUCKET}/AWSLogs/${AWS_ACCOUNT_ID}/*",
         "Condition": {
           "StringEquals": {
             "s3:x-amz-acl": "bucket-owner-full-control",
             "aws:SourceArn": "arn:aws:cloudtrail:${AWS_REGION}:${AWS_ACCOUNT_ID}:trail/clf-lab-trail"
           }
         }
       }
     ]
   }
   JSON

   aws s3api put-bucket-policy --bucket "$TRAIL_BUCKET" \
     --policy file:///tmp/trail-bucket-policy.json
   ```

2. Create a multi-Region trail with **log file validation enabled**. Both flags matter for an audit.

   ```bash
   aws cloudtrail create-trail \
     --name clf-lab-trail \
     --s3-bucket-name "$TRAIL_BUCKET" \
     --is-multi-region-trail \
     --include-global-service-events \
     --enable-log-file-validation \
     --query '[Name,IsMultiRegionTrail,LogFileValidationEnabled,TrailARN]' --output text
   ```

   ```
   clf-lab-trail   True    True    arn:aws:cloudtrail:eu-west-1:111122223333:trail/clf-lab-trail
   ```

3. Start logging. **A created trail is not a logging trail.**

   ```bash
   aws cloudtrail start-logging --name clf-lab-trail
   aws cloudtrail get-trail-status --name clf-lab-trail \
     --query '[IsLogging,LatestDeliveryTime]' --output text
   ```

   ```
   True    None
   ```

4. Add a **data event** selector for the evidence bucket. Management events are on by default; object-level reads and writes are not.

   ```bash
   aws cloudtrail put-event-selectors \
     --trail-name clf-lab-trail \
     --advanced-event-selectors "$(cat <<JSON
   [
     {
       "Name": "Management events",
       "FieldSelectors": [
         { "Field": "eventCategory", "Equals": ["Management"] }
       ]
     },
     {
       "Name": "S3 object-level events on the evidence bucket",
       "FieldSelectors": [
         { "Field": "eventCategory", "Equals": ["Data"] },
         { "Field": "resources.type", "Equals": ["AWS::S3::Object"] },
         { "Field": "resources.ARN", "StartsWith": ["arn:aws:s3:::${EVIDENCE_BUCKET}/"] }
       ]
     }
   ]
   JSON
   )" --query 'AdvancedEventSelectors[].Name' --output text
   ```

   ```
   Management events       S3 object-level events on the evidence bucket
   ```

5. Generate an auditable action, then find it. **Wait 5–15 minutes** — CloudTrail Event history is near-real-time, not real-time.

   ```bash
   aws s3api put-bucket-tagging --bucket "$EVIDENCE_BUCKET" \
     --tagging 'TagSet=[{Key=DataClassification,Value=Confidential}]'

   sleep 600

   aws cloudtrail lookup-events \
     --lookup-attributes AttributeKey=EventName,AttributeValue=PutBucketTagging \
     --max-results 1 \
     --query 'Events[0].[EventTime,Username,EventName,Resources[0].ResourceName]' \
     --output text
   ```

   ```
   2026-09-03T10:41:07+00:00  lab-admin  PutBucketTagging  clf-lab-evidence-111122223333-clf22
   ```

6. Read the full event record. Every field here is a question an auditor will ask.

   ```bash
   aws cloudtrail lookup-events \
     --lookup-attributes AttributeKey=EventName,AttributeValue=PutBucketTagging \
     --max-results 1 --query 'Events[0].CloudTrailEvent' --output text \
     | jq '{eventTime, eventSource, eventName, awsRegion, sourceIPAddress,
            userAgent, userIdentity: .userIdentity.arn, errorCode, readOnly, managementEvent}'
   ```

   ```json
   {
     "eventTime": "2026-09-03T10:41:07Z",
     "eventSource": "s3.amazonaws.com",
     "eventName": "PutBucketTagging",
     "awsRegion": "eu-west-1",
     "sourceIPAddress": "203.0.113.47",
     "userAgent": "aws-cli/2.19.4 md/awscrt#0.23.4 ua/2.0 os/linux#6.11.0",
     "userIdentity": "arn:aws:iam::111122223333:user/lab-admin",
     "errorCode": null,
     "readOnly": false,
     "managementEvent": true
   }
   ```

7. Verify the integrity of the delivered log files. This is the tamper-evidence control.

   ```bash
   aws cloudtrail validate-logs \
     --trail-arn "arn:aws:cloudtrail:${AWS_REGION}:${AWS_ACCOUNT_ID}:trail/clf-lab-trail" \
     --start-time "$(date -u -d '3 hours ago' +%Y-%m-%dT%H:%M:%SZ)"
   ```

   ```
   Validating log files for trail arn:aws:cloudtrail:eu-west-1:111122223333:trail/clf-lab-trail
   between 2026-09-03T08:00:00Z and 2026-09-03T11:00:00Z

   Results requested for 2026-09-03T08:00:00Z to 2026-09-03T11:00:00Z
   Results found for 2026-09-03T08:42:11Z to 2026-09-03T10:55:03Z:

   2/2 digest files valid
   5/5 log files valid
   ```

8. Simulate tampering, then re-validate. **Do this on the lab bucket only.**

   ```bash
   OBJ=$(aws s3api list-objects-v2 --bucket "$TRAIL_BUCKET" \
     --prefix "AWSLogs/${AWS_ACCOUNT_ID}/CloudTrail/" \
     --query 'Contents[0].Key' --output text)
   echo "tampering with: $OBJ"
   printf 'corrupted' | aws s3 cp - "s3://${TRAIL_BUCKET}/${OBJ}"

   aws cloudtrail validate-logs \
     --trail-arn "arn:aws:cloudtrail:${AWS_REGION}:${AWS_ACCOUNT_ID}:trail/clf-lab-trail" \
     --start-time "$(date -u -d '3 hours ago' +%Y-%m-%dT%H:%M:%SZ)" 2>&1 | tail -6
   ```

   ```
   Results found for 2026-09-03T08:42:11Z to 2026-09-03T10:55:03Z:

   2/2 digest files valid
   4/5 log files valid
   Log file  s3://clf-lab-trail-111122223333-clf22/AWSLogs/111122223333/CloudTrail/eu-west-1/2026/09/03/111122223333_CloudTrail_eu-west-1_20260903T0845Z_a1B2c3D4.json.gz
   INVALID: hash value doesn't match
   ```

### Verification questions — Block 5

- **Q5.1** — Step 3 was necessary even though step 2 created the trail. Describe a realistic audit failure caused by skipping it, and name the API call that would have caught it.
- **Q5.2** — Management events are recorded by default; the data-event selector in step 4 had to be added explicitly. Give the two reasons — one financial, one about volume — that AWS made this the default.
- **Q5.3** — In step 8 the log file failed validation but the digest files remained valid. Explain the chain-of-custody structure that makes this possible, and state clearly whether log file validation *prevents* tampering or *detects* it.
- **Q5.4** — CloudTrail records `sourceIPAddress` and `userAgent`. Which specific compliance question does each field answer, and which service would you pair with CloudTrail to detect that a set of these events constitutes an attack rather than routine work?
- **Q5.5** — Distinguish CloudTrail from Amazon CloudWatch in one sentence each. Then place these four items in the right column: an API call that deleted a security group; CPU utilization at 94%; a Lambda function's `print()` output; the identity that disabled a KMS key.

---

## Exercise 6 — Continuous compliance with AWS Config

**CloudTrail tells you what happened. AWS Config tells you what the resource looks like now, what it looked like before, and whether that violates a rule.** This is the service that answers "prove the bucket has been encrypted for 12 months".

> **Cost:** AWS Config bills per configuration item recorded and per rule evaluation. This block records a narrow resource scope. Exercise 9 stops the recorder.

### Steps

1. Create the service-linked role Config needs.

   ```bash
   aws iam create-service-linked-role --aws-service-name config.amazonaws.com \
     --query 'Role.Arn' --output text 2>/dev/null \
     || aws iam get-role --role-name AWSServiceRoleForConfig --query 'Role.Arn' --output text
   ```

   ```
   arn:aws:iam::111122223333:role/aws-service-role/config.amazonaws.com/AWSServiceRoleForConfig
   ```

2. Create the delivery channel bucket and its policy.

   ```bash
   export CONFIG_BUCKET="clf-lab-config-${LAB_SUFFIX}"
   aws s3api create-bucket --bucket "$CONFIG_BUCKET" --region "$AWS_REGION" \
     --create-bucket-configuration LocationConstraint="$AWS_REGION" >/dev/null

   cat > /tmp/config-bucket-policy.json <<JSON
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Sid": "AWSConfigBucketPermissionsCheck",
         "Effect": "Allow",
         "Principal": { "Service": "config.amazonaws.com" },
         "Action": ["s3:GetBucketAcl", "s3:ListBucket"],
         "Resource": "arn:aws:s3:::${CONFIG_BUCKET}",
         "Condition": { "StringEquals": { "aws:SourceAccount": "${AWS_ACCOUNT_ID}" } }
       },
       {
         "Sid": "AWSConfigBucketDelivery",
         "Effect": "Allow",
         "Principal": { "Service": "config.amazonaws.com" },
         "Action": "s3:PutObject",
         "Resource": "arn:aws:s3:::${CONFIG_BUCKET}/AWSLogs/${AWS_ACCOUNT_ID}/Config/*",
         "Condition": {
           "StringEquals": {
             "s3:x-amz-acl": "bucket-owner-full-control",
             "aws:SourceAccount": "${AWS_ACCOUNT_ID}"
           }
         }
       }
     ]
   }
   JSON

   aws s3api put-bucket-policy --bucket "$CONFIG_BUCKET" --policy file:///tmp/config-bucket-policy.json
   ```

3. Configure the recorder with a **narrow** resource scope to control cost.

   ```bash
   aws configservice put-configuration-recorder \
     --configuration-recorder "name=clf-lab-recorder,roleARN=arn:aws:iam::${AWS_ACCOUNT_ID}:role/aws-service-role/config.amazonaws.com/AWSServiceRoleForConfig" \
     --recording-group "allSupported=false,includeGlobalResourceTypes=false,resourceTypes=AWS::S3::Bucket,AWS::KMS::Key,AWS::CloudTrail::Trail"

   aws configservice put-delivery-channel \
     --delivery-channel "name=clf-lab-channel,s3BucketName=${CONFIG_BUCKET}"

   aws configservice start-configuration-recorder --configuration-recorder-name clf-lab-recorder
   aws configservice describe-configuration-recorder-status \
     --query 'ConfigurationRecordersStatus[0].[name,recording,lastStatus]' --output text
   ```

   ```
   clf-lab-recorder   True   SUCCESS
   ```

4. Deploy an **AWS managed rule** that continuously checks S3 default encryption.

   ```bash
   aws configservice put-config-rule --config-rule "$(cat <<'JSON'
   {
     "ConfigRuleName": "clf-lab-s3-sse-enabled",
     "Description": "Checks that S3 buckets have default server-side encryption enabled",
     "Scope": { "ComplianceResourceTypes": ["AWS::S3::Bucket"] },
     "Source": {
       "Owner": "AWS",
       "SourceIdentifier": "S3_BUCKET_SERVER_SIDE_ENCRYPTION_ENABLED"
     }
   }
   JSON
   )"
   ```

5. Add a second rule that enforces the transit control you built in Exercise 4.

   ```bash
   aws configservice put-config-rule --config-rule "$(cat <<'JSON'
   {
     "ConfigRuleName": "clf-lab-s3-ssl-requests-only",
     "Description": "Checks that S3 bucket policies deny requests over plain HTTP",
     "Scope": { "ComplianceResourceTypes": ["AWS::S3::Bucket"] },
     "Source": {
       "Owner": "AWS",
       "SourceIdentifier": "S3_BUCKET_SSL_REQUESTS_ONLY"
     }
   }
   JSON
   )"
   ```

6. Force evaluation and wait for results.

   ```bash
   aws configservice start-config-rules-evaluation \
     --config-rule-names clf-lab-s3-sse-enabled clf-lab-s3-ssl-requests-only
   sleep 120
   ```

7. Read the compliance verdict per resource.

   ```bash
   aws configservice get-compliance-details-by-config-rule \
     --config-rule-name clf-lab-s3-ssl-requests-only \
     --query 'EvaluationResults[].[EvaluationResultIdentifier.EvaluationResultQualifier.ResourceId,ComplianceType]' \
     --output table
   ```

   ```
   ---------------------------------------------------------------------
   |                 GetComplianceDetailsByConfigRule                  |
   +-------------------------------------------------+-----------------+
   |  clf-lab-config-111122223333-clf22               |  NON_COMPLIANT  |
   |  clf-lab-evidence-111122223333-clf22             |  COMPLIANT      |
   |  clf-lab-trail-111122223333-clf22                |  NON_COMPLIANT  |
   +-------------------------------------------------+-----------------+
   ```

8. Get the account-level roll-up — the number that goes on a governance dashboard.

   ```bash
   aws configservice get-compliance-summary-by-config-rule
   ```

   ```json
   {
       "ComplianceSummary": {
           "CompliantResourceCount": {
               "CappedCount": 1,
               "CapExceeded": false
           },
           "NonCompliantResourceCount": {
               "CappedCount": 1,
               "CapExceeded": false
           },
           "ComplianceSummaryTimestamp": "2026-09-03T11:12:44.187000+00:00"
       }
   }
   ```

9. Query the **configuration history** — this is what Artifact cannot give you.

   ```bash
   aws configservice get-resource-config-history \
     --resource-type AWS::S3::Bucket \
     --resource-id "$EVIDENCE_BUCKET" \
     --limit 3 \
     --query 'configurationItems[].[configurationItemCaptureTime,configurationItemStatus,resourceId]' \
     --output table
   ```

   ```
   -----------------------------------------------------------------------------------------
   |                             GetResourceConfigHistory                                  |
   +--------------------------------------+-------------+----------------------------------+
   |  2026-09-03T10:41:19.402000+00:00    |  OK         |  clf-lab-evidence-...-clf22      |
   |  2026-09-03T10:28:55.771000+00:00    |  OK         |  clf-lab-evidence-...-clf22      |
   |  2026-09-03T10:22:03.118000+00:00    |  OK         |  clf-lab-evidence-...-clf22      |
   +--------------------------------------+-------------+----------------------------------+
   ```

10. Remediate the finding from step 7 by applying the transit policy to the trail bucket, then re-evaluate.

    ```bash
    sed "s/${EVIDENCE_BUCKET}/${TRAIL_BUCKET}/g" /tmp/bucket-transit-policy.json \
      | jq 'del(.Statement[] | select(.Sid == "DenyUnencryptedObjectUploads"))' \
      > /tmp/trail-transit.json

    aws s3api get-bucket-policy --bucket "$TRAIL_BUCKET" --query Policy --output text \
      | jq --slurpfile add /tmp/trail-transit.json \
        '.Statement += $add[0].Statement' > /tmp/trail-merged.json

    aws s3api put-bucket-policy --bucket "$TRAIL_BUCKET" --policy file:///tmp/trail-merged.json
    aws configservice start-config-rules-evaluation --config-rule-names clf-lab-s3-ssl-requests-only
    sleep 120
    aws configservice get-compliance-details-by-config-rule \
      --config-rule-name clf-lab-s3-ssl-requests-only \
      --query 'EvaluationResults[?EvaluationResultIdentifier.EvaluationResultQualifier.ResourceId==`'"$TRAIL_BUCKET"'`].ComplianceType' \
      --output text
    ```

    ```
    COMPLIANT
    ```

### Verification questions — Block 6

- **Q6.1** — Step 9 returned a timeline of configuration snapshots. State the audit question this answers that neither CloudTrail nor AWS Artifact can answer alone.
- **Q6.2** — The rule in step 4 has `"Owner": "AWS"`. What is the alternative owner value, what would it require you to build, and why do the exam objectives emphasise the managed-rule path?
- **Q6.3** — Config reported the *trail* bucket as `NON_COMPLIANT` for `S3_BUCKET_SSL_REQUESTS_ONLY` while the *evidence* bucket was compliant. What does this tell you about how the rule evaluates, and what was actually different between the two buckets?
- **Q6.4** — Define a **conformance pack** and explain why an organization mapping to PCI DSS would deploy one rather than 60 individual `put-config-rule` calls.
- **Q6.5** — You must place these three services correctly. For each of the following, name the *one* service that is the primary answer: (a) "show me every change made to this security group over six months"; (b) "show me who deleted it and from which IP"; (c) "show me AWS's ISO 27001 certificate".

---

## Exercise 7 — Threat detection and security posture services

Four services, four different inputs, four different outputs. **The exam tests the mapping, not the configuration.** This block makes each one produce a real artifact so the mapping sticks.

> **Cost:** GuardDuty, Inspector and Macie are free for 30 days per account, then billed. Security Hub bills from the first check. Exercise 9 disables all of them.

### Block A — Amazon GuardDuty: continuous threat detection from telemetry

1. Enable a detector. Note the inputs GuardDuty consumes — you never point it at a log bucket.

   ```bash
   aws guardduty create-detector --enable \
     --finding-publishing-frequency FIFTEEN_MINUTES \
     --query 'DetectorId' --output text
   ```

   ```
   d4c3b2a1e5f6789012345678abcdef01
   ```

   ```bash
   export DETECTOR_ID=d4c3b2a1e5f6789012345678abcdef01
   aws guardduty get-detector --detector-id "$DETECTOR_ID" \
     --query '[Status,ServiceRole,FindingPublishingFrequency]' --output text
   ```

   ```
   ENABLED  arn:aws:iam::111122223333:role/aws-service-role/guardduty.amazonaws.com/AWSServiceRoleForAmazonGuardDuty  FIFTEEN_MINUTES
   ```

2. Generate sample findings so you can inspect the finding schema without being attacked.

   ```bash
   aws guardduty create-sample-findings --detector-id "$DETECTOR_ID" \
     --finding-types "UnauthorizedAccess:EC2/SSHBruteForce" \
                     "CryptoCurrency:EC2/BitcoinTool.B!DNS" \
                     "Policy:IAMUser/RootCredentialUsage"
   sleep 20
   ```

3. List and read one finding.

   ```bash
   aws guardduty list-findings --detector-id "$DETECTOR_ID" --max-results 3 \
     --query 'FindingIds' --output text | tr '\t' '\n'
   ```

   ```
   1ac4d8e2f9b7a3c5d1e0f2a4b6c8d0e2
   2bd5e9f3a0c8b4d6e2f1a3b5c7d9e1f3
   3ce6f0a4b1d9c5e7f3a2b4c6d8e0f2a4
   ```

   ```bash
   aws guardduty get-findings --detector-id "$DETECTOR_ID" \
     --finding-ids 1ac4d8e2f9b7a3c5d1e0f2a4b6c8d0e2 \
     --query 'Findings[0].[Type,Severity,Title,Service.ResourceRole,Service.DetectorId]' --output text
   ```

   ```
   UnauthorizedAccess:EC2/SSHBruteForce   2   [SAMPLE] 198.51.100.0 is performing SSH brute force attacks against i-99999999   TARGET   d4c3b2a1e5f6789012345678abcdef01
   ```

4. Confirm which data sources are feeding the detector.

   ```bash
   aws guardduty list-detector-features --detector-id "$DETECTOR_ID" 2>/dev/null \
     || aws guardduty get-detector --detector-id "$DETECTOR_ID" --query 'Features[].[Name,Status]' --output table
   ```

   ```
   -----------------------------------------------
   |                 GetDetector                 |
   +----------------------------+----------------+
   |  CLOUD_TRAIL               |  ENABLED       |
   |  DNS_LOGS                  |  ENABLED       |
   |  FLOW_LOGS                 |  ENABLED       |
   |  S3_DATA_EVENTS            |  ENABLED       |
   |  EKS_AUDIT_LOGS            |  DISABLED      |
   |  EBS_MALWARE_PROTECTION    |  DISABLED      |
   |  RDS_LOGIN_EVENTS          |  DISABLED      |
   +----------------------------+----------------+
   ```

### Verification questions — Block 7A

- **Q7.1** — The `CLOUD_TRAIL` data source is `ENABLED` even though you never granted GuardDuty access to the trail bucket from Exercise 5. Explain how GuardDuty reads that telemetry and what practical consequence this has for cost and for the possibility of an attacker blinding it.
- **Q7.2** — Finding type `Policy:IAMUser/RootCredentialUsage` is severity-low but many organizations treat it as a page-the-on-call event. Why?
- **Q7.3** — A colleague asks whether GuardDuty will find the unpatched `log4j` library on an EC2 instance. Answer, and name the service that will.

### Block B — Amazon Inspector, Amazon Macie, AWS Security Hub, Amazon Detective

5. Enable Amazon Inspector for the resource types it scans.

   ```bash
   aws inspector2 enable --resource-types EC2 ECR LAMBDA \
     --query 'accounts[].[accountId,state.status]' --output text
   ```

   ```
   111122223333   ENABLING
   ```

   ```bash
   sleep 30
   aws inspector2 batch-get-account-status \
     --query 'accounts[0].resourceState.[ec2.status,ecr.status,lambda.status]' --output text
   ```

   ```
   ENABLED  ENABLED  ENABLED
   ```

6. Query Inspector's coverage. With no instances running, the finding count is zero — and that is itself informative.

   ```bash
   aws inspector2 list-coverage --query 'coveredResources[].[resourceType,scanStatus.statusCode]' --output text
   aws inspector2 list-findings --max-results 5 --query 'findings[].[severity,type,title]' --output text
   ```

   ```
   (no output — no scannable resources in this account)
   ```

7. Enable Amazon Macie and inspect what it classifies.

   ```bash
   aws macie2 enable-macie --status ENABLED --finding-publishing-frequency FIFTEEN_MINUTES
   aws macie2 get-macie-session --query '[status,serviceRole,createdAt]' --output text
   ```

   ```
   ENABLED  arn:aws:iam::111122223333:role/aws-service-role/macie.amazonaws.com/AWSServiceRoleForAmazonMacie  2026-09-03T11:31:02.554000+00:00
   ```

   ```bash
   aws macie2 list-managed-data-identifiers \
     --query 'items[?category==`PERSONAL_INFORMATION`].id' --output text | tr '\t' '\n' | head -8
   ```

   ```
   ADDRESS
   DRIVERS_LICENSE_ID_US
   NATIONAL_IDENTIFICATION_NUMBER_ES
   PASSPORT_NUMBER_US
   PHONE_NUMBER_US
   USA_SOCIAL_SECURITY_NUMBER
   USA_INDIVIDUAL_TAX_IDENTIFICATION_NUMBER
   DATE_OF_BIRTH
   ```

8. Enable AWS Security Hub with default standards. This is the aggregation layer.

   ```bash
   aws securityhub enable-security-hub --enable-default-standards \
     --tags Purpose=clf-c02-lab
   sleep 60
   aws securityhub get-enabled-standards \
     --query 'StandardsSubscriptions[].[StandardsArn,StandardsStatus]' --output text
   ```

   ```
   arn:aws:securityhub:eu-west-1::standards/aws-foundational-security-best-practices/v/1.0.0   READY
   arn:aws:securityhub:::ruleset/cis-aws-foundations-benchmark/v/1.2.0                          READY
   ```

9. Confirm Security Hub is ingesting from the other services. **The product name column is the entire lesson.**

   ```bash
   sleep 300
   aws securityhub get-findings --max-results 50 \
     --query 'Findings[].ProductName' --output text | tr '\t' '\n' | sort | uniq -c | sort -rn
   ```

   ```
        31 Security Hub
         3 GuardDuty
         1 Inspector
   ```

10. Read one finding in **ASFF** (AWS Security Finding Format) — the normalization that makes aggregation possible.

    ```bash
    aws securityhub get-findings --max-results 1 \
      --filters '{"ProductName":[{"Value":"GuardDuty","Comparison":"EQUALS"}]}' \
      --query 'Findings[0].[ProductName,Title,Severity.Label,Compliance.Status,Workflow.Status,RecordState]' \
      --output text
    ```

    ```
    GuardDuty   [SAMPLE] 198.51.100.0 is performing SSH brute force attacks against i-99999999   LOW   None   NEW   ACTIVE
    ```

11. Look at a control-check finding to see the compliance framing.

    ```bash
    aws securityhub get-findings --max-results 1 \
      --filters '{"ComplianceStatus":[{"Value":"FAILED","Comparison":"EQUALS"}]}' \
      --query 'Findings[0].[Title,Severity.Label,Compliance.Status,Compliance.RelatedRequirements]' \
      --output text
    ```

    ```
    S3.8 S3 Block Public Access setting should be enabled at the bucket level   HIGH   FAILED   ['CIS AWS Foundations Benchmark v1.2.0/2.1.5', 'PCI DSS v3.2.1/1.2.1']
    ```

12. Note that Amazon Detective, if enabled, would build a behaviour graph from the same telemetry — for **investigation**, not detection.

    ```bash
    aws detective list-graphs --query 'GraphList[].[Arn,CreatedTime]' --output text
    ```

    ```
    (empty — no behavior graph in this account)
    ```

### Verification questions — Block 7B

- **Q7.4** — Complete this mapping with exactly one service per row, and state what each one *ingests*:

  | Question | Service | Ingests |
  |---|---|---|
  | Is there a CVE in the OS packages on my EC2 fleet or in my container images? | | |
  | Is there personally identifiable information sitting in my S3 buckets? | | |
  | Is a compromised credential exfiltrating data right now? | | |
  | Where do all of the above findings appear on one screen, scored against CIS and PCI? | | |
  | Which other resources did this compromised role touch over the last 90 days? | | |

- **Q7.5** — Step 9 shows Security Hub's own product name with 31 findings alongside 3 from GuardDuty. What generates the 31, and why does that distinction matter when someone claims "Security Hub is a detection service"?
- **Q7.6** — The finding in step 11 lists both `CIS AWS Foundations Benchmark v1.2.0/2.1.5` and `PCI DSS v3.2.1/1.2.1`. Explain the governance value of one technical check mapping to multiple frameworks.
- **Q7.7** — Macie's managed data identifiers include `NATIONAL_IDENTIFICATION_NUMBER_ES`. Connect this to Exercise 2: how do Macie and a data-residency guardrail combine into a single GDPR control narrative?
- **Q7.8** — A cryptomining finding fires on an EC2 instance. Order these four services by when you would open each one during the incident: GuardDuty, Detective, Security Hub, CloudTrail. Justify the order.

---

## Exercise 8 — Governance at scale: Organizations, Control Tower, Audit Manager, License Manager, Trusted Advisor

The final block is mostly read-only and conceptual, because these services either require an organization or a paid support plan. **The exam tests which tool solves which governance problem.**

### Steps

1. Determine whether this account is in an organization and what its posture is.

   ```bash
   aws organizations describe-organization \
     --query 'Organization.[Id,FeatureSet,MasterAccountEmail]' --output text 2>&1
   ```

   ```
   o-a1b2c3d4e5   ALL   billing@example.com
   ```

   or, for a standalone account:

   ```
   An error occurred (AWSOrganizationsNotInUseException) when calling the
   DescribeOrganization operation: Your account is not a member of an organization.
   ```

2. If in an organization, enumerate the policy types available at the root.

   ```bash
   aws organizations list-roots --query 'Roots[0].PolicyTypes' --output table
   ```

   ```
   -------------------------------------------------
   |                   ListRoots                   |
   +--------------------------------+--------------+
   |              Type              |    Status    |
   +--------------------------------+--------------+
   |  SERVICE_CONTROL_POLICY        |  ENABLED     |
   |  TAG_POLICY                    |  ENABLED     |
   |  BACKUP_POLICY                 |  NOT_ENABLED |
   |  AISERVICES_OPT_OUT_POLICY     |  NOT_ENABLED |
   +--------------------------------+--------------+
   ```

3. Check whether AWS Control Tower has established a landing zone.

   ```bash
   aws controltower list-landing-zones --query 'landingZones[].arn' --output text
   ```

   ```
   arn:aws:controltower:eu-west-1:111122223333:landingzone/1A2B3C4D5E6F7G8H
   ```

   or, if never set up:

   ```
   (empty output)
   ```

4. Check AWS Audit Manager. Look at the *frameworks*, which are the pre-built control mappings.

   ```bash
   aws auditmanager get-account-status --query 'status' --output text 2>&1
   ```

   ```
   INACTIVE
   ```

   ```bash
   aws auditmanager list-assessment-frameworks --framework-type Standard \
     --query 'frameworkMetadataList[].[name,controlsCount]' --output table 2>/dev/null | head -12
   ```

   ```
   -------------------------------------------------------------
   |               ListAssessmentFrameworks                    |
   +--------------------------------------------+--------------+
   |  AWS Audit Manager Sample Framework         |  8           |
   |  CIS AWS Foundations Benchmark v1.4.0 L1    |  43          |
   |  GDPR 2016/679                              |  134         |
   |  HIPAA Security Rule 2003                   |  60          |
   |  ISO/IEC 27001:2013 Annex A                 |  114         |
   |  PCI DSS V3.2.1                             |  128         |
   |  SOC 2                                      |  61          |
   +--------------------------------------------+--------------+
   ```

5. Query AWS Trusted Advisor. **This requires a Business, Enterprise On-Ramp, or Enterprise Support plan** for the API and the full check set.

   ```bash
   aws support describe-trusted-advisor-checks --language en \
     --query 'checks[?category==`security`].[name]' --output text --region us-east-1
   ```

   ```
   Security Groups - Specific Ports Unrestricted
   Security Groups - Unrestricted Access
   IAM Use
   MFA on Root Account
   Amazon S3 Bucket Permissions
   Amazon RDS Security Group Access Risk
   AWS CloudTrail Logging
   Exposed Access Keys
   ELB Listener Security
   ```

   On Basic or Developer support:

   ```
   An error occurred (SubscriptionRequiredException) when calling the
   DescribeTrustedAdvisorChecks operation: AWS Premium Support Subscription is required
   to use this service.
   ```

6. Check AWS License Manager for tracked licenses — the governance service for BYOL compliance.

   ```bash
   aws license-manager list-license-configurations \
     --query 'LicenseConfigurations[].[Name,LicenseCountingType,LicenseCount,ConsumedLicenses]' --output table
   ```

   ```
   (empty — no license configurations defined)
   ```

7. Build the decision matrix yourself before reading the answers. Fill in the middle column.

   | Governance problem | Service | Why not the neighbours |
   |---|---|---|
   | Central multi-account billing and an SCP guardrail hierarchy | | |
   | Stand up a compliant multi-account landing zone in an afternoon, with pre-configured guardrails | | |
   | Continuously collect evidence and map it to SOC 2 controls, ready for an auditor | | |
   | Prove I am not over-deploying my 50-core Oracle BYOL entitlement | | |
   | Get proactive best-practice checks on cost, performance, security, fault tolerance, and service limits | | |
   | Obtain AWS's own PCI DSS Attestation of Compliance | | |

### Verification questions — Block 8

- **Q8.1** — Control Tower and Organizations are frequently confused. State the relationship between them precisely, then answer: can you use Control Tower without Organizations?
- **Q8.2** — Audit Manager offers a "GDPR 2016/679" framework with 134 controls. Does deploying that framework make your workload GDPR compliant? What does it actually produce, and who remains accountable?
- **Q8.3** — Trusted Advisor has five check categories. Name them, and identify which single category is available in full on the Basic support plan versus which are gated.
- **Q8.4** — A `TAG_POLICY` is `ENABLED` at the root in step 2. Give one concrete compliance use for tag policies that an SCP cannot achieve.
- **Q8.5** — Your organization must report a suspected abuse of AWS resources — an EC2 instance in someone else's account is port-scanning yours. Which AWS channel do you use, and is this a customer or an AWS responsibility under the shared responsibility model?
- **Q8.6** — Place each of the following on the correct side of the shared responsibility line: hypervisor patching, guest OS patching, physical destruction of decommissioned disks, S3 bucket policy configuration, KMS key policy configuration, the durability of the S3 storage layer, IAM user MFA enforcement, DDoS protection of the AWS global network edge.

---

## Exercise 9 — Cleanup

Run this in full. Config, Security Hub, GuardDuty, Inspector, and Macie all continue billing until disabled.

```bash
# --- Detection and posture services -----------------------------------------
aws securityhub disable-security-hub
aws guardduty delete-detector --detector-id "$DETECTOR_ID"
aws inspector2 disable --resource-types EC2 ECR LAMBDA
aws macie2 disable-macie

# --- AWS Config --------------------------------------------------------------
aws configservice delete-config-rule --config-rule-name clf-lab-s3-sse-enabled
aws configservice delete-config-rule --config-rule-name clf-lab-s3-ssl-requests-only
aws configservice stop-configuration-recorder --configuration-recorder-name clf-lab-recorder
aws configservice delete-delivery-channel --delivery-channel-name clf-lab-channel
aws configservice delete-configuration-recorder --configuration-recorder-name clf-lab-recorder

# --- CloudTrail --------------------------------------------------------------
aws cloudtrail stop-logging --name clf-lab-trail
aws cloudtrail delete-trail --name clf-lab-trail

# --- Organizations SCP (only if Block 2C was run) ---------------------------
# aws organizations detach-policy --policy-id p-x9y8z7w6 --target-id "$OU_ID"
# aws organizations delete-policy --policy-id p-x9y8z7w6

# --- S3 buckets --------------------------------------------------------------
for B in "$EVIDENCE_BUCKET" "$TRAIL_BUCKET" "$CONFIG_BUCKET"; do
  aws s3 rm "s3://${B}" --recursive >/dev/null 2>&1
  aws s3api delete-bucket --bucket "$B" 2>/dev/null && echo "deleted bucket ${B}"
done

# --- KMS: schedule deletion (7-30 day mandatory waiting period) --------------
aws kms delete-alias --alias-name alias/clf-lab-s3
aws kms schedule-key-deletion --key-id "$KEY_ID" --pending-window-in-days 7 \
  --query '[KeyId,KeyState,DeletionDate]' --output text

# --- Local artifacts ---------------------------------------------------------
rm -f /tmp/records.csv /tmp/records.csv.enc /tmp/datakey.json /tmp/wrapped-dk.* \
      /tmp/scp-region-lock.json /tmp/bucket-transit-policy.json \
      /tmp/trail-bucket-policy.json /tmp/config-bucket-policy.json \
      /tmp/trail-transit.json /tmp/trail-merged.json
```

```
1234abcd-12ab-34cd-56ef-1234567890ab   PendingDeletion   2026-09-10T11:58:01.223000+00:00
```

Confirm nothing is still recording:

```bash
aws configservice describe-configuration-recorders --query 'ConfigurationRecorders' --output text
aws cloudtrail describe-trails --query 'trailList[?Name==`clf-lab-trail`]' --output text
aws guardduty list-detectors --query 'DetectorIds' --output text
```

```
(three empty lines — nothing left running)
```

### Verification question — Block 9

- **Q9.1** — `schedule-key-deletion` enforces a minimum 7-day waiting period and the key state becomes `PendingDeletion`. Why does AWS refuse to delete a KMS key immediately, and what is the operational consequence of deleting a key that still protects data?

---

## Answers

<details>
<summary><strong>Click to reveal all answers with explanations</strong></summary>

### Block 0

**A0.1** — Regions introduced after March 20, 2019 are **opt-in**: disabled by default, and no API call of any kind can be made in them until the account explicitly enables the Region. A disabled Region is therefore a *hard* data-residency boundary — no resource can be created there, and no data can be stored there, regardless of what IAM policies say. It is a governance control because it constrains the account's blast radius and its geographic footprint at the account level, above IAM. Enabling an opt-in Region is a deliberate, audited act (`account:EnableRegion`), which is why an SCP that denies it is a common landing-zone guardrail. It is a defence against both attacker resource sprawl (mining instances in `ap-east-1` where nobody is watching CloudWatch) and accidental residency violations.

**A0.2** — Rotating the access key is **the customer's** responsibility: credentials, identities, and their lifecycle are customer-managed under "security *in* the cloud". Patching, scaling, and securing the STS service itself is **AWS's** responsibility under "security *of* the cloud". The dividing line here is exact: AWS guarantees STS answers correctly and is available; you guarantee that the credential presented to it should still exist.

**A0.3** — It went to `us-east-1` (or whichever Region your CLI profile defaults to; the Account API's global endpoint is anchored in `us-east-1`). This matters because global and quasi-global services record their API activity in `us-east-1`, so a naive `aws:RequestedRegion` deny that lists only `eu-west-1` will break IAM, Route 53, CloudFront, Organizations and STS across the whole account. That is precisely why the SCP in Exercise 2 uses `NotAction` to carve them out.

### Block 1

**A1.1** — **No.** AWS Artifact contains AWS's own third-party audit reports about AWS infrastructure; it says nothing about your bucket. The service that answers this is **AWS Config**, whose configuration history and rule-evaluation history record what each resource looked like at each point in time and whether it satisfied `S3_BUCKET_SERVER_SIDE_ENCRYPTION_ENABLED`. This is the shared responsibility boundary made literal: Artifact is evidence for *security of the cloud*; Config is evidence for *security in the cloud*. **AWS Audit Manager** sits on top of Config and packages that evidence against a named framework.

**A1.2** — SOC 2 Type II is a detailed report describing AWS's control environment, the auditor's tests, and the results; it is confidential and released under NDA, which is what `acceptanceType: EXPLICIT` enforces. **SOC 3** is the general-use public summary of the same audit, carries no NDA, and is the one you may publish, share with prospects, or post on your website. Handing a prospect the SOC 2 Type II report breaches the NDA you accepted to download it.

**A1.3** — Two violations. First, the SOC 2 report is under NDA — the term token you exchange in step 4 is your acceptance of a confidentiality agreement, and republishing the document breaches it. Second, a *public* S3 bucket makes it available to anyone on the internet, which is unauthorized disclosure of a third party's confidential audit material. The correct pattern is to leave the reports in Artifact (they are always current there and superseded versions are withdrawn) and grant `artifact:GetReport` to the people who need them; if you must cache them, store them in a private, encrypted, access-logged bucket with a documented retention period.

**A1.4** — The **AWS Business Associate Addendum (BAA)**, accepted through AWS Artifact Agreements. Accepting it does **not** make your workload HIPAA compliant. It establishes AWS's contractual obligations as a Business Associate and defines the HIPAA-eligible services you may use for PHI. Compliance of the workload remains entirely yours: using only HIPAA-eligible services, encrypting PHI at rest and in transit, controlling access, logging, and retaining audit trails. AWS is never "HIPAA compliant on your behalf"; it is a compliant substrate you can build a compliant system on.

### Block 2A

**A2.1** — S3 bucket names are globally unique and the S3 API accepts a request addressed to any Regional endpoint, responding with an HTTP 307 Temporary Redirect (or transparently routing it) to the bucket's home Region. What travelled to `us-east-1` was the *request metadata*; the object bytes were read from — and only ever stored in — `eu-west-1`. The control plane is reachable globally; the data plane is Region-bound. If the request had returned object content, that content would have been served *from* `eu-west-1` over the redirect.

**A2.2** — **S3 Replication** (Cross-Region Replication, CRR), and to a lesser extent explicit copy operations, Multi-Region Access Points with replication, or multi-Region KMS keys used for cross-Region copies. The fact that replication must be explicitly configured — and that `get-bucket-replication` returns `ReplicationConfigurationNotFoundError` when it is not — is a positive, auditable assertion for a GDPR Article 44–50 assessment: it demonstrates that no transfer mechanism to a third country exists. Combine it with an SCP denying `s3:PutBucketReplication` outside approved destinations and you have a preventive control, not just an observation.

**A2.3** — **No.** S3 Standard stores objects redundantly across a minimum of three Availability Zones within the Region, designed for 99.999999999% (eleven nines) durability. This is **AWS's responsibility** — durability of the storage infrastructure is "security of the cloud". Note the boundary: AWS guarantees the object survives hardware and AZ failure; AWS does **not** protect you from *your own* deletion. That is yours, and the controls are versioning, MFA Delete, Object Lock, and lifecycle/backup policy.

### Block 2B

**A2.4** — Two things break. Removing `sts:*` breaks role assumption: `sts:AssumeRole` is evaluated in the Region the STS endpoint serves, and if your operators assume roles through the global `us-east-1` STS endpoint, the deny fires and **nobody can authenticate**. Removing `iam:*` breaks all identity management, because IAM is a global service whose calls are recorded against `us-east-1`; you could no longer create, modify, or even read roles and policies. Together these produce the classic self-lockout: a region-lock SCP applied to the root that renders the organization unmanageable.

**A2.5** — They are recorded against **`us-east-1`** (`N. Virginia`), which is where the control planes for IAM, Route 53, CloudFront, Organizations, WAF Classic, Shield and Support are homed. Consequently `aws:RequestedRegion` for those calls evaluates to `us-east-1`, so any deny that does not list `us-east-1` — or does not exempt those services via `NotAction` — will block them. This is the single most common defect in hand-written region-lock SCPs.

**A2.6** — **No, the instance cannot be launched.** IAM policy evaluation is: an explicit `Deny` in *any* applicable policy always wins, and SCPs are applicable policies for member accounts. The full order is (1) explicit deny anywhere → denied; (2) otherwise, the request must be allowed by an SCP *and* by an identity or resource policy; (3) otherwise, implicit deny. An SCP can only ever subtract; it never grants. So the identity policy's `Allow` is irrelevant once the SCP's `Deny` matches.

**A2.7** — **No.** SCPs never apply to the organization's **management account**, even when the management account is inside an OU that has the policy attached. Operationally, this means the management account is a permanent exception to every guardrail you build — which is exactly why AWS recommends running no workloads in it, keeping its use limited to organization administration and billing, tightly restricting who can access it, and enforcing MFA on it. Any control you rely on for compliance must be verified as *not* dependent on the management account for enforcement.

### Block 2C

**A2.8** — The phrase distinguishes an SCP deny from an IAM permission gap. An operator seeing `explicit deny in a service control policy` knows immediately that the fix is not "add a policy to my user" — no identity-based permission can override it — but "the target Region or action is outside organizational policy; escalate to the cloud governance team". Without that string, the same `UnauthorizedOperation` would send them on a fruitless IAM debugging hunt. To see who else is hitting it, query **AWS CloudTrail**: denied calls are logged with `errorCode: AccessDenied` / `UnauthorizedOperation` and the full `userIdentity`, so `lookup-events` or a CloudWatch Logs Insights query over the trail shows the pattern of who is trying to work outside the boundary — often revealing a legitimate business need or a compromised credential.

**A2.9** — An SCP defines the **maximum available permissions** for principals in the affected accounts. A principal's effective permissions are the *intersection* of what its identity-based (and resource-based) policies allow with what the SCP boundary permits. An SCP by itself grants nothing: a principal with an SCP allowing everything and no IAM policy can do nothing. The mental model is a ceiling, not a floor.

### Block 3A

**A3.1** — No. In a KMS key policy, `arn:aws:iam::111122223333:root` does **not** mean the root user specifically; it means "this AWS account", and it delegates authorization for the key to the account's IAM system. In practice: any principal in account `111122223333` whose *IAM policy* grants them `kms:Decrypt` on this key ARN can decrypt with it. This is the source of the most common KMS misconception. Note the asymmetry: without that statement, IAM policies have no effect on the key at all — the key policy is the root of trust, and a key with an empty key policy is unusable by anyone and effectively bricked.

**A3.2** — With a **customer managed key** you gain: (1) full control of the key policy and grants, including cross-account access; (2) control over rotation schedule, enabling/disabling, and deletion; and additionally key-specific CloudTrail visibility, aliasing, tagging, and imported key material. The cost is **$1/month per key** plus per-request API charges — an AWS managed key (`aws/s3`) carries no monthly key charge. The practical decision rule: use a CMK whenever you need cross-account sharing, an auditable key policy, independent revocation ("cryptographic shredding" by disabling the key), or a compliance requirement to demonstrate customer control of key material.

**A3.3** — **Yes.** KMS automatic rotation creates *new backing key material* while retaining all previous backing keys for the life of the CMK. The key ID and ARN do not change, so applications need no update. Every ciphertext blob records which backing key encrypted it, and KMS selects the correct one on decrypt. Rotation only affects *new* encryption operations. This is also why deleting a CMK is destructive in a way rotation is not: rotation preserves all backing keys; deletion destroys all of them.

### Block 3B

**A3.4** — Only the **data key** crossed the network: a 32-byte AES-256 key going out as ~44 base64 characters and a ~240-byte wrapped blob coming back — on the order of a few hundred bytes, regardless of whether the payload is 46 bytes or 400 GB. KMS's `Encrypt` API is limited to **4 KB** of plaintext precisely because it is not a bulk data path. Envelope encryption solves three problems at once: it removes the size limit, it removes network round-trips and latency proportional to data volume, and it removes per-byte KMS request cost. The expensive, audited, hardware-backed operation happens once per data key; the cheap, local, high-throughput operation happens over the bulk data.

**A3.5** — A KMS ciphertext blob is self-describing: it embeds the **key ARN** (and the specific backing key version), the encryption algorithm, and any encryption context, alongside the wrapped key material. This is why `Decrypt` needs no `--key-id`. The audit property that follows is strong: given only a stored wrapped data key, you can determine exactly which CMK protects it, and every `Decrypt` call is logged in CloudTrail against that key ARN — so you get a complete, non-repudiable record of who unwrapped which key and when. (Specifying `--key-id` on decrypt is still good practice for symmetric keys: it makes KMS *verify* the expected key rather than trusting the blob, defeating a class of confused-deputy attack.)

**A3.6** — They still need the **plaintext data key**, which exists nowhere on disk — it must be obtained by calling `kms:Decrypt` on the wrapped blob. The control that decides whether they get it is the combination of the **KMS key policy and the IAM policy** of whatever principal they can authenticate as (plus any grants, and SCPs above it). If the attacker holds no valid AWS credentials with `kms:Decrypt` on that key, the files are cryptographically inert. And because every attempt is a logged KMS API call, a failed attempt is a detectable event — this is the practical argument for envelope encryption over a locally derived passphrase: the authorization decision is centralized, revocable, and audited.

### Block 3C

**A3.7** — `s3:GetObject` on `arn:aws:s3:::<bucket>/records.csv`, and `kms:Decrypt` on the CMK ARN. They live in two different documents: the S3 permission comes from your **IAM identity policy** (or the bucket policy), while the KMS permission must be satisfied by the **KMS key policy** — either directly, or by the key policy's `root` statement delegating to IAM plus a matching IAM grant. This is why "I have full S3 access but get `AccessDenied` on a KMS-encrypted object" is such a frequent support case: the bucket permission is necessary but not sufficient. It is also a *feature* — it lets you use the key policy as an independent, second authorization gate on sensitive data.

**A3.8** — Without a Bucket Key, S3 calls `kms:GenerateDataKey` (write) or `kms:Decrypt` (read) **once per object operation**. With `BucketKeyEnabled: true`, S3 asks KMS once for a short-lived, bucket-level key, then uses that bucket key locally to derive per-object data keys for a time-limited window. KMS request volume collapses from one call per object to a handful of calls per bucket per interval — up to a 99% reduction in KMS API charges, with a corresponding drop in latency and in KMS request-rate quota pressure. The trade-off to understand: CloudTrail then records KMS calls at the bucket-key level rather than one line per object, so per-object KMS audit granularity is reduced.

**A3.9** — "Is the data encrypted at rest?" — **Yes, provably, by your own configuration**: `head-object` returns `ServerSideEncryption: aws:kms` with a specific key ARN, and AWS Config's `S3_BUCKET_SERVER_SIDE_ENCRYPTION_ENABLED` rule attests it continuously. That claim rests on evidence you generate. "Can I prove AWS staff cannot read it?" — this rests on a **different kind of evidence**: AWS's own control environment, personnel screening, least-privilege operator access, and separation of duties, audited by third parties and published as SOC 2 / ISO 27001 reports in **AWS Artifact**. You cannot test it from the CLI. The honest architectural answer is that KMS's FIPS-validated HSMs mean no AWS employee has plaintext access to your key material, and that assertion is validated by the attestations, not by your configuration. If the regulator will not accept a third-party attestation, the answer is **AWS CloudHSM** or externally-held key material.

**A3.10** — **SSE-S3 (`AES256`)** uses keys AWS wholly manages; you cannot see them, control access to them independently, audit their use per-request, or revoke them — it is free and zero-effort. **SSE-KMS (`aws:kms`)** uses a KMS key you control, giving you an independent key policy, per-request CloudTrail entries for every encrypt/decrypt, controllable rotation, and the ability to revoke access to all data protected by that key at once. **DSSE-KMS** applies two independent layers of AES-256-GCM encryption to the same object, for regimes (notably certain US national-security and defence classifications) that mandate two layers of FIPS-validated encryption. A regulator forces you off SSE-S3 the moment the requirement includes any of: demonstrable customer control of keys, per-object cryptographic access auditing, separation of duties between the storage administrator and the key administrator, or a defined key rotation policy — none of which SSE-S3 can evidence.

### Block 4

**A4.1** — **Encryption at rest** protects against an adversary who obtains the persisted bytes — a stolen disk, a scavenged decommissioned drive, an improperly disposed backup, or unauthorized access to the storage layer. **Encryption in transit** protects against an adversary positioned on the network path — able to observe or modify traffic between client and service. Step 1 was exposed to a **man-in-the-middle / passive interception** attack: the AWS SigV4 `Authorization` header, the session token, the bucket name and object key, and the response metadata all traversed the network in cleartext. Even though SigV4 signatures are not directly replayable for arbitrary requests, exposing them plus session tokens on an untrusted network is a credential-disclosure event.

**A4.2** — With `Effect: Deny`, a wildcard `Principal` means "deny *everyone* who matches these conditions" — which is exactly the intent for a transit control. Anything narrower leaves a hole: a specific principal list would let any unlisted identity, including a future cross-account role or an anonymous request, reach the bucket over HTTP. In an `Allow` statement, `"Principal": "*"` means "grant to everyone on the internet, unauthenticated" — the canonical S3 data-breach misconfiguration. The asymmetry is the whole point: wildcards on deny are conservative; wildcards on allow are catastrophic.

**A4.3** — Step 5's certificate is on the **AWS S3 service endpoint**, so **AWS** renews it — that is security *of* the cloud, and it is invisible to you. Step 6's ACM certificate is issued to *your* domain for *your* endpoint. It is still auto-renewed by AWS provided two customer responsibilities are met: the certificate remains **associated with an integrated service** (CloudFront, ALB/NLB, API Gateway) and the domain validation record stays in place (the CNAME for DNS validation must remain in your hosted zone). If you delete the validation CNAME or detach the certificate, renewal fails and the expiry is yours to own. So: AWS performs the renewal, you maintain the preconditions for it.

**A4.4** — **AWS CloudHSM.** It gives you dedicated, single-tenant HSMs in your VPC, validated to FIPS 140-3 Level 3, where you — not AWS — are the crypto officer. AWS manages the hardware, provisioning, and cluster health but has **no access to the key material**. The responsibility that transfers to you is substantial and often underestimated: you generate and manage all users and credentials, you are solely responsible for **backup and recovery of key material**, you manage cluster sizing and HA across AZs, and you handle application integration through PKCS#11/JCE/CNG rather than a simple AWS API. Critically, **if you lose your CloudHSM credentials or all cluster copies, AWS cannot recover your keys and the data is permanently unrecoverable.** That risk is the price of exclusive control.

**A4.5** — **ACM** is the answer. It provisions public TLS certificates at no charge, deploys them to CloudFront/ALB/NLB/API Gateway, and renews them automatically — zero renewal toil is its explicit design goal. **KMS** is wrong because it manages encryption keys for data, not X.509 certificates for TLS endpoints; it has no role in a TLS handshake with a browser. **CloudHSM** is wrong because it is a key *storage* appliance, not a certificate authority or a certificate lifecycle manager — it would require you to build the entire issuance, deployment and renewal pipeline yourself, and it costs hundreds of dollars a month to solve a problem ACM solves for free. (CloudHSM's legitimate role here would be as the backing HSM for **AWS Private CA** when you need to control the CA's root key — a different requirement.)

### Block 5

**A5.1** — A trail created but never started produces **no logs at all** while appearing correctly configured in the console's trail list. The realistic failure: an incident occurs six months later, the security team goes to reconstruct the attacker's actions, and finds an empty S3 prefix — the entire evidentiary record for that period does not exist and cannot be recreated. Auditors treat this as a control failure for the whole period, not just going forward. The API call that catches it is **`aws cloudtrail get-trail-status`**, whose `IsLogging` field is the authoritative signal; `LatestDeliveryTime` and `LatestDeliveryError` confirm delivery is actually working. In practice you also monitor this with the AWS Config rule `cloudtrail-enabled` / `multi-region-cloudtrail-enabled` and the Security Hub CIS control, so a stopped trail raises a finding rather than waiting to be discovered.

**A5.2** — **Financial:** management events for the first copy of a trail are delivered free, whereas data events are charged per event recorded. A busy S3 bucket or DynamoDB table generates millions of data events per day, so making them opt-in prevents an enormous, surprising bill. **Volume:** management events describe control-plane operations — creating, modifying, deleting resources — which are relatively rare and almost always security-relevant. Data events describe individual object reads and writes, which are the normal operating traffic of the application; recording all of them would bury the security-relevant signal in orders of magnitude more routine noise, and would swamp downstream analysis. The correct practice is exactly what step 4 does: enable data events narrowly, on the specific sensitive resources where object-level access is itself the thing you need to audit.

**A5.3** — CloudTrail log file validation works in two layers. Each delivered log file is hashed (SHA-256). Every hour, CloudTrail writes a **digest file** containing the hashes of all log files delivered in that period, plus the hash of the *previous* digest file, and signs the digest with a private key held by AWS (RSA with SHA-256). This produces a hash chain: digests are chained to each other, and log files are anchored to digests. Modifying a log file changes its hash, so it no longer matches the value recorded in the signed digest — that is exactly the `INVALID: hash value doesn't match` result you saw, while the digest chain itself remained intact and verifiable. Deleting a log file would produce a missing-file error against the digest; tampering with a digest breaks its signature and the chain to the next digest. **Validation detects tampering; it does not prevent it.** Prevention is a separate set of controls: S3 Object Lock in compliance mode, SSE-KMS with a restrictive key policy, MFA Delete, a bucket policy denying `s3:DeleteObject`, and delivering the trail into a dedicated log-archive account that application administrators cannot reach.

**A5.4** — **`sourceIPAddress`** answers *from where* — was this action taken from the corporate network, from a known bastion, from an unexpected country, or from a Tor exit node? It is the field that supports geographic and network-boundary compliance assertions and is central to detecting stolen-credential use. **`userAgent`** answers *by what means* — the console, a specific AWS SDK version, the CLI, or an unrecognized tool; a sudden change in user agent for a service account is a classic compromise indicator. Neither field, by itself, distinguishes attack from routine work; CloudTrail is a **record**, not a **detector**. Pair it with **Amazon GuardDuty**, which consumes the CloudTrail management event stream directly and applies threat intelligence, anomaly detection, and machine learning to raise findings such as `UnauthorizedAccess:IAMUser/ConsoleLoginSuccess.B` or `Discovery:IAMUser/AnomalousBehavior`. **Amazon Detective** then reconstructs the surrounding behaviour graph for the investigation.

**A5.5** — **CloudTrail** records *API activity*: who called which API, when, from where, with what parameters, and whether it succeeded. **CloudWatch** records *operational telemetry*: metrics, logs, and events describing how resources and applications are performing and what they emitted.

| Item | Service |
|---|---|
| An API call that deleted a security group | **CloudTrail** |
| CPU utilization at 94% | **CloudWatch** (metrics) |
| A Lambda function's `print()` output | **CloudWatch** (Logs) |
| The identity that disabled a KMS key | **CloudTrail** |

The reliable heuristic: if the question starts with **"who"**, it is CloudTrail. If it starts with **"how much", "how fast", or "what did it say"**, it is CloudWatch.

### Block 6

**A6.1** — It answers **"what was the configuration of this resource at time T, and how did it change over time?"** — the point-in-time state and the full mutation timeline of the resource itself. CloudTrail records that a `PutBucketEncryption` call occurred but does not give you the resulting *resource state*, and reconstructing state by replaying every API call is impractical and incomplete. AWS Artifact says nothing about your resources at all. Config produces the configuration item timeline, the relationships between resources, and — with rules — the compliance verdict at each point. This is precisely the evidence an auditor requests for a "continuously enforced for 12 months" assertion, and it is why Config underpins AWS Audit Manager.

**A6.2** — The alternative is **`"Owner": "CUSTOMER_LAMBDA"`** (or `CUSTOM_POLICY` for Guard-based rules). A custom Lambda rule requires you to write, deploy, permission, monitor, version and maintain a Lambda function that receives configuration items and returns `COMPLIANT` / `NON_COMPLIANT` / `NOT_APPLICABLE` evaluations — real engineering with its own failure modes. AWS managed rules are pre-built, maintained and updated by AWS, require only a rule name and a scope, and cover several hundred common checks. The exam objectives emphasise them because a Cloud Practitioner should recognise that the vast majority of compliance checks are a *configuration* decision, not a *development* project — the correct instinct is to look for a managed rule or a conformance pack first, and to write custom logic only for organization-specific controls that AWS could not anticipate.

**A6.3** — `S3_BUCKET_SSL_REQUESTS_ONLY` inspects the **bucket policy** and looks for a statement that denies requests where `aws:SecureTransport` is `false`. The evidence bucket had exactly that statement, added in Exercise 4; the trail and config buckets had bucket policies granting CloudTrail and Config write access but no transit deny, so they failed. The general lesson is important: a Config rule evaluates a **specific, declared property** of a resource, not a vague notion of "is it secure". Read the managed rule's documented logic before trusting a `COMPLIANT` verdict — the rule proves what it says it proves and nothing more. It is also a reminder that logging buckets are production data stores subject to the same controls as any other bucket, and are routinely forgotten.

**A6.4** — A **conformance pack** is a deployable collection of AWS Config rules and remediation actions, packaged as a single YAML template, that can be deployed to an account or across an entire AWS Organization in one operation. AWS publishes sample packs mapped to PCI DSS, HIPAA, CIS, NIST 800-53, ISO 27001 and others. The reasons to prefer one over 60 individual API calls are: it is a single versioned artifact under source control; it deploys atomically and can be rolled back atomically; it reports a single aggregated compliance score for the framework; it can be deployed organization-wide from the management or delegated administrator account rather than account by account; and it carries the framework mapping as metadata, so the evidence is already labelled with the control it satisfies when the auditor asks.

**A6.5** — (a) **AWS Config** — configuration history and change timeline for a resource. (b) **AWS CloudTrail** — the identity, timestamp, and source IP of the API call. (c) **AWS Artifact** — AWS's own third-party certifications and attestations.

### Block 7A

**A7.1** — GuardDuty consumes the CloudTrail management event stream, VPC Flow Logs, and Route 53 Resolver DNS query logs **directly from the service producers, out of band**. It does not read your S3 log buckets, and it does not require you to have a trail, a flow log, or query logging enabled at all. Two consequences follow. **Cost:** you are not charged twice — GuardDuty's own pricing covers the analysis, and you do not pay CloudTrail/VPC Flow Logs/Route 53 logging charges for GuardDuty's copy of the data. **Security:** an attacker who deletes your CloudTrail trail, empties your log bucket, or disables flow logs **does not blind GuardDuty** — and in fact the act of stopping a trail generates a GuardDuty finding of its own (`Stealth:IAMUser/CloudTrailLoggingDisabled`). Out-of-band ingestion is a deliberate anti-tampering design.

**A7.2** — Because the root user has unrestricted, un-restrictable power over the account: it can close the account, change the account contact and root email, modify billing, remove the account from an organization, and — crucially — it is **not constrained by SCPs, permission boundaries, or IAM policies**. Every governance control you have built assumes root is not being used. Well-run accounts store root credentials with hardware MFA in a break-glass process invoked perhaps once a year, so *any* root credential use is either a rare, pre-announced, audited event or an active compromise. Severity in GuardDuty reflects the confidence and technical impact of the signal, not your organization's policy — which is exactly why teams route this finding to a high-priority channel via EventBridge regardless of its label. The same logic underlies the CIS benchmark control and Trusted Advisor's "MFA on Root Account" check.

**A7.3** — **No.** GuardDuty is a *behavioural* threat-detection service: it analyses network, DNS and API telemetry to detect activity that indicates compromise or reconnaissance. It does not inspect the software installed on an instance. The service that finds `log4j` is **Amazon Inspector**, which performs continuous, agentless-or-SSM-based vulnerability scanning of EC2 instances, container images in ECR, and Lambda functions and layers, matching installed packages against CVE databases. The clean distinction: **Inspector finds the unlocked window before anyone climbs through it; GuardDuty notices someone climbing through it.**

### Block 7B

**A7.4** —

| Question | Service | Ingests |
|---|---|---|
| Is there a CVE in the OS packages on my EC2 fleet or in my container images? | **Amazon Inspector** | Software inventory from SSM Agent / agentless EBS snapshot scanning, ECR image layers, Lambda function packages and layers — matched against CVE feeds |
| Is there personally identifiable information sitting in my S3 buckets? | **Amazon Macie** | S3 object contents, sampled and classified with managed and custom data identifiers, plus S3 bucket inventory and public-access posture |
| Is a compromised credential exfiltrating data right now? | **Amazon GuardDuty** | CloudTrail management and S3 data events, VPC Flow Logs, Route 53 Resolver DNS query logs (optionally EKS audit logs, RDS login events, EBS volumes for malware) |
| Where do all of the above appear on one screen, scored against CIS and PCI? | **AWS Security Hub** | Findings in ASFF from GuardDuty, Inspector, Macie, IAM Access Analyzer, Firewall Manager, Config, Systems Manager Patch Manager and partner products — plus its own control checks |
| Which other resources did this compromised role touch over the last 90 days? | **Amazon Detective** | The same telemetry as GuardDuty (CloudTrail, VPC Flow Logs, GuardDuty findings, EKS audit logs), pre-processed into a linked **behaviour graph** with up to a year of history |

**A7.5** — The 31 findings with `ProductName: Security Hub` are generated by Security Hub's **own security control checks** — the automated evaluations behind the enabled standards (AWS Foundational Security Best Practices, CIS Benchmark, PCI DSS), which run against your resource configurations largely on top of AWS Config. The 3 GuardDuty findings are *ingested* from another service. The distinction matters because it splits Security Hub's role in two: it is a **posture-management / compliance-scoring service** in its own right (checking configuration against benchmarks — is the door locked?), **and** it is the **aggregation and normalization layer** for detection findings produced elsewhere (is someone at the door?). Calling it a detection service conflates the two and leads teams to believe enabling Security Hub gives them threat detection — it does not; that still requires GuardDuty. The precise statement is that Security Hub *checks posture and aggregates findings*; it does not analyse threat telemetry.

**A7.6** — Compliance frameworks overlap heavily at the technical control level: "do not expose storage publicly" appears in CIS, PCI DSS, HIPAA safeguards, ISO 27001 Annex A and NIST 800-53 under five different identifiers. Mapping one automated check to all of them means (1) you **implement and monitor once** rather than maintaining parallel control sets per framework; (2) a single remediation improves your posture against every framework simultaneously, which is visible in the scores; (3) when an auditor asks for evidence of PCI DSS 1.2.1, you can produce the finding history for control S3.8 directly rather than assembling it by hand; and (4) adding a new framework becomes largely a mapping exercise over controls you already run, not a new engineering programme. This crosswalk is precisely the value AWS Audit Manager packages and automates.

**A7.7** — Macie answers **"what personal data do I actually hold, and where?"** — Article 30 of GDPR requires records of processing activities, and you cannot produce them if you do not know which buckets contain `NATIONAL_IDENTIFICATION_NUMBER_ES` or `DATE_OF_BIRTH`. The residency guardrail from Exercise 2 answers **"and does it stay within the EEA?"** — Chapter V governs transfers to third countries. Together they form a complete, evidenced control narrative: Macie provides *discovery and classification* (we know exactly which objects hold personal data, continuously, not from a stale spreadsheet); the SCP plus the absence of replication configuration provides *preventive residency enforcement* (no mechanism exists to move it, and any attempt is denied and logged); Config provides *continuous verification* of the encryption and access controls on those buckets; and CloudTrail provides the *access record* for each object. Each piece is weak alone — knowing where the data is without controlling where it goes, or controlling residency without knowing what you hold, both fail an audit.

**A7.8** — **GuardDuty → Security Hub → Detective → CloudTrail.**
1. **GuardDuty** raised the finding; you open it first to read the specific finding type, severity, affected instance, the remote IP, and the threat-intelligence context that triggered it.
2. **Security Hub** immediately after, to see whether this instance or account has *related* findings — an unpatched CVE from Inspector, a failed control check for an over-permissive security group, a public S3 bucket — which together suggest the initial access vector and the blast radius. This is the correlation step that converts one alert into a picture.
3. **Detective**, to pivot into the behaviour graph: what did this instance's IAM role do before and after the finding, what other resources did it touch, which API calls were unusual for this principal, and how far back does the anomalous behaviour actually go. Detective answers scope questions that a single finding cannot.
4. **CloudTrail** last, for the forensic ground truth — the exact, unaggregated, signed event records with full request parameters, needed for the incident report, for legal or regulatory notification, and for anything Detective's summarised view does not resolve.

The principle: move from **alert** (something is wrong) to **correlation** (what else is wrong nearby) to **investigation** (how far does it reach) to **evidence** (exactly what happened, defensibly).

### Block 8

**A8.1** — **AWS Organizations** is the foundational multi-account service: it creates the organization, the OU hierarchy, and consolidated billing, and it is where SCPs, tag policies and backup policies are attached. **AWS Control Tower** is an orchestration layer *on top of* Organizations: it sets up a prescriptive, well-architected landing zone — a multi-account structure with a Security OU and a Sandbox OU, log archive and audit accounts, AWS IAM Identity Center for federated access, centralized CloudTrail and Config, and a curated catalogue of **controls** (formerly "guardrails", implemented as SCPs for preventive controls and Config rules for detective controls) — and it provides Account Factory for governed account provisioning. **No, you cannot use Control Tower without Organizations**: Control Tower requires an organization and creates one for you if none exists. The relationship is engine and chassis — Organizations provides the mechanism, Control Tower provides the opinionated, automated, continuously-drift-detected assembly of it.

**A8.2** — **No.** Deploying the framework does not make anything compliant. What it produces is **automated, continuous evidence collection**: Audit Manager maps each of those 134 controls to evidence sources — AWS Config rule evaluations, Security Hub findings, CloudTrail events, and AWS API call results — and continuously gathers, timestamps and organizes that evidence into an **assessment report** that can be handed to an auditor. It replaces the manual quarterly screenshot-gathering exercise. What it explicitly does **not** do is assert compliance or make a judgement: the framework's control mappings are AWS's suggestion, not a certification; many controls require manual evidence you upload yourself; and **you remain fully accountable** for the compliance of your workload, for validating that the collected evidence actually satisfies your auditor, and for the controls the framework does not cover. Only an accredited third-party auditor can attest compliance.

**A8.3** — The five categories are **Cost Optimization, Performance, Security, Fault Tolerance, and Service Limits** (Service Quotas). On **Basic and Developer** support plans you get the full **Service Limits** category plus a small set of core security checks — historically: Security Groups – Specific Ports Unrestricted, IAM Use, MFA on Root Account, Amazon S3 Bucket Permissions, Amazon EBS Public Snapshots, Amazon RDS Public Snapshots. The complete check set across all five categories, along with the Trusted Advisor **API** (`aws support describe-trusted-advisor-checks`), programmatic refresh, and notification integration, requires **Business, Enterprise On-Ramp, or Enterprise Support**. The exam-relevant framing: Trusted Advisor is the proactive best-practice advisor across the Well-Architected pillars, and its depth is a function of your support plan.

**A8.4** — Tag policies **standardize the tags themselves** — they define which tag keys are permitted, the exact capitalization of those keys, and the set of allowed values, and they report non-compliant resources across the organization. An SCP cannot do this: an SCP can deny a `RunInstances` call that lacks a `CostCenter` tag (via the `aws:RequestTag` condition key), but it cannot enforce that the key is spelled `CostCenter` rather than `costcenter` or `Cost_Center`, cannot constrain the *value* to a controlled vocabulary at scale, and cannot report on the drift of resources tagged before the policy existed. The concrete compliance use is **data classification**: a tag policy mandating `DataClassification` ∈ {`Public`, `Internal`, `Confidential`, `Restricted`} on every resource, with organization-wide compliance reporting, is what makes classification-driven controls — backup policies, encryption requirements, access reviews, cost allocation by regulated workload — actually enforceable. Without key standardization, every downstream query silently misses the misspelled resources.

**A8.5** — Use the **AWS Trust & Safety / abuse reporting** channel: the "Report Amazon AWS abuse" form in AWS Support, or email `abuse@amazonaws.com`, including timestamps in UTC, your logs, source and destination IPs and ports. Under the shared responsibility model this is a **shared** obligation with a clear split: **you** are responsible for detecting the activity against your resources (GuardDuty's `Recon:EC2/Portscan` finding, VPC Flow Logs, network ACLs and security groups to block it) and for reporting it with evidence; **AWS** is responsible for acting on the report against the offending account under the AWS Acceptable Use Policy and for protecting the shared infrastructure. Note the mirror-image case: if the abuse originates from *your* account, AWS will contact you and remediation is entirely your responsibility.

**A8.6** —

| Item | Responsibility |
|---|---|
| Hypervisor patching | **AWS** — security *of* the cloud |
| Guest OS patching (EC2) | **Customer** — security *in* the cloud |
| Physical destruction of decommissioned disks | **AWS** — data centre media disposal, evidenced in Artifact reports |
| S3 bucket policy configuration | **Customer** |
| KMS key policy configuration | **Customer** (AWS operates and secures the KMS service and its HSMs) |
| Durability of the S3 storage layer | **AWS** (customer owns versioning, Object Lock, replication and backup choices) |
| IAM user MFA enforcement | **Customer** |
| DDoS protection of the AWS global network edge | **AWS** — AWS Shield Standard, included at no cost (application-layer protection via Shield Advanced and AWS WAF is a customer configuration) |

The recurring pattern: AWS owns the **infrastructure and the service's own security**; the customer owns **configuration, identity, and data**. For managed services the customer's share shrinks — with S3 or DynamoDB you never patch an OS — but it never disappears, because access control and data classification are always yours.

### Block 9

**A9.1** — Because KMS key deletion is **irreversible and unrecoverable**, and it destroys not one key but every backing key ever created by rotation. Every ciphertext that key protects — every S3 object, EBS volume, RDS snapshot, Secrets Manager secret, and every wrapped data key sitting in some application's database — becomes permanently undecryptable. There is no AWS escape hatch: no support ticket, no backup, no recovery. The mandatory waiting period (7 to 30 days, default 30) exists to make this mistake survivable. During the window the key enters `PendingDeletion` state, all cryptographic operations with it **fail immediately** — so any workload still depending on it breaks loudly and visibly rather than silently succeeding until the deletion date — and `cancel-key-deletion` restores it fully at any point before the deadline. The correct operational practice before scheduling deletion is to check **CloudTrail** for recent `Decrypt`, `GenerateDataKey` and `Encrypt` calls against the key (Amazon EventBridge and CloudWatch alarms on KMS usage make this routine), and to prefer **disabling** the key first: disabling is fully reversible and produces the same fail-loud behaviour, making it the safe way to test whether anything still needs the key.

</details>

---

## Sources

All material above is original. The AWS service behaviours, API shapes, policy semantics and responsibility boundaries described are documented at the following official sources.

**Exam scope**
- AWS Certified Cloud Practitioner (CLF-C02) Exam Guide — https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf

**Shared responsibility and compliance evidence**
- Shared Responsibility Model — https://aws.amazon.com/compliance/shared-responsibility-model/
- AWS Artifact User Guide — https://docs.aws.amazon.com/artifact/latest/ug/what-is-aws-artifact.html
- AWS Artifact agreements (BAA and others) — https://docs.aws.amazon.com/artifact/latest/ug/managingagreements.html
- AWS Compliance Programs — https://aws.amazon.com/compliance/programs/

**Regions, residency and organizational guardrails**
- Managing AWS Regions (opt-in Regions) — https://docs.aws.amazon.com/general/latest/gr/rande-manage.html
- Service control policies — https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_scps.html
- Tag policies — https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_tag-policies.html
- `aws:RequestedRegion` global condition key — https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_condition-keys.html#condition-keys-requestedregion
- IAM policy evaluation logic — https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_evaluation-logic.html
- AWS Control Tower — https://docs.aws.amazon.com/controltower/latest/userguide/what-is-control-tower.html

**Encryption**
- AWS KMS concepts, including envelope encryption — https://docs.aws.amazon.com/kms/latest/developerguide/concepts.html
- KMS key policies — https://docs.aws.amazon.com/kms/latest/developerguide/key-policies.html
- Rotating AWS KMS keys — https://docs.aws.amazon.com/kms/latest/developerguide/rotate-keys.html
- Deleting AWS KMS keys — https://docs.aws.amazon.com/kms/latest/developerguide/deleting-keys.html
- S3 server-side encryption — https://docs.aws.amazon.com/AmazonS3/latest/userguide/serv-side-encryption.html
- S3 Bucket Keys — https://docs.aws.amazon.com/AmazonS3/latest/userguide/bucket-key.html
- Enforcing encryption in transit with `aws:SecureTransport` — https://docs.aws.amazon.com/AmazonS3/latest/userguide/security-best-practices.html
- AWS Certificate Manager — https://docs.aws.amazon.com/acm/latest/userguide/acm-overview.html
- AWS CloudHSM — https://docs.aws.amazon.com/cloudhsm/latest/userguide/introduction.html

**Audit, configuration and governance**
- AWS CloudTrail — https://docs.aws.amazon.com/awscloudtrail/latest/userguide/cloudtrail-user-guide.html
- CloudTrail log file integrity validation — https://docs.aws.amazon.com/awscloudtrail/latest/userguide/cloudtrail-log-file-validation-intro.html
- CloudTrail data events — https://docs.aws.amazon.com/awscloudtrail/latest/userguide/logging-data-events-with-cloudtrail.html
- AWS Config — https://docs.aws.amazon.com/config/latest/developerguide/WhatIsConfig.html
- AWS Config managed rules — https://docs.aws.amazon.com/config/latest/developerguide/managed-rules-by-aws-config.html
- AWS Config conformance packs — https://docs.aws.amazon.com/config/latest/developerguide/conformance-packs.html
- AWS Audit Manager — https://docs.aws.amazon.com/audit-manager/latest/userguide/what-is.html
- AWS License Manager — https://docs.aws.amazon.com/license-manager/latest/userguide/license-manager.html
- AWS Trusted Advisor — https://docs.aws.amazon.com/awssupport/latest/user/trusted-advisor.html

**Threat detection and posture management**
- Amazon GuardDuty — https://docs.aws.amazon.com/guardduty/latest/ug/what-is-guardduty.html
- GuardDuty finding types — https://docs.aws.amazon.com/guardduty/latest/ug/guardduty_finding-types-active.html
- AWS Security Hub — https://docs.aws.amazon.com/securityhub/latest/userguide/what-is-securityhub.html
- AWS Security Finding Format (ASFF) — https://docs.aws.amazon.com/securityhub/latest/userguide/securityhub-findings-format.html
- Amazon Inspector — https://docs.aws.amazon.com/inspector/latest/user/what-is-inspector.html
- Amazon Macie — https://docs.aws.amazon.com/macie/latest/user/what-is-macie.html
- Amazon Detective — https://docs.aws.amazon.com/detective/latest/userguide/what-is-detective.html
- Reporting AWS abuse — https://support.aws.amazon.com/#/contacts/report-abuse