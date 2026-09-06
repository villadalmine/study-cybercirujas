# AZ-900 · Tema 3.2 — Características y herramientas de Azure para gobernanza y cumplimiento

**Peso en el examen: 8.33%** · Dominio: *Describir la administración y la gobernanza de Azure* · Versión 2026-07-20

> **Nota sobre el alcance.** Los puntos de la guía de estudio para este objetivo son *Microsoft Purview*, *Azure Policy* y *resource locks*. Revisiones anteriores del AZ-900 también evaluaban el *Service Trust Portal*, y sigue siendo la respuesta canónica a "¿de dónde saco el informe SOC 2 de Microsoft?", así que se cubre acá en §7. Todo lo que va más allá de esos puntos está marcado como **[fuera del alcance del examen]** y existe porque te van a pedir construir esto en producción mucho antes de que te lo pregunten en un examen.

---

## 1. El problema de producción: RBAC es necesario e insuficiente

### 1.1 El modo de falla que da origen al objetivo

Sos el arquitecto de plataforma de un parque de ~180 suscripciones de Azure repartidas en cuatro unidades de negocio. Los equipos de aplicaciones son `Contributor` sobre sus propias suscripciones — esa fue la decisión deliberada, porque un equipo central que revise cada despliegue es una cola, y una cola es una interrupción esperando una ventana de mantenimiento.

Tres semanas después de la puesta en marcha, una auditoría interna produce esto:

| Hallazgo | Cantidad | ¿RBAC lo impidió? |
|---|---|---|
| Cuentas de storage con `allowBlobPublicAccess: true` | 31 | No |
| Recursos sin etiqueta `costCenter` | 4.118 | No |
| Recursos PaaS sin diagnostic settings (sin rastro de auditoría) | 907 | No |
| VMs desplegadas en `brazilsouth` contra un compromiso de residencia de datos | 12 | No |
| Un workspace de Log Analytics de producción eliminado por un `terraform destroy` contra el workspace equivocado | 1 | No |

Cada una de esas acciones fue ejecutada por un principal que estaba **correctamente autorizado**. RBAC respondió su pregunta — *¿puede esta identidad ejecutar `Microsoft.Storage/storageAccounts/write`?* — correctamente, todas las veces. RBAC no tiene vocabulario para las preguntas que la auditoría está haciendo en realidad:

- *¿Qué forma puede tener el recurso?* (`allowBlobPublicAccess` debe ser `false`)
- *¿Qué debe existir junto a él?* (un diagnostic setting que envíe al workspace de plataforma)
- *¿Qué nunca puede destruirse, por nadie, sin importar el rol?* (la VNet hub, el circuito ExpressRoute, el workspace compartido)

Esos son tres planos de control distintos, y Azure te da una primitiva diferente para cada uno.

### 1.2 Los cuatro planos de la gobernanza en Azure

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

**La propiedad arquitectónica más importante:** Azure Policy y los locks se evalúan en el **plano de control de Azure Resource Manager (ARM)**, por el que pasa absolutamente todo camino hacia Azure — portal, CLI, PowerShell, Terraform, Bicep, ARM REST, SDKs, Azure DevOps, GitHub Actions. No hay puerta trasera. Una policy `Deny` asignada en un management group se aplica contra un Owner de suscripción ejecutando `az` desde una laptop igual que contra un service principal dentro de un pipeline.

**La limitación más importante:** ninguna de estas primitivas ve el **plano de datos**. Un lock sobre una cuenta de storage no impide `az storage blob delete`. Una policy sobre un servidor SQL no impide `DROP TABLE`. La gobernanza de plano de control termina en `management.azure.com`. Esta distinción se evalúa en el examen, y es el origen de la mayoría de las sorpresas en producción (§8.3).

### 1.3 Alcance y herencia — el sustrato sobre el que se apoya todo

La gobernanza se aplica sobre un **scope**, y los scopes forman un árbol estricto:

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

Reglas que tenés que internalizar:

- Las asignaciones **se heredan hacia abajo** y no pueden anularse hacia arriba. Un scope hijo **no tiene mecanismo para relajar** un `Deny` del padre. No existe un efecto "allow" en Azure Policy — esto es intencional y es lo que hace auditable al modelo.
- La jerarquía de management groups tiene **seis niveles de profundidad** por debajo de la raíz, excluyendo el nivel raíz y el nivel de suscripción. Cada management group tiene exactamente un padre.
- Una suscripción pertenece a exactamente un management group.
- Asigná en el **scope más alto donde la afirmación sea universalmente verdadera**, y usá `notScopes` (exclusiones) o exemptions para las excepciones — no una reasignación en un nivel inferior.

> **Encuadre de examen.** "Querés que una policy aplique a todas las suscripciones actuales *y futuras* de una unidad de negocio." → asignala en el **management group**, no en cada suscripción.

