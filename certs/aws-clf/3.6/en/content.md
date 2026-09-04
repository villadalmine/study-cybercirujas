# 3.6 — Identify AWS Storage Services

**Certification:** AWS Certified Cloud Practitioner (CLF-C02), v1.0
**Domain:** 3 — Cloud Technology and Services
**Task statement weight:** 4.25
**Audience profile:** SRE / Platform Architect. Everything below is production-grade: real limits, real failure modes, real invoices.

---

## 1. The architectural problem

A storage decision is the least reversible decision in a platform. Compute is cattle — you can re-roll an ASG in ten minutes. Networking is configuration. But data has *gravity*: once 40 TB sits in a filesystem, the migration cost (bandwidth, cutover window, consistency risk, application rewrite) grows superlinearly with the volume, and the choice you made on day one becomes a structural constraint on year three.

The failure mode this task statement exists to prevent is **paradigm mismatch**: picking a storage primitive whose access semantics do not match the workload's access pattern. The three canonical mismatches, all of which we have seen cause production incidents:

| Mismatch | What the team did | What broke |
|---|---|---|
| Object used as block | Backed a PostgreSQL data directory with an S3-FUSE mount | No `fsync` durability, no byte-range in-place writes, no POSIX locking → silent corruption under concurrent writes |
| Block used as shared file | Attached one EBS volume to 12 EC2 instances via Multi-Attach with `ext4` | Not a cluster-aware filesystem → two nodes write the same journal blocks → unrecoverable metadata corruption |
| File used as object | Stored 400 million 4 KB thumbnails on EFS | Per-file metadata overhead + per-GB price 13× S3 Standard → $11k/month for 1.6 TB of actual payload |

So the real skill is not memorising a service list. It is **classifying the workload against four axes**, then reading off the answer:

1. **Access unit** — does the client address *blocks* (LBA offsets, a raw device), *files* (POSIX or SMB paths, directories, locks, permissions), or *objects* (immutable whole-blob PUT/GET by key)?
2. **Sharing topology** — one writer, or many concurrent readers/writers?
3. **Latency class** — sub-millisecond (single-digit ms is too slow), single-digit ms, tens of ms, or hours (archival)?
4. **Durability & blast radius** — must the data survive an AZ loss? A Region loss? An operator `rm -rf`? A ransomware event with valid credentials?

Everything in the AWS storage portfolio is a point in that four-dimensional space. The rest of this document places each service precisely, with the numbers that make the placement defensible in a design review.

### 1.1 The shared responsibility line for storage

This is examinable and frequently misunderstood.

| AWS is responsible for | You are responsible for |
|---|---|
| Physical media, decommissioning (NIST 800-88 wipe), replication across AZ hardware | Choosing a class whose replication scope matches your RPO |
| Availability of the storage control plane and data plane | Bucket policies, IAM, ACLs, Block Public Access, VPC endpoints |
| Encryption *infrastructure* (KMS HSMs, SSE-S3 keys) | *Enabling* encryption, key rotation policy, `aws:SecureTransport` enforcement |
| Durability of what you stored | That what you stored is what you meant to store — versioning, Object Lock, backup |

S3's 99.999999999% durability protects against **hardware** loss. It does not protect against a `DeleteObject` call with valid credentials. Durability ≠ recoverability. That distinction is the entire justification for Versioning, Object Lock and AWS Backup.

---

## 2. The full taxonomy

```
                        AWS Storage
                             │
   ┌─────────────┬───────────┴────────┬──────────────┬───────────────┐
   │             │                    │              │               │
 BLOCK          FILE                OBJECT         HYBRID/EDGE   DATA MOVEMENT
   │             │                    │              │               │
 ┌─┴──┐    ┌─────┼───────┐      ┌─────┴─────┐   ┌────┴────┐    ┌─────┴─────┐
 EBS  │    EFS   │   FSx family  S3     S3 Glacier  Storage   DataSync
      │          │   ├ Windows   │      ├ Instant   Gateway   Transfer Family
 Instance Store  │   ├ Lustre    │      ├ Flexible  ├ S3 File  S3 Transfer
 (ephemeral      │   ├ ONTAP     │      └ Deep      ├ FSx File   Acceleration
  NVMe/SSD)      │   └ OpenZFS   │        Archive   ├ Volume   Snow Family
                 │               │                  └ Tape
            File Cache     S3 Express One Zone
```

Orthogonal to the tree, three **management-plane** services apply across it: **AWS Backup** (centralised policy-driven backup), **AWS Storage Lens** (S3 fleet analytics), and **AWS Elastic Block Store snapshots / Recycle Bin**.

### 2.1 Decision matrix — the one table to internalise

| Requirement in the question stem | Answer | Why not the neighbour |
|---|---|---|
| "Boot volume", "persistent disk for an EC2 instance", "database on EC2" | **EBS** | Instance store is ephemeral; EFS is NFS, not a block device |
| "Highest possible IOPS, temporary, cache/scratch/buffer, data loss acceptable" | **Instance store** | EBS is network-attached; it cannot match local NVMe latency |
| "Shared POSIX filesystem for many Linux instances / containers" | **EFS** | EBS Multi-Attach needs a cluster FS; S3 is not POSIX |
| "Shared Windows file share, SMB, Active Directory integration" | **FSx for Windows File Server** | EFS is NFS/Linux only |
| "HPC, machine learning training, sub-millisecond, hundreds of GB/s, linked to S3" | **FSx for Lustre** | EFS tops out far lower and is not S3-linked |
| "NetApp features — SnapMirror, FlexClone, multi-protocol NFS+SMB+iSCSI" | **FSx for NetApp ONTAP** | Only ONTAP offers those |
| "Static website assets, backups, data lake, unlimited scale, 11 nines" | **S3** | Not a filesystem, but nothing else scales this way |
| "Archive, retrieve within minutes to hours, lowest cost" | **S3 Glacier** family | Standard-IA costs 3–12× more per GB |
| "Compliance retention, WORM, 7 years, regulator-proof" | **S3 Object Lock (Compliance mode)** + Glacier Deep Archive | Governance mode can be bypassed by a privileged user |
| "On-premises app needs low-latency local access to cloud-backed storage" | **AWS Storage Gateway** | DataSync copies; Gateway *presents* |
| "Move 100 TB, site has a 100 Mbps link" | **AWS Snow Family** | Over the wire this takes ~92 days |
| "Recurring, scheduled, automated transfer NFS/SMB → AWS, 10× faster than open-source tools" | **AWS DataSync** | Gateway is not a migration tool |
| "Customers/partners upload via SFTP, FTPS, FTP into S3/EFS" | **AWS Transfer Family** | Managed protocol endpoint, no server to run |
| "Users worldwide upload large files slowly to one bucket" | **S3 Transfer Acceleration** | Uses CloudFront edge network + optimised backbone |
| "One policy, one console, backups of EBS+EFS+RDS+DynamoDB+FSx+EC2" | **AWS Backup** | Per-service snapshot lifecycle does not centralise |

---

## 3. Block storage

### 3.1 Amazon EBS — the mechanics

EBS is **network-attached block storage**, not local disk. Every read and write traverses the Nitro card and a dedicated storage network to a replicated backend inside **one Availability Zone**. Three consequences that dominate production behaviour:

1. **An EBS volume lives in exactly one AZ.** It can only attach to instances in that AZ. Crossing an AZ or Region requires a snapshot (snapshots are Regional; copy for cross-Region).
2. **Latency has a network floor.** Single-digit milliseconds for gp3/io2 on Nitro — excellent, but ~50–100× the latency of local NVMe. If your benchmark needs sub-100 µs, EBS is architecturally the wrong answer.
3. **Two independent ceilings apply**: the *volume's* provisioned performance, and the *instance's* EBS bandwidth. An `io2` volume provisioned at 64,000 IOPS attached to an `m5.large` (4,750 Mbps EBS baseline, ~593 MiB/s) will never deliver 64,000 × 16 KiB. Sizing the volume without sizing the instance is the single most common EBS performance bug.

#### EBS volume types — complete comparison

| | **gp3** | **gp2** (legacy) | **io2 / io2 Block Express** | **io1** (legacy) | **st1** | **sc1** |
|---|---|---|---|---|---|---|
| Media | SSD | SSD | SSD | SSD | HDD | HDD |
| Use case | Default for everything | Superseded by gp3 | Latency-critical DB, SAP HANA, Oracle RAC | Superseded by io2 | Big-data, log processing, streaming reads | Coldest data, infrequent scans |
| Size range | 1 GiB – 16 TiB | 1 GiB – 16 TiB | 4 GiB – 64 TiB | 4 GiB – 16 TiB | 125 GiB – 16 TiB | 125 GiB – 16 TiB |
| Baseline IOPS | **3,000 included** | 3 IOPS/GiB (min 100) | Provisioned | Provisioned | 500 (1 MiB blocks) | 250 (1 MiB blocks) |
| Max IOPS | 16,000 | 16,000 (at 5,334 GiB) | **256,000** (Block Express) | 64,000 | 500 | 250 |
| Max IOPS : GiB ratio | 500 : 1 | n/a (3:1 fixed) | 1,000 : 1 | 50 : 1 | n/a | n/a |
| Baseline throughput | **125 MiB/s included** | scales to 250 MiB/s | scales with IOPS | scales with IOPS | 40 MiB/s per TiB | 12 MiB/s per TiB |
| Max throughput | 1,000 MiB/s | 250 MiB/s | **4,000 MiB/s** | 1,000 MiB/s | 500 MiB/s (burst 250 MiB/s per TiB) | 250 MiB/s (burst 80 MiB/s per TiB) |
| Burst model | None — flat, deterministic | I/O credit bucket (burst 3,000 IOPS if < 1,000 GiB) | None | None | Throughput credit bucket | Throughput credit bucket |
| Durability (AFR) | 99.8 – 99.9% | 99.8 – 99.9% | **99.999%** (0.001% AFR) | 99.8 – 99.9% | 99.8 – 99.9% | 99.8 – 99.9% |
| Bootable | Yes | Yes | Yes | Yes | **No** | **No** |
| Multi-Attach | No | No | **Yes** (up to 16 Nitro instances, same AZ) | Yes | No | No |
| List price (us-east-1) | $0.08/GB-mo + $0.005/prov. IOPS over 3,000 + $0.040/prov. MB/s over 125 | $0.10/GB-mo | $0.125/GB-mo + tiered IOPS ($0.065 / $0.046 / $0.032) | $0.125/GB-mo + $0.065/IOPS | $0.045/GB-mo | $0.015/GB-mo |

