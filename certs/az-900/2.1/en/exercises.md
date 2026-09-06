# Topic 2.1 — Guided Exercises
## Describe the core architectural components of Azure
**Certification:** AZ-900 (exam version 2026-07-20) · **Exam weight of this topic:** 9.62%

---

### What you will build a mental model of

The AZ-900 skill statement covers two orthogonal hierarchies that beginners routinely merge into one, and that merge is the single most common source of wrong answers on this topic:

| Hierarchy | Levels | Owned by | Answers the question |
|---|---|---|---|
| **Physical** | geography → region (→ region pair) → availability zone → datacenter | Microsoft, fixed | *Where does my data physically live, and what fails together?* |
| **Logical (management)** | management group → subscription → resource group → resource | You, arbitrary | *Who pays, who governs, and what gets deleted together?* |

They intersect at exactly one point: a **resource** has a `location` (physical) *and* lives in a **resource group** (logical). Nothing else in one hierarchy constrains the other — a resource group in `eastus` can hold resources in `japaneast`.

Everything below is executed against the Azure control plane, **Azure Resource Manager (ARM)**, which is the single entry point for the portal, CLI, PowerShell, Terraform and the REST API alike.

**Cost and safety notice.** Exercises 1–4 and 7 are **read-only** and cost nothing. Exercise 5 creates two empty StorageV2 accounts (empty accounts accrue no meaningful charge — billing is per GB stored and per transaction) and ends with a cleanup step. Exercise 6 is read-only. Do not run any of this against a production subscription: use a personal, free-tier, or sandbox subscription.

**Reference for the whole topic:**
- Study guide: <https://learn.microsoft.com/en-us/credentials/certifications/resources/study-guides/az-900>
- Regions and geographies: <https://learn.microsoft.com/en-us/azure/reliability/regions-overview>
- Availability zones: <https://learn.microsoft.com/en-us/azure/reliability/availability-zones-overview>
- Azure Resource Manager: <https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/overview>

---

## Exercise 0 — Environment setup

You need Azure CLI ≥ 2.60 and a subscription in which you hold at least **Reader** (Exercises 1–4, 6, 7) and **Contributor** on a resource group you may create (Exercise 5).

1. Verify the CLI is installed and recent enough. `az version` prints the core version plus installed extensions:

   ```bash
   az version
   ```

   ```json
   {
     "azure-cli": "2.64.0",
     "azure-cli-core": "2.64.0",
     "azure-cli-telemetry": "1.1.0",
     "extensions": {}
   }
   ```

2. Authenticate. This opens a browser; in a headless shell use `az login --use-device-code`:

   ```bash
   az login
   ```

3. List the subscriptions your identity can see, and note that each one is bound to exactly one **Microsoft Entra ID tenant** (`tenantId`):

   ```bash
   az account list --query "[].{Name:name, SubscriptionId:id, Tenant:tenantId, State:state, Default:isDefault}" -o table
   ```

   ```text
   Name                 SubscriptionId                        Tenant                                State    Default
   -------------------  ------------------------------------  ------------------------------------  -------  -------
   Visual Studio Ent.   00000000-1111-2222-3333-444444444444  aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee  Enabled  True
   Lab-Sandbox          55555555-6666-7777-8888-999999999999  aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee  Enabled  False
   ```

4. Pin the subscription you will work in for the rest of the session, and export it as a shell variable — every ARM resource ID you will read later starts with it:

   ```bash
   az account set --subscription "Lab-Sandbox"
   export SUB_ID=$(az account show --query id -o tsv)
   echo "$SUB_ID"
   ```

   ```text
   55555555-6666-7777-8888-999999999999
   ```

5. Confirm which Azure **cloud instance** the CLI is talking to. This is the endpoint set, and it is the mechanism behind "sovereign regions":

   ```bash
   az cloud show --query "{Cloud:name, ARM:endpoints.resourceManager, Storage:suffixes.storageEndpoint}" -o yaml
   ```

   ```yaml
   ARM: https://management.azure.com/
   Cloud: AzureCloud
   Storage: core.windows.net
   ```

> **Check your understanding — Block 0**
>
> **Q0.1** A colleague says "I gave you Reader on the tenant, you should see all subscriptions." Why is `az account list` still able to return zero subscriptions for them?
> **Q0.2** `az account show` returns both an `id` and a `tenantId`. Which of the two is the *billing* boundary and which is the *identity* boundary?
> **Q0.3** In step 5 the storage suffix is `core.windows.net`. What would that suffix be if you had run `az cloud set --name AzureUSGovernment`, and what does the difference tell you about cross-cloud connectivity?

---

## Exercise 1 — Enumerate the physical footprint: geographies, regions, region pairs

A **region** is a set of datacenters deployed within a latency-defined perimeter and connected by a dedicated low-latency network. A **geography** is a discrete market — typically a country or a group of countries — that contains two or more regions and preserves data-residency and compliance boundaries. Regions are the unit you deploy into; geographies are the unit compliance auditors care about.

1. List every location visible to your subscription. Notice the row count is far larger than the number of "real" regions:

   ```bash
   az account list-locations --query "length(@)"
   ```

   ```text
   82
   ```

2. Split that list by `metadata.regionType`. `Physical` locations are actual regions; `Logical` locations are aggregations such as `global`, `asiapacific` or `europe` used by non-regional services (Entra ID, Azure DNS, Traffic Manager, Front Door):

   ```bash
   az account list-locations \
     --query "[].metadata.regionType" -o tsv | sort | uniq -c
   ```

   ```text
     8 Logical
    74 Physical
   ```

3. Render the physical regions with their geography, the human-readable datacenter city, and Microsoft's own recommendation tier (`regionCategory`). `Recommended` regions are the ones Microsoft expects most customers to use and where new services and availability zones land first; `Other` regions are typically capacity- or compliance-specific:

   ```bash
   az account list-locations \
     --query "[?metadata.regionType=='Physical'].{Region:name, Geography:metadata.geography, City:metadata.physicalLocation, Tier:metadata.regionCategory}" \
     -o table | head -15
   ```

   ```text
   Region              Geography       City             Tier
   ------------------  --------------  ---------------  -----------
   eastus              United States   Virginia         Recommended
   eastus2             United States   Virginia         Recommended
   southcentralus      United States   Texas            Recommended
   westus2             United States   Washington       Recommended
   westus3             United States   Phoenix          Recommended
   northeurope         Europe          Ireland          Recommended
   westeurope          Europe          Netherlands      Recommended
   swedencentral       Europe          Gävle            Recommended
   uksouth             United Kingdom  London           Recommended
   brazilsouth         Brazil          Sao Paulo State  Recommended
   japaneast           Japan           Tokyo, Saitama   Recommended
   australiaeast       Australia       New South Wales  Recommended
   centralus           United States   Iowa             Recommended
   westus              United States   California       Other
   ```

4. Extract the **region pairs**. A paired region is a second region in the *same geography*, chosen by Microsoft (you cannot pick it), used for platform-managed replication (GRS/GZRS storage), staged platform updates — Microsoft never patches both halves of a pair simultaneously — and prioritized recovery capacity during a broad outage:

   ```bash
   az account list-locations \
     --query "[?metadata.regionType=='Physical' && metadata.pairedRegion!=null].{Region:name, Geography:metadata.geography, Pair:metadata.pairedRegion[0].name}" \
     -o table | head -12
   ```

   ```text
   Region           Geography       Pair
   ---------------  --------------  ---------------
   eastus           United States   westus
   eastus2          United States   centralus
   southcentralus   United States   northcentralus
   westus2          United States   westcentralus
   northeurope      Europe          westeurope
   westeurope       Europe          northeurope
   uksouth          United Kingdom  ukwest
   japaneast        Japan           japanwest
   brazilsouth      Brazil          southcentralus
   australiaeast    Australia       australiasoutheast
   ```

