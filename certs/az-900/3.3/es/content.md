# 3.3 — Características y herramientas para gestionar e implementar recursos de Azure

**Certificación:** AZ-900 (Microsoft Azure Fundamentals) · Versión del examen 2026-07-20
**Dominio:** Describir la administración y el gobierno de Azure · **Peso en el examen:** 8.33 %
**Perfil:** Principal Platform Architect / Senior SRE

---

## 1. El problema en producción: ¿quién es dueño de la verdad sobre tu parque de recursos?

Toda acción de control en Azure — un clic en el portal, un comando `az`, un apply de Terraform, una llamada del SDK desde un controlador, una petición REST desde un runner de CI — termina en el **mismo** endpoint: `https://management.azure.com`. Ese endpoint es **Azure Resource Manager (ARM)**, el *plano de control*. No hay puerta lateral. Este único hecho es el centro arquitectónico de este tema, y produce los tres modos de fallo en los que los equipos SRE realmente invierten tiempo:

**Modo de fallo 1 — Deriva por click-ops.** Un ingeniero de guardia redimensiona una VM a las 03:00 desde el portal para que dejen de sonar las alertas. El cambio es real, queda registrado en el Activity Log, y es invisible para el repositorio de Bicep que supuestamente describe ese entorno. Seis semanas después una pipeline ejecuta `az deployment group create` en modo **Complete** y revierte silenciosamente el arreglo — o peor, borra la regla NSG de emergencia que venía con él. El portal es un *cliente*, nunca una fuente de verdad.

**Modo de fallo 2 — Radio de impacto no declarado.** Un cambio "pequeño" en una plantilla altera una propiedad que el proveedor de recursos trata como inmutable. La respuesta de ARM no es "actualizar"; es *borrar y recrear*. En un `Microsoft.Storage/storageAccounts` o un `Microsoft.Sql/servers` eso es un evento de pérdida de datos. La mitigación no es el cuidado; es una **puerta obligatoria de preflight con `what-if`** y **deny settings en los deployment stacks**.

**Modo de fallo 3 — El parque es más grande que Azure.** La infraestructura real son 400 VMs Linux en un datacenter de Frankfurt, 60 servidores Windows en AWS, tres clústeres de Kubernetes on-prem, y solo *entonces* las suscripciones de Azure. Política, parcheo, inventario, RBAC y recolección de logs deben ser uniformes en todos ellos o el reporte de cumplimiento es ficción. **Azure Arc** existe para proyectar esas máquinas no-Azure dentro de ARM como IDs de recurso de primera clase, de modo que un solo motor de políticas, un solo modelo RBAC y un solo lenguaje de consulta (Resource Graph / KQL) lo cubran todo.

Las herramientas de este tema se corresponden una a una con esos problemas:

| Problema | Herramienta | Qué te da realmente |
|---|---|---|
| Descubrimiento, triaje de incidentes, inspección puntual | **Portal de Azure** | Cliente orientado a personas sobre la REST de ARM; sin determinismo, con auditabilidad completa |
| Operaciones imperativas/con scripts, pegamento, break-glass | **Azure CLI (`az`) / Azure PowerShell (`Az`)** | Imperativo, procedural, códigos de salida, JMESPath/objetos para pipelines |
| Shell sin instalación, preautenticado, con herramientas listas | **Azure Cloud Shell** | Contenedor efímero + home persistente opcional en Azure Files |
| Parque declarativo, revisable, idempotente, reproducible | **Plantillas ARM / Bicep / deployment stacks** | Infraestructura como código con grafo de dependencias, vista previa y ciclo de vida |
| Recursos no-Azure y multicloud bajo un mismo plano de control | **Azure Arc** | IDs de recurso ARM, identidad administrada, política y extensiones para híbrido |

---

## 2. Azure Resource Manager: el plano de control en detalle

### 2.1 La tubería de peticiones

Toda petición de escritura a ARM atraviesa una secuencia fija. Conocer este orden es lo que te permite leer un mensaje de error y saber *qué* etapa te rechazó:

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

Dos consecuencias importan operativamente:

- **Policy se evalúa antes que el proveedor de recursos.** Un `RequestDisallowedByPolicy` no es un problema de cuota, capacidad ni sintaxis — nunca se llegó a intentar crear ningún recurso. El payload del error contiene el `policyAssignmentId` y el `policyDefinitionId`; esa es toda tu causa raíz.
- **La mayoría de las escrituras son asíncronas.** ARM devuelve `202` y una URL de sondeo. Un comando de la CLI que retorna rápido no ha terminado; `--no-wait` lo hace explícito, y la ausencia de `--no-wait` significa que la CLI está sondeando por vos.

