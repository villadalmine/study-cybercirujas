# 2.3 — Describe Azure storage services

**Exam:** AZ-900 (Microsoft Azure Fundamentals), syllabus version 2026-07-20
**Domain:** Describe Azure architecture and services — **weight 9.62 %**
**Level:** Platform Architect / SRE — production depth

---

## 1. The production problem

Storage is where fundamentals stop being academic. Compute is fungible: a VM dies, the scheduler replaces it, and nobody files an incident. Storage is *stateful* — it is the only layer in the stack where an operator mistake is **not idempotent** and not recoverable by "redeploy". Three failure classes drive almost every real Azure storage postmortem:

1. **Wrong blast-radius unit.** The storage account — not the container, not the share — is the unit of throttling limits, of firewall policy, of encryption key scope, of redundancy configuration, and of regional failover. Teams that put "everything for project X" into one account discover at 03:00 that a batch job's 20,000 req/s ceiling is shared with the customer-facing API, and that `ServerBusy` (503) is returned to *both*.
2. **Wrong durability model for the actual failure being defended against.** LRS survives a disk and a rack. It does **not** survive a datacenter. ZRS survives an availability zone. It does **not** survive a region. GRS survives a region — asynchronously, with a real, measurable, non-zero RPO. Nobody reads the RPO number until after the failover.
3. **Wrong cost/latency tier chosen once and never revisited.** Archive is not "cheap Cool". It is *offline*: a `GET` against an archived blob returns **HTTP 409 `BlobArchived`**, not bytes. Discovering this from an application stack trace during a compliance audit is a common and entirely avoidable outage.

Everything below is organised around those three decisions: **what is the container of risk**, **what does the replication actually guarantee**, and **what is the read path's latency and legality**.

---

## 2. The storage account — the real unit of blast radius

An Azure **storage account** is a globally-unique DNS namespace plus a set of service endpoints, a redundancy configuration, an encryption scope, and a set of hard scalability limits. It is created inside a resource group, in a region, and everything inside it inherits its properties.

### 2.1 Anatomy and endpoints

A single account named `stprodtelemetryeus01` exposes up to six data-plane endpoints:

| Service | Endpoint FQDN | Protocol |
|---|---|---|
| Blob | `https://stprodtelemetryeus01.blob.core.windows.net` | REST/HTTPS |
| Data Lake Gen2 (HNS) | `https://stprodtelemetryeus01.dfs.core.windows.net` | REST/HTTPS |
| File | `https://stprodtelemetryeus01.file.core.windows.net` | SMB 3.1.1 / NFS 4.1 / REST |
| Queue | `https://stprodtelemetryeus01.queue.core.windows.net` | REST/HTTPS |
| Table | `https://stprodtelemetryeus01.table.core.windows.net` | REST/HTTPS |
| Static website | `https://stprodtelemetryeus01.z13.web.core.windows.net` | HTTPS |

With read-access geo-redundancy the secondary is the same name with a `-secondary` suffix on the account label: `https://stprodtelemetryeus01-secondary.blob.core.windows.net`.

**Naming constraints (exam-relevant and operationally painful):** 3–24 characters, **lowercase letters and digits only**, **globally unique across all of Azure**. No hyphens, no underscores. This is why account names look like `stprodtelemetryeus01` rather than `st-prod-telemetry-eus-01`.

### 2.2 Account types

| Account type (`kind` / SKU family) | Backing media | Services supported | Tiers available | Typical use |
|---|---|---|---|---|
| **General-purpose v2** (`StorageV2`, Standard) | HDD | Blob, File, Queue, Table, Disk (page blobs) | Hot, Cool, Cold, Archive | Default for ~90 % of workloads |
| **Premium block blobs** (`BlockBlobStorage`) | SSD | Block + append blobs only | Premium only (no Cool/Cold/Archive) | High transaction rate, small objects, single-digit-ms latency |
| **Premium file shares** (`FileStorage`) | SSD | Azure Files only | Premium (provisioned) | SMB/NFS shares needing consistent low latency; **NFS 4.1 requires this type** |
| **Premium page blobs** (`StorageV2`, Premium) | SSD | Page blobs | Premium | Unmanaged disks / niche; managed disks are preferred |
| **General-purpose v1** (`Storage`) — legacy | HDD | Blob, File, Queue, Table | No access tiers | Legacy only; upgrade to v2 |
| **Blob storage** (`BlobStorage`) — legacy | HDD | Blobs only | Hot, Cool, Archive | Legacy only |

> **Architect's rule:** create GPv2 unless you have a measured requirement that only Premium satisfies. Premium changes the *billing model* (you pay for provisioned capacity, not consumed), which is a bigger cost surprise than the per-GB price difference.

### 2.3 Hard limits — why one account is not "one project"

| Limit | Default value |
|---|---|
| Maximum capacity per account | **5 PiB** (higher on request) |
| Maximum request rate per account | **20,000 requests/s** |
| Maximum ingress (LRS/ZRS, most regions) | 60 Gbps |
| Maximum egress (LRS/ZRS, most regions) | 120 Gbps |
| Storage accounts per region per subscription | 250 (soft, raisable to 500) |
| Maximum single block blob | ~190.7 TiB (50,000 blocks × 4000 MiB) |
| Maximum standard file share | 100 TiB (large file shares enabled) |
| Maximum queue message | 64 KiB |
| Maximum table entity | 1 MiB |

**These limits are the account, not the container.** A `ThrottlingError` on one container degrades every other container, share and queue in the same account. Segment accounts by *throughput profile and failure domain*, not by org chart.

---

## 3. The five storage services

### 3.1 Feature comparison

| | **Blob** | **Files** | **Queue** | **Table** | **Managed Disks** |
|---|---|---|---|---|---|
| Data model | Flat object store (virtual dirs via `/`) | Hierarchical file system | FIFO-ish message log | Key/attribute NoSQL | Block device (page blob) |
| Access protocol | HTTPS REST, SDK, NFS 3.0 (opt-in), SFTP (opt-in) | SMB 2.1/3.x, NFS 4.1, REST | HTTPS REST | HTTPS REST, OData | Attached to a VM as `/dev/sdX` |
| Concurrency model | Optimistic (ETag), lease | POSIX/SMB locking | Visibility timeout, at-least-once | Optimistic (ETag) | Single-writer (unless shared disk) |
| Max object size | ~190.7 TiB (block blob) | 4 TiB per file | 64 KiB per message | 1 MiB per entity | 64 TiB |
| Mountable as a filesystem | Only via `blobfuse2` / NFS 3.0 | Natively (`net use`, `mount -t cifs`) | No | No | Yes |
| Key for lookup | Container + blob name | Share + path | Queue name | PartitionKey + RowKey | LUN |
| Tiering (Hot/Cool/Cold/Archive) | **Yes** | Transaction-optimized / Hot / Cool (standard only) | No | No | No (SKU choice instead) |
| Typical SRE use | Logs, backups, artifacts, media, data lake | Lift-and-shift shared drives, config shares, AKS RWX volumes | Decoupling components, retry buffers | Config/metadata store, device registry | VM OS/data disks, databases |

### 3.2 Blob types — an exam trap and a real design constraint

| Blob type | Written by | Optimised for | Max size | Tierable |
|---|---|---|---|---|
| **Block blob** | `Put Block` + `Put Block List` | Sequential upload of discrete objects | 190.7 TiB | Yes |
| **Append blob** | `Append Block` (atomic append only) | Logging, audit trails | ~195 GiB | Yes |
| **Page blob** | `Put Page` (512-byte-aligned random write) | Random-access I/O — VHDs | 8 TiB (32 TiB premium) | No |

You cannot change a blob's type in place. Uploading a VHD with `azcopy` default settings creates a *block* blob; attaching it as an unmanaged disk then fails. This is why **managed disks** exist — Azure owns the page blob and the account.

### 3.3 Decision matrix

| If the requirement is… | Choose | Because |
|---|---|---|
| Many readers, HTTP-addressable, unbounded growth | **Blob** | No filesystem semantics needed; cheapest per GB; tierable |
| Legacy app expects `\\server\share` or a POSIX mount | **Files** | Only service with native SMB/NFS; no code change |
| Multiple pods need ReadWriteMany | **Files** (or Blob NFS) | Managed Disks are ReadWriteOnce |
| Buffer work between a producer and a consumer, no ordering guarantee needed | **Queue** | 64 KiB messages, ~$0.0004/10k ops, no broker to operate |
| Ordered, transactional, exactly-once, topics/subscriptions | *Not Storage Queues* — **Service Bus** | Storage Queues are at-least-once, best-effort ordering |
| Sparse, schemaless key/value at massive scale, no joins | **Table** | Cheapest NoSQL in Azure; upgrade path to Cosmos DB Table API |
| Block device for an OS or a database engine | **Managed Disk** | Only service exposing raw block I/O with guaranteed IOPS |
| Analytics over petabytes with directory-level ACLs | **Blob + Hierarchical Namespace** (ADLS Gen2) | Atomic directory rename + POSIX ACLs on the `dfs` endpoint |

