# 2.1 Describe the core architectural components of Azure

**Examen:** AZ-900 (2026-07-20) · **Peso del dominio:** 9,62 % · **Perfil:** SRE / Platform Architect

---

## 1. El problema de producción que este tema resuelve realmente

Toda revisión de incidente que termina con "se cayó todo el entorno junto" es un problema de dominio de fallo, y toda revisión de incidente que termina con "no pudimos evitar que el cambio llegara a producción" es un problema de alcance. Los componentes arquitectónicos de Azure son las dos respuestas:

- **Jerarquía física** — *geography → region → availability zone → datacenter → fault/update domain* — define qué falla **junto**.
- **Jerarquía lógica** — *tenant de Entra ID → management group → subscription → resource group → resource* — define qué se **gobierna, factura, limita (throttling) y elimina** junto.

Estos dos árboles son ortogonales. Un resource group puede contener recursos en siete regiones; una región puede contener recursos de diez mil subscriptions. Casi todos los errores de diseño reales en Azure vienen de colapsar ambos en un único modelo mental.

Tres modos de fallo que vas a encontrar en producción, todos ellos material puro del tema 2.1:

1. **La mentira de la zona lógica.** La zona `1` en la subscription A *no* es el mismo datacenter físico que la zona `1` en la subscription B. Dos equipos "repartidos entre las zonas 1 y 2" pueden estar sentados en la misma zona física. Azure expone el mapeo a través de la Locations API; casi nadie lo lee.
2. **La trampa de los metadatos del resource group.** El `location` de un resource group almacena sus metadatos de ARM. Si el control plane de esa región está degradado, no podés crear, actualizar ni eliminar recursos en ese resource group — *aunque todos los recursos que contiene vivan en una región sana*. Tu runbook de DR falla justo en el punto donde más necesita ARM.
3. **La subscription como dominio de throttling.** ARM impone presupuestos de lectura/escritura por subscription (y por resource provider). Un pipeline de CI ruidoso en la misma subscription que producción va a devolverle 429 a tu autoscaler. El radio de impacto de un bucle `for` es una subscription.

Todo lo que sigue está escrito para que esos tres fallos sean diagnosticables en menos de cinco minutos.

---

## 2. La jerarquía física

### 2.1 Geography → region → zone → datacenter

| Capa | Qué es | Radio de impacto | Seleccionable por el cliente | Significado de cumplimiento |
|---|---|---|---|---|
| **Geography** | Mercado discreto que contiene ≥ 2 regiones (p. ej. *United States*, *Europe*, *Brazil*) | Nunca falla como unidad | No (implícita por la región) | Frontera de residencia de datos y soberanía |
| **Region** | Conjunto de datacenters dentro de un perímetro definido por latencia, desplegados como una unidad de capacidad/API | Correlacionado: control plane regional compartido, región de red eléctrica compartida | **Sí** — la decisión de despliegue principal | Garantía de residencia, unidad de precio |
| **Availability Zone (AZ)** | Uno o más datacenters con energía, refrigeración y red **independientes** dentro de una región | Independiente por diseño | Sí, para servicios *zonales* | Ninguno — misma región, misma residencia |
| **Datacenter** | Edificio físico | No expuesto | No | — |
| **Fault domain (FD)** | Nivel de rack: energía compartida + switch top-of-rack | Rack | Indirectamente (availability sets / VMSS) | — |
| **Update domain (UD)** | Grupo reiniciado en conjunto durante el mantenimiento de la plataforma | Solo mantenimiento planificado | Indirectamente | — |

Cifras concretas clave de la propia documentación de Microsoft:

- Azure opera **más de 60 regiones en más de 300 datacenters**, más que cualquier otro proveedor cloud.
- Una región con zonas tiene **un mínimo de tres** availability zones.
- La latencia de red de ida y vuelta entre zonas dentro de una región es **inferior a 2 ms**.
- Las regiones emparejadas están, donde la geografía lo permite, **a al menos 300 millas (~480 km) de distancia**.

### 2.2 Zonal vs zone-redundant — la distinción que el examen evalúa de menos y que producción castiga de más

