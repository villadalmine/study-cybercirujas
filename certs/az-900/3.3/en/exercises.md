# AZ-900 — Topic 3.3: Features and Tools for Managing and Deploying Azure Resources
## Guided Exercises (hands-on lab)

> **Exam weight:** 8.33% · **Exam version:** 2026-07-20
> **Official study guide:** https://learn.microsoft.com/en-us/credentials/certifications/resources/study-guides/az-900

---

## 0. Lab prerequisites and cost control

This lab uses an Azure subscription (a free trial or Pay-As-You-Go works). Every resource created here is either free or costs cents per month, and Exercise 9 deletes everything.

| Component | Cost profile |
|---|---|
| Resource group, ARM deployments, locks, tags | Free — control-plane metadata |
| `Standard_LRS` StorageV2 account, empty | ~$0.02/month, billed on stored GB |
| Cloud Shell backing Azure Files share (5 GB image) | ~$0.30/month, or use the ephemeral session (no storage) |
| Azure Arc-enabled servers / Kubernetes — control plane | Free (Policy guest configuration, Change Tracking inventory, Update Manager assessment) |
| Arc + Microsoft Defender for Cloud / Log Analytics ingestion | **Billed** — do not enable in this lab |

**Environment options**

1. **Azure Cloud Shell** (browser, nothing to install) — used deliberately in Exercise 2.
2. **Local workstation** — install the Azure CLI (`az`) 2.60+ and, optionally, the `Az` PowerShell module 11+.

```bash
# Local install check
az version
```

```
{
  "azure-cli": "2.64.0",
  "azure-cli-core": "2.64.0",
  "azure-cli-telemetry": "1.1.0",
  "extensions": {}
}
```

---

## Exercise 1 — Azure Resource Manager: the single control plane

**Goal:** prove empirically that the portal, the CLI, PowerShell and the SDKs are *clients*, not management planes. Azure Resource Manager (ARM) is the one service that authenticates, authorizes, validates and executes every management request.

### Steps

1. Authenticate and inspect the active subscription context.

   ```bash
   az login
   az account show --output table
   ```

   ```
   EnvironmentName    HomeTenantId                          IsDefault    Name                    State    TenantId
   -----------------  ------------------------------------  -----------  ----------------------  -------  ------------------------------------
   AzureCloud         8f2b1c4a-3e77-4a1c-9c5c-0d1e2f3a4b5c  True         Pay-As-You-Go           Enabled  8f2b1c4a-3e77-4a1c-9c5c-0d1e2f3a4b5c
   ```

2. Export the subscription ID for reuse.

   ```bash
   export SUB_ID=$(az account show --query id -o tsv)
   export LOC=eastus
   export RG=rg-az900-lab
   echo "$SUB_ID"
   ```

3. Create the lab resource group with tags.

   ```bash
   az group create \
     --name "$RG" \
     --location "$LOC" \
     --tags env=lab course=az900 owner=student
   ```

   ```json
   {
     "id": "/subscriptions/8f2b1c4a-.../resourceGroups/rg-az900-lab",
     "location": "eastus",
     "managedBy": null,
     "name": "rg-az900-lab",
     "properties": {
       "provisioningState": "Succeeded"
     },
     "tags": {
       "course": "az900",
       "env": "lab",
       "owner": "student"
     },
     "type": "Microsoft.Resources/resourceGroups"
   }
   ```

4. Now issue **the exact same operation** as a raw ARM REST call. `az rest` attaches your bearer token and talks straight to `management.azure.com` — this is literally what the portal's JavaScript does.

   ```bash
   az rest --method get \
     --url "https://management.azure.com/subscriptions/$SUB_ID/resourcegroups?api-version=2021-04-01" \
     --query "value[].{name:name, location:location, state:properties.provisioningState}" \
     -o table
   ```

   ```
   Name            Location    State
   --------------  ----------  ---------
   rg-az900-lab    eastus      Succeeded
   NetworkWatcherRG eastus     Succeeded
   ```

5. Decompose an ARM **resource ID**. Every object in Azure has one, and it encodes its full scope path.

   ```bash
   az group show --name "$RG" --query id -o tsv
   ```

   ```
   /subscriptions/8f2b1c4a-3e77-4a1c-9c5c-0d1e2f3a4b5c/resourceGroups/rg-az900-lab
   ```

6. Inspect **resource providers** — the ARM extensions that actually implement each resource type. A provider must be *registered* in the subscription before its types can be deployed.

   ```bash
   az provider list --query "[?registrationState=='Registered'].namespace" -o tsv | sort | head -10
   az provider show --namespace Microsoft.Storage \
     --query "resourceTypes[?resourceType=='storageAccounts'].apiVersions[0] | [0]" -o tsv
   ```

   ```
   Microsoft.Advisor
   Microsoft.Authorization
   Microsoft.Cache
   Microsoft.Compute
   Microsoft.Network
   Microsoft.Resources
   Microsoft.Storage
   ...
   2024-01-01
   ```

7. Check a provider you have *not* used yet — you will need it in Exercise 8.

   ```bash
   az provider show --namespace Microsoft.HybridCompute --query registrationState -o tsv
   ```

   ```
   NotRegistered
   ```

### Verify your understanding — Block 1

- **Q1.1** — You create a VM in the Azure portal, then delete it with Azure PowerShell, then query it with the Python SDK. How many management planes were involved, and what does that imply for RBAC and Azure Policy enforcement?
- **Q1.2** — Given the ID `/subscriptions/8f2b.../resourceGroups/rg-az900-lab/providers/Microsoft.Storage/storageAccounts/stlab001`, name each of the five segments and state which one identifies the *resource provider*.
- **Q1.3** — A colleague's `az deployment group create` fails with `MissingSubscriptionRegistration`. What is the cause and what is the fix?
- **Q1.4** — ARM is described as "region-agnostic and highly available." If the `eastus` region is degraded, can you still *manage* (list, tag, delete) resources located in `westeurope`? Why?

---

## Exercise 2 — Azure Cloud Shell: Bash, PowerShell, and its persistence model

**Goal:** understand what Cloud Shell actually is — an ephemeral, per-user container with a mounted Azure Files share — and when its statefulness matters.

### Steps

1. Open https://portal.azure.com and click the **Cloud Shell** icon (`>_`) in the top toolbar, or browse directly to https://shell.azure.com.

2. When prompted, choose **Bash**. If offered, pick **Mount storage account** → *We will create a storage account for you*, or select **No storage account required** for an ephemeral session.

3. Inspect the container you landed in.

   ```bash
   uname -a
   df -h | grep -E 'clouddrive|Filesystem'
   echo $HOME
   ```

   ```
   Linux cc-abcd1234-5678-9abc-def0-123456789abc 5.15.0-1073-azure #82-Ubuntu SMP x86_64 GNU/Linux
   Filesystem                                             Size  Used Avail Use% Mounted on
   //cs710000abcdef123.file.core.windows.net/cs-student-...  5.0G  1.2G  3.9G  24% /home/student/clouddrive
   /home/student
   ```

4. Confirm the tooling that ships preinstalled — this is the point of Cloud Shell.

   ```bash
   for t in az kubectl helm terraform ansible git jq bicep; do
     printf "%-10s %s\n" "$t" "$(command -v $t || echo MISSING)"
   done
   az bicep version
   ```

   ```
   az         /usr/bin/az
   kubectl    /usr/local/bin/kubectl
   helm       /usr/local/bin/helm
   terraform  /usr/local/bin/terraform
   ansible    /opt/ansible/bin/ansible
   git        /usr/bin/git
   jq         /usr/bin/jq
   bicep      MISSING
   Bicep CLI version 0.30.3 (managed by the Azure CLI)
   ```