---

## 4. Redundancy — what each option actually survives

### 4.1 The four (six) options

| Option | Copies | Placement | Annual durability | Survives | Does **not** survive | Read from secondary |
|---|---|---|---|---|---|---|
| **LRS** — Locally redundant | 3 | 3 fault domains in **one datacenter** | 11 nines (99.999999999 %) | Disk, node, rack failure | Datacenter fire/flood; region loss | n/a |
| **ZRS** — Zone redundant | 3 | 3 **availability zones**, one region | 12 nines | Loss of an entire AZ | Region loss | n/a |
| **GRS** — Geo redundant | 6 | LRS in primary + LRS in paired region | 16 nines | Region loss (via failover) | AZ loss without downtime | No |
| **RA-GRS** | 6 | Same as GRS | 16 nines | Region loss | AZ loss without downtime | **Yes** (`-secondary`) |
| **GZRS** — Geo-zone redundant | 6 | ZRS in primary + LRS in secondary | 16 nines | AZ loss **and** region loss | — | No |
| **RA-GZRS** | 6 | Same as GZRS | 16 nines | AZ loss **and** region loss | — | **Yes** (`-secondary`) |

### 4.2 The details that break production

**Geo-replication is asynchronous.** Writes are committed to the primary and acknowledged *before* replication to the secondary. Microsoft's stated objective is an **RPO of less than 15 minutes**. There is no synchronous cross-region option in Azure Storage. If your RPO is zero, the answer is application-level dual-write or a different service — not a redundancy dropdown.

**The secondary is read-only until failover.** With RA-GRS you can `GET` from `-secondary`, but you cannot `PUT`. Applications must know which endpoint they are talking to.

**Check staleness before trusting the secondary:**

```bash
$ az storage account show \
    --name stprodtelemetryeus01 \
    --resource-group rg-platform-prod \
    --expand geoReplicationStats \
    --query "geoReplicationStats" -o json
{
  "canFailover": true,
  "canPlannedFailover": true,
  "lastSyncTime": "2026-09-04T11:47:12+00:00",
  "postFailoverRedundancy": "Standard_LRS",
  "postPlannedFailoverRedundancy": "Standard_GRS",
  "status": "Live"
}
```

`lastSyncTime` is the timestamp before which **all** primary writes are guaranteed durable on the secondary. Writes after it may or may not be there. `now() - lastSyncTime` **is your current RPO**. Alert on it.

**Unplanned failover is destructive to your redundancy posture.** Note `postFailoverRedundancy: Standard_LRS` above: after an unplanned failover, the account becomes **LRS in the new primary region**. Data written to the old primary after `lastSyncTime` is **lost**. You must manually re-enable geo-redundancy afterwards, and re-replication of a large account takes hours to days.

```bash
# Unplanned failover — used when the primary region is genuinely unavailable.
$ az storage account failover \
    --name stprodtelemetryeus01 \
    --resource-group rg-platform-prod \
    --yes
```

```bash
# Planned failover — primary is healthy; zero data loss; preserves geo-redundancy.
# Used for DR drills and region migrations.
$ az storage account failover \
    --name stprodtelemetryeus01 \
    --resource-group rg-platform-prod \
    --failover-type Planned \
    --yes
```

**Run planned failover as a scheduled game day.** A DR configuration that has never been exercised is a hypothesis, not a control.

**Changing redundancy is not always a metadata operation.** LRS ↔ ZRS in-region conversion is supported (customer-initiated conversion or live migration request), and adding geo-redundancy is a metadata change plus a background copy. But **ZRS → GZRS across some paths, and any change of region, require a manual data copy** — plan with `azcopy sync`, not a portal dropdown.

---

## 5. Access tiers and lifecycle

### 5.1 The four blob tiers

| Tier | Online? | Storage cost | Access (read) cost | Minimum retention | First-byte latency | Availability SLA (LRS/GRS read) |
|---|---|---|---|---|---|---|
| **Hot** | Yes | Highest | Lowest | none | milliseconds | 99.9 % (99.99 % RA-GRS read) |
| **Cool** | Yes | Lower | Higher | **30 days** | milliseconds | 99 % (99.9 % RA-GRS read) |
| **Cold** | Yes | Lower still | Higher still | **90 days** | milliseconds | 99 % (99.9 % RA-GRS read) |
| **Archive** | **No — offline** | Lowest | Highest | **180 days** | **hours** (rehydration) | 99 % (99.9 % RA-GRS read) |

**Rules that catch people:**

- The account **default access tier** can be `Hot`, `Cool`, or `Cold`. **`Archive` is blob-level only** — there is no "archive storage account".
- Access tiers apply to **block blobs and append blobs**. Page blobs (disks) have no tiers; you pick a disk SKU instead.
- **Premium block blob accounts do not support Cool/Cold/Archive.** To tier premium data you must copy it to a standard account.
- **Early deletion penalty:** deleting or re-tiering a blob before its minimum retention elapses bills you for the *remaining* days at that tier's rate. A lifecycle policy that moves data Hot → Cool → Archive on days 30/60 charges a 30-day Cool early-deletion penalty on every object, forever. Respect the minimums in the policy (`daysAfterLastTierChangeGreaterThan` exists for exactly this).

### 5.2 Rehydration from Archive

An archived blob is unreadable. `GET` returns:

```
HTTP/1.1 409 Conflict
x-ms-error-code: BlobArchived
```

Two ways out:

1. **Set Blob Tier** — rehydrate in place to Hot/Cool/Cold. The blob is unreadable during rehydration.
2. **Copy Blob** — copy to a new online blob; the archived original stays archived and readable-as-archived (i.e. still not readable). Preferred, because the source is untouched.

| Rehydrate priority | Latency (SLO) | Cost |
|---|---|---|
| `Standard` | may take **up to 15 hours** | lower |
| `High` | may complete in **under 1 hour** for objects < 10 GiB | significantly higher |

```bash
$ az storage blob set-tier \
    --account-name stprodtelemetryeus01 \
    --container-name audit \
    --name 2024/q1/ledger.parquet \
    --tier Hot \
    --rehydrate-priority High \
    --auth-mode login

$ az storage blob show \
    --account-name stprodtelemetryeus01 \
    --container-name audit --name 2024/q1/ledger.parquet \
    --auth-mode login \
    --query "properties.{tier:blobTier, status:rehydrationStatus, inferred:blobTierInferred}" -o table
Tier     Status                Inferred
-------  --------------------  ----------
Archive  rehydrate-pending-to-hot  False
```

`Tier` stays `Archive` and `Status` reads `rehydrate-pending-to-hot` for the whole rehydration window. Application code must poll `x-ms-rehydrate-priority` / `x-ms-archive-status`, not assume synchronous availability. **Design the retrieval SLA around 15 hours, not 1.**

### 5.3 Complete lifecycle management policy

Lifecycle rules are evaluated once per day by the platform; the first run after enabling a policy can take up to 48 hours.

```json
{
  "rules": [
    {
      "enabled": true,
      "name": "telemetry-tier-and-expire",
      "type": "Lifecycle",
      "definition": {
        "filters": {
          "blobTypes": [ "blockBlob" ],
          "prefixMatch": [ "telemetry/raw/", "telemetry/enriched/" ],
          "blobIndexMatch": [
            { "name": "retentionClass", "op": "==", "value": "standard" }
          ]
        },
        "actions": {
          "baseBlob": {
            "tierToCool":    { "daysAfterModificationGreaterThan": 30 },
            "tierToCold":    { "daysAfterModificationGreaterThan": 120 },
            "tierToArchive": {
              "daysAfterModificationGreaterThan": 365,
              "daysAfterLastTierChangeGreaterThan": 90
            },
            "delete":        { "daysAfterModificationGreaterThan": 2555 }
          },
          "snapshot": {
            "tierToCool":    { "daysAfterCreationGreaterThan": 30 },
            "tierToArchive": { "daysAfterCreationGreaterThan": 180 },
            "delete":        { "daysAfterCreationGreaterThan": 365 }
          },
          "version": {
            "tierToCool":    { "daysAfterCreationGreaterThan": 30 },
            "tierToArchive": { "daysAfterCreationGreaterThan": 180 },
            "delete":        { "daysAfterCreationGreaterThan": 730 }
          }
        }
      }
    },
    {
      "enabled": true,
      "name": "purge-incomplete-multipart-uploads",
      "type": "Lifecycle",
      "definition": {
        "filters": {
          "blobTypes": [ "blockBlob" ]
        },
        "actions": {
          "baseBlob": {
            "delete": { "daysAfterCreationGreaterThan": 7 }
          }
        }
      }
    }
  ]
}
```

