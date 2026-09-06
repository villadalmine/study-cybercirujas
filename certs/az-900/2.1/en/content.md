# 2.1 Describe the core architectural components of Azure

**Exam:** AZ-900 (2026-07-20) · **Domain weight:** 9.62 % · **Profile:** SRE / Platform Architect

---

## 1. The production problem this topic actually solves

Every incident review that ends with "the whole environment went down together" is a failure-domain problem, and every incident review that ends with "we could not stop the change from reaching production" is a scope problem. Azure's architectural components are the two answers:

- **Physical hierarchy** — *geography → region → availability zone → datacenter → fault/update domain* — defines what fails **together**.
- **Logical hierarchy** — *Entra ID tenant → management group → subscription → resource group → resource* — defines what is **governed, billed, throttled and deleted** together.

These two trees are orthogonal. A resource group can hold resources in seven regions; a region can hold resources from ten thousand subscriptions. Almost every real Azure design mistake comes from collapsing them into one mental model.

Three failure modes you will meet in production, all of which are pure topic-2.1 material:

1. **The logical zone lie.** Zone `1` in subscription A is *not* the same physical datacenter as zone `1` in subscription B. Two teams "spread across zones 1 and 2" can be sitting in the same physical zone. Azure exposes the mapping through the Locations API; almost nobody reads it.
2. **The resource group metadata trap.** A resource group's `location` stores its ARM metadata. If that region's control plane is degraded, you cannot create, update or delete resources in that resource group — *even if every resource inside it lives in a healthy region*. Your DR runbook fails at the point where it needs ARM most.
3. **The subscription as a throttle domain.** ARM enforces read/write budgets per subscription (and per resource provider). A noisy CI pipeline in the same subscription as production will 429 your autoscaler. The blast radius of a `for` loop is a subscription.

Everything below is written to make those three failures diagnosable in under five minutes.

---

## 2. The physical hierarchy

### 2.1 Geography → region → zone → datacenter

| Layer | What it is | Blast radius | Customer-selectable | Compliance meaning |
|---|---|---|---|---|
| **Geography** | Discrete market containing ≥ 2 regions (e.g. *United States*, *Europe*, *Brazil*) | Never fails as a unit | No (implied by region) | Data-residency and sovereignty boundary |
| **Region** | Set of datacenters within a latency-defined perimeter, deployed as one capacity/API unit | Correlated: shared regional control plane, shared power grid region | **Yes** — the primary deployment decision | Residency guarantee, pricing unit |
| **Availability Zone (AZ)** | One or more datacenters with **independent** power, cooling and networking inside a region | Independent by design | Yes, for *zonal* services | None — same region, same residency |
| **Datacenter** | Physical building | Not exposed | No | — |
| **Fault domain (FD)** | Rack-level: shared power + top-of-rack switch | Rack | Indirectly (availability sets / VMSS) | — |
| **Update domain (UD)** | Group rebooted together during platform maintenance | Planned maintenance only | Indirectly | — |

Key hard numbers from Microsoft's own documentation:

- Azure operates **60+ regions across 300+ datacenters**, more than any other cloud provider.
- A region with zones has **a minimum of three** availability zones.
- Inter-zone round-trip network latency inside a region is **under 2 ms**.
- Paired regions are, where geography allows, **at least 300 miles (~480 km) apart**.

### 2.2 Zonal vs zone-redundant — the distinction the exam under-tests and production over-punishes

| Model | Placement | Failure behaviour | Typical services | SRE cost |
|---|---|---|---|---|
| **Zonal (pinned)** | You pin the instance to zone `1`, `2` or `3` | Zone loss = instance loss. **You** must run N instances across N zones and load-balance | VM, managed disk (LRS), zonal Public IP, zonal AKS node pool | You own the redundancy, the failover and the quorum |
| **Zone-redundant (ZR)** | Platform replicates/spreads across ≥ 3 zones behind one endpoint | Zone loss is transparent; possible brief failover | Storage ZRS/GZRS, Standard Load Balancer, App Gateway v2, ZRS managed disks, zone-redundant VPN/ExpressRoute gateways, SQL DB Business Critical ZR | Higher unit price, write latency ≈ slowest zone |
| **Regional (non-zonal)** | Platform places it anywhere in the region | Undefined zone affinity — **not** a redundancy guarantee | Legacy/basic SKUs, Basic Public IP | Silent single point of failure |
| **Global** | No region at all | Region-independent | Entra ID, Traffic Manager, Front Door, DNS zones, management groups | Cannot be region-locked by policy |

> **Trap:** "regional" is not "zone-redundant". A resource created before zones existed in that region, or with a Basic SKU, is regional. It survives nothing.

### 2.3 Availability sets vs availability zones vs regions

| Construct | Protects against | SLA (VM connectivity) | Latency cost | Extra cost |
|---|---|---|---|---|
| Single VM, Standard HDD | Nothing | 95 % | — | — |
| Single VM, Standard SSD | Nothing | 99.5 % | — | — |
| Single VM, Premium SSD / Ultra Disk | Host reboot only (live migration) | 99.9 % | — | Disk premium |
| **Availability set** (≥ 2 VMs, FD + UD spread) | Rack failure, planned maintenance | 99.95 % | Negligible (same DC campus) | Free |
| **≥ 2 VMs in the same AZ** | Rack + maintenance, not zone loss | 99.9 % | Negligible | Free |
| **≥ 2 VMs across ≥ 2 AZs** | Datacenter/zone loss (power, cooling, network) | **99.99 %** | < 2 ms RTT | Cross-zone traffic, duplicated capacity |
| **Multi-region active/active** | Region loss, regional control-plane loss | Composite, you engineer it | 20–150 ms typical | Full duplication + data replication |

**Composite SLA arithmetic** — dependent services multiply, they do not average:

```
App tier  (2 VMs across 2 AZs)   0.9999
SQL DB    (Business Critical ZR) 0.9999
Storage   (ZRS)                  0.9999
Load Bal. (Standard, ZR)         0.9999
-------------------------------------------
Composite = 0.9999^4 = 0.99960  →  ~3 h 30 m/year
```

Adding a fifth dependency at 99.9 % drops you to 99.86 % (~12 h/year). This is why "we have four nines on the VM" is not an availability statement.

### 2.4 Region pairs — and why you must stop assuming they exist

A **region pair** is a static, Microsoft-defined relationship inside a geography (with one famous exception) providing:

- **Physical isolation** — ≥ 300 miles apart where geography allows.
- **Sequential updating** — planned platform updates roll to only one region of a pair at a time.
- **Platform-provided replication** — GRS/RA-GRS storage replicates to the pair, and nowhere else.
- **Region recovery order** — in a multi-region outage, one region of each pair is prioritised for restoration.
- **Data residency** — the pair stays in the same geography, *except* **Brazil South**, which is paired with **South Central US**.

**The modern caveat:** Microsoft's newer regions are increasingly launched **without a pair**, relying on availability zones plus customer-managed multi-region replication. Do not hardcode a pair table. Query it:

```bash
$ SUB=$(az account show --query id -o tsv)
$ az rest --method get \
    --url "https://management.azure.com/subscriptions/$SUB/locations?api-version=2022-12-01" \
    --query "value[?name=='eastus'].{region:name, physical:metadata.physicalLocation, \
             geography:metadata.geography, category:metadata.regionCategory, \
             pair:metadata.pairedRegion[0].name, zones:availabilityZoneMappings}" -o json
```

```json
[
  {
    "region": "eastus",
    "physical": "Virginia",
    "geography": "United States",
    "category": "Recommended",
    "pair": "westus",
    "zones": [
      { "logicalZone": "1", "physicalZone": "eastus-az1" },
      { "logicalZone": "2", "physicalZone": "eastus-az3" },
      { "logicalZone": "3", "physicalZone": "eastus-az2" }
    ]
  }
]
```

**Read that `zones` block again.** In this subscription, logical zone `2` is physical zone `eastus-az3`. The mapping is randomised per subscription so that Azure spreads load evenly. Consequences:

- Cross-subscription zone alignment (e.g. app in sub A, database in sub B, "both in zone 1") is **meaningless** unless you resolve physical zones on both sides.
- A capacity outage reported by Azure as affecting `eastus-az2` maps to a *different* logical zone number in every subscription you own.

### 2.5 Sovereign and special clouds

| Cloud | ARM endpoint | Tenant | Notes |
|---|---|---|---|
| Azure public | `management.azure.com` | Global Entra ID | Default |
| Azure Government (US) | `management.usgovcloudapi.net` | Separate | FedRAMP High, DoD IL5; screened US-person operators |
| Azure China (21Vianet) | `management.chinacloudapi.cn` | Separate | Operated by 21Vianet, not Microsoft; feature lag |
| Azure Local / Edge Zones | Hybrid ARM projection | Global | On-prem or telco-edge extension of the control plane |

They are **separate clouds**: separate identity, separate ARM, separate service catalogue, no cross-cloud resource IDs.