5. Test the persistence boundary. Write one file inside `$HOME` and one inside `clouddrive`.

   ```bash
   echo "ephemeral" > ~/scratch.txt
   echo "persisted"  > ~/clouddrive/lab-notes.txt
   ls -l ~/scratch.txt ~/clouddrive/lab-notes.txt
   ```

6. Type `exit`, wait for the session to recycle (or simply close and reopen Cloud Shell), then re-check both files.

   ```bash
   cat ~/clouddrive/lab-notes.txt   # survives
   cat ~/scratch.txt                # may or may not survive; not guaranteed
   ```

   ```
   persisted
   cat: /home/student/scratch.txt: No such file or directory
   ```

7. Switch the shell type without leaving the browser: use the **Bash ⇄ PowerShell** selector in the Cloud Shell toolbar, then run the PowerShell equivalents of Exercise 1.

   ```powershell
   Get-AzContext | Format-List Name, Account, Subscription, Tenant
   Get-AzResourceGroup -Name rg-az900-lab | Select-Object ResourceGroupName, Location, ProvisioningState
   ```

   ```
   ResourceGroupName Location ProvisioningState
   ----------------- -------- -----------------
   rg-az900-lab      eastus   Succeeded
   ```

8. Compare the two CLIs on the same task and note the object model difference. Azure CLI emits **JSON text**; Azure PowerShell emits **.NET objects** you can pipe.

   ```bash
   # Azure CLI — JMESPath query, text out
   az group list --query "[?tags.env=='lab'].name" -o tsv
   ```

   ```powershell
   # Azure PowerShell — object pipeline, no string parsing
   Get-AzResourceGroup | Where-Object { $_.Tags.env -eq 'lab' } | Select-Object -Expand ResourceGroupName
   ```

### Verify your understanding — Block 2

- **Q2.1** — Cloud Shell is advertised as free. What exactly is billed, and what is not?
- **Q2.2** — A student saves an SSH private key to `~/.ssh/id_rsa` in Cloud Shell and finds it gone the next day. Where should it have gone, and why?
- **Q2.3** — Your workstation is a locked-down corporate laptop with no software-install rights, and you must run `kubectl` against an AKS cluster right now. Which tool solves this and what are its two shell options?
- **Q2.4** — You need to script "for every resource group tagged `env=lab`, list its resources and total them." Which of Azure CLI or Azure PowerShell fits more naturally, and what is the underlying reason?
- **Q2.5** — Is the Azure CLI limited to Cloud Shell? On which operating systems does it run?

---

## Exercise 3 — The Azure portal and Resource Graph: discovery at scale

**Goal:** map portal features to their API equivalents, and understand why the portal alone does not scale to thousands of resources.

### Steps

1. In the portal, open **rg-az900-lab** → left blade → **Overview**. Note the **Deployments** counter (currently `0 Succeeded`).

2. Pin the resource group to a dashboard: **Overview → ⋯ → Pin to dashboard**. Then go to **Dashboard hub** and confirm the tile appears. Dashboards are themselves ARM resources of type `Microsoft.Portal/dashboards` and can be shared and RBAC-controlled.

3. Verify that claim from the CLI:

   ```bash
   az resource list --resource-type Microsoft.Portal/dashboards --query "[].{name:name, rg:resourceGroup}" -o table
   ```

4. Open **All services → Resource Graph Explorer** in the portal, and run this KQL query:

   ```kusto
   Resources
   | summarize count() by type, location
   | order by count_ desc
   | limit 10
   ```

5. Run the same query from the CLI. Azure Resource Graph indexes resources across *all* subscriptions you can read, which the per-resource-group portal blades cannot do.

   ```bash
   az extension add --name resource-graph --only-show-errors
   az graph query -q "Resources | project name, type, location, resourceGroup | limit 5" -o table
   ```

   ```
   Name                Type                                  Location    ResourceGroup
   ------------------  ------------------------------------  ----------  ---------------
   NetworkWatcher_eastus  microsoft.network/networkwatchers   eastus      NetworkWatcherRG
   ...
   ```

6. Reproduce the portal's **Export template** feature from the CLI — this is how you reverse-engineer manually built ("ClickOps") infrastructure into code.

   ```bash
   az group export --name "$RG" > exported-rg.json
   head -20 exported-rg.json
   ```

   ```json
   {
     "$schema": "https://schema.management.azure.com/schemas/2015-01-01/deploymentTemplate.json#",
     "contentVersion": "1.0.0.0",
     "parameters": {},
     "resources": []
   }
   ```

7. Open **Help + support → Azure mobile app** promotion, or install the *Azure* mobile app, and confirm you can view the same resource group. The portal, the mobile app and the CLI are three front ends over one API.

### Verify your understanding — Block 3

- **Q3.1** — Name three things the Azure portal offers that a raw REST call does not, and one thing REST/CLI offers that the portal cannot practically do.
- **Q3.2** — A manager asks: "how many storage accounts do we own across 47 subscriptions, and where?" Why is the portal's resource list the wrong tool, and which service answers this?
- **Q3.3** — Infrastructure was built by hand over two years and nobody has templates. Which portal/CLI capability gives you a starting point, and what is its main limitation?
- **Q3.4** — Are Azure portal dashboards a personal UI setting or a governable Azure resource? Justify with what you observed in step 3.

---

## Exercise 4 — ARM templates: declarative deployment, idempotency and modes

**Goal:** author a syntactically valid ARM JSON template, deploy it, redeploy it to observe idempotency, and understand the *Incremental* vs *Complete* mode distinction — the single most exam-relevant ARM behaviour.

### Steps

1. Create the template file `storage.json`.

   ```bash
   mkdir -p ~/az900-lab && cd ~/az900-lab
   cat > storage.json <<'EOF'
   {
     "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#",
     "contentVersion": "1.0.0.0",
     "metadata": {
       "description": "AZ-900 3.3 lab - StorageV2 account with hardened defaults."
     },
     "parameters": {
       "location": {
         "type": "string",
         "defaultValue": "[resourceGroup().location]",
         "metadata": { "description": "Region; defaults to the resource group location." }
       },
       "skuName": {
         "type": "string",
         "defaultValue": "Standard_LRS",
         "allowedValues": [ "Standard_LRS", "Standard_GRS", "Standard_ZRS" ],
         "metadata": { "description": "Storage redundancy tier." }
       },
       "environment": {
         "type": "string",
         "defaultValue": "lab"
       }
     },
     "variables": {
       "storageAccountName": "[toLower(concat('stlab', uniqueString(resourceGroup().id)))]"
     },
     "resources": [
       {
         "type": "Microsoft.Storage/storageAccounts",
         "apiVersion": "2023-05-01",
         "name": "[variables('storageAccountName')]",
         "location": "[parameters('location')]",
         "sku": { "name": "[parameters('skuName')]" },
         "kind": "StorageV2",
         "tags": {
           "env": "[parameters('environment')]",
           "course": "az900",
           "managedBy": "arm-template"
         },
         "properties": {
           "accessTier": "Hot",
           "minimumTlsVersion": "TLS1_2",
           "supportsHttpsTrafficOnly": true,
           "allowBlobPublicAccess": false,
           "allowSharedKeyAccess": true,
           "networkAcls": {
             "defaultAction": "Allow",
             "bypass": "AzureServices"
           }
         }
       }
     ],
     "outputs": {
       "storageAccountName": {
         "type": "string",
         "value": "[variables('storageAccountName')]"
       },
       "primaryBlobEndpoint": {
         "type": "string",
         "value": "[reference(resourceId('Microsoft.Storage/storageAccounts', variables('storageAccountName'))).primaryEndpoints.blob]"
       }
     }
   }
   EOF
   ```