```bash
$ az storage account management-policy create \
    --account-name stprodtelemetryeus01 \
    --resource-group rg-platform-prod \
    --policy @lifecycle-policy.json \
    --query "policy.rules[].name" -o tsv
telemetry-tier-and-expire
purge-incomplete-multipart-uploads
```

> The second rule matters more than it looks: uncommitted blocks from failed multi-part uploads are **billed** but invisible to `az storage blob list`. They are a classic "our storage bill grew 40 % and nobody knows why" root cause.

---

## 6. Managed disks

A managed disk is a page blob whose storage account Azure owns and hides. That single abstraction removes per-account IOPS contention between VMs, which is why unmanaged disks are deprecated.

### 6.1 SKU comparison

| SKU | Media | Max size | Max IOPS | Max throughput | Latency | IOPS model | Notes |
|---|---|---|---|---|---|---|---|
| **Ultra Disk** | NVMe SSD | 64 TiB | 400,000 | 10,000 MB/s | sub-millisecond | Independently configurable, adjustable live | No host caching; zonal placement constraints; highest cost |
| **Premium SSD v2** | SSD | 64 TiB | 80,000 | 1,200 MB/s | sub-millisecond | Independently configurable (3,000 IOPS + 125 MB/s free baseline) | No host caching; best price/perf for demanding tier-1 |
| **Premium SSD** (P1–P80) | SSD | 32 TiB | 20,000 | 900 MB/s | low single-digit ms | Fixed per size tier; bursting available | Required for VM SLA of 99.9 % single-instance |
| **Standard SSD** (E1–E80) | SSD | 32 TiB | 6,000 | 750 MB/s | ms, variable | Fixed per size tier | Dev/test, light production, web servers |
| **Standard HDD** (S1–S80) | HDD | 32 TiB | 2,000 | 500 MB/s | tens of ms, variable | Fixed per size tier | Backup, archival, non-latency-sensitive |

Zone-redundant variants exist for Premium SSD and Standard SSD (`Premium_ZRS`, `StandardSSD_ZRS`), which allow a disk to be attached to a VM in a different zone after a zone failure — the basis for zone-resilient stateful workloads.

**Key exam distinction:** disk *size tier determines performance* for Premium SSD / Standard SSD / Standard HDD. Provisioning a 32 GiB P4 disk and expecting 20,000 IOPS is the single most common storage performance ticket. Premium SSD v2 and Ultra break that coupling.

---

## 7. Identity, network and encryption (the parts that produce 403s)

**Encryption at rest is not optional and not configurable off.** All data is encrypted with 256-bit AES (Storage Service Encryption), FIPS 140-2 compliant. You choose *who holds the key*:

- **Microsoft-managed keys (MMK)** — default, zero operational burden.
- **Customer-managed keys (CMK)** — an RSA key in Azure Key Vault or Managed HSM; the storage account needs a managed identity with `get`/`wrapKey`/`unwrapKey`. **If the key is deleted or the vault firewall blocks the account, the entire account returns `KeyVaultEncryptionKeyNotFound` and becomes unreadable.**
- **Infrastructure encryption** — a second, independent 256-bit AES layer. Must be enabled **at account creation**; it cannot be turned on later.

**Authorization, in order of preference:**

| Mechanism | Identity | Revocable | Auditable | Verdict |
|---|---|---|---|---|
| **Microsoft Entra ID + RBAC** | User/service principal/managed identity | Instantly | Fully (caller identity in logs) | **Use this** |
| **User delegation SAS** | Signed with an Entra-issued key | Yes (revoke the delegation key) | Yes | Best SAS variant |
| **Service SAS / Account SAS** | Signed with the account key | Only by rotating the key | Caller identity unknown | Avoid for humans |
| **Shared Key (account key)** | The account itself | Rotate both keys | No | **Disable it** |

```bash
$ az storage account update \
    --name stprodtelemetryeus01 --resource-group rg-platform-prod \
    --allow-shared-key-access false \
    --min-tls-version TLS1_2 \
    --allow-blob-public-access false \
    --https-only true \
    --query "{sharedKey:allowSharedKeyAccess, tls:minimumTlsVersion, publicBlob:allowBlobPublicAccess}" -o table
SharedKey    Tls        PublicBlob
-----------  ---------  ------------
False        TLS1_2     False
```

**RBAC roles that matter (data plane, not control plane):**

| Role | Grants |
|---|---|
| `Storage Blob Data Reader` | Read blobs and containers |
| `Storage Blob Data Contributor` | Read/write/delete blobs |
| `Storage Blob Data Owner` | Above + POSIX ACL management (ADLS Gen2) |
| `Storage File Data SMB Share Contributor` | SMB read/write on shares |
| `Storage Queue Data Message Processor` | Peek/get/delete messages |

> `Owner` or `Contributor` at the resource level does **not** grant data-plane access to blobs when Shared Key is disabled. This is deliberate and it is the #1 source of "I'm subscription Owner and I get 403".

---

## 8. Infrastructure as code — complete definitions

### 8.1 Bicep — hardened storage account, private endpoint, lifecycle, file share

```bicep
// storage.bicep — production-grade Azure Storage account with private networking,
// customer-managed keys, immutable audit container and a lifecycle policy.
targetScope = 'resourceGroup'

@minLength(3)
@maxLength(24)
param storageAccountName string

param location string = resourceGroup().location

@allowed([
  'Standard_LRS'
  'Standard_ZRS'
  'Standard_GRS'
  'Standard_GZRS'
  'Standard_RAGRS'
  'Standard_RAGZRS'
  'Premium_LRS'
  'Premium_ZRS'
])
param skuName string = 'Standard_GZRS'

@allowed([ 'Hot' 'Cool' 'Cold' ])
param defaultAccessTier string = 'Hot'

@description('Resource ID of the subnet that will host the private endpoints.')
param privateEndpointSubnetId string

@description('Resource ID of the privatelink.blob.core.windows.net private DNS zone.')
param blobPrivateDnsZoneId string

@description('Resource ID of the privatelink.file.core.windows.net private DNS zone.')
param filePrivateDnsZoneId string

param tags object = {
  environment: 'production'
  costCenter: 'platform'
  dataClassification: 'confidential'
}

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  tags: tags
  sku: {
    name: skuName
  }
  kind: 'StorageV2'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    accessTier: defaultAccessTier
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    allowCrossTenantReplication: false
    defaultToOAuthAuthentication: true
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    publicNetworkAccess: 'Disabled'
    isHnsEnabled: false
    isSftpEnabled: false
    isLocalUserEnabled: false
    largeFileSharesState: 'Enabled'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Deny'
      ipRules: []
      virtualNetworkRules: []
    }
    encryption: {
      keySource: 'Microsoft.Storage'
      requireInfrastructureEncryption: true
      services: {
        blob: {
          enabled: true
          keyType: 'Account'
        }
        file: {
          enabled: true
          keyType: 'Account'
        }
        queue: {
          enabled: true
          keyType: 'Account'
        }
        table: {
          enabled: true
          keyType: 'Account'
        }
      }
    }
    sasPolicy: {
      sasExpirationPeriod: '01.00:00:00'
      expirationAction: 'Log'
    }
    keyPolicy: {
      keyExpirationPeriodInDays: 90
    }
  }
}

resource blobServices 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storageAccount
  name: 'default'
  properties: {
    isVersioningEnabled: true
    changeFeed: {
      enabled: true
      retentionInDays: 90
    }
    restorePolicy: {
      enabled: true
      days: 29
    }
    deleteRetentionPolicy: {
      enabled: true
      days: 30
      allowPermanentDelete: false
    }
    containerDeleteRetentionPolicy: {
      enabled: true
      days: 30
    }
    cors: {
      corsRules: []
    }
  }
}

resource telemetryContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobServices
  name: 'telemetry'
  properties: {
    publicAccess: 'None'
    metadata: {
      owner: 'observability'
    }
  }
}

resource auditContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobServices
  name: 'audit'
  properties: {
    publicAccess: 'None'
    immutableStorageWithVersioning: {
      enabled: true
    }
  }
}

resource auditImmutabilityPolicy 'Microsoft.Storage/storageAccounts/blobServices/containers/immutabilityPolicies@2023-05-01' = {
  parent: auditContainer
  name: 'default'
  properties: {
    immutabilityPeriodSinceCreationInDays: 2555
    allowProtectedAppendWrites: true
  }
}

resource lifecyclePolicy 'Microsoft.Storage/storageAccounts/managementPolicies@2023-05-01' = {
  parent: storageAccount
  name: 'default'
  properties: {
    policy: {
      rules: [
        {
          enabled: true
          name: 'telemetry-tier-and-expire'
          type: 'Lifecycle'
          definition: {
            filters: {
              blobTypes: [ 'blockBlob' ]
              prefixMatch: [ 'telemetry/raw/' ]
            }
            actions: {
              baseBlob: {
                tierToCool: {
                  daysAfterModificationGreaterThan: 30
                }
                tierToCold: {
                  daysAfterModificationGreaterThan: 120
                }
                tierToArchive: {
                  daysAfterModificationGreaterThan: 365
                  daysAfterLastTierChangeGreaterThan: 90
                }
                delete: {
                  daysAfterModificationGreaterThan: 2555
                }
              }
              version: {
                tierToArchive: {
                  daysAfterCreationGreaterThan: 90
                }
                delete: {
                  daysAfterCreationGreaterThan: 730
                }
              }
            }
          }
        }
      ]
    }
  }
}

resource fileServices 'Microsoft.Storage/storageAccounts/fileServices@2023-05-01' = {
  parent: storageAccount
  name: 'default'
  properties: {
    shareDeleteRetentionPolicy: {
      enabled: true
      days: 14
    }
    protocolSettings: {
      smb: {
        versions: 'SMB3.0;SMB3.1.1'
        authenticationMethods: 'Kerberos'
        kerberosTicketEncryption: 'AES-256'
        channelEncryption: 'AES-256-GCM'
      }
    }
  }
}

resource appConfigShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2023-05-01' = {
  parent: fileServices
  name: 'app-config'
  properties: {
    accessTier: 'TransactionOptimized'
    shareQuota: 5120
    enabledProtocols: 'SMB'
  }
}

resource blobPrivateEndpoint 'Microsoft.Network/privateEndpoints@2023-11-01' = {
  name: 'pe-${storageAccountName}-blob'
  location: location
  tags: tags
  properties: {
    subnet: {
      id: privateEndpointSubnetId
    }
    privateLinkServiceConnections: [
      {
        name: 'plsc-blob'
        properties: {
          privateLinkServiceId: storageAccount.id
          groupIds: [ 'blob' ]
          requestMessage: 'Managed by platform IaC'
        }
      }
    ]
  }
}

resource blobPrivateDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-11-01' = {
  parent: blobPrivateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'privatelink-blob-core-windows-net'
        properties: {
          privateDnsZoneId: blobPrivateDnsZoneId
        }
      }
    ]
  }
}

resource filePrivateEndpoint 'Microsoft.Network/privateEndpoints@2023-11-01' = {
  name: 'pe-${storageAccountName}-file'
  location: location
  tags: tags
  properties: {
    subnet: {
      id: privateEndpointSubnetId
    }
    privateLinkServiceConnections: [
      {
        name: 'plsc-file'
        properties: {
          privateLinkServiceId: storageAccount.id
          groupIds: [ 'file' ]
        }
      }
    ]
  }
}

resource filePrivateDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-11-01' = {
  parent: filePrivateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'privatelink-file-core-windows-net'
        properties: {
          privateDnsZoneId: filePrivateDnsZoneId
        }
      }
    ]
  }
}

output storageAccountId string = storageAccount.id
output storageAccountPrincipalId string = storageAccount.identity.principalId
output blobEndpoint string = storageAccount.properties.primaryEndpoints.blob
output fileEndpoint string = storageAccount.properties.primaryEndpoints.file
```

