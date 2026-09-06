# AZ-900 — Topic 3.2: Governance and Compliance Features and Tools in Azure

## Guided Exercises (Production-Grade Lab)

**Exam objective (AZ-900, syllabus version 2026-07-20), weight 8.33%**
- Describe the purpose of Microsoft Purview governance solutions
- Describe the purpose of Azure Policy
- Describe the purpose of resource locks

Source of record: <https://learn.microsoft.com/en-us/credentials/certifications/resources/study-guides/az-900>

---

## 0. Lab Preconditions and Cost Discipline

These exercises run against a real subscription. Everything in Exercises 1–7 uses free or near-free control-plane resources (locks, policy definitions, assignments, remediation tasks, and one Standard_LRS storage account). **Exercise 8 (Microsoft Purview) has a real hourly cost and is presented with a zero-cost read-only path.**

**Required tooling**

```bash
az version
```

Expected output (versions will differ; `azure-cli` must be ≥ 2.61):

```json
{
  "azure-cli": "2.64.0",
  "azure-cli-core": "2.64.0",
  "azure-cli-telemetry": "1.1.0",
  "extensions": {}
}
```

**Required permissions.** Locks and role assignments require `Microsoft.Authorization/locks/*` and `Microsoft.Authorization/roleAssignments/write`. The built-in **Contributor** role explicitly excludes both. You need **Owner**, or **Contributor + User Access Administrator**, at the subscription scope.

Reference: <https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles>

### Steps

1. Sign in and pin the working subscription so nothing leaks into a neighbouring one.

```bash
az login --only-show-errors
az account set --subscription "<your-subscription-name-or-id>"
az account show --query "{name:name, id:id, tenantId:tenantId}" -o table
```

2. Export the identifiers you will reuse. Everything below assumes these variables exist in the shell.

```bash
export LOC="eastus"
export RG="rg-gov-lab"
export SUB=$(az account show --query id -o tsv)
export SCOPE_SUB="/subscriptions/${SUB}"
export SCOPE_RG="/subscriptions/${SUB}/resourceGroups/${RG}"
export SA="stgovlab$RANDOM"
echo "SUB=$SUB  SA=$SA"
```

3. Register the resource providers the lab depends on. `Microsoft.PolicyInsights` is mandatory for remediation tasks and is **not** registered by default in every subscription.

```bash
az provider register --namespace Microsoft.PolicyInsights
az provider register --namespace Microsoft.Storage
az provider show --namespace Microsoft.PolicyInsights --query registrationState -o tsv
```

Expected output (may take 1–2 minutes to move off `Registering`):

```
Registered
```

4. Create the lab resource group with a tag you will later propagate with a `Modify` policy.

```bash
az group create \
  --name "$RG" \
  --location "$LOC" \
  --tags costCenter=CC-4711 env=lab owner=platform-team \
  --query "{name:name, location:location, tags:tags}" -o json
```

Expected output:

```json
{
  "location": "eastus",
  "name": "rg-gov-lab",
  "tags": {
    "costCenter": "CC-4711",
    "env": "lab",
    "owner": "platform-team"
  }
}
```

> **Check your understanding**
>
> **Q0.1** — You are a subscription **Contributor**. You try to place a `CanNotDelete` lock on a resource group and receive `AuthorizationFailed`. Which specific data action or permission is missing, and which two built-in roles grant it?
>
> **Q0.2** — Why does a governance lab need `Microsoft.PolicyInsights` registered, when policy *evaluation* works without it?
>
> **Q0.3** — Tags are covered under cost management (objective 3.1), yet they appear in a governance lab. Give the governance reason a tag matters, distinct from the billing reason.

---

## 1. The Scope Hierarchy: Where Governance Attaches

Every governance control in Azure — RBAC, Policy, locks, deny assignments, budgets — attaches to one of four scopes and flows **downward** by inheritance:

```
Management group  →  Subscription  →  Resource group  →  Resource
```

Understanding the hierarchy is the prerequisite for every other exercise: a policy assigned at a management group is evaluated against every resource in every subscription underneath it, and a lock on a resource group protects every resource inside it.

Reference: <https://learn.microsoft.com/en-us/azure/governance/management-groups/overview>

### Steps

1. Inspect the management group hierarchy of your tenant.

```bash
az account management-group list --query "[].{name:name, displayName:displayName}" -o table
```

Expected output on a tenant that has never used management groups:

```
Name                                  DisplayName
------------------------------------  ------------------
72f988bf-86f1-41af-91ab-2d7cd011db47  Tenant Root Group
```

2. Create a two-level hierarchy that mirrors a real landing zone: a top-level "platform" group with a "sandbox" child.

```bash
az account management-group create --name "mg-contoso-platform" --display-name "Contoso Platform"
az account management-group create --name "mg-contoso-sandbox"  --display-name "Contoso Sandbox" \
  --parent "mg-contoso-platform"
```

3. Render the resulting tree.

```bash
az account management-group show --name "mg-contoso-platform" --expand --recurse \
  --query "{mg:displayName, children:children[].{type:type, name:displayName}}" -o json
```

Expected output:

```json
{
  "children": [
    {
      "name": "Contoso Sandbox",
      "type": "Microsoft.Management/managementGroups"
    }
  ],
  "mg": "Contoso Platform"
}
```

4. Record the scope strings for all four levels. These are the exact `--scope` values that Policy, RBAC and locks consume:

```bash
echo "MG   : /providers/Microsoft.Management/managementGroups/mg-contoso-platform"
echo "SUB  : ${SCOPE_SUB}"
echo "RG   : ${SCOPE_RG}"
echo "RES  : ${SCOPE_RG}/providers/Microsoft.Storage/storageAccounts/${SA}"
```

> **Check your understanding**
>
> **Q1.1** — A subscription can have exactly one parent management group. How many management groups can a *management group* have as a parent, and what is the maximum depth of the hierarchy below the root?
>
> **Q1.2** — A policy is assigned at `mg-contoso-platform` and a *different* policy at the subscription inside `mg-contoso-sandbox`. A resource violates both. How many non-compliance records does it generate, and does one assignment override the other?
>
> **Q1.3** — Why can a global administrator not see the Tenant Root Group in the portal by default, and what action makes it visible?

---

## 2. Resource Locks — Protecting Against Accidental Change

A resource lock is a control-plane guard that applies to **every principal**, regardless of their RBAC role. RBAC answers *"who may act"*; a lock answers *"may this action happen at all"*.

Two lock types exist:

| Lock type | ARM operation blocked | Portal label | Typical use |
|---|---|---|---|
| `CanNotDelete` | `DELETE` | **Delete** | Production data stores, hub networking, jump hosts |
| `ReadOnly` | `DELETE`, `PUT`, `PATCH`, and any `POST` that mutates | **Read-only** | Frozen change windows, decommission holds, audit periods |

Reference: <https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/lock-resources>

### Steps

1. Create the storage account that will act as the protected resource.

```bash
az storage account create \
  --name "$SA" \
  --resource-group "$RG" \
  --location "$LOC" \
  --sku Standard_LRS \
  --kind StorageV2 \
  --min-tls-version TLS1_2 \
  --allow-blob-public-access false \
  --query "{name:name, publicAccess:allowBlobPublicAccess}" -o json
```

Expected output:

```json
{
  "name": "stgovlab24817",
  "publicAccess": false
}
```

2. Apply a `CanNotDelete` lock **on the resource group**, so inheritance is visible.

```bash
az lock create \
  --name "lock-no-delete-rg" \
  --lock-type CanNotDelete \
  --resource-group "$RG" \
  --notes "Change freeze CHG0041299 — remove only via CAB approval"
```

3. Prove that inheritance reaches the child resource, even though no lock was placed on it.

```bash
az lock list --resource-group "$RG" --query "[].{name:name, level:level, scope:id}" -o table
```

Expected output:

```
Name               Level         Scope
-----------------  ------------  --------------------------------------------------------------
lock-no-delete-rg  CanNotDelete  /subscriptions/xxxx/resourceGroups/rg-gov-lab/providers/Micro...
```

4. Attempt the delete that the lock is designed to stop.