| Modelo | Colocación | Comportamiento ante fallo | Servicios típicos | Coste para SRE |
|---|---|---|---|---|
| **Zonal (fijado)** | Fijás la instancia a la zona `1`, `2` o `3` | Pérdida de zona = pérdida de instancia. **Vos** tenés que correr N instancias en N zonas y balancear la carga | VM, managed disk (LRS), Public IP zonal, node pool zonal de AKS | Sos dueño de la redundancia, del failover y del quorum |
| **Zone-redundant (ZR)** | La plataforma replica/reparte entre ≥ 3 zonas detrás de un único endpoint | La pérdida de zona es transparente; posible failover breve | Storage ZRS/GZRS, Standard Load Balancer, App Gateway v2, managed disks ZRS, gateways VPN/ExpressRoute zone-redundant, SQL DB Business Critical ZR | Precio unitario más alto, latencia de escritura ≈ la de la zona más lenta |
| **Regional (no zonal)** | La plataforma lo coloca en cualquier lugar de la región | Afinidad de zona indefinida — **no** es una garantía de redundancia | SKUs legacy/basic, Basic Public IP | Punto único de fallo silencioso |
| **Global** | Sin región en absoluto | Independiente de la región | Entra ID, Traffic Manager, Front Door, zonas DNS, management groups | No se puede restringir por región mediante policy |

> **Trampa:** "regional" no es "zone-redundant". Un recurso creado antes de que existieran zonas en esa región, o con un SKU Basic, es regional. No sobrevive a nada.

### 2.3 Availability sets vs availability zones vs regiones

| Constructo | Protege contra | SLA (conectividad de VM) | Coste de latencia | Coste extra |
|---|---|---|---|---|
| VM única, Standard HDD | Nada | 95 % | — | — |
| VM única, Standard SSD | Nada | 99,5 % | — | — |
| VM única, Premium SSD / Ultra Disk | Solo reinicio del host (live migration) | 99,9 % | — | Sobreprecio del disco |
| **Availability set** (≥ 2 VMs, reparto en FD + UD) | Fallo de rack, mantenimiento planificado | 99,95 % | Despreciable (mismo campus de DC) | Gratis |
| **≥ 2 VMs en la misma AZ** | Rack + mantenimiento, no pérdida de zona | 99,9 % | Despreciable | Gratis |
| **≥ 2 VMs repartidas en ≥ 2 AZs** | Pérdida de datacenter/zona (energía, refrigeración, red) | **99,99 %** | < 2 ms RTT | Tráfico entre zonas, capacidad duplicada |
| **Multirregión activo/activo** | Pérdida de región, pérdida del control plane regional | Compuesto, lo diseñás vos | 20–150 ms típico | Duplicación completa + replicación de datos |

**Aritmética del SLA compuesto** — los servicios dependientes se multiplican, no se promedian:

```
App tier  (2 VMs across 2 AZs)   0.9999
SQL DB    (Business Critical ZR) 0.9999
Storage   (ZRS)                  0.9999
Load Bal. (Standard, ZR)         0.9999
-------------------------------------------
Composite = 0.9999^4 = 0.99960  →  ~3 h 30 m/year
```

Añadir una quinta dependencia al 99,9 % te baja al 99,86 % (~12 h/año). Por esto "tenemos cuatro nueves en la VM" no es una afirmación sobre disponibilidad.

### 2.4 Region pairs — y por qué tenés que dejar de asumir que existen

Un **region pair** es una relación estática, definida por Microsoft, dentro de una geography (con una excepción famosa) que proporciona:

- **Aislamiento físico** — ≥ 300 millas de separación donde la geografía lo permite.
- **Actualización secuencial** — las actualizaciones planificadas de la plataforma se aplican a una sola región del par a la vez.
- **Replicación provista por la plataforma** — el storage GRS/RA-GRS replica al par, y a ningún otro sitio.
- **Orden de recuperación de regiones** — en una caída multirregión, se prioriza la restauración de una región de cada par.
- **Residencia de datos** — el par permanece en la misma geography, *excepto* **Brazil South**, que está emparejada con **South Central US**.

**La salvedad moderna:** las regiones más nuevas de Microsoft se lanzan cada vez más **sin par**, apoyándose en availability zones más replicación multirregión gestionada por el cliente. No codifiques una tabla de pares. Consultala:

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