```bash
$ az cloud list --output table
Name               IsActive    Profile    ActiveDirectoryAuthority
-----------------  ----------  ---------  ------------------------------------
AzureCloud         True        latest     https://login.microsoftonline.com
AzureChinaCloud    False       latest     https://login.chinacloudapi.cn
AzureUSGovernment  False       latest     https://login.microsoftonline.us
```

---

## 3. The logical hierarchy

```
Microsoft Entra ID tenant                      ← identity + trust boundary (1 per hierarchy)
└── Tenant Root Group (management group, id == tenantId)
    ├── mg-platform
    │   ├── mg-platform-identity   → subscription: sub-identity-prod
    │   ├── mg-platform-management → subscription: sub-mgmt-prod
    │   └── mg-platform-connectivity → subscription: sub-conn-prod
    ├── mg-landingzones
    │   ├── mg-lz-corp   → sub-app-a-prod, sub-app-b-prod
    │   └── mg-lz-online → sub-web-prod
    ├── mg-sandbox        → sub-dev-sandbox-*
    └── mg-decommissioned → (quarantine before deletion)
```

### 3.1 What each level *is*, mechanically

| Level | ARM scope string | Primary function | Inherits | Hard limits |
|---|---|---|---|---|
| **Tenant** | `/` | Identity boundary. A subscription trusts exactly **one** tenant | — | 1 root MG |
| **Management group** | `/providers/Microsoft.Management/managementGroups/{name}` | RBAC + Policy + cost rollup across many subscriptions | From parent MG | 10 000 MGs per directory; **6 levels deep** below root; **one parent** per MG |
| **Subscription** | `/subscriptions/{guid}` | Billing unit, **quota unit**, **ARM throttling unit**, resource-provider registration unit | From MG chain | 980 resource groups; one billing account; one tenant |
| **Resource group** | `/subscriptions/{guid}/resourceGroups/{name}` | Lifecycle + deployment + RBAC scope | From subscription | Name ≤ 90 chars; ~800 resources per type; 800 deployment history entries |
| **Resource** | `.../providers/{ns}/{type}/{name}` | The thing itself | From RG | 50 tags |

### 3.2 Inheritance semantics — additive, and one-way

**Azure RBAC is additive and cannot be revoked downward.** If someone is `Contributor` at the management-group level, no assignment at the resource group can take that away. The only subtractive mechanism is a **deny assignment** (created by Deployment Stacks, or historically by Blueprints).

**Azure Policy is evaluated at every scope in the chain.** Effects compose:

| Effect | Applies at | Composition rule |
|---|---|---|
| `Deny` | Create/update time | Any `Deny` anywhere in the chain wins |
| `Audit` | Create/update + periodic scan | Records non-compliance, never blocks |
| `Modify` / `Append` | Create/update | Mutates the request before validation |
| `DeployIfNotExists` | Post-create + remediation task | Needs a managed identity with rights at the target scope |
| `DenyAction` | Delete (`Microsoft.Authorization/*/delete`) | Blocks destructive actions, e.g. accidental RG deletion |

**Locks (`CanNotDelete`, `ReadOnly`) also inherit downward and are also non-overridable.** A `ReadOnly` lock at the subscription is the single most effective way to break a production deployment pipeline at 03:00.

### 3.3 Resource groups: what they are not

A resource group is **not** a network boundary, **not** a security boundary, **not** a region constraint, and **not** a fault domain. It is:

1. A **deployment target** — ARM templates/Bicep deploy at RG scope by default and resolve `dependsOn` graphs within it.
2. A **lifecycle unit** — `az group delete` removes every resource inside, in dependency order. This is the fastest way to lose production in Azure.
3. A **metadata record pinned to one region** — the `location` property.

```bash
$ az group show -n rg-app-prod-eastus --query "{name:name, location:location, provisioningState:properties.provisioningState}" -o json
{
  "location": "eastus",
  "name": "rg-app-prod-eastus",
  "provisioningState": "Succeeded"
}
$ az resource list -g rg-app-prod-eastus --query "[].{name:name, type:type, location:location}" -o table
Name                     Type                                     Location
-----------------------  ---------------------------------------  ----------
vnet-app-prod            Microsoft.Network/virtualNetworks        eastus
st-app-prod-dr           Microsoft.Storage/storageAccounts        westus
afd-app-prod             Microsoft.Cdn/profiles                   global
```

Three regions, one resource group, one metadata location. If `eastus` ARM is degraded, the `westus` storage account is **readable and writable on its data plane** but **unmanageable on its control plane**. Design rule: **DR resources belong in a resource group whose `location` is the DR region.**

### 3.4 Subscriptions as blast-radius and throttle boundaries

ARM applies request budgets per subscription and per resource provider. The counters are returned on every response:

```bash
$ az rest --method get --verbose \
    --url "https://management.azure.com/subscriptions/$SUB/resourcegroups?api-version=2021-04-01" \
    --debug 2>&1 | grep -iE 'x-ms-ratelimit|retry-after'
'x-ms-ratelimit-remaining-subscription-reads': '11842'
'x-ms-ratelimit-remaining-subscription-global-reads': '3748'
```

When exhausted:

```
$ az vm list -o table
(TooManyRequests) The request is being throttled as the limit has been reached for operation type - 'List'.
For more information, see - https://aka.ms/msdn-throttling
Code: TooManyRequests
Retry-After: 42
```

**Subscription topology rules that follow from this:**

| Driver | Split subscriptions when… | Keep together when… |
|---|---|---|
| Quota | You need > 980 RGs, or regional vCPU quota is capped | Quota headroom is ample |
| Throttling | High-churn CI/CD or autoscaling shares a sub with production | Low API churn |
| Billing | Cost must be invoiced to a different cost centre | Tags + management-group rollup suffice |
| Blast radius | A tenant-wide policy or lock would over-reach | Same lifecycle and owner |
| Compliance | PCI/HIPAA scope must be provably isolated | Same regulatory class |

The landing-zone answer is **subscription vending**: a subscription is a cattle-grade unit, created by pipeline, placed under the correct management group, with policy and RBAC applied by inheritance rather than by hand.

---

## 4. Infrastructure as code — complete, deployable

### 4.1 Management-group hierarchy (tenant-scope Bicep)

`platform/mg-hierarchy.bicep`

```bicep
targetScope = 'tenant'

@description('Tenant root management group ID. Equals the Entra ID tenant GUID.')
param rootManagementGroupId string

@description('Prefix for all platform management groups.')
param mgPrefix string = 'contoso'

// ---------- Level 1: intermediate root ----------
resource mgRoot 'Microsoft.Management/managementGroups@2023-04-01' = {
  name: mgPrefix
  properties: {
    displayName: 'Contoso'
    details: {
      parent: {
        id: tenantResourceId('Microsoft.Management/managementGroups', rootManagementGroupId)
      }
    }
  }
}

// ---------- Level 2 ----------
resource mgPlatform 'Microsoft.Management/managementGroups@2023-04-01' = {
  name: '${mgPrefix}-platform'
  properties: {
    displayName: 'Platform'
    details: {
      parent: { id: mgRoot.id }
    }
  }
}

resource mgLandingZones 'Microsoft.Management/managementGroups@2023-04-01' = {
  name: '${mgPrefix}-landingzones'
  properties: {
    displayName: 'Landing Zones'
    details: {
      parent: { id: mgRoot.id }
    }
  }
}

resource mgSandbox 'Microsoft.Management/managementGroups@2023-04-01' = {
  name: '${mgPrefix}-sandbox'
  properties: {
    displayName: 'Sandbox'
    details: {
      parent: { id: mgRoot.id }
    }
  }
}

resource mgDecommissioned 'Microsoft.Management/managementGroups@2023-04-01' = {
  name: '${mgPrefix}-decommissioned'
  properties: {
    displayName: 'Decommissioned'
    details: {
      parent: { id: mgRoot.id }
    }
  }
}

// ---------- Level 3: platform children ----------
var platformChildren = [
  { suffix: 'identity',     display: 'Identity' }
  { suffix: 'management',   display: 'Management' }
  { suffix: 'connectivity', display: 'Connectivity' }
]

resource mgPlatformChildren 'Microsoft.Management/managementGroups@2023-04-01' = [for child in platformChildren: {
  name: '${mgPrefix}-platform-${child.suffix}'
  properties: {
    displayName: child.display
    details: {
      parent: { id: mgPlatform.id }
    }
  }
}]

// ---------- Level 3: landing-zone children ----------
var landingZoneChildren = [
  { suffix: 'corp',   display: 'Corp (private, hub-connected)' }
  { suffix: 'online', display: 'Online (internet-facing)' }
]

resource mgLandingZoneChildren 'Microsoft.Management/managementGroups@2023-04-01' = [for lz in landingZoneChildren: {
  name: '${mgPrefix}-lz-${lz.suffix}'
  properties: {
    displayName: lz.display
    details: {
      parent: { id: mgLandingZones.id }
    }
  }
}]

output rootMgId string = mgRoot.id
output landingZoneCorpId string = mgLandingZoneChildren[0].id
output landingZoneOnlineId string = mgLandingZoneChildren[1].id
```

Deploy:

```bash
$ TENANT_ID=$(az account show --query tenantId -o tsv)
$ az deployment tenant create \
    --name mg-hierarchy-$(date +%Y%m%d%H%M) \
    --location eastus \
    --template-file platform/mg-hierarchy.bicep \
    --parameters rootManagementGroupId=$TENANT_ID mgPrefix=contoso \
    --query "properties.provisioningState" -o tsv
Succeeded
```

> `--location` on a tenant/MG/subscription deployment stores the *deployment metadata*, not the resources. Choose a region you can reach during a DR event.

### 4.2 Custom policy: enforce zone-redundant storage in production

`platform/policies/deny-non-zr-storage.json`

```json
{
  "properties": {
    "displayName": "Storage accounts must be zone-redundant",
    "policyType": "Custom",
    "mode": "Indexed",
    "description": "Denies creation of storage accounts whose SKU is not ZRS, GZRS or RA-GZRS. Zone redundancy is mandatory for production workloads so that the loss of a single availability zone does not cause data-plane unavailability.",
    "metadata": {
      "version": "1.0.0",
      "category": "Storage"
    },
    "parameters": {
      "effect": {
        "type": "String",
        "metadata": {
          "displayName": "Effect",
          "description": "Enable or disable execution of the policy"
        },
        "allowedValues": [ "Audit", "Deny", "Disabled" ],
        "defaultValue": "Deny"
      },
      "allowedSkus": {
        "type": "Array",
        "metadata": {
          "displayName": "Allowed SKUs",
          "description": "Zone-redundant storage SKUs permitted in this scope"
        },
        "defaultValue": [
          "Standard_ZRS",
          "Standard_GZRS",
          "Standard_RAGZRS",
          "Premium_ZRS"
        ]
      }
    },
    "policyRule": {
      "if": {
        "allOf": [
          {
            "field": "type",
            "equals": "Microsoft.Storage/storageAccounts"
          },
          {
            "not": {
              "field": "Microsoft.Storage/storageAccounts/sku.name",
              "in": "[parameters('allowedSkus')]"
            }
          }
        ]
      },
      "then": {
        "effect": "[parameters('effect')]"
      }
    }
  }
}
```

`platform/policies/allowed-locations.json`

```json
{
  "properties": {
    "displayName": "Allowed regions for resource deployment",
    "policyType": "Custom",
    "mode": "Indexed",
    "description": "Restricts deployments to approved regions that have availability zones, so that every workload can be made zone-redundant. Global resources and resource-group metadata objects are exempt.",
    "metadata": { "version": "1.1.0", "category": "General" },
    "parameters": {
      "listOfAllowedLocations": {
        "type": "Array",
        "metadata": {
          "displayName": "Allowed locations",
          "description": "Regions permitted for resources",
          "strongType": "location"
        },
        "defaultValue": [ "eastus", "westus3", "westeurope", "northeurope" ]
      }
    },
    "policyRule": {
      "if": {
        "allOf": [
          {
            "field": "location",
            "notIn": "[parameters('listOfAllowedLocations')]"
          },
          {
            "field": "location",
            "notEquals": "global"
          },
          {
            "field": "type",
            "notEquals": "Microsoft.AzureActiveDirectory/b2cDirectories"
          }
        ]
      },
      "then": { "effect": "deny" }
    }
  }
}
```

### 4.3 Binding policy to the hierarchy (management-group-scope Bicep)

`platform/mg-governance.bicep`

```bicep
targetScope = 'managementGroup'

@description('Regions approved for this management group.')
param allowedLocations array = [ 'eastus', 'westus3' ]

@description('Effect for the zone-redundancy policy.')
@allowed([ 'Audit', 'Deny', 'Disabled' ])
param storageZrEffect string = 'Deny'

var allowedLocationsPolicy = loadJsonContent('policies/allowed-locations.json')
var zrStoragePolicy = loadJsonContent('policies/deny-non-zr-storage.json')

resource defAllowedLocations 'Microsoft.Authorization/policyDefinitions@2023-04-01' = {
  name: 'contoso-allowed-locations'
  properties: allowedLocationsPolicy.properties
}

resource defZrStorage 'Microsoft.Authorization/policyDefinitions@2023-04-01' = {
  name: 'contoso-zr-storage'
  properties: zrStoragePolicy.properties
}

resource initiative 'Microsoft.Authorization/policySetDefinitions@2023-04-01' = {
  name: 'contoso-resilience-baseline'
  properties: {
    displayName: 'Contoso resilience baseline'
    description: 'Region allow-list plus mandatory zone redundancy for stateful services.'
    policyType: 'Custom'
    metadata: { category: 'Resilience', version: '1.0.0' }
    parameters: {
      allowedLocations: {
        type: 'Array'
        metadata: { displayName: 'Allowed locations', strongType: 'location' }
      }
      storageEffect: {
        type: 'String'
        allowedValues: [ 'Audit', 'Deny', 'Disabled' ]
        defaultValue: 'Deny'
      }
    }
    policyDefinitions: [
      {
        policyDefinitionReferenceId: 'allowedLocations'
        policyDefinitionId: defAllowedLocations.id
        parameters: {
          listOfAllowedLocations: { value: '[[parameters(\'allowedLocations\')]' }
        }
      }
      {
        policyDefinitionReferenceId: 'zrStorage'
        policyDefinitionId: defZrStorage.id
        parameters: {
          effect: { value: '[[parameters(\'storageEffect\')]' }
        }
      }
    ]
  }
}

resource assignment 'Microsoft.Authorization/policyAssignments@2024-04-01' = {
  name: 'resilience-baseline'
  location: deployment().location
  identity: { type: 'SystemAssigned' }
  properties: {
    displayName: 'Contoso resilience baseline'
    policyDefinitionId: initiative.id
    enforcementMode: 'Default'
    parameters: {
      allowedLocations: { value: allowedLocations }
      storageEffect: { value: storageZrEffect }
    }
    nonComplianceMessages: [
      {
        message: 'This deployment violates the Contoso resilience baseline. Resources must be deployed in an approved zone-enabled region and stateful storage must be zone-redundant.'
      }
      {
        message: 'Storage accounts must use a zone-redundant SKU (Standard_ZRS, Standard_GZRS, Standard_RAGZRS or Premium_ZRS).'
        policyDefinitionReferenceId: 'zrStorage'
      }
    ]
  }
}

output initiativeId string = initiative.id
output assignmentPrincipalId string = assignment.identity.principalId
```

Deploy at management-group scope:

```bash
$ az deployment mg create \
    --management-group-id contoso-landingzones \
    --name resilience-baseline-$(date +%Y%m%d%H%M) \
    --location eastus \
    --template-file platform/mg-governance.bicep \
    --parameters allowedLocations='["eastus","westus3"]' storageZrEffect=Deny \
    -o table

Name                              ResourceGroup    State      Timestamp
--------------------------------  ---------------  ---------  ------------------------------
resilience-baseline-202609041142                   Succeeded  2026-09-04T11:42:53.918204+00:00
```

### 4.4 Subscription-scope deployment: resource groups aligned to failure domains

`workload/subscription.bicep`

```bicep
targetScope = 'subscription'

@description('Workload short name, used in all resource group names.')
@minLength(2)
@maxLength(10)
param workload string

@allowed([ 'dev', 'test', 'prod' ])
param environment string

@description('Primary region. Must have availability zones.')
param primaryLocation string = 'eastus'

@description('Secondary / DR region. Must be the paired region or an approved alternative.')
param secondaryLocation string = 'westus3'

param costCenter string
param owner string

var baseTags = {
  workload: workload
  environment: environment
  costCenter: costCenter
  owner: owner
  managedBy: 'bicep'
}

// Primary-region control-plane home
resource rgPrimary 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: 'rg-${workload}-${environment}-${primaryLocation}'
  location: primaryLocation
  tags: union(baseTags, { failureDomain: 'primary' })
}

// DR resources live in a resource group whose METADATA is in the DR region,
// so that they remain manageable when the primary region control plane is down.
resource rgSecondary 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: 'rg-${workload}-${environment}-${secondaryLocation}'
  location: secondaryLocation
  tags: union(baseTags, { failureDomain: 'secondary' })
}

// Global / region-independent resources (Front Door, DNS, Traffic Manager).
resource rgGlobal 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: 'rg-${workload}-${environment}-global'
  location: primaryLocation
  tags: union(baseTags, { failureDomain: 'global' })
}

module primaryNetwork 'modules/zonal-network.bicep' = {
  name: 'deploy-network-primary'
  scope: rgPrimary
  params: {
    location: primaryLocation
    workload: workload
    environment: environment
    addressSpace: '10.10.0.0/16'
    tags: baseTags
  }
}

module secondaryNetwork 'modules/zonal-network.bicep' = {
  name: 'deploy-network-secondary'
  scope: rgSecondary
  params: {
    location: secondaryLocation
    workload: workload
    environment: environment
    addressSpace: '10.20.0.0/16'
    tags: baseTags
  }
}

output primaryResourceGroupId string = rgPrimary.id
output secondaryResourceGroupId string = rgSecondary.id
output primaryVnetId string = primaryNetwork.outputs.vnetId
```