5. Find the exception to the "pair stays inside the geography" rule, and then find the regions that have **no pair at all**:

   ```bash
   # the documented one-way exception
   az account list-locations \
     --query "[?name=='brazilsouth'].{Region:name, Geo:metadata.geography, Pair:metadata.pairedRegion[0].name}" -o table

   # regions with no pair — increasingly common for newer, single-region geographies
   az account list-locations \
     --query "[?metadata.regionType=='Physical' && metadata.pairedRegion==null].{Region:name, Geo:metadata.geography, Tier:metadata.regionCategory}" \
     -o table
   ```

   ```text
   Region       Geo     Pair
   -----------  ------  --------------
   brazilsouth  Brazil  southcentralus

   Region           Geo      Tier
   ---------------  -------  -----------
   israelcentral    Israel   Recommended
   italynorth       Italy    Recommended
   polandcentral    Poland   Recommended
   qatarcentral     Qatar    Recommended
   ```

   `brazilsouth` pairs *out* of its geography to `southcentralus`, and the relationship is **not symmetric**: `southcentralus` pairs back to `northcentralus`, not to Brazil. The unpaired regions in the second table are newer single-region geographies: Microsoft's guidance there is availability zones for in-region resilience plus an explicit, customer-chosen secondary region for DR — there is no platform-managed pair to fall back on.

6. Confirm what a *logical* location looks like, and why a `global` resource has no region to fail over from:

   ```bash
   az account list-locations \
     --query "[?metadata.regionType=='Logical'].{Name:name, Type:metadata.regionType, Geo:metadata.geographyGroup}" -o table
   ```

   ```text
   Name           Type     Geo
   -------------  -------  ------
   global         Logical
   asiapacific    Logical  Asia Pacific
   europe         Logical  Europe
   unitedstates   Logical  US
   ```

> **Check your understanding — Block 1**
>
> **Q1.1** You must guarantee that customer records never leave the European Union. Is it sufficient to say "we deploy only to `westeurope`"? What does the region-pair mechanism do to that guarantee if you enable GRS storage?
> **Q1.2** Why is `brazilsouth → southcentralus` a data-residency problem that `northeurope → westeurope` is not?
> **Q1.3** Your architecture assumes "Azure always gives me a paired region for DR." Name two regions from step 5 where that assumption is false, and state what you must do instead.
> **Q1.4** A region is `Other` rather than `Recommended`. Give two concrete operational consequences of choosing it.
> **Q1.5** Entra ID reports its location as `global`. Explain, in terms of the physical hierarchy, why "which region is my Entra tenant in?" is a malformed question.

---

## Exercise 2 — Sovereign clouds: the hardest isolation boundary in Azure

**Sovereign regions** are not regions inside the public cloud with extra rules. They are *separate physical and logical instances of Azure*, with their own ARM endpoints, their own Entra ID, their own portal URL, and their own service catalog. Nothing federates across them by default.

1. List the cloud instances the CLI knows about:

   ```bash
   az cloud list --query "[].{Cloud:name, ARM:endpoints.resourceManager, Portal:endpoints.portal, Active:isActive}" -o table
   ```

   ```text
   Cloud              ARM                                   Portal                             Active
   -----------------  ------------------------------------  ---------------------------------  ------
   AzureCloud         https://management.azure.com/         https://portal.azure.com           True
   AzureChinaCloud    https://management.chinacloudapi.cn/  https://portal.azure.cn            False
   AzureUSGovernment  https://management.usgovcloudapi.net/ https://portal.azure.us            False
   ```

2. Inspect the full suffix set of a sovereign cloud without switching to it:

   ```bash
   az cloud show --name AzureUSGovernment \
     --query "{ARM:endpoints.resourceManager, AAD:endpoints.activeDirectory, Storage:suffixes.storageEndpoint, SQL:suffixes.sqlServerHostname}" -o yaml
   ```

   ```yaml
   AAD: https://login.microsoftonline.us
   ARM: https://management.usgovcloudapi.net/
   SQL: .database.usgovcloudapi.net
   Storage: core.usgovcloudapi.net
   ```

3. Prove the isolation empirically. With `AzureCloud` active, ask for a US Government region by name — ARM has never heard of it:

   ```bash
   az account list-locations --query "[?name=='usgovvirginia']" -o json
   ```

   ```json
   []
   ```

4. Note the operating models, which is what the exam actually asks about:
   - **Azure Government** (`usgovvirginia`, `usgovarizona`, …) — operated by Microsoft, screened US personnel, physically isolated, aligned to FedRAMP High / DoD IL5.
   - **Azure operated by 21Vianet** (China: `chinanorth3`, `chinaeast2`, …) — operated by **21Vianet, not Microsoft**, to satisfy Chinese law. Microsoft licenses the technology; it does not run the datacenters.

> **Check your understanding — Block 2**
>
> **Q2.1** Can you create a resource group in `usgovvirginia` from a subscription in the public cloud? Justify with what you observed in step 3.
> **Q2.2** Who physically operates Azure in China, and why does that answer matter for a support-escalation runbook?
> **Q2.3** Your single Entra ID tenant holds all corporate identities. A team asks to "just add the Government subscription to our tenant." What is wrong with the request?
> **Q2.4** A hardcoded blob URL in your app is `https://stprod.blob.core.windows.net/data`. What breaks if that app is redeployed into Azure Government, and which endpoint value from step 2 is the fix?

---

## Exercise 3 — Availability zones: logical numbers, physical datacenters

An **availability zone** is one or more datacenters within a region with **independent power, cooling and networking**, connected to the other zones by a high-throughput, low-latency (typically <2 ms round-trip) private network. An AZ-enabled region has a **minimum of three** zones. Zones protect against *datacenter-level* failure; they do **not** protect against a region-wide event.

1. Determine which regions have zones. Recent CLI versions surface the mapping directly:

   ```bash
   az account list-locations \
     --query "[?metadata.regionType=='Physical' && availabilityZoneMappings!=null].{Region:name, Zones:length(availabilityZoneMappings)}" \
     -o table | head -10
   ```

   ```text
   Region          Zones
   --------------  -------
   eastus          3
   eastus2         3
   westus2         3
   westus3         3
   northeurope     3
   westeurope      3
   swedencentral   3
   uksouth         3
   japaneast       3
   australiaeast   3
   ```

2. If your CLI version does not expose that field, query ARM directly. This is the authoritative source and is worth knowing because it reveals something the table above hides:

   ```bash
   az rest --method get \
     --url "https://management.azure.com/subscriptions/$SUB_ID/locations?api-version=2022-12-01" \
     --query "value[?name=='eastus'].availabilityZoneMappings[]" -o json
   ```

   ```json
   [
     { "logicalZone": "1", "physicalZone": "eastus-az3" },
     { "logicalZone": "2", "physicalZone": "eastus-az1" },
     { "logicalZone": "3", "physicalZone": "eastus-az2" }
   ]
   ```

   **This is the single most under-taught fact about availability zones.** The numbers `1`, `2`, `3` you type into a deployment are **per-subscription logical labels**. Microsoft shuffles the logical→physical mapping per subscription to spread load evenly across the region. Zone `1` in *your* subscription is very likely a different physical datacenter than zone `1` in your colleague's subscription.

