# AZ-900 · Topic 1.1 — Describe cloud computing
## Guided Exercises (hands-on lab book)

**Exam weight:** 9.4 · **Syllabus version:** 2026-07-20
**Skills covered:** define cloud computing · shared responsibility model · public / private / hybrid cloud models and their use cases · consumption-based model · comparison of cloud pricing models.

---

## Before you start

**What you need**

| Requirement | Notes |
|---|---|
| Azure CLI ≥ 2.60 | `az version` |
| `jq`, `curl`, `python3` | used for the pricing labs |
| An Azure subscription | Owner or Contributor on at least one resource group |
| ~USD 1–3 of spend | if you complete the teardown in the same session |

> **Cost guard.** Blocks 1–4 create billable resources. Every resource lives in **one resource group** so that Block 7 (teardown) removes all of it with a single command. Blocks 5 and 6 use the **Azure Retail Prices API**, which is anonymous and free — you can do them with no subscription at all.

**Convention used in every block:** commands are shown exactly as you type them; the block that follows is the *representative* output. Prices, region counts, quotas and kernel versions change — your values will differ. The exercise is about **the shape and the relationships**, never about matching a number.

---

## Block 0 — Environment and the cost guard rail

1. Confirm your tooling and identify the subscription you are about to spend money in.

   ```bash
   az version --output json | jq '{cli: ."azure-cli", core: ."azure-cli-core"}'
   az login --output none
   az account show --output table
   ```

   ```
   EnvironmentName    HomeTenantId                          IsDefault    Name                State    TenantId
   -----------------  ------------------------------------  -----------  ------------------  -------  ------------------------------------
   AzureCloud         3f1e...c02a                            True         Visual Studio Pro   Enabled  3f1e...c02a
   ```

2. Pin the identifiers you will reuse. Do **not** skip this — every later block assumes these variables.

   ```bash
   export SUB_ID=$(az account show --query id -o tsv)
   export LOCATION=eastus
   export RG=rg-az900-t11
   echo "sub=$SUB_ID region=$LOCATION rg=$RG"
   ```

3. Create the single blast-radius container, tagged so that a cost report can attribute every dollar to this lab.

   ```bash
   az group create --name "$RG" --location "$LOCATION" \
     --tags course=az-900 topic=1.1 lifecycle=ephemeral -o table
   ```

   ```
   Location    Name
   ----------  -------------
   eastus      rg-az900-t11
   ```

4. Inspect the *management scope hierarchy* you just wrote into. This hierarchy is the same object model that later governs cost, policy and access.

   ```bash
   az account management-group list -o table 2>/dev/null || echo "no management groups visible"
   echo "/subscriptions/$SUB_ID/resourceGroups/$RG"
   ```

   ```
   /subscriptions/8c3a1d5e-11b2-4d7f-9a0e-5f6c2b8e4a11/resourceGroups/rg-az900-t11
   ```

5. Record the current spend baseline so Block 4 has something to compare against.

   ```bash
   az consumption budget list -o table 2>/dev/null || echo "budget API not available on this offer"
   ```

### Checkpoint — Block 0

**Q1.** The scope string in step 4 has four segments. Which of them is the *smallest unit at which you can apply an Azure Policy, an RBAC role assignment, and a cost budget simultaneously*, and why does that matter for a lab?

**Q2.** You created the resource group with `lifecycle=ephemeral`. Tags cost nothing and do not change behaviour. In a consumption-based billing model, what concrete operational capability do they unlock that is impossible without them?

**Q3.** True or false: deleting the subscription's resource group deletes all cost history for the resources it contained. Justify.

---

## Block 1 — What "cloud computing" actually buys: self-service, elasticity, metered capacity

Cloud computing is the **delivery of computing services over the internet**. That definition is inert until you measure the three properties that distinguish it from a rack in a closet: *time to provision*, *bidirectional elasticity*, and *the boundary where "unlimited" stops being true*.

1. Measure the provisioning latency of a single compute unit. Time it.

   ```bash
   time az vm create -g "$RG" -n vm-t11-a \
     --image Ubuntu2204 --size Standard_B1s \
     --admin-username azureuser --generate-ssh-keys \
     --public-ip-sku Standard --nsg-rule SSH -o none
   ```

   ```
   real    1m14.822s
   user    0m2.905s
   sys     0m0.361s
   ```

2. Look at what one `az vm create` actually produced. A "virtual machine" is not one resource.

   ```bash
   az resource list -g "$RG" --query "[].{name:name, type:type}" -o table
   ```

   ```
   Name              Type
   ----------------  -----------------------------------------
   vm-t11-a          Microsoft.Compute/virtualMachines
   vm-t11-aVNET      Microsoft.Network/virtualNetworks
   vm-t11-aNSG       Microsoft.Network/networkSecurityGroups
   vm-t11-aPublicIP  Microsoft.Network/publicIPAddresses
   vm-t11-aVMNic     Microsoft.Network/networkInterfaces
   vm-t11-a_disk1_…  Microsoft.Compute/disks
   ```

3. Demonstrate **horizontal elasticity** with a scale set. The `--load-balancer ""` flag suppresses the Standard Load Balancer, which would otherwise bill hourly for a lab you do not need it in.

   ```bash
   az vmss create -g "$RG" -n vmss-t11 \
     --image Ubuntu2204 --vm-sku Standard_B1s \
     --orchestration-mode Uniform --instance-count 2 \
     --admin-username azureuser --generate-ssh-keys \
     --load-balancer "" --upgrade-policy-mode automatic -o none

   time az vmss scale -g "$RG" -n vmss-t11 --new-capacity 6 -o none
   az vmss list-instances -g "$RG" -n vmss-t11 --query "[].{id:instanceId, state:provisioningState}" -o table
   ```

   ```
   real    1m58.311s

   Id    State
   ----  ---------
   0     Succeeded
   1     Succeeded
   2     Succeeded
   3     Succeeded
   4     Succeeded
   5     Succeeded
   ```

4. Now prove elasticity is **bidirectional** — the half of the definition that on-premises capacity cannot satisfy at all.

   ```bash
   time az vmss scale -g "$RG" -n vmss-t11 --new-capacity 0 -o none
   az vmss show -g "$RG" -n vmss-t11 --query "sku.capacity"
   ```

   ```
   real    0m41.507s
   0
   ```

5. Demonstrate **vertical scaling** and its cost: it is not free of disruption.

   ```bash
   az vm show -g "$RG" -n vm-t11-a --query hardwareProfile.vmSize -o tsv
   az vm resize -g "$RG" -n vm-t11-a --size Standard_B2s -o none
   az vm show -g "$RG" -n vm-t11-a --query hardwareProfile.vmSize -o tsv
   az vm get-instance-view -g "$RG" -n vm-t11-a \
     --query "instanceView.statuses[?starts_with(code,'PowerState')].code" -o tsv
   ```

   ```
   Standard_B1s
   Standard_B2s
   PowerState/running
   ```

