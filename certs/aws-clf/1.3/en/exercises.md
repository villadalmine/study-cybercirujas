# Topic 1.3 — Guided Exercises: Benefits of and Strategies for Migration to the AWS Cloud

**Certification:** AWS Certified Cloud Practitioner (CLF-C02) · Domain 1, Task Statement 1.3 · Exam weight 6.0

---

## Before You Start

### Prerequisites

| Requirement | Check command | Expected |
|---|---|---|
| AWS CLI v2 | `aws --version` | `aws-cli/2.x.x Python/3.x ...` |
| Credentials | `aws sts get-caller-identity` | JSON with `Account`, `Arn` |
| `jq` | `jq --version` | `jq-1.6` or later |
| Python 3 | `python3 --version` | `Python 3.9+` |

```bash
aws --version
aws sts get-caller-identity
```

Expected output:

```json
{
    "UserId": "AIDAEXAMPLEUSERID",
    "Account": "123456789012",
    "Arn": "arn:aws:iam::123456789012:user/migration-architect"
}
```

### Cost guardrail — read this

These exercises are structured so the **default path is free**. Anything that provisions billable
infrastructure is marked **`[BILLABLE]`** and is optional. Two techniques keep you safe:

```bash
# 1. Generate the request body without sending it — costs nothing, validates your parameter shape
aws snowball create-job --generate-cli-skeleton input > /tmp/skeleton.json

# 2. Ask the API to validate without executing, where the operation supports it
aws migrationhub notify-application-state \
    --application-id d-application-0a1b2c3d4e5f6g7h8 \
    --status IN_PROGRESS \
    --dry-run
```

> **Never run `aws snowball create-job` for real practice.** It is not a sandbox operation — it
> creates a physical fulfilment order and AWS ships a device to the address you registered.

### Working directory

```bash
mkdir -p ~/labs/clf-1.3/{inventory,dms,datasync,caf}
cd ~/labs/clf-1.3
export AWS_REGION=us-east-1
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "Region: $AWS_REGION  Account: $ACCOUNT_ID"
```

---

## Exercise 1 — Establish the Migration Hub Home Region and Import an Inventory

AWS Migration Hub is the single pane of glass for a migration programme. Before any discovery data
can be stored, you must pin a **home region** — a one-time, per-account decision that determines
where discovery and tracking data lives.

### Steps

**1.** Check whether a home region already exists:

```bash
aws migrationhub-config describe-home-region-controls --region us-west-2
```

Expected output when none is set:

```json
{
    "HomeRegionControls": []
}
```

**2.** Set the home region. Note that the control-plane call itself is made against `us-west-2`
regardless of which home region you choose:

```bash
aws migrationhub-config create-home-region-control \
    --home-region us-east-1 \
    --target Type=ACCOUNT,Id=${ACCOUNT_ID} \
    --region us-west-2
```

Expected output:

```json
{
    "HomeRegionControl": {
        "ControlId": "hrc-a1b2c3d4e5f6g7h8",
        "HomeRegion": "us-east-1",
        "Target": {
            "Type": "ACCOUNT",
            "Id": "123456789012"
        },
        "RequestedTime": "2026-09-03T10:14:22.318000-03:00"
    }
}
```

**3.** Build an agentless inventory file. In a real engagement this CSV comes from an existing CMDB,
RVTools export, or the AWS Application Discovery Agentless Collector. Create
`inventory/wave-0.csv`:

```csv
ExternalId,HostName,IPAddress,OS.Name,OS.Version,CPU.NumberOfCores,RAM.TotalSizeInMB,DISK.NumberOfDisks,ApplicationName
srv-001,web-prod-01,10.20.1.11,Ubuntu,20.04,4,16384,2,storefront
srv-002,web-prod-02,10.20.1.12,Ubuntu,20.04,4,16384,2,storefront
srv-003,ora-prod-01,10.20.2.20,Oracle Linux,7.9,16,131072,6,billing
srv-004,sql-prod-01,10.20.2.30,Microsoft Windows Server,2012 R2,8,65536,4,crm
srv-005,jump-01,10.20.9.5,CentOS,6.10,2,4096,1,legacy-tools
srv-006,fileshare-01,10.20.3.15,Microsoft Windows Server,2019,4,32768,3,shared-storage
```

**4.** Upload it and generate a presigned URL that the import task can read:

```bash
BUCKET="acme-migration-inventory-${ACCOUNT_ID}"
aws s3 mb "s3://${BUCKET}" --region ${AWS_REGION}
aws s3 cp inventory/wave-0.csv "s3://${BUCKET}/wave-0.csv"

IMPORT_URL=$(aws s3 presign "s3://${BUCKET}/wave-0.csv" --expires-in 3600)
echo "$IMPORT_URL"
```

**5.** Start the import task and poll it:

```bash
aws discovery start-import-task \
    --name "wave-0-inventory" \
    --import-url "$IMPORT_URL" \
    --region ${AWS_REGION}
```

Expected output:

```json
{
    "task": {
        "importTaskId": "import-task-0f1e2d3c4b5a69788",
        "clientRequestToken": "b9e6f4d1-3c27-4b5e-9a01-7d8c2e5f4a6b",
        "name": "wave-0-inventory",
        "importUrl": "https://acme-migration-inventory-123456789012.s3.amazonaws.com/wave-0.csv?...",
        "status": "IMPORT_IN_PROGRESS",
        "importRequestTime": "2026-09-03T10:22:05.441000-03:00",
        "importedRecordCount": 0,
        "importFailedRecordCount": 0
    }
}
```

```bash
aws discovery describe-import-tasks --region ${AWS_REGION} \
    --query 'tasks[0].{Status:status,OK:importedRecordCount,Failed:importFailedRecordCount}'
```

Expected output after a minute or two:

```json
{
    "Status": "IMPORT_COMPLETE",
    "OK": 6,
    "Failed": 0
}
```

**6.** Query the discovered configuration items:

```bash
aws discovery list-configurations \
    --configuration-type SERVER \
    --region ${AWS_REGION} \
    --query 'configurations[].{Host:"server.hostName",OS:"server.osName",Cores:"server.cpuType"}' \
    --output table
```

**7.** Filter for the end-of-life estate — the servers most likely to become **retire** or
**replatform** candidates:

```bash
aws discovery list-configurations \
    --configuration-type SERVER \
    --region ${AWS_REGION} \
    --filters '[{"name":"server.osName","values":["CentOS","Windows Server 2012"],"condition":"CONTAINS"}]' \
    --query 'configurations[]."server.hostName"'
```

Expected output:

```json
[
    "jump-01",
    "sql-prod-01"
]
```