> **Prices are us-east-1 list, current at time of writing.** Always confirm against the live pricing page (§13) before quoting a figure in a design document — AWS revises these.

**The gp2 → gp3 arbitrage.** A 1 TiB gp2 volume costs $102.40/month and delivers 3,000 IOPS / 250 MiB/s. The same 1 TiB on gp3 costs $81.92/month and delivers 3,000 IOPS / 125 MiB/s baseline; buying the missing 125 MiB/s costs $5.00/month → **$86.92 for identical performance, a 15% saving**, and the migration is an online `modify-volume` with no downtime. There is no workload where gp2 is the correct new choice.

**The gp2 burst trap.** gp2 volumes under 1,000 GiB use an I/O credit bucket that fills at 3 IOPS/GiB-second and burns at 1 credit per I/O. A 100 GiB gp2 volume has a 300 IOPS baseline and bursts to 3,000. Under sustained load the bucket drains (`BurstBalance` → 0) and throughput collapses by 10× *hours* after deployment — the classic "it was fine in staging" incident. gp3 has no credit bucket; its performance is flat and deterministic. This is why gp3 is the correct default.

#### Elastic Volumes

You can change volume type, size (grow only), IOPS and throughput **online**, with no detach and no downtime. There is a **6-hour cooldown** between modifications on the same volume. After growing the volume you must still grow the partition and filesystem inside the guest — AWS does not do this for you (§10.2).

### 3.2 Instance store

Physically attached NVMe/SSD on the host. Included in the instance price (no separate charge). Delivers the highest IOPS and lowest latency available on EC2 — millions of IOPS on `i4i`/`im4gn` classes.

**Persistence semantics — memorise this exactly:**

| Event | Instance store data |
|---|---|
| Reboot (`reboot`, `aws ec2 reboot-instances`) | **Survives** |
| Stop / Start | **Lost** (instance moves to a new host) |
| Hibernate | **Lost** |
| Terminate | **Lost** |
| Underlying host failure | **Lost** |

Legitimate production uses: buffers, caches, scratch space, replicated shard data where the cluster itself provides durability (Cassandra, Elasticsearch data nodes, Kafka with RF≥3). Illegitimate: anything whose loss requires a restore.

---

## 4. File storage

### 4.1 Amazon EFS

NFSv4.1/4.0, POSIX-compliant, **Linux only**, elastic — grows and shrinks automatically to petabyte scale, you pay only for what is stored. Mounted concurrently by thousands of EC2 instances, Lambda functions, ECS tasks and EKS pods, **across all AZs in the Region**.

| Dimension | Regional (Standard) | One Zone |
|---|---|---|
| Replication scope | ≥ 3 AZs | Single AZ |
| Designed durability | 99.999999999% | 99.999999999% (within the AZ) |
| Designed availability | 99.99% | 99.90% |
| Price (Standard class, us-east-1) | $0.30/GB-mo | $0.16/GB-mo |
| Use case | Production shared state | Dev/test, single-AZ analytics, cost-sensitive |

**Storage classes and lifecycle management** (EFS tiers files automatically based on last-access time):

| Class | Price/GB-mo | Access charge | Minimum residency |
|---|---|---|---|
| Standard | $0.30 | none | — |
| Infrequent Access (IA) | $0.016 | $0.01/GB read/write | 30 days after transition |
| Archive | $0.008 | $0.03/GB | 90 days after transition |

A 20 TB filesystem where 95% of files are untouched after 30 days: $6,144/mo all-Standard versus ~$614/mo with lifecycle to IA — a 90% reduction from a five-line policy.

**Throughput modes:**

| Mode | Behaviour | When to use |
|---|---|---|
| **Elastic** (default) | Scales up and down automatically; pay per GB read/written ($0.03/GB read, $0.06/GB write) | Spiky or unknown patterns — the correct default |
| **Provisioned** | Fixed MiB/s independent of stored size, billed hourly | Steady high throughput on a small dataset |
| **Bursting** | Baseline 50 KiB/s per GiB stored, burst credits | Legacy; small filesystems starve |

The **Bursting** failure mode mirrors gp2: a 10 GiB filesystem gets 500 KiB/s baseline. Once `BurstCreditBalance` hits zero, a CI pipeline reading it slows to a crawl. Elastic mode exists to eliminate this class of incident.

### 4.2 Amazon FSx — four distinct engines

FSx runs **actual third-party filesystems** as a managed service. That is the point: you get vendor-native features and on-disk formats, not an AWS reimplementation.

| | **FSx for Windows File Server** | **FSx for Lustre** | **FSx for NetApp ONTAP** | **FSx for OpenZFS** |
|---|---|---|---|---|
| Protocol | SMB 2.0–3.1.1 | Lustre (POSIX) | **NFS + SMB + iSCSI/NVMe-oF** | NFS v3/4/4.1/4.2 |
| Identity | Active Directory (AWS Managed AD or self-managed) | POSIX UID/GID | AD + NFS | POSIX UID/GID |
| Signature capability | DFS Namespaces, Shadow Copies, quotas | Sub-ms latency, links to S3 (import/export, Data Repository Associations) | SnapMirror, FlexClone, dedup/compression, capacity-pool tiering | Instant point-in-time snapshots, ZFS clones, high IOPS from ARC cache |
| Deployment | Single-AZ / Multi-AZ | Scratch (no replication) / Persistent (replicated in-AZ) | Single-AZ / Multi-AZ | Single-AZ / Multi-AZ |
| Peak throughput | up to ~2 GB/s+ | **hundreds of GB/s** (scales per TiB) | up to ~4 GB/s per HA pair | up to ~21 GB/s from cache |
| Classic workload | Lift-and-shift Windows apps, home directories, SQL Server FCI | HPC, genomics, CFD, ML training over an S3 data lake | Enterprise NetApp migration, multi-protocol estates | Linux app migration off on-prem ZFS/NFS |

**FSx for Lustre + S3 is the pattern to remember for ML/HPC:** the dataset lives durably and cheaply in S3; a Lustre filesystem is linked to the bucket, lazily loads objects on first access, presents them as POSIX files at sub-millisecond latency to the training fleet, and exports results back to S3. Scratch filesystems are then destroyed. Storage cost is S3's; performance is Lustre's.

**Amazon File Cache** is the generalisation: a high-speed, fully managed cache in front of *dispersed* datasets — on-premises NFS, S3 buckets in other Regions — presented as one namespace to burst workloads into AWS.

---

## 5. Object storage

### 5.1 Amazon S3 — the mechanics

Flat key/value namespace inside a **globally unique bucket name**. There are no real directories — `logs/2026/09/04/app.log` is one opaque key; the console renders `/` as folders. Objects are **immutable**: there is no partial update, only a full PUT (or a multipart upload assembled server-side).

Hard limits worth knowing:

| Limit | Value |
|---|---|
| Max object size | 5 TB |
| Max single PUT | 5 GB (multipart required above; recommended above 100 MB) |
| Multipart: max parts / part size | 10,000 parts / 5 MB–5 GB each |
| Request rate | **3,500 PUT/COPY/POST/DELETE and 5,500 GET/HEAD per second, per partitioned prefix** — and prefixes scale horizontally without limit |
| Consistency | **Strong read-after-write** for PUT, DELETE and LIST, on all requests, at no extra cost (since December 2020) |
| Buckets per account | 10,000 general purpose (soft, raisable to 1M) |

Designed durability across every class except One Zone variants: **99.999999999% (11 nines)**, achieved by synchronously writing across ≥3 Availability Zones. That number means: store 10 million objects and you should expect to lose one every 10,000 years.

#### Storage classes — complete comparison

| Class | AZs | Designed availability | $/GB-mo (us-east-1) | Retrieval fee | Min. billable duration | Min. billable object size | First-byte latency |
|---|---|---|---|---|---|---|---|
| **S3 Standard** | ≥3 | 99.99% | $0.023 | none | none | none | ms |
| **S3 Intelligent-Tiering** | ≥3 | 99.9% | $0.023 → $0.0125 → $0.004 (auto) + $0.0025 per 1,000 obj monitoring | **none** | none (no penalty) | objects < 128 KB never tiered | ms (instant tiers) |
| **S3 Standard-IA** | ≥3 | 99.9% | $0.0125 | $0.01/GB | **30 days** | **128 KB** | ms |
| **S3 One Zone-IA** | **1** | 99.5% | $0.01 | $0.01/GB | 30 days | 128 KB | ms |
| **S3 Express One Zone** | 1 (zonal) | 99.95% | $0.16 | none (higher request cost) | 1 hour | none | **single-digit ms, ~10× faster** |
| **S3 Glacier Instant Retrieval** | ≥3 | 99.9% | $0.004 | $0.03/GB | **90 days** | 128 KB | ms |
| **S3 Glacier Flexible Retrieval** | ≥3 | 99.99% | $0.0036 | tiered | **90 days** | 40 KB | Expedited 1–5 min / Standard 3–5 h / **Bulk 5–12 h (free)** |
| **S3 Glacier Deep Archive** | ≥3 | 99.99% | $0.00099 | tiered | **180 days** | 40 KB | Standard 12 h / Bulk 48 h |