```bash
az storage account delete --name "$SA" --resource-group "$RG" --yes
```

Expected output (the request never reaches the resource provider — ARM rejects it):

```
(ScopeLocked) The scope '/subscriptions/xxxx/resourceGroups/rg-gov-lab/providers/
Microsoft.Storage/storageAccounts/stgovlab24817' cannot perform delete operation
because following scope(s) are locked: '/subscriptions/xxxx/resourceGroups/rg-gov-lab'.
Please remove the lock and try again.
Code: ScopeLocked
```

5. Prove that `CanNotDelete` does **not** block modification. Change a property on the "protected" account:

```bash
az storage account update --name "$SA" --resource-group "$RG" \
  --tags env=lab purpose=lock-demo \
  --query "tags" -o json
```

Expected output — the write succeeds:

```json
{
  "env": "lab",
  "purpose": "lock-demo"
}
```

6. Escalate to `ReadOnly` at the resource scope and observe the classic production trap: key listing is a `POST` operation and is therefore blocked.

```bash
az lock delete --name "lock-no-delete-rg" --resource-group "$RG"

az lock create \
  --name "lock-readonly-sa" \
  --lock-type ReadOnly \
  --resource-group "$RG" \
  --resource-name "$SA" \
  --resource-type "Microsoft.Storage/storageAccounts" \
  --namespace "Microsoft.Storage"

az storage account keys list --account-name "$SA" --resource-group "$RG" -o table
```

Expected output:

```
(ScopeLocked) The scope '/subscriptions/xxxx/resourceGroups/rg-gov-lab/providers/
Microsoft.Storage/storageAccounts/stgovlab24817' cannot perform write operation
because following scope(s) are locked: '.../storageAccounts/stgovlab24817'.
```

7. Confirm the lock is a **control-plane** boundary only. Create a container using an Entra ID (data-plane) credential and note that the lock is irrelevant to it:

```bash
az role assignment create \
  --assignee "$(az ad signed-in-user show --query id -o tsv)" \
  --role "Storage Blob Data Contributor" \
  --scope "${SCOPE_RG}/providers/Microsoft.Storage/storageAccounts/${SA}" \
  --only-show-errors

# wait ~30s for RBAC propagation
az storage container create --name "demo" --account-name "$SA" --auth-mode login
```

Expected output:

```json
{
  "created": true
}
```

8. Remove the lock so later exercises are not blocked.

```bash
az lock delete --name "lock-readonly-sa" --resource-group "$RG" \
  --resource-name "$SA" --resource-type "Microsoft.Storage/storageAccounts" \
  --namespace "Microsoft.Storage"
```

> **Check your understanding**
>
> **Q2.1** — A `ReadOnly` lock sits on a resource group. A colleague reports that they can still delete blobs from a storage account inside it. Is this a bug, a misconfiguration, or expected behaviour? Justify in terms of Azure planes.
>
> **Q2.2** — A resource group has a `CanNotDelete` lock at the group scope and a `ReadOnly` lock on one VM inside it. Which operations are blocked on the VM, and which are blocked on the other resources in the group?
>
> **Q2.3** — Your security baseline says "no one, not even the subscription Owner, may delete the hub firewall." Does a resource lock satisfy this literally? If not, what is the actual guarantee a lock provides?
>
> **Q2.4** — You attempt `az group delete --name rg-gov-lab --yes` while one nested resource carries a lock and the resource group itself carries none. What happens, and why is the answer different from what the scope hierarchy alone would suggest?

---

## 3. Azure Policy — Audit Effect and the Evaluation Lifecycle

Azure Policy evaluates the **properties of resources** against business rules, at deployment time and continuously thereafter. It is the mechanism that turns a written standard ("all storage must deny public blob access") into an enforced or measured state.

Critical framing for the exam and for production:

| | Azure RBAC | Azure Policy |
|---|---|---|
| Default posture | **Deny** all; explicit grants allow | **Allow** all; explicit rules deny/audit |
| Subject of the decision | The **principal** (user, group, SP, MI) | The **resource** and its properties |
| Question answered | "Is this identity permitted to act?" | "Is the resulting resource acceptable?" |
| Evaluated when | Every ARM request | ARM request **and** every 24 h, continuously |

Reference: <https://learn.microsoft.com/en-us/azure/governance/policy/overview>

### Steps

1. Find the alias you need. A policy rule can only inspect properties exposed as **aliases** by the resource provider — this is the single most common reason a hand-written policy silently never matches.

```bash
az provider show --namespace Microsoft.Storage \
  --expand "resourceTypes/aliases" \
  --query "resourceTypes[?resourceType=='storageAccounts'].aliases[].name" -o tsv \
  | grep -i publicaccess
```

Expected output:

```
Microsoft.Storage/storageAccounts/allowBlobPublicAccess
```

2. Author the rule. Save as `rules-audit-public-blob.json`. Note the `count`-free, minimal structure: `if` (condition) and `then` (effect).

```json
{
  "if": {
    "allOf": [
      {
        "field": "type",
        "equals": "Microsoft.Storage/storageAccounts"
      },
      {
        "field": "Microsoft.Storage/storageAccounts/allowBlobPublicAccess",
        "notEquals": "false"
      }
    ]
  },
  "then": {
    "effect": "[parameters('effect')]"
  }
}
```

3. Parameterise the effect so the same definition can be rolled out as `audit` first and promoted to `deny` later. Save as `params-effect.json`.

```json
{
  "effect": {
    "type": "String",
    "metadata": {
      "displayName": "Effect",
      "description": "Enable or disable the execution of the policy"
    },
    "allowedValues": [
      "Audit",
      "Deny",
      "Disabled"
    ],
    "defaultValue": "Audit"
  }
}
```

4. Create the custom definition at subscription scope.

```bash
az policy definition create \
  --name "deny-storage-public-blob-access" \
  --display-name "Storage accounts must disable blob public access" \
  --description "Anonymous public read access to blobs and containers must be turned off." \
  --rules @rules-audit-public-blob.json \
  --params @params-effect.json \
  --mode Indexed \
  --metadata category=Storage version=1.0.0 \
  --subscription "$SUB" \
  --query "{name:name, mode:mode, type:policyType}" -o json
```

Expected output:

```json
{
  "mode": "Indexed",
  "name": "deny-storage-public-blob-access",
  "type": "Custom"
}
```

5. Assign it in **audit** mode at the resource group scope.

```bash
az policy assignment create \
  --name "audit-storage-public-blob" \
  --display-name "Audit: storage public blob access" \
  --policy "deny-storage-public-blob-access" \
  --scope "$SCOPE_RG" \
  --params '{"effect":{"value":"Audit"}}' \
  --query "{name:name, enforcementMode:enforcementMode, scope:scope}" -o json
```

Expected output:

```json
{
  "enforcementMode": "Default",
  "name": "audit-storage-public-blob",
  "scope": "/subscriptions/xxxx/resourceGroups/rg-gov-lab"
}
```

6. Create a deliberately non-compliant resource.

```bash
az storage account create \
  --name "stbadpublic$RANDOM" \
  --resource-group "$RG" \
  --location "$LOC" \
  --sku Standard_LRS \
  --allow-blob-public-access true \
  --query "{name:name, publicAccess:allowBlobPublicAccess}" -o json
```

The creation **succeeds** — `Audit` never blocks:

```json
{
  "name": "stbadpublic9042",
  "publicAccess": true
}
```

7. Do not wait 24 hours for the standard compliance cycle. Trigger an on-demand evaluation scan.

```bash
az policy state trigger-scan --resource-group "$RG"
```

The command blocks until the scan completes (typically 1–4 minutes) and returns nothing on success. Then summarise:

```bash
az policy state summarize --resource-group "$RG" \
  --query "value[0].policyAssignments[].{assignment:policyAssignmentId, nonCompliant:results.nonCompliantResources}" -o table
```

Expected output:

```
Assignment                                                                  NonCompliant
--------------------------------------------------------------------------  --------------
/subscriptions/xxxx/.../policyAssignments/audit-storage-public-blob                       1
```

8. Identify exactly which resource failed and why.

