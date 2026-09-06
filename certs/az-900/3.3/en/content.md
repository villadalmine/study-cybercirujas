# 3.3 — Features and Tools for Managing and Deploying Azure Resources

**Certification:** AZ-900 (Microsoft Azure Fundamentals) · Exam version 2026-07-20
**Domain:** Describe Azure management and governance · **Exam weight:** 8.33 %
**Profile:** Principal Platform Architect / Senior SRE

---

## 1. The production problem: who owns the truth about your estate?

Every Azure control action — a click in the portal, an `az` command, a Terraform apply, an SDK call from a controller, a REST request from a CI runner — terminates in the **same** endpoint: `https://management.azure.com`. That endpoint is **Azure Resource Manager (ARM)**, the *control plane*. There is no side door. This single fact is the architectural centre of this topic, and it produces the three failure modes SRE teams actually spend time on:

**Failure mode 1 — Click-ops drift.** An on-call engineer resizes a VM at 03:00 in the portal to stop paging. The change is real, it is logged in the Activity Log, and it is invisible to the Bicep repository that supposedly describes that environment. Six weeks later a pipeline runs `az deployment group create` in **Complete** mode and silently reverts the fix — or worse, deletes the emergency NSG rule that came with it. The portal is a *client*, never a source of truth.

**Failure mode 2 — Undeclared blast radius.** A "small" template change alters a property that the resource provider treats as immutable. ARM's answer is not "update"; it is *delete and recreate*. On a `Microsoft.Storage/storageAccounts` or a `Microsoft.Sql/servers` that is a data-loss event. The mitigation is not care; it is a **mandatory `what-if` preflight gate** and **deny settings on deployment stacks**.

**Failure mode 3 — The estate is bigger than Azure.** Real infrastructure is 400 Linux VMs in a Frankfurt datacentre, 60 Windows servers in AWS, three on-prem Kubernetes clusters, and only *then* the Azure subscriptions. Policy, patching, inventory, RBAC and log collection must be uniform across all of them or compliance reporting is fiction. **Azure Arc** exists to project those non-Azure machines into ARM as first-class resource IDs so that one policy engine, one RBAC model, and one query language (Resource Graph / KQL) cover everything.

The tools in this topic map one-to-one onto those problems:

| Problem | Tool | What it actually gives you |
|---|---|---|
| Discoverability, incident triage, one-off inspection | **Azure portal** | Human-facing client over ARM REST; no determinism, full auditability |
| Scripted/imperative operations, glue, break-glass | **Azure CLI (`az`) / Azure PowerShell (`Az`)** | Imperative, procedural, exit codes, JMESPath/objects for pipelines |
| Zero-install, pre-authenticated, pre-tooled shell | **Azure Cloud Shell** | Ephemeral container + optional persistent Azure Files home |
| Declarative, reviewable, idempotent, reproducible estate | **ARM templates / Bicep / deployment stacks** | Infrastructure as Code with dependency graph, preview, lifecycle |
| Non-Azure and multicloud resources under one control plane | **Azure Arc** | ARM resource IDs, managed identity, policy, extensions for hybrid |

---

## 2. Azure Resource Manager: the control plane in detail

### 2.1 The request pipeline

Every ARM write request traverses a fixed sequence. Knowing this order is what lets you read an error message and know *which* stage rejected you:

```
Client (portal / az / PowerShell / SDK / REST / Terraform)
        │  HTTPS + Bearer JWT (Microsoft Entra ID)
        ▼
[1] Authentication            → 401 InvalidAuthenticationToken
        ▼
[2] Azure RBAC evaluation     → 403 AuthorizationFailed
        ▼
[3] Azure Policy evaluation   → 403 RequestDisallowedByPolicy
    (Deny / Modify / Append / DeployIfNotExists)
        ▼
[4] Resource lock check       → 409 ScopeLocked
        ▼
[5] Template validation +
    provider preflight        → 400 InvalidTemplate / SkuNotAvailable / QuotaExceeded
        ▼
[6] Dispatch to Resource Provider (Microsoft.Compute, Microsoft.Storage, …)
        ▼
[7] Async provisioning        → 202 Accepted + Azure-AsyncOperation header
```

Two consequences matter operationally:

- **Policy runs before the resource provider.** A `RequestDisallowedByPolicy` is not a quota, capacity or syntax problem — no resource was ever attempted. The error payload contains the `policyAssignmentId` and `policyDefinitionId`; that is your entire root cause.
- **Most writes are asynchronous.** ARM returns `202` and a polling URL. A CLI command that returns quickly has not finished; `--no-wait` makes this explicit, and the absence of `--no-wait` means the CLI is polling on your behalf.

### 2.2 Scopes and resource IDs

ARM is hierarchical. Every management operation targets one of four scopes, and inheritance flows downward for RBAC, Policy and tags (with type-specific rules):

```
Management group (up to 6 levels below root, tenant-wide)
  └── Subscription        (billing + quota boundary)
        └── Resource group (lifecycle + region-metadata boundary, non-nestable)
              └── Resource
                    └── Extension resource (locks, diagnostic settings, role assignments, Arc extensions)
```

The canonical resource ID — the primary key of the entire platform:

```
/subscriptions/8f4a1c2e-9b7d-4f0a-a6c1-2d3e4f5a6b7c
  /resourceGroups/rg-platform-prod-weu
  /providers/Microsoft.Storage/storageAccounts/platprodx7k2m9
  /blobServices/default
```

An Arc-enabled on-prem server gets an ID of exactly the same shape:

```
/subscriptions/8f4a1c2e-.../resourceGroups/rg-arc-prod-weu
  /providers/Microsoft.HybridCompute/machines/node-fra-01
```

That symmetry is the whole point of Arc: once a machine has an ARM ID, every ARM-scoped mechanism (RBAC, Policy, tags, Resource Graph, Defender for Cloud, Monitor, locks) applies to it without modification.

### 2.3 Resource providers

A resource provider is the microservice implementing a resource family. It must be **registered per subscription** before its types can be deployed. Unregistered providers are one of the most common first-deployment failures in a fresh subscription.

```console
$ az provider list --query "[?registrationState=='NotRegistered'].namespace" --output tsv | head -8
Microsoft.ContainerService
Microsoft.HybridCompute
Microsoft.Kubernetes
Microsoft.KubernetesConfiguration
Microsoft.ExtendedLocation
Microsoft.GuestConfiguration
Microsoft.PolicyInsights
Microsoft.ResourceConnector

$ az provider register --namespace Microsoft.HybridCompute --wait
$ az provider show --namespace Microsoft.HybridCompute --query "{ns:namespace, state:registrationState}" -o table
Ns                        State
------------------------  ----------
Microsoft.HybridCompute   Registered
```

Discovering valid API versions and locations for a type — the reflex that replaces guessing in template authoring:

```console
$ az provider show --namespace Microsoft.Storage \
    --query "resourceTypes[?resourceType=='storageAccounts'].apiVersions[0:5]" -o tsv
2024-01-01	2023-05-01	2023-04-01	2023-01-01	2022-09-01
```

### 2.4 Limits and throttling you will hit at scale

| Limit | Value | Operational consequence |
|---|---|---|
| Resource groups per subscription | 980 | Landing-zone naming must be planned, not organic |
| Resources per resource group, per type | 800 (many types exempt) | Split by lifecycle, not by team |
| Deployments in RG history | 800 (ARM auto-prunes near the cap) | CI running per-commit deployments must use unique names + accept pruning |
| Template file size / parameter file | 4 MB / 4 MB | Decompose into modules and linked templates |
| Parameters / variables / resources / outputs per template | 256 / 256 / 800 / 64 | Outputs limit bites hard on loop-generated templates |
| Subscription write requests | Token-bucket per region/service/principal (legacy documented figure: 1,200 writes/h) | Read `x-ms-ratelimit-remaining-subscription-writes` and back off |
| Tags per resource | 50 | Tag taxonomy must be curated centrally |

Observing throttling budget directly:

```console
$ az group show --name rg-platform-prod-weu --debug 2>&1 | grep -i 'ratelimit-remaining'
msrest.http_logger : 'x-ms-ratelimit-remaining-subscription-reads': '11997'
```

When you exhaust the bucket ARM returns `429 Too Many Requests` with a `Retry-After` header. The correct client behaviour is exponential backoff honouring that header — never a tight retry loop, which is how one CI runner throttles an entire subscription for every other consumer.

---

## 3. Management surfaces compared

| Surface | Model | Idempotent | Auditable as code | Drift detection | Best production use |
|---|---|---|---|---|---|
| **Azure portal** | Point-and-click over REST | No | No (Activity Log only) | None | Discovery, triage, reading metrics, one-off inspection |
| **Azure CLI (`az`)** | Imperative, Python, cross-platform, JSON/JMESPath | Per-command only | Weakly (scripts drift) | None | Glue, break-glass, day-2 ops, CI steps around IaC |
| **Azure PowerShell (`Az`)** | Imperative, .NET objects, pipeline-native | Per-command only | Weakly | None | Windows-centric estates, object-pipeline reporting |
| **ARM templates (JSON)** | Declarative | Yes | Yes | via `what-if` | Marketplace/managed-app artifacts, exported baselines |
| **Bicep** | Declarative DSL → transpiles to ARM JSON | Yes | Yes | via `what-if` | Default IaC for Azure-only estates |
| **Deployment stacks** | Declarative + lifecycle object | Yes | Yes | Managed-resource inventory + deny settings | Landing zones, anything that must not be hand-edited |
| **Terraform / OpenTofu** | Declarative + external state | Yes | Yes | `plan` (strong) | Multicloud, or where state-based drift detection is required |
| **Azure Developer CLI (`azd`)** | App-centric wrapper (Bicep + build + deploy) | Yes | Yes | Inherits Bicep | Application teams shipping app+infra together |
| **REST / SDKs** | Programmatic | Depends | N/A | None | Controllers, operators, platform tooling |