**The minimum-duration charge is the most expensive trap in this table.** Lifecycle-transition 10 TB of logs to Glacier Deep Archive, then delete them 20 days later: you are billed for 180 days regardless. Deep Archive is for data you are *certain* you will keep — compliance archives, not "probably stale" data.

**The minimum-billable-size trap is the second.** 50 million 8 KB objects = 400 GB of real data. In Standard-IA each is billed at 128 KB → **6.4 TB billed**, $80/mo instead of the $9.20/mo the payload warrants — *more* than S3 Standard. IA classes are for large, infrequently-read objects. Small objects belong in Standard, or aggregated.

**When you genuinely do not know the access pattern, the answer is Intelligent-Tiering.** It has no retrieval fees and no minimum duration; the only cost is $0.0025 per 1,000 objects monitored. Break-even is roughly: worth it when average object size exceeds ~128 KB and access is unpredictable.

### 5.2 S3 data-protection features

| Feature | What it does | Production note |
|---|---|---|
| **Versioning** | Every PUT creates a new version; DELETE inserts a delete marker | Prerequisite for Replication, Object Lock and MFA Delete. Cannot be *disabled* once enabled — only suspended |
| **MFA Delete** | Requires an MFA token to permanently delete a version or suspend versioning | Root-only to configure, CLI-only. Blocks credential-compromise deletion |
| **Object Lock** | WORM. **Governance** mode (bypassable with `s3:BypassGovernanceRetention`) or **Compliance** mode (bypassable by *nobody*, including root, until retention expires) + **Legal Hold** (indefinite, no date) | Must be enabled at bucket creation. Compliance mode is irreversible — a misconfigured 7-year retention on 500 TB is a 7-year invoice |
| **Replication (SRR/CRR)** | Async copy to another bucket, same or cross-Region/account | Requires versioning on both ends. Add **S3 Replication Time Control** for a 15-minute SLA. Does *not* replicate pre-existing objects unless you run Batch Replication |
| **Lifecycle** | Transition between classes, expire objects, expire noncurrent versions, abort incomplete multipart uploads | Always add `AbortIncompleteMultipartUpload` — orphaned parts are invisible to `ls` and billed forever |
| **Block Public Access** | Four independent switches, evaluated *before* policies/ACLs | On by default at account and bucket level since April 2023. Turn it off only with a written justification |
| **Encryption** | SSE-S3 (AES-256, **applied by default to all new objects since January 2023**), SSE-KMS, DSSE-KMS, SSE-C | With SSE-KMS, enable **S3 Bucket Keys** — cuts KMS API calls and cost by up to 99% |

---

## 6. Hybrid, edge and data movement

### 6.1 AWS Storage Gateway

A virtual appliance (VM, hardware appliance, or EC2 instance) on-premises that **presents a standard local protocol and backs it with AWS storage**, with a local cache for low-latency access to the hot working set.

| Gateway type | On-prem protocol | AWS backing | Use case |
|---|---|---|---|
| **S3 File Gateway** | NFS / SMB | S3 objects (1 file = 1 object) | Move file workloads to S3 while apps keep using file paths |
| **FSx File Gateway** | SMB | FSx for Windows File Server | Low-latency on-prem access to a cloud Windows share |
| **Volume Gateway — Cached** | iSCSI | S3, with local cache | Primary data in AWS, hot data cached locally |
| **Volume Gateway — Stored** | iSCSI | Local primary, async backup to EBS snapshots | Primary data stays local, low-RTO DR in AWS |
| **Tape Gateway (VTL)** | iSCSI VTL | S3 Glacier / Deep Archive | Retire a physical tape library without changing the backup software |

**Gateway vs DataSync** is a stem-level discriminator: Gateway *presents* storage continuously (ongoing hybrid access); DataSync *transfers* it (a migration or scheduled replication job, then it is done).

### 6.2 AWS Snow Family

Physical, ruggedised, tamper-evident devices shipped to your site for offline transfer, with on-board encryption (KMS-managed keys, never stored on the device) and optional edge compute (EC2 instances, Lambda, EKS Anywhere).

The arithmetic that justifies them: **100 TB over a saturated 100 Mbps link ≈ 92 days.** Over 1 Gbps ≈ 9 days, assuming you have the entire link and zero contention — which you do not. Below roughly 10 TB, or above ~1 Gbps of genuinely spare bandwidth, use the network (DataSync). Above that, ship the box.

> **Currency warning:** AWS has been actively rationalising this family — **AWS Snowmobile (the 100 PB shipping container) was withdrawn in 2024**, and device SKUs and capacities have changed since. CLF-C02 question banks written earlier may still reference retired devices. Verify current offerings and capacities on the Snow Family page (§13) before citing a specific model or TB figure.

### 6.3 Data movement services

| Service | Direction & trigger | Key property |
|---|---|---|
| **AWS DataSync** | On-prem NFS/SMB/HDFS/object ↔ S3/EFS/FSx, and AWS↔AWS | Agent-based, scheduled or one-off, built-in integrity verification, encryption in transit, up to 10× faster than open-source copy tools |
| **AWS Transfer Family** | External parties → S3/EFS over **SFTP, FTPS, FTP, AS2** | Fully managed protocol endpoint; no servers, keeps partners' existing clients working |
| **S3 Transfer Acceleration** | Clients worldwide → one bucket | Routes uploads through the nearest CloudFront edge onto the AWS backbone |
| **AWS Backup** | Policy-driven backup of EBS, EFS, FSx, S3, RDS, Aurora, DynamoDB, DocumentDB, Neptune, EC2, Storage Gateway, VMware | Central vault + lifecycle to cold storage + **Vault Lock (WORM)** + cross-Region/cross-account copy + compliance reporting |

---

## 7. Complete infrastructure — CloudFormation

A single deployable template covering the three primitives with production defaults: customer-managed KMS key, S3 with versioning + lifecycle + TLS-and-encryption-enforcing policy + access logging, EFS with elastic throughput and lifecycle tiering, a gp3 data volume, and an AWS Backup plan with a locked vault.

```yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: >
  Production storage baseline - S3 (object), EFS (file), EBS gp3 (block),
  a customer-managed KMS key, and an AWS Backup plan with a WORM-locked vault.

Parameters:
  ProjectName:
    Type: String
    Default: platform-storage
    AllowedPattern: '^[a-z0-9-]{3,32}$'
    Description: Lowercase name used as a prefix for every resource.

  VpcId:
    Type: AWS::EC2::VPC::Id
    Description: VPC that will host the EFS mount targets.

  PrivateSubnetIds:
    Type: List<AWS::EC2::Subnet::Id>
    Description: Exactly three private subnets, one per Availability Zone.

  AppSecurityGroupId:
    Type: AWS::EC2::SecurityGroup::Id
    Description: Security group attached to the application instances/pods.

  DataVolumeAz:
    Type: AWS::EC2::AvailabilityZone::Name
    Description: AZ for the EBS data volume. Must match the consuming instance.

  DataVolumeSizeGiB:
    Type: Number
    Default: 500
    MinValue: 1
    MaxValue: 16384

  BackupRetentionDays:
    Type: Number
    Default: 35
    MinValue: 1
    MaxValue: 36500

Resources:

  # ------------------------------------------------------------------
  # Encryption - one customer-managed key for all storage in the stack
  # ------------------------------------------------------------------
  StorageKmsKey:
    Type: AWS::KMS::Key
    DeletionPolicy: Retain
    UpdateReplacePolicy: Retain
    Properties:
      Description: !Sub 'CMK for ${ProjectName} S3, EFS and EBS encryption'
      EnableKeyRotation: true
      PendingWindowInDays: 30
      KeyPolicy:
        Version: '2012-10-17'
        Statement:
          - Sid: EnableIAMUserPermissions
            Effect: Allow
            Principal:
              AWS: !Sub 'arn:${AWS::Partition}:iam::${AWS::AccountId}:root'
            Action: 'kms:*'
            Resource: '*'
          - Sid: AllowAwsServicesToUseTheKey
            Effect: Allow
            Principal:
              Service:
                - s3.amazonaws.com
                - elasticfilesystem.amazonaws.com
                - backup.amazonaws.com
            Action:
              - kms:Encrypt
              - kms:Decrypt
              - kms:ReEncrypt*
              - kms:GenerateDataKey*
              - kms:DescribeKey
              - kms:CreateGrant
            Resource: '*'
            Condition:
              StringEquals:
                'kms:CallerAccount': !Ref AWS::AccountId
      Tags:
        - Key: Project
          Value: !Ref ProjectName

  StorageKmsAlias:
    Type: AWS::KMS::Alias
    Properties:
      AliasName: !Sub 'alias/${ProjectName}-storage'
      TargetKeyId: !Ref StorageKmsKey

  # ------------------------------------------------------------------
  # Object storage - access log bucket first, then the data bucket
  # ------------------------------------------------------------------
  AccessLogBucket:
    Type: AWS::S3::Bucket
    DeletionPolicy: Retain
    UpdateReplacePolicy: Retain
    Properties:
      BucketName: !Sub '${ProjectName}-access-logs-${AWS::AccountId}-${AWS::Region}'
      # S3 server access logging cannot write to an SSE-KMS bucket, so this
      # bucket deliberately uses SSE-S3 (AES256) instead of the CMK.
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
      OwnershipControls:
        Rules:
          - ObjectOwnership: BucketOwnerEnforced
      VersioningConfiguration:
        Status: Enabled
      LifecycleConfiguration:
        Rules:
          - Id: expire-access-logs
            Status: Enabled
            ExpirationInDays: 400
            NoncurrentVersionExpiration:
              NoncurrentDays: 30
            AbortIncompleteMultipartUpload:
              DaysAfterInitiation: 7
      Tags:
        - Key: Project
          Value: !Ref ProjectName

  AccessLogBucketPolicy:
    Type: AWS::S3::BucketPolicy
    Properties:
      Bucket: !Ref AccessLogBucket
      PolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Sid: AllowS3ServerAccessLogging
            Effect: Allow
            Principal:
              Service: logging.s3.amazonaws.com
            Action: 's3:PutObject'
            Resource: !Sub '${AccessLogBucket.Arn}/s3-access/*'
            Condition:
              StringEquals:
                'aws:SourceAccount': !Ref AWS::AccountId
          - Sid: DenyInsecureTransport
            Effect: Deny
            Principal: '*'
            Action: 's3:*'
            Resource:
              - !GetAtt AccessLogBucket.Arn
              - !Sub '${AccessLogBucket.Arn}/*'
            Condition:
              Bool:
                'aws:SecureTransport': 'false'

  DataBucket:
    Type: AWS::S3::Bucket
    DeletionPolicy: Retain
    UpdateReplacePolicy: Retain
    Properties:
      BucketName: !Sub '${ProjectName}-data-${AWS::AccountId}-${AWS::Region}'
      BucketEncryption:
        ServerSideEncryptionConfiguration:
          - ServerSideEncryptionByDefault:
              SSEAlgorithm: 'aws:kms'
              KMSMasterKeyID: !GetAtt StorageKmsKey.Arn
            # Bucket Keys cut KMS request cost by up to 99%.
            BucketKeyEnabled: true
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
      LoggingConfiguration:
        DestinationBucketName: !Ref AccessLogBucket
        LogFilePrefix: s3-access/
      LifecycleConfiguration:
        Rules:
          - Id: tier-current-versions
            Status: Enabled
            Prefix: ''
            Transitions:
              # Standard -> Standard-IA is only legal at 30 days or more.
              - StorageClass: STANDARD_IA
                TransitionInDays: 30
              - StorageClass: GLACIER_IR
                TransitionInDays: 90
              - StorageClass: DEEP_ARCHIVE
                TransitionInDays: 365
            Id: tier-current-versions
          - Id: tier-and-expire-noncurrent-versions
            Status: Enabled
            NoncurrentVersionTransitions:
              - StorageClass: STANDARD_IA
                TransitionInDays: 30
            NoncurrentVersionExpiration:
              NoncurrentDays: 180
              NewerNoncurrentVersions: 5
          - Id: housekeeping
            Status: Enabled
            AbortIncompleteMultipartUpload:
              DaysAfterInitiation: 7
            ExpiredObjectDeleteMarker: true
      Tags:
        - Key: Project
          Value: !Ref ProjectName

  DataBucketPolicy:
    Type: AWS::S3::BucketPolicy
    Properties:
      Bucket: !Ref DataBucket
      PolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Sid: DenyInsecureTransport
            Effect: Deny
            Principal: '*'
            Action: 's3:*'
            Resource:
              - !GetAtt DataBucket.Arn
              - !Sub '${DataBucket.Arn}/*'
            Condition:
              Bool:
                'aws:SecureTransport': 'false'
          - Sid: DenyUnencryptedObjectUploads
            Effect: Deny
            Principal: '*'
            Action: 's3:PutObject'
            Resource: !Sub '${DataBucket.Arn}/*'
            Condition:
              StringNotEquals:
                's3:x-amz-server-side-encryption': 'aws:kms'
          - Sid: DenyWrongKmsKey
            Effect: Deny
            Principal: '*'
            Action: 's3:PutObject'
            Resource: !Sub '${DataBucket.Arn}/*'
            Condition:
              StringNotEqualsIfExists:
                's3:x-amz-server-side-encryption-aws-kms-key-id': !GetAtt StorageKmsKey.Arn
          - Sid: DenyOutdatedTlsVersions
            Effect: Deny
            Principal: '*'
            Action: 's3:*'
            Resource:
              - !GetAtt DataBucket.Arn
              - !Sub '${DataBucket.Arn}/*'
            Condition:
              NumericLessThan:
                's3:TlsVersion': '1.2'

  # ------------------------------------------------------------------
  # File storage - EFS, elastic throughput, lifecycle tiering
  # ------------------------------------------------------------------
  EfsSecurityGroup:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: !Sub 'NFS 2049 ingress for ${ProjectName} EFS'
      VpcId: !Ref VpcId
      SecurityGroupIngress:
        - IpProtocol: tcp
          FromPort: 2049
          ToPort: 2049
          SourceSecurityGroupId: !Ref AppSecurityGroupId
          Description: NFSv4.1 from the application security group
      SecurityGroupEgress:
        - IpProtocol: '-1'
          CidrIp: 0.0.0.0/0
          Description: Allow all egress
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-efs-sg'

  SharedFileSystem:
    Type: AWS::EFS::FileSystem
    DeletionPolicy: Retain
    UpdateReplacePolicy: Retain
    Properties:
      Encrypted: true
      KmsKeyId: !GetAtt StorageKmsKey.Arn
      PerformanceMode: generalPurpose
      ThroughputMode: elastic
      BackupPolicy:
        Status: ENABLED
      LifecyclePolicies:
        - TransitionToIA: AFTER_30_DAYS
        - TransitionToArchive: AFTER_90_DAYS
        - TransitionToPrimaryStorageClass: AFTER_1_ACCESS
      FileSystemPolicy:
        Version: '2012-10-17'
        Statement:
          - Sid: EnforceInTransitEncryption
            Effect: Deny
            Principal:
              AWS: '*'
            Action: '*'
            Condition:
              Bool:
                'elasticfilesystem:AccessedViaMountTarget': 'true'
                'aws:SecureTransport': 'false'
      FileSystemTags:
        - Key: Name
          Value: !Sub '${ProjectName}-shared'
        - Key: Project
          Value: !Ref ProjectName

  MountTargetA:
    Type: AWS::EFS::MountTarget
    Properties:
      FileSystemId: !Ref SharedFileSystem
      SubnetId: !Select [0, !Ref PrivateSubnetIds]
      SecurityGroups:
        - !Ref EfsSecurityGroup

  MountTargetB:
    Type: AWS::EFS::MountTarget
    Properties:
      FileSystemId: !Ref SharedFileSystem
      SubnetId: !Select [1, !Ref PrivateSubnetIds]
      SecurityGroups:
        - !Ref EfsSecurityGroup

  MountTargetC:
    Type: AWS::EFS::MountTarget
    Properties:
      FileSystemId: !Ref SharedFileSystem
      SubnetId: !Select [2, !Ref PrivateSubnetIds]
      SecurityGroups:
        - !Ref EfsSecurityGroup

  AppAccessPoint:
    Type: AWS::EFS::AccessPoint
    Properties:
      FileSystemId: !Ref SharedFileSystem
      PosixUser:
        Uid: '1000'
        Gid: '1000'
        SecondaryGids:
          - '1001'
      RootDirectory:
        Path: /app-data
        CreationInfo:
          OwnerUid: '1000'
          OwnerGid: '1000'
          Permissions: '0755'
      AccessPointTags:
        - Key: Name
          Value: !Sub '${ProjectName}-app-ap'

  # ------------------------------------------------------------------
  # Block storage - gp3 with explicit IOPS and throughput
  # ------------------------------------------------------------------
  DataVolume:
    Type: AWS::EC2::Volume
    DeletionPolicy: Snapshot
    UpdateReplacePolicy: Snapshot
    Properties:
      AvailabilityZone: !Ref DataVolumeAz
      Size: !Ref DataVolumeSizeGiB
      VolumeType: gp3
      Iops: 6000
      Throughput: 250
      Encrypted: true
      KmsKeyId: !GetAtt StorageKmsKey.Arn
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-data'
        - Key: BackupPlan
          Value: !Ref ProjectName

  # ------------------------------------------------------------------
  # AWS Backup - one plan for every resource tagged BackupPlan
  # ------------------------------------------------------------------
  BackupVault:
    Type: AWS::Backup::BackupVault
    DeletionPolicy: Retain
    UpdateReplacePolicy: Retain
    Properties:
      BackupVaultName: !Sub '${ProjectName}-vault'
      EncryptionKeyArn: !GetAtt StorageKmsKey.Arn
      LockConfiguration:
        # WORM: recovery points cannot be deleted before MinRetentionDays,
        # not even by the account root. ChangeableForDays is the grace
        # period during which this lock itself can still be removed.
        MinRetentionDays: 7
        MaxRetentionDays: !Ref BackupRetentionDays
        ChangeableForDays: 3

  BackupRole:
    Type: AWS::IAM::Role
    Properties:
      RoleName: !Sub '${ProjectName}-backup-role'
      AssumeRolePolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Effect: Allow
            Principal:
              Service: backup.amazonaws.com
            Action: 'sts:AssumeRole'
      ManagedPolicyArns:
        - !Sub 'arn:${AWS::Partition}:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup'
        - !Sub 'arn:${AWS::Partition}:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForRestores'

  BackupPlan:
    Type: AWS::Backup::BackupPlan
    Properties:
      BackupPlan:
        BackupPlanName: !Sub '${ProjectName}-daily'
        BackupPlanRule:
          - RuleName: daily-0300-utc
            TargetBackupVault: !Ref BackupVault
            ScheduleExpression: 'cron(0 3 * * ? *)'
            StartWindowMinutes: 60
            CompletionWindowMinutes: 180
            EnableContinuousBackup: false
            Lifecycle:
              MoveToColdStorageAfterDays: 30
              DeleteAfterDays: !Ref BackupRetentionDays
            RecoveryPointTags:
              Project: !Ref ProjectName

  BackupSelection:
    Type: AWS::Backup::BackupSelection
    Properties:
      BackupPlanId: !Ref BackupPlan
      BackupSelection:
        SelectionName: !Sub '${ProjectName}-tagged-resources'
        IamRoleArn: !GetAtt BackupRole.Arn
        ListOfTags:
          - ConditionType: STRINGEQUALS
            ConditionKey: BackupPlan
            ConditionValue: !Ref ProjectName

Outputs:
  DataBucketName:
    Description: Object storage bucket
    Value: !Ref DataBucket
    Export:
      Name: !Sub '${ProjectName}-data-bucket'

  FileSystemId:
    Description: EFS file system id
    Value: !Ref SharedFileSystem
    Export:
      Name: !Sub '${ProjectName}-efs-id'

  FileSystemDnsName:
    Description: DNS name for mounting the file system
    Value: !Sub '${SharedFileSystem}.efs.${AWS::Region}.amazonaws.com'

  AccessPointId:
    Description: EFS access point for the application
    Value: !Ref AppAccessPoint
    Export:
      Name: !Sub '${ProjectName}-efs-ap'

  DataVolumeId:
    Description: gp3 data volume id
    Value: !Ref DataVolume

  KmsKeyArn:
    Description: CMK protecting all storage in this stack
    Value: !GetAtt StorageKmsKey.Arn
```