6. Find where "infinite capacity" ends. This is the single most commonly mis-stated property of cloud computing.

   ```bash
   az vm list-usage --location "$LOCATION" -o table | head -8
   ```

   ```
   Name                              CurrentValue    Limit
   --------------------------------  --------------  -------
   Availability Sets                 0               2500
   Total Regional vCPUs              2               10
   Virtual Machines                  1               25000
   Virtual Machine Scale Sets        1               2500
   Standard BS Family vCPUs          2               10
   Standard DSv5 Family vCPUs        0               0
   ```

7. Notice the last line. Read it carefully, then try to exceed a quota deliberately and observe the failure mode.

   ```bash
   az vmss scale -g "$RG" -n vmss-t11 --new-capacity 40 2>&1 | head -4
   ```

   ```
   (OperationNotAllowed) Operation could not be completed as it results in exceeding
   approved Total Regional Cores quota. Additional required: 38, (Minimum) New Limit
   Required: 40. Submit a request for Quota increase ...
   ```

   ```bash
   az vmss scale -g "$RG" -n vmss-t11 --new-capacity 0 -o none   # restore
   ```

### Checkpoint — Block 1

**Q4.** Step 1 took ~75 seconds. Step 4 took ~41 seconds to release six machines. Name the two distinct cloud characteristics these two measurements demonstrate, and state which of the two an over-provisioned on-premises datacentre can also claim.

**Q5.** Step 2 shows six resources created by one command. When the exam says cloud computing removes the need to "manage physical infrastructure", which of those six did you still have to define, and what does that tell you about where the abstraction boundary sits for IaaS?

**Q6.** In step 6, `Standard DSv5 Family vCPUs` shows a limit of `0` while `Virtual Machines` shows `25000`. Explain in one sentence why both numbers are true at the same time, and what a student who believes "the cloud has unlimited capacity" would get wrong.

**Q7.** Step 5 resized `B1s → B2s` while the VM stayed `PowerState/running`. Under what condition would the same command have required the VM to be deallocated first? (Think about what physically backs a VM size.)

---

## Block 2 — The shared responsibility model, proven service model by service model

The model is not a slogan; it is observable. **Whatever you can configure through the API, you are responsible for. Whatever has no knob, the provider owns.** Use that rule to derive the entire table experimentally.

### 2a — IaaS: you own the operating system

1. Reach into the guest OS. If you can read the kernel version, you own its patch level.

   ```bash
   az vm run-command invoke -g "$RG" -n vm-t11-a \
     --command-id RunShellScript \
     --scripts "uname -r; grep PRETTY /etc/os-release; apt list --upgradable 2>/dev/null | wc -l" \
     --query "value[0].message" -o tsv
   ```

   ```
   Enable succeeded:
   [stdout]
   6.8.0-1021-azure
   PRETTY_NAME="Ubuntu 22.04.5 LTS"
   37

   [stderr]
   ```

2. Confirm that patch orchestration is a **customer-chosen setting**, not a platform default.

   ```bash
   az vm show -g "$RG" -n vm-t11-a --query "osProfile.linuxConfiguration.patchSettings" -o json
   ```

   ```json
   {
     "assessmentMode": "ImageDefault",
     "automaticByPlatformSettings": null,
     "patchMode": "ImageDefault"
   }
   ```

3. Hand part of that responsibility back to Microsoft — and observe that this is an explicit, auditable act.

   ```bash
   az vm update -g "$RG" -n vm-t11-a \
     --set osProfile.linuxConfiguration.patchSettings.patchMode=AutomaticByPlatform \
           osProfile.linuxConfiguration.patchSettings.assessmentMode=AutomaticByPlatform \
     -o none
   az vm show -g "$RG" -n vm-t11-a --query "osProfile.linuxConfiguration.patchSettings" -o json
   ```

   ```json
   {
     "assessmentMode": "AutomaticByPlatform",
     "automaticByPlatformSettings": null,
     "patchMode": "AutomaticByPlatform"
   }
   ```

4. Now try to reach one level lower — the hypervisor and the physical host.

   ```bash
   az vm show -g "$RG" -n vm-t11-a -o json | jq 'paths(scalars) | join(".")' \
     | grep -iE "host|hypervisor|firmware|rack" || echo "no host-level property exposed"
   ```

   ```
   "virtualMachineScaleSet"
   no host-level property exposed
   ```

### 2b — PaaS: you own the runtime version, not the runtime

5. Provision a PaaS application platform. Note that you never chose an operating system image.

   ```bash
   export APP="app-t11-$RANDOM"
   az appservice plan create -g "$RG" -n plan-t11 --is-linux --sku B1 -o none
   az webapp create -g "$RG" -p plan-t11 -n "$APP" --runtime "PYTHON:3.12" -o none
   az webapp show -g "$RG" -n "$APP" --query "{name:name, state:state, host:defaultHostName}" -o table
   ```

   ```
   Name             State    Host
   ---------------  -------  --------------------------------
   app-t11-24817    Running  app-t11-24817.azurewebsites.net
   ```

6. Enumerate the knobs you *do* have. These are your responsibilities.

   ```bash
   az webapp config show -g "$RG" -n "$APP" \
     --query "{runtime:linuxFxVersion, alwaysOn:alwaysOn, minTls:minTlsVersion, ftps:ftpsState, http20:http20Enabled}" -o json
   ```

   ```json
   {
     "alwaysOn": false,
     "ftps": "FtpsOnly",
     "http20": false,
     "minTls": "1.2",
     "runtime": "PYTHON|3.12"
   }
   ```

7. Search for the knobs you do **not** have. The absence is the lesson — run this and read the empty result as data, not as an error.

   ```bash
   az webapp config show -g "$RG" -n "$APP" -o json \
     | jq -r 'paths(scalars) | join(".")' \
     | grep -iE "kernel|hostos|patch|hypervisor" || echo "NO host/OS/patch property exists on a Web App"
   ```

   ```
   NO host/OS/patch property exists on a Web App
   ```

8. Quantify the responsibility surface. Count the resources you must now operate for each model.

   ```bash
   az resource list -g "$RG" --query "[?contains(type,'Compute') || contains(type,'Network')] | length(@)"
   az resource list -g "$RG" --query "[?contains(type,'Web')] | length(@)"
   ```

   ```
   8
   2
   ```

### 2c — SaaS and the invariants

9. Identify the two things you own in **every** model, including SaaS, where no infrastructure API exists at all.

   ```bash
   az ad signed-in-user show --query "{identity:userPrincipalName, objectId:id}" -o json
   ```

   ```json
   {
     "identity": "student@contoso.onmicrosoft.com",
     "objectId": "b41f7d92-8e3c-4a55-9c10-0d7a2f6b1e88"
   }
   ```

10. Complete the canonical table from what you just observed. Fill each cell with **C** (customer), **M** (Microsoft) or **S** (shared). Do it before reading the answers.

    | Layer | On-prem | IaaS | PaaS | SaaS |
    |---|---|---|---|---|
    | Information and data | | | | |
    | Devices (mobile and PCs) | | | | |
    | Accounts and identities | | | | |
    | Identity and directory infrastructure | | | | |
    | Applications | | | | |
    | Network controls | | | | |
    | Operating system | | | | |
    | Physical hosts | | | | |
    | Physical network | | | | |
    | Physical datacentre | | | | |