2. **Validate** the template — a schema/parameter/API-version check that never touches real resources.

   ```bash
   az deployment group validate \
     --resource-group "$RG" \
     --template-file storage.json \
     --query "{state:properties.provisioningState, errors:error}" -o json
   ```

   ```json
   {
     "errors": null,
     "state": "Succeeded"
   }
   ```

3. Run a **what-if** preview. This is validation plus a real diff against current state — the professional pre-deployment gate.

   ```bash
   az deployment group what-if \
     --resource-group "$RG" \
     --name lab-storage \
     --template-file storage.json
   ```

   ```
   Note: The result may contain false positive predictions (noise).
   You can help us improve the accuracy of the result by opening an issue here: https://aka.ms/WhatIfIssues

   Resource and property changes are indicated with these symbols:
     + Create

   The deployment will update the following scope:

   Scope: /subscriptions/8f2b1c4a-.../resourceGroups/rg-az900-lab

     + Microsoft.Storage/storageAccounts/stlab3kq7hv2nrxa4e [2023-05-01]

         apiVersion:            "2023-05-01"
         kind:                  "StorageV2"
         location:              "eastus"
         properties.accessTier: "Hot"
         ...
         sku.name:              "Standard_LRS"

   Resource changes: 1 to create.
   ```

4. Deploy for real, in the default **Incremental** mode.

   ```bash
   az deployment group create \
     --resource-group "$RG" \
     --name lab-storage \
     --template-file storage.json \
     --parameters skuName=Standard_LRS environment=lab \
     --query "{state:properties.provisioningState, mode:properties.mode, outputs:properties.outputs}" -o json
   ```

   ```json
   {
     "mode": "Incremental",
     "outputs": {
       "primaryBlobEndpoint": {
         "type": "String",
         "value": "https://stlab3kq7hv2nrxa4e.blob.core.windows.net/"
       },
       "storageAccountName": {
         "type": "String",
         "value": "stlab3kq7hv2nrxa4e"
       }
     },
     "state": "Succeeded"
   }
   ```

5. **Prove idempotency.** Run the *identical* command again and compare the what-if output.

   ```bash
   az deployment group what-if \
     --resource-group "$RG" --name lab-storage --template-file storage.json \
     --parameters skuName=Standard_LRS environment=lab
   ```

   ```
     = Microsoft.Storage/storageAccounts/stlab3kq7hv2nrxa4e

   Resource changes: no change.
   ```

6. Create a resource **outside** the template, so the resource group now contains drift.

   ```bash
   az network vnet create \
     --resource-group "$RG" --name vnet-orphan \
     --address-prefix 10.42.0.0/16 --subnet-name default --subnet-prefix 10.42.1.0/24 \
     --query "{name:name, state:provisioningState}" -o json
   ```

7. Preview a **Complete** mode deployment. Do not execute it blind — read the diff.

   ```bash
   az deployment group what-if \
     --resource-group "$RG" \
     --template-file storage.json \
     --mode Complete
   ```

   ```
   Resource and property changes are indicated with these symbols:
     - Delete
     = NoChange

     - Microsoft.Network/virtualNetworks/vnet-orphan

     = Microsoft.Storage/storageAccounts/stlab3kq7hv2nrxa4e

   Resource changes: 1 to delete, 1 no change.
   ```

8. Inspect the **deployment history** ARM keeps per resource group.

   ```bash
   az deployment group list --resource-group "$RG" \
     --query "[].{name:name, mode:properties.mode, state:properties.provisioningState, ts:properties.timestamp}" -o table
   ```

   ```
   Name           Mode         State      Ts
   -------------  -----------  ---------  --------------------------------
   lab-storage    Incremental  Succeeded  2026-09-05T14:22:41.118392+00:00
   vnet-orphan    Incremental  Succeeded  2026-09-05T14:25:03.771204+00:00
   ```

9. Delete the orphan VNet the safe way (explicitly, not via Complete mode).

   ```bash
   az network vnet delete --resource-group "$RG" --name vnet-orphan
   ```

### Verify your understanding — Block 4

- **Q4.1** — Define *declarative* vs *imperative* deployment, and classify: (a) `storage.json`, (b) `az storage account create`, (c) a Bash `for` loop calling `az vm create`.
- **Q4.2** — You ran the same template twice and the second run reported "no change." What property of ARM templates is this, and why does it matter for a CI/CD pipeline that redeploys on every commit?
- **Q4.3** — What exactly is the difference between Incremental and Complete mode, which is the default, and what is the classic production incident caused by Complete mode?
- **Q4.4** — What does `az deployment group what-if` give you that `az deployment group validate` does not?
- **Q4.5** — Why is `uniqueString(resourceGroup().id)` used for the storage account name instead of a hard-coded string? Give two reasons.
- **Q4.6** — Where does ARM store the record that `lab-storage` was deployed, and at which scope does that history live?

---

## Exercise 5 — Bicep: the DSL that compiles to ARM JSON

**Goal:** see that Bicep is a *transpiler front end* for the same ARM API — not a different deployment engine — and that JSON and Bicep are mechanically interconvertible.

### Steps

1. Decompile the JSON you wrote into Bicep.

   ```bash
   az bicep decompile --file storage.json
   cat storage.bicep
   ```

   ```bicep
   param location string = resourceGroup().location

   @allowed([
     'Standard_LRS'
     'Standard_GRS'
     'Standard_ZRS'
   ])
   param skuName string = 'Standard_LRS'

   param environment string = 'lab'

   var storageAccountName = toLower('stlab${uniqueString(resourceGroup().id)}')

   resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
     name: storageAccountName
     location: location
     sku: {
       name: skuName
     }
     kind: 'StorageV2'
     tags: {
       env: environment
       course: 'az900'
       managedBy: 'arm-template'
     }
     properties: {
       accessTier: 'Hot'
       minimumTlsVersion: 'TLS1_2'
       supportsHttpsTrafficOnly: true
       allowBlobPublicAccess: false
       allowSharedKeyAccess: true
       networkAcls: {
         defaultAction: 'Allow'
         bypass: 'AzureServices'
       }
     }
   }

   output storageAccountName string = storageAccount.name
   output primaryBlobEndpoint string = storageAccount.properties.primaryEndpoints.blob
   ```

2. Compile it back to ARM JSON and look at what ARM actually receives.

   ```bash
   az bicep build --file storage.bicep --outfile storage.compiled.json
   jq '.metadata' storage.compiled.json
   ```

   ```json
   {
     "_generator": {
       "name": "bicep",
       "version": "0.30.3.12046",
       "templateHash": "13297054621175288904"
     }
   }
   ```

3. Compare line counts — the practical argument for Bicep.

   ```bash
   wc -l storage.json storage.bicep storage.compiled.json
   ```

   ```
     62 storage.json
     36 storage.bicep
     58 storage.compiled.json
   ```

4. Deploy the `.bicep` file directly. The CLI transpiles in memory; ARM never sees Bicep syntax.

   ```bash
   az deployment group create \
     --resource-group "$RG" \
     --name lab-storage-bicep \
     --template-file storage.bicep \
     --confirm-with-what-if
   ```

   ```
   Resource and property changes are indicated with this symbol:
     = NoChange

   Resource changes: no change.

   Are you sure you want to execute the deployment? (y/n): y
   ```