Deploy:

```console
$ aws cloudformation deploy \
    --template-file storage-baseline.yaml \
    --stack-name platform-storage \
    --capabilities CAPABILITY_NAMED_IAM \
    --parameter-overrides \
        ProjectName=platform-storage \
        VpcId=vpc-0a1b2c3d4e5f67890 \
        PrivateSubnetIds=subnet-0aa1,subnet-0bb2,subnet-0cc3 \
        AppSecurityGroupId=sg-041f2e3d4c5b6a798 \
        DataVolumeAz=us-east-1a

Waiting for changeset to be created..
Waiting for stack create/update to complete
Successfully created/updated stack - platform-storage
```

---

## 8. Kubernetes CSI manifests

Same three primitives, expressed through the EBS and EFS CSI drivers on EKS. This is how a platform team actually consumes AWS storage.

```yaml
---
# gp3 block storage. Note WaitForFirstConsumer: an EBS volume is
# AZ-bound, so binding must wait until the scheduler picks a node.
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ebs-gp3-encrypted
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: ebs.csi.aws.com
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
reclaimPolicy: Delete
parameters:
  type: gp3
  iops: "6000"
  throughput: "250"
  encrypted: "true"
  kmsKeyId: arn:aws:kms:us-east-1:111122223333:key/1a2b3c4d-5e6f-7081-92a3-b4c5d6e7f809
  csi.storage.k8s.io/fstype: ext4
  tagSpecification_1: "Project=platform-storage"
  tagSpecification_2: "BackupPlan=platform-storage"
---
# io2 for a latency-critical stateful set.
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ebs-io2-critical
provisioner: ebs.csi.aws.com
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
reclaimPolicy: Retain
parameters:
  type: io2
  iops: "20000"
  encrypted: "true"
  csi.storage.k8s.io/fstype: xfs
---
# Shared EFS with dynamic access-point provisioning. ReadWriteMany
# is possible here and impossible with EBS.
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: efs-shared
provisioner: efs.csi.aws.com
reclaimPolicy: Retain
parameters:
  provisioningMode: efs-ap
  fileSystemId: fs-0c9d8e7f6a5b4c3d2
  directoryPerms: "0755"
  uid: "1000"
  gid: "1000"
  basePath: /dynamic
  subPathPattern: "${.PVC.namespace}/${.PVC.name}"
  ensureUniqueDirectory: "true"
mountOptions:
  - tls
  - iam
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgres-data
  namespace: data
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: ebs-io2-critical
  resources:
    requests:
      storage: 500Gi
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: shared-uploads
  namespace: web
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: efs-shared
  resources:
    requests:
      # EFS is elastic; this value is required by the API but not enforced.
      storage: 100Gi
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgres
  namespace: data
spec:
  serviceName: postgres
  replicas: 1
  selector:
    matchLabels:
      app: postgres
  template:
    metadata:
      labels:
        app: postgres
    spec:
      securityContext:
        fsGroup: 999
      containers:
        - name: postgres
          image: postgres:16.4
          ports:
            - containerPort: 5432
              name: postgres
          env:
            - name: PGDATA
              value: /var/lib/postgresql/data/pgdata
            - name: POSTGRES_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: postgres-credentials
                  key: password
          volumeMounts:
            - name: data
              mountPath: /var/lib/postgresql/data
            - name: scratch
              mountPath: /scratch
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: postgres-data
        - name: scratch
          emptyDir:
            medium: Memory
            sizeLimit: 2Gi
```

---

## 9. CLI walkthroughs with real output

### 9.1 EBS — create, attach, verify, grow

```console
$ aws ec2 create-volume \
    --availability-zone us-east-1a \
    --size 500 \
    --volume-type gp3 \
    --iops 6000 \
    --throughput 250 \
    --encrypted \
    --tag-specifications 'ResourceType=volume,Tags=[{Key=Name,Value=platform-data}]'
{
    "AvailabilityZone": "us-east-1a",
    "CreateTime": "2026-09-04T11:42:18.000Z",
    "Encrypted": true,
    "KmsKeyId": "arn:aws:kms:us-east-1:111122223333:key/1a2b3c4d-5e6f-7081-92a3-b4c5d6e7f809",
    "Size": 500,
    "State": "creating",
    "VolumeId": "vol-0f3a9c81b7e2d4506",
    "Iops": 6000,
    "Throughput": 250,
    "VolumeType": "gp3",
    "MultiAttachEnabled": false
}

$ aws ec2 attach-volume \
    --volume-id vol-0f3a9c81b7e2d4506 \
    --instance-id i-0b7c4e2f19a8d3056 \
    --device /dev/sdf
{
    "AttachTime": "2026-09-04T11:43:02.412000+00:00",
    "Device": "/dev/sdf",
    "InstanceId": "i-0b7c4e2f19a8d3056",
    "State": "attaching",
    "VolumeId": "vol-0f3a9c81b7e2d4506"
}
```

On the instance — note that on Nitro the device name you requested is **not** the device name you get:

```console
$ lsblk
NAME          MAJ:MIN RM  SIZE RO TYPE MOUNTPOINTS
nvme0n1       259:0    0    8G  0 disk
├─nvme0n1p1   259:1    0    8G  0 part /
└─nvme0n1p128 259:2    0    1M  0 part
nvme1n1       259:3    0  500G  0 disk

$ sudo nvme id-ctrl -v /dev/nvme1n1 | grep -i '^sn\|0000:'
sn        : vol0f3a9c81b7e2d4506
0000: 2f 64 65 76 2f 73 64 66 20 20 20 20 20 20 20 20  "/dev/sdf        "

$ sudo mkfs -t xfs /dev/nvme1n1
meta-data=/dev/nvme1n1           isize=512    agcount=4, agsize=32768000 blks
         =                       sectsz=512   attr=2, projid32bit=1
data     =                       bsize=4096   blocks=131072000, imaxpct=25
naming   =version 2              bsize=4096   ascii-ci=0, ftype=1
log      =internal log           bsize=4096   blocks=64000, version=2
realtime =none                   extsz=4096   blocks=0, rtextents=0

$ sudo mkdir -p /data && sudo mount /dev/nvme1n1 /data
$ echo "UUID=$(sudo blkid -s UUID -o value /dev/nvme1n1) /data xfs defaults,nofail 0 2" | sudo tee -a /etc/fstab
UUID=8c2b4f1a-9d3e-4a75-b6c8-1e2f3a4b5c6d /data xfs defaults,nofail 0 2

$ df -hT /data
Filesystem     Type  Size  Used Avail Use% Mounted on
/dev/nvme1n1   xfs   500G  3.6G  497G   1% /data
```

> `nofail` in `/etc/fstab` is not optional. Without it, a missing EBS volume at boot drops the instance into emergency mode and it never reaches SSH.

**Growing the volume online:**

```console
$ aws ec2 modify-volume --volume-id vol-0f3a9c81b7e2d4506 --size 1000 --throughput 500
{
    "VolumeModification": {
        "VolumeId": "vol-0f3a9c81b7e2d4506",
        "ModificationState": "modifying",
        "TargetSize": 1000,
        "TargetIops": 6000,
        "TargetVolumeType": "gp3",
        "TargetThroughput": 500,
        "OriginalSize": 500,
        "OriginalIops": 6000,
        "OriginalThroughput": 250,
        "Progress": 0,
        "StartTime": "2026-09-04T12:10:44.000Z"
    }
}

$ aws ec2 describe-volumes-modifications --volume-id vol-0f3a9c81b7e2d4506 \
    --query 'VolumesModifications[0].[ModificationState,Progress]' --output text
optimizing      100

# The guest still sees the old size until you grow the filesystem:
$ lsblk /dev/nvme1n1
NAME    MAJ:MIN RM  SIZE RO TYPE MOUNTPOINTS
nvme1n1 259:3    0 1000G  0 disk /data

$ df -hT /data
Filesystem     Type  Size  Used Avail Use% Mounted on
/dev/nvme1n1   xfs   500G  3.6G  497G   1% /data      <-- still 500G

$ sudo xfs_growfs /data
data blocks changed from 131072000 to 262144000

$ df -hT /data
Filesystem     Type  Size  Used Avail Use% Mounted on
/dev/nvme1n1   xfs  1000G  3.6G  997G   1% /data
```