Deploy and verify:

```bash
$ az deployment group create \
    --resource-group rg-platform-prod \
    --template-file storage.bicep \
    --parameters storageAccountName=stprodtelemetryeus01 \
                 skuName=Standard_GZRS \
                 privateEndpointSubnetId="/subscriptions/8f1c.../resourceGroups/rg-net-prod/providers/Microsoft.Network/virtualNetworks/vnet-hub-eus/subnets/snet-privatelink" \
                 blobPrivateDnsZoneId="/subscriptions/8f1c.../resourceGroups/rg-net-prod/providers/Microsoft.Network/privateDnsZones/privatelink.blob.core.windows.net" \
                 filePrivateDnsZoneId="/subscriptions/8f1c.../resourceGroups/rg-net-prod/providers/Microsoft.Network/privateDnsZones/privatelink.file.core.windows.net" \
    --query "properties.{state:provisioningState, duration:duration}" -o table
State       Duration
----------  ----------------
Succeeded   PT2M41.9182633S
```

### 8.2 Terraform equivalent

```hcl
terraform {
  required_version = ">= 1.7.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

provider "azurerm" {
  features {
    storage {
      data_plane_available = true
    }
  }
  storage_use_azuread = true
}

variable "storage_account_name" {
  type        = string
  description = "Globally unique, 3-24 lowercase alphanumeric characters."
  validation {
    condition     = can(regex("^[a-z0-9]{3,24}$", var.storage_account_name))
    error_message = "Storage account names must be 3-24 lowercase letters and digits only."
  }
}

variable "resource_group_name" { type = string }
variable "location"            { type = string }
variable "private_endpoint_subnet_id" { type = string }
variable "blob_private_dns_zone_id"   { type = string }

resource "azurerm_storage_account" "this" {
  name                             = var.storage_account_name
  resource_group_name              = var.resource_group_name
  location                         = var.location
  account_kind                     = "StorageV2"
  account_tier                     = "Standard"
  account_replication_type         = "GZRS"
  access_tier                      = "Hot"
  https_traffic_only_enabled       = true
  min_tls_version                  = "TLS1_2"
  allow_nested_items_to_be_public  = false
  shared_access_key_enabled        = false
  default_to_oauth_authentication  = true
  public_network_access_enabled    = false
  cross_tenant_replication_enabled = false
  infrastructure_encryption_enabled = true
  large_file_share_enabled         = true

  identity {
    type = "SystemAssigned"
  }

  blob_properties {
    versioning_enabled            = true
    change_feed_enabled           = true
    change_feed_retention_in_days = 90
    last_access_time_enabled      = true

    delete_retention_policy {
      days = 30
    }

    container_delete_retention_policy {
      days = 30
    }

    restore_policy {
      days = 29
    }
  }

  share_properties {
    retention_policy {
      days = 14
    }
    smb {
      versions                        = ["SMB3.0", "SMB3.1.1"]
      authentication_types            = ["Kerberos"]
      kerberos_ticket_encryption_type = ["AES-256"]
      channel_encryption_type         = ["AES-256-GCM"]
    }
  }

  sas_policy {
    expiration_period = "01.00:00:00"
    expiration_action = "Log"
  }

  network_rules {
    default_action = "Deny"
    bypass         = ["AzureServices"]
    ip_rules       = []
  }

  tags = {
    environment        = "production"
    costCenter         = "platform"
    dataClassification = "confidential"
  }
}

resource "azurerm_storage_container" "telemetry" {
  name                  = "telemetry"
  storage_account_id    = azurerm_storage_account.this.id
  container_access_type = "private"
}

resource "azurerm_storage_management_policy" "lifecycle" {
  storage_account_id = azurerm_storage_account.this.id

  rule {
    name    = "telemetry-tier-and-expire"
    enabled = true

    filters {
      prefix_match = ["telemetry/raw/"]
      blob_types   = ["blockBlob"]
    }

    actions {
      base_blob {
        tier_to_cool_after_days_since_modification_greater_than    = 30
        tier_to_cold_after_days_since_modification_greater_than    = 120
        tier_to_archive_after_days_since_modification_greater_than = 365
        delete_after_days_since_modification_greater_than          = 2555
      }

      version {
        tier_to_archive_after_days_since_creation = 90
        delete_after_days_since_creation          = 730
      }
    }
  }
}

resource "azurerm_private_endpoint" "blob" {
  name                = "pe-${var.storage_account_name}-blob"
  resource_group_name = var.resource_group_name
  location            = var.location
  subnet_id           = var.private_endpoint_subnet_id

  private_service_connection {
    name                           = "plsc-blob"
    private_connection_resource_id = azurerm_storage_account.this.id
    subresource_names              = ["blob"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [var.blob_private_dns_zone_id]
  }
}

output "blob_endpoint" {
  value = azurerm_storage_account.this.primary_blob_endpoint
}
```

### 8.3 Kubernetes (AKS) — all three CSI drivers, complete

AKS ships three in-tree-replacement CSI drivers. The choice between them **is** the Blob/Files/Disk decision, expressed as an access mode.

