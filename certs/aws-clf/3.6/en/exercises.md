# Topic 3.6 — Identify AWS Storage Services

## Guided Exercises · AWS Certified Cloud Practitioner (CLF-C02 v1.0)

**Domain 3: Cloud Technology and Services — exam weight of this task statement: 4.25 %**

---

## 0. Before you start

### 0.1 What this lab does and does not do

At Cloud Practitioner level the verb in the task statement is **"identify"**: given a workload description, name the storage service that fits and justify it. These exercises get you there by making you *touch* the services, because the boundaries that the exam tests — AZ scope, durability class, access protocol, retrieval latency, billing dimension — are exactly the boundaries you hit when you actually provision.

You will build a small but real storage estate: an S3 bucket with versioning and lifecycle policy, an EBS volume and a snapshot restored into a different Availability Zone, an EFS file system, and an AWS Backup plan. You will then run diagnostics on all of it.

### 0.2 Prerequisites

| Requirement | Check |
|---|---|
| AWS account with admin or equivalent | `aws sts get-caller-identity` |
| AWS CLI v2 installed | `aws --version` → `aws-cli/2.x.x ...` |
| A default region set | `aws configure get region` |
| `jq` installed (used for readable output) | `jq --version` |

```console
$ aws --version
aws-cli/2.17.42 Python/3.11.9 Linux/6.8.0-40-generic exe/x86_64.ubuntu.24

$ aws sts get-caller-identity
{
    "UserId": "AIDA2EXAMPLEUSERID4Q",
    "Account": "123456789012",
    "Arn": "arn:aws:iam::123456789012:user/lab-practitioner"
}
```

### 0.3 Cost warning

Most of this lab sits inside or near the AWS Free Tier, but **not all of it**. Approximate list price if you complete every optional step and clean up the same day (us-east-1):

| Resource | Approximate cost |
|---|---|
| S3 objects (a few MB) | < $0.01 |
| EBS `gp3` 8 GiB for 2 hours | ~$0.001 |
| EBS snapshot (a few MB, incremental) | < $0.01 |
| EFS file system, few MB, 2 hours | < $0.01 |
| Optional `t3.micro` EC2 instance, 2 hours | ~$0.02 |
| AWS Backup on-demand backup of the EBS volume | ~$0.01 |

**Section 10 is the cleanup section. Run it.** Storage is the service family that keeps billing after you stop paying attention — that is itself an exam-relevant fact.

> Prices quoted throughout are US East (N. Virginia) list prices at time of writing and are used to teach *relative* economics, not to be memorised. Always verify against <https://aws.amazon.com/s3/pricing/> and <https://aws.amazon.com/ebs/pricing/>.

### 0.4 Shell variables used throughout

```bash
export AWS_REGION=us-east-1
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export LAB=clf36-${ACCOUNT_ID}
export BUCKET=${LAB}-archive
echo "Region=${AWS_REGION}  Account=${ACCOUNT_ID}  Bucket=${BUCKET}"
```

```console
Region=us-east-1  Account=123456789012  Bucket=clf36-123456789012-archive
```

S3 bucket names are in a **single global namespace shared by every AWS account on earth**, which is why the account ID is embedded above. This is not a general AWS naming rule — it is specific to S3 and a favourite exam detail.

---

## Exercise 1 — The three storage families

Everything in this task statement resolves to one of three access models. Get this right and roughly half the exam questions in the domain answer themselves.

### Steps

1. Read the table below and, for each service, write down *by hand* which family it belongs to before you continue.

| Family | How the client sees it | Unit written | AWS services |
|---|---|---|---|
| **Block** | A raw, unformatted disk you must partition and format | Fixed-size blocks (LBA) | Amazon **EBS**, EC2 **instance store** |
| **File** | A mounted POSIX/SMB tree with directories and permissions | Files, byte-range updates | Amazon **EFS**, Amazon **FSx** (Windows File Server, Lustre, NetApp ONTAP, OpenZFS) |
| **Object** | A flat namespace of immutable objects addressed by key, over HTTPS | Whole objects + metadata | Amazon **S3**, **S3 Glacier** storage classes |

2. Internalise the mechanical consequence of each model:

   - **Block**: the *operating system* owns the filesystem. AWS hands you a virtual disk; the guest kernel decides it is `ext4` or `xfs` or NTFS. A single block device can normally be attached to exactly one instance at a time, because two kernels writing the same superblock with independent page caches corrupt it.
   - **File**: the *file server* owns the filesystem and arbitrates concurrent access via a network protocol (NFSv4.1 for EFS, SMB for FSx for Windows). Many clients mount it simultaneously and locking is handled for them.
   - **Object**: there is no filesystem and no partial write. `PutObject` replaces the entire object; there is no `seek()` and no in-place byte modification. The "folders" you see in the console are a console-side rendering of `/` characters in the key.

3. Confirm the object-model claim empirically — S3 keys are just strings:

```bash
aws s3api create-bucket --bucket "${BUCKET}" --region "${AWS_REGION}"
echo "hello" > /tmp/f.txt
aws s3api put-object --bucket "${BUCKET}" --key "a/b/c/d/e.txt" --body /tmp/f.txt >/dev/null
aws s3api list-objects-v2 --bucket "${BUCKET}" --query 'Contents[].Key' --output table
```

```console
{
    "Location": "/clf36-123456789012-archive"
}
-------------------------
|     ListObjectsV2     |
+-----------------------+
|  a/b/c/d/e.txt        |
+-----------------------+
```

> **Region gotcha.** `us-east-1` is the only region where `create-bucket` takes no location constraint. Anywhere else:
> ```bash
> aws s3api create-bucket --bucket "${BUCKET}" --region eu-west-1 \
>   --create-bucket-configuration LocationConstraint=eu-west-1
> ```
> Omitting it returns `IllegalLocationConstraintException`.

4. Notice that no directory `a/`, `a/b/`, or `a/b/c/` was ever created. Delete the object and list again — the "folders" vanish with it, because they never existed.

```bash
aws s3api delete-object --bucket "${BUCKET}" --key "a/b/c/d/e.txt"
aws s3api list-objects-v2 --bucket "${BUCKET}" --query 'KeyCount'
```

```console
0
```

### Comprehension check

**Q1.** A vendor application requires a local disk it can format as `xfs` and on which it performs random 4 KiB in-place updates to a 200 GiB database file. Which family, and which AWS service?

**Q2.** Why can you not "append a line" to an existing S3 object the way you would to a file on EFS? What operation would you have to perform instead?

**Q3.** In S3, are `a/b/c.txt` and `a/b/` two separate stored entities? Justify from the output above.

**Q4.** A finance team wants 40 Windows desktops to open the same `\\share\budget\` folder concurrently, with Active Directory permissions preserved. Which family, and which specific AWS service?

---

## Exercise 2 — Amazon S3: durability, the AZ boundary, and safe defaults

### Steps

1. Inspect the bucket's default security posture. Since April 2023, new buckets are created with S3 Block Public Access fully enabled and ACLs disabled.

```bash
aws s3api get-public-access-block --bucket "${BUCKET}" | jq
aws s3api get-bucket-ownership-controls --bucket "${BUCKET}" | jq -c '.OwnershipControls.Rules'
```

```console
{
  "PublicAccessBlockConfiguration": {
    "BlockPublicAcls": true,
    "IgnorePublicAcls": true,
    "BlockPublicPolicy": true,
    "RestrictPublicBuckets": true
  }
}
[{"ObjectOwnership":"BucketOwnerEnforced"}]
```

Read those four flags precisely — they are two different jobs:

| Flag | What it blocks |
|---|---|
| `BlockPublicAcls` | *New* public ACLs being set (PUT-time rejection) |
| `IgnorePublicAcls` | *Existing* public ACLs being honoured (evaluation-time ignore) |
| `BlockPublicPolicy` | *New* bucket policies that grant public access |
| `RestrictPublicBuckets` | *Existing* public policies, except for authenticated principals in the same account |

`BucketOwnerEnforced` disables ACLs entirely: every object is owned by the bucket owner and access is decided purely by IAM policies, bucket policies, and Access Points. This is the modern, recommended posture.

2. Confirm the bucket is regional, not global, and that S3 replicates within the Region.

```bash
aws s3api get-bucket-location --bucket "${BUCKET}"
```

```console
{
    "LocationConstraint": null
}
```

`null` means `us-east-1` — a legacy artifact of S3 predating the region-constraint API.

3. Enable versioning and observe that overwriting an object does not destroy the prior bytes.

```bash
aws s3api put-bucket-versioning --bucket "${BUCKET}" \
  --versioning-configuration Status=Enabled

printf 'v1 payroll data\n' > /tmp/payroll.csv
aws s3api put-object --bucket "${BUCKET}" --key payroll.csv --body /tmp/payroll.csv \
  --query VersionId --output text

printf 'v2 payroll data CORRUPTED\n' > /tmp/payroll.csv
aws s3api put-object --bucket "${BUCKET}" --key payroll.csv --body /tmp/payroll.csv \
  --query VersionId --output text
```

```console
3sL4kqtJlcpXroDTDmJ+rmSpXd3dIbrHY+MTRCxf3vjVBH40Nr8X8gdRQBpUMLUo
QUpfdndhfg8oVpFAMkVX4EK.oJgAKKq0Hk9y3ID.Ml.h5xAlVhAqCPWRb1Rc6zwK
```

4. List every version, including the shadowed one:

```bash
aws s3api list-object-versions --bucket "${BUCKET}" --prefix payroll.csv \
  --query 'Versions[].{Key:Key,VersionId:VersionId,IsLatest:IsLatest,Size:Size}' \
  --output table
```

```console
------------------------------------------------------------------------------------
|                                ListObjectVersions                                |
+----------+--------+--------+-------------------------------------------------------+
| IsLatest |  Key   | Size   |                     VersionId                         |
+----------+--------+--------+-------------------------------------------------------+
|  True    | payroll.csv | 26 | QUpfdndhfg8oVpFAMkVX4EK.oJgAKKq0Hk9y3ID.Ml.h5xAlVh... |
|  False   | payroll.csv | 16 | 3sL4kqtJlcpXroDTDmJ+rmSpXd3dIbrHY+MTRCxf3vjVBH40Nr... |
+----------+--------+--------+-------------------------------------------------------+
```

5. Delete the object *without* a version ID and inspect what actually happened:

```bash
aws s3api delete-object --bucket "${BUCKET}" --key payroll.csv
aws s3api list-object-versions --bucket "${BUCKET}" --prefix payroll.csv \
  --query 'DeleteMarkers[].{VersionId:VersionId,IsLatest:IsLatest}' --output json
aws s3api get-object --bucket "${BUCKET}" --key payroll.csv /tmp/out.csv
```

```console
[
    {
        "VersionId": "1kbZQ8mDe6.gFqOZ7yTZ9pWdJ4gZ2wQx",
        "IsLatest": true
    }
]

An error occurred (NoSuchKey) when calling the GetObject operation: The specified key does not exist.
```

The bytes are still there. A **delete marker** — a zero-byte version that becomes the current version — is what makes `GetObject` return `NoSuchKey`. This is the mechanism behind "versioning protects against accidental deletion".

6. Recover by removing the delete marker:

```bash
DM=$(aws s3api list-object-versions --bucket "${BUCKET}" --prefix payroll.csv \
     --query 'DeleteMarkers[0].VersionId' --output text)