**Leé ese bloque `zones` otra vez.** En esta subscription, la zona lógica `2` es la zona física `eastus-az3`. El mapeo se aleatoriza por subscription para que Azure reparta la carga de forma pareja. Consecuencias:

- La alineación de zonas entre subscriptions (p. ej. app en la sub A, base de datos en la sub B, "las dos en la zona 1") **no significa nada** salvo que resuelvas las zonas físicas en ambos lados.
- Una caída de capacidad que Azure reporta como afectando a `eastus-az2` se mapea a un número de zona lógica *distinto* en cada subscription que tengas.

### 2.5 Nubes soberanas y especiales

| Nube | Endpoint de ARM | Tenant | Notas |
|---|---|---|---|
| Azure público | `management.azure.com` | Entra ID global | Por defecto |
| Azure Government (US) | `management.usgovcloudapi.net` | Separado | FedRAMP High, DoD IL5; operadores US-person con verificación de antecedentes |
| Azure China (21Vianet) | `management.chinacloudapi.cn` | Separado | Operado por 21Vianet, no por Microsoft; retraso en funcionalidades |
| Azure Local / Edge Zones | Proyección híbrida de ARM | Global | Extensión on-prem o en el edge de telco del control plane |

Son **nubes separadas**: identidad separada, ARM separado, catálogo de servicios separado, sin IDs de recurso entre nubes.

```bash
$ az cloud list --output table
Name               IsActive    Profile    ActiveDirectoryAuthority
-----------------  ----------  ---------  ------------------------------------
AzureCloud         True        latest     https://login.microsoftonline.com
AzureChinaCloud    False       latest     https://login.chinacloudapi.cn
AzureUSGovernment  False       latest     https://login.microsoftonline.us
```

---

## 3. La jerarquía lógica

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

### 3.1 Qué *es* cada nivel, mecánicamente

| Nivel | Cadena de scope de ARM | Función principal | Hereda | Límites duros |
|---|---|---|---|---|
| **Tenant** | `/` | Frontera de identidad. Una subscription confía exactamente en **un** tenant | — | 1 MG raíz |
| **Management group** | `/providers/Microsoft.Management/managementGroups/{name}` | RBAC + Policy + agregación de costes entre muchas subscriptions | Del MG padre | 10 000 MGs por directorio; **6 niveles de profundidad** bajo la raíz; **un padre** por MG |
| **Subscription** | `/subscriptions/{guid}` | Unidad de facturación, **unidad de cuota**, **unidad de throttling de ARM**, unidad de registro de resource providers | De la cadena de MGs | 980 resource groups; una billing account; un tenant |
| **Resource group** | `/subscriptions/{guid}/resourceGroups/{name}` | Ciclo de vida + despliegue + scope de RBAC | De la subscription | Nombre ≤ 90 caracteres; ~800 recursos por tipo; 800 entradas de historial de despliegue |
| **Resource** | `.../providers/{ns}/{type}/{name}` | La cosa en sí | Del RG | 50 tags |

### 3.2 Semántica de la herencia — aditiva, y en un solo sentido

**Azure RBAC es aditivo y no se puede revocar hacia abajo.** Si alguien es `Contributor` a nivel de management group, ninguna asignación en el resource group se lo puede quitar. El único mecanismo sustractivo es una **deny assignment** (creada por Deployment Stacks, o históricamente por Blueprints).

**Azure Policy se evalúa en cada scope de la cadena.** Los efectos se componen:

| Efecto | Se aplica en | Regla de composición |
|---|---|---|
| `Deny` | Momento de creación/actualización | Cualquier `Deny` en cualquier punto de la cadena gana |
| `Audit` | Creación/actualización + escaneo periódico | Registra el incumplimiento, nunca bloquea |
| `Modify` / `Append` | Creación/actualización | Muta la petición antes de la validación |
| `DeployIfNotExists` | Post-creación + tarea de remediación | Necesita una managed identity con permisos en el scope destino |
| `DenyAction` | Eliminación (`Microsoft.Authorization/*/delete`) | Bloquea acciones destructivas, p. ej. el borrado accidental de un RG |