> Source: [Application Discovery Service — import file
> template](https://docs.aws.amazon.com/application-discovery/latest/userguide/discovery-import.html) ·
> [Migration Hub home
> region](https://docs.aws.amazon.com/migrationhub/latest/ug/home-region.html)

### Comprehension check

**Q1.** The home region control-plane call in step 2 was sent to `us-west-2`, but the home region
selected was `us-east-1`. What does the home region actually govern, and why does the exam guide
treat *discovery* as a distinct phase from *migration*?

**Q2.** You set the home region to `us-east-1` for account `123456789012`, then a colleague argues
the workloads should really land in `eu-west-1` and asks you to change it. What is the operational
constraint, and does it prevent migrating servers into `eu-west-1`?

**Q3.** Step 3 imported data from a CSV rather than installing an agent on each server. Name one
concrete piece of decision-making data the CSV import cannot give you that an installed discovery
agent can, and explain which of the 7 Rs is hardest to choose without it.

**Q4.** `jump-01` runs CentOS 6.10 and `sql-prod-01` runs Windows Server 2012 R2. Both are past
vendor end-of-support. Which CLF-C02 migration benefit category does retiring or replatforming
these two servers most directly serve?

---

## Exercise 2 — Apply the 7 Rs to the Discovered Estate

The exam guide expects you to identify migration strategies. The industry-standard set is the
**7 Rs**: rehost, replatform, repurchase, refactor/re-architect, relocate, retain, retire.

### Steps

**1.** Write the decision table. Create `inventory/seven-rs.md`:

```markdown
| R | Also called | What changes | Typical AWS tooling | Effort | Cloud-native benefit |
|---|---|---|---|---|---|
| Rehost | Lift and shift | Nothing above the hypervisor | AWS Application Migration Service (MGN) | Lowest | Lowest |
| Relocate | Hypervisor-level lift | Nothing; the VM moves as-is | VMware Cloud on AWS / VMware Cloud Foundation on AWS | Very low | Very low |
| Replatform | Lift, tinker and shift | Managed service swap, no code rewrite | RDS, Amazon MQ, Amazon EKS, Elastic Beanstalk | Low–medium | Medium |
| Repurchase | Drop and shop | Licence model — buy SaaS instead | AWS Marketplace, third-party SaaS | Medium | Varies |
| Refactor | Re-architect | Application code and architecture | Lambda, DynamoDB, ECS/EKS, EventBridge | Highest | Highest |
| Retain | Revisit | Nothing; stays on premises | Direct Connect / hybrid networking | None | None |
| Retire | Decommission | Turned off | — | None | Immediate cost reduction |
```

**2.** Score the estate with a deterministic script. Create `inventory/classify.py`:

```python
#!/usr/bin/env python3
"""Assign a candidate R to each discovered server. Advisory only: the output is
an input to a human wave-planning workshop, never a final decision."""
import csv
import sys

EOL_OS = ("CentOS", "2012")

def classify(row):
    os_name = f'{row["OS.Name"]} {row["OS.Version"]}'
    app = row["ApplicationName"]

    if app == "legacy-tools":
        return "retire", "No business owner; superseded by SSM Session Manager"
    if "Oracle" in os_name and app == "billing":
        return "replatform", "Database tier is a candidate for RDS or Aurora"
    if any(marker in os_name for marker in EOL_OS):
        return "replatform", "OS past vendor end-of-support; do not rehost the debt"
    if app == "shared-storage":
        return "replatform", "File share maps to Amazon FSx or EFS"
    return "rehost", "Stateless tier; lowest-risk path, refactor after landing"

def main(path):
    with open(path, newline="") as handle:
        rows = list(csv.DictReader(handle))
    print(f'{"Host":<16}{"App":<18}{"Strategy":<14}Rationale')
    print("-" * 92)
    for row in rows:
        strategy, why = classify(row)
        print(f'{row["HostName"]:<16}{row["ApplicationName"]:<18}{strategy:<14}{why}')

if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "inventory/wave-0.csv")
```

**3.** Run it:

```bash
python3 inventory/classify.py inventory/wave-0.csv
```

Expected output:

```
Host            App               Strategy      Rationale
--------------------------------------------------------------------------------------------
web-prod-01     storefront        rehost        Stateless tier; lowest-risk path, refactor after landing
web-prod-02     storefront        rehost        Stateless tier; lowest-risk path, refactor after landing
ora-prod-01     billing           replatform    Database tier is a candidate for RDS or Aurora
sql-prod-01     crm               replatform    OS past vendor end-of-support; do not rehost the debt
jump-01         legacy-tools      retire        No business owner; superseded by SSM Session Manager
fileshare-01    shared-storage    replatform    File share maps to Amazon FSx or EFS
```

**4.** Group the servers into a Migration Hub application so progress can be tracked per business
capability rather than per server:

```bash
aws discovery create-application \
    --name "storefront" \
    --description "Public e-commerce front end - wave 1" \
    --region ${AWS_REGION}
```

Expected output:

```json
{
    "configurationId": "d-application-0a1b2c3d4e5f6g7h8"
}
```

**5.** Record the wave decision as tags on the configuration items so the classification survives
outside the spreadsheet:

```bash
aws discovery create-tags \
    --configuration-ids d-server-01j5k7m9n0p2q4r6 \
    --tags key=migration-strategy,value=rehost key=migration-wave,value=1 \
    --region ${AWS_REGION}
```

> Source: [AWS Prescriptive Guidance — migration
> strategies](https://docs.aws.amazon.com/prescriptive-guidance/latest/large-migration-guide/migration-strategies.html) ·
> [AWS Cloud migration](https://aws.amazon.com/cloud-migration/)

### Comprehension check

**Q5.** `sql-prod-01` was classified `replatform` because Windows Server 2012 R2 is out of support.
Argue the opposing case: under what circumstances is **rehost** the correct call for that same
server, and what does that choice cost you later?

**Q6.** A stakeholder says "we will refactor everything to serverless — it is the highest-value R."
Give the two strongest technical objections to refactor-first for a 500-server estate with a
datacentre lease expiring in nine months.

**Q7.** The script never emits `repurchase` or `relocate`. What kind of inventory signal would you
need to add to detect a `repurchase` candidate, and what infrastructure fact would make `relocate`
the natural choice?

**Q8.** `retire` produces no AWS revenue and requires no engineering. Why is it typically the
highest return-on-effort strategy in the portfolio, and what does discovery data have to prove
before you can act on it?

---

## Exercise 3 — Choose Between Online and Offline Data Transfer

This is the single most commonly examined quantitative judgement in Topic 1.3: given a data volume
and a network link, do you send it over the wire or ship a device?

### Steps

**1.** Build the calculator. Create `inventory/transfer.py`:

```python
#!/usr/bin/env python3
"""Wire-time estimator for bulk data migration.

Reports elapsed transfer time and whether the working set converges: if the
dataset grows faster than the link drains it, no amount of waiting finishes
the job.
"""

SECONDS_PER_DAY = 86_400
BITS_PER_BYTE = 8
BYTES_PER_TB = 10**12


def transfer_days(terabytes, link_gbps, utilisation=0.7):
    """Elapsed days to move `terabytes` over `link_gbps` at `utilisation`."""
    bits = terabytes * BYTES_PER_TB * BITS_PER_BYTE
    effective_bps = link_gbps * 10**9 * utilisation
    return bits / effective_bps / SECONDS_PER_DAY


def converges(terabytes, link_gbps, daily_change_pct, utilisation=0.7):
    """True if the link drains data faster than the source generates it."""
    days = transfer_days(terabytes, link_gbps, utilisation)
    drained_per_day = terabytes / days
    generated_per_day = terabytes * (daily_change_pct / 100)
    return generated_per_day < drained_per_day


SCENARIOS = [
    ("Archive tier",   300, 1.0,  2.0),
    ("Analytics lake",  20, 10.0, 5.0),
    ("VM images",      120, 0.5,  0.5),
]

print(f'{"Scenario":<18}{"TB":>6}{"Gbps":>7}{"Days":>9}{"Converges":>12}  Recommendation')
print("-" * 86)
for name, tb, gbps, change in SCENARIOS:
    days = transfer_days(tb, gbps)
    ok = converges(tb, gbps, change)
    if not ok:
        rec = "OFFLINE - dataset outruns the link"
    elif days > 7:
        rec = "OFFLINE - Snow Family, then DataSync delta"
    else:
        rec = "ONLINE - DataSync over the existing link"
    print(f'{name:<18}{tb:>6}{gbps:>7.1f}{days:>9.1f}{str(ok):>12}  {rec}')
```

**2.** Run it:

```bash
python3 inventory/transfer.py
```

Expected output:

```
Scenario              TB   Gbps     Days   Converges  Recommendation
--------------------------------------------------------------------------------------
Archive tier         300    1.0     39.7       False  OFFLINE - dataset outruns the link
Analytics lake        20   10.0      0.3        True  ONLINE - DataSync over the existing link
VM images            120    0.5     31.8        True  OFFLINE - Snow Family, then DataSync delta
```

**3.** Size the offline shipment for the 300 TB archive. Snowball Edge Storage Optimized presents
80 TB of usable capacity:

```bash
python3 -c "
import math
data_tb, usable_tb = 300, 80
print(f'Devices required: {math.ceil(data_tb / usable_tb)}')
print(f'Headroom on last device: {math.ceil(data_tb/usable_tb)*usable_tb - data_tb} TB')
"
```

Expected output:

```
Devices required: 4
Headroom on last device: 20 TB
```

**4.** Model the job request without submitting it:

```bash
aws snowball create-job --generate-cli-skeleton input | jq 'keys'
```

Expected output:

```json
[
  "AddressId",
  "Description",
  "DeviceConfiguration",
  "ForwardingAddressId",
  "ImpactLevel",
  "JobType",
  "KmsKeyARN",
  "LongTermPricingId",
  "Notification",
  "OnDeviceServiceConfiguration",
  "PickupDetails",
  "RemoteManagement",
  "Resources",
  "RoleARN",
  "ShippingOption",
  "SnowballCapacityPreference",
  "SnowballType",
  "TaxDocuments"
]
```

**5.** Fill in the skeleton to see the shape of a production import job. Create `inventory/job.json`:

```json
{
  "JobType": "IMPORT",
  "Description": "Wave 0 archive tier - 300TB cold storage import",
  "AddressId": "ADID1234ab12-3eec-4eb3-9be6-9374c10eb51b",
  "KmsKeyARN": "arn:aws:kms:us-east-1:123456789012:key/1234abcd-12ab-34cd-56ef-1234567890ab",
  "RoleARN": "arn:aws:iam::123456789012:role/SnowballImportRole",
  "SnowballType": "EDGE_S",
  "SnowballCapacityPreference": "T80",
  "ShippingOption": "SECOND_DAY",
  "Resources": {
    "S3Resources": [
      {
        "BucketArn": "arn:aws:s3:::acme-archive-migration",
        "KeyRange": {
          "BeginMarker": "archive/2019/",
          "EndMarker": "archive/2022/"
        }
      }
    ]
  },
  "Notification": {
    "SnsTopicARN": "arn:aws:sns:us-east-1:123456789012:migration-alerts",
    "JobStatesToNotify": ["InTransitToCustomer", "WithCustomer", "InTransitToAWS", "Complete"],
    "NotifyAll": false
  }
}
```

**6.** Validate the document locally without calling the API:

```bash
jq empty inventory/job.json && echo "JSON is well-formed"
jq -r '.Resources.S3Resources[0].BucketArn' inventory/job.json
```

Expected output:

```
JSON is well-formed
arn:aws:s3:::acme-archive-migration
```

**7. `[BILLABLE, DO NOT RUN IN PRACTICE]`** For reference only, the operations that submit and track
a real job:

```bash
# Register the ship-to address
aws snowball create-address --address \
    "Name=Acme DC Ops,Company=Acme Corp,Street1=1 Industrial Way,City=Newark,\
StateOrProvince=NJ,Country=US,PostalCode=07102,PhoneNumber=+15550100"

# Submit the job from the document above
aws snowball create-job --cli-input-json file://inventory/job.json

# Track it through the physical lifecycle
aws snowball describe-job --job-id JID123e4567-e89b-12d3-a456-426655440000 \
    --query 'JobMetadata.{State:JobState,Type:SnowballType,Shipping:ShippingDetails.ShippingOption}'
```

Expected `describe-job` output while the device is on site:

```json
{
    "State": "WithCustomer",
    "Type": "EDGE_S",
    "Shipping": "SECOND_DAY"
}
```

**8.** Understand the on-device workflow. Once the device arrives it is unlocked with a manifest and
an unlock code fetched separately — a deliberate two-factor split, so possessing the hardware alone
grants nothing:

```bash
aws snowball get-job-manifest --job-id JID123e4567-e89b-12d3-a456-426655440000
aws snowball get-job-unlock-code --job-id JID123e4567-e89b-12d3-a456-426655440000

snowballEdge unlock-device --endpoint https://192.0.2.10 \
    --manifest-file /secure/JID123e4567.manifest.bin \
    --unlock-code 12345-abcde-01234-ABCDE-01234

aws s3 cp /mnt/archive/ s3://acme-archive-migration/ \
    --recursive --endpoint http://192.0.2.10:8080
```

> Source: [AWS Snowball Edge developer
> guide](https://docs.aws.amazon.com/snowball/latest/developer-guide/whatisedge.html) ·
> [AWS DataSync](https://docs.aws.amazon.com/datasync/latest/userguide/what-is-datasync.html)
>
> The Snow Family device line-up changes over time — AWS retired Snowmobile in 2024. Always confirm
> currently orderable devices and capacities at
> <https://aws.amazon.com/snow/> before committing a plan.

### Comprehension check

**Q9.** The archive-tier scenario reported `Converges: False`. Explain in one sentence what that
means physically, and why it makes the "how many days" number irrelevant.

**Q10.** The VM-images scenario converges but still takes 31.8 days. AWS's rule of thumb is to go
offline when a network transfer would exceed roughly one week. What are the two hidden costs of the
31-day online transfer that the elapsed-time figure alone conceals?

**Q11.** Step 8 fetched the manifest and the unlock code with two separate API calls. Why is this
split, and what attack does it defeat that whole-disk encryption alone does not?

**Q12.** After four Snowball devices are ingested into S3, the source filesystem has been live for
three more weeks. What service and what mode do you use to reconcile, and why is a second Snowball
round the wrong answer?

**Q13.** A colleague proposes AWS Storage Gateway instead of Snowball for the 300 TB archive. Under
what access pattern is that actually the better answer, and what does it change about the migration
end state?

---

## Exercise 4 — Rehost with AWS Application Migration Service (MGN)

MGN is the AWS-recommended primary service for lift-and-shift. It performs continuous, block-level
replication from a source server into a low-cost staging area in your VPC, so cutover is a launch
from an already-synchronised volume rather than a copy.

### Steps

**1.** Initialise the service in the target region. This is idempotent and creates the required IAM
service-linked roles and replication template:

```bash
aws mgn initialize-service --region ${AWS_REGION}
```

Expected output:

```json
{}
```

**2.** Inspect the default replication configuration template — this is what every newly-registered
source server inherits:

```bash
aws mgn describe-replication-configuration-templates --region ${AWS_REGION} \
    --query 'items[0].{Template:replicationConfigurationTemplateID,Subnet:stagingAreaSubnetId,Instance:replicationServerInstanceType,Routing:dataPlaneRouting,Encryption:ebsEncryption}'
```

Expected output:

```json
{
    "Template": "rct-01234567890abcdef",
    "Subnet": "subnet-0a1b2c3d4e5f67890",
    "Instance": "t3.small",
    "Routing": "PRIVATE_IP",
    "Encryption": "DEFAULT"
}
```

**3.** Harden the template before any agent connects. Replication traffic should traverse private
paths, disks should be encrypted, and bandwidth should be throttled so replication does not starve
production traffic on a shared WAN link:

```bash
aws mgn update-replication-configuration-template \
    --replication-configuration-template-id rct-01234567890abcdef \
    --staging-area-subnet-id subnet-0a1b2c3d4e5f67890 \
    --replication-server-instance-type t3.small \
    --use-dedicated-replication-server \
    --default-large-staging-disk-type GP3 \
    --ebs-encryption DEFAULT \
    --data-plane-routing PRIVATE_IP \
    --no-create-public-ip \
    --bandwidth-throttling 500 \
    --associate-default-security-group \
    --staging-area-tags Project=wave-1,CostCentre=migration \
    --region ${AWS_REGION}
```

**4.** Understand the source-side agent installation. On each Linux source server:

```bash
wget -O ./aws-replication-installer-init.py \
    https://aws-application-migration-service-us-east-1.s3.us-east-1.amazonaws.com/latest/linux/aws-replication-installer-init.py

sudo python3 ./aws-replication-installer-init.py \
    --region us-east-1 \
    --no-prompt
```

Expected output (abridged):

```
The installation of the AWS Replication Agent has started.
Identifying volumes for replication.
Identified volume for replication: /dev/nvme0n1 of size 100 GiB
All volumes for replication were successfully identified.
Downloading the AWS Replication Agent onto the source server... Finished.
Installing the AWS Replication Agent onto the source server... Finished.
Syncing the source server with the AWS Application Migration Service Console... Finished.
The AWS Replication Agent was successfully installed.
```

**5.** Watch replication converge:

```bash
aws mgn describe-source-servers --filters isArchived=false --region ${AWS_REGION} \
    --query 'items[].{Server:sourceProperties.identificationHints.hostname,
                      ID:sourceServerID,
                      Replication:dataReplicationInfo.dataReplicationState,
                      Lag:dataReplicationInfo.lagDuration,
                      Lifecycle:lifeCycle.state}' \
    --output table
```

Expected output during initial sync:

```
--------------------------------------------------------------------------------------
|                              DescribeSourceServers                                 |
+-------------+----------------------+---------------+---------+--------------------+
|     ID      |        Server        |  Replication  |   Lag   |     Lifecycle      |
+-------------+----------------------+---------------+---------+--------------------+
|  s-1122...  |  web-prod-01         |  INITIAL_SYNC |  PT4H12M|  NOT_READY         |
|  s-3344...  |  web-prod-02         |  INITIAL_SYNC |  PT3H55M|  NOT_READY         |
+-------------+----------------------+---------------+---------+--------------------+
```

And once healthy:

```
+-------------+----------------------+---------------+---------+--------------------+
|  s-1122...  |  web-prod-01         |  CONTINUOUS   |  PT0S   |  READY_FOR_TEST    |
|  s-3344...  |  web-prod-02         |  CONTINUOUS   |  PT0S   |  READY_FOR_TEST    |
+-------------+----------------------+---------------+---------+--------------------+
```

**6.** Set the launch configuration — how the target EC2 instance is built at cutover:

```bash
aws mgn update-launch-configuration \
    --source-server-id s-1122334455667788 \
    --launch-disposition STARTED \
    --target-instance-type-right-sizing-method BASIC \
    --copy-private-ip \
    --copy-tags \
    --boot-mode LEGACY_BIOS \
    --region ${AWS_REGION}
```

Expected output (abridged):

```json
{
    "sourceServerID": "s-1122334455667788",
    "name": "web-prod-01",
    "ec2LaunchTemplateID": "lt-0abc123def4567890",
    "launchDisposition": "STARTED",
    "targetInstanceTypeRightSizingMethod": "BASIC",
    "copyPrivateIp": true,
    "copyTags": true,
    "bootMode": "LEGACY_BIOS"
}
```

**7. `[BILLABLE]`** Launch a **test** instance. This is the rehearsal — it does not touch the
source server, and replication continues throughout:

```bash
aws mgn start-test --source-server-ids s-1122334455667788 --region ${AWS_REGION}
```

Expected output (abridged):

```json
{
    "job": {
        "jobID": "mgnjob-0a1b2c3d4e5f6g7h8",
        "type": "LAUNCH",
        "initiatedBy": "START_TEST",
        "status": "PENDING",
        "creationDateTime": "2026-09-03T14:02:11Z",
        "participatingServers": [
            {
                "sourceServerID": "s-1122334455667788",
                "launchStatus": "PENDING"
            }
        ]
    }
}
```

**8.** Follow the job log:

```bash
aws mgn describe-job-log-items --job-id mgnjob-0a1b2c3d4e5f6g7h8 --region ${AWS_REGION} \
    --query 'items[].{Time:logDateTime,Event:event}' --output table
```

Expected output:

```
------------------------------------------------------------
|                   DescribeJobLogItems                    |
+--------------------------+-------------------------------+
|           Time           |             Event             |
+--------------------------+-------------------------------+
|  2026-09-03T14:02:11Z    |  JOB_START                    |
|  2026-09-03T14:02:34Z    |  SNAPSHOT_START               |
|  2026-09-03T14:06:50Z    |  SNAPSHOT_END                 |
|  2026-09-03T14:07:02Z    |  USING_PREVIOUS_SNAPSHOT      |
|  2026-09-03T14:09:41Z    |  LAUNCH_START                 |
|  2026-09-03T14:12:18Z    |  JOB_END                      |
+--------------------------+-------------------------------+
```

**9. `[BILLABLE]`** After validating the test instance, mark the test complete, then cut over and
finalise. `finalize-cutover` is the irreversible step: it terminates the replication resources and
stops billing for the staging area.

```bash
aws mgn start-cutover --source-server-ids s-1122334455667788 --region ${AWS_REGION}
aws mgn finalize-cutover --source-server-id s-1122334455667788 --region ${AWS_REGION}
```

**10. Teardown.** If you launched anything billable, disconnect the source servers to stop
replication charges:

```bash
aws mgn disconnect-from-service --source-server-id s-1122334455667788 --region ${AWS_REGION}
aws mgn delete-source-server --source-server-id s-1122334455667788 --region ${AWS_REGION}
aws ec2 describe-instances --region ${AWS_REGION} \
    --filters "Name=tag:AWSApplicationMigrationServiceManaged,Values=*" \
    --query 'Reservations[].Instances[].{Id:InstanceId,State:State.Name}' --output table
```

> Source: [AWS Application Migration Service user
> guide](https://docs.aws.amazon.com/mgn/latest/ug/what-is-application-migration-service.html) ·
> [`aws mgn` CLI reference](https://docs.aws.amazon.com/cli/latest/reference/mgn/)

### Comprehension check

**Q14.** MGN replicates continuously into a staging area rather than taking a one-off image. State
the two business metrics this design targets, and which one it improves by orders of magnitude
versus a snapshot-and-copy approach.

**Q15.** Step 7 launched a **test** instance while replication kept running. Why is the ability to
test repeatedly, without disturbing the source, the argument that most directly supports the exam
guide's "reduced business risk" migration benefit?

**Q16.** `--target-instance-type-right-sizing-method BASIC` was set. What does right-sizing do at
launch, and why is it a *migration benefit* rather than merely a configuration convenience?

**Q17.** `finalize-cutover` is described as irreversible. What exactly does it destroy, and what is
the operational consequence of running it before the application team has signed off?

**Q18.** A team rehosts 200 servers with MGN and reports the migration a success — but monthly spend
matches the old datacentre almost exactly. Explain why this is the expected outcome of a pure
rehost, and name the phase where the savings are actually realised.

---

## Exercise 5 — Replatform a Database with AWS DMS

`ora-prod-01` was classified **replatform**: the billing schema moves from self-managed Oracle to
Amazon RDS/Aurora PostgreSQL. That is a *heterogeneous* migration — schema conversion plus data
movement.

### Steps

**1.** Understand the division of labour:

| Concern | Tool | What it produces |
|---|---|---|
| Schema, stored procedures, types | AWS Schema Conversion Tool (SCT) / DMS Schema Conversion | Converted DDL + an assessment report of what could not be converted |
| Rows, plus ongoing changes | AWS DMS | Full load and change data capture (CDC) |
| Correctness after the fact | DMS data validation | Row-level comparison of source and target |

**2. `[BILLABLE]`** Create a private replication instance. Note `--no-publicly-accessible`: the
replication instance sits in your VPC and reaches the source over Direct Connect or VPN.

```bash
aws dms create-replication-subnet-group \
    --replication-subnet-group-identifier dms-private-subnets \
    --replication-subnet-group-description "Private subnets for wave-1 DMS" \
    --subnet-ids subnet-0a1b2c3d4e5f67890 subnet-0f9e8d7c6b5a43210 \
    --region ${AWS_REGION}

aws dms create-replication-instance \
    --replication-instance-identifier dms-wave1 \
    --replication-instance-class dms.c5.large \
    --allocated-storage 100 \
    --engine-version 3.5.2 \
    --no-publicly-accessible \
    --multi-az \
    --replication-subnet-group-identifier dms-private-subnets \
    --vpc-security-group-ids sg-0123456789abcdef0 \
    --tags Key=migration-wave,Value=1 \
    --region ${AWS_REGION}
```

Expected output (abridged):

```json
{
    "ReplicationInstance": {
        "ReplicationInstanceIdentifier": "dms-wave1",
        "ReplicationInstanceClass": "dms.c5.large",
        "ReplicationInstanceStatus": "creating",
        "AllocatedStorage": 100,
        "MultiAZ": true,
        "EngineVersion": "3.5.2",
        "PubliclyAccessible": false,
        "ReplicationInstanceArn": "arn:aws:dms:us-east-1:123456789012:rep:ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    }
}
```

**3.** Create the endpoints. Credentials come from Secrets Manager — never as `--password` on the
command line, which lands in shell history and CloudTrail request logs:

```bash
aws dms create-endpoint \
    --endpoint-identifier src-oracle-billing \
    --endpoint-type source \
    --engine-name oracle \
    --oracle-settings '{
        "SecretsManagerAccessRoleArn": "arn:aws:iam::123456789012:role/DmsSecretsAccess",
        "SecretsManagerSecretId": "arn:aws:secretsmanager:us-east-1:123456789012:secret:dms/oracle/billing-AbCdEf"
    }' \
    --ssl-mode require \
    --region ${AWS_REGION}

aws dms create-endpoint \
    --endpoint-identifier tgt-aurora-billing \
    --endpoint-type target \
    --engine-name aurora-postgresql \
    --postgre-sql-settings '{
        "SecretsManagerAccessRoleArn": "arn:aws:iam::123456789012:role/DmsSecretsAccess",
        "SecretsManagerSecretId": "arn:aws:secretsmanager:us-east-1:123456789012:secret:dms/aurora/billing-GhIjKl"
    }' \
    --ssl-mode verify-full \
    --region ${AWS_REGION}
```

**4.** Prove connectivity *before* building a task. This is the step most commonly skipped, and it
is where firewall and security-group mistakes surface:

```bash
aws dms test-connection \
    --replication-instance-arn arn:aws:dms:us-east-1:123456789012:rep:ABCDEFGHIJKLMNOPQRSTUVWXYZ \
    --endpoint-arn arn:aws:dms:us-east-1:123456789012:endpoint:SRCORACLEBILLING1234567890 \
    --region ${AWS_REGION}

aws dms describe-connections --region ${AWS_REGION} \
    --query 'Connections[].{Endpoint:EndpointIdentifier,Status:Status,Error:LastFailureMessage}' \
    --output table
```

Expected output on success:

```
------------------------------------------------------------------
|                       DescribeConnections                      |
+------------------------+-------------+-------------------------+
|        Endpoint        |   Status    |          Error          |
+------------------------+-------------+-------------------------+
|  src-oracle-billing    |  successful |  None                   |
|  tgt-aurora-billing    |  successful |  None                   |
+------------------------+-------------+-------------------------+
```

**5.** Write the table mappings. Create `dms/table-mappings.json`:

```json
{
  "rules": [
    {
      "rule-type": "selection",
      "rule-id": "1",
      "rule-name": "include-billing-schema",
      "object-locator": {
        "schema-name": "BILLING",
        "table-name": "%"
      },
      "rule-action": "include",
      "filters": []
    },
    {
      "rule-type": "selection",
      "rule-id": "2",
      "rule-name": "exclude-audit-history",
      "object-locator": {
        "schema-name": "BILLING",
        "table-name": "AUDIT_%"
      },
      "rule-action": "exclude",
      "filters": []
    },
    {
      "rule-type": "selection",
      "rule-id": "3",
      "rule-name": "recent-invoices-only",
      "object-locator": {
        "schema-name": "BILLING",
        "table-name": "INVOICE"
      },
      "rule-action": "include",
      "filters": [
        {
          "filter-type": "source",
          "column-name": "CREATED_AT",
          "filter-conditions": [
            {
              "filter-operator": "gte",
              "value": "2023-01-01"
            }
          ]
        }
      ]
    },
    {
      "rule-type": "transformation",
      "rule-id": "4",
      "rule-name": "schema-lowercase",
      "rule-target": "schema",
      "object-locator": {
        "schema-name": "BILLING"
      },
      "rule-action": "convert-lowercase"
    },
    {
      "rule-type": "transformation",
      "rule-id": "5",
      "rule-name": "table-lowercase",
      "rule-target": "table",
      "object-locator": {
        "schema-name": "BILLING",
        "table-name": "%"
      },
      "rule-action": "convert-lowercase"
    },
    {
      "rule-type": "transformation",
      "rule-id": "6",
      "rule-name": "column-lowercase",
      "rule-target": "column",
      "object-locator": {
        "schema-name": "BILLING",
        "table-name": "%",
        "column-name": "%"
      },
      "rule-action": "convert-lowercase"
    }
  ]
}
```

**6.** Write the task settings. Create `dms/task-settings.json`:

```json
{
  "TargetMetadata": {
    "SupportLobs": true,
    "FullLobMode": false,
    "LimitedSizeLobMode": true,
    "LobMaxSize": 32,
    "BatchApplyEnabled": true,
    "ParallelLoadThreads": 0,
    "TargetSchema": ""
  },
  "FullLoadSettings": {
    "TargetTablePrepMode": "DO_NOTHING",
    "MaxFullLoadSubTasks": 8,
    "CommitRate": 10000,
    "TransactionConsistencyTimeout": 600,
    "StopTaskCachedChangesApplied": false,
    "StopTaskCachedChangesNotApplied": false
  },
  "Logging": {
    "EnableLogging": true,
    "LogComponents": [
      { "Id": "SOURCE_UNLOAD", "Severity": "LOGGER_SEVERITY_DEFAULT" },
      { "Id": "SOURCE_CAPTURE", "Severity": "LOGGER_SEVERITY_DEFAULT" },
      { "Id": "TARGET_LOAD", "Severity": "LOGGER_SEVERITY_DEFAULT" },
      { "Id": "TARGET_APPLY", "Severity": "LOGGER_SEVERITY_DEFAULT" },
      { "Id": "VALIDATOR_EXT", "Severity": "LOGGER_SEVERITY_DEFAULT" }
    ]
  },
  "ValidationSettings": {
    "EnableValidation": true,
    "ValidationMode": "ROW_LEVEL",
    "ThreadCount": 5,
    "PartitionSize": 10000,
    "FailureMaxCount": 10000,
    "TableFailureMaxCount": 1000,
    "HandleCollisionLimit": 3,
    "RecordFailureDelayInMinutes": 5,
    "RecordSuspendDelayInMinutes": 30,
    "ValidationOnly": false,
    "SkipLobColumns": false
  },
  "ErrorBehavior": {
    "DataErrorPolicy": "LOG_ERROR",
    "TableErrorPolicy": "SUSPEND_TABLE",
    "ApplyErrorDeletePolicy": "LOG_ERROR",
    "ApplyErrorInsertPolicy": "LOG_ERROR",
    "ApplyErrorUpdatePolicy": "LOG_ERROR",
    "FullLoadIgnoreConflicts": true
  },
  "ControlTablesSettings": {
    "ControlSchema": "dms_control",
    "HistoryTimeslotInMinutes": 5,
    "StatusTableEnabled": true,
    "SuspendedTablesTableEnabled": true,
    "HistoryTableEnabled": true
  }
}
```

**7.** Validate both documents before handing them to the API:

```bash
jq empty dms/table-mappings.json && jq empty dms/task-settings.json && echo "Both documents parse"
jq -r '.rules[] | "\(.["rule-id"])  \(.["rule-type"])  \(.["rule-name"])"' dms/table-mappings.json
```

Expected output:

```
Both documents parse
1  selection  include-billing-schema
2  selection  exclude-audit-history
3  selection  recent-invoices-only
4  transformation  schema-lowercase
5  transformation  table-lowercase
6  transformation  column-lowercase
```

**8. `[BILLABLE]`** Create the task. `full-load-and-cdc` is what makes a near-zero-downtime cutover
possible: the bulk copy runs while the source stays live, then CDC keeps the target current until
you choose the moment to switch:

```bash
aws dms create-replication-task \
    --replication-task-identifier billing-oracle-to-aurora \
    --source-endpoint-arn arn:aws:dms:us-east-1:123456789012:endpoint:SRCORACLEBILLING1234567890 \
    --target-endpoint-arn arn:aws:dms:us-east-1:123456789012:endpoint:TGTAURORABILLING0987654321 \
    --replication-instance-arn arn:aws:dms:us-east-1:123456789012:rep:ABCDEFGHIJKLMNOPQRSTUVWXYZ \
    --migration-type full-load-and-cdc \
    --table-mappings file://dms/table-mappings.json \
    --replication-task-settings file://dms/task-settings.json \
    --region ${AWS_REGION}
```

**9.** Run the premigration assessment *before* starting the task. It reports source constructs DMS
cannot carry — unsupported data types, tables with no primary key (which silently break CDC updates
and deletes), and LOBs that exceed your configured limit:

```bash
aws dms start-replication-task-assessment-run \
    --replication-task-arn arn:aws:dms:us-east-1:123456789012:task:BILLINGORACLETOAURORA123 \
    --service-access-role-arn arn:aws:iam::123456789012:role/DmsAssessmentRole \
    --result-location-bucket acme-dms-assessments \
    --result-location-folder billing/wave-1 \
    --assessment-run-name billing-preflight-01 \
    --include-only '["unsupported-data-types-in-source","table-with-no-primary-key-or-unique-index","large-lob-handling"]' \
    --region ${AWS_REGION}
```

Expected output (abridged):

```json
{
    "ReplicationTaskAssessmentRun": {
        "ReplicationTaskAssessmentRunArn": "arn:aws:dms:us-east-1:123456789012:assessment-run:ABC123",
        "AssessmentRunName": "billing-preflight-01",
        "Status": "running",
        "ResultLocationBucket": "acme-dms-assessments",
        "ResultLocationFolder": "billing/wave-1"
    }
}
```

**10. `[BILLABLE]`** Start the task and watch it:

```bash
aws dms start-replication-task \
    --replication-task-arn arn:aws:dms:us-east-1:123456789012:task:BILLINGORACLETOAURORA123 \
    --start-replication-task-type start-replication \
    --region ${AWS_REGION}

aws dms describe-table-statistics \
    --replication-task-arn arn:aws:dms:us-east-1:123456789012:task:BILLINGORACLETOAURORA123 \
    --region ${AWS_REGION} \
    --query 'TableStatistics[].{Table:TableName,State:TableState,Rows:FullLoadRows,
                                Inserts:Inserts,Updates:Updates,Deletes:Deletes,
                                Validation:ValidationState,Pending:ValidationPendingRecords}' \
    --output table
```

Expected output mid-migration:

```
-------------------------------------------------------------------------------------------------------
|                                       DescribeTableStatistics                                       |
+------------+-----------------------+----------+---------+---------+---------+-------------+---------+
|   Table    |         State         |   Rows   | Inserts | Updates | Deletes | Validation  | Pending |
+------------+-----------------------+----------+---------+---------+---------+-------------+---------+
|  invoice   |  Table completed      |  8412677 |   1204  |    318  |     11  |  Validated  |    0    |
|  customer  |  Table completed      |   201455 |     47  |     92  |      0  |  Validated  |    0    |
|  payment   |  Table is being loaded|  3110982 |      0  |      0  |      0  |  Pending    |  114203 |
|  ledger    |  Table completed      |  5602311 |    880  |    404  |      3  |  Mismatched |     19  |
+------------+-----------------------+----------+---------+---------+---------+-------------+---------+
```

**11. Teardown `[IMPORTANT]`** — a running replication instance bills hourly whether or not a task
is active:

```bash
aws dms stop-replication-task --replication-task-arn arn:aws:dms:us-east-1:123456789012:task:BILLINGORACLETOAURORA123 --region ${AWS_REGION}
aws dms delete-replication-task --replication-task-arn arn:aws:dms:us-east-1:123456789012:task:BILLINGORACLETOAURORA123 --region ${AWS_REGION}
aws dms delete-replication-instance --replication-instance-arn arn:aws:dms:us-east-1:123456789012:rep:ABCDEFGHIJKLMNOPQRSTUVWXYZ --region ${AWS_REGION}
aws dms describe-replication-instances --region ${AWS_REGION} --query 'ReplicationInstances[].ReplicationInstanceIdentifier'
```

> Source: [AWS DMS user
> guide](https://docs.aws.amazon.com/dms/latest/userguide/Welcome.html) ·
> [Table
> mapping](https://docs.aws.amazon.com/dms/latest/userguide/CHAP_Tasks.CustomizingTasks.TableMapping.html) ·
> [Premigration
> assessments](https://docs.aws.amazon.com/dms/latest/userguide/CHAP_Tasks.AssessmentReport.html)

### Comprehension check

**Q19.** The task uses `full-load-and-cdc`. Describe the cutover sequence this enables, and identify
precisely which interval constitutes the application's actual downtime.

**Q20.** `ledger` shows `Validation: Mismatched` with 19 records while every row loaded successfully.
Explain why "the full load completed" and "the data is correct" are different claims, and what
DMS-specific mechanism produced that verdict.

**Q21.** The premigration assessment includes `table-with-no-primary-key-or-unique-index`. What
specifically breaks during CDC on such a table, and why does the failure appear only *after* the
full load looks perfect?

**Q22.** Oracle → Aurora PostgreSQL is heterogeneous. Name the tool that handles schema conversion,
and state what DMS does **not** migrate that this tool must address.

**Q23.** A stakeholder asks why this counts as *replatform* and not *rehost* or *refactor*. Give the
one-sentence discriminator for each of the three.

---

## Exercise 6 — Map the Estate onto the AWS Cloud Adoption Framework (CAF)

The exam guide names AWS CAF explicitly. CAF organises the *organisational* readiness work that
tooling cannot do: six perspectives, each owned by a different group of stakeholders.

### Steps

**1.** Record the six perspectives. Create `caf/perspectives.yaml`:

```yaml
# AWS Cloud Adoption Framework - six perspectives
# Business capability perspectives: Business, People, Governance
# Technical capability perspectives: Platform, Security, Operations
perspectives:
  - name: Business
    owners: [CEO, CFO, COO, CIO]
    question: "Does the cloud investment produce a business outcome we can name?"
    capabilities:
      - strategy-management
      - portfolio-management
      - innovation-management
      - product-management
      - data-monetisation

  - name: People
    owners: [CIO, COO, CTO, HR-leaders]
    question: "Do we have the skills, roles and culture to operate what we build?"
    capabilities:
      - culture-evolution
      - transformational-leadership
      - cloud-fluency
      - workforce-transformation
      - organisation-design

  - name: Governance
    owners: [CIO, CTO, CFO, CDO]
    question: "Can we measure, control and justify the spend and the risk?"
    capabilities:
      - programme-and-project-management
      - benefits-management
      - risk-management
      - cloud-financial-management
      - data-governance

  - name: Platform
    owners: [CTO, technology-leaders, architects, engineers]
    question: "Is there a repeatable landing zone to migrate into?"
    capabilities:
      - platform-architecture
      - data-architecture
      - platform-engineering
      - data-engineering
      - provisioning-and-orchestration
      - modern-application-development

  - name: Security
    owners: [CISO, CCO, security-architects, security-engineers]
    question: "Is the target at least as defensible as the source?"
    capabilities:
      - security-governance
      - security-assurance
      - identity-and-access-management
      - threat-detection
      - vulnerability-management
      - infrastructure-protection
      - data-protection
      - application-security
      - incident-response

  - name: Operations
    owners: [infrastructure-and-operations-leaders, SREs, service-managers]
    question: "Can we run it on day two, at the agreed service level?"
    capabilities:
      - observability
      - event-management
      - incident-and-problem-management
      - change-and-release-management
      - performance-and-capacity-management
      - configuration-management
      - patch-management
      - availability-and-continuity-management
      - application-management
```

**2.** Validate it and count the capabilities per perspective:

```bash
python3 -c "
import yaml, sys
doc = yaml.safe_load(open('caf/perspectives.yaml'))
total = 0
for p in doc['perspectives']:
    n = len(p['capabilities'])
    total += n
    print(f\"{p['name']:<12}{n:>3} capabilities   owners: {', '.join(p['owners'][:3])}\")
print(f\"{'TOTAL':<12}{total:>3}\")
"
```

Expected output:

```
Business      5 capabilities   owners: CEO, CFO, COO
People        5 capabilities   owners: CIO, COO, CTO
Governance    5 capabilities   owners: CIO, CTO, CFO
Platform      6 capabilities   owners: CTO, technology-leaders, architects
Security      9 capabilities   owners: CISO, CCO, security-architects
Operations    9 capabilities   owners: infrastructure-and-operations-leaders, SREs, service-managers
TOTAL        39
```

**3.** Map each blocker from a real migration readiness assessment (MRA) onto a perspective. Create
`caf/blockers.csv`:

```csv
Blocker,Perspective,Capability,Owner,BlocksWave
"No tagging standard; cannot attribute spend to a team",Governance,cloud-financial-management,FinOps lead,1
"No one on staff has operated Aurora PostgreSQL",People,workforce-transformation,Platform manager,1
"Security has not approved a baseline AMI",Security,infrastructure-protection,CISO delegate,1
"No landing zone; accounts created ad hoc",Platform,platform-architecture,Cloud architect,1
"On-call runbooks reference physical console access",Operations,incident-and-problem-management,SRE lead,2
"Migration ROI never agreed with the CFO",Business,benefits-management,Programme director,1
```

**4.** Report readiness by perspective:

```bash
python3 -c "
import csv, collections
rows = list(csv.DictReader(open('caf/blockers.csv')))
by = collections.Counter(r['Perspective'] for r in rows)
wave1 = sum(1 for r in rows if r['BlocksWave'] == '1')
for perspective, count in sorted(by.items(), key=lambda kv: -kv[1]):
    print(f'{perspective:<14}{count} open blocker(s)')
print(f'\nWave-1 gating blockers: {wave1} of {len(rows)}')
"
```

Expected output:

```
Business      1 open blocker(s)
Governance    1 open blocker(s)
Operations    1 open blocker(s)
People        1 open blocker(s)
Platform      1 open blocker(s)
Security      1 open blocker(s)

Wave-1 gating blockers: 5 of 6
```

**5.** Situate CAF within the three-phase migration journey used by the AWS Migration Acceleration
Program (MAP):

```markdown
| Phase | Question answered | Representative outputs |
|---|---|---|
| Assess | Is there a business case, and are we ready? | Migration Readiness Assessment, TCO model from Migration Evaluator, CAF gap analysis |
| Mobilize | Have we closed the gaps and proved the pattern? | Landing zone, security baseline, operating model, skills plan, migration of a pilot application |
| Migrate and Modernize | Can we execute at scale and then improve? | Wave plan executed with MGN/DMS/DataSync, tracked in Migration Hub, followed by modernisation |
```

> Source: [AWS Cloud Adoption Framework
> overview](https://docs.aws.amazon.com/whitepapers/latest/overview-aws-cloud-adoption-framework/welcome.html) ·
> [AWS Migration Acceleration
> Program](https://aws.amazon.com/migration-acceleration-program/)

### Comprehension check

**Q24.** Five of the six blockers gate wave 1, and only one of the five is fixed by writing code.
What does that ratio tell you about why migrations slip, and which CAF perspectives dominate the
critical path?

**Q25.** "No one on staff has operated Aurora PostgreSQL" is filed under **People**, not
**Platform**. Justify that placement, and describe what goes wrong if it is treated as a Platform
problem instead.

**Q26.** A programme skips Mobilize and goes straight from Assess to migrating 50 servers. Name the
two most likely failure modes, mapping each to the CAF perspective that would have caught it.

**Q27.** CAF splits its six perspectives into business capabilities and technical capabilities.
Which three are which, and why does the exam guide care about the distinction for a *cloud
practitioner* rather than an engineer?

---

## Exercise 7 — Quantify the Benefits After Migration

The exam guide lists the benefits of migration in business terms. This exercise converts them into
things you can actually measure in an AWS account.

### Steps

**1.** Map each benefit to a measurable proxy. Create `caf/benefits.md`:

```markdown
| Benefit (CLF-C02) | Measurable proxy | Where the number comes from |
|---|---|---|
| Reduced business risk | Recovery Time Objective, patch latency, % of estate on supported OS | AWS Backup / Elastic Disaster Recovery drill results, Systems Manager Patch Manager compliance |
| Improved ESG performance | Estimated carbon emissions of the workload | AWS Customer Carbon Footprint Tool |
| Increased revenue | Time from idea to production; new regions served | Deployment frequency; latency per geography |
| Increased operational efficiency | Cost per transaction; toil hours per month | Cost Explorer grouped by tag; incident volume in CloudWatch/Systems Manager OpsCenter |
```

**2.** Enforce the tagging that makes any of it measurable. Without a tag policy, "cost per
application" is unanswerable:

```bash
aws organizations describe-organization --query 'Organization.Id' --output text

cat > caf/tag-policy.json <<'EOF'
{
  "tags": {
    "migration-wave": {
      "tag_key": { "@@assign": "migration-wave" },
      "tag_value": { "@@assign": ["0", "1", "2", "3"] },
      "enforced_for": { "@@assign": ["ec2:instance", "rds:db", "s3:bucket"] }
    },
    "application": {
      "tag_key": { "@@assign": "application" },
      "enforced_for": { "@@assign": ["ec2:instance", "rds:db"] }
    },
    "migration-strategy": {
      "tag_key": { "@@assign": "migration-strategy" },
      "tag_value": { "@@assign": ["rehost", "relocate", "replatform", "repurchase", "refactor", "retain", "retire"] }
    }
  }
}
EOF

jq empty caf/tag-policy.json && echo "Tag policy is well-formed"
```

**3.** Activate the tags as cost allocation keys so they appear in Cost Explorer:

```bash
aws ce update-cost-allocation-tags-status \
    --cost-allocation-tags-status \
        TagKey=migration-wave,Status=Active \
        TagKey=application,Status=Active \
        TagKey=migration-strategy,Status=Active \
    --region us-east-1
```

Expected output when all succeed:

```json
{
    "Errors": []
}
```

**4.** Pull actual spend grouped by migration wave:

```bash
aws ce get-cost-and-usage \
    --time-period Start=2026-08-01,End=2026-09-01 \
    --granularity MONTHLY \
    --metrics UnblendedCost \
    --group-by Type=TAG,Key=migration-wave \
    --region us-east-1 \
    --query 'ResultsByTime[0].Groups[].{Wave:Keys[0],Cost:Metrics.UnblendedCost.Amount}' \
    --output table
```

Expected output:

```
------------------------------------------
|           GetCostAndUsage              |
+----------------------+------------------+
|         Wave         |      Cost        |
+----------------------+------------------+
|  migration-wave$1    |  18422.7710      |
|  migration-wave$2    |   4108.3355      |
|  migration-wave$     |   2951.0042      |
+----------------------+------------------+
```

**5.** Interpret the untagged bucket — `migration-wave$` with an empty value is spend you cannot
attribute, and it is the first thing a CFO will challenge:

```bash
aws ce get-cost-and-usage \
    --time-period Start=2026-08-01,End=2026-09-01 \
    --granularity MONTHLY \
    --metrics UnblendedCost \
    --filter '{"Tags":{"Key":"migration-wave","MatchOptions":["ABSENT"]}}' \
    --group-by Type=DIMENSION,Key=SERVICE \
    --region us-east-1 \
    --query 'ResultsByTime[0].Groups[].{Service:Keys[0],Cost:Metrics.UnblendedCost.Amount}' \
    --output table
```

**6.** Compare against the pre-migration baseline. Create `caf/tco.py`:

```python
#!/usr/bin/env python3
"""Compare on-premises total cost of ownership against realised AWS spend.

The on-premises figure must include the costs a datacentre bill hides:
hardware refresh amortisation, facilities, and the staff hours spent racking
and patching rather than shipping product.
"""

ON_PREM_MONTHLY = {
    "hardware amortisation (3yr refresh)": 41_000,
    "datacentre space and power":          12_500,
    "network and circuits":                 6_200,
    "software licences (OS, hypervisor)":  14_800,
    "infrastructure staff (loaded)":       28_000,
    "DR site (idle, standby)":             19_400,
}

AWS_MONTHLY = {
    "compute (EC2, right-sized)":          22_480,
    "storage (EBS, S3)":                    5_910,
    "database (Aurora)",                    # placeholder replaced below
}

AWS_MONTHLY = {
    "compute (EC2, right-sized)":          22_480,
    "storage (EBS, S3)":                    5_910,
    "database (Aurora)":                    8_140,
    "data transfer":                        1_070,
    "support and tooling":                  3_300,
    "cloud platform staff (loaded)":       18_000,
    "DR (Elastic Disaster Recovery, pilot light)": 2_600,
}

def report(title, items):
    print(f"\n{title}")
    print("-" * 56)
    for label, amount in items.items():
        print(f"  {label:<44}{amount:>9,}")
    total = sum(items.values())
    print(f"  {'TOTAL':<44}{total:>9,}")
    return total

before = report("On-premises, monthly (USD)", ON_PREM_MONTHLY)
after = report("AWS, monthly (USD)", AWS_MONTHLY)

delta = before - after
print(f"\nMonthly delta: {delta:,}  ({delta / before * 100:.1f}% reduction)")
print(f"Annualised:    {delta * 12:,}")
print("\nNot captured above, and usually larger: the DR site is now 2,600/month")
print("instead of 19,400 for idle standby hardware, and capacity changes take")
print("minutes instead of a procurement cycle.")
```

**7.** Run it:

```bash
python3 caf/tco.py
```

Expected output:

```
On-premises, monthly (USD)
--------------------------------------------------------
  hardware amortisation (3yr refresh)            41,000
  datacentre space and power                     12,500
  network and circuits                            6,200
  software licences (OS, hypervisor)             14,800
  infrastructure staff (loaded)                  28,000
  DR site (idle, standby)                        19,400
  TOTAL                                         121,900

AWS, monthly (USD)
--------------------------------------------------------
  compute (EC2, right-sized)                     22,480
  storage (EBS, S3)                               5,910
  database (Aurora)                               8,140
  data transfer                                   1,070
  support and tooling                             3,300
  cloud platform staff (loaded)                  18,000
  DR (Elastic Disaster Recovery, pilot light)     2,600
  TOTAL                                          61,500

Monthly delta: 60,400  (49.5% reduction)
Annualised:    724,800

Not captured above, and usually larger: the DR site is now 2,600/month
instead of 19,400 for idle standby hardware, and capacity changes take
minutes instead of a procurement cycle.
```

**8.** Record programme progress in Migration Hub so the benefit claim is anchored to actual
completed work:

```bash
aws migrationhub notify-application-state \
    --application-id d-application-0a1b2c3d4e5f6g7h8 \
    --status COMPLETED \
    --region ${AWS_REGION}

aws migrationhub list-application-states --region ${AWS_REGION} \
    --query 'ApplicationStateList[].{App:ApplicationId,Status:ApplicationStatus,Updated:LastUpdatedTime}' \
    --output table
```

> Source: [AWS Migration
> Evaluator](https://aws.amazon.com/migration-evaluator/) ·
> [Cost Explorer
> `GetCostAndUsage`](https://docs.aws.amazon.com/aws-cost-management/latest/APIReference/API_GetCostAndUsage.html) ·
> [Customer Carbon Footprint
> Tool](https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/ccft-overview.html)

### Comprehension check

**Q28.** Step 6 lists "DR site (idle, standby)" at 19,400 on premises against 2,600 on AWS. Which
architectural property of the cloud produces that specific line-item change, and which CLF-C02
benefit category does it belong to?

**Q29.** "cloud platform staff (loaded)" is 18,000 against 28,000 on premises — a reduction, but not
elimination. Explain why a migration that projects staff cost going to zero is not credible, and
what the staff time is actually redirected toward.

**Q30.** Cost Explorer reported 2,951 USD of untagged spend. Name two consequences for the migration
programme, beyond the accounting inconvenience.

**Q31.** A team claims "we migrated, so we improved our ESG performance." What would you require
them to produce before signing off that claim, and what property of AWS's infrastructure is doing
the actual work?

**Q32.** Argue the case that "increased operational efficiency" and "increased revenue" — two
separate benefit categories in the exam guide — are frequently the *same* underlying change observed
from different seats.

---

## Exercise 8 — Assemble the Wave Plan

Everything above converges into one artefact: a wave plan that a delivery team can execute.

### Steps

**1.** Build the plan. Create `inventory/wave-plan.md`:

```markdown
# Wave plan - Acme datacentre exit

## Wave 0 - Proof (weeks 1-3)
| Server | App | R | Tool | Cutover risk | Rollback |
|---|---|---|---|---|---|
| jump-01 | legacy-tools | retire | - | None | Restore from final backup, 90-day retention |

Exit criteria: landing zone live, tag policy enforced, CAF Governance and Platform blockers closed.

## Wave 1 - Stateless tier (weeks 4-7)
| Server | App | R | Tool | Cutover risk | Rollback |
|---|---|---|---|---|---|
| web-prod-01 | storefront | rehost | MGN | Low - behind ALB, drain and shift | Re-point DNS to on-prem VIP; source untouched |
| web-prod-02 | storefront | rehost | MGN | Low | As above |

Exit criteria: two successful MGN test launches per server, load test at 1.5x peak, runbook rehearsed.

## Wave 2 - Data tier (weeks 8-14)
| Server | App | R | Tool | Cutover risk | Rollback |
|---|---|---|---|---|---|
| ora-prod-01 | billing | replatform | SCT + DMS full-load-and-cdc | High - schema conversion, app connection strings | Reverse CDC task Aurora -> Oracle, pre-built and tested |
| sql-prod-01 | crm | replatform | MGN then in-place upgrade, or RDS SQL Server | Medium - EOL OS | MGN source retained 14 days post-cutover |

Exit criteria: DMS validation reports zero mismatched rows for 72 consecutive hours; reverse
replication task proven by an actual rollback drill, not by inspection.

## Wave 3 - Bulk data (parallel with waves 1-2)
| Dataset | Size | Method | Notes |
|---|---|---|---|
| Archive tier | 300 TB | 4x Snowball Edge Storage Optimized | Offline; dataset outruns the 1 Gbps link |
| Fileshare | 8 TB | DataSync over Direct Connect | Then FSx for Windows File Server; keeps ACLs |

Exit criteria: DataSync delta run after Snowball ingest reports zero differences.

## Retained
| Server | Reason | Review date |
|---|---|---|
| (none in this estate) | - | - |
```

**2.** Sanity-check the plan against the classification output — every discovered server must appear
exactly once, or something has been silently dropped:

```bash
comm -3 \
  <(python3 inventory/classify.py inventory/wave-0.csv | tail -n +3 | awk '{print $1}' | sort) \
  <(grep -oE '^\| [a-z0-9-]+ \|' inventory/wave-plan.md | tr -d '| ' | sort -u)
```

Expected output when the plan is complete:

```
(no output)
```

**3.** Confirm the rollback position for the highest-risk item. For a DMS replatform, the rollback
is a *pre-built reverse task*, not a hope:

```bash
aws dms describe-replication-tasks --region ${AWS_REGION} \
    --query 'ReplicationTasks[].{Task:ReplicationTaskIdentifier,Type:MigrationType,Status:Status}' \
    --output table
```

Expected output when both directions exist:

```
--------------------------------------------------------------------
|                     DescribeReplicationTasks                     |
+------------------------------+---------------------+-------------+
|             Task             |        Type         |   Status    |
+------------------------------+---------------------+-------------+
|  billing-oracle-to-aurora    |  full-load-and-cdc  |  running    |
|  billing-aurora-to-oracle    |  cdc                |  stopped    |
+------------------------------+---------------------+-------------+
```

### Comprehension check

**Q33.** Wave 0 migrates nothing — it retires one server. Defend that as the correct first wave
rather than wasted time.

**Q34.** Wave 3 runs in parallel with waves 1 and 2, while waves 1 and 2 are strictly sequential.
What property of the work makes bulk data movement parallelisable and application cutover not?

**Q35.** The wave-2 exit criterion is "the reverse replication task proven by an actual rollback
drill, not by inspection." Why is an untested rollback path indistinguishable from having none, and
which CLF-C02 benefit does the drill protect?

**Q36.** `sql-prod-01` has two candidate approaches listed (`MGN then in-place upgrade` or `RDS SQL
Server`). Name the single decision input that most cleanly resolves the choice.

---

<details>
<summary><strong>Answers</strong></summary>

### Exercise 1 — Migration Hub home region and inventory import

**A1.** The home region is where Migration Hub and Application Discovery Service **store** discovery
and migration-tracking data — the inventory, the application groupings, and the progress records.
It is deliberately decoupled from the regions you migrate *into*: the control plane for setting it
lives in `us-west-2`, the data lives in the home region you chose, and the workloads can land
anywhere. The exam guide separates discovery from migration because they answer different questions.
Discovery answers "what do we have, how big is it, what talks to what" — and that answer is what
determines the strategy. Migration is execution. A programme that starts executing before it has
discovery data is choosing strategies from a spreadsheet someone maintained by hand, which is the
single most common source of scope surprises mid-migration.

**A2.** The home region is a **one-time setting per account** and cannot be changed once data has
been collected — you would need a new account, or to work with AWS Support. It is a data-residency
and durability decision, not a workload-placement one. It does **not** constrain migration targets:
you can track a migration in a `us-east-1` home region while every server lands in `eu-west-1`. The
only real consideration is regulatory — if inventory metadata (hostnames, IP addresses,
application names) is itself subject to a residency requirement, choose a compliant home region
before importing anything.

**A3.** The CSV gives you **static configuration**: cores, RAM, disk count, OS. An installed
discovery agent gives you **time-series utilisation and network connections** — actual CPU and
memory consumption over weeks, and TCP flows showing which servers talk to which on which ports.

The strategy hardest to choose without it is **retire**, closely followed by right-sizing decisions
inside **rehost**. Without utilisation data you cannot prove a server is idle, so nobody will let you
turn it off; without network dependency data you cannot prove nothing depends on it, so you cannot
group servers into a movable application boundary. Static inventory tells you a server has 16 cores;
only agent data tells you it has averaged 3% CPU for six months and receives no inbound connections.

**A4.** **Reduced business risk.** Unsupported operating systems stop receiving security patches,
which is an unbounded and growing vulnerability exposure, and they typically cannot be covered by a
compliance attestation. Note that it is a secondary win on cost too — extended-support contracts for
EOL software are expensive — but the primary framing in the exam guide is risk reduction.

---

### Exercise 2 — Applying the 7 Rs

**A5.** **Rehost is correct for `sql-prod-01` when the constraint is a hard deadline.** If the
datacentre lease expires in 90 days, the correct move is to lift the server as-is, exit the
facility, and then remediate the OS in AWS where you have snapshots, easy rollback, and no
procurement cycle. Rehost decouples "leave the building" from "fix the debt."

The cost is real and should be stated explicitly: you have imported an unpatched, unsupported
operating system into your AWS account, where it now runs alongside compliant workloads. You must
book the remediation as scheduled work with an owner and a date, and it must be constrained in the
meantime — tight security groups, no public exposure, enhanced monitoring. A rehost that quietly
becomes permanent is how organisations end up with Windows Server 2012 in a "modern cloud estate"
three years later.

**A6.** Two objections:

1. **Refactor is bounded by application-team capacity, not by infrastructure capacity.** Rehosting
   500 servers is a repeatable pipeline a migration team executes. Refactoring 500 applications
   requires 500 sets of developers who understand the business logic, and those people are already
   fully committed to their own roadmaps. The migration timeline becomes the sum of every product
   team's availability — which no migration programme controls.
2. **It puts the datacentre exit on the critical path of application rewrites.** The lease is a hard
   external deadline. Refactoring has genuinely unpredictable duration, because you discover the
   real complexity only once you are inside the code. Coupling a fixed deadline to an unbounded
   activity is the failure mode. The standard answer is **migrate first, modernise second**: exit
   the facility with rehost/replatform, then refactor selectively where it has a business case.

**A7.** For **repurchase**, the missing signal is **software identity** — the installed application
name and vendor, not just the OS. If discovery reports a self-hosted Exchange, GitLab, Jira, or a
commercial CRM, the question becomes "why are we operating this at all?" rather than "where should
we run it?" Discovery agents and CMDB exports carry installed-software inventory; the reduced CSV
here does not.

For **relocate**, the deciding infrastructure fact is that the estate runs on **VMware vSphere**,
and that the priority is moving hundreds or thousands of VMs quickly without changing them. Relocate
moves workloads at the hypervisor layer into a VMware environment on AWS infrastructure, so guest
OS, tooling and operational runbooks are unchanged. It is the fastest exit path and the lowest
cloud-native benefit — appropriate as a staging step, not an end state.

**A8.** Retire has the highest return on effort because the saving is **immediate, permanent, and
100% of that server's cost** — no migration engineering, no cutover risk, no residual runtime spend.
Every other R leaves you paying for something. Typical enterprise estates carry 10–20% zombie
servers, so retire alone often funds a meaningful slice of the programme.

Discovery must prove two things before you can act: **no meaningful utilisation** over a
representative period (covering month-end and quarter-end batch windows, which is why a two-week
sample is not enough), and **no inbound network dependencies** from systems that are staying. The
second is the one that catches people — an idle server can still be the thing that one nightly job
connects to at 3am on the last day of the month.

---

### Exercise 3 — Online versus offline transfer

**A9.** `Converges: False` means the source data is being created faster than the link can drain it.
At 300 TB with 2% daily change, the source generates 6 TB per day while the link moves roughly
7.6 TB per day — and that margin collapses the moment the link is shared, throttled, or interrupted.
The "39.7 days" figure is irrelevant because it assumes a static dataset: in reality you never reach
a synchronised state, you asymptotically chase it. This is why the convergence check must come
before the duration check.

**A10.** Two hidden costs:

1. **You are holding a WAN link at 70% utilisation for a month.** That link is also carrying
   production traffic — replication, backups, user sessions, VPN. A month of sustained bulk transfer
   degrades everything else on it, and the incidents that result are charged to the migration.
2. **You are holding open a 31-day window during which any interruption restarts or extends the
   job.** Circuit maintenance, a failed transfer agent, a firewall change — each one is a partial
   restart. Risk accumulates with elapsed time, and 31 days of exposure is materially different from
   the two or three days a device shipment takes.

There is also a straightforward third: 31 days of engineer attention monitoring a transfer is real
salary spend that never appears in the network cost.

**A11.** The manifest is an encrypted file containing the keys needed to decrypt the device's data;
the unlock code is the passphrase that decrypts the manifest. They are retrieved by two separate API
calls and are meant to travel by two different channels — the manifest by one path, the code by
another (commonly read aloud or sent to a different recipient).

The attack this defeats is **physical interception in transit**. Whole-disk encryption protects
against someone stealing the device and reading the platters, but it does nothing if the credential
needed to unlock it travels with the device or is available to whoever receives it. Splitting the
credential means compromising the shipment is insufficient: an attacker needs the hardware *and*
the manifest *and* the unlock code, obtained through three different channels. It is two-factor
authentication applied to a physical object.

**A12.** Use **AWS DataSync** in incremental mode (`TransferMode=CHANGED`), pointed at the same S3
destination the Snowball data landed in. DataSync compares source and destination metadata and
transfers only what differs, so after the bulk seed you are moving three weeks of deltas — likely
low single-digit terabytes — which the network handles easily.

A second Snowball round is wrong for three reasons: the round trip adds another one to two weeks of
latency during which *more* delta accumulates; the device would carry mostly unchanged data because
Snowball's copy tooling has no efficient way to diff against what is already in S3; and it re-incurs
the whole shipping, handling and secure-erase cycle to move a fraction of a device's capacity. The
canonical pattern is **Snowball for the bulk seed, DataSync for the deltas and the final
reconciliation** — offline for volume, online for currency.

**A13.** Storage Gateway is the better answer when the requirement is **ongoing hybrid access, not a
one-time move** — when on-premises applications must keep reading and writing that data with low
latency while the authoritative copy lives in S3. File Gateway presents an NFS or SMB mount backed
by S3 objects, caching the working set locally.

What it changes about the end state is fundamental: Snowball is a **migration** — the data moves to
AWS and the source is decommissioned. Storage Gateway is an **architecture** — a permanent hybrid
component you now operate, monitor, patch and pay for indefinitely. If the goal is a datacentre
exit, Storage Gateway leaves you with something still in the datacentre. It is the right answer for
"we need cloud-backed storage with local access," and the wrong answer for "we need this data out of
the building."

---

### Exercise 4 — Rehost with MGN

**A14.** The two metrics are **Recovery Point Objective (RPO)** — how much data you can lose — and
**Recovery Time Objective (RTO)** — how long the switch takes. Continuous block-level replication
holds RPO in the sub-second to seconds range, because the target is always current.

The order-of-magnitude improvement is in **RTO**. With snapshot-and-copy, cutover time is
proportional to data volume: a 2 TB server means hours of copying while the application is down.
With MGN the data is already at the destination, so cutover is "take a final consistent snapshot and
boot an instance" — minutes, and crucially *independent of how large the server is*. Removing the
data-volume term from the downtime equation is what makes rehosting hundreds of servers on a
schedule feasible.

**A15.** Because it converts an untested plan into a **rehearsed, evidenced procedure**. The test
launch boots a real instance from real replicated data in the real target VPC, so you discover the
missing DNS entry, the hard-coded IP, the license server that will not respond, and the
security-group gap *before* the maintenance window rather than during it. The source server is never
touched and replication never pauses, so a failed test costs nothing but the instance-hours.

That is the definition of reduced business risk: the migration stops being a one-shot event where
failure means an outage, and becomes a procedure executed for the n-th time on cutover night, with
every previously-discovered surprise already fixed. You can run the test on Tuesday, fix what broke,
run it again on Thursday, and cut over on Saturday having seen the outcome twice.

**A16.** Right-sizing selects the target EC2 instance type from the **source server's actual
specification and observed utilisation** rather than replicating its nameplate configuration. The
`BASIC` method maps the source's CPU and RAM to the smallest instance type that satisfies them,
instead of provisioning a match for hardware that was bought oversized in 2019 to survive a
three-year refresh cycle.

It is a genuine migration benefit rather than a setting because **on premises you could not act on
this knowledge**. You bought a physical server sized for peak-plus-headroom-plus-growth and paid for
that capacity 24/7 for its whole life, whether or not it was used. In AWS, capacity is a
per-hour choice you can revise. Right-sizing at launch is the moment the estate stops carrying years
of accumulated over-provisioning — and it is where most of the actual cost benefit of a rehost comes
from, since the rehost itself changes nothing else.

**A17.** `finalize-cutover` **terminates the replication resources**: the replication servers in the
staging area, the staging EBS volumes holding the replicated data, and the ongoing replication
relationship. The source server moves to a `CUTOVER` lifecycle state and is no longer replicating.

Run it before sign-off and you have destroyed your rollback. Until finalisation, rollback is
trivial — the source server is still live and still synchronised, so you re-point traffic back and
lose nothing. After finalisation, the replicated state is gone; recovering means re-installing the
agent and performing a fresh initial sync, which for a large server is hours to days. Anything the
application wrote in AWS since cutover is now diverged from the source, so "roll back" also becomes
a data-reconciliation problem rather than a traffic change. This is why finalisation is a deliberate,
separate, explicitly-approved step and not part of cutover.

**A18.** Pure rehost changes **where** a workload runs, not **how much it consumes**. The same
oversized instance runs the same code 24/7, and you have converted a depreciating capital asset into
an operating expense at roughly comparable monthly cost — sometimes higher, because on-premises
hardware that is already three years into a five-year amortisation looks very cheap on a monthly
basis. It is a real and well-documented outcome, not a failure of execution.

The savings are realised in the **optimise / modernise phase after landing**: right-sizing against
observed CloudWatch data, turning non-production off outside business hours, Savings Plans or
Reserved Instances for the steady-state baseline, Graviton where the workload supports it, moving
cold data to S3 lifecycle tiers, and replatforming the database tier to a managed service that
removes licensing and administration. Rehost buys you *the ability* to do all of those; it does not
do any of them. The mistake is treating cutover as the end of the programme rather than the point at
which optimisation becomes possible.

---

### Exercise 5 — Replatform with DMS

**A19.** The sequence is: (1) full load copies existing rows while the source database stays live
and serving traffic; (2) CDC captures every change made during and after the full load from the
source's transaction log and applies it to the target, so the target converges on the source and
then tracks it with a small lag; (3) you monitor until lag is consistently near zero; (4) at the
chosen moment you stop the application, wait for the last transactions to drain through CDC, verify
lag is zero, re-point the application's connection string to the target, and start it.

**The downtime is only step 4** — from stopping the application to starting it against the new
endpoint. That is minutes, and it is independent of database size. Without CDC, downtime would be
the entire full-load duration, because the database would have to be quiesced for the whole copy;
for a multi-terabyte database that is hours to days. Eliminating the data-volume term from the
downtime is the entire point.

**A20.** "Full load completed" means every row was **read from the source and written to the
target**. It says nothing about whether the values are equivalent after crossing an engine boundary.
Heterogeneous migration passes data through type conversion, and that is where silent corruption
lives: Oracle `NUMBER` with a precision PostgreSQL cannot represent identically, timestamps losing
sub-second precision or timezone context, `CHAR` padding semantics differing, LOBs truncated at the
configured `LobMaxSize` of 32 KB, character-set conversion mangling non-ASCII text.

The mechanism is **DMS data validation** (`EnableValidation: true`, `ValidationMode: ROW_LEVEL`).
It runs as a separate pass, independently re-reading rows from both source and target and comparing
them value by value. `Mismatched` means it found 19 rows where the target value is not equivalent to
the source value. Those rows loaded "successfully" — DMS wrote whatever the conversion produced.
Only validation catches the difference between "written" and "correct," which is exactly why the
setting should be on for every heterogeneous migration and why cutover criteria are written against
the validation state rather than the load state.

**A21.** CDC applies changes to the target by locating the affected row. Without a primary key or
unique index, DMS has **no way to uniquely identify which target row corresponds to a source
change**. `UPDATE` and `DELETE` operations therefore cannot be applied reliably — depending on
settings, DMS may fail the operation, apply it to every matching row, or apply it to none. Inserts
work fine, because they do not need to locate anything.

The failure appears only after the full load looks perfect because **full load is insert-only**. It
reads every source row and inserts it into the target; no row identity is required. The table
therefore reports a complete, successful load with the correct row count. The problem surfaces once
CDC begins applying the ongoing change stream — and worse, it can surface *quietly*, with row counts
still matching while individual rows drift out of sync. This is precisely why the premigration
assessment exists: it is a static check on source metadata that costs nothing and catches the
problem before you have built a cutover plan around a table that cannot be replicated.

**A22.** The tool is the **AWS Schema Conversion Tool (SCT)**, or its integrated equivalent **DMS
Schema Conversion**.

DMS migrates **data** — rows, and ongoing changes to rows. It does **not** migrate schema objects or
code: table and index definitions, constraints, sequences, views, stored procedures, functions,
packages, triggers, custom types, or database-specific features like Oracle PL/SQL packages and
`DBMS_*` calls. SCT converts what it can automatically and produces an **assessment report**
enumerating what it could not, with an effort estimate per item. That report is the honest input to
the replatform-versus-refactor decision: if SCT reports 5% manual intervention the project is
routine; if it reports 40%, the "replatform" is really a rewrite wearing a replatform label, and
should be scoped and staffed as one.

**A23.**
- **Rehost**: nothing above the hypervisor changes — the same Oracle binaries run on an EC2 instance
  instead of physical hardware.
- **Replatform**: the *platform underneath* the application changes to a managed service, but the
  application's own code does not need rewriting — Oracle becomes Aurora PostgreSQL, so you stop
  administering a database engine, but the billing application still issues SQL against a relational
  database. (Connection strings and dialect-specific queries change; business logic does not.)
- **Refactor**: the *application's architecture* changes — the billing service is decomposed into
  event-driven functions writing to DynamoDB, which is a different data model requiring the
  application to be rewritten.

The one-line discriminator: rehost changes the **hardware**, replatform changes the **platform**,
refactor changes the **application**.

---

### Exercise 6 — AWS CAF

**A24.** It tells you that migrations slip on **organisational readiness, not technology**. Five of
six wave-1 blockers are decisions, approvals, agreements and skills — things that require a person
with authority to commit, and that no amount of engineering throughput accelerates. The critical
path is dominated by **Governance, People, Security and Business**; only the landing zone blocker is
Platform, and it is the one an engineering team can simply go and build.

The practical consequence is scheduling: these blockers must be worked in the Mobilize phase, in
parallel with and ahead of technical preparation, because they have long lead times measured in
committee cycles rather than sprints. A migration programme that staffs only engineers will be
blocked and will not be able to unblock itself.

**A25.** It is a **People** blocker because the gap is *human capability*, and the remedy is
training, hiring, or a partner engagement — a workforce action with a lead time of weeks to months.
Platform's job is to make Aurora available and well-architected; that can be done in an afternoon
with Terraform and does not create a single person who knows what to do when Aurora fails over at
2am.

Treating it as a Platform problem produces a specific and common failure: the platform team
provisions Aurora, declares the capability delivered, and the migration proceeds. The operational
gap surfaces on **day two**, during the first incident, when nobody on call understands replica lag,
failover behaviour, or how to read the performance insights that would explain it. You have
successfully migrated into a service you cannot operate, which is worse than not having migrated —
the old system was at least understood by the people responsible for it. The exam guide's framing of
migration as an organisational change, not just a technical one, is exactly this point.

**A26.** Two likely failure modes:

1. **Inconsistent, ungoverned accounts and no security baseline** — servers land in hand-built
   accounts with ad-hoc networking and IAM, and the estate becomes ungovernable and unauditable at
   scale. Fixing it retroactively across 50 servers costs multiples of doing it once, up front.
   Caught by **Platform** (landing zone) and **Security** (baseline, guardrails, IAM model).
2. **Nobody can operate the result** — no observability, no runbooks written for cloud, an on-call
   rota that still assumes physical console access. The first incident after migration is handled
   badly and visibly. Caught by **Operations** (observability, incident and problem management) and
   **People** (skills and role readiness).

The general pattern: Mobilize exists to build and prove the pattern **once**, on a pilot, so that the
subsequent 50 migrations are repetitions of something known to work rather than 50 independent
first attempts.

**A27.** **Business capabilities: Business, People, Governance.** **Technical capabilities:
Platform, Security, Operations.**

The distinction matters to a cloud practitioner because the practitioner exam is not testing whether
you can build the thing — it is testing whether you understand that **cloud adoption is an
organisational transformation with a technical component, not a technical project with
organisational side effects**. A practitioner is typically the person in a sales, finance, project
management, compliance or leadership seat who must engage with a cloud programme. Their contribution
is on the business-capability side: agreeing the business case, funding it, governing the spend,
managing the risk, and preparing the workforce. CAF's split makes explicit that three of the six
perspectives are owned by people who will never touch the console — and that a programme neglecting
those three will fail regardless of how good its engineering is.

---

### Exercise 7 — Quantifying benefits

**A28.** The property is **elasticity** — specifically, the ability to provision capacity at the
moment of need rather than owning it in advance. An on-premises DR site requires a second set of
physical hardware sized for full production load, sitting idle and depreciating, because you cannot
conjure servers during a disaster. A pilot-light architecture on AWS keeps only the data replicating
and the minimal control plane running, then provisions full capacity from the shared AWS pool during
an actual failover event.

The benefit category is **reduced business risk**, and it is worth noting the direction of the
improvement: you are not merely paying less for the same DR posture, you typically get a *better*
one. Idle standby hardware is rarely exercised, so its readiness is assumed rather than known;
cloud DR is testable on demand at the cost of a few instance-hours, which means it is actually
tested. Cheaper *and* more likely to work is unusual, and it is why DR is one of the most reliable
business cases in a migration.

**A29.** Because the work does not disappear — it **changes shape**. Nobody racks servers, replaces
failed disks, manages hypervisor licensing, or plans a hardware refresh. But somebody must now own
infrastructure-as-code, IAM and the permissions model, cost governance, the CI/CD pipeline,
observability, patching via Systems Manager, and account and guardrail management. Cloud does not
remove operations; it raises the abstraction level at which operations happen.

A business case projecting staff cost to zero is not credible and will be rejected by anyone who has
run infrastructure — and rightly so, because it usually indicates the plan has no day-two operating
model at all. The honest claim is that the same headcount produces more: time formerly spent on
undifferentiated heavy lifting is redirected to automation and to work that is specific to the
business. That redirection is the actual value, and it belongs under **increased operational
efficiency**, sometimes flowing through to **increased revenue** when the freed capacity goes into
product work.

**A30.** Two consequences:

1. **The business case becomes unverifiable.** You cannot report cost-per-application or
   cost-per-wave for spend you cannot attribute, so you cannot demonstrate that a given migration
   delivered its projected saving. The programme's credibility with the CFO rests on exactly this
   number, and "roughly 5% of it is unattributed" is where the conversation stalls.
2. **Optimisation loses its owner.** Untagged resources have no accountable team, so nobody is
   responsible for right-sizing, scheduling, or deleting them. Unattributed spend reliably becomes
   *permanent* spend — orphaned volumes, forgotten test instances, staging environments left running
   after a cutover. It also frequently indicates provisioning happening outside the sanctioned
   pipeline, which is a governance and security signal as much as a cost one.

**A31.** Require the **Customer Carbon Footprint Tool** output for the account over a comparable
period, alongside a documented estimate of the retired on-premises footprint. Without a
before-and-after in the same units, the claim is an assertion.

The property doing the work is **utilisation efficiency at scale**. A typical enterprise datacentre
runs servers at low average utilisation with a poor power usage effectiveness (PUE) ratio, because
capacity is provisioned for peak and cooling is sized for a half-empty room. AWS runs far higher
utilisation across pooled hardware in purpose-built facilities, and backs consumption with renewable
energy procurement. So the reduction is real — but it is contingent on you actually right-sizing.
Rehosting an oversized fleet unchanged moves the same inefficiency to a more efficient facility;
you get the PUE and renewables benefit but not the utilisation one. The honest version of the claim
is specific about which of those you earned.

**A32.** They are the same change measured at two points in the same causal chain. Consider a
release process that took six weeks on premises because it required a change-advisory board, a
manual environment build, and a scheduled outage window, and now takes two days because environments
are provisioned by pipeline and deployed blue/green.

From the **operations seat**, that is efficiency: fewer engineer-hours per release, less toil, no
weekend windows, lower change-failure rate. From the **product seat**, the identical change is
revenue: a feature reaches customers five and a half weeks earlier, experiments can be run and
killed cheaply, and the organisation can respond to a competitor within a quarter instead of a year.
The exam guide separates them because different stakeholders are persuaded by different framings —
the COO funds efficiency, the CEO funds growth — but for a practitioner the useful insight is that
**cycle time is the shared underlying variable**, and most cloud benefits are downstream of reducing
it. Efficiency is what you save; revenue is what you do with the time you saved.

---

### Exercise 8 — The wave plan

**A33.** Because wave 0's real purpose is to **prove the machinery, not to move load**. Retiring one
low-risk server with no business owner exercises the full process end to end — the discovery data is
correct, the decommissioning approval path works, the backup and retention policy is real, the
communication plan reaches the right people, the rollback is defined — while the blast radius of a
mistake is close to zero.

It also front-loads the CAF blockers: wave 0's exit criteria require the landing zone, the tag
policy, and the Governance and Platform items to be closed. Those are the long-lead organisational
items, and putting them behind a deliberately trivial technical wave means they are worked on
during weeks 1–3 rather than discovered as blockers in week 4. And retirement delivers immediate,
permanent saving with no ongoing cost, so the programme books a real win before it takes its first
real risk. A first wave that is technically ambitious is a first wave that discovers process
problems and technical problems simultaneously, with no way to tell them apart.

**A34.** Bulk data movement is parallelisable because it is **additive and idempotent**: copying
300 TB of archive into S3 does not change the source, does not interrupt any running application,
and can be re-run or resumed without consequence. Nothing depends on its completion until the
application that reads it is migrated, so it can occupy the whole calendar without blocking anything.

Application cutover is sequential because it is a **state transition with dependencies and shared
risk**. Wave 2's database cutover depends on wave 1's application servers being stable in AWS and
reachable from the new data tier — cutting over the database while the app tier is mid-migration
means a failure could originate in either, and you cannot tell which. Cutovers also compete for the
same scarce resources: the maintenance window, the on-call team, the application owners who must
validate, and the rollback capacity. Two simultaneous cutovers means a single incident with two
possible causes and a team split across both. Sequencing is what preserves the ability to attribute
a failure and roll back cleanly.

**A35.** Because a rollback path is a **claim about behaviour under failure**, and the only evidence
for such a claim is having observed the behaviour. Reverse DMS replication has many silent failure
modes: the reverse task may lack permissions, the Oracle target may reject PostgreSQL-originated
types, sequences and identity columns may be out of sync, the reverse task may never have been
started so it has no CDC start position, connectivity may have been closed after the forward
cutover. Every one of those is invisible until you try, and you find out at the worst possible
moment — mid-incident, under time pressure, with the business waiting.

An untested rollback is worse than no rollback, because it changes the decision you make. Believing
you can roll back, you accept a riskier cutover; discovering you cannot, you are past the point of
no return with no plan. The drill protects **reduced business risk** — and specifically it converts
risk from unknown to known, which is the only kind you can actually manage.

**A36.** The **licensing and support position** — specifically, whether the organisation already
owns SQL Server licences with active Software Assurance and whether the application depends on
engine features that RDS does not expose.

That single input resolves it cleanly. Owned licences with mobility rights, or an application
needing filesystem access, SQL Agent jobs with OS-level dependencies, linked servers, CLR
assemblies, or a specific patch level make **MGN plus an in-place upgrade** correct: you keep the
licence investment and full engine control, at the cost of continuing to administer the database.
No existing entitlement, or a preference to stop administering it, makes **RDS SQL Server** correct:
licence-included pricing, automated backups, patching and Multi-AZ, at the cost of losing OS-level
access.

Everything else usually cited — cost, effort, "modernisation" — is downstream of that fact and does
not discriminate on its own.

</details>

---

## References

All URLs verified against official AWS documentation.

- **CLF-C02 exam guide** — <https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf>
- **AWS Cloud Adoption Framework** — <https://docs.aws.amazon.com/whitepapers/latest/overview-aws-cloud-adoption-framework/welcome.html>
- **Migration strategies (the 7 Rs)** — <https://docs.aws.amazon.com/prescriptive-guidance/latest/large-migration-guide/migration-strategies.html>
- **AWS Migration Acceleration Program** — <https://aws.amazon.com/migration-acceleration-program/>
- **AWS Migration Hub** — <https://docs.aws.amazon.com/migrationhub/latest/ug/whatis-migrationhub.html>
- **Migration Hub home region** — <https://docs.aws.amazon.com/migrationhub/latest/ug/home-region.html>
- **AWS Application Discovery Service** — <https://docs.aws.amazon.com/application-discovery/latest/userguide/what-is-appdiscovery.html>
- **Application Discovery import template** — <https://docs.aws.amazon.com/application-discovery/latest/userguide/discovery-import.html>
- **AWS Application Migration Service (MGN)** — <https://docs.aws.amazon.com/mgn/latest/ug/what-is-application-migration-service.html>
- **`aws mgn` CLI reference** — <https://docs.aws.amazon.com/cli/latest/reference/mgn/>
- **AWS Database Migration Service** — <https://docs.aws.amazon.com/dms/latest/userguide/Welcome.html>
- **DMS table mapping** — <https://docs.aws.amazon.com/dms/latest/userguide/CHAP_Tasks.CustomizingTasks.TableMapping.html>
- **DMS task settings** — <https://docs.aws.amazon.com/dms/latest/userguide/CHAP_Tasks.CustomizingTasks.html>
- **DMS premigration assessments** — <https://docs.aws.amazon.com/dms/latest/userguide/CHAP_Tasks.AssessmentReport.html>
- **DMS data validation** — <https://docs.aws.amazon.com/dms/latest/userguide/CHAP_Validating.html>
- **AWS Schema Conversion Tool** — <https://docs.aws.amazon.com/SchemaConversionTool/latest/userguide/CHAP_Welcome.html>
- **AWS Snowball Edge developer guide** — <https://docs.aws.amazon.com/snowball/latest/developer-guide/whatisedge.html>
- **AWS Snow Family** — <https://aws.amazon.com/snow/>
- **AWS DataSync** — <https://docs.aws.amazon.com/datasync/latest/userguide/what-is-datasync.html>
- **AWS Storage Gateway** — <https://docs.aws.amazon.com/storagegateway/latest/userguide/WhatIsStorageGateway.html>
- **AWS Transfer Family** — <https://docs.aws.amazon.com/transfer/latest/userguide/what-is-aws-transfer-family.html>
- **AWS Migration Evaluator** — <https://aws.amazon.com/migration-evaluator/>
- **Cost Explorer `GetCostAndUsage`** — <https://docs.aws.amazon.com/aws-cost-management/latest/APIReference/API_GetCostAndUsage.html>
- **Customer Carbon Footprint Tool** — <https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/ccft-overview.html>
- **AWS Organizations tag policies** — <https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_tag-policies.html>