```yaml
---
# =============================================================================
# 1. Azure Disk CSI — ReadWriteOnce block storage, zone-redundant Premium SSD.
#    Use for: databases, single-writer stateful sets.
# =============================================================================
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: managed-csi-premium-zrs
provisioner: disk.csi.azure.com
parameters:
  skuName: PremiumV2_LRS
  cachingMode: None
  DiskIOPSReadWrite: "8000"
  DiskMBpsReadWrite: "500"
  networkAccessPolicy: DenyAll
reclaimPolicy: Delete
allowVolumeExpansion: true
volumeBindingMode: WaitForFirstConsumer
mountOptions:
  - noatime
  - nodiratime
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgres-data
  namespace: data-platform
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: managed-csi-premium-zrs
  resources:
    requests:
      storage: 512Gi
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgres
  namespace: data-platform
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
        runAsUser: 999
        runAsNonRoot: true
      containers:
        - name: postgres
          image: postgres:16.4-alpine
          ports:
            - name: postgres
              containerPort: 5432
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
          resources:
            requests:
              cpu: "2"
              memory: 8Gi
            limits:
              cpu: "4"
              memory: 16Gi
          readinessProbe:
            exec:
              command: ["pg_isready", "-U", "postgres"]
            initialDelaySeconds: 10
            periodSeconds: 5
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: postgres-data
---
# =============================================================================
# 2. Azure Files CSI — ReadWriteMany SMB share, premium tier.
#    Use for: shared config, uploads directories, legacy apps needing RWX.
# =============================================================================
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: azurefile-csi-premium
provisioner: file.csi.azure.com
parameters:
  skuName: Premium_LRS
  protocol: smb
  secretNamespace: shared-storage
reclaimPolicy: Delete
allowVolumeExpansion: true
volumeBindingMode: Immediate
mountOptions:
  - dir_mode=0777
  - file_mode=0777
  - uid=1000
  - gid=1000
  - mfsymlinks
  - cache=strict
  - nosharesock
  - actimeo=30
  - nobrl
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: shared-uploads
  namespace: shared-storage
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: azurefile-csi-premium
  resources:
    requests:
      storage: 1Ti
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: upload-api
  namespace: shared-storage
spec:
  replicas: 6
  selector:
    matchLabels:
      app: upload-api
  template:
    metadata:
      labels:
        app: upload-api
    spec:
      containers:
        - name: api
          image: ghcr.io/example/upload-api:1.9.2
          ports:
            - containerPort: 8080
          volumeMounts:
            - name: uploads
              mountPath: /srv/uploads
          resources:
            requests:
              cpu: 250m
              memory: 512Mi
            limits:
              cpu: "1"
              memory: 1Gi
      volumes:
        - name: uploads
          persistentVolumeClaim:
            claimName: shared-uploads
---
# =============================================================================
# 3. Azure Blob CSI — object storage mounted via NFS 3.0, for read-heavy
#    analytics over an existing data lake container. No POSIX rename atomicity.
# =============================================================================
apiVersion: v1
kind: PersistentVolume
metadata:
  name: pv-datalake-telemetry
spec:
  capacity:
    storage: 100Ti
  accessModes:
    - ReadWriteMany
  persistentVolumeReclaimPolicy: Retain
  storageClassName: azureblob-nfs-premium
  mountOptions:
    - nconnect=8
    - rsize=1048576
    - wsize=1048576
    - hard
    - timeo=600
    - retrans=2
  csi:
    driver: blob.csi.azure.com
    volumeHandle: stprodtelemetryeus01_telemetry
    volumeAttributes:
      resourceGroup: rg-platform-prod
      storageAccount: stprodtelemetryeus01
      containerName: telemetry
      protocol: nfs
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: datalake-telemetry
  namespace: analytics
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: azureblob-nfs-premium
  volumeName: pv-datalake-telemetry
  resources:
    requests:
      storage: 100Ti
---
apiVersion: batch/v1
kind: Job
metadata:
  name: telemetry-rollup
  namespace: analytics
spec:
  backoffLimit: 2
  template:
    spec:
      restartPolicy: OnFailure
      containers:
        - name: rollup
          image: ghcr.io/example/telemetry-rollup:0.14.0
          args:
            - --input=/mnt/telemetry/raw
            - --output=/mnt/telemetry/enriched
            - --parallelism=16
          volumeMounts:
            - name: lake
              mountPath: /mnt/telemetry
          resources:
            requests:
              cpu: "8"
              memory: 32Gi
      volumes:
        - name: lake
          persistentVolumeClaim:
            claimName: datalake-telemetry
```

```bash
$ kubectl apply -f azure-storage.yaml
storageclass.storage.k8s.io/managed-csi-premium-zrs created
persistentvolumeclaim/postgres-data created
statefulset.apps/postgres created
storageclass.storage.k8s.io/azurefile-csi-premium created
persistentvolumeclaim/shared-uploads created
deployment.apps/upload-api created
persistentvolume/pv-datalake-telemetry created
persistentvolumeclaim/datalake-telemetry created
job.batch/telemetry-rollup created

$ kubectl get pvc -A
NAMESPACE        NAME                 STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS              AGE
analytics        datalake-telemetry   Bound    pv-datalake-telemetry                      100Ti      RWX            azureblob-nfs-premium     41s
data-platform    postgres-data        Bound    pvc-2b6f9c41-4d0e-4a19-9f77-0c8b31a5e2d4   512Gi      RWO            managed-csi-premium-zrs   41s
shared-storage   shared-uploads       Bound    pvc-c1a7e883-92bb-4c07-8a55-7d3f11e9b6aa   1Ti        RWX            azurefile-csi-premium     41s
```

---

## 9. Moving and migrating data

### 9.1 Tool selection by scale and constraint

| Data volume | Available bandwidth | Recommended tool | Reason |
|---|---|---|---|
| < 10 GB, ad hoc, interactive | any | **Azure Storage Explorer** | GUI, cross-platform, browsable; not scriptable |
| GB → tens of TB, scripted/CI | ≥ 100 Mbps | **AzCopy** | Parallel, resumable, `sync` semantics, service-to-service copy |
| Ongoing hybrid file share | any | **Azure File Sync** | Bidirectional sync + cloud tiering; keeps on-prem servers as a cache |
| 40 TB – 1 PB, thin/slow WAN | < 100 Mbps effective | **Azure Data Box** family | Ship physical devices; the math beats the wire |
| Continuous on-prem → cloud pipe | any | **Data Box Gateway / Azure Stack Edge** | Virtual/physical appliance presenting an SMB/NFS share that writes to Azure |
| Whole servers/DBs/apps, with assessment | any | **Azure Migrate** | Discovery, dependency mapping, right-sizing, cutover orchestration |

**The bandwidth math you must be able to do:**

```
Transfer time (days) = Data (TB) × 8,000,000 / (Effective Mbps × 86,400)
```

100 TB over a 500 Mbps link at 70 % efficiency ≈ **26 days of saturated WAN**. Data Box round-trip is typically under two weeks and does not consume the production link. That is the entire justification for offline transfer.

### 9.2 AzCopy — real sessions

```bash
$ azcopy --version
azcopy version 10.29.1

# Entra ID auth — no account keys, no SAS.
$ azcopy login --identity
INFO: Logging in under the identity of a managed service identity
INFO: Login succeeded.
```

**Upload a directory tree, preserving structure:**

```bash
$ azcopy copy '/srv/exports/2026-09/' \
    'https://stprodtelemetryeus01.blob.core.windows.net/telemetry/raw/2026-09/' \
    --recursive=true \
    --block-blob-tier=Cool \
    --put-md5 \
    --log-level=INFO

INFO: Scanning...
INFO: Any empty folders will not be processed, because source and/or destination doesn't have full folder support

Job f3c1a90e-7b2d-4e51-a8c2-19d4b7e6f0aa has started
Log file is located at: /home/sre/.azcopy/f3c1a90e-7b2d-4e51-a8c2-19d4b7e6f0aa.log

100.0 %, 18422 Done, 0 Failed, 0 Pending, 0 Skipped, 18422 Total, 2-sec Throughput (Mb/s): 1842.7

Job f3c1a90e-7b2d-4e51-a8c2-19d4b7e6f0aa summary
Elapsed Time (Minutes): 9.7331
Number of File Transfers: 18422
Number of Folder Property Transfers: 0
Number of Symlink Transfers: 0
Total Number of Transfers: 18422
Number of File Transfers Completed: 18422
Number of Folder Transfers Completed: 0
Number of File Transfers Failed: 0
Number of Folder Transfers Failed: 0
Number of File Transfers Skipped: 0
Number of Folder Transfers Skipped: 0
TotalBytesTransferred: 1341829472118
Final Job Status: Completed
```

**Incremental sync (delete-destination is what makes it a mirror):**