```bash
az policy state list --resource-group "$RG" \
  --filter "complianceState eq 'NonCompliant'" \
  --query "[].{resource:resourceId, state:complianceState, assignment:policyAssignmentName}" -o table
```

> **Check your understanding**
>
> **Q3.1** — Name the three events that trigger a policy evaluation, and state the documented latency of each.
>
> **Q3.2** — Your custom policy returns "0 non-compliant resources" but you know 40 storage accounts violate the rule. The rule uses `"field": "properties.allowBlobPublicAccess"`. What is wrong, and how would you have caught it before assigning?
>
> **Q3.3** — Why does the definition use `"mode": "Indexed"` rather than `"mode": "All"`? What would break if you used `All` for this specific rule?
>
> **Q3.4** — Contrast the outcome of blocking a bad storage account with (a) an RBAC deny of `Microsoft.Storage/storageAccounts/write`, and (b) an Azure Policy `Deny` effect. Which one still lets the platform team deploy compliant storage, and why does that matter?

---

## 4. Promoting to `Deny`, and the Two Safety Valves

An `Audit` assignment measures. A `Deny` assignment enforces — and can break existing pipelines the moment it lands. Azure Policy provides two production safety mechanisms: **`enforcementMode: DoNotEnforce`** (evaluate and report but never block, i.e. a what-if) and **exemptions** (a scoped, expiring, auditable carve-out that is *not* the same as excluding the scope).

References:
- <https://learn.microsoft.com/en-us/azure/governance/policy/concepts/assignment-structure>
- <https://learn.microsoft.com/en-us/azure/governance/policy/concepts/exemption-structure>

### Steps

1. Stage the change safely: create the `Deny` assignment with enforcement switched off.

```bash
az policy assignment create \
  --name "deny-storage-public-blob" \
  --display-name "Deny: storage public blob access" \
  --policy "deny-storage-public-blob-access" \
  --scope "$SCOPE_RG" \
  --params '{"effect":{"value":"Deny"}}' \
  --enforcement-mode DoNotEnforce \
  --query "{name:name, enforcementMode:enforcementMode}" -o json
```

Expected output:

```json
{
  "enforcementMode": "DoNotEnforce",
  "name": "deny-storage-public-blob"
}
```

2. Confirm the what-if behaviour: the deployment still succeeds, but the assignment records the would-be violation.

```bash
az storage account create --name "stwhatif$RANDOM" --resource-group "$RG" \
  --location "$LOC" --sku Standard_LRS --allow-blob-public-access true \
  --query name -o tsv
```

3. Turn enforcement on.

```bash
az policy assignment update \
  --name "deny-storage-public-blob" \
  --scope "$SCOPE_RG" \
  --enforcement-mode Default \
  --query enforcementMode -o tsv
```

Expected output:

```
Default
```

4. Attempt the same non-compliant deployment. Allow ~30 minutes after an assignment change for full propagation; new assignments are typically effective within 5–15 minutes at resource-group scope.

```bash
az storage account create --name "stblocked$RANDOM" --resource-group "$RG" \
  --location "$LOC" --sku Standard_LRS --allow-blob-public-access true
```

Expected output — ARM rejects the request before the resource provider ever sees it:

```
(RequestDisallowedByPolicy) Resource 'stblocked5518' was disallowed by policy.
Policy identifiers: '[{"policyAssignment":{"name":"Deny: storage public blob access",
"id":"/subscriptions/xxxx/resourceGroups/rg-gov-lab/providers/Microsoft.Authorization/
policyAssignments/deny-storage-public-blob"},"policyDefinition":{"name":"Storage accounts
must disable blob public access","id":"/subscriptions/xxxx/providers/Microsoft.Authorization/
policyDefinitions/deny-storage-public-blob-access"}}]'
Code: RequestDisallowedByPolicy
```

5. Verify that the *compliant* path is unaffected — this is the property that distinguishes Policy from a blunt RBAC deny.

```bash
az storage account create --name "stgood$RANDOM" --resource-group "$RG" \
  --location "$LOC" --sku Standard_LRS --allow-blob-public-access false \
  --query "{name:name, publicAccess:allowBlobPublicAccess}" -o json
```

6. A legacy public-documents workload genuinely needs anonymous access for 90 days. Grant an **exemption**, not an exclusion.

```bash
export TARGET_SA=$(az storage account list -g "$RG" \
  --query "[?allowBlobPublicAccess].name | [0]" -o tsv)

az policy exemption create \
  --name "exempt-legacy-public-docs" \
  --display-name "Legacy public docs site — CAB CHG0041377" \
  --policy-assignment "$(az policy assignment show --name 'deny-storage-public-blob' --scope "$SCOPE_RG" --query id -o tsv)" \
  --scope "${SCOPE_RG}/providers/Microsoft.Storage/storageAccounts/${TARGET_SA}" \
  --exemption-category Waiver \
  --description "Anonymous read required by legacy CMS; migration tracked in PLAT-2291" \
  --expires-on "2026-12-05T00:00:00Z" \
  --query "{name:name, category:exemptionCategory, expires:expiresOn}" -o json
```

Expected output:

```json
{
  "category": "Waiver",
  "expires": "2026-12-05T00:00:00+00:00",
  "name": "exempt-legacy-public-docs"
}
```

7. Re-scan and confirm the resource now reports `Exempt`, not `Compliant` and not `NonCompliant`.

```bash
az policy state trigger-scan --resource-group "$RG"
az policy state list --resource-group "$RG" \
  --query "[?policyAssignmentName=='deny-storage-public-blob'].{res:resourceId, state:complianceState}" -o table
```

> **Check your understanding**
>
> **Q4.1** — Distinguish `exclusion` (`notScopes` on the assignment), `exemption`, and `enforcementMode: DoNotEnforce`. Which one preserves an audit trail of the carve-out, and which one is invisible in the compliance dashboard?
>
> **Q4.2** — What is the difference between exemption categories `Waiver` and `Mitigated`? Give a scenario for each.
>
> **Q4.3** — A `Deny` policy is assigned at management group scope. 6,000 storage accounts already violate it. What happens to those 6,000 accounts at the moment of assignment?
>
> **Q4.4** — Order these effects by evaluation precedence and explain why the order matters: `Deny`, `Disabled`, `Audit`, `Modify`, `DeployIfNotExists`.

---

## 5. Initiatives (Policy Sets) and the Compliance Dashboard

A single policy is a rule. An **initiative** (policy set definition) is a control framework: a named group of definitions assigned and reported as one unit. Every regulatory framework Microsoft ships — ISO 27001, NIST SP 800-53 Rev. 5, PCI DSS, the Microsoft cloud security benchmark — is delivered as a built-in initiative.

Reference: <https://learn.microsoft.com/en-us/azure/governance/policy/concepts/initiative-definition-structure>

### Steps

1. Discover the built-in definitions you will compose. Derive the GUIDs rather than hardcoding them from a blog post.

```bash
az policy definition list \
  --query "[?displayName=='Allowed locations' || displayName=='Require a tag on resources'].{display:displayName, name:name}" -o table
```

Expected output:

```
Display                        Name
-----------------------------  ------------------------------------
Allowed locations              e56962a6-4747-49cd-b67b-bf8b01975c4c
Require a tag on resources     871b6d14-10aa-478d-b590-94f262ecfa99
```

2. Author the initiative. Save as `initiative-baseline.json`. Note how each member policy's parameters are re-exposed at initiative level so the assignment configures the whole set once.

```json
[
  {
    "policyDefinitionId": "/providers/Microsoft.Authorization/policyDefinitions/e56962a6-4747-49cd-b67b-bf8b01975c4c",
    "policyDefinitionReferenceId": "allowedLocations",
    "parameters": {
      "listOfAllowedLocations": {
        "value": "[parameters('allowedLocations')]"
      }
    }
  },
  {
    "policyDefinitionId": "/providers/Microsoft.Authorization/policyDefinitions/871b6d14-10aa-478d-b590-94f262ecfa99",
    "policyDefinitionReferenceId": "requireCostCenterTag",
    "parameters": {
      "tagName": {
        "value": "costCenter"
      }
    }
  }
]
```