### 2.2 Ámbitos e IDs de recurso

ARM es jerárquico. Toda operación de administración apunta a uno de cuatro ámbitos, y la herencia fluye hacia abajo para RBAC, Policy y etiquetas (con reglas específicas por tipo):

```
Management group (up to 6 levels below root, tenant-wide)
  └── Subscription        (billing + quota boundary)
        └── Resource group (lifecycle + region-metadata boundary, non-nestable)
              └── Resource
                    └── Extension resource (locks, diagnostic settings, role assignments, Arc extensions)
```

El ID de recurso canónico — la clave primaria de toda la plataforma:

```
/subscriptions/8f4a1c2e-9b7d-4f0a-a6c1-2d3e4f5a6b7c
  /resourceGroups/rg-platform-prod-weu
  /providers/Microsoft.Storage/storageAccounts/platprodx7k2m9
  /blobServices/default
```

Un servidor on-prem habilitado con Arc obtiene un ID exactamente de la misma forma:

```
/subscriptions/8f4a1c2e-.../resourceGroups/rg-arc-prod-weu
  /providers/Microsoft.HybridCompute/machines/node-fra-01
```

Esa simetría es todo el sentido de Arc: una vez que una máquina tiene un ID de ARM, cada mecanismo con ámbito ARM (RBAC, Policy, etiquetas, Resource Graph, Defender for Cloud, Monitor, locks) se le aplica sin modificación.

### 2.3 Proveedores de recursos

Un proveedor de recursos es el microservicio que implementa una familia de recursos. Debe estar **registrado por suscripción** antes de poder desplegar sus tipos. Los proveedores no registrados son uno de los fallos de primer despliegue más comunes en una suscripción nueva.

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

Descubrir versiones de API y ubicaciones válidas para un tipo — el reflejo que reemplaza al adivinar cuando escribís plantillas:

```console
$ az provider show --namespace Microsoft.Storage \
    --query "resourceTypes[?resourceType=='storageAccounts'].apiVersions[0:5]" -o tsv
2024-01-01	2023-05-01	2023-04-01	2023-01-01	2022-09-01
```

### 2.4 Límites y throttling que vas a encontrar a escala

| Límite | Valor | Consecuencia operativa |
|---|---|---|
| Grupos de recursos por suscripción | 980 | El nombrado de la landing zone debe planificarse, no crecer orgánicamente |
| Recursos por grupo de recursos, por tipo | 800 (muchos tipos exentos) | Dividí por ciclo de vida, no por equipo |
| Despliegues en el historial del RG | 800 (ARM poda automáticamente cerca del tope) | Una CI que despliega por commit debe usar nombres únicos + aceptar la poda |
| Tamaño del archivo de plantilla / archivo de parámetros | 4 MB / 4 MB | Descomponer en módulos y plantillas enlazadas |
| Parámetros / variables / recursos / salidas por plantilla | 256 / 256 / 800 / 64 | El límite de salidas duele mucho en plantillas generadas con bucles |
| Peticiones de escritura por suscripción | Token-bucket por región/servicio/principal (cifra documentada heredada: 1.200 escrituras/h) | Leé `x-ms-ratelimit-remaining-subscription-writes` y aplicá backoff |
| Etiquetas por recurso | 50 | La taxonomía de etiquetas debe curarse centralmente |

Observar directamente el presupuesto de throttling:

```console
$ az group show --name rg-platform-prod-weu --debug 2>&1 | grep -i 'ratelimit-remaining'
msrest.http_logger : 'x-ms-ratelimit-remaining-subscription-reads': '11997'
```

Cuando agotás el bucket, ARM devuelve `429 Too Many Requests` con una cabecera `Retry-After`. El comportamiento correcto del cliente es backoff exponencial respetando esa cabecera — nunca un bucle de reintentos apretado, que es como un solo runner de CI le aplica throttling a una suscripción entera para todos los demás consumidores.

---

## 3. Comparación de superficies de administración

