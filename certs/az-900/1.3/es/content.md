# 1.3 — Describir los tipos de servicios en la nube

**Certificación:** AZ-900 (Microsoft Azure Fundamentals) · Versión del temario 2026-07-20
**Dominio:** 1 — Describir conceptos de nube · **Peso en el examen:** 9.4
**Nivel:** Arquitecto de plataforma / SRE — profundidad de producción

---

## 1. El problema de producción: el tipo de servicio *es* tu frontera de guardia

La mayor parte del material de fundamentos presenta IaaS / PaaS / SaaS con la metáfora de la pizza como servicio. Ese encuadre es inútil la primera vez que te llaman a las 03:00. El encuadre operativamente correcto es este:

> **Un tipo de servicio en la nube es un contrato que reparte una pila fija de diez capas operativas entre dos rotaciones de guardia: la tuya y la del proveedor. Elegir un tipo de servicio es elegir qué capas pueden despertarte, y qué capas tenés contractualmente prohibido tocar cuando fallan.**

Las capas no desaparecen cuando pasás a PaaS. El hipervisor sigue necesitando parches, el SO invitado sigue necesitando que se remedie una CVE de kernel, el terminador TLS sigue necesitando que se deprecien suites de cifrado. Lo que cambia es *quién sostiene el busca y quién sostiene la ventana de cambio*.

Esto produce tres consecuencias concretas de producción que el examen evalúa de forma indirecta y que tus revisiones de incidentes van a evaluar directamente:

1. **La latencia de remediación está invertida respecto del control.** En IaaS podés parchear un kernel en caliente en 20 minutos porque sos dueño de la capa del SO. En PaaS abrís un caso de soporte y esperás, porque no tenés permitido hacer `ssh` al worker. Mayor abstracción significa menor *varianza* de MTTR (menos incidentes) pero mayor *techo* de MTTR (los incidentes que sí te tocan, no los podés arreglar vos).
2. **La deprecación es asimétrica.** En IaaS podés correr un runtime EOL indefinidamente y hacerte cargo de la CVE. En PaaS la plataforma va a retirar por la fuerza tu stack de runtime según el calendario del proveedor, no el tuyo. Este es un costo operativo real, programado y no negociable que IaaS no tiene.
3. **El SLA se compone, no se hereda.** Cablear tres servicios PaaS de 99,95% en serie no te da 99,95%. Te da ~99,85%. El tipo de servicio determina cuántos términos de SLA independientes se sientan en tu ruta crítica.

Todo lo que sigue está construido sobre ese encuadre.

---

## 2. El modelo de responsabilidad compartida como matriz de propiedad por capas

Microsoft publica la partición canónica como una tabla de diez capas. Memorizá la *forma*, no los píxeles — la forma es lo que necesitan tanto el examen como tus revisiones de arquitectura.

| Capa | Local (on-premises) | IaaS | PaaS | SaaS |
|---|---|---|---|---|
| Información y datos | **Cliente** | **Cliente** | **Cliente** | **Cliente** |
| Dispositivos (móviles y PC) | **Cliente** | **Cliente** | **Cliente** | **Cliente** |
| Cuentas e identidades | **Cliente** | **Cliente** | **Cliente** | **Cliente** |
| Infraestructura de identidad y directorio | **Cliente** | **Cliente** | *Compartido* | *Compartido* |
| Aplicaciones | **Cliente** | **Cliente** | *Compartido* | **Microsoft** |
| Controles de red | **Cliente** | **Cliente** | *Compartido* | **Microsoft** |
| Sistema operativo | **Cliente** | **Cliente** | **Microsoft** | **Microsoft** |
| Hosts físicos | **Cliente** | **Microsoft** | **Microsoft** | **Microsoft** |
| Red física | **Cliente** | **Microsoft** | **Microsoft** | **Microsoft** |
| Centro de datos físico | **Cliente** | **Microsoft** | **Microsoft** | **Microsoft** |