5. Introduce a deliberate error and observe **build-time** type checking, which JSON templates cannot offer.

   ```bash
   sed -i "s/accessTier: 'Hot'/accessTier: 'Warm'/" storage.bicep
   az bicep build --file storage.bicep --outfile /dev/null
   ```

   ```
   storage.bicep(28,17) : Error BCP036: The property "accessTier" expected a value of type
   "'Cold' | 'Cool' | 'Hot' | 'Premium'" but the provided value is of type "'Warm'".
   ```

6. Repair it.

   ```bash
   sed -i "s/accessTier: 'Warm'/accessTier: 'Hot'/" storage.bicep
   az bicep build --file storage.bicep --outfile /dev/null && echo "BUILD OK"
   ```

### Verify your understanding — Block 5

- **Q5.1** — Is Bicep a separate deployment service from ARM? What does ARM receive when you run `az deployment group create --template-file main.bicep`?
- **Q5.2** — Name three concrete advantages of Bicep over hand-written ARM JSON, each supported by something you saw in this exercise.
- **Q5.3** — Your team has 200 legacy ARM JSON templates and wants to migrate. Which single command starts that migration, and what should you still review by hand afterwards?
- **Q5.4** — Both Bicep and Terraform are Infrastructure as Code. Which one is a first-party Microsoft tool tied to the ARM API, and what does the other require that Bicep does not?

---

## Exercise 6 — Deployment scopes: resource group, subscription, management group

**Goal:** deploy above the resource-group scope, which is how governance artifacts (policies, RBAC, subscriptions themselves) are delivered as code.

### Steps

1. Write a **subscription-scoped** template that creates a resource group — something a resource-group-scoped template structurally cannot do.

   ```bash
   cat > sub-scope.bicep <<'EOF'
   targetScope = 'subscription'

   param rgName string = 'rg-az900-lab-2'
   param location string = 'eastus'

   resource newRg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
     name: rgName
     location: location
     tags: {
       env: 'lab'
       course: 'az900'
       createdBy: 'subscription-scoped-deployment'
     }
   }

   output resourceGroupId string = newRg.id
   EOF
   ```

2. Preview and deploy at subscription scope — note the different CLI verb: `az deployment sub`, not `az deployment group`.

   ```bash
   az deployment sub what-if \
     --location "$LOC" \
     --name lab-rg-creation \
     --template-file sub-scope.bicep
   ```

   ```
     + Microsoft.Resources/resourceGroups/rg-az900-lab-2

   Resource changes: 1 to create.
   ```

   ```bash
   az deployment sub create \
     --location "$LOC" \
     --name lab-rg-creation \
     --template-file sub-scope.bicep \
     --query "properties.provisioningState" -o tsv
   ```

   ```
   Succeeded
   ```

3. Note that a subscription-scoped deployment requires `--location`: there is no resource group to inherit a region from, so ARM must be told where to persist the deployment metadata object.

4. List deployments at each scope and observe they are separate histories.

   ```bash
   az deployment sub list --query "[].{name:name, state:properties.provisioningState}" -o table
   az deployment group list --resource-group "$RG" --query "length(@)" -o tsv
   ```

5. Inspect the management group hierarchy — the scope above subscriptions, where `az deployment mg create` operates.

   ```bash
   az account management-group list --query "[].{name:name, displayName:displayName}" -o table
   ```

   ```
   Name                                  DisplayName
   ------------------------------------  ----------------
   8f2b1c4a-3e77-4a1c-9c5c-0d1e2f3a4b5c  Tenant Root Group
   ```

6. Clean up the second resource group.

   ```bash
   az group delete --name rg-az900-lab-2 --yes --no-wait
   ```

### Verify your understanding — Block 6

- **Q6.1** — List the four ARM deployment scopes from narrowest to widest, and give the CLI command for each.
- **Q6.2** — Why does `az deployment sub create` require `--location` while `az deployment group create` does not?
- **Q6.3** — You must guarantee that *every* subscription in the organization gets an identical tagging policy and an identical set of RBAC assignments. Which deployment scope do you target, and why is per-resource-group deployment the wrong answer?
- **Q6.4** — Can a resource-group-scoped template create the resource group it deploys into? Explain.

---

## Exercise 7 — Management guardrails: tags, locks, and move semantics

**Goal:** exercise the ARM-level management features that apply uniformly to every resource type because they live in the control plane, not in the individual services.

### Steps

1. Read the tags ARM applied and note that resource-group tags are **not** inherited by child resources.

   ```bash
   az group show --name "$RG" --query tags -o json
   az resource list --resource-group "$RG" --query "[].{name:name, tags:tags}" -o json
   ```

   ```json
   {
     "course": "az900",
     "env": "lab",
     "owner": "student"
   }
   [
     {
       "name": "stlab3kq7hv2nrxa4e",
       "tags": {
         "course": "az900",
         "env": "lab",
         "managedBy": "arm-template"
       }
     }
   ]
   ```

   The storage account has `managedBy` but not `owner` — because the template set its tags explicitly, not because it inherited anything.

2. Add a tag to an existing resource without touching the template (imperative drift — note what this will cost you later).

   ```bash
   export SA=$(az storage account list -g "$RG" --query "[0].name" -o tsv)
   az tag update \
     --resource-id "$(az storage account show -g $RG -n $SA --query id -o tsv)" \
     --operation Merge --tags costCenter=CC-4471 \
     --query "properties.tags" -o json
   ```

   ```json
   {
     "costCenter": "CC-4471",
     "course": "az900",
     "env": "lab",
     "managedBy": "arm-template"
   }
   ```

3. Prove the drift: what-if now reports a modification, because the template does not declare `costCenter`.

   ```bash
   az deployment group what-if --resource-group "$RG" --template-file storage.bicep
   ```

   ```
     ~ Microsoft.Storage/storageAccounts/stlab3kq7hv2nrxa4e [2023-05-01]
       - tags.costCenter: "CC-4471"

   Resource changes: 1 to modify.
   ```

4. Apply a **CanNotDelete** lock at the resource-group scope.

   ```bash
   az lock create \
     --name lock-az900-lab \
     --lock-type CanNotDelete \
     --resource-group "$RG" \
     --notes "AZ-900 lab guardrail" \
     --query "{name:name, level:level}" -o json
   ```

   ```json
   {
     "level": "CanNotDelete",
     "name": "lock-az900-lab"
   }
   ```

5. Attempt to delete the *child* storage account and observe that locks are **inherited downward**.

   ```bash
   az storage account delete -g "$RG" -n "$SA" --yes
   ```

   ```
   (ScopeLocked) The scope '/subscriptions/8f2b.../resourceGroups/rg-az900-lab/providers/
   Microsoft.Storage/storageAccounts/stlab3kq7hv2nrxa4e' cannot perform delete operation
   because following scope(s) are locked: '/subscriptions/8f2b.../resourceGroups/rg-az900-lab'.
   Please remove the lock and try again.
   Code: ScopeLocked
   ```

6. Confirm that the lock is a **control-plane** guardrail only: it blocks the ARM delete, but does not block data-plane writes.

   ```bash
   az storage container create --account-name "$SA" --name testdata --auth-mode login -o json
   ```

   ```json
   { "created": true }
   ```

7. Remove the lock.

   ```bash
   az lock delete --name lock-az900-lab --resource-group "$RG"
   az lock list --resource-group "$RG" -o table
   ```

### Verify your understanding — Block 7

