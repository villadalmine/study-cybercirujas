# Topic 3.4 — Identify AWS Database Services
## Guided Exercises (production-grade)

**Certification:** AWS Certified Cloud Practitioner — CLF-C02 (v1.0)
**Domain 3:** Cloud Technology and Services · **Task 3.4:** Identify AWS database services
**Exam weight:** 4.25 %

---

### What you will actually be able to do at the end

Not "recite that DynamoDB is NoSQL". You will be able to stand in front of a whiteboard and defend a choice: *why* a workload belongs on Aurora and not on RDS for PostgreSQL, *why* a strongly consistent read on DynamoDB costs twice an eventually consistent one, *where* the shared responsibility line falls when you move a database from EC2 to RDS to DynamoDB, and *what* an RDS Multi-AZ failover does and does not protect you from.

---

## ⚠️ Read before you type anything

These exercises create billable resources. The blocks are labelled:

| Label | Meaning |
|---|---|
| 🟢 **FREE** | Read-only API calls, or local containers. No charge. |
| 🟡 **CHEAP** | A few cents to ~US$1 if you tear down the same day. |
| 🔴 **EXPENSIVE** | Dollars per hour. Read-only by default; create only if you mean it. |

Every creation block has a matching teardown in **Exercise 9**. Do Exercise 9. Orphaned RDS snapshots, unused Elastic IPs and idle Redshift workgroups are the three classic ways a lab account quietly bills you for a month.

Prices quoted below are illustrative for `us-east-1` and change. Always confirm at <https://aws.amazon.com/rds/pricing/> and <https://aws.amazon.com/dynamodb/pricing/>.

---

## Exercise 0 — Guardrails first 🟢 FREE

A production engineer sets the blast radius before opening the tool. Do the same here.

1. Confirm your CLI is v2 and recent enough to know the newer database APIs:

```bash
aws --version
```

Expected shape:

```
aws-cli/2.17.42 Python/3.11.9 linux/6.8.0 exe/x86_64.x86_64
```

2. Confirm *who* you are and *where* you are. Region matters: database service availability is not uniform.

```bash
aws sts get-caller-identity
aws configure get region
```

```json
{
    "UserId": "AIDA...EXAMPLE",
    "Account": "111122223333",
    "Arn": "arn:aws:iam::111122223333:user/clf-lab"
}
```

```
us-east-1
```

3. Pin the region for this whole session so no command silently lands somewhere else:

```bash
export AWS_REGION=us-east-1
export AWS_DEFAULT_REGION=us-east-1
```

4. Create a hard budget alarm before creating a single database. Replace the e-mail:

```bash
cat > /tmp/budget.json <<'JSON'
{
  "BudgetName": "clf34-lab-guard",
  "BudgetLimit": { "Amount": "10", "Unit": "USD" },
  "TimeUnit": "MONTHLY",
  "BudgetType": "COST"
}
JSON

cat > /tmp/notify.json <<'JSON'
[
  {
    "Notification": {
      "NotificationType": "ACTUAL",
      "ComparisonOperator": "GREATER_THAN",
      "Threshold": 50,
      "ThresholdType": "PERCENTAGE"
    },
    "Subscribers": [
      { "SubscriptionType": "EMAIL", "Address": "you@example.com" }
    ]
  }
]
JSON

aws budgets create-budget \
  --account-id "$(aws sts get-caller-identity --query Account --output text)" \
  --budget file:///tmp/budget.json \
  --notifications-with-subscribers file:///tmp/notify.json
```

A successful call returns an empty body (HTTP 200, no output). Verify:

```bash
aws budgets describe-budgets \
  --account-id "$(aws sts get-caller-identity --query Account --output text)" \
  --query 'Budgets[].{Name:BudgetName,Limit:BudgetLimit.Amount}' --output table
```

```
------------------------------
|      DescribeBudgets       |
+-----------------+----------+
|      Name       |  Limit   |
+-----------------+----------+
|  clf34-lab-guard|  10.0    |
+-----------------+----------+
```

5. Record the default VPC and two subnets in different Availability Zones — you will need them for RDS:

```bash
VPC_ID=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true \
  --query 'Vpcs[0].VpcId' --output text)
echo "VPC: $VPC_ID"

aws ec2 describe-subnets --filters Name=vpc-id,Values=$VPC_ID \
  --query 'Subnets[].{Subnet:SubnetId,AZ:AvailabilityZone}' --output table
```

```
--------------------------------------------
|              DescribeSubnets             |
+---------------+--------------------------+
|      AZ       |         Subnet           |
+---------------+--------------------------+
|  us-east-1a   |  subnet-0aa11bb22cc33dd44 |
|  us-east-1b   |  subnet-0ee55ff66gg77hh88 |
|  us-east-1c   |  subnet-0ii99jj00kk11ll22 |
+---------------+--------------------------+
```

> **Note on `describe-budgets`:** AWS Budgets is a global (billing) service. If the call fails with `AccessDeniedException`, your IAM principal lacks `budgets:*` — that is an IAM problem, not a region problem.

### ✅ Comprehension check — Block 0

**Q0.1** — Budgets and Cost Explorer are billing services with a *global* endpoint, yet you exported `AWS_REGION=us-east-1`. Why does the region export still matter for the rest of this lab?

**Q0.2** — You created a budget with an `ACTUAL > 50 %` notification. Does that notification stop AWS from charging you past US$10? What is the actual mechanism a budget provides, and what would you need to *enforce* a stop?

**Q0.3** — Why does an RDS DB subnet group require subnets in **at least two** Availability Zones, even if you intend to deploy a Single-AZ instance?

---

## Exercise 1 — Map the relational surface: what RDS actually offers 🟢 FREE

Before provisioning anything, learn to read the catalogue from the API instead of from a slide.

1. List every engine family RDS can manage:

```bash
aws rds describe-db-engine-versions \
  --query 'DBEngineVersions[].Engine' --output text | tr '\t' '\n' | sort -u
```

```
aurora-mysql
aurora-postgresql
custom-oracle-ee
db2-ae
db2-se
mariadb
mysql
oracle-ee
oracle-se2
postgres
sqlserver-ee
sqlserver-ex
sqlserver-se
sqlserver-web
```

2. Separate the two product lines hiding in that list. Anything starting with `aurora-` is **Amazon Aurora**; the rest is **Amazon RDS** running the community or vendor engine. Count them:

```bash
aws rds describe-db-engine-versions \
  --query 'DBEngineVersions[].Engine' --output text | tr '\t' '\n' | sort -u \
  | awk '/^aurora-/ {a++; next} /^custom-/ {c++; next} {r++} END {print "Aurora:",a," RDS Custom:",c," RDS standard:",r}'
```

```
Aurora: 2  RDS Custom: 1  RDS standard: 11
```

3. Find the newest default MySQL version — this is what you will provision:

```bash
aws rds describe-db-engine-versions --engine mysql \
  --query 'DBEngineVersions[?DBEngineVersionDescription!=null].EngineVersion' \
  --output text | tr '\t' '\n' | sort -V | tail -3
```

```
8.0.39
8.0.40
8.4.3
```

4. Ask which instance classes are actually orderable for that engine in your region, and which of them support Multi-AZ. This is the query that saves you a failed `create-db-instance` twenty minutes into a change window:

```bash
aws rds describe-orderable-db-instance-options \
  --engine mysql --engine-version 8.0.40 \
  --query 'OrderableDBInstanceOptions[?MultiAZCapable==`true`].DBInstanceClass' \
  --output text | tr '\t' '\n' | sort -u | head -8
```

```
db.m5.2xlarge
db.m5.large
db.m5.xlarge
db.m6g.large
db.r6g.large
db.t3.medium
db.t4g.micro
db.t4g.small
```

5. Now look at the same question for a vendor engine with licensing constraints:

```bash
aws rds describe-orderable-db-instance-options \
  --engine oracle-se2 \
  --query 'OrderableDBInstanceOptions[0].{Engine:Engine,Class:DBInstanceClass,License:LicenseModel,MultiAZ:MultiAZCapable}' \
  --output table
```

```
--------------------------------------------------------------
|             DescribeOrderableDBInstanceOptions              |
+-------------+--------------+---------------------+----------+
|    Class    |    Engine    |       License       | MultiAZ  |
+-------------+--------------+---------------------+----------+
|  db.m5.large|  oracle-se2  |  license-included   |  True    |
+-------------+--------------+---------------------+----------+
```

6. Inspect where the responsibility line sits. Ask RDS what it will *not* let you do — list the parameters you may change on a MySQL 8.0 parameter group:

```bash
aws rds describe-engine-default-parameters \
  --db-parameter-group-family mysql8.0 \
  --query 'EngineDefaults.Parameters[?IsModifiable==`false`].ParameterName' \
  --output text | tr '\t' '\n' | head -10
```

```
allow-suspicious-udfs
auto_generate_certs
basedir
bind_address
character_sets_dir
datadir
default_authentication_plugin
innodb_data_home_dir
innodb_log_group_home_dir
lc_messages_dir
```

Every one of those is a filesystem path or a process-level switch. That is the shared responsibility model expressed as an API: AWS owns the host, the OS and the data directory; you own schema, queries, indexes, users and the parameters that shape them.

**Sources:**
- Amazon RDS User Guide — <https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/Welcome.html>
- Shared Responsibility Model — <https://aws.amazon.com/compliance/shared-responsibility-model/>
- RDS Custom — <https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/rds-custom.html>

### ✅ Comprehension check — Block 1

**Q1.1** — `custom-oracle-ee` appeared in the engine list. What does **RDS Custom** give you that standard RDS does not, and what do you give up in exchange?

**Q1.2** — Step 6 showed `datadir` and `innodb_data_home_dir` as non-modifiable. Translate that into shared-responsibility language: name two tasks AWS performs for an RDS MySQL instance that you would perform yourself if MySQL ran on an EC2 instance.

**Q1.3** — The Oracle option reported `license-included`. What is the alternative licensing model on RDS, and in which situation would a company choose it?

**Q1.4** — `db.t4g.micro` and `db.r6g.large` both appear as MultiAZ-capable. What do the letters `t`, `m` and `r` signal about the instance family, and which would you pick for a memory-hungry reporting replica?

---

## Exercise 2 — Provision RDS Multi-AZ and read its anatomy 🟡 CHEAP

> **Cost:** a `db.t4g.micro` Multi-AZ MySQL instance with 20 GiB gp3 runs roughly **US$0.05–0.07/hour** plus storage. Under US$1 if you tear it down the same day. Free Tier covers *Single-AZ* `db.t4g.micro` only — Multi-AZ doubles the instance charge.

1. Create a DB subnet group spanning two AZs (substitute your subnet IDs from Exercise 0):

```bash
aws rds create-db-subnet-group \
  --db-subnet-group-name clf34-subnets \
  --db-subnet-group-description "CLF-C02 task 3.4 lab" \
  --subnet-ids subnet-0aa11bb22cc33dd44 subnet-0ee55ff66gg77hh88 \
  --query 'DBSubnetGroup.{Name:DBSubnetGroupName,VPC:VpcId,AZs:Subnets[].SubnetAvailabilityZone.Name}'
```

```json
{
    "Name": "clf34-subnets",
    "VPC": "vpc-0abc123def4567890",
    "AZs": [ "us-east-1a", "us-east-1b" ]
}
```

2. Create a security group that grants **nothing**. A database that is reachable from the internet is a finding, not a lab shortcut:

```bash
SG_ID=$(aws ec2 create-security-group \
  --group-name clf34-db-sg \
  --description "CLF 3.4 lab - no ingress by design" \
  --vpc-id "$VPC_ID" --query GroupId --output text)
echo "SG: $SG_ID"
```

3. Provision the instance. Read every flag before pressing Enter — each one is an exam concept:

```bash
aws rds create-db-instance \
  --db-instance-identifier clf34-mysql \
  --db-instance-class db.t4g.micro \
  --engine mysql \
  --engine-version 8.0.40 \
  --allocated-storage 20 \
  --storage-type gp3 \
  --master-username admin \
  --manage-master-user-password \
  --db-subnet-group-name clf34-subnets \
  --vpc-security-group-ids "$SG_ID" \
  --multi-az \
  --no-publicly-accessible \
  --storage-encrypted \
  --backup-retention-period 7 \
  --preferred-backup-window 07:00-08:00 \
  --preferred-maintenance-window Sun:09:00-Sun:10:00 \
  --deletion-protection \
  --copy-tags-to-snapshot \
  --tags Key=Project,Value=clf34-lab \
  --query 'DBInstance.{Id:DBInstanceIdentifier,Status:DBInstanceStatus,MultiAZ:MultiAZ,Encrypted:StorageEncrypted}'
```

```json
{
    "Id": "clf34-mysql",
    "Status": "creating",
    "MultiAZ": true,
    "Encrypted": true
}
```

4. Wait. Multi-AZ creation takes roughly 10–15 minutes because AWS builds two instances and synchronises them:

```bash
time aws rds wait db-instance-available --db-instance-identifier clf34-mysql
```

```
real    11m48.302s
```

5. Read the anatomy of what you built:

```bash
aws rds describe-db-instances --db-instance-identifier clf34-mysql \
  --query 'DBInstances[0].{Endpoint:Endpoint.Address,Port:Endpoint.Port,PrimaryAZ:AvailabilityZone,StandbyAZ:SecondaryAvailabilityZone,MultiAZ:MultiAZ,Class:DBInstanceClass,Backup:BackupRetentionPeriod,SecretArn:MasterUserSecret.SecretArn}' \
  --output json
```

```json
{
    "Endpoint": "clf34-mysql.cabcd1efghij.us-east-1.rds.amazonaws.com",
    "Port": 3306,
    "PrimaryAZ": "us-east-1a",
    "StandbyAZ": "us-east-1b",
    "MultiAZ": true,
    "Class": "db.t4g.micro",
    "Backup": 7,
    "SecretArn": "arn:aws:secretsmanager:us-east-1:111122223333:secret:rds!db-1a2b3c4d-AbCdEf"
}
```

Notice: **one endpoint, two AZs**. The standby has no endpoint of its own and serves no traffic. Notice also that `--manage-master-user-password` produced a Secrets Manager ARN — the password was never typed, never landed in your shell history, and rotates on a schedule.

6. Observe the failover mechanism. Force one and watch the AZ swap:

```bash
aws rds describe-db-instances --db-instance-identifier clf34-mysql \
  --query 'DBInstances[0].AvailabilityZone' --output text

aws rds reboot-db-instance \
  --db-instance-identifier clf34-mysql --force-failover \
  --query 'DBInstance.DBInstanceStatus' --output text

aws rds wait db-instance-available --db-instance-identifier clf34-mysql

aws rds describe-db-instances --db-instance-identifier clf34-mysql \
  --query 'DBInstances[0].{AZ:AvailabilityZone,Standby:SecondaryAvailabilityZone}' --output json
```

```
us-east-1a
rebooting
```
```json
{
    "AZ": "us-east-1b",
    "Standby": "us-east-1a"
}
```

7. Confirm the endpoint DNS name did **not** change:

```bash
aws rds describe-db-instances --db-instance-identifier clf34-mysql \
  --query 'DBInstances[0].Endpoint.Address' --output text
```

```
clf34-mysql.cabcd1efghij.us-east-1.rds.amazonaws.com
```

Same name, new AZ, new underlying host. RDS repointed the DNS CNAME. Applications reconnect; they do not reconfigure.

8. Confirm AWS recorded the failover as an event:

```bash
aws rds describe-events \
  --source-identifier clf34-mysql --source-type db-instance \
  --duration 30 --query 'Events[].{At:Date,Msg:Message}' --output table
```

```
--------------------------------------------------------------------------------------
|                                   DescribeEvents                                   |
+----------------------------+-------------------------------------------------------+
|             At             |                         Msg                           |
+----------------------------+-------------------------------------------------------+
|  2026-09-04T14:02:11.421Z  |  Multi-AZ instance failover started.                  |
|  2026-09-04T14:03:38.907Z  |  DB instance restarted                                |
|  2026-09-04T14:03:41.115Z  |  Multi-AZ instance failover completed                 |
+----------------------------+-------------------------------------------------------+
```

9. Add a **read replica** — a different mechanism entirely, for a different problem:

```bash
aws rds create-db-instance-read-replica \
  --db-instance-identifier clf34-mysql-ro \
  --source-db-instance-identifier clf34-mysql \
  --db-instance-class db.t4g.micro \
  --no-publicly-accessible \
  --tags Key=Project,Value=clf34-lab \
  --query 'DBInstance.{Id:DBInstanceIdentifier,Status:DBInstanceStatus,Source:ReadReplicaSourceDBInstanceIdentifier}'
```

```json
{
    "Id": "clf34-mysql-ro",
    "Status": "creating",
    "Source": "clf34-mysql"
}
```

10. Once available, compare the two objects side by side:

```bash
aws rds wait db-instance-available --db-instance-identifier clf34-mysql-ro

aws rds describe-db-instances \
  --query 'DBInstances[?starts_with(DBInstanceIdentifier,`clf34-mysql`)].{Id:DBInstanceIdentifier,Endpoint:Endpoint.Address,MultiAZ:MultiAZ,Replica:ReadReplicaSourceDBInstanceIdentifier}' \
  --output table
```

```
-------------------------------------------------------------------------------------------------------
|                                        DescribeDBInstances                                          |
+------------------------------------------------------------+-----------------+----------+-----------+
|                          Endpoint                           |       Id        | MultiAZ  | Replica   |
+------------------------------------------------------------+-----------------+----------+-----------+
|  clf34-mysql.cabcd1efghij.us-east-1.rds.amazonaws.com       |  clf34-mysql    |  True    |  None     |
|  clf34-mysql-ro.cabcd1efghij.us-east-1.rds.amazonaws.com    |  clf34-mysql-ro |  False   | clf34-mysql|
+------------------------------------------------------------+-----------------+----------+-----------+
|
```

**The distinction the exam tests:** the standby is invisible and synchronous (high availability). The read replica has its own endpoint and is asynchronous (read scaling). They solve different problems and you can, and often should, run both.

11. Inspect the backup layer. Automated backups and manual snapshots are not the same object:

```bash
aws rds describe-db-instance-automated-backups \
  --db-instance-identifier clf34-mysql \
  --query 'DBInstanceAutomatedBackups[0].{Retention:BackupRetentionPeriod,EarliestRestore:RestoreWindow.EarliestTime,LatestRestore:RestoreWindow.LatestTime}'
```

```json
{
    "Retention": 7,
    "EarliestRestore": "2026-09-04T14:21:00+00:00",
    "LatestRestore": "2026-09-04T14:47:00+00:00"
}
```

12. Take a manual snapshot and note that it has no retention period at all:

```bash
aws rds create-db-snapshot \
  --db-instance-identifier clf34-mysql \
  --db-snapshot-identifier clf34-mysql-manual-01 \
  --query 'DBSnapshot.{Id:DBSnapshotIdentifier,Type:SnapshotType,Status:Status}'
```

```json
{
    "Id": "clf34-mysql-manual-01",
    "Type": "manual",
    "Status": "creating"
}
```

**Sources:**
- Multi-AZ deployments — <https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/Concepts.MultiAZ.html>
- Read replicas — <https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_ReadRepl.html>
- Automated backups & PITR — <https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_WorkingWithAutomatedBackups.html>
- Master user password management — <https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/rds-secrets-manager.html>

### ✅ Comprehension check — Block 2

**Q2.1** — In step 5 the standby in `us-east-1b` had no endpoint. Your CTO asks: "we're paying for two instances — can we send reporting queries to the standby?" Answer, and name the correct service feature for that requirement.

**Q2.2** — After the forced failover the endpoint DNS name was unchanged. Explain the mechanism, and explain why an application with a very long JVM DNS cache TTL might still fail for minutes after a successful failover.

**Q2.3** — A Multi-AZ deployment replicates **synchronously**; a read replica replicates **asynchronously**. State the consequence of each for (a) data loss on failure and (b) query latency on the primary.

**Q2.4** — You set `--backup-retention-period 7`. A developer drops a table at 14:32 and reports it at 15:10. Which recovery mechanism do you use, what is the finest granularity you can restore to, and does the restore overwrite `clf34-mysql`?

**Q2.5** — Automated backups are deleted when you delete the instance (unless retained); manual snapshots are not. Which of the two is the cost risk in a lab account, and why?

**Q2.6** — Multi-AZ protects against an AZ failure. Name two failure modes it does **not** protect against, and the AWS feature that addresses each.

---

## Exercise 3 — Aurora: the same SQL, a different machine underneath 🟡 CHEAP

> **Cost:** Aurora Serverless v2 at 0.5 ACU minimum is roughly **US$0.06/hour** plus storage and I/O. Tear down the same day.

Aurora is **not** "RDS with a bigger instance". It replaces the storage engine with a purpose-built distributed log-structured layer, and it splits the object model: a **cluster** owns the storage; **instances** are compute that attaches to it.

1. Create the cluster. Note there is no `--allocated-storage`: Aurora storage grows automatically in 10 GiB increments up to 128 TiB.

```bash
aws rds create-db-cluster \
  --db-cluster-identifier clf34-aurora \
  --engine aurora-postgresql \
  --engine-version 16.4 \
  --master-username postgres \
  --manage-master-user-password \
  --db-subnet-group-name clf34-subnets \
  --vpc-security-group-ids "$SG_ID" \
  --storage-encrypted \
  --backup-retention-period 7 \
  --serverless-v2-scaling-configuration MinCapacity=0.5,MaxCapacity=4 \
  --tags Key=Project,Value=clf34-lab \
  --query 'DBCluster.{Id:DBClusterIdentifier,Status:Status,Engine:Engine,Storage:StorageType}'
```

```json
{
    "Id": "clf34-aurora",
    "Status": "creating",
    "Engine": "aurora-postgresql",
    "Storage": "aurora"
}
```

2. Notice that the cluster alone is useless — it has endpoints but nothing to serve them. Attach a writer instance:

```bash
aws rds create-db-instance \
  --db-instance-identifier clf34-aurora-1 \
  --db-cluster-identifier clf34-aurora \
  --engine aurora-postgresql \
  --db-instance-class db.serverless \
  --query 'DBInstance.{Id:DBInstanceIdentifier,Class:DBInstanceClass,Cluster:DBClusterIdentifier}'
```

```json
{
    "Id": "clf34-aurora-1",
    "Class": "db.serverless",
    "Cluster": "clf34-aurora"
}
```

3. Add a reader in a second AZ. On Aurora this is *not* a copy of the data — it attaches to the **same** shared storage volume:

```bash
aws rds create-db-instance \
  --db-instance-identifier clf34-aurora-2 \
  --db-cluster-identifier clf34-aurora \
  --engine aurora-postgresql \
  --db-instance-class db.serverless \
  --promotion-tier 1 \
  --query 'DBInstance.DBInstanceIdentifier' --output text
```

```
clf34-aurora-2
```

4. Wait, then read the endpoint model — this is the single most testable Aurora fact:

```bash
aws rds wait db-instance-available --db-instance-identifier clf34-aurora-1
aws rds wait db-instance-available --db-instance-identifier clf34-aurora-2

aws rds describe-db-clusters --db-cluster-identifier clf34-aurora \
  --query 'DBClusters[0].{Writer:Endpoint,Reader:ReaderEndpoint,Port:Port,Members:DBClusterMembers[].{Id:DBInstanceIdentifier,IsWriter:IsClusterWriter,Tier:PromotionTier}}' \
  --output json
```

```json
{
    "Writer": "clf34-aurora.cluster-cabcd1efghij.us-east-1.rds.amazonaws.com",
    "Reader": "clf34-aurora.cluster-ro-cabcd1efghij.us-east-1.rds.amazonaws.com",
    "Port": 5432,
    "Members": [
        { "Id": "clf34-aurora-1", "IsWriter": true,  "Tier": 1 },
        { "Id": "clf34-aurora-2", "IsWriter": false, "Tier": 1 }
    ]
}
```

Three endpoint kinds exist: **cluster** (always the writer), **reader** (DNS round-robin across readers), and **instance** (one specific node — use it only for diagnostics, never in application config).

5. Prove the shared-storage claim. Ask for the cluster's storage volume size and compare to the sum of per-instance storage:

```bash
aws rds describe-db-clusters --db-cluster-identifier clf34-aurora \
  --query 'DBClusters[0].{AllocatedStorage:AllocatedStorage,AZs:AvailabilityZones}' --output json
```

```json
{
    "AllocatedStorage": 1,
    "AZs": [ "us-east-1a", "us-east-1b", "us-east-1c" ]
}
```

The cluster lists three AZs although you only put instances in two. Aurora maintains **six copies of every data block across three AZs**, independent of how many compute instances you run. Storage durability is decoupled from compute.

6. Trigger a failover and time it. Because the reader already has the storage attached, promotion is a control-plane operation, not a data copy:

```bash
date +%T
aws rds failover-db-cluster --db-cluster-identifier clf34-aurora \
  --target-db-instance-identifier clf34-aurora-2 \
  --query 'DBCluster.Status' --output text

aws rds wait db-cluster-available --db-cluster-identifier clf34-aurora
date +%T

aws rds describe-db-clusters --db-cluster-identifier clf34-aurora \
  --query 'DBClusters[0].DBClusterMembers[?IsClusterWriter==`true`].DBInstanceIdentifier' --output text
```

```
14:58:02
failing-over
14:58:35
clf34-aurora-2
```

Roughly **30 seconds**, against the ~1–2 minutes typical of an RDS Multi-AZ instance failover.

7. Watch Serverless v2 capacity. ACUs scale in 0.5 increments; each ACU is ~2 GiB of memory with matched CPU and network:

```bash
aws rds describe-db-clusters --db-cluster-identifier clf34-aurora \
  --query 'DBClusters[0].ServerlessV2ScalingConfiguration' --output json
```

```json
{
    "MinCapacity": 0.5,
    "MaxCapacity": 4.0
}
```

**Sources:**
- Aurora overview — <https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/CHAP_AuroraOverview.html>
- Aurora endpoints — <https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/Aurora.Overview.Endpoints.html>
- Aurora Serverless v2 — <https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/aurora-serverless-v2.html>
- Aurora Global Database — <https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/aurora-global-database.html>

### ✅ Comprehension check — Block 3

**Q3.1** — You created a cluster with two instances but `AllocatedStorage` reported a single small number and three AZs. Explain Aurora's storage architecture in one sentence, and say how many copies of each block exist and across how many AZs.

**Q3.2** — An RDS Multi-AZ standby cannot serve reads; an Aurora replica can. Why is that architecturally possible on Aurora and not on RDS?

**Q3.3** — Aurora failover took ~30 s versus ~60–120 s for RDS Multi-AZ. Give the architectural reason, not just the number.

**Q3.4** — Name the three Aurora endpoint types and state which one an application's connection string should normally use for (a) writes and (b) reporting reads.

**Q3.5** — A customer runs a development database used two hours a day. Compare **Aurora Serverless v2** and a provisioned `db.r6g.large` Aurora instance for this workload on cost and on cold-start behaviour.

**Q3.6** — A global retailer needs sub-second read latency in Europe and the Americas, with a documented cross-region RPO. Which Aurora feature applies, and what does it replicate?

---

## Exercise 4 — DynamoDB: pay for shape, not for servers 🟡 CHEAP

> **Cost:** on-demand mode with a handful of items costs fractions of a cent. Effectively free at lab scale.

1. Create a table with a **composite primary key** — partition key plus sort key. This is a modelling decision, and on DynamoDB it is close to irreversible:

```bash
aws dynamodb create-table \
  --table-name clf34-orders \
  --attribute-definitions \
      AttributeName=customerId,AttributeType=S \
      AttributeName=orderTs,AttributeType=S \
  --key-schema \
      AttributeName=customerId,KeyType=HASH \
      AttributeName=orderTs,KeyType=RANGE \
  --billing-mode PAY_PER_REQUEST \
  --sse-specification Enabled=true \
  --tags Key=Project,Value=clf34-lab \
  --query 'TableDescription.{Name:TableName,Status:TableStatus,Billing:BillingModeSummary.BillingMode}'
```

```json
{
    "Name": "clf34-orders",
    "Status": "CREATING",
    "Billing": "PAY_PER_REQUEST"
}
```

2. Note the creation time and contrast it with Exercise 2:

```bash
time aws dynamodb wait table-exists --table-name clf34-orders
```

```
real    0m10.412s
```

Eleven minutes for a Multi-AZ RDS instance; ten seconds for a DynamoDB table. You did not choose an instance class, a storage size, an AZ or a VPC — because there is no instance. Multi-AZ replication across three AZs is not an option you enable; it is the default and only behaviour.

3. Write three items. DynamoDB is schemaless beyond the key attributes — item 3 carries a field the others do not:

```bash
aws dynamodb put-item --table-name clf34-orders --item '{
  "customerId": {"S": "CUST#1001"},
  "orderTs":    {"S": "2026-09-01T10:15:00Z"},
  "total":      {"N": "149.90"},
  "status":     {"S": "SHIPPED"}
}'

aws dynamodb put-item --table-name clf34-orders --item '{
  "customerId": {"S": "CUST#1001"},
  "orderTs":    {"S": "2026-09-03T18:40:00Z"},
  "total":      {"N": "22.50"},
  "status":     {"S": "PENDING"}
}'

aws dynamodb put-item --table-name clf34-orders --item '{
  "customerId": {"S": "CUST#2002"},
  "orderTs":    {"S": "2026-09-02T09:00:00Z"},
  "total":      {"N": "980.00"},
  "status":     {"S": "PENDING"},
  "giftWrap":   {"BOOL": true}
}'
```

(Successful `put-item` calls return no output.)

4. **Query** — the efficient access pattern. It reads only the partition you name:

```bash
aws dynamodb query --table-name clf34-orders \
  --key-condition-expression "customerId = :c" \
  --expression-attribute-values '{":c": {"S": "CUST#1001"}}' \
  --return-consumed-capacity TOTAL \
  --query '{Count:Count,Scanned:ScannedCount,RCU:ConsumedCapacity.CapacityUnits}'
```

```json
{
    "Count": 2,
    "Scanned": 2,
    "RCU": 0.5
}
```

5. **Scan** — the pattern that does not survive production. It reads every item in the table and then filters:

```bash
aws dynamodb scan --table-name clf34-orders \
  --filter-expression "#s = :st" \
  --expression-attribute-names '{"#s": "status"}' \
  --expression-attribute-values '{":st": {"S": "PENDING"}}' \
  --return-consumed-capacity TOTAL \
  --query '{Count:Count,Scanned:ScannedCount,RCU:ConsumedCapacity.CapacityUnits}'
```

```json
{
    "Count": 2,
    "Scanned": 3,
    "RCU": 0.5
}
```

`Scanned: 3` against `Count: 2` is the tell. At three items it is invisible; at thirty million items you have just read and paid for the whole table to return two rows. **You are billed on `ScannedCount`, not on `Count`.**

6. Measure the price of consistency directly. Run the same `get-item` twice, changing only the consistency flag:

```bash
aws dynamodb get-item --table-name clf34-orders \
  --key '{"customerId":{"S":"CUST#1001"},"orderTs":{"S":"2026-09-01T10:15:00Z"}}' \
  --return-consumed-capacity TOTAL \
  --query 'ConsumedCapacity.CapacityUnits'

aws dynamodb get-item --table-name clf34-orders \
  --key '{"customerId":{"S":"CUST#1001"},"orderTs":{"S":"2026-09-01T10:15:00Z"}}' \
  --consistent-read \
  --return-consumed-capacity TOTAL \
  --query 'ConsumedCapacity.CapacityUnits'
```

```
0.5
1.0
```

Exactly double. An eventually consistent read costs 0.5 RCU per 4 KB; a strongly consistent read costs 1 RCU. That number is the direct billing consequence of DynamoDB replicating synchronously to three AZs and letting you choose whether to wait for the quorum.

7. Add a **Global Secondary Index** to support a query pattern the base key cannot serve — "all orders by status":

```bash
aws dynamodb update-table --table-name clf34-orders \
  --attribute-definitions AttributeName=status,AttributeType=S AttributeName=orderTs,AttributeType=S \
  --global-secondary-index-updates '[{
    "Create": {
      "IndexName": "status-orderTs-index",
      "KeySchema": [
        {"AttributeName": "status", "KeyType": "HASH"},
        {"AttributeName": "orderTs", "KeyType": "RANGE"}
      ],
      "Projection": {"ProjectionType": "ALL"}
    }
  }]' \
  --query 'TableDescription.GlobalSecondaryIndexes[0].{Index:IndexName,Status:IndexStatus}'
```

```json
{
    "Index": "status-orderTs-index",
    "Status": "CREATING"
}
```

8. Once `ACTIVE`, run the query the scan could not do efficiently:

```bash
aws dynamodb query --table-name clf34-orders \
  --index-name status-orderTs-index \
  --key-condition-expression "#s = :st" \
  --expression-attribute-names '{"#s": "status"}' \
  --expression-attribute-values '{":st": {"S": "PENDING"}}' \
  --return-consumed-capacity TOTAL \
  --query '{Count:Count,Scanned:ScannedCount,RCU:ConsumedCapacity.CapacityUnits}'
```

```json
{
    "Count": 2,
    "Scanned": 2,
    "RCU": 0.5
}
```

`Scanned` now equals `Count`. The access pattern drives the index; the index does not rescue a bad access pattern.

9. Enable the two data-protection features you should treat as defaults:

```bash
aws dynamodb update-continuous-backups --table-name clf34-orders \
  --point-in-time-recovery-specification PointInTimeRecoveryEnabled=true \
  --query 'ContinuousBackupsDescription.PointInTimeRecoveryDescription.PointInTimeRecoveryStatus' --output text

aws dynamodb update-time-to-live --table-name clf34-orders \
  --time-to-live-specification "Enabled=true, AttributeName=expiresAt" \
  --query 'TimeToLiveSpecification' --output json
```