For a partitioned device use `sudo growpart /dev/nvme1n1 1` first, then `xfs_growfs` (XFS) or `resize2fs` (ext4).

### 9.2 EFS — mount and verify

```console
$ aws efs describe-file-systems --file-system-id fs-0c9d8e7f6a5b4c3d2 \
    --query 'FileSystems[0].[FileSystemId,LifeCycleState,ThroughputMode,SizeInBytes.Value,Encrypted]' \
    --output table
------------------------------------------------------------------
|                      DescribeFileSystems                       |
+---------------------------+-----------+-----------+------+------+
|  fs-0c9d8e7f6a5b4c3d2     |  available|  elastic  | 4194304 | True |
+---------------------------+-----------+-----------+------+------+

$ sudo dnf install -y amazon-efs-utils
$ sudo mkdir -p /mnt/shared
$ sudo mount -t efs -o tls,iam,accesspoint=fsap-07e6d5c4b3a291807 fs-0c9d8e7f6a5b4c3d2 /mnt/shared

$ mount | grep efs
127.0.0.1:/ on /mnt/shared type nfs4 (rw,relatime,vers=4.1,rsize=1048576,wsize=1048576,namlen=255,hard,noresvport,proto=tcp,port=20450,timeo=600,retrans=2,sec=sys,clientaddr=127.0.0.1,local_lock=none,addr=127.0.0.1)

$ df -hT /mnt/shared
Filesystem     Type  Size  Used Avail Use% Mounted on
127.0.0.1:/    nfs4  8.0E  4.0M  8.0E   1% /mnt/shared
```

The `8.0E` (8 exabytes) is EFS reporting that it is elastic — it is not a quota, and monitoring tools that alert on "disk full" percentages are meaningless here. Note the mount is to `127.0.0.1:20450`: `efs-utils` runs a local `stunnel` process that terminates TLS, which is why `tls` mounts show a loopback address.

### 9.3 S3 — lifecycle, classes, verification

```console
$ aws s3api put-bucket-lifecycle-configuration \
    --bucket platform-storage-data-111122223333-us-east-1 \
    --lifecycle-configuration file://lifecycle.json

$ aws s3api get-bucket-lifecycle-configuration \
    --bucket platform-storage-data-111122223333-us-east-1 \
    --query 'Rules[].[ID,Status,Transitions[].StorageClass]' --output json
[
    [ "tier-current-versions", "Enabled", [ "STANDARD_IA", "GLACIER_IR", "DEEP_ARCHIVE" ] ],
    [ "tier-and-expire-noncurrent-versions", "Enabled", null ],
    [ "housekeeping", "Enabled", null ]
]

$ aws s3api get-bucket-encryption \
    --bucket platform-storage-data-111122223333-us-east-1
{
    "ServerSideEncryptionConfiguration": {
        "Rules": [
            {
                "ApplyServerSideEncryptionByDefault": {
                    "SSEAlgorithm": "aws:kms",
                    "KMSMasterKeyID": "arn:aws:kms:us-east-1:111122223333:key/1a2b3c4d-5e6f-7081-92a3-b4c5d6e7f809"
                },
                "BucketKeyEnabled": true
            }
        ]
    }
}

$ aws s3api get-public-access-block \
    --bucket platform-storage-data-111122223333-us-east-1
{
    "PublicAccessBlockConfiguration": {
        "BlockPublicAcls": true,
        "IgnorePublicAcls": true,
        "BlockPublicPolicy": true,
        "RestrictPublicBuckets": true
    }
}

# What class is each object actually in?
$ aws s3api list-objects-v2 \
    --bucket platform-storage-data-111122223333-us-east-1 \
    --prefix logs/2026/05/ \
    --query 'Contents[].[Key,StorageClass,Size]' --output text | head -5
logs/2026/05/01/app.log.gz      GLACIER_IR      184320122
logs/2026/05/02/app.log.gz      GLACIER_IR      191204488
logs/2026/05/03/app.log.gz      GLACIER_IR      177001923
logs/2026/05/04/app.log.gz      STANDARD_IA     188442017
logs/2026/05/05/app.log.gz      STANDARD_IA     190883311

# Restore an object from Glacier Flexible Retrieval.
$ aws s3api restore-object \
    --bucket platform-storage-archive-111122223333-us-east-1 \
    --key archive/2024/ledger.tar.gz \
    --restore-request 'Days=7,GlacierJobParameters={Tier=Bulk}'

$ aws s3api head-object \
    --bucket platform-storage-archive-111122223333-us-east-1 \
    --key archive/2024/ledger.tar.gz \
    --query '[StorageClass,Restore]' --output text
GLACIER ongoing-request="true"

# ...several hours later (Bulk = 5-12 h):
$ aws s3api head-object \
    --bucket platform-storage-archive-111122223333-us-east-1 \
    --key archive/2024/ledger.tar.gz \
    --query '[StorageClass,Restore]' --output text
GLACIER ongoing-request="false", expiry-date="Fri, 11 Sep 2026 00:00:00 GMT"
```

**Finding money you are burning — incomplete multipart uploads are invisible to `s3 ls`:**

```console
$ aws s3api list-multipart-uploads \
    --bucket platform-storage-data-111122223333-us-east-1 \
    --query 'Uploads[].[Key,Initiated]' --output text | head
backups/db-2026-06-14.dump      2026-06-14T02:11:07.000Z
backups/db-2026-06-21.dump      2026-06-21T02:10:52.000Z
backups/db-2026-07-05.dump      2026-07-05T02:12:31.000Z

$ aws s3 ls s3://platform-storage-data-111122223333-us-east-1/backups/ --human-readable --summarize | tail -3

Total Objects: 42
   Total Size: 1.1 TiB
```

Those three uploads consume storage and appear nowhere in the listing or the total. The `AbortIncompleteMultipartUpload` lifecycle rule in the template exists specifically to reap them.

### 9.4 AWS Backup — verify the plan is actually running

```console
$ aws backup list-backup-jobs --by-state COMPLETED --max-results 3 \
    --query 'BackupJobs[].[ResourceType,ResourceArn,BackupSizeInBytes,CompletionDate]' --output table
-----------------------------------------------------------------------------------------------
|                                       ListBackupJobs                                        |
+--------+-------------------------------------------------------------+------------+---------+
|  EBS   |  arn:aws:ec2:us-east-1:111122223333:volume/vol-0f3a9c81b...  | 41231974400| 2026-09-04T03:14:02Z |
|  EFS   |  arn:aws:elasticfilesystem:us-east-1:111122223333:file-sy... |  4194304   | 2026-09-04T03:22:41Z |
|  S3    |  arn:aws:s3:::platform-storage-data-111122223333-us-east-1   | 1209462784 | 2026-09-04T03:31:19Z |
+--------+-------------------------------------------------------------+------------+---------+

# The only backup metric that matters: did anything FAIL?
$ aws backup list-backup-jobs --by-state FAILED --by-created-after 2026-08-28 \
    --query 'length(BackupJobs)'
0
```

---

## 10. Verification and failure diagnosis

### 10.1 EBS — performance is flat, then suddenly is not

**Symptom:** application latency p99 degrades by 10× hours or days after deployment. `iostat` shows high `await` and `%util` pinned at 100%.

**Diagnosis — check the burst credit balance (gp2, st1, sc1 only):**

```console
$ aws cloudwatch get-metric-statistics \
    --namespace AWS/EBS \
    --metric-name BurstBalance \
    --dimensions Name=VolumeId,Value=vol-0a1b2c3d4e5f60718 \
    --start-time 2026-09-03T00:00:00Z --end-time 2026-09-04T12:00:00Z \
    --period 3600 --statistics Average \
    --query 'sort_by(Datapoints,&Timestamp)[].[Timestamp,Average]' --output text
2026-09-03T00:00:00+00:00       100.0
2026-09-03T06:00:00+00:00       87.4
2026-09-03T12:00:00+00:00       41.2
2026-09-03T18:00:00+00:00       6.8
2026-09-04T00:00:00+00:00       0.0
2026-09-04T06:00:00+00:00       0.0
```

`BurstBalance = 0` is conclusive. **Fix:** `aws ec2 modify-volume --volume-type gp3` — online, no downtime, and usually cheaper.

**Symptom:** volume is provisioned for 40,000 IOPS but never exceeds ~12,000.

**Diagnosis ladder, in order:**

1. **Instance EBS bandwidth ceiling.** Check `describe-instance-types`:

   ```console
   $ aws ec2 describe-instance-types --instance-types m5.large \
       --query 'InstanceTypes[0].EbsInfo.EbsOptimizedInfo' --output json
   {
       "BaselineBandwidthInMbps": 4750,
       "BaselineThroughputInMBps": 593.75,
       "BaselineIops": 18750,
       "MaximumBandwidthInMbps": 4750,
       "MaximumThroughputInMBps": 593.75,
       "MaximumIops": 18750
   }
   ```
   The instance, not the volume, is the constraint. Resize the instance.

2. **I/O size.** EBS counts 256 KiB as one I/O for SSD (1 MiB for HDD). 40,000 IOPS at 4 KiB is 156 MiB/s; at 256 KiB the same 40,000 IOPS is 10 GiB/s — impossible. Small random I/O hits the IOPS ceiling; large sequential I/O hits the throughput ceiling. Know which one you are testing.