- **Q7.1** — Do child resources inherit tags from their resource group? Do they inherit locks? Explain the asymmetry you observed in steps 1 and 5.
- **Q7.2** — Which two lock levels exist, and which one would break an application that periodically writes configuration back to its own resource?
- **Q7.3** — In step 6, the lock blocked a delete but allowed a container create. What architectural distinction does this demonstrate?
- **Q7.4** — After manually adding `costCenter` in the portal, a scheduled pipeline redeploys the template and the tag vanishes. Explain the mechanism and state the correct fix.
- **Q7.5** — A resource is protected by `CanNotDelete` and you genuinely need to delete it. What is the required order of operations, and which RBAC permission do you need?

---

## Exercise 8 — Azure Arc: extending the ARM control plane outside Azure

**Goal:** understand Arc's core value — projecting non-Azure machines and clusters into ARM as first-class resources so that RBAC, tags, Policy, Monitor and inventory apply to them identically.

> **Path A** requires any Linux or Windows machine that is **not** an Azure VM (a laptop VM, a Hyper-V/VirtualBox guest, an on-prem server, an EC2 instance) with outbound HTTPS. **Path B** is read-only and needs no external machine — do Path B if you cannot do Path A.

### Steps — Path A: onboard a server with Azure Arc

1. Register the required resource providers (recall Exercise 1, step 7, showed `NotRegistered`).

   ```bash
   for ns in Microsoft.HybridCompute Microsoft.GuestConfiguration Microsoft.HybridConnectivity Microsoft.Compute; do
     az provider register --namespace "$ns" --wait
     echo "$ns -> $(az provider show --namespace $ns --query registrationState -o tsv)"
   done
   ```

   ```
   Microsoft.HybridCompute -> Registered
   Microsoft.GuestConfiguration -> Registered
   Microsoft.HybridConnectivity -> Registered
   Microsoft.Compute -> Registered
   ```

2. On the **target machine** (not in Cloud Shell), install the Connected Machine agent.

   ```bash
   # Linux
   curl -fsSL https://aka.ms/install_linux_azcmagent -o install_linux_azcmagent.sh
   sudo bash install_linux_azcmagent.sh
   azcmagent version
   ```

   ```
   Azure Connected Machine Agent v1.46.02664.1737
   ```

3. Connect the machine to ARM. This performs an Entra ID device authentication and creates a `Microsoft.HybridCompute/machines` resource.

   ```bash
   sudo azcmagent connect \
     --resource-group "rg-az900-lab" \
     --tenant-id "<TENANT_ID>" \
     --location "eastus" \
     --subscription-id "<SUBSCRIPTION_ID>" \
     --cloud "AzureCloud" \
     --tags "env=lab,course=az900"
   ```

   ```
   INFO    Connecting machine to Azure...
   INFO    Testing connectivity to endpoints that are needed to connect to Azure...
   INFO    Creating resource in Azure...
   INFO    Connected machine to Azure
   ```

4. Verify from the machine, then from Azure — the same object, two views.

   ```bash
   sudo azcmagent show
   ```

   ```
   Resource Name                       : lab-server-01
   Resource Group Name                 : rg-az900-lab
   Resource Location                   : eastus
   Agent Status                        : Connected
   Agent Last Heartbeat (UTC)          : 2026-09-05T14:58:12Z
   Using Proxy                         : no
   Agent Version                       : 1.46.02664.1737
   ```

   ```bash
   az connectedmachine list -g "$RG" \
     --query "[].{name:name, os:properties.osName, status:properties.status, agent:properties.agentVersion}" -o table
   ```

   ```
   Name            Os      Status     Agent
   --------------  ------  ---------  -----------------
   lab-server-01   linux   Connected  1.46.02664.1737
   ```

5. Confirm the machine is now addressable by an ARM resource ID — the whole point of Arc.

   ```bash
   az connectedmachine show -g "$RG" -n lab-server-01 --query id -o tsv
   ```

   ```
   /subscriptions/8f2b1c4a-.../resourceGroups/rg-az900-lab/providers/Microsoft.HybridCompute/machines/lab-server-01
   ```

6. In the portal, open **Azure Arc → Machines → lab-server-01**. Confirm the blades available: **Tags**, **Access control (IAM)**, **Policies**, **Extensions**, **Inventory**, **Updates**. These are the same governance blades an Azure VM has.

7. Disconnect and uninstall when done.

   ```bash
   sudo azcmagent disconnect
   sudo bash install_linux_azcmagent.sh --uninstall   # or: sudo apt purge azcmagent
   ```

### Steps — Path B: inspect Arc surface area without an external machine

1. Register the providers as in Path A, step 1.

2. Enumerate the resource types Arc projects into ARM.

   ```bash
   az provider show --namespace Microsoft.HybridCompute --query "resourceTypes[].resourceType" -o tsv
   az provider show --namespace Microsoft.Kubernetes  --query "resourceTypes[].resourceType" -o tsv
   ```

   ```
   machines
   machines/extensions
   machines/runCommands
   licenses
   ...
   connectedClusters
   ```

3. Review what an Arc-enabled Kubernetes onboarding looks like (safe to read; only run against a cluster you own, e.g. k3s or kind):

   ```bash
   az extension add --name connectedk8s --only-show-errors
   # az connectedk8s connect --name arc-k3s-lab --resource-group "$RG" --location "$LOC"
   # kubectl get pods -n azure-arc
   ```

   ```
   NAME                                        READY   STATUS    RESTARTS   AGE
   cluster-metadata-operator-7f9c...           2/2     Running   0          3m
   clusterconnect-agent-6b4d...                3/3     Running   0          3m
   clusteridentityoperator-59f7...             2/2     Running   0          3m
   config-agent-84cd...                        2/2     Running   0          3m
   controller-manager-7d55...                  2/2     Running   0          3m
   extension-manager-6c9b...                   3/3     Running   0          3m
   kube-aad-proxy-58bb...                      2/2     Running   0          3m
   metrics-agent-7a41...                       2/2     Running   0          3m
   resource-sync-agent-5f8e...                 2/2     Running   0          3m
   ```

4. Note the networking model in the documentation: the Arc agents establish **outbound-only HTTPS (443)** connections to endpoints such as `login.microsoftonline.com`, `management.azure.com`, `*.his.arc.azure.com` and `*.guestconfiguration.azure.com`. No inbound port is opened.

### Verify your understanding — Block 8

- **Q8.1** — In one sentence, what problem does Azure Arc solve? Name four resource kinds it can project into ARM.
- **Q8.2** — After onboarding, `lab-server-01` has an ARM resource ID. Name three Azure governance capabilities this unlocks for a machine sitting in your own datacenter.
- **Q8.3** — Does Azure Arc move, migrate or replicate your on-premises workload into Azure? Explain precisely what does and does not cross the boundary.
- **Q8.4** — A security team objects: "we will not open inbound firewall ports for this." How do you respond, based on step 4?
- **Q8.5** — Why is installing the Connected Machine agent on a normal Azure VM unsupported?
- **Q8.6** — Onboarding a machine failed with `MissingSubscriptionRegistration` for `Microsoft.HybridCompute`. Connect this to Exercise 1.

---

## Exercise 9 — Diagnosing a failed deployment, then cleanup

**Goal:** practise the real troubleshooting path when a deployment fails — deployment operations, error codes, and the Activity Log correlation ID.

### Steps