```
ENABLED
```
```json
{
    "Enabled": true,
    "AttributeName": "expiresAt"
}
```

PITR gives you second-level restore over a 35-day window. TTL deletes expired items with **no write cost** — the cheapest data-retention policy AWS sells.

10. Inspect what on-demand mode did to the capacity fields:

```bash
aws dynamodb describe-table --table-name clf34-orders \
  --query 'Table.{Billing:BillingModeSummary.BillingMode,RCU:ProvisionedThroughput.ReadCapacityUnits,WCU:ProvisionedThroughput.WriteCapacityUnits,Size:TableSizeBytes,Items:ItemCount}'
```

```json
{
    "Billing": "PAY_PER_REQUEST",
    "RCU": 0,
    "WCU": 0,
    "Size": 0,
    "Items": 0
}
```

> `TableSizeBytes` and `ItemCount` update on a roughly six-hour cycle. Zero here is expected metadata lag, not missing data — `scan` already returned your three items.

**Sources:**
- DynamoDB developer guide — <https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/Introduction.html>
- Read consistency — <https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/HowItWorks.ReadConsistency.html>
- Global secondary indexes — <https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/GSI.html>
- Time to Live — <https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/TTL.html>
- DAX — <https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/DAX.html>
- Global tables — <https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/GlobalTables.html>

### ✅ Comprehension check — Block 4

**Q4.1** — The table was `ACTIVE` in ten seconds and you never chose an AZ, a VPC or an instance class. What does that tell you about DynamoDB's position on the managed↔serverless spectrum relative to RDS, and what disappears from your operational responsibility?

**Q4.2** — In step 5, `ScannedCount` (3) exceeded `Count` (2). Which number are you billed on, and what is the production consequence at 30 million items?

**Q4.3** — Step 6 measured 0.5 RCU vs 1.0 RCU. Explain *why* strong consistency costs double, in terms of what DynamoDB does with the three replicas.

**Q4.4** — A GSI has its own partition key and its own capacity. Name one thing a GSI can do that a Local Secondary Index cannot, and one constraint an LSI has that a GSI does not.

**Q4.5** — DynamoDB reads are already single-digit milliseconds. When does adding **DAX** make sense, and what latency does it target?

**Q4.6** — Distinguish **DynamoDB global tables** from **Aurora Global Database** on write topology.

**Q4.7** — Both PITR and on-demand backups exist for DynamoDB. Which one satisfies "restore to any second in the last 35 days", and which satisfies "keep a copy of this table for seven years for the auditor"?

---

## Exercise 5 — Caching: ElastiCache, MemoryDB, and the pattern that matters 🟢 FREE

We will demonstrate the **cache-aside** pattern locally with Redis in a container — identical semantics to ElastiCache, zero cost — and inspect the AWS surface read-only.

1. Inspect what ElastiCache actually offers today:

```bash
aws elasticache describe-cache-engine-versions \
  --query 'CacheEngineVersions[].Engine' --output text | tr '\t' '\n' | sort -u
```

```
memcached
redis
valkey
```

2. Look at one concrete difference in the engines' feature surface:

```bash
aws elasticache describe-cache-engine-versions --engine memcached \
  --query 'CacheEngineVersions[-1].{Engine:Engine,Version:EngineVersion,ParamFamily:CacheParameterGroupFamily}' --output json

aws elasticache describe-cache-engine-versions --engine valkey \
  --query 'CacheEngineVersions[-1].{Engine:Engine,Version:EngineVersion,ParamFamily:CacheParameterGroupFamily}' --output json
```

```json
{ "Engine": "memcached", "Version": "1.6.22", "ParamFamily": "memcached1.6" }
```
```json
{ "Engine": "valkey", "Version": "8.0", "ParamFamily": "valkey8" }
```

3. Run Redis locally to demonstrate cache-aside:

```bash
docker run -d --name clf34-cache -p 6379:6379 redis:7-alpine
docker exec -it clf34-cache redis-cli PING
```

```
PONG
```

4. Simulate a cache **miss** followed by a database read and a cache fill, with a TTL:

```bash
docker exec clf34-cache redis-cli GET "order:CUST#1001:2026-09-01"
docker exec clf34-cache redis-cli SETEX "order:CUST#1001:2026-09-01" 300 '{"total":149.90,"status":"SHIPPED"}'
docker exec clf34-cache redis-cli GET "order:CUST#1001:2026-09-01"
docker exec clf34-cache redis-cli TTL "order:CUST#1001:2026-09-01"
```

```

OK
{"total":149.90,"status":"SHIPPED"}
297
```

The first `GET` returned empty — a miss. Your application would then read the source of truth (RDS or DynamoDB), write the result to the cache with a TTL, and return it. Every subsequent request for 300 seconds is served from memory without touching the database.

5. Demonstrate why the TTL is a correctness decision, not a tuning knob. Update the "database" but not the cache:

```bash
docker exec clf34-cache redis-cli GET "order:CUST#1001:2026-09-01"
# ...meanwhile the order ships and the DB row changes to DELIVERED...
docker exec clf34-cache redis-cli GET "order:CUST#1001:2026-09-01"
```

```
{"total":149.90,"status":"SHIPPED"}
{"total":149.90,"status":"SHIPPED"}
```

The cache is now serving a stale answer, and will keep doing so until the TTL expires or the application invalidates the key on write. That window is the price of the cache, and it is the reason a cache is unsuitable as a system of record.

6. Prove that a cache is not durable storage:

```bash
docker restart clf34-cache
sleep 3
docker exec clf34-cache redis-cli GET "order:CUST#1001:2026-09-01"
docker exec clf34-cache redis-cli DBSIZE
```

```

(integer) 0
```

Everything is gone. **This is the single fact that separates ElastiCache from MemoryDB.** MemoryDB persists every write to a Multi-AZ transactional log before acknowledging it, which makes it a durable primary database with in-memory speed — and prices it accordingly.

7. Clean up the container:

```bash
docker rm -f clf34-cache
```

**Sources:**
- ElastiCache — <https://docs.aws.amazon.com/AmazonElastiCache/latest/dg/WhatIs.html>
- Caching strategies — <https://docs.aws.amazon.com/AmazonElastiCache/latest/dg/Strategies.html>
- Amazon MemoryDB — <https://docs.aws.amazon.com/memorydb/latest/devguide/what-is-memorydb.html>

### ✅ Comprehension check — Block 5

**Q5.1** — Step 6 emptied the cache on restart. State the one-line difference between **ElastiCache** and **MemoryDB**, and give a workload for each.

**Q5.2** — Contrast **Memcached** and **Redis/Valkey** on ElastiCache across: data structures, replication, and multi-threading. Which would you pick for a leaderboard, and why?

**Q5.3** — In step 5 the cache served stale data. Name the caching strategy you used, name one alternative strategy, and state the trade-off between them.

**Q5.4** — Your RDS primary is at 95 % CPU serving the same product-catalogue query thousands of times per second. Compare adding a **read replica** against adding **ElastiCache**. Which addresses the root cause, and what does the other one give you?

**Q5.5** — Is ElastiCache a database service on the CLF-C02 exam guide, or a caching service? Why does the distinction matter when a question asks for "the system of record"?

---

## Exercise 6 — Purpose-built engines: match the data model, not the brand 🟢 FREE

AWS's position is that the relational model is one option among many, and that choosing the wrong data model costs more than choosing the wrong instance size. This block is read-only.

1. Confirm each purpose-built engine exists and is reachable in your region:

```bash
aws neptune describe-db-engine-versions \
  --query 'DBEngineVersions[-1].{Engine:Engine,Version:EngineVersion}' --output json

aws docdb describe-db-engine-versions \
  --query 'DBEngineVersions[-1].{Engine:Engine,Version:EngineVersion}' --output json

aws keyspaces list-keyspaces \
  --query 'keyspaces[].keyspaceName' --output text

aws timestream-write describe-endpoints \
  --query 'Endpoints[0].Address' --output text
```

```json
{ "Engine": "neptune", "Version": "1.3.4.0" }
```
```json
{ "Engine": "docdb", "Version": "5.0.0" }
```
```
system  system_schema  system_multiregion_info
```
```
ingest-cell1.timestream.us-east-1.amazonaws.com
```

Note that `keyspaces` already returned system keyspaces without you creating anything: Amazon Keyspaces is serverless, with no cluster to provision.

2. Observe the family resemblance. Neptune and DocumentDB expose the *same* control-plane shape as Aurora — clusters, instances, cluster endpoints — because they are built on the same distributed storage layer:

```bash
aws docdb describe-orderable-db-instance-options --engine docdb \
  --query 'OrderableDBInstanceOptions[0].{Engine:Engine,Class:DBInstanceClass,Storage:StorageType}' --output json
```

```json
{ "Engine": "docdb", "Class": "db.r6g.large", "Storage": "aurora" }
```

`"Storage": "aurora"` on a DocumentDB instance is the architecture leaking through the API.

3. Check the Redshift surface without provisioning anything:

```bash
aws redshift describe-cluster-versions \
  --query 'ClusterVersions[-1].{Version:ClusterVersion,Description:Description}' --output json

aws redshift-serverless list-workgroups \
  --query 'workgroups[].{Name:workgroupName,Status:status,RPU:baseCapacity}' --output table
```

```json
{ "Version": "1.0", "Description": "Cluster version 1.0" }
```
```
-----------------------------------------
|            ListWorkgroups             |
+------+----------+---------------------+
| Name | Status   |        RPU          |
+------+----------+---------------------+
+------+----------+---------------------+
```

Empty, as expected — you have provisioned nothing.

> 🔴 **Do not create a Redshift Serverless workgroup casually.** Minimum base capacity is 8 RPUs at roughly US$0.375/RPU-hour ≈ **US$3/hour**. A weekend of forgetting costs about US$150. Redshift is a data warehouse sized for terabyte scans; it has no "micro" tier.

4. Inspect the migration toolchain:

```bash
aws dms describe-endpoint-types \
  --query 'SupportedEndpointTypes[].EngineName' --output text | tr '\t' '\n' | sort -u | head -14
```

```
aurora
aurora-postgresql
azuredb
db2
docdb
dynamodb
kafka
kinesis
mariadb
mongodb
mysql
opensearch
oracle
postgres
```

Note `dynamodb`, `kinesis` and `opensearch` in that list: DMS moves data between *different* engine families, not merely between two copies of the same one.

5. Build the decision table yourself. Fill in the middle column before reading the answers:

| Workload description | Service | Why |
|---|---|---|
| Order-entry system, ACID transactions, joins, existing PostgreSQL app | ? | |
| Same, but needs 5× the throughput and a 30 s failover SLO | ? | |
| Shopping-cart and session state, single-digit ms, unpredictable spikes | ? | |
| BI dashboards scanning 4 TB of historical sales | ? | |
| Fraud detection: "which accounts are within 3 hops of this device?" | ? | |
| IoT fleet: 200 000 sensors writing metrics every 10 s, queried by time range | ? | |
| Lift-and-shift of a self-hosted MongoDB 5.0 application | ? | |
| Lift-and-shift of a self-hosted Apache Cassandra application | ? | |
| Redis-compatible store that is the **system of record**, must not lose writes | ? | |
| Product-page cache in front of an over-loaded RDS instance | ? | |
| Oracle database that needs OS-level access for a vendor agent | ? | |
| Ad-hoc SQL over compressed logs already sitting in Amazon S3 | ? | |