aws s3api delete-object --bucket "${BUCKET}" --key payroll.csv --version-id "${DM}"
aws s3api get-object --bucket "${BUCKET}" --key payroll.csv /tmp/out.csv >/dev/null && cat /tmp/out.csv
```

```console
v2 payroll data CORRUPTED
```

7. Enforce TLS with a bucket policy. Save as `/tmp/tls-policy.json`:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DenyInsecureTransport",
      "Effect": "Deny",
      "Principal": "*",
      "Action": "s3:*",
      "Resource": [
        "arn:aws:s3:::REPLACE_BUCKET",
        "arn:aws:s3:::REPLACE_BUCKET/*"
      ],
      "Condition": {
        "Bool": { "aws:SecureTransport": "false" }
      }
    }
  ]
}
```

```bash
sed -i "s/REPLACE_BUCKET/${BUCKET}/g" /tmp/tls-policy.json
aws s3api put-bucket-policy --bucket "${BUCKET}" --policy file:///tmp/tls-policy.json
aws s3api get-bucket-policy-status --bucket "${BUCKET}"
```

```console
{
    "PolicyStatus": {
        "IsPublic": false
    }
}
```

Note both ARN forms in `Resource`. `arn:aws:s3:::bucket` is the bucket itself (target of `s3:ListBucket`, `s3:GetBucketLocation`); `arn:aws:s3:::bucket/*` is the objects inside it (target of `s3:GetObject`, `s3:PutObject`). Confusing the two is the single most common cause of a policy that "looks right" and denies everything.

### Comprehension check

**Q5.** S3 Standard is designed for 99.999999999 % durability. Across how many Availability Zones does it store each object, and which two storage classes break that rule?

**Q6.** You enable versioning, then decide you no longer want it. What are your two options, and which one is *not* available?

**Q7.** After step 5, the object was invisible to `GetObject` but you were still being billed. Why?

**Q8.** Distinguish *durability* from *availability* for S3 Standard. Give the numeric design target for each.

**Q9.** A teammate says "our bucket is safe, Block Public Access is on, so we don't need a bucket policy." Name one access path that Block Public Access does **not** restrict.

---

## Exercise 3 — S3 storage classes and lifecycle economics

This exercise is where the exam earns its money. The classes differ along four axes: **cost per GB-month, retrieval fee, retrieval latency, and minimum billable duration.**

### Steps

1. Study the class table. The bolded numbers are the ones that decide exam answers.

| Storage class | AZs | Retrieval latency | Min. storage duration | Min. billable object | ~$/GB-mo | Retrieval fee |
|---|---|---|---|---|---|---|
| S3 Standard | ≥ 3 | ms | none | none | 0.023 | none |
| S3 Intelligent-Tiering | ≥ 3 | ms (frequent/infrequent tiers) | none | none | 0.023 → 0.0036 | **none** (+ monitoring fee) |
| S3 Standard-IA | ≥ 3 | ms | **30 days** | **128 KB** | 0.0125 | $0.01/GB |
| S3 One Zone-IA | **1** | ms | **30 days** | **128 KB** | 0.01 | $0.01/GB |
| S3 Express One Zone | **1** (single AZ, one Availability Zone you choose) | single-digit ms | 1 hour | 512 KB | 0.16 | none |
| S3 Glacier Instant Retrieval | ≥ 3 | **ms** | **90 days** | 128 KB | 0.004 | $0.03/GB |
| S3 Glacier Flexible Retrieval | ≥ 3 | **1–5 min (Expedited) / 3–5 h (Standard) / 5–12 h (Bulk, free)** | **90 days** | — | 0.0036 | tiered |
| S3 Glacier Deep Archive | ≥ 3 | **12 h (Standard) / 48 h (Bulk)** | **180 days** | — | 0.00099 | tiered |

2. Write an object and confirm its class:

```bash
head -c 200000 /dev/urandom > /tmp/blob.bin
aws s3api put-object --bucket "${BUCKET}" --key "logs/2026/app.log" --body /tmp/blob.bin >/dev/null
aws s3api head-object --bucket "${BUCKET}" --key "logs/2026/app.log" \
  --query '{Class:StorageClass,Size:ContentLength}'
```

```console
{
    "Class": null,
    "Size": 200000
}
```

`null` is not a bug: S3 omits `StorageClass` from the response when the object is in `STANDARD`, because Standard is the default.

3. Change the class in place with a same-key copy and re-check:

```bash
aws s3api copy-object --bucket "${BUCKET}" --key "logs/2026/app.log" \
  --copy-source "${BUCKET}/logs/2026/app.log" \
  --storage-class STANDARD_IA --metadata-directive COPY >/dev/null
aws s3api head-object --bucket "${BUCKET}" --key "logs/2026/app.log" --query StorageClass
```

```console
"STANDARD_IA"
```

4. Apply a lifecycle configuration. Save as `/tmp/lifecycle.json`:

```json
{
  "Rules": [
    {
      "ID": "log-archive-cascade",
      "Filter": { "Prefix": "logs/" },
      "Status": "Enabled",
      "Transitions": [
        { "Days": 30,  "StorageClass": "STANDARD_IA" },
        { "Days": 90,  "StorageClass": "GLACIER_IR" },
        { "Days": 180, "StorageClass": "DEEP_ARCHIVE" }
      ],
      "Expiration": { "Days": 2555 },
      "NoncurrentVersionTransitions": [
        { "NoncurrentDays": 30, "StorageClass": "GLACIER" }
      ],
      "NoncurrentVersionExpiration": { "NoncurrentDays": 365 },
      "AbortIncompleteMultipartUpload": { "DaysAfterInitiation": 7 }
    }
  ]
}
```

```bash
aws s3api put-bucket-lifecycle-configuration --bucket "${BUCKET}" \
  --lifecycle-configuration file:///tmp/lifecycle.json
aws s3api get-bucket-lifecycle-configuration --bucket "${BUCKET}" \
  --query 'Rules[0].{ID:ID,Transitions:Transitions[].Days}'
```

```console
{
    "ID": "log-archive-cascade",
    "Transitions": [
        30,
        90,
        180
    ]
}
```

Four separate mechanisms live in that one rule, and the exam treats them as distinct concepts:

- `Transitions` — moves the **current** version between classes.
- `Expiration` — deletes the current version (in a versioned bucket, this *adds a delete marker*; it does not free storage).
- `NoncurrentVersion*` — the rules that actually reclaim space in a versioned bucket.
- `AbortIncompleteMultipartUpload` — deletes orphaned multipart parts. These parts are billed, invisible to `ListObjectsV2`, and are a classic silent cost leak. **Every production bucket should have this rule.**

5. Find the leak yourself:

```bash
aws s3api list-multipart-uploads --bucket "${BUCKET}" --query 'Uploads' --output json
```

```console
null
```

Clean here — but on a bucket fed by a flaky uploader this list grows without ever appearing in the object listing.

6. Do the arithmetic that lifecycle rules exist to serve. For **1 TB** of logs held for a year:

| Scenario | Monthly | Annual |
|---|---|---|
| All 12 months in S3 Standard | $23.55 | **$282.62** |
| Standard 1 mo → Standard-IA 2 mo → Glacier IR 3 mo → Deep Archive 6 mo | varies | **≈ $46** |

*(1 TB = 1024 GiB; Standard at $0.023/GB-mo, Standard-IA $0.0125, Glacier IR $0.004, Deep Archive $0.00099, transition request charges excluded.)*

Roughly a **6× reduction** — and the entire cost of that reduction is retrieval latency you have decided you can tolerate.

### Comprehension check

**Q10.** You have 10 million thumbnail images averaging **40 KB** each, accessed a few times per year. A colleague proposes a lifecycle rule to S3 Standard-IA to save money. Calculate why this makes the bill *worse*, and state the correct alternative.

**Q11.** Regulatory data must be kept for 7 years and retrieved within 12 hours if an auditor asks. Which storage class, and why is Glacier Flexible Retrieval not the cheapest correct answer?

**Q12.** An object is transitioned to S3 Standard-IA on day 1 and deleted on day 10. How many days of Standard-IA storage are you billed for?

**Q13.** What distinguishes **S3 Glacier Instant Retrieval** from **S3 Standard-IA**? Name the axis on which they trade off.

**Q14.** A dataset has completely unpredictable access — some objects are hot, most are cold, and it changes month to month. Which class, and what is its one distinctive charge?

**Q15.** In a versioned bucket, a lifecycle `Expiration` rule fires on 500 GB of objects. Your storage bill does not go down. Explain, and name the rule you are missing.

---

## Exercise 4 — Amazon EBS: block storage and the Availability Zone boundary

### Steps

1. Determine your AZs and create a `gp3` volume:

```bash
AZ_A=$(aws ec2 describe-availability-zones --query 'AvailabilityZones[0].ZoneName' --output text)
AZ_B=$(aws ec2 describe-availability-zones --query 'AvailabilityZones[1].ZoneName' --output text)
echo "AZ_A=${AZ_A}  AZ_B=${AZ_B}"

VOL_ID=$(aws ec2 create-volume \
  --availability-zone "${AZ_A}" \
  --size 8 \
  --volume-type gp3 \
  --iops 3000 \
  --throughput 125 \
  --encrypted \
  --tag-specifications "ResourceType=volume,Tags=[{Key=Name,Value=${LAB}-data}]" \
  --query VolumeId --output text)
echo "VOL_ID=${VOL_ID}"
```

```console
AZ_A=us-east-1a  AZ_B=us-east-1b
VOL_ID=vol-0a1b2c3d4e5f67890
```

2. Inspect what you got:

```bash
aws ec2 describe-volumes --volume-ids "${VOL_ID}" \
  --query 'Volumes[0].{AZ:AvailabilityZone,Type:VolumeType,Size:Size,Iops:Iops,Throughput:Throughput,Enc:Encrypted,State:State,Attached:Attachments}' | jq
```

```console
{
  "AZ": "us-east-1a",
  "Type": "gp3",
  "Size": 8,
  "Iops": 3000,
  "Throughput": 125,
  "Enc": true,
  "State": "available",
  "Attached": []
}
```

The `AvailabilityZone` field is the whole lesson. **An EBS volume lives in exactly one AZ and can only ever be attached to an instance in that same AZ.** It is replicated *within* that AZ for durability, but an AZ failure takes the volume with it.

3. Learn the volume types. `gp3` decouples IOPS and throughput from capacity — that is its headline change over `gp2`.

| Type | Media | Max IOPS | Max throughput | Sizing | Typical use |
|---|---|---|---|---|---|
| `gp3` | SSD | 16,000 | 1,000 MiB/s | 1 GiB–16 TiB, IOPS/throughput set independently | Default general purpose; boot volumes |
| `gp2` | SSD | 16,000 | 250 MiB/s | 3 IOPS per GiB, burst to 3,000 under 1 TiB | Previous generation |
| `io2` / `io2` Block Express | SSD | 64,000 / **256,000** | 1,000 / **4,000** MiB/s | up to 64 TiB (Block Express) | Latency-critical databases; **99.999 % durability** |
| `st1` | HDD | 500 | 500 MiB/s | 125 GiB–16 TiB | Big sequential scans: log processing, data warehouse |
| `sc1` | HDD | 250 | 250 MiB/s | 125 GiB–16 TiB | Coldest data that still needs a filesystem; lowest $/GB block |

**HDD volumes (`st1`, `sc1`) cannot be boot volumes.** They are throughput devices; random small reads on them are pathologically slow.

4. Take a snapshot and watch it complete:

```bash
SNAP_ID=$(aws ec2 create-snapshot --volume-id "${VOL_ID}" \
  --description "${LAB} baseline" \
  --tag-specifications "ResourceType=snapshot,Tags=[{Key=Name,Value=${LAB}-snap}]" \
  --query SnapshotId --output text)

aws ec2 wait snapshot-completed --snapshot-ids "${SNAP_ID}"
aws ec2 describe-snapshots --snapshot-ids "${SNAP_ID}" \
  --query 'Snapshots[0].{Id:SnapshotId,State:State,Progress:Progress,VolumeSize:VolumeSize,Enc:Encrypted}'
```

```console
{
    "Id": "snap-0f9e8d7c6b5a43210",
    "State": "completed",
    "Progress": "100%",
    "VolumeSize": 8,
    "Enc": true
}
```

Two mechanics behind that snapshot that the exam probes:

- **Snapshots are stored in Amazon S3** (in an AWS-managed bucket you cannot browse) and are therefore **Regional**, not zonal. That is what lets them cross the AZ boundary.
- **Snapshots are incremental.** Only blocks changed since the previous snapshot of the same volume are stored. Deleting an older snapshot never invalidates a newer one — AWS re-points block references so the newer snapshot stays fully restorable.

5. Cross the AZ boundary — restore into the *other* AZ:

```bash
VOL_B=$(aws ec2 create-volume \
  --availability-zone "${AZ_B}" \
  --snapshot-id "${SNAP_ID}" \
  --volume-type gp3 \
  --tag-specifications "ResourceType=volume,Tags=[{Key=Name,Value=${LAB}-restored}]" \
  --query VolumeId --output text)

aws ec2 describe-volumes --volume-ids "${VOL_ID}" "${VOL_B}" \
  --query 'Volumes[].{Vol:VolumeId,AZ:AvailabilityZone,Snap:SnapshotId}' --output table
```

```console
--------------------------------------------------------------------------
|                             DescribeVolumes                            |
+------------------+-----------------------+---------------------------+
|        AZ        |         Snap          |            Vol            |
+------------------+-----------------------+---------------------------+
|  us-east-1a      |                       |  vol-0a1b2c3d4e5f67890    |
|  us-east-1b      |  snap-0f9e8d7c6b5a... |  vol-0b2c3d4e5f6a78901    |
+------------------+-----------------------+---------------------------+
```

**Snapshot → restore is the only supported way to move an EBS volume between AZs.** Copy the snapshot to another Region first (`aws ec2 copy-snapshot`) and it becomes the way to move between Regions too.

6. Prove the attachment rule fails across AZs. If you have an instance running in `AZ_A`, try to attach the `AZ_B` volume:

```bash
aws ec2 attach-volume --volume-id "${VOL_B}" --instance-id i-0123456789abcdef0 --device /dev/sdf
```

```console
An error occurred (InvalidVolume.ZoneMismatch) when calling the AttachVolume operation:
The volume 'vol-0b2c3d4e5f6a78901' is not in the same availability zone as instance 'i-0123456789abcdef0'
```

### Comprehension check

**Q16.** Your application server in `us-east-1a` fails. You launch a replacement in `us-east-1b` and try to attach the original 500 GiB data volume. What happens, and what is the correct procedure?

**Q17.** You take daily snapshots of a 1 TiB volume that changes by 2 GiB per day. After 30 days, roughly how much snapshot storage are you paying for, and why is it not 30 TiB?

**Q18.** You delete snapshot #1 of 30. Is snapshot #30 still restorable? Explain the mechanism.

**Q19.** A workload needs 400 MiB/s of *sequential* throughput on 4 TiB of data and never does random I/O. Cost matters. Which EBS volume type, and why not `gp3`?

**Q20.** Name the one EBS feature that allows a single volume to be attached to multiple EC2 instances simultaneously, the volume types that support it, and the requirement it imposes on the guest OS.

---

## Exercise 5 — Instance store: the volume that is not a service you provision

### Steps

1. Query which instance families ship with local NVMe:

```bash
aws ec2 describe-instance-types \
  --filters "Name=instance-storage-supported,Values=true" \
  --query 'InstanceTypes[?starts_with(InstanceType, `i4i.`) || starts_with(InstanceType, `m6gd.`)].{Type:InstanceType,GB:InstanceStorageInfo.TotalSizeInGB,Disks:InstanceStorageInfo.Disks[0].Type}' \
  --output table | head -20
```

```console
------------------------------------------------
|            DescribeInstanceTypes             |
+--------------+----------+--------------------+
|    Disks     |    GB    |       Type         |
+--------------+----------+--------------------+
|  ssd         |  937     |  i4i.large         |
|  ssd         |  1875    |  i4i.xlarge        |
|  ssd         |  3750    |  i4i.2xlarge       |
|  ssd         |  237     |  m6gd.large        |
|  ssd         |  474     |  m6gd.xlarge       |
+--------------+----------+--------------------+
```

2. Note the absence of any `create-instance-store-volume` API. There is none. Instance store is **physically attached to the host server** and is delivered as an attribute of the instance type — you get it because you chose `i4i.large`, not because you asked for it.

3. Memorise the lifecycle table, which is exactly what gets tested:

| Event | EBS volume | Instance store |
|---|---|---|
| Instance reboot | Data survives | **Data survives** |
| Instance stop / start | Data survives | **Data lost** |
| Instance hibernate | Data survives | **Data lost** |
| Instance terminate | Survives if `DeleteOnTermination=false` | **Data lost** |
| Underlying host failure | Data survives (replicated in-AZ) | **Data lost** |
| Snapshot possible? | Yes (`create-snapshot`) | **No** |
| Billed separately? | Yes, per GB-month | **No** — included in instance price |

4. Check the `DeleteOnTermination` flag on an existing instance's root volume — the setting that silently destroys data people assumed was durable:

```bash
aws ec2 describe-instances --instance-ids i-0123456789abcdef0 \
  --query 'Reservations[].Instances[].BlockDeviceMappings[].{Dev:DeviceName,Vol:Ebs.VolumeId,DoT:Ebs.DeleteOnTermination}' \
  --output table
```

```console
-----------------------------------------------------------
|                    DescribeInstances                    |
+-------+------------+--------------------------------+
|  DoT  |    Dev     |              Vol               |
+-------+------------+--------------------------------+
|  True |  /dev/xvda |  vol-0aa11bb22cc33dd44         |
|  False|  /dev/sdf  |  vol-0a1b2c3d4e5f67890         |
+-------+------------+--------------------------------+
```

Default is `true` for the root volume and `false` for volumes attached later.

### Comprehension check

**Q21.** An engineer stores a Redis persistence file on instance store to get maximum IOPS, then stops the instance overnight to save money. What is the state of the file next morning, and why?

**Q22.** How do you back up an instance store volume with a point-in-time snapshot?

**Q23.** Give the one workload profile for which instance store is the *correct* production choice, and state the architectural precondition.

---

## Exercise 6 — Shared file systems: Amazon EFS and Amazon FSx

### Steps

1. Create an EFS file system with Elastic throughput and lifecycle tiering:

```bash
FS_ID=$(aws efs create-file-system \
  --creation-token "${LAB}-efs" \
  --performance-mode generalPurpose \
  --throughput-mode elastic \
  --encrypted \
  --tags Key=Name,Value="${LAB}-efs" \
  --query FileSystemId --output text)

aws efs wait file-system-available --file-system-id "${FS_ID}" 2>/dev/null || sleep 15
aws efs describe-file-systems --file-system-id "${FS_ID}" \
  --query 'FileSystems[0].{Id:FileSystemId,State:LifeCycleState,Mode:PerformanceMode,Tput:ThroughputMode,Size:SizeInBytes.Value,Enc:Encrypted}'
```

```console
{
    "Id": "fs-0123456789abcdef0",
    "State": "available",
    "Mode": "generalPurpose",
    "Tput": "elastic",
    "Size": 6144,
    "Enc": true
}
```

`SizeInBytes` is 6144 on an empty file system — EFS metadata overhead. Note there is no capacity parameter anywhere in that command: **EFS is elastic, growing and shrinking automatically, and you are billed for what you actually store.** This is the sharpest contrast with EBS and FSx, where you provision a size up front.

2. Create mount targets — one per AZ. This is where EFS's multi-AZ nature becomes concrete:

```bash
VPC_ID=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)
for SUB in $(aws ec2 describe-subnets --filters "Name=vpc-id,Values=${VPC_ID}" \
             --query 'Subnets[0:2].SubnetId' --output text); do
  aws efs create-mount-target --file-system-id "${FS_ID}" --subnet-id "${SUB}" \
    --query '{MT:MountTargetId,AZ:AvailabilityZoneName,IP:IpAddress}'
done
```

```console
{
    "MT": "fsmt-0aaa11bb22cc33dd4",
    "AZ": "us-east-1a",
    "IP": "172.31.16.204"
}
{
    "MT": "fsmt-0bbb22cc33dd44ee5",
    "AZ": "us-east-1b",
    "IP": "172.31.32.117"
}
```

Each mount target is an **elastic network interface with a private IP inside one subnet**. A client in `us-east-1a` mounts through the `us-east-1a` mount target. Contrast with EBS: the file system itself spans AZs; only the network entry point is zonal.

3. Add a lifecycle policy so cold files tier down automatically:

```bash
aws efs put-lifecycle-configuration --file-system-id "${FS_ID}" \
  --lifecycle-policies \
    '[{"TransitionToIA":"AFTER_30_DAYS"},
      {"TransitionToArchive":"AFTER_90_DAYS"},
      {"TransitionToPrimaryStorageClass":"AFTER_1_ACCESS"}]' \
  --query 'LifecyclePolicies'
```

```console
[
    {
        "TransitionToIA": "AFTER_30_DAYS"
    },
    {
        "TransitionToArchive": "AFTER_90_DAYS"
    },
    {
        "TransitionToPrimaryStorageClass": "AFTER_1_ACCESS"
    }
]
```

EFS Standard is roughly **$0.30/GB-month** — over 10× S3 Standard. EFS Infrequent Access drops to about **$0.016** and EFS Archive to about **$0.008**. Tiering is not optional hygiene on EFS; it is the difference between a viable and an absurd bill.

4. Mount it (requires an EC2 instance in the VPC with the security group permitting **TCP 2049** from the client):

```bash
sudo dnf install -y amazon-efs-utils     # Amazon Linux 2023
sudo mkdir -p /mnt/efs
sudo mount -t efs -o tls fs-0123456789abcdef0:/ /mnt/efs
df -hT /mnt/efs
```

```console
Filesystem     Type  Size  Used Avail Use% Mounted on
127.0.0.1:/    nfs4  8.0E     0  8.0E   0% /mnt/efs
```

`8.0E` (8 exabytes) is EFS reporting a nominal maximum, not a provisioned size. The mount source shows `127.0.0.1` because `-o tls` routes through the local `stunnel` process that `efs-utils` starts for encryption in transit.

Without `efs-utils`, the raw NFS equivalent is:

```bash
sudo mount -t nfs4 -o nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2,noresvport \
  fs-0123456789abcdef0.efs.us-east-1.amazonaws.com:/ /mnt/efs
```

5. Map the FSx family, which is the "the answer is not EFS" branch of the decision tree:

| Service | Protocol | Client OS | Signature use case |
|---|---|---|---|
| **Amazon EFS** | NFS v4.1 | **Linux only** | Shared home directories, CMS assets, container persistent volumes |
| **FSx for Windows File Server** | **SMB** | Windows (also Linux/macOS) | Windows workloads needing **Active Directory** identity, NTFS ACLs, DFS Namespaces |
| **FSx for Lustre** | Lustre (POSIX) | Linux | HPC, ML training, genomics; **links to an S3 bucket** and presents objects as files at sub-ms latency |
| **FSx for NetApp ONTAP** | **NFS + SMB + iSCSI** simultaneously | Mixed | Lift-and-shift of on-premises NetApp; multi-protocol access to one dataset; snapshots/SnapMirror |
| **FSx for OpenZFS** | NFS (v3/v4/v4.1/v4.2) | Linux | Migrating ZFS or general Linux NAS workloads needing ZFS snapshots and compression |

The exam discriminators, in order of how often they appear: **"Windows / Active Directory / SMB" → FSx for Windows File Server. "HPC / machine learning / high-performance compute over S3 data" → FSx for Lustre. "Linux shared file system" → EFS.**

### Comprehension check

**Q24.** A Windows application needs a shared drive with Active Directory-integrated NTFS permissions. Why is EFS wrong, and what is right?

**Q25.** You created one EFS mount target in `us-east-1a`. An instance in `us-east-1b` hangs on `mount` and eventually times out. Give the two most likely causes and the fix for each.

**Q26.** EFS Standard is 10× the per-GB price of S3 Standard. Name a workload where paying that premium is nevertheless the correct architectural decision.

**Q27.** A genomics pipeline holds 300 TB of reference data in S3 and needs it presented to a 500-node compute cluster as a POSIX filesystem at sub-millisecond latency. Which service?

**Q28.** Which single AWS storage service can present the *same* dataset over NFS, SMB, and iSCSI simultaneously?

---

## Exercise 7 — Hybrid and migration: Storage Gateway, DataSync, Snow Family

You will not provision these — they need on-premises hardware or a physical shipment. You will instead build the decision tree, which is what the exam tests.

### Steps

1. Map the four Storage Gateway types. Every one of them is a **virtual appliance (or hardware appliance) running in your data centre** that presents a local protocol and stores in AWS.

| Gateway type | Local protocol it presents | Backing AWS store | Replaces |
|---|---|---|---|
| **S3 File Gateway** | NFS / SMB | Objects in **S3** (1 file = 1 object) | On-prem NAS, with data landing as native S3 objects |
| **FSx File Gateway** | SMB | **FSx for Windows File Server** | Low-latency on-prem cache in front of an FSx share |
| **Volume Gateway — Cached** | **iSCSI** block | S3, with a local cache of hot blocks | SAN where the primary dataset lives in AWS |
| **Volume Gateway — Stored** | **iSCSI** block | Full copy on-prem, asynchronously backed up to **EBS snapshots** | SAN where the primary dataset stays on-prem |
| **Tape Gateway (VTL)** | **iSCSI VTL** | S3 + **S3 Glacier / Deep Archive** | Physical tape library and off-site tape vaulting |

The Cached-vs-Stored distinction is a reliable exam question: **Cached = primary data in AWS, hot cache local. Stored = primary data local, backup in AWS.** "Low-latency access to my *entire* dataset" ⇒ Stored. "My dataset is bigger than my data centre" ⇒ Cached.

2. Map the transfer services against the constraint that actually decides between them — **link bandwidth and data volume**.

| Service | Mechanism | When it wins |
|---|---|---|
| **AWS DataSync** | Agent-based transfer **over the network** (internet or Direct Connect), NFS/SMB/HDFS/object → S3, EFS, FSx | Adequate bandwidth; recurring or one-time; needs validation, scheduling, and incremental sync |
| **AWS Snowball Edge** | **Physical ruggedised device shipped to you**, ~80 TB usable storage (Storage Optimized), plus on-board compute | Tens to hundreds of TB with insufficient bandwidth, or an edge site with no connectivity |
| **AWS Snowcone** | Smallest device, 8 TB HDD / 14 TB SSD, ~2.1 kg | Space-constrained edge locations, drones, vehicles, small transfers |
| **AWS Transfer Family** | Managed **SFTP / FTPS / FTP / AS2** endpoint in front of S3 or EFS | Partners who must keep using an SFTP client |
| **S3 Transfer Acceleration** | Uploads enter via the nearest **CloudFront edge location**, then travel the AWS backbone | Long-distance uploads to a distant Region |

3. Do the calculation that produces the Snowball answer. Time to transfer *D* terabytes over a link of *B* Mbps at 80 % utilisation:

```
hours = (D × 8 × 1,000,000) / (B × 0.8 × 3600)
```

For **100 TB over a 500 Mbps link**:

```console
$ python3 -c "D=100; B=500; print(f'{(D*8*1e6)/(B*0.8*3600)/24:.1f} days')"
23.1 days
```

23 days of saturating your production internet link. A Snowball Edge round trip is roughly a week and does not touch your bandwidth. **This is the reasoning the exam is looking for — not the device specs.**

4. Note the deprecation: **AWS Snowmobile (the 100 PB shipping container) has been discontinued** and is no longer orderable. Older study material and some question banks still reference it; the current exam guide scopes the Snow Family to Snowcone and Snowball Edge. Extremely large migrations are now handled with multiple parallel Snowball Edge devices.

5. Enable S3 Transfer Acceleration on your lab bucket and observe the alternate endpoint:

```bash
aws s3api put-bucket-accelerate-configuration --bucket "${BUCKET}" \
  --accelerate-configuration Status=Enabled
aws s3api get-bucket-accelerate-configuration --bucket "${BUCKET}"
echo "Accelerated endpoint: ${BUCKET}.s3-accelerate.amazonaws.com"
```

```console
{
    "Status": "Enabled"
}
Accelerated endpoint: clf36-123456789012-archive.s3-accelerate.amazonaws.com
```

Disable it immediately after observing — accelerated transfers carry a per-GB surcharge:

```bash
aws s3api put-bucket-accelerate-configuration --bucket "${BUCKET}" \
  --accelerate-configuration Status=Suspended
```

### Comprehension check

**Q29.** A media company has 400 TB of archive footage on-premises and a 200 Mbps internet link that also carries production traffic. They need it in S3 Glacier within one month. Which service, and show the reasoning.

**Q30.** A hospital must retire its physical tape library but its backup software only speaks to tape drives over iSCSI. Which service and which mode?

**Q31.** Distinguish Volume Gateway Cached from Volume Gateway Stored in one sentence each.

**Q32.** A branch office needs to keep writing to a local NFS share, but the files must end up as S3 objects that a Lambda function can process. Which service?

**Q33.** A team syncs 2 TB nightly from an on-prem NAS to EFS over a 10 Gbps Direct Connect link, and needs integrity verification and scheduling. Snowball or DataSync? Why?

---

## Exercise 8 — AWS Backup and immutability

### Steps

1. Inspect the default backup vault and create a dedicated one:

```bash
aws backup create-backup-vault --backup-vault-name "${LAB}-vault" \
  --backup-vault-tags Purpose=clf36-lab \
  --query '{Name:BackupVaultName,Arn:BackupVaultArn}'
```

```console
{
    "Name": "clf36-123456789012-vault",
    "Arn": "arn:aws:backup:us-east-1:123456789012:backup-vault:clf36-123456789012-vault"
}
```

2. Create a backup plan. Save as `/tmp/plan.json`:

```json
{
  "BackupPlanName": "clf36-daily-plan",
  "Rules": [
    {
      "RuleName": "DailyRetain35",
      "TargetBackupVaultName": "REPLACE_VAULT",
      "ScheduleExpression": "cron(0 5 ? * * *)",
      "StartWindowMinutes": 60,
      "CompletionWindowMinutes": 180,
      "Lifecycle": {
        "MoveToColdStorageAfterDays": 30,
        "DeleteAfterDays": 365
      },
      "RecoveryPointTags": { "Tier": "daily" }
    }
  ]
}
```

```bash
sed -i "s/REPLACE_VAULT/${LAB}-vault/" /tmp/plan.json
PLAN_ID=$(aws backup create-backup-plan --backup-plan file:///tmp/plan.json \
  --query BackupPlanId --output text)
echo "PLAN_ID=${PLAN_ID}"
```

```console
PLAN_ID=8f4a2c1e-5b6d-4a3f-9e2c-7d1b0a9f8e7c
```

> AWS Backup validates `DeleteAfterDays ≥ MoveToColdStorageAfterDays + 90`. Setting `DeleteAfterDays: 100` with cold storage at day 30 returns `InvalidParameterValueException` — this mirrors the 90-day minimum duration of the Glacier tiers underneath.

3. Select resources **by tag**, not by ID. This is the design point of AWS Backup: policy attaches to a tag, so a resource created next month is protected the moment it is tagged.

```bash
ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/service-role/AWSBackupDefaultServiceRole"

aws backup create-backup-selection --backup-plan-id "${PLAN_ID}" \
  --backup-selection "{
    \"SelectionName\": \"tagged-backup-daily\",
    \"IamRoleArn\": \"${ROLE_ARN}\",
    \"ListOfTags\": [
      {\"ConditionType\": \"STRINGEQUALS\", \"ConditionKey\": \"Backup\", \"ConditionValue\": \"daily\"}
    ]
  }" --query SelectionId --output text
```

```console
c3f9a1b7-2d84-4e60-9a1f-6b52c8d0e3a4
```

4. Tag the EBS volume from Exercise 4 and take an on-demand backup:

```bash
aws ec2 create-tags --resources "${VOL_ID}" --tags Key=Backup,Value=daily

JOB_ID=$(aws backup start-backup-job \
  --backup-vault-name "${LAB}-vault" \
  --resource-arn "arn:aws:ec2:${AWS_REGION}:${ACCOUNT_ID}:volume/${VOL_ID}" \
  --iam-role-arn "${ROLE_ARN}" \
  --query BackupJobId --output text)

sleep 60
aws backup describe-backup-job --backup-job-id "${JOB_ID}" \
  --query '{State:State,Pct:PercentDone,Bytes:BackupSizeInBytes,RP:RecoveryPointArn}'
```

```console
{
    "State": "COMPLETED",
    "Pct": "100.0",
    "Bytes": 8589934592,
    "RP": "arn:aws:ec2:us-east-1::snapshot/snap-01a2b3c4d5e6f7890"
}
```

Look closely at that `RecoveryPointArn`: it is an **EBS snapshot**. AWS Backup did not invent a new storage mechanism; it orchestrated the service-native one and applied a policy, retention schedule, and audit trail on top. Its value is *centralisation and governance* across EBS, EFS, RDS, DynamoDB, FSx, Storage Gateway, S3, Aurora, Neptune, DocumentDB and on-premises VMware — one policy, one console, one compliance report.

5. Understand **Vault Lock** without engaging it:

```bash
# DO NOT RUN in compliance mode on a real account.
# aws backup put-backup-vault-lock-configuration \
#   --backup-vault-name "${LAB}-vault" \
#   --min-retention-days 7 --max-retention-days 365 --changeable-for-days 3
```

Vault Lock enforces **WORM** (write-once, read-many) on recovery points. In *compliance mode*, once the `changeable-for-days` grace period (minimum 3 days) elapses, **the lock cannot be removed by anyone — not the account root user, not AWS Support**. Backups cannot be deleted before their retention expires. This is the primary ransomware and insider-threat control in the backup story, and its S3 counterpart is **S3 Object Lock** (which likewise offers governance mode — bypassable with a specific IAM permission — and compliance mode, which is not).

### Comprehension check