1. Force a realistic failure: an invalid SKU for the resource type.

   ```bash
   az deployment group create \
     --resource-group "$RG" \
     --name lab-failure \
     --template-file storage.bicep \
     --parameters skuName=Premium_ZRS 2>&1 | head -20
   ```

   ```
   ERROR: {"code": "InvalidTemplate", "message": "Deployment template validation failed:
   'The provided value 'Premium_ZRS' for the template parameter 'skuName' at line '1' and
   column '210' is not valid. The parameter value is not part of the allowed value(s):
   'Standard_LRS,Standard_GRS,Standard_ZRS'.'", "additionalInfo": ...}
   ```

   The `@allowed` decorator caught it **before** any resource was touched.

2. Now force a failure that reaches the resource provider — a name collision.

   ```bash
   az deployment group create \
     --resource-group "$RG" --name lab-failure-2 \
     --template-uri "https://raw.githubusercontent.com/Azure/azure-quickstart-templates/master/quickstarts/microsoft.storage/storage-account-create/azuredeploy.json" \
     --parameters storageAccountType=Standard_LRS location="$LOC" 2>&1 | tail -5
   ```

3. Drill into the per-resource deployment operations — the layer where the *provider's* error lives.

   ```bash
   az deployment operation group list \
     --resource-group "$RG" --name lab-failure-2 \
     --query "[?properties.provisioningState=='Failed'].{op:properties.provisioningOperation, res:properties.targetResource.resourceName, status:properties.statusCode, msg:properties.statusMessage.error.code}" -o table
   ```

   ```
   Op      Res                  Status    Msg
   ------  -------------------  --------  -------------------------
   Create  store3kq7hv2nrxa4e   Conflict  StorageAccountAlreadyTaken
   ```

4. Trace the same event in the **Activity Log**, which records every ARM write operation for 90 days.

   ```bash
   az monitor activity-log list \
     --resource-group "$RG" \
     --offset 1h \
     --query "[?operationName.value=='Microsoft.Resources/deployments/write'].{time:eventTimestamp, status:status.value, caller:caller, corr:correlationId}" \
     -o table | head -5
   ```

   ```
   Time                              Status     Caller                  Corr
   --------------------------------  ---------  ----------------------  ------------------------------------
   2026-09-05T15:04:11.9021Z         Failed     student@contoso.com     3c2ab9f4-8e11-4f5a-9c02-7d6b1a2e3f44
   2026-09-05T14:22:41.1183Z         Succeeded  student@contoso.com     a71f0e2b-55c3-4d7e-b1a9-90cf3e4d5a61
   ```

5. **Cleanup.** Remove locks first, then the whole resource group. Deleting a resource group deletes every resource it contains.

   ```bash
   az lock list --resource-group "$RG" -o tsv                # must be empty
   az group delete --name "$RG" --yes --no-wait
   az group exists --name "$RG"
   ```

   ```
   false
   ```

6. If you mounted Cloud Shell storage and want it gone too, delete the `cloud-shell-storage-<region>` resource group as well.

   ```bash
   az group list --query "[?starts_with(name,'cloud-shell-storage')].name" -o tsv
   ```

### Verify your understanding — Block 9

- **Q9.1** — Two failures occurred in this exercise. Which one was caught by ARM's template validation and which by the resource provider? Why does the distinction matter operationally?
- **Q9.2** — `az deployment group show` reports `Failed` but the message is generic. Which command gives you the per-resource cause?
- **Q9.3** — What is the correlation ID for, and how long does the Activity Log retain events by default?
- **Q9.4** — Deleting the resource group failed with `ScopeLocked`. What must you do first, and why is this behaviour desirable?

---

<details>
<summary><strong>Answers</strong> — click to expand</summary>

### Block 1 — Azure Resource Manager

**A1.1** — **One** management plane: Azure Resource Manager. The portal, PowerShell and the SDK are all clients that authenticate against Microsoft Entra ID and issue REST calls to `https://management.azure.com`. This is why RBAC, Azure Policy, resource locks, tags and Activity Log auditing are uniform and unavoidable: they are enforced by ARM itself, before the request ever reaches the resource provider. There is no "side door" — you cannot bypass a Policy deny by switching from the portal to the CLI.

**A1.2** — Segments:
| Segment | Value | Meaning |
|---|---|---|
| `/subscriptions/{guid}` | `8f2b...` | Billing and management boundary |
| `/resourceGroups/{name}` | `rg-az900-lab` | Lifecycle container |
| `/providers/{namespace}` | `Microsoft.Storage` | **The resource provider** |
| `/{resourceType}` | `storageAccounts` | Type implemented by that provider |
| `/{name}` | `stlab001` | The instance |

**A1.3** — The resource provider implementing the requested type is not registered in that subscription. ARM refuses to route the call. Fix: `az provider register --namespace Microsoft.<Namespace> --wait`, then retry. Registration is per subscription and idempotent.

**A1.4** — Yes. ARM's control plane is globally distributed and not tied to the region hosting your resources; a regional outage affects the *data plane* and the resources themselves, but management requests continue to be served. (A regional outage can, of course, prevent operations from *completing* against resources physically in the affected region.)

---

### Block 2 — Azure Cloud Shell, Azure CLI, Azure PowerShell

**A2.1** — Cloud Shell's compute (the container) and the preinstalled tooling are free. What is billed is the **Azure Files share** backing the persistent `clouddrive` — standard Azure Files pricing on the 5 GB image, roughly $0.30/month. Choosing an ephemeral session avoids the storage account entirely, at the cost of persistence.

**A2.2** — It should have gone to `~/clouddrive/`, which is the mount point of the Azure Files share. Cloud Shell containers are **ephemeral** — the session recycles after ~20 minutes of inactivity and the container is destroyed; only the mounted share survives. (`$HOME` contents are restored from the image on the share for storage-mounted sessions, but the guaranteed-persistent location is `clouddrive`.)

**A2.3** — **Azure Cloud Shell**, an authenticated browser-based shell with the tooling preinstalled (`az`, `kubectl`, `helm`, `terraform`, `git`, `ansible`). Its two shell experiences are **Bash** and **PowerShell**, switchable within the same session.

**A2.4** — **Azure PowerShell** fits more naturally. Its cmdlets emit .NET objects, so `Get-AzResourceGroup | Where-Object {...} | Get-AzResource | Measure-Object` composes without parsing. The Azure CLI emits JSON *text*, so the same logic needs `--query` (JMESPath) plus `jq` or shell loops. Both are fully capable; the difference is the object pipeline versus text-and-query.

**A2.5** — No. The Azure CLI is a standalone cross-platform tool that runs on **Windows, macOS and Linux** (and in Docker). Cloud Shell is merely one hosted place where it is preinstalled. The `Az` PowerShell module is likewise cross-platform on PowerShell 7.

---

### Block 3 — Azure portal and Resource Graph

**A3.1** — The portal adds: a graphical unified console with guided creation wizards and inline validation; dashboards, favourites and visual metrics/charts; and discoverability — service catalogue, documentation links, cost estimates before you commit. What REST/CLI/PowerShell offers that the portal cannot practically do: **automation and repeatability at scale** — scripting, CI/CD pipelines, bulk operations across hundreds of resources, and version-controlled, reviewable change.

**A3.2** — The portal's resource list is scoped and paginated per subscription/resource group; answering across 47 subscriptions would mean 47 manual passes with no aggregation. **Azure Resource Graph** is the answer: a KQL-queryable, cross-subscription index of all resources, available in the portal (Resource Graph Explorer) and via `az graph query`.

**A3.3** — `az group export` (portal equivalent: **Export template** on the resource group or resource blade). Limitations: the exported JSON contains hard-coded values instead of parameters, may omit or mangle some resource types and properties, embeds no dependencies logic worth keeping, and includes runtime state that should not be redeployed. It is a *starting point* for refactoring into parameterised Bicep, not production IaC.