`workload/modules/zonal-network.bicep`

```bicep
targetScope = 'resourceGroup'

param location string
param workload string
param environment string
param addressSpace string
param tags object

var vnetName = 'vnet-${workload}-${environment}-${location}'

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: vnetName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [ addressSpace ]
    }
    subnets: [
      {
        name: 'snet-app'
        properties: {
          addressPrefix: cidrSubnet(addressSpace, 20, 0)
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
      {
        name: 'snet-data'
        properties: {
          addressPrefix: cidrSubnet(addressSpace, 20, 1)
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
      {
        name: 'AzureBastionSubnet'
        properties: {
          addressPrefix: cidrSubnet(addressSpace, 26, 64)
        }
      }
    ]
  }
}

// Zone-redundant public IP: survives the loss of any single availability zone.
resource pip 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: 'pip-${workload}-${environment}-${location}'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  zones: [ '1', '2', '3' ]        // zone-redundant, NOT zonal
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
    idleTimeoutInMinutes: 4
  }
}

// Zone-redundant Standard Load Balancer.
resource lb 'Microsoft.Network/loadBalancers@2024-05-01' = {
  name: 'lb-${workload}-${environment}-${location}'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  properties: {
    frontendIPConfigurations: [
      {
        name: 'fe-public'
        properties: {
          publicIPAddress: { id: pip.id }
        }
      }
    ]
    backendAddressPools: [
      { name: 'bepool-app' }
    ]
    probes: [
      {
        name: 'probe-https'
        properties: {
          protocol: 'Https'
          port: 443
          requestPath: '/healthz'
          intervalInSeconds: 5
          numberOfProbes: 2
        }
      }
    ]
    loadBalancingRules: [
      {
        name: 'rule-https'
        properties: {
          frontendIPConfiguration: {
            id: resourceId('Microsoft.Network/loadBalancers/frontendIPConfigurations', 'lb-${workload}-${environment}-${location}', 'fe-public')
          }
          backendAddressPool: {
            id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools', 'lb-${workload}-${environment}-${location}', 'bepool-app')
          }
          probe: {
            id: resourceId('Microsoft.Network/loadBalancers/probes', 'lb-${workload}-${environment}-${location}', 'probe-https')
          }
          protocol: 'Tcp'
          frontendPort: 443
          backendPort: 443
          enableFloatingIP: false
          idleTimeoutInMinutes: 4
          loadDistribution: 'Default'
          disableOutboundSnat: true
        }
      }
    ]
  }
}

// Zone-redundant storage for workload state.
resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: toLower('st${workload}${environment}${uniqueString(resourceGroup().id)}')
  location: location
  tags: tags
  sku: {
    name: environment == 'prod' ? 'Standard_GZRS' : 'Standard_ZRS'
  }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
    }
  }
}

output vnetId string = vnet.id
output loadBalancerId string = lb.id
output storageAccountId string = storage.id
```

### 4.5 The same subscription-scope deployment as raw ARM JSON

`workload/subscription.json` — for environments where Bicep tooling is unavailable.

```json
{
  "$schema": "https://schema.management.azure.com/schemas/2018-05-01/subscriptionDeploymentTemplate.json#",
  "contentVersion": "1.0.0.0",
  "parameters": {
    "workload":          { "type": "string",  "minLength": 2, "maxLength": 10 },
    "environment":       { "type": "string",  "allowedValues": [ "dev", "test", "prod" ] },
    "primaryLocation":   { "type": "string",  "defaultValue": "eastus" },
    "secondaryLocation": { "type": "string",  "defaultValue": "westus3" },
    "costCenter":        { "type": "string" },
    "owner":             { "type": "string" }
  },
  "variables": {
    "baseTags": {
      "workload":    "[parameters('workload')]",
      "environment": "[parameters('environment')]",
      "costCenter":  "[parameters('costCenter')]",
      "owner":       "[parameters('owner')]",
      "managedBy":   "arm-json"
    }
  },
  "resources": [
    {
      "type": "Microsoft.Resources/resourceGroups",
      "apiVersion": "2024-03-01",
      "name": "[format('rg-{0}-{1}-{2}', parameters('workload'), parameters('environment'), parameters('primaryLocation'))]",
      "location": "[parameters('primaryLocation')]",
      "tags": "[union(variables('baseTags'), createObject('failureDomain', 'primary'))]",
      "properties": {}
    },
    {
      "type": "Microsoft.Resources/resourceGroups",
      "apiVersion": "2024-03-01",
      "name": "[format('rg-{0}-{1}-{2}', parameters('workload'), parameters('environment'), parameters('secondaryLocation'))]",
      "location": "[parameters('secondaryLocation')]",
      "tags": "[union(variables('baseTags'), createObject('failureDomain', 'secondary'))]",
      "properties": {}
    },
    {
      "type": "Microsoft.Resources/deployments",
      "apiVersion": "2024-03-01",
      "name": "deploy-network-primary",
      "resourceGroup": "[format('rg-{0}-{1}-{2}', parameters('workload'), parameters('environment'), parameters('primaryLocation'))]",
      "dependsOn": [
        "[subscriptionResourceId('Microsoft.Resources/resourceGroups', format('rg-{0}-{1}-{2}', parameters('workload'), parameters('environment'), parameters('primaryLocation')))]"
      ],
      "properties": {
        "mode": "Incremental",
        "template": {
          "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#",
          "contentVersion": "1.0.0.0",
          "resources": [
            {
              "type": "Microsoft.Network/publicIPAddresses",
              "apiVersion": "2024-05-01",
              "name": "[format('pip-{0}-{1}', parameters('workload'), parameters('environment'))]",
              "location": "[parameters('primaryLocation')]",
              "sku": { "name": "Standard", "tier": "Regional" },
              "zones": [ "1", "2", "3" ],
              "properties": {
                "publicIPAllocationMethod": "Static",
                "publicIPAddressVersion": "IPv4"
              }
            }
          ]
        }
      }
    }
  ],
  "outputs": {
    "primaryResourceGroupName": {
      "type": "string",
      "value": "[format('rg-{0}-{1}-{2}', parameters('workload'), parameters('environment'), parameters('primaryLocation'))]"
    }
  }
}
```

### 4.6 Terraform equivalent of the hierarchy

`terraform/hierarchy.tf`

```hcl
terraform {
  required_version = ">= 1.9.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

provider "azurerm" {
  features {
    resource_group {
      prevent_deletion_if_contains_resources = true
    }
  }
}

data "azurerm_client_config" "current" {}

resource "azurerm_management_group" "root" {
  display_name               = "Contoso"
  name                       = "contoso"
  parent_management_group_id = "/providers/Microsoft.Management/managementGroups/${data.azurerm_client_config.current.tenant_id}"
}

resource "azurerm_management_group" "platform" {
  display_name               = "Platform"
  name                       = "contoso-platform"
  parent_management_group_id = azurerm_management_group.root.id
}

resource "azurerm_management_group" "landing_zones" {
  display_name               = "Landing Zones"
  name                       = "contoso-landingzones"
  parent_management_group_id = azurerm_management_group.root.id
}

locals {
  landing_zones = {
    corp   = "Corp (private, hub-connected)"
    online = "Online (internet-facing)"
  }
}

resource "azurerm_management_group" "lz" {
  for_each                   = local.landing_zones
  display_name               = each.value
  name                       = "contoso-lz-${each.key}"
  parent_management_group_id = azurerm_management_group.landing_zones.id
}

resource "azurerm_management_group_subscription_association" "app_prod" {
  management_group_id = azurerm_management_group.lz["corp"].id
  subscription_id     = "/subscriptions/${var.app_prod_subscription_id}"
}

resource "azurerm_management_group_policy_assignment" "allowed_locations" {
  name                 = "allowed-locations"
  management_group_id  = azurerm_management_group.landing_zones.id
  policy_definition_id = "/providers/Microsoft.Authorization/policyDefinitions/e56962a6-4747-49cd-b67b-bf8b01975c4c"
  location             = "eastus"

  identity { type = "SystemAssigned" }

  parameters = jsonencode({
    listOfAllowedLocations = { value = ["eastus", "westus3"] }
  })

  non_compliance_message {
    content = "Resources must be deployed in an approved zone-enabled region."
  }
}

variable "app_prod_subscription_id" {
  type        = string
  description = "GUID of the production application subscription."
}
```

### 4.7 Zone-aware workload on AKS (Kubernetes manifests)

Availability zones stop at the infrastructure boundary unless the scheduler is told about them. AKS labels every node with `topology.kubernetes.io/zone = <region>-<logicalZone>`.

`k8s/storageclass-zrs.yaml`

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: managed-csi-premium-zrs
  annotations:
    storageclass.kubernetes.io/is-default-class: "false"
provisioner: disk.csi.azure.com
parameters:
  skuName: Premium_ZRS          # zone-redundant managed disk: attachable from any zone
  cachingMode: ReadOnly
  networkAccessPolicy: DenyAll