3. **Queue depth.** A single-threaded `dd` will never reach high IOPS regardless of provisioning. Benchmark with realistic concurrency:

   ```console
   $ sudo fio --name=randread --filename=/dev/nvme1n1 --rw=randread \
       --bs=16k --iodepth=32 --numjobs=4 --ioengine=libaio --direct=1 \
       --runtime=60 --time_based --group_reporting
   randread: (groupid=0, jobs=4): err= 0: pid=4127: Thu Sep  4 12:31:09 2026
     read: IOPS=5998, BW=93.7MiB/s (98.3MB/s)(5624MiB/60005msec)
       slat (usec): min=2, max=421, avg= 6.11, stdev= 3.88
       clat (usec): min=241, max=48211, avg=21324.77, stdev=2104.31
        lat (usec): min=248, max=48219, avg=21330.88, stdev=2104.29
     ...
   ```
   6,000 IOPS on a volume provisioned at 6,000 — the volume is behaving exactly as configured. The problem is elsewhere.

**Symptom:** a volume restored from a snapshot is slow on first read, then fine.

**Cause:** snapshot-backed volumes **lazy-load** blocks from S3 on first access. The first touch of any block incurs a large latency penalty. **Fix:** enable **Fast Snapshot Restore (FSR)** on the snapshot for the target AZs (fully-initialised on creation, billed per AZ-hour), or pre-warm with `sudo fio --rw=read --bs=1M --iodepth=32 --name=warm --filename=/dev/nvme1n1 --readonly`.

**Symptom:** `An error occurred (VolumeInUse) when calling the AttachVolume operation.`
**Cause:** the volume is attached elsewhere and Multi-Attach is not enabled. Multi-Attach requires io1/io2, Nitro instances in the same AZ, and — critically — **a cluster-aware filesystem** (GFS2, OCFS2). `ext4` or `xfs` on a Multi-Attach volume corrupts within minutes.

**Symptom:** `InvalidParameterValue: The volume 'vol-xxx' is in availability zone us-east-1a, but the instance is in us-east-1b.`
**Cause:** the defining constraint of EBS. Snapshot the volume, create a new volume from the snapshot in the target AZ.

### 10.2 EFS — mount failures, in diagnostic order

```console
$ sudo mount -t efs fs-0c9d8e7f6a5b4c3d2:/ /mnt/shared
mount.nfs4: Connection timed out
```

Cause, ~90% of the time: the mount target's security group does not allow **TCP 2049** from the client's security group. Verify:

```console
$ aws efs describe-mount-targets --file-system-id fs-0c9d8e7f6a5b4c3d2 \
    --query 'MountTargets[].[AvailabilityZoneName,IpAddress,LifeCycleState]' --output text
us-east-1a      10.0.1.87       available
us-east-1b      10.0.2.143      available
us-east-1c      10.0.3.201      available

$ nc -vz 10.0.1.87 2049
Ncat: Connected to 10.0.1.87:2049.
```

If `nc` connects but `mount` still times out, the client is in an AZ with **no mount target** — cross-AZ NFS traffic to a mount target works but adds latency and data-transfer charges; a *missing* mount target in the client's AZ combined with a subnet-scoped route can fail outright.

```console
$ sudo mount -t efs fs-0c9d8e7f6a5b4c3d2:/ /mnt/shared
mount.nfs4: Failed to resolve server fs-0c9d8e7f6a5b4c3d2.efs.us-east-1.amazonaws.com: \
Name or service not known
```

Cause: `enableDnsSupport` or `enableDnsHostnames` is **false** on the VPC, or the client uses a custom resolver that does not forward to the VPC resolver at `VPC_CIDR_base + 2`.

```console
$ aws ec2 describe-vpc-attribute --vpc-id vpc-0a1b2c3d4e5f67890 --attribute enableDnsHostnames \
    --query 'EnableDnsHostnames.Value'
false

$ aws ec2 modify-vpc-attribute --vpc-id vpc-0a1b2c3d4e5f67890 --enable-dns-hostnames
```

```console
$ sudo mount -t efs -o tls,iam fs-0c9d8e7f6a5b4c3d2:/ /mnt/shared
mount.nfs4: access denied by server while mounting 127.0.0.1:/
```

Cause: the file system policy or IAM role denies the mount. With `-o iam`, the instance profile must hold `elasticfilesystem:ClientMount` / `ClientWrite` / `ClientRootAccess`. A file system policy that denies `aws:SecureTransport=false` (as in the template above) will also reject a mount attempted **without** `-o tls`.

**Symptom:** EFS throughput collapses under sustained load.

```console
$ aws cloudwatch get-metric-statistics --namespace AWS/EFS \
    --metric-name BurstCreditBalance \
    --dimensions Name=FileSystemId,Value=fs-0c9d8e7f6a5b4c3d2 \
    --start-time 2026-09-04T00:00:00Z --end-time 2026-09-04T12:00:00Z \
    --period 3600 --statistics Minimum \
    --query 'Datapoints[-1].Minimum'
0.0
```

**Fix:** `aws efs update-file-system --file-system-id fs-... --throughput-mode elastic`.

### 10.3 S3 — the access-denied decision tree

An S3 authorization failure is the union of **five independent evaluations**. All must permit; any one Deny is final.

```
Request
  │
  ├─ 1. Block Public Access (account, then bucket) ──── blocks anonymous/public first
  ├─ 2. Service Control Policy (Organizations) ──────── Deny wins, invisible in the bucket
  ├─ 3. IAM identity policy (user/role) ─────────────── needs an explicit Allow
  ├─ 4. Bucket policy (resource) ───────────────────── explicit Deny wins over any Allow
  ├─ 5. VPC endpoint policy (if via a gateway endpoint) ─ silently restricts buckets
  └─ 6. Object ACL / Object Ownership ──────────────── mostly moot under BucketOwnerEnforced
        + KMS key policy, if SSE-KMS ────────────────── s3:GetObject alone is not enough
```

```console
$ aws s3 cp big.tar.gz s3://platform-storage-data-111122223333-us-east-1/
upload failed: ./big.tar.gz to s3://platform-storage-data-.../big.tar.gz \
An error occurred (AccessDenied) when calling the CreateMultipartUpload operation: \
User: arn:aws:sts::111122223333:assumed-role/deploy-role/i-0b7c4e2f19a8d3056 \
is not authorized to perform: s3:PutObject on resource "..." with an explicit deny \
in a resource-based policy
```

`with an explicit deny in a resource-based policy` names the culprit precisely: the **bucket policy**. Here it is the `DenyUnencryptedObjectUploads` statement — the client did not send `x-amz-server-side-encryption: aws:kms`. Fix by relying on bucket default encryption (which the AWS CLI honours) or passing `--sse aws:kms --sse-kms-key-id <arn>`.

**Reproduce the whole evaluation without touching data — IAM Policy Simulator via CLI:**

```console
$ aws iam simulate-principal-policy \
    --policy-source-arn arn:aws:iam::111122223333:role/deploy-role \
    --action-names s3:PutObject \
    --resource-arns arn:aws:s3:::platform-storage-data-111122223333-us-east-1/test.txt \
    --query 'EvaluationResults[].[EvalActionName,EvalDecision]' --output text
s3:PutObject    implicitDeny
```

**403 where you expected 404.** `GetObject` on a nonexistent key returns **`404 NoSuchKey`** if the caller holds `s3:ListBucket`, and **`403 AccessDenied`** if it does not — S3 refuses to confirm or deny existence. A "permissions bug" that is really a typo in the key is a recurring waste of an on-call hour.

**Lifecycle transition "did not happen."**

```console
$ aws s3api head-object --bucket platform-storage-data-111122223333-us-east-1 \
    --key logs/2026/08/29/app.log.gz --query '[StorageClass,LastModified]' --output text
None    2026-08-29T04:00:11+00:00
```

`StorageClass: None` means `STANDARD` (S3 omits the header for Standard). The object is 6 days old; the rule transitions at 30 days. Nothing is wrong. Additional real causes when the age *is* sufficient: the object is smaller than 128 KB (transitions to IA are skipped as uneconomic), or the transition is scheduled but not yet executed — lifecycle actions run asynchronously and may lag by up to 48 hours, though **billing changes at the scheduled time, not at execution time**.

**Verify the whole fleet at once with Storage Lens:**

```console
$ aws s3control get-storage-lens-configuration \
    --account-id 111122223333 --config-id default-account-dashboard \
    --query 'StorageLensConfiguration.[Id,IsEnabled,AccountLevel.BucketLevel.PrefixLevel]' --output json
[
    "default-account-dashboard",
    true,
    null
]
```

The free tier of Storage Lens gives 28 days of usage metrics across every bucket in the account — this is the fastest way to find the bucket with 40 TB of noncurrent versions nobody knew about.

### 10.4 The verification ladder for any storage change

Run these in order after any storage modification; each is cheap and each catches a distinct class of error.

| # | Check | Command | Passes when |
|---|---|---|---|
| 1 | Resource exists and is `available` | `aws ec2 describe-volumes` / `efs describe-file-systems` / `s3api head-bucket` | State is `available` / exit 0 |
| 2 | Encryption is on, with the right key | `describe-volumes --query '[].Encrypted'`, `s3api get-bucket-encryption` | `true` + expected key ARN |
| 3 | Not publicly reachable | `s3api get-public-access-block`, `s3api get-bucket-policy-status` | all four `true`, `IsPublic: false` |
| 4 | The guest actually sees it | `lsblk`, `df -hT`, `mount \| grep nfs4` | Expected size at expected path |
| 5 | Survives a reboot | `sudo reboot`, then re-run #4 | Mount present without manual action |
| 6 | Performance matches provisioning | `fio` at realistic block size and queue depth | Within ~10% of provisioned |
| 7 | A backup exists **and restores** | `aws backup list-recovery-points-by-backup-vault`, then an actual restore to a scratch resource | Restored data validates |