| Superficie | Modelo | Idempotente | Auditable como código | Detección de deriva | Mejor uso en producción |
|---|---|---|---|---|---|
| **Portal de Azure** | Apuntar y hacer clic sobre REST | No | No (solo Activity Log) | Ninguna | Descubrimiento, triaje, lectura de métricas, inspección puntual |
| **Azure CLI (`az`)** | Imperativo, Python, multiplataforma, JSON/JMESPath | Solo por comando | Débilmente (los scripts derivan) | Ninguna | Pegamento, break-glass, operaciones día 2, pasos de CI alrededor de IaC |
| **Azure PowerShell (`Az`)** | Imperativo, objetos .NET, nativo de pipeline | Solo por comando | Débilmente | Ninguna | Parques centrados en Windows, reportes con pipeline de objetos |
| **Plantillas ARM (JSON)** | Declarativo | Sí | Sí | vía `what-if` | Artefactos de Marketplace/managed apps, líneas base exportadas |
| **Bicep** | DSL declarativo → transpila a ARM JSON | Sí | Sí | vía `what-if` | IaC por defecto para parques solo-Azure |
| **Deployment stacks** | Declarativo + objeto de ciclo de vida | Sí | Sí | Inventario de recursos gestionados + deny settings | Landing zones, todo lo que no debe editarse a mano |
| **Terraform / OpenTofu** | Declarativo + estado externo | Sí | Sí | `plan` (fuerte) | Multicloud, o donde se requiere detección de deriva basada en estado |
| **Azure Developer CLI (`azd`)** | Envoltorio centrado en la app (Bicep + build + deploy) | Sí | Sí | Hereda de Bicep | Equipos de aplicación que entregan app+infra juntas |
| **REST / SDKs** | Programático | Depende | N/A | Ninguna | Controladores, operadores, tooling de plataforma |

### 3.1 ARM JSON vs Bicep vs Terraform — los trade-offs honestos

| Dimensión | ARM JSON | Bicep | Terraform (AzureRM) |
|---|---|---|---|
| Almacenamiento de estado | **Ninguno** — ARM *es* el estado | **Ninguno** | Archivo de estado externo (contenedor blob + lease) — debe asegurarse y respaldarse |
| Soporte día-0 de APIs nuevas de Azure | Inmediato | Inmediato | Va por detrás de las versiones del provider (mitigado por el provider `azapi`) |
| Calidad de la vista previa | `what-if` (buena, algo de ruido) | `what-if` (mismo motor) | `plan` (excelente, pero solo para recursos conocidos por el estado) |
| Eliminación de recursos removidos | Modo Complete (brusco) o stacks (preciso) | Igual | `plan`/`apply` los elimina de forma natural |
| Multicloud | No | No | Sí |
| Legibilidad | Pobre (sopa de strings `[concat(...)]`) | Buena (tipado, IntelliSense, módulos) | Buena |
| Manejo de secretos | Referencia a Key Vault en el archivo de parámetros | Referencia a Key Vault / `getSecret()` | El archivo de estado puede contener secretos — cifrar en reposo |
| Atomicidad ante fallos | Parcial (por recurso); sin rollback salvo `rollbackToLastSuccessful` | Igual | Parcial; el estado puede desincronizarse |
| Costo de aprendizaje | Alto | Bajo–medio | Medio |

**Regla del arquitecto:** Bicep para líneas base de plataforma solo-Azure (no hay estado que perder, no hay retraso del provider). Terraform cuando la misma pipeline también deba crear DNS en Cloudflare, repos de GitHub e IAM de AWS. Nunca ambos para el mismo recurso — la propiedad dual garantiza una pelea por la deriva.

### 3.2 Modos de despliegue — el interruptor más peligroso de ARM

| Modo | Recursos en la plantilla | Recursos en el RG pero **no** en la plantilla | Disponible en |
|---|---|---|---|
| **Incremental** (por defecto) | Creados o actualizados | **Se dejan intactos** | RG, suscripción, MG, tenant |
| **Complete** | Creados o actualizados | **BORRADOS** | Solo ámbito de grupo de recursos |
| **Validate** | No se despliega nada; se verifica plantilla + preflight | Intactos | Todos los ámbitos |

```console
# Incremental (default) — safe, additive, cannot delete
$ az deployment group create -g rg-platform-prod-weu -f main.bicep --mode Incremental

# Complete — deletes everything in the RG that the template does not declare
$ az deployment group create -g rg-platform-prod-weu -f main.bicep --mode Complete --confirm-with-what-if
```

El modo Complete es la herramienta correcta para imponer "este grupo de recursos contiene exactamente esto y nada más" — y también es la forma en que los equipos borran producción. Nunca lo ejecutes sin `--confirm-with-what-if` o sin un artefacto de `what-if` revisado en la pipeline.

### 3.3 Deployment stacks — el ciclo de vida como objeto de primera clase

Un deployment stack (`Microsoft.Resources/deploymentStacks`) es un recurso que **posee** un conjunto de recursos gestionados. Reemplaza al modo Complete con semántica explícita y revisable, y agrega *deny assignments* para que las personas no puedan editar a mano en el portal los recursos gestionados por el stack.

