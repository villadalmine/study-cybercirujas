# AZ-900 · Topic 1.3 — Describe Cloud Service Types
## Guided Exercises (IaaS / PaaS / SaaS, shared responsibility, use-case selection)

**Exam objective coverage** (AZ-900 study guide, version 2026-07-20):
- Describe infrastructure as a service (IaaS)
- Describe platform as a service (PaaS)
- Describe software as a service (SaaS)
- Identify appropriate use cases for each cloud service type

**Domain weight:** 9.4

---

## 0. Prerequisites and cost control

You will provision real, billable resources. Read this block before running anything.

| Requirement | Check |
|---|---|
| Azure CLI ≥ 2.60 | `az version` |
| An Azure subscription where you hold **Contributor** on a resource group | `az account show` |
| `jq` for JSON filtering | `jq --version` |
| Bicep CLI (bundled with recent `az`) | `az bicep version` |
| Microsoft Entra role to read licences (Global Reader is enough) | Exercise 5 only — read-only |

**Estimated cost of the full walkthrough:** under USD 1 if you complete Exercise 10 (cleanup) the same day. A `Standard_B2s` VM plus a `B1` App Service plan is roughly USD 0.12/hour combined. **Do not walk away from this lab with resources running.**

Set your working variables once:

```bash
export LOC=eastus
export RG=rg-az900-svctypes
export SUFFIX=$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')
echo "Unique suffix for globally-unique names: $SUFFIX"
```

```
Unique suffix for globally-unique names: 7b3af10c
```

```bash
az group create --name "$RG" --location "$LOC" -o table
```

```
Location    Name
----------  ---------------------
eastus      rg-az900-svctypes
```

---

## Exercise 1 — Build the responsibility ladder before you touch Azure

The whole objective collapses into one question: **where does the boundary between you and Microsoft sit?** Do this on paper first, then let the CLI prove or refute you.

1. Draw a ten-row table. Rows, from top to bottom:
   `Information and data` · `Devices (mobile and PCs)` · `Accounts and identities` · `Identity and directory infrastructure` · `Applications` · `Network controls` · `Operating system` · `Physical hosts` · `Physical network` · `Physical datacenter`.
2. Add four columns: `SaaS`, `PaaS`, `IaaS`, `On-premises`.
3. Fill every cell with one of `Customer`, `Microsoft`, `Shared`.
4. Circle the three rows that never change value across the SaaS/PaaS/IaaS columns, and the three rows that never change in the opposite direction.
5. Circle the single row that flips from `Microsoft` to `Customer` exactly at the PaaS → IaaS boundary. Write its name in the margin — the exam tests this row more than any other.
6. Compare your table with the canonical one at <https://learn.microsoft.com/en-us/azure/security/fundamentals/shared-responsibility>. Correct your cells; do not correct your memory of them — you will re-derive the table in Exercise 9.

**Verify your understanding**

- **Q1.** Which three rows are always the customer's responsibility, in every service model including SaaS, and why can a cloud provider never take them over even if it wanted to?
- **Q2.** Which row flips at the PaaS → IaaS boundary, and what is the concrete operational consequence of that flip on a Tuesday morning after a CVE is published?
- **Q3.** `Identity and directory infrastructure` is `Shared` in all three cloud columns. Give one thing Microsoft does in that row and one thing you must do.
- **Q4.** A colleague says "we moved to SaaS, so data loss is Microsoft's problem now." Using only the table, state precisely why this is wrong.

---

## Exercise 2 — IaaS: provision it, then prove you own the operating system

IaaS gives you the compute, storage and networking primitives. Everything from the OS upward is yours. This exercise makes that ownership *measurable* rather than asserted.

1. Create a Linux VM. Note that this single command silently creates **six** resources:

```bash
az vm create \
  --resource-group "$RG" \
  --name vm-iaas-demo \
  --image Ubuntu2404 \
  --size Standard_B2s \
  --admin-username azureuser \
  --generate-ssh-keys \
  --public-ip-sku Standard \
  --nsg-rule SSH \
  -o json
```

```json
{
  "fqdns": "",
  "id": "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-az900-svctypes/providers/Microsoft.Compute/virtualMachines/vm-iaas-demo",
  "location": "eastus",
  "macAddress": "00-0D-3A-1C-4E-2B",
  "powerState": "VM running",
  "privateIpAddress": "10.0.0.4",
  "publicIpAddress": "20.121.44.187",
  "resourceGroup": "rg-az900-svctypes",
  "zones": ""
}
```

2. Count what you now administer:

```bash
az resource list -g "$RG" --query "[].{name:name, type:type}" -o table
```

```
Name                       Type
-------------------------  ------------------------------------------------
vm-iaas-demoVNET           Microsoft.Network/virtualNetworks
vm-iaas-demoNSG            Microsoft.Network/networkSecurityGroups
vm-iaas-demoPublicIP       Microsoft.Network/publicIPAddresses
vm-iaas-demoVMNic          Microsoft.Network/networkInterfaces
vm-iaas-demo               Microsoft.Compute/virtualMachines
vm-iaas-demo_disk1_9f2c…   Microsoft.Compute/disks
```

3. Ask Azure what the guest OS needs. This API exists **only** for IaaS — remember that when you look for its PaaS equivalent in Exercise 3:

```bash
az vm assess-patches -g "$RG" -n vm-iaas-demo -o json
```

```json
{
  "assessmentActivityId": "3f8c1a52-0d47-4c1e-9b6a-77a1f0e2c5d9",
  "availablePatchCountByClassification": {
    "critical": 2,
    "other": 31,
    "security": 9
  },
  "osType": "Linux",
  "rebootPending": false,
  "startDateTime": "2026-09-04T13:02:11.431000+00:00",
  "status": "Succeeded"
}
```

4. Confirm the kernel is yours by touching it from outside:

```bash
az vm run-command invoke \
  -g "$RG" -n vm-iaas-demo \
  --command-id RunShellScript \
  --scripts "uname -r; id; systemctl is-system-running" \
  --query "value[0].message" -o tsv
```

```
Enable succeeded:
[stdout]
6.8.0-1029-azure
uid=0(root) gid=0(root) groups=0(root)
running

[stderr]
```

You are `root`. Nobody at Microsoft is. That is the definition of the IaaS boundary.

5. Now express the same deployment declaratively, so the responsibility surface is visible as code. Save as `iaas.bicep`:

```bicep
targetScope = 'resourceGroup'

@description('Base name used to derive all resource names.')
param baseName string = 'az900svc'

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Admin account created inside the guest OS.')
param adminUsername string = 'azureuser'

@description('SSH public key installed in the guest OS authorized_keys file.')
@secure()
param adminSshPublicKey string

var vnetName   = 'vnet-${baseName}'
var subnetName = 'snet-workload'
var nsgName    = 'nsg-${baseName}'
var pipName    = 'pip-${baseName}'
var nicName    = 'nic-${baseName}'
var vmName     = 'vm-${baseName}'

resource nsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: nsgName
  location: location
  properties: {
    securityRules: [
      {
        name: 'Allow-SSH-Inbound'
        properties: {
          priority: 1000
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '22'
        }
      }
    ]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [ '10.10.0.0/16' ]
    }
    subnets: [
      {
        name: subnetName
        properties: {
          addressPrefix: '10.10.1.0/24'
          networkSecurityGroup: {
            id: nsg.id
          }
        }
      }
    ]
  }
}

resource pip 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: pipName
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource nic 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: nicName
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: '${vnet.id}/subnets/${subnetName}'
          }
          publicIPAddress: {
            id: pip.id
          }
        }
      }
    ]
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: vmName
  location: location
  properties: {
    hardwareProfile: {
      vmSize: 'Standard_B2s'
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: 'ubuntu-24_04-lts'
        sku: 'server'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Premium_LRS'
        }
      }
    }
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      linuxConfiguration: {
        disablePasswordAuthentication: true
        patchSettings: {
          patchMode: 'AutomaticByPlatform'
          assessmentMode: 'AutomaticByPlatform'
        }
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: adminSshPublicKey
            }
          ]
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
        }
      ]
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
      }
    }
  }
}

output publicIp string = pip.properties.ipAddress
output resourcesDeclared int = 5
```

6. Validate it without deploying (a what-if pass costs nothing and changes nothing):

```bash
az deployment group what-if \
  -g "$RG" -f iaas.bicep \
  --parameters adminSshPublicKey="$(cat ~/.ssh/id_rsa.pub)" \
  --no-pretty-print --query "changes[].{type:changeType, id:resourceId}" -o table
```

7. Count the lines of that file, and hold the number: `wc -l iaas.bicep` → `~118`.

**Verify your understanding**

- **Q5.** You set `patchMode: 'AutomaticByPlatform'` and Azure now installs patches for you. Has the operating system moved out of your column in the shared responsibility table? Defend your answer.
- **Q6.** `az vm assess-patches` returned `"critical": 2`. In a PaaS service, which command returns the equivalent figure, and what does that tell you about the abstraction?
- **Q7.** One `az vm create` produced six resources. Name the three of them that are *network controls* and state who owns network controls in the IaaS column.
- **Q8.** `az vm run-command invoke` executed as `uid=0(root)`. Which Azure RBAC permission grants that, and what does its existence prove about the IaaS boundary?
- **Q9.** Give two workload characteristics that make IaaS the correct choice over PaaS, phrased as things PaaS *cannot* do rather than as preferences.

---

## Exercise 3 — PaaS: run the same class of workload with no operating system in your column

1. Create a Basic App Service plan and a Linux web app:

```bash
az appservice plan create \
  -g "$RG" -n plan-paas-demo \
  --sku B1 --is-linux -o table

az webapp create \
  -g "$RG" -p plan-paas-demo \
  -n "app-az900-$SUFFIX" \
  --runtime "PYTHON:3.12" -o table
```

```
AppServicePlan  Location    Name                    State    DefaultHostName
--------------  ----------  ----------------------  -------  -----------------------------------
plan-paas-demo  eastus      app-az900-7b3af10c      Running  app-az900-7b3af10c.azurewebsites.net
```

2. Try to find the machine. Deliberately run the IaaS command against the PaaS app:

```bash
az vm assess-patches -g "$RG" -n "app-az900-$SUFFIX"
```

```
(ResourceNotFound) The Resource 'Microsoft.Compute/virtualMachines/app-az900-7b3af10c'
under resource group 'rg-az900-svctypes' was not found.
```

The resource does not exist because **there is no VM in your subscription for it to be**. Microsoft runs the host; you never see its resource ID.

3. Inspect what you *can* configure. This is the exact surface area of your responsibility in PaaS:

```bash
az webapp config show -g "$RG" -n "app-az900-$SUFFIX" \
  --query "{runtime:linuxFxVersion, workers:numberOfWorkers, alwaysOn:alwaysOn, minTls:minTlsVersion, ftps:ftpsState, http20:http20Enabled}" -o yaml
```

```yaml
alwaysOn: false
ftps: FtpsOnly
http20: false
minTls: '1.2'
runtime: PYTHON|3.12
workers: 1
```

Runtime version, TLS floor, worker count — application and configuration concerns. No kernel, no package manager, no reboot.

4. Open a shell **inside the container** and observe the two things that give the abstraction away:

```bash
az webapp ssh -g "$RG" -n "app-az900-$SUFFIX"
```

```
root@a1b2c3d4e5f6:/# uname -r
6.8.0-1029-azure
root@a1b2c3d4e5f6:/# apt-get install -y nginx
E: Unable to locate package nginx
root@a1b2c3d4e5f6:/# touch /opt/keepme && ls /home
LogFiles  site
root@a1b2c3d4e5f6:/# exit
```

The kernel version you see is the **host's**, patched by Microsoft on Microsoft's schedule; you cannot reboot into a different one. Only `/home` is persistent storage — `/opt/keepme` disappears on the next restart, scale event or platform upgrade.

5. Scale the platform without touching any machine:

```bash
az appservice plan update -g "$RG" -n plan-paas-demo --number-of-workers 3 -o table
az appservice plan show -g "$RG" -n plan-paas-demo --query "{sku:sku.name, capacity:sku.capacity}" -o yaml
```

```yaml
capacity: 3
sku: B1
```

Three instances now exist. You did not provision, image, join, patch or monitor any of them, and none of them appear in `az resource list`.

6. Express the same platform declaratively. Save as `paas.bicep`:

```bicep
targetScope = 'resourceGroup'

@description('Base name used to derive all resource names.')
param baseName string = 'az900svc'

@description('Azure region for all resources.')
param location string = resourceGroup().location

var planName = 'plan-${baseName}'
var siteName = 'app-${baseName}-${uniqueString(resourceGroup().id)}'

resource plan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: planName
  location: location
  kind: 'linux'
  sku: {
    name: 'B1'
    tier: 'Basic'
    capacity: 1
  }
  properties: {
    reserved: true
  }
}

resource site 'Microsoft.Web/sites@2023-12-01' = {
  name: siteName
  location: location
  kind: 'app,linux'
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    siteConfig: {
      linuxFxVersion: 'PYTHON|3.12'
      alwaysOn: true
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      http20Enabled: true
    }
  }
}

output siteHostName string = site.properties.defaultHostName
output resourcesDeclared int = 2
```

7. Compare the two manifests side by side:

```bash
wc -l iaas.bicep paas.bicep
```

```
 118 iaas.bicep
  40 paas.bicep
 158 total
```