3. Run the same query against a second subscription and compare, if you have one:

   ```bash
   for s in $(az account list --query "[].id" -o tsv); do
     echo "--- $s"
     az rest --method get \
       --url "https://management.azure.com/subscriptions/$s/locations?api-version=2022-12-01" \
       --query "value[?name=='eastus'].availabilityZoneMappings[].{L:logicalZone,P:physicalZone}" -o tsv
   done
   ```

   ```text
   --- 00000000-1111-2222-3333-444444444444
   1	eastus-az1
   2	eastus-az2
   3	eastus-az3
   --- 55555555-6666-7777-8888-999999999999
   1	eastus-az3
   2	eastus-az1
   3	eastus-az2
   ```

4. Check whether a specific VM SKU is actually offered in each zone of a region. Zone support is per-region **and** per-SKU — a region having zones does not mean every SKU is in every zone:

   ```bash
   az vm list-skus --location eastus --size Standard_D4s_v5 --resource-type virtualMachines \
     --query "[].{SKU:name, Zones:locationInfo[0].zones}" -o json
   ```

   ```json
   [
     {
       "SKU": "Standard_D4s_v5",
       "Zones": ["1", "2", "3"]
     }
   ]
   ```

5. Classify the three deployment patterns. This taxonomy is the exam's target:

   | Pattern | You specify | Failure of one zone | Example |
   |---|---|---|---|
   | **Zonal** | An explicit zone (`--zone 2`) | That instance is gone; you must have built redundancy yourself across zones | VM, managed disk, zonal public IP |
   | **Zone-redundant** | Nothing — the platform spreads it | Service keeps running, transparently | ZRS storage, zone-redundant SQL DB, Standard Load Balancer |
   | **Regional (non-zonal)** | Nothing, no zone guarantee | Undefined — may or may not survive | LRS storage, Basic-tier services |

6. Verify the classification on storage replication SKUs available in an AZ region versus a non-AZ region:

   ```bash
   az storage account list-skus --query "[].name" -o tsv 2>/dev/null || \
   echo "Standard_LRS Standard_ZRS Standard_GRS Standard_GZRS Standard_RAGRS Premium_LRS Premium_ZRS"
   ```

   ```text
   Standard_LRS Standard_ZRS Standard_GRS Standard_GZRS Standard_RAGRS Premium_LRS Premium_ZRS
   ```

   Mapping to the hierarchy: `LRS` = three copies in **one datacenter** (zone). `ZRS` = three copies across **three zones**, same region. `GRS` = LRS locally + asynchronous copy in the **paired region**. `GZRS` = ZRS locally + asynchronous copy in the paired region. Each step up buys you one more level of the physical hierarchy.

> **Check your understanding — Block 3**
>
> **Q3.1** You and a teammate both deploy a VM into "zone 1" of `eastus`, from different subscriptions, and call it a highly available pair. Using the output of step 3, explain what is wrong — and what is accidentally *right* — about that setup.
> **Q3.2** A single VM is pinned to `--zone 1`. Is it zone-redundant? What is the minimum change that makes the *workload* zone-redundant?
> **Q3.3** Order `Standard_LRS`, `Standard_ZRS` and `Standard_GRS` by the largest failure they survive, and name the failure domain each one stops at.
> **Q3.4** `az account list-locations` shows zones for a region, but `az vm list-skus` returns `"Zones": []` for the SKU you want. What is the correct conclusion, and what are your two options?
> **Q3.5** A flood takes out the entire `westeurope` region. Which of the following survive: a ZRS storage account in `westeurope`; a GRS storage account in `westeurope`; a VM zonal set spread across zones 1, 2, 3 in `westeurope`?

---

## Exercise 4 — The management hierarchy: management group → subscription → resource group → resource

This is the **logical** hierarchy. Its purpose is not resilience — it is governance, billing and access control. Policy and RBAC assignments **inherit downward** and only downward.

1. Read the top of the tree. Every Entra ID tenant has exactly one root management group, whose ID equals the tenant ID and whose display name defaults to *Tenant Root Group*:

   ```bash
   az account management-group list --query "[].{Name:displayName, Id:name, Type:type}" -o table
   ```

   ```text
   Name              Id                                    Type
   ----------------  ------------------------------------  --------------------------------------------
   Tenant Root Group  aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee  Microsoft.Management/managementGroups
   ```

   If this returns an authorization error, you have not been granted access at the root scope. That is normal and by design — root access requires an explicit elevation by a Global Administrator. Treat steps 2–4 as read-only in that case and move to step 5.

2. Build a small governance tree. Management groups are free and carry no region:

   ```bash
   TENANT_ID=$(az account show --query tenantId -o tsv)

   az account management-group create --name "mg-contoso"  --display-name "Contoso"
   az account management-group create --name "mg-prod"     --display-name "Production"  --parent "mg-contoso"
   az account management-group create --name "mg-nonprod"  --display-name "Non-Production" --parent "mg-contoso"
   ```

3. Render the tree, expanded and recursed:

   ```bash
   az account management-group show --name "mg-contoso" --expand --recurse \
     --query "{Name:displayName, Children:children[].{Name:displayName, Type:type, Id:name}}" -o yaml
   ```

   ```yaml
   Children:
   - Id: mg-nonprod
     Name: Non-Production
     Type: Microsoft.Management/managementGroups
   - Id: mg-prod
     Name: Production
     Type: Microsoft.Management/managementGroups
   Name: Contoso
   ```

4. Attach a subscription to a management group. A subscription has **exactly one** parent management group at any time; re-parenting is a move, not an addition:

   ```bash
   az account management-group subscription add --name "mg-nonprod" --subscription "$SUB_ID"

   az account management-group show --name "mg-nonprod" --expand \
     --query "children[?type=='/subscriptions'].{Name:displayName, Id:name}" -o table
   ```

   ```text
   Name         Id
   -----------  ------------------------------------
   Lab-Sandbox  55555555-6666-7777-8888-999999999999
   ```

5. Now walk down to the bottom of the tree and read the actual **ARM resource IDs** at each scope. Memorize these four shapes — the exam tests scope reasoning, and every Azure tool speaks this string:

   ```bash
   echo "MG   : /providers/Microsoft.Management/managementGroups/mg-prod"
   echo "SUB  : /subscriptions/$SUB_ID"
   echo "RG   : /subscriptions/$SUB_ID/resourceGroups/rg-az900-lab"
   echo "RES  : /subscriptions/$SUB_ID/resourceGroups/rg-az900-lab/providers/Microsoft.Storage/storageAccounts/stexample001"
   ```

   Each additional segment is one level down the logical hierarchy. Nothing in these strings encodes a region — the physical hierarchy appears only in a resource's `location` **property**, never in its ID.

6. Observe that a subscription is also a **scale boundary**, not merely a billing one. Quotas are enforced per subscription per region:

   ```bash
   az vm list-usage --location eastus \
     --query "[?contains(localName,'Total Regional vCPUs') || contains(localName,'Standard DSv5 Family')].{Quota:localName, Used:currentValue, Limit:limit}" \
     -o table
   ```

   ```text
   Quota                             Used    Limit
   --------------------------------  ------  -------
   Total Regional vCPUs              8       50
   Standard DSv5 Family vCPUs        4       20
   ```