**Los locks (`CanNotDelete`, `ReadOnly`) también se heredan hacia abajo y tampoco se pueden sobrescribir.** Un lock `ReadOnly` en la subscription es la forma más eficaz que existe de romper un pipeline de despliegue de producción a las 03:00.

### 3.3 Resource groups: lo que no son

Un resource group **no** es una frontera de red, **no** es una frontera de seguridad, **no** es una restricción de región y **no** es un fault domain. Es:

1. Un **destino de despliegue** — las plantillas ARM/Bicep se despliegan a scope de RG por defecto y resuelven los grafos de `dependsOn` dentro de él.
2. Una **unidad de ciclo de vida** — `az group delete` elimina todos los recursos de dentro, en orden de dependencias. Esta es la forma más rápida de perder producción en Azure.
3. Un **registro de metadatos fijado a una región** — la propiedad `location`.

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

Tres regiones, un resource group, una sola ubicación de metadatos. Si el ARM de `eastus` está degradado, la storage account de `westus` es **legible y escribible en su data plane** pero **ingestionable en su control plane**. Regla de diseño: **los recursos de DR pertenecen a un resource group cuyo `location` sea la región de DR.**

### 3.4 Las subscriptions como fronteras de radio de impacto y de throttling

ARM aplica presupuestos de peticiones por subscription y por resource provider. Los contadores se devuelven en cada respuesta:

```bash
$ az rest --method get --verbose \
    --url "https://management.azure.com/subscriptions/$SUB/resourcegroups?api-version=2021-04-01" \
    --debug 2>&1 | grep -iE 'x-ms-ratelimit|retry-after'
'x-ms-ratelimit-remaining-subscription-reads': '11842'
'x-ms-ratelimit-remaining-subscription-global-reads': '3748'
```

Cuando se agotan:

```
$ az vm list -o table
(TooManyRequests) The request is being throttled as the limit has been reached for operation type - 'List'.
For more information, see - https://aka.ms/msdn-throttling
Code: TooManyRequests
Retry-After: 42
```

**Reglas de topología de subscriptions que se derivan de esto:**

| Motivo | Separá subscriptions cuando… | Mantenelas juntas cuando… |
|---|---|---|
| Cuota | Necesitás > 980 RGs, o la cuota regional de vCPU está topada | Hay margen de cuota de sobra |
| Throttling | Un CI/CD de alta rotación o un autoscaling comparte sub con producción | Poca rotación de llamadas a la API |
| Facturación | El coste debe facturarse a un centro de coste distinto | Los tags + la agregación por management group alcanzan |
| Radio de impacto | Una policy o un lock a nivel de tenant tendría demasiado alcance | Mismo ciclo de vida y mismo dueño |
| Cumplimiento | El scope de PCI/HIPAA debe estar aislado de forma demostrable | Misma clase regulatoria |

La respuesta de landing zone es el **subscription vending**: una subscription es una unidad de ganado, creada por pipeline, colocada bajo el management group correcto, con policy y RBAC aplicados por herencia en lugar de a mano.

---

## 4. Infrastructure as code — completo, desplegable

### 4.1 Jerarquía de management groups (Bicep a scope de tenant)

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

Desplegar:

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

> `--location` en un despliegue a tenant/MG/subscription almacena los *metadatos del despliegue*, no los recursos. Elegí una región a la que puedas llegar durante un evento de DR.

### 4.2 Policy personalizada: exigir storage zone-redundant en producción

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

### 4.3 Vincular la policy a la jerarquía (Bicep a scope de management group)

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

Desplegar a scope de management group:

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

### 4.4 Despliegue a scope de subscription: resource groups alineados con los dominios de fallo

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

### 4.5 El mismo despliegue a scope de subscription en ARM JSON puro

`workload/subscription.json` — para entornos donde no hay herramientas de Bicep disponibles.

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

### 4.6 Equivalente en Terraform de la jerarquía

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

### 4.7 Workload consciente de zonas en AKS (manifiestos de Kubernetes)

Las availability zones se detienen en la frontera de la infraestructura salvo que se le diga al scheduler. AKS etiqueta cada nodo con `topology.kubernetes.io/zone = <region>-<logicalZone>`.

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

Verificá que el reparto realmente ocurrió:

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

### 4.8 Puerta de CI: what-if antes del apply

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