```bash
$ azcopy sync '/srv/exports/2026-09/' \
    'https://stprodtelemetryeus01.blob.core.windows.net/telemetry/raw/2026-09/' \
    --recursive=true \
    --delete-destination=true \
    --compare-hash=MD5

INFO: Any empty folders will not be processed, because source and/or destination doesn't have full folder support
INFO: Scanning...
INFO: Comparing hashes; 18422 files at destination

Job 7a2b0d44-1cd8-4c7f-91b6-3e5f8a1d02ce has started

100.0 %, 214 Done, 0 Failed, 0 Pending, 18208 Skipped, 18422 Total,

Job 7a2b0d44-1cd8-4c7f-91b6-3e5f8a1d02ce Summary
Files Scanned at Source: 18422
Files Scanned at Destination: 18422
Elapsed Time (Minutes): 0.4667
Number of Copy Transfers for Files: 214
Number of Deletions at Destination: 3
Total Number of Copy Transfers: 214
Number of Copy Transfers Completed: 214
Number of Copy Transfers Failed: 0
TotalBytesTransferred: 9218447106
Final Job Status: Completed
```

**Server-to-server copy (no bytes traverse your machine):**

```bash
$ azcopy copy \
    'https://stlegacywesteu01.blob.core.windows.net/archive?<sas>' \
    'https://stprodtelemetryeus01.blob.core.windows.net/archive?<sas>' \
    --recursive=true --s2s-preserve-access-tier=false --block-blob-tier=Archive
```

**Resume an interrupted job — never restart from zero:**

```bash
$ azcopy jobs list
Existing Jobs
JobId: f3c1a90e-7b2d-4e51-a8c2-19d4b7e6f0aa
Start Time: Thursday, 04 Sep 2026 09:12:03
Status: Completed
Command: copy /srv/exports/2026-09/ https://stprodtelemetryeus01.blob.core.windows.net/telemetry/raw/2026-09/ --recursive=true

JobId: 9d81ff02-3e77-4a10-bb54-6c2a0f7b4831
Start Time: Thursday, 04 Sep 2026 10:40:55
Status: CompletedWithErrors
Command: copy /srv/exports/2026-08/ https://stprodtelemetryeus01.blob.core.windows.net/telemetry/raw/2026-08/ --recursive=true

$ azcopy jobs resume 9d81ff02-3e77-4a10-bb54-6c2a0f7b4831
```

**Tuning knobs that actually move throughput:**

| Variable | Effect |
|---|---|
| `AZCOPY_CONCURRENCY_VALUE` | Parallel requests (default: auto from CPU count). Raise for many small files. |
| `AZCOPY_BUFFER_GB` | RAM used for in-flight buffers. |
| `--cap-mbps` | Throttle so you don't saturate the production WAN. **Set this in business hours.** |
| `--block-size-mb` | Larger blocks for large files; more efficient for multi-GB objects. |

### 9.3 Azure File Sync — complete deployment

Azure File Sync turns Windows Servers into a **cache** of an Azure file share. Files that are not hot are tiered to the cloud and replaced on the local NTFS volume by a **reparse point** — the file still appears in the directory listing with full size, but occupies almost no local disk. Opening it triggers a transparent recall.

**Topology:** `Storage Sync Service` → `Sync Group` → one **cloud endpoint** (an Azure file share) + N **server endpoints** (a path on a registered server).

```bash
# 1. Create the Storage Sync Service
$ az provider register --namespace Microsoft.StorageSync
$ az storagesync create \
    --resource-group rg-hybrid-prod \
    --name sss-fileservices-eus \
    --location eastus \
    --query "{name:name, state:provisioningState}" -o table
Name                    State
----------------------  ---------
sss-fileservices-eus    Succeeded

# 2. Create the sync group
$ az storagesync sync-group create \
    --resource-group rg-hybrid-prod \
    --storage-sync-service sss-fileservices-eus \
    --name sg-departmental-shares \
    --query "name" -o tsv
sg-departmental-shares

# 3. Cloud endpoint — the Azure file share that is the source of truth
$ az storagesync sync-group cloud-endpoint create \
    --resource-group rg-hybrid-prod \
    --storage-sync-service sss-fileservices-eus \
    --sync-group-name sg-departmental-shares \
    --name ce-departmental \
    --storage-account stprodtelemetryeus01 \
    --azure-file-share-name app-config \
    --query "{name:name, share:azureFileShareName, health:provisioningState}" -o table
Name             Share        Health
---------------  -----------  ---------
ce-departmental  app-config   Succeeded

# 4. Server endpoint — with cloud tiering, keeping 20% of the volume free
$ az storagesync sync-group server-endpoint create \
    --resource-group rg-hybrid-prod \
    --storage-sync-service sss-fileservices-eus \
    --sync-group-name sg-departmental-shares \
    --name se-fs01-e-shares \
    --server-id "6b1f4d92-0c33-4a58-9e2a-77b3c5d18e40" \
    --server-local-path "E:\Shares" \
    --cloud-tiering "on" \
    --volume-free-space-percent 20 \
    --tier-files-older-than-days 30 \
    --offline-data-transfer "off"
```

Register the server first (on the Windows Server, after installing the agent):

```powershell
PS C:\> Register-AzStorageSyncServer `
    -ParentResourceGroupName "rg-hybrid-prod" `
    -ParentStorageSyncServiceName "sss-fileservices-eus"

ServerName          : FS01.corp.example.com
ServerId            : 6b1f4d92-0c33-4a58-9e2a-77b3c5d18e40
ServerRole          : Standalone
StorageSyncService  : sss-fileservices-eus
ServerOSVersion     : 10.0.20348.0
AgentVersion        : 18.0.0.0
ServerManagementErrorCode : 0
```

**Cloud tiering policies — both apply, whichever tiers more wins:**

| Policy | Behaviour |
|---|---|
| **Volume free space** | Tiers coldest files until N % of the volume is free. Always active if tiering is on. |
| **Date policy** | Tiers files not accessed in N days, regardless of free space. |

**The failure mode to know:** a backup agent or an antivirus full scan that reads every file causes a **recall storm** — every tiered file is pulled back from Azure, filling the volume and generating enormous egress. Configure backup to run against the *cloud endpoint* (Azure Backup for Files) or exclude reparse points, never a naïve full-volume backup on a tiered server.

### 9.4 Azure Data Box family

| Device | Raw capacity | Usable capacity | Form factor | Interfaces |
|---|---|---|---|---|
| **Data Box Disk** | 8 TB per SSD, up to 5 disks (40 TB) | ~35 TB | USB/SATA SSDs | USB 3.1 |
| **Data Box** | 100 TB | ~80 TB | Rugged 50 lb appliance | RJ45 1/10 GbE, SFP+ 10 GbE |
| **Data Box Heavy** | 1 PB | ~770 TB | Rolling 500 lb cabinet | 4 × 40 GbE QSFP+ |

All devices are AES 256-bit encrypted, tracked end-to-end, and wiped to NIST SP 800-88r1 standards after upload. You copy over SMB/NFS or the REST interface, ship the device back, and Microsoft uploads into your storage account.

There are also **Data Box Gateway** (virtual appliance for continuous online transfer) and **Azure Stack Edge** (physical appliance with hardware-accelerated inference at the edge that also acts as a cloud storage gateway).

### 9.5 Azure Migrate

Azure Migrate is the **hub**, not a single tool: discovery, dependency analysis, assessment (right-sizing plus cost projection), and migration for servers (VMware, Hyper-V, physical, AWS/GCP VMs), SQL databases, web apps, and virtual desktops. For AZ-900, the point is the *shape* of the workflow:

```
Discover  →  Assess (readiness, right-size, cost)  →  Migrate (replicate, test-failover, cut over)
```

Azure Migrate integrates the Data Box family for the bulk-data leg of a large migration.

---

## 10. Verification and failure diagnosis

### 10.1 Baseline health checks

```bash
# What redundancy and tier is this account really running?
$ az storage account show \
    --name stprodtelemetryeus01 --resource-group rg-platform-prod \
    --query "{sku:sku.name, kind:kind, tier:accessTier, tls:minimumTlsVersion, \
              sharedKey:allowSharedKeyAccess, publicNet:publicNetworkAccess, \
              defaultAction:networkAcls.defaultAction}" -o table
Sku              Kind       Tier    Tls       SharedKey    PublicNet    DefaultAction
---------------  ---------  ------  --------  -----------  -----------  ---------------
Standard_GZRS    StorageV2  Hot     TLS1_2    False        Disabled     Deny

# Consumed capacity (the Capacity metric is emitted once per day).
$ az monitor metrics list \
    --resource "/subscriptions/8f1c.../resourceGroups/rg-platform-prod/providers/Microsoft.Storage/storageAccounts/stprodtelemetryeus01" \
    --metric UsedCapacity --interval PT1H --aggregation Average \
    --query "value[0].timeseries[0].data[-1]" -o json
{
  "average": 1341829472118.0,
  "timeStamp": "2026-09-04T11:00:00+00:00"
}

# Availability and end-to-end latency over the last hour.
$ az monitor metrics list \
    --resource "/subscriptions/8f1c.../providers/Microsoft.Storage/storageAccounts/stprodtelemetryeus01/blobServices/default" \
    --metric Availability SuccessE2ELatency SuccessServerLatency \
    --interval PT5M --aggregation Average \
    --query "value[].{metric:name.value, last:timeseries[0].data[-1].average}" -o table
Metric                Last
--------------------  --------
Availability          100.0
SuccessE2ELatency     41.7
SuccessServerLatency  9.2
```