Fuente: [Shared responsibility in the cloud](https://learn.microsoft.com/en-us/azure/security/fundamentals/shared-responsibility).

### Los tres invariantes que valen más que la tabla

**Invariante 1 — Tres capas *nunca* se delegan.** Los datos, los endpoints y las cuentas/identidades siguen siendo tuyos en todos los modelos, SaaS incluido. Si un tenant de Microsoft 365 es comprometido a través de una credencial phisheada sin MFA, eso es una falla del cliente bajo el contrato SaaS. La obligación del proveedor terminó en "te ofrecimos Conditional Access".

**Invariante 2 — El punto de transición de la capa del SO es exactamente la frontera IaaS→PaaS.** Esta única fila es el discriminador de mayor rendimiento en el examen. "¿Quién parchea el sistema operativo?" responde el tipo de servicio de manera determinista.

**Invariante 3 — `Compartido` es la celda peligrosa.** Las filas de responsabilidad compartida son donde se esconden las caídas de producción, porque ambas partes asumen que la otra se está ocupando. En PaaS, "controles de red" es compartido: Microsoft opera el front-end y el balanceador de carga; *vos* seguís teniendo que habilitar Private Endpoints, deshabilitar el acceso de red público y fijar `minTlsVersion`. Un App Service con configuración por defecto es alcanzable desde internet por cualquier cliente del planeta. Eso no es una falla de Microsoft — es un control del cliente sin ejercer en una fila compartida.

### Verificar la matriz en lugar de confiar en ella

La matriz es una afirmación. Comprobala recurso por recurso contra el plano de control en vivo:

```bash
$ az vm show -g rg-iaas-prod -n vm-appiaas-1 \
    --query "{osType:storageProfile.osDisk.osType, \
              image:storageProfile.imageReference.sku, \
              patchMode:osProfile.linuxConfiguration.patchSettings.patchMode}" -o table
OsType    Image     PatchMode
--------  --------  ------------------
Linux     server    AutomaticByPlatform
```

`patchMode` existe *porque* la capa del SO es tuya. Ahora el equivalente PaaS:

```bash
$ az webapp config show -g rg-paas-prod -n app-checkout-prod \
    --query "{stack:linuxFxVersion, tls:minTlsVersion, ftps:ftpsState, http20:http20Enabled}" -o table
Stack               Tls    Ftps        Http20
------------------  -----  ----------  --------
PYTHON|3.12         1.2    Disabled    True

$ az webapp config show -g rg-paas-prod -n app-checkout-prod --query "patchMode"
# (no output — the property does not exist)
```

La ausencia de `patchMode` en el recurso App Service es el modelo de responsabilidad compartida expresado como superficie de API. No podés expresar una intención sobre algo que no te pertenece.

---

## 3. IaaS — mecánica, y qué compraste realmente

### Qué se aprovisiona

IaaS te da una porción virtualizada de cómputo, almacenamiento y red. En Azure los primitivos son Virtual Machines, Virtual Machine Scale Sets, Managed Disks, Virtual Networks, Load Balancers y Azure Files/Blob en la capa de almacenamiento. La obligación del proveedor se detiene en la frontera del hipervisor: recibís una VM booteada con una NIC y un disco, y todo lo que está por encima de la línea del hardware virtual es tuyo.

**Qué significa "tuyo" concretamente en una rotación de SRE:**

- Cadencia de parcheo del SO invitado, orquestación de reinicios y ventanas de mantenimiento
- Instalación del runtime y fijado de versiones
- Firewall basado en host (`nftables`/Windows Firewall) *además de* los NSG
- Agentes de envío de logs, agentes de métricas y sus modos de falla
- Consistencia de backups (snapshots consistentes con la aplicación vs. consistentes con caída)
- Planificación de capacidad: cantidad de instancias, familia de SKU, nivel de IOPS del disco
- Lógica de escalado horizontal y semántica de los health probes

### El modelo de disponibilidad es *tu* problema de diseño

Una sola VM no tiene aislamiento de fallas significativo. Los niveles de SLA de VM publicados por Azure lo dejan explícito (verificá las cifras actuales contra el documento de SLA vigente — los SLA están versionados):

| Topología de despliegue | SLA de VM publicado | Dominio de falla cubierto | Presupuesto mensual de caída |
|---|---|---|---|
| Instancia única, todos los discos Premium SSD o Ultra | 99,9% | Solo mantenimiento del host | ~43,8 min |
| 2+ instancias en un Availability Set | 99,95% | Rack / energía / switch TOR | ~21,9 min |
| 2+ instancias a través de Availability Zones | 99,99% | Centro de datos | ~4,4 min |

Esto es un asunto puramente de IaaS. En PaaS la plataforma convierte la decisión de redundancia de zona en un flag booleano; en IaaS es una topología que tenés que construir, desplegar dos veces y probar.

### Línea base IaaS completa — Bicep, sin truncar

```bicep
// infra/iaas-baseline.bicep
// One zonal instance of an IaaS workload. Deploy this module 2-3 times with
// different `zone` values behind a shared Standard Load Balancer to reach the
// 99.99% multi-zone VM SLA. Nothing above the virtual hardware line is managed
// for you: note how many properties in this file exist purely because the
// OS layer is a customer responsibility.
targetScope = 'resourceGroup'

@description('Deployment region. Must be an Availability Zone-enabled region.')
param location string = resourceGroup().location

@description('Short workload name, used as a resource-name prefix.')
@minLength(3)
@maxLength(10)
param workload string = 'appiaas'

@description('Availability zone for this instance.')
@allowed([
  '1'
  '2'
  '3'
])
param zone string = '1'

@description('VM size. Dsv5 supports Accelerated Networking and Premium SSD.')
param vmSize string = 'Standard_D4s_v5'

@description('Local administrator name for the guest OS. THIS ACCOUNT IS YOURS.')
param adminUsername string

@description('SSH public key in OpenSSH format. Password auth is disabled below.')
param adminPublicKey string

@description('CIDR of the ingress tier allowed to reach the app subnet.')
param ingressTierCidr string = '10.42.2.0/24'

@description('Log Analytics workspace resource ID for guest telemetry.')
param logAnalyticsWorkspaceId string

var vnetName         = 'vnet-${workload}'
var subnetName       = 'snet-app'
var appSubnetCidr    = '10.42.1.0/24'
var nsgName          = 'nsg-${workload}-app'
var nicName          = 'nic-${workload}-${zone}'
var vmName           = 'vm-${workload}-${zone}'
var diagStorageName  = toLower(take('st${workload}diag${uniqueString(resourceGroup().id)}', 24))

// ---------------------------------------------------------------------------
// Network controls: CUSTOMER responsibility in IaaS. Nothing here is default.
// ---------------------------------------------------------------------------
resource nsg 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: nsgName
  location: location
  properties: {
    securityRules: [
      {
        name: 'allow-https-from-ingress-tier'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: ingressTierCidr
          sourcePortRange: '*'
          destinationAddressPrefix: appSubnetCidr
          destinationPortRange: '8443'
        }
      }
      {
        name: 'allow-azure-lb-health-probe'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'AzureLoadBalancer'
          sourcePortRange: '*'
          destinationAddressPrefix: appSubnetCidr
          destinationPortRange: '8443'
        }
      }
      {
        name: 'deny-all-inbound'
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
      {
        name: 'allow-outbound-to-azure-monitor'
        properties: {
          priority: 200
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: appSubnetCidr
          sourcePortRange: '*'
          destinationAddressPrefix: 'AzureMonitor'
          destinationPortRange: '443'
        }
      }
    ]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.42.0.0/16'
      ]
    }
    subnets: [
      {
        name: subnetName
        properties: {
          addressPrefix: appSubnetCidr
          networkSecurityGroup: {
            id: nsg.id
          }
          privateEndpointNetworkPolicies: 'Enabled'
        }
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Boot diagnostics: the only console you get when the guest OS fails to boot.
// Provision it BEFORE you need it; you cannot enable it on a dead VM cheaply.
// ---------------------------------------------------------------------------
resource diagStorage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: diagStorageName
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    supportsHttpsTrafficOnly: true
  }
}

resource nic 'Microsoft.Network/networkInterfaces@2023-09-01' = {
  name: nicName
  location: location
  properties: {
    enableAcceleratedNetworking: true
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: '${vnet.id}/subnets/${subnetName}'
          }
        }
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// The VM itself. Every property below the `osProfile` line is an operational
// decision that PaaS would have made for you.
// ---------------------------------------------------------------------------
resource vm 'Microsoft.Compute/virtualMachines@2024-03-01' = {
  name: vmName
  location: location
  zones: [
    zone
  ]
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: 'ubuntu-24_04-lts'
        sku: 'server'
        version: 'latest'
      }
      osDisk: {
        name: '${vmName}-osdisk'
        createOption: 'FromImage'
        caching: 'ReadWrite'
        deleteOption: 'Delete'
        managedDisk: {
          storageAccountType: 'Premium_LRS'
        }
      }
      dataDisks: [
        {
          name: '${vmName}-datadisk-0'
          lun: 0
          diskSizeGB: 256
          createOption: 'Empty'
          caching: 'None'
          deleteOption: 'Delete'
          managedDisk: {
            storageAccountType: 'Premium_LRS'
          }
        }
      ]
    }
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: adminPublicKey
            }
          ]
        }
        patchSettings: {
          patchMode: 'AutomaticByPlatform'
          assessmentMode: 'AutomaticByPlatform'
          automaticByPlatformSettings: {
            rebootSetting: 'IfRequired'
            bypassPlatformSafetyChecksOnUserSchedule: false
          }
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
          properties: {
            deleteOption: 'Delete'
          }
        }
      ]
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
        storageUri: diagStorage.properties.primaryEndpoints.blob
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Observability is NOT included in IaaS. You install the agent yourself,
// and you own its failure modes. In PaaS this is a platform capability.
// ---------------------------------------------------------------------------
resource monitorAgent 'Microsoft.Compute/virtualMachines/extensions@2024-03-01' = {
  parent: vm
  name: 'AzureMonitorLinuxAgent'
  location: location
  properties: {
    publisher: 'Microsoft.Azure.Monitor'
    type: 'AzureMonitorLinuxAgent'
    typeHandlerVersion: '1.29'
    autoUpgradeMinorVersion: true
    enableAutomaticUpgrade: true
  }
}

resource dcrAssociation 'Microsoft.Insights/dataCollectionRuleAssociations@2022-06-01' = {
  name: 'dcra-${vmName}'
  scope: vm
  properties: {
    dataCollectionRuleId: dcr.id
  }
  dependsOn: [
    monitorAgent
  ]
}

resource dcr 'Microsoft.Insights/dataCollectionRules@2022-06-01' = {
  name: 'dcr-${workload}-syslog'
  location: location
  properties: {
    dataSources: {
      syslog: [
        {
          name: 'syslog-standard'
          streams: [
            'Microsoft-Syslog'
          ]
          facilityNames: [
            'auth'
            'authpriv'
            'daemon'
            'kern'
            'syslog'
          ]
          logLevels: [
            'Warning'
            'Error'
            'Critical'
            'Alert'
            'Emergency'
          ]
        }
      ]
      performanceCounters: [
        {
          name: 'perf-standard'
          streams: [
            'Microsoft-Perf'
          ]
          samplingFrequencyInSeconds: 60
          counterSpecifiers: [
            'Processor(*)\\% Processor Time'
            'Memory(*)\\Available MBytes'
            'Logical Disk(*)\\Free Megabytes'
            'Network(*)\\Total Bytes Transmitted'
          ]
        }
      ]
    }
    destinations: {
      logAnalytics: [
        {
          name: 'law-destination'
          workspaceResourceId: logAnalyticsWorkspaceId
        }
      ]
    }
    dataFlows: [
      {
        streams: [
          'Microsoft-Syslog'
          'Microsoft-Perf'
        ]
        destinations: [
          'law-destination'
        ]
      }
    ]
  }
}

output vmId string = vm.id
output vmPrincipalId string = vm.identity.principalId
output privateIp string = nic.properties.ipConfigurations[0].properties.privateIPAddress
```

**Leé ese archivo como un documento contable.** Aproximadamente el 60% de sus líneas existen únicamente porque IaaS hace tuyas las capas de SO y de controles de red: reglas NSG, configuración de parches, material de clave SSH, diagnósticos de arranque, el agente de monitoreo, la regla de recolección de datos. El equivalente PaaS de la §4 tiene un tercio del tamaño y hace más.

### Desplegarlo e inspeccionarlo

```bash
$ az deployment group create \
    --resource-group rg-iaas-prod \
    --template-file infra/iaas-baseline.bicep \
    --parameters workload=appiaas zone=1 adminUsername=svcops \
                 adminPublicKey="$(cat ~/.ssh/id_ed25519.pub)" \
                 logAnalyticsWorkspaceId="/subscriptions/8f1c.../resourceGroups/rg-obs-prod/providers/Microsoft.OperationalInsights/workspaces/law-prod" \
    --name iaas-baseline-z1 \
    --output table

Name              ResourceGroup    State        Timestamp                         Mode
----------------  ---------------  -----------  --------------------------------  ---------
iaas-baseline-z1  rg-iaas-prod     Succeeded    2026-09-04T11:42:17.884213+00:00  Incremental
```

```bash
$ az vm list -g rg-iaas-prod -d -o table
Name           ResourceGroup    PowerState    PublicIps    Fqdns    Location    Zones
-------------  ---------------  ------------  -----------  -------  ----------  -------
vm-appiaas-1   rg-iaas-prod     VM running                          eastus      1
vm-appiaas-2   rg-iaas-prod     VM running                          eastus      2
vm-appiaas-3   rg-iaas-prod     VM running                          eastus      3
```

Tres VM en tres zonas es la topología de 99,99%. Notá que hicieron falta tres despliegues y un balanceador de carga que todavía tenés que construir — ese trabajo es el precio de la superficie de control de IaaS.

---

## 4. PaaS — mecánica, y qué entregaste para conseguirlo

### Qué se aprovisiona

PaaS te da un runtime de aplicación gestionado. Vos aportás código o una imagen de contenedor y un objeto de configuración; el proveedor aporta el SO, el runtime, el parcheo, el terminador TLS, el autoescalador, los deployment slots y el pipeline de logs.

Cómputo PaaS de Azure, ordenado por control decreciente:

| Servicio | Unidad de despliegue | Vos controlás | El proveedor controla | Escala a cero |
|---|---|---|---|---|
| Azure App Service | Código o contenedor | Versión del runtime, always-on, slots, integración con VNet | SO, parcheo del host, TLS, LB | No (planes Premium) |
| Azure Container Apps | Imagen de contenedor | Imagen, réplicas, reglas de escalado KEDA, Dapr | Kubernetes, node pool, ingress controller | **Sí** |
| Azure Functions (Consumption) | Código de función | Bindings de trigger, timeout, versión del runtime | Todo lo demás, incl. cantidad de instancias | **Sí** |
| Azure Spring Apps | JAR de Spring Boot | Config de la app, bindings | JVM, SO, registro de servicios | No |
| Azure SQL Database | Esquema + datos | Esquema, índices, nivel, retención de backups | Parcheo del motor, HA, failover, backups | Sí (nivel serverless) |
| Azure Cosmos DB | Contenedor + clave de partición | Clave de partición, política de indexado, consistencia | Replicación, sharding, parcheo | No (RU autoescalado) |

### Los dos costos de PaaS, dichos con honestidad

**Costo 1 — Deprecación forzada del runtime.** App Service impone una política de soporte de lenguajes: cuando un runtime llega al EOL de su comunidad, la plataforma lo retira según un cronograma publicado. Vas a recibir un aviso de Azure Service Health y una fecha límite. No existe la opción "lo actualizamos el trimestre que viene" — después de la fecha límite, los nuevos despliegues quedan bloqueados y con el tiempo la app se detiene. En IaaS el mismo EOL produce una CVE de la que sos dueño, no una fecha límite que tenés que cumplir. Este es un costo de ingeniería real, recurrente y planificable que pertenece a tu roadmap, y es el pasivo de PaaS más subestimado de todos.

**Costo 2 — Techo de diagnóstico.** No podés adjuntar `perf`, no podés leer `dmesg`, no podés tomar un core dump del kernel. Toda tu superficie de diagnóstico es lo que la plataforma decide emitir: logs HTTP, logs de plataforma, la consola Kudu y snapshots del profiler. Cuando la falla está por debajo de esa línea, tu camino de remediación es un ticket de soporte. Presupuestá un p99 de MTTR más alto para la falla profunda infrecuente, a cambio de muchas menos fallas en total.

### Stack PaaS completo — Bicep, sin truncar

```bicep
// infra/paas-stack.bicep
// A production PaaS application tier: App Service on a zone-redundant plan,
// Azure SQL Database with Entra-only auth, and the full observability chain.
// Compare its line count and its operational surface to iaas-baseline.bicep.
targetScope = 'resourceGroup'

@description('Deployment region.')
param location string = resourceGroup().location

@description('Workload name prefix.')
@minLength(3)
@maxLength(12)
param workload string = 'checkout'

@description('Environment discriminator.')
@allowed([
  'dev'
  'stg'
  'prod'
])
param env string = 'prod'

@description('Entra ID object ID of the group that administers the SQL server.')
param sqlAdminGroupObjectId string

@description('Display name of that Entra ID group.')
param sqlAdminGroupName string

@description('Runtime stack. Platform-owned: this value has a retirement date.')
param linuxFxVersion string = 'PYTHON|3.12'

var suffix       = '${workload}-${env}'
var planName     = 'asp-${suffix}'
var appName      = 'app-${suffix}'
var sqlServer    = 'sql-${suffix}-${uniqueString(resourceGroup().id)}'
var sqlDbName    = 'sqldb-${workload}'
var lawName      = 'law-${suffix}'
var appiName     = 'appi-${suffix}'
var zoneRedundant = env == 'prod'

// ---------------------------------------------------------------------------
// Observability. In PaaS this is wiring, not agent installation.
// ---------------------------------------------------------------------------
resource law 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: lawName
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 90
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appiName
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: law.id
    IngestionMode: 'LogAnalytics'
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

// ---------------------------------------------------------------------------
// The plan is the unit of billing AND the unit of zone redundancy.
// zoneRedundant: true is the entire multi-AZ design that took three
// deployments and a load balancer in the IaaS module.
// ---------------------------------------------------------------------------
resource plan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: planName
  location: location
  sku: {
    name: 'P1v3'
    tier: 'PremiumV3'
    capacity: zoneRedundant ? 3 : 1
  }
  kind: 'linux'
  properties: {
    reserved: true
    zoneRedundant: zoneRedundant
    perSiteScaling: false
  }
}

resource app 'Microsoft.Web/sites@2023-12-01' = {
  name: appName
  location: location
  kind: 'app,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    clientAffinityEnabled: false
    publicNetworkAccess: 'Enabled'
    siteConfig: {
      linuxFxVersion: linuxFxVersion
      alwaysOn: true
      http20Enabled: true
      minTlsVersion: '1.2'
      scmMinTlsVersion: '1.2'
      ftpsState: 'Disabled'
      healthCheckPath: '/healthz'
      numberOfWorkers: 3
      appCommandLine: 'gunicorn --bind 0.0.0.0:8000 --workers 4 --timeout 60 app.wsgi:application'
      // Shared responsibility, "network controls" row: these are YOUR controls
      // on a platform-managed front end.
      ipSecurityRestrictionsDefaultAction: 'Deny'
      ipSecurityRestrictions: [
        {
          name: 'allow-front-door'
          priority: 100
          action: 'Allow'
          tag: 'ServiceTag'
          ipAddress: 'AzureFrontDoor.Backend'
        }
      ]
      appSettings: [
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: appInsights.properties.ConnectionString
        }
        {
          name: 'ApplicationInsightsAgent_EXTENSION_VERSION'
          value: '~3'
        }
        {
          name: 'WEBSITES_ENABLE_APP_SERVICE_STORAGE'
          value: 'false'
        }
        {
          name: 'SCM_DO_BUILD_DURING_DEPLOYMENT'
          value: 'true'
        }
        {
          name: 'SQL_SERVER_FQDN'
          value: '${sqlServer}${environment().suffixes.sqlServerHostname}'
        }
        {
          name: 'SQL_DATABASE'
          value: sqlDbName
        }
      ]
    }
  }
}

resource appDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'diag-to-law'
  scope: app
  properties: {
    workspaceId: law.id
    logs: [
      {
        category: 'AppServiceHTTPLogs'
        enabled: true
      }
      {
        category: 'AppServiceConsoleLogs'
        enabled: true
      }
      {
        category: 'AppServiceAppLogs'
        enabled: true
      }
      {
        category: 'AppServicePlatformLogs'
        enabled: true
      }
      {
        category: 'AppServiceAuditLogs'
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

// A staging slot is a PaaS-native capability. The IaaS equivalent is a
// blue/green deployment pipeline you build and maintain yourself.
resource stagingSlot 'Microsoft.Web/sites/slots@2023-12-01' = {
  parent: app
  name: 'staging'
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    siteConfig: {
      linuxFxVersion: linuxFxVersion
      alwaysOn: true
      minTlsVersion: '1.2'
      ftpsState: 'Disabled'
      healthCheckPath: '/healthz'
      appCommandLine: 'gunicorn --bind 0.0.0.0:8000 --workers 2 --timeout 60 app.wsgi:application'
    }
  }
}

// ---------------------------------------------------------------------------
// Data tier. The engine, its patching, its HA and its backups are Microsoft's.
// The schema, the indexes, the data classification and the identity model
// are yours -- the "Information and data" row is never delegated.
// ---------------------------------------------------------------------------
resource sql 'Microsoft.Sql/servers@2021-11-01' = {
  name: sqlServer
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    minimalTlsVersion: '1.2'
    publicNetworkAccess: 'Enabled'
    administrators: {
      administratorType: 'ActiveDirectory'
      principalType: 'Group'
      login: sqlAdminGroupName
      sid: sqlAdminGroupObjectId
      tenantId: subscription().tenantId
      azureADOnlyAuthentication: true
    }
  }
}

resource sqlFirewallAzure 'Microsoft.Sql/servers/firewallRules@2021-11-01' = {
  parent: sql
  name: 'AllowAllWindowsAzureIps'
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '0.0.0.0'
  }
}

resource sqlDb 'Microsoft.Sql/servers/databases@2021-11-01' = {
  parent: sql
  name: sqlDbName
  location: location
  sku: {
    name: 'GP_Gen5_2'
    tier: 'GeneralPurpose'
    family: 'Gen5'
    capacity: 2
  }
  properties: {
    collation: 'SQL_Latin1_General_CP1_CI_AS'
    maxSizeBytes: 34359738368
    zoneRedundant: false
    requestedBackupStorageRedundancy: 'Geo'
    readScale: 'Disabled'
  }
}

resource sqlShortTermBackup 'Microsoft.Sql/servers/databases/backupShortTermRetentionPolicies@2021-11-01' = {
  parent: sqlDb
  name: 'default'
  properties: {
    retentionDays: 14
    diffBackupIntervalInHours: 12
  }
}

resource sqlLongTermBackup 'Microsoft.Sql/servers/databases/backupLongTermRetentionPolicies@2021-11-01' = {
  parent: sqlDb
  name: 'default'
  properties: {
    weeklyRetention: 'P8W'
    monthlyRetention: 'P12M'
    yearlyRetention: 'P7Y'
    weekOfYear: 1
  }
}

output appDefaultHostname string = app.properties.defaultHostName
output appPrincipalId string = app.identity.principalId
output slotPrincipalId string = stagingSlot.identity.principalId
output sqlFqdn string = sql.properties.fullyQualifiedDomainName
output appInsightsConnectionString string = appInsights.properties.ConnectionString
```

### El argumento del recuento de líneas, hecho numéricamente

```bash
$ wc -l infra/iaas-baseline.bicep infra/paas-stack.bicep
  312 infra/iaas-baseline.bicep
  289 infra/paas-stack.bicep
  601 total
```

Tamaño comparable — pero contá qué compra cada uno. `iaas-baseline.bicep` produce **una** VM en **una** zona, con **ninguna** aplicación, **ninguna** base de datos, **ningún** balanceador de carga, **ningún** deployment slot y **ninguna** política de backup. `paas-stack.bicep` produce una capa de aplicación **con redundancia de zona** de tres instancias, un **staging slot**, una **base de datos georredundante con recuperación a un punto en el tiempo y LTR de 7 años**, y un **pipeline de telemetría completo**. Esa proporción — aproximadamente 6:1 en capacidad entregada por línea de IaC — es la economía real de PaaS, y es la razón por la que las respuestas de "caso de uso apropiado" del examen se inclinan hacia PaaS cada vez que el escenario dice "minimizar el esfuerzo administrativo".

---

## 5. Serverless / FaaS — un modelo de consumo de PaaS, no un cuarto tipo de servicio

Serverless se enseña mal con frecuencia como par de IaaS/PaaS/SaaS. No lo es. **Serverless es un modelo de facturación y escalado aplicado a PaaS.** La matriz de responsabilidad es idéntica fila por fila a la de PaaS; lo que cambia es que la capacidad ociosa no se factura y la cantidad de instancias no es una propiedad configurable.

| Propiedad | PaaS clásico (App Service P1v3) | Serverless (Functions Consumption) |
|---|---|---|
| Unidad de facturación | Hora-instancia aprovisionada | GB-segundo + ejecuciones |
| Costo con tráfico cero | Costo completo del plan | ~Cero (aplica el grant gratuito) |
| Piso de escalado | ≥ 1 instancia | 0 instancias |
| Cold start | Ninguno (Always On) | 0,5–5 s, primer request tras la inactividad |
| Duración máxima de ejecución | Sin límite | Acotada (5 min por defecto, techo configurable) |
| Apropiado para | Tráfico estable y sensible a la latencia | Picudo, orientado a eventos, batch, pegamento |

### Medir el impuesto del cold start en lugar de afirmarlo

```bash
$ for i in 1 2 3; do \
    curl -s -o /dev/null \
      -w "attempt=$i  dns=%{time_namelookup}s  tcp=%{time_connect}s  tls=%{time_appconnect}s  ttfb=%{time_starttransfer}s  total=%{time_total}s\n" \
      https://func-checkout-prod.azurewebsites.net/api/quote; \
    sleep 1; \
  done
attempt=1  dns=0.021s  tcp=0.045s  tls=0.118s  ttfb=3.412s  total=3.415s
attempt=2  dns=0.001s  tcp=0.023s  tls=0.071s  ttfb=0.094s  total=0.096s
attempt=3  dns=0.001s  tcp=0.022s  tls=0.069s  ttfb=0.088s  total=0.090s
```

Que `ttfb` caiga de 3,41 s a 0,09 s entre requests por lo demás idénticos es el cold start, aislado: DNS, TCP y TLS están todos planos, así que el delta de 3,3 s es enteramente asignación de worker más inicialización del runtime. Si tu SLO es `p99 < 500 ms` en un endpoint de bajo tráfico, Consumption queda descalificado solo con estos datos, y la decisión de arquitectura es Flex Consumption con instancias preaprovisionadas, un plan Premium, o Container Apps con `minReplicas: 1`.

### Container Apps — contenedores serverless, declarados

Container Apps es la forma PaaS más instructiva para una audiencia SRE: expone semántica derivada de Kubernetes (probes, revisiones, réplicas, escaladores KEDA) manteniendo todo el clúster del lado del proveedor en la línea de responsabilidad.

```yaml
# containerapp-checkout.yaml
# Deploy with:  az containerapp create -g rg-paas-prod -n ca-checkout --yaml containerapp-checkout.yaml
# Note what is ABSENT: no node pool, no kubelet version, no CNI choice,
# no control-plane upgrade. Those layers exist -- they are simply not yours.
location: eastus
type: Microsoft.App/containerApps
name: ca-checkout
resourceGroup: rg-paas-prod
identity:
  type: SystemAssigned
properties:
  managedEnvironmentId: /subscriptions/8f1c2d40-6a1b-4e77-9c3a-2b5d81f0a4e9/resourceGroups/rg-paas-prod/providers/Microsoft.App/managedEnvironments/cae-prod
  workloadProfileName: Consumption
  configuration:
    activeRevisionsMode: Multiple
    maxInactiveRevisions: 5
    ingress:
      external: true
      targetPort: 8080
      exposedPort: 0
      transport: auto
      allowInsecure: false
      clientCertificateMode: ignore
      stickySessions:
        affinity: none
      traffic:
        - revisionName: ca-checkout--v1-14-2
          weight: 90
          label: stable
        - latestRevision: true
          weight: 10
          label: canary
      corsPolicy:
        allowedOrigins:
          - https://shop.contoso.com
        allowedMethods:
          - GET
          - POST
        allowCredentials: true
    registries:
      - server: crprod.azurecr.io
        identity: system
    secrets:
      - name: sql-conn
        keyVaultUrl: https://kv-checkout-prod.vault.azure.net/secrets/sql-conn
        identity: system
  template:
    revisionSuffix: v1-14-2
    terminationGracePeriodSeconds: 45
    containers:
      - image: crprod.azurecr.io/checkout:1.14.2
        name: checkout
        resources:
          cpu: 0.5
          memory: 1Gi
        env:
          - name: SQL_CONNECTION
            secretRef: sql-conn
          - name: OTEL_SERVICE_NAME
            value: checkout
          - name: LOG_LEVEL
            value: info
        probes:
          - type: Startup
            httpGet:
              path: /healthz
              port: 8080
              scheme: HTTP
            initialDelaySeconds: 3
            periodSeconds: 3
            failureThreshold: 20
            timeoutSeconds: 2
          - type: Liveness
            httpGet:
              path: /healthz
              port: 8080
              scheme: HTTP
            periodSeconds: 10
            failureThreshold: 3
            timeoutSeconds: 2
          - type: Readiness
            httpGet:
              path: /ready
              port: 8080
              scheme: HTTP
            periodSeconds: 5
            failureThreshold: 3
            successThreshold: 1
            timeoutSeconds: 2
    scale:
      minReplicas: 1
      maxReplicas: 30
      rules:
        - name: http-concurrency
          http:
            metadata:
              concurrentRequests: "50"
        - name: queue-depth
          custom:
            type: azure-servicebus
            identity: system
            metadata:
              queueName: checkout-events
              namespace: sb-checkout-prod
              messageCount: "20"
```

`minReplicas: 1` es la mitigación del cold start hecha explícita y con precio: elegiste pagar por una réplica siempre caliente para comprar un SLO de latencia. Ese es el trade-off de serverless escrito como una sola línea de YAML.

---

## 6. SaaS — consumo con una superficie de configuración

SaaS entrega una aplicación completa. Microsoft 365, Dynamics 365, GitHub Enterprise Cloud y la experiencia de usuario final de Microsoft Entra ID son SaaS. Toda tu superficie de ingeniería es:

- **Configuración del tenant** — políticas, reglas de compartición, retención, DLP
- **Identidad y acceso** — quién existe, qué puede alcanzar, Conditional Access
- **Datos** — su clasificación, su residencia, su ciclo de vida, su vía de exportación
- **Integración** — APIs, webhooks, conectores hacia tus propios sistemas

No desplegás, ni parcheás, ni escalás, ni versionás SaaS. No podés revertir el lanzamiento de una funcionalidad del proveedor. El costo de salida es la migración de datos, y es el riesgo de lock-in dominante del modelo.

### La falla de SaaS que más se atribuye mal

Una organización pierde un buzón por un compromiso de correo corporativo (BEC). El análisis de causa raíz culpa "al proveedor de nube". Revisá la matriz: **Cuentas e identidades** es una fila del cliente en todos los modelos, SaaS incluido. La obligación del proveedor era poner MFA y Conditional Access a disposición; la obligación del cliente era imponerlos. Verificá la imposición, no la asumas:

```bash
$ az rest --method get \
    --url "https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies?\$select=displayName,state" \
    --resource "https://graph.microsoft.com" \
    --query "value[].{policy:displayName, state:state}" -o table

Policy                                        State
--------------------------------------------  --------
Require MFA for all users                      enabled
Block legacy authentication                    enabled
Require compliant device for admin roles       enabledForReportingButNotEnforced
Require MFA for Azure management               enabled
```

Esa tercera fila es un hallazgo de producción. `enabledForReportingButNotEnforced` significa que la política está en modo solo-informe y no bloquea nada. Bajo el contrato de responsabilidad compartida de SaaS, un compromiso de rol administrativo a través de esa brecha recae enteramente en el cliente.

---

## 7. El medio ambiguo: AKS, y por qué "gestionado" no es un tipo de servicio

AKS es el caso donde la taxonomía de tres baldes visiblemente se tensa, y donde un ingeniero preciso se separa de uno memorizador. **AKS no es un tipo de servicio; es una frontera de tipo de servicio trazada por el medio de un único producto.**

| Capa de AKS | Propietario | Tipo de servicio de esa capa |
|---|---|---|
| etcd, API server, scheduler, controller-manager | Microsoft | PaaS (el nivel gratuito no tiene SLA; los niveles Standard/Premium llevan el SLA de disponibilidad) |
| Parcheo del plano de control y disponibilidad de versiones menores | Microsoft | PaaS |
| Imágenes de VM del node pool, kernel, versión de kubelet | **El cliente dispara, Microsoft provee** | Compartido |
| Parcheo de seguridad del SO de los nodos y reinicios | **Cliente** (salvo que se configure el auto-upgrade de nodos) | IaaS |
| Plugin CNI, elección del motor de network policy | **Cliente** | IaaS |
| Cargas de trabajo, manifiestos, resource requests, PDB | **Cliente** | Equivalente a IaaS |
| Configuración del cluster autoscaler | **Cliente** | IaaS |

Comprobá la división contra el clúster en vivo:

```bash
$ az aks show -g rg-k8s-prod -n aks-prod-eastus \
    --query "{version:kurrentKubernetesVersion, sku:sku.tier, \
              autoUpgrade:autoUpgradeProfile.upgradeChannel, \
              nodeOsUpgrade:autoUpgradeProfile.nodeOsUpgradeChannel, \
              cni:networkProfile.networkPlugin, \
              policy:networkProfile.networkPolicy}" -o json 2>/dev/null

$ az aks show -g rg-k8s-prod -n aks-prod-eastus \
    --query "{version:currentKubernetesVersion, sku:sku.tier, \
              autoUpgrade:autoUpgradeProfile.upgradeChannel, \
              nodeOsUpgrade:autoUpgradeProfile.nodeOsUpgradeChannel, \
              cni:networkProfile.networkPlugin, \
              policy:networkProfile.networkPolicy}" -o json
{
  "autoUpgrade": "stable",
  "cni": "azure",
  "nodeOsUpgrade": "NodeImage",
  "policy": "cilium",
  "sku": "Standard",
  "version": "1.31.3"
}
```

```bash
$ kubectl get nodes -o wide
NAME                                 STATUS   ROLES    AGE   VERSION   INTERNAL-IP   EXTERNAL-IP   OS-IMAGE             KERNEL-VERSION      CONTAINER-RUNTIME
aks-system-24817392-vmss000000       Ready    <none>   19d   v1.31.3   10.244.0.4    <none>        Ubuntu 22.04.5 LTS   5.15.0-1073-azure   containerd://1.7.23
aks-system-24817392-vmss000001       Ready    <none>   19d   v1.31.3   10.244.0.35   <none>        Ubuntu 22.04.5 LTS   5.15.0-1073-azure   containerd://1.7.23
aks-user-38104462-vmss000004         Ready    <none>   6d    v1.31.3   10.244.1.9    <none>        Ubuntu 22.04.5 LTS   5.15.0-1073-azure   containerd://1.7.23
aks-user-38104462-vmss000005         Ready    <none>   6d    v1.31.3   10.244.1.66   <none>        Ubuntu 22.04.5 LTS   5.15.0-1073-azure   containerd://1.7.23

$ kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.nodeInfo.kernelVersion}{"\n"}{end}' | sort -u -k2
aks-system-24817392-vmss000000	5.15.0-1073-azure
```

**Podés ver la versión del kernel.** Esa es la señal: una capa que podés observar con esa granularidad es una capa cuyas fallas son tuyas. En App Service no existe una introspección equivalente a `kubectl` — esa capa no está meramente oculta, *no es tu responsabilidad*.

Concretamente: cuando una regresión de `containerd` causa fallas de pull de imágenes en tu node pool, AKS te deja a cargo de la actualización de la imagen de nodo. Cuando el mismo tipo de bug golpea App Service, nunca te enterás de que pasó.

### La mitad de carga de trabajo de la frontera, completa

```yaml
# k8s/checkout-deployment.yaml
# Everything in this file is on the CUSTOMER side of the AKS responsibility
# split. The scheduler that acts on it is on Microsoft's side.
apiVersion: apps/v1
kind: Deployment
metadata:
  name: checkout
  namespace: shop
  labels:
    app.kubernetes.io/name: checkout
    app.kubernetes.io/version: "1.14.2"
    app.kubernetes.io/component: api
spec:
  replicas: 4
  revisionHistoryLimit: 5
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 0
      maxSurge: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: checkout
  template:
    metadata:
      labels:
        app.kubernetes.io/name: checkout
        app.kubernetes.io/version: "1.14.2"
        azure.workload.identity/use: "true"
    spec:
      serviceAccountName: checkout-sa
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        fsGroup: 10001
        seccompProfile:
          type: RuntimeDefault
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: checkout
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: checkout
      containers:
        - name: checkout
          image: crprod.azurecr.io/checkout:1.14.2
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 8080
              protocol: TCP
          env:
            - name: OTEL_SERVICE_NAME
              value: checkout
            - name: SQL_SERVER_FQDN
              valueFrom:
                configMapKeyRef:
                  name: checkout-config
                  key: sqlServerFqdn
          resources:
            requests:
              cpu: 250m
              memory: 512Mi
            limits:
              memory: 1Gi
          startupProbe:
            httpGet:
              path: /healthz
              port: http
            periodSeconds: 3
            failureThreshold: 20
          livenessProbe:
            httpGet:
              path: /healthz
              port: http
            periodSeconds: 10
            failureThreshold: 3
          readinessProbe:
            httpGet:
              path: /ready
              port: http
            periodSeconds: 5
            failureThreshold: 3
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop:
                - ALL
          volumeMounts:
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: tmp
          emptyDir:
            sizeLimit: 256Mi
---
apiVersion: v1
kind: Service
metadata:
  name: checkout
  namespace: shop
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: checkout
  ports:
    - name: http
      port: 80
      targetPort: http
      protocol: TCP
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: checkout
  namespace: shop
spec:
  minAvailable: 3
  selector:
    matchLabels:
      app.kubernetes.io/name: checkout
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: checkout
  namespace: shop
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: checkout
  minReplicas: 4
  maxReplicas: 24
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 65
  behavior:
    scaleDown:
      stabilizationWindowSeconds: 300
      policies:
        - type: Percent
          value: 50
          periodSeconds: 60
    scaleUp:
      stabilizationWindowSeconds: 0
      policies:
        - type: Percent
          value: 100
          periodSeconds: 30
```

El `PodDisruptionBudget` es la ilustración más filosa de la frontera compartida en todo el dominio. El auto-upgrade de nodos de Microsoft va a drenar tus nodos según *su* cronograma; tu PDB es el único mecanismo que impide que esa acción del lado del proveedor tire abajo tu servicio. Una fila de responsabilidad compartida es segura solo cuando el lado del cliente está efectivamente configurado.

---

## 8. Tablas de trade-offs

### 8.1 Control, esfuerzo y radio de impacto

| Dimensión | IaaS | PaaS | PaaS serverless | SaaS |
|---|---|---|---|---|
| Control a nivel de SO | Total | Ninguno | Ninguno | Ninguno |
| Fijado de versión del runtime | Arbitrario, indefinido | Lista soportada por la plataforma, con fecha de retiro | Igual | Ninguno |
| Tiempo hasta el primer despliegue en producción | Días–semanas | Horas | Minutos | Minutos (solo configuración) |
| FTE de operación continua (indicativo) | 0,5–2,0 por carga de trabajo | 0,1–0,3 | 0,05–0,15 | ~0,05 |
| Superficie de parches/CVE propia | Kernel + runtime + app | Solo la app | Solo la app | Ninguna |
| Diagnóstico profundo (`perf`, core dumps, `strace`) | Sí | No | No | No |
| MTTR para fallas comunes | Más alto (más piezas móviles) | Más bajo | El más bajo | Atado al proveedor |
| Techo de MTTR para fallas profundas infrecuentes | Acotado por tu habilidad | Acotado por el SLA de soporte | Acotado por el SLA de soporte | Acotado por el SLA de soporte |
| Portabilidad / costo de salida | El costo más bajo (una imagen de VM es una imagen de VM) | Medio (configuración específica de la plataforma) | Alto (los bindings de trigger son propietarios) | El más alto (salida solo con datos) |
| Esfuerzo de evidencia de cumplimiento | El más alto (vos atestiguás el SO) | Medio (heredás las atestaciones del proveedor) | Medio | El más bajo |

### 8.2 Forma del costo — el punto de cruce es real y calculable

| Patrón de tráfico | Modelo más barato | Por qué |
|---|---|---|
| Plano 24×7, alta utilización | IaaS con reservas / savings plan | Los compromisos a 1 y 3 años descuentan fuerte; amortizás el costo operativo sobre carga constante |
| Horario comercial, predecible | PaaS con escalado programado | Pagás capacidad aprovisionada solo dentro de la ventana |
| Picudo, bajo ciclo de trabajo (<15%) | Serverless | El ocio no se factura; el cold start es el precio |
| Impredecible, en ráfagas, basado en contenedores | Container Apps (mín. 0–1) | Escala a cero con KEDA, con opción de piso caliente |
| Cualquier patrón, capacidad no diferenciadora | SaaS | El costo por asiento le gana a construirlo y operarlo |

**Punto de cruce, calculado.** Una API en Python que sirve 2M de requests/mes con 120 ms de tiempo medio de CPU:

- *Serverless:* ≈ 2M × 0,12 s × 0,5 GB = **120.000 GB-s** más 2M de ejecuciones. Cómodamente dentro de una factura mensual chica; escala linealmente con el tráfico.
- *PaaS (P1v3, always on, 1 instancia):* costo mensual fijo sin importar si el tráfico es de 2M o de 200 requests.
- *Punto de cruce:* donde la factura de GB-s se encuentra con el precio fijo del plan. **Por debajo** de ese punto, serverless gana en costo y pierde en p99. **Por encima**, el aprovisionado gana en ambos.

Calculá el punto de cruce con tus propias métricas en lugar de adivinar:

```bash
$ az monitor metrics list \
    --resource "/subscriptions/8f1c2d40-6a1b-4e77-9c3a-2b5d81f0a4e9/resourceGroups/rg-paas-prod/providers/Microsoft.Web/sites/app-checkout-prod" \
    --metric "Requests" "AverageResponseTime" \
    --interval PT1H --start-time 2026-08-28T00:00:00Z --end-time 2026-09-04T00:00:00Z \
    --aggregation Total Average --output table | head -12

Timestamp            Name                    Total    Average
-------------------  --------------------  -------  ---------
2026-08-28 00:00:00  Requests                 1204
2026-08-28 01:00:00  Requests                  876
2026-08-28 02:00:00  Requests                  651
2026-08-28 03:00:00  Requests                  598
2026-08-28 08:00:00  Requests                18442
2026-08-28 09:00:00  Requests                31207
2026-08-28 12:00:00  Requests                29883
2026-08-28 18:00:00  Requests                 7115
2026-08-28 23:00:00  Requests                 1902
```

Una relación pico-valle de 52× (598 → 31.207) es el argumento cuantitativo a favor de escalar a cero o de un autoescalado agresivo. Si la relación hubiera sido de 1,4×, la capacidad aprovisionada sería lo correcto y cualquier reescritura a serverless sería una regresión de costo pagada con latencia de cold start.

### 8.3 SLA compuesto — la aritmética que mata los diseños PaaS ingenuos

SLA de Azure publicados al momento de escribir esto (verificá siempre contra el documento de SLA vigente, que está versionado y cambia):

| Servicio | SLA publicado |
|---|---|
| App Service (Basic y superiores) | 99,95% |
| Azure SQL Database, General Purpose | 99,99% |
| Azure Cache for Redis (Standard/Premium) | 99,9% |
| Azure Storage (lectura RA-GRS) | 99,99% |
| Azure Container Apps | 99,95% |
| VM, instancia única, Premium SSD | 99,9% |

Las dependencias en serie **se multiplican**:

```
App Service (0.9995) × SQL DB (0.9999) × Redis (0.999) × Storage (0.9999)
  = 0.99830...
  = 99.83% composite
```

```bash
$ python3 -c "
slas = {'App Service': 0.9995, 'Azure SQL DB': 0.9999, 'Redis': 0.999, 'Storage': 0.9999}
c = 1.0
for name, s in slas.items():
    c *= s
    print(f'{name:<16} {s:.4%}   running composite: {c:.4%}')
mins = (1 - c) * 43200
print(f'\ncomposite SLA        : {c:.4%}')
print(f'monthly error budget : {mins:.1f} minutes')
"
App Service      99.9500%   running composite: 99.9500%
Azure SQL DB     99.9900%   running composite: 99.9400%
Redis            99.9000%   running composite: 99.8401%
Storage          99.9900%   running composite: 99.8301%

composite SLA        : 99.8301%
monthly error budget : 73.4 minutes
```

**73 minutos/mes, no 22.** Cada servicio PaaS que agregás a la ruta crítica gasta presupuesto de error. Este es el argumento técnico más fuerte contra el reflejo de "usemos más servicios gestionados": cada uno es un término de SLA separado, un calendario de mantenimiento del proveedor separado y un dominio de falla separado que no podés inspeccionar. La mitigación es arquitectónica — cache-aside para que Redis sea opcional, circuit breakers y degradación elegante — no un tipo de servicio distinto.

### 8.4 Mapeo de servicios de Azure a tipos de servicio (crítico para el examen)

| Servicio de Azure | Tipo de servicio | Discriminador |
|---|---|---|
| Virtual Machines, VM Scale Sets | **IaaS** | Vos parcheás el SO invitado |
| Virtual Network, NSG, Load Balancer, Route Table | **IaaS** | Primitivos de red crudos |
| Managed Disks, Azure Files (como montaje) | **IaaS** | Primitivos de almacenamiento crudos |
| Azure App Service (Web Apps, API Apps) | **PaaS** | Runtime gestionado; sin acceso al SO |
| Azure Functions | **PaaS** (serverless) | Runtime gestionado, facturación orientada a eventos |
| Azure Container Apps | **PaaS** (contenedores serverless) | Kubernetes gestionado por debajo, oculto |
| Azure SQL Database, Cosmos DB, Database for PostgreSQL | **PaaS** | Motor gestionado; solo sos dueño del esquema y los datos |
| Azure Kubernetes Service | **Híbrido** — plano de control PaaS, node pools IaaS | Seguís parcheando las imágenes de SO de los nodos |
| Azure Logic Apps, Azure Data Factory | **PaaS** | Runtime de orquestación gestionado |
| Azure Blob Storage (vía API) | **PaaS** | Consumido como servicio gestionado, no como disco montado |
| Microsoft 365, Dynamics 365 | **SaaS** | Aplicación terminada |
| Microsoft Entra ID (experiencia de usuario final) | **SaaS** | Aplicación de identidad terminada |
| GitHub Enterprise Cloud, Azure DevOps Services | **SaaS** | Aplicación terminada |

**Heurística de examen, en orden de prioridad:**
1. *"¿Quién parchea el SO?"* → Cliente = IaaS. Proveedor = PaaS o SaaS.
2. *"¿Escribo código?"* → Sí = IaaS o PaaS. No = SaaS.
3. *"¿Elijo la cantidad de instancias?"* → Sí = IaaS o PaaS clásico. No = PaaS serverless.
4. El escenario dice *"minimizar la sobrecarga administrativa"* / *"sin infraestructura que gestionar"* → PaaS o SaaS, nunca IaaS.
5. El escenario dice *"lift and shift"* / *"control total sobre el SO"* / *"módulo de kernel personalizado"* / *"aplicación heredada sin cambios"* → IaaS.

---

## 9. Verificación y diagnóstico de fallas

### 9.1 La pregunta de triaje que precede a todas las demás

Antes de tocar los logs, respondé: **¿la capa que falla está de mi lado de la línea de responsabilidad?** La respuesta encamina el incidente entero. Preguntale a la plataforma, no lo infieras.

```bash
$ az rest --method get \
    --url "https://management.azure.com/subscriptions/8f1c2d40-6a1b-4e77-9c3a-2b5d81f0a4e9/resourceGroups/rg-paas-prod/providers/Microsoft.Web/sites/app-checkout-prod/providers/Microsoft.ResourceHealth/availabilityStatuses/current?api-version=2022-10-01" \
    --query "properties.{status:availabilityState, summary:summary, reason:reasonType, since:occuredTime}" -o json
{
  "reason": "PlatformInitiated",
  "since": "2026-09-04T09:12:44.0000000Z",
  "status": "Degraded",
  "summary": "We are sorry, your resource is impacted by an ongoing platform issue. Engineers are engaged."
}
```

`reasonType: PlatformInitiated` con `status: Degraded` significa que la falla está del lado de **Microsoft** de la línea. Tu acción correcta es abrir un caso de soporte, comunicar a las partes interesadas y *dejar de depurar tu aplicación*. Comparalo con:

```bash
$ az rest --method get \
    --url ".../virtualMachines/vm-appiaas-1/providers/Microsoft.ResourceHealth/availabilityStatuses/current?api-version=2022-10-01" \
    --query "properties.{status:availabilityState, reason:reasonType}" -o json
{
  "reason": "Unknown",
  "status": "Available"
}
```

Que la plataforma diga `Available` mientras tu servicio está caído significa que la falla está **por encima** de la línea del hipervisor — SO invitado, runtime o aplicación. En IaaS, eso es enteramente tuyo.

### 9.2 Escalera de diagnóstico de IaaS

Ordenada de lo más barato a lo más invasivo. No te saltees escalones.

```bash
# Rung 1 -- is the platform even running the VM?
$ az vm get-instance-view -g rg-iaas-prod -n vm-appiaas-1 \
    --query "instanceView.statuses[].{code:code, level:level, message:displayStatus}" -o table
Code                              Level    Message
--------------------------------  -------  ---------------
ProvisioningState/succeeded       Info     Provisioning succeeded
PowerState/running                Info     VM running
```

```bash
# Rung 2 -- did the guest OS boot at all? Serial console output.
$ az vm boot-diagnostics get-boot-log -g rg-iaas-prod -n vm-appiaas-1 | tail -20
[   14.882031] cloud-init[1104]: Cloud-init v. 24.1.3 finished at Thu, 04 Sep 2026 09:03:12 +0000
[   15.001744] systemd[1]: Started Serial Getty on ttyS0.
[  102.334819] systemd[1]: checkout.service: Main process exited, code=exited, status=1/FAILURE
[  102.334902] systemd[1]: checkout.service: Failed with result 'exit-code'.
[  102.335044] systemd[1]: checkout.service: Scheduled restart job, restart counter is at 5.
[  102.335901] systemd[1]: checkout.service: Start request repeated too quickly.
[  102.336012] systemd[1]: checkout.service: Failed with result 'exit-code'.
[  102.336118] systemd[1]: Failed to start Checkout API.
```

La VM está sana en la capa del hipervisor; la unidad de la aplicación está en bucle de caídas. Esta es una falla exclusivamente del lado del cliente — y este diagnóstico *solo existe porque habilitaste los diagnósticos de arranque en el Bicep al momento del aprovisionamiento*. Habilitalos antes del incidente, no durante.

```bash
# Rung 3 -- execute in-guest without SSH (works even with a broken sshd or NSG).
$ az vm run-command invoke -g rg-iaas-prod -n vm-appiaas-1 \
    --command-id RunShellScript \
    --scripts "systemctl status checkout --no-pager -l | head -30; echo '---'; journalctl -u checkout -n 25 --no-pager" \
    --query "value[0].message" -o tsv

Enable succeeded:
[stdout]
× checkout.service - Checkout API
     Loaded: loaded (/etc/systemd/system/checkout.service; enabled; preset: enabled)
     Active: failed (Result: exit-code) since Thu 2026-09-04 09:05:02 UTC; 3min 41s ago
    Process: 1447 ExecStart=/opt/checkout/venv/bin/gunicorn --bind 0.0.0.0:8443 app.wsgi:application (code=exited, status=1/FAILURE)
   Main PID: 1447 (code=exited, status=1/FAILURE)
        CPU: 412ms
---
Sep 04 09:05:02 vm-appiaas-1 gunicorn[1447]: [ERROR] Can't connect to MySQL server on 'sql-checkout-prod.mysql.database.azure.com' (110)
Sep 04 09:05:02 vm-appiaas-1 gunicorn[1447]: OperationalError: (2003, "Can't connect to MySQL server (timed out)")
Sep 04 09:05:02 vm-appiaas-1 systemd[1]: checkout.service: Main process exited, code=exited, status=1/FAILURE

[stderr]
```

`errno 110` es `ETIMEDOUT` — un descarte silencioso, no un rechazo. `ECONNREFUSED` significaría que el paquete llegó a un host sin nada escuchando; un timeout significa que el paquete fue tragado. En IaaS, "controles de red" es una fila del cliente, así que sospechá de tu propio NSG o del firewall de la base de datos antes de sospechar de la plataforma:

```bash
$ az network nsg rule list -g rg-iaas-prod --nsg-name nsg-appiaas-app --include-default \
    -o table --query "sort_by([?direction=='Outbound'], &priority)[].{Name:name, Pri:priority, Access:access, Dst:destinationAddressPrefix, Port:destinationPortRange}"
Name                              Pri    Access    Dst                 Port
--------------------------------  -----  --------  ------------------  ------
allow-outbound-to-azure-monitor     200  Allow     AzureMonitor        443
AllowVnetOutBound                 65000  Allow     VirtualNetwork      *
AllowInternetOutBound             65001  Allow     Internet            *
DenyAllOutBound                   65500  Deny      *                   *
```

La salida hacia Internet está permitida con prioridad 65001, así que el NSG no es la causa. Escalá a las rutas efectivas y al firewall del lado PaaS:

```bash
$ az network nic show-effective-route-table -g rg-iaas-prod -n nic-appiaas-1 -o table
Source                 State    Address Prefix    Next Hop Type     Next Hop IP
---------------------  -------  ----------------  ----------------  -------------
Default                Active   10.42.0.0/16      VnetLocal
Default                Active   0.0.0.0/0         Internet
User                   Active   0.0.0.0/0         VirtualAppliance  10.42.9.4
```

Ahí está. Una ruta definida por el usuario envía todo el egreso a un appliance de firewall en `10.42.9.4` que le gana al default del sistema. La base de datos es inalcanzable porque el NVA está descartando el flujo. La causa raíz está en una capa que existe **únicamente** en IaaS — una clase de incidente que PaaS hace estructuralmente imposible, porque no sos dueño de la tabla de rutas.

### 9.3 Escalera de diagnóstico de PaaS

La escalera es más corta, porque hay menos escalones que tenés permitido subir.

```bash
# Rung 1 -- platform view of the app
$ az webapp show -g rg-paas-prod -n app-checkout-prod \
    --query "{state:state, availability:availabilityState, https:httpsOnly, health:siteConfig.healthCheckPath, workers:siteConfig.numberOfWorkers}" -o table
State      Availability    Https    Health     Workers
---------  --------------  -------  ---------  ---------
Running    Normal          True     /healthz   3
```

```bash
# Rung 2 -- live log stream. This is the PaaS equivalent of `journalctl -f`.
$ az webapp log tail -g rg-paas-prod -n app-checkout-prod
2026-09-04T09:14:02  Startup Command: gunicorn --bind 0.0.0.0:8000 --workers 4 --timeout 60 app.wsgi:application
2026-09-04T09:14:03  [INFO] Starting gunicorn 22.0.0
2026-09-04T09:14:03  [INFO] Listening at: http://0.0.0.0:8000 (8)
2026-09-04T09:14:04  [INFO] Booting worker with pid: 11
2026-09-04T09:14:19  [ERROR] pyodbc.OperationalError: ('HYT00', '[HYT00] [Microsoft][ODBC Driver 18 for SQL Server]Login timeout expired (0)')
2026-09-04T09:14:19  Container app-checkout-prod_0 didn't respond to HTTP pings on port: 8000, failing site start
2026-09-04T09:14:20  Stopping site app-checkout-prod because it failed during startup.
```

```bash
# Rung 3 -- the PaaS-native root-cause check for exactly this error class.
$ az sql server show -g rg-paas-prod -n sql-checkout-prod-k3f9a2md \
    --query "{publicAccess:publicNetworkAccess, tls:minimalTlsVersion, entraOnly:administrators.azureADOnlyAuthentication}" -o table
PublicAccess    Tls    EntraOnly
--------------  -----  -----------
Disabled        1.2    True

$ az webapp config access-restriction show -g rg-paas-prod -n app-checkout-prod \
    --query "{vnetRoute:scmIpSecurityRestrictionsUseMain}" -o tsv

$ az webapp vnet-integration list -g rg-paas-prod -n app-checkout-prod -o table
(empty)
```

Causa raíz: SQL tiene `publicNetworkAccess: Disabled` (correcto, endurecido) mientras que el App Service **no** tiene integración con VNet, así que solo puede alcanzar SQL por el endpoint público que ya no existe. La falla cae de lleno en la fila *compartida* de "controles de red": Microsoft opera la red, vos no configuraste tu parte. Corrección:

```bash
$ az webapp vnet-integration add -g rg-paas-prod -n app-checkout-prod \
    --vnet vnet-paas-prod --subnet snet-appsvc-integration -o table
Id                                                                              Name
------------------------------------------------------------------------------  ----------------------
/subscriptions/8f1c.../sites/app-checkout-prod/config/virtualNetwork             VirtualNetwork

$ az webapp restart -g rg-paas-prod -n app-checkout-prod
$ curl -s -o /dev/null -w "%{http_code} %{time_total}s\n" https://app-checkout-prod.azurewebsites.net/healthz
200 0.184s
```

Notá lo que *no* pudiste hacer en ningún momento: nada de `tcpdump`, nada de `strace`, nada de `ss -tnp`, ningún log de kernel. La escalera de diagnóstico de PaaS tiene tres escalones y después el techo.

### 9.4 KQL — probar la responsabilidad desde la telemetría

Cada consulta de abajo es respondible en exactamente un tipo de servicio, y eso mismo es el punto.

```kusto
// IaaS ONLY. Guest OS patch compliance is a question PaaS cannot even express.
Update
| where TimeGenerated > ago(1d)
| where Classification in ("Critical Updates", "Security Updates")
| where UpdateState == "Needed" and Optional == false
| summarize MissingPatches = count(),
            Oldest = min(PublishedDate)
        by Computer, Classification
| extend DaysExposed = datetime_diff('day', now(), Oldest)
| where DaysExposed > 30
| order by DaysExposed desc
```

```kusto
// PaaS. The platform emits this for you; there is no agent to install or debug.
AppServiceHTTPLogs
| where TimeGenerated > ago(6h)
| summarize
    rps          = count() / 300.0,
    p50          = percentile(TimeTaken, 50),
    p95          = percentile(TimeTaken, 95),
    p99          = percentile(TimeTaken, 99),
    errorRate    = round(100.0 * countif(ScStatus >= 500) / count(), 3)
  by bin(TimeGenerated, 5m), CsHost
| order by TimeGenerated desc
```

```kusto
// PaaS. Cold-start attribution: separate platform container start from app init.
AppServicePlatformLogs
| where TimeGenerated > ago(24h)
| where Message has_any ("Starting container", "Initiating warmup request", "Container is ready")
| project TimeGenerated, ContainerId = tostring(split(Message, " ")[2]), Message
| summarize
    started = minif(TimeGenerated, Message has "Starting container"),
    ready   = maxif(TimeGenerated, Message has "Container is ready")
  by ContainerId
| where isnotempty(started) and isnotempty(ready)
| extend startupSeconds = datetime_diff('millisecond', ready, started) / 1000.0
| summarize p50 = percentile(startupSeconds, 50), p95 = percentile(startupSeconds, 95), n = count()
```

```kusto
// AKS. Answerable BECAUSE node OS is a customer-side layer -- the query
// has no equivalent on App Service or Container Apps.
KubeNodeInventory
| where TimeGenerated > ago(1h)
| summarize arg_max(TimeGenerated, Status, KubeletVersion) by Computer
| join kind=leftouter (
    KubeEvents
    | where TimeGenerated > ago(24h)
    | where Reason in ("NodeNotReady", "KubeletHasDiskPressure", "KubeletHasInsufficientMemory")
    | summarize events = count() by Computer = Name, Reason
  ) on Computer
| project Computer, Status, KubeletVersion, Reason, events
| order by events desc nulls last
```

### 9.5 Tabla de enrutamiento falla-a-responsable

| Síntoma | Responsable en IaaS | Responsable en PaaS | Responsable en SaaS | Primer comando |
|---|---|---|---|---|
| El host se reinicia inesperadamente | Microsoft (mantenimiento) | Microsoft | Microsoft | `az vm get-instance-view` → `instanceView.maintenanceRedeployStatus` |
| Kernel panic del SO invitado | **Vos** | N/A | N/A | `az vm boot-diagnostics get-boot-log` |
| CVE sin parchear en el runtime | **Vos** | Microsoft | Microsoft | `az vm run-command invoke ... "apt list --upgradable"` |
| Runtime retirado por la fuerza | N/A | **Tenés que migrar** | N/A | `az webapp list-runtimes --os linux` |
| La app devuelve 500 | **Vos** | **Vos** | Proveedor | `az webapp log tail` / `journalctl -u <svc>` |
| No se puede alcanzar la base de datos | **Vos** (NSG/UDR) | **Compartido** (integración con VNet) | Proveedor | `az network nic show-effective-route-table` |
| Cifrado TLS deprecado | **Vos** | Microsoft | Microsoft | `az webapp config show --query minTlsVersion` |
| Cuenta de storage con throttling (429) | Compartido (tu patrón de acceso) | Compartido | N/A | `az monitor metrics list --metric Throttling` |
| Credencial phisheada, sin MFA | **Vos** | **Vos** | **Vos** | Graph: estado de la política de Conditional Access |
| Datos borrados por un usuario autorizado | **Vos** | **Vos** | **Vos** | Restaurar desde *tu* política de backup |

Las dos últimas filas nunca cambian de responsable en toda la tabla. Ese es el Invariante 1, expresado operativamente.

### 9.6 Checklist de verificación para una decisión de tipo de servicio

Ejecutá esto antes de firmar una arquitectura. Cada punto es un comando, no una opinión.

```bash
# 1. Enumerate every SLA term on the critical path, then multiply them.
$ az resource list -g rg-paas-prod --query "[].{name:name, type:type}" -o table
Name                          Type
----------------------------  -----------------------------------
asp-checkout-prod             Microsoft.Web/serverFarms
app-checkout-prod             Microsoft.Web/sites
sql-checkout-prod-k3f9a2md    Microsoft.Sql/servers
law-checkout-prod             Microsoft.OperationalInsights/workspaces
appi-checkout-prod            Microsoft.Insights/components

# 2. Confirm zone redundancy is actually ON, not merely available in the region.
$ az appservice plan show -g rg-paas-prod -n asp-checkout-prod \
    --query "{sku:sku.name, capacity:sku.capacity, zoneRedundant:properties.zoneRedundant}" -o table
Sku    Capacity    ZoneRedundant
-----  ----------  ---------------
P1v3   3           True

# 3. Confirm a backup/restore path exists and its RPO is what you claimed.
$ az sql db show -g rg-paas-prod -s sql-checkout-prod-k3f9a2md -n sqldb-checkout \
    --query "{earliestRestore:earliestRestoreDate, redundancy:currentBackupStorageRedundancy}" -o table
EarliestRestore                   Redundancy
--------------------------------  ------------
2026-08-21T09:00:00.000000+00:00  Geo

# 4. Confirm the runtime you depend on is not near retirement.
$ az webapp list-runtimes --os linux --query "[?starts_with(@, 'PYTHON')]" -o tsv
PYTHON|3.13
PYTHON|3.12
PYTHON|3.11
PYTHON|3.10

# 5. Confirm the identity layer -- the row you can never delegate.
$ az webapp identity show -g rg-paas-prod -n app-checkout-prod --query "{type:type, pid:principalId}" -o table
Type            Pid
--------------  ------------------------------------
SystemAssigned  6f0b1c94-2d3e-4a58-9b17-c8e4a09d7f31
```

El punto 4 es el específico de PaaS. Si tu app corre `PYTHON|3.10` y en una futura ejecución de ese comando solo aparecen 3.11+, tenés una migración innegociable con una fecha límite fijada por la plataforma. Ponela en el roadmap el día que desaparece de la lista, no el día que llega el aviso de Service Health.

---

## 10. Procedimiento de decisión

Dada una carga de trabajo, en orden:

1. **¿Ya existe un producto SaaS que haga esto?** Si la capacidad no es un diferenciador (correo, CRM, hosting de código fuente, identidad), compralo. Construirlo es ingeniería de valor negativo.
2. **¿La carga de trabajo requiere acceso a nivel de kernel, un SO no soportado, un driver personalizado o una licencia atada a hardware específico?** Si sí → **IaaS**. No hay argumento que anule una restricción técnica dura.
3. **¿El ciclo de trabajo del tráfico está por debajo de ~15%, o es orientado a eventos, o en ráfagas con un cold start tolerable?** Si sí → **PaaS serverless**.
4. **¿Es un servicio contenerizado que necesita semántica de Kubernetes (probes, revisiones, service mesh) pero no la administración de Kubernetes?** → **Container Apps**.
5. **¿Necesita genuinamente primitivos a nivel de clúster — operadores personalizados, CRDs, DaemonSets, tuning a nivel de nodo, planificación multi-tenant?** → **AKS**, y dotá de personal la mitad IaaS de la división de responsabilidad.
6. **En caso contrario** → **PaaS clásico**. Este es el default correcto para la mayoría de las aplicaciones web de línea de negocio, y los escenarios del examen de "minimizar el esfuerzo administrativo" casi siempre aterrizan acá.

La escalera de migración se mapea limpiamente sobre el mismo eje: *rehost* (lift-and-shift) aterriza en IaaS, *refactor* aterriza en PaaS, *rearchitect* aterriza en PaaS serverless/microservicios, *replace* aterriza en SaaS. Cada escalón hacia abajo cambia esfuerzo de ingeniería ahora por esfuerzo operativo para siempre.

---

## 11. Referencias

**Certificación y temario**
- Guía de estudio de AZ-900 — https://learn.microsoft.com/en-us/credentials/certifications/resources/study-guides/az-900
- Módulo de Microsoft Learn: Describir los tipos de servicios en la nube — https://learn.microsoft.com/en-us/training/modules/describe-cloud-service-types/

**Responsabilidad compartida**
- Responsabilidad compartida en la nube — https://learn.microsoft.com/en-us/azure/security/fundamentals/shared-responsibility

**IaaS**
- Descripción general de Azure Virtual Machines — https://learn.microsoft.com/en-us/azure/virtual-machines/overview
- Opciones de disponibilidad para VM de Azure — https://learn.microsoft.com/en-us/azure/virtual-machines/availability
- Confiabilidad en Virtual Machines — https://learn.microsoft.com/en-us/azure/reliability/reliability-virtual-machines
- Descripción general de Azure Update Manager — https://learn.microsoft.com/en-us/azure/update-manager/overview
- Diagnósticos de arranque — https://learn.microsoft.com/en-us/azure/virtual-machines/boot-diagnostics
- Run Command para VM Linux — https://learn.microsoft.com/en-us/azure/virtual-machines/linux/run-command
- Descripción general de los grupos de seguridad de red — https://learn.microsoft.com/en-us/azure/virtual-network/network-security-groups-overview
- Enrutamiento del tráfico de redes virtuales — https://learn.microsoft.com/en-us/azure/virtual-network/virtual-networks-udr-overview

**PaaS**
- Descripción general de App Service — https://learn.microsoft.com/en-us/azure/app-service/overview
- Política de soporte de runtimes de lenguaje de App Service — https://learn.microsoft.com/en-us/azure/app-service/language-support-policy
- Confiabilidad en Azure App Service — https://learn.microsoft.com/en-us/azure/reliability/reliability-app-service
- Registro de diagnóstico de App Service — https://learn.microsoft.com/en-us/azure/app-service/troubleshoot-diagnostic-logs
- Integración con VNet de App Service — https://learn.microsoft.com/en-us/azure/app-service/overview-vnet-integration
- Descripción general de Azure SQL Database — https://learn.microsoft.com/en-us/azure/azure-sql/database/sql-database-paas-overview
- Backups automatizados en Azure SQL Database — https://learn.microsoft.com/en-us/azure/azure-sql/database/automated-backups-overview

**Serverless**
- Descripción general de Azure Functions — https://learn.microsoft.com/en-us/azure/azure-functions/functions-overview
- Opciones de hosting y escalado de Azure Functions — https://learn.microsoft.com/en-us/azure/azure-functions/functions-scale
- Descripción general de Azure Container Apps — https://learn.microsoft.com/en-us/azure/container-apps/overview
- Reglas de escalado de Container Apps — https://learn.microsoft.com/en-us/azure/container-apps/scale-app
- Referencia YAML de Container Apps (`az containerapp create --yaml`) — https://learn.microsoft.com/en-us/cli/azure/containerapp

**La frontera de AKS**
- ¿Qué es Azure Kubernetes Service? — https://learn.microsoft.com/en-us/azure/aks/what-is-aks
- Políticas de soporte de AKS (la división explícita de responsabilidad) — https://learn.microsoft.com/en-us/azure/aks/support-policies
- Opciones de actualización para clústeres de AKS — https://learn.microsoft.com/en-us/azure/aks/upgrade-cluster
- Auto-upgrade del SO de nodos de AKS — https://learn.microsoft.com/en-us/azure/aks/auto-upgrade-node-os-image

**SLA, confiabilidad y observabilidad**
- Acuerdos de nivel de servicio para Microsoft Online Services — https://www.microsoft.com/licensing/docs/view/Service-Level-Agreements-SLA-for-Online-Services
- Documentación de confiabilidad de Azure — https://learn.microsoft.com/en-us/azure/reliability/overview
- Descripción general de las zonas de disponibilidad — https://learn.microsoft.com/en-us/azure/reliability/availability-zones-overview
- Descripción general de Azure Resource Health — https://learn.microsoft.com/en-us/azure/service-health/resource-health-overview
- Descripción general de Application Insights — https://learn.microsoft.com/en-us/azure/azure-monitor/app/app-insights-overview
- Reglas de recolección de datos de Azure Monitor — https://learn.microsoft.com/en-us/azure/azure-monitor/essentials/data-collection-rule-overview
- Referencia de Kusto Query Language — https://learn.microsoft.com/en-us/kusto/query/

**Infraestructura como código y CLI**
- Descripción general de Bicep — https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/overview
- Referencia de recursos de Bicep (todas las versiones de API usadas arriba) — https://learn.microsoft.com/en-us/azure/templates/
- Referencia de comandos `az vm` — https://learn.microsoft.com/en-us/cli/azure/vm
- Referencia de comandos `az webapp` — https://learn.microsoft.com/en-us/cli/azure/webapp
- Referencia de comandos `az aks` — https://learn.microsoft.com/en-us/cli/azure/aks

**Guía de arquitectura**
- Azure Well-Architected Framework — https://learn.microsoft.com/en-us/azure/well-architected/
- Estrategias de migración a la nube (las cinco R) — https://learn.microsoft.com/en-us/azure/cloud-adoption-framework/migrate/