7. Clean up the management groups if you created them (leaf-first; a management group with children cannot be deleted):

   ```bash
   az account management-group subscription remove --name "mg-nonprod" --subscription "$SUB_ID"
   az account management-group delete --name "mg-nonprod"
   az account management-group delete --name "mg-prod"
   az account management-group delete --name "mg-contoso"
   ```

> **Check your understanding — Block 4**
>
> **Q4.1** You assign an Azure Policy that denies resource creation outside `europe` at `mg-contoso`. Which of the following are affected: `mg-prod`, `Lab-Sandbox`, a resource group inside `Lab-Sandbox`, a *different* subscription parented directly under the root MG?
> **Q4.2** Can one subscription belong to both `mg-prod` and `mg-nonprod` so that two teams' policies both apply? What is the actual mechanism to achieve overlapping governance?
> **Q4.3** From the four ID shapes in step 5, how do you tell a subscription-scope ID from a resource-group-scope ID at a glance?
> **Q4.4** A developer hits a vCPU quota wall in `eastus`. They propose "create another resource group." Why does that not help, and what are the two things that actually would?
> **Q4.5** Why did the cleanup in step 7 have to remove the subscription and delete `mg-nonprod` before `mg-contoso`?

---

## Exercise 5 — Resource groups as the lifecycle and blast-radius boundary

A **resource group** is a logical container. Its defining properties: a resource belongs to exactly one RG; resource groups cannot be nested; deleting an RG deletes everything inside it; and the RG's own `location` stores only the group's **metadata**, not its members' data.

1. Create a resource group and tag it. Creation is free:

   ```bash
   export RG=rg-az900-lab

   az group create --name "$RG" --location eastus \
     --tags owner=student topic=az900-2.1 lifecycle=ephemeral \
     --query "{Name:name, Location:location, State:properties.provisioningState, Id:id}" -o yaml
   ```

   ```yaml
   Id: /subscriptions/55555555-6666-7777-8888-999999999999/resourceGroups/rg-az900-lab
   Location: eastus
   Name: rg-az900-lab
   State: Succeeded
   ```

2. Write a deployment template that deliberately places two resources **in different regions inside one resource group**, using two different replication strategies. Save as `main.bicep`:

   ```bicep
   targetScope = 'resourceGroup'

   @description('Region for the zone-redundant account. Must be an availability-zone-enabled region.')
   param primaryLocation string = 'eastus'

   @description('Region for the second account, deliberately different from the resource group location.')
   param secondaryLocation string = 'westus3'

   @description('Replication SKU for the primary account.')
   @allowed([
     'Standard_LRS'
     'Standard_ZRS'
     'Standard_GRS'
     'Standard_GZRS'
   ])
   param primarySku string = 'Standard_ZRS'

   var suffix = uniqueString(resourceGroup().id)

   resource zoneRedundant 'Microsoft.Storage/storageAccounts@2023-05-01' = {
     name: 'stzr${suffix}'
     location: primaryLocation
     sku: {
       name: primarySku
     }
     kind: 'StorageV2'
     properties: {
       accessTier: 'Hot'
       minimumTlsVersion: 'TLS1_2'
       supportsHttpsTrafficOnly: true
       allowBlobPublicAccess: false
       publicNetworkAccess: 'Disabled'
     }
     tags: {
       topic: 'az900-2.1'
       pattern: 'zone-redundant'
     }
   }

   resource remoteRegion 'Microsoft.Storage/storageAccounts@2023-05-01' = {
     name: 'stfar${suffix}'
     location: secondaryLocation
     sku: {
       name: 'Standard_LRS'
     }
     kind: 'StorageV2'
     properties: {
       accessTier: 'Hot'
       minimumTlsVersion: 'TLS1_2'
       supportsHttpsTrafficOnly: true
       allowBlobPublicAccess: false
       publicNetworkAccess: 'Disabled'
     }
     tags: {
       topic: 'az900-2.1'
       pattern: 'single-zone-remote-region'
     }
   }

   output resourceGroupLocation string = resourceGroup().location
   output zoneRedundantId string = zoneRedundant.id
   output zoneRedundantLocation string = zoneRedundant.location
   output remoteRegionId string = remoteRegion.id
   output remoteRegionLocation string = remoteRegion.location
   ```

   If you prefer not to install Bicep, the equivalent ARM JSON template is fully interchangeable — save as `main.json` and pass it to the same command:

   ```json
   {
     "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#",
     "contentVersion": "1.0.0.0",
     "parameters": {
       "primaryLocation":   { "type": "string", "defaultValue": "eastus" },
       "secondaryLocation": { "type": "string", "defaultValue": "westus3" },
       "primarySku": {
         "type": "string",
         "defaultValue": "Standard_ZRS",
         "allowedValues": ["Standard_LRS", "Standard_ZRS", "Standard_GRS", "Standard_GZRS"]
       }
     },
     "variables": {
       "suffix": "[uniqueString(resourceGroup().id)]"
     },
     "resources": [
       {
         "type": "Microsoft.Storage/storageAccounts",
         "apiVersion": "2023-05-01",
         "name": "[concat('stzr', variables('suffix'))]",
         "location": "[parameters('primaryLocation')]",
         "sku": { "name": "[parameters('primarySku')]" },
         "kind": "StorageV2",
         "properties": {
           "accessTier": "Hot",
           "minimumTlsVersion": "TLS1_2",
           "supportsHttpsTrafficOnly": true,
           "allowBlobPublicAccess": false,
           "publicNetworkAccess": "Disabled"
         },
         "tags": { "topic": "az900-2.1", "pattern": "zone-redundant" }
       },
       {
         "type": "Microsoft.Storage/storageAccounts",
         "apiVersion": "2023-05-01",
         "name": "[concat('stfar', variables('suffix'))]",
         "location": "[parameters('secondaryLocation')]",
         "sku": { "name": "Standard_LRS" },
         "kind": "StorageV2",
         "properties": {
           "accessTier": "Hot",
           "minimumTlsVersion": "TLS1_2",
           "supportsHttpsTrafficOnly": true,
           "allowBlobPublicAccess": false,
           "publicNetworkAccess": "Disabled"
         },
         "tags": { "topic": "az900-2.1", "pattern": "single-zone-remote-region" }
       }
     ],
     "outputs": {
       "resourceGroupLocation": { "type": "string", "value": "[resourceGroup().location]" },
       "zoneRedundantId":       { "type": "string", "value": "[resourceId('Microsoft.Storage/storageAccounts', concat('stzr', variables('suffix')))]" },
       "remoteRegionId":        { "type": "string", "value": "[resourceId('Microsoft.Storage/storageAccounts', concat('stfar', variables('suffix')))]" }
     }
   }
   ```

3. Preview the deployment before committing. `what-if` calls ARM's prediction engine and changes nothing:

   ```bash
   az deployment group what-if --resource-group "$RG" --template-file main.bicep
   ```

   ```text
   Resource and property changes are indicated with these symbols:
     + Create

   The deployment will update the following scope:

   Scope: /subscriptions/5555.../resourceGroups/rg-az900-lab

     + Microsoft.Storage/storageAccounts/stzrhq4k2mnp7xw3d [2023-05-01]
         kind:              "StorageV2"
         location:          "eastus"
         sku.name:          "Standard_ZRS"

     + Microsoft.Storage/storageAccounts/stfarhq4k2mnp7xw3d [2023-05-01]
         kind:              "StorageV2"
         location:          "westus3"
         sku.name:          "Standard_LRS"

   Resource changes: 2 to create.
   ```