## 5. Referencia de CLI con salida real

### 5.1 ¿Dónde estoy? (resolución de contexto)

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

### 5.2 Recorrer el árbol de management groups

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

Mover una subscription entre management groups (este es el comando único de mayor apalancamiento en la gobernanza de Azure — re-emparenta de golpe todas las policies y role assignments heredados):

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

### 5.3 Descubrimiento de regiones y zonas

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

Qué SKUs son realmente capaces de zonas en una región, y dónde están restringidos:

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

> `NotAvailableForSubscription` es una restricción **a nivel de subscription**, no regional. Se resuelve con una solicitud de cuota/capacidad, no eligiendo otra región.

### 5.4 Resource groups e IDs de recurso

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

### 5.5 Deployment Stacks — protección contra el borrado de resource groups que sí aguanta

Azure Blueprints está deprecado (retirada el 11 de julio de 2026). El mecanismo actual para "este resource group no puede eliminarse, ni siquiera por un Owner" es un **deployment stack** con deny settings, que crea una deny assignment real.

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

## 6. Verificación y diagnóstico de fallos

### 6.1 Tabla de decisión para diagnóstico

| Síntoma / código de error | Capa | Causa raíz | Primer comando | Solución |
|---|---|---|---|---|
| `ZonalAllocationFailed` | Zona | No hay capacidad para ese SKU en esa zona **lógica** ahora mismo | `az vm list-skus -l $LOC --size $SKU --zone -o table` | Reintentar en otra zona, otra familia de SKU, o usar un Capacity Reservation Group |
| `AllocationFailed` | Región | Agotamiento de capacidad regional para el SKU/cluster | Lo mismo, más probar otra región | Cambiar de familia de SKU o de región; abrir una solicitud de capacidad |
| `SkuNotAvailable` | Subscription | El SKU no se ofrece en la región **o** está restringido para esta subscription | `az vm list-skus -l $LOC --size $SKU --query "[].restrictions"` | Solicitud de cuota, o SKU distinto |
| `RequestDisallowedByPolicy` | MG / subscription | Una policy `Deny` en la cadena de scopes | `az policy state list --filter "complianceState eq 'NonCompliant'"` | Corregir el recurso, o añadir una exención acotada |
| `RequestDisallowedByAzure` | Cualquiera | Deny assignment (deployment stack / managed app) | `az rest` sobre `Microsoft.Authorization/denyAssignments` | Eliminar/actualizar el stack |
| `ScopeLocked` | RG / recurso | Lock `CanNotDelete` o `ReadOnly` | `az lock list --resource-group $RG -o table` | Quitar el lock, y volver a ponerlo después |
| `MissingSubscriptionRegistration` | Subscription | Resource provider no registrado | `az provider show -n $NS --query registrationState` | `az provider register -n $NS --wait` |
| `TooManyRequests` / HTTP 429 | Subscription | Cubo de throttling de ARM agotado | Leer las cabeceras `Retry-After` + `x-ms-ratelimit-*` | Backoff exponencial; separar subscriptions; agrupar con Resource Graph |
| `ResourceGroupNotFound` durante un DR | Región de metadatos del RG | Los metadatos del RG viven en la región caída | `az group show -n $RG --query location` | Colocar de antemano los resource groups de DR en la región de DR |
| `AuthorizationFailed` tras mover de tenant | Tenant | La subscription cambió de tenant → **todas** las asignaciones de RBAC quedan huérfanas | `az role assignment list --all -o table` | Recrear las asignaciones contra los principals del nuevo tenant |
| "Misma zona" entre subs es lenta / no es HA | Mapeo de zonas | La zona lógica `1` ≠ la misma zona física entre subscriptions | Locations API `availabilityZoneMappings` | Resolver las zonas físicas en ambos lados y alinearlas |

### 6.2 Verificar la alineación de zonas entre subscriptions

Esta es la comprobación que nadie hace, y son tres líneas:

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

**Interpretación:** una app en la zona `1` de la sub A (física `az1`) y una base de datos en la zona `1` de la sub B (física `az2`) están en zonas físicas *distintas*. Aplican la latencia entre zonas y la independencia de fallo entre zonas, al contrario de lo que creen ambos equipos. Si necesitabas co-ubicación por latencia, tenés que apuntar a la zona lógica `2` de la sub B.