### Checkpoint — Block 2

**Q8.** In step 3 you set `patchMode=AutomaticByPlatform`. Did responsibility for OS patching transfer to Microsoft? Answer precisely, distinguishing *execution* from *accountability*.

**Q9.** Step 7 returned nothing. Write the general rule that lets you infer a responsibility boundary from an API surface, and state one case where the rule is misleading.

**Q10.** Step 8 counted 8 vs 2 resources. A colleague concludes "PaaS is four times less work." Give the strongest counter-argument that is still consistent with the shared responsibility model.

**Q11.** Three rows of the table in step 10 have the same value in all four columns. Name them, and explain why the model is constructed so that these three can never shift to the provider.

---

## Block 3 — Public, private and hybrid: locating the control plane

The distinguishing variable is not "where the hardware is". It is **who owns the hardware and who else shares it**. Azure lets you observe all three postures through one API.

1. **Public cloud** — multi-tenant, provider-owned, globally distributed. Count what that means.

   ```bash
   az account list-locations --query "[?metadata.regionType=='Physical'] | length(@)"
   az account list-locations \
     --query "[?metadata.regionType=='Physical'].{region:name, geography:metadata.geographyGroup, paired:metadata.pairedRegion[0].name}" \
     -o table | head -8
   ```

   ```
   64

   Region              Geography       Paired
   ------------------  --------------  ------------------
   eastus              US              westus
   eastus2             US              centralus
   southcentralus      US              northcentralus
   westeurope          Europe          northeurope
   northeurope         Europe          westeurope
   japaneast           Asia Pacific    japanwest
   brazilsouth         South America   southcentralus
   ```

2. Confirm the physical redundancy inside one region — evidence of a scale no single tenant funds.

   ```bash
   az vm list-skus --location "$LOCATION" --size Standard_D2s_v5 --resource-type virtualMachines \
     --query "[0].locationInfo[0].zones" -o tsv | tr '\n' ' '
   ```

   ```
   1 2 3
   ```

3. **Private cloud** — single-tenant hardware, customer- or partner-owned. In Azure the product line is **Azure Local** (formerly Azure Stack HCI) and **Azure Stack Hub**. You cannot provision one in a lab, but you can inspect the ARM contract that governs it.

   ```bash
   az provider show -n Microsoft.AzureStackHCI --query "{namespace:namespace, state:registrationState}" -o table
   az provider show -n Microsoft.AzureStackHCI --query "resourceTypes[].resourceType" -o tsv | head -6
   ```

   ```
   Namespace                 State
   ------------------------  -------------
   Microsoft.AzureStackHCI   NotRegistered

   clusters
   clusters/arcSettings
   clusters/deploymentSettings
   clusters/updates
   edgeDevices
   galleryImages
   ```

4. **Hybrid cloud** — the two above, joined by one control plane. That control plane is **Azure Arc**. Register it and look at the resource type it introduces.

   ```bash
   az provider register --namespace Microsoft.HybridCompute --wait
   az extension add --name connectedmachine --upgrade -o none
   az provider show -n Microsoft.HybridCompute \
     --query "resourceTypes[?resourceType=='machines'].{type:resourceType, regions:length(locations)}" -o table
   az connectedmachine list -o table
   ```

   ```
   Type      Regions
   --------  ---------
   machines  38

   ```

5. Read the empty result in step 4 correctly: you have no Arc-enabled machines, but the *API contract already exists in your subscription*. Compare the two compute resource types side by side.

   ```bash
   for NS in Microsoft.Compute/virtualMachines Microsoft.HybridCompute/machines; do
     echo "$NS"
   done
   ```

   ```
   Microsoft.Compute/virtualMachines     -> Azure-hosted, Microsoft-owned hardware
   Microsoft.HybridCompute/machines      -> anywhere (on-prem, another cloud), customer-owned hardware
   ```

6. Demonstrate the operational payoff of hybrid: **one query, every estate**. Azure Resource Graph reads Azure-native and Arc-projected resources through the same index.

   ```bash
   az extension add --name resource-graph --upgrade -o none
   az graph query -q "Resources | summarize count() by type | order by count_ desc | limit 8" \
     --query "data" -o table
   ```

   ```
   Count_    Type
   --------  -----------------------------------------
   3         microsoft.network/networkinterfaces
   2         microsoft.compute/disks
   2         microsoft.web/sites
   1         microsoft.compute/virtualmachines
   1         microsoft.compute/virtualmachinescalesets
   1         microsoft.network/virtualnetworks
   1         microsoft.network/networksecuritygroups
   1         microsoft.network/publicipaddresses
   ```

7. Map each of the following to **public**, **private**, **hybrid** or **multi-cloud**, and write down the *deciding* attribute for each — not a general justification.

   | # | Scenario |
   |---|---|
   | a | A bank keeps card-holder data on owned hardware in its own datacentre, but runs its public marketing site on Azure App Service. |
   | b | A startup runs everything on Azure, in three regions, with no owned hardware. |
   | c | A hospital deploys Azure Local in a server room so patient records never leave the building, managed from the Azure portal. |
   | d | A retailer runs its API on Azure and its data warehouse on Google BigQuery. |
   | e | A manufacturer runs a factory-floor controller on an on-prem Linux server that is Arc-enabled and governed by Azure Policy. |
   | f | A government agency uses a physically isolated Azure region available only to cleared tenants. |

### Checkpoint — Block 3

**Q12.** Step 1 shows `eastus` paired with `westus`. Region pairing is a *public cloud* property. What does the existence of pairing tell you about who is responsible for cross-region disaster recovery of your data?

**Q13.** In step 3 the provider state was `NotRegistered` yet the resource types were listed anyway. What is the difference between a resource provider being *available* and being *registered*, and why does that distinction matter when someone claims "my subscription cannot do private cloud"?

**Q14.** Scenario (c) puts hardware in a hospital server room and manages it from the Azure portal. Is it private or hybrid? Defend both readings, then commit to the one the AZ-900 syllabus expects.

**Q15.** Give the *single* attribute that separates scenario (d) from scenario (e). Then state which of the two the exam calls "hybrid".

**Q16.** A customer says: "We want the cloud's elasticity but our regulator forbids multi-tenancy." Which model, which Azure product, and what specifically do they lose compared to public cloud?

---

## Block 4 — The consumption-based model: CapEx, OpEx, and what "stopped" really means

Consumption-based means **you pay for what you use, metered, after the fact** — no upfront hardware purchase, no idle depreciation. The most expensive misunderstanding in this whole topic is the difference between *stopped* and *deallocated*.

1. Stop the VM the way an OS-level admin would. Watch the power state.

   ```bash
   az vm stop -g "$RG" -n vm-t11-a -o none
   az vm get-instance-view -g "$RG" -n vm-t11-a --query "instanceView.statuses[].code" -o tsv
   ```

   ```
   ProvisioningState/succeeded
   PowerState/stopped
   ```