Same business capability — serve HTTP. 118 lines versus 40, five declared resources versus two, and one of the two files contains an SSH key you now have to rotate.

**Verify your understanding**

- **Q10.** `az vm assess-patches` failed with `ResourceNotFound` for the web app. Explain, in shared-responsibility terms, why this is the *expected and correct* behaviour rather than a gap in the CLI.
- **Q11.** Inside `az webapp ssh` you saw kernel `6.8.0-1029-azure`. Who patches that kernel, and what happens to your session, your `/opt` writes and your in-flight requests when they do?
- **Q12.** You scaled `plan-paas-demo` to three workers. How many additional entries appeared in `az resource list -g $RG`, and what does that number teach about what "managed" means?
- **Q13.** The `iaas.bicep` file carries an `@secure()` SSH key parameter and `paas.bicep` does not. Map that single difference back to a specific row of the responsibility table.
- **Q14.** Your team needs a specific kernel module loaded and a custom `sysctl` tuning applied. Is App Service still a candidate? Name the service type you must fall back to and one Azure service that provides it.

---

## Exercise 4 — Serverless: PaaS where the billing unit is the giveaway

Serverless is not a fourth service type on the exam — it is PaaS taken to its limit, where you stop paying for allocated capacity and start paying for work performed.

1. Create the storage account a function app requires, then the function app on a Consumption plan:

```bash
az storage account create \
  -g "$RG" -n "stfunc$SUFFIX" \
  -l "$LOC" --sku Standard_LRS \
  --allow-blob-public-access false -o none

az functionapp create \
  -g "$RG" -n "func-az900-$SUFFIX" \
  --storage-account "stfunc$SUFFIX" \
  --consumption-plan-location "$LOC" \
  --runtime python --runtime-version 3.12 \
  --functions-version 4 --os-type Linux -o table
```

2. List the App Service plans in the resource group and look for one you never created:

```bash
az appservice plan list -g "$RG" \
  --query "[].{name:name, sku:sku.name, tier:sku.tier, workers:sku.capacity}" -o table
```

```
Name                     Sku    Tier      Workers
-----------------------  -----  --------  ---------
plan-paas-demo           B1     Basic     3
EastUSLinuxDynamicPlan   Y1     Dynamic   0
```

`Y1` / `Dynamic` with **zero workers**. There is nothing allocated, and therefore nothing to pay for, until an event arrives.

3. Confirm the scale contract:

```bash
az functionapp show -g "$RG" -n "func-az900-$SUFFIX" \
  --query "{sku:sku, state:state, kind:kind}" -o yaml
```

```yaml
kind: functionapp,linux
sku: Dynamic
state: Running
```

4. Contrast the three compute postures you now have running in one resource group:

```bash
az resource list -g "$RG" \
  --query "[?type=='Microsoft.Compute/virtualMachines' || type=='Microsoft.Web/sites' || type=='Microsoft.Web/serverfarms'].{name:name, type:type}" -o table
```

**Verify your understanding**

- **Q15.** The Consumption plan reports `workers: 0` while `state: Running`. Reconcile those two facts, and say what you are billed for in that state.
- **Q16.** A function app on a Consumption plan and a web app on a B1 plan both serve zero requests for 24 hours. Which one costs money, and what does that difference tell you about *allocated capacity* versus *consumed capacity*?
- **Q17.** Serverless removes capacity planning. Name two things it does **not** remove from your responsibility column.
- **Q18.** A batch job runs for 40 minutes at 100% CPU, once a night. Is the Consumption plan the right home for it? Identify the specific platform constraint that decides the answer.

---

## Exercise 5 — SaaS: the workload with no ARM resource at all

The clearest test of SaaS is negative: the product you consume does not appear in your subscription, because you are not renting infrastructure — you are buying seats in someone else's running application.

1. List every resource type your subscription contains and search for a productivity suite:

```bash
az resource list --query "[].type" -o tsv | sort -u | grep -iE 'office|exchange|teams|dynamics' || echo "no SaaS product found in ARM"
```

```
no SaaS product found in ARM
```

2. Ask Microsoft Graph what you actually own. This is where SaaS inventory lives — licences, not resources:

```bash
az rest --method get \
  --url "https://graph.microsoft.com/v1.0/subscribedSkus" \
  --query "value[].{sku:skuPartNumber, enabled:prepaidUnits.enabled, consumed:consumedUnits}" -o table
```

```
Sku                          Enabled    Consumed
---------------------------  ---------  ----------
ENTERPRISEPACK               250        243
EMSPREMIUM                   250        238
POWER_BI_STANDARD            10000      412
```

The unit of purchase is a **user seat**, not a VM-hour or a GB-second.

3. Confirm that the tenant that holds those licences is the same identity plane your IaaS and PaaS resources authenticate against:

```bash
az account show --query "{tenantId:tenantId, subscription:name, user:user.name}" -o yaml
az rest --method get --url "https://graph.microsoft.com/v1.0/organization" \
  --query "value[].{id:id, name:displayName, domain:verifiedDomains[?isDefault].name|[0]}" -o table
```

```
Id                                    Name              Domain
------------------------------------  ----------------  ----------------------
aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee  Contoso Ltd       contoso.onmicrosoft.com
```

One tenant, three service models. That shared tenant is exactly why `Identity and directory infrastructure` is `Shared` and never `Microsoft` in the SaaS column.

4. Find the one control surface SaaS still hands you — conditional access on identity, not on infrastructure:

```bash
az rest --method get \
  --url "https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies" \
  --query "value[].{name:displayName, state:state}" -o table
```

```
Name                                      State
----------------------------------------  --------
Require MFA for all admins                enabled
Block legacy authentication               enabled
Require compliant device for Exchange     enabled
```

You cannot patch Exchange Online. You can decide who reaches it, from what device, under what conditions — `Accounts and identities`, still yours.

**Verify your understanding**

- **Q19.** Microsoft 365 produced zero rows in `az resource list` but real rows in `subscribedSkus`. State the general rule this illustrates about how SaaS is inventoried and billed.
- **Q20.** In the SaaS column, `Applications`, `Network controls` and `Operating system` are all Microsoft's. Name the three rows that are still entirely yours, and give one Azure/Entra control you exercised in this exercise for each.
- **Q21.** Your organisation must retain mailbox data for seven years for a regulator. Whose responsibility is that retention policy, and which row of the table settles it?
- **Q22.** A vendor pitches "a SaaS product you deploy into your own subscription and patch yourself." Using the criteria from this exercise, argue whether that is SaaS, and what it actually is.

---

## Exercise 6 — Rapid classification drill by resource provider

Resource providers are the machine-readable fingerprint of a service. This drill trains the exam reflex of classifying an unfamiliar service name in under five seconds.