| Ajuste | Valores | Significado |
|---|---|---|
| `--action-on-unmanage` | `detachAll` / `deleteResources` / `deleteAll` | Qué ocurre con los recursos eliminados de la plantilla o cuando se borra el stack |
| `--deny-settings-mode` | `none` / `denyDelete` / `denyWriteAndDelete` | Deny assignment aplicada a los recursos gestionados |
| `--deny-settings-excluded-principals` | object IDs | Identidades break-glass (p. ej. el propio SPN de la pipeline) |
| `--deny-settings-apply-to-child-scopes` | flag | Extiende la deny assignment a los recursos hijos |

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

Inspeccionar lo que el stack cree que posee:

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

Un ingeniero que ahora intente borrar esa cuenta de almacenamiento desde el portal recibe `RequestDisallowedByAzure` / una denegación por deny assignment — aplicación efectiva, no documentación.

---

## 4. Manifiestos de infraestructura completos

### 4.1 `main.bicep` — línea base de plataforma (ámbito de grupo de recursos, sin recortes)

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

### 4.2 `main.prod.bicepparam` — archivo de parámetros tipado

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

### 4.3 `bicepconfig.json` — el linter como puerta de merge

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

### 4.4 Plantilla ARM equivalente (JSON) — completa y desplegable

Bicep transpila exactamente a esta forma. Leela una vez para poder depurar una plantilla compilada en un log de pipeline; después escribí en Bicep.

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

Fijate en las dos diferencias estructurales respecto de Bicep: **`dependsOn` explícito** (Bicep lo infiere de las referencias simbólicas) y las **funciones de string `reference()` / `resourceId()`** en lugar de acceso tipado a propiedades. Esas dos son la razón por la que el JSON escrito a mano es propenso a errores a escala.

### 4.5 Bicep con ámbito de suscripción — el propio grupo de recursos

Los grupos de recursos no pueden crearse desde una plantilla con ámbito de grupo de recursos. Este es el bootstrap estándar:

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

> **Restricción relevante para el examen:** los despliegues con ámbito de suscripción, grupo de administración y tenant admiten **solo modo Incremental**. El modo Complete existe exclusivamente en el ámbito de grupo de recursos.

### 4.6 Pipeline CI/CD — GitHub Actions con federación de identidad de carga de trabajo de Entra ID (sin secretos)

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

Dos detalles de producción que vale la pena interiorizar: `set -o pipefail` (una pipeline que se traga un código de salida distinto de cero reporta verde sobre un despliegue fallido), y la **puerta de eliminación** explícita — la salida de `what-if` solo es útil si algo legible por máquina actúa sobre ella.

---

## 5. Superficies de línea de comandos

### 5.1 Azure CLI vs Azure PowerShell

| Aspecto | Azure CLI (`az`) | Azure PowerShell (módulo `Az`) |
|---|---|---|
| Runtime | Python | PowerShell 7+ (.NET) |
| Salida | JSON por defecto; `table`, `tsv`, `yaml`, `none` | Objetos .NET |
| Filtrado | JMESPath (`--query`) | `Where-Object` / `Select-Object` |
| Plataformas | Linux, macOS, Windows, Cloud Shell, contenedores | Las mismas |
| Idiomático para | Pipelines de Bash, contenedores, CI centrada en Linux | Parques Windows, reportes con pipeline de objetos |
| Instalación | `apt`/`dnf`/`brew`/MSI | `Install-Module -Name Az -Scope CurrentUser` |
| Autenticación | `az login`, `az login --identity`, `--service-principal`, `--federated-token` | `Connect-AzAccount [-Identity]` |

Operaciones equivalentes lado a lado:

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

JMESPath es la habilidad de la CLI que separa a los operadores de los usuarios:

```console
$ az vm list --query "[?powerState=='VM running' && storageProfile.osDisk.osType=='Linux'].{name:name, rg:resourceGroup, size:hardwareProfile.vmSize}" -o table

Name              Rg                       Size
----------------  -----------------------  ---------------
app-prod-weu-01   rg-app-prod-weu          Standard_D4as_v5
app-prod-weu-02   rg-app-prod-weu          Standard_D4as_v5
ingress-prod-01   rg-net-prod-weu          Standard_D2as_v5
```

### 5.2 Azure Cloud Shell — arquitectura

Cloud Shell es un shell alojado en el navegador y preautenticado (Bash o PowerShell), accesible desde el portal, `shell.azure.com`, la app móvil de Azure, VS Code y el sitio de documentación. Arquitectónicamente:

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

Propiedades operativas relevantes tanto para el examen como para producción:

| Propiedad | Comportamiento |
|---|---|
| Costo de cómputo | **Gratis** — solo pagás la cuenta de almacenamiento que respalda la persistencia |
| Persistencia | Solo `$HOME` (dentro de la imagen montada) sobrevive; el resto del contenedor se descarta |
| Modo efímero | Las sesiones pueden ejecutarse **sin cuenta de almacenamiento**; no persiste nada entre sesiones |
| Timeout por inactividad | La sesión termina tras ~20 minutos sin interacción |
| Autenticación | Hereda la identidad del usuario autenticado; sin manejo de credenciales |
| Shells | `bash` y `pwsh`, intercambiables en cualquier momento |
| Aislamiento de red | Puede desplegarse dentro de una VNet (Cloud Shell privado) vía Azure Relay |
| Transferencia de archivos | Subida/descarga desde la barra de herramientas del portal, o `clouddrive` |

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

**Dónde gana Cloud Shell:** acceso break-glass desde cualquier dispositivo sin instalación local, e identidad *preautenticada* — sin credenciales de larga vida en una laptop. **Dónde pierde:** el timeout de 20 minutos por inactividad mata operaciones largas (usá `nohup`/`tmux` dentro de la sesión, o mejor, corré los trabajos largos desde CI), y no es un agente de build — no diseñes pipelines alrededor de él.

---

## 6. Azure Arc: extender el plano de control más allá de Azure

### 6.1 Qué hace Arc realmente

Arc proyecta dentro de ARM un recurso que Microsoft no hospeda, dándole un ID de recurso, una identidad administrada, etiquetas, RBAC, aplicabilidad de políticas y visibilidad en Resource Graph. **No** mueve cargas de trabajo, **no** requiere conectividad entrante y **no** toma control del ciclo de vida de la máquina.

| Recurso habilitado con Arc | Tipo ARM | Capacidades que habilita |
|---|---|---|
| **Servidores** (Windows/Linux, on-prem, AWS, GCP) | `Microsoft.HybridCompute/machines` | Inventario, etiquetas, RBAC, Azure Policy + Machine Configuration, extensiones (AMA, Defender, Custom Script), Update Manager, run-command, SSH-over-Arc, identidad administrada |
| **Kubernetes** (cualquier clúster conforme a CNCF) | `Microsoft.Kubernetes/connectedClusters` | GitOps (Flux v2), extensiones de clúster, Azure Policy para Kubernetes (Gatekeeper), Container Insights, Cluster Connect, RBAC con Entra ID, custom locations |
| **SQL Server** | `Microsoft.AzureArcData/sqlServerInstances` | Inventario, evaluación de mejores prácticas, Defender for SQL, Purview |
| **Servicios de datos** (SQL MI, PostgreSQL) | `Microsoft.AzureArcData/*` | Motores de datos PaaS de Azure sobre tu propio Kubernetes |
| **VMware vSphere / SCVMM / Azure Local** | `Microsoft.ConnectedVMwarevSphere/*`, … | Ciclo de vida de VMs autoservicio a través de ARM |

> **Nota sobre costos:** las capacidades centrales del plano de control de Arc (onboarding, inventario, etiquetas, Resource Graph, Azure Policy / guest configuration) no tienen cargo para servidores y Kubernetes habilitados con Arc; los servicios de valor añadido apilados encima (planes de Defender for Cloud, ingesta de Log Analytics, Update Manager para servidores Arc, servicios de datos habilitados con Arc) sí se facturan. Confirmá siempre contra la página de precios vigente antes de comprometer un diseño.

### 6.2 Servidores habilitados con Arc: arquitectura del agente

El **Azure Connected Machine agent** (`azcmagent`) instala tres componentes que cooperan:

| Componente | Proceso | Rol |
|---|---|---|
| **HIMDS** (Hybrid Instance Metadata Service) | `himds` | Endpoint local de metadatos en `127.0.0.1:40342`; emite tokens de identidad administrada; mantiene la identidad de dispositivo de Entra ID y el heartbeat |
| **Agente de Guest Configuration** | `gcad` / `gc_arc_service` | Evalúa y remedia Machine Configuration (asignaciones guest de Policy) |
| **Extension Manager** | `extd` / `gcarcservice` | Instala y gestiona extensiones de VM (Azure Monitor Agent, Defender, Custom Script, …) |

Requisitos de red solo salientes (TCP 443, sin puertos entrantes, con soporte de proxy y Private Link):