**Q34.** AWS Backup's recovery point for an EBS volume turned out to be an EBS snapshot. So what does AWS Backup actually add?

**Q35.** An attacker obtains admin credentials and attempts to delete all backups before encrypting production. Which two features stop this, one for backups and one for S3?

**Q36.** Why did AWS reject a plan with `MoveToColdStorageAfterDays: 30` and `DeleteAfterDays: 100`?

**Q37.** Your backup selection matches on the tag `Backup=daily`. A colleague launches a new RDS instance next month and tags it. What happens, and why is this the design point?

---

## Exercise 9 — Diagnostics

Three failures you will actually meet, each with the investigation path.

### 9.1 `AccessDenied` on `GetObject`

Steps:

1. Reproduce with an unsigned request:

```bash
curl -s -o /dev/null -w '%{http_code}\n' "https://${BUCKET}.s3.amazonaws.com/payroll.csv"
```

```console
403
```

2. Walk the evaluation chain in order. An S3 request is allowed only if **every** layer permits it, and an explicit `Deny` anywhere wins outright:

```bash
echo "--- 1. Block Public Access (account level) ---"
aws s3control get-public-access-block --account-id "${ACCOUNT_ID}" 2>/dev/null | jq -c '.PublicAccessBlockConfiguration' || echo "not configured at account level"

echo "--- 2. Block Public Access (bucket level) ---"
aws s3api get-public-access-block --bucket "${BUCKET}" | jq -c '.PublicAccessBlockConfiguration'

echo "--- 3. Bucket policy ---"
aws s3api get-bucket-policy --bucket "${BUCKET}" --query Policy --output text | jq -c '.Statement[].Effect'

echo "--- 4. Object ownership / ACL state ---"
aws s3api get-bucket-ownership-controls --bucket "${BUCKET}" --query 'OwnershipControls.Rules[0].ObjectOwnership' --output text

echo "--- 5. Default encryption ---"
aws s3api get-bucket-encryption --bucket "${BUCKET}" \
  --query 'ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault' | jq -c
```

```console
--- 1. Block Public Access (account level) ---
{"BlockPublicAcls":true,"IgnorePublicAcls":true,"BlockPublicPolicy":true,"RestrictPublicBuckets":true}
--- 2. Block Public Access (bucket level) ---
{"BlockPublicAcls":true,"IgnorePublicAcls":true,"BlockPublicPolicy":true,"RestrictPublicBuckets":true}
--- 3. Bucket policy ---
"Deny"
--- 4. Object ownership / ACL state ---
BucketOwnerEnforced
--- 5. Default encryption ---
{"SSEAlgorithm":"AES256"}
```

The 403 here is *correct behaviour*, produced by four independent controls. The diagnostic skill is knowing there are four places to look, in that order.

3. Verify your own authenticated identity still works:

```bash
aws s3api get-object --bucket "${BUCKET}" --key payroll.csv /tmp/ok.csv --query 'ContentLength'
```

```console
26
```

### 9.2 Silent S3 cost growth

Steps:

1. Read the free daily storage metrics from CloudWatch. Note the required `StorageType` dimension:

```bash
aws cloudwatch get-metric-statistics \
  --namespace AWS/S3 --metric-name BucketSizeBytes \
  --dimensions Name=BucketName,Value="${BUCKET}" Name=StorageType,Value=StandardStorage \
  --start-time "$(date -u -d '3 days ago' +%Y-%m-%dT%H:%M:%SZ)" \
  --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --period 86400 --statistics Average \
  --query 'sort_by(Datapoints,&Timestamp)[].{T:Timestamp,Bytes:Average}' --output table
```

```console
--------------------------------------------------
|              GetMetricStatistics               |
+------------+-----------------------------------+
|   Bytes    |               T                   |
+------------+-----------------------------------+
|  200042.0  |  2026-09-02T00:00:00+00:00        |
|  200068.0  |  2026-09-03T00:00:00+00:00        |
+------------+-----------------------------------+
```

`BucketSizeBytes` and `NumberOfObjects` are free and reported once daily. Per-request metrics are a paid opt-in.

2. Enumerate the three storage buckets that `ListObjectsV2` does not show you:

```bash
echo "== Non-current versions =="
aws s3api list-object-versions --bucket "${BUCKET}" \
  --query 'length(Versions[?IsLatest==`false`])'

echo "== Delete markers (zero bytes, but they hide live data) =="
aws s3api list-object-versions --bucket "${BUCKET}" --query 'length(DeleteMarkers)'

echo "== Orphaned multipart parts =="
aws s3api list-multipart-uploads --bucket "${BUCKET}" --query 'length(Uploads)'
```

```console
== Non-current versions ==
1
== Delete markers (zero bytes, but they hide live data) ==
0
== Orphaned multipart parts ==
1
```

3. Break down size by storage class for the whole bucket:

```bash
aws s3 ls "s3://${BUCKET}" --recursive --summarize --human-readable | tail -3
aws s3api list-objects-v2 --bucket "${BUCKET}" \
  --query 'Contents[].{Key:Key,Class:StorageClass}' --output table
```

```console
Total Objects: 2
   Total Size: 195.4 KiB
-----------------------------------------------
|               ListObjectsV2                 |
+---------------+-----------------------------+
|     Class     |            Key              |
+---------------+-----------------------------+
|  STANDARD_IA  |  logs/2026/app.log          |
|  None         |  payroll.csv                |
+---------------+-----------------------------+
```

**`aws s3 ls --summarize` counts only current versions.** In a versioned bucket, the number it prints can be a small fraction of what you are billed for. For a real account-wide view, use **S3 Storage Lens** (free dashboard with 28 default metrics, including non-current version bytes and incomplete multipart bytes) or **S3 Inventory** for a scheduled CSV/Parquet manifest.

### 9.3 EBS performance investigation

Steps:

1. Check for volume-level throttling. `BurstBalance` exists only on `gp2`, `st1`, `sc1` — on `gp3` there is nothing to deplete, which is one of its main operational advantages:

```bash
aws cloudwatch get-metric-statistics \
  --namespace AWS/EBS --metric-name BurstBalance \
  --dimensions Name=VolumeId,Value="${VOL_ID}" \
  --start-time "$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)" \
  --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --period 300 --statistics Minimum \
  --query 'length(Datapoints)'
```

```console
0
```

Zero datapoints on a `gp3` volume — expected, and itself diagnostic information.

2. Check `VolumeQueueLength`, the single most useful EBS saturation signal. It is the count of I/O requests waiting to be serviced. Sustained above ~1 per 1,000 provisioned IOPS means the device, not the application, is the bottleneck:

```bash
aws cloudwatch get-metric-statistics \
  --namespace AWS/EBS --metric-name VolumeQueueLength \
  --dimensions Name=VolumeId,Value="${VOL_ID}" \
  --start-time "$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)" \
  --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --period 300 --statistics Average --query 'Datapoints[].Average'
```

3. Check the **instance-level** EBS limits, which are separate from and can be lower than the volume's. On Nitro instances the metrics are `EBSIOBalance%` and `EBSByteBalance%` in the `AWS/EC2` namespace. A volume provisioned for 16,000 IOPS attached to an instance whose EBS bandwidth caps at 8,000 will never exceed 8,000 — and the volume's own metrics will show no throttling at all. **Instance type is half of EBS performance.**

4. On the instance itself, confirm from the guest side:

```bash
lsblk
sudo iostat -xz 5 3
```

```console
NAME          MAJ:MIN RM  SIZE RO TYPE MOUNTPOINTS
nvme0n1       259:0    0    8G  0 disk
└─nvme0n1p1   259:1    0    8G  0 part /
nvme1n1       259:2    0    8G  0 disk /data

Device   r/s     w/s     rkB/s   wkB/s  await  %util
nvme1n1  0.00  2998.40    0.00 11993.60  21.34  99.80
```

`%util` at 99.8 with `w/s` pinned at ~3,000 — exactly the provisioned baseline — is the signature of a volume at its IOPS limit. With `gp3` the fix is a single API call, with no resize and no downtime:

```bash
aws ec2 modify-volume --volume-id "${VOL_ID}" --iops 8000 --throughput 500 \
  --query 'VolumeModification.{State:ModificationState,TargetIops:TargetIops}'
```

```console
{
    "State": "modifying",
    "TargetIops": 8000
}
```

### Comprehension check

**Q38.** `aws s3 ls --summarize` reports 40 GB. Your bill shows 900 GB of S3 Standard. Name three places the missing 860 GB could be, and the command that reveals each.

**Q39.** A `gp3` volume shows no `BurstBalance` metric at all. Is the volume broken?

**Q40.** `VolumeQueueLength` is flat near zero and `VolumeReadOps` is well under the provisioned IOPS, yet the database is slow and `%util` on the guest is 100 %. Where do you look next?

**Q41.** Order the four controls you check when diagnosing an S3 `AccessDenied`, and state the rule that makes the order matter.

---

## Exercise 10 — Cleanup

Run this. Storage bills quietly.

### Steps

1. Empty and delete the versioned bucket. `aws s3 rb --force` **does not remove non-current versions or delete markers** — a versioned bucket must be purged version by version:

```bash
aws s3api delete-objects --bucket "${BUCKET}" --delete "$(
  aws s3api list-object-versions --bucket "${BUCKET}" \
    --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' --output json)" 2>/dev/null

aws s3api delete-objects --bucket "${BUCKET}" --delete "$(
  aws s3api list-object-versions --bucket "${BUCKET}" \
    --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' --output json)" 2>/dev/null

for U in $(aws s3api list-multipart-uploads --bucket "${BUCKET}" \
           --query 'Uploads[].[Key,UploadId]' --output text 2>/dev/null); do :; done

aws s3api delete-bucket --bucket "${BUCKET}" && echo "bucket deleted"
```

```console
bucket deleted
```

2. Remove EBS resources:

```bash
aws ec2 delete-volume --volume-id "${VOL_ID}"
aws ec2 delete-volume --volume-id "${VOL_B}"
aws ec2 delete-snapshot --snapshot-id "${SNAP_ID}"
```

3. Remove EFS — mount targets first, or the delete is refused:

```bash
for MT in $(aws efs describe-mount-targets --file-system-id "${FS_ID}" \
            --query 'MountTargets[].MountTargetId' --output text); do
  aws efs delete-mount-target --mount-target-id "${MT}"
done
sleep 60
aws efs delete-file-system --file-system-id "${FS_ID}" && echo "efs deleted"
```

```console
efs deleted
```

4. Remove AWS Backup objects. Recovery points must go before the vault:

```bash
for RP in $(aws backup list-recovery-points-by-backup-vault \
            --backup-vault-name "${LAB}-vault" \
            --query 'RecoveryPoints[].RecoveryPointArn' --output text); do
  aws backup delete-recovery-point --backup-vault-name "${LAB}-vault" --recovery-point-arn "${RP}"
done

SEL=$(aws backup list-backup-selections --backup-plan-id "${PLAN_ID}" \
      --query 'BackupSelectionsList[0].SelectionId' --output text)
aws backup delete-backup-selection --backup-plan-id "${PLAN_ID}" --selection-id "${SEL}"
aws backup delete-backup-plan --backup-plan-id "${PLAN_ID}" >/dev/null
aws backup delete-backup-vault --backup-vault-name "${LAB}-vault" && echo "vault deleted"
```

5. Verify nothing survived:

```bash
aws ec2 describe-volumes --filters "Name=tag:Name,Values=${LAB}-*" --query 'length(Volumes)'
aws ec2 describe-snapshots --owner-ids self --filters "Name=tag:Name,Values=${LAB}-*" --query 'length(Snapshots)'
aws s3api list-buckets --query "length(Buckets[?Name=='${BUCKET}'])"
```

```console
0
0
0
```

### Comprehension check

**Q42.** Why did `aws s3 rb --force` fail to delete the versioned bucket, and what does that tell you about how S3 accounts for versions?

**Q43.** Deleting the EFS file system failed until the mount targets were removed. What does that ordering reveal about what a mount target *is*?

---

## Final synthesis — the identification table

Commit this to memory. It answers the task statement directly.

| Requirement in the question stem | Service |
|---|---|
| Object storage, HTTP API, static website hosting, data lake | **Amazon S3** |
| Archive, retrieval in hours, lowest cost per GB | **S3 Glacier Flexible Retrieval / Deep Archive** |
| Archive with millisecond retrieval | **S3 Glacier Instant Retrieval** |
| Unpredictable, changing access patterns, automatic optimisation | **S3 Intelligent-Tiering** |
| Persistent block volume for one EC2 instance | **Amazon EBS** |
| Temporary scratch, cache, buffer; max IOPS; data loss acceptable | **EC2 instance store** |
| Shared Linux file system, NFS, elastic capacity, multi-AZ | **Amazon EFS** |
| Shared Windows file system, SMB, Active Directory | **FSx for Windows File Server** |
| HPC / ML file system linked to S3 | **FSx for Lustre** |
| Multi-protocol (NFS+SMB+iSCSI); NetApp migration | **FSx for NetApp ONTAP** |
| ZFS snapshots / Linux NAS migration | **FSx for OpenZFS** |
| On-premises appliance bridging to AWS storage | **AWS Storage Gateway** |
| Replace physical tape library | **Storage Gateway — Tape Gateway** |
| Petabyte migration, insufficient bandwidth, physical shipment | **AWS Snowball Edge** |
| Network-based transfer/sync to S3, EFS, FSx with validation | **AWS DataSync** |
| Managed SFTP/FTPS in front of S3 or EFS | **AWS Transfer Family** |
| Centralised, policy-driven backup across many services | **AWS Backup** |
| Immutable, undeletable backups (WORM) | **Backup Vault Lock** / **S3 Object Lock** |

---

<details>
<summary><strong>Answers</strong> — expand only after attempting every question</summary>

### Exercise 1 — The three storage families

