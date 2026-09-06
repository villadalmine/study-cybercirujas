# AZ-900 · Topic 3.2 — Features and Tools in Azure for Governance and Compliance

**Exam weight: 8.33%** · Domain: *Describe Azure management and governance* · Version 2026-07-20

> **Scope note.** The study guide bullets for this objective are *Microsoft Purview*, *Azure Policy*, and *resource locks*. Earlier revisions of AZ-900 also examined the *Service Trust Portal*, and it remains the canonical answer to "where do I get Microsoft's SOC 2 report?", so it is covered here in §7. Everything beyond the bullets is marked **[beyond exam scope]** and exists because you will be asked to build this in production long before you are asked about it in an exam.

---

## 1. The production problem: RBAC is necessary and insufficient

### 1.1 The failure mode that creates the objective

You are the platform architect for an estate of ~180 Azure subscriptions across four business units. Application teams are `Contributor` on their own subscriptions — that was the deliberate decision, because a central team gating every deployment is a queue, and a queue is an outage waiting for a maintenance window.

Three weeks after go-live, an internal audit produces this:

| Finding | Count | RBAC prevented it? |
|---|---|---|
| Storage accounts with `allowBlobPublicAccess: true` | 31 | No |
| Resources with no `costCenter` tag | 4,118 | No |
| PaaS resources with no diagnostic settings (no audit trail) | 907 | No |
| VMs deployed in `brazilsouth` against a data-residency commitment | 12 | No |
| A production Log Analytics workspace deleted by a `terraform destroy` against the wrong workspace | 1 | No |

Every one of those actions was performed by a principal that was **correctly authorized**. RBAC answered its question — *may this identity perform `Microsoft.Storage/storageAccounts/write`?* — correctly, every time. RBAC has no vocabulary for the questions the audit is actually asking:

- *What shape may the resource have?* (`allowBlobPublicAccess` must be `false`)
- *What must exist alongside it?* (a diagnostic setting shipping to the platform workspace)
- *What may never be destroyed, by anyone, regardless of role?* (the hub VNet, the ExpressRoute circuit, the shared workspace)

Those are three separate control planes, and Azure gives you a distinct primitive for each.

### 1.2 The four planes of Azure governance

```
                        ┌──────────────────────────────────────────────┐
  WHO can act?    ───▶  │  Azure RBAC + deny assignments               │  Identity plane
                        │  role assignments, PIM, ABAC conditions      │
                        └──────────────────────────────────────────────┘
                        ┌──────────────────────────────────────────────┐
  WHAT shape is    ───▶ │  Azure Policy                                │  Configuration plane
  allowed / must        │  definitions, initiatives, assignments,      │
  be true?              │  exemptions, remediation, Machine Config     │
                        └──────────────────────────────────────────────┘
                        ┌──────────────────────────────────────────────┐
  WHAT may not     ───▶ │  Resource locks / deployment-stack           │  Lifecycle plane
  be destroyed or       │  denySettings / Policy DenyAction            │
  mutated?              └──────────────────────────────────────────────┘
                        ┌──────────────────────────────────────────────┐
  WHAT is actually ───▶ │  Microsoft Purview (data) · Defender for     │  Evidence plane
  in the data, and      │  Cloud regulatory dashboard (posture) ·      │
  can I prove           │  Compliance Manager (self-assessment) ·      │
  compliance?           │  Service Trust Portal (Microsoft's audits)   │
                        └──────────────────────────────────────────────┘
```

**The single most important architectural property:** Azure Policy and locks evaluate at the **Azure Resource Manager (ARM) control plane**, which every path into Azure funnels through — portal, CLI, PowerShell, Terraform, Bicep, ARM REST, SDKs, Azure DevOps, GitHub Actions. There is no back door. A `Deny` policy assigned at a management group is enforced against a subscription Owner running `az` from a laptop just as it is against a service principal in a pipeline.

**The single most important limitation:** none of these primitives sees the **data plane**. A lock on a storage account does not prevent `az storage blob delete`. A policy on a SQL server does not prevent `DROP TABLE`. Control-plane governance stops at `management.azure.com`. This distinction is examined, and it is the source of most production surprises (§8.3).

### 1.3 Scope and inheritance — the substrate everything sits on

Governance is applied to a **scope**, and scopes form a strict tree:

```
Root management group (tenant ID as name, one per Entra tenant)
└── mg-contoso                      ← "intermediate root"; never assign to the actual root
    ├── mg-platform
    │   ├── mg-identity             → sub-identity-prod
    │   ├── mg-management           → sub-mgmt-prod       (Log Analytics, automation)
    │   └── mg-connectivity         → sub-conn-prod       (hub VNet, firewall, ER circuit)
    ├── mg-landingzones
    │   ├── mg-corp                 → sub-app-a-prod, sub-app-b-prod, ...
    │   └── mg-online               → sub-web-prod, ...
    ├── mg-sandbox                  → sub-dev-*           (relaxed policy set)
    └── mg-decommissioned           → subscriptions being wound down
```

Rules you must internalise:

- Assignments **inherit downward** and cannot be overridden upward. A child scope has **no mechanism to relax** a parent's `Deny`. There is no "allow" effect in Azure Policy — this is intentional and is what makes the model auditable.
- Management group hierarchy is **six levels deep** below the root, excluding the root level and the subscription level. Each management group has exactly one parent.
- A subscription belongs to exactly one management group.
- Assign at the **highest scope where the statement is universally true**, and use `notScopes` (exclusions) or exemptions for the exceptions — not a lower re-assignment.

> **Exam framing.** "You want a policy to apply to all current *and future* subscriptions in a business unit." → assign it at the **management group**, not at each subscription.