2. Now release the hardware.

   ```bash
   az vm deallocate -g "$RG" -n vm-t11-a -o none
   az vm get-instance-view -g "$RG" -n vm-t11-a --query "instanceView.statuses[].code" -o tsv
   ```

   ```
   ProvisioningState/succeeded
   PowerState/deallocated
   ```

3. Inspect what survived deallocation — and therefore what keeps billing.

   ```bash
   az disk list -g "$RG" --query "[].{name:name, gib:diskSizeGb, sku:sku.name, state:diskState}" -o table
   az network public-ip list -g "$RG" --query "[].{name:name, sku:sku.name, alloc:publicIPAllocationMethod, ip:ipAddress}" -o table
   ```

   ```
   Name                    Gib    Sku              State
   ----------------------  -----  ---------------  --------
   vm-t11-a_disk1_9f2c…    30     Premium_LRS      Reserved

   Name              Sku       Alloc    Ip
   ----------------  --------  -------  -------------
   vm-t11-aPublicIP  Standard  Static   20.121.44.7
   ```

4. Read the `Reserved` disk state and the retained IP address as the answer to "what am I still paying for?". Confirm the compute meter is the only one that stopped by listing what a deallocated VM no longer reports.

   ```bash
   az vm show -d -g "$RG" -n vm-t11-a --query "{power:powerState, privateIp:privateIps, publicIp:publicIps}" -o json
   ```

   ```json
   {
     "power": "VM deallocated",
     "privateIp": "",
     "publicIp": "20.121.44.7"
   }
   ```

5. Pull the actual metered records. Consumption data lags 8–24 hours — that lag is itself an exam-relevant property of the model.

   ```bash
   az consumption usage list \
     --start-date "$(date -u -d '3 days ago' +%Y-%m-%d)" \
     --end-date   "$(date -u +%Y-%m-%d)" \
     --query "[?contains(instanceName,'t11')].{resource:instanceName, meter:meterDetails.meterName, qty:usageQuantity, cost:pretaxCost, currency:currency}" \
     -o table 2>/dev/null | head -10 \
     || echo "az consumption is available on PAYG/EA offers only — use Cost Management below"
   ```

   ```
   Resource       Meter                       Qty        Cost        Currency
   -------------  --------------------------  ---------  ----------  ----------
   vm-t11-a       B2s                         1.983      0.0824      USD
   vm-t11-a       P4 LRS Disk                 0.098      0.0071      USD
   vm-t11-apublicip  Standard IPv4 Static IP  2.000      0.0072      USD
   plan-t11       B1 App                      2.000      0.0292      USD
   ```

6. If the previous command failed (Microsoft Customer Agreement subscriptions), use Cost Management, which works on every offer.

   ```bash
   az extension add --name costmanagement --upgrade -o none
   az costmanagement query --type ActualCost --timeframe MonthToDate \
     --scope "/subscriptions/$SUB_ID/resourceGroups/$RG" \
     --dataset-aggregation '{"totalCost":{"name":"Cost","function":"Sum"}}' \
     --dataset-grouping name="ServiceName" type="Dimension" \
     -o json | jq '{columns: [.columns[].name], rows: .rows}'
   ```

   ```json
   {
     "columns": ["Cost", "ServiceName", "Currency"],
     "rows": [
       [0.0824, "Virtual Machines", "USD"],
       [0.0292, "Azure App Service", "USD"],
       [0.0143, "Storage", "USD"],
       [0.0072, "Virtual Network", "USD"]
     ]
   }
   ```

7. Install the OpEx control that CapEx never needed: a **budget**. In CapEx you controlled spend by not signing the purchase order; in OpEx you control it with an alert on a meter.

   ```bash
   az consumption budget create-with-rg \
     --resource-group "$RG" --budget-name budget-az900-t11 \
     --amount 5 --category Cost --time-grain Monthly \
     --start-date "$(date -u +%Y-%m-01)" --end-date "$(date -u -d '+3 months' +%Y-%m-01)" \
     -o table 2>/dev/null \
     || echo "If this CLI version lacks the command: Portal > Cost Management + Billing > Budgets > Add"
   ```

8. Contrast the two cost curves explicitly. Fill this in from what you have observed, using words, not numbers:

   | | CapEx (on-prem) | OpEx (cloud consumption) |
   |---|---|---|
   | When money leaves | | |
   | Cost of an idle server at 3 a.m. | | |
   | Cost of a demand spike 3× above plan | | |
   | Accounting treatment | | |
   | Unit that is billed | | |

### Checkpoint — Block 4

**Q17.** Steps 1 and 2 produced `PowerState/stopped` and `PowerState/deallocated`. State exactly which meters stop in each case. Then explain why `az vm stop` exists at all if it keeps billing.

**Q18.** The disk in step 3 shows `diskState: Reserved`. Your VM is deallocated and costs nothing for compute. Write down every remaining meter in that resource group, from the output above, that continues to accrue.

**Q19.** Step 5 needed a 3-day window to show anything, and the docs warn of an 8–24 hour lag. Why is a consumption-based model *structurally* incapable of giving you a real-time bill, and what mechanism does Azure offer instead of one?

**Q20.** A finance director says: "Move to cloud and our IT spend becomes predictable." Correct the statement in one sentence, then name the two Azure mechanisms that actually deliver predictability.

---

## Block 5 — Comparing pricing models with real published rates

This block needs **no subscription and no authentication**. The Azure Retail Prices API is public.
Reference: <https://learn.microsoft.com/en-us/rest/api/cost-management/retail-prices/azure-retail-prices>

1. Pull every published price for one SKU in one region.

   ```bash
   FILTER="serviceName eq 'Virtual Machines' and armRegionName eq 'eastus' and armSkuName eq 'Standard_D2s_v5'"
   curl -s -G "https://prices.azure.com/api/retail/prices" \
     --data-urlencode "api-version=2023-01-01-preview" \
     --data-urlencode "currencyCode=USD" \
     --data-urlencode "\$filter=$FILTER" \
   | jq -r '.Items[] | [.skuName, .productName, .type, (.reservationTerm // "-"), .retailPrice, .unitOfMeasure] | @tsv' \
   | column -t -s $'\t'
   ```

   ```
   D2s v5        Virtual Machines Dv5 Series          Consumption         -        0.0960     1 Hour
   D2s v5        Virtual Machines Dv5 Series          Reservation         1 Year   672.1920   1 Hour
   D2s v5        Virtual Machines Dv5 Series          Reservation         3 Years  1345.6560  1 Hour
   D2s v5 Spot   Virtual Machines Dv5 Series          Consumption         -        0.0101     1 Hour
   D2s v5 Low Priority  Virtual Machines Dv5 Series   Consumption         -        0.0192     1 Hour
   D2s v5        Virtual Machines Dv5 Series Windows  Consumption         -        0.1920     1 Hour
   D2s v5        Virtual Machines Dv5 Series          DevTestConsumption  -        0.0960     1 Hour
   ```

2. Look hard at the `Reservation` rows. `unitOfMeasure` says `1 Hour` but `retailPrice` is `672.19`. That is not an hourly rate — for reservations the API returns **the total price for the whole term**. Verify this by computing the effective hourly rate and comparing it to pay-as-you-go.