```
login.microsoftonline.com          → Entra ID token acquisition
management.azure.com               → ARM control plane
*.his.arc.azure.com                → Hybrid Identity Service (agent heartbeat, identity)
*.guestconfiguration.azure.com     → Machine Configuration
packages.microsoft.com             → agent/extension packages
*.blob.core.windows.net            → extension artifacts
```

Incorporar un host Linux:

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

Verificar el estado en el host:

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

La misma máquina, ahora consultable desde Azure exactamente como una VM nativa:

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

Ese `identity.principalId` es una identidad administrada asignada por el sistema real de Entra ID: el servidor on-prem ya puede autenticarse contra Key Vault o Storage sin ningún secreto almacenado.

### 6.3 Kubernetes habilitado con Arc y GitOps

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

Los diez agentes marcan **hacia afuera**; no hace falta ninguna regla de firewall entrante, y `clusterconnect-agent` es lo que después permite llegar con `kubectl` a través de Azure a un clúster detrás de NAT.

Conectar Flux v2 GitOps para que el clúster se reconcilie desde Git en lugar de desde un `kubectl apply` humano:

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

La misma configuración de GitOps expresada declarativamente en Bicep — de modo que la *propia configuración de administración* quede bajo IaC:

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

El contenido del repositorio Git que Flux reconcilia — manifiestos de Kubernetes completos y válidos:

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

Alcanzar el API server de ese clúster privado a través de Azure — sin VPN, sin endpoint público:

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

## 7. Verificación y diagnóstico de fallos

### 7.1 La escalera de preflight

Ejecutá estos pasos en orden; cada peldaño es más barato que el siguiente y atrapa una clase distinta de fallo.

| Peldaño | Comando | Qué atrapa |
|---|---|---|
| 1. Compilar | `az bicep build --file main.bicep` | Sintaxis, errores de tipo, símbolos sin resolver |
| 2. Lint | `az bicep build` con las reglas de `bicepconfig.json` en `error` | Ubicaciones hardcodeadas, secretos en salidas, identificadores inestables |
| 3. Validar | `az deployment group validate` | Esquema, enlace de parámetros, RBAC, preflight del proveedor (cuota, disponibilidad de SKU, conflictos de nombre) |
| 4. What-if | `az deployment group what-if` | Creaciones, borrados, modificaciones a nivel de propiedad, operaciones de **replace** |
| 5. Desplegar | `az deployment group create --confirm-with-what-if` | La realidad |

### 7.2 Leer la salida de `what-if`

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

Leelo como un SRE lee un `terraform plan`:

- `~ sku.name: "Standard_LRS" => "Standard_ZRS"` — **la conversión de SKU en el sitio no está soportada para cuentas de almacenamiento existentes**; ARM va a fallar esto en el proveedor, o en otros tipos de recurso disparará silenciosamente un replace. `what-if` te dice la *intención*, no siempre el *mecanismo*. Cuando una modificación toca una propiedad inmutable, verificá contra la documentación del proveedor de recursos antes de mergear.
- `properties.allowSharedKeyAccess: true => false` — un cambio de endurecimiento correcto que va a romper a todo consumidor que todavía use claves de cuenta. Este es exactamente el tipo de línea que un revisor debe ver en el PR, que es por lo que la pipeline de §4.6 la publica como comentario.
- **Ruido:** algunos proveedores devuelven valores de propiedad normalizados que difieren de la plantilla, produciendo líneas `~` fantasma. Usá `--result-format FullResourcePayloads` para inspeccionar el antes/después crudo, y nunca suprimas el ruido eliminando la puerta.

### 7.3 Diagnosticar un despliegue fallido

```console
$ az deployment group create -g rg-platform-prod-weu -f infra/main.bicep -p infra/main.prod.bicepparam
Deployment failed. Correlation ID: 3a7f1e92-6c48-4b05-9d3f-8e1a72c40b56.
{
  "code": "DeploymentFailed",
  "message": "At least one resource deployment operation failed. Please list deployment operations for details."
}
```

El mensaje es deliberadamente genérico. El error real está en las **operaciones de despliegue**, un nivel más abajo:

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

Correlacioná a través de todo el plano de control usando el correlation ID — esto vincula el despliegue de ARM con cada operación aguas abajo del proveedor:

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

### 7.4 Tabla de triaje de códigos de error