> `SuccessE2ELatency − SuccessServerLatency` is **client-and-network time**. If E2E is 400 ms and server is 8 ms, the storage service is healthy and your problem is DNS, TLS handshakes, small-object chattiness, or a client without connection pooling. This single subtraction resolves most "Azure Storage is slow" tickets.

### 10.2 Symptom → cause → command

| Symptom / error code | Most likely cause | Diagnostic command |
|---|---|---|
| `403 AuthorizationPermissionMismatch` | Caller has a control-plane role (Owner/Contributor) but no **data-plane** role | `az role assignment list --scope <account-id> --assignee <oid> -o table` |
| `403 AuthorizationFailure` | Network ACL denial — request came from an unexpected IP/subnet | `az storage account show --query networkAcls` |
| `403 KeyBasedAuthenticationNotPermitted` | `allowSharedKeyAccess=false` but the client is using an account key or service SAS | Switch client to `DefaultAzureCredential` |
| `403 AuthenticationFailed` + `Signature did not match` | SAS clock skew, or the signed resource/permissions don't match the request | Check `st`/`se` in the SAS; verify host NTP |
| `409 BlobArchived` | Blob is in Archive; it is offline | `az storage blob show --query properties.blobTier` |
| `409 ContainerBeingDeleted` | Recreating a container within the deletion grace window | Wait, or use a different name |
| `503 ServerBusy` / `ClientThrottlingError` | Account-level 20,000 req/s or bandwidth limit hit | KQL by `ResponseType` (below) |
| `500 OperationTimedOut` | Very large single operation; retry with smaller blocks | Reduce `--block-size-mb` |
| `413` on a file share write | Share quota reached | `az storage share-rm show --query properties.shareQuota` |
| Blob URL resolves to a **public** IP inside the VNet | Private DNS zone not linked to the VNet, or missing A record | `nslookup <acct>.blob.core.windows.net` |
| `mount error(13): Permission denied` on SMB | Storage account key rotated, or TLS/SMB version mismatch, or port 445 blocked | `nc -zv <acct>.file.core.windows.net 445` |
| AKS pod stuck `ContainerCreating`, event `MountVolume.MountDevice failed` | CSI cannot reach the account, or the kubelet identity lacks a data role | `kubectl describe pod`, then check the CSI driver logs |
| Storage bill grew with no visible data growth | Orphaned snapshots, blob versions, soft-deleted blobs, uncommitted blocks | Enable and read the **Storage Insights** capacity breakdown |

### 10.3 Private endpoint DNS — the most common "storage is down"

```bash
# From inside the VNet: this MUST return a private IP via the privatelink CNAME.
$ nslookup stprodtelemetryeus01.blob.core.windows.net
Server:         168.63.129.16
Address:        168.63.129.16#53

Non-authoritative answer:
stprodtelemetryeus01.blob.core.windows.net  canonical name = stprodtelemetryeus01.privatelink.blob.core.windows.net.
Name:   stprodtelemetryeus01.privatelink.blob.core.windows.net
Address: 10.42.3.14
```

If you instead see a public `20.x.x.x` address, the private DNS zone `privatelink.blob.core.windows.net` is not linked to this VNet, or the private endpoint's DNS zone group was never created. With `publicNetworkAccess: Disabled`, every request then fails with `403 AuthorizationFailure` — an error that *looks* like RBAC and is actually DNS.

```bash
$ az network private-endpoint-connection list \
    --id "/subscriptions/8f1c.../providers/Microsoft.Storage/storageAccounts/stprodtelemetryeus01" \
    --query "[].{name:name, state:properties.privateLinkServiceConnectionState.status}" -o table
Name                                  State
------------------------------------  ---------
pe-stprodtelemetryeus01-blob.5a2c9f1  Approved
pe-stprodtelemetryeus01-file.9d3b7e4  Approved

$ az network private-dns link vnet list \
    --resource-group rg-net-prod \
    --zone-name privatelink.blob.core.windows.net \
    --query "[].{link:name, vnet:virtualNetwork.id, autoreg:registrationEnabled}" -o table
```

### 10.4 Throttling forensics with KQL

Enable diagnostic settings first (`StorageRead`, `StorageWrite`, `StorageDelete` → Log Analytics), then:

```kusto
// Which response types dominate, and are we being throttled?
StorageBlobLogs
| where TimeGenerated > ago(6h)
| where AccountName == "stprodtelemetryeus01"
| summarize
    Requests = count(),
    P50 = percentile(DurationMs, 50),
    P99 = percentile(DurationMs, 99)
  by StatusCode, StatusText, OperationName
| order by Requests desc
```

```kusto
// Top callers of a throttled account — find the noisy neighbour.
StorageBlobLogs
| where TimeGenerated > ago(1h)
| where StatusText has "ServerBusy" or StatusText has "Throttl"
| summarize ThrottledRequests = count() by CallerIpAddress, UserAgentHeader, AuthenticationType
| top 20 by ThrottledRequests desc
```

```kusto
// Anonymous or Shared Key access that should not exist any more.
StorageBlobLogs
| where TimeGenerated > ago(7d)
| where AuthenticationType in ("AccountKey", "Anonymous", "SAS")
| summarize Requests = count(), FirstSeen = min(TimeGenerated), LastSeen = max(TimeGenerated)
  by AuthenticationType, CallerIpAddress, ObjectKey
| order by Requests desc
```

### 10.5 Geo-replication lag alert (this is your RPO SLO)

```bash
$ az monitor metrics alert create \
    --name alert-storage-geo-rpo-breach \
    --resource-group rg-platform-prod \
    --scopes "/subscriptions/8f1c.../providers/Microsoft.Storage/storageAccounts/stprodtelemetryeus01" \
    --condition "max Availability < 99" \
    --window-size 5m --evaluation-frequency 1m \
    --severity 1 \
    --description "Storage account availability below SLO"
```

For `lastSyncTime` there is no built-in metric — poll `geoReplicationStats.lastSyncTime` from a scheduled job and alert when `now() - lastSyncTime > 15m`. **Treat the absence of this alert as an unmonitored RPO.**

### 10.6 Verification checklist before declaring a storage design "done"

- [ ] Redundancy matches the documented RTO/RPO, and someone has run a **planned failover drill**.
- [ ] `allowSharedKeyAccess = false`; all access is Entra ID + RBAC or user-delegation SAS.
- [ ] `publicNetworkAccess = Disabled` with private endpoints and **DNS verified from inside the VNet**.
- [ ] `minimumTlsVersion = TLS1_2`, `supportsHttpsTrafficOnly = true`, `allowBlobPublicAccess = false`.
- [ ] Blob soft delete, container soft delete, versioning and change feed enabled; retention days chosen deliberately.
- [ ] Lifecycle policy respects the 30/90/180-day minimum retentions to avoid early-deletion penalties.
- [ ] Diagnostic settings shipping `StorageRead/Write/Delete` to Log Analytics with a retention that outlives your audit window.
- [ ] Alerts on `Availability`, `ClientThrottlingError`, `SuccessE2ELatency`, and geo `lastSyncTime`.
- [ ] Capacity headroom checked against the 5 PiB and 20,000 req/s account ceilings; workloads split across accounts if either is within 60 %.
- [ ] Archive retrieval path tested end-to-end, with the application handling `409 BlobArchived` and a 15-hour rehydration window.

---

## 11. Exam-focused summary and the traps