**Sources:**
- Amazon Neptune — <https://docs.aws.amazon.com/neptune/latest/userguide/intro.html>
- Amazon DocumentDB — <https://docs.aws.amazon.com/documentdb/latest/developerguide/what-is.html>
- Amazon Keyspaces — <https://docs.aws.amazon.com/keyspaces/latest/devguide/what-is-keyspaces.html>
- Amazon Timestream — <https://docs.aws.amazon.com/timestream/latest/developerguide/what-is-timestream.html>
- Amazon Redshift — <https://docs.aws.amazon.com/redshift/latest/mgmt/welcome.html>
- Redshift Serverless — <https://docs.aws.amazon.com/redshift/latest/mgmt/serverless-whatis.html>
- AWS DMS — <https://docs.aws.amazon.com/dms/latest/userguide/Welcome.html>

### ✅ Comprehension check — Block 6

**Q6.1** — DocumentDB reported `"StorageType": "aurora"`. What does that reveal, and what does it imply about DocumentDB's availability characteristics?

**Q6.2** — Neptune supports three query languages. Name them, and give the one graph question a relational database answers badly.

**Q6.3** — RDS/Aurora are OLTP; Redshift is OLAP. Give the storage-layout reason (one word each) and explain why it makes each one bad at the other's job.

**Q6.4** — Amazon Athena also runs SQL. Why is Athena **not** a database service, and when would you choose it over loading the data into Redshift?

**Q6.5** — Keyspaces returned system keyspaces immediately with nothing provisioned. What operational property does that demonstrate, and which other database service in this topic shares it?

**Q6.6** — Amazon QLDB appears in older CLF-C02 study material. What was it for, and what is its current status? What should you do if you see it in a practice question?

---

## Exercise 7 — Migration: DMS, SCT, and the two directions of "move" 🟢 FREE

1. See what a replication instance would cost you in sizing terms:

```bash
aws dms describe-orderable-replication-instances \
  --query 'OrderableReplicationInstances[?contains(ReplicationInstanceClass,`t3`)].{Class:ReplicationInstanceClass,MinStorage:MinAllocatedStorageGB,MaxStorage:MaxAllocatedStorageGB,AZ:AvailabilityZone}' \
  --output table
```

```
------------------------------------------------------------------------
|                 DescribeOrderableReplicationInstances                |
+------------+-------------+--------------+---------------------------+
|   Class    | MaxStorage  |  MinStorage  |            AZ             |
+------------+-------------+--------------+---------------------------+
|  dms.t3.micro  |  6000   |      5       |  us-east-1a               |
|  dms.t3.small  |  6000   |      5       |  us-east-1a               |
|  dms.t3.medium |  6000   |      5       |  us-east-1a               |
|  dms.t3.large  |  6000   |      5       |  us-east-1a               |
+------------+-------------+--------------+---------------------------+
```

2. Classify the two migration shapes. Run this against the endpoint-type list from Exercise 6 and reason about the pairs:

```bash
aws dms describe-endpoint-types \
  --query 'SupportedEndpointTypes[?EngineName==`oracle` || EngineName==`postgres`].{Engine:EngineName,Type:EndpointType,SupportsCDC:SupportsCDC}' \
  --output table
```

```
--------------------------------------------------
|             DescribeEndpointTypes              |
+-----------+---------------+--------------------+
|  Engine   |     Type      |    SupportsCDC     |
+-----------+---------------+--------------------+
|  oracle   |  source       |  True              |
|  oracle   |  target       |  True              |
|  postgres |  source       |  True              |
|  postgres |  target       |  True              |
+-----------+---------------+--------------------+
```

`SupportsCDC: true` is what makes a **near-zero-downtime** cutover possible: DMS performs a full load while the source stays online, then applies the change stream captured during that load until the lag reaches near zero, and only then do you cut over.

3. Reason about the two migration classes:

- **Homogeneous** — Oracle → Oracle, MySQL → RDS MySQL. The schema is already compatible. **DMS alone** does the job.
- **Heterogeneous** — Oracle → Aurora PostgreSQL, SQL Server → MySQL. Data types, stored procedures and PL/SQL do not translate. You need **AWS SCT (Schema Conversion Tool)** to convert schema and code objects *first*, then DMS to move the rows. SCT also produces an assessment report listing what it could not convert automatically.

4. Note the ordering constraint that costs projects their timeline: **SCT before DMS, always.** DMS moves data into a target schema; if the schema does not exist, or exists with incompatible types, the load fails or silently truncates.

**Sources:**
- AWS DMS — <https://docs.aws.amazon.com/dms/latest/userguide/Welcome.html>
- AWS SCT — <https://docs.aws.amazon.com/SchemaConversionTool/latest/userguide/CHAP_Welcome.html>
- DMS CDC — <https://docs.aws.amazon.com/dms/latest/userguide/CHAP_Task.CDC.html>

### ✅ Comprehension check — Block 7

**Q7.1** — Define homogeneous vs heterogeneous migration, and state which one requires SCT.

**Q7.2** — `SupportsCDC: true`. Explain in two sentences how CDC enables a near-zero-downtime cutover, and what the source database must have enabled for it to work.

**Q7.3** — A team runs DMS to move 4 TB from on-premises Oracle to Aurora PostgreSQL without running SCT first. Predict the failure mode.

**Q7.4** — DMS lists `kinesis` and `opensearch` as endpoint types. What does that tell you about DMS's scope beyond "database migration"?

---

## Exercise 8 — The exam-shaped drill: shared responsibility across three tiers 🟢 FREE

For each row, mark **C** (customer) or **A** (AWS). Complete all three columns before checking.

| Task | MySQL on EC2 | RDS MySQL | DynamoDB |
|---|---|---|---|
| Patch the guest OS | ? | ? | ? |
| Patch the MySQL engine binary | ? | ? | ? |
| Configure automated backups | ? | ? | ? |
| Design the schema / key model | ? | ? | ? |
| Provision replacement hardware on host failure | ? | ? | ? |
| Encrypt data at rest (turn the feature on) | ? | ? | ? |
| Manage the encryption *service* (KMS) | ? | ? | ? |
| Tune queries and indexes | ? | ? | ? |
| Choose the instance size | ? | ? | ? |
| Configure network access control | ? | ? | ? |
| Scale storage capacity | ? | ? | ? |
| Physical security of the data centre | ? | ? | ? |

**Source:** <https://aws.amazon.com/compliance/shared-responsibility-model/>

### ✅ Comprehension check — Block 8

**Q8.1** — One row differs between all three columns. Which row, and why is it the clearest illustration of the managed-service spectrum?

**Q8.2** — "Encrypt data at rest" is customer responsibility in all three columns even though AWS performs the encryption. Explain the distinction the shared responsibility model draws here.

**Q8.3** — "Design the schema" is customer in all three columns. Name the general principle that explains why no AWS database service will ever take that row.

---

## Exercise 9 — Teardown and cost verification 🟢 FREE (and mandatory)

Run this even if you think you created nothing. Especially then.

1. Delete the read replica first (a replica blocks deletion of its source):

```bash
aws rds delete-db-instance --db-instance-identifier clf34-mysql-ro \
  --skip-final-snapshot --query 'DBInstance.DBInstanceStatus' --output text
aws rds wait db-instance-deleted --db-instance-identifier clf34-mysql-ro
```

```
deleting
```

2. Deletion protection is doing its job — you must disable it explicitly:

```bash
aws rds modify-db-instance --db-instance-identifier clf34-mysql \
  --no-deletion-protection --apply-immediately \
  --query 'DBInstance.PendingModifiedValues' --output json

aws rds delete-db-instance --db-instance-identifier clf34-mysql \
  --skip-final-snapshot --delete-automated-backups \
  --query 'DBInstance.DBInstanceStatus' --output text
aws rds wait db-instance-deleted --db-instance-identifier clf34-mysql
```

3. Delete the Aurora instances *before* the cluster — a cluster with members cannot be deleted:

```bash
for i in clf34-aurora-1 clf34-aurora-2; do
  aws rds delete-db-instance --db-instance-identifier "$i" --skip-final-snapshot
done
for i in clf34-aurora-1 clf34-aurora-2; do
  aws rds wait db-instance-deleted --db-instance-identifier "$i"
done

aws rds delete-db-cluster --db-cluster-identifier clf34-aurora \
  --skip-final-snapshot --query 'DBCluster.Status' --output text
```

4. **Delete the manual snapshot.** This is the one people forget — it survives instance deletion forever and bills forever:

```bash
aws rds delete-db-snapshot --db-snapshot-identifier clf34-mysql-manual-01 \
  --query 'DBSnapshot.Status' --output text
```

5. Delete DynamoDB, the subnet group and the security group:

```bash
aws dynamodb delete-table --table-name clf34-orders \
  --query 'TableDescription.TableStatus' --output text
aws dynamodb wait table-not-exists --table-name clf34-orders

aws rds delete-db-subnet-group --db-subnet-group-name clf34-subnets
aws ec2 delete-security-group --group-id "$SG_ID"
```

6. **Verify, do not assume.** Sweep every database service for survivors:

```bash
echo "--- RDS instances ---"
aws rds describe-db-instances --query 'DBInstances[].DBInstanceIdentifier' --output text
echo "--- RDS clusters ---"
aws rds describe-db-clusters --query 'DBClusters[].DBClusterIdentifier' --output text
echo "--- Manual snapshots ---"
aws rds describe-db-snapshots --snapshot-type manual \
  --query 'DBSnapshots[].DBSnapshotIdentifier' --output text
echo "--- Cluster snapshots ---"
aws rds describe-db-cluster-snapshots --snapshot-type manual \
  --query 'DBClusterSnapshots[].DBClusterSnapshotIdentifier' --output text
echo "--- DynamoDB tables ---"
aws dynamodb list-tables --query 'TableNames' --output text
echo "--- ElastiCache ---"
aws elasticache describe-cache-clusters --query 'CacheClusters[].CacheClusterId' --output text
echo "--- Redshift Serverless ---"
aws redshift-serverless list-workgroups --query 'workgroups[].workgroupName' --output text
```

A clean account prints six blank lines:

```
--- RDS instances ---

--- RDS clusters ---

--- Manual snapshots ---

--- Cluster snapshots ---

--- DynamoDB tables ---

--- ElastiCache ---

--- Redshift Serverless ---

```

7. Confirm against the bill 24 hours later. Cost data lags; a same-day check proves nothing:

```bash
aws ce get-cost-and-usage \
  --time-period Start=2026-09-04,End=2026-09-06 \
  --granularity DAILY --metrics UnblendedCost \
  --group-by Type=DIMENSION,Key=SERVICE \
  --query 'ResultsByTime[].Groups[?contains(Keys[0],`Relational`) || contains(Keys[0],`DynamoDB`)].{Service:Keys[0],Cost:Metrics.UnblendedCost.Amount}' \
  --output table
```

```
------------------------------------------------------------
|                    GetCostAndUsage                       |
+--------------------------------------+-------------------+
|               Service                |       Cost        |
+--------------------------------------+-------------------+
|  Amazon Relational Database Service   |  0.7412031000    |
|  Amazon DynamoDB                      |  0.0000041200    |
+--------------------------------------+-------------------+
```

> `get-cost-and-usage` itself costs US$0.01 per paginated request. Do not put it in a loop.

### ✅ Comprehension check — Block 9

**Q9.1** — Step 2 required disabling deletion protection before deleting. Is deletion protection a security control or an operational control? What does it not protect against?