4. Deploy, then read the outputs:

   ```bash
   az deployment group create --resource-group "$RG" --name dep-2-1 --template-file main.bicep \
     --query "properties.outputs.{RGLocation:resourceGroupLocation.value, ZR:zoneRedundantLocation.value, Remote:remoteRegionLocation.value}" -o yaml
   ```

   ```yaml
   RGLocation: eastus
   Remote: westus3
   ZR: eastus
   ```

5. Confirm the decoupling directly — one resource group, two regions:

   ```bash
   az resource list --resource-group "$RG" \
     --query "[].{Name:name, Type:type, Location:location, SKU:sku.name}" -o table
   ```

   ```text
   Name                 Type                                 Location    SKU
   -------------------  -----------------------------------  ----------  -------------
   stzrhq4k2mnp7xw3d    Microsoft.Storage/storageAccounts     eastus      Standard_ZRS
   stfarhq4k2mnp7xw3d   Microsoft.Storage/storageAccounts     westus3     Standard_LRS
   ```

6. Demonstrate the resource group as a **protection** boundary. Apply a `CanNotDelete` lock at RG scope; locks inherit to every child:

   ```bash
   az lock create --name "no-delete-lab" --resource-group "$RG" --lock-type CanNotDelete
   az lock list --resource-group "$RG" --query "[].{Name:name, Level:level, Scope:id}" -o table
   ```

   ```text
   Name           Level         Scope
   -------------  ------------  ------------------------------------------------------------
   no-delete-lab  CanNotDelete  /subscriptions/5555.../resourceGroups/rg-az900-lab/providers/Microsoft.Authorization/locks/no-delete-lab
   ```

7. Attempt to delete a *child* resource and read the exact error. Note it is the **RG-scope** lock that stops a **resource-scope** operation:

   ```bash
   ZR_NAME=$(az storage account list -g "$RG" --query "[?starts_with(name,'stzr')].name | [0]" -o tsv)
   az storage account delete --name "$ZR_NAME" --resource-group "$RG" --yes
   ```

   ```text
   (ScopeLocked) The scope '/subscriptions/5555.../resourceGroups/rg-az900-lab/providers/Microsoft.Storage/storageAccounts/stzrhq4k2mnp7xw3d'
   cannot perform delete operation because following scope(s) are locked: '/subscriptions/5555.../resourceGroups/rg-az900-lab'.
   Please remove the lock and try again.
   Code: ScopeLocked
   ```

8. Move a resource to a second resource group. This proves the RG is a *label*, not a physical container — the storage account's data never moves and its region does not change:

   ```bash
   az group create --name "rg-az900-lab-b" --location westeurope -o none
   az lock delete --name "no-delete-lab" --resource-group "$RG"

   REMOTE_ID=$(az storage account list -g "$RG" --query "[?starts_with(name,'stfar')].id | [0]" -o tsv)
   az resource move --destination-group "rg-az900-lab-b" --ids "$REMOTE_ID"

   az resource list --resource-group "rg-az900-lab-b" \
     --query "[].{Name:name, Location:location, RG:resourceGroup}" -o table
   ```

   ```text
   Name                 Location    RG
   -------------------  ----------  --------------
   stfarhq4k2mnp7xw3d   westus3     rg-az900-lab-b
   ```

   The resource is now in a resource group whose metadata lives in `westeurope`, while the storage account itself is still in `westus3`. Its ARM ID changed; its data did not move a single byte.

9. **Cleanup.** Deleting the resource group deletes everything in it — this is the blast radius you designed:

   ```bash
   az group delete --name "$RG" --yes --no-wait
   az group delete --name "rg-az900-lab-b" --yes --no-wait
   az group list --query "[?starts_with(name,'rg-az900-lab')].{Name:name, State:properties.provisioningState}" -o table
   ```

   ```text
   Name             State
   ---------------  ----------
   rg-az900-lab     Deleting
   rg-az900-lab-b   Deleting
   ```

> **Check your understanding — Block 5**
>
> **Q5.1** In step 4 the resource group is in `eastus` and one storage account is in `westus3`. If the entire `eastus` region goes offline, is the `westus3` storage account's *data* available? Is it *manageable* through ARM?
> **Q5.2** The lock in step 6 was placed on the resource group, but the error in step 7 was raised for a storage account operation. What property of the logical hierarchy explains this?
> **Q5.3** After the move in step 8, two things about the resource changed and one important thing did not. Name all three.
> **Q5.4** A team asks for "a resource group per environment, nested under a resource group per business unit." What is technically wrong with the request, and which construct actually provides the nesting they want?
> **Q5.5** Why does `az group delete` require no confirmation of the *contents*, and what design rule does that impose on how you group resources in the first place?

---

## Exercise 6 — Diagnosing placement failures across both hierarchies

Most real "Azure is broken" tickets on this topic are one of four control-plane errors, each traceable to a specific level of one of the two hierarchies.

1. **Resource provider not registered** — the subscription has never been told about a service namespace. Symptom: `MissingSubscriptionRegistration`:

   ```bash
   az provider list --query "[?registrationState=='NotRegistered'].namespace" -o tsv | head -5
   az provider show --namespace Microsoft.ContainerService --query "{NS:namespace, State:registrationState}" -o yaml
   ```

   ```yaml
   NS: Microsoft.ContainerService
   State: NotRegistered
   ```

   ```bash
   az provider register --namespace Microsoft.ContainerService --wait
   az provider show --namespace Microsoft.ContainerService --query registrationState -o tsv
   ```

   ```text
   Registered
   ```

   Registration is **per subscription**, not per resource group and not per region.

2. **Resource type not offered in the region** — symptom: `LocationNotAvailableForResourceType`. Query the provider's own region list before deploying:

   ```bash
   az provider show --namespace Microsoft.Storage \
     --query "resourceTypes[?resourceType=='storageAccounts'].locations[]" -o tsv | head -6
   ```

   ```text
   East US
   East US 2
   West US 3
   North Europe
   West Europe
   Japan East
   ```

3. **SKU restricted for your subscription** — symptom: `SkuNotAvailable`. The SKU exists in the region but your subscription is not entitled to it, or it is capacity-restricted in specific zones:

   ```bash
   az vm list-skus --location eastus --resource-type virtualMachines \
     --query "[?restrictions[0]].{SKU:name, Reason:restrictions[0].reasonCode, Type:restrictions[0].type, Zones:restrictions[0].restrictionInfo.zones}" \
     -o table | head -6
   ```

   ```text
   SKU                 Reason                        Type      Zones
   ------------------  ----------------------------  --------  -------
   Standard_M128ms     NotAvailableForSubscription   Location
   Standard_NC24ads_A100_v4  NotAvailableForSubscription  Zone   ['1', '2']
   Standard_HB120rs_v3 NotAvailableForSubscription   Location
   ```

   Read `type` carefully: `Location` means the SKU is unavailable in the whole region for you; `Zone` means it is available but only in the zones **not** listed under `restrictionInfo.zones`.