3. Extract savings-plan rates, which the preview API nests inside each consumption item.

   ```bash
   curl -s -G "https://prices.azure.com/api/retail/prices" \
     --data-urlencode "api-version=2023-01-01-preview" \
     --data-urlencode "currencyCode=USD" \
     --data-urlencode "\$filter=$FILTER" \
   | jq -r '.Items[] | select(.savingsPlan != null) | .skuName as $s | .savingsPlan[] | [$s, .term, .retailPrice] | @tsv' \
   | column -t -s $'\t'
   ```

   ```
   D2s v5  1 Year   0.0782
   D2s v5  3 Years  0.0538
   ```

4. Normalise everything to a comparable effective hourly rate and a discount percentage.

   ```bash
   python3 - <<'PY'
   import json, urllib.parse, urllib.request

   BASE = "https://prices.azure.com/api/retail/prices"
   FILT = ("serviceName eq 'Virtual Machines' and armRegionName eq 'eastus' "
           "and armSkuName eq 'Standard_D2s_v5'")
   url = BASE + "?" + urllib.parse.urlencode({
       "api-version": "2023-01-01-preview", "currencyCode": "USD", "$filter": FILT})
   items = [i for i in json.load(urllib.request.urlopen(url))["Items"]
            if "Windows" not in i["productName"]]

   payg = next(i for i in items
               if i["type"] == "Consumption"
               and not any(k in i["skuName"] for k in ("Spot", "Low Priority")))
   base = payg["retailPrice"]
   print(f"{'model':<22}{'eff. $/h':>10}{'discount':>11}   commitment / risk")
   print(f"{'Pay-as-you-go':<22}{base:>10.4f}{'baseline':>11}   none")

   for i in items:
       if i["type"] == "Reservation":
           years = 3 if "3" in i["reservationTerm"] else 1
           eff = i["retailPrice"] / (8760 * years)
           print(f"{'Reserved ' + i['reservationTerm']:<22}{eff:>10.4f}"
                 f"{100*(1-eff/base):>10.1f}%   fixed SKU+region, {years}y")

   for sp in payg.get("savingsPlan") or []:
       eff = sp["retailPrice"]
       print(f"{'Savings plan ' + sp['term']:<22}{eff:>10.4f}"
             f"{100*(1-eff/base):>10.1f}%   fixed $/h spend, any SKU")

   for i in items:
       if "Spot" in i["skuName"]:
           print(f"{'Spot':<22}{i['retailPrice']:>10.4f}"
                 f"{100*(1-i['retailPrice']/base):>10.1f}%   evictable, 30s notice")
   PY
   ```

   ```
   model                   eff. $/h   discount   commitment / risk
   Pay-as-you-go             0.0960   baseline   none
   Reserved 1 Year           0.0767      20.1%   fixed SKU+region, 1y
   Reserved 3 Years          0.0512      46.7%   fixed SKU+region, 3y
   Savings plan 1 Year       0.0782      18.5%   fixed $/h spend, any SKU
   Savings plan 3 Years      0.0538      44.0%   fixed $/h spend, any SKU
   Spot                      0.0101      89.4%   evictable, 30s notice
   ```

5. Isolate the **licence** component. Compare the Linux and Windows meters for the identical hardware SKU.

   ```bash
   curl -s -G "https://prices.azure.com/api/retail/prices" \
     --data-urlencode "api-version=2023-01-01-preview" \
     --data-urlencode "currencyCode=USD" \
     --data-urlencode "\$filter=$FILTER and priceType eq 'Consumption'" \
   | jq -r '.Items[] | select(.skuName | test("Spot|Low Priority") | not)
            | [.productName, .retailPrice] | @tsv' | column -t -s $'\t'
   ```

   ```
   Virtual Machines Dv5 Series          0.0960
   Virtual Machines Dv5 Series Windows  0.1920
   ```

6. The delta (`0.0960`) is the Windows Server licence. **Azure Hybrid Benefit** is the mechanism that removes it when you already own the licence with Software Assurance. Verify how it is expressed on a VM resource.

   ```bash
   az vm show -g "$RG" -n vm-t11-a --query "{size:hardwareProfile.vmSize, license:licenseType}" -o json
   ```

   ```json
   {
     "license": null,
     "size": "Standard_B2s"
   }
   ```

7. Prove that **price is a per-region attribute**, not a global constant. This is the mechanical reason "choose your region carefully" appears in every cost-optimisation guide.

   ```bash
   for R in eastus westeurope japaneast brazilsouth australiaeast; do
     P=$(curl -s -G "https://prices.azure.com/api/retail/prices" \
       --data-urlencode "api-version=2023-01-01-preview" \
       --data-urlencode "currencyCode=USD" \
       --data-urlencode "\$filter=serviceName eq 'Virtual Machines' and armRegionName eq '$R' and armSkuName eq 'Standard_D2s_v5' and priceType eq 'Consumption' and productName eq 'Virtual Machines Dv5 Series'" \
       | jq -r '.Items[0].retailPrice // "n/a"')
     printf "%-16s %s\n" "$R" "$P"
   done
   ```

   ```
   eastus           0.096
   westeurope       0.1104
   japaneast        0.1284
   brazilsouth      0.1638
   australiaeast    0.1224
   ```

8. Finally, list the meters that are **not** compute — the ones students routinely forget when estimating.

   ```bash
   curl -s -G "https://prices.azure.com/api/retail/prices" \
     --data-urlencode "api-version=2023-01-01-preview" \
     --data-urlencode "currencyCode=USD" \
     --data-urlencode "\$filter=armRegionName eq 'eastus' and serviceName eq 'Bandwidth'" \
   | jq -r '.Items[] | [.meterName, .retailPrice, .unitOfMeasure] | @tsv' | head -6 | column -t -s $'\t'
   ```

   ```
   Inter-Region Egress          0.02   1 GB
   Standard Data Transfer Out   0.087  1 GB
   Data Transfer In             0.0    1 GB
   Intra-Region Egress          0.01   1 GB
   ```

### Checkpoint — Block 5

**Q21.** In step 1 the 1-Year reservation shows `retailPrice 672.19` with `unitOfMeasure "1 Hour"`. Explain the discrepancy and show the arithmetic that converts it to a comparable hourly rate.

**Q22.** Reserved instances and savings plans in step 4 land within ~2 percentage points of each other. Given they cost nearly the same, state the one workload characteristic that should decide between them.

**Q23.** Spot is ~89% cheaper. Name two workload types where that is a correct choice and two where it is a firing offence, and give the technical property that separates the groups.

**Q24.** In step 5 the Windows meter is exactly double the Linux meter. A team applies Azure Hybrid Benefit to 100 of these VMs running 730 h/month. Using only the numbers shown, compute the monthly reduction and state what the team must legally possess for it to be valid.

**Q25.** Step 7 shows `brazilsouth` at ~1.7× `eastus`. Give two legitimate reasons an architect would still choose `brazilsouth`, both of which outrank unit price.

**Q26.** Step 8 shows `Data Transfer In` at `0.0` and `Standard Data Transfer Out` at `0.087/GB`. What architectural anti-pattern does this asymmetric pricing exist to discourage, and what is the name of the general concern it creates?