1. Dump the registered providers in your subscription:

```bash
az provider list --query "[?registrationState=='Registered'].namespace" -o tsv | sort
```

```
Microsoft.Compute
Microsoft.ContainerService
Microsoft.DBforPostgreSQL
Microsoft.Insights
Microsoft.KeyVault
Microsoft.Network
Microsoft.Sql
Microsoft.Storage
Microsoft.Web
```

2. For each service below, write `IaaS`, `PaaS` or `SaaS` **before** reading any answer. Then justify each with the row of the responsibility table that decided it:

| # | Service | Your call | Deciding row |
|---|---|---|---|
| a | Azure Virtual Machines | | |
| b | Azure SQL Database | | |
| c | SQL Server on Azure Virtual Machines | | |
| d | Azure SQL Managed Instance | | |
| e | Azure Blob Storage | | |
| f | Azure App Service | | |
| g | Microsoft 365 | | |
| h | Azure Kubernetes Service (AKS) | | |
| i | Azure Virtual Desktop | | |
| j | Dynamics 365 | | |
| k | Azure Functions (Consumption) | | |
| l | Microsoft Intune | | |

3. Check the family resemblance: run `az provider show -n Microsoft.Sql --query "resourceTypes[?resourceType=='servers/databases'].locations | [0] | length(@)"` and note that a PaaS database exposes *regions*, never *hosts*.

**Verify your understanding**

- **Q23.** Items (b), (c) and (d) are all "SQL on Azure". Order them from most to least customer responsibility and state exactly what you gain and lose at each step.
- **Q24.** AKS is the classic trap. Give the answer the exam expects, then give the honest engineering nuance about the control plane versus the node pools.
- **Q25.** Azure Virtual Desktop delivers Windows desktops to users. Argue the case for classifying it as PaaS and the case for SaaS, then say which classification the AZ-900 study guide supports.

---

## Exercise 7 — Billing-unit forensics with the Retail Prices API

If you can name the unit a service bills in, you can name its service type. This exercise uses the public, unauthenticated Azure Retail Prices API — no subscription, no cost.

1. Ask what a VM costs:

```bash
curl -s -G 'https://prices.azure.com/api/retail/prices' \
  --data-urlencode "\$filter=armRegionName eq 'eastus' and serviceName eq 'Virtual Machines' and armSkuName eq 'Standard_B2s' and priceType eq 'Consumption'" \
  | jq -r '.Items[] | [.meterName, .unitOfMeasure, .retailPrice] | @tsv' | column -t
```

```
B2s               1 Hour  0.0416
B2s Low Priority  1 Hour  0.0083
B2s Spot          1 Hour  0.0083
```

2. Ask what the PaaS plan costs:

```bash
curl -s -G 'https://prices.azure.com/api/retail/prices' \
  --data-urlencode "\$filter=armRegionName eq 'eastus' and serviceName eq 'Azure App Service' and skuName eq 'B1' and priceType eq 'Consumption'" \
  | jq -r '.Items[] | [.productName, .meterName, .unitOfMeasure, .retailPrice] | @tsv' | column -t
```

```
Azure App Service Basic Plan - Linux  B1 App  1 Hour  0.0130
```

3. Ask what serverless costs:

```bash
curl -s -G 'https://prices.azure.com/api/retail/prices' \
  --data-urlencode "\$filter=armRegionName eq 'eastus' and serviceName eq 'Functions' and priceType eq 'Consumption'" \
  | jq -r '.Items[] | [.meterName, .unitOfMeasure, .retailPrice] | @tsv' | column -t
```

```
Standard Execution Time    10 GB Second   0.000016
Standard Total Executions  10 Executions  0.000002
```

4. Write the three units in a column and add the fourth from Exercise 5:

```
IaaS        → 1 Hour of an allocated machine, running or idle
PaaS        → 1 Hour of an allocated plan, running or idle
Serverless  → GB-second of memory actually used + per execution
SaaS        → 1 user seat per month  (subscribedSkus.prepaidUnits.enabled)
```

> Retail prices change continuously and vary by region and currency; treat the numbers above as shape, not as quotes. The exam never tests a price — it tests which of the four *units* applies.

**Verify your understanding**

- **Q26.** The B2s VM and the B1 App Service plan both bill per hour. If the billing unit is identical, what actually differs between them, and where does that difference show up on an invoice at the end of a bad quarter?
- **Q27.** A workload receives 30 requests per day, each finishing in 200 ms. Using the units above, argue for the cheapest of the three compute options and name the failure mode of choosing the B1 plan instead.
- **Q28.** SaaS bills per seat. What happens to your SaaS bill when traffic to the product triples but headcount stays flat, and what does that reveal about who absorbed the capacity risk?

---

## Exercise 8 — The diagnostics ladder: where the logs live in each model

Your troubleshooting entry point is determined by your service type. Getting this wrong wastes the first thirty minutes of every incident.

1. **IaaS** — you get the console, because you own the machine:

```bash
az vm boot-diagnostics get-boot-log -g "$RG" -n vm-iaas-demo | tail -5
```

```
[    3.482119] cloud-init[812]: Cloud-init v. 24.1.3 finished at ...
Ubuntu 24.04.3 LTS vm-iaas-demo ttyS0

vm-iaas-demo login:
```

2. **PaaS** — you get the application's stdout, not the machine's:

```bash
az webapp log config -g "$RG" -n "app-az900-$SUFFIX" \
  --application-logging filesystem --level information -o none

az webapp log tail -g "$RG" -n "app-az900-$SUFFIX" --provider application
```

```
2026-09-04T13:44:07  Starting container for site
2026-09-04T13:44:09  Initiating warmup request to container app-az900-7b3af10c_0_9f2c1a3b
2026-09-04T13:44:21  Container app-az900-7b3af10c_0_9f2c1a3b for site is running
```

There is no boot log. There is no `dmesg`. If the host misbehaves, you do not debug it — you file against the platform.

3. **Platform-side faults, any model** — Resource Health tells you when the problem is Microsoft's:

```bash
SUB=$(az account show --query id -o tsv)
az rest --method get \
  --url "https://management.azure.com/subscriptions/$SUB/providers/Microsoft.ResourceHealth/events?api-version=2022-10-01&\$filter=properties/eventType eq 'ServiceIssue'" \
  --query "value[0:5].{title:properties.title, status:properties.status, impact:properties.impactStartTime}" -o table
```

4. **SaaS** — there is no API in your subscription at all. The signal lives in the Microsoft 365 admin centre under **Health → Service health**, and in the Message centre for change notices. Confirm the asymmetry: nothing you ran in steps 1–3 can tell you that Exchange Online is degraded.

**Verify your understanding**