4. **Zonal capacity exhausted** — symptom: `ZonalAllocationFailed` at deploy time, not at validation time. This one cannot be pre-queried; capacity is a runtime condition. The mitigations, in order of preference: retry into a different logical zone, relax the SKU family, or drop the zone pin and let the platform place the instance regionally.

5. Confirm subscription-level quota before blaming capacity — quota exhaustion produces `QuotaExceeded`, which is a *subscription* problem, while `ZonalAllocationFailed` is a *datacenter* problem:

   ```bash
   az vm list-usage --location eastus --query "[?currentValue >= limit].{Quota:localName, Used:currentValue, Limit:limit}" -o table
   ```

   ```text
   Quota                       Used    Limit
   --------------------------  ------  -------
   Standard NCADSA100v4 Family 0       0
   ```

   A limit of `0` means the family was never approved for this subscription — no amount of retrying will help; it requires a quota-increase request.

> **Check your understanding — Block 6**
>
> **Q6.1** For each of `MissingSubscriptionRegistration`, `LocationNotAvailableForResourceType`, `SkuNotAvailable` and `ZonalAllocationFailed`, name the hierarchy (physical or logical) and the exact level the problem lives at.
> **Q6.2** You register `Microsoft.ContainerService` in subscription A. Does subscription B in the same tenant, under the same management group, now have it registered? Why or why not?
> **Q6.3** A deployment that has succeeded daily for a year suddenly fails with `ZonalAllocationFailed`. Nothing in your template changed. What changed, and which of the four mitigations in step 4 is the fastest?
> **Q6.4** In step 3, `Standard_NC24ads_A100_v4` shows `type: Zone` with `zones: ['1','2']`. In which logical zone can you deploy it, and why is that answer only valid for *your* subscription?

---

## Exercise 7 — Capstone: scope reasoning from a raw ARM ID (no deployment)

Read the following state description carefully. Answer from the ID strings and metadata alone.

```text
Tenant:            aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee  ("Contoso")
Management groups: Tenant Root Group
                     └── mg-contoso
                           ├── mg-prod      [Policy: deny locations outside {westeurope, northeurope}]
                           └── mg-nonprod

Subscriptions:     sub-prod    (11111111-...)  parent = mg-prod
                   sub-sandbox (22222222-...)  parent = mg-nonprod

Resources:
  R1  /subscriptions/11111111-.../resourceGroups/rg-payments/providers/Microsoft.Storage/storageAccounts/stpay001
      location = westeurope     sku = Standard_GZRS
  R2  /subscriptions/11111111-.../resourceGroups/rg-payments/providers/Microsoft.Compute/virtualMachines/vm-api-01
      location = westeurope     zones = ["1"]
  R3  /subscriptions/22222222-.../resourceGroups/rg-scratch/providers/Microsoft.Storage/storageAccounts/stscratch9
      location = eastus         sku = Standard_LRS

  rg-payments  location = northeurope
  rg-scratch   location = eastus
```

> **Check your understanding — Block 7**
>
> **Q7.1** Which resources does the `mg-prod` policy govern? Explicitly state whether R3 is affected and why.
> **Q7.2** `rg-payments` has `location = northeurope` but both its resources are in `westeurope`. Is this a policy violation? What exactly is stored in `northeurope`?
> **Q7.3** An operator runs `az group delete --name rg-payments`. List every resource destroyed, and state whether the deletion crosses a subscription boundary.
> **Q7.4** Availability zone 1 in `westeurope` suffers a total power loss. What is the status of R1 and of R2?
> **Q7.5** The entire `westeurope` region is lost. R1 is `Standard_GZRS`. Where is the surviving copy, who decides that location, and what is the access model for it until Microsoft initiates a failover?
> **Q7.6** Finance asks: "Split the bill between the payments team and the sandbox team." Which level of the logical hierarchy already does this, and what would you use if both teams shared a single subscription instead?
> **Q7.7** Write the ARM ID of the blob container `invoices` inside `stpay001`. What does the extra path segment tell you about how ARM models child resources?

---

<details>
<summary><strong>Answers</strong> — click to expand</summary>

### Block 0

**A0.1** Because "the tenant" is an **identity** boundary (Entra ID), not an authorization scope for Azure resources. Azure RBAC roles are assigned at management group, subscription, resource group or resource scope — the Entra directory itself is none of those. Being a member of the tenant, or even a Global Administrator in it, grants no Azure resource permissions until either an RBAC role is assigned at an Azure scope or a Global Administrator explicitly elevates access to the root management group.

**A0.2** `id` (the subscription ID) is the **billing** boundary — every resource under it rolls up to one invoice and one set of quotas. `tenantId` is the **identity** boundary — the Entra ID directory that authenticates principals. Many subscriptions can trust one tenant; a subscription trusts exactly one tenant at a time.

**A0.3** It would be `core.usgovcloudapi.net`. The difference means Azure Government is a *separate cloud instance*, not a region of the public cloud: separate ARM endpoint, separate Entra ID, separate DNS namespace. There is no implicit connectivity, no shared identity, and no cross-cloud resource management — an integration between them is an ordinary internet integration between two independent clouds.

### Block 1

**A1.1** No, it is not sufficient by itself. `westeurope` (Netherlands) keeps *primary* data in the EU, but GRS/RA-GRS/GZRS asynchronously replicates to the **paired region**, which you do not choose. For `westeurope` the pair is `northeurope` (Ireland) — still in the EU, so this particular case is fine. The point is that the guarantee comes from *verifying the pair*, not from picking the primary. Use LRS/ZRS if you need to eliminate cross-region replication entirely, or verify that the pair sits within your compliance geography before enabling GRS.

**A1.2** Region pairs are normally inside the same **geography**, so the paired region satisfies the same data-residency regime. `brazilsouth` is the documented exception: it pairs to `southcentralus` (Texas), which is a different geography and a different legal jurisdiction. Enabling GRS in `brazilsouth` therefore moves a replica of Brazilian data to the United States. `northeurope → westeurope` stays inside the Europe geography, so no jurisdictional change occurs. Note also that the Brazil pairing is one-way: `southcentralus` pairs back to `northcentralus`, not to Brazil.

**A1.3** From step 5's output: `israelcentral`, `italynorth`, `polandcentral`, `qatarcentral` (any two). These are single-region geographies with no platform-assigned pair. Instead you must (a) use **availability zones** for in-region datacenter-level resilience, and (b) explicitly choose and configure your own secondary region for DR using customer-managed tooling — Azure Site Recovery, object replication, application-level replication — accepting that the secondary may be in a different geography and that Microsoft gives no recovery-prioritization guarantee there.

**A1.4** Two of: new Azure services arrive later or never; availability zones may not be present, so zone-redundant SKUs (ZRS, zone-redundant SQL, zonal VMs) are unavailable; capacity for large or specialized SKUs (GPU, HPC, high-memory) is thinner, raising the rate of `SkuNotAvailable` and allocation failures; fewer SKU families offered overall; and it may not be a valid pair target for the residency guarantee you need.

**A1.5** Because Entra ID is a **non-regional** (`global`) service. It has no single region — Microsoft runs it as a globally distributed service across multiple geographies and manages its own replication and failover. The physical hierarchy (geography → region → zone → datacenter) simply does not apply to it, which is also why you cannot "fail Entra ID over" or pin it to a region for residency purposes.

### Block 2