**A3.4** — They are **governable Azure resources** of type `Microsoft.Portal/dashboards`. Step 3 listed them with `az resource list`, which proves they live in a resource group, carry a resource ID, and are therefore subject to RBAC, tags, locks and Policy like anything else — that is what makes shared team dashboards possible.

---

### Block 4 — ARM templates, idempotency, deployment modes

**A4.1** — *Declarative* states the **desired end state** and lets the engine compute the actions; *imperative* states the **sequence of actions** to perform. Classification: (a) `storage.json` — declarative; (b) `az storage account create` — imperative; (c) the Bash loop calling `az vm create` — imperative (a script of commands, not a description of a target state).

**A4.2** — **Idempotency**: applying the same template to the same target repeatedly produces the same end state, with no duplicate resources and no error on the second run. For CI/CD this is essential — the pipeline can safely redeploy on every commit, reruns after a partial failure are harmless, and the template becomes the single source of truth rather than a one-shot script.

**A4.3** —
- **Incremental (default):** resources in the template are created or updated; resources present in the resource group but *absent from the template* are **left untouched**.
- **Complete:** resources in the resource group that are **not in the template are deleted**.

Classic incident: an engineer deploys a small, correct template with `--mode Complete` into a shared production resource group, and ARM deletes every resource that template does not declare — VMs, databases, network interfaces. This is why `what-if` before a Complete-mode deployment is non-negotiable, and why Complete mode belongs only in resource groups fully owned by one template.

**A4.4** — `validate` performs a static/preflight check: schema correctness, parameter types and allowed values, API versions, resource-name syntax. `what-if` does all of that **plus** compares the template against the *current live state* and returns a per-resource, per-property diff (`+ Create`, `- Delete`, `~ Modify`, `= NoChange`, `* Ignore`). `validate` answers "is this template well-formed?"; `what-if` answers "what will actually change if I run this?".

**A4.5** — (1) **Global uniqueness**: storage account names share a single DNS namespace across all of Azure, so a hard-coded name will collide (`StorageAccountAlreadyTaken`) and make the template non-reusable. (2) **Deterministic idempotency**: `uniqueString` is a hash, not a random value — the same resource group ID always yields the same name, so redeploying updates the existing account instead of creating a second one. A random function would break idempotency.

**A4.6** — In the **deployment history**, stored by ARM as `Microsoft.Resources/deployments` objects **at the scope of the deployment** — here, the resource group `rg-az900-lab`. It is queryable with `az deployment group list/show` and visible under the resource group's *Deployments* blade. ARM retains up to 800 deployments per resource group, automatically pruning the oldest.

---

### Block 5 — Bicep

**A5.1** — No. Bicep is a **domain-specific language that transpiles to ARM JSON**; there is a one-to-one mapping and no separate runtime, state file or service. When you deploy a `.bicep` file, the tooling compiles it in memory and ARM receives ordinary ARM JSON — you can see the injected `metadata._generator` block proving this in step 2.

**A5.2** — (1) **Conciseness** — 36 lines versus 62, no `$schema`/`contentVersion` boilerplate, no `[concat(...)]` string-function gymnastics (step 3). (2) **Type safety and IntelliSense at author time** — `BCP036` caught `accessTier: 'Warm'` at build time, before any API call (step 5); ARM JSON has no such checking. (3) **Automatic dependency inference and symbolic references** — `storageAccount.properties.primaryEndpoints.blob` replaces `reference(resourceId(...))`, and `dependsOn` is usually inferred. Also worth noting: modules for composition, and no state file to manage.

**A5.3** — `az bicep decompile --file <template>.json`. Afterwards, review by hand: generated parameter and variable names are machine-derived and unhelpful; `[concat(...)]` chains often survive as string interpolation that could be simplified; the decompiler emits warnings for constructs it cannot map cleanly; and API versions should be reviewed and modernised. Decompilation is a migration accelerator, not a finished refactor.

**A5.4** — **Bicep** is Microsoft's first-party, ARM-native IaC language — no state file, always-current resource-type coverage via ARM, supported by Microsoft Support. **Terraform** is third-party (HashiCorp), multi-cloud, and requires managing a **state file** (plus its backend, locking and drift reconciliation) and depends on a provider that lags the ARM API. Both are valid on Azure; Bicep is the answer when the exam asks for Azure's native IaC language.

---

### Block 6 — Deployment scopes

**A6.1** — Narrowest to widest:
| Scope | Command | Typical use |
|---|---|---|
| Resource group | `az deployment group create` | Workload resources |
| Subscription | `az deployment sub create` | Resource groups, subscription-level policy/RBAC |
| Management group | `az deployment mg create` | Policy and RBAC across many subscriptions |
| Tenant | `az deployment tenant create` | Management group hierarchy itself |

**A6.2** — The deployment itself is an ARM object (`Microsoft.Resources/deployments`) whose metadata must be persisted somewhere regional. A resource-group deployment inherits the resource group's location; a subscription-scoped deployment has no parent resource group to inherit from, so you must tell ARM where to store the deployment record. Note this is the location of the *deployment metadata*, not necessarily of the resources it creates.

**A6.3** — Target the **management group** scope (`az deployment mg create`), placing the subscriptions under a common management group. Deploying per resource group is wrong because it is not exhaustive (new resource groups and new subscriptions appear without the policy), it does not scale, and it makes the control unenforceable by design — governance must be applied at or above the boundary it is meant to cover, so that everything created below inherits it.

**A6.4** — No. A resource-group-scoped deployment is *executed against* an existing resource group, which must already exist for ARM to route the request. Creating a resource group is a `Microsoft.Resources/resourceGroups` operation at **subscription** scope — which is exactly what `targetScope = 'subscription'` in step 1 declared.

---

### Block 7 — Tags, locks and drift

**A7.1** — **Tags are not inherited**; each resource carries its own tag collection, and a resource group's tags say nothing about its children (step 1: the storage account has `managedBy` but not `owner`). Inheritance must be *simulated* with Azure Policy (`Inherit a tag from the resource group` — `modify` effect). **Locks are inherited**, downward from the scope where they are applied to every child (step 5: the resource-group lock blocked deleting the storage account). The asymmetry is deliberate: tags are metadata for organisation and billing, evaluated per resource; locks are authorisation guardrails, evaluated over the whole scope path so they cannot be circumvented by targeting a child.

**A7.2** — **CanNotDelete** (portal: *Delete*) — read and modify allowed, delete blocked. **ReadOnly** — only read operations allowed; every write and delete blocked. **ReadOnly** is the dangerous one: any application or service that writes back to its own resource (keys rotating, scaling operations, configuration updates, some managed-service internal operations) will break, often with confusing errors from the provider.