**References:** [Management groups overview](https://learn.microsoft.com/en-us/azure/governance/management-groups/overview) · [Understand scope in Azure Policy](https://learn.microsoft.com/en-us/azure/governance/policy/concepts/scope) · [Azure landing zone design areas](https://learn.microsoft.com/en-us/azure/cloud-adoption-framework/ready/landing-zone/)

---

## 2. Azure Policy — mechanics

### 2.1 The object model

```
policyDefinition            the rule: "if <condition> then <effect>"
  └─ parameters             typed inputs (allowedLocations, effect, logAnalytics…)
  └─ policyRule.if          condition over aliases / fields / values
  └─ policyRule.then        effect + details (roleDefinitionIds, deployment, operations)
  └─ mode                   All | Indexed | Microsoft.Kubernetes.Data | Microsoft.KeyVault.Data …

policySetDefinition         "initiative" — an ordered bundle of definitions with
(initiative)                parameter wiring and optional policyDefinitionGroups
                            (used to map definitions to regulatory controls)

policyAssignment            definition-or-initiative + scope + parameter values
  └─ notScopes[]            sub-scopes carved out of the assignment
  └─ identity               system- or user-assigned MI, required for DINE/Modify
  └─ enforcementMode        Default | DoNotEnforce  ("what-if" mode)
  └─ nonComplianceMessages  the text an engineer sees when denied
  └─ overrides[] / resourceSelectors[]   effect override + staged rollout by region/type

policyExemption             time-boxed, audited carve-out of a resource from an
                            assignment: category Waiver | Mitigated, with expiresOn
```

`policyExemption` is the mechanism that keeps governance survivable. It leaves an auditable record (`who`, `why`, `until when`) whereas `notScopes` silently widens a hole forever. **Prefer exemptions for exceptions; reserve `notScopes` for structural carve-outs** such as excluding `mg-sandbox` from a production-only initiative.

### 2.2 `mode` — the property people get wrong

| `mode` | Evaluates | Use for |
|---|---|---|
| `All` | Resource groups, subscriptions, **and all resource types** | Anything targeting RGs/subscriptions, or resource types that do not support tags/location (e.g. `Microsoft.Network/routeTables/routes`) |
| `Indexed` | **Only resource types that support tags and location** | Every tag policy, every location policy. Using `All` for a tag policy produces false non-compliance on child resources that cannot hold a tag |
| `Microsoft.Kubernetes.Data` | AKS / Arc-enabled Kubernetes admission via Gatekeeper | Pod security, allowed registries, required labels |
| `Microsoft.KeyVault.Data` | Key Vault objects (certificates, keys, secrets) | Certificate lifetime, key size, HSM-backed keys |
| `Microsoft.Network.Data` | Virtual Network Manager network groups | `addToNetworkGroup` effect |

### 2.3 Effects — comparison and trade-offs

Effects are **not** evaluated in the order they are written. Order of evaluation:

```
1. Disabled                     ← short-circuits everything; nothing else is evaluated
2. Append / Modify              ← mutate the incoming request payload
3. Deny                         ← reject the request before the RP sees it
4. Audit                        ← allow, mark non-compliant, write to the compliance store
5. AuditIfNotExists /           ← evaluated AFTER the resource provider returns success,
   DeployIfNotExists              because they inspect *related* resources
```

| Effect | Blocks the request? | Needs managed identity | Fixes existing resources | Failure mode you will hit |
|---|:--:|:--:|:--:|---|
| `Audit` | No | No | No | Silently accumulates thousands of findings nobody triages. Use as *stage 1* only |
| `Deny` | **Yes** | No | No | Breaks pipelines with an opaque error unless `nonComplianceMessages` is set |
| `DenyAction` | Yes, on `delete` (and other named actions) | No | No | The modern, scope-scalable alternative to hand-placed locks; still control-plane only |
| `Append` | No — mutates create/update | No | No | **Only applies on write.** Existing resources are untouched and are *not* reported non-compliant. Largely superseded by `Modify` |
| `Modify` | No — mutates create/update | **Yes** | Yes, via remediation task | MI missing the role in `roleDefinitionIds` → remediation fails with `AuthorizationFailed` |
| `AuditIfNotExists` | No | No | No | `existenceCondition` written against the wrong scope silently reports everything compliant |
| `DeployIfNotExists` (DINE) | No | **Yes** | Yes, via remediation task | The single most operationally complex effect. See §8.2 |
| `Disabled` | No | No | No | The correct way to park a definition inside an initiative without deleting it |
| `Manual` | No | No | No | Attestation-based; for controls Azure cannot mechanically observe (e.g. "background checks performed") |
| `AddToNetworkGroup` | No | No | n/a | Azure Virtual Network Manager dynamic membership only |

**Rollout doctrine.** Never assign a new `Deny` cold. The sequence that survives contact with application teams:

```
enforcementMode = DoNotEnforce   →  observe "would have been denied" for 2 sprints
       ↓
effect = Audit                   →  publish the non-compliance list to owning teams
       ↓
effect = Deny at mg-sandbox      →  canary; resourceSelectors can stage by region
       ↓
effect = Deny at mg-landingzones →  with nonComplianceMessages and a documented exemption path
```

### 2.4 Evaluation timing — the numbers that explain "it isn't working"

| Trigger | Latency |
|---|---|
| Resource create/update via ARM | Synchronous, in the request path (`Deny`, `Modify`, `Append`) |
| New or changed policy **assignment** | Up to ~**30 minutes** before the effect is active |
| Standard compliance scan | Every **24 hours** |
| Scan after a policy/initiative definition update in an existing assignment | Triggered automatically |
| On-demand scan | `az policy state trigger-scan` — minutes to hours depending on scope breadth |
| Kubernetes add-on assignment pull | ~**15 minutes** |
| Kubernetes full-cluster compliance report | ~**15 minutes** (budget ~30 min end-to-end) |

**References:** [Azure Policy overview](https://learn.microsoft.com/en-us/azure/governance/policy/overview) · [Effects](https://learn.microsoft.com/en-us/azure/governance/policy/concepts/effects) · [Definition structure](https://learn.microsoft.com/en-us/azure/governance/policy/concepts/definition-structure) · [Assignment structure](https://learn.microsoft.com/en-us/azure/governance/policy/concepts/assignment-structure) · [Exemption structure](https://learn.microsoft.com/en-us/azure/governance/policy/concepts/exemption-structure)

---

## 3. Complete, deployable artefacts

Everything below is production-shaped and syntactically complete. Azure Policy definitions are JSON (ARM's native format); Kubernetes constraints and CI are YAML.

### 3.1 `Deny` — storage accounts must not allow public blob access

`policies/definitions/deny-storage-public-blob-access.json`

```json
{
  "name": "deny-storage-public-blob-access",
  "type": "Microsoft.Authorization/policyDefinitions",
  "apiVersion": "2023-04-01",
  "properties": {
    "displayName": "Storage accounts must disable anonymous blob public access",
    "policyType": "Custom",
    "mode": "Indexed",
    "description": "Anonymous public read access to blob containers bypasses Entra ID and every network control. This definition denies creation or update of a storage account whose allowBlobPublicAccess property is not explicitly false.",
    "metadata": {
      "version": "1.1.0",
      "category": "Storage",
      "source": "https://github.com/contoso/platform-governance"
    },
    "parameters": {
      "effect": {
        "type": "String",
        "metadata": {
          "displayName": "Effect",
          "description": "Deny blocks the request; Audit records non-compliance only."
        },
        "allowedValues": [ "Audit", "Deny", "Disabled" ],
        "defaultValue": "Audit"
      },
      "exemptedAccountPrefixes": {
        "type": "Array",
        "metadata": {
          "displayName": "Exempted storage account name prefixes",
          "description": "Accounts whose name starts with one of these prefixes are skipped, e.g. static website hosting accounts."
        },
        "defaultValue": []
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
            "anyOf": [
              {
                "field": "Microsoft.Storage/storageAccounts/allowBlobPublicAccess",
                "exists": "false"
              },
              {
                "field": "Microsoft.Storage/storageAccounts/allowBlobPublicAccess",
                "notEquals": "false"
              }
            ]
          },
          {
            "count": {
              "value": "[parameters('exemptedAccountPrefixes')]",
              "name": "prefix",
              "where": {
                "field": "name",
                "like": "[concat(current('prefix'), '*')]"
              }
            },
            "equals": 0
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

Two details that matter and are routinely missed:

1. The `exists: false` branch. If a property is absent from the payload, `notEquals` alone does **not** match — you must test for absence explicitly or resources created by older API versions slip through.
2. `count` with `where` and `current()` is how you express "none of the elements of this array match" — the array-quantifier syntax. Without it you cannot parameterise exclusion lists inside a definition.

### 3.2 `DeployIfNotExists` — diagnostic settings, complete with remediation wiring

`policies/definitions/dine-keyvault-diagnostics.json`

```json
{
  "name": "dine-keyvault-diagnostics-to-law",
  "type": "Microsoft.Authorization/policyDefinitions",
  "apiVersion": "2023-04-01",
  "properties": {
    "displayName": "Deploy diagnostic settings for Key Vault to the platform Log Analytics workspace",
    "policyType": "Custom",
    "mode": "Indexed",
    "description": "A Key Vault with no diagnostic setting produces no AuditEvent stream, so secret access is unreconstructable after an incident. This definition creates the setting if it is absent.",
    "metadata": {
      "version": "2.0.1",
      "category": "Monitoring"
    },
    "parameters": {
      "logAnalyticsWorkspaceId": {
        "type": "String",
        "metadata": {
          "displayName": "Log Analytics workspace resource ID",
          "description": "Full ARM resource ID of the destination workspace.",
          "strongType": "Microsoft.OperationalInsights/workspaces",
          "assignPermissions": true
        }
      },
      "profileName": {
        "type": "String",
        "metadata": {
          "displayName": "Diagnostic settings name"
        },
        "defaultValue": "platform-diagnostics"
      },
      "effect": {
        "type": "String",
        "allowedValues": [ "DeployIfNotExists", "AuditIfNotExists", "Disabled" ],
        "defaultValue": "DeployIfNotExists",
        "metadata": {
          "displayName": "Effect"
        }
      }
    },
    "policyRule": {
      "if": {
        "field": "type",
        "equals": "Microsoft.KeyVault/vaults"
      },
      "then": {
        "effect": "[parameters('effect')]",
        "details": {
          "type": "Microsoft.Insights/diagnosticSettings",
          "name": "[parameters('profileName')]",
          "existenceCondition": {
            "allOf": [
              {
                "field": "Microsoft.Insights/diagnosticSettings/logs.enabled",
                "equals": "true"
              },
              {
                "field": "Microsoft.Insights/diagnosticSettings/workspaceId",
                "equals": "[parameters('logAnalyticsWorkspaceId')]"
              }
            ]
          },
          "roleDefinitionIds": [
            "/providers/Microsoft.Authorization/roleDefinitions/749f88d5-cbae-40b8-bcfc-e573ddc772fa",
            "/providers/Microsoft.Authorization/roleDefinitions/92aaf0da-9dab-42b6-94a3-d43ce8d16293"
          ],
          "deployment": {
            "properties": {
              "mode": "incremental",
              "parameters": {
                "vaultName": {
                  "value": "[field('name')]"
                },
                "location": {
                  "value": "[field('location')]"
                },
                "logAnalyticsWorkspaceId": {
                  "value": "[parameters('logAnalyticsWorkspaceId')]"
                },
                "profileName": {
                  "value": "[parameters('profileName')]"
                }
              },
              "template": {
                "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#",
                "contentVersion": "1.0.0.0",
                "parameters": {
                  "vaultName": { "type": "string" },
                  "location": { "type": "string" },
                  "logAnalyticsWorkspaceId": { "type": "string" },
                  "profileName": { "type": "string" }
                },
                "resources": [
                  {
                    "type": "Microsoft.KeyVault/vaults/providers/diagnosticSettings",
                    "apiVersion": "2021-05-01-preview",
                    "name": "[concat(parameters('vaultName'), '/Microsoft.Insights/', parameters('profileName'))]",
                    "location": "[parameters('location')]",
                    "properties": {
                      "workspaceId": "[parameters('logAnalyticsWorkspaceId')]",
                      "logs": [
                        {
                          "category": "AuditEvent",
                          "enabled": true
                        },
                        {
                          "category": "AzurePolicyEvaluationDetails",
                          "enabled": true
                        }
                      ],
                      "metrics": [
                        {
                          "category": "AllMetrics",
                          "enabled": true,
                          "timeGrain": null
                        }
                      ]
                    }
                  }
                ],
                "outputs": {
                  "diagnosticSettingId": {
                    "type": "string",
                    "value": "[resourceId('Microsoft.KeyVault/vaults/providers/diagnosticSettings', parameters('vaultName'), 'Microsoft.Insights', parameters('profileName'))]"
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}
```

Role GUID legend (JSON forbids comments, so it lives here):

| GUID | Built-in role | Why it is needed |
|---|---|---|
| `749f88d5-cbae-40b8-bcfc-e573ddc772fa` | Monitoring Contributor | Create `Microsoft.Insights/diagnosticSettings` |
| `92aaf0da-9dab-42b6-94a3-d43ce8d16293` | Log Analytics Contributor | Write to the destination workspace |

`"assignPermissions": true` on the workspace parameter tells the portal to offer a role assignment on that workspace when the assignment is created — necessary when the workspace lives in a *different* subscription from the assignment scope, which is the normal landing-zone topology.

### 3.3 `Modify` — inherit a tag from the resource group

`policies/definitions/modify-inherit-costcenter-tag.json`

```json
{
  "name": "modify-inherit-tag-from-rg",
  "type": "Microsoft.Authorization/policyDefinitions",
  "apiVersion": "2023-04-01",
  "properties": {
    "displayName": "Inherit a tag from the resource group if it is missing or different",
    "policyType": "Custom",
    "mode": "Indexed",
    "description": "Adds or replaces the specified tag on a resource with the value carried by its parent resource group. Enables cost allocation without requiring every team to tag every resource.",
    "metadata": {
      "version": "1.0.0",
      "category": "Tags"
    },
    "parameters": {
      "tagName": {
        "type": "String",
        "metadata": {
          "displayName": "Tag name",
          "description": "Name of the tag, such as costCenter"
        }
      }
    },
    "policyRule": {
      "if": {
        "allOf": [
          {
            "field": "[concat('tags[', parameters('tagName'), ']')]",
            "notEquals": "[resourceGroup().tags[parameters('tagName')]]"
          },
          {
            "value": "[resourceGroup().tags[parameters('tagName')]]",
            "notEquals": ""
          }
        ]
      },
      "then": {
        "effect": "modify",
        "details": {
          "roleDefinitionIds": [
            "/providers/Microsoft.Authorization/roleDefinitions/4a9ae827-6dc8-4573-8ac7-8239d42aa03f"
          ],
          "operations": [
            {
              "operation": "addOrReplace",
              "field": "[concat('tags[', parameters('tagName'), ']')]",
              "value": "[resourceGroup().tags[parameters('tagName')]]"
            }
          ]
        }
      }
    }
  }
}
```

`4a9ae827-6dc8-4573-8ac7-8239d42aa03f` is **Tag Contributor** — the least-privilege role that can write tags without granting resource write.

### 3.4 The initiative (policy set) that binds them together

`policies/initiatives/contoso-platform-baseline.json`

```json
{
  "name": "contoso-platform-baseline",
  "type": "Microsoft.Authorization/policySetDefinitions",
  "apiVersion": "2023-04-01",
  "properties": {
    "displayName": "Contoso platform baseline",
    "policyType": "Custom",
    "description": "Minimum governance baseline applied to every landing zone subscription. Grouped by ISO 27001:2022 control for the compliance report.",
    "metadata": {
      "version": "3.4.0",
      "category": "Platform baseline"
    },
    "parameters": {
      "allowedLocations": {
        "type": "Array",
        "metadata": {
          "displayName": "Allowed regions",
          "strongType": "location"
        },
        "defaultValue": [ "westeurope", "northeurope" ]
      },
      "storagePublicAccessEffect": {
        "type": "String",
        "allowedValues": [ "Audit", "Deny", "Disabled" ],
        "defaultValue": "Deny"
      },
      "logAnalyticsWorkspaceId": {
        "type": "String",
        "metadata": {
          "displayName": "Platform Log Analytics workspace",
          "strongType": "Microsoft.OperationalInsights/workspaces",
          "assignPermissions": true
        }
      },
      "costCenterTagName": {
        "type": "String",
        "defaultValue": "costCenter"
      }
    },
    "policyDefinitionGroups": [
      {
        "name": "ISO27001-A8.20",
        "displayName": "A.8.20 Network security",
        "category": "ISO 27001:2022"
      },
      {
        "name": "ISO27001-A8.15",
        "displayName": "A.8.15 Logging",
        "category": "ISO 27001:2022"
      },
      {
        "name": "FINOPS",
        "displayName": "Cost allocation",
        "category": "Internal"
      }
    ],
    "policyDefinitions": [
      {
        "policyDefinitionReferenceId": "allowedLocations",
        "policyDefinitionId": "/providers/Microsoft.Authorization/policyDefinitions/e56962a6-4747-49cd-b67b-bf8b01975c4c",
        "groupNames": [ "ISO27001-A8.20" ],
        "parameters": {
          "listOfAllowedLocations": {
            "value": "[parameters('allowedLocations')]"
          }
        }
      },
      {
        "policyDefinitionReferenceId": "denyStoragePublicBlobAccess",
        "policyDefinitionId": "/providers/Microsoft.Management/managementGroups/mg-contoso/providers/Microsoft.Authorization/policyDefinitions/deny-storage-public-blob-access",
        "groupNames": [ "ISO27001-A8.20" ],
        "parameters": {
          "effect": {
            "value": "[parameters('storagePublicAccessEffect')]"
          },
          "exemptedAccountPrefixes": {
            "value": [ "stpublicweb" ]
          }
        }
      },
      {
        "policyDefinitionReferenceId": "keyVaultDiagnostics",
        "policyDefinitionId": "/providers/Microsoft.Management/managementGroups/mg-contoso/providers/Microsoft.Authorization/policyDefinitions/dine-keyvault-diagnostics-to-law",
        "groupNames": [ "ISO27001-A8.15" ],
        "parameters": {
          "logAnalyticsWorkspaceId": {
            "value": "[parameters('logAnalyticsWorkspaceId')]"
          },
          "effect": {
            "value": "DeployIfNotExists"
          }
        }
      },
      {
        "policyDefinitionReferenceId": "inheritCostCenterTag",
        "policyDefinitionId": "/providers/Microsoft.Management/managementGroups/mg-contoso/providers/Microsoft.Authorization/policyDefinitions/modify-inherit-tag-from-rg",
        "groupNames": [ "FINOPS" ],
        "parameters": {
          "tagName": {
            "value": "[parameters('costCenterTagName')]"
          }
        }
      },
      {
        "policyDefinitionReferenceId": "auditVmsWithoutManagedDisks",
        "policyDefinitionId": "/providers/Microsoft.Authorization/policyDefinitions/06a78e20-9358-41c9-923c-fb736d382a4d",
        "groupNames": [ "ISO27001-A8.20" ]
      }
    ]
  }
}
```

`policyDefinitionGroups` is what turns a flat list of rules into a **regulatory compliance report**: the Azure Policy compliance blade renders findings grouped by control, which is the artefact an auditor actually accepts.

The two GUID `policyDefinitionId` values are Microsoft built-ins (`e56962a6…` = *Allowed locations*, `06a78e20…` = *Audit VMs that do not use managed disks*). **Prefer built-ins**: they are versioned, tested by Microsoft, and mapped into the regulatory compliance initiatives.

### 3.5 Bicep — management-group deployment with identity and role assignment

`infra/governance/main.bicep`

```bicep
targetScope = 'managementGroup'

@description('Management group where the baseline is assigned.')
param targetManagementGroupId string = 'mg-landingzones'

@description('Full resource ID of the platform Log Analytics workspace.')
param logAnalyticsWorkspaceId string

@description('Regions the estate is permitted to deploy into.')
param allowedLocations array = [
  'westeurope'
  'northeurope'
]

@allowed([
  'Default'
  'DoNotEnforce'
])
@description('DoNotEnforce runs the assignment in what-if mode: compliance is computed, effects are not applied.')
param enforcementMode string = 'DoNotEnforce'

@description('Region for the assignment managed identity. Does not restrict what the assignment governs.')
param identityLocation string = 'westeurope'

var baselineInitiativeId = tenantResourceId(
  'Microsoft.Authorization/policySetDefinitions',
  'contoso-platform-baseline'
)

// Built-in roles the remediation identity needs.
var monitoringContributorRoleId = '749f88d5-cbae-40b8-bcfc-e573ddc772fa'
var logAnalyticsContributorRoleId = '92aaf0da-9dab-42b6-94a3-d43ce8d16293'
var tagContributorRoleId = '4a9ae827-6dc8-4573-8ac7-8239d42aa03f'

resource baselineAssignment 'Microsoft.Authorization/policyAssignments@2024-04-01' = {
  name: 'contoso-baseline'
  location: identityLocation
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    displayName: 'Contoso platform baseline'
    description: 'Minimum governance baseline for all landing zone subscriptions.'
    policyDefinitionId: baselineInitiativeId
    enforcementMode: enforcementMode
    notScopes: [
      managementGroupResourceId('mg-sandbox')
    ]
    parameters: {
      allowedLocations: {
        value: allowedLocations
      }
      storagePublicAccessEffect: {
        value: 'Deny'
      }
      logAnalyticsWorkspaceId: {
        value: logAnalyticsWorkspaceId
      }
      costCenterTagName: {
        value: 'costCenter'
      }
    }
    nonComplianceMessages: [
      {
        message: 'This deployment violates the Contoso platform baseline. Request an exemption at https://contoso.service-now.com/gov or read https://wiki.contoso.com/platform/baseline.'
      }
      {
        policyDefinitionReferenceId: 'denyStoragePublicBlobAccess'
        message: 'Storage accounts must set allowBlobPublicAccess=false. Use a SAS token or Entra ID auth for external readers.'
      }
      {
        policyDefinitionReferenceId: 'allowedLocations'
        message: 'Data residency: deploy to westeurope or northeurope only.'
      }
    ]
  }
}

// Grant the assignment's managed identity the roles declared in roleDefinitionIds.
// Without these, DINE/Modify remediation fails with AuthorizationFailed.
resource monitoringContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(targetManagementGroupId, baselineAssignment.id, monitoringContributorRoleId)
  properties: {
    roleDefinitionId: tenantResourceId('Microsoft.Authorization/roleDefinitions', monitoringContributorRoleId)
    principalId: baselineAssignment.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource logAnalyticsContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(targetManagementGroupId, baselineAssignment.id, logAnalyticsContributorRoleId)
  properties: {
    roleDefinitionId: tenantResourceId('Microsoft.Authorization/roleDefinitions', logAnalyticsContributorRoleId)
    principalId: baselineAssignment.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource tagContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(targetManagementGroupId, baselineAssignment.id, tagContributorRoleId)
  properties: {
    roleDefinitionId: tenantResourceId('Microsoft.Authorization/roleDefinitions', tagContributorRoleId)
    principalId: baselineAssignment.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

output assignmentId string = baselineAssignment.id
output remediationPrincipalId string = baselineAssignment.identity.principalId
```

`principalType: 'ServicePrincipal'` is not cosmetic — omit it and the role assignment intermittently fails with `PrincipalNotFound` because Entra ID replication has not yet propagated the newly created managed identity.

### 3.6 Terraform equivalent

`terraform/governance/main.tf`

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
  features {}
}

variable "management_group_id" {
  type        = string
  description = "Short name of the target management group."
  default     = "mg-landingzones"
}

variable "log_analytics_workspace_id" {
  type        = string
  description = "Full ARM resource ID of the platform workspace."
}

data "azurerm_management_group" "target" {
  name = var.management_group_id
}

resource "azurerm_policy_definition" "deny_storage_public_blob" {
  name                = "deny-storage-public-blob-access"
  policy_type         = "Custom"
  mode                = "Indexed"
  display_name        = "Storage accounts must disable anonymous blob public access"
  management_group_id = data.azurerm_management_group.target.id

  metadata = jsonencode({
    version  = "1.1.0"
    category = "Storage"
  })

  parameters = jsonencode({
    effect = {
      type          = "String"
      allowedValues = ["Audit", "Deny", "Disabled"]
      defaultValue  = "Audit"
      metadata      = { displayName = "Effect" }
    }
  })

  policy_rule = jsonencode({
    if = {
      allOf = [
        { field = "type", equals = "Microsoft.Storage/storageAccounts" },
        {
          anyOf = [
            { field = "Microsoft.Storage/storageAccounts/allowBlobPublicAccess", exists = "false" },
            { field = "Microsoft.Storage/storageAccounts/allowBlobPublicAccess", notEquals = "false" }
          ]
        }
      ]
    }
    then = {
      effect = "[parameters('effect')]"
    }
  })
}

resource "azurerm_management_group_policy_assignment" "baseline" {
  name                 = "contoso-baseline"
  management_group_id  = data.azurerm_management_group.target.id
  policy_definition_id = azurerm_policy_definition.deny_storage_public_blob.id
  display_name         = "Contoso platform baseline"
  location             = "westeurope"
  enforce              = false # maps to enforcementMode = DoNotEnforce

  not_scopes = [
    "/providers/Microsoft.Management/managementGroups/mg-sandbox"
  ]

  identity {
    type = "SystemAssigned"
  }

  parameters = jsonencode({
    effect = { value = "Deny" }
  })

  non_compliance_message {
    content = "This deployment violates the Contoso platform baseline. See https://wiki.contoso.com/platform/baseline."
  }
}

resource "azurerm_role_assignment" "baseline_monitoring_contributor" {
  scope                = data.azurerm_management_group.target.id
  role_definition_name = "Monitoring Contributor"
  principal_id         = azurerm_management_group_policy_assignment.baseline.identity[0].principal_id
  principal_type       = "ServicePrincipal"
}

# ---- Lifecycle plane: resource lock on the shared hub network ----

resource "azurerm_management_lock" "hub_vnet" {
  name       = "lock-hub-vnet-no-delete"
  scope      = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-connectivity-prod/providers/Microsoft.Network/virtualNetworks/vnet-hub-weu"
  lock_level = "CanNotDelete"
  notes      = "Shared hub. Deleting it severs every spoke peering. Removal requires CAB approval CHG-#### (owner: platform-network@contoso.com)."
}
```

> **Terraform-specific hazard.** A `CanNotDelete` lock on a resource Terraform manages makes `terraform destroy` and any replace-requiring change fail with `ScopeLocked`. That is the point — but it means locks and Terraform state must be owned by the same team, or you will produce a permanently drifted state file.

---

## 4. Resource locks — the lifecycle plane

### 4.1 The two lock levels

| Lock level | Portal label | Blocks | Permits |
|---|---|---|---|
| `CanNotDelete` | **Delete** | `DELETE` on the resource | Read, and all write/update operations |
| `ReadOnly` | **Read-only** | `DELETE` **and** all `PUT`/`PATCH`/**`POST`** | `GET` only |

`ReadOnly` blocking `POST` is the clause that produces production incidents, because a surprising number of *read* operations in Azure are implemented as `POST`:

| Operation | HTTP verb | Blocked by `ReadOnly`? |
|---|:--:|:--:|
| `Microsoft.Storage/storageAccounts/listKeys/action` | POST | **Yes** — breaks the portal's blob browser and any SDK using key auth |
| `Microsoft.Compute/virtualMachines/start/action` | POST | **Yes** |
| `Microsoft.Compute/virtualMachines/restart/action` | POST | **Yes** |
| `Microsoft.Web/sites/publishxml/action` | POST | **Yes** — breaks App Service deployment |
| `Microsoft.KeyVault/vaults/secrets/read` (data plane) | GET on `vault.azure.net` | **No** — different plane |
| Deleting a blob (data plane) | DELETE on `blob.core.windows.net` | **No** |

**Doctrine: use `CanNotDelete` by default. Reach for `ReadOnly` only on a frozen resource you have proven nobody operates**, such as a decommissioned subscription's resources awaiting the retention window.

### 4.2 Inheritance and precedence

- A lock applied at a **subscription**, **resource group**, or **parent resource** is inherited by all children.
- When multiple locks apply, **the most restrictive wins**. A `ReadOnly` at the RG plus a `CanNotDelete` on one resource yields `ReadOnly` behaviour for that resource.
- A lock is a resource in its own right (`Microsoft.Authorization/locks`), so it appears in the resource graph and can be inventoried.
- Deleting a resource group requires **removing every lock in it first** — including locks on child resources. This is why `az group delete` on a well-governed RG fails in a way that confuses people; see §8.3.
- Locks **cannot** be applied at management group scope. Management-group-wide deletion protection is `DenyAction` policy or deployment stacks.

### 4.3 Permissions

Creating or deleting a lock requires `Microsoft.Authorization/locks/*`. Only two built-in roles carry it: **Owner** and **User Access Administrator**.

This is the structural weakness of locks: **a lock protects against accident, not against intent.** Any Owner can remove a lock and then delete the resource, in two API calls, with no approval gate.

### 4.4 The comparison you are actually being asked for

| | Resource lock | `DenyAction` policy | Deployment stack `denySettings` | Deny assignment (RBAC) |
|---|---|---|---|---|
| Applied to | Resource, RG, subscription | Any scope incl. management group | Resources managed by the stack | Any scope |
| Scales to "all future resources"? | No — placed per resource | **Yes** | Yes, within the stack | Yes |
| Blocks delete | Yes | Yes | Yes (`denyDelete`) | Yes |
| Blocks write | Only `ReadOnly` (blocks POST too) | No | Yes (`denyWriteAndDelete`) | Yes |
| Can an Owner bypass it? | **Yes** — remove the lock | Yes — remove/exempt the assignment | Only by mutating the stack | **No** — deny assignments are not removable by data actions |
| Created by | You | You | The stack, automatically | Azure only (Blueprints legacy, managed apps, stacks) |
| Exception mechanism | Delete the lock | Policy exemption (audited, expiring) | `excludedPrincipals`, `excludedActions` | Stack/managed-app definition |
| Exam relevance | **Core** | Beyond scope | Beyond scope | Beyond scope |

**[beyond exam scope]** **Deployment stacks** are the modern answer to "protect everything this deployment created, and garbage-collect what it stops creating." A stack is an ARM resource that owns a set of resources; `denySettings` is materialised as **deny assignments**, which — unlike locks — an Owner cannot simply delete. This is also the migration target for **Azure Blueprints**, which Microsoft deprecated with retirement on **11 July 2026**; the replacement pattern is **Template Specs** (versioned, tenant-shareable templates) plus **Deployment Stacks** (lifecycle + deny) plus **Azure Policy** (ongoing enforcement).

`infra/stacks/hub-network.bicepparam` + stack deployment:

```bicep
// infra/stacks/hub-network.bicep
targetScope = 'resourceGroup'

param location string = resourceGroup().location
param hubAddressSpace string = '10.0.0.0/16'

resource hubVnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: 'vnet-hub-weu'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [ hubAddressSpace ]
    }
    subnets: [
      {
        name: 'AzureFirewallSubnet'
        properties: { addressPrefix: '10.0.1.0/26' }
      }
      {
        name: 'GatewaySubnet'
        properties: { addressPrefix: '10.0.2.0/27' }
      }
      {
        name: 'AzureBastionSubnet'
        properties: { addressPrefix: '10.0.3.0/26' }
      }
    ]
  }
}

output hubVnetId string = hubVnet.id
```

```bash
$ az stack group create \
    --name stack-hub-network \
    --resource-group rg-connectivity-prod \
    --template-file infra/stacks/hub-network.bicep \
    --deny-settings-mode denyWriteAndDelete \
    --deny-settings-excluded-principals "8f3b2c14-9e21-4f6a-b2d7-5a1c9e04d3f8" \
    --deny-settings-excluded-actions "Microsoft.Network/virtualNetworks/subnets/join/action" \
    --deny-settings-apply-to-child-scopes \
    --action-on-unmanage detachAll \
    --yes
```

`--deny-settings-excluded-actions "…/subnets/join/action"` is mandatory in practice: without it, spoke workloads cannot attach NICs to hub subnets and every peered deployment fails with `RequestDisallowedByPolicy`-style deny-assignment errors.

**References:** [Lock resources to prevent unexpected changes](https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/lock-resources) · [Deployment stacks](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/deployment-stacks) · [Template specs](https://learn.microsoft.com/en-us/azure/azure-resource-manager/templates/template-specs) · [Deny assignments](https://learn.microsoft.com/en-us/azure/role-based-access-control/deny-assignments) · [Azure Blueprints overview (deprecation notice)](https://learn.microsoft.com/en-us/azure/governance/blueprints/overview)

---

## 5. **[beyond exam scope]** Azure Policy for Kubernetes — where governance meets CNCF

This section exists because the AZ-900 objective is the conceptual entry point to the control you will actually operate on AKS.

The `azure-policy` add-on installs **Gatekeeper v3** (the OPA admission controller, a CNCF project) into the cluster and translates Azure Policy assignments into Gatekeeper `ConstraintTemplate` and `Constraint` custom resources. The mapping:

| Azure Policy concept | Kubernetes / Gatekeeper concept |
|---|---|
| Policy definition, `mode: Microsoft.Kubernetes.Data` | `ConstraintTemplate` (Rego in `spec.targets[].rego`) |
| Policy assignment + parameters | `Constraint` (an instance of the template) |
| `effect: deny` | `enforcementAction: deny` on the constraint |
| `effect: audit` | `enforcementAction: dryrun` |
| Compliance state | Gatekeeper audit results, exported to Azure Policy every ~15 min |
| Assignment `excludedNamespaces` | `spec.match.excludedNamespaces` |

Enable and inspect:

```bash
$ az aks enable-addons --addons azure-policy \
    --name aks-corp-weu-01 \
    --resource-group rg-app-a-prod
```

```bash
$ kubectl get pods -n gatekeeper-system
NAME                                             READY   STATUS    RESTARTS   AGE
gatekeeper-audit-6c9f7d5b84-2xk9m                1/1     Running   0          14m
gatekeeper-controller-manager-7d84f6bb95-mn4qt   1/1     Running   0          14m
gatekeeper-controller-manager-7d84f6bb95-r8vsp   1/1     Running   0          14m

$ kubectl get pods -n kube-system -l app=azure-policy
NAME                                      READY   STATUS    RESTARTS   AGE
azure-policy-6bb5c9d47f-lq2hd             1/1     Running   0          14m
azure-policy-webhook-5f9c8d6b74-td7cz     1/1     Running   0          14m
```

After assigning the built-in initiative *Kubernetes cluster pod security restricted standards for Linux-based workloads*:

```bash
$ kubectl get constrainttemplates
NAME                                     AGE
k8sazurev1noprivilege                    11m
k8sazurev2blockhostnamespace             11m
k8sazurev1allowedcapabilities            11m
k8sazurev2containerallowedimages         11m
k8sazurev1hostfilesystem                 11m

$ kubectl get constraints
NAME                                                              ENFORCEMENT-ACTION   TOTAL-VIOLATIONS
azurepolicy-k8sazurev1noprivilege-4c8a1e93b7d25f60a11e            deny                 0
azurepolicy-k8sazurev2containerallowedimages-9f2b6d40e1c7a83      deny                 3
```

```bash
$ kubectl get k8sazurev2containerallowedimages \
    azurepolicy-k8sazurev2containerallowedimages-9f2b6d40e1c7a83 -o yaml
```

```yaml
apiVersion: constraints.gatekeeper.sh/v1beta1
kind: K8sAzureV2ContainerAllowedImages
metadata:
  name: azurepolicy-k8sazurev2containerallowedimages-9f2b6d40e1c7a83
  labels:
    managed-by: azure-policy-addon
spec:
  enforcementAction: deny
  match:
    excludedNamespaces:
      - kube-system
      - gatekeeper-system
      - azure-arc
      - kube-node-lease
      - kube-public
    kinds:
      - apiGroups:
          - ""
        kinds:
          - Pod
  parameters:
    allowedContainerImagesRegex: ^(crcontoso\.azurecr\.io|mcr\.microsoft\.com)/.+$
    excludedContainers: []
status:
  auditTimestamp: "2026-09-05T09:41:12Z"
  totalViolations: 3
  violations:
    - enforcementAction: deny
      kind: Pod
      message: 'Container image docker.io/library/nginx:1.27 for container web has not
        been allowed. Allowed registries: ^(crcontoso\.azurecr\.io|mcr\.microsoft\.com)/.+$'
      name: legacy-proxy-7d4b8c9f6-2wqhx
      namespace: team-alpha
```

The denial an application team sees:

```bash
$ kubectl apply -f deploy/nginx.yaml
Error from server (Forbidden): error when creating "deploy/nginx.yaml": admission
webhook "validation.gatekeeper.sh" denied the request: [azurepolicy-k8sazurev2containerallowedimages-9f2b6d40e1c7a83]
Container image docker.io/library/nginx:1.27 for container web has not been allowed.
Allowed registries: ^(crcontoso\.azurecr\.io|mcr\.microsoft\.com)/.+$
```

**Trade-off table — Azure Policy add-on vs. self-managed Gatekeeper/Kyverno:**

| | Azure Policy add-on | Self-managed Gatekeeper | Kyverno |
|---|---|---|---|
| Policy authoring | Azure Policy JSON wrapping Rego | Raw Rego | YAML (no Rego) |
| Central multi-cluster assignment | **Yes**, via management group | No — per-cluster GitOps | No — per-cluster GitOps |
| Compliance rolls up to Azure Policy / Defender for Cloud | **Yes** | No | No |
| Covers Arc-enabled clusters (on-prem, other clouds) | **Yes** | Yes | Yes |
| Mutation | `mutate` effect (preview scope varies) | Gatekeeper mutation | **Mature** |
| Add-on lifecycle | Microsoft-managed, version pinned to AKS | You own upgrades | You own upgrades |
| Latency to enforce a new rule | ~15 min (assignment pull) | Seconds (GitOps sync) | Seconds |

**Reference:** [Understand Azure Policy for Kubernetes clusters](https://learn.microsoft.com/en-us/azure/governance/policy/concepts/policy-for-kubernetes) · [OPA Gatekeeper documentation](https://open-policy-agent.github.io/gatekeeper/website/docs/)

---

## 6. Microsoft Purview — governing the *data*, not the resource

### 6.1 The distinction the exam tests

> **Azure Policy governs resources. Microsoft Purview governs data.**

Azure Policy can guarantee that a storage account is private, encrypted with a customer-managed key, in the correct region, and logging to the platform workspace. It has **no idea whether the blobs inside contain Argentine national ID numbers**. That question — *what data do we hold, where is it, who touched it, is it labelled, and may it leave?* — is Microsoft Purview's.

### 6.2 The solution families

| Purview solution | What it answers | Typical trigger |
|---|---|---|
| **Unified Catalog / Data Map** | "What data assets exist, what is their schema, where did this column come from?" — scanning, automated classification, lineage, business glossary, data products, data quality | A data platform with 40 sources and no one who can answer "where does `revenue_eur` come from?" |
| **Information Protection** | "Is this document/file labelled Confidential, and does the label follow it?" — sensitivity labels, encryption, watermarking | Labels must persist when a file leaves SharePoint |
| **Data Loss Prevention (DLP)** | "Block this email/upload because it contains 14 credit-card numbers" | Egress control on Exchange, Teams, endpoints, and cloud apps |
| **Data Lifecycle & Records Management** | "Retain for 7 years, then delete; make it immutable" | Regulatory retention (SEC 17a-4, GDPR erasure) |
| **Insider Risk Management** | "This user downloaded 4,000 files two days after resigning" | Departing-employee and IP-theft signals |
| **Communication Compliance** | "Scan internal comms for regulated-industry misconduct" | FINRA/MiFID supervision |
| **Audit (Standard / Premium)** | "Reconstruct exactly who accessed what, with longer retention" | Post-incident forensics |
| **eDiscovery** | "Legal hold, collect, review, export for this custodian" | Litigation |
| **Compliance Manager** | "Score our posture against ISO 27001 / NIST 800-53 / GDPR and tell me the next improvement action" | Preparing for an audit |

Access surface: the **Microsoft Purview portal** at `https://purview.microsoft.com`. The Azure-resource footprint for the data-map/catalog capabilities is `Microsoft.Purview/accounts`.

### 6.3 Provisioning and scanning — full sequence

```bash
$ az provider register --namespace Microsoft.Purview --wait

$ az purview account create \
    --name pv-contoso-prod \
    --resource-group rg-governance-prod \
    --location westeurope \
    --managed-resource-group-name managed-rg-pv-contoso-prod \
    --sku-name Standard \
    --sku-capacity 1 \
    --identity-type SystemAssigned \
    --public-network-access Enabled \
    --tags costCenter=CC-4471 dataClassification=internal
```

```json
{
  "friendlyName": "pv-contoso-prod",
  "id": "/subscriptions/8c1e.../resourceGroups/rg-governance-prod/providers/Microsoft.Purview/accounts/pv-contoso-prod",
  "identity": {
    "principalId": "a4d17e6b-2c93-4f18-9b05-77ea1cd3f2b6",
    "tenantId": "3f9a2b71-8d44-4e0c-a6f2-1b5c9e07d418",
    "type": "SystemAssigned"
  },
  "location": "westeurope",
  "managedResourceGroupName": "managed-rg-pv-contoso-prod",
  "managedResources": {
    "eventHubNamespace": "/subscriptions/8c1e.../providers/Microsoft.EventHub/namespaces/pv-contoso-prod",
    "storageAccount": "/subscriptions/8c1e.../providers/Microsoft.Storage/storageAccounts/scanpvcontosoprod"
  },
  "name": "pv-contoso-prod",
  "provisioningState": "Succeeded",
  "sku": { "capacity": 1, "name": "Standard" }
}
```

The scan will silently return **zero assets** until the Purview managed identity has data-plane read on the source. This is the number-one Purview onboarding failure:

```bash
$ PV_MI=$(az purview account show -n pv-contoso-prod -g rg-governance-prod \
    --query identity.principalId -o tsv)

$ az role assignment create \
    --assignee-object-id "$PV_MI" \
    --assignee-principal-type ServicePrincipal \
    --role "Storage Blob Data Reader" \
    --scope "/subscriptions/8c1e.../resourceGroups/rg-data-prod/providers/Microsoft.Storage/storageAccounts/stdatalakeprod"
```

```json
{
  "id": "/subscriptions/8c1e.../providers/Microsoft.Authorization/roleAssignments/5f2a9c31-7b40-4e88-a1d6-3c9074be2f15",
  "principalId": "a4d17e6b-2c93-4f18-9b05-77ea1cd3f2b6",
  "principalType": "ServicePrincipal",
  "roleDefinitionId": ".../roleDefinitions/2a2b9908-6ea1-4ae2-8e65-a410df84e7d1",
  "scope": ".../storageAccounts/stdatalakeprod"
}
```

Now close the loop with Azure Policy — enforce that every Purview account itself is governed:

```bash
$ az policy assignment create \
    --name purview-must-use-private-endpoint \
    --scope "/providers/Microsoft.Management/managementGroups/mg-landingzones" \
    --policy "/providers/Microsoft.Authorization/policyDefinitions/27ea8f46-dc82-4331-99b9-nnnnnnnnnnnn" \
    --params '{"effect":{"value":"Audit"}}' \
    --description "Purview scans traverse data; the control plane must not be internet-reachable."
```

> **The architectural pattern.** Purview *discovers and classifies*; Azure Policy *enforces the resource posture around it*. A mature estate feeds Purview classification results into a tagging strategy (`dataClassification=restricted`), and then writes Azure Policy definitions keyed on that tag — deny public network access on any resource tagged `restricted`, require CMK, require private endpoints. That is the join between the two objectives, and it is the answer to "how do the tools work together?"

**References:** [Microsoft Purview product overview](https://learn.microsoft.com/en-us/purview/purview) · [Microsoft Purview portal](https://purview.microsoft.com) · [Compliance Manager](https://learn.microsoft.com/en-us/purview/compliance-manager)

---

## 7. Proving compliance — four sources, four different questions

Students conflate these constantly. They answer **different questions about different subjects**:

| Tool | Subject | Question answered | Who produces the evidence |
|---|---|---|---|
| **Service Trust Portal** (`servicetrust.microsoft.com`) | **Microsoft's** cloud | "Is Azure itself ISO 27001 / SOC 2 / PCI DSS / FedRAMP certified — show me the auditor's report" | Third-party auditors, published by Microsoft |
| **Microsoft Trust Center** (`microsoft.com/trust-center`) | Microsoft's cloud | "What are Microsoft's privacy, security and compliance commitments and where are my data stored?" | Microsoft |
| **Compliance Manager** (in the Purview portal) | **Your** tenant + shared responsibility | "What is my compliance *score* against GDPR/ISO/NIST, and what is the next improvement action I own?" | You + Microsoft-managed controls |
| **Azure Policy compliance / Defender for Cloud regulatory compliance dashboard** | **Your** Azure resources | "Which of my 4,118 resources currently violate which control, right now" | Continuous machine evaluation |

Key facts about the **Service Trust Portal**:

- It hosts **audit reports** (SOC 1 Type 2, SOC 2 Type 2, SOC 3, ISO 27001/27017/27018/27701, PCI DSS AoC), **penetration test summaries**, **Data Protection Resources** (DPIA support, GDPR documentation), FAQs and white papers, and Azure Security & Compliance Blueprints.
- It requires signing in with a **Microsoft cloud services account**; the substantive reports are **NDA-protected** and are not anonymously downloadable.
- **My Library** lets you pin documents and receive notification when they are updated — this is what you configure so your GRC team is alerted when a new SOC 2 lands.
- It is Microsoft *reporting on itself*. It contains **nothing about your configuration**. If an auditor asks "prove your storage accounts are encrypted," STP is the wrong artefact; Azure Policy compliance export is the right one.

**Shared responsibility, applied:** the auditor's question splits in two. *"Is the datacentre physically secure?"* → Service Trust Portal, Microsoft's control. *"Is public blob access disabled on your 412 storage accounts?"* → Azure Policy compliance data, your control. Handing over an STP report for the second question is the classic — and expensive — audit failure.

**References:** [Microsoft Service Trust Portal](https://servicetrust.microsoft.com/) · [Microsoft Trust Center](https://www.microsoft.com/trust-center) · [Compliance offerings home](https://learn.microsoft.com/en-us/compliance/regulatory/offering-home) · [Defender for Cloud regulatory compliance dashboard](https://learn.microsoft.com/en-us/azure/defender-for-cloud/regulatory-compliance-dashboard)

---

## 8. Verification and failure diagnosis

### 8.1 The verification ladder — run these in order

```bash
# 0. Confirm the assignment exists at the scope you think it does.
$ az policy assignment list \
    --scope "/providers/Microsoft.Management/managementGroups/mg-landingzones" \
    --query "[].{name:name, effectiveScope:scope, enforcement:enforcementMode, def:policyDefinitionId}" \
    -o table
```

```
Name              EffectiveScope                                                     Enforcement   Def
----------------  -----------------------------------------------------------------  ------------  ---------------------------------------------------------------------
contoso-baseline  /providers/Microsoft.Management/managementGroups/mg-landingzones   Default       /providers/Microsoft.Management/.../policySetDefinitions/contoso-platform-baseline
alz-deny-pip      /providers/Microsoft.Management/managementGroups/mg-landingzones   DoNotEnforce  /providers/Microsoft.Authorization/policyDefinitions/83a86a26-fd1f-...
```

```bash
# 1. Force an evaluation instead of waiting 24 hours. This blocks; scope-dependent runtime.
$ az policy state trigger-scan --resource-group rg-app-a-prod
```

```
Policy scan triggered for resource group 'rg-app-a-prod'. Waiting for completion...
Policy scan completed.
```

```bash
# 2. Roll-up: how bad is it?
$ az policy state summarize \
    --management-group mg-landingzones \
    --query "value[0].results" -o json
```

```json
{
  "nonCompliantPolicies": 7,
  "nonCompliantResources": 412,
  "resourceDetails": [
    { "complianceState": "NonCompliant", "count": 412 },
    { "complianceState": "Compliant", "count": 8931 },
    { "complianceState": "Exempt", "count": 14 },
    { "complianceState": "Conflict", "count": 0 }
  ]
}
```

```bash
# 3. Drill in: which resources, under which definition reference?
$ az policy state list \
    --management-group mg-landingzones \
    --filter "complianceState eq 'NonCompliant'" \
    --apply "groupby((policyDefinitionReferenceId, policyDefinitionName), aggregate(\$count as total))" \
    -o table
```

```
PolicyDefinitionReferenceId    PolicyDefinitionName                  Total
-----------------------------  ------------------------------------  -------
denyStoragePublicBlobAccess    deny-storage-public-blob-access        31
keyVaultDiagnostics            dine-keyvault-diagnostics-to-law       288
inheritCostCenterTag           modify-inherit-tag-from-rg             81
allowedLocations               e56962a6-4747-49cd-b67b-bf8b01975c4c   12
```

```bash
# 4. The actual resource IDs for one finding.
$ az policy state list \
    --management-group mg-landingzones \
    --filter "complianceState eq 'NonCompliant' and policyDefinitionReferenceId eq 'denyStoragePublicBlobAccess'" \
    --query "[].{resource:resourceId, sub:subscriptionId, ts:timestamp}" \
    -o tsv | head -5
```

```
/subscriptions/8c1e.../resourceGroups/rg-app-a-prod/providers/Microsoft.Storage/storageAccounts/stappalogs001   8c1e...  2026-09-05T06:12:44Z
/subscriptions/8c1e.../resourceGroups/rg-app-a-prod/providers/Microsoft.Storage/storageAccounts/stappaassets     8c1e...  2026-09-05T06:12:44Z
/subscriptions/b209.../resourceGroups/rg-web-prod/providers/Microsoft.Storage/storageAccounts/stwebstatic01      b209...  2026-09-05T06:12:44Z
```

```bash
# 5. Remediate the pre-existing estate (DINE/Modify do NOT retro-fix on their own).
$ az policy remediation create \
    --name remediate-kv-diagnostics-2026-09 \
    --management-group mg-landingzones \
    --policy-assignment contoso-baseline \
    --definition-reference-id keyVaultDiagnostics \
    --resource-discovery-mode ExistingNonCompliant \
    --parallel-deployments 10 \
    --resource-count 500
```

```json
{
  "deploymentStatus": {
    "failedDeployments": 0,
    "successfulDeployments": 0,
    "totalDeployments": 288
  },
  "provisioningState": "Accepted",
  "resourceDiscoveryMode": "ExistingNonCompliant"
}
```

```bash
$ az policy remediation show \
    --name remediate-kv-diagnostics-2026-09 \
    --management-group mg-landingzones \
    --query "{state:provisioningState, status:deploymentStatus}" -o json
```

```json
{
  "state": "Succeeded",
  "status": {
    "failedDeployments": 4,
    "successfulDeployments": 284,
    "totalDeployments": 288
  }
}
```

```bash
# 6. Inspect the four failures.
$ az policy remediation deployment list \
    --name remediate-kv-diagnostics-2026-09 \
    --management-group mg-landingzones \
    --query "[?status=='Failed'].{res:remediatedResourceId, err:error.message}" -o json
```

```json
[
  {
    "err": "The client 'a4d17e6b-...' with object id 'a4d17e6b-...' does not have authorization to perform action 'Microsoft.Insights/diagnosticSettings/write' over scope '/subscriptions/b209.../providers/Microsoft.KeyVault/vaults/kv-web-prod'.",
    "res": "/subscriptions/b209.../resourceGroups/rg-web-prod/providers/Microsoft.KeyVault/vaults/kv-web-prod"
  }
]
```

### 8.2 Failure catalogue — Azure Policy

| Symptom | Root cause | Diagnosis | Fix |
|---|---|---|---|
| New assignment appears to do nothing | Assignments take up to **30 min** to become effective | Check `properties.metadata.createdOn` on the assignment; wait | Wait, then `az policy state trigger-scan` |
| Everything reports **"Not started"** | No evaluation cycle has run yet at this scope | `az policy state list --filter "complianceState eq 'NotStarted'"` | Trigger a scan; verify the resource provider is registered |
| `Deny` never fires but the resource is reported non-compliant | The alias in `if` matches the *stored* resource but not the *request payload*, or the property is only settable post-create | `az provider show --namespace Microsoft.X --expand "resourceTypes/aliases"` and confirm the alias exists at the API version in use | Combine `Deny` (on the settable path) with `DeployIfNotExists`/`Modify` for the rest |
| DINE reports non-compliant forever, remediation "succeeds" | `existenceCondition` tests a property with a different casing/format than what is stored (`workspaceId` casing, trailing slash) | Fetch the deployed related resource: `az monitor diagnostic-settings show ...` and diff every field in `existenceCondition` | Normalise; compare against the resource ID exactly as ARM returns it |
| Remediation fails `AuthorizationFailed` | The assignment MI lacks a role listed in `roleDefinitionIds`, or the role was granted at a scope narrower than the resource | `az role assignment list --assignee <principalId> --all -o table` | Assign the role at the assignment scope (or above); wait for Entra propagation |
| Remediation fails `PrincipalNotFound` | Role assignment created in the same deployment as the identity, before replication | Re-run the deployment | Set `principalType: 'ServicePrincipal'`; add a retry |
| Array-valued condition matches unexpectedly | `[*]` aliases are **existential** by default: `field: "…/subnets[*].name", equals: "x"` is true if *any* element matches | Rewrite with the `count` expression and `where` | Use `count { value, name, where }` with an explicit `equals 0` / `greaterOrEquals` |
| A tag policy flags hundreds of child resources | `mode: All` on a tag policy pulls in types that cannot carry tags | Inspect `resourceType` distribution of the findings | Change `mode` to `Indexed` |
| Compliance state is **`Conflict`** | Two assignments apply mutually exclusive `Append`/`Modify` operations to the same field | `az policy state list --filter "complianceState eq 'Conflict'"` | Consolidate into one initiative; remove the duplicate |
| A team needs a legitimate exception | — | — | **Exemption, not `notScopes`**: `az policy exemption create --exemption-category Waiver --expires-on 2026-12-31 --description "CHG-8841"` |

Reading a deny error properly — this is what the application team pastes into your channel:

```bash
$ az storage account create -n stappapublic -g rg-app-a-prod -l westeurope --allow-blob-public-access true
```

```
(RequestDisallowedByPolicy) Resource 'stappapublic' was disallowed by policy. Reasons: 'Storage accounts must set allowBlobPublicAccess=false. Use a SAS token or Entra ID auth for external readers.'. See error details for policy resource IDs.
Code: RequestDisallowedByPolicy
Message: Resource 'stappapublic' was disallowed by policy. ...
Additional Information:
Type: PolicyViolation
Info: {
    "evaluationDetails": {
        "evaluatedExpressions": [
            {
                "expression": "type",
                "expressionKind": "Field",
                "expressionValue": "Microsoft.Storage/storageAccounts",
                "operator": "Equals",
                "result": "True",
                "targetValue": "Microsoft.Storage/storageAccounts"
            },
            {
                "expression": "Microsoft.Storage/storageAccounts/allowBlobPublicAccess",
                "expressionKind": "Field",
                "expressionValue": "True",
                "operator": "NotEquals",
                "result": "True",
                "targetValue": "false"
            }
        ]
    },
    "policyAssignmentDisplayName": "Contoso platform baseline",
    "policyAssignmentId": "/providers/Microsoft.Management/managementGroups/mg-landingzones/providers/Microsoft.Authorization/policyAssignments/contoso-baseline",
    "policyAssignmentScope": "/providers/Microsoft.Management/managementGroups/mg-landingzones",
    "policyDefinitionDisplayName": "Storage accounts must disable anonymous blob public access",
    "policyDefinitionId": "/providers/Microsoft.Management/managementGroups/mg-contoso/providers/Microsoft.Authorization/policyDefinitions/deny-storage-public-blob-access",
    "policyDefinitionReferenceId": "denyStoragePublicBlobAccess",
    "policySetDefinitionId": ".../policySetDefinitions/contoso-platform-baseline"
}
```

`evaluatedExpressions` is the whole diagnosis: it tells you exactly which clause matched and with what value. `policyAssignmentScope` tells you which management group to talk to. If `nonComplianceMessages` had not been configured, the `Reasons:` field would be generic and the team would have opened a ticket instead of self-serving.

### 8.3 Failure catalogue — resource locks

```bash
$ az group delete --name rg-connectivity-prod --yes
```

```
(ScopeLocked) The scope '/subscriptions/8c1e.../resourceGroups/rg-connectivity-prod' cannot perform delete operation because following scope(s) are locked: '/subscriptions/8c1e.../resourceGroups/rg-connectivity-prod/providers/Microsoft.Network/virtualNetworks/vnet-hub-weu'. Please remove the lock and try again.
Code: ScopeLocked
```

Find every lock that applies, including inherited ones:

```bash
$ az lock list \
    --resource-group rg-connectivity-prod \
    --include-parents \
    --query "[].{name:name, level:level, notes:notes, scope:id}" -o table
```

```
Name                      Level         Notes                                                                       Scope
------------------------  ------------  --------------------------------------------------------------------------  ------------------------------------------------------------------
lock-sub-prod-no-delete   CanNotDelete  Production subscription. Deletion requires CAB approval.                     /subscriptions/8c1e.../providers/Microsoft.Authorization/locks/...
lock-hub-vnet-no-delete   CanNotDelete  Shared hub. Deleting it severs every spoke peering. CAB CHG-#### required.   /subscriptions/8c1e.../virtualNetworks/vnet-hub-weu/providers/...
```

Tenant-wide lock inventory via Resource Graph — the query to keep in your runbook:

```bash
$ az graph query -q "
resourcecontainers
| where type == 'microsoft.resources/subscriptions'
| project subscriptionId, subName = name
| join kind=leftouter (
    resources
    | where type == 'microsoft.authorization/locks'
    | project subscriptionId, lockName = name, level = tostring(properties.level),
              notes = tostring(properties.notes), lockScope = id
  ) on subscriptionId
| project subName, lockName, level, notes
| order by subName asc
" --first 1000 -o table
```

```
SubName              LockName                   Level         Notes
-------------------  -------------------------  ------------  ----------------------------------------------
sub-conn-prod        lock-sub-prod-no-delete    CanNotDelete  Production subscription. CAB approval required.
sub-conn-prod        lock-hub-vnet-no-delete    CanNotDelete  Shared hub. Severs spoke peerings.
sub-mgmt-prod        lock-law-platform          CanNotDelete  Platform Log Analytics. 2y retention, audit evidence.
sub-app-a-prod
sub-web-prod         lock-sqlmi-readonly        ReadOnly      Decommissioned 2026-08-30, retain until 2027-02.
```

| Symptom | Root cause | Fix |
|---|---|---|
| `ScopeLocked` on delete of an RG | An inherited or child lock; the message names the *locked* scope, which may not be the scope you targeted | `az lock list --include-parents`; remove or escalate |
| Portal blob browser shows "Error listing keys" on a locked account | `ReadOnly` blocks `listKeys` (a POST) | Switch to `CanNotDelete`, or use Entra ID data-plane auth (`Storage Blob Data Reader`) instead of keys |
| VM cannot start | `ReadOnly` blocks `.../start/action` | Switch to `CanNotDelete` |
| App Service deployment fails after a lock is added | `ReadOnly` blocks `publishxml` | Switch to `CanNotDelete` |
| A lock "disappeared" | Any Owner can delete it; locks provide no approval gate | Audit `Microsoft.Authorization/locks/delete` in the Activity Log; move to deployment-stack `denySettings` or `DenyAction` policy for durable protection |
| Terraform plan wants to replace a locked resource, apply fails | Correct behaviour; the lock is doing its job | Remove the lock under change control, apply, re-create the lock — or refactor so the change is in-place |

Auditing lock removal — the Activity Log query you should have alerting on:

```bash
$ az monitor activity-log list \
    --offset 30d \
    --query "[?contains(operationName.value, 'Microsoft.Authorization/locks/delete')].{
        when: eventTimestamp,
        who: caller,
        what: resourceId,
        status: status.value }" \
    -o table
```

```
When                          Who                        What                                                             Status
----------------------------  -------------------------  ---------------------------------------------------------------  ---------
2026-08-28T14:07:33.118Z      j.reyes@contoso.com        /subscriptions/8c1e.../locks/lock-law-platform                    Succeeded
```

### 8.4 CI gate — catching violations before they reach ARM

`.github/workflows/governance-gate.yml`

```yaml
name: governance-gate

on:
  pull_request:
    paths:
      - 'infra/**'
      - 'policies/**'
  workflow_dispatch:

permissions:
  id-token: write        # OIDC federated credential — no client secret in the repo
  contents: read
  pull-requests: write

env:
  AZURE_MG: mg-landingzones
  TARGET_RG: rg-app-a-prod

jobs:
  policy-what-if:
    name: Deny-policy pre-flight
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Azure login (OIDC)
        uses: azure/login@v2
        with:
          client-id: ${{ secrets.AZURE_CLIENT_ID }}
          tenant-id: ${{ secrets.AZURE_TENANT_ID }}
          subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}

      - name: Validate Bicep against live policy assignments
        id: validate
        run: |
          set -euo pipefail
          az deployment group validate \
            --resource-group "${TARGET_RG}" \
            --template-file infra/app/main.bicep \
            --parameters infra/app/prod.bicepparam \
            --output json > validate.json
          echo "validation passed"

      - name: What-if (shows policy denials without deploying)
        run: |
          set -euo pipefail
          az deployment group what-if \
            --resource-group "${TARGET_RG}" \
            --template-file infra/app/main.bicep \
            --parameters infra/app/prod.bicepparam \
            --result-format FullResourcePayload \
            --no-pretty-print > whatif.json

      - name: Fail the PR on any RequestDisallowedByPolicy
        run: |
          set -euo pipefail
          if grep -q 'RequestDisallowedByPolicy' validate.json whatif.json; then
            echo "::error::Deployment violates an Azure Policy Deny assignment."
            python3 - <<'PY'
          import json, pathlib, sys
          for f in ("validate.json", "whatif.json"):
              raw = pathlib.Path(f).read_text()
              if "RequestDisallowedByPolicy" not in raw:
                  continue
              print(f"--- {f} ---")
              print(raw[:4000])
          sys.exit(1)
          PY
          fi

  compliance-drift:
    name: Post-merge compliance drift
    if: github.event_name == 'workflow_dispatch'
    runs-on: ubuntu-latest
    steps:
      - name: Azure login (OIDC)
        uses: azure/login@v2
        with:
          client-id: ${{ secrets.AZURE_CLIENT_ID }}
          tenant-id: ${{ secrets.AZURE_TENANT_ID }}
          subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}

      - name: Trigger evaluation and export non-compliant resources
        run: |
          set -euo pipefail
          az policy state trigger-scan --resource-group "${TARGET_RG}"
          az policy state list \
            --management-group "${AZURE_MG}" \
            --filter "complianceState eq 'NonCompliant'" \
            --query "[].{resource:resourceId, policy:policyDefinitionName, ts:timestamp}" \
            -o json > compliance-drift.json
          COUNT=$(jq 'length' compliance-drift.json)
          echo "non-compliant resources: ${COUNT}"
          echo "NONCOMPLIANT=${COUNT}" >> "$GITHUB_ENV"

      - name: Upload evidence artefact
        uses: actions/upload-artifact@v4
        with:
          name: compliance-drift-${{ github.run_id }}
          path: compliance-drift.json
          retention-days: 400
```

The 400-day artefact retention is deliberate: that JSON export is the **point-in-time compliance evidence** an ISO 27001 surveillance audit asks for, and it must outlive the annual cycle.

### 8.5 Scale limits to design against

Governance designs fail at scale in predictable ways. The published service limits govern how many definitions and assignments a scope can hold — check the current numbers before designing a hierarchy, and design well under them:

```bash
$ az policy definition list --management-group mg-contoso --query "length(@)"
187

$ az policy assignment list --scope "/providers/Microsoft.Management/managementGroups/mg-contoso" --query "length(@)"
23
```

Practical guidance that holds regardless of the exact ceiling:

- **Assign initiatives, not individual definitions.** One initiative assignment carries hundreds of rules and consumes one assignment slot.
- **Custom definitions live at the intermediate root management group**, so every child scope can reference them; assignments live lower.
- **Prefer built-ins.** They do not count against your custom-definition budget and are maintained for you.
- Keep the management group tree **shallow and stable** — moving subscriptions between management groups re-evaluates everything and generates large compliance churn.

**Reference:** [Azure subscription and service limits, quotas, and constraints](https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/azure-subscription-service-limits)

---

## 9. Self-check

1. A subscription Owner deploys a VM to `brazilsouth`. An *Allowed locations* policy with effect `Deny` is assigned at the parent management group. What happens, and why can the Owner not override it?
2. You apply a `ReadOnly` lock to a storage account. A developer reports that the portal can no longer browse blobs. Explain the mechanism.
3. A `DeployIfNotExists` assignment shows 288 non-compliant Key Vaults. You wait 48 hours. The number does not change. What single action is missing?
4. An auditor asks for evidence that (a) Azure datacentres hold ISO 27001 certification and (b) your production storage accounts have public access disabled. Name the tool for each.
5. What is the operational difference between adding a scope to an assignment's `notScopes` and creating a policy exemption for a resource in that scope?
6. Your organisation needs *"nobody, including subscription Owners, may delete the hub VNet."* Why is a `CanNotDelete` lock an incomplete answer, and what closes the gap?
7. Microsoft Purview scans a data lake and finds no assets, though the account provisioned successfully. What is the most likely cause?

<details>
<summary>Answers</summary>

1. The request is rejected at ARM with `RequestDisallowedByPolicy` before the resource provider sees it. Azure Policy inherits downward and has **no allow effect** — a child scope cannot relax a parent's `Deny`. The Owner's RBAC permission is irrelevant; RBAC and Policy are independent gates, and both must pass.
2. `ReadOnly` blocks `POST` in addition to write and delete. The portal's blob browser calls `Microsoft.Storage/storageAccounts/listKeys/action`, which is a `POST`. Use `CanNotDelete`, or switch the browser to Entra ID auth via `Storage Blob Data Reader`.
3. Create a **remediation task** (`az policy remediation create --resource-discovery-mode ExistingNonCompliant`). DINE and Modify act on create/update requests; pre-existing resources are only fixed by an explicit remediation task, which additionally requires the assignment's managed identity to hold every role in `roleDefinitionIds`.
4. (a) **Service Trust Portal** — Microsoft's third-party audit reports about its own cloud. (b) **Azure Policy compliance data** (or the Defender for Cloud regulatory compliance dashboard) — continuous evaluation of *your* resources. Compliance Manager scores the shared-responsibility posture but is not the per-resource evidence.
5. `notScopes` permanently and silently removes a whole sub-scope from evaluation, with no record of why. An **exemption** targets specific resources, carries a category (`Waiver` | `Mitigated`), a description, and an `expiresOn` date, and surfaces the resource as `Exempt` rather than hiding it — so it is auditable and self-expiring.
6. Any Owner or User Access Administrator holds `Microsoft.Authorization/locks/delete` and can remove the lock, then delete the VNet, with no approval gate. Close it with a **deployment stack** using `denySettings: denyWriteAndDelete` (materialised as a deny assignment, which is not removable by role holders) and/or a `DenyAction` policy assigned at the management group, plus an Activity Log alert on `Microsoft.Authorization/locks/delete`.
7. The Purview account's managed identity lacks data-plane read on the source — typically `Storage Blob Data Reader` on the storage account. Control-plane provisioning succeeds independently of data-plane access, so the scan completes with zero assets rather than failing.

</details>

---

## 10. References

**Exam**
- AZ-900 study guide — https://learn.microsoft.com/en-us/credentials/certifications/resources/study-guides/az-900

**Azure Policy**
- Azure Policy overview — https://learn.microsoft.com/en-us/azure/governance/policy/overview
- Understand Azure Policy effects — https://learn.microsoft.com/en-us/azure/governance/policy/concepts/effects
- Azure Policy definition structure — https://learn.microsoft.com/en-us/azure/governance/policy/concepts/definition-structure
- Azure Policy assignment structure — https://learn.microsoft.com/en-us/azure/governance/policy/concepts/assignment-structure
- Azure Policy exemption structure — https://learn.microsoft.com/en-us/azure/governance/policy/concepts/exemption-structure
- Understand scope in Azure Policy — https://learn.microsoft.com/en-us/azure/governance/policy/concepts/scope
- Get compliance data — https://learn.microsoft.com/en-us/azure/governance/policy/how-to/get-compliance-data
- Determine causes of non-compliance — https://learn.microsoft.com/en-us/azure/governance/policy/how-to/determine-non-compliance
- Remediate non-compliant resources — https://learn.microsoft.com/en-us/azure/governance/policy/how-to/remediate-resources
- Azure Policy built-in definitions — https://learn.microsoft.com/en-us/azure/governance/policy/samples/built-in-policies
- Azure Policy for Kubernetes — https://learn.microsoft.com/en-us/azure/governance/policy/concepts/policy-for-kubernetes
- Azure Machine Configuration (in-guest policy) — https://learn.microsoft.com/en-us/azure/governance/machine-configuration/overview
- `az policy` CLI reference — https://learn.microsoft.com/en-us/cli/azure/policy

**Scopes, locks, and lifecycle**
- Management groups overview — https://learn.microsoft.com/en-us/azure/governance/management-groups/overview
- Lock resources to prevent unexpected changes — https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/lock-resources
- Deployment stacks — https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/deployment-stacks
- Template specs — https://learn.microsoft.com/en-us/azure/azure-resource-manager/templates/template-specs
- Deny assignments — https://learn.microsoft.com/en-us/azure/role-based-access-control/deny-assignments
- Azure Blueprints overview (deprecation notice; retirement 11 July 2026) — https://learn.microsoft.com/en-us/azure/governance/blueprints/overview
- Azure subscription and service limits — https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/azure-subscription-service-limits
- Azure landing zone design areas — https://learn.microsoft.com/en-us/azure/cloud-adoption-framework/ready/landing-zone/

**Microsoft Purview**
- Microsoft Purview product overview — https://learn.microsoft.com/en-us/purview/purview
- Microsoft Purview portal — https://purview.microsoft.com
- Microsoft Purview Compliance Manager — https://learn.microsoft.com/en-us/purview/compliance-manager

**Compliance evidence**
- Microsoft Service Trust Portal — https://servicetrust.microsoft.com/
- Microsoft Trust Center — https://www.microsoft.com/trust-center
- Microsoft compliance offerings — https://learn.microsoft.com/en-us/compliance/regulatory/offering-home
- Defender for Cloud regulatory compliance dashboard — https://learn.microsoft.com/en-us/azure/defender-for-cloud/regulatory-compliance-dashboard

**CNCF / upstream**
- OPA Gatekeeper documentation — https://open-policy-agent.github.io/gatekeeper/website/docs/