**Q9.2** — You passed `--skip-final-snapshot`. What is the alternative, and in what environment would omitting the final snapshot be a resume-generating event?

**Q9.3** — Automated backups were removed with `--delete-automated-backups`, but the manual snapshot needed its own delete call. State the retention rule for each in one sentence.

**Q9.4** — The Aurora teardown required deleting instances before the cluster; RDS had no such step. Which architectural fact from Exercise 3 does this ordering reflect?

---

## Exercise 10 — Timed scenario drill (10 minutes, closed book) 🟢 FREE

Answer each with one service and one clause of justification. Time yourself — CLF-C02 gives you roughly 1 minute 45 seconds per question.

1. A hospital must query "all patients treated by any physician who worked at Clinic X between 2019 and 2021, within two degrees of separation."
2. A SaaS product's PostgreSQL database serves 40 000 reads/s and 2 000 writes/s and needs a failover under 60 s across AZs, with minimal application change.
3. A mobile game stores per-player state, has an unpredictable launch spike from 0 to 1 M requests/s, and the team has no DBAs.
4. Finance needs to run 90-day trend queries across 8 TB of transaction history without slowing the transactional system.
5. A regulated firm must migrate 12 TB of on-premises SQL Server to Aurora PostgreSQL with under 15 minutes of downtime.
6. An application needs a Redis-compatible store where losing a write is unacceptable — it is the system of record, not a cache.
7. A wind farm ingests 50 000 turbine measurements per second, queried almost exclusively as "average output per turbine per hour, last 30 days."
8. A team wants to run MongoDB workloads without operating replica sets, sharding or backups.
9. A legacy Oracle application requires an OS-level agent installed on the database host, and the vendor will not certify anything else.
10. Ten TB of compressed CloudTrail logs sit in S3. Security wants ad-hoc SQL over them roughly twice a month.

---

<details>
<summary><strong>📖 Answers — click to expand</strong></summary>

## Block 0 — Guardrails

**A0.1** — Every *resource* call in this lab (RDS, DynamoDB, ElastiCache, Neptune) is regional. Databases, subnet groups, security groups and snapshots exist in exactly one region, and an unset region means the CLI falls back to whatever is in your profile — a classic way to leave a billable Multi-AZ instance running in a region you never look at again. Billing endpoints being global does not change that; it is precisely why the sweep in Exercise 9 must be run per region.

**A0.2** — No. AWS Budgets is a **notification and reporting** mechanism, not a spending cap; AWS never stops serving your resources because a budget was exceeded. To enforce a stop you need **AWS Budgets Actions**, which can be configured to apply a restrictive IAM policy, attach an SCP, or stop EC2/RDS instances when a threshold is breached — and even that is an action you configure, not a native hard limit. The only true hard limits in AWS are service quotas and IAM permission boundaries.

**A0.3** — A DB subnet group is a *property of the deployment configuration*, not of the current topology. RDS requires at least two AZs so that you can convert a Single-AZ instance to Multi-AZ later, and so that RDS can place a replacement instance in a different AZ during a host failure or a maintenance operation. Requiring it up front prevents an outage-time discovery that the standby has nowhere to go.

---

## Block 1 — The relational surface

**A1.1** — **RDS Custom** gives you operating-system and database-level access: you can SSH to the host, install vendor agents, apply custom patches, and configure settings that standard RDS locks down. It exists for legacy Oracle and SQL Server applications with third-party agent requirements. What you give up is the automation contract: because you can modify the host, AWS's automation may be unable to repair or fail over the instance, and support for a customer-broken environment falls back to you. It is the deliberate middle rung between EC2-hosted and fully managed RDS.

**A1.2** — Two of: guest OS patching; database engine minor-version patching; automated backup execution and retention; host hardware failure detection and replacement; storage provisioning, RAID and automatic scaling; Multi-AZ synchronous replication setup; underlying filesystem management. On EC2 every one of those is yours, including writing and testing the backup cron job and being the one paged when it silently stopped working.

**A1.3** — The alternative is **BYOL (Bring Your Own License)**. A company chooses BYOL when it already owns perpetual Oracle or SQL Server licences with active support — paying AWS a second time for the licence embedded in the hourly rate would be duplicate spend. License-included is chosen when there is no existing licence, when the workload is short-lived, or when the customer wants to avoid licence-compliance audits entirely.

**A1.4** — `t` = burstable general purpose (CPU credits, cheap, unsuitable for sustained load); `m` = general purpose with balanced CPU-to-memory; `r` = memory optimised, roughly double the RAM per vCPU of an `m`. For a memory-hungry reporting replica choose **`db.r6g.large`** — reporting queries build large sort and hash-join buffers, and the working set living in RAM is what keeps the query off disk. Choosing `t4g` there produces a replica that is fast for ten minutes and then throttles when its CPU credits run out.

---

## Block 2 — RDS Multi-AZ

**A2.1** — No. The Multi-AZ standby is not readable and not connectable; it exists purely as a synchronous replication target for high availability. Paying for it buys durability and automatic failover, not capacity. The correct feature for reporting reads is a **read replica**, which has its own endpoint and serves read traffic. (Note the exception worth knowing: the **Multi-AZ DB cluster** deployment option — three instances, one writer and two *readable* standbys — does serve reads from its standbys. Standard Multi-AZ *instance* deployments, which is what you built, do not.)

**A2.2** — RDS publishes the instance endpoint as a DNS **CNAME** pointing at the current primary's address. On failover the control plane repoints that CNAME at the promoted standby; the name your application holds never changes, so no configuration or redeployment is required. The JVM failure mode: the JVM's `networkaddress.cache.ttl` historically defaults to caching successful DNS lookups **forever** when a security manager is installed. An application that resolved the endpoint at startup keeps hammering the dead primary's IP address long after AWS has completed a healthy failover. The fix is to set the JVM DNS TTL to 5–10 seconds — an application-side responsibility that AWS cannot fix for you, and a real production incident pattern.

**A2.3** — **(a) Data loss.** Synchronous replication means the write is acknowledged to the client only after it is durable on *both* the primary and the standby, so an AZ failure loses nothing — RPO is effectively zero. Asynchronous replication acknowledges on the primary alone and ships changes afterwards, so a primary failure can lose whatever had not yet been applied — RPO is non-zero and equal to the replication lag at the moment of failure. **(b) Latency.** Synchronous replication puts the cross-AZ network round trip inside every commit, so the primary's write latency is higher — this is the real cost of Multi-AZ and the reason it is not free performance-wise. Asynchronous replication adds essentially nothing to the primary's write path, which is exactly why it can be used across regions where a synchronous round trip would be intolerable.

**A2.4** — Use **point-in-time recovery (PITR)** from automated backups. Granularity is **one second**, within the retention window (7 days here, 1–35 configurable). Critically, PITR **does not overwrite the source** — it restores to a **new DB instance** with a new identifier and a new endpoint. The recovery procedure is therefore: restore to a new instance at 14:31:59, extract the dropped table, and load it back into production. This is a feature, not a limitation: it means the recovery attempt cannot make the incident worse, and it is why "restore" and "roll back" are not synonyms on RDS.

**A2.5** — **Manual snapshots** are the cost risk. Automated backups are governed by the retention period and are deleted when the instance is deleted (unless explicitly retained), so they self-clean. A manual snapshot has no retention period at all — it persists until a human deletes it, survives the deletion of its source instance, and continues to bill for its storage indefinitely. In a lab account this is how you end up paying for a database you deleted eight months ago.

**A2.6** — Two of:
- **Region-wide failure** → cross-region read replica, or **Aurora Global Database**, or cross-region automated backup replication.
- **Logical corruption / accidental `DROP`** → PITR or snapshots. Multi-AZ replicates the `DROP` to the standby *synchronously and faithfully*; the standby is a perfect copy of your mistake.
- **Read capacity exhaustion** → read replicas. Multi-AZ adds zero read capacity.
- **Accidental deletion of the instance** → deletion protection plus final snapshots.

---

## Block 3 — Aurora

**A3.1** — Aurora separates compute from storage: the cluster owns a distributed, self-healing, auto-growing storage volume that all instances share, so `AllocatedStorage` describes a volume that grows on demand rather than a disk you sized. Aurora keeps **six copies of every data block across three Availability Zones** (two per AZ). It tolerates the loss of an entire AZ plus one additional copy without losing write availability, and the loss of an entire AZ plus one more copy without losing read availability.

**A3.2** — On RDS, the standby is a *separate instance with its own independent copy of the data*, kept in step by synchronous block-level replication; letting it serve reads would mean serving from a replica whose consistency guarantees RDS does not expose, and it would consume the I/O headroom the replication itself needs. On Aurora, the replica is not a copy at all — it attaches to the *same* shared storage volume as the writer. There is nothing to synchronise, so a reader is simply another compute node reading the same pages, and serving reads from it is architecturally free.

**A3.3** — Because Aurora failover is a **promotion**, not a **transfer of data ownership**. The replica already has the storage volume attached and its buffer cache partially warm, so failing over means updating the cluster endpoint and letting the promoted node take write ownership of a volume it was already reading. RDS Multi-AZ must detect the primary's failure, confirm the standby has applied all replicated blocks, promote it, and repoint DNS — with a cold cache on the newly promoted instance. Aurora also decouples the buffer cache from the database process on the writer, so a restart does not force a full cache rebuild.

**A3.4** — **Cluster endpoint** (`...cluster-...`) — always resolves to the current writer, follows failover automatically. **Reader endpoint** (`...cluster-ro-...`) — DNS round-robin across all available readers. **Instance endpoint** — one specific node, used for diagnostics or for pinning a single workload; never for general application configuration, because that instance may be demoted, promoted or deleted. (a) Writes → cluster endpoint. (b) Reporting reads → reader endpoint.

**A3.5** — **Aurora Serverless v2** wins decisively on cost for a 2-hours-a-day database: you pay per ACU-second, so a workload idling 22 hours a day costs a fraction of a provisioned instance billed for all 24. On recent engine versions the minimum capacity can be set to **0 ACUs**, pausing the database entirely when idle. The trade-off is cold-start latency: resuming from zero adds a delay on the first connection (typically a few seconds to tens of seconds), which is fine for development and unacceptable for a latency-sensitive user-facing path. A provisioned `db.r6g.large` costs the same whether used or not, but is always warm and has completely predictable performance. Dev database → Serverless v2. Steady 24/7 production load at known capacity → provisioned is usually cheaper per unit of work.

**A3.6** — **Aurora Global Database.** It replicates the *storage layer* from a primary region to up to five secondary regions using dedicated infrastructure rather than the database engine's own replication, achieving typical cross-region replication lag under one second and a documented RPO of ~1 second with an RTO under one minute for managed planned failover. Secondary regions are read-only (with the exception of write-forwarding, where supported) and can be promoted to primary for disaster recovery. Note the contrast with DynamoDB global tables in **A4.6**.

---

## Block 4 — DynamoDB

**A4.1** — DynamoDB is **serverless**, not merely managed. RDS still exposes the server abstraction — you pick an instance class, an AZ, a VPC, a storage size, a maintenance window, and you wait eleven minutes for hardware to be provisioned. DynamoDB exposes only the *table*. What disappears from your responsibility: instance sizing, AZ placement, VPC and subnet design, storage provisioning and growth, engine patching and version upgrades, replication configuration, and failover planning. Multi-AZ replication across three AZs is not a feature you enable and pay extra for — it is the only mode DynamoDB has. What remains yours is exactly what remained yours on RDS too: the data model, the access patterns, and the capacity/cost mode.