reclaimPolicy: Delete
allowVolumeExpansion: true
volumeBindingMode: WaitForFirstConsumer
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: managed-csi-premium-lrs
provisioner: disk.csi.azure.com
parameters:
  skuName: Premium_LRS          # zonal: the PV is pinned to the zone it was created in
  cachingMode: ReadOnly
reclaimPolicy: Delete
allowVolumeExpansion: true
volumeBindingMode: WaitForFirstConsumer   # MANDATORY for LRS, or the PV lands in the wrong zone
```

`k8s/statefulset-zonal.yaml`

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: orders-api
  namespace: prod
  labels:
    app.kubernetes.io/name: orders-api
    app.kubernetes.io/component: api
spec:
  serviceName: orders-api
  replicas: 6
  podManagementPolicy: Parallel
  selector:
    matchLabels:
      app.kubernetes.io/name: orders-api
  template:
    metadata:
      labels:
        app.kubernetes.io/name: orders-api
        app.kubernetes.io/component: api
    spec:
      terminationGracePeriodSeconds: 60
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        fsGroup: 10001
        seccompProfile:
          type: RuntimeDefault
      # Hard requirement: never more than one replica difference between zones.
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: orders-api
          matchLabelKeys:
            - pod-template-hash
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: orders-api
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - key: topology.kubernetes.io/zone
                    operator: In
                    values:
                      - eastus-1
                      - eastus-2
                      - eastus-3
      containers:
        - name: api
          image: contosoacr.azurecr.io/orders-api:1.14.2
          ports:
            - name: https
              containerPort: 8443
          resources:
            requests:
              cpu: 500m
              memory: 512Mi
            limits:
              memory: 1Gi
          readinessProbe:
            httpGet:
              path: /healthz/ready
              port: https
              scheme: HTTPS
            initialDelaySeconds: 5
            periodSeconds: 5
            failureThreshold: 3
          livenessProbe:
            httpGet:
              path: /healthz/live
              port: https
              scheme: HTTPS
            initialDelaySeconds: 20
            periodSeconds: 10
            failureThreshold: 5
          volumeMounts:
            - name: data
              mountPath: /var/lib/orders
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: [ "ALL" ]
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: [ "ReadWriteOnce" ]
        storageClassName: managed-csi-premium-zrs
        resources:
          requests:
            storage: 64Gi
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: orders-api
  namespace: prod
spec:
  # 6 replicas across 3 zones = 2 per zone. maxUnavailable 2 allows a full
  # zone drain without the PDB blocking node-pool upgrades.
  maxUnavailable: 2
  selector:
    matchLabels:
      app.kubernetes.io/name: orders-api
  unhealthyPodEvictionPolicy: AlwaysAllow
```

Verify the spread actually happened:

```bash
$ kubectl get pods -n prod -l app.kubernetes.io/name=orders-api \
    -o custom-columns='POD:.metadata.name,NODE:.spec.nodeName,ZONE:.metadata.labels.topology\.kubernetes\.io/zone' \
    --sort-by='.spec.nodeName'
# zone label is on the node, so join it:
$ kubectl get pods -n prod -l app.kubernetes.io/name=orders-api -o json \
  | jq -r '.items[] | .spec.nodeName' \
  | xargs -I{} kubectl get node {} -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}{"\n"}' \
  | sort | uniq -c
      2 eastus-1
      2 eastus-2
      2 eastus-3
```

### 4.8 CI gate: what-if before apply

`.azure-pipelines/infra.yml`

```yaml
trigger:
  branches:
    include: [ main ]
  paths:
    include: [ platform/**, workload/** ]

pr:
  branches:
    include: [ main ]

variables:
  - name: azureServiceConnection
    value: sc-contoso-platform
  - name: managementGroupId
    value: contoso-landingzones
  - name: deploymentLocation
    value: eastus

stages:
  - stage: Validate
    displayName: Lint and what-if
    jobs:
      - job: Lint
        displayName: Bicep lint
        pool: { vmImage: ubuntu-latest }
        steps:
          - task: AzureCLI@2
            displayName: az bicep build
            inputs:
              azureSubscription: $(azureServiceConnection)
              scriptType: bash
              scriptLocation: inlineScript
              inlineScript: |
                set -euo pipefail
                az bicep upgrade
                az bicep build --file platform/mg-governance.bicep --stdout > /dev/null
                az bicep build --file workload/subscription.bicep  --stdout > /dev/null
                echo "Bicep compiles clean."

      - job: WhatIf
        displayName: Preview changes
        dependsOn: Lint
        pool: { vmImage: ubuntu-latest }
        steps:
          - task: AzureCLI@2
            displayName: Management-group what-if
            inputs:
              azureSubscription: $(azureServiceConnection)
              scriptType: bash
              scriptLocation: inlineScript
              inlineScript: |
                set -euo pipefail
                az deployment mg what-if \
                  --management-group-id "$(managementGroupId)" \
                  --location "$(deploymentLocation)" \
                  --template-file platform/mg-governance.bicep \
                  --parameters allowedLocations='["eastus","westus3"]' \
                  --result-format FullResourcePayload

          - task: AzureCLI@2
            displayName: Subscription what-if
            inputs:
              azureSubscription: $(azureServiceConnection)
              scriptType: bash
              scriptLocation: inlineScript
              inlineScript: |
                set -euo pipefail
                az deployment sub what-if \
                  --location "$(deploymentLocation)" \
                  --template-file workload/subscription.bicep \
                  --parameters workload=orders environment=prod \
                               costCenter=CC-4412 owner=sre-platform

  - stage: Deploy
    displayName: Deploy hierarchy and workload
    dependsOn: Validate
    condition: and(succeeded(), eq(variables['Build.SourceBranch'], 'refs/heads/main'))
    jobs:
      - deployment: ApplyGovernance
        displayName: Apply governance
        environment: azure-platform-prod   # gated by manual approval
        pool: { vmImage: ubuntu-latest }
        strategy:
          runOnce:
            deploy:
              steps:
                - checkout: self
                - task: AzureCLI@2
                  displayName: Deploy management-group governance
                  inputs:
                    azureSubscription: $(azureServiceConnection)
                    scriptType: bash
                    scriptLocation: inlineScript
                    inlineScript: |
                      set -euo pipefail
                      az deployment mg create \
                        --management-group-id "$(managementGroupId)" \
                        --name "gov-$(Build.BuildId)" \
                        --location "$(deploymentLocation)" \
                        --template-file platform/mg-governance.bicep \
                        --parameters allowedLocations='["eastus","westus3"]' \
                        --query "properties.provisioningState" -o tsv
```

---

## 5. CLI reference with real output

### 5.1 Where am I? (context resolution)

```bash
$ az account show -o json
{
  "environmentName": "AzureCloud",
  "homeTenantId": "72f988bf-86f1-41af-91ab-2d7cd011db47",
  "id": "8f3d4c21-9b6a-4d8e-b1f2-6c5a7e9d0341",
  "isDefault": true,
  "name": "sub-orders-prod",
  "state": "Enabled",
  "tenantId": "72f988bf-86f1-41af-91ab-2d7cd011db47",
  "user": {
    "name": "sre-platform@contoso.com",
    "type": "user"
  }
}

$ az account list --query "[].{name:name, id:id, state:state, isDefault:isDefault}" -o table
Name                Id                                    State    IsDefault
------------------  ------------------------------------  -------  -----------
sub-orders-prod     8f3d4c21-9b6a-4d8e-b1f2-6c5a7e9d0341  Enabled  True
sub-orders-nonprod  1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d  Enabled  False
sub-conn-prod       9e8d7c6b-5a4f-4e3d-2c1b-0a9f8e7d6c5b  Enabled  False
sub-mgmt-prod       4d3c2b1a-9f8e-4d7c-6b5a-4f3e2d1c0b9a  Enabled  False
```

### 5.2 Walking the management-group tree

```bash
$ az account management-group list --query "[].{name:name, display:displayName}" -o table
Name                     Display
-----------------------  -----------------------------
72f988bf-...-2d7cd011db47  Tenant Root Group
contoso                  Contoso
contoso-platform         Platform
contoso-landingzones     Landing Zones
contoso-lz-corp          Corp (private, hub-connected)
contoso-lz-online        Online (internet-facing)
contoso-sandbox          Sandbox
contoso-decommissioned   Decommissioned

$ az account management-group show --name contoso --expand --recurse \
    --query "{name:displayName, children:children[].{name:displayName, type:type, \
              children:children[].{name:displayName, type:type}}}" -o yaml
name: Contoso
children:
- name: Platform
  type: Microsoft.Management/managementGroups
  children:
  - name: Identity
    type: Microsoft.Management/managementGroups
  - name: Management
    type: Microsoft.Management/managementGroups
  - name: Connectivity
    type: Microsoft.Management/managementGroups
- name: Landing Zones
  type: Microsoft.Management/managementGroups
  children:
  - name: Corp (private, hub-connected)
    type: Microsoft.Management/managementGroups
  - name: Online (internet-facing)
    type: Microsoft.Management/managementGroups
- name: Sandbox
  type: Microsoft.Management/managementGroups
  children: null
```