| Código | HTTP | Causa raíz | Acción |
|---|---|---|---|
| `InvalidTemplate` | 400 | Error de expresión/tipo/esquema | `az bicep build`; revisá la aridad de las funciones y los destinos de `dependsOn` |
| `InvalidTemplateDeployment` | 400 | El proveedor rechazó el preflight (SKU, región, característica no habilitada) | Leé el `details[]` interno; verificá la disponibilidad regional del SKU |
| `AuthorizationFailed` | 403 | Al principal le falta la acción RBAC requerida | `az role assignment list --assignee <id> --scope <scope>` |
| `RequestDisallowedByPolicy` | 403 | Efecto Deny de Azure Policy | El error interno nombra la asignación y la definición; corregí el recurso o pedí una exención |
| `ScopeLocked` | 409 | Lock `CanNotDelete` / `ReadOnly` en el ámbito o por encima | `az lock list --resource-group <rg>` |
| `DeploymentActive` | 409 | Ya se está ejecutando otro despliegue con el mismo nombre | Usá nombres de despliegue únicos (`main-${{ github.run_id }}`) |
| `StorageAccountAlreadyTaken` | 409 | Colisión de nombre globalmente único | Derivá los nombres con `uniqueString()` |
| `QuotaExceeded` / `SkuNotAvailable` | 400/409 | Cuota de vCPU de la suscripción o capacidad en esa región/zona | `az vm list-usage -l westeurope`; pedí cuota o cambiá de SKU/región |
| `ResourceNotFound` / `ParentResourceNotFound` | 404 | Dependencia implícita faltante u orden incorrecto | Agregá `dependsOn` / usá referencias simbólicas en Bicep |
| `MissingSubscriptionRegistration` | 409 | Proveedor de recursos no registrado | `az provider register --namespace <ns> --wait` |
| `DeploymentQuotaExceeded` | 429 | >800 despliegues en el historial del RG | Podá el historial; ARM también poda automáticamente |
| `TooManyRequests` | 429 | Throttling de ARM | Respetá `Retry-After`; aplicá backoff exponencial |

Recuperación al último estado bueno cuando un despliegue parcial deja el RG inconsistente:

```console
$ az deployment group create \
    --resource-group rg-platform-prod-weu \
    --name main-recovery \
    --template-file infra/main.bicep \
    --parameters infra/main.prod.bicepparam \
    --rollback-on-error
```

### 7.5 Verificación de todo el parque con Azure Resource Graph (KQL)

Resource Graph consulta el índice de recursos de ARM en todas las suscripciones del tenant en segundos — la única forma sensata de responder "¿todo el parque cumple?".

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

Encontrar recursos creados fuera de IaC — el detector de deriva:

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

### 7.6 Diagnósticos específicos de Arc

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

Para Kubernetes habilitado con Arc:

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

## 8. Síntesis orientada al examen

| Afirmación que evalúa AZ-900 | Respuesta correcta |
|---|---|
| El único servicio por el que pasan **todas** las peticiones de administración de Azure | Azure Resource Manager |
| Lenguaje de las plantillas ARM | JSON (declarativo) |
| Lenguaje específico de dominio que transpila a ARM JSON | Bicep |
| Modo de despliegue por defecto | Incremental |
| Modo que borra los recursos que no están en la plantilla | Complete (solo ámbito de grupo de recursos) |
| Previsualizar el efecto de un despliegue sin aplicarlo | `what-if` |
| Shell preautenticado basado en navegador con `az`, `Az`, `kubectl`, `terraform` | Azure Cloud Shell |
| Shells que ofrece Cloud Shell | Bash y PowerShell |
| Mecanismo de persistencia de Cloud Shell | Recurso compartido de Azure Files montado en `$HOME/clouddrive` (también hay sesiones efímeras) |
| Costo de cómputo de Cloud Shell | Gratis; solo pagás el almacenamiento de respaldo |
| Extiende la administración de Azure (RBAC, Policy, etiquetas, Monitor) a on-prem y otras nubes | Azure Arc |
| Familias de recursos soportadas por Arc | Servidores, Kubernetes, SQL Server, servicios de datos, VMware vSphere / SCVMM / Azure Local |
| Requisito de red de Arc | Solo HTTPS saliente (443) — sin puertos entrantes |
| Consulta de recursos entre suscripciones a escala | Azure Resource Graph (KQL) |
| Beneficios clave de IaC frente a clics en el portal | Repetibilidad, idempotencia, control de versiones, revisión por pares, prevención de deriva, recuperación ante desastres |
| Dónde se declaran las dependencias en ARM JSON | `dependsOn` (Bicep las infiere de las referencias simbólicas) |

**Tres distinciones que los estudiantes suelen equivocar:**