### 3.1 ARM JSON vs Bicep vs Terraform — the honest trade-offs

| Dimension | ARM JSON | Bicep | Terraform (AzureRM) |
|---|---|---|---|
| State storage | **None** — ARM *is* the state | **None** | External state file (blob container + lease) — must be secured and backed up |
| Day-0 support for new Azure APIs | Immediate | Immediate | Lags provider releases (mitigated by `azapi` provider) |
| Preview quality | `what-if` (good, some noise) | `what-if` (same engine) | `plan` (excellent, but only for state-known resources) |
| Deletion of removed resources | Complete mode (blunt) or stacks (precise) | Same | `plan`/`apply` removes them naturally |
| Multicloud | No | No | Yes |
| Readability | Poor (`[concat(...)]` string soup) | Good (typed, IntelliSense, modules) | Good |
| Secret handling | Key Vault reference in parameter file | Key Vault reference / `getSecret()` | State file may contain secrets — encrypt at rest |
| Failure atomicity | Partial (per-resource); no rollback except `rollbackToLastSuccessful` | Same | Partial; state may desynchronise |
| Learning cost | High | Low–medium | Medium |

**Architect's rule:** Bicep for Azure-only platform baselines (no state to lose, no provider lag). Terraform when the same pipeline must also create Cloudflare DNS, GitHub repos and AWS IAM. Never both for the same resource — dual ownership guarantees a fight over drift.

### 3.2 Deployment modes — the most dangerous switch in ARM

| Mode | Resources in template | Resources in RG but **not** in template | Available at |
|---|---|---|---|
| **Incremental** (default) | Created or updated | **Left untouched** | RG, subscription, MG, tenant |
| **Complete** | Created or updated | **DELETED** | Resource group scope only |
| **Validate** | Nothing deployed; template + preflight checked | Untouched | All scopes |

```console
# Incremental (default) — safe, additive, cannot delete
$ az deployment group create -g rg-platform-prod-weu -f main.bicep --mode Incremental

# Complete — deletes everything in the RG that the template does not declare
$ az deployment group create -g rg-platform-prod-weu -f main.bicep --mode Complete --confirm-with-what-if
```

Complete mode is the correct tool for enforcing "this resource group contains exactly this and nothing else" — and it is also how teams delete production. Never run it without `--confirm-with-what-if` or a reviewed `what-if` artifact in the pipeline.

### 3.3 Deployment stacks — lifecycle as a first-class object

A deployment stack (`Microsoft.Resources/deploymentStacks`) is a resource that **owns** a set of managed resources. It replaces Complete mode with explicit, reviewable semantics, and it adds *deny assignments* so humans cannot hand-edit stack-managed resources in the portal.