### 6.3 Auditoría de zonas de toda la flota con Azure Resource Graph

Resource Graph consulta todas las subscriptions de un management group con una sola petición — y no está sujeto al throttling de ARM por subscription de la misma manera, lo que lo convierte en la herramienta correcta para inventario.

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

Seis VMs y dos public IPs en `westus3` **no tienen garantía de zona**. Esa es tu región de DR. Tu plan de DR asume que sobrevive a un fallo de zona; no lo hace.

Encontrar resource groups cuya región de metadatos difiere de la de los recursos que contienen:

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

Once recursos de DR están gestionados por un registro de metadatos en `eastus`. Durante un incidente del control plane de `eastus` son ingestionables.

### 6.4 Cumplimiento de policies y forense de denegaciones

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

Cuando un despliegue queda bloqueado, el error nombra la assignment y la definition — resolvelas antes de discutir:

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

Exención acotada y con fecha límite — nunca deshabilites la assignment:

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

### 6.5 RBAC efectivo en un scope

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

Tres de las cuatro asignaciones están **heredadas de management groups**. Eliminar la asignación del resource group no cambia nada para el primer, segundo ni cuarto principal. Este es, con diferencia, el error de diagnóstico de RBAC más común.

### 6.6 Validar un movimiento de recursos antes de intentarlo

Los movimientos fallan *después* de que la API los acepte si algún tipo de recurso del conjunto no es movible. Validá primero:

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

**Reglas de movimiento que vale la pena memorizar:** los resource groups de origen y destino quedan **ambos bloqueados** mientras dura el movimiento; no podés cambiar de región con un movimiento (un movimiento reubica el registro de ARM, no los bits); muchos recursos zonales no se pueden mover en absoluto; y mover entre subscriptions requiere el mismo tenant y el provider registrado en la subscription de destino.

### 6.7 Salud de región y de recursos durante un incidente

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

Dos VMs caídas, ambas en la misma zona lógica. Confirmá la correlación antes de avisar a nadie más:

```bash
$ az vm show -g rg-orders-prod-eastus -n vm-orders-03 --query "zones" -o tsv
2
$ az vm show -g rg-orders-prod-eastus -n vm-orders-06 --query "zones" -o tsv
2
```

Después traducí la zona lógica `2` a la zona física que Microsoft va a nombrar en el aviso de Service Health:

```bash
$ az rest --method get \
    --url "https://management.azure.com/subscriptions/$SUB/locations?api-version=2022-12-01" \
    --query "value[?name=='eastus'].availabilityZoneMappings[?logicalZone=='2'].physicalZone" -o tsv
eastus-az3
```

Ahora el aviso que dice "los clientes en `eastus-az3` podrían experimentar…" es accionable en tu subscription.

### 6.8 Checklist de pre-vuelo para cualquier landing zone nueva

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

## 7. Reglas de diseño destiladas

1. **Elegí la región por latencia, residencia, disponibilidad de servicios y precio — en ese orden — y después verificá el soporte de zonas para cada SKU que necesites.** La paridad de funcionalidades entre regiones no es uniforme; las regiones "Recommended" reciben los servicios nuevos primero.
2. **Por defecto, usá SKUs zone-redundant para todo lo que tenga estado**, y ≥ 3 instancias repartidas en ≥ 3 zonas para todo lo que no lo tenga. El fijado zonal es una decisión deliberada por latencia o licenciamiento, no un valor por defecto.
3. **Nunca confíes en los números de zona lógica entre subscriptions.** Resolvé las zonas físicas desde la Locations API siempre que la co-ubicación o la anti-afinidad cruce una frontera de subscription.
4. **Colocá los resource groups de DR en la región de DR.** El `location` del resource group es una dependencia del control plane, y el DR es exactamente cuando necesitás el control plane.
5. **Los management groups llevan la gobernanza; las subscriptions llevan la cuota y el throttling; los resource groups llevan el ciclo de vida.** Separá subscriptions por cuota, throttling y cumplimiento — no por "queremos una factura aparte", que los tags y las vistas de coste por management group ya te dan.
6. **Asigná RBAC y Policy tan alto en el árbol como sea correcto, y no más alto.** La herencia es aditiva e irrevocable hacia abajo; un error en la raíz del tenant no tiene remedio local.
7. **Protegé los resource groups con deployment stacks (`denyDelete`) más locks `CanNotDelete`**, dado que `az group delete` es un solo comando con un radio de impacto ilimitado. Blueprints se retira el 11 de julio de 2026 — migrá a template specs más deployment stacks.
8. **Calculá SLAs compuestos, no SLAs de componente**, y acordate de que los region pairs te dan replicación *de plataforma* y secuenciación de actualizaciones — nunca failover de aplicación. El multirregión activo/activo es algo que construís, no algo que seleccionás.

