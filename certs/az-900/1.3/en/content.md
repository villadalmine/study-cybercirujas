# 1.3 — Describe cloud service types

**Certification:** AZ-900 (Microsoft Azure Fundamentals) · Syllabus version 2026-07-20
**Domain:** 1 — Describe cloud concepts · **Exam weight:** 9.4
**Level:** Platform Architect / SRE — production depth

---

## 1. The production problem: service type *is* your on-call boundary

Most fundamentals material presents IaaS / PaaS / SaaS as a pizza-as-a-service metaphor. That framing is useless the first time you are paged at 03:00. The operationally correct framing is this:

> **A cloud service type is a contract that partitions a fixed stack of ten operational layers between two on-call rotations: yours and the provider's. Choosing a service type is choosing which layers can wake you up, and which layers you are contractually forbidden from touching when they break.**

The layers do not disappear when you move to PaaS. The hypervisor still needs patching, the guest OS still needs a kernel CVE remediated, the TLS terminator still needs a cipher suite deprecation. What changes is *who holds the pager and who holds the change window*.

This produces three concrete production consequences that the exam tests indirectly and that your incident reviews will test directly:

1. **Remediation latency is inverted from control.** On IaaS you can hotfix a kernel in 20 minutes because you own the OS layer. On PaaS you file a support case and wait, because you are not permitted to `ssh` into the worker. Higher abstraction means lower MTTR *variance* (fewer incidents) but higher MTTR *ceiling* (the incidents you do get, you cannot fix yourself).
2. **Deprecation is asymmetric.** On IaaS you can run an EOL runtime indefinitely and own the CVE. On PaaS the platform will forcibly retire your runtime stack on the provider's calendar, not yours. This is a real, scheduled, non-negotiable operational cost that IaaS does not have.
3. **SLA is composed, not inherited.** Wiring three 99.95% PaaS services in series does not give you 99.95%. It gives you ~99.85%. Service type determines how many independent SLA terms sit on your critical path.

Everything below is built on that framing.

---

## 2. The shared responsibility model as a layered ownership matrix

Microsoft publishes the canonical partition as a ten-layer table. Memorise the *shape*, not the pixels — the shape is what the exam and your architecture reviews both need.

| Layer | On-premises | IaaS | PaaS | SaaS |
|---|---|---|---|---|
| Information and data | **Customer** | **Customer** | **Customer** | **Customer** |
| Devices (mobile and PCs) | **Customer** | **Customer** | **Customer** | **Customer** |
| Accounts and identities | **Customer** | **Customer** | **Customer** | **Customer** |
| Identity and directory infrastructure | **Customer** | **Customer** | *Shared* | *Shared* |
| Applications | **Customer** | **Customer** | *Shared* | **Microsoft** |
| Network controls | **Customer** | **Customer** | *Shared* | **Microsoft** |
| Operating system | **Customer** | **Customer** | **Microsoft** | **Microsoft** |
| Physical hosts | **Customer** | **Microsoft** | **Microsoft** | **Microsoft** |
| Physical network | **Customer** | **Microsoft** | **Microsoft** | **Microsoft** |
| Physical datacenter | **Customer** | **Microsoft** | **Microsoft** | **Microsoft** |