| Question shape | Correct answer | Trap |
|---|---|---|
| "Cheapest storage for data accessed once a year, retrieval delay acceptable" | **Archive** | Cool/Cold if you skip "retrieval delay acceptable" |
| "Survives a datacenter failure but stays in one region" | **ZRS** | LRS survives only disks/racks; GRS is cross-region |
| "Lowest cost that survives a regional outage and an AZ outage" | **GZRS** | RA-GZRS adds read access you weren't asked for and costs more |
| "Lift-and-shift app needs `\\fileserver\data`" | **Azure Files** | Blob cannot be mounted natively as SMB |
| "Decouple a web front end from a back-end worker" | **Queue storage** | Table is not a queue; Service Bus is the answer only when ordering/transactions are required |
| "Store IoT device metadata, schemaless, key lookup" | **Table storage** | Blob has no query-by-key |
| "Move 500 TB with a 50 Mbps link" | **Azure Data Box Heavy** | AzCopy would take years of wire time |
| "Keep frequently used files on-prem, the rest in Azure" | **Azure File Sync** with cloud tiering | AzCopy is one-shot, not a cache |
| "Assess on-prem VMs and plan the move" | **Azure Migrate** | Data Box moves bytes, it does not assess |
| "GUI to browse and manage blobs across subscriptions" | **Azure Storage Explorer** | AzCopy has no GUI |
| "Minimum retention before deleting a Cool blob without penalty" | **30 days** | Cold is 90, Archive is 180 |
| "Which storage type for a SQL Server VM's data volume needing 20,000 IOPS" | **Premium SSD** (or Premium SSD v2 / Ultra) | Standard SSD tops out at 6,000 IOPS |

**Five statements worth memorising verbatim:**

1. The **storage account** is the boundary for redundancy, firewall, encryption scope, throughput limits and failover — not the container or share.
2. **Geo-replication is asynchronous** with an RPO objective under 15 minutes; unplanned failover loses everything after `lastSyncTime` and leaves you LRS.
3. **Archive is offline.** Rehydration takes up to 15 hours at Standard priority; under an hour at High priority for objects under 10 GiB.
4. **Managed disk performance is a function of the SKU and (for Premium SSD / Standard SSD / Standard HDD) the provisioned size**; Premium SSD v2 and Ultra decouple IOPS/throughput from capacity.
5. **Encryption at rest is always on** with 256-bit AES; the only choice is Microsoft-managed vs customer-managed keys, plus optional infrastructure (double) encryption which must be set at creation time.

---

## 12. References

**Certification**
- AZ-900 study guide — https://learn.microsoft.com/en-us/credentials/certifications/resources/study-guides/az-900
- Azure Fundamentals certification — https://learn.microsoft.com/en-us/credentials/certifications/azure-fundamentals/

**Storage accounts and services**
- Storage account overview — https://learn.microsoft.com/en-us/azure/storage/common/storage-account-overview
- Introduction to Azure Storage — https://learn.microsoft.com/en-us/azure/storage/common/storage-introduction
- Create a storage account — https://learn.microsoft.com/en-us/azure/storage/common/storage-account-create
- Scalability and performance targets for standard storage accounts — https://learn.microsoft.com/en-us/azure/storage/common/scalability-targets-standard-account
- Scalability targets for Blob storage — https://learn.microsoft.com/en-us/azure/storage/blobs/scalability-targets

**Redundancy and disaster recovery**
- Azure Storage redundancy — https://learn.microsoft.com/en-us/azure/storage/common/storage-redundancy
- Disaster recovery and account failover — https://learn.microsoft.com/en-us/azure/storage/common/storage-disaster-recovery-guidance
- Initiate an account failover — https://learn.microsoft.com/en-us/azure/storage/common/storage-initiate-account-failover
- Change how a storage account is replicated — https://learn.microsoft.com/en-us/azure/storage/common/redundancy-migration

**Blob storage, tiers and lifecycle**
- Introduction to Blob Storage — https://learn.microsoft.com/en-us/azure/storage/blobs/storage-blobs-introduction
- Access tiers for blob data — https://learn.microsoft.com/en-us/azure/storage/blobs/access-tiers-overview
- Blob rehydration from the Archive tier — https://learn.microsoft.com/en-us/azure/storage/blobs/archive-rehydrate-overview
- Optimize costs by automatically managing the data lifecycle — https://learn.microsoft.com/en-us/azure/storage/blobs/lifecycle-management-overview
- Blob versioning — https://learn.microsoft.com/en-us/azure/storage/blobs/versioning-overview
- Soft delete for blobs — https://learn.microsoft.com/en-us/azure/storage/blobs/soft-delete-blob-overview
- Immutable storage for Blob Storage — https://learn.microsoft.com/en-us/azure/storage/blobs/immutable-storage-overview
- Azure Data Lake Storage introduction — https://learn.microsoft.com/en-us/azure/storage/blobs/data-lake-storage-introduction

**Azure Files, Queues and Tables**
- What is Azure Files? — https://learn.microsoft.com/en-us/azure/storage/files/storage-files-introduction
- Azure Files planning guide — https://learn.microsoft.com/en-us/azure/storage/files/storage-files-planning
- NFS file shares in Azure Files — https://learn.microsoft.com/en-us/azure/storage/files/files-nfs-protocol
- Introduction to Queue Storage — https://learn.microsoft.com/en-us/azure/storage/queues/storage-queues-introduction
- Storage queues and Service Bus queues compared — https://learn.microsoft.com/en-us/azure/service-bus-messaging/service-bus-azure-and-service-bus-queues-compared-contrasted
- Introduction to Table Storage — https://learn.microsoft.com/en-us/azure/storage/tables/table-storage-overview

**Managed disks**
- Introduction to Azure managed disks — https://learn.microsoft.com/en-us/azure/virtual-machines/managed-disks-overview
- Azure managed disk types — https://learn.microsoft.com/en-us/azure/virtual-machines/disks-types
- Azure Premium SSD v2 — https://learn.microsoft.com/en-us/azure/virtual-machines/disks-deploy-premium-v2

**Security**
- Azure Storage encryption for data at rest — https://learn.microsoft.com/en-us/azure/storage/common/storage-service-encryption
- Authorize access to blobs using Microsoft Entra ID — https://learn.microsoft.com/en-us/azure/storage/blobs/authorize-access-azure-active-directory
- Grant limited access with shared access signatures — https://learn.microsoft.com/en-us/azure/storage/common/storage-sas-overview
- Configure Azure Storage firewalls and virtual networks — https://learn.microsoft.com/en-us/azure/storage/common/storage-network-security
- Use private endpoints for Azure Storage — https://learn.microsoft.com/en-us/azure/storage/common/storage-private-endpoints
- Security recommendations for Blob Storage — https://learn.microsoft.com/en-us/azure/storage/blobs/security-recommendations

**Data movement and migration**
- Get started with AzCopy — https://learn.microsoft.com/en-us/azure/storage/common/storage-use-azcopy-v10
- Optimize AzCopy performance — https://learn.microsoft.com/en-us/azure/storage/common/storage-use-azcopy-optimize
- Azure Storage Explorer — https://learn.microsoft.com/en-us/azure/storage/storage-explorer/vs-azure-tools-storage-manage-with-storage-explorer
- Planning for an Azure File Sync deployment — https://learn.microsoft.com/en-us/azure/storage/file-sync/file-sync-planning
- Deploy Azure File Sync — https://learn.microsoft.com/en-us/azure/storage/file-sync/file-sync-deployment-guide
- Azure File Sync cloud tiering overview — https://learn.microsoft.com/en-us/azure/storage/file-sync/file-sync-cloud-tiering-overview
- What is Azure Data Box? — https://learn.microsoft.com/en-us/azure/databox/data-box-overview
- Azure Data Box Disk overview — https://learn.microsoft.com/en-us/azure/databox/data-box-disk-overview
- Choose an Azure data transfer solution — https://learn.microsoft.com/en-us/azure/storage/common/storage-choose-data-transfer-solution
- About Azure Migrate — https://learn.microsoft.com/en-us/azure/migrate/migrate-services-overview

**Monitoring and diagnostics**
- Monitor Azure Storage — https://learn.microsoft.com/en-us/azure/storage/common/monitor-storage
- Azure Storage monitoring data reference — https://learn.microsoft.com/en-us/azure/storage/common/monitor-storage-reference
- Troubleshoot client application errors — https://learn.microsoft.com/en-us/azure/storage/common/troubleshoot-storage-client-application-errors
- Common REST API error codes — https://learn.microsoft.com/en-us/rest/api/storageservices/common-rest-api-error-codes

**Kubernetes / AKS integration**
- Azure Disk CSI driver on AKS — https://learn.microsoft.com/en-us/azure/aks/azure-disk-csi
- Azure Files CSI driver on AKS — https://learn.microsoft.com/en-us/azure/aks/azure-files-csi
- Azure Blob Storage CSI driver on AKS — https://learn.microsoft.com/en-us/azure/aks/azure-blob-csi

**Reference / IaC**
- `Microsoft.Storage/storageAccounts` Bicep & ARM reference — https://learn.microsoft.com/en-us/azure/templates/microsoft.storage/storageaccounts
- `az storage` CLI reference — https://learn.microsoft.com/en-us/cli/azure/storage
- Terraform `azurerm_storage_account` — https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/storage_account
- SLA for Azure Storage Accounts — https://www.microsoft.com/licensing/docs/view/Service-Level-Agreements-SLA-for-Online-Services