**A4.2** — You are billed on **`ScannedCount`** — the items DynamoDB read from storage — not on `Count`, the items that survived your filter. The filter is applied *after* the read and after the metering. At 30 million items, a `scan` with a filter that returns two rows still reads and bills for all 30 million: potentially thousands of RCUs, several seconds to minutes of latency across paginated calls, and, in provisioned mode, throttling of every other query on the table while it runs. This is why "add a `scan`" is the most expensive one-line change in a DynamoDB codebase, and why access patterns must be designed before the key schema is chosen.

**A4.3** — DynamoDB synchronously replicates every write to three Availability Zones. An **eventually consistent** read is served from any *one* of those three replicas — which may not yet have the most recent write — costing one replica read: **0.5 RCU per 4 KB**. A **strongly consistent** read must guarantee it returns the latest committed write, so it is served from the leader replica with a confirmed quorum view, costing **1 RCU per 4 KB**. You are paying for the coordination, and the pricing makes the CAP-theorem trade-off literally visible on the invoice. (Note that a strongly consistent read is also unavailable if the leader's AZ is impaired, while an eventually consistent read still succeeds — the availability half of the same trade-off.)

**A4.4** — A **GSI** can use a *completely different partition key* from the base table, which is what let step 8 query by `status` when the table is partitioned by `customerId`; an LSI must reuse the base table's partition key and may only vary the sort key. Constraints an **LSI** has that a GSI does not: it must be created at table-creation time and can never be added afterwards; it shares the base table's provisioned capacity rather than having its own; it supports strongly consistent reads (a GSI is eventually consistent only); and the item collection for a single partition key is capped at 10 GB when an LSI exists. In practice, prefer GSIs — the "must decide at creation time, forever" property of LSIs is a serious design liability.

**A4.5** — **DAX** is a fully managed, DynamoDB-API-compatible, write-through in-memory cache that takes reads from single-digit **milliseconds** to single-digit **microseconds** — roughly a 10× improvement. It makes sense when (a) the workload is read-heavy with a hot key set read repeatedly, (b) the application is genuinely latency-sensitive at the microsecond scale, such as real-time bidding or high-frequency gaming state, or (c) the read cost of those repeated hot reads exceeds the DAX cluster cost. Its decisive advantage over ElastiCache in front of DynamoDB is that it is API-compatible: you change the client, not the application logic, and you do not implement cache-aside by hand. Its cost is that DAX reads are eventually consistent — a strongly consistent read bypasses the cache entirely.

**A4.6** — **DynamoDB global tables** are **multi-region, active-active**: every replica region accepts writes, and conflicts are resolved last-writer-wins. **Aurora Global Database** is **single-writer**: exactly one region accepts writes, and the others are read-only replicas that must be promoted to take over. That distinction is the whole answer to "can my application write from both regions simultaneously?" — DynamoDB yes, Aurora no (barring write-forwarding, which still routes the write to the single primary).

**A4.7** — **PITR** satisfies "restore to any second in the last 35 days": it is a continuous backup with second-level granularity and a fixed maximum 35-day window, and it always restores to a *new* table. **On-demand backups** satisfy the seven-year audit retention: they are full snapshots that persist until explicitly deleted, have no retention limit, and can be managed under AWS Backup with a lifecycle policy. Using PITR for long-term retention is impossible (the window is capped); using on-demand backups for point-in-time incident recovery is imprecise (you can only restore to the moments you happened to take a backup).

---

## Block 5 — Caching

**A5.1** — **ElastiCache is a cache; MemoryDB is a durable database.** ElastiCache stores data in memory for speed and can lose it on failure or restart — it must always sit in front of a system of record. MemoryDB persists every write to a Multi-AZ transactional log before acknowledging it, giving microsecond reads, single-digit-millisecond writes, and **durability**, so it can *be* the system of record. Workloads: ElastiCache → session store backed by a database, product-catalogue cache, rate-limiter counters, database query cache. MemoryDB → a microservice whose primary datastore is Redis-compatible and where losing a write is a correctness failure, such as an order-state service or a real-time ledger.

**A5.2** — **Data structures:** Memcached stores opaque key/value blobs only; Redis/Valkey provide sorted sets, hashes, lists, streams, hyperloglogs, geospatial indexes and Lua scripting. **Replication:** Memcached has none — no replicas, no failover, no snapshots; Redis/Valkey support replication, Multi-AZ with automatic failover, and backup/restore. **Multi-threading:** Memcached is multi-threaded and can use all cores of a large node; Redis's core command execution is single-threaded (Valkey 8 adds significant multi-threaded I/O). For a **leaderboard**, choose **Redis/Valkey**: the sorted set (`ZADD`/`ZRANGE`/`ZREVRANK`) is a purpose-built ranked structure that gives you top-N and a player's rank in O(log n). On Memcached you would have to fetch the whole leaderboard and sort it in the application on every request.

**A5.3** — You used **cache-aside** (also called lazy loading): the application checks the cache, and on a miss reads the database and populates the cache. Its virtue is that only requested data is ever cached, so the cache stays small; its flaw is precisely what step 5 showed — the cache can serve stale data until the TTL expires, and every miss pays a cache-check penalty on top of the database read. The alternative is **write-through**: every database write also updates the cache, so the cache is never stale. Its trade-off is that write latency increases and the cache fills with data that may never be read, wasting memory. The pragmatic production answer is usually both — write-through for correctness on hot entities, plus a TTL as a backstop against any invalidation you missed.

**A5.4** — A **read replica** adds read capacity but still executes the query, parsing SQL, planning, scanning and joining, every single time. **ElastiCache** eliminates the query entirely: the result is served from memory in microseconds and the database never sees the request. For "the same query thousands of times per second", ElastiCache addresses the root cause — you are paying to compute an identical answer repeatedly. The read replica gives you something ElastiCache cannot: capacity for *diverse* reads that are not cacheable, and a promotable standby for disaster recovery. In production you frequently deploy both, but for this symptom the cache is the correct first move, and it is usually far cheaper than a second `r6g` instance.

**A5.5** — On the CLF-C02 exam guide, ElastiCache is grouped under database services (it is in the in-scope services list under Database), but architecturally it is a **caching** service and never a system of record. The distinction matters because exam questions frequently include ElastiCache as a plausible distractor when the requirement is durable storage. The rule: if the question says "must not lose data", "system of record", "durable", or "source of truth", ElastiCache is wrong — the answer is RDS, Aurora, DynamoDB, or, if it must be Redis-compatible, **MemoryDB**.

---

## Block 6 — Purpose-built engines

**A6.1** — It reveals that DocumentDB is built on the **same distributed storage layer as Aurora** — the compute/storage separation, the cluster-plus-instances object model, the cluster and reader endpoints. The implication is that DocumentDB inherits Aurora's availability characteristics: six copies of data across three AZs, storage that auto-grows, fast failover by promotion rather than data transfer, and up to fifteen read replicas sharing one volume. This is also why DocumentDB is *MongoDB-compatible* rather than *MongoDB* — it implements the MongoDB wire protocol and API on top of Aurora storage; it is not the MongoDB engine.

**A6.2** — **Gremlin** (Apache TinkerPop), **openCypher**, and **SPARQL** (for RDF). The question a relational database answers badly is variable-depth traversal: *"find everything connected to this node within N hops"*. In SQL each hop is another self-join, so a 5-hop query means five joins whose cost multiplies with the branching factor; the query planner cannot help because the depth may be data-dependent or unbounded. A graph database stores adjacency directly, so traversing a hop is a pointer dereference and cost scales with the *subgraph actually visited*, not with the size of the tables. Fraud rings, social recommendations and knowledge graphs are the canonical cases.

**A6.3** — RDS/Aurora are **row**-oriented; Redshift is **columnar**. Row storage keeps all attributes of one record physically together, which makes "read, update or insert this one order" a single efficient I/O — ideal for OLTP, terrible for analytics because computing `AVG(amount)` over a billion rows drags every unused column off disk with it. Columnar storage keeps all values of one column together, so scanning one column of a billion rows reads only that column, and because adjacent values share a type and domain they compress extremely well — ideal for OLAP. It is terrible for OLTP because updating a single row means touching every column's storage block, and inserting one row is a worst-case write pattern. Redshift compounds this with massively parallel processing across nodes and distribution/sort keys, which optimise for large scans, not for point lookups.

**A6.4** — **Athena is a query engine, not a database**: it stores nothing, owns nothing, and manages no data lifecycle. It reads data that already lives in Amazon S3 through a schema defined in the AWS Glue Data Catalog, and bills per terabyte scanned with no cluster to provision. Choose Athena over Redshift when queries are **infrequent and ad hoc**, when the data already sits in S3 and you do not want an ETL pipeline, and when you would otherwise pay for a cluster idling between queries. Choose Redshift when queries are **frequent, complex and latency-sensitive**, when you need consistent performance for BI dashboards refreshing all day, or when joins across large fact and dimension tables benefit from distribution and sort keys. The economics invert around usage frequency: Athena is cheap when idle and expensive per query; Redshift is the reverse.

**A6.5** — It demonstrates that **Amazon Keyspaces is serverless**: there is no cluster, no node count, no instance class, and no capacity to plan — you create a keyspace and a table and start issuing CQL, with the service scaling tables up and down automatically. **DynamoDB** shares this property, as do **Aurora Serverless v2** (partially — you still define ACU bounds), **Redshift Serverless**, **Timestream** and **Athena**. Note the parallel: Keyspaces is to Cassandra what DocumentDB is to MongoDB — a compatible API over AWS-managed infrastructure rather than the upstream engine itself. The practical consequence is that you do not administer nodes, but you also cannot assume every upstream feature or extension is present.

**A6.6** — **Amazon QLDB (Quantum Ledger Database)** was a fully managed ledger database with an immutable, append-only, cryptographically verifiable journal — every change was recorded permanently with a SHA-256 hash chain, so you could prove to an auditor that history had not been altered. Typical use cases were financial ledgers, supply-chain provenance and regulatory audit trails. **Its current status: retired.** AWS announced deprecation in 2024 and ended support on **31 July 2025**; the recommended migration path was Amazon Aurora PostgreSQL, whose verifiable-ledger patterns cover the same requirements. **If you see QLDB in a practice question**, treat it as material written against an older exam guide. Know what it did — the concept of an immutable cryptographically verifiable ledger is still worth understanding, and "immutable, cryptographically verifiable audit trail" is a recognisable requirement phrase — but do not expect it as the correct answer on a current exam, and do not propose it in a real design. Always verify the in-scope services appendix of the current exam guide at <https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf>.

**Decision table (step 5):**

| Workload | Service | Why |
|---|---|---|
| Order entry, ACID, joins, existing PostgreSQL app | **Amazon RDS for PostgreSQL** | Relational OLTP with an existing engine dependency; RDS is the lowest-change managed path |
| Same, 5× throughput, 30 s failover SLO | **Amazon Aurora PostgreSQL** | Wire-compatible so the app is unchanged; ~5× MySQL / ~3× PostgreSQL throughput, ~30 s failover, 15 readers on shared storage |
| Cart/session state, single-digit ms, spiky | **Amazon DynamoDB** | Key-value access pattern, on-demand mode absorbs spikes with no capacity planning |
| BI over 4 TB of history | **Amazon Redshift** | Columnar MPP data warehouse purpose-built for large analytical scans |
| Fraud: 3-hop account/device relationships | **Amazon Neptune** | Graph traversal; the same query in SQL is an unbounded chain of self-joins |
| 200 000 sensors, time-range queries | **Amazon Timestream** | Purpose-built time-series: time-partitioned storage, automatic memory→magnetic tiering, built-in interpolation and time-window functions |
| MongoDB 5.0 lift-and-shift | **Amazon DocumentDB** | MongoDB API compatibility on Aurora storage; no replica sets or sharding to operate |
| Cassandra lift-and-shift | **Amazon Keyspaces** | CQL compatibility, serverless, no ring or node management |
| Redis-compatible **system of record** | **Amazon MemoryDB** | Durable Multi-AZ transaction log; ElastiCache would risk losing acknowledged writes |
| Cache in front of a hot RDS instance | **Amazon ElastiCache** | Eliminates the repeated query entirely rather than re-executing it on a replica |
| Oracle needing OS-level agent access | **Amazon RDS Custom for Oracle** | The one managed option that grants host access; standard RDS forbids it |
| Ad-hoc SQL over S3 logs, twice a month | **Amazon Athena** | Serverless, pay-per-TB-scanned, no cluster idling between the two monthly queries — and not a database at all |

---

## Block 7 — Migration

**A7.1** — A **homogeneous** migration moves between the same or compatible engines (Oracle → Oracle, MySQL → RDS MySQL, PostgreSQL → Aurora PostgreSQL): the schema, data types and procedural code are already compatible, so **DMS alone** suffices. A **heterogeneous** migration moves between different engine families (Oracle → Aurora PostgreSQL, SQL Server → MySQL): data types, sequences, stored procedures, triggers and proprietary SQL dialects do not translate, so you need **AWS SCT** to convert schema and code objects first, then DMS to move the rows. **SCT is required only for heterogeneous migrations.**

**A7.2** — CDC (change data capture) reads the source database's transaction log to capture every change made *while the full load is running*, then applies that backlog to the target until replication lag approaches zero. Because the source stays online and writable throughout, the outage is reduced to the moment you stop the application, let the last few transactions drain, and repoint the connection string — minutes rather than the days a 4 TB offline copy would take. For it to work, the source must have transaction logging enabled and retained in the form DMS requires: supplemental logging plus ARCHIVELOG mode on Oracle, `binlog_format=ROW` with adequate binlog retention on MySQL, logical replication (`wal_level=logical`) on PostgreSQL, and the CDC-enabled equivalent on SQL Server.

**A7.3** — DMS is a data-movement service; it does not convert schemas. With no converted target schema, either the target tables do not exist and the task fails immediately on the full-load phase, or DMS's own basic type mapping creates approximations that succeed structurally while silently corrupting semantics — `NUMBER` precision lost, `DATE` timezone handling changed, `CLOB`/`BLOB` truncated, `VARCHAR2` byte-vs-character semantics mismatched. Worse, none of the Oracle PL/SQL — packages, stored procedures, triggers, sequences — is migrated at all, because DMS moves rows, not code. The team discovers this at cutover, when the application starts and every stored-procedure call fails. Correct order: **SCT assessment report → SCT schema conversion → manual remediation of what SCT flagged → DMS full load + CDC → validation → cutover.**

**A7.4** — DMS is a general-purpose **data replication and integration** service, not merely a one-time migration tool. Endpoints such as `kinesis`, `kafka`, `opensearch`, `s3` and `redshift` mean DMS can continuously stream changes from a transactional database into an analytics or search target — for example, replicating an RDS PostgreSQL order table into OpenSearch for full-text search, or into Kinesis to feed a real-time pipeline, all via ongoing CDC rather than a nightly batch. The migration use case is the headline; continuous CDC-based integration is what many teams actually keep it running for.

---

## Block 8 — Shared responsibility

| Task | MySQL on EC2 | RDS MySQL | DynamoDB |
|---|---|---|---|
| Patch the guest OS | **C** | **A** | **A** |
| Patch the MySQL engine binary | **C** | **A** (customer chooses the window/version) | **A** (n/a — no engine to patch) |
| Configure automated backups | **C** | **C** (configures; AWS executes) | **C** (enables PITR; AWS executes) |
| Design the schema / key model | **C** | **C** | **C** |
| Provision replacement hardware on host failure | **A** (hardware) / **C** (recovery) | **A** | **A** |
| Encrypt data at rest (turn the feature on) | **C** | **C** | **C** (on by default) |
| Manage the encryption *service* (KMS) | **A** | **A** | **A** |
| Tune queries and indexes | **C** | **C** | **C** |
| Choose the instance size | **C** | **C** | **A** (no instances exist) |
| Configure network access control | **C** | **C** | **C** (IAM policies / VPC endpoints) |
| Scale storage capacity | **C** | **C** (or enable storage autoscaling) | **A** |
| Physical security of the data centre | **A** | **A** | **A** |

**A8.1** — **"Choose the instance size."** It is customer on EC2, customer on RDS, and AWS on DynamoDB — because on DynamoDB *there is no instance to size*. That single row is the clearest expression of the managed→serverless progression: EC2 gives you a machine you must fully operate; RDS operates the machine but still makes you specify it; DynamoDB removes the machine from your mental model entirely. Note that "patch the guest OS" also differs in *kind* (C, then A, then not-applicable), but the instance-sizing row is the sharpest because the same responsibility is genuinely transferred rather than merely automated.

**A8.2** — The model distinguishes **security *of* the cloud** from **security *in* the cloud**. AWS is responsible for the encryption infrastructure: operating KMS, protecting key material in HSMs, ensuring the cryptographic implementation is correct, and physically securing the media. The customer is responsible for the *configuration decision*: whether encryption is enabled at all, which key is used (AWS-managed vs customer-managed), who is granted `kms:Decrypt` in the key policy, and whether the key is rotated. AWS will happily run an unencrypted RDS instance for you — enabling encryption is a choice only you can make, and on RDS it must be made **at creation time** for the instance, which is precisely why it appears in the `create-db-instance` call in Exercise 2 and not in a later `modify` call.

**A8.3** — The principle is that **AWS is responsible for the service; the customer is responsible for how the service is used.** A schema encodes business meaning — what an order is, which fields matter, which access patterns the application will issue — and that knowledge exists only on the customer's side of the line. No amount of automation changes this, which is why it is customer responsibility on EC2, on RDS and on DynamoDB alike, and why it is also the row where the most expensive mistakes are made. A badly chosen DynamoDB partition key or a missing index costs more in production than any instance-sizing error, and it is the one thing no managed service will ever fix for you.

---

## Block 10 — Scenario drill

1. **Amazon Neptune** — variable-depth relationship traversal ("within two degrees") is the defining graph query; in SQL it is an unbounded chain of self-joins.
2. **Amazon Aurora PostgreSQL** — PostgreSQL wire compatibility means minimal application change; Aurora supplies the throughput headroom, up to 15 shared-storage readers, and ~30 s failover.
3. **Amazon DynamoDB** (on-demand capacity) — key-value access by player ID, on-demand absorbs a 0→1 M req/s launch spike with no capacity planning, and there is no database to administer.
4. **Amazon Redshift** — 8 TB of historical trend analysis is textbook OLAP; running it on the transactional database is what "without slowing the transactional system" is ruling out. (Redshift Serverless if the query load is intermittent.)
5. **AWS SCT + AWS DMS with CDC** — heterogeneous (SQL Server → PostgreSQL) so SCT converts schema and code first; DMS full load plus CDC keeps the source online and compresses the outage to the cutover window.
6. **Amazon MemoryDB** — Redis-compatible *and* durable. ElastiCache is the trap answer: it would satisfy "Redis-compatible" and fail "losing a write is unacceptable".
7. **Amazon Timestream** — high-ingest time-series with time-window aggregation queries; purpose-built time partitioning, automatic tiering from memory to magnetic store, and native time-series functions.
8. **Amazon DocumentDB** — MongoDB API compatibility with replica sets, sharding, patching and backups handled by AWS.
9. **Amazon RDS Custom for Oracle** — the only managed option granting OS-level host access for the vendor agent. (Self-managed Oracle on EC2 also technically works, but RDS Custom is the correct answer because it retains managed backups and automation.)
10. **Amazon Athena** — twice a month over data already in S3. Provisioning a Redshift cluster that idles for 29 days a month is the wrong economic shape; Athena bills per TB scanned with nothing running in between.

</details>

---

## Exam-day compression card

- **RDS** = managed relational, 8 engine families. **Multi-AZ = availability** (synchronous, invisible standby, no reads). **Read replica = scale** (asynchronous, own endpoint, readable).
- **Aurora** = MySQL/PostgreSQL-compatible, shared distributed storage, **6 copies / 3 AZs**, 15 readers, ~30 s failover, three endpoint types. **Serverless v2** for spiky or intermittent load. **Global Database** = cross-region, single writer.
- **DynamoDB** = serverless key-value/document, single-digit ms, on-demand or provisioned. **`scan` bills on `ScannedCount`.** Strong consistency = 2× the RCU. **DAX** for microseconds. **Global tables = active-active.**
- **ElastiCache** = cache, volatile, Valkey/Redis/Memcached. **MemoryDB** = durable Redis-compatible primary database.
- **Purpose-built:** Neptune (graph) · DocumentDB (document, MongoDB-compatible) · Keyspaces (wide-column, Cassandra-compatible) · Timestream (time series) · Redshift (columnar data warehouse, OLAP).
- **Migration:** homogeneous → DMS. Heterogeneous → **SCT then DMS**. CDC → near-zero downtime.
- **Traps:** S3 is object storage, not a database. Athena is a query engine, not a database. ElastiCache is never the system of record. QLDB is retired (end of support 31 July 2025).
- **Constant across every service:** schema and access-pattern design is always yours.

---

### Reference sources

- AWS Certified Cloud Practitioner (CLF-C02) Exam Guide — <https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf>
- Amazon RDS User Guide — <https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/Welcome.html>
- Amazon Aurora User Guide — <https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/CHAP_AuroraOverview.html>
- Amazon DynamoDB Developer Guide — <https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/Introduction.html>
- Amazon ElastiCache User Guide — <https://docs.aws.amazon.com/AmazonElastiCache/latest/dg/WhatIs.html>
- Amazon MemoryDB Developer Guide — <https://docs.aws.amazon.com/memorydb/latest/devguide/what-is-memorydb.html>
- Amazon DocumentDB Developer Guide — <https://docs.aws.amazon.com/documentdb/latest/developerguide/what-is.html>
- Amazon Neptune User Guide — <https://docs.aws.amazon.com/neptune/latest/userguide/intro.html>
- Amazon Keyspaces Developer Guide — <https://docs.aws.amazon.com/keyspaces/latest/devguide/what-is-keyspaces.html>
- Amazon Timestream Developer Guide — <https://docs.aws.amazon.com/timestream/latest/developerguide/what-is-timestream.html>
- Amazon Redshift Management Guide — <https://docs.aws.amazon.com/redshift/latest/mgmt/welcome.html>
- AWS Database Migration Service User Guide — <https://docs.aws.amazon.com/dms/latest/userguide/Welcome.html>
- AWS Schema Conversion Tool User Guide — <https://docs.aws.amazon.com/SchemaConversionTool/latest/userguide/CHAP_Welcome.html>
- AWS Shared Responsibility Model — <https://aws.amazon.com/compliance/shared-responsibility-model/>