---

## Block 6 — Decision drill (no cloud resources required)

For each scenario, write down **(i)** the cloud model, **(ii)** the service model, **(iii)** the pricing model, and **(iv)** the one sentence of justification you would give an exam grader.

| # | Scenario |
|---|---|
| 1 | A logistics firm runs a batch route-optimisation job every night for 4 hours. It is restartable from a checkpoint and has no deadline before 06:00. |
| 2 | A SaaS company runs 40 identical production API servers 24×7. The architecture is frozen for the next three years. |
| 3 | A bank must keep an HSM-backed key store on hardware it physically controls, but wants Azure Monitor to alert on it. |
| 4 | A university spins up 300 student lab VMs for two weeks each semester and destroys them afterwards. |
| 5 | An ISV is uncertain whether it will standardise on VMs, containers or functions, but is confident it will spend at least USD 8,000/month on compute for the next year. |
| 6 | A retailer's e-commerce front end sits at 12 servers of load for 11 months and 90 servers for six weeks around the holidays. |
| 7 | A payroll company wants email, documents and identity with zero infrastructure operations, but is contractually accountable for who can read the payroll files. |

### Checkpoint — Block 6

**Q27.** Scenarios 2 and 5 both involve long-term commitment. Which gets a reservation and which gets a savings plan? State the deciding word in each scenario text.

**Q28.** Scenario 6 is the classic argument for cloud economics. Draw (in words) the CapEx capacity line versus the OpEx consumption line across the year, and name the two costs the CapEx line incurs that the OpEx line does not.

**Q29.** Scenario 7 is SaaS. Identify the one responsibility the payroll company cannot delegate, quoting the row of the shared responsibility table it comes from.

---

## Block 7 — Teardown (do not skip)

1. Remove everything in one operation. The resource group boundary you set in Block 0 is what makes this safe.

   ```bash
   az resource list -g "$RG" --query "length(@)"
   az group delete --name "$RG" --yes --no-wait
   ```

   ```
   10
   ```

2. Confirm, after a few minutes, that the group is gone.

   ```bash
   az group exists --name "$RG"
   ```

   ```
   false
   ```

3. Sweep for orphans that a `vm delete` (as opposed to a group delete) would have left behind. Unattached disks and idle public IPs are the two most common silent charges.

   ```bash
   az disk list --query "[?diskState=='Unattached'].{name:name, rg:resourceGroup, gib:diskSizeGb}" -o table
   az network public-ip list --query "[?ipConfiguration==null].{name:name, rg:resourceGroup, sku:sku.name}" -o table
   ```

   ```
   (no output — nothing orphaned)
   ```

4. Verify the cost stopped accruing by re-running the Cost Management query from Block 4 tomorrow. Remember the 8–24 h lag: an empty result today proves nothing.

### Checkpoint — Block 7

**Q30.** Step 3 looks for resources with `diskState == 'Unattached'` and `ipConfiguration == null`. In a consumption-based model, what does each of those two conditions cost you, and why does deleting a VM in the portal not eliminate them by default?

---

## Sources

- AZ-900 study guide — <https://learn.microsoft.com/en-us/credentials/certifications/resources/study-guides/az-900>
- Shared responsibility in the cloud — <https://learn.microsoft.com/en-us/azure/security/fundamentals/shared-responsibility>
- Azure Retail Prices API — <https://learn.microsoft.com/en-us/rest/api/cost-management/retail-prices/azure-retail-prices>
- Virtual machine states and billing — <https://learn.microsoft.com/en-us/azure/virtual-machines/states-billing>
- Save costs with reservations — <https://learn.microsoft.com/en-us/azure/cost-management-billing/reservations/save-compute-costs-reservations>
- Azure savings plan for compute — <https://learn.microsoft.com/en-us/azure/cost-management-billing/savings-plan/savings-plan-compute-overview>
- Azure Spot Virtual Machines — <https://learn.microsoft.com/en-us/azure/virtual-machines/spot-vms>
- Azure Arc overview — <https://learn.microsoft.com/en-us/azure/azure-arc/overview>
- Availability zones — <https://learn.microsoft.com/en-us/azure/reliability/availability-zones-overview>
- Create and manage budgets — <https://learn.microsoft.com/en-us/azure/cost-management-billing/costs/tutorial-acm-create-budgets>
- Azure subscription and service limits — <https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/azure-subscription-service-limits>

---

<details>
<summary><strong>Answers — expand only after attempting every checkpoint</strong></summary>

### Block 0

**Q1.** The **resource group** (`/subscriptions/{id}/resourceGroups/{name}`). It is the smallest scope that accepts Azure Policy assignments, RBAC role assignments and Cost Management budgets simultaneously. Individual resources accept RBAC and some policy effects, but not budgets. For a lab this matters because one deletion of that single scope guarantees no orphaned billable resource survives — the blast radius equals the cost radius.

**Q2.** **Cost attribution and chargeback.** Consumption billing produces one flat stream of metered line items with no notion of team, project or purpose. Tags are the only mechanism that projects business meaning onto that stream — they let you group cost by `course`, `owner` or `cost-centre` in Cost Management, and let policy automatically clean up anything marked `lifecycle=ephemeral`. Without tags the invoice is accurate and useless.

**Q3.** **False.** Cost and usage records are billing-scope data, retained independently of the resource lifecycle. Deleting the resource group stops future accrual; historical line items remain queryable in Cost Management (and in exports) under the subscription/billing account scope. This is precisely why step 4 of Block 7 says to re-check tomorrow rather than immediately.

### Block 1

**Q4.** (i) **Rapid elasticity / self-service provisioning** — capacity appears on an API call in ~75 s with no procurement cycle. (ii) **Bidirectional elasticity with metered release** — capacity is *returned* in ~41 s and billing stops. An over-provisioned on-prem datacentre can claim the first (spin up a VM on spare hardware quickly) but **never the second**: releasing a VM on owned hardware returns nothing, because the capital was already spent and the depreciation continues.

**Q5.** You still defined the **virtual network, subnet, NSG rules, public IP and NIC** — plus the OS image and disk. The abstraction boundary for IaaS sits **at the hypervisor**: Microsoft removed racking, cabling, power, cooling and physical network fabric, but every *logical* infrastructure construct is still yours to design, secure and operate. "No physical infrastructure" is not "no infrastructure".

**Q6.** They measure different things. `Virtual Machines` is a *count* quota (how many VM objects may exist); `Standard DSv5 Family vCPUs` is a *capacity* quota per SKU family in that region, and it is `0` because the subscription has never been approved for that family there. A student who believes capacity is unlimited will design an autoscale rule to 40 instances, pass every functional test at 2 instances, and discover the ceiling during the traffic peak the design existed to survive. Cloud capacity is elastic **within a per-region, per-family quota**; raising it is a support request with a lead time.

**Q7.** When the target size belongs to a **different hardware cluster / VM family** than the one currently hosting the VM. `B1s → B2s` stays inside the B-family on the same cluster, so Azure can resize in place. `B2s → D2s_v5` (or any size not offered by the current cluster) requires `az vm deallocate` first, because the VM must be re-placed onto physically different hardware — which also means it loses its dynamic IP and any local temp disk contents.

