# AZ-900 — Topic 2.3: Describe Azure Storage Services
## Guided Exercises (hands-on lab)

**Exam weight:** 9.62 % · **Syllabus version:** 2026-07-20
**Official study guide:** https://learn.microsoft.com/en-us/credentials/certifications/resources/study-guides/az-900

---

## Before you start

**Prerequisites**

- An Azure subscription. A free trial or an Azure for Students subscription is enough — every resource in this lab is either free or costs cents if you complete the cleanup in Exercise 9.
- Azure Cloud Shell (Bash) or a local shell with Azure CLI `2.60.0` or later. Check with `az version`.
- No Windows machine is required. Two exercises (Azure File Sync, Storage Explorer) are **read-and-reason** blocks rather than execute blocks, because they need a Windows Server or a desktop install — the exam tests what they *are* and *when you choose them*, not their installers.

**Cost warning.** Managed disks and premium storage accounts bill from the second they exist. Exercise 6 creates a disk; Exercise 9 deletes everything. Do not stop halfway.

**Conventions used below**

- Lines starting with `$` are commands you type. Everything else in an output block is what Azure returns.
- Output is trimmed to the fields that matter. Your GUIDs, timestamps and IPs will differ.
- `<...>` means substitute your own value.

---

## Exercise 1 — The storage account is the boundary

Almost every Azure storage decision is made **once, at account creation**, and is expensive or impossible to change later. This exercise makes that boundary visible.

### Steps