Move a subscription between management groups (this is the highest-leverage single command in Azure governance — it re-parents every inherited policy and role assignment at once):

```bash
$ az account management-group subscription add \
    --name contoso-lz-corp \
    --subscription 8f3d4c21-9b6a-4d8e-b1f2-6c5a7e9d0341
$ az account management-group show --name contoso-lz-corp --expand \
    --query "children[?type=='/subscriptions'].{name:displayName, id:name}" -o table
Name             Id
---------------  ------------------------------------
sub-orders-prod  8f3d4c21-9b6a-4d8e-b1f2-6c5a7e9d0341
```

### 5.3 Region and zone discovery

```bash
$ az account list-locations \
    --query "[?metadata.regionType=='Physical' && metadata.geographyGroup=='US'] \
             .{name:name, display:displayName, physical:metadata.physicalLocation, \
               pair:metadata.pairedRegion[0].name, category:metadata.regionCategory}" -o table
Name          Display          Physical      Pair          Category
------------  ---------------  ------------  ------------  -----------
centralus     Central US       Iowa          eastus2       Recommended
eastus        East US          Virginia      westus        Recommended
eastus2       East US 2        Virginia      centralus     Recommended
northcentralus North Central US Illinois     southcentralus Other
southcentralus South Central US Texas        northcentralus Recommended
westus         West US         California    eastus        Other
westus2        West US 2       Washington    westcentralus Recommended
westus3        West US 3       Phoenix       eastus        Recommended
```

Which SKUs are actually zone-capable in a region, and where are they restricted:

```bash
$ az vm list-skus --location eastus --size Standard_D8ds_v5 --zone -o table
ResourceType     Locations    Name              Zones    Restrictions
---------------  -----------  ----------------  -------  --------------
virtualMachines  eastus       Standard_D8ds_v5  1,2,3    None

$ az vm list-skus --location westus3 --size Standard_M --zone \
    --query "[].{name:name, zones:locationInfo[0].zones, \
                 restricted:restrictions[0].reasonCode}" -o table
Name                Zones      Restricted
------------------  ---------  ---------------------------
Standard_M128ms     ['1']      NotAvailableForSubscription
Standard_M64ms      ['1','2']  None
```

> `NotAvailableForSubscription` is a **subscription-level** restriction, not a regional one. It is resolved by a quota/capacity request, not by choosing another region.

### 5.4 Resource groups and resource IDs

```bash
$ az group create -n rg-orders-prod-eastus -l eastus \
    --tags workload=orders environment=prod costCenter=CC-4412 failureDomain=primary \
    --query "{id:id, location:location, state:properties.provisioningState}" -o json
{
  "id": "/subscriptions/8f3d4c21-9b6a-4d8e-b1f2-6c5a7e9d0341/resourceGroups/rg-orders-prod-eastus",
  "location": "eastus",
  "state": "Succeeded"
}

$ az group list --query "[?tags.environment=='prod'].{name:name, location:location, workload:tags.workload}" -o table
Name                     Location    Workload
-----------------------  ----------  ----------
rg-orders-prod-eastus    eastus      orders
rg-orders-prod-westus3   westus3     orders
rg-orders-prod-global    eastus      orders
```

### 5.5 Deployment Stacks — resource-group deletion protection that actually holds

Azure Blueprints is deprecated (retirement 11 July 2026). The current mechanism for "this resource group cannot be deleted, even by an Owner" is a **deployment stack** with deny settings, which creates a real deny assignment.

```bash
$ az stack sub create \
    --name stack-orders-prod \
    --location eastus \
    --template-file workload/subscription.bicep \
    --parameters workload=orders environment=prod costCenter=CC-4412 owner=sre-platform \
    --deny-settings-mode denyDelete \
    --deny-settings-excluded-actions "Microsoft.Compute/virtualMachines/restart/action" \
    --action-on-unmanage deleteResources \
    --yes \
    --query "{name:name, state:provisioningState, denyMode:denySettings.mode}" -o json
{
  "denyMode": "denyDelete",
  "name": "stack-orders-prod",
  "state": "succeeded"
}

$ az group delete -n rg-orders-prod-eastus --yes
(RequestDisallowedByAzure) Resource '/subscriptions/8f3d4c21-.../resourceGroups/rg-orders-prod-eastus'
was disallowed by a deny assignment created by deployment stack 'stack-orders-prod'.
Code: RequestDisallowedByAzure
```

---

## 6. Verification and failure diagnosis

### 6.1 Diagnostic decision table

| Symptom / error code | Layer | Root cause | First command | Fix |
|---|---|---|---|---|
| `ZonalAllocationFailed` | Zone | No capacity for that SKU in that **logical** zone right now | `az vm list-skus -l $LOC --size $SKU --zone -o table` | Retry another zone, another SKU family, or use a Capacity Reservation Group |
| `AllocationFailed` | Region | Regional capacity exhaustion for the SKU/cluster | Same, plus try a different region | Change SKU family or region; open a capacity request |
| `SkuNotAvailable` | Subscription | SKU not offered in the region **or** restricted for this subscription | `az vm list-skus -l $LOC --size $SKU --query "[].restrictions"` | Quota request, or different SKU |
| `RequestDisallowedByPolicy` | MG / subscription | A `Deny` policy in the scope chain | `az policy state list --filter "complianceState eq 'NonCompliant'"` | Fix the resource, or add a scoped exemption |
| `RequestDisallowedByAzure` | Any | Deny assignment (deployment stack / managed app) | `az rest` on `Microsoft.Authorization/denyAssignments` | Delete/update the stack |
| `ScopeLocked` | RG / resource | `CanNotDelete` or `ReadOnly` lock | `az lock list --resource-group $RG -o table` | Remove the lock, then re-lock |
| `MissingSubscriptionRegistration` | Subscription | Resource provider not registered | `az provider show -n $NS --query registrationState` | `az provider register -n $NS --wait` |
| `TooManyRequests` / HTTP 429 | Subscription | ARM throttle bucket exhausted | Read `Retry-After` + `x-ms-ratelimit-*` headers | Back off exponentially; split subscriptions; batch with Resource Graph |
| `ResourceGroupNotFound` during DR | RG metadata region | RG metadata lives in the failed region | `az group show -n $RG --query location` | Pre-place DR resource groups in the DR region |
| `AuthorizationFailed` after a tenant move | Tenant | Subscription moved tenants → **all** RBAC assignments are orphaned | `az role assignment list --all -o table` | Re-create assignments against the new tenant's principals |
| Cross-sub "same zone" is slow / not HA | Zone mapping | Logical zone `1` ≠ same physical zone across subscriptions | Locations API `availabilityZoneMappings` | Resolve physical zones on both sides and align |

### 6.2 Verifying zone alignment across subscriptions

This is the check nobody runs, and it is three lines:

```bash
$ for SUB in 8f3d4c21-9b6a-4d8e-b1f2-6c5a7e9d0341 1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d; do
    echo "=== $SUB ==="
    az rest --method get \
      --url "https://management.azure.com/subscriptions/$SUB/locations?api-version=2022-12-01" \
      --query "value[?name=='eastus'].availabilityZoneMappings[]" -o table
  done
=== 8f3d4c21-9b6a-4d8e-b1f2-6c5a7e9d0341 ===
LogicalZone    PhysicalZone
-------------  --------------
1              eastus-az1
2              eastus-az3
3              eastus-az2
=== 1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d ===
LogicalZone    PhysicalZone
-------------  --------------
1              eastus-az2
2              eastus-az1
3              eastus-az3
```

**Interpretation:** an app in sub A zone `1` (physical `az1`) and a database in sub B zone `1` (physical `az2`) are in *different* physical zones. Cross-zone latency and cross-zone failure independence apply, contrary to what both teams believe. If you needed co-location for latency, you must target sub B's logical zone `2`.

### 6.3 Fleet-wide zone audit with Azure Resource Graph

Resource Graph queries across every subscription in a management group with one request — and it is not subject to per-subscription ARM throttling in the same way, which makes it the correct tool for inventory.

```bash
$ az extension add --name resource-graph --only-show-errors

$ az graph query --management-groups contoso-landingzones --first 1000 -q "
resources
| where type in~ (
    'microsoft.compute/virtualmachines',
    'microsoft.compute/disks',
    'microsoft.network/publicipaddresses')
| extend zoneCount = array_length(zones)
| extend posture = case(
    zoneCount == 0, 'REGIONAL (no zone guarantee)',
    zoneCount == 1, strcat('ZONAL: ', tostring(zones[0])),
    'ZONE-REDUNDANT')
| summarize count() by type, location, posture
| order by type asc, location asc
" -o table

Count_  Location   Posture                        Type
------  ---------  -----------------------------  -----------------------------------
    18  eastus     ZONAL: 1                       microsoft.compute/disks
    17  eastus     ZONAL: 2                       microsoft.compute/disks
    17  eastus     ZONAL: 3                       microsoft.compute/disks
     6  westus3    REGIONAL (no zone guarantee)   microsoft.compute/disks
    18  eastus     ZONAL: 1                       microsoft.compute/virtualmachines
    17  eastus     ZONAL: 2                       microsoft.compute/virtualmachines
    17  eastus     ZONAL: 3                       microsoft.compute/virtualmachines
     6  westus3    REGIONAL (no zone guarantee)   microsoft.compute/virtualmachines
     4  eastus     ZONE-REDUNDANT                 microsoft.network/publicipaddresses
     2  westus3    REGIONAL (no zone guarantee)   microsoft.network/publicipaddresses
```