- **Q29.** Rank IaaS, PaaS and SaaS by how much diagnostic data the platform exposes to you, and explain why that ranking is the exact inverse of the operational burden ranking.
- **Q30.** An App Service app returns HTTP 503. List, in order, the two places you check and the one place you *cannot* check, naming the responsibility row that closes off the third.
- **Q31.** Users report that Teams is failing. Your Azure Service Health blade is all green. Explain why both facts can be true simultaneously.

---

## Exercise 9 — Use-case decision drill (exam-shaped)

For each scenario, write the service type, the deciding constraint, and one concrete Azure service. Answer without re-reading the earlier exercises.

1. A hospital runs a 15-year-old clinical application that requires Windows Server 2012 R2, a specific ODBC driver installed system-wide, and a licensed kernel-mode agent from the vendor. It must move off dying hardware in six weeks with no code changes.
2. A payroll team of 400 needs email, documents and video meetings by the end of next month. There is no IT operations staff.
3. A development team wants to publish a Python REST API, deploy from GitHub on every merge, run staging and production side by side, and never talk about servers.
4. An IoT platform receives a message roughly every 90 seconds, and must run a 300 ms validation routine on each. Traffic is zero overnight.
5. A regulated bank must keep the database engine on a version frozen at 15.4 for the next 18 months, with the ability to attach a third-party auditing agent to the database process.
6. A CRM rollout for a 2,000-person sales organisation, with per-user licensing and no infrastructure budget line.
7. A research group needs 200 GPU nodes for eleven days to train a model, with full control of CUDA driver versions, then wants to release everything.

**Verify your understanding**

- **Q32.** Which scenarios are IaaS, and what single word appears in each of their descriptions that forces the answer?
- **Q33.** Scenario 3 and scenario 4 are both PaaS. What distinguishes the right *plan* for each, and which billing unit follows from it?
- **Q34.** Scenario 5 says "frozen at 15.4" and "attach an agent to the database process." Which of those two phrases alone would already rule out a fully managed database, and why?
- **Q35.** Rewrite scenario 1 as a set of requirements that would make PaaS viable, and estimate what that rewrite costs the hospital that lift-and-shift does not.
- **Q36.** A stakeholder asks for "the cheapest option" across all seven. Explain why service type, not price, is the first filter, and give the correct sequence of questions to ask instead.

---

## Exercise 10 — Cleanup and cost verification

1. Confirm what is still running and what it is costing you per hour:

```bash
az resource list -g "$RG" --query "length(@)"
az vm list -d -g "$RG" --query "[].{name:name, power:powerState}" -o table
az appservice plan list -g "$RG" --query "[].{name:name, sku:sku.name, capacity:sku.capacity}" -o table
```

2. Note the trap: deallocating the VM stops compute charges but **not** disk or public IP charges.

```bash
az vm deallocate -g "$RG" -n vm-iaas-demo -o none
az vm list -d -g "$RG" --query "[].{name:name, power:powerState}" -o table
```

```
Name           Power
-------------  -------------
vm-iaas-demo   VM deallocated
```

```bash
az disk list -g "$RG" --query "[].{name:name, sizeGb:diskSizeGb, sku:sku.name}" -o table
```

```
Name                                          SizeGb    Sku
--------------------------------------------  --------  -----------
vm-iaas-demo_disk1_9f2c1a3b…                  30        Premium_LRS
```

Still billed. This is `IaaS` in one line: resources you allocated stay allocated until you say otherwise.

3. Delete everything:

```bash
az group delete --name "$RG" --yes --no-wait
az group exists --name "$RG"
```

```
true
```

(`--no-wait` returns immediately; re-run `az group exists` after a few minutes until it returns `false`.)

4. Verify the SaaS side needs no cleanup, and understand why:

```bash
az rest --method get --url "https://graph.microsoft.com/v1.0/subscribedSkus" \
  --query "value[].skuPartNumber" -o tsv
```

The licences are unaffected by anything you did in ARM. Different plane, different lifecycle, different bill.

**Verify your understanding**

- **Q37.** A deallocated VM still generated charges. Name the two resource types responsible and explain which service model makes this class of surprise structurally possible.
- **Q38.** Deleting the resource group removed all IaaS and PaaS artefacts but changed nothing about your Microsoft 365 licences. State the general principle about SaaS lifecycle that this proves.

---

<details>
<summary><strong>Answers</strong></summary>

### Exercise 1 — Responsibility ladder

**A1.** `Information and data`, `Devices (mobile and PCs)`, and `Accounts and identities` are always the customer's, in every model. A provider cannot own them because it cannot know the semantics: only you know which records are regulated, which employee should still have access after they change teams, and which laptop belongs to a contractor. These are business decisions expressed as configuration, not infrastructure Microsoft can operate on your behalf. Physical hosts, physical network and physical datacenter are the mirror image — always Microsoft's in all three cloud columns, and the customer's only on-premises.

**A2.** `Operating system`. It is Microsoft's in SaaS and PaaS, and the customer's in IaaS. The Tuesday-morning consequence: with IaaS, a published CVE means *you* run the assessment, schedule the maintenance window, install the package, reboot the guest and verify the fleet — measured in engineer-hours proportional to VM count. With PaaS, the same CVE means Microsoft rolls the underlying image and you may not even receive a notification. That single row is where most of the operational cost difference between IaaS and PaaS actually lives.

**A3.** Microsoft operates the Entra ID service itself — the directory's availability, replication, token issuance, the authentication protocol implementations, and the physical and logical security of the directory infrastructure. You configure what runs on it: tenant settings, group and role assignments, conditional access policies, MFA enforcement, application registrations, external-collaboration rules, and lifecycle for joiners/movers/leavers. Microsoft guarantees the directory answers; you determine what it answers *yes* to.

**A4.** `Information and data` is the customer's in **every** column, SaaS included. Microsoft guarantees the platform's availability and durability, not the correctness or survival of your content: a user who deletes a mailbox item, a script that overwrites a SharePoint library, or a ransomware actor with valid credentials are all inside your responsibility row. Retention, backup beyond the platform's default windows, classification and recovery policy remain yours regardless of the service model.

### Exercise 2 — IaaS

**A5.** No. Automation changes *who performs the action*, not *who is accountable for the outcome*. You chose the patch mode, you own the reboot policy and its blast radius, you own the regression when a patch breaks the application, and you own the compliance evidence that the patch landed. `AutomaticByPlatform` is Azure operating a control **inside your responsibility column at your instruction** — it is not a transfer of the row. The proof is that `az vm assess-patches` still exists and still returns *your* pending count; nobody at Microsoft is on the hook for that number reaching zero.

**A6.** There is none. No PaaS equivalent of `az vm assess-patches` exists, and that absence is the abstraction working correctly rather than a missing feature: guest OS patch state is not a customer-visible property of a PaaS service, because the guest OS is not in your responsibility column. When a command has no PaaS counterpart, that is usually a reliable signal that the concern it addresses has moved to the provider.