1. Open Cloud Shell (https://shell.azure.com) and confirm which subscription you are in:

   ```bash
   $ az account show --output table
   ```

   ```
   EnvironmentName    HomeTenantId                          IsDefault    Name                State    TenantId
   -----------------  ------------------------------------  -----------  ------------------  -------  ------------------------------------
   AzureCloud         3f1a...c9d2                           True         Pay-As-You-Go       Enabled  3f1a...c9d2
   ```

2. Export a globally unique account name. Storage account names are **3–24 characters, lowercase letters and digits only**, and share one global DNS namespace with every other Azure tenant on Earth:

   ```bash
   $ export RG=rg-az900-storage
   $ export LOC=eastus
   $ export SA=st900lab$RANDOM$RANDOM
   $ echo $SA
   ```

   ```
   st900lab1842229517
   ```

3. Create the resource group, then the storage account. Note that we pass **no** `--sku`, deliberately:

   ```bash
   $ az group create --name $RG --location $LOC --output table
   $ az storage account create \
       --name $SA \
       --resource-group $RG \
       --location $LOC \
       --output none
   ```

4. Inspect what Azure chose for you:

   ```bash
   $ az storage account show --name $SA --resource-group $RG \
       --query "{kind:kind, sku:sku.name, tier:accessTier, https:enableHttpsTrafficOnly, tls:minimumTlsVersion, publicBlob:allowBlobPublicAccess}" \
       --output yaml
   ```

   ```yaml
   https: true
   kind: StorageV2
   publicBlob: false
   sku: Standard_RAGRS
   tier: Hot
   tls: TLS1_2
   ```

5. List the service endpoints the account exposes:

   ```bash
   $ az storage account show --name $SA --resource-group $RG \
       --query primaryEndpoints --output yaml
   ```

   ```yaml
   blob: https://st900lab1842229517.blob.core.windows.net/
   dfs: https://st900lab1842229517.dfs.core.windows.net/
   file: https://st900lab1842229517.file.core.windows.net/
   queue: https://st900lab1842229517.queue.core.windows.net/
   table: https://st900lab1842229517.table.core.windows.net/
   web: https://st900lab1842229517.z13.web.core.windows.net/
   ```

6. Try to create a second account with the same name in a different resource group and read the error:

   ```bash
   $ az storage account create --name $SA --resource-group $RG --location westus2 --output none
   ```

   ```
   (StorageAccountAlreadyExists) The storage account named st900lab1842229517 is already taken.
   Code: StorageAccountAlreadyExists
   ```

### Check your understanding — block 1

**Q1.1** Why must a storage account name be globally unique, when a virtual machine name only has to be unique inside its resource group?

**Q1.2** The account was created as `StorageV2` (general-purpose v2). Which four storage *services* does that single account contain, and which one of the five services usually named in the exam objective is **not** in the list?

**Q1.3** The CLI defaulted to `Standard_RAGRS`. Name one concrete risk of accepting that default without thinking, and one concrete benefit.

**Q1.4** `allowBlobPublicAccess` came back `false`. If a colleague says "just make the container public so the website can read it," what has to change first, and what does that setting do at the account level versus the container level?

**Q1.5** The `dfs` endpoint appeared even though you did not ask for Data Lake. What feature does that endpoint serve, and is it usable on this account as created?

---

## Exercise 2 — Blob storage: containers, blob types, and the flat namespace

### Steps

1. Blob operations need an authorisation mode. Use your Entra ID identity rather than account keys — this is the production pattern and it also demonstrates that **RBAC on the control plane is not RBAC on the data plane**:

   ```bash
   $ az storage container create \
       --name media \
       --account-name $SA \
       --auth-mode login \
       --output table
   ```

   ```
   (AuthorizationPermissionMismatch) This request is not authorized to perform this operation using this permission.
   ```

2. That failure is the lesson. Owner/Contributor on the subscription lets you *manage* the account but not *read its data*. Grant yourself a data-plane role:

   ```bash
   $ export ME=$(az ad signed-in-user show --query id --output tsv)
   $ export SCOPE=$(az storage account show --name $SA --resource-group $RG --query id --output tsv)
   $ az role assignment create \
       --assignee-object-id $ME \
       --assignee-principal-type User \
       --role "Storage Blob Data Contributor" \
       --scope $SCOPE \
       --output none
   ```

   Wait 1–3 minutes for the assignment to propagate, then retry step 1. It now succeeds:

   ```
   Created
   --------
   True
   ```

3. Create three files of different shapes and upload them:

   ```bash
   $ head -c 2M /dev/urandom > report.bin
   $ echo "2026-09-05T10:00:00Z INFO service started" > app.log
   $ echo '{"id":1,"status":"ok"}' > record.json
   $ az storage blob upload-batch \
       --destination media \
       --source . \
       --pattern "*.bin" \
       --account-name $SA --auth-mode login --output none
   $ az storage blob upload --container-name media --name logs/2026/09/app.log --file app.log \
       --account-name $SA --auth-mode login --output none
   $ az storage blob upload --container-name media --name logs/2026/09/record.json --file record.json \
       --account-name $SA --auth-mode login --output none
   ```

4. List what exists, showing blob type and tier:

   ```bash
   $ az storage blob list --container-name media \
       --account-name $SA --auth-mode login \
       --query "[].{name:name, type:properties.blobType, tier:properties.blobTier, bytes:properties.contentLength}" \
       --output table
   ```

   ```
   Name                      Type       Tier    Bytes
   ------------------------  ---------  ------  -------
   logs/2026/09/app.log      BlockBlob  Hot     42
   logs/2026/09/record.json  BlockBlob  Hot     23
   report.bin                BlockBlob  Hot     2097152
   ```

5. Prove the namespace is flat, not hierarchical. Try to delete the "folder":

   ```bash
   $ az storage blob delete --container-name media --name "logs/2026/09" \
       --account-name $SA --auth-mode login
   ```

   ```
   (BlobNotFound) The specified blob does not exist.
   ```

   Then list with a delimiter and see the illusion Azure renders for you:

   ```bash
   $ az storage blob list --container-name media --delimiter "/" \
       --account-name $SA --auth-mode login \
       --query "[].name" --output tsv
   ```

   ```
   logs/
   report.bin
   ```

### Check your understanding — block 2

**Q2.1** Step 1 failed while you were subscription Owner. Explain the difference between the Azure Resource Manager control plane and the storage data plane, and name the role you had to add.

**Q2.2** All three uploads produced `BlockBlob`. Describe the three blob types and give the canonical workload for each.

**Q2.3** In step 5, deleting `logs/2026/09` failed but the listing in step 4 showed a path. Where does the "folder" actually exist?

**Q2.4** What would change about step 5 if the account had been created with hierarchical namespace (HNS / Data Lake Storage Gen2) enabled?

**Q2.5** A container is created inside an account. What is the relationship between account → container → blob, and can a blob exist outside a container?

---

## Exercise 3 — Access tiers and the cost of being wrong

### Steps

1. Move the log blobs down the tier ladder and observe which transitions Azure allows:

   ```bash
   $ az storage blob set-tier --container-name media --name logs/2026/09/app.log \
       --tier Cool --account-name $SA --auth-mode login --output none
   $ az storage blob set-tier --container-name media --name logs/2026/09/record.json \
       --tier Cold --account-name $SA --auth-mode login --output none
   $ az storage blob set-tier --container-name media --name report.bin \
       --tier Archive --account-name $SA --auth-mode login --output none
   ```

2. Re-list and read the result:

   ```bash
   $ az storage blob list --container-name media \
       --account-name $SA --auth-mode login \
       --query "[].{name:name, tier:properties.blobTier, status:properties.rehydrationStatus}" \
       --output table
   ```

   ```
   Name                      Tier     Status
   ------------------------  -------  --------
   logs/2026/09/app.log      Cool
   logs/2026/09/record.json  Cold
   report.bin                Archive
   ```

3. Now try to read the archived blob:

   ```bash
   $ az storage blob download --container-name media --name report.bin --file /tmp/out.bin \
       --account-name $SA --auth-mode login
   ```

   ```
   (BlobArchived) This operation is not permitted on an archived blob.
   ```

4. Start a rehydration and watch the intermediate state:

   ```bash
   $ az storage blob set-tier --container-name media --name report.bin \
       --tier Hot --rehydrate-priority High \
       --account-name $SA --auth-mode login --output none
   $ az storage blob show --container-name media --name report.bin \
       --account-name $SA --auth-mode login \
       --query "{tier:properties.blobTier, status:properties.rehydrationStatus}" --output yaml
   ```

   ```yaml
   status: rehydrate-pending-to-hot
   tier: Archive
   ```

5. Set an account-level default tier and confirm it does **not** retroactively move existing blobs:

   ```bash
   $ az storage account update --name $SA --resource-group $RG --access-tier Cool --output none
   $ az storage account show --name $SA --resource-group $RG --query accessTier --output tsv
   ```

   ```
   Cool
   ```

6. Write a lifecycle management policy so the tiering happens without a human. Create `policy.json`:

   ```json
   {
     "rules": [
       {
         "enabled": true,
         "name": "logs-age-out",
         "type": "Lifecycle",
         "definition": {
           "filters": {
             "blobTypes": [ "blockBlob" ],
             "prefixMatch": [ "media/logs/" ]
           },
           "actions": {
             "baseBlob": {
               "tierToCool":    { "daysAfterModificationGreaterThan": 30 },
               "tierToCold":    { "daysAfterModificationGreaterThan": 90 },
               "tierToArchive": { "daysAfterModificationGreaterThan": 180 },
               "delete":        { "daysAfterModificationGreaterThan": 2555 }
             }
           }
         }
       }
     ]
   }
   ```

   Apply it:

   ```bash
   $ az storage account management-policy create \
       --account-name $SA --resource-group $RG \
       --policy @policy.json --output none
   $ az storage account management-policy show \
       --account-name $SA --resource-group $RG \
       --query "policy.rules[].name" --output tsv
   ```

   ```
   logs-age-out
   ```

### Check your understanding — block 3

**Q3.1** Fill in the four online/offline tiers from most to least expensive **per GB stored**, and state what moves in the opposite direction as you go down.

**Q3.2** What is the minimum retention period for Cool, Cold and Archive, and what happens financially if you delete or re-tier a blob before it elapses?

**Q3.3** Step 3 failed with `BlobArchived`. In plain terms, why can Azure not simply serve the bytes?

**Q3.4** You chose `--rehydrate-priority High`. Compare High and Standard rehydration in terms of expected time and cost, and give the object-size caveat.

**Q3.5** Step 5 set the account default to `Cool`. Which blobs does that affect, and which tier can **never** be set as an account default?

**Q3.6** The lifecycle policy is free to run but the tier transitions are not. Name the cost that a naive "archive everything after 30 days" policy creates for a dataset of millions of tiny blobs.

---

## Exercise 4 — Redundancy: what survives what

### Steps

1. Read the current redundancy and the secondary region Azure paired for you:

   ```bash
   $ az storage account show --name $SA --resource-group $RG \
       --query "{sku:sku.name, primary:primaryLocation, secondary:secondaryLocation, status:statusOfPrimary, secStatus:statusOfSecondary}" \
       --output yaml
   ```

   ```yaml
   primary: eastus
   secStatus: available
   secondary: westus
   sku: Standard_RAGRS
   status: available
   ```

2. Because the SKU is **read-access** geo-redundant, a second read endpoint exists:

   ```bash
   $ az storage account show --name $SA --resource-group $RG \
       --query secondaryEndpoints.blob --output tsv
   ```

   ```
   https://st900lab1842229517-secondary.blob.core.windows.net/
   ```

3. Check how far behind the secondary is. This number is the real RPO:

   ```bash
   $ az storage account show --name $SA --resource-group $RG \
       --query geoReplicationStats --output yaml
   ```

   ```yaml
   canFailover: true
   lastSyncTime: '2026-09-05T09:52:11Z'
   status: Live
   ```

4. Move to zone redundancy and read the error that teaches the conversion matrix:

   ```bash
   $ az storage account update --name $SA --resource-group $RG --sku Standard_ZRS --output none
   ```

   ```
   (InvalidAccountTypeConversion) Conversion of storage account SKU from Standard_RAGRS
   to Standard_ZRS is not supported. Convert to Standard_LRS first.
   ```

5. Do it in the supported order:

   ```bash
   $ az storage account update --name $SA --resource-group $RG --sku Standard_LRS --output none
   $ az storage account update --name $SA --resource-group $RG --sku Standard_ZRS --output none
   $ az storage account show --name $SA --resource-group $RG --query sku.name --output tsv
   ```

   ```
   Standard_ZRS
   ```

6. Confirm the secondary endpoint disappeared with the geo-redundancy:

   ```bash
   $ az storage account show --name $SA --resource-group $RG --query secondaryEndpoints --output tsv
   ```

   ```

   ```

7. Return to geo + zone redundancy for the rest of the lab:

   ```bash
   $ az storage account update --name $SA --resource-group $RG --sku Standard_GZRS --output none
   ```

### Check your understanding — block 4

**Q4.1** Complete this table from memory, then verify against the docs:

| Option | Copies in primary | Spread across | Copies in secondary | Secondary readable? |
|---|---|---|---|---|
| LRS | | | | |
| ZRS | | | | |
| GRS | | | | |
| GZRS | | | | |
| RA-GRS | | | | |
| RA-GZRS | | | | |

**Q4.2** A single rack loses power in the datacenter. Which options keep the data available? An entire availability zone floods. Which options keep the data available? The whole region is offline. Which options still hold a copy?

**Q4.3** Geo-replication is asynchronous. Using `lastSyncTime` from step 3, explain in one sentence what a customer can lose in an unplanned regional failover.

**Q4.4** Why does the SDK for a RA-GRS account not automatically write to the secondary endpoint when the primary is down?

**Q4.5** Premium storage accounts (premium block blob, premium file shares) do not offer GRS or GZRS. Given that, how would you build cross-region protection for a premium workload?

**Q4.6** Redundancy is *not* backup. Give one failure that LRS through RA-GZRS all fail to protect against, and name the blob feature that does.

---

## Exercise 5 — Azure Files, Queues and Tables in one account

### Steps

1. Create an SMB file share with a quota:

   ```bash
   $ az storage share-rm create \
       --resource-group $RG --storage-account $SA \
       --name projectdata --quota 100 \
       --output table
   ```

   ```
   AccessTier    EnabledProtocols    Name         Quota    ResourceGroup
   ------------  ------------------  -----------  -------  ----------------
   TransactionOptimized  SMB         projectdata  100      rg-az900-storage
   ```

2. Read the mount string Azure would hand a Windows or Linux client:

   ```bash
   $ echo "//$SA.file.core.windows.net/projectdata"
   ```

   ```
   //st900lab1842229517.file.core.windows.net/projectdata
   ```

   On Linux this becomes `mount -t cifs //<account>.file.core.windows.net/projectdata /mnt/share -o vers=3.1.1,...`. On Windows it is `net use Z: \\<account>.file.core.windows.net\projectdata`. Both require **outbound TCP 445**, which most ISPs and many corporate firewalls block — the single most common Azure Files support case.

3. Create a queue and push a message:

   ```bash
   $ az storage queue create --name orders --account-name $SA --auth-mode login --output none
   $ az storage message put --queue-name orders \
       --content '{"orderId":"A-1042","action":"ship"}' \
       --account-name $SA --auth-mode login --output none
   ```

4. Peek at the message without consuming it, then read it properly:

   ```bash
   $ az storage message peek --queue-name orders --account-name $SA --auth-mode login \
       --query "[].{id:id, dequeues:dequeueCount, content:content}" --output table
   ```

   ```
   Id                                    Dequeues    Content
   ------------------------------------  ----------  ------------------------------------
   9d3b1f2e-5a44-4c0e-9b7c-1e2f3a4b5c6d  0           {"orderId":"A-1042","action":"ship"}
   ```

   ```bash
   $ az storage message get --queue-name orders --visibility-timeout 30 \
       --account-name $SA --auth-mode login \
       --query "[].{id:id, pop:popReceipt}" --output yaml
   ```

   ```yaml
   - id: 9d3b1f2e-5a44-4c0e-9b7c-1e2f3a4b5c6d
     pop: AgAAAAMAAAAAAAAAr1Zw...
   ```

5. Create a table and insert an entity with an explicit composite key:

   ```bash
   $ az storage table create --name devices --account-name $SA --auth-mode login --output none
   $ az storage entity insert --table-name devices \
       --entity PartitionKey=warehouse-01 RowKey=sensor-7 temperature=21.4 status=online \
       --account-name $SA --auth-mode login --output none
   $ az storage entity query --table-name devices \
       --filter "PartitionKey eq 'warehouse-01'" \
       --account-name $SA --auth-mode login \
       --query "items[].{pk:PartitionKey, rk:RowKey, t:temperature, s:status}" --output table
   ```

   ```
   Pk            Rk        T     S
   ------------  --------  ----  ------
   warehouse-01  sensor-7  21.4  online
   ```

6. Confirm all four services live in the same account and share its redundancy setting:

   ```bash
   $ az storage account show --name $SA --resource-group $RG \
       --query "{sku:sku.name, endpoints:primaryEndpoints}" --output yaml
   ```

### Check your understanding — block 5

**Q5.1** For each of Blob, Files, Queue and Table, give the access protocol and the one-sentence workload it is designed for.

**Q5.2** You changed the account SKU to GZRS in Exercise 4. Does the `projectdata` file share inherit that redundancy, or is it configured separately?

**Q5.3** Two teams argue: one wants Azure Files for a shared lift-and-shift application drive, the other wants Blob storage with a mounted client. Which is correct and what is the decisive technical reason?

**Q5.4** The queue message in step 4 has a `dequeueCount` and a `popReceipt`, and `get` took a `--visibility-timeout 30`. Describe what happens if the consumer crashes 10 seconds after reading, and what problem that mechanism solves.

**Q5.5** Table storage required both `PartitionKey` and `RowKey`. What is each for, and what does the pair guarantee?

**Q5.6** A developer proposes Table storage for a new global application needing single-digit-millisecond latency and multi-region writes. Which Azure service should they use instead, and what is the migration friction?

---

## Exercise 6 — Managed disks: the storage service that is not in a storage account

### Steps

1. Create a standalone managed disk:

   ```bash
   $ az disk create \
       --resource-group $RG --name disk-data-01 \
       --size-gb 128 --sku StandardSSD_LRS \
       --output table
   ```

   ```
   DiskSizeGb    Location    Name          ProvisioningState    ResourceGroup     Sku
   ------------  ----------  ------------  -------------------  ----------------  ---------------
   128           eastus      disk-data-01  Succeeded            rg-az900-storage  StandardSSD_LRS
   ```

2. Look for it inside the storage account you built:

   ```bash
   $ az storage container list --account-name $SA --auth-mode login --query "[].name" --output tsv
   ```

   ```
   media
   ```

   The disk is nowhere in there.

3. Confirm the disk is its own ARM resource type:

   ```bash
   $ az resource list --resource-group $RG --query "[].{name:name, type:type}" --output table
   ```

   ```
   Name                Type
   ------------------  ---------------------------------
   st900lab1842229517  Microsoft.Storage/storageAccounts
   disk-data-01        Microsoft.Compute/disks
   ```

4. Compare the performance tiers available:

   ```bash
   $ az disk create --resource-group $RG --name disk-test --size-gb 4 --sku UltraSSD_LRS --output none
   ```

   ```
   (BadRequest) UltraSSD disks can only be created in an availability zone that supports them,
   and require the UltraSSDEnabled property on the VM.
   ```

5. Read the disk's SKU options and its redundancy:

   ```bash
   $ az disk show --resource-group $RG --name disk-data-01 \
       --query "{sku:sku.name, tier:sku.tier, size:diskSizeGb, state:diskState}" --output yaml
   ```

   ```yaml
   size: 128
   sku: StandardSSD_LRS
   state: Unattached
   tier: Standard
   ```

### Check your understanding — block 6

**Q6.1** The exam objective lists "disks" among Azure storage services, yet `disk-data-01` is `Microsoft.Compute/disks`. Explain what a *managed* disk manages, and what an *unmanaged* disk was.

**Q6.2** Rank Standard HDD, Standard SSD, Premium SSD, Premium SSD v2 and Ultra Disk by performance, and name the workload signal that should push you up a tier.

**Q6.3** The disk shows `StandardSSD_LRS` and state `Unattached`. Is it billing? Is its data protected against a zone failure?

**Q6.4** A VM is deleted but its data disk is not. What happens to the data, and what does that tell you about the disk's lifecycle relative to the VM?

**Q6.5** In one sentence each, when do you choose a managed disk versus Azure Files versus Blob storage for the same 500 GB of data?

---

## Exercise 7 — Moving data in: AzCopy, Storage Explorer, File Sync

### Steps

1. AzCopy is preinstalled in Cloud Shell. Confirm and authenticate:

   ```bash
   $ azcopy --version
   ```

   ```
   azcopy version 10.27.1
   ```

   ```bash
   $ azcopy login --identity     # in Cloud Shell; use `azcopy login` interactively elsewhere
   ```

2. Build a small source tree and copy it recursively:

   ```bash
   $ mkdir -p upload/2026/{01,02}
   $ for i in 1 2 3; do head -c 512K /dev/urandom > upload/2026/01/file$i.dat; done
   $ for i in 4 5;   do head -c 512K /dev/urandom > upload/2026/02/file$i.dat; done
   $ azcopy copy "upload" "https://$SA.blob.core.windows.net/media/" --recursive
   ```

   ```
   INFO: Scanning...
   Job 6f0a2c11-... has started
   
   Elapsed Time (Minutes): 0.1001
   Number of File Transfers: 5
   Number of Folder Property Transfers: 0
   Total Number of Transfers: 5
   Number of Transfers Completed: 5
   Number of Transfers Failed: 0
   Number of Transfers Skipped: 0
   TotalBytesTransferred: 2621440
   Final Job Status: Completed
   ```

3. Change one file and run `sync` instead of `copy`. Read the counters carefully:

   ```bash
   $ head -c 512K /dev/urandom > upload/2026/01/file2.dat
   $ azcopy sync "upload" "https://$SA.blob.core.windows.net/media/upload" --recursive
   ```

   ```
   INFO: Any empty folders will not be processed...
   Job 8b31d904-... has started
   
   Files Scanned at Source: 5
   Files Scanned at Destination: 5
   Number of Copy Transfers for Files: 1
   Number of Deletions at Destination: 0
   Total Number of Transfers: 1
   Number of Transfers Completed: 1
   Final Job Status: Completed
   ```

4. Inspect a completed job — AzCopy keeps a resumable plan file:

   ```bash
   $ azcopy jobs list --output-type text | head -20
   ```

   ```
   JobId: 8b31d904-...
   Start Time: Saturday, 05 Sep 2026 10:14:32
   Status: Completed
   Command: sync upload https://st900lab1842229517.blob.core.windows.net/media/upload --recursive
   ```

5. **Reason, do not execute.** Read the descriptions of the two GUI/agent tools and answer the questions below.

   - **Azure Storage Explorer** — a free standalone desktop application (Windows, macOS, Linux) that browses blobs, file shares, queues, tables and Data Lake across multiple accounts and subscriptions, with drag-and-drop upload. It uses AzCopy underneath for bulk transfers. It is interactive and human-driven; it is not schedulable.
   - **Azure File Sync** — an agent installed on **Windows Server** that registers the server with a *Storage Sync Service* resource. A *sync group* joins one **cloud endpoint** (an Azure file share) to one or more **server endpoints** (paths on registered servers). With **cloud tiering** enabled, cold files are replaced on the server by pointers and their bytes live only in Azure; the server keeps a local cache sized by a free-space or date policy.

### Check your understanding — block 7

**Q7.1** In step 3, `sync` transferred 1 file where `copy` would have transferred 5. Explain the difference between `azcopy copy` and `azcopy sync`, including the destructive behaviour `sync` can have that `copy` never does.

**Q7.2** For each scenario, choose AzCopy, Storage Explorer, Azure File Sync, or Data Box, and justify in one sentence:
  a. A nightly cron job pushing 40 GB of build artefacts to a container.
  b. An engineer spot-checking whether a blob uploaded correctly, across three subscriptions.
  c. A branch-office Windows file server whose 8 TB share must be centralised in Azure while staff keep their `\\fileserver\share` UNC path.
  d. A 60 TB video archive on-premises behind a 100 Mbps link.

**Q7.3** In Azure File Sync, what exactly is left on the server for a tiered file, and what does the user experience when they open it?

**Q7.4** Storage Explorer "uses AzCopy underneath." Why does that matter when you are deciding which to put in a runbook?

**Q7.5** AzCopy authenticated with `azcopy login`. What is the other common authorisation method for AzCopy, and what is its main operational risk?

---

## Exercise 8 — Migration: sizing the decision, not the tool

This block is arithmetic and judgement. No commands.

### Steps

1. Compute how long an online transfer takes. Use:

   ```
   hours = (size_TB × 8 × 1000 × 1000) / (Mbps × 3600 × utilisation)
   ```

2. Fill in the table. Assume 70 % effective utilisation of the link (a realistic figure once TCP overhead, contention and business-hours throttling are accounted for):

   | Dataset | Link | Hours | Days |
   |---|---|---|---|
   | 5 TB | 1 Gbps | | |
   | 50 TB | 500 Mbps | | |
   | 500 TB | 1 Gbps | | |

3. Match each result to a member of the Azure Data Box family:

   | Product | Raw capacity | Usable capacity | Form factor |
   |---|---|---|---|
   | Data Box Disk | 8 TB per order (up to 5 SSDs, 40 TB) | ~35 TB | Solid-state disks, shipped to you |
   | Data Box | 100 TB | ~80 TB | Ruggedised single-node appliance |
   | Data Box Heavy | 1 PB | ~770 TB | Liftgate-delivered rack-scale appliance |

   Note there is also an **online** branch of the family — Data Box Gateway (a virtual appliance) and Azure Stack Edge (a physical one) — which stream continuously to Azure rather than shipping.

4. Read the role of Azure Migrate: a **hub** that discovers, assesses and migrates on-premises servers, databases, web apps and data. For storage specifically, its assessment output tells you which disks and shares exist, how large they are, and what they would cost in Azure — it is the planning surface that tells you *whether* you need a Data Box at all.

### Check your understanding — block 8

**Q8.1** Give the three computed durations from step 2 (hours and days). Which of the three is clearly a Data Box case, and which is clearly not?

**Q8.2** Why is "usable capacity" smaller than "raw capacity" on every Data Box product, and why does the exam care?

**Q8.3** A Data Box takes roughly 10 days end to end (ship out, copy, ship back, ingest). For the 50 TB / 500 Mbps row, compare that against the online figure — and name the *non-time* factor that might still push you to online transfer.

**Q8.4** Data is written to a Data Box in your datacenter and the appliance is couriered to a Microsoft datacenter. State the two protections that make this acceptable to a security team.

**Q8.5** What is Azure Migrate's relationship to Data Box — competitor, prerequisite, or complement? Justify.

**Q8.6** A team with 3 TB on a 1 Gbps link orders a Data Box "to be safe." What is the argument against, in one sentence?

---

## Exercise 9 — Diagnostics, then cleanup

### Steps

1. Deliberately produce the four errors you will meet in production. Read each one before moving on.

   **a. Wrong endpoint:**

   ```bash
   $ curl -s -o /dev/null -w "%{http_code}\n" https://$SA.blob.core.windows.net/media/report.bin
   ```

   ```
   404
   ```

   Public access is disabled, so an anonymous read returns `404`, **not** `403` — Azure deliberately hides the existence of the resource.

   **b. Expired or malformed SAS:**

   ```bash
   $ SAS=$(az storage container generate-sas --name media --account-name $SA \
       --permissions r --expiry 2020-01-01T00:00Z --auth-mode login --as-user --output tsv 2>/dev/null)
   $ curl -s "https://$SA.blob.core.windows.net/media/report.bin?$SAS" | head -3
   ```

   ```xml
   <?xml version="1.0" encoding="utf-8"?>
   <Error><Code>AuthenticationFailed</Code>
   <Message>Signature not valid in the specified time frame</Message></Error>
   ```

   **c. Name violation:**

   ```bash
   $ az storage account create --name "MyStorageAccount_2026" --resource-group $RG --location $LOC
   ```

   ```
   (AccountNameInvalid) The specified account name is not valid.
   ```

   **d. Tier violation** — you saw `BlobArchived` in Exercise 3. Re-read it now with the tier ladder in mind.

2. Check the account's actual consumption before you delete it:

   ```bash
   $ az storage account show-usage --location $LOC --output table
   $ az storage blob list --container-name media --account-name $SA --auth-mode login \
       --query "sum([].properties.contentLength)" --output tsv
   ```

   ```
   5244440
   ```

3. **Clean up. Do not skip this.**

   ```bash
   $ az group delete --name $RG --yes --no-wait
   $ az group exists --name $RG
   ```

   ```
   true      # returns false once the async delete finishes, typically 2-5 minutes
   ```

4. Verify the role assignment you created in Exercise 2 was removed with the scope:

   ```bash
   $ az role assignment list --assignee $ME --scope $SCOPE --output table
   ```

   ```
   []
   ```

### Check your understanding — block 9

**Q9.1** Step 1a returned `404` rather than `403` for a blob that definitely exists. Why is that the more secure design?

**Q9.2** A SAS token grants access without an Entra ID identity. Name the two things every SAS carries that a role assignment does not, and the one thing you cannot do to an already-issued account-key SAS.

**Q9.3** Deleting the resource group removed the storage account and the disk in one call. What is the one blob feature that could have made the *blobs* survivable after an accidental delete — and would it have survived this particular command?

**Q9.4** Summarise, for the exam: which of these decisions are fixed at account creation and which can be changed later — region, redundancy, performance tier (standard/premium), account kind, access tier, hierarchical namespace.

---

## Sources

- AZ-900 study guide — https://learn.microsoft.com/en-us/credentials/certifications/resources/study-guides/az-900
- Storage account overview — https://learn.microsoft.com/en-us/azure/storage/common/storage-account-overview
- Data redundancy — https://learn.microsoft.com/en-us/azure/storage/common/storage-redundancy
- Disaster recovery and account failover — https://learn.microsoft.com/en-us/azure/storage/common/storage-disaster-recovery-guidance
- Blob access tiers — https://learn.microsoft.com/en-us/azure/storage/blobs/access-tiers-overview
- Archive rehydration — https://learn.microsoft.com/en-us/azure/storage/blobs/archive-rehydrate-overview
- Lifecycle management — https://learn.microsoft.com/en-us/azure/storage/blobs/lifecycle-management-overview
- Azure Files introduction — https://learn.microsoft.com/en-us/azure/storage/files/storage-files-introduction
- Azure File Sync introduction — https://learn.microsoft.com/en-us/azure/storage/file-sync/file-sync-introduction
- Queue Storage introduction — https://learn.microsoft.com/en-us/azure/storage/queues/storage-queues-introduction
- Table Storage overview — https://learn.microsoft.com/en-us/azure/storage/tables/table-storage-overview
- Managed disks overview — https://learn.microsoft.com/en-us/azure/virtual-machines/managed-disks-overview
- AzCopy v10 — https://learn.microsoft.com/en-us/azure/storage/common/storage-use-azcopy-v10
- Storage Explorer — https://learn.microsoft.com/en-us/azure/storage/storage-explorer/vs-azure-tools-storage-manage-with-storage-explorer
- Azure Data Box overview — https://learn.microsoft.com/en-us/azure/databox/data-box-overview
- Azure Migrate overview — https://learn.microsoft.com/en-us/azure/migrate/migrate-services-overview
- Authorize access to blobs with Entra ID — https://learn.microsoft.com/en-us/azure/storage/blobs/authorize-access-azure-active-directory

---

<details>
<summary><strong>Answers</strong> — open only after you have attempted every block</summary>

### Block 1 — The storage account is the boundary

**A1.1** The account name becomes a public DNS hostname: `<name>.blob.core.windows.net` and four siblings. DNS is a single global namespace, so the label must be unique across every Azure customer worldwide. A VM name is only an ARM resource identifier scoped to its resource group; it never becomes a public DNS record unless you separately attach a public IP with a DNS label — and *that* label must then be unique within its region.

**A1.2** A general-purpose v2 account contains **Blob** (including Data Lake Gen2), **Files**, **Queue** and **Table**. The service the exam objective names that is *not* in the account is **Disk** — managed disks are `Microsoft.Compute/disks`, a separate resource type (Exercise 6).

**A1.3**
- *Risk:* RA-GRS is roughly twice the per-GB price of LRS and replicates every byte to a second region. For scratch data, test environments, or data that is already a replica of something else, you pay double for nothing. It also silently places a copy of your data in the paired region, which may violate a data-residency requirement.
- *Benefit:* the data survives a full regional outage and remains readable from the `-secondary` endpoint during it, with no action from you.

**A1.4** `allowBlobPublicAccess = false` at the *account* level is a master switch: while it is false, no container in the account can serve anonymous requests regardless of its own setting. To allow public reads you must first set the account switch to true (`az storage account update --allow-blob-public-access true`), *then* set the container's public access level to `blob` (blobs readable, container not listable) or `container` (blobs readable and listable). The account switch is a guardrail; the container setting is the actual grant. Note the account default has been `false` for new accounts since the 2023 API versions — a deliberate secure-by-default change.

**A1.5** `dfs` is the Data Lake Storage Gen2 endpoint, which speaks a filesystem-oriented API (directories, atomic rename, POSIX-style ACLs). It is listed on every StorageV2 account, but the true hierarchical namespace only exists if the account was created with HNS enabled (`--enable-hierarchical-namespace true`). On this account it is not enabled, so directory operations against `dfs` are emulated over the flat namespace rather than native. HNS cannot be turned on after creation without a migration.

---

### Block 2 — Blob storage

**A2.1** The **control plane** is Azure Resource Manager: creating, configuring, deleting the account, and reading its properties. Owner and Contributor grant this. The **data plane** is the storage REST API: reading and writing the actual blobs, messages and entities, served by `*.blob.core.windows.net` and its siblings — ARM is not in that path at all. Data-plane access needs either an account key, a SAS, or an Entra ID **data role**. You added **Storage Blob Data Contributor**. (Owner *can* read the account keys and thereby reach the data — but that is a separate, auditable action, not the same as having the data role.)

**A2.2**
- **Block blob** — composed of blocks that are uploaded independently and then committed. Optimised for large sequential writes and whole-object reads. Canonical workload: files, images, video, backups, logs. Default type; up to ~190.7 TiB.
- **Append blob** — a block blob optimised for append-only writes; you cannot modify or delete existing blocks. Canonical workload: log files and audit trails written by many concurrent writers.
- **Page blob** — a collection of 512-byte pages supporting random read/write at arbitrary offsets. Canonical workload: VHD files, i.e. the underlying storage for unmanaged disks and the internal representation of managed disks. Up to 8 TiB.

**A2.3** Only in the blob's **name**. `logs/2026/09/app.log` is a single flat key that happens to contain `/` characters. Blob storage has no directory objects. The `--delimiter "/"` flag asks the service to group results by the first `/` and return synthetic "prefixes", which is how portals and tools render a tree. Deleting the "folder" fails because there is no object at that key.

**A2.4** With hierarchical namespace enabled, directories are **real objects**. `logs/2026/09` would exist, could be deleted (recursively, in a single atomic operation), could be renamed atomically, and could carry POSIX ACLs. This is the difference between Blob storage and Azure Data Lake Storage Gen2 — same account, same endpoint family, different namespace semantics. Big-data engines (Spark, Databricks, Synapse) depend on atomic directory rename, which is why HNS matters for analytics.

**A2.5** Account → container → blob is a strict two-level hierarchy: an account holds containers, a container holds blobs, and a blob cannot exist outside a container. Containers cannot nest. Any deeper structure is simulated with `/` in blob names (unless HNS is on).

---

### Block 3 — Access tiers

**A3.1** Most to least expensive **per GB stored**: **Hot → Cool → Cold → Archive**. Moving in the opposite direction, the **access/transaction cost rises** and the **latency rises**. Hot has the cheapest reads and millisecond latency; Archive has the most expensive reads and takes hours to first byte because the data is offline. Archive is also the only *offline* tier — Hot, Cool and Cold are all online.

**A3.2** Minimum retention: **Cool = 30 days, Cold = 90 days, Archive = 180 days.** Deleting, overwriting or moving a blob to a different tier before that period elapses triggers an **early deletion charge**: you are billed pro rata for the remaining days as though the blob had stayed. A blob written and deleted after one day in Archive is billed for 180.

**A3.3** Archive is offline storage. The bytes are not on a spinning disk waiting behind a filesystem — they are on low-cost, high-latency media not attached to the live serving path. There is nothing to read from until Azure physically stages the object back onto online storage. The only operations valid on an archived blob are getting/setting its metadata and properties, deleting it, and starting a rehydration.

**A3.4**
- **High priority:** typically under 1 hour for objects **smaller than 10 GB**; larger objects take longer and the SLA-ish guidance does not apply. Costs significantly more per operation.
- **Standard priority:** up to **15 hours**. Cheaper. This is the default.

Two ways to rehydrate: `set-tier` to an online tier in place (the blob stays archived and shows `rehydrate-pending-to-hot` until it completes, as you saw), or `copy blob` to a *new* blob in an online tier — which leaves the original archived and is usually the better production choice because the source stays available and you can cancel by deleting the copy.

**A3.5** The account-level default tier applies **only to blobs uploaded afterwards that do not specify a tier explicitly** — and to blobs that were inferring the account default rather than carrying an explicit tier. It never retroactively re-tiers blobs with an explicit tier set. **Archive can never be an account default**; it is a blob-level-only tier. Hot, Cool and Cold can all be account defaults.

**A3.6** Every tier transition is a **write operation**, billed per 10,000 operations, and transitions *into* Cool/Cold/Archive are billed at the higher "infrequent access" write rate. For millions of small blobs, the transaction charges can exceed the storage savings outright — especially since Archive's per-GB saving on a 4 KB blob is a fraction of a cent while the transition operation is not. Rule of thumb: tier by size and access pattern, not by age alone. Lifecycle policies support `blobIndexMatch` and prefix filters precisely so you can exclude small objects.

---

### Block 4 — Redundancy

**A4.1**

| Option | Copies in primary | Spread across | Copies in secondary | Secondary readable? |
|---|---|---|---|---|
| LRS | 3 | 3 fault domains in **one** datacenter/physical location | 0 | n/a |
| ZRS | 3 | 3 **availability zones** in the region | 0 | n/a |
| GRS | 3 | 1 datacenter (LRS locally) | 3 (LRS in paired region) | **No** |
| GZRS | 3 | 3 availability zones | 3 (LRS in paired region) | **No** |
| RA-GRS | 3 | 1 datacenter | 3 | **Yes** |
| RA-GZRS | 3 | 3 availability zones | 3 | **Yes** |

Durability figures Microsoft publishes over a year: LRS ≈ 11 nines, ZRS ≈ 12 nines, GRS/GZRS ≈ 16 nines.

**A4.2**
- **Rack failure:** all six options survive it. Even LRS spreads its three copies across separate fault domains (racks) within the facility.
- **Availability-zone loss:** **ZRS, GZRS, RA-GZRS** stay available. LRS is gone if it was in that zone. GRS/RA-GRS lose the primary — RA-GRS can still *read* from the secondary, GRS cannot without a failover.
- **Whole-region loss:** only the geo options — **GRS, GZRS, RA-GRS, RA-GZRS** — still hold a copy.

**A4.3** Anything written to the primary after `lastSyncTime` had not yet reached the secondary, so an unplanned failover loses it permanently. `lastSyncTime` is therefore the concrete, observable RPO at that moment — typically minutes, but never zero and never guaranteed.

**A4.4** The secondary is **read-only by design**. Allowing writes to both regions while replication is asynchronous would create divergent, unreconcilable copies. The secondary only becomes writable after a failover promotes it to primary. Note the two failover kinds: an **unplanned** failover accepts the data loss described in A4.3 and (in the classic form) leaves the account as LRS in the new primary, so you must reconfigure geo-redundancy afterwards; a **customer-managed planned failover** requires a healthy primary, has zero data loss because it waits for replication to complete, and swaps the roles while retaining the redundancy configuration.

**A4.5** Replicate at the application or data layer instead of the storage layer:
- **Object replication** for block blobs — an asynchronous, rule-based copy from a source account to a destination account, which may be in another region.
- A second account in the paired region plus an AzCopy/Data Factory job.
- For premium file shares, **Azure Backup** for file shares, or an application-level sync.
The trade-off is that you now own the replication logic, its monitoring and its RPO.

**A4.6** All six protect against **infrastructure** failure. None protects against **logical** failure: an accidental or malicious delete, an application bug that overwrites good data, or ransomware. The delete replicates faithfully to every copy. The mitigations are **soft delete** (blob and container level, recoverable within a retention window), **blob versioning** (every overwrite keeps the prior version), **point-in-time restore**, **immutable storage** with time-based or legal-hold policies (WORM), and **Azure Backup**. Redundancy is availability; these are recoverability.

---

### Block 5 — Files, Queues, Tables

**A5.1**
- **Blob** — HTTP/HTTPS REST (and `dfs` for Data Lake). Unstructured object storage for anything read by an application or served over the web: media, backups, logs, datasets, static sites.
- **Files** — **SMB 3.x** (Windows/Linux/macOS) and **NFS 4.1** (premium/FileStorage accounts only), plus a REST API. A fully managed network file share that can be mounted with a drive letter or a mount point, for lift-and-shift applications and shared configuration or tooling.
- **Queue** — HTTP/HTTPS REST. Durable, at-least-once messaging that decouples producers from consumers and absorbs load spikes. Messages up to **64 KiB**.
- **Table** — HTTP/HTTPS REST (OData). A schemaless key-value/wide-column NoSQL store for large volumes of structured, non-relational data queried by key. Entities up to **1 MiB** and 255 properties.

**A5.2** It **inherits** it. Redundancy is an account-level property, so the file share, the containers, the queue and the table in this account are all GZRS. That is exactly why the account is the boundary from Exercise 1: you cannot make one share LRS and one container GZRS inside the same account. Different redundancy means a different account. (Caveat: standard file shares over 5 TiB have historically had redundancy restrictions — check the current support matrix for large file shares.)

**A5.3** **Azure Files** is correct. The decisive reason: the application expects a **filesystem** — a mounted path, byte-range writes, file locking, POSIX/NTFS semantics, and a UNC or drive-letter path it was compiled against. Blob storage is an object store; `blobfuse` or similar can present it as a mount but does not provide real file locking or efficient partial writes, and behaves badly under concurrent access. If the application code can be changed to call the blob API, Blob is cheaper and scales further. If it cannot, Files is the answer. That is the lift-and-shift criterion.

**A5.4** `get` makes the message **invisible** to other consumers for the visibility timeout (30 s here) but does **not** delete it. Deleting requires a second call with the `popReceipt` as proof you held it. If the consumer crashes at t+10 s, the message becomes visible again at t+30 s, another consumer picks it up, and `dequeueCount` increments to 2. This gives **at-least-once delivery**: no message is lost to a consumer crash. The consequence you must design for is that a message can be processed twice, so handlers should be idempotent. `dequeueCount` is also how you detect a **poison message** — one that keeps crashing its consumer — and route it to a dead-letter queue after N attempts.

**A5.5**
- **PartitionKey** — determines which partition (and therefore which physical partition server) the entity lives on. It is the unit of scale-out and the unit of transaction scope: entity-group transactions only work within a single partition.
- **RowKey** — uniquely identifies the entity within its partition. Entities are stored sorted by RowKey, so range queries on RowKey within one partition are efficient.

Together the pair is the **primary key** and is guaranteed unique across the table; it is also the only index. A query filtering on both is a point lookup; a query on PartitionKey alone is a partition scan; a query on neither is a full table scan.

**A5.6** **Azure Cosmos DB for Table** (the Table API). It offers turnkey global distribution with multi-region writes, single-digit-millisecond latency backed by SLAs, automatic secondary indexing on every property, and five tunable consistency levels — none of which Table storage has. Migration friction is deliberately low: the wire protocol and SDKs are compatible, so it is largely a connection-string change. The real friction is **cost model** — Cosmos DB bills provisioned or serverless request units, which is far more expensive than Table storage's per-GB-and-per-transaction pricing, and a partition-key design that was fine at Table-storage scale may become an expensive hot partition in Cosmos.

---

### Block 6 — Managed disks

**A6.1** A managed disk is still, underneath, a **page blob** — but Azure owns the storage account it lives in, and you never see it. What is "managed" is exactly that: Microsoft handles the account placement, the IOPS/throughput limits, the fault-domain spreading, and the scaling. An **unmanaged disk** (the pre-2017 model, now retired for new deployments) required you to create and manage the storage account yourself, which meant you could accidentally put every disk of an availability set into a single account and turn it into a single point of failure — and you had to track the per-account IOPS ceiling (20,000) by hand. Managed disks eliminated both failure modes.

**A6.2** Slowest to fastest: **Standard HDD → Standard SSD → Premium SSD → Premium SSD v2 → Ultra Disk.**
The signal that should push you up a tier is **IOPS and latency requirements**, not capacity. Backup targets and dev/test tolerate Standard HDD. Web servers and lightly used production sit on Standard SSD. Production databases and anything latency-sensitive need Premium SSD. Premium SSD v2 and Ultra Disk let you provision IOPS and throughput **independently of disk size**, which is the tell: if you need 20,000 IOPS on a 100 GB volume, the older tiers force you to over-buy capacity to get performance, and v2/Ultra do not. Ultra additionally supports sub-millisecond latency and live resizing of performance, at the cost of zone/VM restrictions (as step 4 showed) and no snapshot support parity.

**A6.3** **Yes, it is billing.** Managed disks are billed on **provisioned** capacity, not consumed, and being `Unattached` changes nothing — an orphaned disk after a VM delete is one of the most common sources of surprise Azure spend. As for zone failure: `StandardSSD_LRS` is locally redundant, so **no**, it is not protected against losing an availability zone. `StandardSSD_ZRS` would be. Ultra Disk and Premium SSD v2 are LRS-only.

**A6.4** The data **survives intact**. A managed disk is an independent ARM resource with its own lifecycle; a VM merely references it. Deleting the VM deletes the OS disk only if the `deleteOption` on that disk is set to `Delete` (the portal default for the OS disk in recent versions), and data disks default to being **detached and retained** unless you explicitly opt into cascade delete. Practically, this means (a) you can reattach the disk to a new VM and recover the data, and (b) you must audit for orphaned disks or you will pay for them forever.

**A6.5**
- **Managed disk** — when exactly one VM needs it as a block device: the OS volume, a database's data files, anything requiring raw block semantics and per-VM performance guarantees.
- **Azure Files** — when several machines or people need the *same* data through a filesystem path simultaneously: a shared application drive, user home directories, a config share for a scale set.
- **Blob storage** — when the data is objects consumed by an application over HTTP and no filesystem semantics are needed: media, backups, datasets, static content. Cheapest by a wide margin and the only one with Archive tiering.

---

### Block 7 — Moving data in

**A7.1** `copy` transfers every source item unconditionally (or skips per `--overwrite`), producing a one-way push. `sync` first enumerates **both** sides, compares last-modified timestamps and sizes, and transfers only differences — which is why it moved one file. The destructive behaviour is `--delete-destination`: `sync` can **delete files at the destination that no longer exist at the source**, making the destination a mirror. `copy` never deletes anything. Run `sync --delete-destination=prompt` before you ever run it with `=true` in a script.

**A7.2**
- **a. AzCopy.** It is a command-line binary, scriptable, resumable via its job plan, and handles concurrency and retries. Storage Explorer cannot be scheduled.
- **b. Azure Storage Explorer.** Interactive, multi-account, multi-subscription browsing with a GUI. This is exactly the human spot-check case; scripting it would be more work than the task.
- **c. Azure File Sync.** It keeps the on-premises Windows Server as the access point (staff keep `\\fileserver\share`) while the authoritative copy lives in an Azure file share, and cloud tiering means the 8 TB does not need 8 TB of local disk. AzCopy would be a one-shot copy with no ongoing sync and would not preserve the UNC access path.
- **d. Azure Data Box.** 60 TB over 100 Mbps at 70 % utilisation is roughly 1,900 hours ≈ 79 days. A Data Box (100 TB raw / ~80 TB usable) turns that into about 10 days including shipping.

**A7.3** The file's **metadata and a sparse pointer (a reparse point)** remain on the server — the file appears in Explorer with its correct name, size, timestamps and permissions, and it is marked offline. When a user opens it, the File Sync filter driver transparently recalls the bytes from the Azure file share. The user sees a delay proportional to file size and link speed, then the file opens normally. Applications that scan or index every file (some antivirus scanners, backup agents, search indexers) will recall the entire dataset and defeat tiering — excluding them is standard practice.

**A7.4** Because it means Storage Explorer inherits AzCopy's transfer performance and semantics but adds a GUI and an interactive login that a runbook cannot drive. If you need the transfer behaviour, call AzCopy directly: it is headless, scriptable, exits with a status code, and logs to a plan file you can query with `azcopy jobs`. Putting a desktop GUI in an automation path is the anti-pattern.

**A7.5** A **shared access signature (SAS)** appended to the destination URL. Its main operational risk is that the SAS is a **bearer token in a URL**: anyone who obtains it has exactly its permissions until it expires, it appears in shell history, process listings and logs, and an account-key-derived SAS cannot be individually revoked — the only way to invalidate it is to rotate the account key, which breaks every other SAS derived from it. A **user delegation SAS** (signed with Entra ID credentials, as in Exercise 9) is the safer form because it is bounded by the signing identity's own permissions and by a maximum 7-day lifetime.

---

### Block 8 — Migration

**A8.1** Using `hours = (TB × 8 × 10⁶) / (Mbps × 3600 × 0.7)`:

| Dataset | Link | Hours | Days |
|---|---|---|---|
| 5 TB | 1 Gbps | ≈ 16 h | ≈ 0.7 days |
| 50 TB | 500 Mbps | ≈ 317 h | ≈ 13 days |
| 500 TB | 1 Gbps | ≈ 1,587 h | ≈ 66 days |

**5 TB / 1 Gbps** is clearly *not* a Data Box case — it finishes overnight over the wire. **500 TB / 1 Gbps** is clearly a Data Box case (Data Box Heavy, or several Data Boxes) — two months of saturated WAN is not a migration plan. The 50 TB row is the genuinely arguable middle, which is the point of the exercise.

**A8.2** Raw capacity is the sum of the physical media; usable capacity is what remains after the appliance's own **encryption overhead, RAID/parity, filesystem overhead and reserved space**. The exam cares because the sizing question is always asked against *usable* figures: an 85 TB dataset does not fit on a 100 TB Data Box, because the usable figure is ~80 TB.

**A8.3** Online is ~13 days; Data Box is ~10 days end to end. On pure elapsed time they are nearly a wash, so time is not the deciding factor here. The **non-time factor** is **link contention**: the online transfer consumes 500 Mbps (or 70 % of it) continuously for 13 days, degrading every other business use of that circuit — VPNs, VoIP, SaaS, backups. Data Box moves the load off the WAN entirely. The counter-argument for online is that it needs **no physical logistics, no chain of custody, and no change freeze** — the data can keep changing during a long online sync (with a final delta pass), whereas a Data Box captures a point-in-time snapshot and everything written after the copy must be reconciled separately.

**A8.4** (1) The data is **encrypted at rest on the appliance with AES-256**, and the unlock key is delivered to you separately through the Azure portal, never travelling with the device — a courier who steals it gets ciphertext. (2) **Chain of custody and secure erase**: the device is tracked as a managed Azure resource through the whole journey, and after the data is ingested into your storage account Microsoft **securely wipes the appliance to NIST SP 800-88 standards** before reuse. Add that the device is ruggedised and tamper-evident.

**A8.5** **Complement, and in practice a prerequisite for the decision.** Azure Migrate discovers and assesses what you have — server inventory, disk sizes, dependencies, right-sized Azure targets, cost estimates. Data Box moves bytes. You use Azure Migrate's assessment to learn that you have, say, 47 TB across 60 servers on a 500 Mbps link, and *that* is the input to the Data-Box-or-not decision. They are not competitors: Azure Migrate has no offline-shipping capability, and Data Box has no discovery or assessment capability.

**A8.6** 3 TB over 1 Gbps at realistic utilisation completes in roughly **10 hours** — less than a single overnight window — so ordering a Data Box adds a week or more of shipping and handling, physical logistics, and a chain-of-custody process to a problem that solves itself before the next business day.

---

### Block 9 — Diagnostics and cleanup

**A9.1** Returning `403 Forbidden` would confirm to an unauthenticated caller that a blob named `report.bin` exists in a container named `media` — an information leak that lets an attacker enumerate your namespace by response code alone. `404 Not Found` is indistinguishable from a genuinely absent blob, so an anonymous caller learns nothing. This is the same reasoning behind "invalid username or password" instead of "no such user."

**A9.2** Every SAS carries (1) an **explicit expiry time** and (2) a **fixed set of permissions and a scope** (service/container/blob, plus optional IP range and allowed protocol) baked into its signature — a role assignment has no expiry and is evaluated dynamically at request time. What you **cannot** do to an already-issued account-key SAS is **revoke it individually**: the only remedies are to wait for expiry, rotate the signing account key (invalidating every SAS derived from it), or — if you planned ahead — have issued it against a **stored access policy** on the container, which *can* be modified or deleted to revoke the SAS. A user delegation SAS can also be revoked by revoking the delegation key.

**A9.3** **Blob soft delete** (with container soft delete and versioning) is the feature that makes an accidental blob delete recoverable — deleted blobs are retained and restorable for the configured retention period. But it would **not** have survived this command. `az group delete` removes the storage **account** itself, and soft delete operates *within* an account. The account-level protections are **resource locks** (`CanNotDelete`) and, if the subscription and account meet the criteria, **storage account soft delete / account recovery** within the deletion retention window. The general lesson: data-plane protections do not defend against control-plane deletion; you need a lock or a policy for that.

**A9.4**

| Decision | Changeable after creation? |
|---|---|
| **Region** | **No.** You must create a new account in the target region and copy the data (AzCopy, object replication, Data Factory). |
| **Redundancy** | **Yes**, with rules. LRS ↔ GRS ↔ RA-GRS is a simple SKU update. LRS ↔ ZRS requires a conversion and cannot be reached directly from a geo SKU — go GRS → LRS → ZRS, as Exercise 4 demonstrated. Some conversions are region-limited. |
| **Performance tier (standard/premium)** | **No.** Standard and premium are different account kinds under the hood; migration means a new account and a data copy. |
| **Account kind** (StorageV2 / BlockBlobStorage / FileStorage) | **No** for standard↔premium kinds. Legacy Storage (v1) and BlobStorage accounts *can* be upgraded to StorageV2 in place, one way. |
| **Access tier** | **Yes**, freely — at account level (default for new blobs) and per blob, subject to early-deletion charges and the Archive rehydration delay. |
| **Hierarchical namespace (HNS)** | **No** in the normal sense — it is set at creation. Microsoft provides a one-way upgrade path from a non-HNS StorageV2 account to HNS, but it cannot be reversed and has prerequisites. Treat it as a creation-time decision. |

The exam-ready summary: **region, performance tier and account kind are permanent; redundancy and access tier are not.** That is why Exercise 1 called the account a boundary.

</details>