Six VMs and two public IPs in `westus3` have **no zone guarantee**. That is your DR region. Your DR plan assumes it survives a zone failure; it does not.

Find resource groups whose metadata region differs from the resources they hold:

```bash
$ az graph query --management-groups contoso -q "
resources
| project resourceGroup, subscriptionId, resourceLocation = location
| where resourceLocation !in ('global', 'Global')
| join kind=inner (
    resourcecontainers
    | where type =~ 'microsoft.resources/subscriptions/resourcegroups'
    | project resourceGroup = name, subscriptionId, rgLocation = location
  ) on resourceGroup, subscriptionId
| where resourceLocation != rgLocation
| summarize resources = count() by resourceGroup, rgLocation, resourceLocation
| order by resources desc
" -o table

Resources  ResourceGroup            RgLocation    ResourceLocation
---------  -----------------------  ------------  ------------------
       11  rg-orders-prod-eastus    eastus        westus3
        3  rg-shared-tools          eastus        northeurope
```

Eleven DR resources are managed by an `eastus` metadata record. During an `eastus` control-plane incident they are unmanageable.

### 6.4 Policy compliance and denial forensics

```bash
$ az policy state summarize \
    --management-group contoso-landingzones \
    --query "value[0].policyAssignments[].{assignment:policyAssignmentId, \
             nonCompliant:results.nonCompliantResources}" -o table
Assignment                                                                        NonCompliant
--------------------------------------------------------------------------------  --------------
/providers/microsoft.management/managementgroups/.../resilience-baseline                        7

$ az policy state list \
    --management-group contoso-landingzones \
    --filter "complianceState eq 'NonCompliant'" \
    --apply "groupby((resourceType, policyDefinitionName), aggregate(\$count as total))" \
    -o table
```

When a deployment is blocked, the error names the assignment and the definition — resolve them before arguing:

```
$ az storage account create -n storderprodwus3 -g rg-orders-prod-westus3 \
    -l westus3 --sku Standard_LRS
(RequestDisallowedByPolicy) Resource 'storderprodwus3' was disallowed by policy.
Reasons: 'This deployment violates the Contoso resilience baseline. Storage accounts must use a
zone-redundant SKU (Standard_ZRS, Standard_GZRS, Standard_RAGZRS or Premium_ZRS).'.
See error details for policy resource IDs.
Code: RequestDisallowedByPolicy
```

```bash
$ az policy assignment show --name resilience-baseline \
    --scope /providers/Microsoft.Management/managementGroups/contoso-landingzones \
    --query "{definition:policyDefinitionId, enforcement:enforcementMode, params:parameters}" -o json
```

Scoped, time-boxed exemption — never disable the assignment:

```bash
$ az policy exemption create \
    --name exempt-legacy-lrs-migration \
    --policy-assignment "/providers/Microsoft.Management/managementGroups/contoso-landingzones/providers/Microsoft.Authorization/policyAssignments/resilience-baseline" \
    --policy-definition-reference-ids zrStorage \
    --exemption-category Waiver \
    --scope "/subscriptions/8f3d4c21-9b6a-4d8e-b1f2-6c5a7e9d0341/resourceGroups/rg-legacy-migration" \
    --expires-on 2026-12-31T23:59:59Z \
    --description "Legacy LRS accounts pending migration; tracked in PLAT-2291."
```

### 6.5 Effective RBAC at a scope

```bash
$ az role assignment list \
    --scope "/subscriptions/8f3d4c21-9b6a-4d8e-b1f2-6c5a7e9d0341/resourceGroups/rg-orders-prod-eastus" \
    --include-inherited --include-groups \
    --query "[].{principal:principalName, role:roleDefinitionName, scope:scope}" -o table
Principal                      Role                        Scope
-----------------------------  --------------------------  ------------------------------------------------------------
sg-platform-owners@contoso.com  Owner                       /providers/Microsoft.Management/managementGroups/contoso
sg-sre-oncall@contoso.com       Contributor                 /providers/Microsoft.Management/managementGroups/contoso-lz-corp
sp-cicd-orders                  Contributor                 /subscriptions/8f3d4c21-.../resourceGroups/rg-orders-prod-eastus
sg-auditors@contoso.com         Reader                      /providers/Microsoft.Management/managementGroups/contoso
```

Three of the four assignments are **inherited from management groups**. Removing the resource-group assignment changes nothing for the first, second or fourth principal. This is the single most common RBAC misdiagnosis.

### 6.6 Validating a resource move before you attempt it

Moves fail *after* the API accepts them if any resource type in the set is non-movable. Validate first:

```bash
$ SRC="/subscriptions/8f3d4c21-9b6a-4d8e-b1f2-6c5a7e9d0341/resourceGroups/rg-orders-prod-eastus"
$ az resource invoke-action \
    --action validateMoveResources \
    --ids "$SRC" \
    --request-body "{
      \"resources\": [
        \"$SRC/providers/Microsoft.Storage/storageAccounts/stordersprodeus\",
        \"$SRC/providers/Microsoft.Network/publicIPAddresses/pip-orders-prod-eastus\"
      ],
      \"targetResourceGroup\": \"/subscriptions/8f3d4c21-9b6a-4d8e-b1f2-6c5a7e9d0341/resourceGroups/rg-orders-prod-consolidated\"
    }"

{
  "error": {
    "code": "ResourceMoveValidationFailed",
    "message": "Resource move validation failed. Please see details. Diagnostic information: ...",
    "details": [
      {
        "code": "ResourceMoveNotSupported",
        "target": ".../publicIPAddresses/pip-orders-prod-eastus",
        "message": "Resource move is not supported for resources that have zones. Public IP 'pip-orders-prod-eastus' has zones ['1','2','3']."
      }
    ]
  }
}
```

**Move rules worth memorising:** the source and target resource groups are **both locked** for the duration of the move; you cannot change region with a move (a move relocates the ARM record, not the bits); many zonal resources cannot be moved at all; and moving across subscriptions requires the same tenant and the provider registered in the destination subscription.

### 6.7 Region and resource health during an incident

```bash
$ az rest --method get \
    --url "https://management.azure.com/subscriptions/$SUB/providers/Microsoft.ResourceHealth/availabilityStatuses?api-version=2023-07-01-preview&\$filter=properties/availabilityState%20ne%20'Available'" \
    --query "value[].{resource:id, state:properties.availabilityState, \
             summary:properties.summary, since:properties.occuredTime}" -o table

Resource                                                          State        Summary                                             Since
----------------------------------------------------------------  -----------  --------------------------------------------------  --------------------------
/subscriptions/.../virtualMachines/vm-orders-03                    Unavailable  Host server power event in availability zone         2026-09-04T09:12:44Z
/subscriptions/.../virtualMachines/vm-orders-06                    Unavailable  Host server power event in availability zone         2026-09-04T09:12:51Z
```

Two VMs down, both in the same logical zone. Confirm the correlation before you page anyone else:

```bash
$ az vm show -g rg-orders-prod-eastus -n vm-orders-03 --query "zones" -o tsv
2
$ az vm show -g rg-orders-prod-eastus -n vm-orders-06 --query "zones" -o tsv
2
```

Then translate logical zone `2` to the physical zone Microsoft will name in the Service Health advisory:

```bash
$ az rest --method get \
    --url "https://management.azure.com/subscriptions/$SUB/locations?api-version=2022-12-01" \
    --query "value[?name=='eastus'].availabilityZoneMappings[?logicalZone=='2'].physicalZone" -o tsv
eastus-az3
```

Now the advisory that says "customers in `eastus-az3` may experience…" is actionable in your subscription.

### 6.8 Pre-flight checklist for any new landing zone