| Setting | Values | Meaning |
|---|---|---|
| `--action-on-unmanage` | `detachAll` / `deleteResources` / `deleteAll` | What happens to resources removed from the template or when the stack is deleted |
| `--deny-settings-mode` | `none` / `denyDelete` / `denyWriteAndDelete` | Deny assignment applied to managed resources |
| `--deny-settings-excluded-principals` | object IDs | Break-glass identities (e.g. the pipeline's own SPN) |
| `--deny-settings-apply-to-child-scopes` | flag | Extends the deny assignment to child resources |

```console
$ az stack group create \
    --name stack-platform-baseline \
    --resource-group rg-platform-prod-weu \
    --template-file main.bicep \
    --parameters main.prod.bicepparam \
    --action-on-unmanage deleteResources \
    --deny-settings-mode denyWriteAndDelete \
    --deny-settings-excluded-principals "3f2a8c17-5b41-4e6d-9a02-7c8b1d5e0f93" \
    --deny-settings-apply-to-child-scopes \
    --description "Platform baseline; owner=platform-sre; source=github.com/contoso/platform-iac" \
    --yes \
    --output table

Name                     ResourceGroup            ProvisioningState    DeploymentId
-----------------------  -----------------------  -------------------  ---------------------------------------------------
stack-platform-baseline  rg-platform-prod-weu     succeeded            /subscriptions/8f4a1c2e-.../deployments/stack-platform-baseline-2026-09-05...
```

Inspect what the stack believes it owns:

```console
$ az stack group show --name stack-platform-baseline -g rg-platform-prod-weu \
    --query "resources[].{id:id, status:status, denyStatus:denyStatus}" -o table

Id                                                                              Status    DenyStatus
------------------------------------------------------------------------------  --------  ------------------
.../Microsoft.OperationalInsights/workspaces/plat-prod-law                       managed   denyWriteAndDelete
.../Microsoft.Storage/storageAccounts/platprodx7k2m9                             managed   denyWriteAndDelete
.../Microsoft.Network/virtualNetworks/plat-prod-vnet                             managed   denyWriteAndDelete
.../Microsoft.KeyVault/vaults/plat-prod-kv-x7k2m9                                managed   denyWriteAndDelete
```

An engineer who now tries to delete that storage account in the portal receives `RequestDisallowedByAzure` / deny-assignment denial — enforcement, not documentation.

---

## 4. Complete infrastructure manifests

### 4.1 `main.bicep` — platform baseline (resource-group scope, uncut)

```bicep
// ---------------------------------------------------------------------------
// main.bicep - Platform baseline: observability workspace, hardened storage,
// network segment, RBAC-authorized Key Vault, and diagnostics wiring.
// Target scope: resource group
// ---------------------------------------------------------------------------
targetScope = 'resourceGroup'

@description('Short workload prefix used to derive every resource name.')
@minLength(3)
@maxLength(11)
param namePrefix string

@description('Deployment environment. Drives SKU redundancy and retention.')
@allowed([
  'dev'
  'stg'
  'prod'
])
param environment string = 'dev'

@description('Azure region. Defaults to the resource group region.')
param location string = resourceGroup().location

@description('Log Analytics retention in days.')
@minValue(30)
@maxValue(730)
param retentionInDays int = 30

@description('Address space for the workload virtual network.')
param vnetAddressPrefix string = '10.42.0.0/16'

@description('Address prefix for the application subnet.')
param appSubnetPrefix string = '10.42.1.0/24'

@description('Object ID of the Entra ID group granted Key Vault Secrets User.')
param secretsReaderPrincipalId string

@description('Common tags applied to every resource in this deployment.')
param tags object = {
  owner: 'platform-sre'
  costCenter: 'CC-4471'
  managedBy: 'bicep'
}

// ------------------------------- Variables ---------------------------------

var suffix = substring(uniqueString(resourceGroup().id), 0, 6)
var workspaceName = '${namePrefix}-${environment}-law'
var storageAccountName = toLower('${namePrefix}${environment}${suffix}')
var keyVaultName = '${namePrefix}-${environment}-kv-${suffix}'
var vnetName = '${namePrefix}-${environment}-vnet'
var nsgName = '${namePrefix}-${environment}-app-nsg'
var storageSku = environment == 'prod' ? 'Standard_ZRS' : 'Standard_LRS'
var effectiveTags = union(tags, {
  environment: environment
  deployedAt: 'pipeline'
})

// Built-in role definition ID: Key Vault Secrets User
var keyVaultSecretsUserRoleId = '4633458b-17de-408a-b874-0445c86b69e6'

// ------------------------------- Resources ---------------------------------

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: workspaceName
  location: location
  tags: effectiveTags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: retentionInDays
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
      immediatePurgeDataOn30Days: false
    }
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
    workspaceCapping: {
      dailyQuotaGb: environment == 'prod' ? -1 : 5
    }
  }
}

resource nsg 'Microsoft.Network/networkSecurityGroups@2024-01-01' = {
  name: nsgName
  location: location
  tags: effectiveTags
  properties: {
    securityRules: [
      {
        name: 'AllowHttpsInboundFromVnet'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRange: '443'
        }
      }
      {
        name: 'DenyAllInbound'
        properties: {
          priority: 4096
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2024-01-01' = {
  name: vnetName
  location: location
  tags: effectiveTags
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressPrefix
      ]
    }
    subnets: [
      {
        name: 'snet-app'
        properties: {
          addressPrefix: appSubnetPrefix
          networkSecurityGroup: {
            id: nsg.id
          }
          serviceEndpoints: [
            {
              service: 'Microsoft.Storage'
              locations: [
                location
              ]
            }
            {
              service: 'Microsoft.KeyVault'
              locations: [
                location
              ]
            }
          ]
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
    ]
  }
}

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  tags: effectiveTags
  sku: {
    name: storageSku
  }
  kind: 'StorageV2'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    accessTier: 'Hot'
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    defaultToOAuthAuthentication: true
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Deny'
      ipRules: []
      virtualNetworkRules: [
        {
          id: '${vnet.id}/subnets/snet-app'
          action: 'Allow'
        }
      ]
    }
    encryption: {
      requireInfrastructureEncryption: true
      keySource: 'Microsoft.Storage'
      services: {
        blob: {
          enabled: true
          keyType: 'Account'
        }
        file: {
          enabled: true
          keyType: 'Account'
        }
      }
    }
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storage
  name: 'default'
  properties: {
    isVersioningEnabled: true
    changeFeed: {
      enabled: true
      retentionInDays: 7
    }
    deleteRetentionPolicy: {
      enabled: true
      days: 7
    }
    containerDeleteRetentionPolicy: {
      enabled: true
      days: 7
    }
  }
}

resource artifactsContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: 'artifacts'
  properties: {
    publicAccess: 'None'
    metadata: {
      purpose: 'build-artifacts'
    }
  }
}

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: keyVaultName
  location: location
  tags: effectiveTags
  properties: {
    tenantId: subscription().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 90
    enablePurgeProtection: environment == 'prod' ? true : null
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Deny'
      ipRules: []
      virtualNetworkRules: [
        {
          id: '${vnet.id}/subnets/snet-app'
        }
      ]
    }
  }
}

// Extension resource: RBAC role assignment scoped to the Key Vault.
resource secretsUserAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: keyVault
  name: guid(keyVault.id, secretsReaderPrincipalId, keyVaultSecretsUserRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', keyVaultSecretsUserRoleId)
    principalId: secretsReaderPrincipalId
    principalType: 'Group'
  }
}

// Extension resource: diagnostics from blob service into the workspace.
resource blobDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: blobService
  name: 'to-log-analytics'
  properties: {
    workspaceId: workspace.id
    logs: [
      {
        categoryGroup: 'audit'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'Transaction'
        enabled: true
      }
    ]
  }
}

resource keyVaultDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: keyVault
  name: 'to-log-analytics'
  properties: {
    workspaceId: workspace.id
    logs: [
      {
        categoryGroup: 'audit'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

// -------------------------------- Outputs ----------------------------------

@description('Resource ID of the Log Analytics workspace.')
output workspaceResourceId string = workspace.id

@description('Immutable workspace (customer) ID used by agents.')
output workspaceCustomerId string = workspace.properties.customerId

@description('Resource ID of the storage account.')
output storageAccountId string = storage.id

@description('Primary blob endpoint.')
output blobEndpoint string = storage.properties.primaryEndpoints.blob

@description('Key Vault URI.')
output keyVaultUri string = keyVault.properties.vaultUri

@description('Resource ID of the application subnet.')
output appSubnetId string = '${vnet.id}/subnets/snet-app'
```

### 4.2 `main.prod.bicepparam` — typed parameter file

```bicep
using './main.bicep'

param namePrefix = 'platform'
param environment = 'prod'
param location = 'westeurope'
param retentionInDays = 180
param vnetAddressPrefix = '10.42.0.0/16'
param appSubnetPrefix = '10.42.1.0/24'
param secretsReaderPrincipalId = 'c91d7e40-8a3b-4f52-b16d-9e07f4a2c8d1'
param tags = {
  owner: 'platform-sre'
  costCenter: 'CC-4471'
  managedBy: 'bicep'
  dataClassification: 'internal'
}
```

### 4.3 `bicepconfig.json` — linter as a merge gate

```json
{
  "analyzers": {
    "core": {
      "enabled": true,
      "verbose": true,
      "rules": {
        "adminusername-should-not-be-literal": { "level": "error" },
        "no-hardcoded-env-urls": { "level": "error" },
        "no-hardcoded-location": { "level": "error" },
        "no-loc-expr-outside-params": { "level": "error" },
        "outputs-should-not-contain-secrets": { "level": "error" },
        "secure-parameter-default": { "level": "error" },
        "secure-params-in-nested-deploy": { "level": "error" },
        "no-unused-params": { "level": "warning" },
        "no-unused-vars": { "level": "warning" },
        "prefer-interpolation": { "level": "warning" },
        "explicit-values-for-loc-params": { "level": "warning" },
        "use-recent-api-versions": {
          "level": "warning",
          "maxAgeInDays": 730
        },
        "use-stable-resource-identifiers": { "level": "error" },
        "use-stable-vm-image": { "level": "error" }
      }
    }
  },
  "cloud": {
    "currentProfile": "AzureCloud"
  },
  "formatting": {
    "indentKind": "Space",
    "indentSize": 2,
    "newlineKind": "LF",
    "insertFinalNewline": true
  }
}
```

### 4.4 Equivalent ARM template (JSON) — complete and deployable

Bicep transpiles to exactly this shape. Read it once so you can debug a compiled template in a pipeline log; author in Bicep thereafter.

```json
{
  "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#",
  "contentVersion": "1.0.0.0",
  "metadata": {
    "description": "Observability workspace + hardened StorageV2 account with blob diagnostics."
  },
  "parameters": {
    "namePrefix": {
      "type": "string",
      "minLength": 3,
      "maxLength": 11,
      "metadata": {
        "description": "Short workload prefix used to derive every resource name."
      }
    },
    "environment": {
      "type": "string",
      "defaultValue": "dev",
      "allowedValues": [ "dev", "stg", "prod" ],
      "metadata": {
        "description": "Deployment environment; drives SKU redundancy."
      }
    },
    "location": {
      "type": "string",
      "defaultValue": "[resourceGroup().location]",
      "metadata": {
        "description": "Azure region for all resources."
      }
    },
    "retentionInDays": {
      "type": "int",
      "defaultValue": 30,
      "minValue": 30,
      "maxValue": 730
    },
    "tags": {
      "type": "object",
      "defaultValue": {
        "owner": "platform-sre",
        "managedBy": "arm-template"
      }
    }
  },
  "variables": {
    "suffix": "[substring(uniqueString(resourceGroup().id), 0, 6)]",
    "workspaceName": "[format('{0}-{1}-law', parameters('namePrefix'), parameters('environment'))]",
    "storageAccountName": "[toLower(format('{0}{1}{2}', parameters('namePrefix'), parameters('environment'), variables('suffix')))]",
    "storageSku": "[if(equals(parameters('environment'), 'prod'), 'Standard_ZRS', 'Standard_LRS')]"
  },
  "resources": [
    {
      "type": "Microsoft.OperationalInsights/workspaces",
      "apiVersion": "2023-09-01",
      "name": "[variables('workspaceName')]",
      "location": "[parameters('location')]",
      "tags": "[parameters('tags')]",
      "properties": {
        "sku": {
          "name": "PerGB2018"
        },
        "retentionInDays": "[parameters('retentionInDays')]",
        "features": {
          "enableLogAccessUsingOnlyResourcePermissions": true
        },
        "publicNetworkAccessForIngestion": "Enabled",
        "publicNetworkAccessForQuery": "Enabled"
      }
    },
    {
      "type": "Microsoft.Storage/storageAccounts",
      "apiVersion": "2023-05-01",
      "name": "[variables('storageAccountName')]",
      "location": "[parameters('location')]",
      "tags": "[parameters('tags')]",
      "sku": {
        "name": "[variables('storageSku')]"
      },
      "kind": "StorageV2",
      "identity": {
        "type": "SystemAssigned"
      },
      "properties": {
        "accessTier": "Hot",
        "minimumTlsVersion": "TLS1_2",
        "supportsHttpsTrafficOnly": true,
        "allowBlobPublicAccess": false,
        "allowSharedKeyAccess": false,
        "defaultToOAuthAuthentication": true,
        "networkAcls": {
          "bypass": "AzureServices",
          "defaultAction": "Deny",
          "ipRules": [],
          "virtualNetworkRules": []
        },
        "encryption": {
          "requireInfrastructureEncryption": true,
          "keySource": "Microsoft.Storage",
          "services": {
            "blob": { "enabled": true, "keyType": "Account" },
            "file": { "enabled": true, "keyType": "Account" }
          }
        }
      }
    },
    {
      "type": "Microsoft.Storage/storageAccounts/blobServices",
      "apiVersion": "2023-05-01",
      "name": "[format('{0}/default', variables('storageAccountName'))]",
      "dependsOn": [
        "[resourceId('Microsoft.Storage/storageAccounts', variables('storageAccountName'))]"
      ],
      "properties": {
        "isVersioningEnabled": true,
        "deleteRetentionPolicy": { "enabled": true, "days": 7 },
        "containerDeleteRetentionPolicy": { "enabled": true, "days": 7 }
      }
    },
    {
      "type": "Microsoft.Insights/diagnosticSettings",
      "apiVersion": "2021-05-01-preview",
      "scope": "[format('Microsoft.Storage/storageAccounts/{0}/blobServices/default', variables('storageAccountName'))]",
      "name": "to-log-analytics",
      "dependsOn": [
        "[resourceId('Microsoft.Storage/storageAccounts/blobServices', variables('storageAccountName'), 'default')]",
        "[resourceId('Microsoft.OperationalInsights/workspaces', variables('workspaceName'))]"
      ],
      "properties": {
        "workspaceId": "[resourceId('Microsoft.OperationalInsights/workspaces', variables('workspaceName'))]",
        "logs": [
          { "categoryGroup": "audit", "enabled": true }
        ],
        "metrics": [
          { "category": "Transaction", "enabled": true }
        ]
      }
    }
  ],
  "outputs": {
    "storageAccountId": {
      "type": "string",
      "value": "[resourceId('Microsoft.Storage/storageAccounts', variables('storageAccountName'))]"
    },
    "blobEndpoint": {
      "type": "string",
      "value": "[reference(resourceId('Microsoft.Storage/storageAccounts', variables('storageAccountName'))).primaryEndpoints.blob]"
    },
    "workspaceCustomerId": {
      "type": "string",
      "value": "[reference(resourceId('Microsoft.OperationalInsights/workspaces', variables('workspaceName'))).customerId]"
    }
  }
}
```

Note the two structural differences from Bicep: **explicit `dependsOn`** (Bicep infers it from symbolic references) and **`reference()` / `resourceId()` string functions** instead of typed property access. Those two are why hand-authored JSON is error-prone at scale.

### 4.5 Subscription-scope Bicep — the resource group itself

Resource groups cannot be created from a resource-group-scoped template. This is the standard bootstrap:

```bicep
// rg-bootstrap.bicep — deploy with: az deployment sub create
targetScope = 'subscription'

@description('Name of the resource group to create.')
param resourceGroupName string

@description('Region for the resource group metadata.')
param location string = 'westeurope'

param tags object = {
  owner: 'platform-sre'
  managedBy: 'bicep'
}

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: location
  tags: tags
}

module baseline 'main.bicep' = {
  name: 'platform-baseline'
  scope: rg
  params: {
    namePrefix: 'platform'
    environment: 'prod'
    location: location
    retentionInDays: 180
    secretsReaderPrincipalId: 'c91d7e40-8a3b-4f52-b16d-9e07f4a2c8d1'
    tags: tags
  }
}

output resourceGroupId string = rg.id
output storageAccountId string = baseline.outputs.storageAccountId
```

> **Exam-relevant constraint:** subscription-, management-group- and tenant-scoped deployments support **Incremental mode only**. Complete mode exists at resource-group scope exclusively.

### 4.6 CI/CD pipeline — GitHub Actions with Entra ID workload identity federation (no secrets)

```yaml
# .github/workflows/deploy-platform.yml
name: deploy-platform-baseline

on:
  pull_request:
    paths:
      - 'infra/**'
  push:
    branches: [ main ]
    paths:
      - 'infra/**'

permissions:
  id-token: write        # required for OIDC federation to Entra ID
  contents: read
  pull-requests: write

env:
  AZURE_RESOURCE_GROUP: rg-platform-prod-weu
  TEMPLATE_FILE: infra/main.bicep
  PARAMETER_FILE: infra/main.prod.bicepparam
  STACK_NAME: stack-platform-baseline

jobs:
  validate:
    name: Lint, build and what-if
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v4

      - name: Azure login (OIDC, no client secret)
        uses: azure/login@v2
        with:
          client-id: ${{ vars.AZURE_CLIENT_ID }}
          tenant-id: ${{ vars.AZURE_TENANT_ID }}
          subscription-id: ${{ vars.AZURE_SUBSCRIPTION_ID }}

      - name: Bicep lint (fails on any linter error)
        run: |
          az bicep install
          az bicep build --file "$TEMPLATE_FILE" --stdout > /dev/null

      - name: ARM template deployment preflight
        run: |
          az deployment group validate \
            --resource-group "$AZURE_RESOURCE_GROUP" \
            --template-file "$TEMPLATE_FILE" \
            --parameters "$PARAMETER_FILE" \
            --output none

      - name: What-if preview
        id: whatif
        run: |
          set -o pipefail
          az deployment group what-if \
            --resource-group "$AZURE_RESOURCE_GROUP" \
            --template-file "$TEMPLATE_FILE" \
            --parameters "$PARAMETER_FILE" \
            --result-format FullResourcePayloads \
            --no-pretty-print > whatif.json
          az deployment group what-if \
            --resource-group "$AZURE_RESOURCE_GROUP" \
            --template-file "$TEMPLATE_FILE" \
            --parameters "$PARAMETER_FILE" \
            --result-format ResourceIdOnly | tee whatif.txt

      - name: Fail the PR if any resource would be deleted
        run: |
          deletions=$(jq '[.changes[] | select(.changeType == "Delete")] | length' whatif.json)
          echo "Planned deletions: ${deletions}"
          if [ "${deletions}" -gt 0 ]; then
            echo "::error::Template would DELETE ${deletions} resource(s). Manual approval required."
            exit 1
          fi

      - name: Publish what-if to the pull request
        if: github.event_name == 'pull_request'
        uses: actions/github-script@v7
        with:
          script: |
            const fs = require('fs');
            const body = '### Azure what-if\n\n```\n' + fs.readFileSync('whatif.txt', 'utf8') + '\n```';
            await github.rest.issues.createComment({
              issue_number: context.issue.number,
              owner: context.repo.owner,
              repo: context.repo.repo,
              body
            });

      - uses: actions/upload-artifact@v4
        with:
          name: whatif-plan
          path: whatif.json
          retention-days: 30

  deploy:
    name: Deploy stack
    needs: validate
    if: github.ref == 'refs/heads/main' && github.event_name == 'push'
    runs-on: ubuntu-24.04
    environment: production          # gated by GitHub environment reviewers
    steps:
      - uses: actions/checkout@v4

      - uses: azure/login@v2
        with:
          client-id: ${{ vars.AZURE_CLIENT_ID }}
          tenant-id: ${{ vars.AZURE_TENANT_ID }}
          subscription-id: ${{ vars.AZURE_SUBSCRIPTION_ID }}

      - name: Deploy as a deployment stack
        run: |
          az stack group create \
            --name "$STACK_NAME" \
            --resource-group "$AZURE_RESOURCE_GROUP" \
            --template-file "$TEMPLATE_FILE" \
            --parameters "$PARAMETER_FILE" \
            --action-on-unmanage deleteResources \
            --deny-settings-mode denyWriteAndDelete \
            --deny-settings-excluded-principals "${{ vars.AZURE_PIPELINE_OBJECT_ID }}" \
            --deny-settings-apply-to-child-scopes \
            --description "commit=${{ github.sha }} run=${{ github.run_id }}" \
            --yes \
            --output json > stack-result.json

      - name: Assert provisioning succeeded
        run: |
          state=$(jq -r '.provisioningState' stack-result.json)
          echo "provisioningState=${state}"
          [ "${state}" = "succeeded" ]
```

Two production details worth internalising: `set -o pipefail` (a pipeline that swallows a non-zero exit reports green on a failed deployment), and the explicit **deletion gate** — `what-if` output is only useful if something machine-readable acts on it.

---

## 5. Command-line surfaces

### 5.1 Azure CLI vs Azure PowerShell

| Aspect | Azure CLI (`az`) | Azure PowerShell (`Az` module) |
|---|---|---|
| Runtime | Python | PowerShell 7+ (.NET) |
| Output | JSON by default; `table`, `tsv`, `yaml`, `none` | .NET objects |
| Filtering | JMESPath (`--query`) | `Where-Object` / `Select-Object` |
| Platforms | Linux, macOS, Windows, Cloud Shell, containers | Same |
| Idiomatic for | Bash pipelines, containers, Linux-first CI | Windows estates, object-pipeline reporting |
| Install | `apt`/`dnf`/`brew`/MSI | `Install-Module -Name Az -Scope CurrentUser` |
| Auth | `az login`, `az login --identity`, `--service-principal`, `--federated-token` | `Connect-AzAccount [-Identity]` |

Equivalent operations side by side:

```console
# Azure CLI
$ az login --tenant contoso.onmicrosoft.com
$ az account set --subscription "Contoso-Platform-Prod"
$ az group create --name rg-platform-prod-weu --location westeurope --tags owner=platform-sre
$ az deployment group create -g rg-platform-prod-weu -f infra/main.bicep -p infra/main.prod.bicepparam
```

```powershell
# Azure PowerShell
Connect-AzAccount -Tenant 'contoso.onmicrosoft.com'
Set-AzContext -Subscription 'Contoso-Platform-Prod'
New-AzResourceGroup -Name 'rg-platform-prod-weu' -Location 'westeurope' -Tag @{ owner = 'platform-sre' }
New-AzResourceGroupDeployment `
  -ResourceGroupName 'rg-platform-prod-weu' `
  -TemplateFile 'infra/main.bicep' `
  -TemplateParameterFile 'infra/main.prod.bicepparam' `
  -Mode Incremental
```

JMESPath is the CLI skill that separates operators from users:

```console
$ az vm list --query "[?powerState=='VM running' && storageProfile.osDisk.osType=='Linux'].{name:name, rg:resourceGroup, size:hardwareProfile.vmSize}" -o table

Name              Rg                       Size
----------------  -----------------------  ---------------
app-prod-weu-01   rg-app-prod-weu          Standard_D4as_v5
app-prod-weu-02   rg-app-prod-weu          Standard_D4as_v5
ingress-prod-01   rg-net-prod-weu          Standard_D2as_v5
```

### 5.2 Azure Cloud Shell — architecture

Cloud Shell is a browser-hosted, pre-authenticated shell (Bash or PowerShell) reachable from the portal, `shell.azure.com`, the Azure mobile app, VS Code and the docs site. Architecturally:

```
Browser (portal / shell.azure.com)
   │  WebSocket terminal
   ▼
Ephemeral Linux container (per session, Microsoft-hosted, free of charge)
   │  pre-authenticated with YOUR Entra ID token — no `az login` needed
   ├── /usr/bin: az, Az PowerShell, kubectl, helm, terraform, ansible,
   │             git, jq, python3, dotnet, node, ssh, bicep
   └── $HOME  ──► (persistent mode) 5 GiB page blob `acc_<user>.img`
                  in an Azure Files share, mounted at $HOME/clouddrive
```

Operational properties that are exam- and production-relevant:

| Property | Behaviour |
|---|---|
| Compute cost | **Free** — you pay only for the storage account backing persistence |
| Persistence | Only `$HOME` (inside the mounted image) survives; the rest of the container is discarded |
| Ephemeral mode | Sessions can run with **no storage account**; nothing persists between sessions |
| Idle timeout | Session terminates after ~20 minutes without interaction |
| Authentication | Inherits the signed-in user's identity; no credential handling |
| Shells | `bash` and `pwsh`, switchable at any time |
| Network isolation | Can be deployed into a VNet (private Cloud Shell) via an Azure Relay |
| File transfer | Upload/download through the portal toolbar, or `clouddrive` |

```console
dalmine@Azure:~$ df -h $HOME/clouddrive
Filesystem      Size  Used Avail Use% Mounted on
//cs710032...file.core.windows.net/cs-dalmine-westeurope
                5.0G  312M  4.7G   7% /home/dalmine/clouddrive

dalmine@Azure:~$ az account show --output table
EnvironmentName    HomeTenantId                          IsDefault    Name                   State    TenantId
-----------------  ------------------------------------  -----------  ---------------------  -------  ------------------------------------
AzureCloud         7f8e3d21-4c6b-4a19-8e52-1b0c9d7f6a34  True         Contoso-Platform-Prod  Enabled  7f8e3d21-4c6b-4a19-8e52-1b0c9d7f6a34

dalmine@Azure:~$ az version --output json
{
  "azure-cli": "2.75.0",
  "azure-cli-core": "2.75.0",
  "azure-cli-telemetry": "1.1.0",
  "extensions": {
    "connectedk8s": "1.10.7",
    "k8s-configuration": "2.1.0",
    "k8s-extension": "1.6.5"
  }
}

dalmine@Azure:~$ which terraform kubectl helm bicep
/usr/bin/terraform
/usr/bin/kubectl
/usr/local/bin/helm
/home/dalmine/.azure/bin/bicep
```

**Where Cloud Shell wins:** break-glass access from any device with no local install, and *pre-authenticated* identity — no long-lived credentials on a laptop. **Where it loses:** the 20-minute idle timeout kills long operations (use `nohup`/`tmux` inside the session, or better, run long jobs from CI), and it is not a build agent — do not architect pipelines around it.

---

## 6. Azure Arc: extending the control plane beyond Azure

### 6.1 What Arc actually does

Arc projects a resource that Microsoft does not host into ARM, giving it a resource ID, a managed identity, tags, RBAC, policy applicability and Resource Graph visibility. It does **not** move workloads, does **not** require inbound connectivity, and does **not** take over the machine's lifecycle.

| Arc-enabled resource | ARM type | Capabilities unlocked |
|---|---|---|
| **Servers** (Windows/Linux, on-prem, AWS, GCP) | `Microsoft.HybridCompute/machines` | Inventory, tags, RBAC, Azure Policy + Machine Configuration, extensions (AMA, Defender, Custom Script), Update Manager, Run-command, SSH-over-Arc, managed identity |
| **Kubernetes** (any CNCF-conformant cluster) | `Microsoft.Kubernetes/connectedClusters` | GitOps (Flux v2), cluster extensions, Azure Policy for Kubernetes (Gatekeeper), Container Insights, Cluster Connect, Entra ID RBAC, custom locations |
| **SQL Server** | `Microsoft.AzureArcData/sqlServerInstances` | Inventory, best-practices assessment, Defender for SQL, Purview |
| **Data services** (SQL MI, PostgreSQL) | `Microsoft.AzureArcData/*` | Azure PaaS data engines on your own Kubernetes |
| **VMware vSphere / SCVMM / Azure Local** | `Microsoft.ConnectedVMwarevSphere/*`, … | Self-service VM lifecycle through ARM |

> **Cost note:** core Arc control-plane capabilities (onboarding, inventory, tags, Resource Graph, Azure Policy / guest configuration) carry no charge for Arc-enabled servers and Kubernetes; value-added services layered on top (Defender for Cloud plans, Log Analytics ingestion, Update Manager for Arc servers, Arc-enabled data services) are billed. Always confirm against the current pricing page before committing a design.

### 6.2 Arc-enabled servers: agent architecture

The **Azure Connected Machine agent** (`azcmagent`) installs three cooperating components:

| Component | Process | Role |
|---|---|---|
| **HIMDS** (Hybrid Instance Metadata Service) | `himds` | Local metadata endpoint on `127.0.0.1:40342`; issues managed-identity tokens; maintains the Entra ID device identity and heartbeat |
| **Guest Configuration agent** | `gcad` / `gc_arc_service` | Evaluates and remediates Machine Configuration (Policy guest assignments) |
| **Extension Manager** | `extd` / `gcarcservice` | Installs and manages VM extensions (Azure Monitor Agent, Defender, Custom Script, …) |

Outbound-only network requirements (TCP 443, no inbound ports, proxy and Private Link supported):

```
login.microsoftonline.com          → Entra ID token acquisition
management.azure.com               → ARM control plane
*.his.arc.azure.com                → Hybrid Identity Service (agent heartbeat, identity)
*.guestconfiguration.azure.com     → Machine Configuration
packages.microsoft.com             → agent/extension packages
*.blob.core.windows.net            → extension artifacts
```

Onboarding a Linux host:

```console
$ curl -fsSL https://aka.ms/azcmagent -o install_linux_azcmagent.sh
$ sudo bash install_linux_azcmagent.sh
Installing packages...
Azure Connected Machine Agent 1.53.02891.1044 installed.

$ sudo azcmagent connect \
    --resource-group "rg-arc-prod-weu" \
    --tenant-id "7f8e3d21-4c6b-4a19-8e52-1b0c9d7f6a34" \
    --location "westeurope" \
    --subscription-id "8f4a1c2e-9b7d-4f0a-a6c1-2d3e4f5a6b7c" \
    --cloud "AzureCloud" \
    --tags "Datacenter=Frankfurt,City=FFM,Owner=platform-sre,Env=prod" \
    --service-principal-id "3f2a8c17-5b41-4e6d-9a02-7c8b1d5e0f93" \
    --service-principal-secret-file /run/secrets/arc-onboarding

INFO    Onboarding Machine. It usually takes a few minutes to complete.
INFO    Testing connectivity to endpoints that are needed to connect to Azure...
INFO    Creating resource in Azure...
INFO    Connecting machine to Azure...
INFO    Successfully onboarded resource to Azure

Resource Id: /subscriptions/8f4a1c2e-9b7d-4f0a-a6c1-2d3e4f5a6b7c/resourceGroups/rg-arc-prod-weu/providers/Microsoft.HybridCompute/machines/node-fra-01
```

Verifying state on the host:

```console
$ sudo azcmagent show
Resource Name              : node-fra-01
Resource Group Name        : rg-arc-prod-weu
Resource Id                : /subscriptions/8f4a1c2e-.../providers/Microsoft.HybridCompute/machines/node-fra-01
Subscription Id            : 8f4a1c2e-9b7d-4f0a-a6c1-2d3e4f5a6b7c
Tenant Id                  : 7f8e3d21-4c6b-4a19-8e52-1b0c9d7f6a34
Location                   : westeurope
Agent Version              : 1.53.02891.1044
Agent Status               : Connected
Agent Last Heartbeat       : 2026-09-05T09:41:12Z (28 seconds ago)
Agent Error Code           : <none>
Using Proxy                : false
Upstream Proxy             : <none>
Dependent Service Status
  Agent Service (himds)    : active
  GC Service (gcad)        : active
  Extension Service (extd) : active
```

The same machine, now queryable from Azure exactly like a native VM:

```console
$ az connectedmachine show -g rg-arc-prod-weu -n node-fra-01 \
    --query "{name:name, status:status, agent:agentVersion, os:osName, osVersion:osVersion, identity:identity.principalId}" -o yaml

name: node-fra-01
status: Connected
agent: 1.53.02891.1044
os: linux
osVersion: 9.5
identity: 6b1c9f24-3a70-4e88-b512-0d47e9a1c3f2
```

That `identity.principalId` is a real Entra ID system-assigned managed identity: the on-prem server can now authenticate to Key Vault or Storage with no stored secret.

### 6.3 Arc-enabled Kubernetes and GitOps

```console
$ az extension add --name connectedk8s --upgrade
$ az extension add --name k8s-configuration --upgrade

$ kubectl config current-context
onprem-fra-prod

$ az connectedk8s connect \
    --name k8s-fra-prod \
    --resource-group rg-arc-prod-weu \
    --location westeurope \
    --distribution generic \
    --infrastructure generic \
    --tags "Owner=platform-sre,Env=prod,Site=Frankfurt"

This operation might take a while...
Azure resource provisioning has begun.
Azure resource provisioning has finished.
Starting to install Azure arc agents on the Kubernetes cluster.
{
  "agentVersion": "1.20.3",
  "connectivityStatus": "Connected",
  "distribution": "generic",
  "id": "/subscriptions/8f4a1c2e-.../providers/Microsoft.Kubernetes/connectedClusters/k8s-fra-prod",
  "kubernetesVersion": "1.31.4",
  "location": "westeurope",
  "name": "k8s-fra-prod",
  "provisioningState": "Succeeded",
  "totalNodeCount": 6
}

$ kubectl -n azure-arc get pods
NAME                                         READY   STATUS    RESTARTS   AGE
cluster-metadata-operator-6d8b4f7c9c-tq2xr   2/2     Running   0          3m41s
clusterconnect-agent-7f5b9c4d88-h4wmn        3/3     Running   0          3m41s
clusteridentityoperator-59c7d64b7f-9kfpz     2/2     Running   0          3m41s
config-agent-6b4c8d9f74-2vlnq                2/2     Running   0          3m41s
controller-manager-5d9f7b6c84-xg7dt          2/2     Running   0          3m41s
extension-manager-7c8d4b5f96-plr3s           3/3     Running   0          3m41s
flux-logs-agent-58b7c6d4f9-mn8kz             1/1     Running   0          3m41s
kube-aad-proxy-6f9c7b8d55-w2jhx              2/2     Running   0          3m41s
metrics-agent-849d6f7b93-4tqvc               2/2     Running   0          3m41s
resource-sync-agent-6c5b8f7d94-zr6nl         2/2     Running   0          3m41s
```

All ten agents dial **out**; no inbound firewall rule is required, and `clusterconnect-agent` is what later allows `kubectl` through Azure to a cluster behind NAT.

Attaching Flux v2 GitOps so the cluster reconciles from Git rather than from human `kubectl apply`:

```console
$ az k8s-extension create \
    --cluster-name k8s-fra-prod \
    --resource-group rg-arc-prod-weu \
    --cluster-type connectedClusters \
    --name flux \
    --extension-type microsoft.flux \
    --auto-upgrade-minor-version true \
    --output none

$ az k8s-configuration flux create \
    --cluster-name k8s-fra-prod \
    --resource-group rg-arc-prod-weu \
    --cluster-type connectedClusters \
    --name platform-apps \
    --namespace platform-system \
    --scope cluster \
    --url https://github.com/contoso/k8s-platform-config \
    --branch main \
    --interval 1m \
    --kustomization name=infra path=./clusters/fra-prod/infra prune=true sync_interval=1m retry_interval=30s \
    --kustomization name=apps  path=./clusters/fra-prod/apps  prune=true depends_on=["infra"] sync_interval=2m \
    --output table

Name           Namespace         Scope    ProvisioningState    ComplianceState
-------------  ----------------  -------  -------------------  -----------------
platform-apps  platform-system   cluster  Succeeded            Compliant
```

The same GitOps configuration expressed declaratively in Bicep — so the *management configuration itself* is under IaC:

```bicep
// arc-gitops.bicep — Flux extension + GitOps configuration on an Arc cluster
targetScope = 'resourceGroup'

@description('Name of the Arc-enabled Kubernetes cluster.')
param connectedClusterName string

@description('HTTPS URL of the Git repository holding cluster desired state.')
param gitRepositoryUrl string = 'https://github.com/contoso/k8s-platform-config'

@description('Branch to reconcile from.')
param gitBranch string = 'main'

resource connectedCluster 'Microsoft.Kubernetes/connectedClusters@2024-01-01' existing = {
  name: connectedClusterName
}

resource fluxExtension 'Microsoft.KubernetesConfiguration/extensions@2023-05-01' = {
  scope: connectedCluster
  name: 'flux'
  properties: {
    extensionType: 'microsoft.flux'
    autoUpgradeMinorVersion: true
    releaseTrain: 'Stable'
    scope: {
      cluster: {
        releaseNamespace: 'flux-system'
      }
    }
    configurationSettings: {
      'helm-controller.enabled': 'true'
      'source-controller.enabled': 'true'
      'kustomize-controller.enabled': 'true'
      'notification-controller.enabled': 'true'
      'image-automation-controller.enabled': 'false'
      'image-reflector-controller.enabled': 'false'
    }
  }
}

resource fluxConfiguration 'Microsoft.KubernetesConfiguration/fluxConfigurations@2023-05-01' = {
  scope: connectedCluster
  name: 'platform-apps'
  dependsOn: [
    fluxExtension
  ]
  properties: {
    scope: 'cluster'
    namespace: 'platform-system'
    sourceKind: 'GitRepository'
    suspend: false
    gitRepository: {
      url: gitRepositoryUrl
      repositoryRef: {
        branch: gitBranch
      }
      syncIntervalInSeconds: 60
      timeoutInSeconds: 600
      httpsCACert: ''
    }
    kustomizations: {
      infra: {
        path: './clusters/fra-prod/infra'
        dependsOn: []
        timeoutInSeconds: 600
        syncIntervalInSeconds: 60
        retryIntervalInSeconds: 30
        prune: true
        force: false
        wait: true
      }
      apps: {
        path: './clusters/fra-prod/apps'
        dependsOn: [
          'infra'
        ]
        timeoutInSeconds: 600
        syncIntervalInSeconds: 120
        retryIntervalInSeconds: 60
        prune: true
        force: false
        wait: true
      }
    }
  }
}

output fluxConfigurationId string = fluxConfiguration.id
output complianceState string = fluxConfiguration.properties.complianceState
```

The Git repository content that Flux reconciles — complete, valid Kubernetes manifests:

```yaml
# clusters/fra-prod/infra/namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: payments
  labels:
    app.kubernetes.io/managed-by: flux
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
---
# clusters/fra-prod/infra/resourcequota.yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: payments-quota
  namespace: payments
spec:
  hard:
    requests.cpu: "8"
    requests.memory: 16Gi
    limits.cpu: "16"
    limits.memory: 32Gi
    persistentvolumeclaims: "10"
    count/deployments.apps: "20"
```

```yaml
# clusters/fra-prod/apps/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: payments
resources:
  - deployment.yaml
  - service.yaml
commonLabels:
  app.kubernetes.io/part-of: payments-platform
  app.kubernetes.io/managed-by: flux
images:
  - name: contoso/payments-api
    newTag: 1.14.3
---
# clusters/fra-prod/apps/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payments-api
  namespace: payments
  labels:
    app.kubernetes.io/name: payments-api
    app.kubernetes.io/version: 1.14.3
spec:
  replicas: 3
  revisionHistoryLimit: 5
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  selector:
    matchLabels:
      app.kubernetes.io/name: payments-api
  template:
    metadata:
      labels:
        app.kubernetes.io/name: payments-api
        app.kubernetes.io/version: 1.14.3
    spec:
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        fsGroup: 10001
        seccompProfile:
          type: RuntimeDefault
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: payments-api
      containers:
        - name: api
          image: contoso/payments-api:1.14.3
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 8080
              protocol: TCP
          env:
            - name: LOG_LEVEL
              value: "info"
            - name: OTEL_EXPORTER_OTLP_ENDPOINT
              value: "http://otel-collector.observability.svc.cluster.local:4317"
          resources:
            requests:
              cpu: 250m
              memory: 256Mi
            limits:
              cpu: "1"
              memory: 512Mi
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop:
                - ALL
          livenessProbe:
            httpGet:
              path: /healthz
              port: http
            initialDelaySeconds: 10
            periodSeconds: 10
            failureThreshold: 3
          readinessProbe:
            httpGet:
              path: /readyz
              port: http
            initialDelaySeconds: 5
            periodSeconds: 5
            failureThreshold: 3
          volumeMounts:
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: tmp
          emptyDir:
            sizeLimit: 64Mi
---
# clusters/fra-prod/apps/service.yaml
apiVersion: v1
kind: Service
metadata:
  name: payments-api
  namespace: payments
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: payments-api
  ports:
    - name: http
      port: 80
      targetPort: http
      protocol: TCP
```

Reaching that private cluster's API server through Azure — no VPN, no public endpoint:

```console
$ az connectedk8s proxy --name k8s-fra-prod --resource-group rg-arc-prod-weu
Proxy is listening on port 47011
Merged "k8s-fra-prod" as current context in /home/dalmine/.kube/config
Start sending kubectl requests on 'k8s-fra-prod' context using kubeconfig at /home/dalmine/.kube/config
Press Ctrl+C to close proxy.

# In another terminal:
$ kubectl get nodes
NAME            STATUS   ROLES           AGE    VERSION
fra-cp-01       Ready    control-plane   412d   v1.31.4
fra-cp-02       Ready    control-plane   412d   v1.31.4
fra-cp-03       Ready    control-plane   412d   v1.31.4
fra-worker-01   Ready    <none>          412d   v1.31.4
fra-worker-02   Ready    <none>          412d   v1.31.4
fra-worker-03   Ready    <none>          287d   v1.31.4
```

---

## 7. Verification and failure diagnosis

### 7.1 The preflight ladder

Run these in order; each rung is cheaper than the one below it and catches a different class of failure.

| Rung | Command | Catches |
|---|---|---|
| 1. Compile | `az bicep build --file main.bicep` | Syntax, type errors, unresolved symbols |
| 2. Lint | `az bicep build` with `bicepconfig.json` rules at `error` | Hardcoded locations, secrets in outputs, unstable identifiers |
| 3. Validate | `az deployment group validate` | Schema, parameter binding, RBAC, provider preflight (quota, SKU availability, name conflicts) |
| 4. What-if | `az deployment group what-if` | Creates, deletes, property-level modifications, **replace** operations |
| 5. Deploy | `az deployment group create --confirm-with-what-if` | Reality |

### 7.2 Reading `what-if` output

```console
$ az deployment group what-if \
    --resource-group rg-platform-prod-weu \
    --template-file infra/main.bicep \
    --parameters infra/main.prod.bicepparam

Note: The result may contain false positive predictions (noise).
You can help us improve the accuracy of the result by opening an issue here: https://aka.ms/WhatIfIssues

Resource and property changes are indicated with these symbols:
  - Delete
  + Create
  ~ Modify
  = NoChange
  * Ignore

The deployment will update the following scope:

Scope: /subscriptions/8f4a1c2e-9b7d-4f0a-a6c1-2d3e4f5a6b7c/resourceGroups/rg-platform-prod-weu

  + Microsoft.KeyVault/vaults/platform-prod-kv-x7k2m9
      apiVersion:                                "2023-07-01"
      location:                                  "westeurope"
      properties.enablePurgeProtection:          true
      properties.enableRbacAuthorization:        true
      properties.softDeleteRetentionInDays:      90
      sku.family:                                "A"
      sku.name:                                  "standard"

  ~ Microsoft.OperationalInsights/workspaces/platform-prod-law
      ~ properties.retentionInDays: 30 => 180

  ~ Microsoft.Storage/storageAccounts/platformprodx7k2m9
      ~ properties.allowSharedKeyAccess:  true => false
      ~ properties.networkAcls.defaultAction: "Allow" => "Deny"
      ~ sku.name: "Standard_LRS" => "Standard_ZRS"

  = Microsoft.Network/virtualNetworks/platform-prod-vnet

Resource changes: 1 to create, 2 to modify, 1 no change.
```

Read this the way an SRE reads a `terraform plan`:

- `~ sku.name: "Standard_LRS" => "Standard_ZRS"` — **an in-place SKU conversion is not supported for existing storage accounts**; ARM will fail this at the provider, or in other resource types silently trigger a replace. `what-if` tells you the *intent*, not always the *mechanism*. When a modification touches an immutable property, verify against the resource provider's documentation before merging.
- `properties.allowSharedKeyAccess: true => false` — a correct hardening change that will break every consumer still using account keys. This is exactly the kind of line a reviewer must see in the PR, which is why the pipeline in §4.6 posts it as a comment.
- **Noise:** some providers return normalised property values that differ from the template, producing phantom `~` lines. Use `--result-format FullResourcePayloads` to inspect the raw before/after, and never suppress noise by removing the gate.

### 7.3 Diagnosing a failed deployment

```console
$ az deployment group create -g rg-platform-prod-weu -f infra/main.bicep -p infra/main.prod.bicepparam
Deployment failed. Correlation ID: 3a7f1e92-6c48-4b05-9d3f-8e1a72c40b56.
{
  "code": "DeploymentFailed",
  "message": "At least one resource deployment operation failed. Please list deployment operations for details."
}
```

The message is deliberately generic. The real error is in the **deployment operations**, one level down:

```console
$ az deployment operation group list \
    --resource-group rg-platform-prod-weu \
    --name main \
    --query "[?properties.provisioningState=='Failed'].{resource:properties.targetResource.resourceName, type:properties.targetResource.resourceType, code:properties.statusMessage.error.code, message:properties.statusMessage.error.message}" \
    --output yaml

- code: StorageAccountAlreadyTaken
  message: The storage account named platformprodx7k2m9 is already taken.
  resource: platformprodx7k2m9
  type: Microsoft.Storage/storageAccounts
```

Correlate across the entire control plane using the correlation ID — this ties the ARM deployment to every downstream provider operation:

```console
$ az monitor activity-log list \
    --correlation-id 3a7f1e92-6c48-4b05-9d3f-8e1a72c40b56 \
    --query "[].{time:eventTimestamp, op:operationName.value, status:status.value, sub:subStatus.value, caller:caller}" \
    --output table

Time                              Op                                                    Status     Sub          Caller
--------------------------------  ----------------------------------------------------  ---------  -----------  -----------------------------
2026-09-05T09:12:44.118Z          Microsoft.Resources/deployments/write                  Started                 github-actions-platform@...
2026-09-05T09:12:51.902Z          Microsoft.Storage/storageAccounts/write                Failed     Conflict     github-actions-platform@...
2026-09-05T09:12:53.441Z          Microsoft.Resources/deployments/write                  Failed     Conflict     github-actions-platform@...
```

### 7.4 Error-code triage table

| Code | HTTP | Root cause | Action |
|---|---|---|---|
| `InvalidTemplate` | 400 | Expression/type/schema error | `az bicep build`; check function arity and `dependsOn` targets |
| `InvalidTemplateDeployment` | 400 | Provider rejected preflight (SKU, region, feature not enabled) | Read the inner `details[]`; check regional SKU availability |
| `AuthorizationFailed` | 403 | Principal lacks the required RBAC action | `az role assignment list --assignee <id> --scope <scope>` |
| `RequestDisallowedByPolicy` | 403 | Azure Policy Deny effect | Inner error names the assignment and definition; fix the resource or request an exemption |
| `ScopeLocked` | 409 | `CanNotDelete` / `ReadOnly` lock at or above the scope | `az lock list --resource-group <rg>` |
| `DeploymentActive` | 409 | Another deployment with the same name is running | Use unique deployment names (`main-${{ github.run_id }}`) |
| `StorageAccountAlreadyTaken` | 409 | Globally unique name collision | Derive names with `uniqueString()` |
| `QuotaExceeded` / `SkuNotAvailable` | 400/409 | Subscription vCPU quota or capacity in that region/zone | `az vm list-usage -l westeurope`; request quota or change SKU/region |
| `ResourceNotFound` / `ParentResourceNotFound` | 404 | Missing implicit dependency or wrong ordering | Add `dependsOn` / use symbolic references in Bicep |
| `MissingSubscriptionRegistration` | 409 | Resource provider not registered | `az provider register --namespace <ns> --wait` |
| `DeploymentQuotaExceeded` | 429 | >800 deployments in RG history | Prune history; ARM also auto-prunes |
| `TooManyRequests` | 429 | ARM throttling | Honour `Retry-After`; back off exponentially |

Recovery to the last good state when a partial deployment leaves the RG inconsistent:

```console
$ az deployment group create \
    --resource-group rg-platform-prod-weu \
    --name main-recovery \
    --template-file infra/main.bicep \
    --parameters infra/main.prod.bicepparam \
    --rollback-on-error
```

### 7.5 Estate-wide verification with Azure Resource Graph (KQL)

Resource Graph queries the ARM resource index across every subscription in the tenant in seconds — the only sane way to answer "is the whole estate compliant?".

```console
$ az graph query -q "
resources
| where type =~ 'microsoft.hybridcompute/machines'
| extend status      = tostring(properties.status),
         agentVer    = tostring(properties.agentVersion),
         osName      = tostring(properties.osName),
         lastSeen    = todatetime(properties.lastStatusChange)
| where status != 'Connected'
| project name, resourceGroup, location, status, agentVer, osName, lastSeen
| order by lastSeen asc
" --first 10 --output table

Name           ResourceGroup      Location     Status         AgentVer            OsName   LastSeen
-------------  -----------------  -----------  -------------  ------------------  -------  --------------------------
node-fra-17    rg-arc-prod-weu    westeurope   Disconnected   1.42.02710.1671     linux    2026-08-22T04:11:07.000Z
node-fra-23    rg-arc-prod-weu    westeurope   Disconnected   1.48.02804.1902     linux    2026-09-01T23:57:44.000Z
win-ams-04     rg-arc-prod-weu    westeurope   Expired        1.39.02611.1548     windows  2026-07-30T11:02:19.000Z
```

Finding resources created outside IaC — the drift detector:

```console
$ az graph query -q "
resources
| extend managedBy = tostring(tags['managedBy'])
| where isempty(managedBy) or managedBy !in ('bicep','terraform')
| where type !startswith 'microsoft.insights/'
| summarize orphans = count() by type, subscriptionId
| order by orphans desc
" --output table

Type                                          SubscriptionId                          Orphans
--------------------------------------------  --------------------------------------  ---------
microsoft.network/networkinterfaces           8f4a1c2e-9b7d-4f0a-a6c1-2d3e4f5a6b7c    41
microsoft.compute/disks                       8f4a1c2e-9b7d-4f0a-a6c1-2d3e4f5a6b7c    38
microsoft.network/publicipaddresses           8f4a1c2e-9b7d-4f0a-a6c1-2d3e4f5a6b7c    17
microsoft.storage/storageaccounts             8f4a1c2e-9b7d-4f0a-a6c1-2d3e4f5a6b7c    6
```

### 7.6 Arc-specific diagnostics

```console
# Connectivity preflight before (or after) onboarding — validates every required endpoint
$ sudo azcmagent check --location westeurope
Checking connectivity to Azure services...

Endpoint                                       Reachable  TLS  Notes
---------------------------------------------  ---------  ---  -------------------------------
login.microsoftonline.com                       true       1.3
management.azure.com                            true       1.3
westeurope.his.arc.azure.com                    true       1.3
gbl.his.arc.azure.com                           true       1.3
packages.microsoft.com                          true       1.3
guestnotificationservice.azure.com              false      -    connection timed out
*.guestconfiguration.azure.com                  true       1.3

Details: 1 of 6 checks failed. Extension push notifications will be delayed;
the agent will fall back to polling.

# Service-level state
$ sudo systemctl status himds --no-pager | head -5
● himds.service - Azure Hybrid Instance Metadata Service
     Loaded: loaded (/lib/systemd/system/himds.service; enabled; preset: enabled)
     Active: active (running) since Fri 2026-09-05 08:03:12 UTC; 1h 41min ago
   Main PID: 1174 (himds)
      Tasks: 12 (limit: 9418)

# Collect a full diagnostic bundle for support
$ sudo azcmagent logs --full --output /tmp/arc-node-fra-01.zip
Logs collected: /tmp/arc-node-fra-01.zip (4.1 MiB)

# Extension state as Azure sees it
$ az connectedmachine extension list -g rg-arc-prod-weu --machine-name node-fra-01 \
    --query "[].{name:name, publisher:properties.publisher, type:properties.type, state:properties.provisioningState}" -o table

Name                    Publisher                            Type                  State
----------------------  -----------------------------------  --------------------  ---------
AzureMonitorLinuxAgent  Microsoft.Azure.Monitor              AzureMonitorLinuxAgent Succeeded
MDE.Linux               Microsoft.Azure.AzureDefenderForServers MDE.Linux           Failed
```

For Arc-enabled Kubernetes:

```console
$ az connectedk8s troubleshoot --name k8s-fra-prod --resource-group rg-arc-prod-weu
Diagnoser running. This may take a while...

Checking Diagnoser Prerequisites ...                                        [OK]
Checking Azure Arc Agent State ...                                          [OK]
Checking Kubernetes Cluster Certificates ...                                [OK]
Checking MSI Certificate expiry ...                                         [OK]
Checking Cluster Connectivity Status ...                                    [OK]
Checking Cluster Security Policy ...                                        [OK]
Checking Azure Arc Agents Version ...                                       [WARN]
  Agent version 1.18.2 is more than 3 versions behind the latest (1.20.3).
  Run: az connectedk8s upgrade -n k8s-fra-prod -g rg-arc-prod-weu

$ kubectl -n azure-arc logs deploy/config-agent --tail=20 | grep -i error
E0905 09:47:02.113445  1 gitrepo.go:214] failed to clone repository: authentication required

$ az k8s-configuration flux show \
    --cluster-name k8s-fra-prod -g rg-arc-prod-weu --cluster-type connectedClusters \
    --name platform-apps \
    --query "{state:provisioningState, compliance:complianceState, msg:statuses[0].statusReason}" -o yaml

state: Succeeded
compliance: Non-Compliant
msg: 'source/GitRepository: failed to checkout and determine revision: unable to clone: authentication required'
```

---

## 8. Exam-focused synthesis

| Statement AZ-900 tests | Correct answer |
|---|---|
| The single service through which **all** Azure management requests pass | Azure Resource Manager |
| Language of ARM templates | JSON (declarative) |
| Domain-specific language that transpiles to ARM JSON | Bicep |
| Default deployment mode | Incremental |
| Mode that deletes resources not in the template | Complete (resource-group scope only) |
| Preview a deployment's effect without applying it | `what-if` |
| Browser-based, pre-authenticated shell with `az`, `Az`, `kubectl`, `terraform` | Azure Cloud Shell |
| Cloud Shell shells offered | Bash and PowerShell |
| Cloud Shell persistence mechanism | Azure Files share mounted at `$HOME/clouddrive` (ephemeral sessions also available) |
| Cloud Shell compute cost | Free; you pay only for the backing storage |
| Extends Azure management (RBAC, Policy, tags, Monitor) to on-prem and other clouds | Azure Arc |
| Arc-supported resource families | Servers, Kubernetes, SQL Server, data services, VMware vSphere / SCVMM / Azure Local |
| Arc network requirement | Outbound HTTPS (443) only — no inbound ports |
| Cross-subscription resource querying at scale | Azure Resource Graph (KQL) |
| Key benefits of IaC over portal clicks | Repeatability, idempotency, version control, peer review, drift prevention, disaster recovery |
| Where dependencies are declared in ARM JSON | `dependsOn` (Bicep infers them from symbolic references) |

**Three distinctions students most often get wrong:**

1. **Azure Arc ≠ Azure Stack.** Arc *manages* hardware you already own from Azure's control plane; Azure Stack (HCI/Hub/Edge) *runs Azure services* on hardware in your datacentre. Arc adds management, not compute.
2. **The portal, CLI, PowerShell and templates are not alternatives to ARM.** They are all clients *of* ARM. There is one control plane and many front ends.
3. **`what-if` is not `validate`.** `validate` checks that the template *could* be submitted (schema, RBAC, provider preflight). `what-if` computes the *delta* between declared and actual state. Production pipelines run both.

---

## 9. Referencias

- Microsoft Learn — AZ-900 study guide: https://learn.microsoft.com/en-us/credentials/certifications/resources/study-guides/az-900
- Azure Resource Manager overview: https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/overview
- Resource providers and resource types: https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/resource-providers-and-types
- ARM deployment modes (Incremental / Complete): https://learn.microsoft.com/en-us/azure/azure-resource-manager/templates/deployment-modes
- ARM template what-if: https://learn.microsoft.com/en-us/azure/azure-resource-manager/templates/deploy-what-if
- Bicep overview: https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/overview
- Bicep parameter files (`.bicepparam`): https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/parameter-files
- Bicep linter and `bicepconfig.json`: https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/linter
- Deployment stacks: https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/deployment-stacks
- Template specs: https://learn.microsoft.com/en-us/azure/azure-resource-manager/templates/template-specs
- Deployment scopes (subscription / management group / tenant): https://learn.microsoft.com/en-us/azure/azure-resource-manager/templates/deploy-to-subscription
- Azure subscription and service limits: https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/azure-subscription-service-limits
- ARM request limits and throttling: https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/request-limits-and-throttling
- Troubleshoot common Azure deployment errors: https://learn.microsoft.com/en-us/azure/azure-resource-manager/troubleshooting/common-deployment-errors
- Find error codes in deployment operations: https://learn.microsoft.com/en-us/azure/azure-resource-manager/troubleshooting/find-error-code
- Azure CLI documentation: https://learn.microsoft.com/en-us/cli/azure/
- Azure CLI JMESPath query tutorial: https://learn.microsoft.com/en-us/cli/azure/query-azure-cli
- Azure PowerShell documentation: https://learn.microsoft.com/en-us/powershell/azure/
- Azure Cloud Shell overview: https://learn.microsoft.com/en-us/azure/cloud-shell/overview
- Cloud Shell persistent storage: https://learn.microsoft.com/en-us/azure/cloud-shell/persisting-shell-storage
- Cloud Shell features and tools: https://learn.microsoft.com/en-us/azure/cloud-shell/features
- Azure Arc overview: https://learn.microsoft.com/en-us/azure/azure-arc/overview
- Azure Arc-enabled servers overview: https://learn.microsoft.com/en-us/azure/azure-arc/servers/overview
- Connected Machine agent architecture: https://learn.microsoft.com/en-us/azure/azure-arc/servers/agent-overview
- Arc-enabled servers network requirements: https://learn.microsoft.com/en-us/azure/azure-arc/servers/network-requirements
- Managing and maintaining the Connected Machine agent: https://learn.microsoft.com/en-us/azure/azure-arc/servers/manage-agent
- Azure Arc-enabled Kubernetes overview: https://learn.microsoft.com/en-us/azure/azure-arc/kubernetes/overview
- GitOps with Flux v2 on Arc-enabled Kubernetes: https://learn.microsoft.com/en-us/azure/azure-arc/kubernetes/conceptual-gitops-flux2
- Cluster connect for Arc-enabled Kubernetes: https://learn.microsoft.com/en-us/azure/azure-arc/kubernetes/conceptual-cluster-connect
- Azure Resource Graph overview: https://learn.microsoft.com/en-us/azure/governance/resource-graph/overview
- Resource Graph starter queries: https://learn.microsoft.com/en-us/azure/governance/resource-graph/samples/starter
- Azure portal documentation: https://learn.microsoft.com/en-us/azure/azure-portal/
- Azure Developer CLI (`azd`) overview: https://learn.microsoft.com/en-us/azure/developer/azure-developer-cli/overview
- GitHub Actions authentication to Azure with OIDC: https://learn.microsoft.com/en-us/azure/developer/github/connect-from-azure-openid-connect
- Azure Arc pricing: https://azure.microsoft.com/en-us/pricing/details/azure-arc/