### Block 2

**Q8.** **Execution transferred; accountability did not.** `AutomaticByPlatform` makes Azure Update Manager schedule and apply the patches, so Microsoft *performs* the work. But you chose the mode, you own the maintenance window, you own what happens if a patch breaks the application, and you remain answerable in an audit for the machine's patch level. In the shared responsibility model the OS row stays **customer** for IaaS regardless of who pushes the button. Delegating a task is not delegating responsibility.

**Q9.** Rule: **the configurable surface of a service is a lower bound on your responsibility for it.** If the API exposes a knob, the provider has declared that setting to be your decision, and therefore your liability. If no knob exists at any layer, that layer is operated entirely by the provider. Where it misleads: **read-only** properties (you can *see* the host's fault domain but cannot set it) and **shared** rows such as network controls and identity infrastructure, where both parties hold real obligations and the presence of a knob understates neither. Absence of an API also never removes your data and identity responsibilities — SaaS has almost no infrastructure API and yet those rows stay yours.

**Q10.** PaaS removes *breadth* of responsibility, not *depth*. The eight IaaS resources are largely one-time infrastructure definitions; the two PaaS resources still carry the application code, its dependencies, its secrets, its identity configuration, its data and its availability design — and those are where nearly all incidents originate. PaaS moves your effort **up the stack, not out of existence**: you stop patching kernels and start owning a runtime you can no longer inspect below the container boundary. Resource count measures surface area, not operational load.

**Q11.** **Information and data**, **Devices**, and **Accounts and identities** are customer-owned in all four columns. The model is built this way because these three are the things the provider cannot see, cannot value, and cannot make decisions about: Microsoft does not know which of your records are regulated, which laptop belongs to a departing employee, or which account should have been disabled last Friday. Provider responsibility can only extend to what the provider can observe and control; these three are definitionally outside that set, which is why every cloud breach analysis eventually lands on one of them.

**Reference table for step 10** (C = customer, M = Microsoft, S = shared):

| Layer | On-prem | IaaS | PaaS | SaaS |
|---|---|---|---|---|
| Information and data | C | C | C | C |
| Devices (mobile and PCs) | C | C | C | C |
| Accounts and identities | C | C | C | C |
| Identity and directory infrastructure | C | S | S | S |
| Applications | C | C | S | M |
| Network controls | C | C | S | M |
| Operating system | C | C | M | M |
| Physical hosts | C | M | M | M |
| Physical network | C | M | M | M |
| Physical datacentre | C | M | M | M |

### Block 3

**Q12.** Pairing tells you Microsoft has engineered **physical and operational separation** (>300 km typically, sequential platform updates, prioritised recovery) — it is a *capability*, not a service. Responsibility for cross-region DR of your data remains **yours**: you must choose geo-redundant storage, configure replication, and test failover. Pairing gives you a well-chosen destination; it does not copy anything on your behalf. Confusing the two is the origin of "we thought Azure had a backup".

**Q13.** **Available** means the resource provider exists in the Azure fleet and its resource types and API versions are published — that is why the types listed. **Registered** means *this subscription* has opted in, permitting resource creation in that namespace. Registration is a free, self-service, idempotent operation (`az provider register`). So "my subscription cannot do private cloud" is almost never a capability statement; it is usually an unregistered provider or a missing RBAC role, both fixable in one command. Real blockers are licensing, hardware and regional availability, not the provider state.

**Q14.** *Private reading:* the hardware is single-tenant, customer-owned, in a customer-controlled facility; no other tenant shares it — that is the textbook definition of private cloud. *Hybrid reading:* it is managed through the Azure control plane, billed through an Azure subscription, and governed by the same policies as public Azure resources, so the estate spans both. **Commit to hybrid.** The syllabus defines hybrid as an environment that combines public and private cloud *and lets them be operated together*; Azure Local's defining feature is exactly that Azure-connected management plane. Azure Stack Hub in fully disconnected mode would be the cleaner "private cloud" answer.

**Q15.** **Whether the two environments are joined by a single control plane.** (d) runs two independent public clouds side by side with separate management, identity and billing — that is **multi-cloud**. (e) projects an on-premises machine into Azure Resource Manager via Arc so one policy engine, one RBAC model and one inventory cover both — that is **hybrid**. The exam calls (e) hybrid.

**Q16.** Model: **private cloud**. Product: **Azure Local** (or Azure Stack Hub for a fully disconnected requirement). What they lose: **true elasticity and the consumption model.** Capacity is now bounded by hardware they bought, so scaling out is a procurement cycle again, the CapEx returns, idle capacity is paid for, and the global region footprint, unlimited-scale PaaS services and pay-per-second billing are not available. They keep the operating model and the API; they give up the economics.

### Block 4

**Q17.** `PowerState/stopped`: the guest OS is shut down, but the VM **remains allocated** on a physical host — the compute meter, the disk meters and the IP meter all keep running. Azure is holding that hardware for you. `PowerState/deallocated`: the VM is released from the host — the **compute meter stops**; disk and static public IP meters continue. `az vm stop` exists because deallocation is not always desired: it releases the host reservation (so a subsequent start can fail on capacity or land on different hardware), it discards the temporary disk, and it drops dynamic IPs. When you need a fast, guaranteed restart on the same hardware, you stop; when you want to stop paying, you deallocate.

**Q18.** Still accruing after deallocation, from the outputs shown:
- **Managed OS disk** — 30 GiB `Premium_LRS`, `diskState: Reserved` (provisioned capacity is billed whether attached or not).
- **Static Standard public IP** — `20.121.44.7`, billed hourly for the reservation of the address itself.
- **App Service plan `plan-t11` (B1)** — a dedicated plan bills continuously regardless of whether an app is running.
- Plus small storage transaction/diagnostic meters if boot diagnostics is enabled.
The VNet and NSG themselves are free.

**Q19.** Because the model bills **metered events after they occur**. Every second of usage across millions of tenants must be emitted by the resource provider, collected, deduplicated, rated against your specific price sheet (which depends on offer, negotiated discounts, reservations, credits and currency), and only then materialised as a cost record. Rating is the expensive step and it is inherently retrospective. Azure's answer is not a real-time bill but **predictive and reactive controls**: budgets with threshold alerts, cost anomaly detection, and quota limits that cap the physical ability to spend. You control an OpEx bill by bounding it in advance, not by watching it live.

**Q20.** Correction: *"Cloud makes IT spend **variable and proportional to use**; that is the opposite of predictable — it is why an unbounded workload can produce an unbounded invoice."* The two mechanisms that restore predictability: **(1) commitment pricing** — reservations and savings plans, which convert a variable rate into a fixed one; **(2) governance controls** — budgets with alerts and action groups, plus quotas and Azure Policy limits on SKU and region, which cap what can be provisioned at all.

### Block 5

**Q21.** For `type: "Reservation"` items the API returns the **total price for the entire term**, and `unitOfMeasure` reflects the underlying consumption unit rather than the billing unit of that row. Convert by dividing by the hours in the term:

```
1-Year:  672.1920 / (8760 × 1)  = 0.07673 $/h   →  1 − 0.07673/0.0960 = 20.1% discount
3-Year: 1345.6560 / (8760 × 3)  = 0.05119 $/h   →  1 − 0.05119/0.0960 = 46.7% discount
```
(8760 = 365 × 24; Azure's own material commonly uses 730 h/month × 12.) Comparing `672.19` directly against `0.0960` is the classic error — it makes a reservation look 7,000× more expensive than pay-as-you-go.

**Q22.** **Whether the workload's SKU, family and region are stable for the term.** A *reservation* is locked to a specific VM family, region and term; it delivers the deepest discount but only pays out if you actually run that shape. A *savings plan* commits to a fixed hourly **dollar amount** and applies automatically across eligible compute (different VM families, App Service, Container Instances, Functions Premium, across regions), trading a slightly smaller discount for flexibility. So: architecture frozen → reservation; architecture likely to change → savings plan.

**Q23.** **Correct for Spot:** batch/ETL and rendering jobs with checkpointing; CI/CD build agents; large-scale stateless test fleets; opportunistic ML training with saved checkpoints. **Firing offence:** the primary database; a synchronous customer-facing API tier; a stateful session server without external session storage; anything under an availability SLA. The separating property is **interruption tolerance**: Spot instances are evicted with roughly 30 seconds of notice whenever Azure needs the capacity back or your max price is exceeded, and Spot carries **no availability SLA**. If losing the instance mid-request loses work or breaks a promise to a user, Spot is wrong at any discount.

**Q24.** Per-VM licence uplift = `0.1920 − 0.0960 = 0.0960 $/h`.
`0.0960 × 730 h × 100 VMs = 7,008 USD/month` saved (≈ 84,096 USD/year).
Requirement: the organisation must **own Windows Server licences with active Software Assurance, or subscription licences**, in sufficient quantity for the cores being covered, and must attest to that when enabling the benefit (`--license-type Windows_Server`). Azure does not verify entitlement at provisioning time — the customer bears the compliance risk, and this is audited.

**Q25.** (1) **Data residency and regulatory compliance** — Brazilian law (LGPD) or sector regulation may require the data to remain in-country; an illegal deployment at half price is not cheaper. (2) **Latency to the user base** — for interactive workloads serving Brazilian users, ~150 ms of added round-trip to `eastus` degrades the product in a way a ~40% compute saving cannot offset. A third valid answer: **data egress cost and gravity** — placing compute far from the data it reads can cost more in cross-region bandwidth than the compute discount saves.

**Q26.** It discourages **chatty, cross-region and cross-cloud architectures that repeatedly pull data out of the platform** — for example, a compute tier in one region reading a dataset stored in another on every request, or a reporting layer that exports full tables instead of querying in place. Ingress is free precisely because the provider wants your data in; egress is charged because moving it out consumes the provider's expensive backbone and internet transit. The general concern this creates is **data gravity** and its commercial consequence, **vendor lock-in**: the larger the dataset, the more it costs to move, so the data anchors the compute to the platform. Architecturally the mitigations are: compute next to data, aggregate before egress, and use private peering or CDN for genuinely external traffic.

### Block 6

| # | Cloud model | Service model | Pricing model | Justification |
|---|---|---|---|---|
| 1 | Public | IaaS (VMs / Batch) | **Spot** | Restartable from a checkpoint with a 6-hour slack window — eviction costs a retry, not the job. |
| 2 | Public | IaaS | **Reserved instances, 3-year** | 40 *identical* servers, 24×7, architecture *frozen for three years*: SKU, region and term are all fixed, so the deepest commitment discount applies with no flexibility risk. |
| 3 | Hybrid | IaaS on customer hardware + Azure Arc | Pay-as-you-go for the Azure services | Hardware must be physically controlled (private), yet must be visible to Azure Monitor — that combination *is* hybrid, delivered by Arc. |
| 4 | Public | IaaS (or Azure Lab Services / DevTest Labs) | **Pay-as-you-go**, with auto-shutdown; Dev/Test rates if the subscription qualifies | Two bursts a year — commitment pricing would idle for 11 months; the value here is deallocating everything between semesters. |
| 5 | Public | mixed (undecided) | **Savings plan, 1-year** | The commitment is expressed as *dollars per month*, not as a SKU. A savings plan commits spend and floats across VMs, containers and functions. |
| 6 | Public | IaaS/PaaS with autoscale | **Hybrid: reservation or savings plan for the ~12-server baseline + pay-as-you-go (or Spot) for the peak** | Commit only to the floor you will always consume; buy the peak on demand. Committing to 90 would waste 78 servers for 11 months. |
| 7 | Public | **SaaS** (Microsoft 365) | Per-user subscription | Zero infrastructure operations is the definition of SaaS; billing is per seat, not per resource-hour. |

**Q27.** Scenario 2 → **reservation**; the deciding words are *"40 identical"* and *"architecture is frozen"* — the SKU is known and immovable. Scenario 5 → **savings plan**; the deciding words are *"uncertain whether it will standardise on VMs, containers or functions"* combined with a confident *dollar* figure — you can commit to spend without committing to shape.

**Q28.** **CapEx line:** a flat step at 90 servers' worth of capacity for the whole year — the peak must be bought in advance, provisioned months before it is needed, and it does not decrease in January. Roughly 87% of that capacity is idle for 11 months. **OpEx line:** it traces demand itself — flat at 12 for 11 months, a near-vertical ramp to 90 for six weeks, then back down. Two costs the CapEx line incurs that OpEx does not: **(1) the carrying cost of idle capacity** — depreciation, power, cooling, rack space, licences and support on 78 unused servers for 11 months; **(2) the cost of being wrong in the other direction** — if the peak turns out to be 120, the OpEx line simply scales, while the CapEx line requires a procurement cycle measured in months and loses the revenue in the meantime. A frequently-credited third is the **opportunity cost of the capital** locked in the purchase.

**Q29.** **"Information and data"** — and by extension **"Accounts and identities"**. The scenario says the company is *contractually accountable for who can read the payroll files*. Microsoft operates the application, the OS, the network and the datacentre, but it cannot know which employee record is confidential or which account should have been revoked. Access governance, data classification, retention and the consequences of a wrong permission remain with the customer in every service model, SaaS included.

### Block 7

**Q30.** **Unattached managed disk:** billed at its **provisioned** size and performance tier, continuously, forever — a 1 TiB Premium SSD costs the same detached as attached, because Azure reserved that capacity for you. **Public IP with `ipConfiguration == null`:** a Standard SKU address is billed hourly for the *reservation of the address itself*, whether or not anything is behind it; IPv4 scarcity is the reason. Neither is removed by deleting a VM in the portal because both are **independent ARM resources with their own lifecycle** — the portal's delete blade offers to remove them but historically did not do so by default, and CLI/ARM/Terraform deletions of the VM resource never do. This is the single most common source of "we deleted everything and the bill did not go down", and it is exactly why Block 0 put every resource inside one resource group: `az group delete` has no such gap.

</details>