**A7.3** — The distinction between the **control plane** (ARM: create/read/update/delete the *resource*, at `management.azure.com`) and the **data plane** (the service's own endpoint: blobs, queues, database rows, at `<account>.blob.core.windows.net`). Locks, RBAC at ARM scope, Policy and the Activity Log govern the control plane. Protecting data-plane operations requires different controls — data-plane RBAC roles (e.g. *Storage Blob Data Contributor*), network rules, or immutability policies.

**A7.4** — The template is the declared desired state, and it does not declare `costCenter`. When ARM reconciles, it applies the template's `tags` object, which replaces the resource's tag collection and drops the undeclared tag. This is **configuration drift**, and it works exactly as designed: manual portal edits to IaC-managed resources are ephemeral. The correct fix is to add `costCenter` to the template (as a parameter), commit it, and redeploy — never to re-apply it by hand. If tags genuinely must be applied out-of-band, use Azure Policy `modify`/`append` and structure the template so it does not clobber them.

**A7.5** — (1) Delete the lock first — `az lock delete --name <lock> --resource-group <rg>`, or from the portal's *Locks* blade — then (2) delete the resource. Managing locks requires the `Microsoft.Authorization/locks/*` permissions, held by **Owner** and **User Access Administrator** but *not* by Contributor. That separation is the point: a Contributor can operate resources but cannot silently remove the guardrail protecting them.

---

### Block 8 — Azure Arc

**A8.1** — Azure Arc extends the Azure Resource Manager control plane to resources **outside Azure** — on-premises datacenters, other clouds, and the edge — so they can be managed with the same tools and governance as native Azure resources. Kinds it projects: **servers** (Windows/Linux, `Microsoft.HybridCompute/machines`), **Kubernetes clusters** (`Microsoft.Kubernetes/connectedClusters`), **SQL Server instances and Azure Arc data services** (SQL Managed Instance, PostgreSQL), and **VMware vSphere / Azure Stack HCI / SCVMM virtualization infrastructure**.

**A8.2** — Any three of: **Azure RBAC** on the machine's resource ID; **tags** for organisation and cost attribution; **Azure Policy** with machine configuration to audit or enforce in-guest settings; **Microsoft Defender for Cloud** threat protection and posture management; **Azure Monitor / Log Analytics** with the Azure Monitor Agent; **Azure Update Manager** for patch assessment and deployment; **Change Tracking and Inventory**; **Run command / extensions** for remote script execution; inclusion in **Azure Resource Graph** queries alongside Azure VMs.

**A8.3** — No. Arc is a **management-plane projection only**. What crosses the boundary is the machine's *metadata and management signal*: identity, OS and hardware inventory, heartbeats, policy compliance results, and extension instructions — over outbound HTTPS. What does **not** cross: the workload itself, its application data, and its compute. The server keeps running exactly where it is; Azure gains a control-plane handle on it. Arc is not a migration tool (that is Azure Migrate) and not a replication tool (that is Azure Site Recovery).

**A8.4** — No inbound ports are required. The Connected Machine agent (and the Arc Kubernetes agents) initiate **outbound-only HTTPS on TCP 443** to a documented, restrictable set of endpoints — `login.microsoftonline.com`, `management.azure.com`, `*.his.arc.azure.com`, `*.guestconfiguration.azure.com`. The firewall can allowlist exactly those FQDNs, an HTTP proxy or Azure Private Link scope can be interposed, and the machine remains unreachable from the internet.

**A8.5** — An Azure VM is *already* an ARM resource (`Microsoft.Compute/virtualMachines`) with its own agent and identity. Installing the Connected Machine agent creates a second, conflicting representation of the same machine, and the two agents compete over the Instance Metadata Service endpoint (`169.254.169.254`) used for managed-identity token acquisition — producing unpredictable identity and extension behaviour. Microsoft documents an evaluation-only workaround (blocking the IMDS route) that is explicitly unsupported for production.

**A8.6** — Identical root cause to Exercise 1, Q1.3: ARM cannot route requests for a resource type whose provider is not registered in the subscription. Arc's server resources live under the `Microsoft.HybridCompute` namespace, so that provider (plus `Microsoft.GuestConfiguration` and `Microsoft.HybridConnectivity` for policy and connectivity features) must be registered first: `az provider register --namespace Microsoft.HybridCompute --wait`. Arc resources are ordinary ARM resources and obey every ARM rule.

---

### Block 9 — Deployment troubleshooting

**A9.1** — The `Premium_ZRS` failure was caught by **ARM template validation** (`InvalidTemplate`), because the `@allowed` decorator constrains the parameter before ARM submits anything to a provider — zero resources touched, zero cost, instant feedback. The name collision (`StorageAccountAlreadyTaken`, HTTP 409 `Conflict`) came from the **resource provider**, `Microsoft.Storage`, and only surfaced mid-deployment. This matters operationally because provider-stage failures can leave a deployment **partially applied** — some resources created, others not — which is precisely why idempotent templates and `what-if` are the discipline: you re-run to converge rather than manually unwinding.

**A9.2** — `az deployment operation group list --resource-group <rg> --name <deployment>` (portal: **Deployments → <deployment> → Operation details**). The top-level deployment record aggregates status; the *operations* list holds one entry per resource with the provider's own `statusCode` and `statusMessage.error.code`.

**A9.3** — The **correlation ID** groups every Activity Log event emitted by a single logical operation — a deployment that touched twelve resources produces many entries sharing one correlation ID — so you can reconstruct the full chain of a failure and hand it to Microsoft Support as the single identifier for the incident. The Activity Log retains events for **90 days**; retaining longer requires exporting via a diagnostic setting to Log Analytics, a storage account, or Event Hubs.

**A9.4** — Delete the **CanNotDelete lock** on the resource group first (`az lock delete`), then re-run the group delete. This is desirable because deleting a resource group is an irreversible cascade that destroys every resource inside it; the lock forces a second, deliberate, differently-privileged action (lock management requires Owner or User Access Administrator, not Contributor) and thereby converts an accidental one-command catastrophe into a two-step decision.

</details>

---

## Official sources

- AZ-900 study guide — https://learn.microsoft.com/en-us/credentials/certifications/resources/study-guides/az-900
- What is Azure Resource Manager? — https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/overview
- ARM template deployment modes — https://learn.microsoft.com/en-us/azure/azure-resource-manager/templates/deployment-modes
- ARM template what-if — https://learn.microsoft.com/en-us/azure/azure-resource-manager/templates/deploy-what-if
- Deployment scopes (resource group, subscription, management group, tenant) — https://learn.microsoft.com/en-us/azure/azure-resource-manager/templates/deploy-to-subscription
- Azure resource providers and types — https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/resource-providers-and-types
- What is Bicep? — https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/overview
- Decompile ARM JSON to Bicep — https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/decompile
- Overview of Azure Cloud Shell — https://learn.microsoft.com/en-us/azure/cloud-shell/overview
- Persist files in Azure Cloud Shell — https://learn.microsoft.com/en-us/azure/cloud-shell/persisting-shell-storage
- What is the Azure CLI? — https://learn.microsoft.com/en-us/cli/azure/what-is-azure-cli
- Introducing Azure PowerShell — https://learn.microsoft.com/en-us/powershell/azure/what-is-azure-powershell
- Azure portal overview — https://learn.microsoft.com/en-us/azure/azure-portal/azure-portal-overview
- Azure Resource Graph overview — https://learn.microsoft.com/en-us/azure/governance/resource-graph/overview
- Use tags to organize Azure resources — https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/tag-resources
- Lock resources to prevent changes — https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/lock-resources
- Azure Arc overview — https://learn.microsoft.com/en-us/azure/azure-arc/overview
- Azure Arc-enabled servers: connected machine agent — https://learn.microsoft.com/en-us/azure/azure-arc/servers/agent-overview
- Azure Arc-enabled servers network requirements — https://learn.microsoft.com/en-us/azure/azure-arc/servers/network-requirements
- Azure Arc-enabled Kubernetes overview — https://learn.microsoft.com/en-us/azure/azure-arc/kubernetes/overview
- Troubleshoot common Azure deployment errors — https://learn.microsoft.com/en-us/azure/azure-resource-manager/troubleshooting/common-deployment-errors
- Azure Monitor activity log — https://learn.microsoft.com/en-us/azure/azure-monitor/essentials/activity-log