**A2.1** No. `az account list-locations` in `AzureCloud` returns an empty array for `usgovvirginia` — the public cloud's ARM instance has no knowledge of Government regions at all. They are served by a completely different ARM endpoint (`management.usgovcloudapi.net`) backed by a different identity provider. Creating a resource there requires a Government subscription, a Government Entra tenant, and `az cloud set --name AzureUSGovernment`.

**A2.2** **21Vianet** (Beijing 21Vianet Broad Band Data Center Co., Ltd.), not Microsoft, operates Azure in China. Microsoft licenses the technology to them. For a runbook this means support tickets, SLAs, incident communications and billing all go through 21Vianet's channels; Microsoft global support cannot see or act on those resources, and Microsoft engineers do not have operational access to the datacenters.

**A2.3** A subscription trusts exactly one Entra tenant, and Azure Government has its **own, separate** Entra ID instance with its own tenant IDs and its own login endpoint (`login.microsoftonline.us`). A Government subscription cannot be attached to a public-cloud tenant. Achieving a unified identity experience requires a second directory in Government plus an explicit synchronization or federation mechanism between the two — it is a cross-cloud integration project, not a configuration toggle.

**A2.4** DNS resolution fails: `core.windows.net` does not exist in the Government cloud's namespace, so the app cannot reach its storage account. The fix is the `Storage` suffix from step 2 — `core.usgovcloudapi.net` — and the correct engineering practice is never to hardcode the suffix but to read it from the cloud environment metadata at runtime (the CLI, every SDK, and the instance metadata service all expose it).

### Block 3

**A3.1** What is wrong: zone numbers are **per-subscription logical labels**, and step 3 shows the two subscriptions map `1` to different physical zones (`eastus-az1` vs `eastus-az3`). "Both in zone 1" therefore does **not** mean "both in the same datacenter," so any reasoning based on co-location — such as an assumption of low intra-zone latency between them — is invalid. What is accidentally right: precisely because the mappings differ, the two VMs happen to sit in *different* physical zones, so they do have real zone-level fault isolation. The setup is accidentally resilient and deliberately unreasoned, which is the worst kind of architecture — the mapping is Microsoft's to change.

**A3.2** No. A single VM pinned to one zone is **zonal**, not zone-redundant: if that zone fails, the VM is gone. The minimum change is to deploy **at least two more instances into the other two logical zones** and put them behind a zone-redundant Standard Load Balancer (with the data tier on ZRS or a zone-redundant database). Redundancy is a property of the deployed set, never of a single zonal instance.

**A3.3** Ascending order of failure survived:
1. `Standard_LRS` — three copies inside a **single datacenter/zone**. Survives disk, rack and node failure. Stops at the zone boundary.
2. `Standard_ZRS` — three copies across **three availability zones** in one region. Survives the loss of a whole datacenter/zone. Stops at the region boundary.
3. `Standard_GRS` — LRS locally plus an asynchronous copy in the **paired region**. Survives the loss of the entire region. Stops at the geography boundary (and, because it is LRS at each end, it does *not* survive a zone failure without a full regional failover — that is what GZRS is for).

**A3.4** The correct conclusion is that **zone support is per-SKU, not just per-region**: this region has zones, but this particular SKU is not offered zonally there (often true for specialized GPU/HPC/high-memory families). Your two options: (a) choose a different SKU family that does list zones in that region, or (b) choose a different region where the SKU is offered zonally. A third, non-solution, is to deploy it regionally with no zone pin — but that buys you no zone resilience and you must say so explicitly rather than pretend otherwise.

**A3.5** None of the first or third survive; only the GRS account does.
- ZRS in `westeurope` — **lost**. ZRS protects against zone failure *within* a region; a whole-region loss takes all three zones.
- GRS in `westeurope` — **survives**, as an asynchronous replica in the paired region `northeurope`. Note "survives" means the data exists there; it is not readable until Microsoft initiates a failover, unless the SKU is RA-GRS.
- VM set across zones 1/2/3 in `westeurope` — **lost**. Zonal spread is in-region resilience only.

### Block 4

**A4.1** Affected: `mg-prod` (child management group), `Lab-Sandbox` (it is parented under `mg-nonprod`, which is a child of `mg-contoso`), and the resource group inside `Lab-Sandbox` — plus every resource in it. Policy and RBAC assignments inherit **downward through the entire subtree**. Not affected: the subscription parented directly under the root management group, because it is a sibling of `mg-contoso`, not a descendant. Inheritance flows only down, never sideways or up.

**A4.2** No. A subscription has **exactly one** parent management group. To get overlapping governance you assign policies at **different levels of the same branch** — for example a baseline policy at `mg-contoso` that every descendant inherits, plus a stricter policy at `mg-prod`. The effects compose along the ancestor chain: a `Deny` at any level in the chain wins.

**A4.3** Count the segments. A subscription-scope ID is exactly `/subscriptions/{guid}` and stops there. A resource-group-scope ID adds `/resourceGroups/{name}`. A resource-scope ID adds `/providers/{namespace}/{type}/{name}` on top of that. The presence of the `/providers/` segment is the reliable marker that you are at resource scope rather than at a container scope. Management-group IDs are distinctive in that they have **no** `/subscriptions/` segment at all — they start `/providers/Microsoft.Management/managementGroups/`.

**A4.4** It does not help because quotas are enforced **per subscription per region**, and a resource group is a metadata label with no quota of its own — every resource group in the subscription draws on the same vCPU pool. The two things that actually work: (a) request a quota increase for that family/region in that subscription, or (b) deploy into a **different subscription**, or a **different region** in the same subscription, since each combination has an independent quota pool.

**A4.5** Because a management group cannot be deleted while it still has children — and both subscriptions and child management groups count as children. `mg-nonprod` held the subscription, so the subscription had to be detached first; `mg-contoso` held `mg-prod` and `mg-nonprod`, so both had to go first. Deletion proceeds leaf-first up the tree. (This is also the opposite of resource-group deletion, which cascades — the two hierarchies have deliberately different destruction semantics.)

### Block 5

**A5.1** The **data** in `westus3` is unaffected — the storage account's bytes live in `westus3` and have no dependency on `eastus`. The resource group's location only determines where ARM stores that group's **metadata**. Manageability is the subtler answer: ARM's control plane is a globally distributed service with its own redundancy, and metadata for a resource group is replicated beyond its stated location, so management operations generally continue. The design rule the exam wants: **resource group location affects metadata and deployment-metadata storage, never where resources run or where their data lives.**

**A5.2** **Inheritance.** Locks, like RBAC role assignments and Azure Policy assignments, apply at their scope *and to every descendant scope*. A `CanNotDelete` lock at resource-group scope therefore blocks delete operations on every resource in that group. This is the same downward-only inheritance seen at management-group scope in Exercise 4; the resource group is simply the lowest container level at which you can apply it.

**A5.3** Changed: (1) its **ARM resource ID**, since the ID embeds the resource group name — every reference, RBAC assignment scoped to the old path, script and automation using the old ID now points at nothing; (2) its **governance context** — it now inherits the tags, locks, policies and RBAC of `rg-az900-lab-b`. Unchanged: its **physical location** — still `westus3`. Not one byte of data moved, and the account's endpoints are identical. That is the whole point: the resource group is a label in the logical hierarchy with no bearing on the physical one.

**A5.4** Resource groups **cannot be nested** — there is no parent-child relationship between them, and a resource belongs to exactly one. The construct that provides the hierarchy they want is the **management group**, which nests (up to six levels below the root, not counting the root or the subscription level) and into which subscriptions are parented. The idiomatic shape is: management group per business unit → child management group or subscription per environment → resource groups per application lifecycle inside it.