---

## 8. Referencias

**Guía de estudio y alcance del examen**
- AZ-900 study guide — https://learn.microsoft.com/en-us/credentials/certifications/resources/study-guides/az-900
- Microsoft Azure Fundamentals learning path — https://learn.microsoft.com/en-us/training/paths/microsoft-azure-fundamentals-describe-cloud-concepts/

**Arquitectura física**
- Azure geographies, regions and availability zones — https://learn.microsoft.com/en-us/azure/reliability/regions-overview
- What are Azure availability zones? — https://learn.microsoft.com/en-us/azure/reliability/availability-zones-overview
- Availability zone service and region support — https://learn.microsoft.com/en-us/azure/reliability/availability-zones-region-support
- Azure region pairs / cross-region replication — https://learn.microsoft.com/en-us/azure/reliability/regions-paired
- Azure regions list — https://learn.microsoft.com/en-us/azure/reliability/regions-list
- Availability sets, fault domains and update domains — https://learn.microsoft.com/en-us/azure/virtual-machines/availability
- Azure global infrastructure — https://datacenters.microsoft.com/globe/explore
- Reliability guidance by service — https://learn.microsoft.com/en-us/azure/reliability/overview-reliability-guidance

**Jerarquía lógica y gobernanza**
- Azure Resource Manager overview — https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/overview
- Manage resource groups — https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/manage-resource-groups-cli
- Organize your Azure resources with management groups — https://learn.microsoft.com/en-us/azure/governance/management-groups/overview
- Understand scope in Azure RBAC — https://learn.microsoft.com/en-us/azure/role-based-access-control/scope-overview
- Azure Policy overview and effects — https://learn.microsoft.com/en-us/azure/governance/policy/concepts/effects
- Azure Policy exemption structure — https://learn.microsoft.com/en-us/azure/governance/policy/concepts/exemption-structure
- Lock resources to prevent changes — https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/lock-resources
- Move resources to a new resource group or subscription — https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/move-resource-group-and-subscription
- Move operation support by resource type — https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/move-support-resources

**Límites, throttling y cuotas**
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

**Consulta, salud y SLA**
- Azure Resource Graph query language — https://learn.microsoft.com/en-us/azure/governance/resource-graph/concepts/query-language
- Azure Resource Health overview — https://learn.microsoft.com/en-us/azure/service-health/resource-health-overview
- Locations - List (REST, incluye `availabilityZoneMappings`) — https://learn.microsoft.com/en-us/rest/api/resources/subscriptions/list-locations
- Service Level Agreements for Microsoft Online Services — https://www.microsoft.com/licensing/docs/view/Service-Level-Agreements-SLA-for-Online-Services
- Bandwidth pricing (transferencia de datos entre zonas / entre regiones) — https://azure.microsoft.com/en-us/pricing/details/bandwidth/

**AKS y consciencia de zonas**
- Create an AKS cluster that uses availability zones — https://learn.microsoft.com/en-us/azure/aks/availability-zones
- Azure Disk CSI driver storage class parameters — https://learn.microsoft.com/en-us/azure/aks/azure-csi-disk-storage-provision
- Kubernetes pod topology spread constraints — https://kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints/
- Kubernetes well-known labels (`topology.kubernetes.io/zone`) — https://kubernetes.io/docs/reference/labels-annotations-taints/#topologykubernetesiozone

**Nubes soberanas**
- Azure Government documentation — https://learn.microsoft.com/en-us/azure/azure-government/
- Azure operated by 21Vianet — https://learn.microsoft.com/en-us/azure/china/