1. **Azure Arc ≠ Azure Stack.** Arc *administra* hardware que ya poseés desde el plano de control de Azure; Azure Stack (HCI/Hub/Edge) *ejecuta servicios de Azure* sobre hardware en tu datacenter. Arc agrega administración, no cómputo.
2. **El portal, la CLI, PowerShell y las plantillas no son alternativas a ARM.** Todos son clientes *de* ARM. Hay un solo plano de control y muchos front ends.
3. **`what-if` no es `validate`.** `validate` comprueba que la plantilla *podría* enviarse (esquema, RBAC, preflight del proveedor). `what-if` calcula el *delta* entre el estado declarado y el real. Las pipelines de producción ejecutan ambos.

---

## 9. Referencias

- Microsoft Learn — guía de estudio de AZ-900: https://learn.microsoft.com/en-us/credentials/certifications/resources/study-guides/az-900
- Introducción a Azure Resource Manager: https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/overview
- Proveedores de recursos y tipos de recurso: https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/resource-providers-and-types
- Modos de despliegue de ARM (Incremental / Complete): https://learn.microsoft.com/en-us/azure/azure-resource-manager/templates/deployment-modes
- What-if de plantillas ARM: https://learn.microsoft.com/en-us/azure/azure-resource-manager/templates/deploy-what-if
- Introducción a Bicep: https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/overview
- Archivos de parámetros de Bicep (`.bicepparam`): https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/parameter-files
- Linter de Bicep y `bicepconfig.json`: https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/linter
- Deployment stacks: https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/deployment-stacks
- Template specs: https://learn.microsoft.com/en-us/azure/azure-resource-manager/templates/template-specs
- Ámbitos de despliegue (suscripción / grupo de administración / tenant): https://learn.microsoft.com/en-us/azure/azure-resource-manager/templates/deploy-to-subscription
- Límites de suscripción y servicio de Azure: https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/azure-subscription-service-limits
- Límites de peticiones y throttling de ARM: https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/request-limits-and-throttling
- Solucionar errores comunes de despliegue en Azure: https://learn.microsoft.com/en-us/azure/azure-resource-manager/troubleshooting/common-deployment-errors
- Encontrar códigos de error en las operaciones de despliegue: https://learn.microsoft.com/en-us/azure/azure-resource-manager/troubleshooting/find-error-code
- Documentación de Azure CLI: https://learn.microsoft.com/en-us/cli/azure/
- Tutorial de consultas JMESPath en Azure CLI: https://learn.microsoft.com/en-us/cli/azure/query-azure-cli
- Documentación de Azure PowerShell: https://learn.microsoft.com/en-us/powershell/azure/
- Introducción a Azure Cloud Shell: https://learn.microsoft.com/en-us/azure/cloud-shell/overview
- Almacenamiento persistente de Cloud Shell: https://learn.microsoft.com/en-us/azure/cloud-shell/persisting-shell-storage
- Características y herramientas de Cloud Shell: https://learn.microsoft.com/en-us/azure/cloud-shell/features
- Introducción a Azure Arc: https://learn.microsoft.com/en-us/azure/azure-arc/overview
- Introducción a los servidores habilitados con Azure Arc: https://learn.microsoft.com/en-us/azure/azure-arc/servers/overview
- Arquitectura del Connected Machine agent: https://learn.microsoft.com/en-us/azure/azure-arc/servers/agent-overview
- Requisitos de red de los servidores habilitados con Arc: https://learn.microsoft.com/en-us/azure/azure-arc/servers/network-requirements
- Administrar y mantener el Connected Machine agent: https://learn.microsoft.com/en-us/azure/azure-arc/servers/manage-agent
- Introducción a Kubernetes habilitado con Azure Arc: https://learn.microsoft.com/en-us/azure/azure-arc/kubernetes/overview
- GitOps con Flux v2 en Kubernetes habilitado con Arc: https://learn.microsoft.com/en-us/azure/azure-arc/kubernetes/conceptual-gitops-flux2
- Cluster connect para Kubernetes habilitado con Arc: https://learn.microsoft.com/en-us/azure/azure-arc/kubernetes/conceptual-cluster-connect
- Introducción a Azure Resource Graph: https://learn.microsoft.com/en-us/azure/governance/resource-graph/overview
- Consultas iniciales de Resource Graph: https://learn.microsoft.com/en-us/azure/governance/resource-graph/samples/starter
- Documentación del portal de Azure: https://learn.microsoft.com/en-us/azure/azure-portal/
- Introducción a Azure Developer CLI (`azd`): https://learn.microsoft.com/en-us/azure/developer/azure-developer-cli/overview
- Autenticación de GitHub Actions con Azure mediante OIDC: https://learn.microsoft.com/en-us/azure/developer/github/connect-from-azure-openid-connect
- Precios de Azure Arc: https://azure.microsoft.com/en-us/pricing/details/azure-arc/