**A5.5** Because the resource group **is** the lifecycle unit: ARM's contract is that everything in a group shares a fate, so deleting the group is a single, intentional, all-or-nothing operation. The design rule this imposes: **group resources by what you would delete together**, not by what they have in common conceptually. A shared database placed in the same resource group as an ephemeral test app will be destroyed when that app is torn down. When you cannot restructure, `CanNotDelete` locks are the compensating control.

### Block 6

**A6.1**
- `MissingSubscriptionRegistration` — **logical**, **subscription** level. The resource provider namespace is not registered in that subscription.
- `LocationNotAvailableForResourceType` — **physical**, **region** level. The service is not offered in that region at all.
- `SkuNotAvailable` — the intersection: the SKU exists in the region (physical) but your **subscription** (logical) is not entitled to it, or it is restricted to a subset of zones (physical).
- `ZonalAllocationFailed` — **physical**, **availability zone / datacenter** level. Real capacity in that specific zone is exhausted right now.

**A6.2** No. Resource provider registration is a **per-subscription** setting, stored on the subscription object. It does not inherit from a management group and it is not shared across subscriptions in a tenant. Subscription B must run its own `az provider register`. (Azure auto-registers many providers on first use through the portal, which is why this failure so often appears only in scripted or CI deployments.)

**A6.3** What changed is **Microsoft's capacity in that physical zone** — other customers' demand, or hardware taken out for maintenance. Nothing on your side changed; allocation is a runtime condition evaluated at deploy time and cannot be pre-queried. The fastest mitigation is to **retry into a different logical zone** (`--zone 2` or `3`) — it is a one-flag change and preserves your zone-resilience posture. If that also fails, relax the SKU family, then as a last resort drop the zone pin and accept regional placement, documenting the loss of zone guarantees.

**A6.4** Zone **3**. `restrictionInfo.zones` lists the zones where the SKU is **restricted**, so the unrestricted remainder of `{1,2,3}` is the deployable set. The answer is subscription-specific for two reasons: the restriction itself is scoped to your subscription (`reasonCode: NotAvailableForSubscription`), and — more fundamentally — the logical zone numbers are mapped to physical zones per subscription, so "zone 3" here names a physical datacenter that another subscription reaches under a different number.

### Block 7

**A7.1** `mg-prod` governs `sub-prod` and everything beneath it: `rg-payments`, R1 and R2. **R3 is not affected**, because it lives in `sub-sandbox`, which is parented under `mg-nonprod` — a **sibling** of `mg-prod`, not a descendant. Inheritance flows strictly downward through the ancestor chain; a policy at `mg-prod` never reaches `mg-nonprod`. This is why R3 can sit in `eastus` despite the "EU only" rule.

**A7.2** Not a violation. The resource group's `location` stores only that group's **metadata** — its record in ARM and its deployment history. The policy `deny locations outside {westeurope, northeurope}` is satisfied by both resources' locations (`westeurope`), and `northeurope` would be an allowed value anyway. No customer data of R1 or R2 resides in `northeurope` by virtue of the group's location; the storage account's blobs are in `westeurope`, and the VM's compute and managed disks are in `westeurope`.

**A7.3** Destroyed: **R1** (`stpay001`) and **R2** (`vm-api-01`), plus every child resource implicitly created for them — the VM's NIC, OS and data managed disks, any zonal public IP, and all blob containers and their contents in `stpay001`. Deleting a resource group cascades to its entire contents unconditionally. It does **not** cross a subscription boundary: a resource group belongs to exactly one subscription, so `sub-sandbox`, `rg-scratch` and R3 are untouched.

**A7.4** **R1 survives.** It is `Standard_GZRS`, whose local component is ZRS — three copies spread across all three `westeurope` zones — so the loss of one zone is transparent and the account stays online and writable. **R2 is down.** It is a zonal VM pinned to `zones: ["1"]` with no peers in the other zones, so its compute and its zone-local managed disks are gone until the zone is restored. R2 is a textbook single-zone deployment mistaken for a resilient one.

**A7.5** The surviving copy is in `northeurope`, the **paired region** for `westeurope`. **Microsoft decides that location**, not you — pairs are fixed by the platform and cannot be chosen or changed. Until failover the secondary copy is **not accessible**: `Standard_GZRS` replication is asynchronous and the secondary endpoint is not readable. Two consequences follow. First, a customer-initiated or Microsoft-initiated **account failover** is required to promote it, and because replication is asynchronous, any writes not yet replicated at the moment of the outage are lost (the gap is measurable via the account's *last sync time*). Second, if you needed read access to the secondary without a failover, the correct SKU would have been `Standard_RA-GZRS`.

**A7.6** The **subscription** is the billing boundary and already splits the two teams' costs: `sub-prod` and `sub-sandbox` produce separate cost rollups, and each carries its own quotas. If both teams shared one subscription, the mechanism would be **resource tags** (for example `costCenter=payments`) combined with Cost Management grouping and budgets, optionally reinforced by an Azure Policy that requires the tag at creation time. Resource groups also serve as a coarse grouping dimension in Cost Management, but tags are the durable answer because they survive a resource being moved between groups.

**A7.7**

```text
/subscriptions/11111111-.../resourceGroups/rg-payments/providers/Microsoft.Storage/storageAccounts/stpay001/blobServices/default/containers/invoices
```

The extra `blobServices/default/containers/invoices` segments show that ARM models **child resources as a path extension of the parent's ID**, not as independent objects. Three consequences follow: the child's scope is strictly nested inside the parent's, so RBAC and locks assigned to `stpay001` inherit to the container; the child cannot exist without the parent and is destroyed with it; and the child has no independent `location` — it is physically wherever `stpay001` is (`westeurope`). The `default` segment is a singleton sub-resource, a pattern ARM uses whenever a parent has exactly one instance of a service tier.

</details>

---

## Sources

- AZ-900 study guide — <https://learn.microsoft.com/en-us/credentials/certifications/resources/study-guides/az-900>
- Azure regions and geographies overview — <https://learn.microsoft.com/en-us/azure/reliability/regions-overview>
- Azure region pairs and non-paired regions — <https://learn.microsoft.com/en-us/azure/reliability/regions-paired>
- Availability zones overview — <https://learn.microsoft.com/en-us/azure/reliability/availability-zones-overview>
- Availability zone region support — <https://learn.microsoft.com/en-us/azure/reliability/availability-zones-region-support>
- Azure Resource Manager overview — <https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/overview>
- Manage resource groups with Azure CLI — <https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/manage-resource-groups-cli>
- Move resources to a new resource group or subscription — <https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/move-resource-group-and-subscription>
- Lock resources to prevent changes — <https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/lock-resources>
- Management groups overview — <https://learn.microsoft.com/en-us/azure/governance/management-groups/overview>
- Azure subscription and service limits — <https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/azure-subscription-service-limits>
- Azure Storage redundancy — <https://learn.microsoft.com/en-us/azure/storage/common/storage-redundancy>
- Subscriptions – List Locations (REST) — <https://learn.microsoft.com/en-us/rest/api/resources/subscriptions/list-locations>
- Azure Government documentation — <https://learn.microsoft.com/en-us/azure/azure-government/documentation-government-welcome>
- Azure operated by 21Vianet — <https://learn.microsoft.com/en-us/azure/china/>