Source: [Shared responsibility in the cloud](https://learn.microsoft.com/en-us/azure/security/fundamentals/shared-responsibility).

### The three invariants worth more than the table

**Invariant 1 — Three layers are *never* delegated.** Data, endpoints, and accounts/identities remain yours in every model including SaaS. If a Microsoft 365 tenant is breached through a phished credential with no MFA, that is a customer failure under the SaaS contract. The provider's obligation ended at "we offered you Conditional Access."

**Invariant 2 — The transition point for the OS layer is exactly the IaaS→PaaS boundary.** This single row is the highest-yield discriminator on the exam. "Who patches the operating system?" answers the service type deterministically.

**Invariant 3 — `Shared` is the dangerous cell.** Shared responsibility rows are where production outages hide, because both parties assume the other has it. In PaaS, "network controls" is shared: Microsoft runs the front-end and the load balancer; *you* still have to enable Private Endpoints, disable public network access, and set `minTlsVersion`. A default-configured App Service is internet-reachable by any client on earth. That is not a Microsoft failure — it is an unexercised customer control in a shared row.

### Verifying the matrix instead of trusting it

The matrix is a claim. Prove it per-resource against the live control plane:

```bash
$ az vm show -g rg-iaas-prod -n vm-appiaas-1 \
    --query "{osType:storageProfile.osDisk.osType, \
              image:storageProfile.imageReference.sku, \
              patchMode:osProfile.linuxConfiguration.patchSettings.patchMode}" -o table
OsType    Image     PatchMode
--------  --------  ------------------
Linux     server    AutomaticByPlatform
```

`patchMode` exists *because* the OS layer is yours. Now the PaaS equivalent:

```bash
$ az webapp config show -g rg-paas-prod -n app-checkout-prod \
    --query "{stack:linuxFxVersion, tls:minTlsVersion, ftps:ftpsState, http20:http20Enabled}" -o table
Stack               Tls    Ftps        Http20
------------------  -----  ----------  --------
PYTHON|3.12         1.2    Disabled    True

$ az webapp config show -g rg-paas-prod -n app-checkout-prod --query "patchMode"
# (no output — the property does not exist)
```

The absence of `patchMode` on the App Service resource is the shared responsibility model expressed as an API surface. You cannot express an intent you do not own.

---

## 3. IaaS — mechanics, and what you actually bought

### What is provisioned

IaaS gives you a virtualised slice of compute, storage, and network. In Azure the primitives are Virtual Machines, Virtual Machine Scale Sets, Managed Disks, Virtual Networks, Load Balancers, and Azure Files/Blob at the storage layer. The provider's obligation stops at the hypervisor boundary: you get a booted VM with a NIC and a disk, and everything above the virtual hardware line is yours.

**What "yours" concretely means in an SRE rotation:**

- Guest OS patching cadence, reboot orchestration, and maintenance windows
- Runtime installation and version pinning
- Host-based firewall (`nftables`/Windows Firewall) *in addition to* NSGs
- Log shipping agents, metric agents, and their failure modes
- Backup consistency (application-consistent vs crash-consistent snapshots)
- Capacity planning: instance count, SKU family, disk IOPS tier
- Scale-out logic and health probe semantics

### The availability model is *your* design problem

A single VM has no meaningful fault isolation. Azure's published VM SLA tiers make this explicit (verify current figures against the live SLA document — SLAs are versioned):

| Deployment topology | Published VM SLA | Fault domain covered | Monthly downtime budget |
|---|---|---|---|
| Single instance, all disks Premium SSD or Ultra | 99.9% | Host maintenance only | ~43.8 min |
| 2+ instances in an Availability Set | 99.95% | Rack / power / TOR switch | ~21.9 min |
| 2+ instances across Availability Zones | 99.99% | Datacenter | ~4.4 min |

This is a pure IaaS concern. In PaaS the platform makes the zone-redundancy decision a boolean flag; in IaaS it is a topology you must build, deploy twice, and test.

### Complete IaaS baseline — Bicep, not truncated

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

**Read that file as an accounting document.** Roughly 60% of its lines exist solely because IaaS makes the OS and network-control layers yours: NSG rules, patch settings, SSH key material, boot diagnostics, the monitoring agent, the data collection rule. The PaaS equivalent in §4 is a third of the size and does more.

### Deploying and inspecting it

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

Three VMs across three zones is the 99.99% topology. Note it took three deployments and a load balancer you still have to build — that labour is the price of the IaaS control surface.

---

## 4. PaaS — mechanics, and what you gave up to get it

### What is provisioned

PaaS gives you a managed application runtime. You supply code or a container image and a configuration object; the provider supplies the OS, the runtime, the patching, the TLS terminator, the autoscaler, the deployment slots, and the log pipeline.

Azure PaaS compute, ordered by decreasing control:

| Service | Unit of deployment | You control | Provider controls | Scale-to-zero |
|---|---|---|---|---|
| Azure App Service | Code or container | Runtime version, always-on, slots, VNet integration | OS, host patching, TLS, LB | No (Premium plans) |
| Azure Container Apps | Container image | Image, replicas, KEDA scale rules, Dapr | Kubernetes, node pool, ingress controller | **Yes** |
| Azure Functions (Consumption) | Function code | Trigger bindings, timeout, runtime version | Everything else, incl. instance count | **Yes** |
| Azure Spring Apps | Spring Boot JAR | App config, bindings | JVM, OS, service registry | No |
| Azure SQL Database | Schema + data | Schema, indexes, tier, backup retention | Engine patching, HA, failover, backups | Yes (serverless tier) |
| Azure Cosmos DB | Container + partition key | Partition key, indexing policy, consistency | Replication, sharding, patching | No (autoscale RU) |

### The two costs of PaaS, stated honestly

**Cost 1 — Forced runtime deprecation.** App Service enforces a language support policy: when a runtime reaches community EOL, the platform retires it on a published schedule. You will receive an Azure Service Health notice and a deadline. There is no "we will upgrade next quarter" option — after the deadline, new deployments are blocked and eventually the app stops. On IaaS the same EOL produces a CVE you own, not a deadline you must meet. This is a real, recurring, plannable engineering cost that belongs in your roadmap, and it is the single most-underestimated PaaS liability.

**Cost 2 — Diagnostic ceiling.** You cannot attach `perf`, you cannot read `dmesg`, you cannot take a kernel core dump. Your entire diagnostic surface is what the platform chooses to emit: HTTP logs, platform logs, the Kudu console, and profiler snapshots. When the failure is below that line, your remediation path is a support ticket. Budget for a higher p99 MTTR on the rare deep failure, in exchange for far fewer failures overall.

### Complete PaaS stack — Bicep, not truncated

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

### The line-count argument, made numerically

```bash
$ wc -l infra/iaas-baseline.bicep infra/paas-stack.bicep
  312 infra/iaas-baseline.bicep
  289 infra/paas-stack.bicep
  601 total
```

Comparable size — but count what each buys. `iaas-baseline.bicep` produces **one** VM in **one** zone with **no** application, **no** database, **no** load balancer, **no** deployment slot, and **no** backup policy. `paas-stack.bicep` produces a **zone-redundant** three-instance app tier, a **staging slot**, a **geo-redundant, point-in-time-recoverable database with 7-year LTR**, and a **complete telemetry pipeline**. That ratio — roughly 6:1 in delivered capability per line of IaC — is the actual economics of PaaS, and it is why the "appropriate use case" answers on the exam skew toward PaaS whenever the scenario says "minimise administrative effort."

---

## 5. Serverless / FaaS — a PaaS consumption model, not a fourth service type

Serverless is frequently mis-taught as a peer of IaaS/PaaS/SaaS. It is not. **Serverless is a billing and scaling model applied to PaaS.** The responsibility matrix row for row is identical to PaaS; what changes is that idle capacity is not billed and the instance count is not a configurable property.

| Property | Classic PaaS (App Service P1v3) | Serverless (Functions Consumption) |
|---|---|---|
| Billing unit | Provisioned instance-hour | GB-second + executions |
| Cost at zero traffic | Full plan cost | ~Zero (free grant applies) |
| Scale floor | ≥ 1 instance | 0 instances |
| Cold start | None (Always On) | 0.5–5 s, first request after idle |
| Max execution duration | Unbounded | Bounded (default 5 min, configurable ceiling) |
| Suited to | Steady, latency-sensitive traffic | Spiky, event-driven, batch, glue |

### Measuring the cold-start tax rather than asserting it

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

`ttfb` dropping from 3.41 s to 0.09 s across otherwise identical requests is the cold start, isolated: DNS, TCP and TLS are all flat, so the 3.3 s delta is entirely worker allocation plus runtime initialisation. If your SLO is `p99 < 500 ms` on a low-traffic endpoint, Consumption is disqualified on this data alone, and the architecture decision is Flex Consumption with pre-provisioned instances, a Premium plan, or Container Apps with `minReplicas: 1`.

### Container Apps — serverless containers, declared

Container Apps is the most instructive PaaS shape for an SRE audience: it exposes Kubernetes-derived semantics (probes, revisions, replicas, KEDA scalers) while keeping the entire cluster on the provider's side of the responsibility line.

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

`minReplicas: 1` is the cold-start mitigation made explicit and priced: you have chosen to pay for one always-warm replica to buy a latency SLO. That is the serverless trade-off written as a single line of YAML.

---

## 6. SaaS — consumption with a configuration surface

SaaS delivers a complete application. Microsoft 365, Dynamics 365, GitHub Enterprise Cloud, and Microsoft Entra ID's end-user experience are SaaS. Your entire engineering surface is:

- **Tenant configuration** — policies, sharing rules, retention, DLP
- **Identity and access** — who exists, what they can reach, Conditional Access
- **Data** — its classification, its residency, its lifecycle, its export path
- **Integration** — APIs, webhooks, connectors into your own systems

You do not deploy, patch, scale, or version SaaS. You cannot roll back a vendor feature release. The exit cost is data migration, and it is the dominant lock-in risk of the model.

### The SaaS failure most often mis-attributed

An organisation loses a mailbox to a business email compromise. Root-cause analysis blames "the cloud provider." Check the matrix: **Accounts and identities** is a customer row in every model, including SaaS. The provider's obligation was to make MFA and Conditional Access available; the customer's obligation was to enforce them. Verify enforcement, do not assume it:

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

That third row is a production finding. `enabledForReportingButNotEnforced` means the policy is in report-only mode and blocks nothing. Under the SaaS shared responsibility contract, an admin-role compromise through that gap is entirely on the customer.

---

## 7. The ambiguous middle: AKS, and why "managed" is not a service type

AKS is the case where the three-bucket taxonomy visibly strains, and where a precise engineer separates from a memoriser. **AKS is not one service type; it is a service type boundary drawn through the middle of a single product.**

| AKS layer | Owner | Service type of that layer |
|---|---|---|
| etcd, API server, scheduler, controller-manager | Microsoft | PaaS (free tier has no SLA; Standard/Premium tier carries the uptime SLA) |
| Control-plane patching and minor-version availability | Microsoft | PaaS |
| Node pool VM images, kernel, kubelet version | **Customer triggers, Microsoft supplies** | Shared |
| Node OS security patching and reboots | **Customer** (unless node auto-upgrade is configured) | IaaS |
| CNI plugin, network policy engine choice | **Customer** | IaaS |
| Workloads, manifests, resource requests, PDBs | **Customer** | IaaS-equivalent |
| Cluster autoscaler configuration | **Customer** | IaaS |

Prove the split against the live cluster:

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

**You can see the kernel version.** That is the tell: a layer you can observe at that granularity is a layer whose failures are yours. On App Service, `kubectl`-equivalent introspection does not exist — that layer is not merely hidden, it is *not your responsibility*.

Concretely: when a `containerd` regression causes image pull failures on your node pool, AKS puts you on the hook for the node image upgrade. When the same class of bug hits App Service, you never learn it happened.

### The workload half of the boundary, in full

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

The `PodDisruptionBudget` is the sharpest illustration of the shared boundary in the whole domain. Microsoft's node auto-upgrade will drain your nodes on *its* schedule; your PDB is the only mechanism that prevents that provider-side action from taking your service down. A shared-responsibility row is safe only when the customer side is actually configured.

---

## 8. Trade-off tables

### 8.1 Control, effort, and blast radius

| Dimension | IaaS | PaaS | Serverless PaaS | SaaS |
|---|---|---|---|---|
| OS-level control | Full | None | None | None |
| Runtime version pinning | Arbitrary, indefinite | Platform-supported list, with a retirement date | Same | None |
| Time to first production deploy | Days–weeks | Hours | Minutes | Minutes (config only) |
| Ongoing ops FTE (indicative) | 0.5–2.0 per workload | 0.1–0.3 | 0.05–0.15 | ~0.05 |
| Patch/CVE surface owned | Kernel + runtime + app | App only | App only | None |
| Deep diagnostics (`perf`, core dumps, `strace`) | Yes | No | No | No |
| MTTR for common failures | Higher (more moving parts) | Lower | Lowest | Vendor-bound |
| MTTR ceiling for rare deep failures | Bounded by your skill | Bounded by support SLA | Bounded by support SLA | Bounded by support SLA |
| Portability / exit cost | Lowest cost (a VM image is a VM image) | Medium (platform-specific config) | High (trigger bindings are proprietary) | Highest (data-only exit) |
| Compliance evidence effort | Highest (you attest the OS) | Medium (inherit provider attestations) | Medium | Lowest |

### 8.2 Cost shape — the crossover is real and computable

| Traffic pattern | Cheapest model | Why |
|---|---|---|
| Flat 24×7, high utilisation | IaaS with reservations / savings plan | 1- and 3-year commitments discount steeply; you amortise the ops cost across constant load |
| Business hours, predictable | PaaS with scheduled scaling | Pay for provisioned capacity only in the window |
| Spiky, low duty cycle (<15%) | Serverless | Idle is not billed; the cold start is the price |
| Unpredictable, bursty, container-based | Container Apps (min 0–1) | KEDA scale-to-zero with warm-floor option |
| Any pattern, non-differentiating capability | SaaS | Per-seat cost beats building and running it |

**Worked crossover.** A Python API serving 2M requests/month at 120 ms mean CPU time:

- *Serverless:* ≈ 2M × 0.12 s × 0.5 GB = **120,000 GB-s** plus 2M executions. Comfortably inside a small monthly bill; scales linearly with traffic.
- *PaaS (P1v3, always on, 1 instance):* fixed monthly cost regardless of whether traffic is 2M or 200 requests.
- *Crossover:* wherever the GB-s bill meets the fixed plan price. **Below** that point, serverless wins on cost and loses on p99. **Above** it, provisioned wins on both.

Compute the crossover from your own metrics rather than guessing:

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

A 52× peak-to-trough ratio (598 → 31,207) is the quantitative argument for scale-to-zero or aggressive autoscaling. If the ratio had been 1.4×, provisioned capacity would be correct and any serverless rewrite would be a cost regression paid for with cold-start latency.

### 8.3 Composite SLA — the arithmetic that kills naive PaaS designs

Published Azure SLAs at the time of writing (always verify against the live SLA document, which is versioned and changes):

| Service | Published SLA |
|---|---|
| App Service (Basic and above) | 99.95% |
| Azure SQL Database, General Purpose | 99.99% |
| Azure Cache for Redis (Standard/Premium) | 99.9% |
| Azure Storage (RA-GRS read) | 99.99% |
| Azure Container Apps | 99.95% |
| VM, single instance, Premium SSD | 99.9% |

Serial dependencies **multiply**:

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

**73 minutes/month, not 22.** Every PaaS service you add to the critical path spends error budget. This is the strongest technical argument against reflexive "just use more managed services": each one is a separate SLA term, a separate provider maintenance calendar, and a separate failure domain you cannot inspect. Mitigation is architectural — cache-aside so Redis is optional, circuit breakers, and graceful degradation — not a different service type.

### 8.4 Mapping Azure services to service types (exam-critical)

| Azure service | Service type | Discriminator |
|---|---|---|
| Virtual Machines, VM Scale Sets | **IaaS** | You patch the guest OS |
| Virtual Network, NSG, Load Balancer, Route Table | **IaaS** | Raw network primitives |
| Managed Disks, Azure Files (as a mount) | **IaaS** | Raw storage primitives |
| Azure App Service (Web Apps, API Apps) | **PaaS** | Managed runtime; no OS access |
| Azure Functions | **PaaS** (serverless) | Managed runtime, event-driven billing |
| Azure Container Apps | **PaaS** (serverless containers) | Managed Kubernetes underneath, hidden |
| Azure SQL Database, Cosmos DB, Database for PostgreSQL | **PaaS** | Managed engine; you own only schema and data |
| Azure Kubernetes Service | **Hybrid** — PaaS control plane, IaaS node pools | You still patch node OS images |
| Azure Logic Apps, Azure Data Factory | **PaaS** | Managed orchestration runtime |
| Azure Blob Storage (via API) | **PaaS** | Consumed as a managed service, not a mounted disk |
| Microsoft 365, Dynamics 365 | **SaaS** | Finished application |
| Microsoft Entra ID (end-user experience) | **SaaS** | Finished identity application |
| GitHub Enterprise Cloud, Azure DevOps Services | **SaaS** | Finished application |

**Exam heuristic, in priority order:**
1. *"Who patches the OS?"* → Customer = IaaS. Provider = PaaS or SaaS.
2. *"Do I write code?"* → Yes = IaaS or PaaS. No = SaaS.
3. *"Do I choose the instance count?"* → Yes = IaaS or classic PaaS. No = serverless PaaS.
4. Scenario says *"minimise administrative overhead"* / *"no infrastructure to manage"* → PaaS or SaaS, never IaaS.
5. Scenario says *"lift and shift"* / *"full control over the OS"* / *"custom kernel module"* / *"legacy application unchanged"* → IaaS.

---

## 9. Verification and failure diagnosis

### 9.1 The triage question that precedes every other

Before touching logs, answer: **is the failing layer on my side of the responsibility line?** The answer routes the entire incident. Ask the platform, do not infer.

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

`reasonType: PlatformInitiated` with `status: Degraded` means the fault is on **Microsoft's** side of the line. Your correct action is to open a support case, communicate to stakeholders, and *stop debugging your application*. Contrast:

```bash
$ az rest --method get \
    --url ".../virtualMachines/vm-appiaas-1/providers/Microsoft.ResourceHealth/availabilityStatuses/current?api-version=2022-10-01" \
    --query "properties.{status:availabilityState, reason:reasonType}" -o json
{
  "reason": "Unknown",
  "status": "Available"
}
```

`Available` from the platform while your service is down means the fault is **above** the hypervisor line — guest OS, runtime, or application. On IaaS, that is entirely yours.

### 9.2 IaaS diagnostic ladder

Ordered from cheapest to most invasive. Do not skip rungs.

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

The VM is healthy at the hypervisor layer; the application unit is crash-looping. This is exclusively a customer-side failure — and this diagnostic *only exists because you enabled boot diagnostics in the Bicep at provisioning time*. Enable it before the incident, not during.

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

`errno 110` is `ETIMEDOUT` — a silent drop, not a refusal. `ECONNREFUSED` would mean the packet reached a host with nothing listening; a timeout means the packet was swallowed. On IaaS, "network controls" is a customer row, so suspect your own NSG or the database firewall before suspecting the platform:

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

Outbound to Internet is allowed at priority 65001, so the NSG is not the cause. Escalate to effective routes and the PaaS-side firewall:

```bash
$ az network nic show-effective-route-table -g rg-iaas-prod -n nic-appiaas-1 -o table
Source                 State    Address Prefix    Next Hop Type     Next Hop IP
---------------------  -------  ----------------  ----------------  -------------
Default                Active   10.42.0.0/16      VnetLocal
Default                Active   0.0.0.0/0         Internet
User                   Active   0.0.0.0/0         VirtualAppliance  10.42.9.4
```

There it is. A user-defined route sends all egress to a firewall appliance at `10.42.9.4` that outranks the system default. The database is unreachable because the NVA is dropping the flow. Root cause is at a layer that exists **only** in IaaS — a class of incident PaaS makes structurally impossible, because you do not own the route table.

### 9.3 PaaS diagnostic ladder

The ladder is shorter, because there are fewer rungs you are allowed to climb.

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

Root cause: SQL has `publicNetworkAccess: Disabled` (correct, hardened) while the App Service has **no** VNet integration, so it can only reach SQL over the public endpoint that no longer exists. The failure is squarely in the *shared* "network controls" row: Microsoft runs the network, you failed to configure your side of it. Fix:

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

Note what you could *not* do at any point: no `tcpdump`, no `strace`, no `ss -tnp`, no kernel log. The PaaS diagnostic ladder has three rungs and then the ceiling.

### 9.4 KQL — proving responsibility from telemetry

Each query below is answerable in exactly one service type, which is itself the point.

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

### 9.5 Failure-to-owner routing table

| Symptom | IaaS owner | PaaS owner | SaaS owner | First command |
|---|---|---|---|---|
| Host reboots unexpectedly | Microsoft (maintenance) | Microsoft | Microsoft | `az vm get-instance-view` → `instanceView.maintenanceRedeployStatus` |
| Guest OS kernel panic | **You** | N/A | N/A | `az vm boot-diagnostics get-boot-log` |
| Unpatched CVE in runtime | **You** | Microsoft | Microsoft | `az vm run-command invoke ... "apt list --upgradable"` |
| Runtime forcibly retired | N/A | **You must migrate** | N/A | `az webapp list-runtimes --os linux` |
| App returns 500 | **You** | **You** | Vendor | `az webapp log tail` / `journalctl -u <svc>` |
| Cannot reach the database | **You** (NSG/UDR) | **Shared** (VNet integration) | Vendor | `az network nic show-effective-route-table` |
| TLS cipher deprecated | **You** | Microsoft | Microsoft | `az webapp config show --query minTlsVersion` |
| Storage account throttled (429) | Shared (your access pattern) | Shared | N/A | `az monitor metrics list --metric Throttling` |
| Credential phished, no MFA | **You** | **You** | **You** | Graph: Conditional Access policy state |
| Data deleted by an authorised user | **You** | **You** | **You** | Restore from *your* backup policy |

The last two rows never change owner across the entire table. That is Invariant 1, expressed operationally.

### 9.6 Verification checklist for a service-type decision

Run these before signing off an architecture. Every one is a command, not an opinion.

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

Item 4 is the PaaS-specific one. If your app runs `PYTHON|3.10` and only 3.11+ appear in a future run of that command, you have an unnegotiable migration on a platform-set deadline. Put it on the roadmap the day it disappears from the list, not the day the Service Health notice arrives.

---

## 10. Decision procedure

Given a workload, in order:

1. **Does a SaaS product already do this?** If the capability is not a differentiator (email, CRM, source hosting, identity), buy it. Building it is negative-value engineering.
2. **Does the workload require kernel-level access, an unsupported OS, a custom driver, or a licence bound to specific hardware?** If yes → **IaaS**. There is no argument that overrides a hard technical constraint.
3. **Is the traffic duty cycle below ~15%, or event-driven, or bursty with a tolerable cold start?** If yes → **serverless PaaS**.
4. **Is it a containerised service needing Kubernetes semantics (probes, revisions, service mesh) but not Kubernetes administration?** → **Container Apps**.
5. **Does it genuinely need cluster-level primitives — custom operators, CRDs, DaemonSets, node-level tuning, multi-tenant scheduling?** → **AKS**, and staff for the IaaS half of the responsibility split.
6. **Otherwise** → **classic PaaS**. This is the correct default for the majority of line-of-business web applications, and the exam's "minimise administrative effort" scenarios almost always land here.

The migration ladder maps cleanly onto the same axis: *rehost* (lift-and-shift) lands on IaaS, *refactor* lands on PaaS, *rearchitect* lands on serverless/microservices PaaS, *replace* lands on SaaS. Each rung down the ladder trades engineering effort now for operational effort forever.

---

## 11. Referencias

**Certification and syllabus**
- AZ-900 study guide — https://learn.microsoft.com/en-us/credentials/certifications/resources/study-guides/az-900
- Microsoft Learn module: Describe cloud service types — https://learn.microsoft.com/en-us/training/modules/describe-cloud-service-types/

**Shared responsibility**
- Shared responsibility in the cloud — https://learn.microsoft.com/en-us/azure/security/fundamentals/shared-responsibility

**IaaS**
- Azure Virtual Machines overview — https://learn.microsoft.com/en-us/azure/virtual-machines/overview
- Availability options for Azure VMs — https://learn.microsoft.com/en-us/azure/virtual-machines/availability
- Reliability in Virtual Machines — https://learn.microsoft.com/en-us/azure/reliability/reliability-virtual-machines
- Azure Update Manager overview — https://learn.microsoft.com/en-us/azure/update-manager/overview
- Boot diagnostics — https://learn.microsoft.com/en-us/azure/virtual-machines/boot-diagnostics
- Run Command for Linux VMs — https://learn.microsoft.com/en-us/azure/virtual-machines/linux/run-command
- Network security groups overview — https://learn.microsoft.com/en-us/azure/virtual-network/network-security-groups-overview
- Virtual network traffic routing — https://learn.microsoft.com/en-us/azure/virtual-network/virtual-networks-udr-overview

**PaaS**
- App Service overview — https://learn.microsoft.com/en-us/azure/app-service/overview
- App Service language runtime support policy — https://learn.microsoft.com/en-us/azure/app-service/language-support-policy
- Reliability in Azure App Service — https://learn.microsoft.com/en-us/azure/reliability/reliability-app-service
- App Service diagnostic logging — https://learn.microsoft.com/en-us/azure/app-service/troubleshoot-diagnostic-logs
- App Service VNet integration — https://learn.microsoft.com/en-us/azure/app-service/overview-vnet-integration
- Azure SQL Database overview — https://learn.microsoft.com/en-us/azure/azure-sql/database/sql-database-paas-overview
- Automated backups in Azure SQL Database — https://learn.microsoft.com/en-us/azure/azure-sql/database/automated-backups-overview

**Serverless**
- Azure Functions overview — https://learn.microsoft.com/en-us/azure/azure-functions/functions-overview
- Azure Functions hosting options and scale — https://learn.microsoft.com/en-us/azure/azure-functions/functions-scale
- Azure Container Apps overview — https://learn.microsoft.com/en-us/azure/container-apps/overview
- Container Apps scaling rules — https://learn.microsoft.com/en-us/azure/container-apps/scale-app
- Container Apps YAML reference (`az containerapp create --yaml`) — https://learn.microsoft.com/en-us/cli/azure/containerapp

**The AKS boundary**
- What is Azure Kubernetes Service? — https://learn.microsoft.com/en-us/azure/aks/what-is-aks
- AKS support policies (the explicit responsibility split) — https://learn.microsoft.com/en-us/azure/aks/support-policies
- Upgrade options for AKS clusters — https://learn.microsoft.com/en-us/azure/aks/upgrade-cluster
- AKS node OS auto-upgrade — https://learn.microsoft.com/en-us/azure/aks/auto-upgrade-node-os-image

**SLA, reliability, and observability**
- Service Level Agreements for Microsoft Online Services — https://www.microsoft.com/licensing/docs/view/Service-Level-Agreements-SLA-for-Online-Services
- Azure reliability documentation — https://learn.microsoft.com/en-us/azure/reliability/overview
- Availability zones overview — https://learn.microsoft.com/en-us/azure/reliability/availability-zones-overview
- Azure Resource Health overview — https://learn.microsoft.com/en-us/azure/service-health/resource-health-overview
- Application Insights overview — https://learn.microsoft.com/en-us/azure/azure-monitor/app/app-insights-overview
- Azure Monitor data collection rules — https://learn.microsoft.com/en-us/azure/azure-monitor/essentials/data-collection-rule-overview
- Kusto Query Language reference — https://learn.microsoft.com/en-us/kusto/query/

**Infrastructure as code and CLI**
- Bicep overview — https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/overview
- Bicep resource reference (all API versions used above) — https://learn.microsoft.com/en-us/azure/templates/
- `az vm` command reference — https://learn.microsoft.com/en-us/cli/azure/vm
- `az webapp` command reference — https://learn.microsoft.com/en-us/cli/azure/webapp
- `az aks` command reference — https://learn.microsoft.com/en-us/cli/azure/aks

**Architecture guidance**
- Azure Well-Architected Framework — https://learn.microsoft.com/en-us/azure/well-architected/
- Cloud migration strategies (the five Rs) — https://learn.microsoft.com/en-us/azure/cloud-adoption-framework/migrate/