**A1.** **Block storage → Amazon EBS**, specifically a `gp3` or `io2` volume. Two requirements force it: the application must *format* the device itself (so it needs a raw block device, not a file server's namespace), and it performs *in-place random updates* to a large file. Object storage cannot do partial writes at all; a network file system would add protocol latency to every 4 KiB update. If the workload also demanded sub-millisecond latency at very high IOPS, `io2` Block Express is the escalation.

**A2.** Because S3 objects are **immutable**. There is no `append`, no `seek`, and no byte-range write in the S3 data model — only `PutObject`, which replaces the entire object and creates a new version (or overwrites, if versioning is off). To "append", you must `GetObject` the whole object, concatenate locally, and `PutObject` it back. This is why append-heavy workloads (logs, databases, WAL files) belong on EBS or EFS, and only land in S3 once they are sealed. It is also why partitioned, roll-over log files are the standard S3 logging pattern.

**A3.** No — there is exactly **one** stored entity, the object with key `a/b/c/d/e.txt`. The proof is in step 4: deleting that single object dropped `KeyCount` to 0, and no `a/`, `a/b/`, or `a/b/c/` remained. S3's namespace is flat; the `/` characters are ordinary bytes in the key string. The console renders a directory tree by grouping on a delimiter (`ListObjectsV2 --delimiter /` returns `CommonPrefixes`), which is presentation, not storage.

**A4.** **File storage → Amazon FSx for Windows File Server.** The discriminators are *Windows*, *concurrent access to the same tree*, and *Active Directory permissions*. EFS is NFS-only and cannot serve NTFS ACLs or AD identity. EBS is ruled out because a block volume cannot be shared read-write among 40 clients.

### Exercise 2 — Amazon S3

**A5.** S3 Standard stores each object redundantly across a **minimum of three Availability Zones** within the Region. The two classes that break this are **S3 One Zone-IA** and **S3 Express One Zone**, which store data in a **single AZ**. Both still carry 11 nines of *designed durability against device failure*, but neither survives the destruction of its AZ — which is why One Zone-IA is only appropriate for re-creatable data (derived thumbnails, secondary copies of data whose primary is elsewhere).

**A6.** The two options are **Suspended** and **Enabled**. There is no way back to the original *unversioned* state — the option that is not available. Once versioning is enabled, the bucket is permanently version-aware. Suspending it stops S3 assigning new version IDs (new objects get version ID `null`), but every version already created remains stored and billed. If you truly need an unversioned bucket, create a new one and copy.

**A7.** Because the delete marker only *shadows* the object; it does not remove any data. All prior versions — the 16-byte v1 and the 26-byte v2 — remained fully stored and fully billed, plus the delete marker itself as a (negligible) additional version. `GetObject` returned `NoSuchKey` because it resolves to the current version, and the current version was the delete marker. This is exactly the mechanism behind the classic runaway S3 bill: a "cleanup" script that deletes millions of objects in a versioned bucket, frees zero bytes, and adds millions of delete markers.

**A8.**
- **Durability** = the probability the stored bytes are not lost. S3 Standard is *designed for* **99.999999999 %** (11 nines) over a year. This is about data loss.
- **Availability** = the probability you can successfully reach the data right now. S3 Standard is *designed for* **99.99 %** availability, backed by a **99.9 %** availability SLA (the SLA number is deliberately lower than the design target).

They are independent: an S3 Region-wide API outage makes data unavailable while it remains perfectly durable. The exam frequently offers 99.99 % as a durability distractor.

**A9.** Block Public Access, as its name says, restricts **public** access — anonymous or `Principal: "*"` grants. It does **not** restrict:
- IAM principals in your own account with `s3:*` permissions;
- cross-account access granted via a bucket policy to a *specific* account or role ARN (this is not "public");
- presigned URLs, which carry the signature of an authorised principal and work regardless of BPA;
- access via an S3 Access Point or VPC endpoint policy that grants a named principal.

So BPA prevents accidental world-readability; it is not an access control system. You still need least-privilege IAM and bucket policies.

### Exercise 3 — Storage classes and lifecycle

**A10.** S3 Standard-IA has a **128 KB minimum billable object size**. Each 40 KB thumbnail would be billed as 128 KB — a 3.2× inflation of billed bytes. Additionally there is a **30-day minimum storage duration** and a **$0.01/GB retrieval fee**.

Rough monthly arithmetic for 10 M × 40 KB (≈ 400 GB actual):
- S3 Standard: 400 GB × $0.023 ≈ **$9.20**
- S3 Standard-IA: billed as 10 M × 128 KB ≈ 1,280 GB × $0.0125 ≈ **$16.00**, plus retrieval fees, plus the per-object transition request charge (~$0.01 per 1,000 = **$100 one-off** for 10 M objects).

The "optimisation" nearly doubles the recurring bill and adds a $100 transition charge. **The correct alternative is S3 Intelligent-Tiering**, which has **no minimum object size penalty**, no retrieval fee, and no minimum duration — objects under 128 KB simply stay in the Frequent Access tier and are never charged the monitoring fee. Intelligent-Tiering is the safe default whenever object sizes are small or access is unknown.

**A11.** **S3 Glacier Deep Archive.** Its Standard retrieval is **within 12 hours**, which exactly meets the requirement, at roughly **$0.00099/GB-month** — the lowest storage price in AWS. Glacier Flexible Retrieval is the *wrong* answer specifically because it is **~3.6× more expensive** ($0.0036/GB-mo) and you are paying that premium for retrieval speed (3–5 h Standard, 1–5 min Expedited) that the 12-hour requirement does not need. The correct reasoning is: pick the *slowest* class that still meets the stated SLA. Deep Archive's 180-day minimum duration is a non-issue against a 7-year retention.

**A12.** **30 days.** S3 Standard-IA has a 30-day minimum storage duration. Deleting (or transitioning again) before that bills you for the full 30-day period regardless. Same trap at 90 days for both Glacier Instant Retrieval and Glacier Flexible Retrieval, and 180 days for Deep Archive. This is why lifecycle rules that move objects through several classes too quickly can cost *more* than leaving them in Standard.

**A13.** They are **the same on latency and durability** — both deliver millisecond retrieval, both replicate across ≥ 3 AZs, both carry a 128 KB minimum billable size. They differ on the **storage/retrieval cost trade**:

| | Storage $/GB-mo | Retrieval $/GB | Min. duration |
|---|---|---|---|
| Standard-IA | 0.0125 | 0.01 | 30 days |
| Glacier Instant Retrieval | **0.004** | **0.03** | **90 days** |

Glacier IR is ~3× cheaper to *store* and ~3× more expensive to *retrieve*. The break-even is access frequency: Glacier IR wins when objects are read roughly **once per quarter or less**; Standard-IA wins when they are read roughly monthly. The axis is **access frequency**, not latency.

**A14.** **S3 Intelligent-Tiering.** Its distinctive charge is a small **per-object monitoring and automation fee** (~$0.0025 per 1,000 objects per month) — it is the only class that charges for *observation* rather than only for storage and requests. In exchange, S3 moves objects between Frequent, Infrequent, Archive Instant Access and (optionally) Archive/Deep Archive Access tiers automatically, **with no retrieval fees and no minimum duration**. Because the monitoring fee is per object, it is uneconomic for buckets with enormous numbers of tiny objects; AWS waives it for objects smaller than 128 KB, which stay in Frequent Access.

**A15.** In a versioned bucket, `Expiration` on a *current* version does not delete data — it **adds a delete marker** and turns the previously-current version into a non-current version. All 500 GB remain stored and billed; they are merely invisible to `ListObjectsV2` and `GetObject`. You are missing **`NoncurrentVersionExpiration`** (with `NoncurrentDays`), which is the rule that actually reclaims the space. A complete versioned-bucket lifecycle rule needs `Expiration`, `NoncurrentVersionExpiration`, `ExpiredObjectDeleteMarker: true` (to sweep up delete markers whose versions are all gone), and `AbortIncompleteMultipartUpload`.

### Exercise 4 — Amazon EBS

**A16.** The attach fails with **`InvalidVolume.ZoneMismatch`**, exactly as demonstrated in step 6. An EBS volume is bound to a single Availability Zone for its entire life and can never be attached across that boundary. The correct procedure:

1. `aws ec2 create-snapshot --volume-id vol-xxx` (the snapshot is stored in S3 and is **Regional**);
2. `aws ec2 wait snapshot-completed`;
3. `aws ec2 create-volume --snapshot-id snap-xxx --availability-zone us-east-1b`;
4. `aws ec2 attach-volume` to the new instance;
5. mount inside the guest.

Cross-Region is the same flow with `aws ec2 copy-snapshot` inserted between steps 2 and 3. The architectural lesson: if this recovery time is unacceptable, the data should not have been on a single-AZ EBS volume — use EFS, a Multi-AZ RDS instance, or S3.

**A17.** Roughly **1 TiB + (29 × 2 GiB) ≈ 1,058 GiB**, not 30 TiB. The first snapshot captures every allocated block; every subsequent snapshot stores **only the blocks changed since the previous snapshot** of the same volume, with unchanged blocks stored as references. Snapshot storage is billed on the *unique* blocks retained across the whole snapshot set. Two refinements worth knowing: EBS snapshots are compressed, so the real figure is usually lower, and only *written* blocks are captured, so a freshly formatted 1 TiB volume containing 100 GiB of data produces a snapshot far smaller than 1 TiB.

**A18.** **Yes, fully restorable.** When you delete a snapshot, AWS removes only the blocks that are *exclusively* referenced by it; any block still needed by a later snapshot is retained and re-parented to the next snapshot in the chain. Snapshots are not a differential chain that breaks if you remove a link — the incremental structure is an implementation detail invisible to restore. Every snapshot behaves as a complete, independent point-in-time image. This is precisely what makes rolling retention policies (keep 7 daily, 4 weekly, 12 monthly) safe.

**A19.** **`st1` (Throughput Optimized HDD).** It delivers up to 500 MiB/s, comfortably above the required 400 MiB/s, on purely sequential access, at roughly **$0.045/GB-month** — a little over half the price of `gp3`. `gp3` is the wrong choice on cost: 4 TiB of `gp3` at ~$0.08/GB-month is roughly $327/month versus roughly $184 for `st1`, and you would be paying for random-access SSD capability the workload never uses. The caveats to state: `st1` cannot be a boot volume, its performance collapses under random I/O, and it uses a credit-based burst model, so the sustained baseline scales with volume size (4 TiB is large enough here). If throughput needed to exceed 500 MiB/s, `st1` would be out and `gp3` (up to 1,000 MiB/s) back in.

**A20.** **EBS Multi-Attach.** Supported on **`io1` and `io2`** (including `io2` Block Express) only, up to **16 Nitro-based instances in the same Availability Zone**. The critical requirement: **the guest OS must use a cluster-aware file system** — GFS2, OCFS2, or a raw-device clustered application such as Oracle RAC. Mounting `ext4` or `xfs` from two instances simultaneously **will corrupt the filesystem**, because each kernel independently caches metadata and neither is aware of the other's writes. Multi-Attach provides shared block access; it does **not** provide the distributed locking that shared access requires. When someone asks for "shared storage" without a cluster filesystem, the correct answer is EFS or FSx, not Multi-Attach.

### Exercise 5 — Instance store

**A21.** **The file is gone.** Instance store data survives a *reboot* but not a *stop/start*, because stopping releases the instance from its physical host; on start it is placed on a different host with different physical disks. There is no migration and no warning. Additionally, the cost saving was partly illusory: instance store capacity is bundled into the instance's hourly price and is not billed separately, so stopping saved only the compute charge. The correct pattern is EBS for anything that must survive a stop, with instance store reserved for data reconstructible from another source.

**A22.** **You cannot.** There is no snapshot API for instance store — `create-snapshot` accepts only an EBS volume ID. Instance store is ephemeral local NVMe with no AWS-managed durability layer. Your options are all application-level: replicate to another node, write to an EBS volume, sync to S3, or use a service (AWS Backup, a database's own replication) that operates on data already on durable storage. If the question implies "snapshot the instance store", the answer being tested is that this is impossible by design.

**A23.** The correct profile is **high-IOPS, low-latency temporary data that is reconstructible**: database buffer/temp space and scratch tables, Elasticsearch/OpenSearch data nodes with replicas, in-memory cache spillover, MapReduce/Spark shuffle space, and video transcoding scratch. The **architectural precondition is that durability is provided at the layer above** — replication across nodes, a durable copy in S3 or EBS, or the ability to rebuild the data from source. Instance store is a legitimate and often correct production choice; the mistake is using it *without* that precondition.

### Exercise 6 — EFS and FSx

**A24.** EFS is wrong on two independent counts: it speaks **NFS v4.1 only** (Windows has no supported production NFS client for this pattern), and it uses **POSIX** ownership — UID/GID — so it cannot express NTFS ACLs or map to Active Directory identities. The right service is **Amazon FSx for Windows File Server**: native SMB, NTFS semantics, native AD join (AWS Managed Microsoft AD or your self-managed AD), Windows shadow copies, and DFS Namespaces. Rule of thumb: **NFS/Linux → EFS; SMB/Windows/AD → FSx for Windows File Server.**

**A25.** Two likely causes:

1. **No mount target in the client's AZ.** An EFS client must reach a mount target, and a mount target is an ENI in one specific subnet. With only a `us-east-1a` mount target, the `us-east-1b` client has no endpoint to reach (or is routed cross-AZ, incurring charges, if routing even permits it). *Fix:* `aws efs create-mount-target` in a `us-east-1b` subnet — best practice is one mount target per AZ that has clients.
2. **Security group blocks TCP 2049.** The mount target's security group must allow inbound NFS (2049) from the client's security group or CIDR. *Fix:* add that inbound rule. A `mount` that hangs and then times out — rather than failing immediately — is the classic signature of a dropped (rather than rejected) packet, i.e. a security group or NACL problem.

A third, less common cause: DNS resolution of `fs-xxx.efs.<region>.amazonaws.com` fails because the VPC has `enableDnsHostnames`/`enableDnsSupport` disabled.

**A26.** Any workload where **multiple compute nodes must read and write the same POSIX tree concurrently, with immediate consistency**. Concrete examples: a WordPress or Drupal fleet behind a load balancer sharing `wp-content/uploads`; a Jenkins or GitLab runner farm sharing a workspace; container persistent volumes that must survive pod rescheduling to a different node or AZ; a scientific pipeline where stage 2 reads files stage 1 is still producing.

S3 cannot substitute because it offers no POSIX semantics, no file locking, and no partial writes — the application would need rewriting. EBS cannot substitute because a volume attaches to one instance in one AZ. The premium buys the shared, multi-AZ, POSIX-compliant namespace, and EFS Infrequent Access plus Archive tiering (about $0.016 and $0.008/GB-month) reclaims most of the cost for the cold majority of the data.

**A27.** **Amazon FSx for Lustre**, with an **S3 data repository association**. Lustre is a parallel filesystem purpose-built for HPC: it presents the linked S3 bucket's objects as files in a POSIX namespace, lazy-loads object contents on first access, delivers sub-millisecond latency and hundreds of GB/s aggregate throughput scaling with provisioned capacity, and can write results back to S3. EFS is the wrong answer at this scale — its latency and per-client throughput are not designed for a 500-node parallel compute cluster. The exam trigger words are **HPC, machine learning training, genomics, seismic analysis, sub-millisecond, "linked to S3"**.

**A28.** **Amazon FSx for NetApp ONTAP.** It exposes one dataset over **NFS (v3/v4.x), SMB, and iSCSI** simultaneously, with the full ONTAP feature set — snapshots, SnapMirror replication, FlexClone, deduplication, compression, and automatic tiering of cold blocks to capacity storage. It is the standard answer for lift-and-shift of an on-premises NetApp estate and for mixed Linux/Windows environments that must share the same files. No other AWS storage service offers all three protocols over one dataset.

### Exercise 7 — Hybrid and migration

**A29.** **AWS Snowball Edge** (multiple devices in parallel), then a lifecycle rule or direct import that lands the data in S3 Glacier.

The reasoning is the arithmetic. Assuming the full 200 Mbps were available at 80 % efficiency:

```
hours = (400 × 8 × 1e6) / (200 × 0.8 × 3600) = 5,556 h ≈ 231 days
```

Over seven months against a one-month deadline — and that assumes the entire link, which also carries production traffic, so the realistic figure is far worse. Snowball Edge Storage Optimized holds roughly 80 TB usable, so ~5–6 devices ordered in parallel, each with a round trip of about a week, complete the migration inside the deadline while consuming **zero** internet bandwidth. Snowmobile is not an option — it has been discontinued. Data lands in S3, and a lifecycle rule (or the import configuration) moves it to Glacier Flexible Retrieval or Deep Archive per the retrieval SLA.

**A30.** **AWS Storage Gateway in Tape Gateway (VTL) mode.** It presents a **virtual tape library over iSCSI** — virtual tape drives and a media changer — that existing backup software (Veeam, Veritas NetBackup, Commvault, Backup Exec, Dell NetWorker) recognises as physical tape hardware, usually with no application changes. Virtual tapes are stored in S3; ejecting a tape to the virtual shelf archives it to **S3 Glacier Flexible Retrieval or Deep Archive**. This is the canonical "retire the tape library without replacing the backup software" answer.

**A31.**
- **Volume Gateway — Cached:** the **primary dataset lives in S3**; only frequently accessed blocks are cached on local disk. Use when your dataset exceeds local capacity and you want AWS to be the system of record.
- **Volume Gateway — Stored:** the **primary dataset lives on-premises** with local low-latency access to *all* of it; the gateway asynchronously replicates point-in-time copies to AWS as **EBS snapshots** for backup and DR. Use when every byte must be locally fast and AWS is the backup target.

Mnemonic: *Cached = capacity in the cloud. Stored = capacity on the floor.*

**A32.** **AWS Storage Gateway — S3 File Gateway.** It presents an **NFS or SMB** share locally that the branch office writes to unchanged, and stores each file as a **native S3 object** in your bucket, one file to one object, with the directory path becoming the key prefix. Because the objects are native S3 objects (not an opaque backup format), S3 Event Notifications can trigger a Lambda function on `s3:ObjectCreated:*` exactly as if the file had been uploaded via the API. DataSync would also move the data but is a scheduled transfer service, not a continuously mounted share — it does not give the branch a live local NFS mount point.

**A33.** **AWS DataSync**, unambiguously. The bandwidth is ample: 2 TB over 10 Gbps at realistic efficiency is well under an hour, so the physical-shipment reasoning that justifies Snowball never applies. This is also a **recurring nightly** job, and Snow devices are one-time shipments. DataSync provides exactly the requested features: built-in **integrity verification** (checksums on transfer and optional post-transfer verification), **scheduling**, incremental transfer of only changed data, bandwidth throttling, and native support for **EFS as a destination** (Snowball imports to S3). The decision rule: *Snowball is for when bandwidth is the constraint. DataSync is for when it is not.*

### Exercise 8 — AWS Backup

**A34.** AWS Backup orchestrates the service-native mechanisms rather than replacing them, and what it adds is **governance**:

- **One policy across many services** — EBS, EFS, RDS, Aurora, DynamoDB, FSx, Storage Gateway, S3, DocumentDB, Neptune, Redshift, VMware on-prem — instead of a per-service scheduler, a Lambda, or a cron job for each.
- **Tag-based, dynamic resource selection**, so protection follows a tag rather than a hand-maintained resource list.
- **Lifecycle management** — automatic transition of recovery points to cold storage and expiry — as policy, not scripting.
- **Cross-Region and cross-account copy** for DR and for isolating backups from a compromised production account.
- **Vault Lock (WORM)** immutability.
- **Backup Audit Manager** — continuous compliance reporting against controls such as "every volume tagged `prod` has a backup no older than 24 hours".
- A **single restore workflow**, audit trail, and set of CloudWatch/EventBridge notifications.

Concise framing: AWS Backup does not invent the backup; it makes the backup *governed, uniform, and provable*.

**A35.**
1. **AWS Backup Vault Lock in compliance mode.** Once the `changeable-for-days` grace period (minimum 3 days) elapses, the lock is irreversible: recovery points cannot be deleted before their retention expires and retention cannot be shortened — **by anyone**, including the account root user and AWS Support. Even valid admin credentials cannot destroy the backups.
2. **S3 Object Lock in compliance mode** (which requires bucket versioning). Object versions are WORM-protected for their retention period; no principal can delete or overwrite them, and the retention period cannot be shortened.

The shared principle is that both remove the destructive capability from the IAM control plane entirely, so possessing credentials is not sufficient to destroy data. Complements worth naming: **cross-account backup copy** into an isolated account, and **MFA Delete** on S3 (which requires root-user MFA credentials to delete a version). Note that *governance* mode in both services is bypassable by a principal holding a specific permission — it protects against accident, not against a determined attacker with admin rights.

**A36.** AWS Backup enforces **`DeleteAfterDays` ≥ `MoveToColdStorageAfterDays` + 90**. With cold storage at day 30, the minimum legal `DeleteAfterDays` is **120**; 100 is rejected with `InvalidParameterValueException`. The rule exists because cold storage is backed by the Glacier tiers, which carry a **90-day minimum storage duration** — deleting sooner would incur an early-deletion charge for storage you never used. AWS enforces the constraint at plan-creation time rather than surprising you on the bill. It is the same 90-day minimum from Exercise 3, surfacing in a different service.

**A37.** The new RDS instance is **automatically protected** on the next scheduled run of the plan, with no change to the backup configuration. Backup selections are evaluated dynamically at job time against current resource tags, not resolved once into a static list.

This is the design point because backup coverage otherwise degrades exactly the way it always has: someone provisions a resource, forgets to register it with the backup system, and the gap is discovered during a restore. Binding policy to a tag inverts the default — a resource is protected unless someone actively removes the tag — and makes coverage auditable as a single question ("is every production resource tagged?") rather than a per-resource inventory reconciliation. Backup Audit Manager can then enforce that question as a continuous control.

### Exercise 9 — Diagnostics

**A38.** The 860 GB is in storage that `ListObjectsV2` (and therefore `aws s3 ls`) does not enumerate:

1. **Non-current object versions** — every overwrite in a versioned bucket retains the prior bytes.
   `aws s3api list-object-versions --bucket B --query 'length(Versions[?IsLatest==`false`])'`
   For total bytes: `aws s3api list-object-versions --bucket B --query 'sum(Versions[?IsLatest==\`false\`].Size)'`
2. **Incomplete multipart uploads** — parts from failed or abandoned uploads are billed indefinitely and never appear in any object listing.
   `aws s3api list-multipart-uploads --bucket B`, then `aws s3api list-parts --bucket B --key K --upload-id U` for sizes.
3. **Delete markers and the versions they shadow** — objects "deleted" in a versioned bucket.
   `aws s3api list-object-versions --bucket B --query 'length(DeleteMarkers)'`

The account-wide tool for all three at once is **S3 Storage Lens**, whose free default dashboard reports non-current version bytes and incomplete multipart upload bytes per bucket; **S3 Inventory** produces the same data as a scheduled CSV/Parquet manifest for large buckets where the `list-object-versions` API would be too slow. The fixes are the lifecycle rules from Exercise 3: `NoncurrentVersionExpiration`, `AbortIncompleteMultipartUpload`, and `ExpiredObjectDeleteMarker`.

**A39.** **No — that is correct and expected behaviour.** `BurstBalance` is published only for volume types with a credit-based burst model: `gp2`, `st1`, and `sc1`. `gp3` has **no burst mechanism at all**; it delivers its provisioned IOPS and throughput (3,000 IOPS and 125 MiB/s baseline, independently configurable up to 16,000 IOPS and 1,000 MiB/s) continuously and deterministically. The absence of the metric is a positive signal: the volume cannot suffer the credit-exhaustion cliff where a `gp2` volume runs fast for hours and then abruptly drops to its baseline. This predictability, plus roughly 20 % lower per-GB cost, is why `gp3` is the default recommendation over `gp2`.

**A40.** The volume is not the bottleneck, so look **above and beside it**:

1. **Instance-level EBS limits.** Every EC2 instance type has its own EBS bandwidth and IOPS ceiling, independent of the volume's. Check `EBSIOBalance%` and `EBSByteBalance%` in the `AWS/EC2` namespace on Nitro instances — a value trending toward 0 % means the *instance* is throttling. A 16,000-IOPS volume on an instance capped at 6,000 will never exceed 6,000, and `AWS/EBS` volume metrics will show no throttling whatsoever. *Fix:* move to a larger or EBS-optimized instance type.
2. **I/O size, not I/O count.** EBS meters IOPS in 256 KiB units for SSD volumes; a workload issuing 1 MiB requests consumes 4 IOPS per request. Low `VolumeReadOps` with saturated `%util` and high `VolumeReadBytes` means you are hitting the **throughput** ceiling, not the IOPS ceiling. Check `VolumeReadBytes`/`VolumeWriteBytes` against provisioned MiB/s and `--throughput` on a `gp3`.
3. **Latency, not saturation.** Compute average latency as `VolumeTotalReadTime / VolumeReadOps`. High per-operation latency with a short queue points at the workload's access pattern — synchronous single-threaded fsync-heavy I/O, for instance — rather than at device capacity. `iostat -xz`'s `await` versus `svctm`, and `%util` reaching 100 % on a queue depth of 1, tell the same story.
4. **Not storage at all.** `%util` of 100 % on NVMe is a well-known unreliable signal (it measures time-with-at-least-one-request-outstanding, which saturates on parallel devices long before capacity does). Confirm with `iostat` queue depth and application-level latency before concluding it is the disk. CPU steal, memory pressure driving swap, or network latency to a dependency all present as "the database is slow".

**A41.** The order is:

1. **Block Public Access** — account level, then bucket level. Account-level settings override and cannot be relaxed per bucket.
2. **Bucket policy** — an explicit `Deny` here (like the `aws:SecureTransport` condition in Exercise 2) ends the evaluation immediately.
3. **IAM identity policy** on the calling principal (plus any **SCP** from AWS Organizations, and any **permissions boundary** or **session policy**).
4. **Object ownership / ACLs** — only relevant if `ObjectOwnership` is not `BucketOwnerEnforced`; when it is, ACLs are disabled and this layer does not exist.

Then, only after access is granted: **KMS key policy** if the object is encrypted with SSE-KMS (a common cause of `AccessDenied` on `GetObject` where every S3 policy is correct but the caller lacks `kms:Decrypt`), and **VPC endpoint policy** if the request traverses a gateway or interface endpoint.

The rule that makes the order matter is IAM's evaluation logic: **an explicit `Deny` in any policy overrides every `Allow`, and access requires an explicit `Allow` with no matching `Deny`.** Checking from the outermost, broadest deny inward finds the cause fastest — and it explains why adding permissions frequently fails to fix a 403: the problem is a `Deny` somewhere, not a missing `Allow`. The systematic tool for this is the **IAM Policy Simulator** or `aws iam simulate-principal-policy`, which evaluates the whole chain and names the deciding statement.

### Exercise 10 — Cleanup

**A42.** `aws s3 rb --force` runs `aws s3 rm --recursive` under the hood, which uses `ListObjectsV2` and `DeleteObject` **without version IDs**. In a versioned bucket, a versionless `DeleteObject` does not remove anything — it adds a **delete marker**. So the command dutifully "deletes" every current object, creates a delete marker for each, removes nothing, and then fails to delete the bucket because S3 refuses to delete a bucket that still contains versions (`BucketNotEmpty`).

What this reveals: **S3 accounts for storage at the version level, not the key level.** A key is merely an index into a stack of versions; `List`/`Get`/`Delete` without a version ID operate on the top of that stack, while billing operates on the whole stack. Emptying a versioned bucket requires enumerating with `list-object-versions` and deleting each `(Key, VersionId)` pair explicitly, including the delete markers — which is exactly what the cleanup script does. The same asymmetry is the root cause of A7, A15, and A38.

**A43.** A **mount target is an elastic network interface (ENI) with a private IP address inside one of your subnets** — it is a resource in *your* VPC, not merely a property of the file system. Deleting the file system while an ENI exists would orphan a network interface holding an IP in your subnet and, potentially, a live NFS session, so EFS enforces the dependency ordering: mount targets first, file system second.

The architectural point behind the error message: the file system itself is a Regional, multi-AZ construct, but **access to it is always zonal**, mediated by a per-AZ ENI subject to your VPC's security groups, route tables, and NACLs. That is why NFS traffic to EFS is controlled with security groups on port 2049 like any other VPC traffic, why a missing mount target in an AZ makes the file system unreachable from that AZ (A25), and why EFS access never leaves your VPC.

</details>

---

## Official sources

- AWS Certified Cloud Practitioner (CLF-C02) Exam Guide — <https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf>
- Amazon S3 — Using Amazon S3 storage classes — <https://docs.aws.amazon.com/AmazonS3/latest/userguide/storage-class-intro.html>
- Amazon S3 — Managing the lifecycle of objects — <https://docs.aws.amazon.com/AmazonS3/latest/userguide/object-lifecycle-mgmt.html>
- Amazon S3 — Lifecycle transition general considerations — <https://docs.aws.amazon.com/AmazonS3/latest/userguide/lifecycle-transition-general-considerations.html>
- Amazon S3 — Blocking public access to your Amazon S3 storage — <https://docs.aws.amazon.com/AmazonS3/latest/userguide/access-control-block-public-access.html>
- Amazon S3 — Using S3 Object Lock — <https://docs.aws.amazon.com/AmazonS3/latest/userguide/object-lock.html>
- Amazon S3 — Assessing storage activity with S3 Storage Lens — <https://docs.aws.amazon.com/AmazonS3/latest/userguide/storage_lens.html>
- Amazon EBS — Amazon EBS volume types — <https://docs.aws.amazon.com/ebs/latest/userguide/ebs-volume-types.html>
- Amazon EBS — Amazon EBS snapshots — <https://docs.aws.amazon.com/ebs/latest/userguide/ebs-snapshots.html>
- Amazon EBS — Attach a volume to multiple instances with Multi-Attach — <https://docs.aws.amazon.com/ebs/latest/userguide/ebs-volumes-multi.html>
- Amazon EC2 — Instance store temporary block storage — <https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/InstanceStorage.html>
- Amazon EFS — Amazon EFS performance — <https://docs.aws.amazon.com/efs/latest/ug/performance.html>
- Amazon EFS — Managing storage with lifecycle policies — <https://docs.aws.amazon.com/efs/latest/ug/lifecycle-management-efs.html>
- Amazon FSx — What is Amazon FSx? — <https://docs.aws.amazon.com/fsx/>
- AWS Storage Gateway — What is AWS Storage Gateway? — <https://docs.aws.amazon.com/storagegateway/latest/userguide/WhatIsStorageGateway.html>
- AWS Snow Family — What is the AWS Snow Family? — <https://docs.aws.amazon.com/snowball/latest/developer-guide/whatissnowball.html>
- AWS DataSync — What is AWS DataSync? — <https://docs.aws.amazon.com/datasync/latest/userguide/what-is-datasync.html>
- AWS Backup — What is AWS Backup? — <https://docs.aws.amazon.com/aws-backup/latest/devguide/whatisbackup.html>
- AWS Backup — AWS Backup Vault Lock — <https://docs.aws.amazon.com/aws-backup/latest/devguide/vault-lock.html>
- Amazon CloudWatch — Amazon EBS CloudWatch metrics — <https://docs.aws.amazon.com/ebs/latest/userguide/using_cloudwatch_ebs.html>
- Amazon S3 pricing — <https://aws.amazon.com/s3/pricing/>
- Amazon EBS pricing — <https://aws.amazon.com/ebs/pricing/>