3. Author the initiative parameters. Save as `initiative-params.json`.

```json
{
  "allowedLocations": {
    "type": "Array",
    "metadata": {
      "displayName": "Allowed locations",
      "description": "Regions approved by the data residency standard",
      "strongType": "location"
    },
    "defaultValue": [
      "eastus",
      "westeurope"
    ]
  }
}
```

4. Create and assign the initiative.

```bash
az policy set-definition create \
  --name "contoso-landing-zone-baseline" \
  --display-name "Contoso landing zone baseline" \
  --description "Minimum governance controls for every subscription" \
  --definitions @initiative-baseline.json \
  --params @initiative-params.json \
  --metadata category="Contoso Baseline" version=1.0.0 \
  --subscription "$SUB" \
  --query "{name:name, members:length(policyDefinitions)}" -o json
```

Expected output:

```json
{
  "members": 2,
  "name": "contoso-landing-zone-baseline"
}
```

```bash
az policy assignment create \
  --name "assign-lz-baseline" \
  --display-name "Contoso landing zone baseline" \
  --policy-set-definition "contoso-landing-zone-baseline" \
  --scope "$SCOPE_RG" \
  --params '{"allowedLocations":{"value":["eastus"]}}' \
  --query name -o tsv
```

5. Read compliance as a percentage, the way an auditor would.

```bash
az policy state trigger-scan --resource-group "$RG"

az policy state summarize --resource-group "$RG" \
  --query "value[0].results.{nonCompliantResources:nonCompliantResources, nonCompliantPolicies:nonCompliantPolicies}" -o json
```

Expected output:

```json
{
  "nonCompliantPolicies": 1,
  "nonCompliantResources": 3
}
```

6. Query the same data at fleet scale with Azure Resource Graph — the only viable approach beyond a few hundred resources.

```bash
az graph query -q "policyresources
| where type == 'microsoft.policyinsights/policystates'
| where properties.complianceState == 'NonCompliant'
| summarize count() by tostring(properties.policyDefinitionName)
| order by count_ desc" --first 10 -o table
```

> **Check your understanding**
>
> **Q5.1** — Why is a regulatory framework such as ISO 27001 shipped as an *initiative* rather than as a single policy definition?
>
> **Q5.2** — The Regulatory Compliance dashboard in Microsoft Defender for Cloud shows "NIST SP 800-53 Rev. 5 — 64% compliant". What Azure component actually produced that number?
>
> **Q5.3** — A control in a regulatory initiative is marked `Manual` effect with state `Unknown`. What does that mean, and who is responsible for changing it?
>
> **Q5.4** — Your initiative reports 100% compliant. Name two distinct reasons this may still not mean "we are compliant with the standard".

---

## 6. `Modify` Effect, Managed Identity and Remediation

`Audit` and `Deny` handle *new* resources. Bringing the **existing estate** into compliance requires an effect that changes resources — `Modify` (property/tag mutation) or `DeployIfNotExists` (deploy an ARM template when a related resource is missing) — plus a **managed identity** that Policy uses to act, and a **remediation task** that sweeps existing resources.

Reference: <https://learn.microsoft.com/en-us/azure/governance/policy/how-to/remediate-resources>

### Steps

1. Author a `Modify` rule that inherits the `costCenter` tag from the resource group. Save as `rules-inherit-tag.json`.

```json
{
  "if": {
    "allOf": [
      {
        "field": "type",
        "equals": "Microsoft.Storage/storageAccounts"
      },
      {
        "field": "tags['costCenter']",
        "exists": "false"
      },
      {
        "value": "[resourceGroup().tags['costCenter']]",
        "notEquals": ""
      }
    ]
  },
  "then": {
    "effect": "modify",
    "details": {
      "roleDefinitionIds": [
        "/providers/Microsoft.Authorization/roleDefinitions/b24988ac-6180-42a0-ab88-20f7382dd24c"
      ],
      "conflictEffect": "audit",
      "operations": [
        {
          "operation": "addOrReplace",
          "field": "tags['costCenter']",
          "value": "[resourceGroup().tags['costCenter']]"
        }
      ]
    }
  }
}
```

> `b24988ac-6180-42a0-ab88-20f7382dd24c` is the built-in **Contributor** role. `roleDefinitionIds` declares the minimum permission the remediation identity needs; Policy refuses to assign an identity broader than what you request here.

2. Create the definition.

```bash
az policy definition create \
  --name "inherit-costcenter-tag" \
  --display-name "Inherit costCenter tag from the resource group" \
  --rules @rules-inherit-tag.json \
  --mode Indexed \
  --metadata category=Tags version=1.0.0 \
  --subscription "$SUB" \
  --query name -o tsv
```

3. Assign it **with a system-assigned managed identity**. `--mi-system-assigned` requires `--location`, because a managed identity is a regional object.

```bash
az policy assignment create \
  --name "assign-inherit-costcenter" \
  --display-name "Inherit costCenter tag" \
  --policy "inherit-costcenter-tag" \
  --scope "$SCOPE_RG" \
  --mi-system-assigned \
  --location "$LOC" \
  --identity-scope "$SCOPE_RG" \
  --role "Contributor" \
  --query "{name:name, principalId:identity.principalId, type:identity.type}" -o json
```

Expected output:

```json
{
  "name": "assign-inherit-costcenter",
  "principalId": "3f7c1c2e-9d40-4c31-8f2b-6a1e8c9d0b55",
  "type": "SystemAssigned"
}
```

4. Confirm the role assignment Policy created on your behalf.

```bash
az role assignment list --scope "$SCOPE_RG" \
  --query "[?principalId=='3f7c1c2e-9d40-4c31-8f2b-6a1e8c9d0b55'].{role:roleDefinitionName, scope:scope}" -o table
```

5. Evaluate, then remediate the **pre-existing** untagged storage accounts.

```bash
az policy state trigger-scan --resource-group "$RG"

az policy remediation create \
  --name "remediate-costcenter-$(date +%s)" \
  --resource-group "$RG" \
  --policy-assignment "assign-inherit-costcenter" \
  --resource-discovery-mode ExistingNonCompliant \
  --query "{name:name, state:provisioningState}" -o json
```

Expected output:

```json
{
  "name": "remediate-costcenter-1780012345",
  "state": "Accepted"
}
```

6. Watch the task drain and verify the estate changed.

```bash
az policy remediation list --resource-group "$RG" \
  --query "[].{name:name, state:provisioningState, deployed:deploymentStatus.successfulDeployments}" -o table

az storage account list -g "$RG" --query "[].{name:name, costCenter:tags.costCenter}" -o table
```

Expected output:

```
Name              CostCenter
----------------  ------------
stgovlab24817     CC-4711
stbadpublic9042   CC-4711
stgood7731        CC-4711
```

> **Check your understanding**
>
> **Q6.1** — Why must a `Modify` or `DeployIfNotExists` assignment carry a managed identity, while `Audit` and `Deny` must not?
>
> **Q6.2** — What is the functional difference between `Modify` and `DeployIfNotExists`? Give one requirement that only each can satisfy.
>
> **Q6.3** — You assigned a `DeployIfNotExists` policy last week. Ten resources created since then are compliant, but 900 older ones are still non-compliant. Explain precisely why, and the one action that fixes it.
>
> **Q6.4** — `conflictEffect: audit` is set in the rule above. What conflict is it referring to, and what would `conflictEffect: deny` have done instead?

---

## 7. Deny Assignments — Deployment Stacks and the Azure Blueprints Retirement

Azure Blueprints (Preview) is **deprecated**; Microsoft directs customers to **Template Specs** plus **Deployment Stacks**. This matters for the exam because older AZ-900 material still names Blueprints, and it matters in production because deployment stacks introduce **deny assignments** — a stronger guard than a resource lock, since a deny assignment cannot simply be deleted by an Owner acting on the resource.

References:
- <https://learn.microsoft.com/en-us/azure/governance/blueprints/overview>
- <https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/deployment-stacks>
- <https://learn.microsoft.com/en-us/azure/role-based-access-control/deny-assignments>

### Steps