**A7.** `vm-iaas-demoVNET` (`Microsoft.Network/virtualNetworks`), `vm-iaas-demoNSG` (`Microsoft.Network/networkSecurityGroups`) and `vm-iaas-demoPublicIP` (`Microsoft.Network/publicIPAddresses`); the NIC is arguably a fourth. `Network controls` is **Customer** in the IaaS column — which is exactly why the CLI created an NSG whose rules you must now review, and why `--nsg-rule SSH` opening port 22 to `Internet` is your risk to accept or narrow, not Azure's.

**A8.** `Microsoft.Compute/virtualMachines/runCommand/action`, carried by roles such as Virtual Machine Contributor and Contributor. Its existence proves the IaaS boundary sits below the OS: an Azure control-plane permission grants unmediated root execution inside the guest, because the guest is your property. There is no analogous control-plane permission that grants root on an App Service host — because that host is not yours. It also makes an important security point: control-plane RBAC on IaaS is effectively data-plane access to the machine.

**A9.** Any two of:
- **You must control the kernel or load kernel-mode code** — drivers, GPU/CUDA versions, kernel modules, `sysctl` tuning, licensed vendor agents that run in kernel space. PaaS cannot express this; there is no kernel in your column to modify.
- **The software cannot be re-platformed** — legacy Windows versions, MSI installers with system-wide side effects, applications requiring a specific machine identity, hard-coded local paths, or COM/GAC registration.
- **You need lift-and-shift with no code change under a deadline** — PaaS requires the application to fit the platform's runtime, filesystem and lifecycle contract; changing the app is a project, and IaaS is the option that does not require one.

### Exercise 3 — PaaS

**A10.** The command failed because there is no `Microsoft.Compute/virtualMachines` resource backing the web app *in your subscription*. Compute for App Service is drawn from a Microsoft-operated multi-tenant fleet that is not projected into your resource graph. Since `Operating system` is Microsoft's in the PaaS column, patch state is not a property you are entitled to query — and a `ResourceNotFound` is the API correctly declining to expose something outside your responsibility boundary. A CLI gap would look like an unimplemented command; this looks like an absent resource, which is the semantically accurate answer.

**A11.** Microsoft patches it, on Microsoft's schedule, without asking you. When they do, your SSH session terminates, everything you wrote outside `/home` is gone (only `/home` is backed by persistent shared storage; the rest of the container filesystem is ephemeral), and in-flight requests are drained to another instance — which is precisely why `alwaysOn`, multiple workers and stateless application design are not optional niceties on App Service but requirements of the platform contract. Design consequence: never store session state, uploads or caches on the local container filesystem.

**A12.** Zero. `az resource list` still shows the same `Microsoft.Web/serverfarms` and `Microsoft.Web/sites` entries; only `sku.capacity` changed from 1 to 3. "Managed" means the platform's units of execution are not modelled as resources in your subscription: you declare an intent (`capacity: 3`) and Microsoft satisfies it with machines you never name, never patch, never monitor and never see. Contrast Exercise 2, where a single VM produced six addressable resources you must now govern.

**A13.** `Operating system`. An SSH key exists only because there is a guest OS with a login, an `authorized_keys` file and an account lifecycle — all in your column under IaaS. Because the OS is Microsoft's under PaaS, no host credential exists for you to hold, distribute, store in Key Vault, rotate on schedule, or leak. The `@secure()` parameter in `iaas.bicep` is the responsibility table showing up as a line of code, and its absence in `paas.bicep` is an entire class of credential-management work that PaaS deletes.