**Referencias:** [Management groups overview](https://learn.microsoft.com/en-us/azure/governance/management-groups/overview) · [Understand scope in Azure Policy](https://learn.microsoft.com/en-us/azure/governance/policy/concepts/scope) · [Azure landing zone design areas](https://learn.microsoft.com/en-us/azure/cloud-adoption-framework/ready/landing-zone/)

---

## 2. Azure Policy — mecánica

### 2.1 El modelo de objetos

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

`policyExemption` es el mecanismo que mantiene la gobernanza sostenible. Deja un registro auditable (`quién`, `por qué`, `hasta cuándo`), mientras que `notScopes` abre un agujero silencioso para siempre. **Preferí exemptions para las excepciones; reservá `notScopes` para exclusiones estructurales** como sacar `mg-sandbox` de una iniciativa que solo aplica a producción.

### 2.2 `mode` — la propiedad que la gente se equivoca

| `mode` | Evalúa | Usalo para |
|---|---|---|
| `All` | Resource groups, suscripciones **y todos los tipos de recurso** | Cualquier cosa dirigida a RGs/suscripciones, o tipos de recurso que no soportan tags/location (p. ej. `Microsoft.Network/routeTables/routes`) |
| `Indexed` | **Solo tipos de recurso que soportan tags y location** | Toda policy de tags, toda policy de location. Usar `All` para una policy de tags produce falsos incumplimientos en recursos hijos que no pueden llevar una tag |
| `Microsoft.Kubernetes.Data` | Admisión en AKS / Kubernetes habilitado por Arc vía Gatekeeper | Pod security, registries permitidos, labels requeridas |
| `Microsoft.KeyVault.Data` | Objetos de Key Vault (certificados, claves, secretos) | Vida útil de certificados, tamaño de clave, claves respaldadas por HSM |
| `Microsoft.Network.Data` | Network groups de Virtual Network Manager | Efecto `addToNetworkGroup` |

### 2.3 Efectos — comparación y compromisos

Los efectos **no** se evalúan en el orden en que están escritos. Orden de evaluación:

```
1. Disabled                     ← short-circuits everything; nothing else is evaluated
2. Append / Modify              ← mutate the incoming request payload
3. Deny                         ← reject the request before the RP sees it
4. Audit                        ← allow, mark non-compliant, write to the compliance store
5. AuditIfNotExists /           ← evaluated AFTER the resource provider returns success,
   DeployIfNotExists              because they inspect *related* resources
```

| Efecto | ¿Bloquea la petición? | Necesita managed identity | Arregla recursos existentes | Modo de falla con el que te vas a topar |
|---|:--:|:--:|:--:|---|
| `Audit` | No | No | No | Acumula en silencio miles de hallazgos que nadie tría. Usalo solo como *etapa 1* |
| `Deny` | **Sí** | No | No | Rompe pipelines con un error opaco salvo que configures `nonComplianceMessages` |
| `DenyAction` | Sí, sobre `delete` (y otras acciones nombradas) | No | No | La alternativa moderna y escalable por scope a los locks puestos a mano; sigue siendo solo plano de control |
| `Append` | No — muta create/update | No | No | **Solo aplica en escritura.** Los recursos existentes quedan intactos y *no* se reportan como no conformes. Mayormente reemplazado por `Modify` |
| `Modify` | No — muta create/update | **Sí** | Sí, vía remediation task | Si a la MI le falta el rol de `roleDefinitionIds` → la remediación falla con `AuthorizationFailed` |
| `AuditIfNotExists` | No | No | No | Una `existenceCondition` escrita contra el scope equivocado reporta todo como conforme en silencio |
| `DeployIfNotExists` (DINE) | No | **Sí** | Sí, vía remediation task | El efecto operativamente más complejo. Ver §8.2 |
| `Disabled` | No | No | No | La forma correcta de aparcar una definición dentro de una iniciativa sin borrarla |
| `Manual` | No | No | No | Basado en atestación; para controles que Azure no puede observar mecánicamente (p. ej. "se hicieron los chequeos de antecedentes") |
| `AddToNetworkGroup` | No | No | n/a | Solo pertenencia dinámica en Azure Virtual Network Manager |

**Doctrina de despliegue.** Nunca asignes un `Deny` nuevo en frío. La secuencia que sobrevive al contacto con los equipos de aplicaciones:

```
enforcementMode = DoNotEnforce   →  observe "would have been denied" for 2 sprints
       ↓
effect = Audit                   →  publish the non-compliance list to owning teams
       ↓
effect = Deny at mg-sandbox      →  canary; resourceSelectors can stage by region
       ↓
effect = Deny at mg-landingzones →  with nonComplianceMessages and a documented exemption path
```

### 2.4 Tiempos de evaluación — los números que explican "no está funcionando"

| Disparador | Latencia |
|---|---|
| Creación/actualización de recurso vía ARM | Sincrónico, en el camino de la petición (`Deny`, `Modify`, `Append`) |
| **Asignación** de policy nueva o modificada | Hasta ~**30 minutos** antes de que el efecto esté activo |
| Escaneo de cumplimiento estándar | Cada **24 horas** |
| Escaneo tras actualizar una definición de policy/iniciativa en una asignación existente | Se dispara automáticamente |
| Escaneo bajo demanda | `az policy state trigger-scan` — de minutos a horas según la amplitud del scope |
| Pull de asignaciones por el add-on de Kubernetes | ~**15 minutos** |
| Reporte de cumplimiento completo del clúster de Kubernetes | ~**15 minutos** (presupuestá ~30 min de punta a punta) |

**Referencias:** [Azure Policy overview](https://learn.microsoft.com/en-us/azure/governance/policy/overview) · [Effects](https://learn.microsoft.com/en-us/azure/governance/policy/concepts/effects) · [Definition structure](https://learn.microsoft.com/en-us/azure/governance/policy/concepts/definition-structure) · [Assignment structure](https://learn.microsoft.com/en-us/azure/governance/policy/concepts/assignment-structure) · [Exemption structure](https://learn.microsoft.com/en-us/azure/governance/policy/concepts/exemption-structure)

---

## 3. Artefactos completos y desplegables

Todo lo que sigue tiene forma de producción y es sintácticamente completo. Las definiciones de Azure Policy son JSON (el formato nativo de ARM); las constraints de Kubernetes y el CI son YAML.

### 3.1 `Deny` — las cuentas de storage no deben permitir acceso público a blobs

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

Dos detalles que importan y que se pasan por alto rutinariamente:

1. La rama `exists: false`. Si una propiedad está ausente del payload, `notEquals` por sí solo **no** hace match — hay que testear la ausencia explícitamente o los recursos creados con versiones de API más viejas se cuelan.
2. `count` con `where` y `current()` es la forma de expresar "ninguno de los elementos de este array hace match" — la sintaxis de cuantificadores sobre arrays. Sin eso no podés parametrizar listas de exclusión dentro de una definición.

### 3.2 `DeployIfNotExists` — diagnostic settings, con todo el cableado de remediación

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

Leyenda de los GUID de rol (JSON no admite comentarios, así que vive acá):

| GUID | Rol integrado | Por qué hace falta |
|---|---|---|
| `749f88d5-cbae-40b8-bcfc-e573ddc772fa` | Monitoring Contributor | Crear `Microsoft.Insights/diagnosticSettings` |
| `92aaf0da-9dab-42b6-94a3-d43ce8d16293` | Log Analytics Contributor | Escribir en el workspace de destino |

`"assignPermissions": true` en el parámetro del workspace le indica al portal que ofrezca una role assignment sobre ese workspace cuando se crea la asignación — necesario cuando el workspace vive en una suscripción *distinta* de la del scope de la asignación, que es la topología normal de una landing zone.

### 3.3 `Modify` — heredar una tag del resource group

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

`4a9ae827-6dc8-4573-8ac7-8239d42aa03f` es **Tag Contributor** — el rol de menor privilegio que puede escribir tags sin otorgar escritura sobre el recurso.

### 3.4 La iniciativa (policy set) que las une

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

`policyDefinitionGroups` es lo que convierte una lista plana de reglas en un **reporte de cumplimiento normativo**: la hoja de compliance de Azure Policy muestra los hallazgos agrupados por control, que es el artefacto que un auditor realmente acepta.

Los dos `policyDefinitionId` con GUID son integrados de Microsoft (`e56962a6…` = *Allowed locations*, `06a78e20…` = *Audit VMs that do not use managed disks*). **Preferí los integrados**: están versionados, probados por Microsoft y mapeados dentro de las iniciativas de cumplimiento normativo.

### 3.5 Bicep — despliegue a nivel de management group con identidad y role assignment

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

`principalType: 'ServicePrincipal'` no es cosmético — si lo omitís, la role assignment falla de forma intermitente con `PrincipalNotFound` porque la replicación de Entra ID todavía no propagó la managed identity recién creada.

### 3.6 Equivalente en Terraform

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

> **Riesgo específico de Terraform.** Un lock `CanNotDelete` sobre un recurso que administra Terraform hace que `terraform destroy` y cualquier cambio que requiera reemplazo fallen con `ScopeLocked`. Ese es justamente el punto — pero significa que los locks y el state de Terraform deben pertenecer al mismo equipo, o vas a producir un archivo de state permanentemente desalineado.

---

## 4. Resource locks — el plano de ciclo de vida

### 4.1 Los dos niveles de lock

| Nivel de lock | Etiqueta en el portal | Bloquea | Permite |
|---|---|---|---|
| `CanNotDelete` | **Delete** | `DELETE` sobre el recurso | Lectura, y todas las operaciones de escritura/actualización |
| `ReadOnly` | **Read-only** | `DELETE` **y** todos los `PUT`/`PATCH`/**`POST`** | Solo `GET` |

Que `ReadOnly` bloquee `POST` es la cláusula que produce incidentes en producción, porque una cantidad sorprendente de operaciones de *lectura* en Azure están implementadas como `POST`:

| Operación | Verbo HTTP | ¿Bloqueada por `ReadOnly`? |
|---|:--:|:--:|
| `Microsoft.Storage/storageAccounts/listKeys/action` | POST | **Sí** — rompe el explorador de blobs del portal y cualquier SDK que use autenticación por clave |
| `Microsoft.Compute/virtualMachines/start/action` | POST | **Sí** |
| `Microsoft.Compute/virtualMachines/restart/action` | POST | **Sí** |
| `Microsoft.Web/sites/publishxml/action` | POST | **Sí** — rompe el despliegue de App Service |
| `Microsoft.KeyVault/vaults/secrets/read` (plano de datos) | GET sobre `vault.azure.net` | **No** — plano distinto |
| Borrar un blob (plano de datos) | DELETE sobre `blob.core.windows.net` | **No** |

**Doctrina: usá `CanNotDelete` por defecto. Recurrí a `ReadOnly` solo sobre un recurso congelado del que probaste que nadie opera**, como los recursos de una suscripción dada de baja esperando la ventana de retención.

### 4.2 Herencia y precedencia

- Un lock aplicado a nivel de **suscripción**, **resource group** o **recurso padre** es heredado por todos los hijos.
- Cuando aplican múltiples locks, **gana el más restrictivo**. Un `ReadOnly` en el RG más un `CanNotDelete` sobre un recurso da comportamiento `ReadOnly` para ese recurso.
- Un lock es un recurso por derecho propio (`Microsoft.Authorization/locks`), así que aparece en el resource graph y puede inventariarse.
- Borrar un resource group requiere **quitar antes todos los locks que contiene** — incluidos los locks sobre recursos hijos. Por eso `az group delete` sobre un RG bien gobernado falla de una manera que confunde a la gente; ver §8.3.
- Los locks **no** pueden aplicarse a nivel de management group. La protección contra borrado a nivel de management group es la policy `DenyAction` o los deployment stacks.

### 4.3 Permisos

Crear o borrar un lock requiere `Microsoft.Authorization/locks/*`. Solo dos roles integrados lo tienen: **Owner** y **User Access Administrator**.

Esta es la debilidad estructural de los locks: **un lock protege contra el accidente, no contra la intención.** Cualquier Owner puede quitar un lock y después borrar el recurso, en dos llamadas a la API, sin ninguna instancia de aprobación.

### 4.4 La comparación que en realidad te están pidiendo

| | Resource lock | Policy `DenyAction` | `denySettings` de deployment stack | Deny assignment (RBAC) |
|---|---|---|---|---|
| Se aplica a | Recurso, RG, suscripción | Cualquier scope, incluido management group | Recursos administrados por el stack | Cualquier scope |
| ¿Escala a "todos los recursos futuros"? | No — se coloca recurso por recurso | **Sí** | Sí, dentro del stack | Sí |
| Bloquea borrado | Sí | Sí | Sí (`denyDelete`) | Sí |
| Bloquea escritura | Solo `ReadOnly` (también bloquea POST) | No | Sí (`denyWriteAndDelete`) | Sí |
| ¿Un Owner puede saltearlo? | **Sí** — quita el lock | Sí — quita/exime la asignación | Solo mutando el stack | **No** — las deny assignments no son removibles por data actions |
| Creado por | Vos | Vos | El stack, automáticamente | Solo Azure (legado de Blueprints, managed apps, stacks) |
| Mecanismo de excepción | Borrar el lock | Policy exemption (auditada, con vencimiento) | `excludedPrincipals`, `excludedActions` | Definición del stack/managed app |
| Relevancia para el examen | **Central** | Fuera del alcance | Fuera del alcance | Fuera del alcance |

**[fuera del alcance del examen]** Los **deployment stacks** son la respuesta moderna a "protegé todo lo que creó este despliegue, y recolectá como basura lo que deje de crear". Un stack es un recurso ARM que posee un conjunto de recursos; `denySettings` se materializa como **deny assignments**, que — a diferencia de los locks — un Owner no puede simplemente borrar. Este es además el destino de migración de **Azure Blueprints**, que Microsoft deprecó con retiro el **11 de julio de 2026**; el patrón de reemplazo es **Template Specs** (plantillas versionadas y compartibles en el tenant) más **Deployment Stacks** (ciclo de vida + deny) más **Azure Policy** (aplicación continua).

`infra/stacks/hub-network.bicepparam` + despliegue del stack:

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

`--deny-settings-excluded-actions "…/subnets/join/action"` es obligatorio en la práctica: sin eso, las cargas de trabajo spoke no pueden adjuntar NICs a las subnets del hub y todo despliegue con peering falla con errores de deny assignment del estilo `RequestDisallowedByPolicy`.

**Referencias:** [Lock resources to prevent unexpected changes](https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/lock-resources) · [Deployment stacks](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/deployment-stacks) · [Template specs](https://learn.microsoft.com/en-us/azure/azure-resource-manager/templates/template-specs) · [Deny assignments](https://learn.microsoft.com/en-us/azure/role-based-access-control/deny-assignments) · [Azure Blueprints overview (deprecation notice)](https://learn.microsoft.com/en-us/azure/governance/blueprints/overview)

---

## 5. **[fuera del alcance del examen]** Azure Policy para Kubernetes — donde la gobernanza se cruza con CNCF

Esta sección existe porque el objetivo de AZ-900 es la puerta de entrada conceptual al control que realmente vas a operar sobre AKS.

El add-on `azure-policy` instala **Gatekeeper v3** (el admission controller de OPA, un proyecto CNCF) dentro del clúster y traduce las asignaciones de Azure Policy a custom resources `ConstraintTemplate` y `Constraint` de Gatekeeper. El mapeo:

| Concepto de Azure Policy | Concepto de Kubernetes / Gatekeeper |
|---|---|
| Policy definition, `mode: Microsoft.Kubernetes.Data` | `ConstraintTemplate` (Rego en `spec.targets[].rego`) |
| Policy assignment + parámetros | `Constraint` (una instancia del template) |
| `effect: deny` | `enforcementAction: deny` en la constraint |
| `effect: audit` | `enforcementAction: dryrun` |
| Estado de cumplimiento | Resultados de auditoría de Gatekeeper, exportados a Azure Policy cada ~15 min |
| `excludedNamespaces` de la asignación | `spec.match.excludedNamespaces` |

Habilitar e inspeccionar:

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

Después de asignar la iniciativa integrada *Kubernetes cluster pod security restricted standards for Linux-based workloads*:

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

El rechazo que ve un equipo de aplicaciones:

```bash
$ kubectl apply -f deploy/nginx.yaml
Error from server (Forbidden): error when creating "deploy/nginx.yaml": admission
webhook "validation.gatekeeper.sh" denied the request: [azurepolicy-k8sazurev2containerallowedimages-9f2b6d40e1c7a83]
Container image docker.io/library/nginx:1.27 for container web has not been allowed.
Allowed registries: ^(crcontoso\.azurecr\.io|mcr\.microsoft\.com)/.+$
```

**Tabla de compromisos — add-on de Azure Policy vs. Gatekeeper/Kyverno autoadministrados:**

| | Add-on de Azure Policy | Gatekeeper autoadministrado | Kyverno |
|---|---|---|---|
| Autoría de policies | JSON de Azure Policy envolviendo Rego | Rego crudo | YAML (sin Rego) |
| Asignación centralizada multiclúster | **Sí**, vía management group | No — GitOps por clúster | No — GitOps por clúster |
| El cumplimiento se consolida en Azure Policy / Defender for Cloud | **Sí** | No | No |
| Cubre clústeres habilitados por Arc (on-prem, otras nubes) | **Sí** | Sí | Sí |
| Mutación | Efecto `mutate` (el alcance en preview varía) | Mutación de Gatekeeper | **Madura** |
| Ciclo de vida del add-on | Administrado por Microsoft, versión atada a AKS | Vos sos dueño de las actualizaciones | Vos sos dueño de las actualizaciones |
| Latencia para aplicar una regla nueva | ~15 min (pull de la asignación) | Segundos (sincronización GitOps) | Segundos |

**Referencia:** [Understand Azure Policy for Kubernetes clusters](https://learn.microsoft.com/en-us/azure/governance/policy/concepts/policy-for-kubernetes) · [OPA Gatekeeper documentation](https://open-policy-agent.github.io/gatekeeper/website/docs/)

---

## 6. Microsoft Purview — gobernar los *datos*, no el recurso

### 6.1 La distinción que evalúa el examen

> **Azure Policy gobierna recursos. Microsoft Purview gobierna datos.**

Azure Policy puede garantizar que una cuenta de storage sea privada, esté cifrada con una clave gestionada por el cliente, esté en la región correcta y registre en el workspace de plataforma. **No tiene ni idea de si los blobs adentro contienen números de DNI argentinos.** Esa pregunta — *¿qué datos tenemos, dónde están, quién los tocó, están etiquetados y pueden salir?* — es la de Microsoft Purview.

### 6.2 Las familias de soluciones

| Solución de Purview | Qué responde | Disparador típico |
|---|---|---|
| **Unified Catalog / Data Map** | "¿Qué activos de datos existen, cuál es su esquema, de dónde vino esta columna?" — escaneo, clasificación automatizada, linaje, glosario de negocio, data products, calidad de datos | Una plataforma de datos con 40 fuentes y nadie que pueda responder "¿de dónde sale `revenue_eur`?" |
| **Information Protection** | "¿Este documento/archivo está etiquetado como Confidencial, y la etiqueta lo acompaña?" — sensitivity labels, cifrado, marcas de agua | Las etiquetas deben persistir cuando un archivo sale de SharePoint |
| **Data Loss Prevention (DLP)** | "Bloqueá este correo/carga porque contiene 14 números de tarjeta de crédito" | Control de egreso en Exchange, Teams, endpoints y aplicaciones cloud |
| **Data Lifecycle & Records Management** | "Retener 7 años, después borrar; hacerlo inmutable" | Retención regulatoria (SEC 17a-4, borrado GDPR) |
| **Insider Risk Management** | "Este usuario descargó 4.000 archivos dos días después de renunciar" | Señales de empleado saliente y robo de propiedad intelectual |
| **Communication Compliance** | "Escanear comunicaciones internas por conducta indebida en industrias reguladas" | Supervisión FINRA/MiFID |
| **Audit (Standard / Premium)** | "Reconstruir exactamente quién accedió a qué, con retención más larga" | Forense post-incidente |
| **eDiscovery** | "Retención legal, recolección, revisión y exportación para este custodio" | Litigio |
| **Compliance Manager** | "Puntuá nuestra postura contra ISO 27001 / NIST 800-53 / GDPR y decime cuál es la próxima acción de mejora" | Preparación para una auditoría |

Superficie de acceso: el **portal de Microsoft Purview** en `https://purview.microsoft.com`. La huella de recurso de Azure para las capacidades de data map/catálogo es `Microsoft.Purview/accounts`.

### 6.3 Aprovisionamiento y escaneo — secuencia completa

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

El escaneo va a devolver **cero activos** en silencio hasta que la managed identity de Purview tenga lectura de plano de datos sobre el origen. Esta es la falla número uno del onboarding de Purview:

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

Ahora cerrá el círculo con Azure Policy — hacé cumplir que la propia cuenta de Purview esté gobernada:

```bash
$ az policy assignment create \
    --name purview-must-use-private-endpoint \
    --scope "/providers/Microsoft.Management/managementGroups/mg-landingzones" \
    --policy "/providers/Microsoft.Authorization/policyDefinitions/27ea8f46-dc82-4331-99b9-nnnnnnnnnnnn" \
    --params '{"effect":{"value":"Audit"}}' \
    --description "Purview scans traverse data; the control plane must not be internet-reachable."
```

> **El patrón arquitectónico.** Purview *descubre y clasifica*; Azure Policy *hace cumplir la postura del recurso alrededor*. Un parque maduro alimenta los resultados de clasificación de Purview hacia una estrategia de etiquetado (`dataClassification=restricted`), y después escribe definiciones de Azure Policy basadas en esa tag — denegar acceso de red pública en cualquier recurso etiquetado como `restricted`, exigir CMK, exigir private endpoints. Esa es la unión entre los dos objetivos, y es la respuesta a "¿cómo trabajan juntas las herramientas?".

**Referencias:** [Microsoft Purview product overview](https://learn.microsoft.com/en-us/purview/purview) · [Microsoft Purview portal](https://purview.microsoft.com) · [Compliance Manager](https://learn.microsoft.com/en-us/purview/compliance-manager)

---

## 7. Demostrar cumplimiento — cuatro fuentes, cuatro preguntas distintas

Los estudiantes confunden estas constantemente. Responden **preguntas distintas sobre sujetos distintos**:

| Herramienta | Sujeto | Pregunta que responde | Quién produce la evidencia |
|---|---|---|---|
| **Service Trust Portal** (`servicetrust.microsoft.com`) | La nube **de Microsoft** | "¿Azure en sí está certificado ISO 27001 / SOC 2 / PCI DSS / FedRAMP — mostrame el informe del auditor?" | Auditores externos, publicado por Microsoft |
| **Microsoft Trust Center** (`microsoft.com/trust-center`) | La nube de Microsoft | "¿Cuáles son los compromisos de privacidad, seguridad y cumplimiento de Microsoft y dónde se almacenan mis datos?" | Microsoft |
| **Compliance Manager** (en el portal de Purview) | **Tu** tenant + responsabilidad compartida | "¿Cuál es mi *puntaje* de cumplimiento contra GDPR/ISO/NIST, y cuál es la próxima acción de mejora que me toca a mí?" | Vos + controles administrados por Microsoft |
| **Cumplimiento de Azure Policy / panel de cumplimiento normativo de Defender for Cloud** | **Tus** recursos de Azure | "Cuáles de mis 4.118 recursos violan qué control, ahora mismo" | Evaluación continua por máquina |

Datos clave sobre el **Service Trust Portal**:

- Aloja **informes de auditoría** (SOC 1 Type 2, SOC 2 Type 2, SOC 3, ISO 27001/27017/27018/27701, PCI DSS AoC), **resúmenes de pruebas de penetración**, **Data Protection Resources** (soporte para DPIA, documentación de GDPR), FAQs y white papers, y Azure Security & Compliance Blueprints.
- Requiere iniciar sesión con una **cuenta de servicios cloud de Microsoft**; los informes sustantivos están **protegidos por NDA** y no son descargables de forma anónima.
- **My Library** te permite fijar documentos y recibir notificaciones cuando se actualizan — esto es lo que configurás para que tu equipo de GRC se entere cuando aparece un nuevo SOC 2.
- Es Microsoft *informando sobre sí mismo*. No contiene **nada sobre tu configuración**. Si un auditor pide "demostrá que tus cuentas de storage están cifradas", el STP es el artefacto equivocado; la exportación de cumplimiento de Azure Policy es el correcto.

**Responsabilidad compartida, aplicada:** la pregunta del auditor se parte en dos. *"¿El datacenter es físicamente seguro?"* → Service Trust Portal, control de Microsoft. *"¿El acceso público a blobs está deshabilitado en tus 412 cuentas de storage?"* → datos de cumplimiento de Azure Policy, tu control. Entregar un informe del STP para la segunda pregunta es el fracaso de auditoría clásico — y caro.

**Referencias:** [Microsoft Service Trust Portal](https://servicetrust.microsoft.com/) · [Microsoft Trust Center](https://www.microsoft.com/trust-center) · [Compliance offerings home](https://learn.microsoft.com/en-us/compliance/regulatory/offering-home) · [Defender for Cloud regulatory compliance dashboard](https://learn.microsoft.com/en-us/azure/defender-for-cloud/regulatory-compliance-dashboard)

---

## 8. Verificación y diagnóstico de fallas

### 8.1 La escalera de verificación — ejecutá esto en orden

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

### 8.2 Catálogo de fallas — Azure Policy

| Síntoma | Causa raíz | Diagnóstico | Solución |
|---|---|---|---|
| La asignación nueva parece no hacer nada | Las asignaciones tardan hasta **30 min** en volverse efectivas | Revisá `properties.metadata.createdOn` en la asignación; esperá | Esperar, después `az policy state trigger-scan` |
| Todo reporta **"Not started"** | Todavía no corrió ningún ciclo de evaluación en este scope | `az policy state list --filter "complianceState eq 'NotStarted'"` | Disparar un escaneo; verificar que el resource provider esté registrado |
| El `Deny` nunca se dispara pero el recurso se reporta como no conforme | El alias del `if` matchea el recurso *almacenado* pero no el *payload de la petición*, o la propiedad solo se puede establecer después de la creación | `az provider show --namespace Microsoft.X --expand "resourceTypes/aliases"` y confirmar que el alias existe en la versión de API en uso | Combinar `Deny` (sobre el camino modificable) con `DeployIfNotExists`/`Modify` para el resto |
| DINE reporta no conforme para siempre, la remediación "tiene éxito" | La `existenceCondition` testea una propiedad con distinta capitalización/formato del valor almacenado (capitalización de `workspaceId`, barra final) | Traé el recurso relacionado desplegado: `az monitor diagnostic-settings show ...` y compará cada campo de `existenceCondition` | Normalizar; comparar contra el resource ID exactamente como lo devuelve ARM |
| La remediación falla con `AuthorizationFailed` | A la MI de la asignación le falta un rol listado en `roleDefinitionIds`, o el rol se otorgó en un scope más angosto que el recurso | `az role assignment list --assignee <principalId> --all -o table` | Asignar el rol en el scope de la asignación (o más arriba); esperar la propagación de Entra |
| La remediación falla con `PrincipalNotFound` | Role assignment creada en el mismo despliegue que la identidad, antes de la replicación | Volver a ejecutar el despliegue | Definir `principalType: 'ServicePrincipal'`; agregar un reintento |
| Una condición sobre arrays matchea de forma inesperada | Los aliases `[*]` son **existenciales** por defecto: `field: "…/subnets[*].name", equals: "x"` es verdadero si *algún* elemento matchea | Reescribir con la expresión `count` y `where` | Usar `count { value, name, where }` con un `equals 0` / `greaterOrEquals` explícito |
| Una policy de tags marca cientos de recursos hijos | `mode: All` en una policy de tags arrastra tipos que no pueden llevar tags | Inspeccionar la distribución de `resourceType` en los hallazgos | Cambiar `mode` a `Indexed` |
| El estado de cumplimiento es **`Conflict`** | Dos asignaciones aplican operaciones `Append`/`Modify` mutuamente excluyentes sobre el mismo campo | `az policy state list --filter "complianceState eq 'Conflict'"` | Consolidar en una sola iniciativa; quitar la duplicada |
| Un equipo necesita una excepción legítima | — | — | **Exemption, no `notScopes`**: `az policy exemption create --exemption-category Waiver --expires-on 2026-12-31 --description "CHG-8841"` |

Leer bien un error de deny — esto es lo que el equipo de aplicaciones pega en tu canal:

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

`evaluatedExpressions` es todo el diagnóstico: te dice exactamente qué cláusula matcheó y con qué valor. `policyAssignmentScope` te dice con qué management group hablar. Si `nonComplianceMessages` no hubiera estado configurado, el campo `Reasons:` sería genérico y el equipo habría abierto un ticket en vez de resolverlo solo.

### 8.3 Catálogo de fallas — resource locks

```bash
$ az group delete --name rg-connectivity-prod --yes
```

```
(ScopeLocked) The scope '/subscriptions/8c1e.../resourceGroups/rg-connectivity-prod' cannot perform delete operation because following scope(s) are locked: '/subscriptions/8c1e.../resourceGroups/rg-connectivity-prod/providers/Microsoft.Network/virtualNetworks/vnet-hub-weu'. Please remove the lock and try again.
Code: ScopeLocked
```

Encontrá todos los locks que aplican, incluidos los heredados:

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

Inventario de locks a nivel de tenant vía Resource Graph — la consulta para tener en tu runbook:

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

| Síntoma | Causa raíz | Solución |
|---|---|---|
| `ScopeLocked` al borrar un RG | Un lock heredado o de un hijo; el mensaje nombra el scope *bloqueado*, que puede no ser el scope que apuntaste | `az lock list --include-parents`; quitar o escalar |
| El explorador de blobs del portal muestra "Error listing keys" en una cuenta bloqueada | `ReadOnly` bloquea `listKeys` (un POST) | Cambiar a `CanNotDelete`, o usar autenticación de plano de datos con Entra ID (`Storage Blob Data Reader`) en vez de claves |
| Una VM no arranca | `ReadOnly` bloquea `.../start/action` | Cambiar a `CanNotDelete` |
| El despliegue de App Service falla después de agregar un lock | `ReadOnly` bloquea `publishxml` | Cambiar a `CanNotDelete` |
| Un lock "desapareció" | Cualquier Owner puede borrarlo; los locks no proveen instancia de aprobación | Auditar `Microsoft.Authorization/locks/delete` en el Activity Log; pasar a `denySettings` de deployment stack o a policy `DenyAction` para protección duradera |
| El plan de Terraform quiere reemplazar un recurso bloqueado, el apply falla | Comportamiento correcto; el lock está haciendo su trabajo | Quitar el lock bajo control de cambios, aplicar, recrear el lock — o refactorizar para que el cambio sea in situ |

Auditar la eliminación de locks — la consulta de Activity Log sobre la que deberías tener alertas:

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

### 8.4 Gate de CI — atrapar violaciones antes de que lleguen a ARM

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

La retención de artefactos de 400 días es deliberada: esa exportación JSON es la **evidencia de cumplimiento en un punto del tiempo** que pide una auditoría de vigilancia ISO 27001, y tiene que sobrevivir al ciclo anual.

### 8.5 Límites de escala contra los que hay que diseñar

Los diseños de gobernanza fallan a escala de maneras predecibles. Los límites de servicio publicados rigen cuántas definiciones y asignaciones puede contener un scope — chequeá los números vigentes antes de diseñar una jerarquía, y diseñá bien por debajo de ellos:

```bash
$ az policy definition list --management-group mg-contoso --query "length(@)"
187

$ az policy assignment list --scope "/providers/Microsoft.Management/managementGroups/mg-contoso" --query "length(@)"
23
```

Guía práctica que se sostiene sin importar el techo exacto:

- **Asigná iniciativas, no definiciones individuales.** Una asignación de iniciativa lleva cientos de reglas y consume un solo cupo de asignación.
- **Las definiciones personalizadas viven en el management group raíz intermedio**, para que todo scope hijo pueda referenciarlas; las asignaciones viven más abajo.
- **Preferí los integrados.** No cuentan contra tu presupuesto de definiciones personalizadas y los mantienen por vos.
- Mantené el árbol de management groups **poco profundo y estable** — mover suscripciones entre management groups revalúa todo y genera una gran rotación de cumplimiento.

**Referencia:** [Azure subscription and service limits, quotas, and constraints](https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/azure-subscription-service-limits)

---

## 9. Autoevaluación

1. Un Owner de suscripción despliega una VM en `brazilsouth`. Hay una policy *Allowed locations* con efecto `Deny` asignada en el management group padre. ¿Qué pasa, y por qué el Owner no puede anularla?
2. Aplicás un lock `ReadOnly` a una cuenta de storage. Un desarrollador reporta que el portal ya no puede navegar los blobs. Explicá el mecanismo.
3. Una asignación `DeployIfNotExists` muestra 288 Key Vaults no conformes. Esperás 48 horas. El número no cambia. ¿Qué única acción falta?
4. Un auditor pide evidencia de que (a) los datacenters de Azure tienen certificación ISO 27001 y (b) tus cuentas de storage de producción tienen el acceso público deshabilitado. Nombrá la herramienta para cada caso.
5. ¿Cuál es la diferencia operativa entre agregar un scope a los `notScopes` de una asignación y crear una policy exemption para un recurso de ese scope?
6. Tu organización necesita *"nadie, ni siquiera los Owners de suscripción, puede borrar la VNet hub."* ¿Por qué un lock `CanNotDelete` es una respuesta incompleta, y qué cierra la brecha?
7. Microsoft Purview escanea un data lake y no encuentra ningún activo, aunque la cuenta se aprovisionó correctamente. ¿Cuál es la causa más probable?

<details>
<summary>Respuestas</summary>

1. La petición se rechaza en ARM con `RequestDisallowedByPolicy` antes de que el resource provider la vea. Azure Policy se hereda hacia abajo y **no tiene efecto allow** — un scope hijo no puede relajar un `Deny` del padre. El permiso RBAC del Owner es irrelevante; RBAC y Policy son compuertas independientes, y ambas deben pasar.
2. `ReadOnly` bloquea `POST` además de escritura y borrado. El explorador de blobs del portal llama a `Microsoft.Storage/storageAccounts/listKeys/action`, que es un `POST`. Usá `CanNotDelete`, o cambiá el explorador a autenticación con Entra ID vía `Storage Blob Data Reader`.
3. Crear una **remediation task** (`az policy remediation create --resource-discovery-mode ExistingNonCompliant`). DINE y Modify actúan sobre peticiones de creación/actualización; los recursos preexistentes solo se arreglan con una remediation task explícita, que además requiere que la managed identity de la asignación tenga todos los roles de `roleDefinitionIds`.
4. (a) **Service Trust Portal** — los informes de auditoría de terceros que Microsoft publica sobre su propia nube. (b) **Datos de cumplimiento de Azure Policy** (o el panel de cumplimiento normativo de Defender for Cloud) — evaluación continua de *tus* recursos. Compliance Manager puntúa la postura de responsabilidad compartida pero no es la evidencia por recurso.
5. `notScopes` quita de la evaluación un sub-scope entero, de forma permanente y silenciosa, sin registro de por qué. Una **exemption** apunta a recursos específicos, lleva una categoría (`Waiver` | `Mitigated`), una descripción y una fecha `expiresOn`, y muestra el recurso como `Exempt` en lugar de ocultarlo — así que es auditable y se vence sola.
6. Cualquier Owner o User Access Administrator tiene `Microsoft.Authorization/locks/delete` y puede quitar el lock y después borrar la VNet, sin ninguna instancia de aprobación. Cerralo con un **deployment stack** usando `denySettings: denyWriteAndDelete` (materializado como una deny assignment, que los titulares de roles no pueden quitar) y/o una policy `DenyAction` asignada en el management group, más una alerta de Activity Log sobre `Microsoft.Authorization/locks/delete`.
7. A la managed identity de la cuenta de Purview le falta lectura de plano de datos sobre el origen — típicamente `Storage Blob Data Reader` sobre la cuenta de storage. El aprovisionamiento del plano de control tiene éxito independientemente del acceso al plano de datos, así que el escaneo termina con cero activos en lugar de fallar.

</details>

---

## 10. Referencias

**Examen**
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

**Scopes, locks y ciclo de vida**
- Management groups overview — https://learn.microsoft.com/en-us/azure/governance/management-groups/overview
- Lock resources to prevent unexpected changes — https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/lock-resources
- Deployment stacks — https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/deployment-stacks
- Template specs — https://learn.microsoft.com/en-us/azure/azure-resource-manager/templates/template-specs
- Deny assignments — https://learn.microsoft.com/en-us/azure/role-based-access-control/deny-assignments
- Azure Blueprints overview (aviso de deprecación; retiro 11 de julio de 2026) — https://learn.microsoft.com/en-us/azure/governance/blueprints/overview
- Azure subscription and service limits — https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/azure-subscription-service-limits
- Azure landing zone design areas — https://learn.microsoft.com/en-us/azure/cloud-adoption-framework/ready/landing-zone/

**Microsoft Purview**
- Microsoft Purview product overview — https://learn.microsoft.com/en-us/purview/purview
- Microsoft Purview portal — https://purview.microsoft.com
- Microsoft Purview Compliance Manager — https://learn.microsoft.com/en-us/purview/compliance-manager

**Evidencia de cumplimiento**
- Microsoft Service Trust Portal — https://servicetrust.microsoft.com/
- Microsoft Trust Center — https://www.microsoft.com/trust-center
- Microsoft compliance offerings — https://learn.microsoft.com/en-us/compliance/regulatory/offering-home
- Defender for Cloud regulatory compliance dashboard — https://learn.microsoft.com/en-us/azure/defender-for-cloud/regulatory-compliance-dashboard

**CNCF / upstream**
- OPA Gatekeeper documentation — https://open-policy-agent.github.io/gatekeeper/website/docs/