1. Author a minimal Bicep template. Save as `stack-storage.bicep`.

```bicep
param location string = resourceGroup().location
param storageAccountName string

resource sa 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    allowBlobPublicAccess: false
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
  }
}

output storageId string = sa.id
```

2. Deploy it as a managed stack with deny settings.

```bash
export STACK_SA="ststack$RANDOM"

az stack group create \
  --name "stack-platform-baseline" \
  --resource-group "$RG" \
  --template-file stack-storage.bicep \
  --parameters storageAccountName="$STACK_SA" \
  --deny-settings-mode denyWriteAndDelete \
  --action-on-unmanage detachAll \
  --yes \
  --query "{name:name, mode:denySettings.mode, state:provisioningState}" -o json
```

Expected output:

```json
{
  "mode": "denyWriteAndDelete",
  "name": "stack-platform-baseline",
  "state": "succeeded"
}
```

3. Attempt an out-of-band change — the drift a lock would also stop, but observe the different error class.

```bash
az storage account update --name "$STACK_SA" --resource-group "$RG" --tags drift=yes
```

Expected output:

```
(RequestDisallowedByAzure) Resource '.../storageAccounts/ststack1902' was disallowed
by a deny assignment created by deployment stack 'stack-platform-baseline'.
Code: RequestDisallowedByAzure
```

4. Compare the three protection mechanisms you have now exercised.

```bash
az lock list --resource-group "$RG" -o table
az role assignment list --scope "$SCOPE_RG" --include-inherited --query "[].roleDefinitionName" -o tsv | sort -u
```

5. Tear the stack down, detaching rather than deleting the resource.

```bash
az stack group delete --name "stack-platform-baseline" --resource-group "$RG" \
  --action-on-unmanage detachAll --yes
```

> **Check your understanding**
>
> **Q7.1** — Fill in the decision table: for each of *resource lock*, *deny assignment*, *Azure Policy Deny*, state (a) what it protects, (b) whether a subscription Owner can bypass it directly, (c) whether it is evaluated on *existing* resources.
>
> **Q7.2** — An exam question written against an older syllabus asks which service lets you "package ARM templates, RBAC assignments and policy assignments into a repeatable, versioned environment definition." What is the historical answer, what is its current status, and what replaces it?
>
> **Q7.3** — Your `--action-on-unmanage` choice is `deleteAll` instead of `detachAll`. Describe the blast radius of running `az stack group delete` on a production stack.

---

## 8. Microsoft Purview — Data Governance and Compliance Portfolio

Microsoft Purview is the umbrella for two distinct families that the exam treats as one objective:

**A. Data governance (the former Azure Purview)** — knows *where your data is, what it contains, and where it flows*, across Azure, on-premises, AWS/GCP and SaaS:

| Component | Purpose |
|---|---|
| **Data Map** | The scanned, continuously refreshed graph of data assets, classifications and lineage |
| **Data Catalog / Unified Catalog** | Business-glossary search over the map; the "find trustworthy data" surface |
| **Data Estate Insights / Health** | Executive reporting on coverage, classification and stewardship |
| **Data Sharing** | In-place sharing between organisations without copying |
| **Data Policy** | Access policies for registered sources, authored centrally |

**B. Risk and compliance solutions** — Compliance Manager, Information Protection (sensitivity labels), Data Loss Prevention, Insider Risk Management, Data Lifecycle Management, eDiscovery, Audit, Communication Compliance.

References:
- <https://learn.microsoft.com/en-us/purview/purview>
- <https://learn.microsoft.com/en-us/purview/compliance-manager>
- <https://learn.microsoft.com/en-us/azure/compliance/>

> **COST WARNING.** A Purview account bills for an always-on Data Map (elastic capacity units, billed per hour) plus per-vCore-hour scanning. Path A below provisions real infrastructure and **must be deleted immediately after**. Path B is free and covers everything the AZ-900 objective actually requires. Choose one.

### Path A — Provision and scan (billable)

1. Add the CLI extension and provision the account.

```bash
az extension add --name purview --upgrade
az provider register --namespace Microsoft.Purview

az purview account create \
  --name "pvw-gov-lab-$RANDOM" \
  --resource-group "$RG" \
  --location "$LOC" \
  --query "{name:name, endpoint:properties.endpoints.catalog, state:properties.provisioningState}" -o json
```

Expected output:

```json
{
  "endpoint": "https://pvw-gov-lab-3312.purview.azure.com/catalog",
  "name": "pvw-gov-lab-3312",
  "state": "Succeeded"
}
```