**A14.** No. Kernel modules and `sysctl` tuning require control of the operating system, which App Service does not give you. Fall back to **IaaS** — Azure Virtual Machines, or Virtual Machine Scale Sets if you need the elasticity you would be giving up. (Azure Kubernetes Service is a partial middle ground, since you control the node pools' VMs and can apply node-level configuration via a DaemonSet or custom node image, but you have then re-accepted the OS row for those nodes.)

### Exercise 4 — Serverless

**A15.** `state: Running` describes the *application's* readiness to accept events — its triggers are registered and the platform is listening. `workers: 0` describes *allocated compute*, which is genuinely nothing while idle. You are billed only for the storage account backing the function app and for whatever executions occur; the compute meter stays at zero. This is the defining property of serverless: capacity is a consequence of demand, not a prerequisite for it.

**A16.** The B1 web app costs money — roughly USD 0.013/hour × 24, incurred whether or not a single request arrives. The Consumption function app costs effectively nothing beyond its storage account. The B1 plan bills **allocated capacity** (you reserved a machine's worth of platform and it stood ready); the Consumption plan bills **consumed capacity** (GB-seconds actually executed plus execution count). Idle is free in one model and full price in the other, which is why request shape — not request volume — usually decides between them.

**A17.** Any two of: application code correctness and its dependency supply chain; `Information and data` (what the function reads, writes and logs); `Accounts and identities` (its managed identity and the RBAC you grant it); secrets and configuration handling; and cost governance — serverless removes capacity planning but introduces *concurrency* planning, since an unbounded event source scales your bill linearly with no ceiling unless you set one.

**A18.** Probably not on Consumption. The deciding constraint is the Consumption plan's execution timeout: 5 minutes by default, raisable to a hard maximum of 10 minutes. A 40-minute job cannot complete. Correct answers are to decompose it into durable, resumable steps (Durable Functions), or to move to a plan without that ceiling (Premium or Dedicated/App Service plan), or to use a batch-oriented service. A secondary constraint also disqualifies it: a nightly job at 100% CPU for 40 minutes is *predictable* load, and predictable sustained load is where allocated-capacity pricing beats per-GB-second pricing.

### Exercise 5 — SaaS

**A19.** SaaS is inventoried as **entitlements in a directory**, not as resources in a subscription, and billed per **user seat per month**, not per unit of infrastructure-time. The general rule: if a service appears in your ARM resource graph, you are renting infrastructure or a platform and you hold some operational responsibility for it; if it appears only as a licence assigned to identities, you are buying access to an application someone else runs entirely.

**A20.** `Information and data`, `Devices (mobile and PCs)`, `Accounts and identities`.
- *Accounts and identities* → the conditional access policies you listed ("Require MFA for all admins", "Block legacy authentication"), plus role assignment and joiner/mover/leaver lifecycle in the tenant.
- *Devices* → the "Require compliant device for Exchange" policy, backed by device compliance rules in Intune.
- *Information and data* → retention, sensitivity labelling, DLP and eDiscovery policy — none of which Microsoft chooses for you, all of which you configure in the tenant.

**A21.** Yours. `Information and data` is the customer's in the SaaS column without exception. Microsoft guarantees the mailbox service is available and durable; it does not guarantee that a seven-year retention obligation is met, because it does not know the obligation exists. You configure retention policies, retention labels and litigation hold, and you own the evidence that they were applied. The row settles it: nothing about SaaS moves data governance to the provider.

**A22.** It is not SaaS. Deploying into your subscription means it materialises as ARM resources you own; patching it yourself means `Operating system` and/or `Applications` are in your column. That is a **vendor-provided application delivered as IaaS or PaaS** — commonly a marketplace VM image, a managed application, or a container offering. The commercial packaging may be subscription-based, but the *service type* is determined by where the responsibility boundary sits, never by how the invoice is worded. Practical test: ask who applies the next critical patch, and whether the product appears in `az resource list`.

### Exercise 6 — Classification drill

| # | Service | Type | Deciding row |
|---|---|---|---|
| a | Azure Virtual Machines | **IaaS** | `Operating system` = Customer |
| b | Azure SQL Database | **PaaS** | OS *and* engine managed; you own schema and data |
| c | SQL Server on Azure VMs | **IaaS** | You install, patch and licence the engine and the OS |
| d | Azure SQL Managed Instance | **PaaS** | Managed engine with near-full instance surface; still no OS access |
| e | Azure Blob Storage | **PaaS** | Consumed via API; no OS, no capacity to provision |
| f | Azure App Service | **PaaS** | `Operating system` = Microsoft; you own the app |
| g | Microsoft 365 | **SaaS** | `Applications` = Microsoft; per-seat licence, no ARM resource |
| h | Azure Kubernetes Service | **PaaS** | Managed control plane (see A24 for the nuance) |
| i | Azure Virtual Desktop | **PaaS** | Managed brokering/gateway; you still own the session-host OS |
| j | Dynamics 365 | **SaaS** | Finished business application, per-seat licence |
| k | Azure Functions (Consumption) | **PaaS** (serverless) | Managed platform; billed per execution, not per hour |
| l | Microsoft Intune | **SaaS** | Finished management application consumed via the cloud |

**A23.** Most → least customer responsibility: **(c) SQL Server on Azure VMs → (d) SQL Managed Instance → (b) Azure SQL Database.**
- *(c) → (d)*: you give up the guest OS, engine installation, patching, and backup plumbing. You gain automated patching, built-in HA and automated backups. You lose OS-level access, the ability to pin an exact engine build indefinitely, and the ability to install anything on the host.
- *(d) → (b)*: you give up instance-scoped features (SQL Agent, cross-database queries, CLR, Service Broker, some DBCC surface). You gain the simplest operational model, serverless and elastic-pool tiers, and finer-grained scaling. You lose instance-level compatibility, which is exactly what makes Managed Instance the usual landing zone for a lift-and-shift.

**A24.** **Exam answer: PaaS.** The nuance: the AKS control plane (API server, scheduler, etcd) is fully managed by Microsoft, does not appear as a VM in your subscription, and is not something you patch — unambiguously PaaS. The **node pools**, however, are VM Scale Sets that live in a node resource group in your subscription; you choose their VM size and OS SKU, and you initiate node image upgrades and Kubernetes version upgrades. So the `Operating system` row is Microsoft's for the control plane and effectively shared-to-customer for the nodes. AZ-900 does not test that split — it tests "managed Kubernetes service" → PaaS. Know both, answer PaaS.

**A25.** *Case for PaaS*: Microsoft manages the brokering, gateway, web client, diagnostics and load-balancing infrastructure, but **you** supply, image, patch, licence and monitor the session-host VMs, which are ordinary IaaS VMs in your subscription — the OS row is firmly yours. *Case for SaaS*: the end user experiences a finished desktop application delivered over the network with nothing to install, which is the SaaS user experience. **The AZ-900 study guide supports PaaS**: the customer-managed session hosts are decisive, and a true SaaS product would never leave you a VM to patch. Windows 365 Cloud PC, by contrast, *is* the SaaS-shaped answer in this space.

### Exercise 7 — Billing units

**A26.** The unit is the same; what differs is **what you must do to keep the hour productive**. The VM hour buys raw capacity that only becomes useful after you image, patch, harden, monitor and secure the OS — labour that never appears on the Azure invoice but appears on the payroll one. The App Service hour buys the same capacity with those tasks already performed. At the end of a bad quarter the difference surfaces as: unpatched VMs in the compliance report, engineer-hours consumed by maintenance windows, and — the classic one — orphaned VMs, disks and public IPs from projects nobody deallocated, because IaaS resources persist until explicitly removed.

**A27.** 30 requests × 200 ms ≈ **6 seconds of compute per day**. On the Consumption plan you pay for roughly 6 GB-seconds plus 30 executions — small fractions of a cent per month. On the B1 plan you pay ~0.013 × 730 ≈ **USD 9.50/month for 3 minutes of work per year**, a utilisation of well under 0.01%. The failure mode of choosing B1 is not a technical fault but a structural one: you have bought allocated capacity for a consumption-shaped workload, and the mismatch compounds with every additional low-traffic service that gets its own plan. (The counter-argument for B1 is latency: Consumption cold starts add hundreds of milliseconds to the first request after idle. If that matters, the answer is the Premium plan, not B1.)

**A28.** Nothing — the bill is flat, because it is a function of headcount, not load. That reveals that in SaaS the provider has absorbed **all** capacity risk: Microsoft sizes, scales and pays for the infrastructure behind Exchange Online whether your users send 100 or 100,000 messages. It is the strongest financial argument for SaaS and also its main constraint, since you cannot optimise a bill that is not driven by consumption — the only lever is licence count and licence tier.

### Exercise 8 — Diagnostics

**A29.** Most to least exposed: **IaaS → PaaS → SaaS**. IaaS gives you the serial console, boot diagnostics, kernel logs, full guest telemetry and root shell. PaaS gives you application logs, platform lifecycle events and metrics — but no host. SaaS gives you a status page and a message centre. The ranking is the inverse of operational burden because access and accountability are the same thing: you are shown exactly the layers you are responsible for repairing. Anything below your responsibility boundary is invisible precisely because fixing it is not your job — and being shown data you cannot act on would be a liability, not a feature.

**A30.** (1) Application logs — `az webapp log tail`, plus Application Insights if instrumented; a 503 is most often your process failing to start, failing its warmup probe, or exhausting workers. (2) Platform state — `az webapp show` for site state, deployment/slot swap history, quota exhaustion on the plan, and Azure Service Health / Resource Health for a platform incident. What you *cannot* check is the host operating system: no `dmesg`, no boot log, no host metrics. `Operating system` is Microsoft's in the PaaS column, so if the fault is genuinely below the container the only correct action is to escalate to Microsoft, not to investigate further.

**A31.** They monitor different planes. Azure Service Health reports on **Azure** services scoped to your subscriptions and regions — the IaaS/PaaS resources you own. Microsoft Teams is a Microsoft 365 SaaS service whose health is reported in the **Microsoft 365 admin centre → Health → Service health**, and in the Microsoft 365 Service health API, scoped to your tenant rather than your subscription. Green in Azure says nothing about Microsoft 365, which is one more consequence of SaaS living entirely outside your resource graph: even its incident reporting is on the other side of the boundary.

### Exercise 9 — Use-case decisions

**A32.** Scenarios **1, 5 and 7** are IaaS. The forcing words are the ones that name something *below the application*: "installed system-wide" and "kernel-mode agent" (1); "frozen at 15.4" and "attach a third-party agent to the database process" (5); "full control of CUDA driver versions" (7). Whenever a requirement names the operating system, a driver, a kernel component, or an exact engine build the customer must pin, the `Operating system` row has been claimed by the customer, and PaaS is out. Scenarios **3 and 4** are PaaS (App Service; Azure Functions on Consumption). Scenarios **2 and 6** are SaaS (Microsoft 365; Dynamics 365).

**A33.** Scenario 3 is a continuously-served API with staging and production side by side: it wants an **App Service plan** (Standard tier or above for deployment slots), billed **per hour of allocated plan**, with the plan cost amortised across steady traffic. Scenario 4 is sparse, event-driven, 300 ms of work per event with idle nights: it wants **Functions on the Consumption plan**, billed **per GB-second plus per execution**, so overnight idle costs nothing. Same service type, opposite billing units — the request shape decides, not the technology.

**A34.** "Attach a third-party auditing agent to the database process" is the harder disqualifier on its own: it requires loading foreign code into the engine's process space, and no fully managed database permits that, in any tier. "Frozen at 15.4 for 18 months" is severe but not always fatal — managed database services do offer version-pinning windows, and 18 months may fall inside a supported major-version lifecycle. The agent requirement admits no configuration that satisfies it, so it alone forces IaaS (or a managed offering with an explicitly supported extension mechanism, which must be verified rather than assumed).

**A35.** A PaaS-viable rewrite: replace the vendor's kernel-mode agent with a supported userspace or API-based equivalent; remove the system-wide ODBC driver dependency by moving to a supported managed database connector; recompile the application against a supported runtime on a current OS; externalise all state to managed storage so instances can be replaced at will; and remove any assumption of local disk persistence or fixed machine identity. The cost that lift-and-shift does not incur: a re-platforming project measured in months rather than the stated six weeks, vendor re-certification of a 15-year-old clinical application, and — in a hospital context — clinical revalidation of a modified system. This is the whole reason IaaS continues to exist: sometimes the correct engineering answer is the one that ships before the hardware dies, and re-platforming is a decision to be scheduled deliberately rather than forced by a migration deadline.

**A36.** Because price only compares options that are actually viable, and service type is what determines viability. Costing a PaaS option for scenario 5 produces a cheap number for a solution that cannot run the required agent — a comparison of one real option against one fictional one. The correct sequence: **(1)** What must the workload control below the application — OS, drivers, engine build? That eliminates service types. **(2)** What is the load shape — steady, spiky, or sparse? That chooses the billing unit within the surviving type. **(3)** What operational capacity does the team actually have? That weights managed against self-managed. **(4)** *Only now*, what does it cost — including the engineer-hours the earlier answers implied, not just the Azure invoice.

### Exercise 10 — Cleanup

**A37.** `Microsoft.Compute/disks` (the Premium_LRS managed OS disk) and `Microsoft.Network/publicIPAddresses` (a Standard SKU static IP, billed whether or not it is attached to a running machine). Deallocating releases the compute allocation only. This class of surprise is structurally an **IaaS** phenomenon: IaaS decomposes a machine into independently-lifecycled resources that you allocated and that therefore persist until you explicitly delete them. PaaS and SaaS have no equivalent — deleting an App Service plan removes everything it billed for, and SaaS has no allocated artefacts at all. It is the direct financial expression of "you manage the infrastructure."

**A38.** SaaS entitlements live in the **Microsoft Entra tenant**, not in an Azure subscription, and the two have independent lifecycles. A subscription can be created, emptied, or cancelled without affecting a single licence; equally, licences continue to bill until you reduce the seat count in the licensing portal, no matter what you delete in ARM. The general principle: SaaS is decommissioned by changing entitlements and identities, IaaS and PaaS by deleting resources — and confusing the two is how organisations end up paying for seats long after the project that needed them was torn down.

</details>

---

## Sources

- AZ-900 study guide (exam objectives, version 2026-07-20) — <https://learn.microsoft.com/en-us/credentials/certifications/resources/study-guides/az-900>
- Describe cloud service types (Microsoft Learn training module) — <https://learn.microsoft.com/en-us/training/modules/describe-cloud-service-types/>
- Shared responsibility in the cloud — <https://learn.microsoft.com/en-us/azure/security/fundamentals/shared-responsibility>
- Azure services and their resource providers — <https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/azure-services-resource-providers>
- `az vm` command reference (including `az vm assess-patches`, `az vm run-command`) — <https://learn.microsoft.com/en-us/cli/azure/vm>
- Azure App Service overview and hosting plans — <https://learn.microsoft.com/en-us/azure/app-service/overview-hosting-plans>
- App Service Linux container filesystem and persistent `/home` — <https://learn.microsoft.com/en-us/azure/app-service/operating-system-functionality>
- Azure Functions Consumption plan (scaling, timeouts, billing) — <https://learn.microsoft.com/en-us/azure/azure-functions/consumption-plan>
- Azure Functions scale and hosting comparison — <https://learn.microsoft.com/en-us/azure/azure-functions/functions-scale>
- Azure Retail Prices API — <https://learn.microsoft.com/en-us/rest/api/cost-management/retail-prices/azure-retail-prices>
- Microsoft Graph `subscribedSkus` (list) — <https://learn.microsoft.com/en-us/graph/api/subscribedsku-list?view=graph-rest-1.0>
- Azure Update Manager overview — <https://learn.microsoft.com/en-us/azure/update-manager/overview>
- Azure Service Health overview — <https://learn.microsoft.com/en-us/azure/service-health/overview>
- View Microsoft 365 service health — <https://learn.microsoft.com/en-us/microsoft-365/enterprise/view-service-health>
- Azure Kubernetes Service introduction — <https://learn.microsoft.com/en-us/azure/aks/what-is-aks>
- Azure Virtual Desktop overview — <https://learn.microsoft.com/en-us/azure/virtual-desktop/overview>
- Azure SQL deployment options compared — <https://learn.microsoft.com/en-us/azure/azure-sql/azure-sql-iaas-vs-paas-what-is-overview>