Step 7 is the one teams skip. An untested backup is a hypothesis, not a control.

---

## 11. Cost model — three worked examples

**(a) 10 TB of application logs, 90 days hot, 7 years retained, us-east-1.**

| Strategy | Monthly cost at steady state | Notes |
|---|---|---|
| All S3 Standard | 10,000 GB × $0.023 = **$230** | Naive |
| Lifecycle → Standard-IA at 30 d → Glacier Deep Archive at 90 d | ≈ 1,000 GB Std ($23) + 2,000 GB IA ($25) + 7,000 GB DA ($6.93) = **$54.93** | 76% saving |
| Intelligent-Tiering with Deep Archive access tier | ≈ **$60–70** incl. monitoring | Correct when access is unpredictable |

**(b) 1 TiB database volume.**

| Option | Monthly | IOPS | Verdict |
|---|---|---|---|
| gp2 1 TiB | $102.40 | 3,000 (bursts to 3,000) | Never choose |
| gp3 1 TiB, 3,000/125 | $81.92 | 3,000 | Baseline default |
| gp3 1 TiB, 16,000 IOPS, 1,000 MiB/s | $81.92 + $65.00 + $35.00 = **$181.92** | 16,000 | Ceiling of gp3 |
| io2 1 TiB, 20,000 IOPS | $128.00 + (32,000-tier pricing on 20,000 × $0.065) = **$1,428.00** | 20,000, 99.999% durability | Only when the 5-nines durability or >16k IOPS is genuinely required |

The gp3→io2 jump is nearly 8× at the same IOPS. io2 buys **durability** and headroom, not just speed; justify it on the durability line, not the IOPS line.

**(c) 2 TB shared filesystem, 5% hot.**

| Option | Monthly |
|---|---|
| EFS Standard, no lifecycle | 2,000 × $0.30 = **$600** |
| EFS with lifecycle (100 GB Standard, 1,900 GB Archive) | $30 + $15.20 = **$45.20** + access charges |
| FSx for OpenZFS (128 MB/s, 2 TB SSD) | ≈ **$500–600** — buy it for the ZFS features, not the price |
| S3 Standard (if the app can be rewritten to object semantics) | 2,000 × $0.023 = **$46** |

---

## 12. Exam disambiguation — the traps CLF-C02 actually sets

| Trap | Wrong instinct | Correct reasoning |
|---|---|---|
| "Durable" vs "available" | Treating 11 nines as an uptime promise | Durability = data survives. Availability = you can reach it now. S3 Standard: 11 nines durable, 99.99% available |
| "S3 is a file system" | Choosing S3 for a shared POSIX mount | S3 is object storage. Shared POSIX = EFS (Linux) or FSx (Windows/Lustre/ONTAP/OpenZFS) |
| "EBS can be shared" | Choosing EBS for ReadWriteMany | Single instance by default; Multi-Attach is io1/io2 + same AZ + cluster FS |
| "Instance store is cheap EBS" | Using it for a database | Data is lost on stop/terminate/host failure |
| "Glacier means slow" | Ruling out Glacier for millisecond needs | **Glacier Instant Retrieval** is millisecond access at $0.004/GB |
| "Cheapest per GB is cheapest" | Deep Archive for 20-day-old data | Minimum billable durations: IA 30 d, Glacier IR/Flexible 90 d, Deep Archive 180 d |
| "One Zone-IA is just cheaper IA" | Using it for irreplaceable data | Single AZ. AZ loss = data loss. Only for reproducible data |
| Gateway vs DataSync | Interchanging them | Gateway *presents* storage on-prem continuously; DataSync *transfers* data on a schedule |
| Snow vs DataSync | Using Snow for 2 TB | Below ~10 TB, or with real spare bandwidth, use the network |
| "Backup = Snapshot" | Assuming snapshots satisfy compliance | AWS Backup adds central policy, cross-Region/account copy, Vault Lock (WORM) and audit reports |
| Object Lock modes | Assuming root can override | **Governance** mode: bypassable with a specific permission. **Compliance** mode: bypassable by nobody, including root |
| "S3 is eventually consistent" | Repeating pre-2020 material | S3 has had **strong read-after-write consistency** since December 2020 |

---

## 13. References

Official AWS sources for every claim in this document:

**Exam**
- AWS Certified Cloud Practitioner (CLF-C02) Exam Guide — https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf
- AWS Certified Cloud Practitioner — certification page — https://aws.amazon.com/certification/certified-cloud-practitioner/

**Block storage**
- Amazon EBS User Guide — https://docs.aws.amazon.com/ebs/latest/userguide/what-is-ebs.html
- EBS volume types — https://docs.aws.amazon.com/ebs/latest/userguide/ebs-volume-types.html
- Amazon EBS Multi-Attach — https://docs.aws.amazon.com/ebs/latest/userguide/ebs-volumes-multi.html
- Modify an EBS volume (Elastic Volumes) — https://docs.aws.amazon.com/ebs/latest/userguide/requesting-ebs-volume-modifications.html
- Amazon EBS Fast Snapshot Restore — https://docs.aws.amazon.com/ebs/latest/userguide/ebs-fast-snapshot-restore.html
- Amazon EC2 instance store — https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/InstanceStorage.html
- Amazon EBS pricing — https://aws.amazon.com/ebs/pricing/

**File storage**
- Amazon EFS User Guide — https://docs.aws.amazon.com/efs/latest/ug/whatisefs.html
- EFS storage classes and lifecycle management — https://docs.aws.amazon.com/efs/latest/ug/storage-classes.html
- EFS performance and throughput modes — https://docs.aws.amazon.com/efs/latest/ug/performance.html
- Troubleshooting Amazon EFS mount issues — https://docs.aws.amazon.com/efs/latest/ug/troubleshooting-efs-mounting.html
- Amazon FSx — https://aws.amazon.com/fsx/
- FSx for Windows File Server — https://docs.aws.amazon.com/fsx/latest/WindowsGuide/what-is.html
- FSx for Lustre — https://docs.aws.amazon.com/fsx/latest/LustreGuide/what-is.html
- FSx for NetApp ONTAP — https://docs.aws.amazon.com/fsx/latest/ONTAPGuide/what-is-fsx-ontap.html
- FSx for OpenZFS — https://docs.aws.amazon.com/fsx/latest/OpenZFSGuide/what-is-fsx.html
- Amazon File Cache — https://docs.aws.amazon.com/fsx/latest/FileCacheGuide/what-is.html

**Object storage**
- Amazon S3 User Guide — https://docs.aws.amazon.com/AmazonS3/latest/userguide/Welcome.html
- S3 storage classes — https://docs.aws.amazon.com/AmazonS3/latest/userguide/storage-class-intro.html
- S3 lifecycle configuration — https://docs.aws.amazon.com/AmazonS3/latest/userguide/object-lifecycle-mgmt.html
- S3 data consistency model — https://docs.aws.amazon.com/AmazonS3/latest/userguide/Welcome.html#ConsistencyModel
- S3 Object Lock — https://docs.aws.amazon.com/AmazonS3/latest/userguide/object-lock.html
- S3 Versioning — https://docs.aws.amazon.com/AmazonS3/latest/userguide/Versioning.html
- S3 Block Public Access — https://docs.aws.amazon.com/AmazonS3/latest/userguide/access-control-block-public-access.html
- S3 default encryption and Bucket Keys — https://docs.aws.amazon.com/AmazonS3/latest/userguide/bucket-key.html
- S3 best practices design patterns (request rates, prefixes) — https://docs.aws.amazon.com/AmazonS3/latest/userguide/optimizing-performance.html
- S3 Express One Zone — https://docs.aws.amazon.com/AmazonS3/latest/userguide/s3-express-one-zone.html
- S3 Storage Lens — https://docs.aws.amazon.com/AmazonS3/latest/userguide/storage_lens.html
- Amazon S3 pricing — https://aws.amazon.com/s3/pricing/

**Hybrid, edge and data movement**
- AWS Storage Gateway — https://docs.aws.amazon.com/storagegateway/latest/userguide/WhatIsStorageGateway.html
- AWS Snow Family — https://docs.aws.amazon.com/snowball/latest/developer-guide/whatissnowball.html
- AWS DataSync — https://docs.aws.amazon.com/datasync/latest/userguide/what-is-datasync.html
- AWS Transfer Family — https://docs.aws.amazon.com/transfer/latest/userguide/what-is-aws-transfer-family.html
- S3 Transfer Acceleration — https://docs.aws.amazon.com/AmazonS3/latest/userguide/transfer-acceleration.html

**Data protection and governance**
- AWS Backup Developer Guide — https://docs.aws.amazon.com/aws-backup/latest/devguide/whatisbackup.html
- AWS Backup Vault Lock — https://docs.aws.amazon.com/aws-backup/latest/devguide/vault-lock.html
- AWS Shared Responsibility Model — https://aws.amazon.com/compliance/shared-responsibility-model/
- AWS Well-Architected Framework — Reliability Pillar — https://docs.aws.amazon.com/wellarchitected/latest/reliability-pillar/welcome.html

**Infrastructure as code and Kubernetes**
- AWS CloudFormation resource reference — https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-template-resource-type-ref.html
- Amazon EBS CSI driver — https://docs.aws.amazon.com/eks/latest/userguide/ebs-csi.html
- Amazon EFS CSI driver — https://docs.aws.amazon.com/eks/latest/userguide/efs-csi.html
- Mountpoint for Amazon S3 CSI driver — https://docs.aws.amazon.com/eks/latest/userguide/s3-csi.html