2. In the Microsoft Purview portal (<https://purview.microsoft.com>), open **Data Map → Data sources → Register**, choose **Azure Blob Storage**, and select the `$SA` account created in Exercise 2. Registration only records the source; it reads no data.

3. On the registered source choose **New scan**, authenticate with the Purview account's **managed identity**, and set the scan rule set to **AzureStorage (system default)**. Before running, grant the identity read access:

```bash
export PVW_MI=$(az purview account show --name "<your-purview-account>" -g "$RG" \
  --query identity.principalId -o tsv)

az role assignment create \
  --assignee "$PVW_MI" \
  --role "Storage Blob Data Reader" \
  --scope "${SCOPE_RG}/providers/Microsoft.Storage/storageAccounts/${SA}"
```

4. Run the scan, then open **Data Catalog → Browse assets**. Inspect a discovered asset's **Schema** tab and note any classification applied (for example `Credit Card Number`, `EU National Identification Number`) — these come from built-in sensitive information types, matched by pattern and checksum, not by filename.

5. **Delete the account immediately** — the Data Map bills while it exists.

```bash
az purview account delete --name "<your-purview-account>" -g "$RG" --yes
```

### Path B — Zero-cost compliance evidence trail

1. Open the **Service Trust Portal** at <https://servicetrust.microsoft.com>. Navigate to **Reports → Audit reports** and locate the current **SOC 2 Type II** report for Azure. Note that downloading requires sign-in and acceptance of an NDA.

2. Open **Microsoft Purview Compliance Manager** (<https://purview.microsoft.com> → **Compliance Manager**, or the direct Learn walkthrough at <https://learn.microsoft.com/en-us/purview/compliance-manager-setup>). Record your tenant's **compliance score**, then open one improvement action and identify:
   - its **points achieved / possible**,
   - whether it is **Microsoft-managed** or **customer-managed**,
   - its **assessment** and **control family**.

3. Open the Azure compliance documentation index at <https://learn.microsoft.com/en-us/azure/compliance/>. Locate an offering relevant to a regulated workload (for example ISO/IEC 27001, HIPAA HITRUST, FedRAMP High, or a regional offering such as GDPR) and note the scope statement — which Azure services are in scope for that attestation.

4. Cross-link the two halves of the objective: in Azure Policy, list the built-in initiatives that implement those same frameworks.

```bash
az policy set-definition list \
  --query "[?policyType=='BuiltIn' && contains(displayName, 'ISO')].{display:displayName, name:name}" -o table
```

Expected output (abridged):

```
Display                                                          Name
---------------------------------------------------------------  ------------------------------------
ISO 27001:2013                                                   89c6cddc-1c73-4ac1-b19c-54d1a15a42f2
```

> **Check your understanding**
>
> **Q8.1** — A regulator asks: "Do you know whether any customer national ID numbers are stored outside the EU?" Which Microsoft Purview capability answers that, and which Azure Policy effect would *prevent* the situation from recurring?
>
> **Q8.2** — Distinguish the **Trust Center**, the **Service Trust Portal**, and **Compliance Manager**. Which one produces a *score*, which one produces *third-party audit reports*, and which one is *marketing/overview* material?
>
> **Q8.3** — Compliance Manager shows an improvement action worth 27 points that is marked "Microsoft-managed." Can you increase your score by working on it? What does that reveal about the shared responsibility model?
>
> **Q8.4** — Microsoft Purview scans an on-premises SQL Server and an AWS S3 bucket. What does this tell you about the scope of the product versus the scope of Azure Policy?
>
> **Q8.5** — Why can Microsoft Purview classify data that Azure Policy is structurally incapable of seeing? Answer in terms of control plane versus data plane.

---

## 9. Decision Drill — Requirement to Tool

No commands here. For each requirement, name the **single** correct tool and, in one sentence, why the near-neighbours are wrong. This is the exact discrimination AZ-900 tests.

1. "The finance VM must not be deleted by anyone, including admins, during the quarter-end freeze."
2. "Every VM deployed anywhere in the tenant must be in `westeurope` or `northeurope`."
3. "We need to know which of our 40 data stores contain passport numbers, including two on-premises file shares."
4. "Auditors want our current SOC 2 Type II attestation letter for Azure."
5. "Show a percentage score of our progress against ISO 27001, with recommended actions and evidence upload."
6. "Every storage account missing a `costCenter` tag should have it added automatically, including the 900 that already exist."
7. "Nobody in the contractors group may create resources in the production subscription."
8. "A resource must not be modified out-of-band after the platform team deploys it from source control."
9. "Report — do not block — how many VMs lack Azure Backup, before we make it mandatory next quarter."
10. "Group forty separate security rules into one auditable control set assigned per subscription."

> **Check your understanding**
>
> **Q9.1** — Answer all ten.
>
> **Q9.2** — Items 1, 7 and 8 all "stop someone doing something." State the mechanism used by each and the one property that makes them non-interchangeable.

---

## 10. Cleanup

Locks and deny assignments will block deletion, so they come off first.

```bash
# 1. Remove any remaining locks
for L in $(az lock list --resource-group "$RG" --query "[].name" -o tsv); do
  az lock delete --name "$L" --resource-group "$RG"
done

# 2. Remove exemptions, then assignments, then definitions (dependency order)
az policy exemption delete --name "exempt-legacy-public-docs" \
  --scope "${SCOPE_RG}/providers/Microsoft.Storage/storageAccounts/${TARGET_SA}" 2>/dev/null

for A in audit-storage-public-blob deny-storage-public-blob assign-lz-baseline assign-inherit-costcenter; do
  az policy assignment delete --name "$A" --scope "$SCOPE_RG" 2>/dev/null
done

az policy set-definition delete --name "contoso-landing-zone-baseline" --subscription "$SUB"
az policy definition delete --name "deny-storage-public-blob-access" --subscription "$SUB"
az policy definition delete --name "inherit-costcenter-tag" --subscription "$SUB"

# 3. Resource group
az group delete --name "$RG" --yes --no-wait

# 4. Management groups (children first)
az account management-group delete --name "mg-contoso-sandbox"
az account management-group delete --name "mg-contoso-platform"
```

Confirm nothing survives:

```bash
az policy assignment list --scope "$SCOPE_SUB" --query "[?contains(name,'storage') || contains(name,'baseline')].name" -o tsv
az lock list --query "[].{name:name, scope:id}" -o table
```

---

<details>
<summary><strong>Answers</strong> — expand only after attempting every block</summary>

### Exercise 0

**A0.1** — The missing permission is `Microsoft.Authorization/locks/*` (specifically `.../locks/write` for creation and `.../locks/delete` for removal). Contributor grants nearly all resource actions but carries an explicit `NotActions` entry for `Microsoft.Authorization/*/Write` and `Microsoft.Authorization/*/Delete`, which excludes locks and role assignments. The two built-in roles that grant it are **Owner** and **User Access Administrator**. This is deliberate: if Contributor could remove locks, a lock would only be a suggestion to the very role most likely to delete something by accident.

**A0.2** — Evaluation is performed by the Policy engine regardless. `Microsoft.PolicyInsights` is the resource provider that owns **remediation tasks** (`Microsoft.PolicyInsights/remediations`) and the **policy states / policy events** APIs used by `az policy state list|summarize|trigger-scan` and by the compliance dashboard. Without it registered, `DeployIfNotExists` and `Modify` remediation of existing resources fails, and on-demand scans return provider-not-registered errors.

**A0.3** — Billing is the cost-management reason. The governance reason is that a tag is a **policy-addressable property**: Azure Policy can require it (`Require a tag on resources`), inherit it (`Modify`), deny resources without it, and Resource Graph can query the estate by it. A tag converts an organisational fact (ownership, data classification, environment, regulatory scope) into machine-enforceable metadata. That is why tag policies are in nearly every landing-zone baseline, independent of chargeback.

---

### Exercise 1

**A1.1** — A management group has exactly **one** parent (the hierarchy is a tree, not a graph). Beneath the root management group, Azure supports **six levels** of nested management groups — the root level does not count toward that six, and the subscription level is not counted either. Each management group can have many children; a directory supports up to 10,000 management groups.

**A1.2** — It generates **two** separate non-compliance records — one per assignment. Policy assignments are **cumulative and never override each other**. There is no "most specific wins" resolution as there is in some other systems: if any applicable assignment has a `Deny` effect, the request is denied. This is why a `Deny` at management-group scope cannot be relaxed by a child-scope assignment; only an exclusion (`notScopes`) or an exemption on the *parent* assignment can carve out the child.

**A1.3** — The Tenant Root Group requires **elevated access**: a Global Administrator must toggle *Access management for Azure resources* in Microsoft Entra ID properties, which grants them the **User Access Administrator** role at root scope (`/`). Entra ID roles and Azure RBAC roles are separate systems; being Global Administrator confers no Azure resource permissions by default. The elevation should be removed after the required root-scope assignment is made.

---

### Exercise 2

**A2.1** — **Expected behaviour, not a bug.** Resource locks are enforced by **Azure Resource Manager** and therefore apply only to the **control plane** (`management.azure.com`) — creating, updating and deleting *resources*. Deleting a blob is a **data-plane** operation against `<account>.blob.core.windows.net`, which never traverses ARM and is authorised by RBAC data actions or a SAS/key. Protecting blob contents requires data-plane controls: immutability policies / legal holds, soft delete, versioning, and restricted data-plane RBAC.

**A2.2** — Locks are **inherited downward, and the most restrictive lock in the inheritance chain wins**. On the VM, both locks apply, so the effective protection is `ReadOnly`: delete is blocked *and* every write is blocked (no resize, no tag change, no start/stop — `POST` operations that mutate state are also blocked, so you cannot even restart it). On every other resource in the group only `CanNotDelete` applies: they can be modified freely but not deleted. Note also that a child scope cannot *loosen* an inherited lock.

**A2.3** — **No, not literally.** A lock is not an authorisation boundary — anyone holding `Microsoft.Authorization/locks/delete` (Owner, User Access Administrator) can remove the lock and then perform the delete. What a lock actually guarantees is that the destructive action becomes **two deliberate steps instead of one**: it eliminates accidental deletion, fat-fingered CLI, and cascading template/pipeline deletions, and it produces a distinct activity-log entry (`Microsoft.Authorization/locks/delete`) that can be alerted on. For a guarantee that survives an Owner, you need a **deny assignment** (Exercise 7) or to remove the Owner role itself.

**A2.4** — The delete **fails**. ARM must delete every resource in the group to delete the group; the locked child cannot be deleted, so the whole operation is rejected with `ScopeLocked`. The asymmetry is worth internalising: locks are inherited *downward* for protection, but deletion is evaluated *upward* — a lock anywhere in the subtree blocks a parent's deletion. Partial deletion may still occur for unlocked resources before the failure, which is why lock inventory should be checked before any group teardown.

---

### Exercise 3

**A3.1** — (1) **A resource is created or updated** via ARM — evaluated synchronously, in the request path, before the resource provider is called; `Deny`, `Modify`, `Append` and `Audit` act here. (2) **A policy or initiative is assigned, updated or removed** — the affected scope is evaluated, generally effective within about **30 minutes**. (3) **The standard compliance evaluation cycle**, which runs approximately **every 24 hours**. Additionally, on-demand scans (`az policy state trigger-scan`) and resource-provider-triggered re-evaluations exist. `DeployIfNotExists` and `AuditIfNotExists` evaluate *after* the resource provider returns success, not in the request path.

**A3.2** — The condition uses a raw JSON path, not an **alias**. Azure Policy can only evaluate properties the resource provider exposes as aliases, in the form `Microsoft.Storage/storageAccounts/allowBlobPublicAccess`. A `field` that matches no alias silently never evaluates true, producing a permanently "compliant" assignment — the most dangerous failure mode in policy authoring, because it looks like success. Catch it before assigning by listing aliases (`az provider show --namespace <ns> --expand "resourceTypes/aliases"`) and by testing against a known-bad resource in `DoNotEnforce` mode.

**A3.3** — `Indexed` tells Policy to evaluate only resource types that **support tags and location** — effectively, individual resources rather than resource groups, subscriptions, or extension/child resources. Storage accounts are indexed resources, so `Indexed` is correct and avoids generating spurious `NonCompliant` results for resource groups and subscriptions that obviously have no `allowBlobPublicAccess` property. Use `mode: All` when the policy must evaluate resource groups or subscriptions themselves (for example "resource groups must have a costCenter tag"), or provider modes such as `Microsoft.Kubernetes.Data` for AKS admission control.

**A3.4** — (a) An RBAC deny of `Microsoft.Storage/storageAccounts/write` blocks the **principal** from creating *any* storage account, compliant or not. It is coarse, identity-scoped, and forces an exception process for legitimate work. (b) An Azure Policy `Deny` blocks only the **non-compliant shape** — the same engineer can immediately deploy a storage account with `allowBlobPublicAccess: false` and succeed. This is the central design point: Policy constrains *what* may exist without constraining *who* may build. It scales to self-service platforms; RBAC denial does not.

---

### Exercise 4

**A4.1** —
- **Exclusion (`notScopes`)**: the scope is removed from the assignment's reach entirely. No evaluation, no compliance record, no expiry, no justification field. Effectively invisible in the compliance dashboard — the resources simply do not appear.
- **Exemption**: the resource *is* in scope, is evaluated, and is reported with compliance state **`Exempt`**. It carries a category (`Waiver`/`Mitigated`), a description, and an optional `expiresOn`. This is the auditable carve-out.
- **`enforcementMode: DoNotEnforce`**: applies to the whole assignment. Effects are not applied (nothing is denied or modified), but evaluation and compliance reporting continue. It is a what-if / staging mode, not a carve-out.

The exemption preserves the audit trail; the exclusion is the one that disappears from the dashboard.

**A4.2** — **`Waiver`** = the risk is knowingly accepted, and the resource is *not* brought into compliance by other means (for example: a legacy CMS genuinely requires anonymous blob read until it is migrated; tracked as technical debt with an expiry date). **`Mitigated`** = the objective is met through an alternative control, so the policy's own check is not meaningful here (for example: a VM lacks the required endpoint-protection extension because it is a hardened appliance image with vendor-supplied protection, or a public IP is exempt because it is fronted by an Azure Firewall enforcing the same rule).

**A4.3** — **Nothing happens to them.** A `Deny` effect is evaluated only in the ARM request path; it cannot retroactively delete or change existing resources. All 6,000 will be evaluated on the next compliance cycle and reported as `NonCompliant`, and they will be blocked from any future *update* that keeps them non-compliant, but they continue to run untouched. Remediating existing resources requires `Modify`/`DeployIfNotExists` plus a remediation task, or an out-of-band campaign.

**A4.4** — Evaluation order: **`Disabled` → `Append`/`Modify` → `Deny` → `Audit` → `AuditIfNotExists`/`DeployIfNotExists`.
It matters because (1) `Disabled` short-circuits everything, which is how you kill a misfiring policy instantly without deleting the assignment; (2) `Modify`/`Append` run *before* `Deny`, so a policy that adds a required tag can satisfy a second policy that denies resources missing that tag — order determines whether the two compose or conflict; (3) `Audit` runs after `Deny`, so a denied request generates no audit record of a resource that was never created; (4) the `*IfNotExists` effects run only after the resource provider returns success, because they inspect *related* resources that cannot exist until the parent does.

---

### Exercise 5

**A5.1** — A regulatory standard is dozens to hundreds of discrete technical controls, each mapping to a different resource type and property. An initiative is the unit of **assignment, parameterisation and reporting**: it lets you assign 200 definitions once, parameterise them consistently (allowed regions, log retention days, required tags), and report a single roll-up compliance figure per framework per scope. It also gives each member a `policyDefinitionReferenceId`, which is how a control ID (e.g. `AC-2`) is bound to the technical check and how exemptions can target one control without disabling the set.

**A5.2** — **Azure Policy.** The Defender for Cloud Regulatory Compliance dashboard is a presentation layer over built-in **policy initiatives** — the compliance state of each control is the aggregated policy compliance state of its member definitions, sourced from the Policy Insights `policyStates` API. The same data is reachable via `az policy state summarize` and Azure Resource Graph. Defender for Cloud adds the control-family grouping, the framework metadata, and the recommendation experience; it does not perform the evaluation.

**A5.3** — The **`Manual`** effect exists for controls that cannot be evaluated by inspecting resource properties — process, documentation and physical/organisational controls ("a security awareness training programme exists", "background checks are performed"). Its default compliance state is **`Unknown`**, and a human with the appropriate permission (`Microsoft.PolicyInsights/policyStates/write` via a role such as Resource Policy Contributor) must **attest** the state to `Compliant` or `NonCompliant`, optionally with evidence. It is the mechanism that lets a single dashboard cover both technical and procedural controls, and it is the customer's responsibility, never Microsoft's.

**A5.4** — Two of many valid reasons: (1) **Coverage gap** — the initiative only measures what its member definitions check, and not every control in a standard has an automatable check; the `Manual` and Microsoft-managed controls may be untouched. (2) **Scope gap** — compliance is reported for the scope the assignment covers; subscriptions, management groups or resource types outside that scope contribute nothing, so 100% may mean "100% of the 3% we assigned". Others: exempted resources report `Exempt` rather than `NonCompliant` and can be excluded from the denominator depending on the view; a definition using an invalid alias silently passes (see A3.2); and `enforcementMode: DoNotEnforce` assignments report state without ever having enforced anything.

---

### Exercise 6

**A6.1** — `Modify` and `DeployIfNotExists` **change resources** — they perform writes or template deployments on the customer's behalf. Azure Policy therefore needs a security principal with permission to do so, which is the assignment's managed identity (system-assigned or user-assigned), granted exactly the roles declared in the definition's `roleDefinitionIds`. `Audit` and `Deny` only read the incoming request or the existing resource state and produce a verdict; they perform no writes, so an identity would be unnecessary privilege. Azure Policy enforces this: assigning a `Modify`/`DeployIfNotExists` policy without an identity fails, and assigning an `Audit` policy with one is rejected as invalid.

**A6.2** — `Modify` **mutates properties or tags of the resource being evaluated**, in the request path (add/addOrReplace/remove operations on aliases and tags). `DeployIfNotExists` **deploys an ARM template creating or configuring a *related* resource** when a required companion object is missing, and runs *after* the resource provider succeeds. Only `Modify` can add a `costCenter` tag to the storage account itself as it is created. Only `DeployIfNotExists` can create the diagnostic setting that ships that storage account's logs to a Log Analytics workspace, or install a VM extension — those are separate resources that `Modify` cannot touch.

**A6.3** — `DeployIfNotExists` (like `Deny` and `Modify`) is evaluated in the **request path** for new and updated resources. The 900 older resources were created before the assignment existed, so no deployment was ever triggered for them; they are correctly reported `NonCompliant` by the periodic evaluation cycle, but nothing acts on them. The fix is to create a **remediation task** against the assignment (`az policy remediation create --resource-discovery-mode ExistingNonCompliant`), which enumerates the non-compliant resources and executes the embedded deployment for each, using the assignment's managed identity.

**A6.4** — `conflictEffect` governs what happens when **two `Modify` policies would write conflicting values to the same field** on the same resource — for example one policy inheriting `costCenter` from the resource group and another forcing a fixed value. With `conflictEffect: audit`, the operation is not applied and the resource is simply marked non-compliant, so a policy conflict degrades to a reporting problem. With `conflictEffect: deny`, the *resource request itself is blocked* — a policy-authoring mistake becomes an outage for every deployment in scope. `audit` is the safe default for a rollout; `deny` is appropriate only when an ambiguous value is worse than a failed deployment.

---

### Exercise 7

**A7.1** —

| | Resource lock | Deny assignment | Azure Policy `Deny` |
|---|---|---|---|
| **What it protects** | A specific resource / RG / subscription, against `DELETE` (and writes, if `ReadOnly`) | A specific set of resources and actions, against a set of principals, independent of their RBAC roles | The *shape* of any resource matching the rule, at any scope in the assignment |
| **Can an Owner bypass it directly?** | **Yes** — an Owner can delete the lock, then act (two steps, both logged) | **No** — a deny assignment takes precedence over every role assignment, including Owner; it can only be removed by deleting/updating the object that created it (deployment stack, or the system in the case of managed-app deny assignments) | **No** — Owner has no bypass; only an exemption, an exclusion, or unassigning the policy changes the outcome |
| **Applies to existing resources?** | Yes, immediately, for future operations on them | Yes, for future operations on the managed resources | Evaluated for compliance reporting, but the `Deny` effect itself only blocks *new or updated* requests; it never touches resources at rest |

**A7.2** — The historical answer is **Azure Blueprints**. Its current status is **deprecated** — the preview will not go GA, and Microsoft has announced retirement (11 July 2026), directing customers to the replacement path. The replacement is **Template Specs** (versioned, RBAC-controlled ARM/Bicep artifacts stored in Azure) combined with **Deployment Stacks** (lifecycle management of a resource set plus deny settings that reproduce the blueprint locking behaviour), with policy and RBAC delivered through the normal Azure Policy and role-assignment mechanisms — typically orchestrated as infrastructure-as-code in a landing-zone accelerator. If an exam item still lists Blueprints as an option for this description, it remains the intended answer for that item.

**A7.3** — With `--action-on-unmanage deleteAll`, deleting the stack **deletes every resource the stack manages, and the resource groups it created**, not just the stack object. On a production stack this is a full teardown of the managed footprint in a single command — data stores included, subject only to any locks or deny assignments still in place. `detachAll` (the safe default posture) removes the stack and its deny assignments while leaving all resources running; `deleteResources` deletes managed resources but preserves the resource groups. Because the stack definition carries this setting, the blast radius is decided at deploy time by whoever authored the pipeline, not at delete time by whoever runs the command — which is precisely why it belongs in code review.

---

### Exercise 8

**A8.1** — **Microsoft Purview** answers it: the **Data Map** scans registered sources across Azure, on-premises and other clouds, applies **classifications** from built-in sensitive information types (national/regional ID numbers among them), and the **Data Catalog / Data Estate Insights** surface lets you filter assets by classification and by the region of the source. The recurrence is prevented on the Azure side by an Azure Policy **`Deny`** effect on allowed locations (built-in `Allowed locations`, optionally scoped to the data-service resource types) assigned at management-group scope — plus, for existing resources, a `DeployIfNotExists`/`Modify` remediation or a migration campaign, since `Deny` does not move anything that already exists.

**A8.2** —
- **Trust Center** (<https://www.microsoft.com/trust-center>) — the public, overview-level site describing Microsoft's approach to security, privacy, compliance and transparency. No score, no downloads under NDA; it is the front door.
- **Service Trust Portal** (<https://servicetrust.microsoft.com>) — the authenticated repository of **third-party audit reports and certifications**: SOC 1/2/3, ISO 27001/27018, FedRAMP packages, penetration test summaries, and data protection resources. This is where an auditor's evidence request is satisfied.
- **Compliance Manager** (in the Microsoft Purview portal) — the **risk assessment tool that produces a compliance score**, decomposes frameworks into improvement actions split between Microsoft-managed and customer-managed controls, and tracks evidence and assignment of those actions.

**A8.3** — **No.** Microsoft-managed controls are implemented and audited by Microsoft; their points are already credited to your score and you cannot act on them. You can only raise your score by completing **customer-managed** (and shared) improvement actions. This is the shared responsibility model made numeric: a portion of your compliance posture is inherited from the cloud provider — physical security, hypervisor patching, datacentre operations — and a portion is irreducibly yours: identity configuration, data classification, access reviews, encryption key management, retention policy. Compliance Manager's value is precisely that it makes the boundary explicit rather than assumed.

**A8.4** — It shows that **Microsoft Purview is a data-estate product, not an Azure-resource product**. Its scope is wherever the organisation's data lives — Azure, AWS, GCP, on-premises SQL Server and file shares (via a self-hosted integration runtime), Power BI, and Microsoft 365 — because the governance question ("where is our sensitive data, who owns it, where does it flow") does not respect cloud boundaries. Azure Policy, by contrast, evaluates **Azure Resource Manager resources** and only those; the closest it comes to leaving Azure is via **Azure Arc**, which projects non-Azure servers and Kubernetes clusters into ARM so that policy can then evaluate them as Azure resources.

**A8.5** — Azure Policy operates on the **control plane**: it sees the ARM representation of a resource — its type, location, SKU, tags and configuration properties. It can determine that a storage account exists, is in `eastus`, and permits public blob access. It structurally cannot see **what is inside** that account, because blob contents never traverse ARM. Microsoft Purview operates on the **data plane**: it authenticates to the source (managed identity, service principal or key), reads schemas and samples content, and pattern-matches against sensitive information types. The two are complementary and non-overlapping — Policy governs the container, Purview governs the contents — and neither substitutes for the other.

---

### Exercise 9

**A9.1** —

1. **Resource lock** (`CanNotDelete`). Policy cannot protect an existing resource from deletion; RBAC removal would also block legitimate management of the VM. (Note the caveat from A2.3 about "including admins".)
2. **Azure Policy** — built-in `Allowed locations`, `Deny` effect, assigned at the **management group** covering the tenant. Not a lock (locks do not evaluate location), not RBAC (identity-agnostic requirement).
3. **Microsoft Purview** — Data Map scanning with classification, including on-premises sources via a self-hosted integration runtime. Azure Policy cannot see data-plane content.
4. **Service Trust Portal.** Compliance Manager tracks *your* actions and score; it does not host Microsoft's attestation letters. The Trust Center is overview material.
5. **Microsoft Purview Compliance Manager.** It is the only one of these that produces a score with improvement actions and evidence upload.
6. **Azure Policy** with the **`Modify`** effect, a managed identity, and a **remediation task** with `--resource-discovery-mode ExistingNonCompliant` for the 900 existing accounts. `Deny` would not fix anything that already exists.
7. **Azure RBAC** (withhold or remove the role granting `write` on that scope; optionally a **deny assignment**). This is an identity-scoped requirement — "nobody in group X" — which is exactly what Policy cannot express and RBAC exists for.
8. **Deployment stack with `denySettingsMode: denyWriteAndDelete`** (creating a deny assignment). A `ReadOnly` lock is the near-neighbour but is removable by an Owner and is not tied to the deployment lifecycle.
9. **Azure Policy** with the **`AuditIfNotExists`** effect (or an `Audit`/`DeployIfNotExists` definition assigned with `enforcementMode: DoNotEnforce`). The requirement is explicitly "report, do not block".
10. **Azure Policy initiative** (policy set definition), assigned per subscription — ideally inherited from a management group.

**A9.2** —
- **Item 1 — resource lock.** Enforced by ARM against a *scope*, applies to **all principals** equally, blocks a specific ARM verb (`DELETE`), and is **removable by anyone with `Microsoft.Authorization/locks/delete`**.
- **Item 7 — RBAC.** Enforced by the authorisation layer against a **principal**, default-deny with explicit grants, and it is the only one of the three that can express "these people, not those people".
- **Item 8 — deny assignment.** Enforced by the authorisation layer, **overrides every role assignment including Owner**, is scoped to the resources a deployment stack manages, and is removable only through the object that created it.

They are non-interchangeable because each answers a different question: the lock answers *"may this verb run against this resource at all?"*, RBAC answers *"is this identity permitted?"*, and the deny assignment answers *"is this resource under managed lifecycle control that no role may override?"* Azure Policy — the fourth mechanism — answers a question none of them touch: *"is the resulting resource configuration acceptable?"*

</details>