```bash
#!/usr/bin/env bash
# preflight.sh — verify the architectural preconditions before deploying a workload.
set -euo pipefail

SUB="${1:?usage: preflight.sh <subscription-id> <region> <mg-id>}"
LOC="${2:?}"
MG="${3:?}"

az account set --subscription "$SUB"

echo "== 1. Subscription is enabled and in the expected management group =="
az account show --query "{name:name, state:state, tenant:tenantId}" -o json
az account management-group show --name "$MG" --expand \
  --query "children[?name=='$SUB']" -o json | grep -q "$SUB" \
  && echo "OK: subscription is a child of $MG" \
  || { echo "FAIL: subscription is not under $MG"; exit 1; }

echo "== 2. Region has availability zones and a documented pair =="
az account list-locations \
  --query "[?name=='$LOC'].{region:name, pair:metadata.pairedRegion[0].name, category:metadata.regionCategory}" -o table
ZONES=$(az rest --method get \
  --url "https://management.azure.com/subscriptions/$SUB/locations?api-version=2022-12-01" \
  --query "length(value[?name=='$LOC'].availabilityZoneMappings[])" -o tsv)
[ "$ZONES" -ge 3 ] && echo "OK: $ZONES availability zones" \
  || { echo "FAIL: region $LOC exposes $ZONES zones to this subscription"; exit 1; }

echo "== 3. Required resource providers are registered =="
for NS in Microsoft.Compute Microsoft.Network Microsoft.Storage \
          Microsoft.ContainerService Microsoft.KeyVault Microsoft.Insights; do
  STATE=$(az provider show -n "$NS" --query registrationState -o tsv)
  printf '  %-32s %s\n' "$NS" "$STATE"
  [ "$STATE" = "Registered" ] || az provider register -n "$NS" --wait
done

echo "== 4. Compute quota headroom in the region =="
az vm list-usage --location "$LOC" \
  --query "[?currentValue > \`0\` || contains(localName, 'Total Regional')] \
           .{quota:localName, used:currentValue, limit:limit}" -o table

echo "== 5. Governance is inherited, not absent =="
az policy assignment list --scope "/providers/Microsoft.Management/managementGroups/$MG" \
  --query "[].{name:name, enforcement:enforcementMode}" -o table

echo "== 6. No blocking locks =="
az lock list --query "[].{name:name, level:level, scope:id}" -o table

echo "PREFLIGHT PASSED"
```

```
$ ./preflight.sh 8f3d4c21-9b6a-4d8e-b1f2-6c5a7e9d0341 eastus contoso-lz-corp
== 1. Subscription is enabled and in the expected management group ==
{
  "name": "sub-orders-prod",
  "state": "Enabled",
  "tenant": "72f988bf-86f1-41af-91ab-2d7cd011db47"
}
OK: subscription is a child of contoso-lz-corp
== 2. Region has availability zones and a documented pair ==
Region    Pair    Category
--------  ------  -----------
eastus    westus  Recommended
OK: 3 availability zones
== 3. Required resource providers are registered ==
  Microsoft.Compute                Registered
  Microsoft.Network                Registered
  Microsoft.Storage                Registered
  Microsoft.ContainerService       NotRegistered
  Microsoft.KeyVault               Registered
  Microsoft.Insights               Registered
== 4. Compute quota headroom in the region ==
Quota                                    Used    Limit
---------------------------------------  ------  -------
Total Regional vCPUs                     186     350
Standard DDSv5 Family vCPUs              144     256
Standard ESv5 Family vCPUs               42      128
== 5. Governance is inherited, not absent ==
Name                  Enforcement
--------------------  -------------
resilience-baseline   Default
deny-public-blob      Default
== 6. No blocking locks ==
PREFLIGHT PASSED
```

---

## 7. Design rules distilled

1. **Choose the region for latency, residency, service availability and price — in that order — then verify zone support for every SKU you need.** Region feature parity is not uniform; "Recommended" regions get new services first.
2. **Default to zone-redundant SKUs for anything stateful**, and to ≥ 3 instances across ≥ 3 zones for anything stateless. Zonal pinning is a deliberate choice for latency or licensing, not a default.
3. **Never trust logical zone numbers across subscriptions.** Resolve physical zones from the Locations API whenever co-location or anti-affinity crosses a subscription boundary.
4. **Place DR resource groups in the DR region.** The resource group's `location` is a control-plane dependency, and DR is exactly when you need the control plane.
5. **Management groups carry governance; subscriptions carry quota and throttling; resource groups carry lifecycle.** Split subscriptions on quota, throttling and compliance — not on "we want a separate bill", which tags and management-group cost views already give you.
6. **Assign RBAC and Policy as high in the tree as is correct, and no higher.** Inheritance is additive and irrevocable downward; a mistake at the tenant root has no local remedy.
7. **Protect resource groups with deployment stacks (`denyDelete`) plus `CanNotDelete` locks**, since `az group delete` is a single command with an unbounded blast radius. Blueprints is retiring on 11 July 2026 — migrate to template specs plus deployment stacks.
8. **Compute composite SLAs, not component SLAs**, and remember that region pairs give you *platform* replication and update sequencing — never application failover. Multi-region active/active is something you build, not something you select.

---

## 8. Referencias

**Study guide and exam scope**
- AZ-900 study guide — https://learn.microsoft.com/en-us/credentials/certifications/resources/study-guides/az-900
- Microsoft Azure Fundamentals learning path — https://learn.microsoft.com/en-us/training/paths/microsoft-azure-fundamentals-describe-cloud-concepts/

**Physical architecture**
- Azure geographies, regions and availability zones — https://learn.microsoft.com/en-us/azure/reliability/regions-overview
- What are Azure availability zones? — https://learn.microsoft.com/en-us/azure/reliability/availability-zones-overview
- Availability zone service and region support — https://learn.microsoft.com/en-us/azure/reliability/availability-zones-region-support
- Azure region pairs / cross-region replication — https://learn.microsoft.com/en-us/azure/reliability/regions-paired
- Azure regions list — https://learn.microsoft.com/en-us/azure/reliability/regions-list
- Availability sets, fault domains and update domains — https://learn.microsoft.com/en-us/azure/virtual-machines/availability
- Azure global infrastructure — https://datacenters.microsoft.com/globe/explore
- Reliability guidance by service — https://learn.microsoft.com/en-us/azure/reliability/overview-reliability-guidance

**Logical hierarchy and governance**
- Azure Resource Manager overview — https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/overview
- Manage resource groups — https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/manage-resource-groups-cli
- Organize your Azure resources with management groups — https://learn.microsoft.com/en-us/azure/governance/management-groups/overview
- Understand scope in Azure RBAC — https://learn.microsoft.com/en-us/azure/role-based-access-control/scope-overview
- Azure Policy overview and effects — https://learn.microsoft.com/en-us/azure/governance/policy/concepts/effects
- Azure Policy exemption structure — https://learn.microsoft.com/en-us/azure/governance/policy/concepts/exemption-structure
- Lock resources to prevent changes — https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/lock-resources
- Move resources to a new resource group or subscription — https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/move-resource-group-and-subscription
- Move operation support by resource type — https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/move-support-resources

**Limits, throttling and quotas**
- Azure subscription and service limits, quotas and constraints — https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/azure-subscription-service-limits
- Throttling Resource Manager requests — https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/request-limits-and-throttling
- Resource providers and types — https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/resource-providers-and-types

**Infrastructure as code**
- Bicep deployment scopes — https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/deploy-to-management-group
- Subscription-scope deployments — https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/deploy-to-subscription
- Tenant-scope deployments — https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/deploy-to-tenant
- ARM template what-if — https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/deploy-what-if
- Azure deployment stacks — https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/deployment-stacks
- Azure Blueprints deprecation and migration — https://learn.microsoft.com/en-us/azure/governance/blueprints/overview
- Terraform `azurerm_management_group` — https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/management_group

**Cloud Adoption Framework**
- Azure landing zone design areas — https://learn.microsoft.com/en-us/azure/cloud-adoption-framework/ready/landing-zone/design-areas
- Management group and subscription organization — https://learn.microsoft.com/en-us/azure/cloud-adoption-framework/ready/landing-zone/design-area/resource-org-management-groups
- Subscription vending — https://learn.microsoft.com/en-us/azure/cloud-adoption-framework/ready/landing-zone/design-area/subscription-vending
- Naming and tagging conventions — https://learn.microsoft.com/en-us/azure/cloud-adoption-framework/ready/azure-best-practices/resource-naming

**Query, health and SLA**
- Azure Resource Graph query language — https://learn.microsoft.com/en-us/azure/governance/resource-graph/concepts/query-language
- Azure Resource Health overview — https://learn.microsoft.com/en-us/azure/service-health/resource-health-overview
- Locations - List (REST, includes `availabilityZoneMappings`) — https://learn.microsoft.com/en-us/rest/api/resources/subscriptions/list-locations
- Service Level Agreements for Microsoft Online Services — https://www.microsoft.com/licensing/docs/view/Service-Level-Agreements-SLA-for-Online-Services
- Bandwidth pricing (inter-zone / inter-region data transfer) — https://azure.microsoft.com/en-us/pricing/details/bandwidth/

**AKS and zone awareness**
- Create an AKS cluster that uses availability zones — https://learn.microsoft.com/en-us/azure/aks/availability-zones
- Azure Disk CSI driver storage class parameters — https://learn.microsoft.com/en-us/azure/aks/azure-csi-disk-storage-provision
- Kubernetes pod topology spread constraints — https://kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints/
- Kubernetes well-known labels (`topology.kubernetes.io/zone`) — https://kubernetes.io/docs/reference/labels-annotations-taints/#topologykubernetesiozone

**Sovereign clouds**
- Azure Government documentation — https://learn.microsoft.com/en-us/azure/azure-government/
- Azure operated by 21Vianet — https://learn.microsoft.com/en-us/azure/china/